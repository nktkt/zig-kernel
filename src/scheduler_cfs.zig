// Completely Fair Scheduler (CFS-like) -- virtual-runtime based scheduling
//
// Each task accumulates virtual runtime (vruntime) weighted by its nice value.
// The task with the lowest vruntime is always scheduled next, ensuring fairness.
// Nice values range from -20 (high priority) to 19 (low priority), affecting
// the rate at which vruntime grows. A red-black tree is simulated via a sorted
// array (max 16 tasks). Jain's fairness index is computed for analysis.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_CFS_TASKS = 16;
pub const MIN_NICE: i8 = -20;
pub const MAX_NICE: i8 = 19;
pub const NICE_RANGE = 40; // -20..19

/// Scheduling period in ticks (6ms at 1kHz PIT)
pub const SCHED_PERIOD: u64 = 6;

/// Minimum granularity in ticks (1ms) -- never give a task less than this
pub const MIN_GRANULARITY: u64 = 1;

/// Default nice for new tasks
pub const DEFAULT_NICE: i8 = 0;

/// Weight 0 corresponds to nice 0. The table is indexed by (nice + 20).
/// Weights roughly follow the Linux kernel sched_prio_to_weight[] table
/// but scaled to small integers suitable for our integer-only arithmetic.
/// Higher weight = higher priority (lower nice).
const WEIGHT_TABLE = [NICE_RANGE]u32{
    // nice -20..-11
    88761, 71755, 56483, 46273, 36291,
    29154, 23254, 18705, 14949, 11916,
    // nice -10..-1
    9548, 7620, 6100, 4904, 3906,
    3121, 2501, 1991, 1586, 1277,
    // nice 0..9
    1024, 820, 655, 526, 423,
    335, 272, 215, 172, 137,
    // nice 10..19
    110, 87, 70, 56, 45,
    36, 29, 23, 18, 15,
};

/// Inverse weight table (pre-calculated as 2^32 / weight) for fast division.
/// Used to compute: vruntime_delta = (delta * NICE_0_WEIGHT * inv_weight) >> 32
const NICE_0_WEIGHT: u64 = 1024; // weight at nice 0

// ---- CFS task entry ----

pub const CfsTask = struct {
    active: bool,
    pid: u32,
    nice: i8,
    weight: u32,
    vruntime: u64, // virtual runtime in "weighted ticks"
    exec_runtime: u64, // actual CPU ticks consumed
    last_scheduled_tick: u64,
    slice_remaining: u64, // ticks until preemption
    num_schedules: u64, // how many times this task was scheduled
    wait_ticks: u64, // total ticks spent waiting
};

// ---- Scheduler statistics ----

pub const CfsStats = struct {
    total_switches: u64,
    total_tasks: u32,
    active_tasks: u32,
    min_vruntime: u64,
    max_vruntime: u64,
    fairness_index: u32, // Jain's index * 1000 (fixed point)
    avg_latency: u64, // average scheduling latency in ticks
};

// ---- State ----

var tasks: [MAX_CFS_TASKS]CfsTask = undefined;
var task_count: u32 = 0;
var total_weight: u64 = 0;
var min_vruntime: u64 = 0; // floor: new tasks start here
var total_switches: u64 = 0;
var total_latency_sum: u64 = 0;
var total_latency_count: u64 = 0;
var initialized: bool = false;

// ---- Sorted order index (simulates RB-tree traversal) ----
// Indices into tasks[] sorted by vruntime ascending
var sorted_indices: [MAX_CFS_TASKS]u8 = undefined;
var sorted_count: u8 = 0;

// ---- Initialization ----

pub fn init() void {
    for (&tasks) |*t| {
        t.active = false;
        t.pid = 0;
        t.nice = 0;
        t.weight = WEIGHT_TABLE[20]; // nice 0
        t.vruntime = 0;
        t.exec_runtime = 0;
        t.last_scheduled_tick = 0;
        t.slice_remaining = 0;
        t.num_schedules = 0;
        t.wait_ticks = 0;
    }
    task_count = 0;
    total_weight = 0;
    min_vruntime = 0;
    total_switches = 0;
    total_latency_sum = 0;
    total_latency_count = 0;
    sorted_count = 0;
    initialized = true;

    serial.write("[cfs] Completely Fair Scheduler initialized\n");
}

// ---- Weight from nice ----

fn niceToWeight(nice: i8) u32 {
    const idx: usize = @intCast(@as(i32, nice) + 20);
    if (idx >= NICE_RANGE) return WEIGHT_TABLE[20]; // fallback to nice 0
    return WEIGHT_TABLE[idx];
}

