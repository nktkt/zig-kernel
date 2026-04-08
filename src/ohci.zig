// USB OHCI (Open Host Controller Interface) Driver
//
// OHCI is a USB 1.1 host controller standard. It uses memory-mapped I/O
// via PCI BAR0 for register access.
//
// PCI class: 0x0C (Serial Bus), subclass: 0x03 (USB), prog-if: 0x10 (OHCI)
//
// Key register sets:
//   - Control and Status (HcControl, HcCommandStatus)
//   - Memory pointer (HCCA, ED/TD list heads)
//   - Frame management (HcFmInterval, HcFmRemaining, HcFmNumber)
//   - Root hub (HcRhDescriptorA/B, HcRhStatus, HcRhPortStatus)
//
// Data structures: Endpoint Descriptors (ED) and Transfer Descriptors (TD)
// are linked lists in shared memory.

const pci = @import("pci.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- PCI identification ----

const USB_CLASS: u8 = 0x0C; // Serial Bus Controller
const USB_SUBCLASS: u8 = 0x03; // USB
const OHCI_PROGIF: u8 = 0x10; // OHCI

// ---- OHCI Register Offsets (from MMIO base) ----

const HC_REVISION: u32 = 0x000; // HcRevision (RO)
const HC_CONTROL: u32 = 0x004; // HcControl (R/W)
const HC_COMMAND_STATUS: u32 = 0x008; // HcCommandStatus (R/W)
const HC_INTERRUPT_STATUS: u32 = 0x00C; // HcInterruptStatus (R/W)
const HC_INTERRUPT_ENABLE: u32 = 0x010; // HcInterruptEnable (R/W)
const HC_INTERRUPT_DISABLE: u32 = 0x014; // HcInterruptDisable (R/W)
const HC_HCCA: u32 = 0x018; // HcHCCA (R/W)
const HC_PERIOD_CURRENT_ED: u32 = 0x01C; // HcPeriodCurrentED (RO)
const HC_CONTROL_HEAD_ED: u32 = 0x020; // HcControlHeadED (R/W)
const HC_CONTROL_CURRENT_ED: u32 = 0x024; // HcControlCurrentED (R/W)
const HC_BULK_HEAD_ED: u32 = 0x028; // HcBulkHeadED (R/W)
const HC_BULK_CURRENT_ED: u32 = 0x02C; // HcBulkCurrentED (R/W)
const HC_DONE_HEAD: u32 = 0x030; // HcDoneHead (RO)
const HC_FM_INTERVAL: u32 = 0x034; // HcFmInterval (R/W)
const HC_FM_REMAINING: u32 = 0x038; // HcFmRemaining (RO)
const HC_FM_NUMBER: u32 = 0x03C; // HcFmNumber (RO)
const HC_PERIODIC_START: u32 = 0x040; // HcPeriodicStart (R/W)
const HC_LS_THRESHOLD: u32 = 0x044; // HcLSThreshold (R/W)
const HC_RH_DESCRIPTOR_A: u32 = 0x048; // HcRhDescriptorA (R/W)
const HC_RH_DESCRIPTOR_B: u32 = 0x04C; // HcRhDescriptorB (R/W)
const HC_RH_STATUS: u32 = 0x050; // HcRhStatus (R/W)
const HC_RH_PORT_STATUS_BASE: u32 = 0x054; // HcRhPortStatus[0] (R/W)

// ---- HcControl bits ----

const CTRL_CBSR_MASK: u32 = 0x03; // Control/Bulk Service Ratio
const CTRL_PLE: u32 = 1 << 2; // Periodic List Enable
const CTRL_IE: u32 = 1 << 3; // Isochronous Enable
const CTRL_CLE: u32 = 1 << 4; // Control List Enable
const CTRL_BLE: u32 = 1 << 5; // Bulk List Enable
const CTRL_HCFS_MASK: u32 = 0xC0; // Host Controller Functional State
const CTRL_HCFS_SHIFT: u5 = 6;
const CTRL_IR: u32 = 1 << 8; // Interrupt Routing
const CTRL_RWC: u32 = 1 << 9; // Remote Wakeup Connected
const CTRL_RWE: u32 = 1 << 10; // Remote Wakeup Enable

// Host Controller Functional States
const HCFS_RESET: u32 = 0x00;
const HCFS_RESUME: u32 = 0x01;
const HCFS_OPERATIONAL: u32 = 0x02;
const HCFS_SUSPEND: u32 = 0x03;

// ---- HcCommandStatus bits ----

const CMD_HCR: u32 = 1 << 0; // Host Controller Reset
const CMD_CLF: u32 = 1 << 1; // Control List Filled
const CMD_BLF: u32 = 1 << 2; // Bulk List Filled
const CMD_OCR: u32 = 1 << 3; // Ownership Change Request

// ---- HcInterruptStatus/Enable/Disable bits ----

const INT_SO: u32 = 1 << 0; // Scheduling Overrun
const INT_WDH: u32 = 1 << 1; // Writeback Done Head
const INT_SF: u32 = 1 << 2; // Start of Frame
const INT_RD: u32 = 1 << 3; // Resume Detected
const INT_UE: u32 = 1 << 4; // Unrecoverable Error
const INT_FNO: u32 = 1 << 5; // Frame Number Overflow
const INT_RHSC: u32 = 1 << 6; // Root Hub Status Change
const INT_OC: u32 = 1 << 30; // Ownership Change
const INT_MIE: u32 = 1 << 31; // Master Interrupt Enable

// ---- HcRhPortStatus bits ----

const PORT_CCS: u32 = 1 << 0; // Current Connect Status
const PORT_PES: u32 = 1 << 1; // Port Enable Status
const PORT_PSS: u32 = 1 << 2; // Port Suspend Status
const PORT_POCI: u32 = 1 << 3; // Port Over Current Indicator
const PORT_PRS: u32 = 1 << 4; // Port Reset Status
const PORT_PPS: u32 = 1 << 8; // Port Power Status
const PORT_LSDA: u32 = 1 << 9; // Low Speed Device Attached
const PORT_CSC: u32 = 1 << 16; // Connect Status Change
const PORT_PESC: u32 = 1 << 17; // Port Enable Status Change
const PORT_PSSC: u32 = 1 << 18; // Port Suspend Status Change
const PORT_OCIC: u32 = 1 << 19; // Port Over Current Indicator Change
const PORT_PRSC: u32 = 1 << 20; // Port Reset Status Change

// ---- HcRhDescriptorA bits ----

const RHA_NDP_MASK: u32 = 0xFF; // Number of Downstream Ports
const RHA_PSM: u32 = 1 << 8; // Power Switching Mode
const RHA_NPS: u32 = 1 << 9; // No Power Switching
const RHA_DT: u32 = 1 << 10; // Device Type (0 = not compound)
const RHA_OCPM: u32 = 1 << 11; // Over Current Protection Mode
const RHA_NOCP: u32 = 1 << 12; // No Over Current Protection

// ---- Endpoint Descriptor (ED) ----

pub const EndpointDescriptor = extern struct {
    control: u32, // FA[6:0], EN[10:7], D[12:11], S[13], K[14], F[15], MPS[26:16]
    tail_td: u32, // Tail pointer to TD
    head_td: u32, // Head pointer to TD (bits 1:0 are H and C flags)
    next_ed: u32, // Next ED pointer
};

// ---- Transfer Descriptor (TD) ----

pub const TransferDescriptor = extern struct {
    control: u32, // R[18], DP[20:19], DI[23:21], T[25:24], EC[27:26], CC[31:28]
    cbp: u32, // Current Buffer Pointer
    next_td: u32, // Next TD pointer
    be: u32, // Buffer End
};

// ---- HCCA (Host Controller Communication Area, 256 bytes) ----

pub const HCCA = extern struct {
    interrupt_table: [32]u32, // Interrupt ED pointers
    frame_number: u16, // Current frame number
    pad1: u16,
    done_head: u32, // Done head pointer
    reserved: [116]u8,
};

// ---- Condition Codes (from TD) ----

pub const ConditionCode = enum(u4) {
    no_error = 0,
    crc = 1,
    bit_stuffing = 2,
    data_toggle_mismatch = 3,
    stall = 4,
    device_not_responding = 5,
    pid_check_failure = 6,
    unexpected_pid = 7,
    data_overrun = 8,
    data_underrun = 9,
    buffer_overrun = 12,
    buffer_underrun = 13,
    not_accessed = 14,
    not_accessed2 = 15,
    _,
};

// ---- State ----

var mmio_base: u32 = 0;
var detected: bool = false;
var ohci_bus: u8 = 0;
var ohci_slot: u8 = 0;
var ohci_func: u8 = 0;
var vendor_id: u16 = 0;
var device_id: u16 = 0;
var ohci_revision: u8 = 0;
var port_count: u8 = 0;
var operational: bool = false;

// ---- MMIO access ----

fn mmioRead(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    return ptr.*;
}

fn mmioWrite(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    ptr.* = val;
}

// ---- Delay ----

fn delayMs(ms: u32) void {
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        asm volatile ("pause");
    }
}

