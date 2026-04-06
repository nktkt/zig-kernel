// Intel HD Audio Controller Driver -- PCI class 0x04/0x03 detection
//
// Detects HDA controllers via PCI, reads BAR0 for MMIO registers,
// performs controller reset, enumerates codecs, and reads widget info.
// Based on Intel High Definition Audio Specification Rev 1.0a.

const idt = @import("idt.zig");
const pci = @import("pci.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- HDA Register Offsets (from BAR0 MMIO base) ----

const GCAP: u32 = 0x00; // Global Capabilities (16-bit)
const VMIN: u32 = 0x02; // Minor Version (8-bit)
const VMAJ: u32 = 0x03; // Major Version (8-bit)
const OUTPAY: u32 = 0x04; // Output Payload Capability (16-bit)
const INPAY: u32 = 0x06; // Input Payload Capability (16-bit)
const GCTL: u32 = 0x08; // Global Control (32-bit)
const WAKEEN: u32 = 0x0C; // Wake Enable (16-bit)
const STATESTS: u32 = 0x0E; // State Change Status (16-bit)
const GSTS: u32 = 0x10; // Global Status (16-bit)
const INTCTL: u32 = 0x20; // Interrupt Control (32-bit)
const INTSTS: u32 = 0x24; // Interrupt Status (32-bit)
const WALCLK: u32 = 0x30; // Wall Clock Counter (32-bit)
const CORBLBASE: u32 = 0x40; // CORB Lower Base Address (32-bit)
const CORBUBASE: u32 = 0x44; // CORB Upper Base Address (32-bit)
const CORBWP: u32 = 0x48; // CORB Write Pointer (16-bit)
const CORBRP: u32 = 0x4A; // CORB Read Pointer (16-bit)
const CORBCTL: u32 = 0x4C; // CORB Control (8-bit)
const CORBSTS: u32 = 0x4D; // CORB Status (8-bit)
const CORBSIZE: u32 = 0x4E; // CORB Size (8-bit)
const RIRBLBASE: u32 = 0x50; // RIRB Lower Base Address (32-bit)
const RIRBUBASE: u32 = 0x54; // RIRB Upper Base Address (32-bit)
const RIRBWP: u32 = 0x58; // RIRB Write Pointer (16-bit)
const RINTCNT: u32 = 0x5A; // Response Interrupt Count (16-bit)
const RIRBCTL: u32 = 0x5C; // RIRB Control (8-bit)
const RIRBSTS: u32 = 0x5D; // RIRB Status (8-bit)
const RIRBSIZE: u32 = 0x5E; // RIRB Size (8-bit)

// ---- GCTL bits ----

const GCTL_CRST: u32 = 0x01; // Controller Reset
const GCTL_FCNTRL: u32 = 0x02; // Flush Control
const GCTL_UNSOL: u32 = 0x100; // Accept Unsolicited Response Enable

// ---- Widget types ----

pub const WidgetType = enum(u4) {
    audio_output = 0,
    audio_input = 1,
    audio_mixer = 2,
    audio_selector = 3,
    pin_complex = 4,
    power_widget = 5,
    volume_knob = 6,
    beep_generator = 7,
    vendor_defined = 15,
    _,
};

// ---- Codec info ----

pub const CodecInfo = struct {
    address: u8,
    vendor_id: u16,
    device_id: u16,
    revision_id: u32,
    afg_node_id: u8, // Audio Function Group node
    afg_widget_count: u8,
    afg_widget_start: u8,
    present: bool,
};

// ---- Controller state ----

var hda_present: bool = false;
var mmio_base: u32 = 0;
var pci_bus: u8 = 0;
var pci_slot: u8 = 0;
var pci_func: u8 = 0;
var pci_vendor: u16 = 0;
var pci_device: u16 = 0;
var hda_version_major: u8 = 0;
var hda_version_minor: u8 = 0;
var global_caps: u16 = 0;
var num_output_streams: u4 = 0;
var num_input_streams: u4 = 0;
var num_bidirectional_streams: u4 = 0;

const MAX_CODECS = 4;
var codecs: [MAX_CODECS]CodecInfo = @splat(CodecInfo{
    .address = 0,
    .vendor_id = 0,
    .device_id = 0,
    .revision_id = 0,
    .afg_node_id = 0,
    .afg_widget_count = 0,
    .afg_widget_start = 0,
    .present = false,
});
var codec_count: u8 = 0;

// ---- MMIO read/write ----

fn mmioRead8(offset: u32) u8 {
    if (mmio_base == 0) return 0;
    const ptr: *volatile u8 = @ptrFromInt(mmio_base + offset);
    return ptr.*;
}

fn mmioRead16(offset: u32) u16 {
    if (mmio_base == 0) return 0;
    const ptr: *volatile u16 = @ptrFromInt(mmio_base + offset);
    return ptr.*;
}

fn mmioRead32(offset: u32) u32 {
    if (mmio_base == 0) return 0;
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    return ptr.*;
}

fn mmioWrite32(offset: u32, val: u32) void {
    if (mmio_base == 0) return;
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    ptr.* = val;
}

fn mmioWrite16(offset: u32, val: u16) void {
    if (mmio_base == 0) return;
    const ptr: *volatile u16 = @ptrFromInt(mmio_base + offset);
    ptr.* = val;
}

fn mmioWrite8(offset: u32, val: u8) void {
    if (mmio_base == 0) return;
    const ptr: *volatile u8 = @ptrFromInt(mmio_base + offset);
    ptr.* = val;
}

// ---- Delay helper ----

fn delayMs(ms: u32) void {
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        asm volatile ("pause");
    }
}

