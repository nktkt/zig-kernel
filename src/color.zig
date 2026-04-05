// Color Manipulation -- RGB/HSV conversion, blending, VGA 256-color palette
// For VGA/framebuffer use in freestanding x86 kernel

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Color Structs ----

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(self: RGB, other: RGB) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const HSV = struct {
    h: u16, // Hue: 0-360
    s: u8, // Saturation: 0-100
    v: u8, // Value: 0-100
};

// ---- Predefined Colors ----

pub const BLACK = RGB{ .r = 0, .g = 0, .b = 0 };
pub const WHITE = RGB{ .r = 255, .g = 255, .b = 255 };
pub const RED = RGB{ .r = 255, .g = 0, .b = 0 };
pub const GREEN = RGB{ .r = 0, .g = 255, .b = 0 };
pub const BLUE = RGB{ .r = 0, .g = 0, .b = 255 };
pub const YELLOW = RGB{ .r = 255, .g = 255, .b = 0 };
pub const CYAN = RGB{ .r = 0, .g = 255, .b = 255 };
pub const MAGENTA = RGB{ .r = 255, .g = 0, .b = 255 };
pub const ORANGE = RGB{ .r = 255, .g = 165, .b = 0 };
pub const PURPLE = RGB{ .r = 128, .g = 0, .b = 128 };
pub const GREY = RGB{ .r = 128, .g = 128, .b = 128 };
pub const DARK_GREY = RGB{ .r = 64, .g = 64, .b = 64 };
pub const LIGHT_GREY = RGB{ .r = 192, .g = 192, .b = 192 };
pub const BROWN = RGB{ .r = 165, .g = 42, .b = 42 };
pub const PINK = RGB{ .r = 255, .g = 192, .b = 203 };

// ---- RGB <-> HSV Conversion ----

/// Convert RGB to HSV.
/// Uses integer arithmetic only (no floating point).
pub fn rgbToHsv(rgb: RGB) HSV {
    const r: u32 = rgb.r;
    const g: u32 = rgb.g;
    const b: u32 = rgb.b;

    const max_val = max3(r, g, b);
    const min_val = min3(r, g, b);
    const delta = max_val - min_val;

    // Value: V = max * 100 / 255
    const v: u8 = @truncate((max_val * 100) / 255);

    if (delta == 0) {
        // Achromatic (grey)
        return HSV{ .h = 0, .s = 0, .v = v };
    }

    // Saturation: S = delta * 100 / max
    const s: u8 = @truncate((delta * 100) / max_val);

    // Hue calculation
    var h_raw: i32 = 0;
    if (max_val == r) {
        // H = 60 * ((G - B) / delta)
        h_raw = @divTrunc(@as(i32, 60) * (@as(i32, @intCast(g)) - @as(i32, @intCast(b))), @as(i32, @intCast(delta)));
    } else if (max_val == g) {
        h_raw = 120 + @divTrunc(@as(i32, 60) * (@as(i32, @intCast(b)) - @as(i32, @intCast(r))), @as(i32, @intCast(delta)));
    } else {
        h_raw = 240 + @divTrunc(@as(i32, 60) * (@as(i32, @intCast(r)) - @as(i32, @intCast(g))), @as(i32, @intCast(delta)));
    }

    if (h_raw < 0) h_raw += 360;
    return HSV{ .h = @intCast(h_raw), .s = s, .v = v };
}

/// Convert HSV to RGB.
/// Uses integer arithmetic only.
pub fn hsvToRgb(hsv: HSV) RGB {
    if (hsv.s == 0) {
        // Achromatic
        const val: u8 = @truncate((@as(u32, hsv.v) * 255) / 100);
        return RGB{ .r = val, .g = val, .b = val };
    }

    const h = hsv.h % 360;
    const s: u32 = hsv.s;
    const v: u32 = hsv.v;

    // Sector: 0-5
    const sector = h / 60;
    const f = @as(u32, h % 60); // fractional part in [0, 60)

    // p = V * (100 - S) / 100
    const p = (v * (100 - s)) / 100;
    // q = V * (100 - S * f / 60) / 100
    const q = (v * (100 - (s * f) / 60)) / 100;
    // t = V * (100 - S * (60 - f) / 60) / 100
    const t = (v * (100 - (s * (60 - f)) / 60)) / 100;

    var r: u32 = 0;
    var g: u32 = 0;
    var b: u32 = 0;

    switch (sector) {
        0 => {
            r = v;
            g = t;
            b = p;
        },
        1 => {
            r = q;
            g = v;
            b = p;
        },
        2 => {
            r = p;
            g = v;
            b = t;
        },
        3 => {
            r = p;
            g = q;
            b = v;
        },
        4 => {
            r = t;
            g = p;
            b = v;
        },
        else => {
            r = v;
            g = p;
            b = q;
        },
    }

    return RGB{
        .r = @truncate((r * 255) / 100),
        .g = @truncate((g * 255) / 100),
        .b = @truncate((b * 255) / 100),
    };
}

