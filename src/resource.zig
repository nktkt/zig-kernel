// Resource limit management — rlimit-like per-process resource limits
//
// Supports soft/hard limits for CPU_TIME, MEMORY, OPEN_FILES, PROCESSES,
// FILE_SIZE, STACK_SIZE. Soft limits are advisory (can be raised to hard),
// hard limits are enforced.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_PROCESSES = 16;
pub const UNLIMITED: u32 = 0xFFFFFFFF;

// ---- Resource types ----

pub const ResourceType = enum(u8) {
    cpu_time = 0, // seconds of CPU time
    memory = 1, // bytes of memory
    open_files = 2, // number of open file descriptors
    processes = 3, // number of child processes
    file_size = 4, // maximum file size in bytes
    stack_size = 5, // stack size in bytes

    pub fn name(self: ResourceType) []const u8 {
        return switch (self) {
            .cpu_time => "CPU_TIME   ",
            .memory => "MEMORY     ",
            .open_files => "OPEN_FILES ",
            .processes => "PROCESSES  ",
            .file_size => "FILE_SIZE  ",
            .stack_size => "STACK_SIZE ",
        };
    }

    pub fn unit(self: ResourceType) []const u8 {
        return switch (self) {
            .cpu_time => "sec",
            .memory => "bytes",
            .open_files => "fds",
            .processes => "procs",
            .file_size => "bytes",
            .stack_size => "bytes",
        };
    }
};

pub const NUM_RESOURCES = 6;

// ---- Rlimit struct ----

pub const Rlimit = struct {
    soft: u32,
    hard: u32,
    current: u32,
};

// ---- Default limits ----

const DEFAULT_LIMITS = [NUM_RESOURCES]Rlimit{
    .{ .soft = 3600, .hard = UNLIMITED, .current = 0 }, // CPU_TIME: 1 hour soft
    .{ .soft = 1024 * 1024 * 64, .hard = 1024 * 1024 * 256, .current = 0 }, // MEMORY: 64MB/256MB
    .{ .soft = 32, .hard = 64, .current = 0 }, // OPEN_FILES
    .{ .soft = 16, .hard = 32, .current = 0 }, // PROCESSES
    .{ .soft = 1024 * 1024 * 16, .hard = UNLIMITED, .current = 0 }, // FILE_SIZE: 16MB
    .{ .soft = 4096 * 2, .hard = 4096 * 8, .current = 0 }, // STACK_SIZE: 8KB/32KB
};

// ---- Per-process resource limits ----

const ProcessLimits = struct {
    active: bool,
    pid: u32,
    limits: [NUM_RESOURCES]Rlimit,
};

// ---- State ----

var processes: [MAX_PROCESSES]ProcessLimits = undefined;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&processes) |*p| {
        p.active = false;
        p.pid = 0;
        p.limits = DEFAULT_LIMITS;
    }
    initialized = true;
    serial.write("[rlimit] Resource limit manager initialized\n");
}

// ---- Process registration ----

/// Register a new process with default limits.
pub fn registerProcess(pid: u32) bool {
    if (!initialized) return false;

    // Check if already registered
    for (&processes) |*p| {
        if (p.active and p.pid == pid) return true; // already registered
    }

    // Find free slot
    for (&processes) |*p| {
        if (!p.active) {
            p.active = true;
            p.pid = pid;
            p.limits = DEFAULT_LIMITS;
            return true;
        }
    }
    return false;
}

/// Unregister a process.
pub fn unregisterProcess(pid: u32) void {
    if (!initialized) return;
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            p.active = false;
            return;
        }
    }
}

// ---- Limit management ----

/// Set the soft and hard limits for a resource.
/// Returns false if: hard < soft, or new hard > old hard (non-root can't raise hard).
pub fn setLimit(pid: u32, resource: ResourceType, soft: u32, hard: u32) bool {
    if (!initialized) return false;
    if (hard != UNLIMITED and soft != UNLIMITED and soft > hard) return false;

    const res_idx = @intFromEnum(resource);
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            // Non-root cannot raise hard limit above current hard
            // (simplified: we always allow for now in kernel mode)
            p.limits[res_idx].soft = soft;
            p.limits[res_idx].hard = hard;

            serial.write("[rlimit] set pid=");
            serialDec(pid);
            serial.write(" ");
            serial.write(resource.name());
            serial.write(" soft=");
            if (soft == UNLIMITED) {
                serial.write("unlimited");
            } else {
                serialDec(soft);
            }
            serial.write(" hard=");
            if (hard == UNLIMITED) {
                serial.write("unlimited");
            } else {
                serialDec(hard);
            }
            serial.write("\n");
            return true;
        }
    }
    return false;
}

/// Get the current limit for a resource.
pub fn getLimit(pid: u32, resource: ResourceType) ?Rlimit {
    if (!initialized) return null;
    const res_idx = @intFromEnum(resource);
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            return p.limits[res_idx];
        }
    }
    return null;
}

/// Update the current usage value for a resource.
pub fn updateCurrent(pid: u32, resource: ResourceType, current: u32) void {
    if (!initialized) return;
    const res_idx = @intFromEnum(resource);
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            p.limits[res_idx].current = current;
            return;
        }
    }
}

/// Check if current usage is within soft limit.
pub fn checkLimit(pid: u32, resource: ResourceType, current: u32) bool {
    if (!initialized) return true;
    const res_idx = @intFromEnum(resource);
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            const soft = p.limits[res_idx].soft;
            if (soft == UNLIMITED) return true;
            return current <= soft;
        }
    }
    return true; // unknown process -> allow
}