// ---- Public API ----

/// Detect and initialize OHCI controller.
pub fn init() void {
    detected = false;
    operational = false;
    mmio_base = 0;

    // Scan PCI for OHCI controller
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

            const r2 = pci.readConfig(0, slot, func, 0x08);
            const class: u8 = @truncate(r2 >> 24);
            const subclass: u8 = @truncate(r2 >> 16);
            const progif: u8 = @truncate(r2 >> 8);

            if (class == USB_CLASS and subclass == USB_SUBCLASS and progif == OHCI_PROGIF) {
                // BAR0 = MMIO base
                const bar0 = pci.readConfig(0, slot, func, 0x10);
                if (bar0 & 0x01 == 0 and bar0 != 0) { // Memory space
                    mmio_base = bar0 & 0xFFFFF000;
                    ohci_bus = 0;
                    ohci_slot = slot;
                    ohci_func = func;
                    vendor_id = vid;
                    device_id = @truncate(r0 >> 16);
                    detected = true;

                    // Enable bus mastering and memory space
                    pci.enableBusMastering(0, slot, func);

                    serial.write("[OHCI] found at ");
                    serialHex8(slot);
                    serial.write(" mmio=0x");
                    serialHex32(mmio_base);
                    serial.write("\n");

                    initController();
                    return;
                }
            }

            if (func == 0) {
                const hdr: u8 = @truncate(pci.readConfig(0, slot, 0, 0x0C) >> 16);
                if (hdr & 0x80 == 0) break;
            }
        }
    }

    serial.write("[OHCI] not found\n");
}

