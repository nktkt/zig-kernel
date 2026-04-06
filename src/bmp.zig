// BMP image format reader/writer
// Supports 1, 4, 8, and 24 bpp uncompressed BMP images.
// BMP File Header (14 bytes) + BITMAPINFOHEADER (40 bytes)

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const framebuf = @import("framebuf.zig");

// ---- Constants ----

const BMP_SIGNATURE: u16 = 0x4D42; // "BM" in little-endian
const BMP_FILE_HEADER_SIZE: usize = 14;
const BMP_DIB_HEADER_SIZE: usize = 40; // BITMAPINFOHEADER
const MAX_PALETTE_ENTRIES: usize = 256;

// ---- BMP structures ----

pub const BmpFileHeader = struct {
    signature: u16, // "BM" = 0x4D42
    file_size: u32,
    reserved1: u16,
    reserved2: u16,
    data_offset: u32,
};

pub const BmpDibHeader = struct {
    header_size: u32, // 40 for BITMAPINFOHEADER
    width: i32,
    height: i32, // positive = bottom-up, negative = top-down
    planes: u16, // always 1
    bpp: u16, // bits per pixel: 1, 4, 8, 24, 32
    compression: u32, // 0 = BI_RGB (uncompressed)
    image_size: u32, // may be 0 for BI_RGB
    x_ppm: i32, // horizontal pixels per meter
    y_ppm: i32, // vertical pixels per meter
    colors_used: u32,
    colors_important: u32,
};

pub const PaletteEntry = struct {
    blue: u8,
    green: u8,
    red: u8,
    reserved: u8,
};

pub const BmpInfo = struct {
    file_header: BmpFileHeader,
    dib_header: BmpDibHeader,
    palette: [MAX_PALETTE_ENTRIES]PaletteEntry,
    palette_count: usize,
    width: u32,
    height: u32,
    bpp: u16,
    top_down: bool,
    data_offset: usize,
    row_stride: usize, // bytes per row (padded to 4-byte boundary)
    valid: bool,
};

// ---- Little-endian byte reading ----

