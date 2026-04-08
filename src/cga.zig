// CGA/EGA/VGA 互換ビデオモードドライバ — モード設定とカーソル制御
//
// VGA レジスタプログラミングによるビデオモード設定.
// テキストモード: 40x25, 80x25. グラフィックスモード: 320x200x4, 640x200x2.
// カーソル形状制御 (開始/終了スキャンライン), 表示/非表示.
// CGA カラーパレット (16 色), ブリンク/ブライトバックグラウンド切り替え.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- VGA Register Ports ----

const MISC_OUTPUT_WRITE: u16 = 0x3C2; // Miscellaneous Output Register (write)
const MISC_OUTPUT_READ: u16 = 0x3CC; // Miscellaneous Output Register (read)
const SEQ_INDEX: u16 = 0x3C4; // Sequencer Index
const SEQ_DATA: u16 = 0x3C5; // Sequencer Data
const CRTC_INDEX: u16 = 0x3D4; // CRT Controller Index
const CRTC_DATA: u16 = 0x3D5; // CRT Controller Data
const GFX_INDEX: u16 = 0x3CE; // Graphics Controller Index
const GFX_DATA: u16 = 0x3CF; // Graphics Controller Data
const ATTR_INDEX: u16 = 0x3C0; // Attribute Controller Index/Data
const ATTR_DATA_WRITE: u16 = 0x3C0; // Attribute Controller Data (write)
const ATTR_DATA_READ: u16 = 0x3C1; // Attribute Controller Data (read)
const INPUT_STATUS_1: u16 = 0x3DA; // Input Status Register 1 (also resets ATTR flip-flop)
const DAC_ADDR_WRITE: u16 = 0x3C8; // DAC Address Write Mode
const DAC_DATA: u16 = 0x3C9; // DAC Data

// ---- Video Modes ----

pub const Mode = enum(u8) {
    text_40x25 = 0x01,
    text_80x25 = 0x03,
    gfx_320x200x4 = 0x04,
    gfx_640x200x2 = 0x06,
    unknown = 0xFF,
};

pub const ModeInfo = struct {
    mode: Mode,
    width: u16,
    height: u16,
    bpp: u8, // bits per pixel (text = 0)
    is_text: bool,
    name: []const u8,
};

pub const mode_info_table = [_]ModeInfo{
    .{ .mode = .text_40x25, .width = 40, .height = 25, .bpp = 0, .is_text = true, .name = "Text 40x25 16-color" },
    .{ .mode = .text_80x25, .width = 80, .height = 25, .bpp = 0, .is_text = true, .name = "Text 80x25 16-color" },
    .{ .mode = .gfx_320x200x4, .width = 320, .height = 200, .bpp = 2, .is_text = false, .name = "CGA 320x200 4-color" },
    .{ .mode = .gfx_640x200x2, .width = 640, .height = 200, .bpp = 1, .is_text = false, .name = "CGA 640x200 2-color" },
};

// ---- CGA Color Palette ----

pub const CgaColor = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

// CGA color names for display
const cga_color_names = [16][]const u8{
    "Black", "Blue", "Green", "Cyan",
    "Red", "Magenta", "Brown", "Light Gray",
    "Dark Gray", "Light Blue", "Light Green", "Light Cyan",
    "Light Red", "Light Magenta", "Yellow", "White",
};

// ---- VGA Register Tables for each mode ----

// Standard VGA Text 80x25 register values
const mode_80x25_misc: u8 = 0x67;
const mode_80x25_seq = [5]u8{ 0x03, 0x00, 0x03, 0x00, 0x02 };
const mode_80x25_crtc = [25]u8{
    0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F,
    0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x50,
    0x9C, 0x0E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3,
    0xFF,
};
const mode_80x25_gfx = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x00, 0xFF };
const mode_80x25_attr = [21]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07,
    0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    0x0C, 0x00, 0x0F, 0x08, 0x00,
};

