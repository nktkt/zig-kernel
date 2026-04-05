// Kernel Threads — カーネル空間で動作するスレッド管理
//
// ユーザー空間プロセスとは異なり、カーネル空間で直接実行される
// 軽量スレッド。割り込みハンドラのボトムハーフ処理や、
// 定期的なメンテナンス処理に使用する。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");

// ---- 定数 ----

const MAX_KTHREADS: usize = 8;
const MAX_NAME_LEN: usize = 16;
const STACK_SIZE: usize = 4096;
const MAX_TLS_SLOTS: usize = 4;

// ---- スレッド状態 ----

pub const ThreadState = enum(u8) {
    free, // 未使用スロット
    created, // 作成済み (未開始)
    running, // 実行中
    sleeping, // スリープ中
    stopped, // 停止要求済み
    dead, // 終了済み
};

// ---- 優先度 ----

pub const ThreadPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
};

// ---- エントリ関数の型 ----

pub const ThreadEntryFn = *const fn () void;

// ---- KThread 構造体 ----

pub const KThread = struct {
    tid: u32, // スレッド ID
    state: ThreadState,
    entry_fn: ?ThreadEntryFn,
    priority: ThreadPriority,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    stack_base: u32, // スタックの底 (PMM で割り当て)
    stack_ptr: u32, // 現在のスタックポインタ
    sleep_until: u64, // スリープ終了 tick
    stop_requested: bool, // 停止要求フラグ
    tls: [MAX_TLS_SLOTS]u32, // スレッドローカルストレージ
    // 統計
    create_tick: u64,
    total_run_ticks: u64,
    last_run_tick: u64,
    run_count: u64,
};

fn initKThread() KThread {
    return .{
        .tid = 0,
        .state = .free,
        .entry_fn = null,
        .priority = .normal,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .stack_base = 0,
        .stack_ptr = 0,
        .sleep_until = 0,
        .stop_requested = false,
        .tls = [_]u32{0} ** MAX_TLS_SLOTS,
        .create_tick = 0,
        .total_run_ticks = 0,
        .last_run_tick = 0,
        .run_count = 0,
    };
}

// ---- グローバル状態 ----

var threads: [MAX_KTHREADS]KThread = initAllThreads();
var next_tid: u32 = 1;
var current_thread: ?usize = null; // 現在実行中のスレッドインデックス
var total_created: u64 = 0;
var total_finished: u64 = 0;

fn initAllThreads() [MAX_KTHREADS]KThread {
    var arr: [MAX_KTHREADS]KThread = undefined;
    for (&arr) |*t| {
        t.* = initKThread();
    }
    return arr;
}

// ---- ヘルパー ----

