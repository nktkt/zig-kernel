// Power management -- shutdown, reboot, halt, uptime
//
// Provides multiple reboot/shutdown strategies:
//   - ACPI-based shutdown (via acpi.zig)
//   - Keyboard controller reset (port 0x64, command 0xFE)
//   - Triple fault reboot (load invalid IDT then INT 0)
//   - CPU halt loop

const idt = @import("idt.zig");
const acpi = @import("acpi.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Power states ----

pub const PowerState = enum(u8) {
    running = 0,
    shutting_down = 1,
    rebooting = 2,
    halted = 3,
};

var current_state: PowerState = .running;
var boot_tick: u64 = 0;

// Scheduled shutdown
var shutdown_scheduled: bool = false;
var shutdown_target_tick: u64 = 0;

/// Initialize power module -- record boot tick.
pub fn init() void {
    boot_tick = pit.getTicks();
    current_state = .running;
    shutdown_scheduled = false;
}

// ---- Shutdown ----

/// Attempt ACPI-based shutdown, with QEMU/Bochs fallbacks.
pub fn shutdown() void {
    current_state = .shutting_down;
    serial.write("[POWER] Shutdown initiated\n");

    vga.setColor(.yellow, .black);
    vga.write("\nSystem is shutting down...\n");

    // Try ACPI shutdown
    acpi.shutdown();

    // If we're still here, ACPI shutdown didn't work.
    // QEMU-specific fallback (0x604 port).
    idt.outw(0x604, 0x2000);
    // Bochs fallback
    idt.outw(0xB004, 0x2000);

    // Last resort: halt
    serial.write("[POWER] Shutdown failed, halting\n");
    halt();
}

// ---- Reboot ----

/// Reboot using keyboard controller reset (most reliable on PC hardware).
pub fn reboot() void {
    current_state = .rebooting;
    serial.write("[POWER] Reboot via keyboard controller\n");

    vga.setColor(.yellow, .black);
    vga.write("\nSystem is rebooting...\n");

    // Disable interrupts before resetting
    asm volatile ("cli");

    // Pulse the keyboard controller reset line
    // Wait for input buffer to be clear
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (idt.inb(0x64) & 0x02 == 0) break;
    }
    idt.outb(0x64, 0xFE); // Reset command

    // If that didn't work, try triple fault
    tripleFault();
}

/// Reboot via triple fault: load an invalid IDT and trigger an interrupt.
pub fn tripleFault() void {
    serial.write("[POWER] Triple fault reboot\n");

    asm volatile ("cli");

    // Load a zero-length IDT -- any interrupt will cause a triple fault
    const null_idt = packed struct { limit: u16, base: u32 }{ .limit = 0, .base = 0 };
    asm volatile ("lidt (%[idt])"
        :
        : [idt] "r" (&null_idt),
    );

    // Trigger interrupt -> double fault -> triple fault -> reset
    asm volatile ("int $0x03");

    // Should never reach here
    unreachable;
}

// ---- Halt ----

/// Halt the CPU in a loop. Does not return.
pub fn halt() void {
    current_state = .halted;
    serial.write("[POWER] System halted\n");

    vga.setColor(.light_red, .black);
    vga.write("System halted. Please power off manually.\n");

    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

// ---- Scheduled shutdown ----

/// Schedule a shutdown after delay_ms milliseconds.
pub fn scheduleShutdown(delay_ms: u32) void {
    shutdown_scheduled = true;
    shutdown_target_tick = pit.getTicks() + @as(u64, delay_ms);
    serial.write("[POWER] Shutdown scheduled in ");
    serialWriteDec(delay_ms);
    serial.write("ms\n");

    vga.setColor(.yellow, .black);
    vga.write("Shutdown scheduled in ");
    printDec(@as(usize, delay_ms / 1000));
    vga.write(" seconds\n");
}

/// Cancel a scheduled shutdown.
pub fn cancelShutdown() void {
    if (shutdown_scheduled) {
        shutdown_scheduled = false;
        serial.write("[POWER] Scheduled shutdown cancelled\n");
        vga.setColor(.light_green, .black);
        vga.write("Scheduled shutdown cancelled\n");
    }
}

/// Check if a scheduled shutdown is due. Call from timer tick handler.
pub fn checkScheduled() void {
    if (shutdown_scheduled and pit.getTicks() >= shutdown_target_tick) {
        shutdown_scheduled = false;
        shutdown();
    }
}

pub fn isShutdownScheduled() bool {
    return shutdown_scheduled;
}

// ---- Uptime ----

/// Get uptime in seconds.
pub fn uptimeSecs() u32 {
    return @truncate((pit.getTicks() -| boot_tick) / 1000);
}

/// Print formatted uptime: Xd Xh Xm Xs
pub fn printUptime() void {
    const total = uptimeSecs();
    const days = total / 86400;
    const hours = (total % 86400) / 3600;
    const mins = (total % 3600) / 60;
    const secs = total % 60;

    vga.setColor(.light_grey, .black);
    vga.write("Uptime: ");
    if (days > 0) {
        printDec(@as(usize, days));
        vga.write("d ");
    }
    printDec(@as(usize, hours));
    vga.write("h ");
    printDec(@as(usize, mins));
    vga.write("m ");
    printDec(@as(usize, secs));
    vga.write("s\n");
}

// ---- Status ----

/// Get the current power state.
pub fn getState() PowerState {
    return current_state;
}

pub fn stateName(state: PowerState) []const u8 {
    return switch (state) {
        .running => "Running",
        .shutting_down => "Shutting down",
        .rebooting => "Rebooting",
        .halted => "Halted",
    };
}

/// Display power information.
pub fn printPowerInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Power Info:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  State:  ");
    vga.write(stateName(current_state));
    vga.putChar('\n');

    vga.write("  ");
    printUptime();

    if (shutdown_scheduled) {
        const remaining = (shutdown_target_tick -| pit.getTicks()) / 1000;
        vga.write("  Shutdown in: ");
        printDec(@truncate(remaining));
        vga.write("s\n");
    }

    // Boot tick
    vga.write("  Boot tick:  ");
    printDec64(boot_tick);
    vga.putChar('\n');
}

// ---- Helpers ----

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
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

fn serialWriteDec(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
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
