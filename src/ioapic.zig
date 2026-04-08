// I/O APIC Standalone Module
//
// The I/O APIC (Input/Output Advanced Programmable Interrupt Controller)
// routes external hardware interrupts to Local APICs. It typically resides
// at physical address 0xFEC00000 and provides a redirection table that maps
// each IRQ pin to a destination APIC, vector, and delivery parameters.
//
// Register access is via two MMIO registers:
//   IOREGSEL (offset 0x00) - select which internal register to access
//   IOWIN    (offset 0x10) - read/write the selected register

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- MMIO Register Offsets ----

const IOREGSEL_OFFSET: u32 = 0x00; // I/O Register Select
const IOWIN_OFFSET: u32 = 0x10; // I/O Window (data)

// ---- Internal Register Indices ----

const REG_ID: u32 = 0x00; // I/O APIC ID
const REG_VER: u32 = 0x01; // I/O APIC Version
const REG_ARB: u32 = 0x02; // I/O APIC Arbitration ID
const REG_REDTBL_BASE: u32 = 0x10; // Redirection Table Entry 0 (low)

// ---- Delivery Modes ----

pub const DeliveryMode = enum(u3) {
    fixed = 0, // Deliver to specific APIC(s)
    lowest_priority = 1, // Deliver to lowest-priority APIC
    smi = 2, // System Management Interrupt
    reserved = 3,
    nmi = 4, // Non-Maskable Interrupt
    init = 5, // INIT signal
    reserved2 = 6,
    ext_int = 7, // External Interrupt (8259A compatible)
};

// ---- Destination Mode ----

pub const DestMode = enum(u1) {
    physical = 0, // Destination is APIC ID
    logical = 1, // Destination is logical ID
};

// ---- Trigger Mode ----

pub const TriggerMode = enum(u1) {
    edge = 0,
    level = 1,
};

// ---- Pin Polarity ----

pub const Polarity = enum(u1) {
    active_high = 0,
    active_low = 1,
};

// ---- Redirection Table Entry ----

pub const RedirEntry = struct {
    vector: u8, // Interrupt vector (0-255)
    delivery_mode: DeliveryMode, // How to deliver
    dest_mode: DestMode, // Physical or logical destination
    polarity: Polarity, // Active high or low
    trigger: TriggerMode, // Edge or level triggered
    mask: bool, // true = masked (disabled)
    destination: u8, // APIC ID (physical) or logical dest
};

// ---- State ----

var base_addr: u32 = 0xFEC00000; // Default I/O APIC base
var initialized: bool = false;
var ioapic_id: u8 = 0;
var ioapic_version: u8 = 0;
var max_redirs: u8 = 0; // Number of redirection entries - 1

// ---- MMIO Register Access ----

/// Read an I/O APIC internal register.
pub fn readRegister(reg: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(base_addr + IOREGSEL_OFFSET);
    const win: *volatile u32 = @ptrFromInt(base_addr + IOWIN_OFFSET);
    sel.* = reg;
    return win.*;
}

/// Write an I/O APIC internal register.
pub fn writeRegister(reg: u32, val: u32) void {
    const sel: *volatile u32 = @ptrFromInt(base_addr + IOREGSEL_OFFSET);
    const win: *volatile u32 = @ptrFromInt(base_addr + IOWIN_OFFSET);
    sel.* = reg;
    win.* = val;
}

// ---- Initialization ----

/// Initialize the I/O APIC module with a given base address.
pub fn init() void {
    initWithBase(0xFEC00000);
}

/// Initialize with a specific MMIO base address.
pub fn initWithBase(addr: u32) void {
    base_addr = addr;

    // Probe: read ID register
    const id_reg = readRegister(REG_ID);
    ioapic_id = @truncate((id_reg >> 24) & 0x0F);

    // Read version register
    const ver_reg = readRegister(REG_VER);
    ioapic_version = @truncate(ver_reg & 0xFF);
    max_redirs = @truncate((ver_reg >> 16) & 0xFF);

    initialized = true;

    serial.write("[IOAPIC] ID=");
    serialDecU8(ioapic_id);
    serial.write(" Ver=0x");
    serialHex8(ioapic_version);
    serial.write(" MaxRedir=");
    serialDecU8(max_redirs);
    serial.write("\n");
}

