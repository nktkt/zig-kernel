// Signal handling framework -- POSIX-like signal delivery for kernel tasks
//
// Provides 32 standard signal definitions (SIGHUP through SIGSYS), per-process
// signal masks and pending sets, custom handler registration, and reliable
// signal queuing. Default actions include terminate, core dump, stop, continue,
// and ignore.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Signal numbers (1-based, matching POSIX) ----

pub const SIGHUP = 1;
pub const SIGINT = 2;
pub const SIGQUIT = 3;
pub const SIGILL = 4;
pub const SIGTRAP = 5;
pub const SIGABRT = 6;
pub const SIGBUS = 7;
pub const SIGFPE = 8;
pub const SIGKILL = 9;
pub const SIGSEGV = 10;
pub const SIGPIPE = 11;
pub const SIGALRM = 12;
pub const SIGTERM = 13;
pub const SIGUSR1 = 14;
pub const SIGUSR2 = 15;
pub const SIGCHLD = 16;
pub const SIGCONT = 17;
pub const SIGSTOP = 18;
pub const SIGTSTP = 19;
pub const SIGTTIN = 20;
pub const SIGTTOU = 21;
pub const SIGURG = 22;
pub const SIGXCPU = 23;
pub const SIGXFSZ = 24;
pub const SIGVTALRM = 25;
pub const SIGPROF = 26;
pub const SIGWINCH = 27;
pub const SIGIO = 28;
pub const SIGPWR = 29;
pub const SIGSYS = 30;
pub const SIGRTMIN = 31;
pub const SIGRTMAX = 32;

pub const NUM_SIGNALS = 32;

// ---- Signal names ----

const signal_names = [NUM_SIGNALS][]const u8{
    "SIGHUP",  "SIGINT",    "SIGQUIT",  "SIGILL",
    "SIGTRAP", "SIGABRT",   "SIGBUS",   "SIGFPE",
    "SIGKILL", "SIGSEGV",   "SIGPIPE",  "SIGALRM",
    "SIGTERM", "SIGUSR1",   "SIGUSR2",  "SIGCHLD",
    "SIGCONT", "SIGSTOP",   "SIGTSTP",  "SIGTTIN",
    "SIGTTOU", "SIGURG",    "SIGXCPU",  "SIGXFSZ",
    "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGIO",
    "SIGPWR",  "SIGSYS",    "SIGRTMIN", "SIGRTMAX",
};

/// Get human-readable signal name from number (1-based).
pub fn signalName(signum: u8) []const u8 {
    if (signum == 0 or signum > NUM_SIGNALS) return "UNKNOWN";
    return signal_names[signum - 1];
}

// ---- Default actions ----

pub const Action = enum(u8) {
    terminate = 0,
    core_dump = 1,
    stop = 2,
    @"continue" = 3,
    ignore = 4,
};

/// Default action for each signal (indexed by signum - 1).
const default_actions = [NUM_SIGNALS]Action{
    .terminate,  // SIGHUP
    .terminate,  // SIGINT
    .core_dump,  // SIGQUIT
    .core_dump,  // SIGILL
    .core_dump,  // SIGTRAP
    .core_dump,  // SIGABRT
    .core_dump,  // SIGBUS
    .core_dump,  // SIGFPE
    .terminate,  // SIGKILL (cannot be caught)
    .core_dump,  // SIGSEGV
    .terminate,  // SIGPIPE
    .terminate,  // SIGALRM
    .terminate,  // SIGTERM
    .terminate,  // SIGUSR1
    .terminate,  // SIGUSR2
    .ignore,     // SIGCHLD
    .@"continue",// SIGCONT
    .stop,       // SIGSTOP (cannot be caught)
    .stop,       // SIGTSTP
    .stop,       // SIGTTIN
    .stop,       // SIGTTOU
    .ignore,     // SIGURG
    .core_dump,  // SIGXCPU
    .core_dump,  // SIGXFSZ
    .terminate,  // SIGVTALRM
    .terminate,  // SIGPROF
    .ignore,     // SIGWINCH
    .terminate,  // SIGIO
    .terminate,  // SIGPWR
    .core_dump,  // SIGSYS
    .terminate,  // SIGRTMIN
    .terminate,  // SIGRTMAX
};

fn getDefaultAction(signum: u8) Action {
    if (signum == 0 or signum > NUM_SIGNALS) return .terminate;
    return default_actions[signum - 1];
}

// ---- Signal disposition ----

