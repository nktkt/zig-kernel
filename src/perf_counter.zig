// Performance counters and metrics -- Named counters, gauges, histograms
// Counter types: monotonic, gauge, histogram.
// Named counters: max 32. Built-in counters for kernel subsystems.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Constants ----

const MAX_COUNTERS = 32;
const MAX_NAME_LEN = 24;
const HISTOGRAM_BUCKETS = 8;

// ---- Counter types ----

pub const CounterType = enum(u8) {
    monotonic, // only increments
    gauge, // can go up and down
    histogram, // tracks distribution
};

// ---- Counter value (tagged union emulated with struct) ----

pub const CounterValue = struct {
    counter_type: CounterType,
    // Monotonic counter value
    monotonic_val: u64,
    // Gauge value
    gauge_val: i64,
    // Histogram data: exponential buckets
    // Bucket boundaries: [0, 1), [1, 2), [2, 4), [4, 8), [8, 16), [16, 32), [32, 64), [64, inf)
    hist_buckets: [HISTOGRAM_BUCKETS]u32,
    hist_count: u32,
    hist_sum: u64,
    hist_min: u32,
    hist_max: u32,
};

// ---- Named counter entry ----

const CounterEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    value: CounterValue,
    used: bool,
};

// ---- State ----

var counters: [MAX_COUNTERS]CounterEntry = undefined;
var counter_count: usize = 0;
var initialized: bool = false;

// ---- Built-in counter indices ----
var idx_syscalls: ?usize = null;
var idx_ctx_switches: ?usize = null;
var idx_page_faults: ?usize = null;
var idx_interrupts: ?usize = null;
var idx_allocations: ?usize = null;
var idx_frees: ?usize = null;

// ---- Initialization ----

fn ensureInit() void {
    if (initialized) return;
    var i: usize = 0;
    while (i < MAX_COUNTERS) : (i += 1) {
        counters[i].used = false;
        counters[i].name_len = 0;
    }
    counter_count = 0;
    initialized = true;

    // Register built-in counters
    idx_syscalls = registerCounter("syscalls_total", .monotonic);
    idx_ctx_switches = registerCounter("context_switches", .monotonic);
    idx_page_faults = registerCounter("page_faults", .monotonic);
    idx_interrupts = registerCounter("interrupts", .monotonic);
    idx_allocations = registerCounter("allocations", .monotonic);
    idx_frees = registerCounter("frees", .monotonic);

    // Register built-in gauges
    _ = registerCounter("active_tasks", .gauge);
    _ = registerCounter("free_pages", .gauge);

    // Register built-in histogram
    _ = registerCounter("syscall_latency_ms", .histogram);
}

// ---- Public API: Registration ----

/// Register a new named counter. Returns index or null if full.
pub fn registerCounter(name: []const u8, counter_type: CounterType) ?usize {
    ensureInit();
    if (name.len > MAX_NAME_LEN) return null;

    // Check for existing
    var i: usize = 0;
    while (i < counter_count) : (i += 1) {
        if (counters[i].used and counters[i].name_len == name.len and
            sliceEql(counters[i].name[0..counters[i].name_len], name))
        {
            return i;
        }
    }

    if (counter_count >= MAX_COUNTERS) return null;

    const idx = counter_count;
    counters[idx].used = true;
    counters[idx].name_len = @intCast(name.len);
    @memcpy(counters[idx].name[0..counters[idx].name_len], name[0..name.len]);
    initValue(&counters[idx].value, counter_type);
    counter_count += 1;
    return idx;
}

fn initValue(val: *CounterValue, ct: CounterType) void {
    val.counter_type = ct;
    val.monotonic_val = 0;
    val.gauge_val = 0;
    val.hist_count = 0;
    val.hist_sum = 0;
    val.hist_min = 0xFFFFFFFF;
    val.hist_max = 0;
    var i: usize = 0;
    while (i < HISTOGRAM_BUCKETS) : (i += 1) {
        val.hist_buckets[i] = 0;
    }
}

/// Find a counter by name. Returns index or null.
pub fn getCounter(name: []const u8) ?usize {
    ensureInit();
    var i: usize = 0;
    while (i < counter_count) : (i += 1) {
        if (counters[i].used and counters[i].name_len == name.len and
            sliceEql(counters[i].name[0..counters[i].name_len], name))
        {
            return i;
        }
    }
    return null;
}

// ---- Public API: Monotonic Counter operations ----

/// Increment a monotonic counter by 1.
pub fn increment(idx: usize) void {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return;
    counters[idx].value.monotonic_val += 1;
}

