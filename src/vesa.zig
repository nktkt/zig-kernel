// VESA VBE (Video BIOS Extensions) Mode Information
//
// Parses VBE information blocks passed by the bootloader via Multiboot.
// Provides mode enumeration, mode search, and framebuffer information.
//
// VBE 2.0+ info block is 512 bytes at a physical address given by Multiboot.
// Mode info block is 256 bytes per mode.
//
// Note: Actual VBE BIOS calls (INT 0x10) are not available in protected mode.
// This module works with pre-populated VBE info (from bootloader).

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- VBE Info Block (512 bytes) ----

pub const VbeInfoBlock = extern struct {
    signature: [4]u8, // "VESA"
    version: u16, // VBE version (BCD, e.g., 0x0300 = 3.0)
    oem_string_ptr: u32, // Far pointer to OEM string
    capabilities: u32, // Capability flags
    video_mode_ptr: u32, // Far pointer to mode list
    total_memory: u16, // Number of 64KB blocks
    oem_software_rev: u16,
    oem_vendor_name_ptr: u32,
    oem_product_name_ptr: u32,
    oem_product_rev_ptr: u32,
    reserved: [222]u8,
    oem_data: [256]u8,
};

// ---- VBE Mode Info Block (256 bytes) ----

pub const ModeInfo = extern struct {
    // Mandatory info (all VBE versions)
    mode_attributes: u16,
    win_a_attributes: u8,
    win_b_attributes: u8,
    win_granularity: u16, // Window granularity in KB
    win_size: u16, // Window size in KB
    win_a_segment: u16,
    win_b_segment: u16,
    win_func_ptr: u32, // Far pointer to windowed mode function
    bytes_per_scanline: u16, // Pitch

    // VBE 1.2+
    x_resolution: u16,
    y_resolution: u16,
    x_char_size: u8,
    y_char_size: u8,
    number_of_planes: u8,
    bits_per_pixel: u8,
    number_of_banks: u8,
    memory_model: u8,
    bank_size: u8,
    number_of_image_pages: u8,
    reserved1: u8,

    // Direct Color fields
    red_mask_size: u8,
    red_field_position: u8,
    green_mask_size: u8,
    green_field_position: u8,
    blue_mask_size: u8,
    blue_field_position: u8,
    reserved_mask_size: u8,
    reserved_field_position: u8,
    direct_color_mode_info: u8,

    // VBE 2.0+
    framebuffer_addr: u32, // Physical address of LFB
    off_screen_mem_offset: u32,
    off_screen_mem_size: u16,

    // VBE 3.0+
    lin_bytes_per_scanline: u16,
    bnk_number_of_image_pages: u8,
    lin_number_of_image_pages: u8,
    lin_red_mask_size: u8,
    lin_red_field_position: u8,
    lin_green_mask_size: u8,
    lin_green_field_position: u8,
    lin_blue_mask_size: u8,
    lin_blue_field_position: u8,
    lin_reserved_mask_size: u8,
    lin_reserved_field_position: u8,
    max_pixel_clock: u32,

    reserved2: [189]u8,
};

// ---- Memory model types ----

pub const MemoryModel = enum(u8) {
    text = 0x00,
    cga = 0x01,
    hercules = 0x02,
    planar = 0x03,
    packed_pixel = 0x04,
    non_chain_4 = 0x05,
    direct_color = 0x06,
    yuv = 0x07,
    _,
};

// ---- VBE Capability bits ----

const CAP_DAC_SWITCHABLE: u32 = 1 << 0;
const CAP_NOT_VGA_COMPAT: u32 = 1 << 1;
const CAP_RAMDAC_BLANK: u32 = 1 << 2;

// ---- Mode attribute bits ----

const MODE_SUPPORTED: u16 = 1 << 0;
const MODE_COLOR: u16 = 1 << 3;
const MODE_GRAPHICS: u16 = 1 << 4;
const MODE_NOT_VGA_COMPAT: u16 = 1 << 5;
const MODE_NO_WINDOWED: u16 = 1 << 6;
const MODE_LFB_AVAIL: u16 = 1 << 7;

