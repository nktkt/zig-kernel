// Scheduler statistics and analysis — per-task and system-wide metrics
//
// Tracks wait_time, run_time, turnaround_time, response_time per task.
// Provides system-wide averages, throughput, CPU utilization, and a
// Gantt chart visualization.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_TASKS: usize = 16;
const GANTT_WIDTH: usize = 60; // Characters wide for Gantt chart
const GANTT_MAX_TICKS: usize = 120; // Max ticks to display

// ============================================================
// Types
// ============================================================

pub const TaskStats = struct {
    pid: u32 = 0,
    active: bool = false,

    // Timing (all in PIT ticks = milliseconds at 1kHz)
    arrival_tick: u64 = 0, // When task first entered ready queue
    first_run_tick: u64 = 0, // When task first got the CPU
    last_dispatch_tick: u64 = 0, // Last time dispatched
    last_preempt_tick: u64 = 0, // Last time preempted
    completion_tick: u64 = 0, // When task completed

    // Accumulated times
    total_run_time: u64 = 0, // Total ticks spent running
    total_wait_time: u64 = 0, // Total ticks spent in ready queue
    dispatch_count: u32 = 0, // Number of times dispatched

    // Derived (computed on completion)
    turnaround_time: u64 = 0, // completion - arrival
    response_time: u64 = 0, // first_run - arrival

    completed: bool = false,
    has_response: bool = false, // first dispatch recorded
};

pub const SystemStats = struct {
    total_tasks: u32 = 0,
    completed_tasks: u32 = 0,
    total_dispatches: u64 = 0,
    total_preemptions: u64 = 0,
    idle_ticks: u64 = 0,
    busy_ticks: u64 = 0,
    measurement_start: u64 = 0,
    measurement_end: u64 = 0,
};

// Gantt chart entry: which PID was running at each tick
const GanttEntry = struct {
    pid: u8 = 0, // 0 = idle
    valid: bool = false,
};

// Scheduler comparison result
pub const SchedResult = struct {
    name: [8]u8 = @splat(0),
    name_len: u8 = 0,
    avg_wait: u64 = 0,
    avg_turnaround: u64 = 0,
    avg_response: u64 = 0,
    throughput_x100: u64 = 0, // tasks/sec * 100 for fixed point
    cpu_util_pct: u32 = 0,
};

// ============================================================
// State
// ============================================================

var task_stats: [MAX_TASKS]TaskStats = [_]TaskStats{.{}} ** MAX_TASKS;
var sys_stats: SystemStats = .{};
var gantt: [GANTT_MAX_TICKS]GanttEntry = [_]GanttEntry{.{}} ** GANTT_MAX_TICKS;
var gantt_pos: usize = 0;
var last_tick: u64 = 0;

// Comparison results for different schedulers
const MAX_SCHED_RESULTS: usize = 4;
var sched_results: [MAX_SCHED_RESULTS]SchedResult = [_]SchedResult{.{}} ** MAX_SCHED_RESULTS;
var sched_result_count: usize = 0;

// ============================================================
// Public API — Recording events
// ============================================================

/// Register a new task for tracking.
pub fn registerTask(pid: u32) void {
    const now = pit.getTicks();
    if (sys_stats.total_tasks == 0) {
        sys_stats.measurement_start = now;
    }

    for (&task_stats) |*ts| {
        if (!ts.active) {
            ts.* = .{
                .pid = pid,
                .active = true,
                .arrival_tick = now,
            };
            sys_stats.total_tasks += 1;
            return;
        }
    }
}

/// Record when a task is dispatched (gets the CPU).
pub fn recordDispatch(pid: u32) void {
    const now = pit.getTicks();
    sys_stats.total_dispatches += 1;

    for (&task_stats) |*ts| {
        if (ts.active and ts.pid == pid) {
            // Calculate wait time since last preemption or arrival
            if (ts.dispatch_count == 0) {
                ts.first_run_tick = now;
                ts.response_time = now -| ts.arrival_tick;
                ts.has_response = true;
            } else {
                ts.total_wait_time += now -| ts.last_preempt_tick;
            }
            ts.last_dispatch_tick = now;
            ts.dispatch_count += 1;
            break;
        }
    }

    // Record in Gantt chart
    recordGantt(@truncate(pid));
}

/// Record when a task is preempted (removed from CPU).
pub fn recordPreempt(pid: u32) void {
    const now = pit.getTicks();
    sys_stats.total_preemptions += 1;

    for (&task_stats) |*ts| {
        if (ts.active and ts.pid == pid) {
            const run_slice = now -| ts.last_dispatch_tick;
            ts.total_run_time += run_slice;
            ts.last_preempt_tick = now;
            sys_stats.busy_ticks += run_slice;
            break;
        }
    }
}

