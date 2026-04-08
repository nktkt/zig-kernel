// Page cache for disk blocks — read-through cache with LRU eviction
//
// Caches up to 32 disk block pages in memory. Supports dirty-page tracking,
// sync to disk, per-device invalidation, read-ahead, and hit/miss statistics.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const blkdev = @import("blkdev.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_CACHED_PAGES: usize = 32;
const PAGE_SIZE: usize = 4096;
const BLOCK_SIZE: usize = 512;
const BLOCKS_PER_PAGE: u8 = 8; // PAGE_SIZE / BLOCK_SIZE
const READ_AHEAD_MAX: usize = 8; // Max blocks to read ahead

// ============================================================
// Types
// ============================================================

pub const CachePage = struct {
    device_id: u8 = 0,
    block_num: u32 = 0,
    data: [PAGE_SIZE]u8 = @splat(0),
    dirty: bool = false,
    ref_count: u16 = 0,
    access_time: u64 = 0, // Last access tick for LRU
    valid: bool = false,
    locked: bool = false, // Locked pages cannot be evicted
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    evictions: u64 = 0,
    dirty_writebacks: u64 = 0,
    read_aheads: u64 = 0,
    read_errors: u64 = 0,
    write_errors: u64 = 0,
};

// ============================================================
// State
// ============================================================

var pages: [MAX_CACHED_PAGES]CachePage = [_]CachePage{.{}} ** MAX_CACHED_PAGES;
var page_count: usize = 0;
var stats: Stats = .{};

// ============================================================
// Public API
// ============================================================

/// Get a cached page for the given device and block. Reads from disk if not cached.
/// Returns a pointer to the cache page, or null on error.
pub fn getPage(dev: u8, block: u32) ?*CachePage {
    const now = pit.getTicks();

    // Check cache first
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev and p.block_num == block) {
            p.access_time = now;
            p.ref_count += 1;
            stats.hits += 1;
            return p;
        }
    }

    // Cache miss — need to read from disk
    stats.misses += 1;

    // Find a free page or evict LRU
    const slot = findFreePage() orelse evictLru() orelse return null;
    var p = &pages[slot];

    // Read from disk
    if (!readBlockFromDisk(dev, block, &p.data)) {
        stats.read_errors += 1;
        return null;
    }

    p.device_id = dev;
    p.block_num = block;
    p.dirty = false;
    p.ref_count = 1;
    p.access_time = now;
    p.valid = true;
    p.locked = false;

    if (slot >= page_count) {
        page_count = slot + 1;
    }

    stats.reads += 1;
    return p;
}

/// Mark a cached block as dirty.
pub fn markDirty(dev: u8, block: u32) void {
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev and p.block_num == block) {
            p.dirty = true;
            return;
        }
    }
}

/// Write data into a cached page (write-back).
pub fn writePage(dev: u8, block: u32, data: []const u8) bool {
    // Get or create cache entry
    const p = getPage(dev, block) orelse return false;

    const copy_len = if (data.len > PAGE_SIZE) PAGE_SIZE else data.len;
    @memcpy(p.data[0..copy_len], data[0..copy_len]);
    p.dirty = true;
    stats.writes += 1;
    return true;
}

/// Release a reference to a cache page.
pub fn releasePage(dev: u8, block: u32) void {
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev and p.block_num == block) {
            if (p.ref_count > 0) p.ref_count -= 1;
            return;
        }
    }
}

/// Lock a page so it cannot be evicted.
pub fn lockPage(dev: u8, block: u32) void {
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev and p.block_num == block) {
            p.locked = true;
            return;
        }
    }
}

/// Unlock a page.
pub fn unlockPage(dev: u8, block: u32) void {
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev and p.block_num == block) {
            p.locked = false;
            return;
        }
    }
}

/// Sync all dirty pages to disk.
pub fn sync() void {
    for (&pages) |*p| {
        if (p.valid and p.dirty) {
            writeBackPage(p);
        }
    }
}

/// Sync dirty pages for a specific device.
pub fn syncDevice(dev: u8) void {
    for (&pages) |*p| {
        if (p.valid and p.dirty and p.device_id == dev) {
            writeBackPage(p);
        }
    }
}

/// Invalidate a specific cached block (discard without writing back).
pub fn invalidate(dev: u8, block: u32) void {
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev and p.block_num == block) {
            p.valid = false;
            p.dirty = false;
            return;
        }
    }
}

/// Invalidate all cached blocks for a device.
pub fn invalidateDevice(dev: u8) void {
    for (&pages) |*p| {
        if (p.valid and p.device_id == dev) {
            if (p.dirty) {
                writeBackPage(p);
            }
            p.valid = false;
        }
    }
}

/// Read-ahead: prefetch consecutive blocks into cache.
pub fn readAhead(dev: u8, block: u32, count_req: u32) void {
    const actual_count = if (count_req > READ_AHEAD_MAX) READ_AHEAD_MAX else count_req;
    var i: u32 = 0;
    while (i < actual_count) : (i += 1) {
        const target_block = block + i;

        // Skip if already cached
        var found = false;
        for (&pages) |*p| {
            if (p.valid and p.device_id == dev and p.block_num == target_block) {
                found = true;
                break;
            }
        }
        if (found) continue;

        // Try to cache it
        _ = getPage(dev, target_block);
        stats.read_aheads += 1;
    }
}

/// Get count of dirty pages.
pub fn dirtyPageCount() usize {
    var count: usize = 0;
    for (&pages) |*p| {
        if (p.valid and p.dirty) count += 1;
    }
    return count;
}

/// Get count of cached pages.
pub fn cachedPageCount() usize {
    var count: usize = 0;
    for (&pages) |*p| {
        if (p.valid) count += 1;
    }
    return count;
}

