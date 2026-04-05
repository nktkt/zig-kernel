// POSIX-compatible error number definitions
//
// Provides a common Error enum, per-task last-error tracking, and
// human-readable error strings.  Mirrors the subset of POSIX errnos
// most relevant to a minimal kernel.

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Error enum (POSIX-compatible values) ----

pub const Error = enum(u16) {
    SUCCESS = 0,
    EPERM = 1, // Operation not permitted
    ENOENT = 2, // No such file or directory
    ESRCH = 3, // No such process
    EINTR = 4, // Interrupted system call
    EIO = 5, // I/O error
    ENXIO = 6, // No such device or address
    E2BIG = 7, // Argument list too long
    ENOEXEC = 8, // Exec format error
    EBADF = 9, // Bad file descriptor
    ECHILD = 10, // No child processes
    EDEADLK = 11, // Resource deadlock avoided
    ENOMEM = 12, // Out of memory
    EACCES = 13, // Permission denied
    EFAULT = 14, // Bad address
    EBUSY = 16, // Device or resource busy
    EEXIST = 17, // File exists
    EXDEV = 18, // Cross-device link
    ENODEV = 19, // No such device
    ENOTDIR = 20, // Not a directory
    EISDIR = 21, // Is a directory
    EINVAL = 22, // Invalid argument
    ENFILE = 23, // Too many open files in system
    EMFILE = 24, // Too many open files
    ENOTTY = 25, // Inappropriate ioctl for device
    EFBIG = 27, // File too large
    ENOSPC = 28, // No space left on device
    ESPIPE = 29, // Illegal seek
    EROFS = 30, // Read-only file system
    EMLINK = 31, // Too many links
    EPIPE = 32, // Broken pipe
    EDOM = 33, // Numerical argument out of domain
    ERANGE = 34, // Result too large
    EAGAIN = 35, // Resource temporarily unavailable
    ETIMEDOUT = 60, // Connection timed out
    ECONNREFUSED = 61, // Connection refused
    ENOSYS = 78, // Function not implemented
};

// ---- Human-readable error strings ----

/// Return a descriptive string for the given error code.
pub fn strerror(err: Error) []const u8 {
    return switch (err) {
        .SUCCESS => "Success",
        .EPERM => "Operation not permitted",
        .ENOENT => "No such file or directory",
        .ESRCH => "No such process",
        .EINTR => "Interrupted system call",
        .EIO => "Input/output error",
        .ENXIO => "No such device or address",
        .E2BIG => "Argument list too long",
        .ENOEXEC => "Exec format error",
        .EBADF => "Bad file descriptor",
        .ECHILD => "No child processes",
        .EDEADLK => "Resource deadlock avoided",
        .ENOMEM => "Cannot allocate memory",
        .EACCES => "Permission denied",
        .EFAULT => "Bad address",
        .EBUSY => "Device or resource busy",
        .EEXIST => "File exists",
        .EXDEV => "Invalid cross-device link",
        .ENODEV => "No such device",
        .ENOTDIR => "Not a directory",
        .EISDIR => "Is a directory",
        .EINVAL => "Invalid argument",
        .ENFILE => "Too many open files in system",
        .EMFILE => "Too many open files",
        .ENOTTY => "Inappropriate ioctl for device",
        .EFBIG => "File too large",
        .ENOSPC => "No space left on device",
        .ESPIPE => "Illegal seek",
        .EROFS => "Read-only file system",
        .EMLINK => "Too many links",
        .EPIPE => "Broken pipe",
        .EDOM => "Numerical argument out of domain",
        .ERANGE => "Numerical result out of range",
        .EAGAIN => "Resource temporarily unavailable",
        .ETIMEDOUT => "Connection timed out",
        .ECONNREFUSED => "Connection refused",
        .ENOSYS => "Function not implemented",
    };
}