/// Calculate time slice for a task given current total weight.
/// slice = max(MIN_GRANULARITY, (weight / total_weight) * SCHED_PERIOD)
fn calcTimeSlice(weight: u32) u64 {
    if (total_weight == 0) return SCHED_PERIOD;
    const slice = (SCHED_PERIOD * @as(u64, weight)) / total_weight;
    return if (slice < MIN_GRANULARITY) MIN_GRANULARITY else slice;
}

/// Calculate vruntime delta:
/// vruntime_delta = delta_ticks * (NICE_0_WEIGHT / weight)
/// We scale by 1024 to maintain precision.
fn calcVruntimeDelta(delta_ticks: u64, weight: u32) u64 {
    if (weight == 0) return delta_ticks;
    return (delta_ticks * NICE_0_WEIGHT) / @as(u64, weight);
}

// ---- Sorted array maintenance ----

fn rebuildSorted() void {
    sorted_count = 0;
    for (&tasks, 0..) |*t, i| {
        if (t.active) {
            sorted_indices[sorted_count] = @truncate(i);
            sorted_count += 1;
        }
    }
    // Insertion sort by vruntime ascending
    if (sorted_count <= 1) return;
    var i: u8 = 1;
    while (i < sorted_count) : (i += 1) {
        const key = sorted_indices[i];
        const key_vrt = tasks[key].vruntime;
        var j: u8 = i;
        while (j > 0 and tasks[sorted_indices[j - 1]].vruntime > key_vrt) {
            sorted_indices[j] = sorted_indices[j - 1];
            j -= 1;
        }
        sorted_indices[j] = key;
    }
}

// ---- Task management ----

/// Add a new task with the given nice value.
pub fn addTask(pid: u32, nice: i8) bool {
    if (!initialized) return false;

    // Check if already exists
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) return false;
    }

    // Find free slot
    var slot: ?usize = null;
    for (&tasks, 0..) |*t, i| {
        if (!t.active) {
            slot = i;
            break;
        }
    }
    const s = slot orelse return false; // full

    const clamped_nice = clampNice(nice);
    const w = niceToWeight(clamped_nice);

    tasks[s] = .{
        .active = true,
        .pid = pid,
        .nice = clamped_nice,
        .weight = w,
        .vruntime = min_vruntime, // start at current minimum so new tasks aren't starved
        .exec_runtime = 0,
        .last_scheduled_tick = pit.getTicks(),
        .slice_remaining = calcTimeSlice(w),
        .num_schedules = 0,
        .wait_ticks = 0,
    };

    task_count += 1;
    total_weight += @as(u64, w);
    rebuildSorted();

    serial.write("[cfs] added pid=");
    serialDec(pid);
    serial.write(" nice=");
    serialDecSigned(clamped_nice);
    serial.write(" weight=");
    serialDec(w);
    serial.write("\n");

    return true;
}

/// Remove a task from the scheduler.
pub fn removeTask(pid: u32) bool {
    if (!initialized) return false;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            total_weight -= @as(u64, t.weight);
            t.active = false;
            task_count -= 1;
            rebuildSorted();
            return true;
        }
    }
    return false;
}

/// Pick the task with the minimum vruntime (leftmost in "RB-tree").
pub fn pickNext() ?u32 {
    if (!initialized or sorted_count == 0) return null;
    rebuildSorted();
    const idx = sorted_indices[0];
    const t = &tasks[idx];
    t.num_schedules += 1;
    t.last_scheduled_tick = pit.getTicks();

    // Recalculate time slice
    t.slice_remaining = calcTimeSlice(t.weight);
    total_switches += 1;

    return t.pid;
}

/// Update the vruntime of a task after it has run for delta_ticks.
pub fn updateVruntime(pid: u32, delta_ticks: u64) void {
    if (!initialized) return;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            const vdelta = calcVruntimeDelta(delta_ticks, t.weight);
            t.vruntime += vdelta;
            t.exec_runtime += delta_ticks;

            // Update minimum vruntime floor
            updateMinVruntime();

            // Rebuild sorted order after vruntime change
            rebuildSorted();
            return;
        }
    }
}

/// Track min vruntime as floor for new tasks.
fn updateMinVruntime() void {
    var found = false;
    var new_min: u64 = 0;
    for (&tasks) |*t| {
        if (t.active) {
            if (!found or t.vruntime < new_min) {
                new_min = t.vruntime;
                found = true;
            }
        }
    }
    if (found and new_min > min_vruntime) {
        min_vruntime = new_min;
    }
}

