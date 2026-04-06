// System load average calculation — exponential moving average
//
// Samples runnable task count every 5 seconds and computes
// 1-minute, 5-minute, 15-minute exponential moving averages.
// Uses fixed-point 8.8 arithmetic (256 = 1.0).

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const task = @import("task.zig");
const serial = @import("serial.zig");

// ---- Constants ----

/// Fixed-point scale: 8.8 format (256 = 1.0)
const FP_SCALE: u32 = 256;

/// Sample interval in ticks (5000ms = 5 seconds at 1kHz PIT)
const SAMPLE_INTERVAL: u64 = 5000;

/// EMA decay factors (fixed-point 8.8)
/// For 5-second samples:
///   1-min  = 12 samples  -> alpha ~= 0.92 -> 1 - alpha = 0.08 -> ~20/256
///   5-min  = 60 samples  -> alpha ~= 0.98 -> 1 - alpha = 0.02 -> ~5/256
///   15-min = 180 samples -> alpha ~= 0.99 -> 1 - alpha = 0.007 -> ~2/256
const DECAY_1MIN: u32 = 20; // ~0.08 * 256
const DECAY_5MIN: u32 = 5; // ~0.02 * 256
const DECAY_15MIN: u32 = 2; // ~0.007 * 256

// ---- Task state counts ----

pub const TaskCounts = struct {
    running: u32,
    sleeping: u32, // ready + waiting
    zombie: u32,
    stopped: u32, // terminated
    total: u32,
};

// ---- State ----

var load_1min: u32 = 0; // fixed-point 8.8
var load_5min: u32 = 0;
var load_15min: u32 = 0;

var last_sample_tick: u64 = 0;
var total_samples: u32 = 0;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    load_1min = 0;
    load_5min = 0;
    load_15min = 0;
    last_sample_tick = pit.getTicks();
    total_samples = 0;
    initialized = true;
    serial.write("[loadavg] Load average monitor initialized\n");
}

// ---- Sampling ----

/// Count runnable tasks by scanning the task table.
fn countRunnable() u32 {
    var count: u32 = 0;
    var pid: u32 = 0;
    while (pid < 256) : (pid += 1) {
        if (task.getTask(pid)) |t| {
            if (t.state == .running or t.state == .ready) {
                count += 1;
            }
        }
    }
    return count;
}

/// Get detailed task state counts.
pub fn getTaskCounts() TaskCounts {
    var counts = TaskCounts{
        .running = 0,
        .sleeping = 0,
        .zombie = 0,
        .stopped = 0,
        .total = 0,
    };

    var pid: u32 = 0;
    while (pid < 256) : (pid += 1) {
        if (task.getTask(pid)) |t| {
            counts.total += 1;
            switch (t.state) {
                .running => counts.running += 1,
                .ready, .waiting => counts.sleeping += 1,
                .zombie => counts.zombie += 1,
                .terminated => counts.stopped += 1,
                .unused => {},
            }
        }
    }
    return counts;
}

/// Called periodically (from timer or main loop).
/// Checks if SAMPLE_INTERVAL has elapsed and takes a sample if so.
pub fn sample() void {
    if (!initialized) return;

    const now = pit.getTicks();
    if (now - last_sample_tick < SAMPLE_INTERVAL) return;
    last_sample_tick = now;

    const runnable = countRunnable();
    const load_fp = runnable * FP_SCALE; // convert to fixed-point

    // Update exponential moving averages:
    // new_avg = old_avg + decay * (sample - old_avg)
    // In fixed-point: new_avg = old_avg + (decay * (sample - old_avg)) / FP_SCALE

    if (total_samples == 0) {
        // First sample: initialize directly
        load_1min = load_fp;
        load_5min = load_fp;
        load_15min = load_fp;
    } else {
        load_1min = emaUpdate(load_1min, load_fp, DECAY_1MIN);
        load_5min = emaUpdate(load_5min, load_fp, DECAY_5MIN);
        load_15min = emaUpdate(load_15min, load_fp, DECAY_15MIN);
    }

    total_samples += 1;
}

