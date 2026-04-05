// Base64 Encoder/Decoder -- Standard Base64 alphabet (RFC 4648)
// A-Z, a-z, 0-9, +, / with = padding

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Alphabet ----

const encode_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Decode table: maps ASCII value to 6-bit value, 0xFF = invalid
const decode_table: [256]u8 = blk: {
    @setEvalBranchQuota(3000);
    var table: [256]u8 = [_]u8{0xFF} ** 256;
    const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (alpha, 0..) |c, i| {
        table[c] = @truncate(i);
    }
    break :blk table;
};

// ---- Size Calculation ----

/// Calculate the encoded output length for a given input length (including padding).
pub fn encodedLength(input_len: usize) usize {
    if (input_len == 0) return 0;
    return ((input_len + 2) / 3) * 4;
}

/// Calculate the maximum decoded output length for a given base64 input length.
/// The actual length may be less due to padding.
pub fn decodedLength(input_len: usize) usize {
    if (input_len == 0) return 0;
    return (input_len / 4) * 3;
}

// ---- Encode ----

/// Encode input bytes to base64 string.
/// Returns the number of bytes written to output.
/// Output buffer must be at least encodedLength(input.len) bytes.
pub fn encode(input: []const u8, output: []u8) usize {
    if (input.len == 0) return 0;

    const out_len = encodedLength(input.len);
    if (output.len < out_len) return 0;

    var out_idx: usize = 0;
    var i: usize = 0;

    // Process 3-byte groups
    while (i + 3 <= input.len) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];

        output[out_idx] = encode_table[b0 >> 2];
        output[out_idx + 1] = encode_table[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[out_idx + 2] = encode_table[((b1 & 0x0F) << 2) | (b2 >> 6)];
        output[out_idx + 3] = encode_table[b2 & 0x3F];

        i += 3;
        out_idx += 4;
    }

    // Handle remaining bytes (1 or 2)
    const remaining = input.len - i;
    if (remaining == 1) {
        const b0 = input[i];
        output[out_idx] = encode_table[b0 >> 2];
        output[out_idx + 1] = encode_table[(b0 & 0x03) << 4];
        output[out_idx + 2] = '=';
        output[out_idx + 3] = '=';
        out_idx += 4;
    } else if (remaining == 2) {
        const b0 = input[i];
        const b1 = input[i + 1];
        output[out_idx] = encode_table[b0 >> 2];
        output[out_idx + 1] = encode_table[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[out_idx + 2] = encode_table[(b1 & 0x0F) << 2];
        output[out_idx + 3] = '=';
        out_idx += 4;
    }

    return out_idx;
}

// ---- Decode ----

/// Decode a base64 string to bytes.
/// Returns the number of bytes written to output, or null if input is invalid.
/// Output buffer must be at least decodedLength(input.len) bytes.
pub fn decode(input: []const u8, output: []u8) ?usize {
    if (input.len == 0) return 0;

    // Base64 input length must be a multiple of 4
    if (input.len % 4 != 0) return null;

    const max_out = decodedLength(input.len);
    if (output.len < max_out) return null;

    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        // Decode 4 base64 characters to 3 bytes
        const c0 = input[i];
        const c1 = input[i + 1];
        const c2 = input[i + 2];
        const c3 = input[i + 3];

        const v0 = decode_table[c0];
        const v1 = decode_table[c1];

        // First two chars must always be valid
        if (v0 == 0xFF or v1 == 0xFF) return null;

        // Handle padding
        if (c2 == '=' and c3 == '=') {
            // One output byte
            output[out_idx] = (v0 << 2) | (v1 >> 4);
            out_idx += 1;
        } else if (c3 == '=') {
            // Two output bytes
            const v2 = decode_table[c2];
            if (v2 == 0xFF) return null;
            output[out_idx] = (v0 << 2) | (v1 >> 4);
            output[out_idx + 1] = ((v1 & 0x0F) << 4) | (v2 >> 2);
            out_idx += 2;
        } else {
            // Three output bytes
            const v2 = decode_table[c2];
            const v3 = decode_table[c3];
            if (v2 == 0xFF or v3 == 0xFF) return null;
            output[out_idx] = (v0 << 2) | (v1 >> 4);
            output[out_idx + 1] = ((v1 & 0x0F) << 4) | (v2 >> 2);
            output[out_idx + 2] = ((v2 & 0x03) << 6) | v3;
            out_idx += 3;
        }

        i += 4;
    }

    return out_idx;
}

