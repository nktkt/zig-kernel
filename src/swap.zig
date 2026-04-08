// Swap space management — page swapping to disk with clock algorithm
//
// Manages swap areas on block devices. Tracks which physical pages are
// swapped out, allocates swap slots, and implements the second-chance
// (clock) page replacement algorithm.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const blkdev = @import("blkdev.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_SWAP_PAGES: usize = 256;
const PAGE_SIZE: usize = 4096;
const SECTORS_PER_PAGE: u8 = 8; // 4096 / 512
const MAX_SWAP_AREAS: usize = 2;

// ============================================================
// Types
// ============================================================

pub const SwapSlot = struct {
    used: bool = false,
    phys_page: u32 = 0, // Physical page address that was swapped out
    dirty: bool = false, // Dirty flag (modified since swap out)
};

pub const SwapArea = struct {
    device_id: u8 = 0,
    start_sector: u32 = 0,
    size_sectors: u32 = 0,
    total_slots: u32 = 0,
    used_slots: u32 = 0,
    priority: i8 = 0, // Higher = preferred
    active: bool = false,
};

pub const SwapInfo = struct {
    total: u32 = 0, // Total swap slots
    used: u32 = 0, // Used swap slots
    free: u32 = 0, // Free swap slots
    total_bytes: u64 = 0,
    used_bytes: u64 = 0,
};

pub const Stats = struct {
    swap_outs: u64 = 0, // Pages written to swap
    swap_ins: u64 = 0, // Pages read from swap
    page_faults: u64 = 0,
    reclaims: u64 = 0, // Pages reclaimed by clock algorithm
    write_errors: u64 = 0,
    read_errors: u64 = 0,
};

// Page frame entry for clock algorithm
const PageFrame = struct {
    phys_addr: u32 = 0,
    referenced: bool = false, // R bit for clock algorithm
    valid: bool = false,
    swap_slot: u32 = 0, // If swapped, which slot
    swapped: bool = false,
};

// ============================================================
// State
// ============================================================

var swap_map: [MAX_SWAP_PAGES]SwapSlot = [_]SwapSlot{.{}} ** MAX_SWAP_PAGES;
var swap_areas: [MAX_SWAP_AREAS]SwapArea = [_]SwapArea{.{}} ** MAX_SWAP_AREAS;
var area_count: usize = 0;
var stats: Stats = .{};

// Clock algorithm state
const MAX_PAGE_FRAMES: usize = 64;
var page_frames: [MAX_PAGE_FRAMES]PageFrame = [_]PageFrame{.{}} ** MAX_PAGE_FRAMES;
var clock_hand: usize = 0;
var frame_count: usize = 0;

var initialized: bool = false;

// ============================================================
// Public API
// ============================================================

/// Initialize swap with a device and sector range.
pub fn init(device_id: u8, start_sector: u32, size_sectors: u32) void {
    if (area_count >= MAX_SWAP_AREAS) return;
    if (size_sectors == 0) return;

    var area = &swap_areas[area_count];
    area.device_id = device_id;
    area.start_sector = start_sector;
    area.size_sectors = size_sectors;
    area.total_slots = size_sectors / SECTORS_PER_PAGE;
    if (area.total_slots > MAX_SWAP_PAGES) area.total_slots = MAX_SWAP_PAGES;
    area.used_slots = 0;
    area.priority = @intCast(area_count);
    area.active = true;

    area_count += 1;

    // Initialize swap map slots for this area
    for (&swap_map) |*slot| {
        slot.used = false;
    }

    initialized = true;

    serial.write("[SWAP] initialized: ");
    serialPrintDec(size_sectors);
    serial.write(" sectors (");
    serialPrintDec(area.total_slots);
    serial.write(" pages)\n");
}

/// Swap out a physical page to disk. Returns the swap slot number.
pub fn swapOut(phys_page: u32) ?u32 {
    if (!initialized) return null;

    // Find a free swap slot
    const slot = allocSlot() orelse return null;

    // Write page to disk
    if (!writePage(slot, phys_page)) {
        swap_map[slot].used = false;
        stats.write_errors += 1;
        return null;
    }

    swap_map[slot].phys_page = phys_page;
    swap_map[slot].dirty = false;
    stats.swap_outs += 1;

    return @intCast(slot);
}

/// Swap in a page from disk to a physical address. Returns true on success.
pub fn swapIn(slot: u32, phys_page: u32) bool {
    if (!initialized) return false;
    if (slot >= MAX_SWAP_PAGES or !swap_map[slot].used) return false;

    // Read page from disk
    if (!readPage(slot, phys_page)) {
        stats.read_errors += 1;
        return false;
    }

    stats.swap_ins += 1;
    return true;
}

