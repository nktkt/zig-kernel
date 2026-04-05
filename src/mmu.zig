// Memory management unit utilities -- page allocation tracker per process
//
// Tracks which physical pages are allocated to which process,
// provides memory map visualization and fragmentation analysis.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const serial = @import("serial.zig");

// ---- Constants ----

const MAX_TRACKED_PAGES = 256;
const PAGE_SIZE = 4096;

// Flags for page tracking
pub const PF_READ: u8 = 1 << 0;
pub const PF_WRITE: u8 = 1 << 1;
pub const PF_EXEC: u8 = 1 << 2;
pub const PF_USER: u8 = 1 << 3;
pub const PF_KERNEL: u8 = 1 << 4;

// Memory map: each character represents 64KB (16 pages)
const MAP_WIDTH = 80;
const MAP_BLOCK_SIZE = 64 * 1024; // 64KB per character in the map

// ---- Page info ----

pub const PageInfo = struct {
    physical_addr: u32,
    virtual_addr: u32,
    owner_pid: u32,
    flags: u8,
    used: bool,
};

// ---- State ----

var pages: [MAX_TRACKED_PAGES]PageInfo = undefined;
var mmu_initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&pages) |*p| {
        p.used = false;
        p.physical_addr = 0;
        p.virtual_addr = 0;
        p.owner_pid = 0;
        p.flags = 0;
    }
    mmu_initialized = true;
    serial.write("[mmu] page tracker initialized (max ");
    writeDecSerial(MAX_TRACKED_PAGES);
    serial.write(" pages)\n");
}

// ---- Page allocation ----

/// Allocate a physical page and track it for a process.
/// Returns the physical address, or null on failure.
pub fn allocForProcess(pid: u32, virt_addr: u32) ?u32 {
    if (!mmu_initialized) return null;

    // Find a free tracking slot
    const slot = findFreeSlot() orelse {
        serial.write("[mmu] tracking table full\n");
        return null;
    };

    // Allocate physical page from PMM
    const phys = pmm.alloc() orelse {
        serial.write("[mmu] PMM out of memory\n");
        return null;
    };

    // Zero the page
    const ptr: [*]u8 = @ptrFromInt(phys);
    @memset(ptr[0..PAGE_SIZE], 0);

    // Track it
    pages[slot] = .{
        .physical_addr = @truncate(phys),
        .virtual_addr = virt_addr,
        .owner_pid = pid,
        .flags = PF_READ | PF_WRITE | PF_USER,
        .used = true,
    };

    serial.write("[mmu] alloc page phys=0x");
    serial.writeHex(phys);
    serial.write(" virt=0x");
    serial.writeHex(@as(usize, virt_addr));
    serial.write(" pid=");
    writeDecSerial(@as(usize, pid));
    serial.write("\n");

    return @truncate(phys);
}

/// Free a page tracked for a process at a given virtual address.
pub fn freeForProcess(pid: u32, virt_addr: u32) void {
    if (!mmu_initialized) return;

    for (&pages) |*p| {
        if (p.used and p.owner_pid == pid and p.virtual_addr == virt_addr) {
            // Free the physical page
            pmm.free(@as(usize, p.physical_addr));
            p.used = false;

            serial.write("[mmu] free page virt=0x");
            serial.writeHex(@as(usize, virt_addr));
            serial.write(" pid=");
            writeDecSerial(@as(usize, pid));
            serial.write("\n");
            return;
        }
    }
}

/// Free all pages belonging to a process.
pub fn freeAllForProcess(pid: u32) void {
    if (!mmu_initialized) return;

    var freed: usize = 0;
    for (&pages) |*p| {
        if (p.used and p.owner_pid == pid) {
            pmm.free(@as(usize, p.physical_addr));
            p.used = false;
            freed += 1;
        }
    }

    if (freed > 0) {
        serial.write("[mmu] freed ");
        writeDecSerial(freed);
        serial.write(" pages for pid=");
        writeDecSerial(@as(usize, pid));
        serial.write("\n");
    }
}

// ---- Query ----

/// Get the number of pages allocated to a process.
pub fn getProcessPages(pid: u32) usize {
    if (!mmu_initialized) return 0;
    var count: usize = 0;
    for (&pages) |*p| {
        if (p.used and p.owner_pid == pid) count += 1;
    }
    return count;
}

/// Get info for a page by its physical address.
pub fn getPageInfo(phys: u32) ?PageInfo {
    if (!mmu_initialized) return null;
    for (&pages) |*p| {
        if (p.used and p.physical_addr == phys) return p.*;
    }
    return null;
}

/// Get the total number of tracked pages.
pub fn totalTracked() usize {
    var count: usize = 0;
    for (&pages) |*p| {
        if (p.used) count += 1;
    }
    return count;
}