/// Convert a raw integer to an Error, returning EINVAL for unknown values.
pub fn fromInt(val: u16) Error {
    return switch (val) {
        0 => .SUCCESS,
        1 => .EPERM,
        2 => .ENOENT,
        3 => .ESRCH,
        4 => .EINTR,
        5 => .EIO,
        6 => .ENXIO,
        7 => .E2BIG,
        8 => .ENOEXEC,
        9 => .EBADF,
        10 => .ECHILD,
        11 => .EDEADLK,
        12 => .ENOMEM,
        13 => .EACCES,
        14 => .EFAULT,
        16 => .EBUSY,
        17 => .EEXIST,
        18 => .EXDEV,
        19 => .ENODEV,
        20 => .ENOTDIR,
        21 => .EISDIR,
        22 => .EINVAL,
        23 => .ENFILE,
        24 => .EMFILE,
        25 => .ENOTTY,
        27 => .EFBIG,
        28 => .ENOSPC,
        29 => .ESPIPE,
        30 => .EROFS,
        31 => .EMLINK,
        32 => .EPIPE,
        33 => .EDOM,
        34 => .ERANGE,
        35 => .EAGAIN,
        60 => .ETIMEDOUT,
        61 => .ECONNREFUSED,
        78 => .ENOSYS,
        else => .EINVAL,
    };
}

// ---- Per-task errno tracking ----

const MAX_TASKS = 64;
var task_errno: [MAX_TASKS]Error = [_]Error{.SUCCESS} ** MAX_TASKS;

/// Set the error for the current task (by PID).
pub fn setErrno(err: Error) void {
    const pid = getCurrentPid();
    if (pid < MAX_TASKS) {
        task_errno[pid] = err;
    }
}

/// Get the error for the current task.
pub fn getErrno() Error {
    const pid = getCurrentPid();
    if (pid < MAX_TASKS) {
        return task_errno[pid];
    }
    return .EINVAL;
}

/// Set errno for a specific task by PID.
pub fn setErrnoForTask(pid: usize, err: Error) void {
    if (pid < MAX_TASKS) {
        task_errno[pid] = err;
    }
}

/// Get errno for a specific task by PID.
pub fn getErrnoForTask(pid: usize) Error {
    if (pid < MAX_TASKS) {
        return task_errno[pid];
    }
    return .EINVAL;
}

/// Clear all per-task errno values.
pub fn clearAll() void {
    for (&task_errno) |*e| {
        e.* = .SUCCESS;
    }
}

/// Get current PID (stub -- returns 0 for kernel task).
/// In a full kernel this would call task.currentPid().
fn getCurrentPid() usize {
    return 0;
}

// ---- Display helpers ----

/// Print "msg: error string\n" to VGA.
pub fn printError(msg: []const u8) void {
    const err = getErrno();
    vga.setColor(.light_red, .black);
    vga.write(msg);
    vga.write(": ");
    vga.write(strerror(err));
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

/// Print "msg: error string\n" using a specific error.
pub fn printErrorCode(msg: []const u8, err: Error) void {
    vga.setColor(.light_red, .black);
    vga.write(msg);
    vga.write(": ");
    vga.write(strerror(err));
    vga.write(" (");
    printDec(@intFromEnum(err));
    vga.write(")\n");
    vga.setColor(.light_grey, .black);
}

/// Print all non-SUCCESS task errnos (for debugging).
pub fn printTaskErrors() void {
    vga.setColor(.yellow, .black);
    vga.write("Per-task errno:\n");
    vga.setColor(.light_grey, .black);
    var any = false;
    for (task_errno, 0..) |e, i| {
        if (e != .SUCCESS) {
            vga.write("  PID ");
            printDec(i);
            vga.write(": ");
            vga.write(strerror(e));
            vga.write(" (");
            printDec(@intFromEnum(e));
            vga.write(")\n");
            any = true;
        }
    }
    if (!any) {
        vga.write("  (all clear)\n");
    }
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