// ---- Controller reset ----

fn resetController() bool {
    // Put controller into reset
    var gctl = mmioRead32(GCTL);
    gctl &= ~GCTL_CRST;
    mmioWrite32(GCTL, gctl);

    // Wait for reset to take effect (CRST bit should read 0)
    var timeout: u32 = 0;
    while (timeout < 100) : (timeout += 1) {
        delayMs(1);
        if (mmioRead32(GCTL) & GCTL_CRST == 0) break;
    }
    if (mmioRead32(GCTL) & GCTL_CRST != 0) return false;

    // Bring controller out of reset
    delayMs(1);
    gctl = mmioRead32(GCTL);
    gctl |= GCTL_CRST;
    mmioWrite32(GCTL, gctl);

    // Wait for controller to exit reset (CRST bit should read 1)
    timeout = 0;
    while (timeout < 100) : (timeout += 1) {
        delayMs(1);
        if (mmioRead32(GCTL) & GCTL_CRST != 0) break;
    }
    if (mmioRead32(GCTL) & GCTL_CRST == 0) return false;

    // Wait for codecs to initialize
    delayMs(10);

    return true;
}

// ---- Codec enumeration ----

/// Send a verb to a codec via immediate command interface (polling mode).
/// verb format: [codec_addr:4][node_id:8][verb_payload:20]
fn sendVerb(codec_addr: u8, node_id: u8, verb: u32) ?u32 {
    // Use the Immediate Command Output Interface (ICO/ICI)
    // ICO at offset 0x60, ICI at offset 0x64, ICS at offset 0x68
    const ICO: u32 = 0x60;
    const ICI: u32 = 0x64;
    const ICS: u32 = 0x68;

    // Build command: codec_addr(28:31) | node_id(20:27) | verb(0:19)
    const cmd = (@as(u32, codec_addr) << 28) | (@as(u32, node_id) << 20) | (verb & 0xFFFFF);

    // Wait for ICB (Immediate Command Busy) to clear
    var timeout: u32 = 0;
    while (timeout < 1000) : (timeout += 1) {
        if (mmioRead16(ICS) & 0x01 == 0) break;
        delayMs(1);
    }
    if (mmioRead16(ICS) & 0x01 != 0) return null;

    // Clear IRV (Immediate Result Valid) bit
    mmioWrite16(ICS, 0x02);

    // Write command
    mmioWrite32(ICO, cmd);

    // Set ICB to start transfer
    mmioWrite16(ICS, mmioRead16(ICS) | 0x01);

    // Wait for IRV bit to be set (result valid)
    timeout = 0;
    while (timeout < 1000) : (timeout += 1) {
        const ics = mmioRead16(ICS);
        if (ics & 0x02 != 0) break;
        if (ics & 0x01 == 0) break; // ICB cleared = done
        delayMs(1);
    }

    // Check if result is valid
    if (mmioRead16(ICS) & 0x02 == 0) return null;

    return mmioRead32(ICI);
}