/// Free a swap slot.
pub fn freeSlot(slot: u32) void {
    if (slot >= MAX_SWAP_PAGES) return;
    if (swap_map[slot].used) {
        swap_map[slot].used = false;
        // Update area used counts
        updateAreaCounts();
    }
}

/// Get swap usage info.
pub fn getUsage() SwapInfo {
    var info: SwapInfo = .{};
    for (swap_areas[0..area_count]) |*area| {
        if (!area.active) continue;
        info.total += area.total_slots;
    }
    var used: u32 = 0;
    for (&swap_map) |*slot| {
        if (slot.used) used += 1;
    }
    info.used = used;
    info.free = info.total -| used;
    info.total_bytes = @as(u64, info.total) * PAGE_SIZE;
    info.used_bytes = @as(u64, info.used) * PAGE_SIZE;
    return info;
}

/// Get statistics.
pub fn getSwapStats() Stats {
    return stats;
}

/// Reset statistics.
pub fn resetSwapStats() void {
    stats = .{};
}

// ============================================================
// Clock (Second Chance) Page Replacement
// ============================================================

/// Register a page frame for tracking by the clock algorithm.
pub fn registerPageFrame(phys_addr: u32) void {
    if (frame_count >= MAX_PAGE_FRAMES) return;
    page_frames[frame_count] = .{
        .phys_addr = phys_addr,
        .referenced = true,
        .valid = true,
    };
    frame_count += 1;
}

/// Mark a page as referenced (called on access).
pub fn markReferenced(phys_addr: u32) void {
    for (&page_frames) |*pf| {
        if (pf.valid and pf.phys_addr == phys_addr) {
            pf.referenced = true;
            return;
        }
    }
}

/// Find a victim page using the clock (second chance) algorithm.
/// Returns the physical address of the page to evict, or null if none available.
pub fn clockFindVictim() ?u32 {
    if (frame_count == 0) return null;

    // Two passes max: first pass clears R bits, second pass finds victim
    var checked: usize = 0;
    while (checked < frame_count * 2) : (checked += 1) {
        var pf = &page_frames[clock_hand];

        if (pf.valid) {
            if (pf.referenced) {
                // Second chance: clear R bit, advance
                pf.referenced = false;
            } else {
                // Found victim
                const victim_addr = pf.phys_addr;
                clock_hand = (clock_hand + 1) % frame_count;
                stats.reclaims += 1;
                return victim_addr;
            }
        }

        clock_hand = (clock_hand + 1) % frame_count;
    }

    // All pages referenced, just take current one
    if (frame_count > 0) {
        const victim = page_frames[clock_hand].phys_addr;
        clock_hand = (clock_hand + 1) % frame_count;
        stats.reclaims += 1;
        return victim;
    }

    return null;
}

/// Evict a page: swap it out and free the frame.
pub fn evictPage(phys_addr: u32) ?u32 {
    // Swap out
    const slot = swapOut(phys_addr) orelse return null;

    // Mark frame as swapped
    for (&page_frames) |*pf| {
        if (pf.valid and pf.phys_addr == phys_addr) {
            pf.swapped = true;
            pf.swap_slot = slot;
            pf.valid = false;
            return slot;
        }
    }

    return slot;
}

/// Restore a previously evicted page to a new frame.
pub fn restorePage(swap_slot: u32, new_phys: u32) bool {
    if (!swapIn(swap_slot, new_phys)) return false;
    freeSlot(swap_slot);

    // Re-register in frame table
    registerPageFrame(new_phys);
    return true;
}

// ============================================================
// Swap area priority
// ============================================================

/// Set priority for a swap area (higher = preferred).
pub fn setAreaPriority(area_idx: usize, priority: i8) void {
    if (area_idx >= area_count) return;
    swap_areas[area_idx].priority = priority;
}

/// Get area with highest priority that has free slots.
fn getBestArea() ?usize {
    var best_idx: ?usize = null;
    var best_pri: i8 = -128;

    for (swap_areas[0..area_count], 0..) |*area, i| {
        if (!area.active) continue;
        if (area.used_slots >= area.total_slots) continue;
        if (area.priority > best_pri) {
            best_pri = area.priority;
            best_idx = i;
        }
    }
    return best_idx;
}

// ============================================================
// Display
// ============================================================

