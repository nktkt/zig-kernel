// UTF-8 Handling -- Decode, encode, validate, iterate over UTF-8 strings
// Supports full Unicode range (U+0000 to U+10FFFF)

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Types ----

/// A decoded Unicode codepoint with its byte length in UTF-8.
pub const Codepoint = struct {
    value: u32, // Unicode codepoint (0 to 0x10FFFF)
    byte_len: u8, // Number of bytes in UTF-8 encoding (1-4)
};

/// Iterator over codepoints in a UTF-8 string.
pub const Utf8Iterator = struct {
    bytes: []const u8,
    pos: usize,

    /// Get the next codepoint, or null if at end or invalid.
    pub fn next(self: *Utf8Iterator) ?Codepoint {
        if (self.pos >= self.bytes.len) return null;
        const result = decodeChar(self.bytes[self.pos..]) orelse return null;
        self.pos += result.byte_len;
        return result;
    }

    /// Peek at the next codepoint without advancing.
    pub fn peek(self: *const Utf8Iterator) ?Codepoint {
        if (self.pos >= self.bytes.len) return null;
        return decodeChar(self.bytes[self.pos..]);
    }

    /// Check if the iterator has more codepoints.
    pub fn hasNext(self: *const Utf8Iterator) bool {
        return self.pos < self.bytes.len;
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *Utf8Iterator) void {
        self.pos = 0;
    }

    /// Get the remaining bytes.
    pub fn remaining(self: *const Utf8Iterator) []const u8 {
        return self.bytes[self.pos..];
    }
};

// ---- Decoding ----

/// Determine the number of bytes needed for a UTF-8 character
/// based on the first byte. Returns 0 for invalid lead bytes.
pub fn charLen(first_byte: u8) u8 {
    if (first_byte < 0x80) return 1; // 0xxxxxxx
    if (first_byte & 0xE0 == 0xC0) return 2; // 110xxxxx
    if (first_byte & 0xF0 == 0xE0) return 3; // 1110xxxx
    if (first_byte & 0xF8 == 0xF0) return 4; // 11110xxx
    return 0; // Invalid lead byte (continuation byte or 0xFE/0xFF)
}

/// Decode one UTF-8 character from the start of `bytes`.
/// Returns null if the bytes are not a valid UTF-8 sequence.
pub fn decodeChar(bytes: []const u8) ?Codepoint {
    if (bytes.len == 0) return null;

    const first = bytes[0];
    const len = charLen(first);
    if (len == 0) return null;
    if (bytes.len < len) return null;

    var value: u32 = 0;

    switch (len) {
        1 => {
            value = first;
        },
        2 => {
            if (!isContinuation(bytes[1])) return null;
            value = (@as(u32, first & 0x1F) << 6) |
                @as(u32, bytes[1] & 0x3F);
            // Overlong check: must be >= 0x80
            if (value < 0x80) return null;
        },
        3 => {
            if (!isContinuation(bytes[1]) or !isContinuation(bytes[2])) return null;
            value = (@as(u32, first & 0x0F) << 12) |
                (@as(u32, bytes[1] & 0x3F) << 6) |
                @as(u32, bytes[2] & 0x3F);
            // Overlong check: must be >= 0x800
            if (value < 0x800) return null;
            // Surrogate check
            if (value >= 0xD800 and value <= 0xDFFF) return null;
        },
        4 => {
            if (!isContinuation(bytes[1]) or !isContinuation(bytes[2]) or !isContinuation(bytes[3])) return null;
            value = (@as(u32, first & 0x07) << 18) |
                (@as(u32, bytes[1] & 0x3F) << 12) |
                (@as(u32, bytes[2] & 0x3F) << 6) |
                @as(u32, bytes[3] & 0x3F);
            // Overlong check: must be >= 0x10000
            if (value < 0x10000) return null;
            // Maximum Unicode codepoint
            if (value > 0x10FFFF) return null;
        },
        else => return null,
    }

    return Codepoint{ .value = value, .byte_len = len };
}

