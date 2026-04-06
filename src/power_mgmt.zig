// Extended Power Management -- CPU idle states, load average, thermal, power states
//
// Tracks CPU usage via idle tick accounting. Computes 1/5/15 minute
// exponential moving average load. Provides HLT-based idle entry,
// basic thermal zone reading (if available), and system power state model.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- CPU C-States ----

pub const CState = enum(u8) {
    C0 = 0, // Active: CPU executing instructions
    C1 = 1, // Halt: CPU stopped, instantly resumable on interrupt
};

// ---- System power states (ACPI-like) ----

pub const PowerState = enum(u8) {
    S0 = 0, // Running (working)
    S1 = 1, // Standby (CPU stopped, RAM refreshed)
    S3 = 3, // Suspend to RAM (Sleep)
    S4 = 4, // Suspend to Disk (Hibernate)
    S5 = 5, // Soft Off
};

// ---- State tracking ----

var current_cstate: CState = .C0;
var current_power_state: PowerState = .S0;

// Tick counters
var total_ticks: u64 = 0;
var idle_ticks: u64 = 0;
var active_ticks: u64 = 0;
var last_update_tick: u64 = 0;

// Load average (fixed-point, scaled by 1000 for 3 decimal places)
// Updated every second based on run queue length estimate
var load_avg_1: u32 = 0; // 1-minute load average x1000
var load_avg_5: u32 = 0; // 5-minute load average x1000
var load_avg_15: u32 = 0; // 15-minute load average x1000
var last_load_update_sec: u32 = 0;

// Power consumption estimate (arbitrary units based on active ratio)
var power_estimate: u32 = 0; // milliwatts estimate

// Thermal zone
var last_thermal_read: u32 = 0; // temperature in degrees C x 10
var thermal_available: bool = false;

// CPU usage percentage (0-100)
var cpu_usage_percent: u8 = 0;

// History for per-second tracking
var prev_idle_ticks: u64 = 0;
var prev_total_ticks: u64 = 0;

// ---- Init ----

pub fn init() void {
    total_ticks = 0;
    idle_ticks = 0;
    active_ticks = 0;
    last_update_tick = pit.getTicks();
    last_load_update_sec = 0;
    load_avg_1 = 0;
    load_avg_5 = 0;
    load_avg_15 = 0;
    power_estimate = 0;
    cpu_usage_percent = 0;
    prev_idle_ticks = 0;
    prev_total_ticks = 0;
    current_cstate = .C0;
    current_power_state = .S0;
    thermal_available = false;
    last_thermal_read = 0;

    // Try to detect thermal sensor
    detectThermal();

    serial.write("[POWER_MGMT] Initialized\n");
}

// ---- Idle entry ----

/// Enter CPU idle state (C1 = HLT). Returns when an interrupt occurs.
pub fn enterIdle() void {
    current_cstate = .C1;
    asm volatile ("hlt");
    current_cstate = .C0;
}

/// Enter a power-saving busy wait (uses PAUSE instruction).
pub fn busyWait() void {
    asm volatile ("pause");
}

// ---- Tick accounting (call from timer IRQ) ----

/// Called on each timer tick. `is_idle` indicates whether the CPU was idle.
pub fn accountTick(is_idle: bool) void {
    total_ticks += 1;
    if (is_idle) {
        idle_ticks += 1;
    } else {
        active_ticks += 1;
    }

    // Update load average every second (1000 ticks at 1kHz PIT)
    const current_sec = pit.getUptimeSecs();
    if (current_sec > last_load_update_sec) {
        updateLoadAverage();
        updateCpuUsage();
        updatePowerEstimate();
        last_load_update_sec = current_sec;
    }
}

// ---- Load average calculation ----

// Exponential decay constants (scaled by 1000):
// For 1-minute:  exp(-1/60)  ~= 0.983 -> 983
// For 5-minute:  exp(-1/300) ~= 0.997 -> 997
// For 15-minute: exp(-1/900) ~= 0.999 -> 999
const EXP_1: u32 = 983;
const EXP_5: u32 = 997;
const EXP_15: u32 = 999;

