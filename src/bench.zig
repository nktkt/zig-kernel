// Benchmark Suite -- Performance measurement for kernel subsystems
// Uses PIT ticks for timing. Runs built-in benchmarks and reports ops/sec.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const crypto = @import("crypto.zig");
const sort = @import("sort.zig");
const string = @import("string.zig");
const math = @import("math.zig");
const ramfs = @import("ramfs.zig");

// ---- Types ----

pub const BenchResult = struct {
    name: []const u8,
    iterations: u32,
    elapsed_ticks: u64,
    result: u32, // opaque result to prevent dead-code elimination
};

const BenchFn = *const fn (u32) u32;

const BenchEntry = struct {
    name: []const u8,
    func: BenchFn,
    default_iters: u32,
};

// ---- Core Runner ----

/// Run a named benchmark for `iterations` iterations.
pub fn run(name: []const u8, iterations: u32, func: BenchFn) BenchResult {
    // Warm up (1 iteration)
    _ = func(1);

    const start = pit.getTicks();
    const result = func(iterations);
    const end = pit.getTicks();

    return BenchResult{
        .name = name,
        .iterations = iterations,
        .elapsed_ticks = end - start,
        .result = result,
    };
}

/// Print a benchmark result with ops/sec.
pub fn printResult(r: BenchResult) void {
    vga.setColor(.light_cyan, .black);
    vga.write("  ");
    // Pad name to 20 chars
    var name_len: usize = 0;
    for (r.name) |c| {
        vga.putChar(c);
        name_len += 1;
    }
    while (name_len < 20) : (name_len += 1) {
        vga.putChar(' ');
    }

    vga.setColor(.light_grey, .black);

    // Print iterations
    printDec32(r.iterations);
    vga.write(" iters  ");

    // Print elapsed ticks
    printDec64(r.elapsed_ticks);
    vga.write(" ticks  ");

    // Calculate ops/sec (ticks are ~1ms each, so 1000 ticks = 1 second)
    if (r.elapsed_ticks > 0) {
        // ops_per_sec = iterations * 1000 / elapsed_ticks
        const ops: u64 = @as(u64, r.iterations) * 1000 / r.elapsed_ticks;
        printDec64(ops);
        vga.write(" ops/s");
    } else {
        vga.write("(instant)");
    }

    vga.putChar('\n');
}

// ---- Built-in Benchmarks ----

const all_benchmarks = [_]BenchEntry{
    .{ .name = "memcpy_4k", .func = bench_memcpy, .default_iters = 1000 },
    .{ .name = "pmm_alloc_free", .func = bench_alloc, .default_iters = 500 },
    .{ .name = "heap_alloc_free", .func = bench_heap, .default_iters = 500 },
    .{ .name = "crc32_1k", .func = bench_hash, .default_iters = 1000 },
    .{ .name = "sort_64", .func = bench_sort, .default_iters = 500 },
    .{ .name = "string_ops", .func = bench_string, .default_iters = 1000 },
    .{ .name = "math_sqrt", .func = bench_math, .default_iters = 500 },
    .{ .name = "ramfs_crud", .func = bench_fs, .default_iters = 200 },
};

/// Run all built-in benchmarks and print results.
pub fn runAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Benchmark Suite ===\n");
    vga.setColor(.light_grey, .black);

    var results: [all_benchmarks.len]BenchResult = undefined;

    for (all_benchmarks, 0..) |entry, i| {
        results[i] = run(entry.name, entry.default_iters, entry.func);
        printResult(results[i]);
    }

    // Sort results by elapsed ticks (fastest first) using simple selection sort
    var sorted_indices: [all_benchmarks.len]usize = undefined;
    for (0..all_benchmarks.len) |i| {
        sorted_indices[i] = i;
    }
    for (0..all_benchmarks.len) |i| {
        var min_idx = i;
        for (i + 1..all_benchmarks.len) |j| {
            if (results[sorted_indices[j]].elapsed_ticks < results[sorted_indices[min_idx]].elapsed_ticks) {
                min_idx = j;
            }
        }
        if (min_idx != i) {
            const tmp = sorted_indices[i];
            sorted_indices[i] = sorted_indices[min_idx];
            sorted_indices[min_idx] = tmp;
        }
    }

    vga.setColor(.yellow, .black);
    vga.write("\nRanking (fastest first):\n");
    vga.setColor(.light_grey, .black);
    for (sorted_indices, 0..) |idx, rank| {
        vga.write("  ");
        printDec32(@truncate(rank + 1));
        vga.write(". ");
        vga.write(results[idx].name);
        vga.putChar('\n');
    }
}