/// Called from timer tick for the currently running task.
/// Returns next PID if preemption needed, null otherwise.
pub fn tick(current_pid: u32) ?u32 {
    if (!initialized) return null;

    for (&tasks) |*t| {
        if (t.active and t.pid == current_pid) {
            // Advance vruntime by 1 tick weighted
            const vdelta = calcVruntimeDelta(1, t.weight);
            t.vruntime += vdelta;
            t.exec_runtime += 1;

            if (t.slice_remaining > 0) {
                t.slice_remaining -= 1;
            }

            // Accumulate wait time for other tasks
            for (&tasks) |*other| {
                if (other.active and other.pid != current_pid) {
                    other.wait_ticks += 1;
                }
            }

            // If slice expired, preempt
            if (t.slice_remaining == 0) {
                updateMinVruntime();
                rebuildSorted();

                const next = pickNext();
                if (next) |next_pid| {
                    if (next_pid != current_pid) {
                        // Track latency
                        total_latency_sum += 1;
                        total_latency_count += 1;
                        return next_pid;
                    }
                    // Same task picked again, reset slice
                    t.slice_remaining = calcTimeSlice(t.weight);
                }
            }
            break;
        }
    }
    return null;
}

// ---- Nice value management ----

fn clampNice(nice: i8) i8 {
    if (nice < MIN_NICE) return MIN_NICE;
    if (nice > MAX_NICE) return MAX_NICE;
    return nice;
}

/// Change the nice value of a running task.
pub fn setNice(pid: u32, nice: i8) bool {
    if (!initialized) return false;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            const old_weight = t.weight;
            t.nice = clampNice(nice);
            t.weight = niceToWeight(t.nice);

            // Adjust total weight
            total_weight = total_weight - @as(u64, old_weight) + @as(u64, t.weight);

            // Scale vruntime to compensate for weight change:
            // new_vruntime = old_vruntime * old_weight / new_weight
            if (t.weight > 0) {
                t.vruntime = (t.vruntime * @as(u64, old_weight)) / @as(u64, t.weight);
            }

            // Recalculate slice
            t.slice_remaining = calcTimeSlice(t.weight);
            rebuildSorted();
            return true;
        }
    }
    return false;
}

/// Get the nice value of a task.
pub fn getNice(pid: u32) ?i8 {
    if (!initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return t.nice;
        }
    }
    return null;
}

/// Get the weight of a task.
pub fn getWeight(pid: u32) ?u32 {
    if (!initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return t.weight;
        }
    }
    return null;
}

/// Get the vruntime of a task.
pub fn getVruntime(pid: u32) ?u64 {
    if (!initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return t.vruntime;
        }
    }
    return null;
}

/// Get time slice for a task.
pub fn getTimeSlice(pid: u32) ?u64 {
    if (!initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return calcTimeSlice(t.weight);
        }
    }
    return null;
}

// ---- Jain's Fairness Index ----
//
// J(x1..xn) = (sum(xi))^2 / (n * sum(xi^2))
// Returns value * 1000 for fixed-point (1000 = perfectly fair)

fn computeFairnessIndex() u32 {
    if (task_count < 2) return 1000;

    var sum: u64 = 0;
    var sum_sq: u64 = 0;
    var n: u64 = 0;

    for (&tasks) |*t| {
        if (!t.active) continue;
        const x = t.exec_runtime;
        sum += x;
        sum_sq += x * x;
        n += 1;
    }

    if (n == 0 or sum_sq == 0) return 1000;

    // J = sum^2 / (n * sum_sq), scaled by 1000
    const numerator = (sum * sum * 1000);
    const denominator = n * sum_sq;
    if (denominator == 0) return 1000;
    const index = numerator / denominator;

    return @truncate(index);
}

// ---- Statistics ----

pub fn getStats() CfsStats {
    var active: u32 = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    var first = true;

    for (&tasks) |*t| {
        if (t.active) {
            active += 1;
            if (first) {
                mn = t.vruntime;
                mx = t.vruntime;
                first = false;
            } else {
                if (t.vruntime < mn) mn = t.vruntime;
                if (t.vruntime > mx) mx = t.vruntime;
            }
        }
    }

    const avg_lat: u64 = if (total_latency_count > 0)
        total_latency_sum / total_latency_count
    else
        0;

    return .{
        .total_switches = total_switches,
        .total_tasks = task_count,
        .active_tasks = active,
        .min_vruntime = mn,
        .max_vruntime = mx,
        .fairness_index = computeFairnessIndex(),
        .avg_latency = avg_lat,
    };
}

