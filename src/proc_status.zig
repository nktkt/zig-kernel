// Process status reporting — /proc/[pid]/status equivalent
//
// Generates per-process status information including name, state, PID, memory
// usage, CPU time, and I/O statistics. Similar to reading /proc/[pid]/status
// on Linux.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const task = @import("task.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_TRACKED_PROCS: usize = 16;
const STATUS_BUF_SIZE: usize = 512;

// ============================================================
// Types
// ============================================================

pub const ProcessMemInfo = struct {
    vm_size: u32 = 0, // Virtual memory size in bytes
    vm_rss: u32 = 0, // Resident set size in bytes
    vm_data: u32 = 0, // Data segment size
    vm_stack: u32 = 0, // Stack size
    page_faults: u32 = 0,
};

pub const ProcessCpuTime = struct {
    user_ticks: u64 = 0, // Ticks in user mode
    system_ticks: u64 = 0, // Ticks in kernel mode
    start_tick: u64 = 0, // Tick when process started
    last_scheduled: u64 = 0, // Last time this process was scheduled
};

pub const ProcessIoStats = struct {
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    read_ops: u32 = 0,
    write_ops: u32 = 0,
    cancelled_write_bytes: u64 = 0,
};

pub const ProcessInfo = struct {
    pid: u32 = 0,
    ppid: u32 = 0,
    uid: u16 = 0,
    gid: u16 = 0,
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,
    state: u8 = 0, // TaskState as u8
    threads: u8 = 1,
    sig_pending: u32 = 0,
    sig_blocked: u32 = 0,
    cap_effective: u32 = 0,
    mem: ProcessMemInfo = .{},
    cpu: ProcessCpuTime = .{},
    io: ProcessIoStats = .{},
    valid: bool = false,
};

// ============================================================
// State — per-process extended info
// ============================================================

var proc_info: [MAX_TRACKED_PROCS]ProcessInfo = [_]ProcessInfo{.{}} ** MAX_TRACKED_PROCS;

// ============================================================
// Public API
// ============================================================

/// Initialize tracking for a process.
pub fn initProcess(pid: u32) void {
    const idx = findOrAllocSlot(pid);
    if (idx == null) return;
    const i = idx.?;

    proc_info[i].pid = pid;
    proc_info[i].valid = true;
    proc_info[i].cpu.start_tick = pit.getTicks();
    proc_info[i].threads = 1;

    // Try to read task info
    syncFromTask(pid, &proc_info[i]);
}

/// Remove tracking for a process.
pub fn removeProcess(pid: u32) void {
    for (&proc_info) |*p| {
        if (p.valid and p.pid == pid) {
            p.valid = false;
            return;
        }
    }
}

