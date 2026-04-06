// Extended PIT Functionality -- Full PIT channel control, precise delays, TSC calibration
//
// PIT channels:
//   Channel 0: System timer (1kHz, managed by pit.zig)
//   Channel 1: DRAM refresh (legacy, usually not used)
//   Channel 2: PC speaker tone generation / precise delay source
//
// This module provides:
//   - Direct channel counter read/write for channels 0-2
//   - Microsecond-precision busy wait using PIT channel 2
//   - TSC frequency calibration using PIT
//   - One-shot delay capability
//   - Frequency measurement utilities

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- PIT ports ----

const PIT_CH0: u16 = 0x40;
const PIT_CH1: u16 = 0x41;
const PIT_CH2: u16 = 0x42;
const PIT_CMD: u16 = 0x43;
const SPEAKER_PORT: u16 = 0x61;

const PIT_FREQ: u32 = 1193182; // PIT oscillator frequency (Hz)

// ---- Channel port lookup ----

fn channelPort(ch: u2) u16 {
    return switch (ch) {
        0 => PIT_CH0,
        1 => PIT_CH1,
        2 => PIT_CH2,
        3 => PIT_CH2, // channel 3 doesn't exist, map to 2
    };
}

// ---- Read current counter ----

/// Latch and read the current 16-bit counter for a PIT channel.
/// The latch command freezes the counter value so it can be read atomically.
pub fn readCounter(channel: u2) u16 {
    // Send latch command: channel bits (6-7), latch (00 in bits 4-5)
    const cmd: u8 = @as(u8, channel) << 6;
    idt.outb(PIT_CMD, cmd);

    // Read low byte then high byte
    const lo: u16 = idt.inb(channelPort(channel));
    const hi: u16 = idt.inb(channelPort(channel));
    return (hi << 8) | lo;
}

/// Set a channel to a specific count and mode.
/// mode: 0=interrupt on terminal count, 2=rate generator, 3=square wave
pub fn setChannel(channel: u2, count: u16, mode: u3) void {
    // Command: channel(6-7), access lo/hi(4-5=11), mode(1-3), binary(0=0)
    const cmd: u8 = (@as(u8, channel) << 6) | 0x30 | (@as(u8, mode) << 1);
    idt.outb(PIT_CMD, cmd);
    idt.outb(channelPort(channel), @truncate(count & 0xFF));
    idt.outb(channelPort(channel), @truncate(count >> 8));
}

// ---- Channel 2 gate control ----

/// Enable PIT channel 2 gate (bit 0 of port 0x61).
/// This starts channel 2 counting. Does NOT connect to speaker (bit 1).
fn enableCh2Gate() void {
    const val = idt.inb(SPEAKER_PORT);
    idt.outb(SPEAKER_PORT, (val | 0x01) & 0xFD); // set gate, clear speaker
}

/// Disable PIT channel 2 gate.
fn disableCh2Gate() void {
    const val = idt.inb(SPEAKER_PORT);
    idt.outb(SPEAKER_PORT, val & 0xFC); // clear gate and speaker
}

/// Read channel 2 output status (bit 5 of port 0x61).
fn readCh2Output() bool {
    return (idt.inb(SPEAKER_PORT) & 0x20) != 0;
}

// ---- Microsecond delay ----

/// Busy-wait for the specified number of microseconds using PIT channel 2.
/// Precision: approximately +/- 1 microsecond for short delays.
/// For delays > 50ms, consider using pit.getTicks() instead.
///
/// Method: Programs channel 2 in one-shot mode (mode 0). When the counter
/// reaches 0, the output goes high (bit 5 of port 0x61).
pub fn usleep(microseconds: u32) void {
    if (microseconds == 0) return;

    // PIT_FREQ / 1_000_000 = ~1.193 ticks per microsecond
    // For precision, we compute: count = microseconds * PIT_FREQ / 1_000_000
    // But we must handle overflow for large values.

    // Max single PIT count is 65535, which is ~54925 us (~55ms).
    // For longer delays, loop.

    var remaining = microseconds;

    while (remaining > 0) {
        const chunk = if (remaining > 50000) @as(u32, 50000) else remaining;
        remaining -= chunk;

        // Compute count: chunk * 1193182 / 1000000
        // To avoid overflow: (chunk * 1193) + (chunk * 182) / 1000
        const count_raw = (chunk * PIT_FREQ + 500000) / 1000000;
        const count: u16 = if (count_raw > 0xFFFF) 0xFFFF else if (count_raw == 0) 1 else @truncate(count_raw);

        // Program channel 2 in mode 0 (interrupt on terminal count)
        // Command: channel 2 (10), access lo/hi (11), mode 0 (000), binary (0)
        idt.outb(PIT_CMD, 0xB0);

        // Disable gate, then set count, then enable gate to start
        disableCh2Gate();

        idt.outb(PIT_CH2, @truncate(count & 0xFF));
        idt.outb(PIT_CH2, @truncate(count >> 8));

        // Enable gate to start countdown
        enableCh2Gate();

        // Wait for output to go high (terminal count reached)
        while (!readCh2Output()) {
            asm volatile ("pause");
        }
    }

    disableCh2Gate();
}