// ---- Simplified mode entry ----

pub const SimpleModeInfo = struct {
    mode_number: u16,
    width: u16,
    height: u16,
    bpp: u8,
    framebuffer_addr: u32,
    pitch: u16,
    memory_model: u8,
    has_lfb: bool,
};

// ---- State ----

var vbe_info_addr: u32 = 0;
var vbe_mode_info_addr: u32 = 0;
var current_mode: u16 = 0;
var vbe_present: bool = false;
var vbe_version: u16 = 0;
var total_memory_kb: u32 = 0;

// Mode cache
const MAX_MODES = 64;
var mode_cache: [MAX_MODES]SimpleModeInfo = @splat(SimpleModeInfo{
    .mode_number = 0xFFFF,
    .width = 0,
    .height = 0,
    .bpp = 0,
    .framebuffer_addr = 0,
    .pitch = 0,
    .memory_model = 0,
    .has_lfb = false,
});
var mode_count: usize = 0;

// ---- Initialization ----

/// Initialize VESA module with Multiboot VBE info addresses.
pub fn initFromMultiboot(info_addr: u32, mode_info_addr: u32, mode_num: u16) void {
    vbe_info_addr = info_addr;
    vbe_mode_info_addr = mode_info_addr;
    current_mode = mode_num;

    if (info_addr == 0) {
        vbe_present = false;
        serial.write("[VESA] No VBE info from bootloader\n");
        return;
    }

    // Validate VBE info block signature
    const sig: [*]const u8 = @ptrFromInt(info_addr);
    if (sig[0] != 'V' or sig[1] != 'E' or sig[2] != 'S' or sig[3] != 'A') {
        vbe_present = false;
        serial.write("[VESA] Invalid VBE signature\n");
        return;
    }

    const info: *const VbeInfoBlock = @ptrFromInt(info_addr);
    vbe_version = info.version;
    total_memory_kb = @as(u32, info.total_memory) * 64;
    vbe_present = true;

    // Parse mode list
    parseModeList(info.video_mode_ptr);

    serial.write("[VESA] VBE ");
    serialDecU8(@truncate(vbe_version >> 8));
    serial.write(".");
    serialDecU8(@truncate(vbe_version & 0xFF));
    serial.write(" VRAM=");
    serialDec32(total_memory_kb);
    serial.write("KB modes=");
    serialDec32(@truncate(mode_count));
    serial.write("\n");
}

/// Initialize without Multiboot (try to use saved VBE info).
pub fn init() void {
    vbe_present = false;
    mode_count = 0;
}

// ---- Mode list parsing ----

fn parseModeList(mode_ptr: u32) void {
    mode_count = 0;

    if (mode_ptr == 0 or mode_ptr >= 0x100000) return;

    // Convert real-mode far pointer: segment:offset -> linear
    const segment = (mode_ptr >> 16) & 0xFFFF;
    const offset = mode_ptr & 0xFFFF;
    const linear = segment * 16 + offset;

    if (linear == 0 or linear >= 0x100000) return;

    const modes: [*]const u16 = @ptrFromInt(linear);

    var i: usize = 0;
    while (i < 256 and mode_count < MAX_MODES) : (i += 1) {
        const mode_num = modes[i];
        if (mode_num == 0xFFFF) break; // End of mode list

        // Store basic entry (details require BIOS call, which we can't do in PM)
        mode_cache[mode_count] = .{
            .mode_number = mode_num,
            .width = 0,
            .height = 0,
            .bpp = 0,
            .framebuffer_addr = 0,
            .pitch = 0,
            .memory_model = 0,
            .has_lfb = false,
        };
        mode_count += 1;
    }
}

// ---- Query functions ----

/// Check if VBE is present.
pub fn isPresent() bool {
    return vbe_present;
}

/// Get VBE version (BCD format, e.g., 0x0300 for VBE 3.0).
pub fn getVersion() u16 {
    return vbe_version;
}