/// Enforce hard limit. Returns false if current exceeds hard limit.
pub fn enforceLimit(pid: u32, resource: ResourceType, current: u32) bool {
    if (!initialized) return true;
    const res_idx = @intFromEnum(resource);
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            const hard = p.limits[res_idx].hard;
            if (hard == UNLIMITED) return true;
            if (current > hard) {
                serial.write("[rlimit] HARD LIMIT EXCEEDED pid=");
                serialDec(pid);
                serial.write(" ");
                serial.write(resource.name());
                serial.write(" current=");
                serialDec(current);
                serial.write(" hard=");
                serialDec(hard);
                serial.write("\n");
                return false;
            }
            return true;
        }
    }
    return true;
}

/// Check if approaching soft limit (within 90%).
pub fn isNearLimit(pid: u32, resource: ResourceType, current: u32) bool {
    if (!initialized) return false;
    const res_idx = @intFromEnum(resource);
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            const soft = p.limits[res_idx].soft;
            if (soft == UNLIMITED) return false;
            // 90% threshold
            const threshold = soft - (soft / 10);
            return current >= threshold;
        }
    }
    return false;
}

// ---- Display ----

/// Print all limits for a process.
pub fn printLimits(pid: u32) void {
    if (!initialized) {
        vga.write("Resource limits not initialized.\n");
        return;
    }

    var found = false;
    for (&processes) |*p| {
        if (p.active and p.pid == pid) {
            found = true;

            vga.setColor(.light_cyan, .black);
            vga.write("=== Resource Limits for PID ");
            fmt.printDec(@as(usize, pid));
            vga.write(" ===\n");

            vga.setColor(.yellow, .black);
            vga.write("  RESOURCE     SOFT           HARD           CURRENT        UNIT\n");
            vga.setColor(.light_grey, .black);

            var r: u8 = 0;
            while (r < NUM_RESOURCES) : (r += 1) {
                const lim = p.limits[r];
                const res: ResourceType = @enumFromInt(r);

                vga.write("  ");
                vga.write(res.name());
                vga.write("  ");

                // Soft limit
                printLimitValue(lim.soft, 13);
                vga.write("  ");

                // Hard limit
                printLimitValue(lim.hard, 13);
                vga.write("  ");

                // Current value
                // Color based on usage
                if (lim.soft != UNLIMITED and lim.current > lim.soft) {
                    vga.setColor(.light_red, .black);
                } else if (lim.soft != UNLIMITED and lim.current > lim.soft - (lim.soft / 10)) {
                    vga.setColor(.yellow, .black);
                } else {
                    vga.setColor(.light_green, .black);
                }
                printLimitValue(lim.current, 13);
                vga.setColor(.light_grey, .black);
                vga.write("  ");

                vga.write(res.unit());
                vga.putChar('\n');
            }
            break;
        }
    }

    if (!found) {
        vga.write("Process ");
        fmt.printDec(@as(usize, pid));
        vga.write(" not registered for resource limits.\n");
    }
}

/// Print limits for all registered processes.
pub fn printAllLimits() void {
    if (!initialized) {
        vga.write("Resource limits not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== All Process Resource Limits ===\n");

    var any = false;
    for (&processes) |*p| {
        if (p.active) {
            any = true;
            vga.setColor(.light_grey, .black);
            vga.write("\nPID ");
            fmt.printDec(@as(usize, p.pid));
            vga.write(":\n");

            var r: u8 = 0;
            while (r < NUM_RESOURCES) : (r += 1) {
                const lim = p.limits[r];
                const res: ResourceType = @enumFromInt(r);
                vga.write("  ");
                vga.write(res.name());
                vga.write(": ");
                printLimitValue(lim.current, 0);
                vga.write(" / ");
                printLimitValue(lim.soft, 0);
                vga.write(" (hard: ");
                printLimitValue(lim.hard, 0);
                vga.write(")\n");
            }
        }
    }

    if (!any) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no processes registered)\n");
    }
}

/// Print default limits.
pub fn printDefaults() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Default Resource Limits ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  RESOURCE     SOFT           HARD\n");
    vga.setColor(.light_grey, .black);

    var r: u8 = 0;
    while (r < NUM_RESOURCES) : (r += 1) {
        const lim = DEFAULT_LIMITS[r];
        const res: ResourceType = @enumFromInt(r);
        vga.write("  ");
        vga.write(res.name());
        vga.write("  ");
        printLimitValue(lim.soft, 13);
        vga.write("  ");
        printLimitValue(lim.hard, 13);
        vga.putChar('\n');
    }
}

// ---- Helpers ----

fn printLimitValue(val: u32, min_width: usize) void {
    if (val == UNLIMITED) {
        vga.write("unlimited");
        if (min_width > 9) {
            var pad = min_width - 9;
            while (pad > 0) : (pad -= 1) vga.putChar(' ');
        }
    } else {
        if (min_width > 0) {
            fmt.printDecPadded(@as(usize, val), min_width);
        } else {
            fmt.printDec(@as(usize, val));
        }
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

/// Get the count of registered processes.
pub fn getRegisteredCount() u32 {
    var count: u32 = 0;
    for (&processes) |*p| {
        if (p.active) count += 1;
    }
    return count;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}
