// Work Queue — カーネルの遅延実行キュー
//
// 割り込みコンテキストから直接実行できない処理を後回しにして、
// アイドルループやスケジューラから安全に実行する仕組み。
// 優先度付き、遅延実行、周期実行をサポート。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- 定数 ----

const MAX_WORK_ITEMS: usize = 32;
const MAX_NAME_LEN: usize = 16;

// ---- 優先度 ----

pub const Priority = enum(u8) {
    high = 0,
    normal = 1,
    low = 2,
};

// ---- ワークアイテムの状態 ----

pub const WorkState = enum(u8) {
    free, // 未使用スロット
    pending, // 実行待ち
    running, // 実行中
    completed, // 実行完了
    cancelled, // キャンセル済み
};

// ---- ワークアイテム ----

pub const WorkFn = *const fn (?*anyopaque) void;

pub const WorkItem = struct {
    func: ?WorkFn,
    data: ?*anyopaque,
    priority: Priority,
    state: WorkState,
    deadline_tick: u64, // この tick 以降に実行 (0=即時)
    interval_ms: u32, // 周期実行間隔 (0=一回のみ)
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    id: u16, // ユニーク ID
    enqueue_tick: u64, // エンキュー時刻
    start_tick: u64, // 実行開始時刻
    end_tick: u64, // 実行完了時刻
};

fn initWorkItem() WorkItem {
    return .{
        .func = null,
        .data = null,
        .priority = .normal,
        .state = .free,
        .deadline_tick = 0,
        .interval_ms = 0,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .id = 0,
        .enqueue_tick = 0,
        .start_tick = 0,
        .end_tick = 0,
    };
}

// ---- グローバル状態 ----

var work_items: [MAX_WORK_ITEMS]WorkItem = initAllItems();
var next_id: u16 = 1;

// 統計
var items_processed: u64 = 0;
var items_cancelled: u64 = 0;
var total_latency_ticks: u64 = 0; // 合計レイテンシ (平均算出用)
var max_latency_ticks: u64 = 0;
var current_pending: usize = 0;

fn initAllItems() [MAX_WORK_ITEMS]WorkItem {
    var items: [MAX_WORK_ITEMS]WorkItem = undefined;
    for (&items) |*item| {
        item.* = initWorkItem();
    }
    return items;
}

// ---- ヘルパー ----

fn findFreeSlot() ?usize {
    for (&work_items, 0..) |*item, i| {
        if (item.state == .free or item.state == .completed or item.state == .cancelled) {
            return i;
        }
    }
    return null;
}

