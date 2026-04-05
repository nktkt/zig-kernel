// Kernel profiler -- function-level timing and PC sampling
//
// Provides two profiling modes:
// 1. Instrumented profiling: bracket code sections with beginProfile/endProfile
//    to track call counts, total/min/max/average ticks per function.
// 2. Sampling profiler: periodically sample the program counter (EIP) from the
//    timer interrupt to build a histogram of where CPU time is spent.
//
// Supports up to 32 profiled functions and a 256-bucket PC histogram.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_PROFILES = 32;
pub const MAX_NAME_LEN = 24;
pub const HISTOGRAM_BUCKETS = 256;

/// Assume kernel text starts at 1MB and spans 1MB (for histogram bucketing)
const KERNEL_TEXT_BASE: u32 = 0x00100000;
const KERNEL_TEXT_SIZE: u32 = 0x00100000; // 1MB
const BUCKET_SIZE: u32 = KERNEL_TEXT_SIZE / HISTOGRAM_BUCKETS;

/// Hotspot threshold: flag functions using more than 10% of total ticks
const HOTSPOT_THRESHOLD_PERCENT: u64 = 10;

// ---- Profile entry ----

const ProfileEntry = struct {
    active: bool,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    call_count: u64,
    total_ticks: u64,
    min_ticks: u64,
    max_ticks: u64,
    // Tracking for in-progress measurement
    start_tick: u64,
    in_progress: bool,
};

// ---- Profile scope handle ----

pub const ScopeHandle = struct {
    id: u32,
    valid: bool,

    /// End the profiling scope. Should be called when the scope exits.
    pub fn end(self: *ScopeHandle) void {
        if (self.valid) {
            endProfile(self.id);
            self.valid = false;
        }
    }
};

// ---- State ----

var entries: [MAX_PROFILES]ProfileEntry = undefined;
var entry_count: u32 = 0;
var total_measured_ticks: u64 = 0;
var profiling_enabled: bool = false;
var initialized: bool = false;

// Sampling profiler state
var histogram: [HISTOGRAM_BUCKETS]u32 = undefined;
var total_samples: u64 = 0;
var sampling_enabled: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&entries) |*e| {
        e.active = false;
        e.name_len = 0;
        e.call_count = 0;
        e.total_ticks = 0;
        e.min_ticks = 0;
        e.max_ticks = 0;
        e.start_tick = 0;
        e.in_progress = false;
        for (&e.name) |*c| c.* = 0;
    }
    entry_count = 0;
    total_measured_ticks = 0;
    profiling_enabled = true;
    initialized = true;

    // Clear histogram
    for (&histogram) |*h| h.* = 0;
    total_samples = 0;
    sampling_enabled = false;

    serial.write("[profiler] initialized, ");
    serialDec(MAX_PROFILES);
    serial.write(" slots, ");
    serialDec(HISTOGRAM_BUCKETS);
    serial.write(" histogram buckets\n");
}

// ---- Instrumented profiling ----

/// Begin profiling a named code section. Returns a profile ID.
/// If the name already exists, reuses that entry. Otherwise creates new.
pub fn beginProfile(name: []const u8) u32 {
    if (!initialized or !profiling_enabled) return 0;

    const id = findOrCreate(name) orelse return 0;
    const entry = &entries[id];

    entry.start_tick = pit.getTicks();
    entry.in_progress = true;

    return id;
}

/// End profiling for the given ID. Accumulates timing statistics.
pub fn endProfile(id: u32) void {
    if (!initialized or !profiling_enabled) return;
    if (id >= MAX_PROFILES) return;

    const entry = &entries[id];
    if (!entry.active or !entry.in_progress) return;

    const end_tick = pit.getTicks();
    const elapsed = if (end_tick >= entry.start_tick) end_tick - entry.start_tick else 0;

    entry.call_count += 1;
    entry.total_ticks += elapsed;
    total_measured_ticks += elapsed;

    // Update min/max
    if (entry.call_count == 1) {
        entry.min_ticks = elapsed;
        entry.max_ticks = elapsed;
    } else {
        if (elapsed < entry.min_ticks) entry.min_ticks = elapsed;
        if (elapsed > entry.max_ticks) entry.max_ticks = elapsed;
    }

    entry.in_progress = false;
}

