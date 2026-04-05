// Enhanced round-robin scheduler with priority support and statistics
//
// Priority levels: idle(0), low(1), normal(2), high(3), realtime(4)
// Higher priority = more time slices before preemption.
// Starvation prevention via aging.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_TASKS = 16;
pub const NUM_PRIORITIES = 5;

pub const Priority = enum(u8) {
    idle = 0,
    low = 1,
    normal = 2,
    high = 3,
    realtime = 4,
};

// Time slices per priority level (in ticks)
// idle=1, low=2, normal=4, high=8, realtime=16
const SLICE_TABLE = [NUM_PRIORITIES]u32{ 1, 2, 4, 8, 16 };

// Aging threshold: if a task hasn't run for this many ticks, boost priority
const AGING_THRESHOLD: u64 = 500; // 500ms at 1kHz
const AGING_INTERVAL: u64 = 100; // check every 100ms

// ---- Per-task data ----

const TaskInfo = struct {
    active: bool,
    pid: u32,
    priority: Priority,
    base_priority: Priority, // original priority before aging boost
    time_slice_remaining: u32,
    cpu_ticks: u64, // total CPU time consumed
    last_scheduled_tick: u64,
    starve_counter: u64, // ticks since last run
};

// ---- Ready queues (one per priority level) ----

const QUEUE_SIZE = MAX_TASKS;

const ReadyQueue = struct {
    pids: [QUEUE_SIZE]u32,
    head: usize,
    tail: usize,
    count: usize,

    fn init_queue() ReadyQueue {
        return .{
            .pids = @splat(0),
            .head = 0,
            .tail = 0,
            .count = 0,
        };
    }

    fn enqueue(self: *ReadyQueue, pid: u32) bool {
        if (self.count >= QUEUE_SIZE) return false;
        self.pids[self.tail] = pid;
        self.tail = (self.tail + 1) % QUEUE_SIZE;
        self.count += 1;
        return true;
    }

    fn dequeue(self: *ReadyQueue) ?u32 {
        if (self.count == 0) return null;
        const pid = self.pids[self.head];
        self.head = (self.head + 1) % QUEUE_SIZE;
        self.count -= 1;
        return pid;
    }

    fn isEmpty(self: *const ReadyQueue) bool {
        return self.count == 0;
    }

    fn removeByPid(self: *ReadyQueue, pid: u32) bool {
        if (self.count == 0) return false;
        // Linear scan and compact
        var new_pids: [QUEUE_SIZE]u32 = @splat(0);
        var new_count: usize = 0;
        var idx = self.head;
        var remaining = self.count;
        var found = false;
        while (remaining > 0) : (remaining -= 1) {
            if (self.pids[idx] == pid and !found) {
                found = true;
            } else {
                new_pids[new_count] = self.pids[idx];
                new_count += 1;
            }
            idx = (idx + 1) % QUEUE_SIZE;
        }
        if (found) {
            self.pids = new_pids;
            self.head = 0;
            self.tail = new_count;
            self.count = new_count;
        }
        return found;
    }
};

// ---- Scheduler statistics ----

pub const SchedStats = struct {
    total_context_switches: u64,
    total_tasks: u32,
    active_tasks: u32,
    uptime_ticks: u64,
};

// ---- State ----

var tasks: [MAX_TASKS]TaskInfo = undefined;
var queues: [NUM_PRIORITIES]ReadyQueue = undefined;
var total_context_switches: u64 = 0;
var last_aging_tick: u64 = 0;
var sched_initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&tasks) |*t| {
        t.active = false;
        t.pid = 0;
        t.priority = .normal;
        t.base_priority = .normal;
        t.time_slice_remaining = 0;
        t.cpu_ticks = 0;
        t.last_scheduled_tick = 0;
        t.starve_counter = 0;
    }

    for (&queues) |*q| {
        q.* = ReadyQueue.init_queue();
    }

    total_context_switches = 0;
    last_aging_tick = pit.getTicks();
    sched_initialized = true;

    serial.write("[sched_rr] initialized with ");
    writeDecSerial(NUM_PRIORITIES);
    serial.write(" priority levels\n");
}

// ---- Task registration ----

