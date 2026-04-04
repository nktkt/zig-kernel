// タスク管理 — プロセス構造体、コンテキストスイッチ、スケジューラ

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const tss = @import("tss.zig");
const serial = @import("serial.zig");
const syscall = @import("syscall.zig");

const MAX_TASKS = 16;
const KERNEL_STACK_SIZE = 4096;
const USER_STACK_SIZE = 4096;

const USER_CS = 0x18 | 3; // GDT entry 3, RPL 3
const USER_DS = 0x20 | 3; // GDT entry 4, RPL 3

pub const TaskState = enum(u8) {
    unused,
    ready,
    running,
    terminated,
};

pub const Task = struct {
    pid: u32,
    state: TaskState,
    kernel_esp: u32, // 保存されたカーネルスタックポインタ
    kernel_stack: u32, // カーネルスタックの底
    user_stack: u32, // ユーザースタックの底
    name: [16]u8,
    name_len: u8,
};

var tasks: [MAX_TASKS]Task = undefined;
var current_task: u32 = 0;
var next_pid: u32 = 1;
var task_count: u32 = 0;
var scheduling_enabled: bool = false;

pub fn init() void {
    for (&tasks) |*t| {
        t.state = .unused;
        t.pid = 0;
    }
    // タスク0: カーネル (idle)
    tasks[0].pid = 0;
    tasks[0].state = .running;
    tasks[0].name_len = 6;
    @memcpy(tasks[0].name[0..6], "kernel");
    current_task = 0;
    task_count = 1;
}

pub fn enableScheduling() void {
    scheduling_enabled = true;
}

// ユーザータスクを作成
pub fn createUserTask(entry_point: u32, name: []const u8) ?u32 {
    // 空きスロットを探す
    var slot: ?usize = null;
    for (&tasks, 0..) |*t, i| {
        if (t.state == .unused) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse return null;

    // カーネルスタックとユーザースタックを確保
    const kstack = pmm.alloc() orelse return null;
    const ustack = pmm.alloc() orelse {
        pmm.free(kstack);
        return null;
    };
    const kstack_top = kstack + KERNEL_STACK_SIZE;
    const ustack_top = ustack + USER_STACK_SIZE;

    // カーネルスタック上に IRET 用のフレームを構築
    // Ring 3 への遷移: SS, ESP, EFLAGS, CS, EIP をプッシュ
    const stack_ptr: [*]u32 = @ptrFromInt(kstack_top - 13 * 4);

    // pusha で復帰するレジスタ (8個: EDI,ESI,EBP,ESP,EBX,EDX,ECX,EAX)
    stack_ptr[0] = 0; // EDI
    stack_ptr[1] = 0; // ESI
    stack_ptr[2] = 0; // EBP
    stack_ptr[3] = 0; // ESP (ignored by popa)
    stack_ptr[4] = 0; // EBX
    stack_ptr[5] = 0; // EDX
    stack_ptr[6] = 0; // ECX
    stack_ptr[7] = 0; // EAX

    // IRET フレーム (Ring 3 へ)
    stack_ptr[8] = entry_point; // EIP
    stack_ptr[9] = USER_CS; // CS
    stack_ptr[10] = 0x202; // EFLAGS (IF=1)
    stack_ptr[11] = ustack_top; // User ESP
    stack_ptr[12] = USER_DS; // User SS

    const pid = next_pid;
    next_pid += 1;

    tasks[idx] = .{
        .pid = pid,
        .state = .ready,
        .kernel_esp = kstack_top - 13 * 4,
        .kernel_stack = kstack,
        .user_stack = ustack,
        .name = undefined,
        .name_len = @intCast(@min(name.len, 16)),
    };
    @memcpy(tasks[idx].name[0..tasks[idx].name_len], name[0..tasks[idx].name_len]);
    task_count += 1;

    serial.write("[task] created pid=");
    serial.writeHex(pid);
    serial.write("\n");

    return pid;
}

// コンテキストスイッチは timerSchedule (IRQ0) 経由で行う。
// voluntary な schedule/switchContext は不要。IRQ0 の pusha/popa/iret と
// 整合するフレームを自前で構築するのは複雑でバグの温床になるため、
// yield/exit では割り込みを再有効化して timer に委ねる。

// IRQ0 (タイマー) から呼ばれる
pub export fn timerSchedule(esp: u32) u32 {
    if (!scheduling_enabled) return esp;

    tasks[current_task].kernel_esp = esp;

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
    tasks[current_task].state = .terminated;
    task_count -= 1;
    serial.write("[task] exit pid=");
    serial.writeHex(tasks[current_task].pid);
    serial.write("\n");

    // 割り込みを再有効化し、タイマーに切り替えを委ねる
    asm volatile ("sti");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn yield() void {
    // INT 0x80 は割り込みゲートなので IF=0 の状態で入る。
    // sti で割り込みを再有効化し、hlt で次のタイマー割り込みを待つ。
    // タイマー (IRQ0) が pusha/popa/iret で正しくコンテキストスイッチする。
    asm volatile ("sti; hlt");
}

pub fn getCurrentPid() u32 {
    return tasks[current_task].pid;
}

pub fn printTaskList() void {
    vga.setColor(.yellow, .black);
    vga.write("PID  STATE       NAME\n");
    vga.setColor(.light_grey, .black);
    for (&tasks) |*t| {
        if (t.state == .unused) continue;
        pmm.printNum(t.pid);
        if (t.pid < 10) vga.write("    ");
        if (t.pid >= 10) vga.write("   ");
        switch (t.state) {
            .running => {
                vga.setColor(.light_green, .black);
                vga.write("running     ");
            },
            .ready => {
                vga.setColor(.light_cyan, .black);
                vga.write("ready       ");
            },
            .terminated => {
                vga.setColor(.dark_grey, .black);
                vga.write("terminated  ");
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
        // reverse
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