/// Begin a profiling scope that auto-ends. Returns a handle.
/// Usage: var scope = profiler.profileScope("my_func"); defer scope.end();
pub fn profileScope(name: []const u8) ScopeHandle {
    if (!initialized or !profiling_enabled) {
        return .{ .id = 0, .valid = false };
    }
    const id = beginProfile(name);
    return .{ .id = id, .valid = true };
}

/// Reset all profile entries.
pub fn resetAll() void {
    for (&entries) |*e| {
        if (e.active) {
            e.call_count = 0;
            e.total_ticks = 0;
            e.min_ticks = 0;
            e.max_ticks = 0;
            e.in_progress = false;
        }
    }
    total_measured_ticks = 0;
    serial.write("[profiler] all profiles reset\n");
}

/// Enable/disable profiling.
pub fn setEnabled(en: bool) void {
    profiling_enabled = en;
}

/// Check if profiling is enabled.
pub fn isEnabled() bool {
    return profiling_enabled;
}

fn findOrCreate(name: []const u8) ?u32 {
    // Search for existing entry
    for (&entries, 0..) |*e, i| {
        if (e.active and e.name_len == name.len) {
            if (strEq(e.name[0..e.name_len], name)) {
                return @truncate(i);
            }
        }
    }

    // Create new entry
    if (entry_count >= MAX_PROFILES) return null;

    for (&entries, 0..) |*e, i| {
        if (!e.active) {
            e.active = true;
            const copy_len = if (name.len > MAX_NAME_LEN) MAX_NAME_LEN else name.len;
            for (0..copy_len) |j| {
                e.name[j] = name[j];
            }
            var k: usize = copy_len;
            while (k < MAX_NAME_LEN) : (k += 1) {
                e.name[k] = 0;
            }
            e.name_len = @truncate(copy_len);
            e.call_count = 0;
            e.total_ticks = 0;
            e.min_ticks = 0;
            e.max_ticks = 0;
            e.in_progress = false;
            entry_count += 1;
            return @truncate(i);
        }
    }
    return null;
}

// ---- Reporting ----

