// Memory-Mapped I/O Utilities
//
// Provides type-safe volatile read/write functions for MMIO registers,
// read-modify-write helpers, bit polling with timeout, memory barriers,
// and MMIO region tracking for debugging.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- Volatile read functions ----

/// Read an 8-bit value from a memory-mapped I/O address.
pub fn readU8(addr: u32) u8 {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    return ptr.*;
}

/// Read a 16-bit value from a memory-mapped I/O address.
pub fn readU16(addr: u32) u16 {
    const ptr: *volatile u16 = @ptrFromInt(addr);
    return ptr.*;
}

/// Read a 32-bit value from a memory-mapped I/O address.
pub fn readU32(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

// ---- Volatile write functions ----

/// Write an 8-bit value to a memory-mapped I/O address.
pub fn writeU8(addr: u32, val: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    ptr.* = val;
}

/// Write a 16-bit value to a memory-mapped I/O address.
pub fn writeU16(addr: u32, val: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(addr);
    ptr.* = val;
}

/// Write a 32-bit value to a memory-mapped I/O address.
pub fn writeU32(addr: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}

// ---- Read-Modify-Write ----

/// Atomically read a 32-bit register, clear bits in `mask`, set bits in `val`.
/// Result = (old_value & ~mask) | (val & mask)
pub fn readModifyWrite(addr: u32, mask: u32, val: u32) void {
    const old = readU32(addr);
    const new = (old & ~mask) | (val & mask);
    writeU32(addr, new);
}

/// Set specific bits in a 32-bit register (OR operation).
pub fn setBits(addr: u32, bits: u32) void {
    writeU32(addr, readU32(addr) | bits);
}

/// Clear specific bits in a 32-bit register (AND NOT operation).
pub fn clearBits(addr: u32, bits: u32) void {
    writeU32(addr, readU32(addr) & ~bits);
}

// ---- Bit polling with timeout ----

/// Wait until a specific bit is set in a 32-bit register.
/// `timeout` is in PIT ticks (~ms). Returns true if bit became set, false on timeout.
pub fn waitBitSet(addr: u32, bit: u5, timeout: u32) bool {
    const mask: u32 = @as(u32, 1) << bit;
    const start = pit.getTicks();
    while (pit.getTicks() - start < timeout) {
        if (readU32(addr) & mask != 0) return true;
        pause();
    }
    return false;
}

/// Wait until a specific bit is cleared in a 32-bit register.
/// `timeout` is in PIT ticks (~ms). Returns true if bit cleared, false on timeout.
pub fn waitBitClear(addr: u32, bit: u5, timeout: u32) bool {
    const mask: u32 = @as(u32, 1) << bit;
    const start = pit.getTicks();
    while (pit.getTicks() - start < timeout) {
        if (readU32(addr) & mask == 0) return true;
        pause();
    }
    return false;
}

/// Poll a register until (value & mask) == expected.
/// `timeout` is in PIT ticks (~ms). Returns true on match, false on timeout.
pub fn pollRegister(addr: u32, mask: u32, expected: u32, timeout: u32) bool {
    const start = pit.getTicks();
    while (pit.getTicks() - start < timeout) {
        if (readU32(addr) & mask == expected) return true;
        pause();
    }
    return false;
}

/// Poll with a spin count instead of PIT ticks. Useful before PIT is initialized.
pub fn pollRegisterSpin(addr: u32, mask: u32, expected: u32, max_spins: u32) bool {
    var i: u32 = 0;
    while (i < max_spins) : (i += 1) {
        if (readU32(addr) & mask == expected) return true;
        pause();
    }
    return false;
}

/// Wait for a 32-bit register to have all bits in mask set.
pub fn waitAllBitsSet(addr: u32, mask: u32, timeout: u32) bool {
    const start = pit.getTicks();
    while (pit.getTicks() - start < timeout) {
        if (readU32(addr) & mask == mask) return true;
        pause();
    }
    return false;
}

/// Wait for a 32-bit register to have all bits in mask cleared.
pub fn waitAllBitsClear(addr: u32, mask: u32, timeout: u32) bool {
    const start = pit.getTicks();
    while (pit.getTicks() - start < timeout) {
        if (readU32(addr) & mask == 0) return true;
        pause();
    }
    return false;
}

// ---- Memory barriers ----

/// Full memory barrier (read + write ordering).
pub fn mb() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Read memory barrier (load ordering).
pub fn rmb() void {
    asm volatile ("lfence" ::: .{ .memory = true });
}

/// Write memory barrier (store ordering).
pub fn wmb() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}

/// Compiler-only barrier: prevents reordering across this point.
pub fn compilerBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

/// CPU hint for spin-wait loops.
fn pause() void {
    asm volatile ("pause");
}

// ---- MMIO region tracking ----

/// Describes a registered MMIO region.
pub const MmioRegion = struct {
    name: [32]u8,
    base: u32,
    size: u32,
    active: bool,
};

const MAX_REGIONS = 32;
var regions: [MAX_REGIONS]MmioRegion = @splat(MmioRegion{
    .name = @splat(0),
    .base = 0,
    .size = 0,
    .active = false,
});
var region_count: usize = 0;