// ---- Blending and Manipulation ----

/// Alpha blend two colors. alpha=0 returns c1, alpha=255 returns c2.
pub fn blend(c1: RGB, c2: RGB, alpha: u8) RGB {
    const a: u16 = alpha;
    const inv_a: u16 = 255 - a;

    return RGB{
        .r = @truncate((@as(u16, c1.r) * inv_a + @as(u16, c2.r) * a) / 255),
        .g = @truncate((@as(u16, c1.g) * inv_a + @as(u16, c2.g) * a) / 255),
        .b = @truncate((@as(u16, c1.b) * inv_a + @as(u16, c2.b) * a) / 255),
    };
}

/// Lighten a color by `amount` (0-255).
pub fn lighten(col: RGB, amount: u8) RGB {
    return blend(col, WHITE, amount);
}

/// Darken a color by `amount` (0-255).
pub fn darken(col: RGB, amount: u8) RGB {
    return blend(col, BLACK, amount);
}

/// Invert a color.
pub fn invert(col: RGB) RGB {
    return RGB{
        .r = 255 - col.r,
        .g = 255 - col.g,
        .b = 255 - col.b,
    };
}

/// Convert to greyscale using luminance weights (integer approximation).
/// Y = (r * 77 + g * 150 + b * 29) >> 8
pub fn greyscale(col: RGB) RGB {
    const lum: u8 = @truncate((@as(u16, col.r) * 77 + @as(u16, col.g) * 150 + @as(u16, col.b) * 29) >> 8);
    return RGB{ .r = lum, .g = lum, .b = lum };
}

/// Compute the squared Euclidean distance between two colors.
pub fn distance(c1: RGB, c2: RGB) u32 {
    const dr: i32 = @as(i32, c1.r) - @as(i32, c2.r);
    const dg: i32 = @as(i32, c1.g) - @as(i32, c2.g);
    const db: i32 = @as(i32, c1.b) - @as(i32, c2.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

// ---- VGA 256-Color Palette ----
//
// Standard VGA 256-color palette:
//   0-15:    Standard CGA colors
//   16-231:  6x6x6 color cube (R * 36 + G * 6 + B + 16)
//   232-255: Greyscale ramp (24 shades)

/// Map an RGB color to the nearest VGA 256-color palette index.
pub fn rgbTo256(rgb: RGB) u8 {
    // Try the 6x6x6 color cube (indices 16-231)
    // Each axis has 6 levels: 0, 51, 102, 153, 204, 255
    const r6 = nearestCubeLevel(rgb.r);
    const g6 = nearestCubeLevel(rgb.g);
    const b6 = nearestCubeLevel(rgb.b);
    const cube_index: u8 = 16 + r6 * 36 + g6 * 6 + b6;
    const cube_rgb = palette256ToRgb(cube_index);
    const cube_dist = distance(rgb, cube_rgb);

    // Try the greyscale ramp (indices 232-255)
    const grey_val = greyscale(rgb).r;
    const grey_level: u8 = @truncate(@as(u16, grey_val) * 24 / 256);
    const clamped_grey = if (grey_level > 23) @as(u8, 23) else grey_level;
    const grey_index: u8 = 232 + clamped_grey;
    const grey_rgb = palette256ToRgb(grey_index);
    const grey_dist = distance(rgb, grey_rgb);

    if (grey_dist < cube_dist) {
        return grey_index;
    }
    return cube_index;
}

/// Convert a VGA 256-color palette index to RGB.
pub fn palette256ToRgb(index: u8) RGB {
    if (index < 16) {
        // Standard CGA colors
        return cga_colors[index];
    } else if (index < 232) {
        // 6x6x6 color cube
        const ci = index - 16;
        const b_idx: u8 = ci % 6;
        const g_idx: u8 = (ci / 6) % 6;
        const r_idx: u8 = ci / 36;
        return RGB{
            .r = cubeLevel(r_idx),
            .g = cubeLevel(g_idx),
            .b = cubeLevel(b_idx),
        };
    } else {
        // Greyscale ramp: 232-255 -> 8, 18, 28, ..., 238
        const grey: u8 = 8 + (index - 232) * 10;
        return RGB{ .r = grey, .g = grey, .b = grey };
    }
}

/// Find the nearest palette color for an RGB value (searches all 256).
pub fn nearestPaletteColor(rgb: RGB) u8 {
    var best_idx: u8 = 0;
    var best_dist: u32 = 0xFFFFFFFF;

    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const idx: u8 = @truncate(i);
        const pal = palette256ToRgb(idx);
        const dist = distance(rgb, pal);
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = idx;
        }
    }

    return best_idx;
}

