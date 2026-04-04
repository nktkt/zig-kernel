// タスク管理 — プロセス構造体、コンテキストスイッチ、スケジューラ、fork/wait/signal

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const tss = @import("tss.zig");
const serial = @import("serial.zig");
const syscall = @import("syscall.zig");
const vmm = @import("vmm.zig");

pub const MAX_TASKS = 16;
const KERNEL_STACK_SIZE = 4096;
const USER_STACK_SIZE = 4096;

const USER_CS = 0x18 | 3;
const USER_DS = 0x20 | 3;

pub const TaskState = enum(u8) {
    unused,
    ready,
    running,
    waiting, // wait() で子プロセス待ち
    terminated,
    zombie, // 終了済みだが親が wait していない
};

// シグナル
pub const SIG_NONE: u8 = 0;
pub const SIG_KILL: u8 = 9;
pub const SIG_TERM: u8 = 15;
pub const SIG_INT: u8 = 2;

pub const Task = struct {
    pid: u32,
    ppid: u32, // 親プロセスID
    state: TaskState,
    kernel_esp: u32,
    kernel_stack: u32,
    user_stack: u32,
    page_dir: u32, // ページディレクトリ物理アドレス (0=カーネル共有)
    exit_code: i32,
    pending_signal: u8,
    name: [16]u8,
    name_len: u8,
};

var tasks: [MAX_TASKS]Task = undefined;
pub var current_task: u32 = 0;
var next_pid: u32 = 1;
var task_count: u32 = 0;
var scheduling_enabled: bool = false;

pub fn init() void {
    for (&tasks) |*t| {
        t.state = .unused;
        t.pid = 0;
        t.ppid = 0;
        t.page_dir = 0;
        t.exit_code = 0;
        t.pending_signal = SIG_NONE;
    }
    tasks[0].pid = 0;
    tasks[0].ppid = 0;
    tasks[0].state = .running;
    tasks[0].page_dir = vmm.getCR3(); // カーネルの PD
    tasks[0].name_len = 6;
    @memcpy(tasks[0].name[0..6], "kernel");
    current_task = 0;
    task_count = 1;
}

pub fn enableScheduling() void {
    scheduling_enabled = true;
}

// ---- プロセス作成 ----