/// Get process status text in a buffer. Returns the number of bytes written.
pub fn getStatus(pid: u32, buf: []u8) ?usize {
    const info = findInfo(pid);
    if (info == null) return null;
    const p = info.?;

    var pos: usize = 0;

    // Name
    pos = writeField(buf, pos, "Name:\t");
    pos = writeSlice(buf, pos, p.name[0..p.name_len]);
    pos = writeChar(buf, pos, '\n');

    // State
    pos = writeField(buf, pos, "State:\t");
    pos = writeSlice(buf, pos, stateString(p.state));
    pos = writeChar(buf, pos, '\n');

    // Pid, PPid
    pos = writeField(buf, pos, "Pid:\t");
    pos = writeDec(buf, pos, p.pid);
    pos = writeChar(buf, pos, '\n');

    pos = writeField(buf, pos, "PPid:\t");
    pos = writeDec(buf, pos, p.ppid);
    pos = writeChar(buf, pos, '\n');

    // Uid, Gid
    pos = writeField(buf, pos, "Uid:\t");
    pos = writeDec(buf, pos, p.uid);
    pos = writeChar(buf, pos, '\n');

    pos = writeField(buf, pos, "Gid:\t");
    pos = writeDec(buf, pos, p.gid);
    pos = writeChar(buf, pos, '\n');

    // Memory
    pos = writeField(buf, pos, "VmSize:\t");
    pos = writeDec(buf, pos, p.mem.vm_size / 1024);
    pos = writeSlice(buf, pos, " kB\n");

    pos = writeField(buf, pos, "VmRSS:\t");
    pos = writeDec(buf, pos, p.mem.vm_rss / 1024);
    pos = writeSlice(buf, pos, " kB\n");

    pos = writeField(buf, pos, "VmData:\t");
    pos = writeDec(buf, pos, p.mem.vm_data / 1024);
    pos = writeSlice(buf, pos, " kB\n");

    pos = writeField(buf, pos, "VmStk:\t");
    pos = writeDec(buf, pos, p.mem.vm_stack / 1024);
    pos = writeSlice(buf, pos, " kB\n");

    // Threads
    pos = writeField(buf, pos, "Threads:\t");
    pos = writeDec(buf, pos, p.threads);
    pos = writeChar(buf, pos, '\n');

    // Signals
    pos = writeField(buf, pos, "SigPnd:\t");
    pos = writeHex32(buf, pos, p.sig_pending);
    pos = writeChar(buf, pos, '\n');

    pos = writeField(buf, pos, "SigBlk:\t");
    pos = writeHex32(buf, pos, p.sig_blocked);
    pos = writeChar(buf, pos, '\n');

    // Capabilities
    pos = writeField(buf, pos, "CapEff:\t");
    pos = writeHex32(buf, pos, p.cap_effective);
    pos = writeChar(buf, pos, '\n');

    return pos;
}

/// Get memory info for a process.
pub fn getMemInfo(pid: u32) ?ProcessMemInfo {
    const info = findInfo(pid);
    if (info == null) return null;
    return info.?.mem;
}

/// Get CPU time for a process.
pub fn getCpuTime(pid: u32) ?ProcessCpuTime {
    const info = findInfo(pid);
    if (info == null) return null;
    return info.?.cpu;
}

/// Get I/O stats for a process.
pub fn getIoStats(pid: u32) ?ProcessIoStats {
    const info = findInfo(pid);
    if (info == null) return null;
    return info.?.io;
}

/// Record CPU time for a process.
pub fn recordUserTick(pid: u32) void {
    if (findInfoMut(pid)) |p| {
        p.cpu.user_ticks += 1;
        p.cpu.last_scheduled = pit.getTicks();
    }
}

/// Record kernel CPU time.
pub fn recordSystemTick(pid: u32) void {
    if (findInfoMut(pid)) |p| {
        p.cpu.system_ticks += 1;
        p.cpu.last_scheduled = pit.getTicks();
    }
}

/// Record I/O operation.
pub fn recordRead(pid: u32, bytes: u32) void {
    if (findInfoMut(pid)) |p| {
        p.io.read_bytes += bytes;
        p.io.read_ops += 1;
    }
}

/// Record write I/O.
pub fn recordWrite(pid: u32, bytes: u32) void {
    if (findInfoMut(pid)) |p| {
        p.io.write_bytes += bytes;
        p.io.write_ops += 1;
    }
}

/// Record memory usage.
pub fn updateMemInfo(pid: u32, vm_size: u32, vm_rss: u32) void {
    if (findInfoMut(pid)) |p| {
        p.mem.vm_size = vm_size;
        p.mem.vm_rss = vm_rss;
    }
}

/// Record page fault.
pub fn recordPageFault(pid: u32) void {
    if (findInfoMut(pid)) |p| {
        p.mem.page_faults += 1;
    }
}

/// Set signal state.
pub fn setSignals(pid: u32, pending: u32, blocked: u32) void {
    if (findInfoMut(pid)) |p| {
        p.sig_pending = pending;
        p.sig_blocked = blocked;
    }
}