fn copyName(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

fn findByTid(tid: u32) ?usize {
    for (&threads, 0..) |*t, i| {
        if (t.state != .free and t.tid == tid) return i;
    }
    return null;
}

fn findFreeSlot() ?usize {
    for (&threads, 0..) |*t, i| {
        if (t.state == .free) return i;
    }
    return null;
}

// ---- 公開 API ----

/// カーネルスレッドを作成
/// 戻り値: スレッド ID (失敗時 null)
pub fn create(name: []const u8, entry_fn: ThreadEntryFn, priority: ThreadPriority) ?u32 {
    const slot = findFreeSlot() orelse {
        serial.write("[kthread] no free slots\n");
        return null;
    };

    // スタック割り当て
    const stack = pmm.alloc() orelse {
        serial.write("[kthread] stack alloc failed\n");
        return null;
    };

    const tid = next_tid;
    next_tid += 1;

    threads[slot] = .{
        .tid = tid,
        .state = .created,
        .entry_fn = entry_fn,
        .priority = priority,
        .name = undefined,
        .name_len = 0,
        .stack_base = @truncate(stack),
        .stack_ptr = @truncate(stack + STACK_SIZE),
        .sleep_until = 0,
        .stop_requested = false,
        .tls = [_]u32{0} ** MAX_TLS_SLOTS,
        .create_tick = pit.getTicks(),
        .total_run_ticks = 0,
        .last_run_tick = 0,
        .run_count = 0,
    };
    threads[slot].name_len = copyName(&threads[slot].name, name);

    total_created += 1;

    serial.write("[kthread] created tid=");
    serial.writeHex(tid);
    serial.write(" name=");
    serial.write(name);
    serial.write("\n");

    return tid;
}

/// スレッドの実行を開始
pub fn start(tid: u32) bool {
    const idx = findByTid(tid) orelse return false;
    if (threads[idx].state != .created) return false;

    threads[idx].state = .running;
    threads[idx].last_run_tick = pit.getTicks();

    serial.write("[kthread] started tid=");
    serial.writeHex(tid);
    serial.write("\n");

    return true;
}

/// スレッドに停止を要求
pub fn stop(tid: u32) bool {
    const idx = findByTid(tid) orelse return false;
    if (threads[idx].state == .free or threads[idx].state == .dead) return false;

    threads[idx].stop_requested = true;
    threads[idx].state = .stopped;

    serial.write("[kthread] stop requested tid=");
    serial.writeHex(tid);
    serial.write("\n");

    return true;
}

/// スレッドの終了を待つ (ポーリング)
/// 注意: 実際のブロッキングは行わない、状態チェックのみ
pub fn join(tid: u32) bool {
    const idx = findByTid(tid) orelse return false;
    return threads[idx].state == .dead;
}

/// スレッドをスリープ (ms 指定)
pub fn sleep(ms: u32) void {
    if (current_thread) |idx| {
        threads[idx].state = .sleeping;
        threads[idx].sleep_until = pit.getTicks() + @as(u64, ms);
    }
}

/// 自発的な CPU 譲渡
pub fn yield() void {
    // スケジューラに制御を戻す
    // 実際にはタスクスイッチが必要だが、ここではフラグのみ設定
    if (current_thread) |idx| {
        threads[idx].run_count += 1;
    }
}

/// 現在のスレッドが停止要求されているかチェック
pub fn shouldStop() bool {
    if (current_thread) |idx| {
        return threads[idx].stop_requested;
    }
    return false;
}

/// スレッドを実行 (スケジューラから呼ばれる)
pub fn runPending() void {
    const now = pit.getTicks();

    // スリープ中のスレッドを起こす
    for (&threads) |*t| {
        if (t.state == .sleeping and now >= t.sleep_until) {
            t.state = .running;
        }
    }

    // 優先度順にスレッドを実行
    var prio: u8 = 2; // high から開始
    while (true) {
        for (&threads, 0..) |*t, i| {
            if (t.state == .running and @intFromEnum(t.priority) == prio) {
                current_thread = i;
                t.last_run_tick = now;
                t.run_count += 1;

                // エントリ関数を実行
                if (t.entry_fn) |entry| {
                    entry();
                }

                // 停止要求されていたら dead に遷移
                if (t.stop_requested) {
                    t.state = .dead;
                    total_finished += 1;
                    current_thread = null;

                    serial.write("[kthread] finished tid=");
                    serial.writeHex(t.tid);
                    serial.write("\n");
                }
            }
        }
        if (prio == 0) break;
        prio -= 1;
    }

    current_thread = null;
}

/// 完了したスレッドのリソースを回収
pub fn reapDead() void {
    for (&threads) |*t| {
        if (t.state == .dead) {
            // スタックを解放
            if (t.stack_base != 0) {
                pmm.free(t.stack_base);
            }
            t.* = initKThread();
        }
    }
}

// ---- TLS ----

/// スレッドローカル値を設定
pub fn setTls(slot: usize, value: u32) bool {
    if (slot >= MAX_TLS_SLOTS) return false;
    if (current_thread) |idx| {
        threads[idx].tls[slot] = value;
        return true;
    }
    return false;
}

/// スレッドローカル値を取得
pub fn getTls(slot: usize) u32 {
    if (slot >= MAX_TLS_SLOTS) return 0;
    if (current_thread) |idx| {
        return threads[idx].tls[slot];
    }
    return 0;
}

/// TID でスレッドローカル値を設定
pub fn setTlsForThread(tid: u32, slot: usize, value: u32) bool {
    if (slot >= MAX_TLS_SLOTS) return false;
    const idx = findByTid(tid) orelse return false;
    threads[idx].tls[slot] = value;
    return true;
}

/// TID でスレッドローカル値を取得
pub fn getTlsForThread(tid: u32, slot: usize) ?u32 {
    if (slot >= MAX_TLS_SLOTS) return null;
    const idx = findByTid(tid) orelse return null;
    return threads[idx].tls[slot];
}

// ---- 情報 ----

/// スレッドの状態を取得
pub fn getState(tid: u32) ?ThreadState {
    const idx = findByTid(tid) orelse return null;
    return threads[idx].state;
}

/// 現在実行中のスレッド TID
pub fn currentTid() ?u32 {
    if (current_thread) |idx| {
        return threads[idx].tid;
    }
    return null;
}

/// アクティブなスレッド数
pub fn activeThreadCount() usize {
    var count: usize = 0;
    for (&threads) |*t| {
        if (t.state != .free and t.state != .dead) count += 1;
    }
    return count;
}

// ---- 表示 ----

/// 全カーネルスレッドを表示
pub fn printThreads() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Kernel Threads ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  TID   State     Prio    Name             Runs\n");
    vga.write("  ----  --------  ------  ---------------  ----\n");

    var count: usize = 0;
    for (&threads) |*t| {
        if (t.state == .free) continue;

        vga.write("  ");
        fmt.printDecPadded(t.tid, 4);
        vga.write("  ");
        printState(t.state);
        vga.write("  ");
        printPriority(t.priority);
        vga.write("  ");
        vga.write(t.name[0..t.name_len]);
        // パディング
        if (t.name_len < 15) {
            var pad: usize = 15 - @as(usize, t.name_len);
            while (pad > 0) : (pad -= 1) vga.putChar(' ');
        }
        vga.write("  ");
        fmt.printDec(@truncate(t.run_count));
        vga.putChar('\n');
        count += 1;
    }

    if (count == 0) {
        vga.write("  No kernel threads.\n");
    }

    vga.write("\n  Total created: ");
    fmt.printDec(@truncate(total_created));
    vga.write("  Finished: ");
    fmt.printDec(@truncate(total_finished));
    vga.write("  Active: ");
    fmt.printDec(activeThreadCount());
    vga.putChar('\n');
}

fn printState(s: ThreadState) void {
    switch (s) {
        .free => vga.write("free    "),
        .created => vga.write("created "),
        .running => vga.write("running "),
        .sleeping => vga.write("sleeping"),
        .stopped => vga.write("stopped "),
        .dead => vga.write("dead    "),
    }
}

fn printPriority(p: ThreadPriority) void {
    switch (p) {
        .low => vga.write("low   "),
        .normal => vga.write("normal"),
        .high => vga.write("high  "),
    }
}