// ---- CGA Standard Colors ----

const cga_colors = [16]RGB{
    RGB{ .r = 0, .g = 0, .b = 0 }, // 0: Black
    RGB{ .r = 0, .g = 0, .b = 170 }, // 1: Blue
    RGB{ .r = 0, .g = 170, .b = 0 }, // 2: Green
    RGB{ .r = 0, .g = 170, .b = 170 }, // 3: Cyan
    RGB{ .r = 170, .g = 0, .b = 0 }, // 4: Red
    RGB{ .r = 170, .g = 0, .b = 170 }, // 5: Magenta
    RGB{ .r = 170, .g = 85, .b = 0 }, // 6: Brown
    RGB{ .r = 170, .g = 170, .b = 170 }, // 7: Light grey
    RGB{ .r = 85, .g = 85, .b = 85 }, // 8: Dark grey
    RGB{ .r = 85, .g = 85, .b = 255 }, // 9: Light blue
    RGB{ .r = 85, .g = 255, .b = 85 }, // 10: Light green
    RGB{ .r = 85, .g = 255, .b = 255 }, // 11: Light cyan
    RGB{ .r = 255, .g = 85, .b = 85 }, // 12: Light red
    RGB{ .r = 255, .g = 85, .b = 255 }, // 13: Light magenta
    RGB{ .r = 255, .g = 255, .b = 85 }, // 14: Yellow
    RGB{ .r = 255, .g = 255, .b = 255 }, // 15: White
};

// ---- Helpers ----

fn max3(a: u32, b: u32, c: u32) u32 {
    var m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    return m;
}

fn min3(a: u32, b: u32, c: u32) u32 {
    var m = a;
    if (b < m) m = b;
    if (c < m) m = c;
    return m;
}

/// Map a 0-255 value to the nearest of 6 cube levels: 0, 1, 2, 3, 4, 5
fn nearestCubeLevel(val: u8) u8 {
    // Levels: 0, 51, 102, 153, 204, 255
    // Thresholds (midpoints): 26, 77, 128, 179, 230
    if (val < 26) return 0;
    if (val < 77) return 1;
    if (val < 128) return 2;
    if (val < 179) return 3;
    if (val < 230) return 4;
    return 5;
}

/// Convert cube level (0-5) to actual color value.
fn cubeLevel(idx: u8) u8 {
    const levels = [6]u8{ 0, 51, 102, 153, 204, 255 };
    if (idx < 6) return levels[idx];
    return 255;
}

// ---- Display ----

/// Print an RGB color.
pub fn printRgb(c: RGB) void {
    vga.write("RGB(");
    printDec(c.r);
    vga.write(", ");
    printDec(c.g);
    vga.write(", ");
    printDec(c.b);
    vga.putChar(')');
}

/// Print an HSV color.
pub fn printHsv(h: HSV) void {
    vga.write("HSV(");
    printDec16(h.h);
    vga.write(", ");
    printDec(h.s);
    vga.write(", ");
    printDec(h.v);
    vga.putChar(')');
}

fn printDec(n: u8) void {
    const val: usize = n;
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [3]u8 = undefined;
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

fn printDec16(n: u16) void {
    const val: usize = n;
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
