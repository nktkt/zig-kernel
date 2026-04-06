// PC Speaker Driver -- PIT Channel 2 tone generation
//
// Uses PIT channel 2 (port 0x42) to generate square wave tones through
// the PC speaker. Gate control via port 0x61 bits 0-1.
// Provides beep(), playNote(), playMelody() with predefined melodies.

const idt = @import("idt.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- PIT / Speaker ports ----

const PIT_CHANNEL2: u16 = 0x42;
const PIT_CMD: u16 = 0x43;
const SPEAKER_PORT: u16 = 0x61;

const PIT_FREQ: u32 = 1193182; // PIT base frequency in Hz

// ---- Note definitions ----

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
    REST = 12, // silence
};

// Base frequencies for octave 4 (in Hz * 100 for integer precision)
// C4=261.63, C#4=277.18, D4=293.66, D#4=311.13, E4=329.63,
// F4=349.23, F#4=369.99, G4=392.00, G#4=415.30, A4=440.00,
// A#4=466.16, B4=493.88
const base_freq_x100 = [12]u32{
    26163, // C
    27718, // C#
    29366, // D
    31113, // D#
    32963, // E
    34923, // F
    36999, // F#
    39200, // G
    41530, // G#
    44000, // A
    46616, // A#
    49388, // B
};

/// Compute frequency in Hz for a given note and octave (1-8).
/// Octave 4 is the reference octave.
pub fn noteFreq(note: Note, octave: u8) u32 {
    if (note == .REST) return 0;
    const idx = @intFromEnum(note);
    if (idx >= 12) return 0;

    const base = base_freq_x100[idx];
    // Shift relative to octave 4
    if (octave >= 4) {
        const shift: u5 = @intCast(octave - 4);
        return (base << shift) / 100;
    } else {
        const shift: u5 = @intCast(4 - octave);
        return (base >> shift) / 100;
    }
}

// ---- Speaker control ----

/// Enable the PC speaker and connect PIT channel 2 output.
fn speakerOn() void {
    const val = idt.inb(SPEAKER_PORT);
    if (val & 0x03 != 0x03) {
        idt.outb(SPEAKER_PORT, val | 0x03);
    }
}

/// Disable the PC speaker.
fn speakerOff() void {
    const val = idt.inb(SPEAKER_PORT);
    idt.outb(SPEAKER_PORT, val & 0xFC);
}

/// Set PIT channel 2 to generate a square wave at the given frequency.
fn setFrequency(freq_hz: u32) void {
    if (freq_hz == 0) return;
    const divisor: u32 = PIT_FREQ / freq_hz;
    if (divisor == 0 or divisor > 0xFFFF) return;

    // Channel 2, access lo/hi byte, square wave generator, binary
    idt.outb(PIT_CMD, 0xB6);
    idt.outb(PIT_CHANNEL2, @truncate(divisor & 0xFF));
    idt.outb(PIT_CHANNEL2, @truncate((divisor >> 8) & 0xFF));
}

/// Busy-wait for approximately `ms` milliseconds using PIT ticks.
fn delayMs(ms: u32) void {
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        // busy wait -- PIT runs at ~1kHz
        asm volatile ("pause");
    }
}

// ---- Public API ----

/// Produce a beep at the given frequency for the given duration.
pub fn beep(freq_hz: u32, duration_ms: u32) void {
    if (freq_hz == 0 or duration_ms == 0) return;

    setFrequency(freq_hz);
    speakerOn();
    delayMs(duration_ms);
    speakerOff();
}

/// Play a musical note at the given octave for the given duration in ms.
pub fn playNote(note: Note, octave: u8, duration_ms: u32) void {
    if (note == .REST) {
        silence();
        delayMs(duration_ms);
        return;
    }
    const freq = noteFreq(note, octave);
    if (freq == 0) return;
    beep(freq, duration_ms);
}

/// Immediately silence the speaker.
pub fn silence() void {
    speakerOff();
}

// ---- Melody support ----

pub const MelodyNote = struct {
    note: Note,
    octave: u8,
    duration_ms: u16,
    pause_ms: u16, // gap between this note and next
};

/// Play a sequence of notes.
pub fn playMelody(notes: []const MelodyNote) void {
    for (notes) |n| {
        playNote(n.note, n.octave, n.duration_ms);
        if (n.pause_ms > 0) {
            delayMs(n.pause_ms);
        }
    }
}

