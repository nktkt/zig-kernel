// Multi-Level Feedback Queue Scheduler — 多段フィードバックキュースケジューラ
// 4 段階の優先度キュー (0=最高)
// 新規タスクはレベル 0 から開始
// タイムクォンタム: レベル 0=1, 1=2, 2=4, 3=8 ティック
// クォンタム使い切り → 降格, 長時間待機 → 昇格 (飢餓防止)

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const NUM_LEVELS = 4;
pub const MAX_TASKS = 32;
pub const QUEUE_SIZE = MAX_TASKS;

/// レベルごとのタイムクォンタム (ティック数)
pub const QUANTUM = [NUM_LEVELS]u32{ 1, 2, 4, 8 };

/// 飢餓防止: この tick 数待機すると昇格
pub const STARVATION_THRESHOLD: u64 = 200;

/// 飢餓チェック間隔 (ティック)
pub const AGING_CHECK_INTERVAL: u64 = 50;

// ---- タスク情報 ----

pub const MLTask = struct {
    pid: u32 = 0,
    level: u8 = 0, // 現在のキューレベル (0-3)
    quantum_remaining: u32 = 0, // 残りクォンタム
    ticks_waiting: u64 = 0, // 待機ティック数
    total_ticks: u64 = 0, // 総 CPU 使用ティック
    active: bool = false,
    times_demoted: u32 = 0, // 降格回数
    times_promoted: u32 = 0, // 昇格回数
};

// ---- 循環キュー ----

pub const CircularQueue = struct {
    pids: [QUEUE_SIZE]u32 = @splat(0),
    head: usize = 0,
    tail: usize = 0,
    count_val: usize = 0,

    pub fn enqueue(self: *CircularQueue, pid: u32) bool {
        if (self.count_val >= QUEUE_SIZE) return false;
        self.pids[self.tail] = pid;
        self.tail = (self.tail + 1) % QUEUE_SIZE;
        self.count_val += 1;
        return true;
    }

    pub fn dequeue(self: *CircularQueue) ?u32 {
        if (self.count_val == 0) return null;
        const pid = self.pids[self.head];
        self.head = (self.head + 1) % QUEUE_SIZE;
        self.count_val -= 1;
        return pid;
    }

    pub fn count(self: *const CircularQueue) usize {
        return self.count_val;
    }

    pub fn isEmpty(self: *const CircularQueue) bool {
        return self.count_val == 0;
    }

    /// キューから特定の PID を削除
    pub fn removePid(self: *CircularQueue, pid: u32) bool {
        if (self.count_val == 0) return false;

        var found = false;
        var new_count: usize = 0;
        var temp_pids: [QUEUE_SIZE]u32 = @splat(0);

        var i: usize = 0;
        while (i < self.count_val) : (i += 1) {
            const idx = (self.head + i) % QUEUE_SIZE;
            if (self.pids[idx] == pid and !found) {
                found = true;
                continue;
            }
            temp_pids[new_count] = self.pids[idx];
            new_count += 1;
        }

        if (!found) return false;

        // キューを再構築
        self.head = 0;
        self.tail = new_count;
        self.count_val = new_count;
        for (0..new_count) |j| {
            self.pids[j] = temp_pids[j];
        }
        return true;
    }

    pub fn clear(self: *CircularQueue) void {
        self.head = 0;
        self.tail = 0;
        self.count_val = 0;
    }
};

// ---- レベル統計 ----

pub const LevelStats = struct {
    tasks_run: u64 = 0,
    total_ticks: u64 = 0,
    current_tasks: u32 = 0,
};

// ---- MLFQ スケジューラ ----