/// Set capabilities.
pub fn setCapabilities(pid: u32, cap_eff: u32) void {
    if (findInfoMut(pid)) |p| {
        p.cap_effective = cap_eff;
    }
}

// ============================================================
// Display
// ============================================================

/// Print status for a process to VGA.
pub fn printStatus(pid: u32) void {
    const info = findInfo(pid);
    if (info == null) {
        vga.write("Process not found: PID ");
        printDecVga(pid);
        vga.putChar('\n');
        return;
    }
    const p = info.?;

    vga.setColor(.yellow, .black);
    vga.write("Process Status (PID ");
    printDecVga(p.pid);
    vga.write("):\n");
    vga.setColor(.light_grey, .black);

    // Name and state
    vga.write("  Name:      ");
    vga.write(p.name[0..p.name_len]);
    vga.putChar('\n');
    vga.write("  State:     ");
    vga.write(stateString(p.state));
    vga.putChar('\n');
    vga.write("  PPid:      ");
    printDecVga(p.ppid);
    vga.putChar('\n');
    vga.write("  Uid/Gid:   ");
    printDecVga(p.uid);
    vga.putChar('/');
    printDecVga(p.gid);
    vga.putChar('\n');

    // Memory
    vga.write("  VmSize:    ");
    printDecVga(p.mem.vm_size / 1024);
    vga.write(" kB\n");
    vga.write("  VmRSS:     ");
    printDecVga(p.mem.vm_rss / 1024);
    vga.write(" kB\n");
    vga.write("  VmData:    ");
    printDecVga(p.mem.vm_data / 1024);
    vga.write(" kB\n");
    vga.write("  VmStack:   ");
    printDecVga(p.mem.vm_stack / 1024);
    vga.write(" kB\n");
    vga.write("  PageFaults:");
    printDecVga(p.mem.page_faults);
    vga.putChar('\n');

    // CPU
    const now = pit.getTicks();
    const uptime_secs = (now -| p.cpu.start_tick) / 1000;
    vga.write("  UserTime:  ");
    printDecVga(@truncate(p.cpu.user_ticks));
    vga.write(" ticks\n");
    vga.write("  SysTime:   ");
    printDecVga(@truncate(p.cpu.system_ticks));
    vga.write(" ticks\n");
    vga.write("  Runtime:   ");
    printDecVga(@truncate(uptime_secs));
    vga.write(" sec\n");

    // I/O
    vga.write("  ReadBytes: ");
    printDecVga(@truncate(p.io.read_bytes));
    vga.putChar('\n');
    vga.write("  WriteBytes:");
    printDecVga(@truncate(p.io.write_bytes));
    vga.putChar('\n');
    vga.write("  ReadOps:   ");
    printDecVga(p.io.read_ops);
    vga.putChar('\n');
    vga.write("  WriteOps:  ");
    printDecVga(p.io.write_ops);
    vga.putChar('\n');

    // Threads
    vga.write("  Threads:   ");
    printDecVga(p.threads);
    vga.putChar('\n');

    // Signals
    vga.write("  SigPnd:    0x");
    fmt.printHex32(p.sig_pending);
    vga.putChar('\n');
    vga.write("  SigBlk:    0x");
    fmt.printHex32(p.sig_blocked);
    vga.putChar('\n');
    vga.write("  CapEff:    0x");
    fmt.printHex32(p.cap_effective);
    vga.putChar('\n');
}