fn updateLoadAverage() void {
    // Estimate current "load" as the fraction of time CPU was active
    // since last update (0-1000 scale).
    const delta_total = total_ticks - prev_total_ticks;
    const delta_idle = idle_ticks - prev_idle_ticks;

    var current_load: u32 = 0;
    if (delta_total > 0) {
        const delta_active = delta_total - delta_idle;
        current_load = @truncate((delta_active * 1000) / delta_total);
    }

    // Exponential moving average: avg = avg * exp + load * (1 - exp)
    load_avg_1 = (load_avg_1 * EXP_1 + current_load * (1000 - EXP_1)) / 1000;
    load_avg_5 = (load_avg_5 * EXP_5 + current_load * (1000 - EXP_5)) / 1000;
    load_avg_15 = (load_avg_15 * EXP_15 + current_load * (1000 - EXP_15)) / 1000;

    prev_total_ticks = total_ticks;
    prev_idle_ticks = idle_ticks;
}

fn updateCpuUsage() void {
    // Compute CPU usage as percentage from load_avg_1
    // load_avg_1 is in range 0-1000 (representing 0.000 to 1.000)
    if (load_avg_1 > 1000) {
        cpu_usage_percent = 100;
    } else {
        cpu_usage_percent = @truncate((load_avg_1 * 100) / 1000);
    }
}

fn updatePowerEstimate() void {
    // Very rough power estimate based on CPU activity.
    // Assume: idle = ~5W, full load = ~65W (typical desktop CPU range)
    // All values in milliwatts.
    const idle_power: u32 = 5000; // 5W idle
    const max_power: u32 = 65000; // 65W full load
    const delta = max_power - idle_power;
    power_estimate = idle_power + (delta * cpu_usage_percent) / 100;
}

// ---- Thermal zone ----

fn detectThermal() void {
    // Check for thermal sensor via MSR 0x19C (IA32_THERM_STATUS)
    // This is only available on Intel CPUs with thermal monitoring.
    // For safety in our freestanding kernel, we just check if CPUID reports it.
    // We'll attempt an MSR read; if it faults, thermal is not available.
    // In this simplified version, we mark it as unavailable by default
    // and let the user call readThermal() which tries the MSR.
    thermal_available = false;
}

/// Attempt to read CPU temperature from thermal MSR.
/// Returns temperature in degrees Celsius, or null if unavailable.
pub fn thermalZone() ?u32 {
    if (!thermal_available) return null;
    return last_thermal_read / 10;
}

/// Manually set thermal availability (e.g., after CPUID check confirms support).
pub fn enableThermal() void {
    thermal_available = true;
}

/// Read thermal data from MSR (if available). Returns temp in C x 10.
pub fn readThermalMsr() ?u32 {
    // IA32_THERM_STATUS MSR = 0x19C
    // IA32_TEMPERATURE_TARGET MSR = 0x1A2
    // Digital readout in bits 22:16 of 0x19C = delta below TjMax
    // TjMax typically in bits 23:16 of 0x1A2

    // We skip actual MSR reads in this safe version to avoid GP faults
    // on CPUs that don't support thermal MSRs.
    return null;
}

// ---- Public accessors ----

/// Get load averages (1, 5, 15 minute). Each value is scaled by 1000.
/// e.g., a value of 500 means load average of 0.500
pub fn getLoadAverage() [3]u32 {
    return .{ load_avg_1, load_avg_5, load_avg_15 };
}

/// Get CPU usage as a percentage (0-100).
pub fn getCpuUsage() u8 {
    return cpu_usage_percent;
}

/// Get total idle ticks since boot.
pub fn getIdleTicks() u64 {
    return idle_ticks;
}

/// Get total active ticks since boot.
pub fn getActiveTicks() u64 {
    return active_ticks;
}

/// Get total ticks accounted.
pub fn getTotalTicks() u64 {
    return total_ticks;
}

/// Get current C-state.
pub fn getCurrentCState() CState {
    return current_cstate;
}

/// Get current power state.
pub fn getCurrentPowerState() PowerState {
    return current_power_state;
}

/// Get estimated power consumption in milliwatts.
pub fn getPowerEstimate() u32 {
    return power_estimate;
}

