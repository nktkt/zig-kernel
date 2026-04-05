// Counting Semaphore — カウンティングセマフォの実装
//
// プロセス間/スレッド間の同期プリミティブ。
// 指定された初期カウントを持ち、wait (P操作) でデクリメント、
// signal (V操作) でインクリメントする。
// カウントが 0 の場合、wait はウェイターキューに追加される。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- 定数 ----

const MAX_SEMAPHORES: usize = 16;
const MAX_WAITERS: usize = 8;
const MAX_NAME_LEN: usize = 16;

// ---- セマフォ構造体 ----

const Semaphore = struct {
    count: u32, // 現在のカウント
    max_count: u32, // 最大カウント
    wait_queue: [MAX_WAITERS]u32, // 待機中の PID/TID (0=空)
    waiter_count: u8,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    active: bool,
    // 統計
    wait_count: u64, // wait 呼び出し回数
    signal_count: u64, // signal 呼び出し回数
    contention_count: u64, // ブロックが発生した回数
    create_tick: u64,
};

fn initSemaphore() Semaphore {
    return .{
        .count = 0,
        .max_count = 0,
        .wait_queue = [_]u32{0} ** MAX_WAITERS,
        .waiter_count = 0,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .active = false,
        .wait_count = 0,
        .signal_count = 0,
        .contention_count = 0,
        .create_tick = 0,
    };
}

// ---- グローバル状態 ----

var semaphores: [MAX_SEMAPHORES]Semaphore = initAllSemaphores();
var total_created: u64 = 0;
var total_destroyed: u64 = 0;

