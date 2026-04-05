// System watchdog timer -- software watchdog with configurable actions
//
// Monitors system health by requiring periodic "feeds" from healthy code paths.
// If the watchdog is not fed within the configured timeout, it triggers a
// configurable action: log a warning, reset the system, or panic.
// A pre-timeout warning is issued at 50% of the timeout period.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Watchdog actions ----

pub const WatchdogAction = enum(u8) {
    log_warning = 0,
    reset_system = 1,
    panic = 2,
};

// ---- Statistics ----

pub const WatchdogStats = struct {
    total_feeds: u64,
    total_timeouts: u32,
    total_warnings: u32,
    last_feed_tick: u64,
    uptime_ticks: u64,
};

// ---- State ----

var enabled: bool = false;
var timeout_ms: u32 = 5000; // default 5 seconds
var timeout_ticks: u64 = 5000; // timeout in PIT ticks (1kHz)
var last_feed_tick: u64 = 0;
var action: WatchdogAction = .log_warning;
var pre_timeout_warned: bool = false;
var initialized: bool = false;

// Statistics
var total_feeds: u64 = 0;
var total_timeouts: u32 = 0;
var total_warnings: u32 = 0;

// Stack trace depth for timeout dumps
const MAX_STACK_DEPTH = 8;

// ---- Initialization ----

/// Initialize the watchdog with the given timeout in milliseconds.
pub fn init(timeout: u32) void {
    timeout_ms = if (timeout < 100) 100 else timeout; // minimum 100ms
    timeout_ticks = @as(u64, timeout_ms); // at 1kHz PIT, 1 tick = 1ms
    last_feed_tick = pit.getTicks();
    pre_timeout_warned = false;
    enabled = false; // must be explicitly enabled
    total_feeds = 0;
    total_timeouts = 0;
    total_warnings = 0;
    action = .log_warning;
    initialized = true;

    serial.write("[watchdog] initialized, timeout=");
    serialDec(timeout_ms);
    serial.write("ms\n");
}

// ---- Control ----

/// Enable the watchdog timer.
pub fn enable() void {
    if (!initialized) return;
    enabled = true;
    last_feed_tick = pit.getTicks();
    pre_timeout_warned = false;
    serial.write("[watchdog] enabled\n");
}

/// Disable the watchdog timer.
pub fn disable() void {
    if (!initialized) return;
    enabled = false;
    serial.write("[watchdog] disabled\n");
}

/// Feed the watchdog (reset the timer). Call from healthy code paths.
pub fn feed() void {
    if (!initialized) return;
    last_feed_tick = pit.getTicks();
    pre_timeout_warned = false;
    total_feeds += 1;
}

/// Set the watchdog timeout in milliseconds.
pub fn setTimeout(timeout: u32) void {
    if (!initialized) return;
    timeout_ms = if (timeout < 100) 100 else timeout;
    timeout_ticks = @as(u64, timeout_ms);
    // Re-feed to avoid immediate timeout
    feed();
}

/// Set the action to take on timeout.
pub fn setAction(new_action: WatchdogAction) void {
    action = new_action;
}

/// Get the remaining time until timeout (in ms).
pub fn getRemaining() u32 {
    if (!initialized or !enabled) return 0;
    const now = pit.getTicks();
    const elapsed = if (now >= last_feed_tick) now - last_feed_tick else 0;
    if (elapsed >= timeout_ticks) return 0;
    return @truncate(timeout_ticks - elapsed);
}

/// Check if the watchdog is enabled.
pub fn isEnabled() bool {
    return enabled;
}

/// Check if the watchdog is initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Timer check (called from timer interrupt) ----

/// Check if the watchdog has expired. Should be called periodically
/// (e.g., from the PIT timer interrupt handler).
pub fn check() void {
    if (!initialized or !enabled) return;

    const now = pit.getTicks();
    const elapsed = if (now >= last_feed_tick) now - last_feed_tick else 0;

    // Pre-timeout warning at 50%
    const half_timeout = timeout_ticks / 2;
    if (elapsed >= half_timeout and !pre_timeout_warned) {
        pre_timeout_warned = true;
        total_warnings += 1;
        handlePreTimeout(elapsed);
    }

    // Full timeout
    if (elapsed >= timeout_ticks) {
        total_timeouts += 1;
        handleTimeout(elapsed);

        // After handling, re-feed to prevent repeated triggers
        // (unless action is panic/reset which won't return)
        last_feed_tick = now;
        pre_timeout_warned = false;
    }
}