// Standard VGA Text 40x25 register values
const mode_40x25_misc: u8 = 0x67;
const mode_40x25_seq = [5]u8{ 0x08, 0x00, 0x03, 0x00, 0x02 }; // Clk/2 for 40 cols
const mode_40x25_crtc = [25]u8{
    0x2D, 0x27, 0x28, 0x90, 0x2B, 0xA0, 0xBF, 0x1F,
    0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00,
    0x9C, 0x8E, 0x8F, 0x14, 0x1F, 0x96, 0xB9, 0xA3,
    0xFF,
};

// ---- State ----

var current_mode: Mode = .text_80x25;
var blink_mode: bool = true; // true = blink, false = bright background
var cursor_visible: bool = true;
var cursor_start: u8 = 0x0D; // Default cursor start scanline
var cursor_end: u8 = 0x0E; // Default cursor end scanline

// ---- Mode setting ----

/// Set the video mode by programming VGA registers
pub fn setMode(mode: Mode) void {
    switch (mode) {
        .text_80x25 => {
            programRegisters(
                mode_80x25_misc,
                &mode_80x25_seq,
                &mode_80x25_crtc,
                &mode_80x25_gfx,
                &mode_80x25_attr,
            );
            current_mode = .text_80x25;
        },
        .text_40x25 => {
            programRegisters(
                mode_40x25_misc,
                &mode_40x25_seq,
                &mode_40x25_crtc,
                &mode_80x25_gfx, // Same GFX regs for text
                &mode_80x25_attr, // Same ATTR regs for text
            );
            current_mode = .text_40x25;
        },
        .gfx_320x200x4 => {
            // For CGA 320x200, we program a simplified register set
            programCgaGraphics320();
            current_mode = .gfx_320x200x4;
        },
        .gfx_640x200x2 => {
            programCgaGraphics640();
            current_mode = .gfx_640x200x2;
        },
        .unknown => {},
    }

    serial.write("[CGA] Mode set to 0x");
    serialHex8(@intFromEnum(mode));
    serial.write("\n");
}

fn programRegisters(
    misc: u8,
    seq: *const [5]u8,
    crtc: *const [25]u8,
    gfx: *const [9]u8,
    attr: *const [21]u8,
) void {
    // Miscellaneous Output Register
    idt.outb(MISC_OUTPUT_WRITE, misc);

    // Sequencer registers
    // Unlock CRTC (reset register)
    idt.outb(SEQ_INDEX, 0x00);
    idt.outb(SEQ_DATA, 0x01); // Synchronous reset
    for (seq, 0..) |val, i| {
        idt.outb(SEQ_INDEX, @truncate(i));
        idt.outb(SEQ_DATA, val);
    }
    // End reset
    idt.outb(SEQ_INDEX, 0x00);
    idt.outb(SEQ_DATA, 0x03);

    // Unlock CRTC registers (clear bit 7 of register 0x11)
    idt.outb(CRTC_INDEX, 0x11);
    const cr11 = idt.inb(CRTC_DATA);
    idt.outb(CRTC_INDEX, 0x11);
    idt.outb(CRTC_DATA, cr11 & 0x7F);

    // CRTC registers
    for (crtc, 0..) |val, i| {
        idt.outb(CRTC_INDEX, @truncate(i));
        idt.outb(CRTC_DATA, val);
    }

    // Graphics Controller registers
    for (gfx, 0..) |val, i| {
        idt.outb(GFX_INDEX, @truncate(i));
        idt.outb(GFX_DATA, val);
    }

    // Attribute Controller registers
    // Reset flip-flop first
    _ = idt.inb(INPUT_STATUS_1);
    for (attr, 0..) |val, i| {
        idt.outb(ATTR_INDEX, @truncate(i));
        idt.outb(ATTR_DATA_WRITE, val);
    }
    // Re-enable video output
    idt.outb(ATTR_INDEX, 0x20);
}

