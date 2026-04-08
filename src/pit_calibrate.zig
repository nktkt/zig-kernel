// Hardware Timer Calibration
//
// Uses the PIT (Programmable Interval Timer) as a known reference clock
// to calibrate the APIC timer and TSC (Time Stamp Counter) frequencies.
//
// PIT frequency: 1,193,182 Hz (exact).
// Calibration method: program PIT channel 2 for a known interval,
// then count target timer ticks during that interval.
//
// Also provides HPET detection and frequency reading if available.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- PIT constants ----

const PIT_FREQ: u32 = 1193182; // PIT base frequency in Hz
const PIT_CHANNEL0: u16 = 0x40;
const PIT_CHANNEL2: u16 = 0x42;
const PIT_CMD: u16 = 0x43;
const PIT_GATE: u16 = 0x61; // NMI Status and Control Register (port 0x61)

// ---- APIC register offsets (from LAPIC base) ----

const LAPIC_TIMER_LVT: u32 = 0x320;
const LAPIC_TIMER_ICR: u32 = 0x380;
const LAPIC_TIMER_CCR: u32 = 0x390;
const LAPIC_TIMER_DCR: u32 = 0x3E0;
const LAPIC_DEFAULT_BASE: u32 = 0xFEE00000;

// APIC Timer LVT bits
const TIMER_MASKED: u32 = 0x10000;
const TIMER_ONESHOT: u32 = 0x00000; // one-shot mode (bits 18:17 = 00)

// ---- HPET ----

const HPET_DEFAULT_ADDR: u32 = 0xFED00000;
const HPET_GEN_CAP: u32 = 0x000; // General Capabilities and ID
const HPET_GEN_CONF: u32 = 0x010; // General Configuration
const HPET_MAIN_CNT: u32 = 0x0F0; // Main Counter Value

// ---- Calibration state ----

var apic_ticks_per_ms: u32 = 0;
var tsc_freq_hz: u64 = 0;
var hpet_freq_hz: u64 = 0;
var hpet_detected: bool = false;
var calibration_done: bool = false;
var calibration_samples: u32 = 0;

// ---- LAPIC MMIO helpers ----

fn lapicRead(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(LAPIC_DEFAULT_BASE + offset);
    return ptr.*;
}

fn lapicWrite(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(LAPIC_DEFAULT_BASE + offset);
    ptr.* = val;
}

// ---- HPET MMIO helpers ----

fn hpetRead(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(HPET_DEFAULT_ADDR + offset);
    return ptr.*;
}

fn hpetRead64(offset: u32) u64 {
    const lo: u64 = hpetRead(offset);
    const hi: u64 = hpetRead(offset + 4);
    return (hi << 32) | lo;
}

// ---- PIT channel 2 one-shot timer ----

/// Program PIT channel 2 for a one-shot countdown of `count` ticks.
/// The counter starts counting after the gate is enabled.
fn pitStartOneShot(count: u16) void {
    // Disable gate (port 0x61, bit 0 = gate for channel 2)
    var gate = idt.inb(PIT_GATE);
    gate &= 0xFC; // Clear bits 0 (GATE) and 1 (speaker)
    idt.outb(PIT_GATE, gate);

    // Program channel 2: mode 0 (interrupt on terminal count), binary
    // 10 11 000 0 = 0xB0 (channel 2, lo/hi byte, mode 0, binary)
    idt.outb(PIT_CMD, 0xB0);

    // Load count (lo byte first, then hi byte)
    idt.outb(PIT_CHANNEL2, @truncate(count & 0xFF));
    idt.outb(PIT_CHANNEL2, @truncate(count >> 8));

    // Enable gate to start counting
    gate = idt.inb(PIT_GATE);
    gate = (gate | 0x01) & 0xFD; // Set bit 0 (GATE), clear bit 1 (speaker)
    idt.outb(PIT_GATE, gate);
}

/// Check if PIT channel 2 has finished counting.
fn pitIsDone() bool {
    // Bit 5 of port 0x61 indicates OUT of channel 2
    return (idt.inb(PIT_GATE) & 0x20) != 0;
}

/// Wait for PIT channel 2 to finish. Returns false if it times out.
fn pitWaitDone(max_loops: u32) bool {
    var loops: u32 = 0;
    while (loops < max_loops) : (loops += 1) {
        if (pitIsDone()) return true;
        asm volatile ("pause");
    }
    return false;
}