/// Enumerate codecs by checking STATESTS register.
fn enumerateCodecs() void {
    codec_count = 0;

    const statests = mmioRead16(STATESTS);

    var addr: u8 = 0;
    while (addr < MAX_CODECS) : (addr += 1) {
        if (statests & (@as(u16, 1) << @as(u4, @truncate(addr))) == 0) continue;

        // Codec present at this address
        var info = &codecs[codec_count];
        info.address = addr;
        info.present = true;

        // Get vendor/device ID: verb 0xF0000 to root node (0)
        if (sendVerb(addr, 0, 0xF0000)) |resp| {
            info.vendor_id = @truncate(resp >> 16);
            info.device_id = @truncate(resp);
        }

        // Get revision ID: verb 0xF0002 to root node
        if (sendVerb(addr, 0, 0xF0002)) |resp| {
            info.revision_id = resp;
        }

        // Get subordinate node count from root: verb 0xF0004
        if (sendVerb(addr, 0, 0xF0004)) |resp| {
            const start_node: u8 = @truncate(resp >> 16);
            const total_nodes: u8 = @truncate(resp);

            // Look for Audio Function Group (type=1) among subnodes
            var node: u8 = start_node;
            var remaining = total_nodes;
            while (remaining > 0) : ({
                node += 1;
                remaining -= 1;
            }) {
                if (sendVerb(addr, node, 0xF0005)) |fgt| {
                    const fg_type: u8 = @truncate(fgt);
                    if (fg_type == 0x01) {
                        // Audio Function Group found
                        info.afg_node_id = node;

                        // Get widgets under this AFG
                        if (sendVerb(addr, node, 0xF0004)) |sub| {
                            info.afg_widget_start = @truncate(sub >> 16);
                            info.afg_widget_count = @truncate(sub);
                        }
                        break;
                    }
                }
            }
        }

        codec_count += 1;
        if (codec_count >= MAX_CODECS) break;
    }
}

// ---- Public API ----

/// Detect HDA controller via PCI (class 0x04, subclass 0x03).
pub fn init() void {
    hda_present = false;
    codec_count = 0;

    // Scan PCI for audio device: class 0x04, subclass 0x03
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        const r0 = pci.readConfig(0, slot, 0, 0x00);
        const vendor: u16 = @truncate(r0);
        if (vendor == 0xFFFF) continue;

        const r2 = pci.readConfig(0, slot, 0, 0x08);
        const class: u8 = @truncate(r2 >> 24);
        const subclass: u8 = @truncate(r2 >> 16);

        if (class == 0x04 and subclass == 0x03) {
            pci_bus = 0;
            pci_slot = slot;
            pci_func = 0;
            pci_vendor = vendor;
            pci_device = @truncate(r0 >> 16);

            // Read BAR0 (MMIO base)
            const bar0 = pci.readConfig(0, slot, 0, 0x10);
            mmio_base = bar0 & 0xFFFFFFF0; // Clear lower bits

            if (mmio_base == 0) {
                serial.write("[HDA] BAR0 is zero, skipping\n");
                continue;
            }

            // Enable bus mastering and memory space
            pci.enableBusMastering(0, slot, 0);

            hda_present = true;
            break;
        }
    }

    if (!hda_present) {
        serial.write("[HDA] No HD Audio controller found\n");
        return;
    }

    serial.write("[HDA] Found at PCI ");
    serialWriteHex8(pci_bus);
    serial.putChar(':');
    serialWriteHex8(pci_slot);
    serial.write(", BAR0=0x");
    serial.writeHex(mmio_base);
    serial.write("\n");

    // Read version and capabilities
    hda_version_major = mmioRead8(VMAJ);
    hda_version_minor = mmioRead8(VMIN);
    global_caps = mmioRead16(GCAP);

    // Parse GCAP fields
    num_output_streams = @truncate((global_caps >> 12) & 0x0F);
    num_input_streams = @truncate((global_caps >> 8) & 0x0F);
    num_bidirectional_streams = @truncate((global_caps >> 3) & 0x1F);

    // Reset controller
    if (!resetController()) {
        serial.write("[HDA] Controller reset failed\n");
        return;
    }

    // Enumerate codecs
    enumerateCodecs();

    serial.write("[HDA] ");
    serialWriteDec(codec_count);
    serial.write(" codec(s) detected\n");
}

/// Get the number of detected codecs.
pub fn getCodecCount() u8 {
    return codec_count;
}

/// Get codec info by index.
pub fn getCodec(idx: u8) ?*const CodecInfo {
    if (idx >= codec_count) return null;
    return &codecs[idx];
}

/// Check if HDA controller is present.
pub fn isPresent() bool {
    return hda_present;
}