// ---- Validation ----

/// Check if a string is valid base64.
pub fn isValid(input: []const u8) bool {
    if (input.len == 0) return true;
    if (input.len % 4 != 0) return false;

    var i: usize = 0;
    // Check all but last group
    while (i + 4 < input.len) {
        if (decode_table[input[i]] == 0xFF) return false;
        if (decode_table[input[i + 1]] == 0xFF) return false;
        if (decode_table[input[i + 2]] == 0xFF) return false;
        if (decode_table[input[i + 3]] == 0xFF) return false;
        i += 4;
    }

    // Check last group (may have padding)
    if (i < input.len) {
        if (decode_table[input[i]] == 0xFF) return false;
        if (decode_table[input[i + 1]] == 0xFF) return false;

        if (input[i + 2] == '=') {
            if (input[i + 3] != '=') return false;
        } else {
            if (decode_table[input[i + 2]] == 0xFF) return false;
            if (input[i + 3] != '=' and decode_table[input[i + 3]] == 0xFF) return false;
        }
    }

    return true;
}

// ---- Display / Self-test ----

/// Run base64 self-test.
pub fn selfTest() void {
    vga.setColor(.yellow, .black);
    vga.write("Base64 self-test:\n");
    vga.setColor(.light_grey, .black);

    var passed: usize = 0;
    var failed: usize = 0;

    // Test 1: encode "Hello"
    {
        const input = "Hello";
        var out: [16]u8 = undefined;
        const len = encode(input, &out);
        if (len == 8 and eql(out[0..8], "SGVsbG8=")) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: encode 'Hello'\n");
        }
    }

    // Test 2: decode "SGVsbG8="
    {
        const input = "SGVsbG8=";
        var out: [16]u8 = undefined;
        if (decode(input, &out)) |len| {
            if (len == 5 and eql(out[0..5], "Hello")) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: decode 'SGVsbG8=' result\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: decode 'SGVsbG8=' returned null\n");
        }
    }

    // Test 3: empty
    {
        var out: [4]u8 = undefined;
        const len = encode("", &out);
        if (len == 0) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: encode empty\n");
        }
    }

    // Test 4: roundtrip
    {
        const original = "Zig kernel!";
        var encoded: [32]u8 = undefined;
        var decoded: [32]u8 = undefined;
        const enc_len = encode(original, &encoded);
        if (decode(encoded[0..enc_len], &decoded)) |dec_len| {
            if (dec_len == original.len and eql(decoded[0..dec_len], original)) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: roundtrip mismatch\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: roundtrip decode\n");
        }
    }

    // Test 5: invalid input
    {
        if (!isValid("ABC")) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: invalid length check\n");
        }
    }

    // Test 6: encode "AB"
    {
        const input = "AB";
        var out: [8]u8 = undefined;
        const len = encode(input, &out);
        if (len == 4 and eql(out[0..4], "QUI=")) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: encode 'AB'\n");
        }
    }

    // Test 7: encode "A"
    {
        const input = "A";
        var out: [8]u8 = undefined;
        const len = encode(input, &out);
        if (len == 4 and eql(out[0..4], "QQ==")) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: encode 'A'\n");
        }
    }

    vga.setColor(.light_green, .black);
    vga.write("  Passed: ");
    printDec(passed);
    vga.setColor(.light_red, .black);
    vga.write("  Failed: ");
    printDec(failed);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

// ---- Helpers ----

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn printDec(n: usize) void {
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