/// Get statistics.
pub fn getCacheStats() Stats {
    return stats;
}

/// Reset statistics.
pub fn resetCacheStats() void {
    stats = .{};
}

/// Flush all pages (sync + invalidate).
pub fn flushAll() void {
    sync();
    for (&pages) |*p| {
        p.valid = false;
    }
    page_count = 0;
}

// ============================================================
// Display
// ============================================================

/// Print cache statistics.
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("Page Cache Statistics:\n\n");
    vga.setColor(.light_grey, .black);

    // Summary
    const cached = cachedPageCount();
    const dirty = dirtyPageCount();
    vga.write("  Cached pages:      ");
    printDec(cached);
    vga.write("/");
    printDec(MAX_CACHED_PAGES);
    vga.putChar('\n');
    vga.write("  Dirty pages:       ");
    printDec(dirty);
    vga.putChar('\n');
    vga.write("  Memory used:       ");
    printDec(cached * PAGE_SIZE / 1024);
    vga.write(" KB\n");

    // Usage bar
    vga.write("  ");
    printBar(cached, MAX_CACHED_PAGES, 40);
    vga.putChar('\n');

    // Counters
    vga.write("\n  Hits:              ");
    printDec64(stats.hits);
    vga.putChar('\n');
    vga.write("  Misses:            ");
    printDec64(stats.misses);
    vga.putChar('\n');
    vga.write("  Reads:             ");
    printDec64(stats.reads);
    vga.putChar('\n');
    vga.write("  Writes:            ");
    printDec64(stats.writes);
    vga.putChar('\n');
    vga.write("  Evictions:         ");
    printDec64(stats.evictions);
    vga.putChar('\n');
    vga.write("  Dirty writebacks:  ");
    printDec64(stats.dirty_writebacks);
    vga.putChar('\n');
    vga.write("  Read-aheads:       ");
    printDec64(stats.read_aheads);
    vga.putChar('\n');
    vga.write("  Read errors:       ");
    printDec64(stats.read_errors);
    vga.putChar('\n');
    vga.write("  Write errors:      ");
    printDec64(stats.write_errors);
    vga.putChar('\n');

    // Hit rate
    if (stats.hits + stats.misses > 0) {
        const total = stats.hits + stats.misses;
        const pct = (stats.hits * 100) / total;
        vga.write("  Hit rate:          ");
        printDec64(pct);
        vga.write("%\n");
    }

    // Per-page details
    vga.setColor(.yellow, .black);
    vga.write("\nCached Pages:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Dev  Block     Dirty  Refs  Locked  Age(s)\n");
    vga.write("  ---  --------  -----  ----  ------  ------\n");

    const now = pit.getTicks();
    for (&pages) |*p| {
        if (!p.valid) continue;

        vga.write("  ");
        printDecPadded(@as(u64, p.device_id), 3);
        vga.write("  ");
        printDecPadded(p.block_num, 8);
        vga.write("  ");
        if (p.dirty) {
            vga.write("yes  ");
        } else {
            vga.write("no   ");
        }
        vga.write(" ");
        printDecPadded(p.ref_count, 4);
        vga.write("  ");
        if (p.locked) {
            vga.write("yes   ");
        } else {
            vga.write("no    ");
        }
        const age_secs = (now -| p.access_time) / 1000;
        printDecPadded(age_secs, 6);
        vga.putChar('\n');
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn findFreePage() ?usize {
    for (&pages, 0..) |*p, i| {
        if (!p.valid) return i;
    }
    return null;
}

fn evictLru() ?usize {
    var lru_idx: ?usize = null;
    var lru_time: u64 = ~@as(u64, 0);

    for (&pages, 0..) |*p, i| {
        if (!p.valid) return i; // found free anyway
        if (p.locked) continue; // cannot evict locked pages
        if (p.ref_count > 0) continue; // still in use

        if (p.access_time < lru_time) {
            lru_time = p.access_time;
            lru_idx = i;
        }
    }

    // If all have refs, try to evict lowest ref_count
    if (lru_idx == null) {
        var min_refs: u16 = ~@as(u16, 0);
        for (&pages, 0..) |*p, i| {
            if (!p.valid or p.locked) continue;
            if (p.ref_count < min_refs) {
                min_refs = p.ref_count;
                lru_idx = i;
            }
        }
    }

    if (lru_idx) |idx| {
        var p = &pages[idx];
        if (p.dirty) {
            writeBackPage(p);
        }
        p.valid = false;
        stats.evictions += 1;
        return idx;
    }

    return null;
}

fn writeBackPage(p: *CachePage) void {
    if (writeBlockToDisk(p.device_id, p.block_num, &p.data)) {
        p.dirty = false;
        stats.dirty_writebacks += 1;
    } else {
        stats.write_errors += 1;
    }
}

fn readBlockFromDisk(dev: u8, block: u32, data: *[PAGE_SIZE]u8) bool {
    // Read BLOCKS_PER_PAGE sectors
    return blkdev.read(dev, block * BLOCKS_PER_PAGE, BLOCKS_PER_PAGE, @ptrCast(data));
}

fn writeBlockToDisk(dev: u8, block: u32, data: *const [PAGE_SIZE]u8) bool {
    return blkdev.write(dev, block * BLOCKS_PER_PAGE, BLOCKS_PER_PAGE, @ptrCast(data));
}

fn printBar(used: usize, total: usize, width: usize) void {
    if (total == 0) return;
    const filled = (used * width) / total;
    vga.putChar('[');
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            vga.putChar('#');
        } else {
            vga.putChar('-');
        }
    }
    vga.putChar(']');
}

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

fn printDec64(n: u64) void {
    printDec(n);
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