/// Increment a monotonic counter by n.
pub fn incrementBy(idx: usize, n: u64) void {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return;
    counters[idx].value.monotonic_val += n;
}

/// Get the value of a monotonic counter.
pub fn getValue(idx: usize) u64 {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return 0;
    return counters[idx].value.monotonic_val;
}

// ---- Public API: Gauge operations ----

/// Set a gauge value.
pub fn gaugeSet(idx: usize, val: i64) void {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return;
    counters[idx].value.gauge_val = val;
}

/// Increment a gauge by 1.
pub fn gaugeIncrement(idx: usize) void {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return;
    counters[idx].value.gauge_val += 1;
}

/// Decrement a gauge by 1.
pub fn gaugeDecrement(idx: usize) void {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return;
    counters[idx].value.gauge_val -= 1;
}

/// Get gauge value.
pub fn gaugeGetValue(idx: usize) i64 {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return 0;
    return counters[idx].value.gauge_val;
}

// ---- Public API: Histogram operations ----

/// Observe a value in a histogram.
pub fn observe(idx: usize, value: u32) void {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return;
    var val = &counters[idx].value;

    val.hist_count += 1;
    val.hist_sum += value;
    if (value < val.hist_min) val.hist_min = value;
    if (value > val.hist_max) val.hist_max = value;

    // Find bucket: [0,1), [1,2), [2,4), [4,8), [8,16), [16,32), [32,64), [64,inf)
    const bucket = getBucket(value);
    val.hist_buckets[bucket] += 1;
}

fn getBucket(value: u32) usize {
    if (value == 0) return 0;
    if (value < 2) return 1;
    if (value < 4) return 2;
    if (value < 8) return 3;
    if (value < 16) return 4;
    if (value < 32) return 5;
    if (value < 64) return 6;
    return 7;
}

/// Get the approximate percentile (0-100) from a histogram.
pub fn getPercentile(idx: usize, p: u32) u32 {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) return 0;
    const val = &counters[idx].value;
    if (val.hist_count == 0) return 0;

    const target: u32 = (val.hist_count * p + 99) / 100;
    var cumulative: u32 = 0;

    // Bucket upper bounds
    const bounds = [HISTOGRAM_BUCKETS]u32{ 1, 2, 4, 8, 16, 32, 64, 128 };

    var i: usize = 0;
    while (i < HISTOGRAM_BUCKETS) : (i += 1) {
        cumulative += val.hist_buckets[i];
        if (cumulative >= target) {
            return bounds[i];
        }
    }
    return val.hist_max;
}

/// Get histogram statistics.
pub fn getHistStats(idx: usize) struct { count: u32, sum: u64, min: u32, max: u32, avg: u32 } {
    ensureInit();
    if (idx >= MAX_COUNTERS or !counters[idx].used) {
        return .{ .count = 0, .sum = 0, .min = 0, .max = 0, .avg = 0 };
    }
    const val = &counters[idx].value;
    const avg: u32 = if (val.hist_count > 0) @truncate(val.hist_sum / val.hist_count) else 0;
    return .{
        .count = val.hist_count,
        .sum = val.hist_sum,
        .min = if (val.hist_min == 0xFFFFFFFF) 0 else val.hist_min,
        .max = val.hist_max,
        .avg = avg,
    };
}

// ---- Public API: Convenience for built-in counters ----

/// Record a syscall.
pub fn recordSyscall() void {
    if (idx_syscalls) |idx| increment(idx);
}

/// Record a context switch.
pub fn recordContextSwitch() void {
    if (idx_ctx_switches) |idx| increment(idx);
}

/// Record a page fault.
pub fn recordPageFault() void {
    if (idx_page_faults) |idx| increment(idx);
}

/// Record an interrupt.
pub fn recordInterrupt() void {
    if (idx_interrupts) |idx| increment(idx);
}

/// Record an allocation.
pub fn recordAllocation() void {
    if (idx_allocations) |idx| increment(idx);
}

/// Record a free.
pub fn recordFree() void {
    if (idx_frees) |idx| increment(idx);
}

// ---- Public API: Display ----