fn initAllSemaphores() [MAX_SEMAPHORES]Semaphore {
    var arr: [MAX_SEMAPHORES]Semaphore = undefined;
    for (&arr) |*s| {
        s.* = initSemaphore();
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

fn nameMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn addWaiter(sem: *Semaphore, id: u32) bool {
    if (sem.waiter_count >= MAX_WAITERS) return false;
    sem.wait_queue[sem.waiter_count] = id;
    sem.waiter_count += 1;
    return true;
}

fn removeFirstWaiter(sem: *Semaphore) ?u32 {
    if (sem.waiter_count == 0) return null;
    const id = sem.wait_queue[0];
    // シフト
    var i: usize = 0;
    while (i < sem.waiter_count - 1) : (i += 1) {
        sem.wait_queue[i] = sem.wait_queue[i + 1];
    }
    sem.waiter_count -= 1;
    return id;
}

// ---- 公開 API ----

/// セマフォを作成
pub fn create(initial: u32, max: u32) ?u8 {
    return createNamed("sem", initial, max);
}

/// 名前付きセマフォを作成
pub fn createNamed(name: []const u8, initial: u32, max: u32) ?u8 {
    if (initial > max) return null;

    for (&semaphores, 0..) |*s, i| {
        if (!s.active) {
            s.* = initSemaphore();
            s.count = initial;
            s.max_count = max;
            s.name_len = copyName(&s.name, name);
            s.active = true;
            s.create_tick = pit.getTicks();
            total_created += 1;

            serial.write("[sem] created id=");
            serial.writeHex(i);
            serial.write(" name=");
            serial.write(name);
            serial.write(" init=");
            serial.writeHex(initial);
            serial.write("\n");

            return @truncate(i);
        }
    }
    return null;
}

/// セマフォを破棄
pub fn destroy(id: u8) void {
    if (id >= MAX_SEMAPHORES) return;
    if (!semaphores[id].active) return;

    // ウェイターがいる場合は警告
    if (semaphores[id].waiter_count > 0) {
        serial.write("[sem] warning: destroying sem with ");
        serial.writeHex(semaphores[id].waiter_count);
        serial.write(" waiters\n");
    }

    semaphores[id].active = false;
    total_destroyed += 1;
}

/// wait (P操作): カウントをデクリメント
/// カウントが 0 の場合、呼び出し元 ID をウェイターキューに追加
/// 戻り値: true = 即座に取得, false = ブロック
pub fn wait(id: u8) bool {
    if (id >= MAX_SEMAPHORES) return false;
    const sem = &semaphores[id];
    if (!sem.active) return false;

    sem.wait_count += 1;

    if (sem.count > 0) {
        sem.count -= 1;
        return true;
    }

    // ブロック: ウェイターキューに追加
    sem.contention_count += 1;
    _ = addWaiter(sem, 0); // PID 0 (カーネルスレッド) をプレースホルダーとして使用
    return false;
}

/// tryWait: ノンブロッキング版
pub fn tryWait(id: u8) bool {
    if (id >= MAX_SEMAPHORES) return false;
    const sem = &semaphores[id];
    if (!sem.active) return false;

    if (sem.count > 0) {
        sem.count -= 1;
        sem.wait_count += 1;
        return true;
    }
    return false;
}

/// signal (V操作): カウントをインクリメント、ウェイターがいれば起こす
pub fn signal(id: u8) void {
    if (id >= MAX_SEMAPHORES) return;
    const sem = &semaphores[id];
    if (!sem.active) return;

    sem.signal_count += 1;

    if (sem.waiter_count > 0) {
        // ウェイターを1つ起こす
        const waiter = removeFirstWaiter(sem);
        if (waiter) |_| {
            // 実際のウェイクアップ処理 (task.wake 等) はここで行う
            serial.write("[sem] woke waiter on sem ");
            serial.writeHex(id);
            serial.write("\n");
        }
    } else {
        if (sem.count < sem.max_count) {
            sem.count += 1;
        }
    }
}

/// タイムアウト付き wait
/// 戻り値: true = 取得成功, false = タイムアウト
pub fn waitTimeout(id: u8, timeout_ms: u32) bool {
    if (id >= MAX_SEMAPHORES) return false;
    const sem = &semaphores[id];
    if (!sem.active) return false;

    sem.wait_count += 1;

    if (sem.count > 0) {
        sem.count -= 1;
        return true;
    }

    // タイムアウト待機 (ポーリングベース)
    const deadline = pit.getTicks() + @as(u64, timeout_ms);
    sem.contention_count += 1;

    while (pit.getTicks() < deadline) {
        if (sem.count > 0) {
            sem.count -= 1;
            return true;
        }
        // ビジーウェイト (実際のカーネルでは yield するべき)
        asm volatile ("pause");
    }

    return false; // タイムアウト
}

/// 現在のカウント値を取得
pub fn getValue(id: u8) ?u32 {
    if (id >= MAX_SEMAPHORES) return null;
    if (!semaphores[id].active) return null;
    return semaphores[id].count;
}

/// ウェイター数を取得
pub fn getWaiterCount(id: u8) ?u8 {
    if (id >= MAX_SEMAPHORES) return null;
    if (!semaphores[id].active) return null;
    return semaphores[id].waiter_count;
}

/// 名前でセマフォを検索
pub fn findByName(name: []const u8) ?u8 {
    for (&semaphores, 0..) |*s, i| {
        if (s.active and nameMatch(s.name[0..s.name_len], name)) {
            return @truncate(i);
        }
    }
    return null;
}

// ---- 表示 ----

/// 全セマフォを表示
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Semaphores ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  ID  Name             Count  Max    Waiters  Contention\n");
    vga.write("  --  ---------------  -----  -----  -------  ----------\n");

    var count: usize = 0;
    for (&semaphores, 0..) |*s, i| {
        if (!s.active) continue;

        vga.write("  ");
        fmt.printDecPadded(i, 2);
        vga.write("  ");
        vga.write(s.name[0..s.name_len]);
        // パディング
        if (s.name_len < 15) {
            var pad: usize = 15 - @as(usize, s.name_len);
            while (pad > 0) : (pad -= 1) vga.putChar(' ');
        }
        vga.write("  ");
        fmt.printDecPadded(s.count, 5);
        vga.write("  ");
        fmt.printDecPadded(s.max_count, 5);
        vga.write("  ");
        fmt.printDecPadded(s.waiter_count, 7);
        vga.write("  ");
        fmt.printDec(@truncate(s.contention_count));
        vga.putChar('\n');
        count += 1;
    }

    if (count == 0) {
        vga.write("  No active semaphores.\n");
    }

    vga.write("\n  Total created: ");
    fmt.printDec(@truncate(total_created));
    vga.write("  Destroyed: ");
    fmt.printDec(@truncate(total_destroyed));
    vga.putChar('\n');
}

/// 特定セマフォの詳細を表示
pub fn printDetail(id: u8) void {
    if (id >= MAX_SEMAPHORES) {
        vga.write("  Invalid semaphore ID.\n");
        return;
    }
    const sem = &semaphores[id];
    if (!sem.active) {
        vga.write("  Semaphore not active.\n");
        return;
    }

    vga.setColor(.yellow, .black);
    vga.write("=== Semaphore ");
    fmt.printDec(id);
    vga.write(" ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Name:       ");
    vga.write(sem.name[0..sem.name_len]);
    vga.write("\n  Count:      ");
    fmt.printDec(sem.count);
    vga.write(" / ");
    fmt.printDec(sem.max_count);
    vga.write("\n  Waiters:    ");
    fmt.printDec(sem.waiter_count);
    vga.write("\n  Waits:      ");
    fmt.printDec(@truncate(sem.wait_count));
    vga.write("\n  Signals:    ");
    fmt.printDec(@truncate(sem.signal_count));
    vga.write("\n  Contention: ");
    fmt.printDec(@truncate(sem.contention_count));
    vga.putChar('\n');

    if (sem.waiter_count > 0) {
        vga.write("  Wait queue: ");
        for (0..sem.waiter_count) |i| {
            if (i > 0) vga.write(", ");
            fmt.printDec(sem.wait_queue[i]);
        }
        vga.putChar('\n');
    }
}