/// Print the profiling report sorted by total_ticks descending.
pub fn printReport() void {
    if (!initialized) {
        vga.write("Profiler not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Profiler Report ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  Name                     Calls     Total       Min       Max       Avg     %\n");
    vga.setColor(.light_grey, .black);

    // Build sorted index array (by total_ticks descending)
    var sorted: [MAX_PROFILES]u8 = undefined;
    var count: u8 = 0;
    for (0..MAX_PROFILES) |i| {
        if (entries[i].active) {
            sorted[count] = @truncate(i);
            count += 1;
        }
    }

    // Insertion sort descending
    if (count > 1) {
        var i: u8 = 1;
        while (i < count) : (i += 1) {
            const key = sorted[i];
            const key_ticks = entries[key].total_ticks;
            var j: u8 = i;
            while (j > 0 and entries[sorted[j - 1]].total_ticks < key_ticks) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }
    }

    // Print entries
    var idx: u8 = 0;
    while (idx < count) : (idx += 1) {
        const e = &entries[sorted[idx]];

        // Hotspot marker
        const pct = if (total_measured_ticks > 0)
            (e.total_ticks * 100) / total_measured_ticks
        else
            0;

        if (pct >= HOTSPOT_THRESHOLD_PERCENT) {
            vga.setColor(.light_red, .black);
            vga.write("* ");
        } else {
            vga.setColor(.light_grey, .black);
            vga.write("  ");
        }

        // Name (padded to 24 chars)
        printNamePadded(&e.name, e.name_len, MAX_NAME_LEN);
        vga.write(" ");

        // Calls
        printDec64Padded(e.call_count, 8);
        vga.write(" ");

        // Total ticks
        printDec64Padded(e.total_ticks, 9);
        vga.write(" ");

        // Min ticks
        printDec64Padded(e.min_ticks, 9);
        vga.write(" ");

        // Max ticks
        printDec64Padded(e.max_ticks, 9);
        vga.write(" ");

        // Average
        const avg = if (e.call_count > 0) e.total_ticks / e.call_count else 0;
        printDec64Padded(avg, 9);
        vga.write(" ");

        // Percentage
        fmt.printDecPadded(@as(usize, @truncate(pct)), 3);
        vga.putChar('%');

        vga.putChar('\n');
    }

    if (count == 0) {
        vga.write("  (no profiled functions)\n");
    }

    vga.setColor(.light_grey, .black);
    vga.write("\nTotal measured ticks: ");
    printDec64(total_measured_ticks);
    vga.write("\nHotspots marked with * (>");
    fmt.printDec(@as(usize, HOTSPOT_THRESHOLD_PERCENT));
    vga.write("% of total)\n");
}

// ---- Sampling profiler ----

/// Enable the sampling profiler (call samplePC from timer interrupt).
pub fn enableSampling() void {
    sampling_enabled = true;
}

/// Disable the sampling profiler.
pub fn disableSampling() void {
    sampling_enabled = false;
}

/// Record a sample of the current program counter.
/// Should be called from the timer interrupt handler with the interrupted EIP.
pub fn samplePC(eip: u32) void {
    if (!initialized or !sampling_enabled) return;

    // Map EIP to histogram bucket
    if (eip < KERNEL_TEXT_BASE) return;
    const offset = eip - KERNEL_TEXT_BASE;
    if (offset >= KERNEL_TEXT_SIZE) return;

    const bucket = offset / BUCKET_SIZE;
    if (bucket < HISTOGRAM_BUCKETS) {
        histogram[bucket] += 1;
        total_samples += 1;
    }
}

/// Reset the sampling histogram.
pub fn resetHistogram() void {
    for (&histogram) |*h| h.* = 0;
    total_samples = 0;
}

/// Print the PC histogram showing where CPU time is spent.
pub fn printHistogram() void {
    if (!initialized) {
        vga.write("Profiler not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== PC Sampling Histogram ===\n");
    vga.setColor(.light_grey, .black);
    vga.write("Total samples: ");
    printDec64(total_samples);
    vga.write("\n\n");

    if (total_samples == 0) {
        vga.write("  (no samples collected)\n");
        return;
    }

    // Find max count for scaling the bar chart
    var max_count: u32 = 0;
    for (&histogram) |h| {
        if (h > max_count) max_count = h;
    }
    if (max_count == 0) return;

    // Print non-zero buckets
    vga.setColor(.yellow, .black);
    vga.write("  Address Range          Count   Bar\n");
    vga.setColor(.light_grey, .black);

    var printed: usize = 0;
    for (&histogram, 0..) |h, bucket| {
        if (h == 0) continue;
        if (printed >= 20) {
            // Only show top 20 to avoid flooding the screen
            vga.write("  ... (");
            fmt.printDec(countNonZero());
            vga.write(" total active buckets)\n");
            break;
        }

        const addr_start = KERNEL_TEXT_BASE + @as(u32, @truncate(bucket)) * BUCKET_SIZE;
        const addr_end = addr_start + BUCKET_SIZE - 1;

        vga.write("  0x");
        fmt.printHex32(addr_start);
        vga.write("-0x");
        fmt.printHex32(addr_end);
        vga.write(" ");
        fmt.printDecPadded(@as(usize, h), 6);
        vga.write("  ");

        // Bar (scaled to max 32 chars)
        const bar_len = (@as(u64, h) * 32) / @as(u64, max_count);
        var b: u64 = 0;
        while (b < bar_len) : (b += 1) {
            vga.putChar('#');
        }
        vga.putChar('\n');
        printed += 1;
    }
}

fn countNonZero() usize {
    var count: usize = 0;
    for (&histogram) |h| {
        if (h > 0) count += 1;
    }
    return count;
}

// ---- Helper functions ----

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn printNamePadded(name: []const u8, name_len: u8, width: usize) void {
    var printed: usize = 0;
    if (name_len > 0) {
        const len = @as(usize, name_len);
        const to_print = if (len > width) width else len;
        vga.write(name[0..to_print]);
        printed = to_print;
    }
    while (printed < width) : (printed += 1) {
        vga.putChar(' ');
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

fn serialDec(n: usize) void {
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