/// Register an MMIO region for tracking.
pub fn registerRegion(name: []const u8, base: u32, size: u32) bool {
    if (region_count >= MAX_REGIONS) return false;

    var r = &regions[region_count];
    r.base = base;
    r.size = size;
    r.active = true;

    // Copy name (truncate to 31 chars)
    const copy_len = if (name.len > 31) 31 else name.len;
    for (0..copy_len) |i| {
        r.name[i] = name[i];
    }
    for (copy_len..32) |i| {
        r.name[i] = 0;
    }

    region_count += 1;
    return true;
}

/// Unregister an MMIO region by base address.
pub fn unregisterRegion(base: u32) bool {
    for (&regions) |*r| {
        if (r.active and r.base == base) {
            r.active = false;
            return true;
        }
    }
    return false;
}

/// Find which region contains a given address.
pub fn findRegion(addr: u32) ?*const MmioRegion {
    for (&regions) |*r| {
        if (r.active and addr >= r.base and addr < r.base + r.size) {
            return r;
        }
    }
    return null;
}

/// Get the number of registered regions.
pub fn getRegionCount() usize {
    var count: usize = 0;
    for (&regions) |*r| {
        if (r.active) count += 1;
    }
    return count;
}

/// Check if a given address range overlaps with any registered region.
pub fn checkOverlap(base: u32, size: u32) bool {
    for (&regions) |*r| {
        if (!r.active) continue;
        // Overlap if: start_a < end_b AND start_b < end_a
        if (base < r.base + r.size and r.base < base + size) {
            return true;
        }
    }
    return false;
}

// ---- Block read/write ----

/// Read `count` 32-bit words from consecutive MMIO addresses into buffer.
pub fn readBlock32(base_addr: u32, buf: [*]u32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        buf[i] = readU32(base_addr + @as(u32, @truncate(i * 4)));
    }
}

/// Write `count` 32-bit words from buffer to consecutive MMIO addresses.
pub fn writeBlock32(base_addr: u32, buf: [*]const u32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        writeU32(base_addr + @as(u32, @truncate(i * 4)), buf[i]);
    }
}

/// Fill a range of MMIO addresses with a constant 32-bit value.
pub fn fillU32(base_addr: u32, val: u32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        writeU32(base_addr + @as(u32, @truncate(i * 4)), val);
    }
}

// ---- Dump utility ----

/// Dump `count` 32-bit registers from base address to VGA.
pub fn dumpRegisters(base_addr: u32, count: usize) void {
    vga.setColor(.yellow, .black);
    vga.write("MMIO Dump @ 0x");
    printHex32(base_addr);
    vga.write(":\n");
    vga.setColor(.light_grey, .black);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i % 4 == 0) {
            vga.write("  +0x");
            printHex8(@truncate(i * 4));
            vga.write(": ");
        }
        printHex32(readU32(base_addr + @as(u32, @truncate(i * 4))));
        if (i % 4 == 3 or i == count - 1) {
            vga.putChar('\n');
        } else {
            vga.putChar(' ');
        }
    }
}

// ---- Display ----

/// Print all registered MMIO regions.
pub fn printRegions() void {
    vga.setColor(.yellow, .black);
    vga.write("MMIO Regions (");
    printDec(getRegionCount());
    vga.write(" registered):\n");
    vga.setColor(.light_grey, .black);

    if (region_count == 0) {
        vga.write("  No regions registered\n");
        return;
    }

    vga.write("  NAME                             BASE       SIZE\n");
    vga.write("  --------------------------------------------------\n");

    for (&regions) |*r| {
        if (!r.active) continue;

        vga.write("  ");
        // Print name (padded to 32 chars)
        var name_len: usize = 0;
        for (r.name) |c| {
            if (c == 0) break;
            name_len += 1;
        }
        for (r.name[0..name_len]) |c| {
            vga.putChar(c);
        }
        var pad = 33 -| name_len;
        while (pad > 0) : (pad -= 1) {
            vga.putChar(' ');
        }

        vga.write("0x");
        printHex32(r.base);
        vga.write("  ");

        // Print size in human-readable form
        if (r.size >= 1024 * 1024) {
            printDec(r.size / (1024 * 1024));
            vga.write(" MB");
        } else if (r.size >= 1024) {
            printDec(r.size / 1024);
            vga.write(" KB");
        } else {
            printDec(r.size);
            vga.write(" B");
        }
        vga.putChar('\n');
    }
}

// ---- Diagnostic info ----

/// Print a single MMIO register value (for debugging).
pub fn printRegister(name: []const u8, addr: u32) void {
    vga.write("  ");
    vga.write(name);
    vga.write(": 0x");
    printHex32(readU32(addr));
    vga.putChar('\n');
}

/// Verify that a region is accessible by reading the first word.
/// Returns true if the read did not return 0xFFFFFFFF (typical bus error value).
pub fn probeRegion(addr: u32) bool {
    const val = readU32(addr);
    return val != 0xFFFFFFFF;
}

// ---- Internal helpers ----

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