fn programCgaGraphics320() void {
    // CGA 320x200 4-color mode via VGA registers
    const misc: u8 = 0x63;
    const seq = [5]u8{ 0x03, 0x09, 0x03, 0x00, 0x02 };
    const crtc = [25]u8{
        0x2D, 0x27, 0x28, 0x90, 0x2B, 0x80, 0xBF, 0x1F,
        0x00, 0xC1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x9C, 0x8E, 0x8F, 0x14, 0x00, 0x96, 0xB9, 0xA2,
        0xFF,
    };
    const gfx = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x0F, 0x00, 0xFF };
    const attr = [21]u8{
        0x00, 0x13, 0x15, 0x17, 0x02, 0x04, 0x06, 0x07,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x01, 0x00, 0x03, 0x00, 0x00,
    };
    programRegisters(misc, &seq, &crtc, &gfx, &attr);
}

fn programCgaGraphics640() void {
    // CGA 640x200 2-color mode via VGA registers
    const misc: u8 = 0x63;
    const seq = [5]u8{ 0x03, 0x01, 0x01, 0x00, 0x06 };
    const crtc = [25]u8{
        0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F,
        0x00, 0xC1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x9C, 0x8E, 0x8F, 0x28, 0x00, 0x96, 0xB9, 0xC2,
        0xFF,
    };
    const gfx = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0xFF };
    const attr = [21]u8{
        0x00, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17,
        0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17,
        0x01, 0x00, 0x01, 0x00, 0x00,
    };
    programRegisters(misc, &seq, &crtc, &gfx, &attr);
}

/// Get the current video mode
pub fn getMode() Mode {
    return current_mode;
}

// ---- Cursor control ----

/// Set cursor shape by start and end scanlines (0-15 for VGA text)
pub fn setCursorShape(start: u8, end: u8) void {
    cursor_start = start & 0x1F;
    cursor_end = end & 0x1F;

    if (cursor_visible) {
        // Write to CRTC registers
        idt.outb(CRTC_INDEX, 0x0A); // Cursor Start Register
        idt.outb(CRTC_DATA, cursor_start & 0x1F); // bit 5 = cursor disable
        idt.outb(CRTC_INDEX, 0x0B); // Cursor End Register
        idt.outb(CRTC_DATA, cursor_end & 0x1F);
    }
}

/// Hide the hardware cursor
pub fn hideCursor() void {
    idt.outb(CRTC_INDEX, 0x0A);
    idt.outb(CRTC_DATA, 0x20); // Bit 5 = disable cursor
    cursor_visible = false;
}

/// Show the hardware cursor
pub fn showCursor() void {
    idt.outb(CRTC_INDEX, 0x0A);
    idt.outb(CRTC_DATA, cursor_start & 0x1F); // Bit 5 clear = enable
    idt.outb(CRTC_INDEX, 0x0B);
    idt.outb(CRTC_DATA, cursor_end & 0x1F);
    cursor_visible = true;
}

/// Set cursor position (for text modes)
pub fn setCursorPos(row: u16, col: u16) void {
    const width: u16 = switch (current_mode) {
        .text_40x25 => 40,
        else => 80,
    };
    const pos = row * width + col;
    idt.outb(CRTC_INDEX, 0x0F); // Cursor Location Low
    idt.outb(CRTC_DATA, @truncate(pos));
    idt.outb(CRTC_INDEX, 0x0E); // Cursor Location High
    idt.outb(CRTC_DATA, @truncate(pos >> 8));
}

/// Get current cursor position
pub fn getCursorPos() struct { row: u16, col: u16 } {
    idt.outb(CRTC_INDEX, 0x0F);
    const lo: u16 = idt.inb(CRTC_DATA);
    idt.outb(CRTC_INDEX, 0x0E);
    const hi: u16 = idt.inb(CRTC_DATA);
    const pos = (hi << 8) | lo;
    const width: u16 = switch (current_mode) {
        .text_40x25 => 40,
        else => 80,
    };
    return .{
        .row = pos / width,
        .col = pos % width,
    };
}