/// Exponential moving average update in fixed-point.
/// new = old + (decay * (sample - old)) / FP_SCALE
fn emaUpdate(old: u32, sample_val: u32, decay: u32) u32 {
    if (sample_val >= old) {
        // sample >= old: positive delta
        const delta = sample_val - old;
        return old + (decay * delta) / FP_SCALE;
    } else {
        // sample < old: negative delta
        const delta = old - sample_val;
        const decrease = (decay * delta) / FP_SCALE;
        if (decrease > old) return 0;
        return old - decrease;
    }
}

// ---- Queries ----

/// Get load averages as fixed-point 8.8 values.
/// Returns [3]u32: [0]=1min, [1]=5min, [2]=15min
pub fn getLoadAvg() [3]u32 {
    return .{ load_1min, load_5min, load_15min };
}

/// Get load average as integer part (for simple display).
pub fn getLoadAvgInt() [3]u32 {
    return .{
        load_1min / FP_SCALE,
        load_5min / FP_SCALE,
        load_15min / FP_SCALE,
    };
}

/// Get sample count.
pub fn getSampleCount() u32 {
    return total_samples;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Display ----

/// Print load averages (similar to /proc/loadavg).
pub fn printLoadAvg() void {
    if (!initialized) {
        vga.write("Load average not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("Load average: ");
    vga.setColor(.white, .black);

    printFixedPoint(load_1min);
    vga.write(", ");
    printFixedPoint(load_5min);
    vga.write(", ");
    printFixedPoint(load_15min);

    // Task counts
    const counts = getTaskCounts();
    vga.setColor(.light_grey, .black);
    vga.write("  (");
    fmt.printDec(@as(usize, counts.running));
    vga.write("/");
    fmt.printDec(@as(usize, counts.total));
    vga.write(" running)\n");
}

/// Print detailed load average info.
pub fn printLoadAvgDetail() void {
    if (!initialized) {
        vga.write("Load average not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== System Load Average ===\n");

    vga.setColor(.light_grey, .black);
    vga.write("  1-minute:  ");
    vga.setColor(.white, .black);
    printFixedPoint(load_1min);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  5-minute:  ");
    vga.setColor(.white, .black);
    printFixedPoint(load_5min);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  15-minute: ");
    vga.setColor(.white, .black);
    printFixedPoint(load_15min);
    vga.putChar('\n');

    // Task state summary
    const counts = getTaskCounts();
    vga.setColor(.light_cyan, .black);
    vga.write("\nTask States:\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Total:    ");
    fmt.printDec(@as(usize, counts.total));
    vga.putChar('\n');

    vga.write("  Running:  ");
    vga.setColor(.light_green, .black);
    fmt.printDec(@as(usize, counts.running));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  Sleeping: ");
    vga.setColor(.light_cyan, .black);
    fmt.printDec(@as(usize, counts.sleeping));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  Zombie:   ");
    if (counts.zombie > 0) {
        vga.setColor(.light_red, .black);
    } else {
        vga.setColor(.light_grey, .black);
    }
    fmt.printDec(@as(usize, counts.zombie));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  Stopped:  ");
    fmt.printDec(@as(usize, counts.stopped));
    vga.putChar('\n');

    vga.write("\nSamples taken: ");
    fmt.printDec(@as(usize, total_samples));
    vga.putChar('\n');

    // Visual load bar
    vga.setColor(.light_cyan, .black);
    vga.write("\nLoad (1m): ");
    const bar_load = load_1min / (FP_SCALE / 10); // scale to 0-N*10
    const bar_val: usize = if (bar_load > 40) 40 else @as(usize, @truncate(bar_load));
    fmt.printBar(bar_val, 40, 40);
    vga.putChar('\n');
}

// ---- Helpers ----

/// Print a fixed-point 8.8 value as X.XX
fn printFixedPoint(val: u32) void {
    const integer = val / FP_SCALE;
    const frac = ((val % FP_SCALE) * 100) / FP_SCALE;

    fmt.printDec(@as(usize, integer));
    vga.putChar('.');
    if (frac < 10) vga.putChar('0');
    fmt.printDec(@as(usize, frac));
}