// ---- TSC helpers ----

/// Read the Time Stamp Counter.
fn readTSC() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

// ---- Calibration functions ----

/// Calibrate the APIC timer using PIT channel 2.
/// Returns the number of APIC timer ticks per millisecond.
/// Performs multiple samples and averages for accuracy.
pub fn calibrateApicTimer() u32 {
    const NUM_SAMPLES = 3;
    const CALIB_MS = 10; // Calibrate over 10ms
    const pit_count: u16 = @truncate((PIT_FREQ * CALIB_MS) / 1000);

    var total: u64 = 0;
    var valid_samples: u32 = 0;

    var sample: u32 = 0;
    while (sample < NUM_SAMPLES) : (sample += 1) {
        // Setup APIC timer: divide by 16, masked one-shot
        lapicWrite(LAPIC_TIMER_DCR, 0x03); // Divide by 16
        lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED | TIMER_ONESHOT);
        lapicWrite(LAPIC_TIMER_ICR, 0xFFFFFFFF); // Start counting down from max

        // Start PIT one-shot for calibration period
        pitStartOneShot(pit_count);

        // Wait for PIT to finish
        if (!pitWaitDone(10000000)) continue;

        // Read how many APIC ticks elapsed
        const elapsed = 0xFFFFFFFF - lapicRead(LAPIC_TIMER_CCR);

        // Stop APIC timer
        lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED);

        if (elapsed > 0) {
            total += elapsed;
            valid_samples += 1;
        }
    }

    if (valid_samples == 0) {
        apic_ticks_per_ms = 0;
        return 0;
    }

    // Calculate average ticks per millisecond
    // total / valid_samples = ticks per CALIB_MS ms
    // ticks_per_ms = (total / valid_samples) / CALIB_MS
    const avg = total / valid_samples;
    apic_ticks_per_ms = @truncate(avg / CALIB_MS);
    calibration_samples = valid_samples;
    calibration_done = true;

    serial.write("[CAL] APIC timer: ");
    serialDec32(apic_ticks_per_ms);
    serial.write(" ticks/ms (");
    serialDec32(valid_samples);
    serial.write(" samples)\n");

    return apic_ticks_per_ms;
}

/// Calibrate the TSC (Time Stamp Counter) frequency using PIT.
/// Returns the TSC frequency in Hz.
pub fn calibrateTSC() u64 {
    const NUM_SAMPLES = 3;
    const CALIB_MS = 10;
    const pit_count: u16 = @truncate((PIT_FREQ * CALIB_MS) / 1000);

    var total: u64 = 0;
    var valid_samples: u32 = 0;

    var sample: u32 = 0;
    while (sample < NUM_SAMPLES) : (sample += 1) {
        // Read TSC before
        const tsc_start = readTSC();

        // Start PIT one-shot
        pitStartOneShot(pit_count);

        // Wait for PIT
        if (!pitWaitDone(10000000)) continue;

        // Read TSC after
        const tsc_end = readTSC();
        const elapsed = tsc_end - tsc_start;

        if (elapsed > 0) {
            total += elapsed;
            valid_samples += 1;
        }
    }

    if (valid_samples == 0) {
        tsc_freq_hz = 0;
        return 0;
    }

    // average ticks per CALIB_MS ms
    const avg_ticks = total / valid_samples;
    // Convert to Hz: ticks_per_ms * 1000
    tsc_freq_hz = (avg_ticks * 1000) / CALIB_MS;
    calibration_done = true;

    serial.write("[CAL] TSC freq: ");
    serialDec64(tsc_freq_hz / 1000000);
    serial.write(" MHz (");
    serialDec32(valid_samples);
    serial.write(" samples)\n");

    return tsc_freq_hz;
}

/// Detect HPET and read its frequency.
pub fn detectHPET() bool {
    // Try to read HPET General Capabilities register
    // This may fault if HPET is not mapped; in that case we just return false.
    const cap = hpetRead(HPET_GEN_CAP);

    // Check for valid revision (bits 7:0)
    const revision = cap & 0xFF;
    if (revision == 0 or revision == 0xFF) {
        hpet_detected = false;
        return false;
    }

    // Counter CLK period is in the upper 32 bits of GCAP_ID (in femtoseconds)
    const period_fs: u64 = hpetRead(HPET_GEN_CAP + 4);
    if (period_fs == 0 or period_fs > 0x05F5E100) {
        // Invalid or unreasonable period (> 100ms)
        hpet_detected = false;
        return false;
    }

    // frequency = 10^15 / period_fs
    hpet_freq_hz = 1_000_000_000_000_000 / period_fs;
    hpet_detected = true;

    serial.write("[CAL] HPET freq: ");
    serialDec64(hpet_freq_hz / 1000000);
    serial.write(" MHz\n");

    return true;
}

