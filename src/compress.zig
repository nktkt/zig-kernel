// Simple Compression -- RLE (Run-Length Encoding) + LZ77-lite
// Designed for freestanding x86 kernel, no std library

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// RLE (Run-Length Encoding)
// ===========================================================================
//
// Format:
//   [count][byte]  -- if count >= 1: repeat byte 'count' times
//   [0][length][bytes...] -- literal run: 'length' literal bytes follow
//
// Maximum run length: 255 (one byte count)
// A count of 0 introduces a literal run, where the next byte is the literal length.

const RLE_LITERAL_MARKER: u8 = 0;
const RLE_MIN_RUN: usize = 3; // Minimum run length to compress as a run

/// Encode input using RLE. Returns number of bytes written to output.
/// Output buffer must be large enough (worst case: 2 * input.len for no runs).
pub fn rleEncode(input: []const u8, output: []u8) usize {
    if (input.len == 0) return 0;

    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (in_pos < input.len) {
        // Count run of identical bytes
        const current = input[in_pos];
        var run_len: usize = 1;
        while (in_pos + run_len < input.len and input[in_pos + run_len] == current and run_len < 255) {
            run_len += 1;
        }

        if (run_len >= RLE_MIN_RUN) {
            // Encode as a run
            if (out_pos + 2 > output.len) break;
            output[out_pos] = @truncate(run_len);
            output[out_pos + 1] = current;
            out_pos += 2;
            in_pos += run_len;
        } else {
            // Collect literals until we hit a run or reach max literal length
            const lit_start = in_pos;
            var lit_len: usize = 0;

            while (in_pos + lit_len < input.len and lit_len < 255) {
                // Check if a run starts here
                if (lit_len > 0) {
                    var ahead_run: usize = 1;
                    const ahead_byte = input[in_pos + lit_len];
                    while (in_pos + lit_len + ahead_run < input.len and input[in_pos + lit_len + ahead_run] == ahead_byte and ahead_run < 255) {
                        ahead_run += 1;
                    }
                    if (ahead_run >= RLE_MIN_RUN) break;
                }
                lit_len += 1;
            }

            if (lit_len == 0) {
                // Should not happen, but handle gracefully
                if (out_pos + 2 > output.len) break;
                output[out_pos] = 1;
                output[out_pos + 1] = input[in_pos];
                out_pos += 2;
                in_pos += 1;
            } else {
                // Encode as literal run: [0][length][bytes...]
                if (out_pos + 2 + lit_len > output.len) break;
                output[out_pos] = RLE_LITERAL_MARKER;
                output[out_pos + 1] = @truncate(lit_len);
                var k: usize = 0;
                while (k < lit_len) : (k += 1) {
                    output[out_pos + 2 + k] = input[lit_start + k];
                }
                out_pos += 2 + lit_len;
                in_pos += lit_len;
            }
        }
    }

    return out_pos;
}

/// Decode RLE-encoded data. Returns number of bytes written to output.
pub fn rleDecode(input: []const u8, output: []u8) usize {
    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (in_pos < input.len) {
        if (in_pos + 1 >= input.len) break;

        const count = input[in_pos];
        in_pos += 1;

        if (count == RLE_LITERAL_MARKER) {
            // Literal run
            const lit_len = input[in_pos];
            in_pos += 1;
            if (in_pos + lit_len > input.len) break;
            if (out_pos + lit_len > output.len) break;
            var k: usize = 0;
            while (k < lit_len) : (k += 1) {
                output[out_pos + k] = input[in_pos + k];
            }
            out_pos += lit_len;
            in_pos += lit_len;
        } else {
            // Repeat run
            const byte = input[in_pos];
            in_pos += 1;
            if (out_pos + count > output.len) break;
            var k: usize = 0;
            while (k < count) : (k += 1) {
                output[out_pos + k] = byte;
            }
            out_pos += count;
        }
    }

    return out_pos;
}

// ===========================================================================
// LZ77-lite (Simplified)
// ===========================================================================
//
// Look-back window: 256 bytes
// Match format: [0xFF][offset][length] for matches (3 bytes overhead)
// Minimum match length: 3
// Maximum match length: 255
// Literal bytes are passed through directly.
// If a literal byte is 0xFF, it is escaped as [0xFF][0][0xFF].

const LZ77_MATCH_MARKER: u8 = 0xFF;
const LZ77_WINDOW_SIZE: usize = 256;
const LZ77_MIN_MATCH: usize = 3;
const LZ77_MAX_MATCH: usize = 255;

/// Encode input using LZ77-lite. Returns number of bytes written to output.
/// Output buffer should be at least input.len * 2 for safety.
pub fn lz77Encode(input: []const u8, output: []u8) usize {
    if (input.len == 0) return 0;

    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (in_pos < input.len) {
        // Search for the longest match in the look-back window
        var best_offset: usize = 0;
        var best_length: usize = 0;

        const window_start = if (in_pos > LZ77_WINDOW_SIZE) in_pos - LZ77_WINDOW_SIZE else 0;

        var search_pos = window_start;
        while (search_pos < in_pos) : (search_pos += 1) {
            var match_len: usize = 0;
            while (in_pos + match_len < input.len and match_len < LZ77_MAX_MATCH) {
                if (input[search_pos + match_len] != input[in_pos + match_len]) break;
                match_len += 1;
            }

            if (match_len >= LZ77_MIN_MATCH and match_len > best_length) {
                best_length = match_len;
                best_offset = in_pos - search_pos;
            }
        }

        if (best_length >= LZ77_MIN_MATCH) {
            // Emit match: [0xFF][offset][length]
            if (out_pos + 3 > output.len) break;
            output[out_pos] = LZ77_MATCH_MARKER;
            output[out_pos + 1] = @truncate(best_offset);
            output[out_pos + 2] = @truncate(best_length);
            out_pos += 3;
            in_pos += best_length;
        } else {
            // Emit literal byte
            if (input[in_pos] == LZ77_MATCH_MARKER) {
                // Escape 0xFF as [0xFF][0][0xFF]
                if (out_pos + 3 > output.len) break;
                output[out_pos] = LZ77_MATCH_MARKER;
                output[out_pos + 1] = 0;
                output[out_pos + 2] = LZ77_MATCH_MARKER;
                out_pos += 3;
            } else {
                if (out_pos + 1 > output.len) break;
                output[out_pos] = input[in_pos];
                out_pos += 1;
            }
            in_pos += 1;
        }
    }

    return out_pos;
}

