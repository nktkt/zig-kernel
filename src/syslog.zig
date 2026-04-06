// System logging (syslog-like) — ring buffer kernel log with priorities and facilities
//
// Supports syslog-style priorities (EMERG..DEBUG) and facilities (kern, user,
// daemon, auth, local0-7). Messages are stored in a 128-entry ring buffer.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

const MAX_MESSAGES = 128;
const MAX_MSG_LEN = 80;
const MAX_IDENT_LEN = 16;

// ---- Log levels (priorities) ----

pub const Priority = enum(u8) {
    emerg = 0, // System is unusable
    alert = 1, // Action must be taken immediately
    crit = 2, // Critical conditions
    err = 3, // Error conditions
    warning = 4, // Warning conditions
    notice = 5, // Normal but significant condition
    info = 6, // Informational
    debug = 7, // Debug-level messages

    pub fn name(self: Priority) []const u8 {
        return switch (self) {
            .emerg => "EMERG  ",
            .alert => "ALERT  ",
            .crit => "CRIT   ",
            .err => "ERR    ",
            .warning => "WARNING",
            .notice => "NOTICE ",
            .info => "INFO   ",
            .debug => "DEBUG  ",
        };
    }

    pub fn color(self: Priority) vga.Color {
        return switch (self) {
            .emerg => .light_red,
            .alert => .light_red,
            .crit => .light_red,
            .err => .red,
            .warning => .yellow,
            .notice => .light_cyan,
            .info => .light_green,
            .debug => .dark_grey,
        };
    }
};

// ---- Facilities ----

pub const Facility = enum(u8) {
    kern = 0,
    user = 1,
    daemon = 2,
    auth = 3,
    local0 = 4,
    local1 = 5,
    local2 = 6,
    local3 = 7,
    local4 = 8,
    local5 = 9,
    local6 = 10,
    local7 = 11,

    pub fn name(self: Facility) []const u8 {
        return switch (self) {
            .kern => "kern  ",
            .user => "user  ",
            .daemon => "daemon",
            .auth => "auth  ",
            .local0 => "local0",
            .local1 => "local1",
            .local2 => "local2",
            .local3 => "local3",
            .local4 => "local4",
            .local5 => "local5",
            .local6 => "local6",
            .local7 => "local7",
        };
    }
};

// ---- Log message entry ----

const LogEntry = struct {
    valid: bool,
    priority: Priority,
    facility: Facility,
    timestamp: u64, // tick at which message was logged
    ident: [MAX_IDENT_LEN]u8,
    ident_len: u8,
    message: [MAX_MSG_LEN]u8,
    msg_len: u8,
};

// ---- State ----

var messages: [MAX_MESSAGES]LogEntry = undefined;
var write_idx: usize = 0;
var total_messages: u32 = 0;
var dropped_messages: u32 = 0;

// Current log context
var current_ident: [MAX_IDENT_LEN]u8 = undefined;
var current_ident_len: u8 = 0;
var current_facility: Facility = .kern;

// Filter
var min_priority: Priority = .debug; // show all by default

var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&messages) |*m| {
        m.valid = false;
        m.msg_len = 0;
        m.ident_len = 0;
    }
    write_idx = 0;
    total_messages = 0;
    dropped_messages = 0;
    current_ident_len = 0;
    current_facility = .kern;
    min_priority = .debug;
    initialized = true;

    serial.write("[syslog] System logger initialized (");
    serialDec(MAX_MESSAGES);
    serial.write(" entries, ");
    serialDec(MAX_MSG_LEN);
    serial.write(" chars/msg)\n");
}

// ---- Configuration ----

/// Open a log context (like openlog).
pub fn openlog(ident: []const u8, facility: Facility) void {
    current_ident_len = @intCast(@min(ident.len, MAX_IDENT_LEN));
    @memcpy(current_ident[0..current_ident_len], ident[0..current_ident_len]);
    current_facility = facility;
}

/// Set minimum priority filter.
pub fn setMinPriority(prio: Priority) void {
    min_priority = prio;
}