pub const MLFQScheduler = struct {
    queues: [NUM_LEVELS]CircularQueue = [_]CircularQueue{.{}} ** NUM_LEVELS,
    tasks: [MAX_TASKS]MLTask = [_]MLTask{.{}} ** MAX_TASKS,
    stats: [NUM_LEVELS]LevelStats = [_]LevelStats{.{}} ** NUM_LEVELS,
    task_count: usize = 0,
    current_tick: u64 = 0,
    last_aging_check: u64 = 0,
    total_scheduled: u64 = 0,

    // ---- タスク管理 ----

    /// タスクを検索 (PID → インデックス)
    fn findTask(self: *const MLFQScheduler, pid: u32) ?usize {
        for (0..MAX_TASKS) |i| {
            if (self.tasks[i].active and self.tasks[i].pid == pid) return i;
        }
        return null;
    }

    /// 空きスロットを確保
    fn allocSlot(self: *const MLFQScheduler) ?usize {
        for (0..MAX_TASKS) |i| {
            if (!self.tasks[i].active) return i;
        }
        return null;
    }

    /// タスクを追加 (レベル 0 から開始)
    pub fn addTask(self: *MLFQScheduler, pid: u32) bool {
        if (self.findTask(pid) != null) return false; // 既に存在
        const slot = self.allocSlot() orelse return false;

        self.tasks[slot] = .{
            .pid = pid,
            .level = 0,
            .quantum_remaining = QUANTUM[0],
            .ticks_waiting = 0,
            .total_ticks = 0,
            .active = true,
        };

        if (!self.queues[0].enqueue(pid)) return false;
        self.task_count += 1;
        self.stats[0].current_tasks += 1;
        return true;
    }

    /// タスクを削除
    pub fn removeTask(self: *MLFQScheduler, pid: u32) bool {
        const slot = self.findTask(pid) orelse return false;
        const level = self.tasks[slot].level;

        _ = self.queues[level].removePid(pid);
        self.tasks[slot].active = false;
        self.task_count -= 1;
        if (self.stats[level].current_tasks > 0) {
            self.stats[level].current_tasks -= 1;
        }
        return true;
    }

    /// 次に実行するタスクを取得 (最高優先度の非空キューから)
    pub fn getNext(self: *MLFQScheduler) ?u32 {
        // エイジングチェック
        self.current_tick += 1;
        if (self.current_tick - self.last_aging_check >= AGING_CHECK_INTERVAL) {
            self.checkStarvation();
            self.last_aging_check = self.current_tick;
        }

        // 最高優先度の非空キューから取り出す
        for (0..NUM_LEVELS) |level| {
            if (self.queues[level].dequeue()) |pid| {
                if (self.findTask(pid)) |slot| {
                    self.tasks[slot].quantum_remaining = QUANTUM[level];
                    self.tasks[slot].ticks_waiting = 0;
                    self.stats[level].tasks_run += 1;
                    self.total_scheduled += 1;
                }
                return pid;
            }
        }
        return null;
    }

    /// タスクがクォンタムを使い切った場合に呼ぶ
    pub fn tickTask(self: *MLFQScheduler, pid: u32) void {
        const slot = self.findTask(pid) orelse return;
        self.tasks[slot].total_ticks += 1;
        self.stats[self.tasks[slot].level].total_ticks += 1;

        if (self.tasks[slot].quantum_remaining > 0) {
            self.tasks[slot].quantum_remaining -= 1;
        }

        // クォンタム使い切り → 降格してキューに戻す
        if (self.tasks[slot].quantum_remaining == 0) {
            self.demote(pid);
            // キューに再投入
            const new_level = self.tasks[slot].level;
            _ = self.queues[new_level].enqueue(pid);
        }
    }

    /// タスクが自発的に CPU を放棄した場合 (I/O 待ちなど)
    pub fn yieldTask(self: *MLFQScheduler, pid: u32) void {
        const slot = self.findTask(pid) orelse return;
        const level = self.tasks[slot].level;
        // 同じレベルのキューに戻す (降格しない)
        _ = self.queues[level].enqueue(pid);
    }

    /// タスクを降格
    pub fn demote(self: *MLFQScheduler, pid: u32) void {
        const slot = self.findTask(pid) orelse return;
        const current_level = self.tasks[slot].level;

        if (current_level < NUM_LEVELS - 1) {
            if (self.stats[current_level].current_tasks > 0) {
                self.stats[current_level].current_tasks -= 1;
            }
            self.tasks[slot].level = current_level + 1;
            self.tasks[slot].quantum_remaining = QUANTUM[current_level + 1];
            self.tasks[slot].times_demoted += 1;
            self.stats[current_level + 1].current_tasks += 1;
        }
    }

    /// タスクを昇格
    pub fn promote(self: *MLFQScheduler, pid: u32) void {
        const slot = self.findTask(pid) orelse return;
        const current_level = self.tasks[slot].level;

        if (current_level > 0) {
            // 現在のキューから削除
            _ = self.queues[current_level].removePid(pid);
            if (self.stats[current_level].current_tasks > 0) {
                self.stats[current_level].current_tasks -= 1;
            }

            self.tasks[slot].level = current_level - 1;
            self.tasks[slot].quantum_remaining = QUANTUM[current_level - 1];
            self.tasks[slot].ticks_waiting = 0;
            self.tasks[slot].times_promoted += 1;
            self.stats[current_level - 1].current_tasks += 1;

            // 新しいキューに投入
            _ = self.queues[current_level - 1].enqueue(pid);
        }
    }

    /// 飢餓防止チェック: 長時間待機しているタスクを昇格
    fn checkStarvation(self: *MLFQScheduler) void {
        for (&self.tasks) |*t| {
            if (!t.active) continue;
            if (t.level == 0) continue; // 既に最高レベル

            t.ticks_waiting += AGING_CHECK_INTERVAL;
            if (t.ticks_waiting >= STARVATION_THRESHOLD) {
                self.promote(t.pid);
            }
        }
    }

    /// 全キューをブースト (全タスクをレベル 0 に)
    pub fn boostAll(self: *MLFQScheduler) void {
        // 全キューをクリア
        for (0..NUM_LEVELS) |level| {
            self.queues[level].clear();
            self.stats[level].current_tasks = 0;
        }

        // 全タスクをレベル 0 に
        for (&self.tasks) |*t| {
            if (!t.active) continue;
            t.level = 0;
            t.quantum_remaining = QUANTUM[0];
            t.ticks_waiting = 0;
            _ = self.queues[0].enqueue(t.pid);
            self.stats[0].current_tasks += 1;
        }
    }

    // ---- 表示 ----

    pub fn printQueues(self: *const MLFQScheduler) void {
        vga.setColor(.yellow, .black);
        vga.write("MLFQ Scheduler (");
        fmt.printDec(self.task_count);
        vga.write(" tasks, ");
        fmt.printDec(@as(usize, @truncate(self.total_scheduled)));
        vga.write(" scheduled):\n");
        vga.setColor(.light_grey, .black);

        for (0..NUM_LEVELS) |level| {
            vga.write("  Level ");
            fmt.printDec(level);
            vga.write(" (quantum=");
            fmt.printDec(QUANTUM[level]);
            vga.write("): ");

            // キュー内のタスク数
            fmt.printDec(self.queues[level].count());
            vga.write(" tasks");

            // 統計
            vga.write(" | ran=");
            fmt.printDec(@as(usize, @truncate(self.stats[level].tasks_run)));
            vga.write(" ticks=");
            fmt.printDec(@as(usize, @truncate(self.stats[level].total_ticks)));
            vga.putChar('\n');
        }

        // 個別タスク情報
        vga.write("  Tasks:\n");
        for (&self.tasks) |*t| {
            if (!t.active) continue;
            vga.write("    PID ");
            fmt.printDec(t.pid);
            vga.write(" lv=");
            fmt.printDec(t.level);
            vga.write(" q=");
            fmt.printDec(t.quantum_remaining);
            vga.write(" cpu=");
            fmt.printDec(@as(usize, @truncate(t.total_ticks)));
            vga.write(" wait=");
            fmt.printDec(@as(usize, @truncate(t.ticks_waiting)));
            if (t.times_demoted > 0) {
                vga.write(" dem=");
                fmt.printDec(t.times_demoted);
            }
            if (t.times_promoted > 0) {
                vga.write(" prom=");
                fmt.printDec(t.times_promoted);
            }
            vga.putChar('\n');
        }
    }

    pub fn printSummary(self: *const MLFQScheduler) void {
        vga.write("MLFQ: ");
        fmt.printDec(self.task_count);
        vga.write(" tasks [");
        for (0..NUM_LEVELS) |level| {
            if (level > 0) vga.putChar('|');
            fmt.printDec(self.queues[level].count());
        }
        vga.write("]\n");
    }
};

