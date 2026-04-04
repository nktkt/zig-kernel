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

// INT 0x80 ハンドラから呼ばれるディスパッチ関数
export fn syscallDispatch(eax: u32, ebx: u32, ecx: u32, edx: u32) u32 {
    return switch (eax) {
        SYS_EXIT => sysExit(ebx),
        SYS_WRITE => sysWrite(ebx, ecx, edx),
        SYS_GETPID => sysGetpid(),
        SYS_YIELD => sysYield(),
        SYS_SLEEP => sysSleep(ebx),
        else => 0xFFFFFFFF, // unknown syscall
    };
}

fn sysExit(status: u32) u32 {
    _ = status;
    serial.write("[syscall] exit\n");
    task.exitCurrentTask();
    return 0;
}

fn sysWrite(_: u32, buf_ptr: u32, len: u32) u32 {
    // 簡易的な安全チェック
    if (len > 4096) return 0;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const slice = buf[0..len];
    vga.write(slice);
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