/// Encode a Unicode codepoint to UTF-8 bytes.
/// Returns the number of bytes written (1-4), or 0 if the codepoint is invalid.
/// `buf` must be at least 4 bytes.
pub fn encodeChar(codepoint: u32, buf: []u8) u8 {
    if (buf.len < 4) return 0;

    if (codepoint < 0x80) {
        buf[0] = @truncate(codepoint);
        return 1;
    } else if (codepoint < 0x800) {
        buf[0] = @truncate(0xC0 | (codepoint >> 6));
        buf[1] = @truncate(0x80 | (codepoint & 0x3F));
        return 2;
    } else if (codepoint < 0x10000) {
        // Reject surrogates
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return 0;
        buf[0] = @truncate(0xE0 | (codepoint >> 12));
        buf[1] = @truncate(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @truncate(0x80 | (codepoint & 0x3F));
        return 3;
    } else if (codepoint <= 0x10FFFF) {
        buf[0] = @truncate(0xF0 | (codepoint >> 18));
        buf[1] = @truncate(0x80 | ((codepoint >> 12) & 0x3F));
        buf[2] = @truncate(0x80 | ((codepoint >> 6) & 0x3F));
        buf[3] = @truncate(0x80 | (codepoint & 0x3F));
        return 4;
    }
    return 0; // Invalid codepoint
}

// ---- String Functions ----

/// Count the number of Unicode codepoints in a UTF-8 string.
/// Returns 0 if the string contains invalid UTF-8.
pub fn strlen(s: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        const len = charLen(s[pos]);
        if (len == 0 or pos + len > s.len) return count;
        pos += len;
        count += 1;
    }
    return count;
}

/// Validate a UTF-8 string. Returns true if all bytes form valid UTF-8.
pub fn isValid(s: []const u8) bool {
    var pos: usize = 0;
    while (pos < s.len) {
        const cp = decodeChar(s[pos..]) orelse return false;
        pos += cp.byte_len;
    }
    return true;
}

/// Check if a string is pure ASCII (all bytes < 128).
pub fn isAscii(s: []const u8) bool {
    for (s) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

/// Create an iterator over codepoints in a UTF-8 string.
pub fn iterator(s: []const u8) Utf8Iterator {
    return Utf8Iterator{ .bytes = s, .pos = 0 };
}

// ---- Character Classification ----

/// Check if a codepoint is an ASCII or Latin letter (basic letter check).
pub fn isAlpha(cp: u32) bool {
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp >= 'a' and cp <= 'z') return true;
    // Basic Latin supplement (accented letters)
    if (cp >= 0xC0 and cp <= 0xFF and cp != 0xD7 and cp != 0xF7) return true;
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // Hiragana
    if (cp >= 0x3040 and cp <= 0x309F) return true;
    // Katakana
    if (cp >= 0x30A0 and cp <= 0x30FF) return true;
    // Hangul
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
    // Greek
    if (cp >= 0x0370 and cp <= 0x03FF) return true;
    // Cyrillic
    if (cp >= 0x0400 and cp <= 0x04FF) return true;
    // Arabic
    if (cp >= 0x0600 and cp <= 0x06FF) return true;
    return false;
}

/// Check if a codepoint is a digit.
pub fn isDigit(cp: u32) bool {
    return cp >= '0' and cp <= '9';
}

/// Check if a codepoint is whitespace.
pub fn isSpace(cp: u32) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        0x00A0 => true, // No-break space
        0x2000...0x200B => true, // Various typographic spaces
        0x2028 => true, // Line separator
        0x2029 => true, // Paragraph separator
        0x3000 => true, // Ideographic space
        0xFEFF => true, // BOM / zero-width no-break space
        else => false,
    };
}

/// Check if a codepoint is punctuation (basic set).
pub fn isPunctuation(cp: u32) bool {
    // ASCII punctuation
    if (cp >= 0x21 and cp <= 0x2F) return true;
    if (cp >= 0x3A and cp <= 0x40) return true;
    if (cp >= 0x5B and cp <= 0x60) return true;
    if (cp >= 0x7B and cp <= 0x7E) return true;
    // General punctuation block
    if (cp >= 0x2000 and cp <= 0x206F) return true;
    // CJK punctuation
    if (cp >= 0x3000 and cp <= 0x303F) return true;
    return false;
}

/// Convert a codepoint to ASCII if possible (returns null for non-ASCII).
pub fn toAscii(cp: u32) ?u8 {
    if (cp < 0x80) return @truncate(cp);
    return null;
}

