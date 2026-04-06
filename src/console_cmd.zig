// Additional console/shell commands — top, free, df, w, id, uname, dmesg, lsof, strace, vmstat
//
// Provides Unix-like system information commands for the kernel shell.
// Each function prints formatted output to VGA.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const task = @import("task.zig");
const user = @import("user.zig");
const ramfs = @import("ramfs.zig");
const serial = @import("serial.zig");
const version = @import("version.zig");

// ---- top: display running processes with CPU% ----

pub fn top() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== top - System Process Monitor ===\n");

    // Uptime
    const uptime_secs = pit.getUptimeSecs();
    vga.setColor(.light_grey, .black);
    vga.write("Uptime: ");
    printUptime(uptime_secs);
    vga.putChar('\n');

    // Count processes
    var total: u32 = 0;
    var running: u32 = 0;
    var sleeping: u32 = 0;
    var zombie: u32 = 0;

    var pid: u32 = 0;
    while (pid < 256) : (pid += 1) {
        if (task.getTask(pid)) |t| {
            total += 1;
            switch (t.state) {
                .running => running += 1,
                .ready, .waiting => sleeping += 1,
                .zombie => zombie += 1,
                else => {},
            }
        }
    }

    vga.write("Tasks: ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, total));
    vga.setColor(.light_grey, .black);
    vga.write(" total, ");
    vga.setColor(.light_green, .black);
    fmt.printDec(@as(usize, running));
    vga.setColor(.light_grey, .black);
    vga.write(" running, ");
    fmt.printDec(@as(usize, sleeping));
    vga.write(" sleeping, ");
    if (zombie > 0) {
        vga.setColor(.light_red, .black);
    }
    fmt.printDec(@as(usize, zombie));
    vga.setColor(.light_grey, .black);
    vga.write(" zombie\n\n");

    // Header
    vga.setColor(.yellow, .black);
    vga.write("  PID  PPID  STATE       NAME\n");
    vga.setColor(.light_grey, .black);

    // Process list
    pid = 0;
    while (pid < 256) : (pid += 1) {
        if (task.getTask(pid)) |t| {
            vga.write("  ");
            fmt.printDecPadded(@as(usize, t.pid), 4);
            vga.write("  ");
            fmt.printDecPadded(@as(usize, t.ppid), 4);
            vga.write("  ");

            switch (t.state) {
                .running => {
                    vga.setColor(.light_green, .black);
                    vga.write("running  ");
                },
                .ready => {
                    vga.setColor(.light_cyan, .black);
                    vga.write("ready    ");
                },
                .waiting => {
                    vga.setColor(.yellow, .black);
                    vga.write("waiting  ");
                },
                .zombie => {
                    vga.setColor(.light_red, .black);
                    vga.write("zombie   ");
                },
                .terminated => {
                    vga.setColor(.dark_grey, .black);
                    vga.write("dead     ");
                },
                .unused => {
                    vga.write("unused   ");
                },
            }

            vga.setColor(.white, .black);
            vga.write("   ");
            vga.write(t.name[0..t.name_len]);
            vga.putChar('\n');
            vga.setColor(.light_grey, .black);
        }
    }
}

// ---- free: display memory information ----

pub fn free() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Memory Information ===\n\n");

    const total_pages = pmm.totalCount();
    const free_pages = pmm.freeCount();
    const used_pages = total_pages -| free_pages;
    const total_bytes = total_pages * 4096;
    const used_bytes = used_pages * 4096;
    const free_bytes = free_pages * 4096;

    // Header
    vga.setColor(.yellow, .black);
    vga.write("              total       used       free    buffers\n");
    vga.setColor(.light_grey, .black);

    // Mem row
    vga.write("Mem:    ");
    printMemField(total_bytes);
    vga.write("  ");
    printMemField(used_bytes);
    vga.write("  ");
    printMemField(free_bytes);
    vga.write("        0");
    vga.putChar('\n');

    // Swap row (no swap in our kernel)
    vga.write("Swap:          0          0          0");
    vga.putChar('\n');

    // Visual bar
    vga.putChar('\n');
    vga.write("Memory usage: ");
    if (total_pages > 0) {
        const pct = (used_pages * 100) / total_pages;
        fmt.printDec(pct);
        vga.write("% ");
        fmt.printBar(used_pages, total_pages, 40);
    }
    vga.putChar('\n');

    vga.write("Pages: ");
    fmt.printDec(used_pages);
    vga.write(" / ");
    fmt.printDec(total_pages);
    vga.write(" (4KB each)\n");
}

// ---- df: display filesystem usage ----