fn initController() void {
    // Read revision
    const rev = mmioRead(HC_REVISION);
    ohci_revision = @truncate(rev & 0xFF);

    if (ohci_revision != 0x10 and ohci_revision != 0x11) {
        serial.write("[OHCI] unsupported revision 0x");
        serialHex8(ohci_revision);
        serial.write("\n");
        return;
    }

    // Reset controller
    resetController();

    // Read root hub info
    const rh_desc_a = mmioRead(HC_RH_DESCRIPTOR_A);
    port_count = @truncate(rh_desc_a & RHA_NDP_MASK);

    if (port_count > 15) port_count = 15; // Sanity limit

    serial.write("[OHCI] rev=0x");
    serialHex8(ohci_revision);
    serial.write(" ports=");
    serialDecU8(port_count);
    serial.write("\n");

    operational = true;
}

fn resetController() void {
    // Save FmInterval
    const fm_interval = mmioRead(HC_FM_INTERVAL);

    // Issue software reset
    mmioWrite(HC_COMMAND_STATUS, CMD_HCR);

    // Wait for reset to complete (max 10us, but we wait 1ms to be safe)
    var timeout: u32 = 0;
    while (timeout < 30) : (timeout += 1) {
        if (mmioRead(HC_COMMAND_STATUS) & CMD_HCR == 0) break;
        delayMs(1);
    }

    // Restore FmInterval (toggle FIT bit)
    mmioWrite(HC_FM_INTERVAL, fm_interval ^ (1 << 31));

    // Set HCFS to Operational
    var control = mmioRead(HC_CONTROL);
    control &= ~CTRL_HCFS_MASK;
    control |= HCFS_OPERATIONAL << CTRL_HCFS_SHIFT;
    mmioWrite(HC_CONTROL, control);

    // Set periodic start to 90% of frame interval
    const fi = fm_interval & 0x3FFF;
    mmioWrite(HC_PERIODIC_START, (fi * 9) / 10);

    // Enable all interrupts (except ownership change)
    mmioWrite(HC_INTERRUPT_DISABLE, INT_MIE);
    mmioWrite(HC_INTERRUPT_STATUS, 0xFFFFFFFF); // Clear all
    mmioWrite(HC_INTERRUPT_ENABLE, INT_WDH | INT_RHSC | INT_UE | INT_MIE);

    // Power on all ports
    if (mmioRead(HC_RH_DESCRIPTOR_A) & RHA_NPS == 0) {
        mmioWrite(HC_RH_STATUS, 1 << 16); // Set Global Power (LPSC)
        delayMs(20); // Power settling time
    }
}