/// Convert a codepoint to lowercase if it's an ASCII letter.
pub fn toLower(cp: u32) u32 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return cp;
}

/// Convert a codepoint to uppercase if it's an ASCII letter.
pub fn toUpper(cp: u32) u32 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    return cp;
}

// ---- Internal Helpers ----

fn isContinuation(b: u8) bool {
    return (b & 0xC0) == 0x80; // 10xxxxxx
}

// ---- Display ----

/// Print a codepoint as U+XXXX format.
pub fn printCodepoint(cp: u32) void {
    vga.write("U+");
    printHex(cp);
}

fn printHex(val: u32) void {
    const hex = "0123456789ABCDEF";
    // Determine number of hex digits needed
    var digits: usize = 4; // minimum 4 digits
    if (val >= 0x10000) digits = 6;
    if (val >= 0x100000) digits = 6;

    var shift: usize = (digits - 1) * 4;
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        const nibble: u4 = @truncate((val >> @truncate(shift)) & 0xF);
        vga.putChar(hex[nibble]);
        if (shift >= 4) {
            shift -= 4;
        } else {
            break;
        }
    }
}

/// Self-test for UTF-8 module.
pub fn selfTest() void {
    vga.setColor(.yellow, .black);
    vga.write("UTF-8 self-test:\n");
    vga.setColor(.light_grey, .black);

    var passed: usize = 0;
    var failed: usize = 0;

    // Test 1: ASCII decoding
    {
        const s = "A";
        if (decodeChar(s)) |cp| {
            if (cp.value == 0x41 and cp.byte_len == 1) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: ASCII decode\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: ASCII decode null\n");
        }
    }

    // Test 2: 2-byte character (C3 A9 = U+00E9 'e with acute')
    {
        const s = [_]u8{ 0xC3, 0xA9 };
        if (decodeChar(&s)) |cp| {
            if (cp.value == 0x00E9 and cp.byte_len == 2) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: 2-byte decode\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: 2-byte decode null\n");
        }
    }

    // Test 3: 3-byte character (E3 81 82 = U+3042 Hiragana 'a')
    {
        const s = [_]u8{ 0xE3, 0x81, 0x82 };
        if (decodeChar(&s)) |cp| {
            if (cp.value == 0x3042 and cp.byte_len == 3) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: 3-byte decode\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: 3-byte decode null\n");
        }
    }

    // Test 4: encode and roundtrip
    {
        var buf: [4]u8 = undefined;
        const len = encodeChar(0x3042, &buf);
        if (len == 3 and buf[0] == 0xE3 and buf[1] == 0x81 and buf[2] == 0x82) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: encode U+3042\n");
        }
    }

    // Test 5: strlen
    {
        // "Aあ" = 'A' (1 byte) + U+3042 (3 bytes) = 4 bytes, 2 codepoints
        const s = [_]u8{ 'A', 0xE3, 0x81, 0x82 };
        if (strlen(&s) == 2) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: strlen\n");
        }
    }

    // Test 6: isValid
    {
        const valid = "Hello";
        const invalid = [_]u8{ 0xFF, 0xFE };
        if (isValid(valid) and !isValid(&invalid)) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: isValid\n");
        }
    }

    // Test 7: isAscii
    {
        if (isAscii("Hello") and !isAscii(&[_]u8{ 0xC3, 0xA9 })) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: isAscii\n");
        }
    }

    // Test 8: overlong rejection
    {
        // Overlong encoding of U+0041 (should be 1 byte, encoded as 2)
        const overlong = [_]u8{ 0xC1, 0x81 };
        if (decodeChar(&overlong) == null) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: overlong rejection\n");
        }
    }

    // Test 9: surrogate rejection
    {
        // U+D800 (surrogate) encoded as UTF-8 (invalid)
        const surrogate = [_]u8{ 0xED, 0xA0, 0x80 };
        if (decodeChar(&surrogate) == null) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: surrogate rejection\n");
        }
    }

    vga.setColor(.light_green, .black);
    vga.write("  Passed: ");
    printDecUsize(passed);
    vga.setColor(.light_red, .black);
    vga.write("  Failed: ");
    printDecUsize(failed);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

fn printDecUsize(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