/// Get a widget type from a codec.
pub fn getWidgetType(codec_addr: u8, node_id: u8) ?WidgetType {
    const resp = sendVerb(codec_addr, node_id, 0xF0009) orelse return null;
    const wtype: u4 = @truncate(resp >> 20);
    return @enumFromInt(wtype);
}

/// Get widget capabilities word.
pub fn getWidgetCaps(codec_addr: u8, node_id: u8) ?u32 {
    return sendVerb(codec_addr, node_id, 0xF0009);
}

/// Send end-of-interrupt / acknowledge.
pub fn sendEOI() void {
    if (!hda_present) return;
    // Clear RIRB status
    mmioWrite8(RIRBSTS, 0x05);
}

// ---- Info display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("HD Audio Controller\n");
    vga.setColor(.light_grey, .black);

    if (!hda_present) {
        vga.write("  No HDA controller detected\n");
        return;
    }

    vga.write("  PCI: ");
    fmt.printHex8(pci_bus);
    vga.putChar(':');
    fmt.printHex8(pci_slot);
    vga.write(".0  Vendor: 0x");
    fmt.printHex16(pci_vendor);
    vga.write("  Device: 0x");
    fmt.printHex16(pci_device);
    vga.putChar('\n');

    vga.write("  MMIO Base: 0x");
    fmt.printHex32(mmio_base);
    vga.putChar('\n');

    vga.write("  HDA Version: ");
    fmt.printDec(hda_version_major);
    vga.putChar('.');
    fmt.printDec(hda_version_minor);
    vga.putChar('\n');

    vga.write("  Streams: out=");
    fmt.printDec(num_output_streams);
    vga.write(" in=");
    fmt.printDec(num_input_streams);
    vga.write(" bidir=");
    fmt.printDec(num_bidirectional_streams);
    vga.putChar('\n');

    vga.write("  Codecs: ");
    fmt.printDec(codec_count);
    vga.putChar('\n');

    // Print codec details
    var i: u8 = 0;
    while (i < codec_count) : (i += 1) {
        const c = &codecs[i];
        vga.write("    Codec ");
        fmt.printDec(c.address);
        vga.write(": vendor=0x");
        fmt.printHex16(c.vendor_id);
        vga.write(" dev=0x");
        fmt.printHex16(c.device_id);
        vga.putChar('\n');

        if (c.afg_node_id != 0) {
            vga.write("      AFG node=");
            fmt.printDec(c.afg_node_id);
            vga.write("  widgets: ");
            fmt.printDec(c.afg_widget_start);
            vga.write("-");
            if (c.afg_widget_count > 0) {
                fmt.printDec(@as(usize, c.afg_widget_start) + c.afg_widget_count - 1);
            }
            vga.write(" (");
            fmt.printDec(c.afg_widget_count);
            vga.write(" total)\n");

            // Print first few widget types
            printWidgets(c);
        }
    }
}

fn printWidgets(codec: *const CodecInfo) void {
    const max_show: u8 = 8; // show at most 8 widgets
    var count: u8 = 0;
    var node = codec.afg_widget_start;
    while (count < codec.afg_widget_count and count < max_show) : ({
        node += 1;
        count += 1;
    }) {
        const wtype = getWidgetType(codec.address, node) orelse continue;
        vga.write("      Node ");
        fmt.printDec(node);
        vga.write(": ");
        vga.write(widgetTypeName(wtype));
        vga.putChar('\n');
    }
    if (codec.afg_widget_count > max_show) {
        vga.write("      ... (");
        fmt.printDec(codec.afg_widget_count - max_show);
        vga.write(" more)\n");
    }
}

fn widgetTypeName(wtype: WidgetType) []const u8 {
    return switch (wtype) {
        .audio_output => "Audio Output",
        .audio_input => "Audio Input",
        .audio_mixer => "Audio Mixer",
        .audio_selector => "Audio Selector",
        .pin_complex => "Pin Complex",
        .power_widget => "Power Widget",
        .volume_knob => "Volume Knob",
        .beep_generator => "Beep Generator",
        .vendor_defined => "Vendor Defined",
        _ => "Unknown",
    };
}

// ---- Serial helpers ----

fn serialWriteHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0x0F]);
}

fn serialWriteDec(val: u8) void {
    if (val >= 100) {
        serial.putChar('0' + val / 100);
    }
    if (val >= 10) {
        serial.putChar('0' + (val / 10) % 10);
    }
    serial.putChar('0' + val % 10);
}