// ---- Benchmark Implementations ----

/// bench_memcpy: Copy a 4KB block N times.
fn bench_memcpy(iterations: u32) u32 {
    var src: [4096]u8 = undefined;
    var dst: [4096]u8 = undefined;

    // Fill source
    for (&src, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    var checksum: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        string.memcpy(&dst, &src, 4096);
        checksum +%= dst[0];
    }
    return checksum;
}

/// bench_alloc: PMM alloc + free N times.
fn bench_alloc(iterations: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        if (pmm.alloc()) |addr| {
            count +%= 1;
            pmm.free(addr);
        }
    }
    return count;
}

/// bench_heap: Heap alloc + free N times.
fn bench_heap(iterations: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        if (heap.alloc(64)) |ptr| {
            count +%= 1;
            heap.free(ptr);
        }
    }
    return count;
}

/// bench_hash: CRC32 of 1KB data N times.
fn bench_hash(iterations: u32) u32 {
    var data: [1024]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    var result: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        result ^= crypto.crc32(&data);
    }
    return result;
}

/// bench_sort: Sort 64 pseudo-random numbers N times.
fn bench_sort(iterations: u32) u32 {
    var checksum: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var arr: [64]u32 = undefined;
        // Generate pseudo-random data using LCG inline
        var seed: u32 = 12345 +% i;
        for (&arr) |*v| {
            seed = seed *% 1664525 +% 1013904223;
            v.* = seed;
        }
        sort.quickSort(&arr);
        checksum +%= arr[0];
    }
    return checksum;
}

/// bench_string: strlen/strcmp operations N times.
fn bench_string(iterations: u32) u32 {
    const test_str = "The quick brown fox jumps over the lazy dog";
    const cmp_str = "The quick brown fox jumps over the lazy cat";
    var result: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // strlen on a slice using our kernel string module
        const a: []const u8 = test_str;
        const b: []const u8 = cmp_str;
        const cmp = string.strcmp(a, b);
        result +%= @bitCast(cmp);
        if (string.contains(test_str, "fox")) {
            result +%= 1;
        }
    }
    return result;
}

/// bench_math: sqrt_int for numbers 1-1000.
fn bench_math(iterations: u32) u32 {
    var result: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var n: u32 = 1;
        while (n <= 1000) : (n += 1) {
            result +%= math.sqrt_int(n);
        }
    }
    return result;
}

/// bench_fs: ramfs create + write + read + delete.
fn bench_fs(iterations: u32) u32 {
    var count: u32 = 0;
    const test_data = "Benchmark test data for ramfs operations.";
    var read_buf: [64]u8 = undefined;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Create
        if (ramfs.createFile("_bench_tmp", 0)) |idx| {
            // Write
            _ = ramfs.writeFile(idx, test_data);
            // Read
            const rlen = ramfs.readFile(idx, &read_buf);
            count +%= @truncate(rlen);
            // Delete
            ramfs.remove(idx);
        }
    }
    return count;
}

// ---- Single Benchmark Runner ----

/// Run a single benchmark by name.
pub fn runByName(name: []const u8) void {
    for (all_benchmarks) |entry| {
        if (eql(entry.name, name)) {
            const result = run(entry.name, entry.default_iters, entry.func);
            printResult(result);
            return;
        }
    }
    vga.write("Unknown benchmark: ");
    vga.write(name);
    vga.putChar('\n');
    vga.write("Available: ");
    for (all_benchmarks, 0..) |entry, i| {
        if (i > 0) vga.write(", ");
        vga.write(entry.name);
    }
    vga.putChar('\n');
}

/// List all available benchmarks.
pub fn listAll() void {
    vga.setColor(.yellow, .black);
    vga.write("Available benchmarks:\n");
    vga.setColor(.light_grey, .black);
    for (all_benchmarks) |entry| {
        vga.write("  ");
        vga.write(entry.name);
        vga.write(" (");
        printDec32(entry.default_iters);
        vga.write(" iters)\n");
    }
}

// ---- Helpers ----

fn printDec32(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val: u32 = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val: u64 = n;
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

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