// ---- グローバルインスタンス ----

var global_scheduler: MLFQScheduler = .{};

pub fn getScheduler() *MLFQScheduler {
    return &global_scheduler;
}

// ---- デモ ----

pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== MLFQ Scheduler Demo ===\n");
    vga.setColor(.light_grey, .black);

    var sched: MLFQScheduler = .{};

    // タスク追加
    _ = sched.addTask(1);
    _ = sched.addTask(2);
    _ = sched.addTask(3);
    _ = sched.addTask(4);

    vga.write("Initial state:\n");
    sched.printQueues();

    // スケジューリングシミュレーション
    vga.write("\nScheduling simulation:\n");
    var round: u32 = 0;
    while (round < 12) : (round += 1) {
        if (sched.getNext()) |pid| {
            vga.write("  tick ");
            fmt.printDec(round);
            vga.write(": run PID ");
            fmt.printDec(pid);

            // CPU を使用
            sched.tickTask(pid);

            if (sched.findTask(pid)) |slot| {
                vga.write(" (lv=");
                fmt.printDec(sched.tasks[slot].level);
                vga.write(")\n");
            } else {
                vga.putChar('\n');
            }
        } else {
            vga.write("  tick ");
            fmt.printDec(round);
            vga.write(": idle\n");
        }
    }

    vga.write("\nAfter simulation:\n");
    sched.printQueues();

    // ブースト
    vga.write("\nAfter boost:\n");
    sched.boostAll();
    sched.printSummary();
}

pub fn printInfo() void {
    global_scheduler.printQueues();
}