pub fn createUserTask(entry_point: u32, name: []const u8) ?u32 {
    var slot: ?usize = null;
    for (&tasks, 0..) |*t, i| {
        if (t.state == .unused) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse return null;

    const kstack = pmm.alloc() orelse return null;
    const ustack = pmm.alloc() orelse {
        pmm.free(kstack);
        return null;
    };
    const kstack_top = kstack + KERNEL_STACK_SIZE;
    const ustack_top = ustack + USER_STACK_SIZE;

    const stack_ptr: [*]u32 = @ptrFromInt(kstack_top - 13 * 4);
    // pusha regs
    stack_ptr[0] = 0; // EDI
    stack_ptr[1] = 0; // ESI
    stack_ptr[2] = 0; // EBP
    stack_ptr[3] = 0; // ESP (ignored)
    stack_ptr[4] = 0; // EBX
    stack_ptr[5] = 0; // EDX
    stack_ptr[6] = 0; // ECX
    stack_ptr[7] = 0; // EAX
    // IRET frame
    stack_ptr[8] = entry_point;
    stack_ptr[9] = USER_CS;
    stack_ptr[10] = 0x202; // EFLAGS (IF=1)
    stack_ptr[11] = ustack_top;
    stack_ptr[12] = USER_DS;

    const pid = next_pid;
    next_pid += 1;

    tasks[idx] = .{
        .pid = pid,
        .ppid = tasks[current_task].pid,
        .state = .ready,
        .kernel_esp = kstack_top - 13 * 4,
        .kernel_stack = kstack,
        .user_stack = ustack,
        .page_dir = 0, // カーネル共有 PD (identity mapped)
        .exit_code = 0,
        .pending_signal = SIG_NONE,
        .name = undefined,
        .name_len = @intCast(@min(name.len, 16)),
    };
    @memcpy(tasks[idx].name[0..tasks[idx].name_len], name[0..tasks[idx].name_len]);
    task_count += 1;

    serial.write("[task] created pid=");
    serial.writeHex(pid);
    serial.write(" ppid=");
    serial.writeHex(tasks[current_task].pid);
    serial.write("\n");

    return pid;
}

// ---- fork ----

pub fn fork() i32 {
    var slot: ?usize = null;
    for (&tasks, 0..) |*t, i| {
        if (t.state == .unused) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse return -1;

    const parent = &tasks[current_task];

    // 新しいカーネルスタック
    const kstack = pmm.alloc() orelse return -1;

    // 親のカーネルスタックをコピー
    const parent_kstack: [*]const u8 = @ptrFromInt(parent.kernel_stack);
    const child_kstack: [*]u8 = @ptrFromInt(kstack);
    @memcpy(child_kstack[0..KERNEL_STACK_SIZE], parent_kstack[0..KERNEL_STACK_SIZE]);

    // 新しいユーザースタック
    const ustack = pmm.alloc() orelse {
        pmm.free(kstack);
        return -1;
    };
    // 親のユーザースタックをコピー
    const parent_ustack: [*]const u8 = @ptrFromInt(parent.user_stack);
    const child_ustack: [*]u8 = @ptrFromInt(ustack);
    @memcpy(child_ustack[0..USER_STACK_SIZE], parent_ustack[0..USER_STACK_SIZE]);

    const pid = next_pid;
    next_pid += 1;

    // 子の kernel_esp は親と同じオフセット (スタック底からの距離)
    const esp_offset = parent.kernel_esp - parent.kernel_stack;
    const child_esp = kstack + esp_offset;

    // 子の IRET フレーム内の User ESP を新しい ustack に調整
    // kernel_esp → pusha[8] → IRET[EIP,CS,EFLAGS,ESP,SS]
    // User ESP は offset +11*4 from kernel_esp
    const child_stack: [*]u32 = @ptrFromInt(child_esp);
    const parent_ustack_top = parent.user_stack + USER_STACK_SIZE;
    const child_ustack_top = ustack + USER_STACK_SIZE;
    // User ESP の差分を調整
    if (child_stack[11] >= parent.user_stack and child_stack[11] <= parent_ustack_top) {
        const usp_offset = parent_ustack_top - child_stack[11];
        child_stack[11] = child_ustack_top - usp_offset;
    }

    // 子の EAX (fork 戻り値) を 0 に設定
    child_stack[7] = 0; // EAX = 0 (child returns 0)

    tasks[idx] = .{
        .pid = pid,
        .ppid = parent.pid,
        .state = .ready,
        .kernel_esp = child_esp,
        .kernel_stack = kstack,
        .user_stack = ustack,
        .page_dir = 0, // カーネル共有
        .exit_code = 0,
        .pending_signal = SIG_NONE,
        .name = parent.name,
        .name_len = parent.name_len,
    };
    task_count += 1;

    serial.write("[task] fork pid=");
    serial.writeHex(pid);
    serial.write(" from ");
    serial.writeHex(parent.pid);
    serial.write("\n");

    return @intCast(pid); // parent returns child PID
}

// ---- wait ----

pub fn wait() i32 {
    const parent_pid = tasks[current_task].pid;

    // zombie の子を探す
    for (&tasks) |*t| {
        if (t.ppid == parent_pid and t.state == .zombie) {
            const code = t.exit_code;
            serial.write("[task] reaped pid=");
            serial.writeHex(t.pid);
            serial.write("\n");
            t.state = .unused;
            task_count -= 1;
            return code;
        }
    }

    // 子プロセスが存在するか確認
    var has_children = false;
    for (&tasks) |*t| {
        if (t.ppid == parent_pid and t.state != .unused) {
            has_children = true;
            break;
        }
    }
    if (!has_children) return -1; // 子なし

    // 子が終了するまで待つ (yield して再試行)
    return -2; // caller should retry after yield
}

// ---- exit ----

pub fn exitWithCode(code: i32) void {
    const t = &tasks[current_task];
    t.exit_code = code;
    t.state = .zombie;

    serial.write("[task] exit pid=");
    serial.writeHex(t.pid);
    serial.write(" code=");
    serial.writeHex(@intCast(code));
    serial.write("\n");

    // orphan された子は init (pid=0) に引き渡す
    for (&tasks) |*child| {
        if (child.ppid == t.pid and child.state != .unused) {
            child.ppid = 0;
        }
    }

    // waiting 中の親を起こす
    for (&tasks) |*parent| {
        if (parent.pid == t.ppid and parent.state == .waiting) {
            parent.state = .ready;
        }
    }

    asm volatile ("sti");
    while (true) {
        asm volatile ("hlt");
    }
}

// ---- signal ----

pub fn sendSignal(pid: u32, sig: u8) bool {
    for (&tasks) |*t| {
        if (t.pid == pid and t.state != .unused and t.state != .zombie) {
            if (sig == SIG_KILL or sig == SIG_TERM) {
                // 即座に終了
                t.exit_code = -@as(i32, sig);
                t.state = .zombie;
                serial.write("[task] killed pid=");
                serial.writeHex(pid);
                serial.write("\n");
                // 親を起こす
                for (&tasks) |*parent| {
                    if (parent.pid == t.ppid and parent.state == .waiting) {
                        parent.state = .ready;
                    }
                }
                return true;
            }
            t.pending_signal = sig;
            return true;
        }
    }
    return false;
}

// ---- スケジューラ ----

pub export fn timerSchedule(esp: u32) u32 {
    if (!scheduling_enabled) return esp;

    tasks[current_task].kernel_esp = esp;

    // pending signal チェック
    if (tasks[current_task].pending_signal == SIG_INT) {
        tasks[current_task].pending_signal = SIG_NONE;
        tasks[current_task].exit_code = -2;
        tasks[current_task].state = .zombie;
    }

    const prev = current_task;
    var next = current_task;

    var i: u32 = 0;
    while (i < MAX_TASKS) : (i += 1) {
        next = (next + 1) % MAX_TASKS;
        if (tasks[next].state == .ready) break;
    }

    if (next == prev) return esp;

    if (tasks[prev].state == .running) {
        tasks[prev].state = .ready;
    }
    tasks[next].state = .running;
    current_task = next;

    tss.setKernelStack(tasks[next].kernel_stack + KERNEL_STACK_SIZE);

    return tasks[next].kernel_esp;
}

pub fn exitCurrentTask() void {
    exitWithCode(0);
}

pub fn yield() void {
    asm volatile ("sti; hlt");
}

pub fn getCurrentPid() u32 {
    return tasks[current_task].pid;
}

pub fn getTask(pid: u32) ?*Task {
    for (&tasks) |*t| {
        if (t.pid == pid and t.state != .unused) return t;
    }
    return null;
}

pub fn printTaskList() void {
    vga.setColor(.yellow, .black);
    vga.write("PID  PPID STATE       NAME\n");
    vga.setColor(.light_grey, .black);
    for (&tasks) |*t| {
        if (t.state == .unused) continue;
        pmm.printNum(t.pid);
        if (t.pid < 10) vga.write("    ") else vga.write("   ");
        pmm.printNum(t.ppid);
        if (t.ppid < 10) vga.write("    ") else vga.write("   ");
        switch (t.state) {
            .running => {
                vga.setColor(.light_green, .black);
                vga.write("running  ");
            },
            .ready => {
                vga.setColor(.light_cyan, .black);
                vga.write("ready    ");
            },
            .waiting => {
                vga.setColor(.yellow, .black);
                vga.write("waiting  ");
            },
            .zombie => {
                vga.setColor(.light_red, .black);
                vga.write("zombie   ");
            },
            .terminated => {
                vga.setColor(.dark_grey, .black);
                vga.write("dead     ");
            },
            .unused => {},
        }
        vga.setColor(.light_grey, .black);
        vga.write(t.name[0..t.name_len]);
        vga.putChar('\n');
    }
}

// ---- 組み込みユーザープログラム ----

pub fn userProgramHello() callconv(.c) noreturn {
    const msg = "Hello from user space! (pid=";
    _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);

    const pid = syscall.userSyscall(syscall.SYS_GETPID, 0, 0, 0);
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    var v = pid;
    if (v == 0) {
        buf[0] = '0';
        len = 1;
    } else {
        while (v > 0) {
            buf[len] = @truncate('0' + v % 10);
            len += 1;
            v /= 10;
        }
        var a: usize = 0;
        var b: usize = len - 1;
        while (a < b) {
            const tmp = buf[a];
            buf[a] = buf[b];
            buf[b] = tmp;
            a += 1;
            b -= 1;
        }
    }
    _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(&buf), @truncate(len));
    const msg2 = ")\n";
    _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(msg2.ptr), msg2.len);
    _ = syscall.userSyscall(syscall.SYS_EXIT, 0, 0, 0);
    while (true) {}
}

