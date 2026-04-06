// WAV audio format parser -- RIFF/WAVE PCM data access
// Supports reading and generating PCM WAV audio data.
// RIFF header: "RIFF" + chunk_size + "WAVE"
// Format chunk: "fmt " + PCM format details
// Data chunk: "data" + raw samples

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- Constants ----

const RIFF_MAGIC: u32 = 0x46464952; // "RIFF" little-endian
const WAVE_MAGIC: u32 = 0x45564157; // "WAVE" little-endian
const FMT_MAGIC: u32 = 0x20746D66; // "fmt " little-endian
const DATA_MAGIC: u32 = 0x61746164; // "data" little-endian

const PCM_FORMAT: u16 = 1; // Uncompressed PCM

const MAX_CHANNELS: u16 = 8;
const MAX_BPS: u16 = 32; // bits per sample

// ---- WAV Info ----

pub const WavInfo = struct {
    // Format chunk data
    audio_format: u16, // 1 = PCM
    channels: u16, // 1 = mono, 2 = stereo
    sample_rate: u32, // e.g., 44100, 22050, 8000
    byte_rate: u32, // sample_rate * channels * bps/8
    block_align: u16, // channels * bps/8
    bits_per_sample: u16, // 8, 16, 24, 32

    // Data chunk info
    data_offset: usize, // offset of raw sample data in input
    data_size: u32, // size of raw sample data

    // Computed values
    total_samples: u32, // per channel
    duration_ms: u32, // duration in milliseconds

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

// ---- Public API ----

/// Parse a WAV file from raw data. Returns null on invalid WAV.
pub fn parse(data: []const u8) ?WavInfo {
    if (data.len < 44) return null; // minimum WAV header size

    var info: WavInfo = undefined;
    info.valid = false;

    // Check RIFF header
    if (readU32LE(data, 0) != RIFF_MAGIC) return null;
    // data[4..8] = chunk size (skip)
    if (readU32LE(data, 8) != WAVE_MAGIC) return null;

    // Scan for chunks
    var found_fmt = false;
    var found_data = false;
    var pos: usize = 12;

    while (pos + 8 <= data.len) {
        const chunk_id = readU32LE(data, pos);
        const chunk_size = readU32LE(data, pos + 4);
        const chunk_data_start = pos + 8;

        if (chunk_id == FMT_MAGIC) {
            if (chunk_size < 16) return null;
            if (chunk_data_start + 16 > data.len) return null;

            info.audio_format = readU16LE(data, chunk_data_start);
            info.channels = readU16LE(data, chunk_data_start + 2);
            info.sample_rate = readU32LE(data, chunk_data_start + 4);
            info.byte_rate = readU32LE(data, chunk_data_start + 8);
            info.block_align = readU16LE(data, chunk_data_start + 12);
            info.bits_per_sample = readU16LE(data, chunk_data_start + 14);

            found_fmt = true;
        } else if (chunk_id == DATA_MAGIC) {
            info.data_offset = chunk_data_start;
            info.data_size = chunk_size;
            found_data = true;
        }

        // Move to next chunk (chunks are word-aligned)
        const advance = chunk_size + (chunk_size & 1); // pad to even
        pos = chunk_data_start + advance;

        if (found_fmt and found_data) break;
    }

    if (!found_fmt or !found_data) return null;

    // Validate format
    if (info.audio_format != PCM_FORMAT) return null;
    if (info.channels == 0 or info.channels > MAX_CHANNELS) return null;
    if (info.sample_rate == 0) return null;
    if (info.bits_per_sample == 0 or info.bits_per_sample > MAX_BPS) return null;
    if (info.bits_per_sample != 8 and info.bits_per_sample != 16 and
        info.bits_per_sample != 24 and info.bits_per_sample != 32) return null;

    // Compute derived values
    const bytes_per_sample = @as(u32, info.bits_per_sample) / 8;
    if (bytes_per_sample == 0 or info.channels == 0) return null;
    const frame_size = bytes_per_sample * @as(u32, info.channels);
    if (frame_size == 0) return null;
    info.total_samples = info.data_size / frame_size;

    // Duration in ms: (total_samples * 1000) / sample_rate
    if (info.sample_rate > 0) {
        info.duration_ms = @truncate((@as(u64, info.total_samples) * 1000) / @as(u64, info.sample_rate));
    } else {
        info.duration_ms = 0;
    }

    info.valid = true;
    return info;
}

/// Get a single PCM sample as i16. For 8-bit, centers around 0.
/// Index is the frame index (not byte offset). Channel 0 is left.
pub fn getSample(info: *const WavInfo, data: []const u8, index: u32, channel: u16) i16 {
    if (!info.valid) return 0;
    if (index >= info.total_samples) return 0;
    if (channel >= info.channels) return 0;

    const bytes_per_sample = @as(usize, info.bits_per_sample) / 8;
    const frame_size = bytes_per_sample * @as(usize, info.channels);
    const offset = info.data_offset + @as(usize, index) * frame_size + @as(usize, channel) * bytes_per_sample;

    if (offset + bytes_per_sample > data.len) return 0;

    switch (info.bits_per_sample) {
        8 => {
            // 8-bit WAV is unsigned, center it
            const val: i16 = @as(i16, data[offset]) - 128;
            return val * 256; // scale to 16-bit range
        },
        16 => {
            const lo: u16 = data[offset];
            const hi: u16 = data[offset + 1];
            return @bitCast(lo | (hi << 8));
        },
        24 => {
            // Take upper 16 bits of 24-bit sample
            const mid: u16 = data[offset + 1];
            const hi: u16 = data[offset + 2];
            return @bitCast(mid | (hi << 8));
        },
        32 => {
            // Take upper 16 bits of 32-bit sample
            const mid: u16 = data[offset + 2];
            const hi: u16 = data[offset + 3];
            return @bitCast(mid | (hi << 8));
        },
        else => return 0,
    }
}

/// Get the duration in milliseconds.
pub fn getDuration(info: *const WavInfo) u32 {
    return info.duration_ms;
}

/// Create a WAV header for a sine wave tone.
/// Generates a mono 16-bit PCM sine wave at the given frequency.
/// Returns total bytes written to buf (header + samples).
pub fn createSineWave(freq: u32, duration_ms: u32, sample_rate: u32, buf: []u8) usize {
    if (freq == 0 or duration_ms == 0 or sample_rate == 0) return 0;

    const total_samples: u32 = @truncate((@as(u64, sample_rate) * @as(u64, duration_ms)) / 1000);
    const bytes_per_sample: u32 = 2; // 16-bit
    const data_size = total_samples * bytes_per_sample;
    const file_size: usize = 44 + @as(usize, data_size); // RIFF header + data

    if (buf.len < file_size) return 0;

    // Write RIFF header
    buf[0] = 'R';
    buf[1] = 'I';
    buf[2] = 'F';
    buf[3] = 'F';
    writeU32LE(buf, 4, @intCast(file_size - 8)); // chunk size
    buf[8] = 'W';
    buf[9] = 'A';
    buf[10] = 'V';
    buf[11] = 'E';

    // Write fmt chunk
    buf[12] = 'f';
    buf[13] = 'm';
    buf[14] = 't';
    buf[15] = ' ';
    writeU32LE(buf, 16, 16); // fmt chunk size
    writeU16LE(buf, 20, PCM_FORMAT);
    writeU16LE(buf, 22, 1); // mono
    writeU32LE(buf, 24, sample_rate);
    writeU32LE(buf, 28, sample_rate * bytes_per_sample); // byte rate
    writeU16LE(buf, 32, @intCast(bytes_per_sample)); // block align
    writeU16LE(buf, 34, 16); // bits per sample

    // Write data chunk header
    buf[36] = 'd';
    buf[37] = 'a';
    buf[38] = 't';
    buf[39] = 'a';
    writeU32LE(buf, 40, data_size);

    // Generate sine wave samples using integer approximation
    // Use a quarter-wave sine LUT (64 entries, scaled to i16 range)
    var i: u32 = 0;
    while (i < total_samples) : (i += 1) {
        const sample = sineApprox(i, freq, sample_rate);
        const offset: usize = 44 + @as(usize, i) * 2;
        writeU16LE(buf, offset, @bitCast(sample));
    }

    return file_size;
}

/// Integer sine approximation for audio generation.
/// Returns an i16 sample value for a given sample index, frequency, and sample rate.
fn sineApprox(sample_idx: u32, freq: u32, sample_rate: u32) i16 {
    // Phase in 0..255 (full cycle)
    const phase: u32 = @truncate((@as(u64, sample_idx) * @as(u64, freq) * 256) / @as(u64, sample_rate));
    const p: u8 = @truncate(phase & 0xFF);

    // Quarter-wave sine table (0..63 -> 0..32767)
    const quarter_sine = [64]i16{
        0,     804,   1608,  2410,  3212,  4011,  4808,  5602,
        6393,  7179,  7962,  8739,  9512,  10278, 11039, 11793,
        12539, 13279, 14010, 14732, 15446, 16151, 16846, 17530,
        18204, 18868, 19519, 20159, 20787, 21403, 22005, 22594,
        23170, 23731, 24279, 24811, 25329, 25832, 26319, 26790,
        27245, 27683, 28105, 28510, 28898, 29268, 29621, 29956,
        30273, 30571, 30852, 31113, 31356, 31580, 31785, 31971,
        32137, 32285, 32412, 32521, 32609, 32678, 32728, 32757,
    };

    // Map phase (0-255) to sine value
    var val: i16 = 0;
    if (p < 64) {
        val = quarter_sine[p];
    } else if (p < 128) {
        val = quarter_sine[127 - p];
    } else if (p < 192) {
        val = -quarter_sine[p - 128];
    } else {
        val = -quarter_sine[255 - p];
    }

    return val;
}

/// Create a square wave tone.
pub fn createSquareWave(freq: u32, duration_ms: u32, sample_rate: u32, amplitude: i16, buf: []u8) usize {
    if (freq == 0 or duration_ms == 0 or sample_rate == 0) return 0;

    const total_samples: u32 = @truncate((@as(u64, sample_rate) * @as(u64, duration_ms)) / 1000);
    const data_size = total_samples * 2;
    const file_size: usize = 44 + @as(usize, data_size);

    if (buf.len < file_size) return 0;

    // Write the same WAV header
    buf[0] = 'R';
    buf[1] = 'I';
    buf[2] = 'F';
    buf[3] = 'F';
    writeU32LE(buf, 4, @intCast(file_size - 8));
    buf[8] = 'W';
    buf[9] = 'A';
    buf[10] = 'V';
    buf[11] = 'E';
    buf[12] = 'f';
    buf[13] = 'm';
    buf[14] = 't';
    buf[15] = ' ';
    writeU32LE(buf, 16, 16);
    writeU16LE(buf, 20, PCM_FORMAT);
    writeU16LE(buf, 22, 1);
    writeU32LE(buf, 24, sample_rate);
    writeU32LE(buf, 28, sample_rate * 2);
    writeU16LE(buf, 32, 2);
    writeU16LE(buf, 34, 16);
    buf[36] = 'd';
    buf[37] = 'a';
    buf[38] = 't';
    buf[39] = 'a';
    writeU32LE(buf, 40, data_size);

    // Generate square wave
    var i: u32 = 0;
    while (i < total_samples) : (i += 1) {
        const half_period = sample_rate / (freq * 2);
        const sample: i16 = if (half_period > 0 and (i / half_period) % 2 == 0) amplitude else -amplitude;
        const offset: usize = 44 + @as(usize, i) * 2;
        writeU16LE(buf, offset, @bitCast(sample));
    }

    return file_size;
}

/// Print WAV info to VGA.
pub fn printInfo(info: *const WavInfo) void {
    if (!info.valid) {
        vga.write("WAV: invalid\n");
        return;
    }
    vga.setColor(.light_cyan, .black);
    vga.write("WAV Audio Info:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Format:     ");
    if (info.audio_format == PCM_FORMAT) {
        vga.write("PCM\n");
    } else {
        vga.write("unknown (");
        fmt.printDec(info.audio_format);
        vga.write(")\n");
    }

    vga.write("  Channels:   ");
    fmt.printDec(info.channels);
    if (info.channels == 1) {
        vga.write(" (mono)\n");
    } else if (info.channels == 2) {
        vga.write(" (stereo)\n");
    } else {
        vga.write("\n");
    }

    vga.write("  Sample rate: ");
    fmt.printDec(info.sample_rate);
    vga.write(" Hz\n");

    vga.write("  Bit depth:  ");
    fmt.printDec(info.bits_per_sample);
    vga.write(" bits\n");

    vga.write("  Byte rate:  ");
    fmt.printDec(info.byte_rate);
    vga.write(" B/s\n");

    vga.write("  Samples:    ");
    fmt.printDec(info.total_samples);
    vga.write("\n");

    vga.write("  Duration:   ");
    const secs = info.duration_ms / 1000;
    const ms_rem = info.duration_ms % 1000;
    fmt.printDec(secs);
    vga.putChar('.');
    if (ms_rem < 100) vga.putChar('0');
    if (ms_rem < 10) vga.putChar('0');
    fmt.printDec(ms_rem);
    vga.write(" s\n");

    vga.write("  Data size:  ");
    fmt.printSize(info.data_size);
    vga.write("\n");
}

/// Get the peak amplitude from the WAV data (absolute max sample value).
pub fn getPeakAmplitude(info: *const WavInfo, data: []const u8) u16 {
    if (!info.valid) return 0;

    var peak: u16 = 0;
    var i: u32 = 0;
    const step = if (info.total_samples > 1000) info.total_samples / 1000 else 1;

    while (i < info.total_samples) : (i += step) {
        var ch: u16 = 0;
        while (ch < info.channels) : (ch += 1) {
            const s = getSample(info, data, i, ch);
            const abs_val: u16 = if (s < 0) @intCast(-s) else @intCast(s);
            if (abs_val > peak) peak = abs_val;
        }
    }
    return peak;
}

/// Simple RMS level calculation (root mean square, integer approximation).
pub fn getRmsLevel(info: *const WavInfo, data: []const u8) u16 {
    if (!info.valid or info.total_samples == 0) return 0;

    var sum: u64 = 0;
    var count: u64 = 0;
    var i: u32 = 0;
    const step = if (info.total_samples > 2000) info.total_samples / 2000 else 1;

    while (i < info.total_samples) : (i += step) {
        const s = getSample(info, data, i, 0);
        const val: i32 = s;
        sum += @intCast(@as(u32, @bitCast(val * val)));
        count += 1;
    }

    if (count == 0) return 0;
    const mean = sum / count;

    // Integer square root
    var root: u64 = 0;
    var bit: u64 = @as(u64, 1) << 30;
    var val = mean;
    while (bit > val) bit >>= 2;
    while (bit != 0) {
        if (val >= root + bit) {
            val -= root + bit;
            root = (root >> 1) + bit;
        } else {
            root >>= 1;
        }
        bit >>= 2;
    }
    return @truncate(root);
}