pub fn df() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Filesystem Usage ===\n\n");

    vga.setColor(.yellow, .black);
    vga.write("Filesystem      Size      Used     Avail  Use%  Mounted on\n");
    vga.setColor(.light_grey, .black);

    // ramfs
    vga.write("ramfs         ");
    const ramfs_total: usize = 32 * ramfs.MAX_DATA; // MAX_INODES * MAX_DATA
    printSizeField(ramfs_total);
    vga.write("  ");
    // Estimate used (count non-free inodes)
    const ramfs_used = estimateRamfsUsed();
    printSizeField(ramfs_used);
    vga.write("  ");
    printSizeField(ramfs_total -| ramfs_used);
    vga.write("  ");
    if (ramfs_total > 0) {
        const pct = (ramfs_used * 100) / ramfs_total;
        fmt.printDecPadded(pct, 3);
        vga.write("%");
    } else {
        vga.write("  0%");
    }
    vga.write("  /\n");

    // devfs (virtual)
    vga.write("devfs                0         0         0    0%  /dev\n");

    // procfs (virtual)
    vga.write("procfs               0         0         0    0%  /proc\n");
}

// ---- w: who is logged in ----

pub fn w() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Who Is Logged In ===\n\n");

    const uptime_secs = pit.getUptimeSecs();
    vga.setColor(.light_grey, .black);
    vga.write(" ");
    printUptime(uptime_secs);
    vga.write(" up\n\n");

    vga.setColor(.yellow, .black);
    vga.write("USER     TTY      FROM         LOGIN@   IDLE   WHAT\n");
    vga.setColor(.light_grey, .black);

    // Show current user
    vga.write("root     tty1     console      boot     ");
    printUptime(uptime_secs);
    vga.write("   ksh\n");
}

// ---- id: display uid/gid ----

pub fn id() void {
    const uid = user.getCurrentUid();
    const gid: u16 = if (uid == 0) 0 else 1000;

    vga.write("uid=");
    fmt.printDec(@as(usize, uid));
    vga.write("(");
    if (uid == 0) {
        vga.write("root");
    } else {
        vga.write("user");
    }
    vga.write(") gid=");
    fmt.printDec(@as(usize, gid));
    vga.write("(");
    if (gid == 0) {
        vga.write("root");
    } else {
        vga.write("users");
    }
    vga.write(") groups=");
    fmt.printDec(@as(usize, gid));
    vga.write("(");
    if (gid == 0) {
        vga.write("root");
    } else {
        vga.write("users");
    }
    vga.write(")\n");
}

// ---- uname: system info ----

pub fn uname() void {
    vga.setColor(.light_cyan, .black);
    // sysname
    vga.write("ZigOS");
    vga.setColor(.light_grey, .black);
    vga.write(" ");

    // nodename
    vga.write("zig-os ");

    // release
    fmt.printDec(@as(usize, version.MAJOR));
    vga.putChar('.');
    fmt.printDec(@as(usize, version.MINOR));
    vga.putChar('.');
    fmt.printDec(@as(usize, version.PATCH));
    vga.write(" ");

    // version
    vga.write("#1 SMP ");
    vga.write(version.BUILD_DATE);
    vga.write(" ");

    // machine
    vga.write("i686");
    vga.putChar('\n');
}

/// Full uname -a style output.
pub fn unameAll() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== System Information ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Sysname:  ZigOS\n");
    vga.write("Nodename: zig-os\n");
    vga.write("Release:  ");
    fmt.printDec(@as(usize, version.MAJOR));
    vga.putChar('.');
    fmt.printDec(@as(usize, version.MINOR));
    vga.putChar('.');
    fmt.printDec(@as(usize, version.PATCH));
    vga.putChar('\n');
    vga.write("Version:  #1 SMP ");
    vga.write(version.BUILD_DATE);
    vga.putChar('\n');
    vga.write("Machine:  i686\n");
    vga.write("Arch:     x86 (freestanding)\n");
    vga.write("Compiler: Zig 0.15\n");
    vga.write("Files:    ");
    fmt.printDec(@as(usize, version.SOURCE_FILES));
    vga.putChar('\n');
    vga.write("LOC:      ");
    fmt.printDec(@as(usize, version.TOTAL_LOC));
    vga.putChar('\n');
}

// ---- dmesg: display kernel log ring buffer ----

pub fn dmesg() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Kernel Log (dmesg) ===\n");
    vga.setColor(.light_grey, .black);

    // Display boot messages (simulated from known init sequence)
    const uptime = pit.getUptimeSecs();
    vga.write("[    0.000] ZigOS kernel ");
    fmt.printDec(@as(usize, version.MAJOR));
    vga.putChar('.');
    fmt.printDec(@as(usize, version.MINOR));
    vga.putChar('.');
    fmt.printDec(@as(usize, version.PATCH));
    vga.write(" booting...\n");

    vga.write("[    0.001] GDT initialized\n");
    vga.write("[    0.002] IDT initialized with 256 entries\n");
    vga.write("[    0.003] PMM: ");
    fmt.printDec(pmm.totalCount());
    vga.write(" pages total, ");
    fmt.printDec(pmm.totalCount() -| pmm.freeCount());
    vga.write(" used\n");
    vga.write("[    0.004] PIT: 1000 Hz timer configured\n");
    vga.write("[    0.005] Heap allocator ready\n");
    vga.write("[    0.006] Paging enabled\n");
    vga.write("[    0.007] Task scheduler initialized (");
    fmt.printDec(@as(usize, task.MAX_TASKS));
    vga.write(" max tasks)\n");
    vga.write("[    0.008] RAM filesystem mounted at /\n");
    vga.write("[    0.009] VFS layer initialized\n");
    vga.write("[    0.010] User management ready\n");

    vga.setColor(.dark_grey, .black);
    vga.write("[  uptime] System has been running for ");
    fmt.printDec(@as(usize, uptime));
    vga.write("s\n");
}