// ---- Predefined melodies ----

/// Startup chime: C5 E5 G5 C6 (ascending major chord)
pub const startup_chime = [_]MelodyNote{
    .{ .note = .C, .octave = 5, .duration_ms = 120, .pause_ms = 30 },
    .{ .note = .E, .octave = 5, .duration_ms = 120, .pause_ms = 30 },
    .{ .note = .G, .octave = 5, .duration_ms = 120, .pause_ms = 30 },
    .{ .note = .C, .octave = 6, .duration_ms = 250, .pause_ms = 0 },
};

/// Error beep: two low-pitched beeps
pub const error_beep = [_]MelodyNote{
    .{ .note = .A, .octave = 3, .duration_ms = 200, .pause_ms = 100 },
    .{ .note = .A, .octave = 3, .duration_ms = 200, .pause_ms = 0 },
};

/// Success tone: quick ascending two-note
pub const success_tone = [_]MelodyNote{
    .{ .note = .G, .octave = 5, .duration_ms = 100, .pause_ms = 20 },
    .{ .note = .C, .octave = 6, .duration_ms = 150, .pause_ms = 0 },
};

/// Warning tone: three descending notes
pub const warning_tone = [_]MelodyNote{
    .{ .note = .E, .octave = 5, .duration_ms = 100, .pause_ms = 50 },
    .{ .note = .C, .octave = 5, .duration_ms = 100, .pause_ms = 50 },
    .{ .note = .A, .octave = 4, .duration_ms = 200, .pause_ms = 0 },
};

/// Simple scale: C4 D4 E4 F4 G4 A4 B4 C5
pub const scale_melody = [_]MelodyNote{
    .{ .note = .C, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .D, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .E, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .F, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .G, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .A, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .B, .octave = 4, .duration_ms = 150, .pause_ms = 20 },
    .{ .note = .C, .octave = 5, .duration_ms = 300, .pause_ms = 0 },
};

/// Power-down jingle: descending C6 G5 E5 C5
pub const powerdown_jingle = [_]MelodyNote{
    .{ .note = .C, .octave = 6, .duration_ms = 120, .pause_ms = 30 },
    .{ .note = .G, .octave = 5, .duration_ms = 120, .pause_ms = 30 },
    .{ .note = .E, .octave = 5, .duration_ms = 120, .pause_ms = 30 },
    .{ .note = .C, .octave = 5, .duration_ms = 250, .pause_ms = 0 },
};

// ---- Convenience wrappers ----

pub fn playStartup() void {
    playMelody(&startup_chime);
}

pub fn playError() void {
    playMelody(&error_beep);
}

pub fn playSuccess() void {
    playMelody(&success_tone);
}

pub fn playWarning() void {
    playMelody(&warning_tone);
}

pub fn playPowerdown() void {
    playMelody(&powerdown_jingle);
}

// ---- Status / debug ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("PC Speaker Driver\n");
    vga.setColor(.light_grey, .black);
    vga.write("  PIT Channel 2 frequency generator\n");
    vga.write("  Speaker port: 0x61\n");
    vga.write("  Note range: C1-B8 (12 semitones x 8 octaves)\n");
    vga.write("  Predefined melodies: startup, error, success, warning, scale, powerdown\n");

    // Show current speaker port state
    const spk = idt.inb(SPEAKER_PORT);
    vga.write("  Speaker gate: ");
    if (spk & 0x03 == 0x03) {
        vga.setColor(.light_green, .black);
        vga.write("ON\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("OFF\n");
    }
    vga.setColor(.light_grey, .black);
}

/// Print the frequency table for a given octave.
pub fn printFreqTable(octave: u8) void {
    const note_names = [12][]const u8{ "C ", "C#", "D ", "D#", "E ", "F ", "F#", "G ", "G#", "A ", "A#", "B " };

    vga.setColor(.yellow, .black);
    vga.write("Frequency table for octave ");
    fmt.printDec(octave);
    vga.write(":\n");
    vga.setColor(.light_grey, .black);

    for (note_names, 0..) |name, i| {
        vga.write("  ");
        vga.write(name);
        vga.write(": ");
        const freq = noteFreq(@enumFromInt(i), octave);
        fmt.printDec(freq);
        vga.write(" Hz\n");
    }
}
