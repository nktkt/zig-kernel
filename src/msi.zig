// MSI (Message Signaled Interrupts) Support
//
// MSI replaces traditional pin-based interrupts with in-band messages.
// A PCI device writes a specific value to a specific address to signal
// an interrupt, bypassing the I/O APIC entirely.
//
// MSI capability is found by walking the PCI capability list.
// Capability ID 0x05 = MSI, Capability ID 0x11 = MSI-X.
//
// MSI message format (x86):
//   Address: 0xFEE00000 | (dest_apic_id << 12) | rh | dm
//   Data:    (trigger_mode << 15) | (level << 14) | (delivery_mode << 8) | vector

const pci = @import("pci.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- PCI Capability IDs ----

const CAP_ID_MSI: u8 = 0x05;
const CAP_ID_MSIX: u8 = 0x11;

// ---- MSI Capability Register Offsets (from capability pointer) ----

const MSI_CAP_ID: u8 = 0x00; // Capability ID (1 byte)
const MSI_NEXT_PTR: u8 = 0x01; // Next capability pointer (1 byte)
const MSI_MSG_CTRL: u8 = 0x02; // Message Control (2 bytes)
const MSI_MSG_ADDR: u8 = 0x04; // Message Address (4 bytes)
const MSI_MSG_ADDR_HI: u8 = 0x08; // Message Upper Address (4 bytes, 64-bit only)
const MSI_MSG_DATA_32: u8 = 0x08; // Message Data (2 bytes, 32-bit mode)
const MSI_MSG_DATA_64: u8 = 0x0C; // Message Data (2 bytes, 64-bit mode)
const MSI_MASK_32: u8 = 0x0C; // Mask Bits (4 bytes, 32-bit, per-vector masking)
const MSI_MASK_64: u8 = 0x10; // Mask Bits (4 bytes, 64-bit, per-vector masking)
const MSI_PENDING_32: u8 = 0x10; // Pending Bits (4 bytes, 32-bit)
const MSI_PENDING_64: u8 = 0x14; // Pending Bits (4 bytes, 64-bit)

// ---- Message Control Register bits ----

const MSGCTRL_ENABLE: u16 = 1 << 0; // MSI Enable
const MSGCTRL_MMC_MASK: u16 = 0x000E; // Multiple Message Capable (bits 3:1)
const MSGCTRL_MMC_SHIFT: u4 = 1;
const MSGCTRL_MME_MASK: u16 = 0x0070; // Multiple Message Enable (bits 6:4)
const MSGCTRL_MME_SHIFT: u4 = 4;
const MSGCTRL_64BIT: u16 = 1 << 7; // 64-bit address capable
const MSGCTRL_PVM: u16 = 1 << 8; // Per-vector masking capable

// ---- MSI-X Capability Register Offsets ----

const MSIX_CAP_ID: u8 = 0x00;
const MSIX_NEXT_PTR: u8 = 0x01;
const MSIX_MSG_CTRL: u8 = 0x02;
const MSIX_TABLE_OFFSET: u8 = 0x04; // Table Offset + BIR
const MSIX_PBA_OFFSET: u8 = 0x08; // PBA Offset + BIR

// ---- MSI-X Message Control bits ----

const MSIX_CTRL_TABLE_SIZE_MASK: u16 = 0x07FF; // bits 10:0
const MSIX_CTRL_FUNC_MASK: u16 = 1 << 14;
const MSIX_CTRL_ENABLE: u16 = 1 << 15;

// ---- x86 MSI Address format ----

const MSI_ADDR_BASE: u32 = 0xFEE00000;
const MSI_ADDR_DEST_SHIFT: u5 = 12;
const MSI_ADDR_RH: u32 = 1 << 3; // Redirection Hint
const MSI_ADDR_DM: u32 = 1 << 2; // Destination Mode (0=physical, 1=logical)

// ---- x86 MSI Data format ----

pub const MsiDeliveryMode = enum(u3) {
    fixed = 0,
    lowest_priority = 1,
    smi = 2,
    reserved = 3,
    nmi = 4,
    init = 5,
    reserved2 = 6,
    ext_int = 7,
};

// ---- MSI capability info ----

pub const MsiCapInfo = struct {
    cap_offset: u8, // Offset within PCI config space
    is_64bit: bool, // 64-bit address capable
    per_vector_mask: bool, // Per-vector masking support
    max_vectors: u8, // Maximum vectors (1, 2, 4, 8, 16, 32)
    enabled_vectors: u8, // Currently enabled vectors
    is_enabled: bool, // MSI enabled
};

pub const MsixCapInfo = struct {
    cap_offset: u8,
    table_size: u16, // Number of entries (0-based in register)
    table_bar: u8, // BAR Indicator Register
    table_offset: u32, // Offset within BAR
    pba_bar: u8,
    pba_offset: u32,
    is_enabled: bool,
    func_mask: bool,
};

// ---- PCI Capability List Walking ----

/// Read a single byte from PCI config space.
fn pciReadByte(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    const dword = pci.readConfig(bus, slot, func, offset & 0xFC);
    const shift: u5 = @truncate((offset & 0x03) * 8);
    return @truncate(dword >> shift);
}

/// Read a 16-bit word from PCI config space.
fn pciReadWord(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    const dword = pci.readConfig(bus, slot, func, offset & 0xFC);
    const shift: u5 = @truncate((offset & 0x02) * 8);
    return @truncate(dword >> shift);
}

/// Write a 16-bit word to PCI config space (read-modify-write).
fn pciWriteWord(bus: u8, slot: u8, func: u8, offset: u8, val: u16) void {
    const aligned = offset & 0xFC;
    var dword = pci.readConfig(bus, slot, func, aligned);
    const shift: u5 = @truncate((offset & 0x02) * 8);
    dword &= ~(@as(u32, 0xFFFF) << shift);
    dword |= @as(u32, val) << shift;
    pci.writeConfig(bus, slot, func, aligned, dword);
}

/// Check if a PCI device has capabilities.
fn hasCapabilities(bus: u8, slot: u8, func: u8) bool {
    // Status register bit 4 = capabilities list
    const status = pciReadWord(bus, slot, func, 0x06);
    return (status & (1 << 4)) != 0;
}

/// Get the first capability pointer.
fn getCapPointer(bus: u8, slot: u8, func: u8) u8 {
    // Capabilities pointer at offset 0x34 (for normal devices)
    return pciReadByte(bus, slot, func, 0x34) & 0xFC;
}

/// Find a PCI capability by ID. Returns the offset or null.
fn findCapability(bus: u8, slot: u8, func: u8, cap_id: u8) ?u8 {
    if (!hasCapabilities(bus, slot, func)) return null;

    var ptr = getCapPointer(bus, slot, func);
    var limit: u8 = 48; // Safety limit (prevent infinite loops)

    while (ptr != 0 and limit > 0) : (limit -= 1) {
        const id = pciReadByte(bus, slot, func, ptr);
        if (id == cap_id) return ptr;
        ptr = pciReadByte(bus, slot, func, ptr + 1) & 0xFC;
    }

    return null;
}

// ---- Public API: MSI ----

/// Find MSI capability for a PCI device. Returns capability offset or null.
pub fn findMsiCapability(bus: u8, slot: u8, func: u8) ?u8 {
    return findCapability(bus, slot, func, CAP_ID_MSI);
}

/// Get detailed MSI capability information.
pub fn getMsiInfo(bus: u8, slot: u8, func: u8) ?MsiCapInfo {
    const cap_off = findCapability(bus, slot, func, CAP_ID_MSI) orelse return null;

    const msg_ctrl = pciReadWord(bus, slot, func, cap_off + MSI_MSG_CTRL);

    const mmc = @as(u8, @truncate((msg_ctrl & MSGCTRL_MMC_MASK) >> MSGCTRL_MMC_SHIFT));
    const mme = @as(u8, @truncate((msg_ctrl & MSGCTRL_MME_MASK) >> MSGCTRL_MME_SHIFT));

    return .{
        .cap_offset = cap_off,
        .is_64bit = (msg_ctrl & MSGCTRL_64BIT) != 0,
        .per_vector_mask = (msg_ctrl & MSGCTRL_PVM) != 0,
        .max_vectors = @as(u8, 1) << @truncate(mmc),
        .enabled_vectors = @as(u8, 1) << @truncate(mme),
        .is_enabled = (msg_ctrl & MSGCTRL_ENABLE) != 0,
    };
}

/// Enable MSI for a PCI device with a specific vector.
/// Configures the device to send interrupt messages to the BSP (APIC ID 0).
pub fn enableMsi(bus: u8, slot: u8, func: u8, vector: u8) bool {
    const cap_off = findCapability(bus, slot, func, CAP_ID_MSI) orelse return false;

    var msg_ctrl = pciReadWord(bus, slot, func, cap_off + MSI_MSG_CTRL);
    const is_64bit = (msg_ctrl & MSGCTRL_64BIT) != 0;

    // Build MSI address: target APIC ID 0 (BSP), physical destination
    const msg_addr: u32 = MSI_ADDR_BASE; // APIC ID 0

    // Build MSI data: edge trigger, fixed delivery, vector
    const msg_data: u16 = @as(u16, vector);

    // Write message address
    pci.writeConfig(bus, slot, func, cap_off + MSI_MSG_ADDR, msg_addr);

    if (is_64bit) {
        // Upper address = 0 for 32-bit physical space
        pci.writeConfig(bus, slot, func, cap_off + MSI_MSG_ADDR_HI, 0);
        // Data register at +0x0C for 64-bit
        pciWriteWord(bus, slot, func, cap_off + MSI_MSG_DATA_64, msg_data);
    } else {
        // Data register at +0x08 for 32-bit
        pciWriteWord(bus, slot, func, cap_off + MSI_MSG_DATA_32, msg_data);
    }

    // Enable MSI, single vector (MME = 0)
    msg_ctrl &= ~MSGCTRL_MME_MASK; // Clear MME
    msg_ctrl |= MSGCTRL_ENABLE; // Set enable
    pciWriteWord(bus, slot, func, cap_off + MSI_MSG_CTRL, msg_ctrl);

    // Also disable legacy INTx
    const cmd = pciReadWord(bus, slot, func, 0x04);
    pciWriteWord(bus, slot, func, 0x04, cmd | (1 << 10)); // Interrupt Disable bit

    serial.write("[MSI] Enabled vec=0x");
    serialHex8(vector);
    serial.write(" for ");
    serialHex8(bus);
    serial.write(":");
    serialHex8(slot);
    serial.write(".");
    serialHex8(func);
    serial.write("\n");

    return true;
}

/// Enable MSI with a specific destination APIC ID and delivery mode.
pub fn enableMsiAdvanced(bus: u8, slot: u8, func: u8, vector: u8, dest_apic: u8, delivery: MsiDeliveryMode) bool {
    const cap_off = findCapability(bus, slot, func, CAP_ID_MSI) orelse return false;

    var msg_ctrl = pciReadWord(bus, slot, func, cap_off + MSI_MSG_CTRL);
    const is_64bit = (msg_ctrl & MSGCTRL_64BIT) != 0;

    const msg_addr: u32 = MSI_ADDR_BASE | (@as(u32, dest_apic) << MSI_ADDR_DEST_SHIFT);
    const msg_data: u16 = (@as(u16, @intFromEnum(delivery)) << 8) | @as(u16, vector);

    pci.writeConfig(bus, slot, func, cap_off + MSI_MSG_ADDR, msg_addr);

    if (is_64bit) {
        pci.writeConfig(bus, slot, func, cap_off + MSI_MSG_ADDR_HI, 0);
        pciWriteWord(bus, slot, func, cap_off + MSI_MSG_DATA_64, msg_data);
    } else {
        pciWriteWord(bus, slot, func, cap_off + MSI_MSG_DATA_32, msg_data);
    }

    msg_ctrl &= ~MSGCTRL_MME_MASK;
    msg_ctrl |= MSGCTRL_ENABLE;
    pciWriteWord(bus, slot, func, cap_off + MSI_MSG_CTRL, msg_ctrl);

    return true;
}

/// Disable MSI for a PCI device.
pub fn disableMsi(bus: u8, slot: u8, func: u8) bool {
    const cap_off = findCapability(bus, slot, func, CAP_ID_MSI) orelse return false;

    var msg_ctrl = pciReadWord(bus, slot, func, cap_off + MSI_MSG_CTRL);
    msg_ctrl &= ~MSGCTRL_ENABLE;
    pciWriteWord(bus, slot, func, cap_off + MSI_MSG_CTRL, msg_ctrl);

    // Re-enable legacy INTx
    const cmd = pciReadWord(bus, slot, func, 0x04);
    pciWriteWord(bus, slot, func, 0x04, cmd & ~@as(u16, 1 << 10));

    return true;
}

// ---- Public API: MSI-X ----

/// Find MSI-X capability for a PCI device.
pub fn findMsixCapability(bus: u8, slot: u8, func: u8) ?u8 {
    return findCapability(bus, slot, func, CAP_ID_MSIX);
}

/// Get MSI-X capability information.
pub fn getMsixInfo(bus: u8, slot: u8, func: u8) ?MsixCapInfo {
    const cap_off = findCapability(bus, slot, func, CAP_ID_MSIX) orelse return null;

    const msg_ctrl = pciReadWord(bus, slot, func, cap_off + MSIX_MSG_CTRL);
    const table_reg = pci.readConfig(bus, slot, func, cap_off + MSIX_TABLE_OFFSET);
    const pba_reg = pci.readConfig(bus, slot, func, cap_off + MSIX_PBA_OFFSET);

    return .{
        .cap_offset = cap_off,
        .table_size = (msg_ctrl & MSIX_CTRL_TABLE_SIZE_MASK) + 1,
        .table_bar = @truncate(table_reg & 0x07),
        .table_offset = table_reg & 0xFFFFFFF8,
        .pba_bar = @truncate(pba_reg & 0x07),
        .pba_offset = pba_reg & 0xFFFFFFF8,
        .is_enabled = (msg_ctrl & MSIX_CTRL_ENABLE) != 0,
        .func_mask = (msg_ctrl & MSIX_CTRL_FUNC_MASK) != 0,
    };
}

/// Check if device has MSI-X support.
pub fn hasMsix(bus: u8, slot: u8, func: u8) bool {
    return findCapability(bus, slot, func, CAP_ID_MSIX) != null;
}

/// Check if device has MSI support.
pub fn hasMsi(bus: u8, slot: u8, func: u8) bool {
    return findCapability(bus, slot, func, CAP_ID_MSI) != null;
}

// ---- Display ----

/// Print MSI/MSI-X capability info for a specific PCI device.
pub fn printMsiInfo(bus: u8, slot: u8, func: u8) void {
    vga.setColor(.yellow, .black);
    vga.write("MSI Info for ");
    printHex8(bus);
    vga.putChar(':');
    printHex8(slot);
    vga.putChar('.');
    printDecU8(func);
    vga.write(":\n");
    vga.setColor(.light_grey, .black);

    // MSI
    if (getMsiInfo(bus, slot, func)) |info| {
        vga.write("  MSI Capability at offset 0x");
        printHex8(info.cap_offset);
        vga.putChar('\n');

        vga.write("    Enabled:          ");
        if (info.is_enabled) vga.write("Yes\n") else vga.write("No\n");

        vga.write("    64-bit:           ");
        if (info.is_64bit) vga.write("Yes\n") else vga.write("No\n");

        vga.write("    Per-vector mask:  ");
        if (info.per_vector_mask) vga.write("Yes\n") else vga.write("No\n");

        vga.write("    Max vectors:      ");
        printDecU8(info.max_vectors);
        vga.putChar('\n');

        vga.write("    Enabled vectors:  ");
        printDecU8(info.enabled_vectors);
        vga.putChar('\n');
    } else {
        vga.write("  No MSI capability\n");
    }

    // MSI-X
    if (getMsixInfo(bus, slot, func)) |info| {
        vga.write("  MSI-X Capability at offset 0x");
        printHex8(info.cap_offset);
        vga.putChar('\n');

        vga.write("    Enabled:      ");
        if (info.is_enabled) vga.write("Yes\n") else vga.write("No\n");

        vga.write("    Table size:   ");
        printDec16(info.table_size);
        vga.putChar('\n');

        vga.write("    Table BAR:    ");
        printDecU8(info.table_bar);
        vga.write("  Offset: 0x");
        printHex32(info.table_offset);
        vga.putChar('\n');

        vga.write("    PBA BAR:      ");
        printDecU8(info.pba_bar);
        vga.write("  Offset: 0x");
        printHex32(info.pba_offset);
        vga.putChar('\n');

        vga.write("    Func mask:    ");
        if (info.func_mask) vga.write("Yes\n") else vga.write("No\n");
    } else {
        vga.write("  No MSI-X capability\n");
    }
}

/// Scan all PCI devices and print MSI support status.
pub fn printAllMsiDevices() void {
    vga.setColor(.yellow, .black);
    vga.write("PCI MSI/MSI-X Capable Devices:\n");
    vga.setColor(.light_grey, .black);

    var found: u8 = 0;

    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        var func: u8 = 0;
        while (func < 8) : (func += 1) {
            const r0 = pci.readConfig(0, slot, func, 0x00);
            const vid: u16 = @truncate(r0);
            if (vid == 0xFFFF) {
                if (func == 0) break;
                continue;
            }

            const has_m = hasMsi(0, slot, func);
            const has_mx = hasMsix(0, slot, func);

            if (has_m or has_mx) {
                vga.write("  00:");
                printHex8(slot);
                vga.putChar('.');
                printDecU8(func);
                vga.write("  ");
                printHex16(@truncate(r0));
                vga.putChar(':');
                printHex16(@truncate(r0 >> 16));
                if (has_m) vga.write("  [MSI]");
                if (has_mx) vga.write("  [MSI-X]");
                vga.putChar('\n');
                found += 1;
            }

            if (func == 0) {
                const hdr: u8 = @truncate(pci.readConfig(0, slot, 0, 0x0C) >> 16);
                if (hdr & 0x80 == 0) break;
            }
        }
    }

    if (found == 0) {
        vga.write("  No MSI-capable devices found\n");
    } else {
        printDecU8(found);
        vga.write(" device(s) with MSI support\n");
    }
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

fn printHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;
    var v = val;
    var i: usize = 4;
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

fn printDec16(val: u16) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [5]u8 = undefined;
    var len: usize = 0;
    var v = val;
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

fn serialHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0xF]);
}
