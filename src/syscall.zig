// システムコール — INT 0x80 でユーザー空間からカーネル機能を呼び出す

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

export fn syscallDispatch(eax: u32, ebx: u32, ecx: u32, edx: u32) u32 {
    return switch (eax) {
        SYS_EXIT => sysExit(ebx),
        SYS_WRITE => sysWrite(ebx, ecx, edx),
        SYS_GETPID => sysGetpid(),
        SYS_YIELD => sysYield(),
        SYS_SLEEP => sysSleep(ebx),
        SYS_FORK => sysFork(),
        SYS_WAIT => sysWait(),
        SYS_KILL => sysKill(ebx, ecx),
        SYS_GETPPID => sysGetppid(),
        else => 0xFFFFFFFF,
    };
}

fn sysExit(status: u32) u32 {
    task.exitWithCode(@intCast(status & 0xFF));
    return 0;
}

fn sysWrite(_: u32, buf_ptr: u32, len: u32) u32 {
    if (len > 4096) return 0;
    if (buf_ptr == 0) return 0;
    const end = @addWithOverflow(buf_ptr, len);
    if (end[1] != 0) return 0;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    vga.write(buf[0..len]);
    return len;
}

fn sysGetpid() u32 {
    return task.getCurrentPid();
}

fn sysYield() u32 {
    task.yield();
    return 0;
}

fn sysSleep(ms: u32) u32 {
    _ = ms;
    task.yield();
    return 0;
}

fn sysFork() u32 {
    const result = task.fork();
    if (result < 0) return 0xFFFFFFFF;
    return @intCast(result);
}

fn sysWait() u32 {
    const result = task.wait();
    if (result == -2) {
        // 子がまだ生きている — yield して再試行
        task.yield();
        return @bitCast(task.wait());
    }
    return @bitCast(result);
}

fn sysKill(pid: u32, sig: u32) u32 {
    if (task.sendSignal(pid, @truncate(sig))) return 0;
    return 0xFFFFFFFF;
}

fn sysGetppid() u32 {
    if (task.getTask(task.getCurrentPid())) |t| {
        return t.ppid;
    }
    return 0;
}

// ユーザー空間用のシステムコールラッパー
pub fn userSyscall(num: u32, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> u32),
        : [num] "{eax}" (num),
          [a1] "{ebx}" (arg1),
          [a2] "{ecx}" (arg2),
          [a3] "{edx}" (arg3),
        : .{ .memory = true }
    );
}