/// Get minimum priority filter.
pub fn getMinPriority() Priority {
    return min_priority;
}

// ---- Logging ----

/// Log a message with the given priority (uses current ident/facility).
pub fn syslog_msg(priority: Priority, message: []const u8) void {
    logWithFacility(priority, current_facility, message);
}

/// Log a message with explicit facility.
pub fn logWithFacility(priority: Priority, facility: Facility, message: []const u8) void {
    if (!initialized) return;

    const entry = &messages[write_idx];
    entry.valid = true;
    entry.priority = priority;
    entry.facility = facility;
    entry.timestamp = pit.getTicks();

    // Copy ident
    entry.ident_len = current_ident_len;
    if (current_ident_len > 0) {
        @memcpy(entry.ident[0..current_ident_len], current_ident[0..current_ident_len]);
    }

    // Copy message
    entry.msg_len = @intCast(@min(message.len, MAX_MSG_LEN));
    @memcpy(entry.message[0..entry.msg_len], message[0..entry.msg_len]);

    write_idx = (write_idx + 1) % MAX_MESSAGES;
    total_messages += 1;

    // Also echo to serial for critical messages
    if (@intFromEnum(priority) <= @intFromEnum(Priority.err)) {
        serial.write("[syslog] ");
        serial.write(priority.name());
        serial.write(": ");
        serial.write(message[0..@min(message.len, MAX_MSG_LEN)]);
        serial.write("\n");
    }
}

/// Convenience: log to kern facility.
pub fn klog(priority: Priority, message: []const u8) void {
    const save_fac = current_facility;
    current_facility = .kern;
    syslog_msg(priority, message);
    current_facility = save_fac;
}

/// Convenience logging shortcuts.
pub fn emerg(msg: []const u8) void { klog(.emerg, msg); }
pub fn alert(msg: []const u8) void { klog(.alert, msg); }
pub fn crit(msg: []const u8) void { klog(.crit, msg); }
pub fn err(msg: []const u8) void { klog(.err, msg); }
pub fn warning(msg: []const u8) void { klog(.warning, msg); }
pub fn notice(msg: []const u8) void { klog(.notice, msg); }
pub fn info(msg: []const u8) void { klog(.info, msg); }
pub fn debug(msg: []const u8) void { klog(.debug, msg); }

// ---- Query ----

/// Get total message count (including overwritten ones).
pub fn getMessageCount() usize {
    return @as(usize, total_messages);
}

/// Clear all log messages.
pub fn clearLog() void {
    for (&messages) |*m| {
        m.valid = false;
    }
    write_idx = 0;
    total_messages = 0;
    dropped_messages = 0;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Display ----

/// Print recent log messages (most recent last).
pub fn printLog() void {
    if (!initialized) {
        vga.write("Syslog not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== System Log ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  TIME       PRI     FACILITY  IDENT     MESSAGE\n");
    vga.setColor(.light_grey, .black);

    const count = if (total_messages < MAX_MESSAGES) total_messages else MAX_MESSAGES;
    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no messages)\n");
        return;
    }

    // Print from oldest to newest
    var displayed: u32 = 0;
    var i: usize = 0;
    while (i < MAX_MESSAGES) : (i += 1) {
        // Calculate index: start from oldest
        const start = if (total_messages >= MAX_MESSAGES) write_idx else 0;
        const idx = (start + i) % MAX_MESSAGES;
        const entry = &messages[idx];
        if (!entry.valid) continue;

        // Apply priority filter
        if (@intFromEnum(entry.priority) > @intFromEnum(min_priority)) continue;

        printEntry(entry);
        displayed += 1;
    }

    vga.setColor(.dark_grey, .black);
    vga.write("--- ");
    fmt.printDec(@as(usize, displayed));
    vga.write(" messages (total logged: ");
    fmt.printDec(@as(usize, total_messages));
    vga.write(") ---\n");
}