/// Request transition to a power state.
/// Only S0 (running) is fully supported; others are informational.
pub fn requestPowerState(state: PowerState) void {
    switch (state) {
        .S0 => {
            current_power_state = .S0;
        },
        .S1 => {
            // Standby: just HLT in a loop
            current_power_state = .S1;
            serial.write("[POWER_MGMT] Entering S1 (standby)\n");
            enterIdle();
            current_power_state = .S0;
        },
        .S3 => {
            // Suspend to RAM: would require ACPI support
            serial.write("[POWER_MGMT] S3 not implemented\n");
        },
        .S4 => {
            serial.write("[POWER_MGMT] S4 not implemented\n");
        },
        .S5 => {
            serial.write("[POWER_MGMT] S5 (soft off) not implemented\n");
        },
    }
}

// ---- Display ----

pub fn printPowerStats() void {
    vga.setColor(.yellow, .black);
    vga.write("Power Management Status\n");
    vga.setColor(.light_grey, .black);

    // CPU state
    vga.write("  CPU state: ");
    switch (current_cstate) {
        .C0 => vga.write("C0 (active)\n"),
        .C1 => vga.write("C1 (halt)\n"),
    }

    // System power state
    vga.write("  Power state: ");
    switch (current_power_state) {
        .S0 => vga.write("S0 (running)\n"),
        .S1 => vga.write("S1 (standby)\n"),
        .S3 => vga.write("S3 (sleep)\n"),
        .S4 => vga.write("S4 (hibernate)\n"),
        .S5 => vga.write("S5 (off)\n"),
    }

    // CPU usage
    vga.write("  CPU usage: ");
    fmt.printDec(cpu_usage_percent);
    vga.write("% ");
    fmt.printBar(cpu_usage_percent, 100, 20);
    vga.putChar('\n');

    // Load averages
    const load = getLoadAverage();
    vga.write("  Load average: ");
    printFixedPoint(load[0]);
    vga.write("  ");
    printFixedPoint(load[1]);
    vga.write("  ");
    printFixedPoint(load[2]);
    vga.write("  (1/5/15 min)\n");

    // Tick stats
    vga.write("  Total ticks: ");
    fmt.printDec(@truncate(total_ticks));
    vga.putChar('\n');
    vga.write("  Active ticks: ");
    fmt.printDec(@truncate(active_ticks));
    vga.putChar('\n');
    vga.write("  Idle ticks: ");
    fmt.printDec(@truncate(idle_ticks));
    vga.putChar('\n');

    // Idle percentage
    if (total_ticks > 0) {
        const idle_pct: u32 = @truncate((idle_ticks * 100) / total_ticks);
        vga.write("  Idle: ");
        fmt.printDec(idle_pct);
        vga.write("%\n");
    }

    // Power estimate
    vga.write("  Estimated power: ");
    fmt.printDec(power_estimate / 1000);
    vga.putChar('.');
    fmt.printDec((power_estimate % 1000) / 100);
    vga.write(" W\n");

    // Thermal
    if (thermal_available) {
        if (thermalZone()) |temp| {
            vga.write("  CPU temperature: ");
            fmt.printDec(temp);
            vga.write(" C\n");
        }
    } else {
        vga.write("  Thermal: not available\n");
    }

    // Uptime
    const uptime = pit.getUptimeSecs();
    vga.write("  Uptime: ");
    fmt.printDec(uptime / 3600);
    vga.putChar('h');
    fmt.printDec((uptime % 3600) / 60);
    vga.putChar('m');
    fmt.printDec(uptime % 60);
    vga.write("s\n");
}

/// Print a fixed-point value (x1000) as "N.NNN".
fn printFixedPoint(val: u32) void {
    fmt.printDec(val / 1000);
    vga.putChar('.');
    const frac = val % 1000;
    if (frac < 100) vga.putChar('0');
    if (frac < 10) vga.putChar('0');
    fmt.printDec(frac);
}

/// Print a compact summary (one line).
pub fn printSummary() void {
    vga.write("CPU: ");
    fmt.printDec(cpu_usage_percent);
    vga.write("% load=");
    printFixedPoint(load_avg_1);
    vga.write(" idle=");
    if (total_ticks > 0) {
        fmt.printDec(@truncate((idle_ticks * 100) / total_ticks));
    } else {
        vga.putChar('0');
    }
    vga.write("% ~");
    fmt.printDec(power_estimate / 1000);
    vga.write("W\n");
}