fn handlePreTimeout(elapsed: u64) void {
    serial.write("[watchdog] WARNING: pre-timeout at ");
    serialDec64(elapsed);
    serial.write("ms (timeout=");
    serialDec(timeout_ms);
    serial.write("ms)\n");

    vga.setColor(.yellow, .black);
    vga.write("[WATCHDOG] Warning: ");
    printDec64(elapsed);
    vga.write("ms since last feed (timeout: ");
    fmt.printDec(@as(usize, timeout_ms));
    vga.write("ms)\n");
    vga.setColor(.light_grey, .black);
}

fn handleTimeout(elapsed: u64) void {
    switch (action) {
        .log_warning => {
            serial.write("[watchdog] TIMEOUT after ");
            serialDec64(elapsed);
            serial.write("ms\n");

            vga.setColor(.light_red, .black);
            vga.write("[WATCHDOG] TIMEOUT: ");
            printDec64(elapsed);
            vga.write("ms since last feed!\n");
            vga.setColor(.light_grey, .black);

            // Print stack trace
            printStackTrace();
        },
        .reset_system => {
            serial.write("[watchdog] TIMEOUT - resetting system\n");
            vga.setColor(.light_red, .black);
            vga.write("[WATCHDOG] TIMEOUT - System reset!\n");

            // Triple fault to reset (write to ACPI reset port or triple fault)
            // In a real system: outb(0x64, 0xFE)
            // For now, just log and halt
            printStackTrace();
            haltLoop();
        },
        .panic => {
            serial.write("[watchdog] TIMEOUT - KERNEL PANIC\n");
            vga.setColor(.light_red, .black);
            vga.write("\n!!! WATCHDOG PANIC !!!\n");
            vga.write("System has been unresponsive for ");
            printDec64(elapsed);
            vga.write("ms\n\n");

            printStackTrace();
            haltLoop();
        },
    }
}

fn printStackTrace() void {
    vga.setColor(.yellow, .black);
    vga.write("Stack trace:\n");
    vga.setColor(.light_grey, .black);

    // Walk the EBP chain
    var ebp = asm volatile ("" : [ebp] "={ebp}" (-> u32));
    var depth: usize = 0;

    while (depth < MAX_STACK_DEPTH) : (depth += 1) {
        if (ebp == 0 or ebp < 0x1000) break; // invalid frame pointer

        // Return address is at [EBP + 4]
        const ret_addr_ptr: *const u32 = @ptrFromInt(ebp + 4);
        const ret_addr = ret_addr_ptr.*;

        if (ret_addr == 0) break;

        vga.write("  #");
        fmt.printDec(depth);
        vga.write("  0x");
        fmt.printHex32(ret_addr);
        vga.putChar('\n');

        serial.write("  #");
        serialDec(@as(u32, @truncate(depth)));
        serial.write("  0x");
        serialHex32(ret_addr);
        serial.write("\n");

        // Next frame
        const next_ebp_ptr: *const u32 = @ptrFromInt(ebp);
        ebp = next_ebp_ptr.*;
    }
}

fn haltLoop() void {
    while (true) {
        asm volatile ("hlt");
    }
}

// ---- Statistics ----

pub fn getStats() WatchdogStats {
    return .{
        .total_feeds = total_feeds,
        .total_timeouts = total_timeouts,
        .total_warnings = total_warnings,
        .last_feed_tick = last_feed_tick,
        .uptime_ticks = pit.getTicks(),
    };
}

/// Print the current watchdog status.
pub fn printStatus() void {
    if (!initialized) {
        vga.write("Watchdog not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Watchdog Status ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("State:        ");
    if (enabled) {
        vga.setColor(.light_green, .black);
        vga.write("ENABLED\n");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("DISABLED\n");
    }
    vga.setColor(.light_grey, .black);

    vga.write("Timeout:      ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, timeout_ms));
    vga.write(" ms\n");

    vga.setColor(.light_grey, .black);
    vga.write("Remaining:    ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, getRemaining()));
    vga.write(" ms\n");

    vga.setColor(.light_grey, .black);
    vga.write("Action:       ");
    vga.setColor(.white, .black);
    switch (action) {
        .log_warning => vga.write("Log warning"),
        .reset_system => vga.write("Reset system"),
        .panic => vga.write("Kernel panic"),
    }
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Total feeds:  ");
    vga.setColor(.white, .black);
    printDec64(total_feeds);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Timeouts:     ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, total_timeouts));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Warnings:     ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, total_warnings));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Last feed:    tick ");
    vga.setColor(.white, .black);
    printDec64(last_feed_tick);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Pre-warned:   ");
    vga.setColor(.white, .black);
    vga.write(if (pre_timeout_warned) "yes" else "no");
    vga.putChar('\n');
}

// ---- Helpers ----

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn serialDec(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
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
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var v = val;
    var i: usize = 8;
    var buf: [8]u8 = undefined;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| serial.putChar(c);
}
