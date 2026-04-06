// PIT チャネル 2 + PC スピーカー統合ドライバ — ビープ音/メロディ再生
//
// PIT チャネル 2 で周波数を生成し、ポート 0x61 でスピーカーゲートを制御.
// 音階テーブル (C4=262Hz 〜 B7), ノート/オクターブ/デュレーション指定,
// ソングデータ形式 (ノート, 持続時間) の配列.
// 内蔵曲: スケール, 起動音, アラーム, マリオテーマ (冒頭).

const idt = @import("idt.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Ports ----

const PIT_CHANNEL2: u16 = 0x42; // PIT Channel 2 data port
const PIT_CMD: u16 = 0x43; // PIT command register
const SPEAKER_PORT: u16 = 0x61; // PC Speaker / NMI status and control

const PIT_FREQ: u32 = 1193182; // PIT base frequency (Hz)

// ---- Musical notes ----

pub const Note = enum(u8) {
    C = 0,
    Cs = 1, // C#
    D = 2,
    Ds = 3, // D#
    E = 4,
    F = 5,
    Fs = 6, // F#
    G = 7,
    Gs = 8, // G#
    A = 9,
    As = 10, // A#
    B = 11,
    REST = 255,
};

// ---- Note frequency table ----
// Base frequencies for octave 4 (middle C = C4 = 262 Hz)
// Stored as Hz * 100 for precision, then divided by 100

const base_freq_x100 = [12]u32{
    26163, // C4  = 261.63 Hz
    27718, // C#4 = 277.18 Hz
    29366, // D4  = 293.66 Hz
    31113, // D#4 = 311.13 Hz
    32963, // E4  = 329.63 Hz
    34923, // F4  = 349.23 Hz
    36999, // F#4 = 369.99 Hz
    39200, // G4  = 392.00 Hz
    41530, // G#4 = 415.30 Hz
    44000, // A4  = 440.00 Hz
    46616, // A#4 = 466.16 Hz
    49388, // B4  = 493.88 Hz
};

// ---- Song data format ----

pub const SongNote = struct {
    note: Note,
    octave: u8, // 0-8 (4 = middle octave)
    duration_ms: u16, // Duration in milliseconds
};

// ---- State ----

var speaker_enabled: bool = false;
var current_freq: u32 = 0;

// ---- Core functions ----

/// Set PIT Channel 2 to generate a specific frequency
pub fn setFrequency(hz: u32) void {
    if (hz == 0) {
        disableSpeaker();
        current_freq = 0;
        return;
    }

    // Calculate divisor
    const divisor: u32 = PIT_FREQ / hz;
    if (divisor == 0 or divisor > 65535) return;

    // Program PIT Channel 2: mode 3 (square wave), lo/hi byte
    idt.outb(PIT_CMD, 0xB6); // Channel 2, lo/hi, mode 3, binary

    // Set divisor
    idt.outb(PIT_CHANNEL2, @truncate(divisor & 0xFF));
    idt.outb(PIT_CHANNEL2, @truncate((divisor >> 8) & 0xFF));

    current_freq = hz;
}

/// Enable the PC speaker (connect PIT Channel 2 to speaker)
pub fn enableSpeaker() void {
    const val = idt.inb(SPEAKER_PORT);
    if (val & 0x03 != 0x03) {
        idt.outb(SPEAKER_PORT, val | 0x03); // Set bits 0 and 1
    }
    speaker_enabled = true;
}

/// Disable the PC speaker
pub fn disableSpeaker() void {
    const val = idt.inb(SPEAKER_PORT);
    idt.outb(SPEAKER_PORT, val & 0xFC); // Clear bits 0 and 1
    speaker_enabled = false;
}

/// Check if speaker is currently enabled
pub fn isSpeakerEnabled() bool {
    return speaker_enabled;
}

/// Get the current frequency being generated
pub fn getCurrentFreq() u32 {
    return current_freq;
}

// ---- Note/Frequency conversion ----

/// Convert a note and octave to frequency in Hz
pub fn noteToFreq(note: Note, octave: u8) u32 {
    if (note == .REST) return 0;

    const note_idx: usize = @intFromEnum(note);
    if (note_idx >= 12) return 0;

    // Get base frequency (octave 4)
    var freq = base_freq_x100[note_idx];

    // Adjust for octave
    if (octave < 4) {
        const shift: u5 = @truncate(4 - octave);
        freq >>= shift;
    } else if (octave > 4) {
        const shift: u5 = @truncate(octave - 4);
        freq <<= shift;
    }

    // Convert from x100 to Hz
    return freq / 100;
}

// ---- Playback functions ----

/// Delay using PIT ticks (approximate ms)
fn delayMs(ms: u32) void {
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        asm volatile ("hlt"); // Wait for next interrupt
    }
}

/// Play a tone at the given frequency for a specified duration
pub fn playTone(freq: u32, duration_ms: u32) void {
    if (freq == 0) {
        // Rest — just wait
        disableSpeaker();
        delayMs(duration_ms);
        return;
    }

    setFrequency(freq);
    enableSpeaker();
    delayMs(duration_ms);
    disableSpeaker();
}

/// Play a musical note at a given octave for a specified duration
pub fn playNote(note: Note, octave: u8, duration_ms: u32) void {
    const freq = noteToFreq(note, octave);
    playTone(freq, duration_ms);
}

/// Play a song (array of SongNote)
pub fn playSong(song: []const SongNote) void {
    for (song) |sn| {
        playNote(sn.note, sn.octave, sn.duration_ms);
        // Small gap between notes for articulation
        delayMs(20);
    }
}

// ---- Built-in songs ----