/// Register a task with the scheduler. Default priority: normal.
pub fn addTask(pid: u32) bool {
    if (!sched_initialized) return false;
    const slot = findSlot(pid) orelse findFreeSlot() orelse return false;

    tasks[slot].active = true;
    tasks[slot].pid = pid;
    tasks[slot].priority = .normal;
    tasks[slot].base_priority = .normal;
    tasks[slot].time_slice_remaining = SLICE_TABLE[@intFromEnum(Priority.normal)];
    tasks[slot].cpu_ticks = 0;
    tasks[slot].last_scheduled_tick = pit.getTicks();
    tasks[slot].starve_counter = 0;

    return queues[@intFromEnum(Priority.normal)].enqueue(pid);
}

/// Remove a task from the scheduler.
pub fn removeTask(pid: u32) void {
    if (!sched_initialized) return;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            t.active = false;
            // Remove from its queue
            _ = queues[@intFromEnum(t.priority)].removeByPid(pid);
            return;
        }
    }
}

// ---- Priority management ----

/// Set the priority of a task.
pub fn setPriority(pid: u32, level: Priority) bool {
    if (!sched_initialized) return false;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            const old_prio = t.priority;
            t.priority = level;
            t.base_priority = level;
            t.time_slice_remaining = SLICE_TABLE[@intFromEnum(level)];

            // Move between queues if priority changed
            if (old_prio != level) {
                _ = queues[@intFromEnum(old_prio)].removeByPid(pid);
                _ = queues[@intFromEnum(level)].enqueue(pid);
            }
            return true;
        }
    }
    return false;
}

/// Get the priority of a task.
pub fn getPriority(pid: u32) ?u8 {
    if (!sched_initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return @intFromEnum(t.priority);
        }
    }
    return null;
}

/// Get the time slice for a priority level.
pub fn getTimeSlice(level: Priority) u32 {
    return SLICE_TABLE[@intFromEnum(level)];
}

// ---- Scheduling ----

/// Called on each timer tick for the currently running task.
/// Returns the PID of the next task to run, or null if no switch needed.
pub fn tick(current_pid: u32) ?u32 {
    if (!sched_initialized) return null;

    const now = pit.getTicks();

    // Update CPU time for current task
    for (&tasks) |*t| {
        if (t.active and t.pid == current_pid) {
            t.cpu_ticks += 1;
            t.last_scheduled_tick = now;
            t.starve_counter = 0;

            // Decrement time slice
            if (t.time_slice_remaining > 0) {
                t.time_slice_remaining -= 1;
            }

            // If time slice expired, preempt
            if (t.time_slice_remaining == 0) {
                // Reset slice and re-enqueue
                t.time_slice_remaining = SLICE_TABLE[@intFromEnum(t.priority)];
                _ = queues[@intFromEnum(t.priority)].enqueue(current_pid);

                // Pick next task
                const next = pickNext();
                if (next) |next_pid| {
                    if (next_pid != current_pid) {
                        total_context_switches += 1;
                    }
                    return next_pid;
                }
            }
            break;
        }
    }

    // Aging check
    if (now - last_aging_tick >= AGING_INTERVAL) {
        last_aging_tick = now;
        performAging(now);
    }

    return null;
}

/// Pick the highest-priority ready task.
fn pickNext() ?u32 {
    // Scan from highest priority to lowest
    var p: usize = NUM_PRIORITIES;
    while (p > 0) {
        p -= 1;
        if (queues[p].dequeue()) |pid| {
            // Update last_scheduled for this task
            for (&tasks) |*t| {
                if (t.active and t.pid == pid) {
                    t.last_scheduled_tick = pit.getTicks();
                    t.starve_counter = 0;
                    break;
                }
            }
            return pid;
        }
    }
    return null;
}

/// Re-enqueue a task (e.g. when it becomes ready again).
pub fn makeReady(pid: u32) void {
    if (!sched_initialized) return;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            _ = queues[@intFromEnum(t.priority)].enqueue(pid);
            return;
        }
    }
}

// ---- Starvation prevention (aging) ----

