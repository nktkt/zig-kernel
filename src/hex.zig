// Hexadecimal utilities and hex editor — encode, decode, xxd-style dump, diff, search
//
// Provides hex encoding/decoding, xxd-style memory dumps with ASCII sidebar,
// paginated hex view, side-by-side hex comparison, pattern searching, and
// an ASCII/hex reference table.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Constants ----

const HEX_CHARS = "0123456789abcdef";
const HEX_CHARS_UPPER = "0123456789ABCDEF";
const BYTES_PER_LINE = 16;
const LINES_PER_PAGE = 16;

// ---- Hex encoding ----

/// Encode a byte slice as a hex string. Returns the written portion of buf.
/// Each input byte produces 2 hex characters.
pub fn hexEncode(data: []const u8, buf: []u8) []u8 {
    const max_bytes = buf.len / 2;
    const n = if (data.len < max_bytes) data.len else max_bytes;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i * 2] = HEX_CHARS[data[i] >> 4];
        buf[i * 2 + 1] = HEX_CHARS[data[i] & 0x0F];
    }
    return buf[0 .. n * 2];
}

/// Encode a byte slice as uppercase hex string.
pub fn hexEncodeUpper(data: []const u8, buf: []u8) []u8 {
    const max_bytes = buf.len / 2;
    const n = if (data.len < max_bytes) data.len else max_bytes;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i * 2] = HEX_CHARS_UPPER[data[i] >> 4];
        buf[i * 2 + 1] = HEX_CHARS_UPPER[data[i] & 0x0F];
    }
    return buf[0 .. n * 2];
}

/// Decode a hex string into bytes. Returns the written portion of buf, or null on error.
pub fn hexDecode(hex_str: []const u8, buf: []u8) ?[]u8 {
    if (hex_str.len % 2 != 0) return null;

    const n = hex_str.len / 2;
    if (n > buf.len) return null;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hi = hexCharToVal(hex_str[i * 2]) orelse return null;
        const lo = hexCharToVal(hex_str[i * 2 + 1]) orelse return null;
        buf[i] = (hi << 4) | lo;
    }
    return buf[0..n];
}

/// Convert a single hex character to its 4-bit value.
fn hexCharToVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @truncate(c - '0');
    if (c >= 'a' and c <= 'f') return @truncate(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @truncate(c - 'A' + 10);
    return null;
}

/// Check if a string is valid hex.
pub fn isValidHex(s: []const u8) bool {
    if (s.len % 2 != 0) return false;
    for (s) |c| {
        if (hexCharToVal(c) == null) return false;
    }
    return true;
}

// ---- xxd-style dump ----

/// Print an xxd-style hex dump of data with a base address.
/// Format: ADDR  XX XX XX ... XX  |ASCII...|
pub fn xxd(data: []const u8, base_addr: usize) void {
    var offset: usize = 0;
    while (offset < data.len) {
        // Address
        vga.setColor(.dark_grey, .black);
        fmt.printHex32(@truncate(base_addr + offset));
        vga.write(": ");

        // Hex bytes
        vga.setColor(.light_grey, .black);
        var i: usize = 0;
        while (i < BYTES_PER_LINE) : (i += 1) {
            if (offset + i < data.len) {
                const b = data[offset + i];
                // Color non-zero bytes differently
                if (b == 0) {
                    vga.setColor(.dark_grey, .black);
                } else if (b >= 0x20 and b < 0x7F) {
                    vga.setColor(.light_green, .black);
                } else {
                    vga.setColor(.light_cyan, .black);
                }
                fmt.printHex8(b);
                vga.setColor(.light_grey, .black);
                vga.putChar(' ');
            } else {
                vga.write("   ");
            }
            if (i == 7) vga.putChar(' '); // extra space at midpoint
        }

        // ASCII sidebar
        vga.setColor(.dark_grey, .black);
        vga.write(" |");
        vga.setColor(.yellow, .black);
        i = 0;
        while (i < BYTES_PER_LINE and offset + i < data.len) : (i += 1) {
            const c = data[offset + i];
            if (c >= 0x20 and c < 0x7F) {
                vga.putChar(c);
            } else {
                vga.setColor(.dark_grey, .black);
                vga.putChar('.');
                vga.setColor(.yellow, .black);
            }
        }
        vga.setColor(.dark_grey, .black);
        vga.write("|\n");

        offset += BYTES_PER_LINE;
    }

    vga.setColor(.light_grey, .black);
}