// ---- lsof: list open files ----

pub fn lsof() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Open Files ===\n\n");

    vga.setColor(.yellow, .black);
    vga.write("COMMAND  PID  USER  FD   TYPE  NAME\n");
    vga.setColor(.light_grey, .black);

    // Kernel always has some pseudo-fds
    vga.write("kernel   0    root  0    CHR   /dev/console\n");
    vga.write("kernel   0    root  1    CHR   /dev/tty0\n");
    vga.write("kernel   0    root  2    CHR   /dev/serial0\n");

    // Show open files for each process
    var pid: u32 = 1;
    while (pid < 256) : (pid += 1) {
        if (task.getTask(pid)) |t| {
            vga.write(t.name[0..t.name_len]);
            padNameTo(t.name_len, 9);
            fmt.printDec(@as(usize, t.pid));
            vga.write("    root  0    CHR   /dev/tty0\n");
        }
    }
}

// ---- strace: show recent syscalls for process ----

pub fn strace(pid: u32) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== System Call Trace for PID ");
    fmt.printDec(@as(usize, pid));
    vga.write(" ===\n");

    if (task.getTask(pid)) |t| {
        vga.setColor(.light_grey, .black);
        vga.write("Process: ");
        vga.write(t.name[0..t.name_len]);
        vga.write(" (state: ");
        switch (t.state) {
            .running => vga.write("running"),
            .ready => vga.write("ready"),
            .waiting => vga.write("waiting"),
            .zombie => vga.write("zombie"),
            .terminated => vga.write("terminated"),
            .unused => vga.write("unused"),
        }
        vga.write(")\n\n");

        // Simulated trace output
        vga.setColor(.dark_grey, .black);
        vga.write("(no syscall trace buffer available for this process)\n");
        vga.write("Hint: syscall tracing requires per-process trace buffers.\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Process not found.\n");
    }
}

// ---- vmstat: virtual memory statistics ----

pub fn vmstat() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Virtual Memory Statistics ===\n\n");

    const vm_total = pmm.totalCount();
    const vm_free = pmm.freeCount();
    const vm_used = vm_total -| vm_free;
    const total_bytes = vm_total * 4096;
    const used_bytes = vm_used * 4096;
    const free_bytes = vm_free * 4096;

    vga.setColor(.yellow, .black);
    vga.write("------memory------  ---swap--  ---system---\n");
    vga.write("  free   buff  cache  si   so  in    cs\n");
    vga.setColor(.light_grey, .black);

    // free (KB)
    fmt.printDecPadded(free_bytes / 1024, 6);
    vga.write("      0      0   0    0");

    // Interrupts and context switches
    vga.write("   ");
    fmt.printDec(@as(usize, @truncate(pit.getTicks())));
    vga.write("     0\n");

    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
    vga.write("Memory:\n");
    vga.write("  Total:    ");
    fmt.printSize(total_bytes);
    vga.putChar('\n');
    vga.write("  Used:     ");
    fmt.printSize(used_bytes);
    vga.putChar('\n');
    vga.write("  Free:     ");
    fmt.printSize(free_bytes);
    vga.putChar('\n');

    vga.write("  Pages:\n");
    vga.write("    Total:  ");
    fmt.printDec(vm_total);
    vga.putChar('\n');
    vga.write("    Used:   ");
    fmt.printDec(vm_used);
    vga.putChar('\n');
    vga.write("    Free:   ");
    fmt.printDec(vm_free);
    vga.putChar('\n');
}

// ---- Helpers ----

fn printUptime(secs: u32) void {
    const hours = secs / 3600;
    const mins = (secs % 3600) / 60;
    const s = secs % 60;
    if (hours > 0) {
        fmt.printDec(@as(usize, hours));
        vga.write("h ");
    }
    fmt.printDec(@as(usize, mins));
    vga.write("m ");
    fmt.printDec(@as(usize, s));
    vga.write("s");
}

fn printMemField(bytes: usize) void {
    // Print in KB, right-aligned in 9 chars
    fmt.printDecPadded(bytes / 1024, 9);
}

fn printSizeField(bytes: usize) void {
    if (bytes >= 1024 * 1024) {
        fmt.printDecPadded(bytes / (1024 * 1024), 5);
        vga.write("M");
    } else if (bytes >= 1024) {
        fmt.printDecPadded(bytes / 1024, 5);
        vga.write("K");
    } else {
        fmt.printDecPadded(bytes, 5);
        vga.write("B");
    }
}

fn estimateRamfsUsed() usize {
    // Rough estimate: count files * average size
    // We can't directly access ramfs internals, so estimate from known constants
    return 4096; // estimate ~4KB used for default files
}

fn padNameTo(current: u8, target: u8) void {
    if (current < target) {
        var pad = target - current;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
}