pub const Disposition = enum(u8) {
    default = 0,
    ignore = 1,
    handler = 2,
};

pub const HandlerFn = *const fn (u8) void;

const SignalDisposition = struct {
    disposition: Disposition,
    handler: ?HandlerFn,
};

// ---- Signal queue entry ----

const MAX_QUEUED = 8;

const QueuedSignal = struct {
    signum: u8,
    valid: bool,
};

// ---- Per-process signal state ----

pub const MAX_PROCESSES = 16;

const ProcessSignalState = struct {
    active: bool,
    pid: u32,
    mask: u32, // blocked signals (bit N = signal N+1)
    pending: u32, // pending signals
    dispositions: [NUM_SIGNALS]SignalDisposition,
    // Reliable signal queue
    queue: [MAX_QUEUED]QueuedSignal,
    queue_count: u8,
    // Statistics
    signals_received: u32,
    signals_delivered: u32,
    signals_ignored: u32,
    signals_blocked: u32,
};

// ---- sigprocmask operations ----

pub const SIG_BLOCK = 0;
pub const SIG_UNBLOCK = 1;
pub const SIG_SETMASK = 2;

// ---- State ----

var processes: [MAX_PROCESSES]ProcessSignalState = undefined;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&processes) |*p| {
        resetProcess(p);
    }
    initialized = true;
    serial.write("[signal] Signal handler initialized\n");
}

fn resetProcess(p: *ProcessSignalState) void {
    p.active = false;
    p.pid = 0;
    p.mask = 0;
    p.pending = 0;
    p.queue_count = 0;
    p.signals_received = 0;
    p.signals_delivered = 0;
    p.signals_ignored = 0;
    p.signals_blocked = 0;
    for (&p.dispositions) |*d| {
        d.disposition = .default;
        d.handler = null;
    }
    for (&p.queue) |*q| {
        q.valid = false;
        q.signum = 0;
    }
}

fn findProcess(pid: u32) ?*ProcessSignalState {
    for (&processes) |*p| {
        if (p.active and p.pid == pid) return p;
    }
    return null;
}

fn findOrCreateProcess(pid: u32) ?*ProcessSignalState {
    // Try to find existing
    if (findProcess(pid)) |p| return p;
    // Create new
    for (&processes) |*p| {
        if (!p.active) {
            resetProcess(p);
            p.active = true;
            p.pid = pid;
            return p;
        }
    }
    return null;
}

// ---- Signal bit helpers ----

fn sigBit(signum: u8) u32 {
    if (signum == 0 or signum > NUM_SIGNALS) return 0;
    return @as(u32, 1) << @truncate(signum - 1);
}

// ---- Handler registration ----

/// Register a custom signal handler for a process.
/// SIGKILL and SIGSTOP cannot be caught.
pub fn registerHandler(pid: u32, signum: u8, handler: HandlerFn) bool {
    if (signum == SIGKILL or signum == SIGSTOP) return false;
    if (signum == 0 or signum > NUM_SIGNALS) return false;

    const p = findOrCreateProcess(pid) orelse return false;
    p.dispositions[signum - 1] = .{
        .disposition = .handler,
        .handler = handler,
    };
    return true;
}

/// Set disposition to ignore for a signal.
pub fn ignoreSignal(pid: u32, signum: u8) bool {
    if (signum == SIGKILL or signum == SIGSTOP) return false;
    if (signum == 0 or signum > NUM_SIGNALS) return false;

    const p = findOrCreateProcess(pid) orelse return false;
    p.dispositions[signum - 1] = .{
        .disposition = .ignore,
        .handler = null,
    };
    return true;
}

/// Reset disposition to default for a signal.
pub fn resetHandler(pid: u32, signum: u8) bool {
    if (signum == 0 or signum > NUM_SIGNALS) return false;
    const p = findProcess(pid) orelse return false;
    p.dispositions[signum - 1] = .{
        .disposition = .default,
        .handler = null,
    };
    return true;
}

// ---- Signal mask management ----

/// Set the signal mask for a process.
pub fn setMask(pid: u32, mask: u32) bool {
    const p = findOrCreateProcess(pid) orelse return false;
    // Cannot block SIGKILL or SIGSTOP
    p.mask = mask & ~(sigBit(SIGKILL) | sigBit(SIGSTOP));
    return true;
}

/// Get the signal mask for a process.
pub fn getMask(pid: u32) u32 {
    const p = findProcess(pid) orelse return 0;
    return p.mask;
}

