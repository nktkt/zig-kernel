// Visual Theme System -- Mode 13h (256-color) UI theming
// Provides color schemes for window manager, widgets, and desktop

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Color Element Enum ----

pub const Element = enum(u8) {
    window_bg = 0,
    window_border = 1,
    titlebar_bg = 2,
    titlebar_fg = 3,
    button_bg = 4,
    button_fg = 5,
    text_color = 6,
    highlight = 7,
    shadow = 8,
    desktop_bg = 9,
    button_hover = 10,
    checkbox_bg = 11,
    checkbox_check = 12,
    progress_bg = 13,
    progress_fill = 14,
    input_bg = 15,
    input_border = 16,
    input_text = 17,
    close_btn = 18,
    close_btn_fg = 19,
};

pub const element_count = 20;

// ---- Theme Struct ----

pub const Theme = struct {
    name: [16]u8,
    name_len: u8,
    colors: [element_count]u8,
};

// ---- Built-in Themes ----

const theme_count = 3;

const builtin_themes: [theme_count]Theme = initBuiltinThemes();

fn initBuiltinThemes() [theme_count]Theme {
    var themes: [theme_count]Theme = undefined;

    // Theme 0: "default" -- Classic blue titlebar
    themes[0] = .{
        .name = strToBuf16("default"),
        .name_len = 7,
        .colors = .{
            248, // window_bg:      light grey
            240, // window_border:  dark grey
            1, //   titlebar_bg:    blue
            15, //  titlebar_fg:    white
            7, //   button_bg:      silver
            0, //   button_fg:      black
            0, //   text_color:     black
            11, //  highlight:      bright cyan
            8, //   shadow:         dark grey
            1, //   desktop_bg:     blue
            9, //   button_hover:   light blue
            15, //  checkbox_bg:    white
            0, //   checkbox_check: black
            8, //   progress_bg:    dark grey
            10, //  progress_fill:  light green
            15, //  input_bg:       white
            8, //   input_border:   dark grey
            0, //   input_text:     black
            4, //   close_btn:      red
            15, //  close_btn_fg:   white
        },
    };

    // Theme 1: "dark" -- Dark grey theme
    themes[1] = .{
        .name = strToBuf16("dark"),
        .name_len = 4,
        .colors = .{
            8, //   window_bg:      dark grey
            0, //   window_border:  black
            240, // titlebar_bg:    medium grey
            15, //  titlebar_fg:    white
            240, // button_bg:      medium grey
            15, //  button_fg:      white
            15, //  text_color:     white
            14, //  highlight:      yellow
            0, //   shadow:         black
            0, //   desktop_bg:     black
            7, //   button_hover:   light grey
            240, // checkbox_bg:    medium grey
            14, //  checkbox_check: yellow
            0, //   progress_bg:    black
            14, //  progress_fill:  yellow
            240, // input_bg:       medium grey
            0, //   input_border:   black
            15, //  input_text:     white
            4, //   close_btn:      red
            15, //  close_btn_fg:   white
        },
    };

    // Theme 2: "retro" -- Green monochrome terminal style
    themes[2] = .{
        .name = strToBuf16("retro"),
        .name_len = 5,
        .colors = .{
            0, //   window_bg:      black
            2, //   window_border:  green
            2, //   titlebar_bg:    green
            0, //   titlebar_fg:    black
            2, //   button_bg:      green
            0, //   button_fg:      black
            10, //  text_color:     light green
            10, //  highlight:      bright green
            8, //   shadow:         dark grey
            0, //   desktop_bg:     black
            10, //  button_hover:   bright green
            0, //   checkbox_bg:    black
            10, //  checkbox_check: bright green
            0, //   progress_bg:    black
            2, //   progress_fill:  green
            0, //   input_bg:       black
            2, //   input_border:   green
            10, //  input_text:     bright green
            4, //   close_btn:      red
            10, //  close_btn_fg:   bright green
        },
    };

    return themes;
}

// ---- State ----

var active_theme: u8 = 0;

// ---- Public API ----

/// Set the active theme by name. Returns true on success.
pub fn setTheme(name: []const u8) bool {
    for (builtin_themes, 0..) |t, i| {
        if (strEql(name, t.name[0..t.name_len])) {
            active_theme = @truncate(i);
            return true;
        }
    }
    return false;
}

/// Get the palette color index for a given UI element
pub fn getColor(element: Element) u8 {
    return builtin_themes[active_theme].colors[@intFromEnum(element)];
}

/// Get the name of the current theme
pub fn currentTheme() []const u8 {
    const t = &builtin_themes[active_theme];
    return t.name[0..t.name_len];
}

/// List all available themes (prints to VGA)
pub fn listThemes() void {
    vga.write("Available themes:\n");
    for (builtin_themes, 0..) |t, i| {
        vga.write("  ");
        if (i == active_theme) {
            vga.write("* ");
        } else {
            vga.write("  ");
        }
        vga.write(t.name[0..t.name_len]);
        vga.write("\n");
    }
}

/// Print theme list to serial
pub fn listThemesSerial() void {
    serial.write("Available themes:\n");
    for (builtin_themes, 0..) |t, i| {
        serial.write("  ");
        if (i == active_theme) {
            serial.write("* ");
        } else {
            serial.write("  ");
        }
        serial.write(t.name[0..t.name_len]);
        serial.write("\n");
    }
}

/// Get the active theme struct
pub fn getActiveTheme() *const Theme {
    return &builtin_themes[active_theme];
}