/// Print a compact hex dump (no ASCII, no address coloring).
pub fn xxdCompact(data: []const u8, base_addr: usize) void {
    var offset: usize = 0;
    while (offset < data.len) {
        fmt.printHex32(@truncate(base_addr + offset));
        vga.write(": ");

        var i: usize = 0;
        while (i < BYTES_PER_LINE) : (i += 1) {
            if (offset + i < data.len) {
                fmt.printHex8(data[offset + i]);
                vga.putChar(' ');
            } else {
                vga.write("   ");
            }
        }
        vga.putChar('\n');
        offset += BYTES_PER_LINE;
    }
}

// ---- Paginated hex view ----

/// Display a paginated hex view of data. Shows LINES_PER_PAGE lines at a time.
/// page_num is 0-indexed.
pub fn interactiveHexView(data: []const u8, page_num: usize) void {
    const bytes_per_page = BYTES_PER_LINE * LINES_PER_PAGE;
    const total_pages = (data.len + bytes_per_page - 1) / bytes_per_page;
    const start_offset = page_num * bytes_per_page;

    if (start_offset >= data.len) {
        vga.write("(page out of range)\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Hex View Page ");
    fmt.printDec(page_num + 1);
    vga.write("/");
    fmt.printDec(total_pages);
    vga.write(" (");
    fmt.printDec(data.len);
    vga.write(" bytes total) ===\n");

    const end_offset = if (start_offset + bytes_per_page > data.len) data.len else start_offset + bytes_per_page;
    xxd(data[start_offset..end_offset], start_offset);

    vga.setColor(.dark_grey, .black);
    vga.write("--- Page ");
    fmt.printDec(page_num + 1);
    vga.write(" of ");
    fmt.printDec(total_pages);
    vga.write(" ---\n");
}

// ---- Side-by-side hex diff ----

/// Compare two byte slices and print a side-by-side hex diff.
/// Differences are highlighted in red.
pub fn compareHex(a: []const u8, b: []const u8) void {
    const max_len = if (a.len > b.len) a.len else b.len;

    vga.setColor(.light_cyan, .black);
    vga.write("=== Hex Compare ===\n");
    vga.setColor(.yellow, .black);
    vga.write("OFFSET   LEFT              RIGHT             DIFF\n");
    vga.setColor(.light_grey, .black);

    var offset: usize = 0;
    var diff_count: usize = 0;

    while (offset < max_len) {
        // Check if this line has any differences
        var line_has_diff = false;
        var i: usize = 0;
        while (i < 8 and offset + i < max_len) : (i += 1) {
            const av: u8 = if (offset + i < a.len) a[offset + i] else 0;
            const bv: u8 = if (offset + i < b.len) b[offset + i] else 0;
            if (av != bv) line_has_diff = true;
        }

        if (line_has_diff) {
            // Offset
            vga.setColor(.dark_grey, .black);
            fmt.printHex32(@truncate(offset));
            vga.write(" ");

            // Left side
            i = 0;
            while (i < 8) : (i += 1) {
                if (offset + i < a.len) {
                    const av = a[offset + i];
                    const bv: u8 = if (offset + i < b.len) b[offset + i] else 0;
                    if (av != bv) {
                        vga.setColor(.light_red, .black);
                    } else {
                        vga.setColor(.light_grey, .black);
                    }
                    fmt.printHex8(av);
                } else {
                    vga.setColor(.dark_grey, .black);
                    vga.write("--");
                }
                vga.putChar(' ');
            }

            vga.setColor(.dark_grey, .black);
            vga.write(" ");

            // Right side
            i = 0;
            while (i < 8) : (i += 1) {
                if (offset + i < b.len) {
                    const av: u8 = if (offset + i < a.len) a[offset + i] else 0;
                    const bv = b[offset + i];
                    if (av != bv) {
                        vga.setColor(.light_green, .black);
                    } else {
                        vga.setColor(.light_grey, .black);
                    }
                    fmt.printHex8(bv);
                } else {
                    vga.setColor(.dark_grey, .black);
                    vga.write("--");
                }
                vga.putChar(' ');
            }

            // Diff count for this line
            i = 0;
            var line_diffs: usize = 0;
            while (i < 8 and offset + i < max_len) : (i += 1) {
                const av: u8 = if (offset + i < a.len) a[offset + i] else 0;
                const bv: u8 = if (offset + i < b.len) b[offset + i] else 0;
                if (av != bv) line_diffs += 1;
            }
            diff_count += line_diffs;

            vga.setColor(.yellow, .black);
            vga.write(" ");
            fmt.printDec(line_diffs);
            vga.putChar('\n');
        }

        offset += 8;
    }

    vga.setColor(.light_grey, .black);
    vga.write("\nTotal differences: ");
    fmt.printDec(diff_count);
    vga.write(" bytes\n");
}

// ---- Byte patching ----

/// Patch a single byte in a buffer.
pub fn patchByte(data: []u8, offset: usize, value: u8) bool {
    if (offset >= data.len) return false;
    data[offset] = value;
    return true;
}

/// Patch multiple bytes from a hex string.
pub fn patchHex(data: []u8, offset: usize, hex_str: []const u8) bool {
    var decode_buf: [128]u8 = undefined;
    const decoded = hexDecode(hex_str, &decode_buf) orelse return false;
    if (offset + decoded.len > data.len) return false;

    var i: usize = 0;
    while (i < decoded.len) : (i += 1) {
        data[offset + i] = decoded[i];
    }
    return true;
}

// ---- Pattern search ----

/// Search for a byte pattern in data. Returns the offset of the first match, or null.
pub fn searchPattern(data: []const u8, pattern: []const u8) ?usize {
    if (pattern.len == 0 or pattern.len > data.len) return null;

    var i: usize = 0;
    while (i <= data.len - pattern.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < pattern.len) : (j += 1) {
            if (data[i + j] != pattern[j]) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Search for a hex pattern string in data.
pub fn searchHexPattern(data: []const u8, hex_pattern: []const u8) ?usize {
    var pat_buf: [64]u8 = undefined;
    const decoded = hexDecode(hex_pattern, &pat_buf) orelse return null;
    return searchPattern(data, decoded);
}

/// Count all occurrences of a pattern.
pub fn countPattern(data: []const u8, pattern: []const u8) usize {
    if (pattern.len == 0 or pattern.len > data.len) return 0;

    var count: usize = 0;
    var i: usize = 0;
    while (i <= data.len - pattern.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < pattern.len) : (j += 1) {
            if (data[i + j] != pattern[j]) {
                match = false;
                break;
            }
        }
        if (match) count += 1;
    }
    return count;
}

// ---- ASCII/Hex reference table ----

/// Print an ASCII/hex reference table for printable characters.
pub fn printHexTable() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== ASCII / Hex Reference Table ===\n\n");

    // Header
    vga.setColor(.yellow, .black);
    vga.write("Char  Hex  Dec  Oct  | Char  Hex  Dec  Oct\n");
    vga.setColor(.dark_grey, .black);
    vga.write("----------------------------------------------\n");

    // Print in two columns: 0x20-0x4F | 0x50-0x7E
    var row: u8 = 0x20;
    while (row < 0x50) : (row += 1) {
        printCharEntry(row);
        vga.write("  | ");
        if (row + 0x30 < 0x7F) {
            printCharEntry(row + 0x30);
        }
        vga.putChar('\n');
    }
}

fn printCharEntry(c: u8) void {
    // Character
    vga.setColor(.light_green, .black);
    if (c >= 0x20 and c < 0x7F) {
        vga.write("  ");
        vga.putChar(c);
        vga.write("  ");
    } else {
        vga.write("  .  ");
    }

    // Hex
    vga.setColor(.light_cyan, .black);
    vga.write(" 0x");
    fmt.printHex8(c);

    // Decimal
    vga.setColor(.light_grey, .black);
    vga.write("  ");
    fmt.printDecPadded(@as(usize, c), 3);

    // Octal
    vga.setColor(.dark_grey, .black);
    vga.write("  ");
    printOctal(c);
}

fn printOctal(val: u8) void {
    const d2 = val / 64;
    const d1 = (val % 64) / 8;
    const d0 = val % 8;
    vga.putChar('0' + d2);
    vga.putChar('0' + d1);
    vga.putChar('0' + d0);
}

/// Print summary of a data buffer.
pub fn printSummary(data: []const u8) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Data Summary ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Size: ");
    fmt.printDec(data.len);
    vga.write(" bytes\n");

    // Count byte classes
    var zeros: usize = 0;
    var printable: usize = 0;
    var control: usize = 0;
    var high: usize = 0;

    for (data) |b| {
        if (b == 0) zeros += 1
        else if (b >= 0x20 and b < 0x7F) printable += 1
        else if (b < 0x20) control += 1
        else high += 1;
    }

    vga.write("Zero bytes:    ");
    fmt.printDec(zeros);
    vga.putChar('\n');
    vga.write("Printable:     ");
    fmt.printDec(printable);
    vga.putChar('\n');
    vga.write("Control chars: ");
    fmt.printDec(control);
    vga.putChar('\n');
    vga.write("High bytes:    ");
    fmt.printDec(high);
    vga.putChar('\n');
}
