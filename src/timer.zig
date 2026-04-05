// High-Resolution Timer — タイマーコールバック・ベンチマーク機能
// PIT の tick を利用した高精度タイミング

const pit = @import("pit.zig");
const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

/// タイマーコールバック関数の型
pub const CallbackFn = *const fn () void;

/// タイマーコールバック構造体
pub const TimerCallback = struct {
    active: bool = false,
    interval_ms: u32 = 0,
    last_fired: u64 = 0,
    callback: ?CallbackFn = null,
    name: [16]u8 = undefined,
    name_len: usize = 0,
    fire_count: u32 = 0,
};

const MAX_CALLBACKS = 4;
var callbacks: [MAX_CALLBACKS]TimerCallback = [_]TimerCallback{.{}} ** MAX_CALLBACKS;
var callback_count: usize = 0;

/// 現在のタイムスタンプ (ms 単位の tick 数) を返す
pub fn timestamp() u64 {
    return pit.getTicks();
}

/// 経過時間を計算 (ms)
pub fn elapsed(start: u64) u64 {
    const now = pit.getTicks();
    return now -| start;
}

/// ベンチマーク: 関数の実行時間を計測して表示
pub fn benchmark(name: []const u8, func: *const fn () void) void {
    vga.setColor(.light_cyan, .black);
    vga.write("Benchmark: ");
    vga.write(name);
    vga.write(" ... ");

    const start = timestamp();
    func();
    const end = timestamp();

    const duration = end -| start;
    vga.setColor(.light_green, .black);
    pmm.printNum(@truncate(duration));
    vga.write(" ms\n");

    // シリアルにもログ
    serial.write("Benchmark [");
    serial.write(name);
    serial.write("] = ");
    serial.writeHex(@truncate(duration));
    serial.write(" ms\n");
}

/// タイマーコールバックを登録
/// interval_ms: 発火間隔 (ミリ秒)
/// func: コールバック関数
/// name: タイマー名 (最大16文字)
/// 戻り値: スロットインデックス, 満杯なら null
pub fn registerCallback(interval_ms: u32, func: CallbackFn, name: []const u8) ?usize {
    // 空きスロットを探す
    for (&callbacks, 0..) |*cb, i| {
        if (!cb.active) {
            cb.active = true;
            cb.interval_ms = interval_ms;
            cb.last_fired = timestamp();
            cb.callback = func;
            cb.fire_count = 0;
            const copy_len = if (name.len < 16) name.len else 16;
            @memcpy(cb.name[0..copy_len], name[0..copy_len]);
            cb.name_len = copy_len;
            callback_count += 1;
            return i;
        }
    }
    return null;
}

/// タイマーコールバックを解除
pub fn unregisterCallback(slot: usize) void {
    if (slot >= MAX_CALLBACKS) return;
    if (callbacks[slot].active) {
        callbacks[slot].active = false;
        if (callback_count > 0) callback_count -= 1;
    }
}

/// PIT の tick() から呼ばれる: 登録済みコールバックをチェック・発火
pub fn tickCallbacks() void {
    const now = timestamp();
    for (&callbacks) |*cb| {
        if (cb.active) {
            if (cb.callback) |func| {
                if (now -| cb.last_fired >= cb.interval_ms) {
                    func();
                    cb.last_fired = now;
                    cb.fire_count +|= 1;
                }
            }
        }
    }
}

/// アクティブなタイマー一覧を表示
pub fn printTimers() void {
    vga.setColor(.yellow, .black);
    vga.write("Active Timers:\n");
    vga.setColor(.light_grey, .black);

    var found = false;
    for (&callbacks, 0..) |*cb, i| {
        if (cb.active) {
            found = true;
            vga.write("  [");
            pmm.printNum(i);
            vga.write("] ");
            vga.write(cb.name[0..cb.name_len]);
            vga.write(" every ");
            pmm.printNum(cb.interval_ms);
            vga.write("ms (fired ");
            pmm.printNum(cb.fire_count);
            vga.write("x)\n");
        }
    }

    if (!found) {
        vga.write("  (none)\n");
    }

    vga.write("  Total registered: ");
    pmm.printNum(callback_count);
    vga.putChar('\n');
}

/// メモリベンチマーク用の関数
pub fn memBenchmark() void {
    // 簡易メモリ読み書きベンチマーク
    // カーネルスタック上のバッファに繰り返しアクセス
    var buf: [1024]u8 = undefined;
    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        // 書き込み
        for (&buf, 0..) |*b, j| {
            b.* = @truncate(j ^ iter);
        }
        // 読み込み (揮発を防ぐため volatile 風に sum を取る)
        var sum: u32 = 0;
        for (buf) |b| {
            sum +%= b;
        }
        // sum を使う (最適化で消えないように)
        if (sum == 0xDEADBEEF) {
            vga.putChar('.');
        }
    }
}
