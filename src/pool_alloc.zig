// Pool-based memory allocator -- fixed-size pool hierarchy
//
// Provides fast O(1) allocation from multiple fixed-size pools:
// 16, 32, 64, 128, 256, 512, 1024, 2048 bytes.
// Each pool uses bitmap-based free tracking backed by PMM pages.
// Guarantees 8-byte alignment. Automatically selects the smallest
// pool that satisfies the request, with fallback to larger pools.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const NUM_POOLS = 8;
pub const PAGE_SIZE = 4096;
pub const ALIGNMENT = 8;

/// Pool sizes in bytes
const POOL_SIZES = [NUM_POOLS]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

/// Number of objects per pool page
/// objects_per_pool[i] = PAGE_SIZE / POOL_SIZES[i]
/// (minus space for bitmap, but we keep bitmap separate)
const OBJECTS_PER_POOL = [NUM_POOLS]usize{
    PAGE_SIZE / 16, // 256
    PAGE_SIZE / 32, // 128
    PAGE_SIZE / 64, //  64
    PAGE_SIZE / 128, // 32
    PAGE_SIZE / 256, // 16
    PAGE_SIZE / 512, //  8
    PAGE_SIZE / 1024, // 4
    PAGE_SIZE / 2048, // 2
};

/// Maximum objects we track with bitmaps (max across all pools = 256)
const MAX_OBJECTS = 256;
const BITMAP_WORDS = (MAX_OBJECTS + 31) / 32;

// ---- Pool statistics ----

const PoolStats = struct {
    allocs: u64,
    frees: u64,
    current_usage: u32,
    peak_usage: u32,
    oom_count: u32, // out-of-memory attempts
};

// ---- Pool structure ----

const Pool = struct {
    active: bool,
    obj_size: usize,
    capacity: usize, // objects per pool
    base_addr: usize, // PMM-allocated page address
    bitmap: [BITMAP_WORDS]u32, // 1 = in use
    stats: PoolStats,
};

// ---- State ----

var pools: [NUM_POOLS]Pool = undefined;
var initialized: bool = false;
var total_allocs: u64 = 0;
var total_frees: u64 = 0;

// ---- Initialization ----

/// Initialize all pools. Each pool gets one PMM page.
pub fn init() void {
    for (&pools, 0..) |*pool, i| {
        pool.active = false;
        pool.obj_size = POOL_SIZES[i];
        pool.capacity = OBJECTS_PER_POOL[i];
        pool.base_addr = 0;
        for (&pool.bitmap) |*w| w.* = 0;
        pool.stats = .{
            .allocs = 0,
            .frees = 0,
            .current_usage = 0,
            .peak_usage = 0,
            .oom_count = 0,
        };

        // Allocate a page from PMM
        if (pmm.alloc()) |page| {
            pool.base_addr = page;
            pool.active = true;

            // Zero the page
            const ptr: [*]u8 = @ptrFromInt(page);
            for (0..PAGE_SIZE) |j| {
                ptr[j] = 0;
            }
        }
    }

    initialized = true;
    serial.write("[pool_alloc] initialized ");
    serialDec(NUM_POOLS);
    serial.write(" pools\n");
}

// ---- Allocation ----

/// Allocate memory of at least `size` bytes. Returns a pointer or null.
/// The allocation is taken from the smallest pool that fits.
/// Guarantees 8-byte alignment.
pub fn alloc(size: usize) ?[*]u8 {
    return allocInner(size, true);
}

/// Allocate and zero-initialize.
pub fn allocZeroed(size: usize) ?[*]u8 {
    const ptr = allocInner(size, true) orelse return null;
    const usable = getUsableSize(ptr);
    for (0..usable) |i| {
        ptr[i] = 0;
    }
    return ptr;
}

fn allocInner(size: usize, try_larger: bool) ?[*]u8 {
    if (!initialized or size == 0) return null;

    // Align size up to ALIGNMENT
    const aligned_size = (size + ALIGNMENT - 1) & ~@as(usize, ALIGNMENT - 1);

    // Find the smallest pool that fits
    var pool_idx: ?usize = null;
    for (0..NUM_POOLS) |i| {
        if (POOL_SIZES[i] >= aligned_size) {
            pool_idx = i;
            break;
        }
    }

    const start_idx = pool_idx orelse return null; // size too large

    // Try to allocate from the selected pool, then larger pools on failure
    var idx = start_idx;
    while (idx < NUM_POOLS) : (idx += 1) {
        if (allocFromPool(idx)) |ptr| {
            total_allocs += 1;
            return ptr;
        }
        if (!try_larger) break;
    }

    // All pools exhausted for this size
    if (start_idx < NUM_POOLS) {
        pools[start_idx].stats.oom_count += 1;
    }
    return null;
}

fn allocFromPool(pool_idx: usize) ?[*]u8 {
    if (pool_idx >= NUM_POOLS) return null;
    const pool = &pools[pool_idx];
    if (!pool.active) return null;

    // Find a free bit in the bitmap
    const cap = pool.capacity;
    const words_needed = (cap + 31) / 32;

    for (pool.bitmap[0..words_needed], 0..) |*word, wi| {
        if (word.* != 0xFFFFFFFF) {
            // Find first zero bit
            var bit: u5 = 0;
            while (true) : (bit += 1) {
                if (word.* & (@as(u32, 1) << bit) == 0) {
                    const obj_idx = wi * 32 + @as(usize, bit);
                    if (obj_idx >= cap) return null;

                    // Mark as used
                    word.* |= @as(u32, 1) << bit;

                    pool.stats.allocs += 1;
                    pool.stats.current_usage += 1;
                    if (pool.stats.current_usage > pool.stats.peak_usage) {
                        pool.stats.peak_usage = pool.stats.current_usage;
                    }

                    const addr = pool.base_addr + obj_idx * pool.obj_size;
                    return @ptrFromInt(addr);
                }
                if (bit == 31) break;
            }
        }
    }
    return null;
}