pub fn userProgramCounter() callconv(.c) noreturn {
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const msg = "Counter task running...\n";
        _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
        _ = syscall.userSyscall(syscall.SYS_YIELD, 0, 0, 0);
    }
    const done = "Counter task done.\n";
    _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(done.ptr), done.len);
    _ = syscall.userSyscall(syscall.SYS_EXIT, 0, 0, 0);
    while (true) {}
}

// fork テスト用: 親子で異なるメッセージを出力
pub fn userProgramForkTest() callconv(.c) noreturn {
    const pid = syscall.userSyscall(syscall.SYS_FORK, 0, 0, 0);
    if (pid == 0) {
        // 子プロセス
        const msg = "  Child process running!\n";
        _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
        _ = syscall.userSyscall(syscall.SYS_EXIT, 42, 0, 0);
    } else {
        // 親プロセス
        const msg = "  Parent: forked child\n";
        _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
        // 子の終了を待つ
        _ = syscall.userSyscall(syscall.SYS_WAIT, 0, 0, 0);
        const msg2 = "  Parent: child exited\n";
        _ = syscall.userSyscall(syscall.SYS_WRITE, 1, @intFromPtr(msg2.ptr), msg2.len);
        _ = syscall.userSyscall(syscall.SYS_EXIT, 0, 0, 0);
    }
    while (true) {}
}