/// Check if OHCI controller was detected.
pub fn isDetected() bool {
    return detected;
}

/// Check if controller is in operational state.
pub fn isOperational() bool {
    return operational;
}

/// Get the number of root hub ports.
pub fn getPortCount() u8 {
    return port_count;
}

/// Get the status of a root hub port.
pub fn getPortStatus(port: u8) u32 {
    if (!detected or port >= port_count) return 0;
    return mmioRead(HC_RH_PORT_STATUS_BASE + @as(u32, port) * 4);
}

/// Check if a device is connected to a port.
pub fn isDeviceConnected(port: u8) bool {
    return (getPortStatus(port) & PORT_CCS) != 0;
}

/// Check if port is enabled.
pub fn isPortEnabled(port: u8) bool {
    return (getPortStatus(port) & PORT_PES) != 0;
}

/// Check if a low-speed device is attached.
pub fn isLowSpeed(port: u8) bool {
    return (getPortStatus(port) & PORT_LSDA) != 0;
}

/// Reset a port (initiate bus reset).
pub fn resetPort(port: u8) void {
    if (!detected or port >= port_count) return;
    const reg = HC_RH_PORT_STATUS_BASE + @as(u32, port) * 4;

    // Set Port Reset
    mmioWrite(reg, PORT_PRS);

    // Wait for reset to complete (10ms minimum per USB spec)
    delayMs(50);

    // Clear reset status change
    mmioWrite(reg, PORT_PRSC);
}

/// Enable a port.
pub fn enablePort(port: u8) void {
    if (!detected or port >= port_count) return;
    const reg = HC_RH_PORT_STATUS_BASE + @as(u32, port) * 4;
    mmioWrite(reg, PORT_PES);
}

/// Suspend a port.
pub fn suspendPort(port: u8) void {
    if (!detected or port >= port_count) return;
    const reg = HC_RH_PORT_STATUS_BASE + @as(u32, port) * 4;
    mmioWrite(reg, PORT_PSS);
}

/// Clear connect status change.
pub fn clearConnectChange(port: u8) void {
    if (!detected or port >= port_count) return;
    const reg = HC_RH_PORT_STATUS_BASE + @as(u32, port) * 4;
    mmioWrite(reg, PORT_CSC);
}

/// Get the current frame number.
pub fn getFrameNumber() u16 {
    if (!detected) return 0;
    return @truncate(mmioRead(HC_FM_NUMBER) & 0xFFFF);
}

/// Get the functional state of the controller.
pub fn getFunctionalState() u8 {
    if (!detected) return 0;
    return @truncate((mmioRead(HC_CONTROL) & CTRL_HCFS_MASK) >> CTRL_HCFS_SHIFT);
}

/// Get the controller revision.
pub fn getRevision() u8 {
    return ohci_revision;
}

/// Read a register directly.
pub fn readRegister(offset: u32) u32 {
    if (!detected) return 0;
    return mmioRead(offset);
}

// ---- Display ----