/// Set the I/O APIC base address (without re-reading registers).
pub fn setBase(addr: u32) void {
    base_addr = addr;
}

/// Get the configured base address.
pub fn getBase() u32 {
    return base_addr;
}

// ---- ID, Version, Arbitration ----

/// Get the I/O APIC ID.
pub fn getId() u8 {
    return @truncate((readRegister(REG_ID) >> 24) & 0x0F);
}

/// Set the I/O APIC ID.
pub fn setId(id: u8) void {
    var reg = readRegister(REG_ID);
    reg = (reg & 0xF0FFFFFF) | (@as(u32, id & 0x0F) << 24);
    writeRegister(REG_ID, reg);
    ioapic_id = id & 0x0F;
}

/// Get the I/O APIC version.
pub fn getVersion() u8 {
    return @truncate(readRegister(REG_VER) & 0xFF);
}

/// Get the arbitration ID.
pub fn getArbitrationId() u8 {
    return @truncate((readRegister(REG_ARB) >> 24) & 0x0F);
}

/// Get the maximum number of redirection entries (0-based, so actual count = return + 1).
pub fn getMaxRedirections() u8 {
    return @truncate((readRegister(REG_VER) >> 16) & 0xFF);
}

// ---- Redirection Table ----

/// Read a redirection table entry.
pub fn getRedirection(irq: u8) RedirEntry {
    const reg_lo = REG_REDTBL_BASE + @as(u32, irq) * 2;
    const reg_hi = reg_lo + 1;

    const lo = readRegister(reg_lo);
    const hi = readRegister(reg_hi);

    return .{
        .vector = @truncate(lo & 0xFF),
        .delivery_mode = @enumFromInt(@as(u3, @truncate((lo >> 8) & 0x7))),
        .dest_mode = @enumFromInt(@as(u1, @truncate((lo >> 11) & 0x1))),
        .polarity = @enumFromInt(@as(u1, @truncate((lo >> 13) & 0x1))),
        .trigger = @enumFromInt(@as(u1, @truncate((lo >> 15) & 0x1))),
        .mask = (lo & (1 << 16)) != 0,
        .destination = @truncate((hi >> 24) & 0xFF),
    };
}

/// Write a redirection table entry.
pub fn setRedirection(irq: u8, entry: RedirEntry) void {
    const reg_lo = REG_REDTBL_BASE + @as(u32, irq) * 2;
    const reg_hi = reg_lo + 1;

    var lo: u32 = @as(u32, entry.vector);
    lo |= @as(u32, @intFromEnum(entry.delivery_mode)) << 8;
    lo |= @as(u32, @intFromEnum(entry.dest_mode)) << 11;
    lo |= @as(u32, @intFromEnum(entry.polarity)) << 13;
    lo |= @as(u32, @intFromEnum(entry.trigger)) << 15;
    if (entry.mask) lo |= (1 << 16);

    const hi: u32 = @as(u32, entry.destination) << 24;

    writeRegister(reg_lo, lo);
    writeRegister(reg_hi, hi);
}

/// Mask (disable) a specific IRQ.
pub fn maskIrq(irq: u8) void {
    const reg_lo = REG_REDTBL_BASE + @as(u32, irq) * 2;
    var lo = readRegister(reg_lo);
    lo |= (1 << 16); // Set mask bit
    writeRegister(reg_lo, lo);
}

/// Unmask (enable) a specific IRQ.
pub fn unmaskIrq(irq: u8) void {
    const reg_lo = REG_REDTBL_BASE + @as(u32, irq) * 2;
    var lo = readRegister(reg_lo);
    lo &= ~@as(u32, 1 << 16); // Clear mask bit
    writeRegister(reg_lo, lo);
}

/// Check if an IRQ is masked.
pub fn isIrqMasked(irq: u8) bool {
    const reg_lo = REG_REDTBL_BASE + @as(u32, irq) * 2;
    return (readRegister(reg_lo) & (1 << 16)) != 0;
}

/// Mask all IRQs.
pub fn maskAll() void {
    const max = getMaxRedirections();
    var i: u8 = 0;
    while (i <= max) : (i += 1) {
        maskIrq(i);
    }
}