/// Record when a task completes.
pub fn recordComplete(pid: u32) void {
    const now = pit.getTicks();
    sys_stats.completed_tasks += 1;
    sys_stats.measurement_end = now;

    for (&task_stats) |*ts| {
        if (ts.active and ts.pid == pid) {
            // Add final run time
            const run_slice = now -| ts.last_dispatch_tick;
            ts.total_run_time += run_slice;
            sys_stats.busy_ticks += run_slice;

            ts.completion_tick = now;
            ts.turnaround_time = now -| ts.arrival_tick;
            ts.completed = true;
            break;
        }
    }
}

/// Record an idle tick (no task running).
pub fn recordIdle() void {
    sys_stats.idle_ticks += 1;
    recordGantt(0);
}

fn recordGantt(pid: u8) void {
    if (gantt_pos < GANTT_MAX_TICKS) {
        gantt[gantt_pos] = .{ .pid = pid, .valid = true };
        gantt_pos += 1;
    }
}

// ============================================================
// Public API — Queries
// ============================================================

/// Get per-task stats.
pub fn getTaskStats(pid: u32) ?TaskStats {
    for (&task_stats) |*ts| {
        if (ts.active and ts.pid == pid) return ts.*;
    }
    return null;
}

/// Get system stats.
pub fn getSystemStats() SystemStats {
    return sys_stats;
}

/// Compute average wait time across all completed tasks.
pub fn avgWaitTime() u64 {
    var total: u64 = 0;
    var count: u64 = 0;
    for (&task_stats) |*ts| {
        if (ts.active and ts.completed) {
            total += ts.total_wait_time;
            count += 1;
        }
    }
    return if (count > 0) total / count else 0;
}

/// Compute average turnaround time.
pub fn avgTurnaroundTime() u64 {
    var total: u64 = 0;
    var count: u64 = 0;
    for (&task_stats) |*ts| {
        if (ts.active and ts.completed) {
            total += ts.turnaround_time;
            count += 1;
        }
    }
    return if (count > 0) total / count else 0;
}

/// Compute average response time.
pub fn avgResponseTime() u64 {
    var total: u64 = 0;
    var count: u64 = 0;
    for (&task_stats) |*ts| {
        if (ts.active and ts.has_response) {
            total += ts.response_time;
            count += 1;
        }
    }
    return if (count > 0) total / count else 0;
}

/// Compute throughput (tasks completed per second * 100 for fixed-point).
pub fn throughput() u64 {
    const elapsed = sys_stats.measurement_end -| sys_stats.measurement_start;
    if (elapsed == 0) return 0;
    // tasks/sec * 100 = (completed * 100 * 1000) / elapsed_ms
    return (@as(u64, sys_stats.completed_tasks) * 100_000) / elapsed;
}

/// Compute CPU utilization percentage.
pub fn cpuUtilization() u32 {
    const total = sys_stats.busy_ticks + sys_stats.idle_ticks;
    if (total == 0) return 0;
    return @truncate((sys_stats.busy_ticks * 100) / total);
}

// ============================================================
// Scheduler comparison
// ============================================================

/// Store results for a scheduler comparison run.
pub fn storeSchedulerResult(name: []const u8) void {
    if (sched_result_count >= MAX_SCHED_RESULTS) return;

    var r = &sched_results[sched_result_count];
    r.name_len = @intCast(@min(name.len, 8));
    @memcpy(r.name[0..r.name_len], name[0..r.name_len]);
    r.avg_wait = avgWaitTime();
    r.avg_turnaround = avgTurnaroundTime();
    r.avg_response = avgResponseTime();
    r.throughput_x100 = throughput();
    r.cpu_util_pct = cpuUtilization();

    sched_result_count += 1;
}

/// Reset for next comparison run.
pub fn resetForComparison() void {
    for (&task_stats) |*ts| ts.active = false;
    sys_stats = .{};
    gantt_pos = 0;
    for (&gantt) |*g| g.valid = false;
}

/// Full reset including comparison results.
pub fn resetAll() void {
    resetForComparison();
    sched_result_count = 0;
}

// ============================================================
// Display
// ============================================================

/// Print per-task and system-wide stats.
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("Scheduler Statistics:\n\n");
    vga.setColor(.light_grey, .black);

    // Per-task table
    vga.write("  PID  Wait(ms)  Run(ms)  Turnaround  Response  Dispatches  Status\n");
    vga.write("  ---  --------  -------  ----------  --------  ----------  ------\n");

    for (&task_stats) |*ts| {
        if (!ts.active) continue;

        vga.write("  ");
        printDecPadded(ts.pid, 3);
        vga.write("  ");
        printDecPadded(ts.total_wait_time, 8);
        vga.write("  ");
        printDecPadded(ts.total_run_time, 7);
        vga.write("  ");
        printDecPadded(ts.turnaround_time, 10);
        vga.write("  ");
        printDecPadded(ts.response_time, 8);
        vga.write("  ");
        printDecPadded(ts.dispatch_count, 10);
        vga.write("  ");
        if (ts.completed) {
            vga.write("done");
        } else {
            vga.write("active");
        }
        vga.putChar('\n');
    }

    // System-wide stats
    vga.setColor(.yellow, .black);
    vga.write("\nSystem-wide:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Avg Wait Time:       ");
    printDec(avgWaitTime());
    vga.write(" ms\n");
    vga.write("  Avg Turnaround:      ");
    printDec(avgTurnaroundTime());
    vga.write(" ms\n");
    vga.write("  Avg Response Time:   ");
    printDec(avgResponseTime());
    vga.write(" ms\n");

    const tp = throughput();
    vga.write("  Throughput:          ");
    printDec(tp / 100);
    vga.putChar('.');
    printDecPadded(tp % 100, 2);
    vga.write(" tasks/sec\n");

    vga.write("  CPU Utilization:     ");
    printDec(cpuUtilization());
    vga.write("%\n");
    vga.write("  Total Dispatches:    ");
    printDec(sys_stats.total_dispatches);
    vga.putChar('\n');
    vga.write("  Total Preemptions:   ");
    printDec(sys_stats.total_preemptions);
    vga.putChar('\n');
}

