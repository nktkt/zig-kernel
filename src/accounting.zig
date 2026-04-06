// Process accounting — per-process and system-wide resource usage tracking
//
// Tracks CPU ticks (user/system), memory peak, start time per process.
// System-wide: total forks, execs, exits, context switches.
// CPU utilization breakdown: user%, system%, idle%.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_ACCT_PROCS = 16;
const HISTORY_SIZE = 32; // recent exit history

// ---- Per-process accounting ----

pub const ProcessTime = struct {
    user_ticks: u64,
    system_ticks: u64,
    start_time: u64,
    memory_peak: u32, // peak memory in bytes
    total_ticks: u64, // user + system
};

const ProcessAcct = struct {
    active: bool,
    pid: u32,
    user_ticks: u64,
    system_ticks: u64,
    start_time: u64,
    memory_peak: u32,
    name: [16]u8,
    name_len: u8,
};

// ---- Exit history ----

const ExitRecord = struct {
    pid: u32,
    exit_code: i32,
    user_ticks: u64,
    system_ticks: u64,
    wall_time: u64, // time from creation to exit
    valid: bool,
};

// ---- System-wide accounting ----

pub const SystemAcct = struct {
    total_forks: u32,
    total_execs: u32,
    total_exits: u32,
    context_switches: u64,
    boot_time: u64,
    total_user_ticks: u64,
    total_system_ticks: u64,
    total_idle_ticks: u64,
};

// ---- State ----

var procs: [MAX_ACCT_PROCS]ProcessAcct = undefined;
var exit_history: [HISTORY_SIZE]ExitRecord = undefined;
var exit_history_idx: usize = 0;

var sys_forks: u32 = 0;
var sys_execs: u32 = 0;
var sys_exits: u32 = 0;
var sys_context_switches: u64 = 0;
var sys_boot_time: u64 = 0;
var sys_user_ticks: u64 = 0;
var sys_system_ticks: u64 = 0;
var sys_idle_ticks: u64 = 0;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&procs) |*p| {
        p.active = false;
        p.pid = 0;
        p.user_ticks = 0;
        p.system_ticks = 0;
        p.start_time = 0;
        p.memory_peak = 0;
        p.name_len = 0;
    }
    for (&exit_history) |*e| {
        e.valid = false;
    }
    exit_history_idx = 0;
    sys_forks = 0;
    sys_execs = 0;
    sys_exits = 0;
    sys_context_switches = 0;
    sys_boot_time = pit.getTicks();
    sys_user_ticks = 0;
    sys_system_ticks = 0;
    sys_idle_ticks = 0;
    initialized = true;
    serial.write("[acct] Process accounting initialized\n");
}

// ---- Process lifecycle ----

/// Called when a new process is created (fork).
pub fn processCreated(pid: u32) void {
    if (!initialized) return;
    sys_forks += 1;

    // Find a free slot
    for (&procs) |*p| {
        if (!p.active) {
            p.active = true;
            p.pid = pid;
            p.user_ticks = 0;
            p.system_ticks = 0;
            p.start_time = pit.getTicks();
            p.memory_peak = 0;
            p.name_len = 0;
            serial.write("[acct] process created pid=");
            serialDec(pid);
            serial.write("\n");
            return;
        }
    }
}

/// Called when a process is created with a name.
pub fn processCreatedNamed(pid: u32, name: []const u8) void {
    if (!initialized) return;
    sys_forks += 1;

    for (&procs) |*p| {
        if (!p.active) {
            p.active = true;
            p.pid = pid;
            p.user_ticks = 0;
            p.system_ticks = 0;
            p.start_time = pit.getTicks();
            p.memory_peak = 0;
            p.name_len = @intCast(@min(name.len, 16));
            @memcpy(p.name[0..p.name_len], name[0..p.name_len]);
            return;
        }
    }
}

/// Called when a process performs exec.
pub fn processExeced(pid: u32) void {
    _ = pid;
    if (!initialized) return;
    sys_execs += 1;
}

/// Called when a process exits.
pub fn processExited(pid: u32, exit_code: i32) void {
    if (!initialized) return;
    sys_exits += 1;

    for (&procs) |*p| {
        if (p.active and p.pid == pid) {
            // Record in exit history
            const now = pit.getTicks();
            exit_history[exit_history_idx] = .{
                .pid = pid,
                .exit_code = exit_code,
                .user_ticks = p.user_ticks,
                .system_ticks = p.system_ticks,
                .wall_time = now - p.start_time,
                .valid = true,
            };
            exit_history_idx = (exit_history_idx + 1) % HISTORY_SIZE;

            serial.write("[acct] process exited pid=");
            serialDec(pid);
            serial.write(" code=");
            serialDecSigned(exit_code);
            serial.write(" user=");
            serialDec64(p.user_ticks);
            serial.write(" sys=");
            serialDec64(p.system_ticks);
            serial.write("\n");

            p.active = false;
            return;
        }
    }
}