/// Route an IRQ to a specific APIC with given vector (edge-triggered, active high).
pub fn routeIrq(irq: u8, vector: u8, apic_id: u8) void {
    setRedirection(irq, .{
        .vector = vector,
        .delivery_mode = .fixed,
        .dest_mode = .physical,
        .polarity = .active_high,
        .trigger = .edge,
        .mask = false,
        .destination = apic_id,
    });
}

/// Route an IRQ with level-triggered, active-low signaling (common for PCI).
pub fn routeIrqLevel(irq: u8, vector: u8, apic_id: u8) void {
    setRedirection(irq, .{
        .vector = vector,
        .delivery_mode = .fixed,
        .dest_mode = .physical,
        .polarity = .active_low,
        .trigger = .level,
        .mask = false,
        .destination = apic_id,
    });
}

// ---- Display ----

/// Print the full redirection table.
pub fn printRedirectionTable() void {
    vga.setColor(.yellow, .black);
    vga.write("I/O APIC Redirection Table:\n");
    vga.setColor(.light_grey, .black);

    if (!initialized) {
        vga.write("  I/O APIC not initialized\n");
        return;
    }

    vga.write("  ID: ");
    printDecU8(ioapic_id);
    vga.write("  Version: 0x");
    printHex8(ioapic_version);
    vga.write("  Base: 0x");
    printHex32(base_addr);
    vga.putChar('\n');

    const max = getMaxRedirections();
    vga.write("  IRQ  VEC  DEL   DEST  TRIG  POL   MASK\n");
    vga.write("  -----------------------------------------\n");

    var i: u8 = 0;
    while (i <= max) : (i += 1) {
        const entry = getRedirection(i);

        vga.write("  ");
        printDecPad(i, 3);
        vga.write("  ");
        printHex8(entry.vector);
        vga.write("   ");

        // Delivery mode name
        switch (entry.delivery_mode) {
            .fixed => vga.write("FIX "),
            .lowest_priority => vga.write("LOW "),
            .smi => vga.write("SMI "),
            .nmi => vga.write("NMI "),
            .init => vga.write("INIT"),
            .ext_int => vga.write("EINT"),
            else => vga.write("??? "),
        }
        vga.write("  ");

        // Destination
        printHex8(entry.destination);
        if (entry.dest_mode == .logical) {
            vga.write("L");
        } else {
            vga.write("P");
        }
        vga.write("  ");

        // Trigger
        if (entry.trigger == .level) {
            vga.write("LVL ");
        } else {
            vga.write("EDGE");
        }
        vga.write("  ");

        // Polarity
        if (entry.polarity == .active_low) {
            vga.write("LOW ");
        } else {
            vga.write("HIGH");
        }
        vga.write("  ");

        // Mask
        if (entry.mask) {
            vga.write("MASK");
        } else {
            vga.setColor(.light_green, .black);
            vga.write("ON  ");
            vga.setColor(.light_grey, .black);
        }

        vga.putChar('\n');
    }
}

/// Print summary info.
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("I/O APIC Info:\n");
    vga.setColor(.light_grey, .black);

    if (!initialized) {
        vga.write("  Not initialized\n");
        return;
    }

    vga.write("  Base Address: 0x");
    printHex32(base_addr);
    vga.putChar('\n');

    vga.write("  ID:           ");
    printDecU8(ioapic_id);
    vga.putChar('\n');

    vga.write("  Version:      0x");
    printHex8(ioapic_version);
    vga.putChar('\n');

    vga.write("  Arbitration:  ");
    printDecU8(getArbitrationId());
    vga.putChar('\n');

    vga.write("  Max IRQs:     ");
    printDecU8(max_redirs + 1);
    vga.putChar('\n');

    // Count unmasked IRQs
    var unmasked: u8 = 0;
    var i: u8 = 0;
    while (i <= max_redirs) : (i += 1) {
        if (!isIrqMasked(i)) unmasked += 1;
    }
    vga.write("  Active IRQs:  ");
    printDecU8(unmasked);
    vga.putChar('\n');
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

fn printDecU8(val: u8) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [3]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = '0' + v % 10;
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDecPad(val: u8, width: u8) void {
    // Count digits
    var digits: u8 = 0;
    var tmp = val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    // Pad with spaces
    var p = width -| digits;
    while (p > 0) : (p -= 1) {
        vga.putChar(' ');
    }
    printDecU8(val);
}

fn serialDecU8(val: u8) void {
    if (val == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [3]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = '0' + v % 10;
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0xF]);
}
