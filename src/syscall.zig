// システムコール — INT 0x80 でユーザー空間からカーネル機能を呼び出す (64-bit)

const vga = @import("vga.zig");
const task = @import("task.zig");
const serial = @import("serial.zig");

// システムコール番号
pub const SYS_EXIT = 0;
pub const SYS_WRITE = 1;
pub const SYS_GETPID = 2;
pub const SYS_YIELD = 3;
pub const SYS_SLEEP = 4;
pub const SYS_FORK = 5;
pub const SYS_WAIT = 6;
pub const SYS_KILL = 7;
pub const SYS_GETPPID = 8;

// Called from syscallStub in idt.zig via System V AMD64 calling convention:
// RDI=syscall_num, RSI=arg1, RDX=arg2, RCX=arg3
export fn syscallDispatch64(rdi: u64, rsi: u64, rdx: u64, rcx: u64) u64 {
    const num: u32 = @truncate(rdi);
    const arg1: u64 = rsi;
    const arg2: u64 = rdx;
    const arg3: u64 = rcx;
    return switch (num) {
        SYS_EXIT => sysExit(arg1),
        SYS_WRITE => sysWrite(arg1, arg2, arg3),
        SYS_GETPID => sysGetpid(),
        SYS_YIELD => sysYield(),
        SYS_SLEEP => sysSleep(arg1),
        SYS_FORK => sysFork(),
        SYS_WAIT => sysWait(),
        SYS_KILL => sysKill(arg1, arg2),
        SYS_GETPPID => sysGetppid(),
        else => 0xFFFFFFFFFFFFFFFF,
    };
}

fn sysExit(status: u64) u64 {
    task.exitWithCode(@intCast(@as(u32, @truncate(status)) & 0xFF));
    return 0;
}

fn sysWrite(_: u64, buf_ptr: u64, len: u64) u64 {
    if (len > 4096) return 0;
    if (buf_ptr == 0) return 0;
    const end = @addWithOverflow(buf_ptr, len);
    if (end[1] != 0) return 0;
    const buf: [*]const u8 = @ptrFromInt(@as(usize, @truncate(buf_ptr)));
    vga.write(buf[0..@as(usize, @truncate(len))]);
    return len;
}

fn sysGetpid() u64 {
    return task.getCurrentPid();
}

fn sysYield() u64 {
    task.yield();
    return 0;
}

fn sysSleep(ms: u64) u64 {
    _ = ms;
    task.yield();
    return 0;
}

fn sysFork() u64 {
    const result = task.fork();
    if (result < 0) return 0xFFFFFFFFFFFFFFFF;
    return @intCast(result);
}

fn sysWait() u64 {
    const result = task.wait();
    if (result == -2) {
        // 子がまだ生きている — yield して再試行
        task.yield();
        return @bitCast(@as(i64, task.wait()));
    }
    return @bitCast(@as(i64, result));
}

fn sysKill(pid: u64, sig: u64) u64 {
    if (task.sendSignal(@truncate(pid), @truncate(sig))) return 0;
    return 0xFFFFFFFFFFFFFFFF;
}

fn sysGetppid() u64 {
    if (task.getTask(task.getCurrentPid())) |t| {
        return t.ppid;
    }
    return 0;
}

// ユーザー空間用のシステムコールラッパー (64-bit)
pub fn userSyscall(num: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a1] "{rbx}" (arg1),
          [a2] "{rcx}" (arg2),
          [a3] "{rdx}" (arg3),
        : .{ .memory = true }
    );
}