// ---- Tick accounting ----

/// Called from the timer interrupt for the currently running process.
pub fn updateTick(pid: u32, is_system: bool) void {
    if (!initialized) return;

    if (is_system) {
        sys_system_ticks += 1;
    } else {
        sys_user_ticks += 1;
    }

    for (&procs) |*p| {
        if (p.active and p.pid == pid) {
            if (is_system) {
                p.system_ticks += 1;
            } else {
                p.user_ticks += 1;
            }
            return;
        }
    }

    // If no process found, count as idle
    sys_idle_ticks += 1;
}

/// Record an idle tick (no process running).
pub fn idleTick() void {
    if (!initialized) return;
    sys_idle_ticks += 1;
}

/// Record a context switch.
pub fn contextSwitch() void {
    if (!initialized) return;
    sys_context_switches += 1;
}

/// Update memory peak for a process.
pub fn updateMemoryPeak(pid: u32, current_bytes: u32) void {
    if (!initialized) return;
    for (&procs) |*p| {
        if (p.active and p.pid == pid) {
            if (current_bytes > p.memory_peak) {
                p.memory_peak = current_bytes;
            }
            return;
        }
    }
}

// ---- Queries ----

/// Get process time for a specific PID.
pub fn getProcessTime(pid: u32) ?ProcessTime {
    if (!initialized) return null;
    for (&procs) |*p| {
        if (p.active and p.pid == pid) {
            return ProcessTime{
                .user_ticks = p.user_ticks,
                .system_ticks = p.system_ticks,
                .start_time = p.start_time,
                .memory_peak = p.memory_peak,
                .total_ticks = p.user_ticks + p.system_ticks,
            };
        }
    }
    return null;
}

/// Get system uptime in ticks.
pub fn getUptime() u64 {
    return pit.getTicks() - sys_boot_time;
}

/// Get system uptime in seconds.
pub fn getUptimeSecs() u32 {
    return @truncate(getUptime() / 1000);
}

/// Get system-wide accounting stats.
pub fn getSystemAcct() SystemAcct {
    return .{
        .total_forks = sys_forks,
        .total_execs = sys_execs,
        .total_exits = sys_exits,
        .context_switches = sys_context_switches,
        .boot_time = sys_boot_time,
        .total_user_ticks = sys_user_ticks,
        .total_system_ticks = sys_system_ticks,
        .total_idle_ticks = sys_idle_ticks,
    };
}

// ---- CPU utilization ----

/// Return CPU utilization percentages (user, system, idle) as u32 (0-100).
pub fn getCpuUtilization() struct { user: u32, system: u32, idle: u32 } {
    const total = sys_user_ticks + sys_system_ticks + sys_idle_ticks;
    if (total == 0) return .{ .user = 0, .system = 0, .idle = 100 };

    const user_pct: u32 = @truncate((sys_user_ticks * 100) / total);
    const sys_pct: u32 = @truncate((sys_system_ticks * 100) / total);
    const idle_pct: u32 = 100 -| (user_pct + sys_pct);

    return .{ .user = user_pct, .system = sys_pct, .idle = idle_pct };
}

// ---- Display ----

/// Print accounting info for a specific process.
pub fn printProcessAccounting(pid: u32) void {
    if (!initialized) {
        vga.write("Accounting not initialized.\n");
        return;
    }

    for (&procs) |*p| {
        if (p.active and p.pid == pid) {
            const now = pit.getTicks();
            const wall = now - p.start_time;

            vga.setColor(.light_cyan, .black);
            vga.write("=== Process Accounting PID ");
            fmt.printDec(@as(usize, pid));
            vga.write(" ===\n");

            if (p.name_len > 0) {
                vga.setColor(.light_grey, .black);
                vga.write("  Name:        ");
                vga.write(p.name[0..p.name_len]);
                vga.putChar('\n');
            }

            vga.setColor(.light_grey, .black);
            vga.write("  User time:   ");
            printDec64(p.user_ticks);
            vga.write(" ticks (");
            printTimePretty(p.user_ticks);
            vga.write(")\n");

            vga.write("  System time: ");
            printDec64(p.system_ticks);
            vga.write(" ticks (");
            printTimePretty(p.system_ticks);
            vga.write(")\n");

            vga.write("  Total CPU:   ");
            printDec64(p.user_ticks + p.system_ticks);
            vga.write(" ticks\n");

            vga.write("  Wall time:   ");
            printDec64(wall);
            vga.write(" ticks (");
            printTimePretty(wall);
            vga.write(")\n");

            vga.write("  Memory peak: ");
            fmt.printSize(@as(usize, p.memory_peak));
            vga.putChar('\n');

            // CPU utilization for this process
            if (wall > 0) {
                const cpu_pct = ((p.user_ticks + p.system_ticks) * 100) / wall;
                vga.write("  CPU usage:   ");
                printDec64(cpu_pct);
                vga.write("%\n");
            }
            return;
        }
    }

    vga.write("Process ");
    fmt.printDec(@as(usize, pid));
    vga.write(" not found in accounting.\n");
}