fn readU16LE(data: []const u8, offset: usize) u16 {
    if (offset + 2 > data.len) return 0;
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32LE(data: []const u8, offset: usize) u32 {
    if (offset + 4 > data.len) return 0;
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn readI32LE(data: []const u8, offset: usize) i32 {
    return @bitCast(readU32LE(data, offset));
}

fn writeU16LE(buf: []u8, offset: usize, val: u16) void {
    if (offset + 2 > buf.len) return;
    buf[offset] = @truncate(val & 0xFF);
    buf[offset + 1] = @truncate((val >> 8) & 0xFF);
}

fn writeU32LE(buf: []u8, offset: usize, val: u32) void {
    if (offset + 4 > buf.len) return;
    buf[offset] = @truncate(val & 0xFF);
    buf[offset + 1] = @truncate((val >> 8) & 0xFF);
    buf[offset + 2] = @truncate((val >> 16) & 0xFF);
    buf[offset + 3] = @truncate((val >> 24) & 0xFF);
}

fn writeI32LE(buf: []u8, offset: usize, val: i32) void {
    writeU32LE(buf, offset, @bitCast(val));
}

// ---- Public API ----

/// Parse BMP headers from raw data. Returns null on invalid BMP.
pub fn parse(data: []const u8) ?BmpInfo {
    if (data.len < BMP_FILE_HEADER_SIZE + BMP_DIB_HEADER_SIZE) return null;

    var info: BmpInfo = undefined;
    info.valid = false;

    // Parse file header
    info.file_header.signature = readU16LE(data, 0);
    if (info.file_header.signature != BMP_SIGNATURE) return null;

    info.file_header.file_size = readU32LE(data, 2);
    info.file_header.reserved1 = readU16LE(data, 6);
    info.file_header.reserved2 = readU16LE(data, 8);
    info.file_header.data_offset = readU32LE(data, 10);

    // Parse DIB header (BITMAPINFOHEADER)
    info.dib_header.header_size = readU32LE(data, 14);
    if (info.dib_header.header_size < BMP_DIB_HEADER_SIZE) return null;

    info.dib_header.width = readI32LE(data, 18);
    info.dib_header.height = readI32LE(data, 22);
    info.dib_header.planes = readU16LE(data, 26);
    info.dib_header.bpp = readU16LE(data, 28);
    info.dib_header.compression = readU32LE(data, 30);
    info.dib_header.image_size = readU32LE(data, 34);
    info.dib_header.x_ppm = readI32LE(data, 38);
    info.dib_header.y_ppm = readI32LE(data, 42);
    info.dib_header.colors_used = readU32LE(data, 46);
    info.dib_header.colors_important = readU32LE(data, 50);

    // Validate
    if (info.dib_header.planes != 1) return null;
    if (info.dib_header.compression != 0) return null; // only uncompressed

    const bpp = info.dib_header.bpp;
    if (bpp != 1 and bpp != 4 and bpp != 8 and bpp != 24 and bpp != 32) return null;

    if (info.dib_header.width <= 0) return null;
    info.width = @intCast(info.dib_header.width);

    info.top_down = info.dib_header.height < 0;
    if (info.top_down) {
        info.height = @intCast(-info.dib_header.height);
    } else {
        info.height = @intCast(info.dib_header.height);
    }

    info.bpp = bpp;
    info.data_offset = info.file_header.data_offset;

    // Calculate row stride (rows are padded to 4-byte boundaries)
    const bits_per_row = @as(usize, info.width) * @as(usize, bpp);
    const bytes_per_row = (bits_per_row + 7) / 8;
    info.row_stride = (bytes_per_row + 3) & ~@as(usize, 3);

    // Parse color palette for 1/4/8 bpp
    info.palette_count = 0;
    if (bpp <= 8) {
        var palette_entries: usize = info.dib_header.colors_used;
        if (palette_entries == 0) {
            palette_entries = @as(usize, 1) << @intCast(bpp);
        }
        if (palette_entries > MAX_PALETTE_ENTRIES) palette_entries = MAX_PALETTE_ENTRIES;

        const palette_offset = BMP_FILE_HEADER_SIZE + info.dib_header.header_size;
        var i: usize = 0;
        while (i < palette_entries) : (i += 1) {
            const off = palette_offset + i * 4;
            if (off + 4 > data.len) break;
            info.palette[i].blue = data[off];
            info.palette[i].green = data[off + 1];
            info.palette[i].red = data[off + 2];
            info.palette[i].reserved = data[off + 3];
            info.palette_count += 1;
        }
    }

    // Validate data_offset
    if (info.data_offset >= data.len) return null;

    info.valid = true;
    return info;
}

/// Get pixel color at (x, y) as 0x00RRGGBB. Returns 0 on error.
pub fn getPixel(info: *const BmpInfo, data: []const u8, x: u32, y: u32) u32 {
    if (!info.valid or x >= info.width or y >= info.height) return 0;

    // BMP rows: bottom-up unless top_down
    const actual_y = if (info.top_down) y else (info.height - 1 - y);
    const row_offset = info.data_offset + @as(usize, actual_y) * info.row_stride;

    switch (info.bpp) {
        24 => {
            const px_offset = row_offset + @as(usize, x) * 3;
            if (px_offset + 3 > data.len) return 0;
            const b = data[px_offset];
            const g = data[px_offset + 1];
            const r = data[px_offset + 2];
            return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        },
        32 => {
            const px_offset = row_offset + @as(usize, x) * 4;
            if (px_offset + 4 > data.len) return 0;
            const b = data[px_offset];
            const g = data[px_offset + 1];
            const r = data[px_offset + 2];
            return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        },
        8 => {
            const px_offset = row_offset + @as(usize, x);
            if (px_offset >= data.len) return 0;
            const idx = data[px_offset];
            if (idx >= info.palette_count) return 0;
            const pe = info.palette[idx];
            return (@as(u32, pe.red) << 16) | (@as(u32, pe.green) << 8) | @as(u32, pe.blue);
        },
        4 => {
            const byte_offset = row_offset + @as(usize, x) / 2;
            if (byte_offset >= data.len) return 0;
            const byte_val = data[byte_offset];
            const idx: u8 = if (x % 2 == 0) (byte_val >> 4) else (byte_val & 0x0F);
            if (idx >= info.palette_count) return 0;
            const pe = info.palette[idx];
            return (@as(u32, pe.red) << 16) | (@as(u32, pe.green) << 8) | @as(u32, pe.blue);
        },
        1 => {
            const byte_offset = row_offset + @as(usize, x) / 8;
            if (byte_offset >= data.len) return 0;
            const byte_val = data[byte_offset];
            const bit: u3 = @truncate(7 - (x % 8));
            const idx: u8 = @truncate((byte_val >> bit) & 1);
            if (idx >= info.palette_count) return 0;
            const pe = info.palette[idx];
            return (@as(u32, pe.red) << 16) | (@as(u32, pe.green) << 8) | @as(u32, pe.blue);
        },
        else => return 0,
    }
}

/// Create a BMP file (8-bit or 24-bit) in the provided buffer.
/// Returns the number of bytes written, or 0 on error.
pub fn create(width: u32, height: u32, bpp: u16, buf: []u8) usize {
    if (width == 0 or height == 0) return 0;
    if (bpp != 8 and bpp != 24) return 0;

    const bits_per_row = @as(usize, width) * @as(usize, bpp);
    const bytes_per_row = (bits_per_row + 7) / 8;
    const row_stride = (bytes_per_row + 3) & ~@as(usize, 3);
    const image_size = row_stride * @as(usize, height);

    const palette_size: usize = if (bpp == 8) 256 * 4 else 0;
    const data_offset = BMP_FILE_HEADER_SIZE + BMP_DIB_HEADER_SIZE + palette_size;
    const file_size = data_offset + image_size;

    if (buf.len < file_size) return 0;

    // Zero the buffer
    var i: usize = 0;
    while (i < file_size) : (i += 1) {
        buf[i] = 0;
    }

    // Write file header
    writeU16LE(buf, 0, BMP_SIGNATURE);
    writeU32LE(buf, 2, @intCast(file_size));
    writeU16LE(buf, 6, 0); // reserved1
    writeU16LE(buf, 8, 0); // reserved2
    writeU32LE(buf, 10, @intCast(data_offset));

    // Write DIB header (BITMAPINFOHEADER)
    writeU32LE(buf, 14, BMP_DIB_HEADER_SIZE);
    writeI32LE(buf, 18, @intCast(width));
    writeI32LE(buf, 22, @intCast(height)); // bottom-up
    writeU16LE(buf, 26, 1); // planes
    writeU16LE(buf, 28, bpp);
    writeU32LE(buf, 30, 0); // compression = BI_RGB
    writeU32LE(buf, 34, @intCast(image_size));
    writeI32LE(buf, 38, 2835); // 72 DPI
    writeI32LE(buf, 42, 2835);
    writeU32LE(buf, 46, if (bpp == 8) 256 else 0);
    writeU32LE(buf, 50, 0);

    // Write default grayscale palette for 8-bit
    if (bpp == 8) {
        const palette_off = BMP_FILE_HEADER_SIZE + BMP_DIB_HEADER_SIZE;
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            const off = palette_off + c * 4;
            const v: u8 = @truncate(c);
            buf[off] = v; // blue
            buf[off + 1] = v; // green
            buf[off + 2] = v; // red
            buf[off + 3] = 0; // reserved
        }
    }

    return file_size;
}

/// Set a pixel in a BMP buffer created with create().
/// Supports 8-bit and 24-bit BMP.
pub fn setPixel(buf: []u8, width: u32, height: u32, bpp: u16, x: u32, y: u32, color: u32) void {
    if (x >= width or y >= height) return;
    if (bpp != 8 and bpp != 24) return;

    const bits_per_row = @as(usize, width) * @as(usize, bpp);
    const bytes_per_row = (bits_per_row + 7) / 8;
    const row_stride = (bytes_per_row + 3) & ~@as(usize, 3);
    const palette_size: usize = if (bpp == 8) 256 * 4 else 0;
    const data_offset = BMP_FILE_HEADER_SIZE + BMP_DIB_HEADER_SIZE + palette_size;

    // Bottom-up: row 0 is at the bottom
    const actual_y = height - 1 - y;
    const row_offset = data_offset + @as(usize, actual_y) * row_stride;

    if (bpp == 24) {
        const px_offset = row_offset + @as(usize, x) * 3;
        if (px_offset + 3 > buf.len) return;
        buf[px_offset] = @truncate(color & 0xFF); // blue
        buf[px_offset + 1] = @truncate((color >> 8) & 0xFF); // green
        buf[px_offset + 2] = @truncate((color >> 16) & 0xFF); // red
    } else if (bpp == 8) {
        const px_offset = row_offset + @as(usize, x);
        if (px_offset >= buf.len) return;
        buf[px_offset] = @truncate(color & 0xFF);
    }
}

/// Display a BMP image on the framebuffer at position (fb_x, fb_y).
pub fn displayOnFramebuf(info: *const BmpInfo, data: []const u8, fb_x: u32, fb_y: u32) void {
    if (!info.valid) return;
    if (!framebuf.isAvailable()) return;

    const max_w = framebuf.getWidth();
    const max_h = framebuf.getHeight();

    var py: u32 = 0;
    while (py < info.height) : (py += 1) {
        if (fb_y + py >= max_h) break;
        var px: u32 = 0;
        while (px < info.width) : (px += 1) {
            if (fb_x + px >= max_w) break;
            const color = getPixel(info, data, px, py);
            framebuf.putPixel(fb_x + px, fb_y + py, color);
        }
    }
}

/// Display a scaled BMP on framebuffer (nearest-neighbor scaling).
pub fn displayScaled(info: *const BmpInfo, data: []const u8, fb_x: u32, fb_y: u32, dest_w: u32, dest_h: u32) void {
    if (!info.valid or info.width == 0 or info.height == 0) return;
    if (!framebuf.isAvailable()) return;

    const max_w = framebuf.getWidth();
    const max_h = framebuf.getHeight();

    var dy: u32 = 0;
    while (dy < dest_h) : (dy += 1) {
        if (fb_y + dy >= max_h) break;
        const src_y = (dy * info.height) / dest_h;
        var dx: u32 = 0;
        while (dx < dest_w) : (dx += 1) {
            if (fb_x + dx >= max_w) break;
            const src_x = (dx * info.width) / dest_w;
            const color = getPixel(info, data, src_x, src_y);
            framebuf.putPixel(fb_x + dx, fb_y + dy, color);
        }
    }
}

/// Print BMP info to VGA.
pub fn printInfo(info: *const BmpInfo) void {
    if (!info.valid) {
        vga.write("BMP: invalid\n");
        return;
    }
    vga.setColor(.light_cyan, .black);
    vga.write("BMP Image Info:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Size:       ");
    fmt.printDec(info.width);
    vga.write(" x ");
    fmt.printDec(info.height);
    vga.write(" pixels\n");

    vga.write("  BPP:        ");
    fmt.printDec(info.bpp);
    vga.write("\n");

    vga.write("  File size:  ");
    fmt.printDec(info.file_header.file_size);
    vga.write(" bytes\n");

    vga.write("  Data off:   ");
    fmt.printDec(info.data_offset);
    vga.write("\n");

    vga.write("  Row stride: ");
    fmt.printDec(info.row_stride);
    vga.write(" bytes\n");

    vga.write("  Orientation: ");
    if (info.top_down) {
        vga.write("top-down\n");
    } else {
        vga.write("bottom-up\n");
    }

    if (info.palette_count > 0) {
        vga.write("  Palette:    ");
        fmt.printDec(info.palette_count);
        vga.write(" entries\n");
    }

    vga.write("  Compression: ");
    if (info.dib_header.compression == 0) {
        vga.write("none (BI_RGB)\n");
    } else {
        fmt.printDec(info.dib_header.compression);
        vga.write("\n");
    }
}

/// Convert an RGB color (0x00RRGGBB) to a grayscale value (0-255).
pub fn rgbToGray(color: u32) u8 {
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    // Luminance: 0.299*R + 0.587*G + 0.114*B (integer approximation)
    return @truncate((r * 77 + g * 150 + b * 29) >> 8);
}

/// Count unique colors in a BMP image (up to max_count).
pub fn countColors(info: *const BmpInfo, data: []const u8, max_count: usize) usize {
    if (!info.valid) return 0;
    if (info.bpp <= 8) return info.palette_count;

    // For high-color, sample and count unique values
    const MAX_TRACK = 64;
    var seen: [MAX_TRACK]u32 = undefined;
    var count: usize = 0;

    var py: u32 = 0;
    while (py < info.height) : (py += 1) {
        var px: u32 = 0;
        while (px < info.width) : (px += 1) {
            const c = getPixel(info, data, px, py);
            var found = false;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (seen[i] == c) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (count >= MAX_TRACK or count >= max_count) return count;
                seen[count] = c;
                count += 1;
            }
        }
    }
    return count;
}

/// Fill a rectangle within a BMP buffer with a solid color.
pub fn fillRect(buf: []u8, width: u32, height: u32, bpp: u16, rx: u32, ry: u32, rw: u32, rh: u32, color: u32) void {
    var dy: u32 = 0;
    while (dy < rh) : (dy += 1) {
        if (ry + dy >= height) break;
        var dx: u32 = 0;
        while (dx < rw) : (dx += 1) {
            if (rx + dx >= width) break;
            setPixel(buf, width, height, bpp, rx + dx, ry + dy, color);
        }
    }
}

/// Draw a horizontal line in a BMP buffer.
pub fn drawHLine(buf: []u8, width: u32, height: u32, bpp: u16, x: u32, y: u32, length: u32, color: u32) void {
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        setPixel(buf, width, height, bpp, x + i, y, color);
    }
}

/// Draw a vertical line in a BMP buffer.
pub fn drawVLine(buf: []u8, width: u32, height: u32, bpp: u16, x: u32, y: u32, length: u32, color: u32) void {
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        setPixel(buf, width, height, bpp, x, y + i, color);
    }
}