/// Check if cursor is visible
pub fn isCursorVisible() bool {
    return cursor_visible;
}

// ---- Blink/Bright background ----

/// Set blink mode: true = bit 7 of attribute byte controls blinking
/// false = bit 7 controls bright background (16 background colors)
pub fn setBlinkMode(on: bool) void {
    // Read Input Status 1 to reset attribute flip-flop
    _ = idt.inb(INPUT_STATUS_1);

    // Select Attribute Mode Control Register (index 0x10)
    idt.outb(ATTR_INDEX, 0x10 | 0x20); // Index + PAS bit

    const cur = idt.inb(ATTR_DATA_READ);

    if (on) {
        idt.outb(ATTR_DATA_WRITE, cur | 0x08); // Set blink bit
    } else {
        idt.outb(ATTR_DATA_WRITE, cur & ~@as(u8, 0x08)); // Clear blink bit
    }

    blink_mode = on;
}

/// Get current blink mode
pub fn isBlinkMode() bool {
    return blink_mode;
}

// ---- Text Start Position ----

/// Set the display start address (for hardware scrolling)
pub fn setStartAddress(addr: u16) void {
    idt.outb(CRTC_INDEX, 0x0C); // Start Address High
    idt.outb(CRTC_DATA, @truncate(addr >> 8));
    idt.outb(CRTC_INDEX, 0x0D); // Start Address Low
    idt.outb(CRTC_DATA, @truncate(addr));
}

// ---- Display ----

pub fn printModeInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("CGA/EGA/VGA Video:\n");
    vga.setColor(.light_grey, .black);

    // Current mode
    vga.write("  Current Mode: ");
    const cur_info = getModeInfoStruct(current_mode);
    if (cur_info) |info| {
        vga.write(info.name);
    } else {
        vga.write("Unknown");
    }
    vga.write(" (0x");
    printHex8(@intFromEnum(current_mode));
    vga.write(")\n");

    // Cursor
    vga.write("  Cursor: ");
    if (cursor_visible) {
        vga.setColor(.light_green, .black);
        vga.write("Visible");
        vga.setColor(.light_grey, .black);
        vga.write(" (scanlines ");
        printDec(cursor_start);
        vga.write("-");
        printDec(cursor_end);
        vga.write(")");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("Hidden");
        vga.setColor(.light_grey, .black);
    }
    vga.putChar('\n');

    // Blink mode
    vga.write("  Attribute bit 7: ");
    if (blink_mode) {
        vga.write("Blink");
    } else {
        vga.write("Bright Background (16 bg colors)");
    }
    vga.putChar('\n');

    // Misc Output Register
    const misc = idt.inb(MISC_OUTPUT_READ);
    vga.write("  MISC: 0x");
    printHex8(misc);
    vga.write("  I/O Addr: ");
    if (misc & 0x01 != 0) vga.write("0x3Dx") else vga.write("0x3Bx");
    vga.putChar('\n');

    // Available modes
    vga.write("  Available Modes:\n");
    for (mode_info_table) |info| {
        vga.write("    0x");
        printHex8(@intFromEnum(info.mode));
        vga.write("  ");
        vga.write(info.name);
        vga.putChar('\n');
    }

    // CGA Color palette
    vga.write("  CGA Palette:\n    ");
    for (cga_color_names, 0..) |name, i| {
        printDec(i);
        vga.write("=");
        vga.write(name);
        if (i < 15) {
            if (i == 7) {
                vga.write("\n    ");
            } else {
                vga.write(" ");
            }
        }
    }
    vga.putChar('\n');
}

fn getModeInfoStruct(mode: Mode) ?*const ModeInfo {
    for (&mode_info_table) |*info| {
        if (info.mode == mode) return info;
    }
    return null;
}

// ---- Helpers ----

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printDec(n: anytype) void {
    const val: u32 = @intCast(n);
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

fn serialHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0xF]);
}