/// Block a specific signal for a process.
pub fn blockSignal(pid: u32, signum: u8) bool {
    if (signum == SIGKILL or signum == SIGSTOP) return false;
    const p = findOrCreateProcess(pid) orelse return false;
    p.mask |= sigBit(signum);
    return true;
}

/// Unblock a specific signal for a process.
pub fn unblockSignal(pid: u32, signum: u8) bool {
    const p = findProcess(pid) orelse return false;
    p.mask &= ~sigBit(signum);
    return true;
}

/// sigprocmask: modify signal mask (SIG_BLOCK, SIG_UNBLOCK, SIG_SETMASK).
pub fn sigprocmask(pid: u32, how: u8, set: u32) bool {
    const p = findOrCreateProcess(pid) orelse return false;
    const protected = sigBit(SIGKILL) | sigBit(SIGSTOP);

    switch (how) {
        SIG_BLOCK => {
            p.mask |= (set & ~protected);
        },
        SIG_UNBLOCK => {
            p.mask &= ~set;
        },
        SIG_SETMASK => {
            p.mask = set & ~protected;
        },
        else => return false,
    }
    return true;
}

// ---- Sending signals ----

/// Send a signal to a process. Queues it in the reliable signal queue
/// and marks it as pending.
pub fn sendSignal(pid: u32, signum: u8) bool {
    if (signum == 0 or signum > NUM_SIGNALS) return false;
    const p = findOrCreateProcess(pid) orelse return false;

    p.signals_received += 1;

    // Check if blocked
    if (p.mask & sigBit(signum) != 0) {
        // Signal is blocked, just mark pending
        p.pending |= sigBit(signum);
        p.signals_blocked += 1;
        return true;
    }

    // Check disposition
    const disp = p.dispositions[signum - 1];
    if (disp.disposition == .ignore) {
        p.signals_ignored += 1;
        return true;
    }

    // Mark pending
    p.pending |= sigBit(signum);

    // Queue for reliable delivery
    if (p.queue_count < MAX_QUEUED) {
        p.queue[p.queue_count] = .{
            .signum = signum,
            .valid = true,
        };
        p.queue_count += 1;
    }
    // If queue is full, the signal is still pending (standard signals coalesce)

    return true;
}

/// Check if a signal is pending for a process.
pub fn isPending(pid: u32, signum: u8) bool {
    if (signum == 0 or signum > NUM_SIGNALS) return false;
    const p = findProcess(pid) orelse return false;
    return (p.pending & sigBit(signum)) != 0;
}

/// Get all pending signals for a process.
pub fn getPending(pid: u32) u32 {
    const p = findProcess(pid) orelse return 0;
    return p.pending;
}

// ---- Signal delivery ----

/// Process and deliver all pending, unblocked signals for a task.
/// Returns the number of signals delivered.
pub fn deliverSignals(pid: u32) u32 {
    const p = findProcess(pid) orelse return 0;

    // Deliverable = pending & ~mask
    const deliverable = p.pending & ~p.mask;
    if (deliverable == 0) return 0;

    var count: u32 = 0;
    var sig: u8 = 1;
    while (sig <= NUM_SIGNALS) : (sig += 1) {
        if (deliverable & sigBit(sig) == 0) continue;

        const disp = p.dispositions[sig - 1];
        switch (disp.disposition) {
            .handler => {
                // Call the handler
                if (disp.handler) |h| {
                    h(sig);
                }
                count += 1;
                p.signals_delivered += 1;
            },
            .ignore => {
                p.signals_ignored += 1;
            },
            .default => {
                // Execute default action
                const action = getDefaultAction(sig);
                executeDefaultAction(pid, sig, action);
                count += 1;
                p.signals_delivered += 1;
            },
        }

        // Clear pending bit
        p.pending &= ~sigBit(sig);
    }

    // Compact queue: remove delivered entries
    compactQueue(p);

    return count;
}

fn compactQueue(p: *ProcessSignalState) void {
    var write_idx: u8 = 0;
    var read_idx: u8 = 0;
    while (read_idx < p.queue_count) : (read_idx += 1) {
        const entry = &p.queue[read_idx];
        if (entry.valid) {
            // Check if still pending
            if (p.pending & sigBit(entry.signum) != 0) {
                if (write_idx != read_idx) {
                    p.queue[write_idx] = p.queue[read_idx];
                }
                write_idx += 1;
            }
        }
    }
    p.queue_count = write_idx;
}