/// Print OHCI controller information.
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("OHCI Controller Info:\n");
    vga.setColor(.light_grey, .black);

    if (!detected) {
        vga.write("  Not detected\n");
        return;
    }

    vga.write("  PCI:      00:");
    printHex8(ohci_slot);
    vga.putChar('.');
    printDecU8(ohci_func);
    vga.write("  VID:DID ");
    printHex16(vendor_id);
    vga.putChar(':');
    printHex16(device_id);
    vga.putChar('\n');

    vga.write("  MMIO:     0x");
    printHex32(mmio_base);
    vga.putChar('\n');

    vga.write("  Revision: ");
    printDecU8(ohci_revision >> 4);
    vga.putChar('.');
    printDecU8(ohci_revision & 0x0F);
    vga.putChar('\n');

    // Functional state
    const state = getFunctionalState();
    vga.write("  State:    ");
    switch (state) {
        0 => vga.write("Reset"),
        1 => vga.write("Resume"),
        2 => {
            vga.setColor(.light_green, .black);
            vga.write("Operational");
            vga.setColor(.light_grey, .black);
        },
        3 => vga.write("Suspended"),
        else => vga.write("Unknown"),
    }
    vga.putChar('\n');

    // Frame interval
    const fi = mmioRead(HC_FM_INTERVAL);
    vga.write("  FmInterval: ");
    printDec32(fi & 0x3FFF);
    vga.write("  Frame: ");
    printDec32(mmioRead(HC_FM_NUMBER) & 0xFFFF);
    vga.putChar('\n');

    // Interrupt status
    const int_status = mmioRead(HC_INTERRUPT_STATUS);
    const int_enable = mmioRead(HC_INTERRUPT_ENABLE);
    vga.write("  IntStatus:  0x");
    printHex32(int_status);
    vga.write("  IntEnable: 0x");
    printHex32(int_enable);
    vga.putChar('\n');

    // Root Hub
    vga.write("  Root Hub Ports: ");
    printDecU8(port_count);
    vga.putChar('\n');

    // Port status
    if (port_count > 0) {
        vga.write("  PORT  CONN  ENABLE  SPEED   POWER  SUSPEND  RESET\n");
        vga.write("  ---------------------------------------------------\n");

        var p: u8 = 0;
        while (p < port_count) : (p += 1) {
            const ps = getPortStatus(p);

            vga.write("  ");
            printDecPad(p, 4);
            vga.write("  ");

            // Connected
            if (ps & PORT_CCS != 0) {
                vga.setColor(.light_green, .black);
                vga.write("Yes ");
                vga.setColor(.light_grey, .black);
            } else {
                vga.write("No  ");
            }
            vga.write("  ");

            // Enabled
            if (ps & PORT_PES != 0) vga.write("Yes   ") else vga.write("No    ");
            vga.write("  ");

            // Speed
            if (ps & PORT_LSDA != 0) vga.write("Low   ") else vga.write("Full  ");
            vga.write("  ");

            // Power
            if (ps & PORT_PPS != 0) vga.write("On  ") else vga.write("Off ");
            vga.write("   ");

            // Suspend
            if (ps & PORT_PSS != 0) vga.write("Yes   ") else vga.write("No    ");
            vga.write("  ");

            // Reset
            if (ps & PORT_PRS != 0) vga.write("Yes") else vga.write("No ");
            vga.putChar('\n');
        }
    }

    // Control register details
    const ctrl = mmioRead(HC_CONTROL);
    vga.write("  Control:    ");
    if (ctrl & CTRL_PLE != 0) vga.write("PLE ");
    if (ctrl & CTRL_IE != 0) vga.write("IE ");
    if (ctrl & CTRL_CLE != 0) vga.write("CLE ");
    if (ctrl & CTRL_BLE != 0) vga.write("BLE ");
    if (ctrl & CTRL_IR != 0) vga.write("IR ");
    if (ctrl & CTRL_RWE != 0) vga.write("RWE ");
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

fn printDec32(val: u32) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
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

fn printDecPad(val: u8, width: u8) void {
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
    var p = width -| digits;
    while (p > 0) : (p -= 1) {
        vga.putChar(' ');
    }
    printDecU8(val);
}

fn serialHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0xF]);
}

fn serialHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| serial.putChar(c);
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