/// Print swap status.
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("Swap Space Status:\n\n");
    vga.setColor(.light_grey, .black);

    if (!initialized) {
        vga.write("  Swap not initialized.\n");
        return;
    }

    // Swap areas
    for (swap_areas[0..area_count], 0..) |*area, i| {
        if (!area.active) continue;
        vga.write("  Area ");
        printDec(i);
        vga.write(": dev=");
        printDec(area.device_id);
        vga.write(" start=");
        printDec(area.start_sector);
        vga.write(" size=");
        printDec(area.size_sectors);
        vga.write(" slots=");
        printDec(area.total_slots);
        vga.write(" pri=");
        printDec(@as(u64, @intCast(@as(u32, @bitCast(@as(i32, area.priority))))));
        vga.putChar('\n');
    }

    // Usage
    const usage = getUsage();
    vga.write("\n  Total: ");
    printDec(usage.total);
    vga.write(" pages (");
    printDec(usage.total_bytes / 1024);
    vga.write(" KB)\n");
    vga.write("  Used:  ");
    printDec(usage.used);
    vga.write(" pages (");
    printDec(usage.used_bytes / 1024);
    vga.write(" KB)\n");
    vga.write("  Free:  ");
    printDec(usage.free);
    vga.write(" pages\n");

    // Usage bar
    vga.write("  ");
    printBar(usage.used, usage.total, 40);
    vga.putChar('\n');

    // Statistics
    vga.setColor(.yellow, .black);
    vga.write("\nSwap Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Swap outs:    ");
    printDec(stats.swap_outs);
    vga.putChar('\n');
    vga.write("  Swap ins:     ");
    printDec(stats.swap_ins);
    vga.putChar('\n');
    vga.write("  Reclaims:     ");
    printDec(stats.reclaims);
    vga.putChar('\n');
    vga.write("  Write errors: ");
    printDec(stats.write_errors);
    vga.putChar('\n');
    vga.write("  Read errors:  ");
    printDec(stats.read_errors);
    vga.putChar('\n');

    // Clock algorithm state
    vga.write("  Clock hand:   ");
    printDec(clock_hand);
    vga.write("/");
    printDec(frame_count);
    vga.putChar('\n');
}

// ============================================================
// Internal helpers
// ============================================================

fn allocSlot() ?usize {
    for (&swap_map, 0..) |*slot, i| {
        if (!slot.used) {
            // Check if this slot belongs to an active area
            if (slotInActiveArea(i)) {
                slot.used = true;
                return i;
            }
        }
    }
    return null;
}

fn slotInActiveArea(slot_idx: usize) bool {
    var slot_offset: usize = 0;
    for (swap_areas[0..area_count]) |*area| {
        if (!area.active) continue;
        if (slot_idx >= slot_offset and slot_idx < slot_offset + area.total_slots) {
            return true;
        }
        slot_offset += area.total_slots;
    }
    // If no areas configured, allow if within total
    return slot_idx < MAX_SWAP_PAGES;
}

fn updateAreaCounts() void {
    for (swap_areas[0..area_count]) |*area| {
        if (!area.active) continue;
        area.used_slots = 0;
    }
    for (&swap_map, 0..) |*slot, i| {
        if (!slot.used) continue;
        var offset: u32 = 0;
        for (swap_areas[0..area_count]) |*area| {
            if (!area.active) continue;
            if (i >= offset and i < offset + area.total_slots) {
                area.used_slots += 1;
                break;
            }
            offset += area.total_slots;
        }
    }
}

fn writePage(slot_idx: usize, phys_page: u32) bool {
    // Calculate disk sector from slot index
    const area_idx = getBestArea() orelse 0;
    if (area_idx >= area_count) return false;

    const area = &swap_areas[area_idx];
    const sector = area.start_sector + @as(u32, @intCast(slot_idx)) * SECTORS_PER_PAGE;

    // Write page data to disk sector by sector
    const page_ptr: [*]const u8 = @ptrFromInt(phys_page);
    return blkdev.write(area.device_id, sector, SECTORS_PER_PAGE, page_ptr);
}

fn readPage(slot_idx: usize, phys_page: u32) bool {
    // Find which area this slot belongs to
    var area_idx: usize = 0;
    var offset: usize = 0;
    var found = false;
    for (swap_areas[0..area_count], 0..) |*area, i| {
        if (!area.active) continue;
        if (slot_idx >= offset and slot_idx < offset + area.total_slots) {
            area_idx = i;
            found = true;
            break;
        }
        offset += area.total_slots;
    }
    if (!found and area_count > 0) area_idx = 0;

    const area = &swap_areas[area_idx];
    const sector = area.start_sector + @as(u32, @intCast(slot_idx)) * SECTORS_PER_PAGE;

    const page_ptr: [*]u8 = @ptrFromInt(phys_page);
    return blkdev.read(area.device_id, sector, SECTORS_PER_PAGE, page_ptr);
}

fn printBar(used: u32, total: u32, width: usize) void {
    if (total == 0) return;
    const filled = (@as(usize, used) * width) / total;
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

fn serialPrintDec(n: anytype) void {
    const v_init: u64 = @intCast(n);
    if (v_init == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}