/// C major scale (C4 to C5)
pub const song_scale = [_]SongNote{
    .{ .note = .C, .octave = 4, .duration_ms = 200 },
    .{ .note = .D, .octave = 4, .duration_ms = 200 },
    .{ .note = .E, .octave = 4, .duration_ms = 200 },
    .{ .note = .F, .octave = 4, .duration_ms = 200 },
    .{ .note = .G, .octave = 4, .duration_ms = 200 },
    .{ .note = .A, .octave = 4, .duration_ms = 200 },
    .{ .note = .B, .octave = 4, .duration_ms = 200 },
    .{ .note = .C, .octave = 5, .duration_ms = 400 },
};

/// Startup jingle
pub const song_startup = [_]SongNote{
    .{ .note = .C, .octave = 5, .duration_ms = 100 },
    .{ .note = .E, .octave = 5, .duration_ms = 100 },
    .{ .note = .G, .octave = 5, .duration_ms = 100 },
    .{ .note = .C, .octave = 6, .duration_ms = 300 },
};

/// Alarm sound (alternating tones)
pub const song_alarm = [_]SongNote{
    .{ .note = .A, .octave = 5, .duration_ms = 150 },
    .{ .note = .REST, .octave = 0, .duration_ms = 50 },
    .{ .note = .E, .octave = 5, .duration_ms = 150 },
    .{ .note = .REST, .octave = 0, .duration_ms = 50 },
    .{ .note = .A, .octave = 5, .duration_ms = 150 },
    .{ .note = .REST, .octave = 0, .duration_ms = 50 },
    .{ .note = .E, .octave = 5, .duration_ms = 150 },
    .{ .note = .REST, .octave = 0, .duration_ms = 50 },
    .{ .note = .A, .octave = 5, .duration_ms = 150 },
    .{ .note = .REST, .octave = 0, .duration_ms = 50 },
    .{ .note = .E, .octave = 5, .duration_ms = 150 },
};

/// Mario theme (first few notes of Ground Theme)
pub const song_mario = [_]SongNote{
    .{ .note = .E, .octave = 5, .duration_ms = 120 },
    .{ .note = .E, .octave = 5, .duration_ms = 120 },
    .{ .note = .REST, .octave = 0, .duration_ms = 120 },
    .{ .note = .E, .octave = 5, .duration_ms = 120 },
    .{ .note = .REST, .octave = 0, .duration_ms = 120 },
    .{ .note = .C, .octave = 5, .duration_ms = 120 },
    .{ .note = .E, .octave = 5, .duration_ms = 240 },
    .{ .note = .G, .octave = 5, .duration_ms = 240 },
    .{ .note = .REST, .octave = 0, .duration_ms = 240 },
    .{ .note = .G, .octave = 4, .duration_ms = 240 },
    .{ .note = .REST, .octave = 0, .duration_ms = 240 },
    .{ .note = .C, .octave = 5, .duration_ms = 240 },
    .{ .note = .REST, .octave = 0, .duration_ms = 120 },
    .{ .note = .G, .octave = 4, .duration_ms = 240 },
    .{ .note = .REST, .octave = 0, .duration_ms = 120 },
    .{ .note = .E, .octave = 4, .duration_ms = 240 },
    .{ .note = .REST, .octave = 0, .duration_ms = 120 },
    .{ .note = .A, .octave = 4, .duration_ms = 180 },
    .{ .note = .B, .octave = 4, .duration_ms = 180 },
    .{ .note = .As, .octave = 4, .duration_ms = 120 },
    .{ .note = .A, .octave = 4, .duration_ms = 180 },
    .{ .note = .G, .octave = 4, .duration_ms = 160 },
    .{ .note = .E, .octave = 5, .duration_ms = 160 },
    .{ .note = .G, .octave = 5, .duration_ms = 160 },
    .{ .note = .A, .octave = 5, .duration_ms = 240 },
    .{ .note = .F, .octave = 5, .duration_ms = 120 },
    .{ .note = .G, .octave = 5, .duration_ms = 120 },
};

/// Error/failure beep
pub const song_error = [_]SongNote{
    .{ .note = .A, .octave = 3, .duration_ms = 500 },
};

/// Success beep
pub const song_success = [_]SongNote{
    .{ .note = .C, .octave = 6, .duration_ms = 80 },
    .{ .note = .E, .octave = 6, .duration_ms = 80 },
    .{ .note = .G, .octave = 6, .duration_ms = 150 },
};

// ---- Display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("PC Speaker / PIT Channel 2:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Speaker: ");
    if (speaker_enabled) {
        vga.setColor(.light_green, .black);
        vga.write("ON");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("OFF");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    vga.write("  Current Freq: ");
    if (current_freq > 0) {
        printDec(current_freq);
        vga.write(" Hz");
    } else {
        vga.write("(none)");
    }
    vga.putChar('\n');

    vga.write("  Port 0x61: 0x");
    printHex8(idt.inb(SPEAKER_PORT));
    vga.putChar('\n');

    // Note frequency table
    vga.write("  Note table (octave 4):\n");
    const note_names = [12][]const u8{ "C ", "C#", "D ", "D#", "E ", "F ", "F#", "G ", "G#", "A ", "A#", "B " };
    vga.write("    ");
    for (note_names, 0..) |name, i| {
        vga.write(name);
        vga.write("=");
        printDec(base_freq_x100[i] / 100);
        if (i < 11) vga.write(" ");
    }
    vga.putChar('\n');

    // Built-in songs
    vga.write("  Songs: scale(");
    printDec(song_scale.len);
    vga.write(") startup(");
    printDec(song_startup.len);
    vga.write(") alarm(");
    printDec(song_alarm.len);
    vga.write(") mario(");
    printDec(song_mario.len);
    vga.write(")\n");
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