fn executeDefaultAction(pid: u32, signum: u8, act: Action) void {
    switch (act) {
        .terminate => {
            serial.write("[signal] pid ");
            serialDec32(pid);
            serial.write(" terminated by ");
            serial.write(signalName(signum));
            serial.write("\n");
        },
        .core_dump => {
            serial.write("[signal] pid ");
            serialDec32(pid);
            serial.write(" core dumped by ");
            serial.write(signalName(signum));
            serial.write("\n");
        },
        .stop => {
            serial.write("[signal] pid ");
            serialDec32(pid);
            serial.write(" stopped by ");
            serial.write(signalName(signum));
            serial.write("\n");
        },
        .@"continue" => {
            serial.write("[signal] pid ");
            serialDec32(pid);
            serial.write(" continued\n");
        },
        .ignore => {},
    }
}

// ---- Removal ----

/// Remove signal state for a process (on exit).
pub fn removeProcess(pid: u32) void {
    const p = findProcess(pid) orelse return;
    resetProcess(p);
}

// ---- Printing / Debug ----

/// Print complete signal information for a process.
pub fn printSignalInfo(pid: u32) void {
    const p = findProcess(pid) orelse {
        vga.write("No signal state for pid ");
        fmt.printDec(@as(usize, pid));
        vga.putChar('\n');
        return;
    };

    vga.setColor(.light_cyan, .black);
    vga.write("=== Signal Info for PID ");
    fmt.printDec(@as(usize, p.pid));
    vga.write(" ===\n");

    // Pending signals
    vga.setColor(.yellow, .black);
    vga.write("Pending: ");
    vga.setColor(.light_grey, .black);
    printSignalSet(p.pending);
    vga.putChar('\n');

    // Blocked signals
    vga.setColor(.yellow, .black);
    vga.write("Blocked: ");
    vga.setColor(.light_grey, .black);
    printSignalSet(p.mask);
    vga.putChar('\n');

    // Handlers
    vga.setColor(.yellow, .black);
    vga.write("Handlers:\n");
    vga.setColor(.light_grey, .black);
    var sig: u8 = 1;
    while (sig <= NUM_SIGNALS) : (sig += 1) {
        const disp = p.dispositions[sig - 1];
        if (disp.disposition != .default) {
            vga.write("  ");
            vga.write(signalName(sig));
            vga.write(": ");
            switch (disp.disposition) {
                .handler => vga.write("HANDLER"),
                .ignore => vga.write("IGNORE"),
                .default => vga.write("DEFAULT"),
            }
            vga.putChar('\n');
        }
    }

    // Queue
    vga.setColor(.yellow, .black);
    vga.write("Queued: ");
    vga.setColor(.light_grey, .black);
    fmt.printDec(@as(usize, p.queue_count));
    vga.write("/");
    fmt.printDec(MAX_QUEUED);
    vga.putChar('\n');

    // Statistics
    vga.setColor(.yellow, .black);
    vga.write("Stats: ");
    vga.setColor(.light_grey, .black);
    vga.write("recv=");
    fmt.printDec(@as(usize, p.signals_received));
    vga.write(" deliv=");
    fmt.printDec(@as(usize, p.signals_delivered));
    vga.write(" ign=");
    fmt.printDec(@as(usize, p.signals_ignored));
    vga.write(" blk=");
    fmt.printDec(@as(usize, p.signals_blocked));
    vga.putChar('\n');
}

/// Print all active signal states.
pub fn printAll() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Signal State (all processes) ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID   PENDING    BLOCKED    RECV  DELIV  IGN   BLK   QUEUED\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    for (&processes) |*p| {
        if (!p.active) continue;
        any = true;
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.pid), 4);
        vga.write("  0x");
        fmt.printHex32(p.pending);
        vga.write("  0x");
        fmt.printHex32(p.mask);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.signals_received), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.signals_delivered), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.signals_ignored), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.signals_blocked), 4);
        vga.write("  ");
        fmt.printDec(@as(usize, p.queue_count));
        vga.putChar('\n');
    }
    if (!any) {
        vga.write("  (no processes)\n");
    }
}

fn printSignalSet(set: u32) void {
    if (set == 0) {
        vga.write("(none)");
        return;
    }
    var first = true;
    var sig: u8 = 1;
    while (sig <= NUM_SIGNALS) : (sig += 1) {
        if (set & sigBit(sig) != 0) {
            if (!first) vga.write(" ");
            vga.write(signalName(sig));
            first = false;
        }
    }
}

// ---- Helpers ----

fn serialDec32(n: u32) void {
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
