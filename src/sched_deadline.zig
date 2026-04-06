// Earliest Deadline First (EDF) scheduler — real-time deadline-based scheduling
//
// Each task declares: deadline (absolute), period, and runtime (WCET).
// The scheduler always picks the task with the earliest absolute deadline.
// Admission control ensures total CPU utilization stays <= 100%.
// Deadline miss detection logs violations via serial.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_EDF_TASKS = 16;
const UTILIZATION_SCALE = 10000; // fixed-point 100.00% = 10000

// ---- Task entry ----

pub const EdfTask = struct {
    active: bool,
    pid: u32,
    deadline_ms: u32, // relative deadline (period-relative)
    period_ms: u32, // period in milliseconds
    runtime_ms: u32, // worst-case execution time per period
    abs_deadline: u64, // absolute deadline in ticks (ms)
    remaining_runtime: u32, // remaining runtime in current period
    period_start: u64, // start tick of current period
    total_executed: u64, // total ticks consumed
    deadline_misses: u32, // count of deadline misses
    periods_completed: u32, // count of completed periods
    utilization: u32, // fixed-point: (runtime/period) * SCALE
};

// ---- Statistics ----

pub const EdfStats = struct {
    total_tasks: u32,
    active_tasks: u32,
    total_utilization: u32, // sum of all task utilizations (scaled)
    total_deadline_misses: u32,
    total_periods: u32,
    feasible: bool,
};

// ---- State ----

var tasks: [MAX_EDF_TASKS]EdfTask = undefined;
var task_count: u32 = 0;
var total_utilization: u32 = 0; // sum of per-task utilization (scaled)
var total_deadline_misses: u32 = 0;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&tasks) |*t| {
        t.active = false;
        t.pid = 0;
        t.deadline_ms = 0;
        t.period_ms = 0;
        t.runtime_ms = 0;
        t.abs_deadline = 0;
        t.remaining_runtime = 0;
        t.period_start = 0;
        t.total_executed = 0;
        t.deadline_misses = 0;
        t.periods_completed = 0;
        t.utilization = 0;
    }
    task_count = 0;
    total_utilization = 0;
    total_deadline_misses = 0;
    initialized = true;

    serial.write("[edf] Earliest Deadline First scheduler initialized\n");
}

// ---- Utilization calculation ----

/// Compute utilization for a single task: (runtime / period) * UTILIZATION_SCALE
fn computeUtilization(runtime_ms: u32, period_ms: u32) u32 {
    if (period_ms == 0) return UTILIZATION_SCALE;
    return (@as(u32, runtime_ms) * UTILIZATION_SCALE) / period_ms;
}

// ---- Admission control ----

/// Check if adding a new task would keep total utilization <= 100%.
/// EDF is optimal for uniprocessor: schedulable iff U <= 1.0
pub fn canSchedule(deadline_ms: u32, period_ms: u32, runtime_ms: u32) bool {
    _ = deadline_ms;
    if (!initialized) return false;
    if (period_ms == 0) return false;
    if (runtime_ms > period_ms) return false;

    const new_util = computeUtilization(runtime_ms, period_ms);
    return (total_utilization + new_util) <= UTILIZATION_SCALE;
}

/// Check if a specific task can be admitted (by pid for convenience).
pub fn canScheduleTask(pid: u32, deadline_ms: u32, period_ms: u32, runtime_ms: u32) bool {
    _ = pid;
    return canSchedule(deadline_ms, period_ms, runtime_ms);
}

// ---- Task management ----

/// Add a new EDF task.
pub fn addTask(pid: u32, deadline_ms: u32, period_ms: u32, runtime_ms: u32) bool {
    if (!initialized) return false;
    if (period_ms == 0) return false;
    if (runtime_ms == 0 or runtime_ms > period_ms) return false;

    // Check admission
    if (!canSchedule(deadline_ms, period_ms, runtime_ms)) {
        serial.write("[edf] admission denied for pid=");
        serialDec(pid);
        serial.write(" (utilization would exceed 100%)\n");
        return false;
    }

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
    const s = slot orelse return false;

    const now = pit.getTicks();
    const util = computeUtilization(runtime_ms, period_ms);

    tasks[s] = .{
        .active = true,
        .pid = pid,
        .deadline_ms = deadline_ms,
        .period_ms = period_ms,
        .runtime_ms = runtime_ms,
        .abs_deadline = now + @as(u64, deadline_ms),
        .remaining_runtime = runtime_ms,
        .period_start = now,
        .total_executed = 0,
        .deadline_misses = 0,
        .periods_completed = 0,
        .utilization = util,
    };

    task_count += 1;
    total_utilization += util;

    serial.write("[edf] added pid=");
    serialDec(pid);
    serial.write(" D=");
    serialDec(deadline_ms);
    serial.write(" T=");
    serialDec(period_ms);
    serial.write(" C=");
    serialDec(runtime_ms);
    serial.write(" U=");
    serialDec(util);
    serial.write("/");
    serialDec(UTILIZATION_SCALE);
    serial.write("\n");

    return true;
}