/// Print messages filtered by priority level.
pub fn printByPriority(level: Priority) void {
    if (!initialized) return;

    vga.setColor(.light_cyan, .black);
    vga.write("=== Syslog [");
    vga.write(level.name());
    vga.write("] ===\n");

    var count: u32 = 0;
    var i: usize = 0;
    while (i < MAX_MESSAGES) : (i += 1) {
        const start = if (total_messages >= MAX_MESSAGES) write_idx else 0;
        const idx = (start + i) % MAX_MESSAGES;
        const entry = &messages[idx];
        if (!entry.valid) continue;
        if (entry.priority != level) continue;

        printEntry(entry);
        count += 1;
    }

    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no messages at this level)\n");
    }
}

/// Print messages filtered by facility.
pub fn printByFacility(facility: Facility) void {
    if (!initialized) return;

    vga.setColor(.light_cyan, .black);
    vga.write("=== Syslog [");
    vga.write(facility.name());
    vga.write("] ===\n");

    var count: u32 = 0;
    var i: usize = 0;
    while (i < MAX_MESSAGES) : (i += 1) {
        const start = if (total_messages >= MAX_MESSAGES) write_idx else 0;
        const idx = (start + i) % MAX_MESSAGES;
        const entry = &messages[idx];
        if (!entry.valid) continue;
        if (entry.facility != facility) continue;

        printEntry(entry);
        count += 1;
    }

    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no messages for this facility)\n");
    }
}

/// Print log summary/statistics.
pub fn printStats() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Syslog Statistics ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Total messages:   ");
    fmt.printDec(@as(usize, total_messages));
    vga.putChar('\n');

    vga.write("Buffer capacity:  ");
    fmt.printDec(MAX_MESSAGES);
    vga.putChar('\n');

    vga.write("Buffer used:      ");
    const used = if (total_messages < MAX_MESSAGES) total_messages else MAX_MESSAGES;
    fmt.printDec(@as(usize, used));
    vga.putChar('\n');

    vga.write("Filter level:     ");
    vga.write(min_priority.name());
    vga.putChar('\n');

    // Count per priority
    vga.setColor(.light_cyan, .black);
    vga.write("\nMessages by priority:\n");

    var prio: u8 = 0;
    while (prio <= 7) : (prio += 1) {
        var count: u32 = 0;
        for (&messages) |*m| {
            if (m.valid and @intFromEnum(m.priority) == prio) {
                count += 1;
            }
        }
        const p: Priority = @enumFromInt(prio);
        vga.setColor(p.color(), .black);
        vga.write("  ");
        vga.write(p.name());
        vga.write(": ");
        fmt.printDec(@as(usize, count));
        vga.putChar('\n');
    }
}

// ---- Internal ----

fn printEntry(entry: *const LogEntry) void {
    // Timestamp
    vga.setColor(.dark_grey, .black);
    vga.write("  [");
    printTimestamp(entry.timestamp);
    vga.write("] ");

    // Priority
    vga.setColor(entry.priority.color(), .black);
    vga.write(entry.priority.name());
    vga.write("  ");

    // Facility
    vga.setColor(.dark_grey, .black);
    vga.write(entry.facility.name());
    vga.write("  ");

    // Ident
    vga.setColor(.yellow, .black);
    if (entry.ident_len > 0) {
        vga.write(entry.ident[0..entry.ident_len]);
    } else {
        vga.write("-");
    }
    padTo(entry.ident_len, 10);

    // Message
    vga.setColor(.light_grey, .black);
    vga.write(entry.message[0..entry.msg_len]);
    vga.putChar('\n');
}

fn printTimestamp(ticks: u64) void {
    // Print as seconds.milliseconds
    const secs = ticks / 1000;
    const ms = ticks % 1000;
    printDec64Compact(secs);
    vga.putChar('.');
    if (ms < 100) vga.putChar('0');
    if (ms < 10) vga.putChar('0');
    printDec64Compact(ms);
}

fn padTo(current_len: u8, target: u8) void {
    if (current_len < target) {
        var pad = target - current_len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
}

fn printDec64Compact(n: u64) void {
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