/// Print system-wide accounting.
pub fn printSystemAccounting() void {
    if (!initialized) {
        vga.write("Accounting not initialized.\n");
        return;
    }

    const uptime = getUptime();
    const cpu = getCpuUtilization();

    vga.setColor(.light_cyan, .black);
    vga.write("=== System Accounting ===\n");

    vga.setColor(.light_grey, .black);
    vga.write("Uptime:           ");
    vga.setColor(.white, .black);
    printTimePretty(uptime);
    vga.write(" (");
    printDec64(uptime);
    vga.write(" ticks)\n");

    vga.setColor(.light_grey, .black);
    vga.write("Total forks:      ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, sys_forks));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Total execs:      ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, sys_execs));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Total exits:      ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, sys_exits));
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("Context switches: ");
    vga.setColor(.white, .black);
    printDec64(sys_context_switches);
    vga.putChar('\n');

    vga.setColor(.light_cyan, .black);
    vga.write("\nCPU Utilization:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  User:   ");
    vga.setColor(.light_green, .black);
    fmt.printDec(@as(usize, cpu.user));
    vga.write("%  ");
    fmt.printBar(@as(usize, cpu.user), 100, 30);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  System: ");
    vga.setColor(.light_red, .black);
    fmt.printDec(@as(usize, cpu.system));
    vga.write("%  ");
    fmt.printBar(@as(usize, cpu.system), 100, 30);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  Idle:   ");
    vga.setColor(.light_cyan, .black);
    fmt.printDec(@as(usize, cpu.idle));
    vga.write("%  ");
    fmt.printBar(@as(usize, cpu.idle), 100, 30);
    vga.putChar('\n');

    // Active processes
    vga.setColor(.light_cyan, .black);
    vga.write("\nActive Processes:\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID  USER_TICKS  SYS_TICKS  MEM_PEAK   NAME\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    for (&procs) |*p| {
        if (!p.active) continue;
        any = true;
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.pid), 4);
        vga.write("  ");
        printDec64Padded(p.user_ticks, 10);
        vga.write("  ");
        printDec64Padded(p.system_ticks, 9);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, p.memory_peak), 8);
        vga.write("   ");
        if (p.name_len > 0) {
            vga.write(p.name[0..p.name_len]);
        } else {
            vga.write("-");
        }
        vga.putChar('\n');
    }

    if (!any) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no tracked processes)\n");
    }
}

/// Print recent exit history.
pub fn printExitHistory() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Recent Exit History ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID  EXIT_CODE  USER_TICKS  SYS_TICKS  WALL_TIME\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    var i: usize = 0;
    while (i < HISTORY_SIZE) : (i += 1) {
        const idx = (exit_history_idx + HISTORY_SIZE - 1 - i) % HISTORY_SIZE;
        const e = &exit_history[idx];
        if (!e.valid) continue;
        any = true;

        vga.write("  ");
        fmt.printDecPadded(@as(usize, e.pid), 4);
        vga.write("  ");
        if (e.exit_code < 0) {
            vga.setColor(.light_red, .black);
            vga.write("    -");
            const abs: u32 = @intCast(-@as(i64, e.exit_code));
            fmt.printDec(@as(usize, abs));
        } else {
            fmt.printDecPadded(@as(usize, @intCast(e.exit_code)), 9);
        }
        vga.setColor(.light_grey, .black);
        vga.write("  ");
        printDec64Padded(e.user_ticks, 10);
        vga.write("  ");
        printDec64Padded(e.system_ticks, 9);
        vga.write("  ");
        printDec64Padded(e.wall_time, 9);
        vga.putChar('\n');
    }

    if (!any) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no exit records)\n");
    }
}

// ---- Helpers ----

/// Pretty-print ticks as Xh Xm Xs.
fn printTimePretty(ticks_val: u64) void {
    const secs = ticks_val / 1000;
    const hours = secs / 3600;
    const mins = (secs % 3600) / 60;
    const s = secs % 60;

    if (hours > 0) {
        printDec64(hours);
        vga.write("h ");
    }
    if (mins > 0 or hours > 0) {
        printDec64(mins);
        vga.write("m ");
    }
    printDec64(s);
    vga.write("s");
}

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

fn printDec64Padded(n: u64, width: usize) void {
    var digits: usize = 0;
    var tmp = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec64(n);
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

fn serialDecSigned(n: i32) void {
    if (n < 0) {
        serial.putChar('-');
        const abs: u32 = @intCast(-@as(i64, n));
        serialDec(abs);
    } else {
        serialDec(@intCast(n));
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

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}