fn copyName(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

/// 優先度の数値 (小さい方が高優先度)
fn priorityValue(p: Priority) u8 {
    return @intFromEnum(p);
}

// ---- 公開 API ----

/// ワークアイテムをスケジュール (即時実行)
pub fn schedule(func: WorkFn, data: ?*anyopaque) ?u16 {
    return scheduleInternal(func, data, .normal, 0, 0, "work");
}

/// ワークアイテムを名前付きでスケジュール
pub fn scheduleNamed(func: WorkFn, data: ?*anyopaque, name: []const u8) ?u16 {
    return scheduleInternal(func, data, .normal, 0, 0, name);
}

/// 遅延実行ワークアイテムをスケジュール
pub fn scheduleDelayed(func: WorkFn, data: ?*anyopaque, delay_ms: u32) ?u16 {
    const deadline = pit.getTicks() + @as(u64, delay_ms);
    return scheduleInternal(func, data, .normal, deadline, 0, "delayed");
}

/// 周期実行ワークアイテムをスケジュール
pub fn scheduleRepeating(func: WorkFn, data: ?*anyopaque, interval_ms: u32) ?u16 {
    return scheduleInternal(func, data, .normal, 0, interval_ms, "repeating");
}

/// 優先度付きでスケジュール
pub fn schedulePriority(func: WorkFn, data: ?*anyopaque, priority: Priority) ?u16 {
    return scheduleInternal(func, data, priority, 0, 0, "priority");
}

fn scheduleInternal(
    func: WorkFn,
    data: ?*anyopaque,
    priority: Priority,
    deadline: u64,
    interval_ms: u32,
    name: []const u8,
) ?u16 {
    const slot = findFreeSlot() orelse {
        serial.write("[workqueue] full, cannot schedule\n");
        return null;
    };

    const id = next_id;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;

    work_items[slot] = .{
        .func = func,
        .data = data,
        .priority = priority,
        .state = .pending,
        .deadline_tick = deadline,
        .interval_ms = interval_ms,
        .name = undefined,
        .name_len = 0,
        .id = id,
        .enqueue_tick = pit.getTicks(),
        .start_tick = 0,
        .end_tick = 0,
    };
    work_items[slot].name_len = copyName(&work_items[slot].name, name);
    current_pending += 1;

    return id;
}

/// ワークアイテムをキャンセル
pub fn cancelWork(id: u16) bool {
    for (&work_items) |*item| {
        if (item.id == id and item.state == .pending) {
            item.state = .cancelled;
            current_pending -|= 1;
            items_cancelled += 1;
            return true;
        }
    }
    return false;
}

/// ペンディング中のワークアイテムを実行 (アイドルループから呼ばれる)
pub fn processWork() void {
    const now = pit.getTicks();

    // 優先度順に処理 (high → normal → low)
    var prio: u8 = 0;
    while (prio < 3) : (prio += 1) {
        for (&work_items) |*item| {
            if (item.state != .pending) continue;
            if (priorityValue(item.priority) != prio) continue;

            // デッドラインチェック
            if (item.deadline_tick > 0 and now < item.deadline_tick) continue;

            // 実行
            item.state = .running;
            item.start_tick = now;
            current_pending -|= 1;

            if (item.func) |func| {
                func(item.data);
            }

            item.end_tick = pit.getTicks();
            items_processed += 1;

            // レイテンシ計算
            const latency = item.start_tick -| item.enqueue_tick;
            total_latency_ticks += latency;
            if (latency > max_latency_ticks) {
                max_latency_ticks = latency;
            }

            // 周期実行の場合は再スケジュール
            if (item.interval_ms > 0) {
                item.state = .pending;
                item.deadline_tick = item.end_tick + @as(u64, item.interval_ms);
                item.enqueue_tick = item.end_tick;
                current_pending += 1;
            } else {
                item.state = .completed;
            }
        }
    }
}

/// ペンディング中のアイテム数を返す
pub fn pendingCount() usize {
    return current_pending;
}

/// 処理済みアイテム数
pub fn processedCount() u64 {
    return items_processed;
}

/// 平均レイテンシ (ticks)
pub fn averageLatency() u64 {
    if (items_processed == 0) return 0;
    return total_latency_ticks / items_processed;
}

/// 最大レイテンシ (ticks)
pub fn maxLatency() u64 {
    return max_latency_ticks;
}

/// ID からワークアイテムの状態を返す
pub fn getState(id: u16) ?WorkState {
    for (&work_items) |*item| {
        if (item.id == id) return item.state;
    }
    return null;
}

// ---- 表示 ----

/// ワークキューの状態を表示
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Work Queue Status ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Pending:    ");
    fmt.printDec(current_pending);
    vga.write("\n  Processed:  ");
    printU64(items_processed);
    vga.write("  Cancelled:  ");
    printU64(items_cancelled);
    vga.write("  Avg latency: ");
    printU64(averageLatency());
    vga.write(" ticks\n  Max latency: ");
    printU64(max_latency_ticks);
    vga.write(" ticks\n");

    // アクティブなアイテムを表示
    var has_items = false;
    for (&work_items) |*item| {
        if (item.state == .pending or item.state == .running) {
            if (!has_items) {
                vga.write("\n  ID     Prio    State     Name\n");
                vga.write("  -----  ------  --------  ----\n");
                has_items = true;
            }
            vga.write("  ");
            fmt.printDecPadded(item.id, 5);
            vga.write("  ");
            printPriority(item.priority);
            vga.write("  ");
            printState(item.state);
            vga.write("  ");
            vga.write(item.name[0..item.name_len]);
            if (item.interval_ms > 0) {
                vga.write(" (every ");
                fmt.printDec(item.interval_ms);
                vga.write("ms)");
            }
            vga.putChar('\n');
        }
    }

    if (!has_items) {
        vga.write("  No active work items.\n");
    }
}

fn printPriority(p: Priority) void {
    switch (p) {
        .high => vga.write("high  "),
        .normal => vga.write("normal"),
        .low => vga.write("low   "),
    }
}

fn printState(s: WorkState) void {
    switch (s) {
        .free => vga.write("free    "),
        .pending => vga.write("pending "),
        .running => vga.write("running "),
        .completed => vga.write("done    "),
        .cancelled => vga.write("cancel  "),
    }
}

fn printU64(val: u64) void {
    fmt.printDec(@truncate(val));
}

/// ワークキューをリセット (テスト用)
pub fn reset() void {
    for (&work_items) |*item| {
        item.* = initWorkItem();
    }
    next_id = 1;
    items_processed = 0;
    items_cancelled = 0;
    total_latency_ticks = 0;
    max_latency_ticks = 0;
    current_pending = 0;
}

/// 全完了/キャンセル済みアイテムをクリア
pub fn cleanup() void {
    for (&work_items) |*item| {
        if (item.state == .completed or item.state == .cancelled) {
            item.* = initWorkItem();
        }
    }
}