/// Print scheduler comparison table.
pub fn printComparison() void {
    vga.setColor(.yellow, .black);
    vga.write("Scheduler Comparison:\n\n");
    vga.setColor(.light_grey, .black);

    if (sched_result_count == 0) {
        vga.write("  No comparison data. Run workloads with different schedulers first.\n");
        return;
    }

    vga.write("  Scheduler   Avg Wait  Avg Turn  Avg Resp  Throughput  CPU%\n");
    vga.write("  ----------  --------  --------  --------  ----------  ----\n");

    for (sched_results[0..sched_result_count]) |*r| {
        vga.write("  ");
        vga.write(r.name[0..r.name_len]);
        var col: usize = r.name_len;
        while (col < 12) : (col += 1) vga.putChar(' ');

        printDecPadded(r.avg_wait, 8);
        vga.write("  ");
        printDecPadded(r.avg_turnaround, 8);
        vga.write("  ");
        printDecPadded(r.avg_response, 8);
        vga.write("  ");
        printDecPadded(r.throughput_x100 / 100, 6);
        vga.putChar('.');
        printDecPadded(r.throughput_x100 % 100, 2);
        vga.write("    ");
        printDecPadded(r.cpu_util_pct, 3);
        vga.putChar('%');
        vga.putChar('\n');
    }
}

/// Print Gantt chart — visual timeline of which task was running.
pub fn printGantt() void {
    vga.setColor(.yellow, .black);
    vga.write("Gantt Chart (");
    printDec(gantt_pos);
    vga.write(" ticks):\n\n");
    vga.setColor(.light_grey, .black);

    if (gantt_pos == 0) {
        vga.write("  (no data)\n");
        return;
    }

    // Collect unique PIDs
    var pids: [MAX_TASKS]u8 = @splat(0);
    var pid_count: usize = 0;
    for (gantt[0..gantt_pos]) |g| {
        if (!g.valid) continue;
        var found = false;
        for (pids[0..pid_count]) |p| {
            if (p == g.pid) {
                found = true;
                break;
            }
        }
        if (!found and pid_count < MAX_TASKS) {
            pids[pid_count] = g.pid;
            pid_count += 1;
        }
    }

    // Scale factor: how many ticks per character
    const display_len = if (gantt_pos > GANTT_WIDTH) GANTT_WIDTH else gantt_pos;
    const scale = if (gantt_pos > GANTT_WIDTH) gantt_pos / GANTT_WIDTH else 1;

    // Print time axis
    vga.write("       ");
    var t: usize = 0;
    while (t < display_len) : (t += 1) {
        if ((t * scale) % 10 == 0) {
            vga.putChar('|');
        } else {
            vga.putChar('-');
        }
    }
    vga.putChar('\n');

    // Print each PID row
    for (pids[0..pid_count]) |pid| {
        if (pid == 0) {
            vga.write("  idle ");
        } else {
            vga.write("  P");
            printDecPadded(pid, 2);
            vga.write("  ");
        }

        var col: usize = 0;
        while (col < display_len) : (col += 1) {
            const tick_idx = col * scale;
            if (tick_idx < gantt_pos and gantt[tick_idx].valid and gantt[tick_idx].pid == pid) {
                vga.setColor(.light_green, .black);
                vga.putChar('#');
                vga.setColor(.light_grey, .black);
            } else {
                vga.putChar('.');
            }
        }
        vga.putChar('\n');
    }

    // Print scale legend
    vga.write("\n  1 char = ");
    printDec(scale);
    vga.write(" tick(s)\n");
}

// ============================================================
// Internal helpers
// ============================================================

fn printDec(n: anytype) void {
    const v_init: u64 = @intCast(n);
    if (v_init == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = v_init;
    while (v > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDecPadded(n: anytype, width: usize) void {
    const val: u64 = @intCast(n);
    var digits: usize = 0;
    var tmp = val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    var pad = if (digits < width) width - digits else 0;
    while (pad > 0) : (pad -= 1) {
        vga.putChar(' ');
    }
    printDec(val);
}