/// Get the number of free tracking slots.
pub fn freeSlots() usize {
    return MAX_TRACKED_PAGES - totalTracked();
}

// ---- Memory map visualization ----

/// Print a visual map of physical memory usage.
/// Each character represents 64KB of physical memory.
/// Legend: '.' = free, '#' = kernel, '0'-'9' = process PID (mod 10), '?' = unknown.
pub fn printMemoryMap() void {
    if (!mmu_initialized) {
        vga.write("MMU not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Physical Memory Map ===\n");
    vga.setColor(.dark_grey, .black);
    vga.write("Each char = 64KB  '.'=free '#'=kernel '0-9'=process\n\n");

    // Determine range: show up to total PMM pages
    const total = pmm.totalCount();
    const total_bytes = total * PAGE_SIZE;
    const map_chars = if (total_bytes / MAP_BLOCK_SIZE > 0) @min(total_bytes / MAP_BLOCK_SIZE, MAP_WIDTH * 4) else MAP_WIDTH;

    // Print address header
    vga.setColor(.dark_grey, .black);
    vga.write("0x00000000 ");

    var col: usize = 0;
    var block: usize = 0;
    while (block < map_chars) : (block += 1) {
        const block_start: u32 = @truncate(block * MAP_BLOCK_SIZE);
        const block_end: u32 = block_start + @as(u32, MAP_BLOCK_SIZE);

        // Check what's in this block
        const status = classifyBlock(block_start, block_end);

        switch (status.kind) {
            .free => {
                vga.setColor(.green, .black);
                vga.putChar('.');
            },
            .kernel => {
                vga.setColor(.light_red, .black);
                vga.putChar('#');
            },
            .process => {
                // Color by PID
                const pid_colors = [_]vga.Color{ .light_blue, .light_green, .yellow, .light_magenta, .light_cyan, .white, .light_red, .brown, .blue, .magenta };
                const ci = status.pid % pid_colors.len;
                vga.setColor(pid_colors[ci], .black);
                const digit: u8 = @truncate('0' + status.pid % 10);
                vga.putChar(digit);
            },
            .mixed => {
                vga.setColor(.dark_grey, .black);
                vga.putChar('?');
            },
        }

        col += 1;
        if (col >= MAP_WIDTH) {
            col = 0;
            vga.putChar('\n');
            // Print address for next row
            if (block + 1 < map_chars) {
                vga.setColor(.dark_grey, .black);
                vga.write("0x");
                fmt.printHex32(@truncate((block + 1) * MAP_BLOCK_SIZE));
                vga.putChar(' ');
            }
        }
    }

    if (col > 0) vga.putChar('\n');

    // Summary
    vga.setColor(.light_grey, .black);
    vga.write("\nTracked pages: ");
    fmt.printDec(totalTracked());
    vga.write("/");
    fmt.printDec(MAX_TRACKED_PAGES);
    vga.write("  PMM free: ");
    fmt.printDec(pmm.freeCount());
    vga.write("/");
    fmt.printDec(pmm.totalCount());
    vga.write(" pages\n");
}

const BlockKind = enum { free, kernel, process, mixed };
const BlockStatus = struct {
    kind: BlockKind,
    pid: u32,
};

fn classifyBlock(start: u32, end: u32) BlockStatus {
    // Kernel region: 0 - 2MB
    if (start < 0x200000) {
        return .{ .kind = .kernel, .pid = 0 };
    }

    // Check tracked pages
    var found_pid: ?u32 = null;
    var found_count: usize = 0;

    for (&pages) |*p| {
        if (!p.used) continue;
        if (p.physical_addr >= start and p.physical_addr < end) {
            found_count += 1;
            if (found_pid == null) {
                found_pid = p.owner_pid;
            } else if (found_pid.? != p.owner_pid) {
                return .{ .kind = .mixed, .pid = 0 };
            }
        }
    }

    if (found_count > 0) {
        return .{ .kind = .process, .pid = found_pid.? };
    }
    return .{ .kind = .free, .pid = 0 };
}

/// Print memory info for a specific process.
pub fn printProcessMemory(pid: u32) void {
    if (!mmu_initialized) {
        vga.write("MMU not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("Memory for PID ");
    fmt.printDec(@as(usize, pid));
    vga.write(":\n");

    vga.setColor(.yellow, .black);
    vga.write("  PHYS_ADDR   VIRT_ADDR   FLAGS\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    var total_size: usize = 0;

    for (&pages) |*p| {
        if (!p.used or p.owner_pid != pid) continue;

        vga.write("  0x");
        fmt.printHex32(p.physical_addr);
        vga.write("  0x");
        fmt.printHex32(p.virtual_addr);
        vga.write("  ");

        // Print flags
        if (p.flags & PF_READ != 0) vga.putChar('R') else vga.putChar('-');
        if (p.flags & PF_WRITE != 0) vga.putChar('W') else vga.putChar('-');
        if (p.flags & PF_EXEC != 0) vga.putChar('X') else vga.putChar('-');
        if (p.flags & PF_USER != 0) vga.putChar('U') else vga.putChar('-');
        if (p.flags & PF_KERNEL != 0) vga.putChar('K') else vga.putChar('-');
        vga.putChar('\n');

        count += 1;
        total_size += PAGE_SIZE;
    }

    if (count == 0) {
        vga.write("  (no pages tracked)\n");
    } else {
        vga.setColor(.dark_grey, .black);
        fmt.printDec(count);
        vga.write(" pages, ");
        fmt.printSize(total_size);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
}

/// Calculate memory fragmentation percentage.
/// Fragmentation = percentage of free pages that are not contiguous.
/// Returns 0-100.
pub fn getFragmentation() u32 {
    if (!mmu_initialized) return 0;

    // Build a simple bitmap of tracked physical pages
    // We'll check the first 256 pages after kernel (1MB-2MB)
    const check_start: u32 = 0x200000; // 2MB
    const check_pages: u32 = 256;
    var occupied: [256]bool = @splat(false);

    for (&pages) |*p| {
        if (!p.used) continue;
        if (p.physical_addr >= check_start) {
            const page_idx = (p.physical_addr - check_start) / PAGE_SIZE;
            if (page_idx < check_pages) {
                occupied[@as(usize, page_idx)] = true;
            }
        }
    }

    // Count free pages and free runs
    var free_pages: u32 = 0;
    var free_runs: u32 = 0;
    var in_run = false;

    for (occupied) |occ| {
        if (!occ) {
            free_pages += 1;
            if (!in_run) {
                free_runs += 1;
                in_run = true;
            }
        } else {
            in_run = false;
        }
    }

    if (free_pages <= 1 or free_runs <= 1) return 0;

    // Fragmentation = (runs - 1) / (free_pages - 1) * 100
    // More runs = more fragmented
    return ((free_runs - 1) * 100) / (free_pages - 1);
}

/// Print fragmentation info.
pub fn printFragmentation() void {
    const frag = getFragmentation();
    vga.setColor(.light_grey, .black);
    vga.write("Memory fragmentation: ");
    if (frag < 25) {
        vga.setColor(.light_green, .black);
    } else if (frag < 50) {
        vga.setColor(.yellow, .black);
    } else if (frag < 75) {
        vga.setColor(.light_red, .black);
    } else {
        vga.setColor(.red, .black);
    }
    fmt.printDec(@as(usize, frag));
    vga.write("%\n");
    vga.setColor(.light_grey, .black);
}

/// Print a summary of memory usage.
pub fn printSummary() void {
    if (!mmu_initialized) {
        vga.write("MMU not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== MMU Summary ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Tracked pages:  ");
    fmt.printDec(totalTracked());
    vga.write(" / ");
    fmt.printDec(MAX_TRACKED_PAGES);
    vga.write(" (");
    fmt.printSize(totalTracked() * PAGE_SIZE);
    vga.write(")\n");

    vga.write("PMM pages:      ");
    fmt.printDec(pmm.freeCount());
    vga.write(" free / ");
    fmt.printDec(pmm.totalCount());
    vga.write(" total\n");

    printFragmentation();

    // Per-process summary
    var pids: [MAX_TRACKED_PAGES]u32 = undefined;
    var pid_count: usize = 0;

    for (&pages) |*p| {
        if (!p.used) continue;
        var found = false;
        var j: usize = 0;
        while (j < pid_count) : (j += 1) {
            if (pids[j] == p.owner_pid) {
                found = true;
                break;
            }
        }
        if (!found and pid_count < MAX_TRACKED_PAGES) {
            pids[pid_count] = p.owner_pid;
            pid_count += 1;
        }
    }

    if (pid_count > 0) {
        vga.setColor(.light_cyan, .black);
        vga.write("\nPer-process memory:\n");
        vga.setColor(.yellow, .black);
        vga.write("  PID   PAGES   SIZE\n");
        vga.setColor(.light_grey, .black);

        var i: usize = 0;
        while (i < pid_count) : (i += 1) {
            const pcount = getProcessPages(pids[i]);
            vga.write("  ");
            fmt.printDecPadded(@as(usize, pids[i]), 4);
            vga.write("  ");
            fmt.printDecPadded(pcount, 6);
            vga.write("  ");
            fmt.printSize(pcount * PAGE_SIZE);
            vga.putChar('\n');
        }
    }
}

// ---- Internal helpers ----

fn findFreeSlot() ?usize {
    for (&pages, 0..) |*p, i| {
        if (!p.used) return i;
    }
    return null;
}

fn writeDecSerial(n: usize) void {
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