/// Get theme by index
pub fn getThemeByIndex(idx: u8) ?*const Theme {
    if (idx >= theme_count) return null;
    return &builtin_themes[idx];
}

/// Get number of built-in themes
pub fn getThemeCount() u8 {
    return theme_count;
}

// ---- VGA Palette Helpers ----

/// Set a single VGA DAC palette entry (index 0-255)
/// r, g, b are 6-bit values (0-63) as per VGA hardware
pub fn setPaletteEntry(index: u8, r: u8, g: u8, b: u8) void {
    idt.outb(0x3C8, index);
    idt.outb(0x3C9, r & 0x3F);
    idt.outb(0x3C9, g & 0x3F);
    idt.outb(0x3C9, b & 0x3F);
}

/// Read a VGA DAC palette entry
pub fn getPaletteEntry(index: u8) [3]u8 {
    idt.outb(0x3C7, index);
    const r = idt.inb(0x3C9);
    const g = idt.inb(0x3C9);
    const b = idt.inb(0x3C9);
    return .{ r, g, b };
}

/// Initialize a nice 256-color palette for the UI
/// Layout:
///   0-15:    Standard 16 CGA colors
///   16-31:   Grey ramp (16 shades)
///   32-63:   Red gradient
///   64-95:   Green gradient
///   96-127:  Blue gradient
///   128-159: Yellow gradient
///   160-191: Cyan gradient
///   192-223: Magenta gradient
///   224-239: Orange gradient
///   240-255: UI-specific colors (light greys, mid-tones)
pub fn initPalette() void {
    // Standard CGA 16 colors
    const cga_colors = [16][3]u8{
        .{ 0, 0, 0 }, //  0: black
        .{ 0, 0, 42 }, //  1: blue
        .{ 0, 42, 0 }, //  2: green
        .{ 0, 42, 42 }, //  3: cyan
        .{ 42, 0, 0 }, //  4: red
        .{ 42, 0, 42 }, //  5: magenta
        .{ 42, 21, 0 }, //  6: brown
        .{ 42, 42, 42 }, //  7: light grey
        .{ 21, 21, 21 }, //  8: dark grey
        .{ 21, 21, 63 }, //  9: light blue
        .{ 21, 63, 21 }, // 10: light green
        .{ 21, 63, 63 }, // 11: light cyan
        .{ 63, 21, 21 }, // 12: light red
        .{ 63, 21, 63 }, // 13: light magenta
        .{ 63, 63, 21 }, // 14: yellow
        .{ 63, 63, 63 }, // 15: white
    };
    for (cga_colors, 0..) |c, i| {
        setPaletteEntry(@truncate(i), c[0], c[1], c[2]);
    }

    // 16-31: Grey ramp
    var i: u16 = 0;
    while (i < 16) : (i += 1) {
        const v: u8 = @truncate(i * 4);
        setPaletteEntry(@truncate(16 + i), v, v, v);
    }

    // 32-63: Red gradient
    i = 0;
    while (i < 32) : (i += 1) {
        const v: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(32 + i), v, 0, 0);
    }

    // 64-95: Green gradient
    i = 0;
    while (i < 32) : (i += 1) {
        const v: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(64 + i), 0, v, 0);
    }

    // 96-127: Blue gradient
    i = 0;
    while (i < 32) : (i += 1) {
        const v: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(96 + i), 0, 0, v);
    }

    // 128-159: Yellow gradient
    i = 0;
    while (i < 32) : (i += 1) {
        const v: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(128 + i), v, v, 0);
    }

    // 160-191: Cyan gradient
    i = 0;
    while (i < 32) : (i += 1) {
        const v: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(160 + i), 0, v, v);
    }

    // 192-223: Magenta gradient
    i = 0;
    while (i < 32) : (i += 1) {
        const v: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(192 + i), v, 0, v);
    }

    // 224-239: Orange gradient
    i = 0;
    while (i < 16) : (i += 1) {
        const r: u8 = @truncate(32 + i * 2);
        const g: u8 = @truncate(i * 2);
        setPaletteEntry(@truncate(224 + i), r, g, 0);
    }

    // 240-255: UI-specific tones (greys, pastels)
    setPaletteEntry(240, 32, 32, 32); // medium dark grey
    setPaletteEntry(241, 36, 36, 36);
    setPaletteEntry(242, 40, 40, 40);
    setPaletteEntry(243, 44, 44, 44);
    setPaletteEntry(244, 48, 48, 48);
    setPaletteEntry(245, 50, 50, 50);
    setPaletteEntry(246, 52, 52, 52);
    setPaletteEntry(247, 54, 54, 54);
    setPaletteEntry(248, 56, 56, 56); // window bg default
    setPaletteEntry(249, 58, 58, 58);
    setPaletteEntry(250, 60, 60, 60);
    setPaletteEntry(251, 46, 46, 58); // subtle blue-grey
    setPaletteEntry(252, 42, 52, 42); // subtle green-grey
    setPaletteEntry(253, 58, 50, 42); // subtle warm grey
    setPaletteEntry(254, 50, 42, 54); // subtle purple-grey
    setPaletteEntry(255, 62, 62, 62); // near-white
}

// ---- Utility ----

fn strToBuf16(comptime s: []const u8) [16]u8 {
    var buf: [16]u8 = @splat(0);
    for (s, 0..) |c, i| {
        buf[i] = c;
    }
    return buf;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