/// Print all counters to VGA.
pub fn printAll() void {
    ensureInit();

    vga.setColor(.light_cyan, .black);
    vga.write("Performance Counters:\n");
    vga.setColor(.yellow, .black);
    vga.write("  NAME                     TYPE       VALUE\n");
    vga.setColor(.dark_grey, .black);
    vga.write("  ----                     ----       -----\n");

    var i: usize = 0;
    while (i < counter_count) : (i += 1) {
        if (!counters[i].used) continue;

        vga.setColor(.light_grey, .black);
        vga.write("  ");
        vga.write(counters[i].name[0..counters[i].name_len]);

        // Pad name
        var pad = MAX_NAME_LEN -| counters[i].name_len;
        pad += 2;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');

        // Type
        vga.setColor(.dark_grey, .black);
        switch (counters[i].value.counter_type) {
            .monotonic => vga.write("counter    "),
            .gauge => vga.write("gauge      "),
            .histogram => vga.write("histogram  "),
        }

        // Value
        vga.setColor(.white, .black);
        switch (counters[i].value.counter_type) {
            .monotonic => {
                printU64(counters[i].value.monotonic_val);
            },
            .gauge => {
                if (counters[i].value.gauge_val < 0) {
                    vga.putChar('-');
                    printU64(@intCast(-counters[i].value.gauge_val));
                } else {
                    printU64(@intCast(counters[i].value.gauge_val));
                }
            },
            .histogram => {
                const stats = getHistStats(i);
                vga.write("n=");
                fmt.printDec(stats.count);
                vga.write(" avg=");
                fmt.printDec(stats.avg);
                vga.write(" min=");
                fmt.printDec(stats.min);
                vga.write(" max=");
                fmt.printDec(stats.max);
            },
        }
        vga.putChar('\n');
    }

    // Print histogram details
    i = 0;
    while (i < counter_count) : (i += 1) {
        if (!counters[i].used or counters[i].value.counter_type != .histogram) continue;
        if (counters[i].value.hist_count == 0) continue;

        vga.setColor(.light_cyan, .black);
        vga.write("\n  Histogram: ");
        vga.write(counters[i].name[0..counters[i].name_len]);
        vga.putChar('\n');

        printHistogram(&counters[i].value);
    }

    vga.setColor(.dark_grey, .black);
    vga.putChar('\n');
    fmt.printDec(counter_count);
    vga.write(" counters registered\n");
    vga.setColor(.light_grey, .black);
}

fn printHistogram(val: *const CounterValue) void {
    const labels = [HISTOGRAM_BUCKETS][]const u8{
        "   [0, 1)", "   [1, 2)", "   [2, 4)", "   [4, 8)",
        "  [8, 16)", " [16, 32)", " [32, 64)", "[64, inf)",
    };

    // Find max bucket for bar scaling
    var max_bucket: u32 = 1;
    var j: usize = 0;
    while (j < HISTOGRAM_BUCKETS) : (j += 1) {
        if (val.hist_buckets[j] > max_bucket) max_bucket = val.hist_buckets[j];
    }

    j = 0;
    while (j < HISTOGRAM_BUCKETS) : (j += 1) {
        vga.setColor(.dark_grey, .black);
        vga.write("    ");
        vga.write(labels[j]);
        vga.write(" ");

        // Bar
        const bar_width: u32 = if (max_bucket > 0) (val.hist_buckets[j] * 20) / max_bucket else 0;
        vga.setColor(.light_green, .black);
        var b: u32 = 0;
        while (b < bar_width) : (b += 1) {
            vga.putChar('#');
        }
        while (b < 20) : (b += 1) {
            vga.putChar(' ');
        }

        // Count
        vga.setColor(.light_grey, .black);
        vga.write(" ");
        fmt.printDec(val.hist_buckets[j]);
        vga.putChar('\n');
    }

    // Percentiles
    vga.setColor(.dark_grey, .black);
    vga.write("    p50=");
    fmt.printDec(getPercentileFromValue(val, 50));
    vga.write(" p90=");
    fmt.printDec(getPercentileFromValue(val, 90));
    vga.write(" p99=");
    fmt.printDec(getPercentileFromValue(val, 99));
    vga.putChar('\n');
}

fn getPercentileFromValue(val: *const CounterValue, p: u32) u32 {
    if (val.hist_count == 0) return 0;
    const target: u32 = (val.hist_count * p + 99) / 100;
    var cumulative: u32 = 0;
    const bounds = [HISTOGRAM_BUCKETS]u32{ 1, 2, 4, 8, 16, 32, 64, 128 };
    var i: usize = 0;
    while (i < HISTOGRAM_BUCKETS) : (i += 1) {
        cumulative += val.hist_buckets[i];
        if (cumulative >= target) return bounds[i];
    }
    return val.hist_max;
}

/// Reset all counters to zero.
pub fn resetAll() void {
    ensureInit();
    var i: usize = 0;
    while (i < counter_count) : (i += 1) {
        if (!counters[i].used) continue;
        initValue(&counters[i].value, counters[i].value.counter_type);
    }
}

/// Get total number of registered counters.
pub fn getCounterCount() usize {
    ensureInit();
    return counter_count;
}

fn printU64(val: u64) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
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

// ---- Utility ----

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