/// Decode LZ77-lite encoded data. Returns number of bytes written to output.
pub fn lz77Decode(input: []const u8, output: []u8) usize {
    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (in_pos < input.len) {
        if (input[in_pos] == LZ77_MATCH_MARKER) {
            // Check if we have enough bytes
            if (in_pos + 2 >= input.len) break;

            const offset = input[in_pos + 1];
            const length = input[in_pos + 2];

            if (offset == 0) {
                // Escaped literal 0xFF: [0xFF][0][byte]
                if (out_pos + 1 > output.len) break;
                output[out_pos] = length; // the actual byte value
                out_pos += 1;
            } else {
                // Match reference
                if (out_pos < offset) break; // invalid reference
                if (out_pos + length > output.len) break;
                const src_start = out_pos - @as(usize, offset);
                var k: usize = 0;
                while (k < length) : (k += 1) {
                    output[out_pos + k] = output[src_start + k];
                }
                out_pos += length;
            }
            in_pos += 3;
        } else {
            if (out_pos + 1 > output.len) break;
            output[out_pos] = input[in_pos];
            out_pos += 1;
            in_pos += 1;
        }
    }

    return out_pos;
}

// ===========================================================================
// Utilities
// ===========================================================================

/// Compute compression ratio as a percentage.
/// Returns (compressed_len * 100) / original_len.
/// 100 = no compression, <100 = compressed, >100 = expanded.
pub fn ratio(original_len: usize, compressed_len: usize) u32 {
    if (original_len == 0) return 100;
    return @truncate((compressed_len * 100) / original_len);
}

/// Print compression stats.
pub fn printStats(name: []const u8, original_len: usize, compressed_len: usize) void {
    vga.write(name);
    vga.write(": ");
    printDec(original_len);
    vga.write(" -> ");
    printDec(compressed_len);
    vga.write(" bytes (");
    printDec(ratio(original_len, compressed_len));
    vga.write("%)\n");
}

// ---- Self-test ----

/// Run compression self-test.
pub fn selfTest() void {
    vga.setColor(.yellow, .black);
    vga.write("Compress self-test:\n");
    vga.setColor(.light_grey, .black);

    var passed: usize = 0;
    var failed: usize = 0;

    // Test 1: RLE roundtrip with runs
    {
        const input = "AAAAABBBCCDDDDDDDD";
        var compressed: [128]u8 = undefined;
        var decompressed: [128]u8 = undefined;
        const comp_len = rleEncode(input, &compressed);
        const dec_len = rleDecode(compressed[0..comp_len], &decompressed);
        if (dec_len == input.len and eql(decompressed[0..dec_len], input)) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: RLE roundtrip\n");
        }
    }

    // Test 2: RLE with no runs (all different)
    {
        const input = "ABCDEFGH";
        var compressed: [128]u8 = undefined;
        var decompressed: [128]u8 = undefined;
        const comp_len = rleEncode(input, &compressed);
        const dec_len = rleDecode(compressed[0..comp_len], &decompressed);
        if (dec_len == input.len and eql(decompressed[0..dec_len], input)) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: RLE no-run roundtrip\n");
        }
    }

    // Test 3: LZ77 roundtrip with repetition
    {
        const input = "abcabcabcabc";
        var compressed: [128]u8 = undefined;
        var decompressed: [128]u8 = undefined;
        const comp_len = lz77Encode(input, &compressed);
        const dec_len = lz77Decode(compressed[0..comp_len], &decompressed);
        if (dec_len == input.len and eql(decompressed[0..dec_len], input)) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: LZ77 roundtrip\n");
        }
    }

    // Test 4: LZ77 with no repetition
    {
        const input = "ABCDEFGH";
        var compressed: [128]u8 = undefined;
        var decompressed: [128]u8 = undefined;
        const comp_len = lz77Encode(input, &compressed);
        const dec_len = lz77Decode(compressed[0..comp_len], &decompressed);
        if (dec_len == input.len and eql(decompressed[0..dec_len], input)) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: LZ77 no-match roundtrip\n");
        }
    }

    // Test 5: empty input
    {
        var compressed: [16]u8 = undefined;
        const rle_len = rleEncode("", &compressed);
        const lz_len = lz77Encode("", &compressed);
        if (rle_len == 0 and lz_len == 0) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: empty input\n");
        }
    }

    // Test 6: ratio calculation
    {
        if (ratio(100, 50) == 50 and ratio(100, 100) == 100 and ratio(100, 150) == 150) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: ratio\n");
        }
    }

    // Test 7: RLE compression ratio for highly compressible data
    {
        var input: [200]u8 = undefined;
        var k: usize = 0;
        while (k < 200) : (k += 1) input[k] = 'X';

        var compressed: [512]u8 = undefined;
        const comp_len = rleEncode(&input, &compressed);
        if (comp_len < input.len) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: RLE compression\n");
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