// ---- Deallocation ----

/// Free a previously allocated pointer back to its pool.
pub fn free(ptr: [*]u8) void {
    if (!initialized) return;

    const addr = @intFromPtr(ptr);

    // Find which pool this belongs to
    for (&pools) |*pool| {
        if (!pool.active) continue;
        if (addr < pool.base_addr) continue;

        const offset = addr - pool.base_addr;
        if (offset >= pool.capacity * pool.obj_size) continue;

        // Verify alignment
        if (offset % pool.obj_size != 0) continue;

        const obj_idx = offset / pool.obj_size;
        const word_idx = obj_idx / 32;
        const bit_idx: u5 = @truncate(obj_idx % 32);

        // Check if actually allocated
        if (pool.bitmap[word_idx] & (@as(u32, 1) << bit_idx) == 0) {
            serial.write("[pool_alloc] double free detected!\n");
            return;
        }

        // Clear the bit
        pool.bitmap[word_idx] &= ~(@as(u32, 1) << bit_idx);
        pool.stats.frees += 1;
        if (pool.stats.current_usage > 0) {
            pool.stats.current_usage -= 1;
        }
        total_frees += 1;
        return;
    }

    serial.write("[pool_alloc] free: pointer not found in any pool\n");
}

// ---- Reallocation ----

/// Resize an allocation. May move the data to a different pool.
/// Returns null if the new size cannot be satisfied.
pub fn realloc(ptr: [*]u8, new_size: usize) ?[*]u8 {
    if (!initialized) return null;
    if (new_size == 0) {
        free(ptr);
        return null;
    }

    const old_usable = getUsableSize(ptr);
    if (old_usable == 0) return null; // ptr not found

    // If new size fits in current pool, return same pointer
    if (new_size <= old_usable) return ptr;

    // Allocate from new pool
    const new_ptr = alloc(new_size) orelse return null;

    // Copy old data
    const copy_len = if (old_usable < new_size) old_usable else new_size;
    for (0..copy_len) |i| {
        new_ptr[i] = ptr[i];
    }

    // Free old allocation
    free(ptr);
    return new_ptr;
}

// ---- Query ----

/// Get the usable size of an allocation (the pool's object size).
pub fn getUsableSize(ptr: [*]u8) usize {
    if (!initialized) return 0;

    const addr = @intFromPtr(ptr);

    for (&pools) |*pool| {
        if (!pool.active) continue;
        if (addr < pool.base_addr) continue;

        const offset = addr - pool.base_addr;
        if (offset >= pool.capacity * pool.obj_size) continue;
        if (offset % pool.obj_size != 0) continue;

        return pool.obj_size;
    }
    return 0;
}

/// Get the pool index for a given size.
pub fn poolIndexForSize(size: usize) ?usize {
    const aligned = (size + ALIGNMENT - 1) & ~@as(usize, ALIGNMENT - 1);
    for (0..NUM_POOLS) |i| {
        if (POOL_SIZES[i] >= aligned) return i;
    }
    return null;
}

// ---- Statistics ----

/// Print statistics for all pools.
pub fn printStats() void {
    if (!initialized) {
        vga.write("Pool allocator not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Pool Allocator Statistics ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  Size    Cap   Used  Peak   Allocs   Frees    OOM   Active\n");
    vga.setColor(.light_grey, .black);

    for (&pools, 0..) |*pool, i| {
        vga.write("  ");
        fmt.printDecPadded(POOL_SIZES[i], 5);
        vga.write("  ");
        fmt.printDecPadded(pool.capacity, 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, pool.stats.current_usage), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, pool.stats.peak_usage), 4);
        vga.write("  ");
        printDec64Padded(pool.stats.allocs, 7);
        vga.write("  ");
        printDec64Padded(pool.stats.frees, 7);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, pool.stats.oom_count), 4);
        vga.write("  ");
        if (pool.active) {
            vga.setColor(.light_green, .black);
            vga.write("yes");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("no ");
        }
        vga.setColor(.light_grey, .black);
        vga.putChar('\n');
    }

    // Summary
    vga.setColor(.light_cyan, .black);
    vga.write("\nTotals: ");
    vga.setColor(.white, .black);
    printDec64(total_allocs);
    vga.write(" allocs, ");
    printDec64(total_frees);
    vga.write(" frees, ");
    printDec64(total_allocs - total_frees);
    vga.write(" in-use\n");

    // Memory usage
    vga.setColor(.light_grey, .black);
    vga.write("Pages used: ");
    var pages_used: usize = 0;
    for (&pools) |*pool| {
        if (pool.active) pages_used += 1;
    }
    fmt.printDec(pages_used);
    vga.write(" (");
    fmt.printDec(pages_used * PAGE_SIZE);
    vga.write(" bytes)\n");
}

/// Get pool info by index.
pub fn getPoolInfo(idx: usize) ?struct {
    obj_size: usize,
    capacity: usize,
    current: u32,
    peak: u32,
    active: bool,
} {
    if (idx >= NUM_POOLS) return null;
    const pool = &pools[idx];
    return .{
        .obj_size = pool.obj_size,
        .capacity = pool.capacity,
        .current = pool.stats.current_usage,
        .peak = pool.stats.peak_usage,
        .active = pool.active,
    };
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
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