/// Sleep for the given number of milliseconds using PIT channel 2.
pub fn msleep(milliseconds: u32) void {
    usleep(milliseconds * 1000);
}

// ---- TSC calibration ----

var tsc_freq_khz: u64 = 0;
var tsc_calibrated: bool = false;

/// Read the Time Stamp Counter.
fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

/// Calibrate TSC frequency using PIT channel 2.
/// Measures TSC ticks over a 100ms PIT-timed interval.
/// Returns TSC frequency in kHz (0 if calibration failed).
pub fn calibrateTSC() u64 {
    // Set up PIT channel 2 for a one-shot 100ms delay
    // 100ms = 119318 PIT ticks (too large for 16-bit)
    // Instead, use 10ms x 10 iterations for better precision

    const iterations: u32 = 10;
    const delay_us: u32 = 10000; // 10ms per iteration

    const tsc_start = rdtsc();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        usleep(delay_us);
    }

    const tsc_end = rdtsc();
    const tsc_elapsed = tsc_end - tsc_start;
    const total_ms = iterations * 10; // 100ms total

    // freq_khz = tsc_elapsed / total_ms
    tsc_freq_khz = tsc_elapsed / total_ms;
    tsc_calibrated = true;

    serial.write("[PIT_EXT] TSC freq: ");
    serial.writeHex(@truncate(tsc_freq_khz));
    serial.write(" kHz\n");

    return tsc_freq_khz;
}

/// Get the calibrated TSC frequency in kHz. Returns 0 if not calibrated.
pub fn getTscFreqKhz() u64 {
    return tsc_freq_khz;
}

/// Get the calibrated TSC frequency in MHz. Returns 0 if not calibrated.
pub fn getTscFreqMhz() u32 {
    return @truncate(tsc_freq_khz / 1000);
}

/// Check if TSC has been calibrated.
pub fn isTscCalibrated() bool {
    return tsc_calibrated;
}

// ---- Frequency measurement ----

/// Measure the frequency of an external signal using PIT channel 2 as a gate.
/// This is a theoretical utility; in practice, it counts how many PIT ticks
/// elapse during a number of TSC cycles.
///
/// Returns the estimated frequency in Hz based on TSC-to-PIT ratio.
pub fn measureFrequency(sample_ms: u32) u64 {
    if (!tsc_calibrated or tsc_freq_khz == 0) return 0;
    if (sample_ms == 0) return 0;

    const start = rdtsc();
    usleep(sample_ms * 1000);
    const end = rdtsc();

    const elapsed_tsc = end - start;
    // expected_tsc = tsc_freq_khz * sample_ms
    const expected = tsc_freq_khz * sample_ms;

    if (expected == 0) return 0;

    // Ratio gives a measure of how accurate the timing was
    // Return the effective rate: elapsed / sample_ms * 1000
    return (elapsed_tsc * 1000) / sample_ms;
}

/// Get the PIT base frequency.
pub fn getPitFreq() u32 {
    return PIT_FREQ;
}

/// Read the PIT status (readback command) for a channel.
/// Returns the status byte: output state, null count, access mode, mode, BCD.
pub fn readStatus(channel: u2) u8 {
    // Readback command: 11 | !count | !status | channel_mask | 0
    // We want status only (not count), so set "don't latch count" bit
    const ch_mask: u8 = @as(u8, 1) << (channel + 1);
    const cmd: u8 = 0xC0 | 0x20 | ch_mask; // 0xE0 base, status only
    idt.outb(PIT_CMD, cmd);
    return idt.inb(channelPort(channel));
}

// ---- Info display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("PIT Extended Information\n");
    vga.setColor(.light_grey, .black);

    vga.write("  PIT base frequency: ");
    fmt.printDec(PIT_FREQ);
    vga.write(" Hz (1.193182 MHz)\n");

    // Read current counters
    vga.write("  Channel 0 counter: ");
    fmt.printDec(readCounter(0));
    vga.putChar('\n');

    vga.write("  Channel 2 counter: ");
    fmt.printDec(readCounter(2));
    vga.putChar('\n');

    // Speaker port status
    const spk = idt.inb(SPEAKER_PORT);
    vga.write("  Speaker port (0x61): 0x");
    fmt.printHex8(spk);
    vga.write("  [gate=");
    vga.putChar(if (spk & 0x01 != 0) '1' else '0');
    vga.write(" spk=");
    vga.putChar(if (spk & 0x02 != 0) '1' else '0');
    vga.write(" out=");
    vga.putChar(if (spk & 0x20 != 0) '1' else '0');
    vga.write("]\n");

    // TSC calibration
    if (tsc_calibrated) {
        vga.write("  TSC frequency: ");
        fmt.printDec(@truncate(tsc_freq_khz));
        vga.write(" kHz (");
        fmt.printDec(getTscFreqMhz());
        vga.write(" MHz)\n");
    } else {
        vga.write("  TSC: not calibrated\n");
    }

    // System uptime
    vga.write("  System ticks: ");
    fmt.printDec(@truncate(pit.getTicks()));
    vga.write(" (");
    fmt.printDec(pit.getUptimeSecs());
    vga.write(" seconds)\n");
}
