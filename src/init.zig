// init プロセス — PID=0 (カーネル) が init として機能
// zombie プロセスの回収をタイマー割り込みで行う

const task = @import("task.zig");
const serial = @import("serial.zig");

/// タイマー割り込みから定期的に呼ばれる: zombie 子プロセスを回収
pub fn reapZombies() void {
    // カーネル (PID=0) の子で zombie になったプロセスを回収
    const result = task.wait();
    if (result >= 0) {
        serial.write("[init] reaped zombie, exit=");
        serial.writeHex(@intCast(result));
        serial.write("\n");
    }
}