/// Print summary of all tracked processes.
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("Process Status Summary:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  PID  PPID  State       Name          VmRSS   CPU(ticks)\n");
    vga.write("  ---  ----  ----------  ------------  ------  ----------\n");

    var found = false;
    for (&proc_info) |*p| {
        if (!p.valid) continue;
        found = true;

        vga.write("  ");
        printDecPaddedVga(p.pid, 3);
        vga.write("  ");
        printDecPaddedVga(p.ppid, 4);
        vga.write("  ");
        printStringPadded(stateString(p.state), 10);
        vga.write("  ");
        printStringPadded(p.name[0..p.name_len], 12);
        vga.write("  ");
        printDecPaddedVga(p.mem.vm_rss / 1024, 4);
        vga.write("kB");
        vga.write("  ");
        printDecPaddedVga(p.cpu.user_ticks + p.cpu.system_ticks, 10);
        vga.putChar('\n');
    }

    if (!found) {
        vga.write("  (no processes tracked)\n");
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn findInfo(pid: u32) ?*const ProcessInfo {
    for (&proc_info) |*p| {
        if (p.valid and p.pid == pid) return p;
    }
    return null;
}

fn findInfoMut(pid: u32) ?*ProcessInfo {
    for (&proc_info) |*p| {
        if (p.valid and p.pid == pid) return p;
    }
    return null;
}

fn findOrAllocSlot(pid: u32) ?usize {
    // Look for existing
    for (&proc_info, 0..) |*p, i| {
        if (p.valid and p.pid == pid) return i;
    }
    // Find free
    for (&proc_info, 0..) |*p, i| {
        if (!p.valid) return i;
    }
    return null;
}

fn syncFromTask(pid: u32, p: *ProcessInfo) void {
    // Read task data from the task module if available
    if (task.getTask(pid)) |ti| {
        p.ppid = ti.ppid;
        p.state = @intFromEnum(ti.state);
        p.name_len = ti.name_len;
        @memcpy(p.name[0..ti.name_len], ti.name[0..ti.name_len]);
    }
}

fn stateString(state: u8) []const u8 {
    return switch (state) {
        0 => "unused",
        1 => "ready",
        2 => "running",
        3 => "waiting",
        4 => "terminated",
        5 => "zombie",
        else => "unknown",
    };
}

// ---- Buffer write helpers ----

fn writeField(buf: []u8, pos: usize, field: []const u8) usize {
    if (pos + field.len > buf.len) return pos;
    @memcpy(buf[pos..][0..field.len], field);
    return pos + field.len;
}

fn writeSlice(buf: []u8, pos: usize, data: []const u8) usize {
    if (pos + data.len > buf.len) return pos;
    @memcpy(buf[pos..][0..data.len], data);
    return pos + data.len;
}

fn writeChar(buf: []u8, pos: usize, c: u8) usize {
    if (pos >= buf.len) return pos;
    buf[pos] = c;
    return pos + 1;
}

fn writeDec(buf: []u8, pos: usize, n: anytype) usize {
    const val: u64 = @intCast(n);
    if (val == 0) {
        return writeChar(buf, pos, '0');
    }
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        tmp[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    var p = pos;
    while (len > 0) {
        len -= 1;
        p = writeChar(buf, p, tmp[len]);
    }
    return p;
}

fn writeHex32(buf: []u8, pos: usize, val: u32) usize {
    const hex = "0123456789abcdef";
    var p = pos;
    var v = val;
    var digits: [8]u8 = undefined;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        digits[i] = hex[@truncate(v & 0xF)];
        v >>= 4;
    }
    for (digits) |d| {
        p = writeChar(buf, p, d);
    }
    return p;
}

// ---- VGA print helpers ----

fn printDecVga(n: anytype) void {
    const val: u64 = @intCast(n);
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
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

fn printDecPaddedVga(n: anytype, width: usize) void {
    const val: u64 = @intCast(n);
    var digits: usize = 0;
    var tmp = val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    var pad = if (digits < width) width - digits else 0;
    while (pad > 0) : (pad -= 1) {
        vga.putChar(' ');
    }
    printDecVga(val);
}

fn printStringPadded(s: []const u8, width: usize) void {
    vga.write(s);
    var col = s.len;
    while (col < width) : (col += 1) {
        vga.putChar(' ');
    }
}