/// Remove a task from the EDF scheduler.
pub fn removeTask(pid: u32) bool {
    if (!initialized) return false;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            total_utilization -= t.utilization;
            t.active = false;
            task_count -= 1;
            serial.write("[edf] removed pid=");
            serialDec(pid);
            serial.write("\n");
            return true;
        }
    }
    return false;
}

// ---- Scheduling ----

/// Pick the task with the earliest absolute deadline.
/// Returns the PID or null if no tasks are runnable.
pub fn getNext() ?u32 {
    if (!initialized or task_count == 0) return null;

    var best: ?usize = null;
    var best_deadline: u64 = 0;

    for (&tasks, 0..) |*t, i| {
        if (!t.active) continue;
        if (t.remaining_runtime == 0) continue; // already finished this period

        if (best == null or t.abs_deadline < best_deadline) {
            best = i;
            best_deadline = t.abs_deadline;
        }
    }

    if (best) |idx| {
        return tasks[idx].pid;
    }
    return null;
}

/// Called each tick from the timer interrupt.
/// Advances the currently running EDF task, checks deadlines, and handles period rollovers.
pub fn updateDeadlines() void {
    if (!initialized) return;

    const now = pit.getTicks();

    for (&tasks) |*t| {
        if (!t.active) continue;

        // Check for period expiration and deadline miss
        if (now >= t.period_start + @as(u64, t.period_ms)) {
            // Period has elapsed: check if task finished
            if (t.remaining_runtime > 0) {
                // Deadline miss!
                t.deadline_misses += 1;
                total_deadline_misses += 1;
                serial.write("[edf] DEADLINE MISS pid=");
                serialDec(t.pid);
                serial.write(" remaining=");
                serialDec(t.remaining_runtime);
                serial.write("ms\n");
            }

            // Start new period
            t.periods_completed += 1;
            t.period_start = now;
            t.abs_deadline = now + @as(u64, t.deadline_ms);
            t.remaining_runtime = t.runtime_ms;
        }

        // Check if absolute deadline was passed without completing
        if (now > t.abs_deadline and t.remaining_runtime > 0) {
            // Overrun: deadline has passed but task still has remaining work
            // This is detected but the task continues (best effort)
            if (t.deadline_misses == 0 or
                (now - t.abs_deadline) < 2)
            {
                // Only log once per miss cycle
                serial.write("[edf] overrun pid=");
                serialDec(t.pid);
                serial.write("\n");
            }
        }
    }
}

/// Consume one tick of runtime for a given task.
pub fn consumeTick(pid: u32) void {
    if (!initialized) return;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            if (t.remaining_runtime > 0) {
                t.remaining_runtime -= 1;
            }
            t.total_executed += 1;
            return;
        }
    }
}

// ---- Modification ----

/// Change the parameters of an existing task (removes and re-adds).
pub fn modifyTask(pid: u32, deadline_ms: u32, period_ms: u32, runtime_ms: u32) bool {
    if (!initialized) return false;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            // Check if new params are feasible
            const old_util = t.utilization;
            const new_util = computeUtilization(runtime_ms, period_ms);
            if ((total_utilization - old_util + new_util) > UTILIZATION_SCALE) {
                return false; // would exceed 100%
            }

            // Update
            total_utilization = total_utilization - old_util + new_util;
            t.deadline_ms = deadline_ms;
            t.period_ms = period_ms;
            t.runtime_ms = runtime_ms;
            t.utilization = new_util;
            // Reset period
            const now = pit.getTicks();
            t.period_start = now;
            t.abs_deadline = now + @as(u64, deadline_ms);
            t.remaining_runtime = runtime_ms;
            return true;
        }
    }
    return false;
}

// ---- Query ----

/// Get task info by PID.
pub fn getTask(pid: u32) ?*const EdfTask {
    if (!initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) return t;
    }
    return null;
}

/// Get utilization as percentage (0-100) in fixed-point x100.
pub fn getUtilizationPercent() u32 {
    // total_utilization is in UTILIZATION_SCALE (10000 = 100%)
    // Return as percent * 100 (e.g. 7500 = 75.00%)
    return total_utilization;
}

/// Check if system is feasible (U <= 1.0).
pub fn isFeasible() bool {
    return total_utilization <= UTILIZATION_SCALE;
}

// ---- Statistics ----