/// Print all tasks sorted by vruntime (the "red-black tree" view).
pub fn printTree() void {
    if (!initialized) {
        vga.write("CFS not initialized.\n");
        return;
    }
    rebuildSorted();

    vga.setColor(.light_cyan, .black);
    vga.write("=== CFS Task Tree (sorted by vruntime) ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID   NICE  WEIGHT   VRUNTIME     EXEC_RT   SLICE\n");
    vga.setColor(.light_grey, .black);

    var i: u8 = 0;
    while (i < sorted_count) : (i += 1) {
        const idx = sorted_indices[i];
        const t = &tasks[idx];
        if (!t.active) continue;

        // Mark leftmost (next to run) with arrow
        if (i == 0) {
            vga.setColor(.light_green, .black);
            vga.write("> ");
        } else {
            vga.setColor(.light_grey, .black);
            vga.write("  ");
        }

        fmt.printDecPadded(@as(usize, t.pid), 4);
        vga.write("  ");
        printNicePadded(t.nice);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.weight), 6);
        vga.write("  ");
        printDec64Padded(t.vruntime, 10);
        vga.write("  ");
        printDec64Padded(t.exec_runtime, 8);
        vga.write("  ");
        printDec64Padded(t.slice_remaining, 4);
        vga.putChar('\n');
    }

    if (sorted_count == 0) {
        vga.write("  (no tasks)\n");
    }

    vga.setColor(.light_grey, .black);
    vga.write("Total weight: ");
    printDec64(total_weight);
    vga.write("  Min vruntime: ");
    printDec64(min_vruntime);
    vga.putChar('\n');
}

/// Print comprehensive scheduler statistics.
pub fn printStats() void {
    if (!initialized) {
        vga.write("CFS not initialized.\n");
        return;
    }

    const stats = getStats();

    vga.setColor(.light_cyan, .black);
    vga.write("=== CFS Scheduler Statistics ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Context switches: ");
    vga.setColor(.white, .black);
    printDec64(stats.total_switches);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Active tasks:     ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, stats.active_tasks));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Vruntime range:   ");
    vga.setColor(.white, .black);
    printDec64(stats.min_vruntime);
    vga.write(" - ");
    printDec64(stats.max_vruntime);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Avg latency:      ");
    vga.setColor(.white, .black);
    printDec64(stats.avg_latency);
    vga.write(" ticks\n");

    vga.setColor(.light_grey, .black);
    vga.write("Fairness index:   ");
    // Print as X.XXX
    const fi = stats.fairness_index;
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, fi / 1000));
    vga.putChar('.');
    const frac = fi % 1000;
    if (frac < 100) vga.putChar('0');
    if (frac < 10) vga.putChar('0');
    fmt.printDec(@as(usize, frac));
    vga.write(" / 1.000\n");

    vga.setColor(.light_grey, .black);
    vga.write("Sched period:     ");
    fmt.printDec(@as(usize, SCHED_PERIOD));
    vga.write(" ticks\n");
    vga.write("Min granularity:  ");
    fmt.printDec(@as(usize, MIN_GRANULARITY));
    vga.write(" ticks\n");
    vga.write("Total weight:     ");
    printDec64(total_weight);
    vga.putChar('\n');

    // Per-task breakdown
    vga.setColor(.light_cyan, .black);
    vga.write("\nPer-task breakdown:\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID   NICE  WEIGHT   EXEC_RT  SCHED_CNT  WAIT_TICKS\n");
    vga.setColor(.light_grey, .black);

    for (&tasks) |*t| {
        if (!t.active) continue;
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.pid), 4);
        vga.write("  ");
        printNicePadded(t.nice);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.weight), 6);
        vga.write("  ");
        printDec64Padded(t.exec_runtime, 8);
        vga.write("  ");
        printDec64Padded(t.num_schedules, 9);
        vga.write("  ");
        printDec64Padded(t.wait_ticks, 10);
        vga.putChar('\n');
    }
}

/// Reset all statistics without removing tasks.
pub fn resetStats() void {
    total_switches = 0;
    total_latency_sum = 0;
    total_latency_count = 0;
    for (&tasks) |*t| {
        if (t.active) {
            t.exec_runtime = 0;
            t.num_schedules = 0;
            t.wait_ticks = 0;
        }
    }
}

/// Get count of active tasks.
pub fn getTaskCount() u32 {
    return task_count;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Helpers ----

fn printNicePadded(nice: i8) void {
    if (nice >= 0) {
        vga.putChar(' ');
    }
    if (nice < 0) {
        vga.putChar('-');
        const abs: u8 = @intCast(-@as(i16, nice));
        if (abs < 10) vga.putChar(' ');
        fmt.printDec(@as(usize, abs));
    } else {
        const val: u8 = @intCast(nice);
        if (val < 10) vga.putChar(' ');
        fmt.printDec(@as(usize, val));
    }
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

fn serialDec(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialDecSigned(n: i8) void {
    if (n < 0) {
        serial.putChar('-');
        const abs: u8 = @intCast(-@as(i16, n));
        serialDec(@as(u32, abs));
    } else {
        serialDec(@as(u32, @intCast(n)));
    }
}