fn performAging(now: u64) void {
    for (&tasks) |*t| {
        if (!t.active) continue;
        // Increment starvation counter for tasks not recently scheduled
        if (now > t.last_scheduled_tick) {
            t.starve_counter = now - t.last_scheduled_tick;
        }

        // If starving and not already at realtime, boost priority
        if (t.starve_counter >= AGING_THRESHOLD) {
            const current: u8 = @intFromEnum(t.priority);
            if (current < @intFromEnum(Priority.realtime)) {
                const old_prio = t.priority;
                const new_prio: u8 = current + 1;
                t.priority = @enumFromInt(new_prio);

                // Move between queues
                _ = queues[@intFromEnum(old_prio)].removeByPid(t.pid);
                _ = queues[new_prio].enqueue(t.pid);

                // Reset starvation counter
                t.starve_counter = 0;
            }
        }
    }
}

/// Reset boosted priorities back to base (call periodically).
pub fn resetAging() void {
    if (!sched_initialized) return;
    for (&tasks) |*t| {
        if (!t.active) continue;
        if (@intFromEnum(t.priority) != @intFromEnum(t.base_priority)) {
            const old_prio = t.priority;
            t.priority = t.base_priority;
            t.time_slice_remaining = SLICE_TABLE[@intFromEnum(t.base_priority)];

            _ = queues[@intFromEnum(old_prio)].removeByPid(t.pid);
            _ = queues[@intFromEnum(t.base_priority)].enqueue(t.pid);
        }
    }
}

// ---- Statistics ----

pub fn getStats() SchedStats {
    var active: u32 = 0;
    var total: u32 = 0;
    for (&tasks) |*t| {
        if (t.active) {
            active += 1;
            total += 1;
        }
    }
    return .{
        .total_context_switches = total_context_switches,
        .total_tasks = total,
        .active_tasks = active,
        .uptime_ticks = pit.getTicks(),
    };
}

/// Print scheduler statistics to VGA.
pub fn printStats() void {
    if (!sched_initialized) {
        vga.write("Scheduler not initialized.\n");
        return;
    }

    const stats = getStats();

    vga.setColor(.light_cyan, .black);
    vga.write("=== Scheduler Statistics ===\n");

    vga.setColor(.light_grey, .black);
    vga.write("Context switches: ");
    vga.setColor(.white, .black);
    printDec64(stats.total_context_switches);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Active tasks:     ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, stats.active_tasks));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Uptime (ticks):   ");
    vga.setColor(.white, .black);
    printDec64(stats.uptime_ticks);
    vga.putChar('\n');

    // Per-queue status
    vga.setColor(.light_cyan, .black);
    vga.write("\nPriority queues:\n");

    const prio_names = [NUM_PRIORITIES][]const u8{ "idle    ", "low     ", "normal  ", "high    ", "realtime" };
    for (0..NUM_PRIORITIES) |p| {
        vga.setColor(.dark_grey, .black);
        vga.write("  [");
        fmt.printDec(p);
        vga.write("] ");
        vga.setColor(.yellow, .black);
        vga.write(prio_names[p]);
        vga.setColor(.light_grey, .black);
        vga.write("  queued=");
        fmt.printDec(queues[p].count);
        vga.write("  slice=");
        fmt.printDec(@as(usize, SLICE_TABLE[p]));
        vga.putChar('\n');
    }

    // Per-task details
    vga.setColor(.light_cyan, .black);
    vga.write("\nPer-task CPU time:\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID  PRIO      CPU_TICKS  LAST_SCHED\n");
    vga.setColor(.light_grey, .black);

    for (&tasks) |*t| {
        if (!t.active) continue;
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.pid), 4);
        vga.write("  ");
        printPriorityName(t.priority);
        vga.write("  ");
        printDec64Padded(t.cpu_ticks, 10);
        vga.write("  ");
        printDec64Padded(t.last_scheduled_tick, 10);
        vga.putChar('\n');
    }
}

fn printPriorityName(p: Priority) void {
    switch (p) {
        .idle => vga.write("idle    "),
        .low => vga.write("low     "),
        .normal => vga.write("normal  "),
        .high => vga.write("high    "),
        .realtime => vga.write("realtime"),
    }
}

// ---- Helpers ----

fn findSlot(pid: u32) ?usize {
    for (&tasks, 0..) |*t, i| {
        if (t.active and t.pid == pid) return i;
    }
    return null;
}

fn findFreeSlot() ?usize {
    for (&tasks, 0..) |*t, i| {
        if (!t.active) return i;
    }
    return null;
}

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDec64Padded(n: u64, width: usize) void {
    // Count digits
    var digits: usize = 0;
    var tmp = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec64(n);
}

fn writeDecSerial(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