/// Get total video memory in kilobytes.
pub fn getTotalMemoryKB() u32 {
    return total_memory_kb;
}

/// Get the current VBE mode number.
pub fn getCurrentMode() u16 {
    return current_mode;
}

/// Get the number of available modes.
pub fn getModeCount() usize {
    return mode_count;
}

/// Get mode info for a mode by index.
pub fn getModeByIndex(idx: usize) ?*const SimpleModeInfo {
    if (idx >= mode_count) return null;
    return &mode_cache[idx];
}

/// Get the current mode info block (from Multiboot).
pub fn getCurrentModeInfo() ?*const ModeInfo {
    if (vbe_mode_info_addr == 0) return null;
    return @ptrFromInt(vbe_mode_info_addr);
}

/// Search for a mode matching the given resolution and color depth.
pub fn findMode(width: u16, height: u16, bpp: u8) ?u16 {
    for (mode_cache[0..mode_count]) |*m| {
        if (m.width == width and m.height == height and m.bpp == bpp) {
            return m.mode_number;
        }
    }
    return null;
}

/// Get mode info for a specific mode number.
pub fn getModeInfo(mode: u16) ?*const SimpleModeInfo {
    for (&mode_cache) |*m| {
        if (m.mode_number == mode) return m;
    }
    return null;
}

/// Check if a mode has a Linear Frame Buffer.
pub fn hasLinearFramebuffer(mode: u16) bool {
    if (getModeInfo(mode)) |m| {
        return m.has_lfb;
    }
    return false;
}

/// Calculate the memory required for a given mode in bytes.
pub fn calculateMemorySize(width: u16, height: u16, bpp: u8) u32 {
    const pitch: u32 = (@as(u32, width) * bpp + 7) / 8;
    return pitch * @as(u32, height);
}

/// Get the current framebuffer address (from Multiboot mode info).
pub fn getFramebufferAddr() u32 {
    if (getCurrentModeInfo()) |mi| {
        return mi.framebuffer_addr;
    }
    return 0;
}

/// Get the current framebuffer pitch (bytes per scanline).
pub fn getFramebufferPitch() u16 {
    if (getCurrentModeInfo()) |mi| {
        return mi.bytes_per_scanline;
    }
    return 0;
}

/// Get the memory model name.
pub fn getMemoryModelName(model: u8) []const u8 {
    return switch (model) {
        0x00 => "Text",
        0x01 => "CGA",
        0x02 => "Hercules",
        0x03 => "Planar",
        0x04 => "Packed Pixel",
        0x05 => "Non-Chain 4",
        0x06 => "Direct Color",
        0x07 => "YUV",
        else => "Unknown",
    };
}

// ---- Display functions ----

/// Print all available VBE modes.
pub fn printAvailableModes() void {
    vga.setColor(.yellow, .black);
    vga.write("VBE Modes (");
    printDec(mode_count);
    vga.write(" available):\n");
    vga.setColor(.light_grey, .black);

    if (!vbe_present) {
        vga.write("  VBE not available\n");
        return;
    }

    if (mode_count == 0) {
        vga.write("  No modes enumerated\n");
        return;
    }

    vga.write("  MODE    RESOLUTION   BPP  MODEL         LFB   ADDR\n");
    vga.write("  -------------------------------------------------------\n");

    for (mode_cache[0..mode_count]) |*m| {
        vga.write("  0x");
        printHex16(m.mode_number);
        vga.write("  ");

        if (m.width > 0) {
            printDecPad(m.width, 4);
            vga.write("x");
            printDecPad(m.height, 4);
            vga.write("  ");
            printDecPad(m.bpp, 2);
            vga.write("   ");
            vga.write(getMemoryModelName(m.memory_model));

            // Pad model name to 13 chars
            var name_len = getMemoryModelName(m.memory_model).len;
            while (name_len < 13) : (name_len += 1) {
                vga.putChar(' ');
            }

            if (m.has_lfb) vga.write(" Yes") else vga.write(" No ");

            vga.write("  0x");
            printHex32(m.framebuffer_addr);
        } else {
            vga.write("(details unavailable)");
        }
        vga.putChar('\n');
    }
}