/// Get HPET frequency in Hz. Returns 0 if not detected.
pub fn getHPETFrequency() u64 {
    return hpet_freq_hz;
}

/// Check if HPET was detected.
pub fn isHPETDetected() bool {
    return hpet_detected;
}

// ---- Query functions ----

/// Get the calibrated APIC timer ticks per millisecond.
pub fn getApicTicksPerMs() u32 {
    return apic_ticks_per_ms;
}

/// Get the calibrated TSC frequency in Hz.
pub fn getTSCFrequency() u64 {
    return tsc_freq_hz;
}

/// Check if calibration has been performed.
pub fn isCalibrated() bool {
    return calibration_done;
}

/// Estimate the TSC ticks for a given number of microseconds.
pub fn tscTicksForUs(us: u32) u64 {
    if (tsc_freq_hz == 0) return 0;
    return (tsc_freq_hz * us) / 1_000_000;
}

/// Estimate the APIC ticks for a given number of microseconds.
pub fn apicTicksForUs(us: u32) u32 {
    if (apic_ticks_per_ms == 0) return 0;
    return (apic_ticks_per_ms * us) / 1000;
}

/// Calculate calibration accuracy estimate (as a percentage deviation).
/// Runs an additional sample and compares to the average.
pub fn estimateAccuracy() u32 {
    if (apic_ticks_per_ms == 0) return 0;

    const CALIB_MS = 10;
    const pit_count: u16 = @truncate((PIT_FREQ * CALIB_MS) / 1000);

    // Take one more sample
    lapicWrite(LAPIC_TIMER_DCR, 0x03);
    lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED | TIMER_ONESHOT);
    lapicWrite(LAPIC_TIMER_ICR, 0xFFFFFFFF);

    pitStartOneShot(pit_count);
    if (!pitWaitDone(10000000)) return 0;

    const elapsed = 0xFFFFFFFF - lapicRead(LAPIC_TIMER_CCR);
    lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED);

    const measured: u32 = @truncate(elapsed / CALIB_MS);

    // Calculate deviation as percentage * 100
    if (measured > apic_ticks_per_ms) {
        return ((measured - apic_ticks_per_ms) * 10000) / apic_ticks_per_ms;
    } else {
        return ((apic_ticks_per_ms - measured) * 10000) / apic_ticks_per_ms;
    }
}

// ---- Display ----

/// Print calibration results.
pub fn printCalibration() void {
    vga.setColor(.yellow, .black);
    vga.write("Timer Calibration:\n");
    vga.setColor(.light_grey, .black);

    if (!calibration_done) {
        vga.write("  Not yet calibrated\n");
        return;
    }

    // APIC timer
    vga.write("  APIC Timer:\n");
    vga.write("    Ticks/ms:   ");
    printDec32(apic_ticks_per_ms);
    vga.putChar('\n');
    if (apic_ticks_per_ms > 0) {
        vga.write("    Frequency:  ");
        printDec32(apic_ticks_per_ms / 1000);
        vga.write(" MHz (approx, div16)\n");

        vga.write("    Samples:    ");
        printDec32(calibration_samples);
        vga.putChar('\n');
    }

    // TSC
    vga.write("  TSC:\n");
    if (tsc_freq_hz > 0) {
        vga.write("    Frequency:  ");
        printDec64(tsc_freq_hz / 1000000);
        vga.write(" MHz\n");

        vga.write("    Ticks/us:   ");
        printDec64(tsc_freq_hz / 1000000);
        vga.putChar('\n');
    } else {
        vga.write("    Not calibrated\n");
    }

    // HPET
    vga.write("  HPET:\n");
    if (hpet_detected) {
        vga.write("    Frequency:  ");
        printDec64(hpet_freq_hz / 1000000);
        vga.write(" MHz\n");
    } else {
        vga.write("    Not detected\n");
    }
}

// ---- Internal helpers ----

fn printDec32(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
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

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn serialDec32(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialDec64(n: u64) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