pub fn getStats() EdfStats {
    var active: u32 = 0;
    var total_misses: u32 = 0;
    var total_periods: u32 = 0;

    for (&tasks) |*t| {
        if (t.active) {
            active += 1;
            total_misses += t.deadline_misses;
            total_periods += t.periods_completed;
        }
    }

    return .{
        .total_tasks = task_count,
        .active_tasks = active,
        .total_utilization = total_utilization,
        .total_deadline_misses = total_misses,
        .total_periods = total_periods,
        .feasible = isFeasible(),
    };
}

// ---- Display ----

/// Print all EDF tasks and their status.
pub fn printTasks() void {
    if (!initialized) {
        vga.write("EDF scheduler not initialized.\n");
        return;
    }

    const now = pit.getTicks();

    vga.setColor(.light_cyan, .black);
    vga.write("=== EDF Deadline Scheduler ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID  DEADLINE  PERIOD  RUNTIME  REMAIN  MISSES  PERIODS  UTIL%\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    for (&tasks) |*t| {
        if (!t.active) continue;
        any = true;

        // Highlight tasks near deadline
        if (t.remaining_runtime > 0 and t.abs_deadline > 0 and
            now + 10 >= t.abs_deadline)
        {
            vga.setColor(.light_red, .black);
        } else if (t.remaining_runtime == 0) {
            vga.setColor(.light_green, .black);
        } else {
            vga.setColor(.light_grey, .black);
        }

        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.pid), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.deadline_ms), 8);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.period_ms), 6);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.runtime_ms), 7);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.remaining_runtime), 6);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.deadline_misses), 6);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.periods_completed), 7);
        vga.write("  ");
        // Print utilization as XX.XX%
        printUtilPercent(t.utilization);
        vga.putChar('\n');
    }

    if (!any) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no tasks registered)\n");
    }

    // Summary
    vga.setColor(.light_cyan, .black);
    vga.write("\nSystem utilization: ");
    vga.setColor(.white, .black);
    printUtilPercent(total_utilization);
    vga.write(" / 100.00%");
    if (isFeasible()) {
        vga.setColor(.light_green, .black);
        vga.write("  [FEASIBLE]\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  [OVERLOADED]\n");
    }

    vga.setColor(.light_grey, .black);
    vga.write("Total deadline misses: ");
    fmt.printDec(@as(usize, total_deadline_misses));
    vga.putChar('\n');
    vga.write("Registered tasks:     ");
    fmt.printDec(@as(usize, task_count));
    vga.putChar('\n');
}

/// Print individual task detail.
pub fn printTaskDetail(pid: u32) void {
    if (!initialized) return;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            vga.setColor(.light_cyan, .black);
            vga.write("EDF Task PID=");
            fmt.printDec(@as(usize, t.pid));
            vga.putChar('\n');

            vga.setColor(.light_grey, .black);
            vga.write("  Deadline:    ");
            fmt.printDec(@as(usize, t.deadline_ms));
            vga.write(" ms\n");
            vga.write("  Period:      ");
            fmt.printDec(@as(usize, t.period_ms));
            vga.write(" ms\n");
            vga.write("  Runtime:     ");
            fmt.printDec(@as(usize, t.runtime_ms));
            vga.write(" ms\n");
            vga.write("  Remaining:   ");
            fmt.printDec(@as(usize, t.remaining_runtime));
            vga.write(" ms\n");
            vga.write("  Abs deadline:");
            printDec64(t.abs_deadline);
            vga.write(" ticks\n");
            vga.write("  Executed:    ");
            printDec64(t.total_executed);
            vga.write(" ticks\n");
            vga.write("  Misses:      ");
            fmt.printDec(@as(usize, t.deadline_misses));
            vga.putChar('\n');
            vga.write("  Periods:     ");
            fmt.printDec(@as(usize, t.periods_completed));
            vga.putChar('\n');
            vga.write("  Utilization: ");
            printUtilPercent(t.utilization);
            vga.putChar('\n');
            return;
        }
    }
    vga.write("Task not found.\n");
}

/// Print utilization as XX.XX%
fn printUtilPercent(util: u32) void {
    // util is in UTILIZATION_SCALE (10000 = 100%)
    const percent = util / 100; // integer part of percent
    const frac = util % 100; // fractional part
    fmt.printDec(@as(usize, percent));
    vga.putChar('.');
    if (frac < 10) vga.putChar('0');
    fmt.printDec(@as(usize, frac));
    vga.putChar('%');
}

/// Get the number of active tasks.
pub fn getTaskCount() u32 {
    return task_count;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

/// Reset all tasks and statistics.
pub fn reset() void {
    for (&tasks) |*t| {
        t.active = false;
    }
    task_count = 0;
    total_utilization = 0;
    total_deadline_misses = 0;
}

// ---- Helpers ----

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