/// Print current VBE mode information.
pub fn printCurrentMode() void {
    vga.setColor(.yellow, .black);
    vga.write("Current VBE Mode:\n");
    vga.setColor(.light_grey, .black);

    if (!vbe_present) {
        vga.write("  VBE not available\n");
        return;
    }

    vga.write("  Mode number: 0x");
    printHex16(current_mode);
    vga.putChar('\n');

    if (getCurrentModeInfo()) |mi| {
        vga.write("  Resolution:  ");
        printDec16(mi.x_resolution);
        vga.write("x");
        printDec16(mi.y_resolution);
        vga.putChar('\n');

        vga.write("  BPP:         ");
        printDecU8(mi.bits_per_pixel);
        vga.putChar('\n');

        vga.write("  Pitch:       ");
        printDec16(mi.bytes_per_scanline);
        vga.write(" bytes\n");

        vga.write("  Memory Model:");
        vga.write(getMemoryModelName(mi.memory_model));
        vga.putChar('\n');

        vga.write("  Framebuffer: 0x");
        printHex32(mi.framebuffer_addr);
        vga.putChar('\n');

        vga.write("  Color Mask:  R=");
        printDecU8(mi.red_mask_size);
        vga.write("@");
        printDecU8(mi.red_field_position);
        vga.write(" G=");
        printDecU8(mi.green_mask_size);
        vga.write("@");
        printDecU8(mi.green_field_position);
        vga.write(" B=");
        printDecU8(mi.blue_mask_size);
        vga.write("@");
        printDecU8(mi.blue_field_position);
        vga.putChar('\n');

        // LFB available
        vga.write("  LFB:         ");
        if (mi.mode_attributes & MODE_LFB_AVAIL != 0) {
            vga.write("Yes\n");
        } else {
            vga.write("No\n");
        }

        // Memory needed
        const mem_needed = calculateMemorySize(mi.x_resolution, mi.y_resolution, mi.bits_per_pixel);
        vga.write("  FB Size:     ");
        printDec32(mem_needed / 1024);
        vga.write(" KB\n");
    } else {
        vga.write("  No mode info available\n");
    }
}

/// Print VBE info block summary.
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("VESA VBE Info:\n");
    vga.setColor(.light_grey, .black);

    if (!vbe_present) {
        vga.write("  VBE not present\n");
        return;
    }

    vga.write("  Version:     ");
    printDecU8(@truncate(vbe_version >> 8));
    vga.putChar('.');
    printDecU8(@truncate(vbe_version & 0xFF));
    vga.putChar('\n');

    vga.write("  Video RAM:   ");
    if (total_memory_kb >= 1024) {
        printDec32(total_memory_kb / 1024);
        vga.write(" MB\n");
    } else {
        printDec32(total_memory_kb);
        vga.write(" KB\n");
    }

    vga.write("  Modes:       ");
    printDec(mode_count);
    vga.putChar('\n');

    vga.write("  Current:     0x");
    printHex16(current_mode);
    vga.putChar('\n');

    // Print VBE capabilities if info block available
    if (vbe_info_addr != 0) {
        const info: *const VbeInfoBlock = @ptrFromInt(vbe_info_addr);
        vga.write("  Capabilities:");
        if (info.capabilities & CAP_DAC_SWITCHABLE != 0) vga.write(" DAC");
        if (info.capabilities & CAP_NOT_VGA_COMPAT != 0) vga.write(" NonVGA");
        if (info.capabilities & CAP_RAMDAC_BLANK != 0) vga.write(" RAMDACBlank");
        if (info.capabilities == 0) vga.write(" (none)");
        vga.putChar('\n');
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

fn printDec32(n: u32) void {
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

fn printDecPad(val: u16, width: u16) void {
    var digits: u16 = 0;
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
    printDec16(val);
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

fn serialDec32(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}
