// 簡易シェル — コマンドライン入力と実行

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const heap = @import("heap.zig");
const paging = @import("paging.zig");
const rtc = @import("rtc.zig");
const serial = @import("serial.zig");
const task = @import("task.zig");
const idt = @import("idt.zig");
const ramfs = @import("ramfs.zig");
const pci = @import("pci.zig");
const ata = @import("ata.zig");
const fat16 = @import("fat16.zig");
const e1000 = @import("e1000.zig");
const net = @import("net.zig");
const vfs = @import("vfs.zig");
const elf = @import("elf.zig");
const user = @import("user.zig");
const tcp = @import("tcp.zig");
const pipe = @import("pipe.zig");

const MAX_INPUT = 256;
var input_buf: [MAX_INPUT]u8 = undefined;
var input_len: usize = 0;

// 最後に alloc したアドレスを記録
var last_page_alloc: ?usize = null;
var last_heap_alloc: ?[*]u8 = null;

pub fn init() void {
    input_len = 0;
    printPrompt();
}

pub fn handleKey(char: u8) void {
    switch (char) {
        '\n' => {
            vga.putChar('\n');
            if (input_len > 0) {
                execute(input_buf[0..input_len]);
            }
            input_len = 0;
            printPrompt();
        },
        8 => { // backspace
            if (input_len > 0) {
                input_len -= 1;
                vga.backspace();
            }
        },
        else => {
            if (input_len < MAX_INPUT - 1) {
                input_buf[input_len] = char;
                input_len += 1;
                vga.putChar(char);
            }
        },
    }
}

fn printPrompt() void {
    vga.setColor(.light_green, .black);
    vga.write(user.getCurrentName());
    vga.setColor(.light_grey, .black);
    vga.putChar('@');
    vga.setColor(.light_cyan, .black);
    vga.write("zig-os");
    vga.setColor(.light_grey, .black);
    if (user.isRoot()) {
        vga.write("# ");
    } else {
        vga.write("$ ");
    }
    vga.setColor(.white, .black);
}

fn execute(input: []const u8) void {
    const full = trim(input);
    if (full.len == 0) return;

    // コマンドと引数を分割
    var split: usize = full.len;
    for (full, 0..) |c, i| {
        if (c == ' ') {
            split = i;
            break;
        }
    }
    const cmd = full[0..split];
    const args = if (split < full.len) trim(full[split + 1 ..]) else "";

    if (eql(cmd, "help")) {
        cmdHelp();
    } else if (eql(cmd, "clear")) {
        cmdClear();
    } else if (eql(cmd, "mem")) {
        cmdMem();
    } else if (eql(cmd, "alloc")) {
        cmdAlloc();
    } else if (eql(cmd, "free")) {
        cmdFree();
    } else if (eql(cmd, "malloc")) {
        cmdMalloc();
    } else if (eql(cmd, "mfree")) {
        cmdMfree();
    } else if (eql(cmd, "heap")) {
        cmdHeap();
    } else if (eql(cmd, "uptime")) {
        cmdUptime();
    } else if (eql(cmd, "ticks")) {
        cmdTicks();
    } else if (eql(cmd, "ps")) {
        cmdPs();
    } else if (eql(cmd, "run")) {
        cmdRun();
    } else if (eql(cmd, "date")) {
        cmdDate();
    } else if (eql(cmd, "paging")) {
        cmdPaging();
    } else if (eql(cmd, "reboot")) {
        cmdReboot();
    } else if (eql(cmd, "ls")) {
        cmdLs();
    } else if (eql(cmd, "cat")) {
        cmdCat(args);
    } else if (eql(cmd, "write")) {
        cmdWrite(args);
    } else if (eql(cmd, "rm")) {
        cmdRm(args);
    } else if (eql(cmd, "lspci")) {
        cmdLspci();
    } else if (eql(cmd, "disk")) {
        cmdDisk();
    } else if (eql(cmd, "net")) {
        cmdNet();
    } else if (eql(cmd, "ping")) {
        cmdPing(args);
    } else if (eql(cmd, "exec")) {
        cmdExec(args);
    } else if (eql(cmd, "whoami")) {
        cmdWhoami();
    } else if (eql(cmd, "users")) {
        cmdUsers();
    } else if (eql(cmd, "su")) {
        cmdSu(args);
    } else if (eql(cmd, "touch")) {
        cmdTouch(args);
    } else if (eql(cmd, "cp")) {
        cmdCp(args);
    } else if (eql(cmd, "dwrite")) {
        cmdDwrite(args);
    } else if (eql(cmd, "stat")) {
        cmdStat(args);
    } else if (eql(cmd, "pipe")) {
        cmdPipe();
    } else if (eql(cmd, "tcp")) {
        cmdTcp(args);
    } else if (eql(cmd, "fork")) {
        cmdFork();
    } else if (eql(cmd, "kill")) {
        cmdKill(args);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Unknown command: ");
        vga.write(cmd);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
        vga.write("Type 'help' for available commands.\n");
    }
    vga.setColor(.white, .black);
}

// ---- コマンド実装 ----

fn cmdHelp() void {
    vga.setColor(.yellow, .black);
    vga.write("Available commands:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  help    - Show this message\n");
    vga.write("  clear   - Clear the screen\n");
    vga.write("  mem     - Physical memory status\n");
    vga.write("  heap    - Heap allocator status\n");
    vga.write("  alloc   - Allocate a 4KB page\n");
    vga.write("  free    - Free last allocated page\n");
    vga.write("  malloc  - Allocate 64 bytes\n");
    vga.write("  mfree   - Free last heap alloc\n");
    vga.write("  uptime  - System uptime\n");
    vga.write("  ticks   - Raw tick count\n");
    vga.write("  date    - Current date/time\n");
    vga.write("  paging  - Paging status\n");
    vga.write("  ps      - List tasks\n");
    vga.write("  run     - Spawn user tasks\n");
    vga.write("  ls      - List files (ramfs)\n");
    vga.write("  cat <f> - Show file contents\n");
    vga.write("  write <f> <text> - Create/write file\n");
    vga.write("  rm <f>  - Remove file\n");
    vga.write("  lspci   - List PCI devices\n");
    vga.write("  disk    - Disk (ATA) info\n");
    vga.write("  net     - Network status\n");
    vga.write("  ping <ip> - Send ICMP ping\n");
    vga.write("  exec <f>  - Load & run ELF/program\n");
    vga.write("  whoami  - Current user\n");
    vga.write("  users   - List users\n");
    vga.write("  su <user> - Switch user\n");
    vga.write("  touch <f> - Create empty file\n");
    vga.write("  cp <s> <d> - Copy file\n");
    vga.write("  dwrite <f> <txt> - Write to disk\n");
    vga.write("  stat <f> - File info\n");
    vga.write("  pipe    - Pipe demo\n");
    vga.write("  tcp <ip:port> - TCP connect\n");
    vga.write("  fork    - Fork test (parent+child)\n");
    vga.write("  kill <pid> - Kill process\n");
    vga.write("  reboot  - Reboot system\n");
}

fn cmdClear() void {
    vga.init();
}

fn cmdMem() void {
    pmm.printStatus();
}

fn cmdHeap() void {
    heap.printStatus();
}

fn cmdAlloc() void {
    if (pmm.alloc()) |addr| {
        last_page_alloc = addr;
        vga.setColor(.light_green, .black);
        vga.write("Allocated page at 0x");
        printHex(addr);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Out of memory!\n");
    }
}

fn cmdFree() void {
    if (last_page_alloc) |addr| {
        pmm.free(addr);
        vga.setColor(.light_green, .black);
        vga.write("Freed page at 0x");
        printHex(addr);
        vga.putChar('\n');
        last_page_alloc = null;
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Nothing to free.\n");
    }
}

fn cmdMalloc() void {
    if (heap.alloc(64)) |ptr| {
        last_heap_alloc = ptr;
        vga.setColor(.light_green, .black);
        vga.write("Allocated 64 bytes at 0x");
        printHex(@intFromPtr(ptr));
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Heap allocation failed!\n");
    }
}

fn cmdMfree() void {
    if (last_heap_alloc) |ptr| {
        heap.free(ptr);
        vga.setColor(.light_green, .black);
        vga.write("Freed heap allocation at 0x");
        printHex(@intFromPtr(ptr));
        vga.putChar('\n');
        last_heap_alloc = null;
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Nothing to free.\n");
    }
}

fn cmdUptime() void {
    pit.printUptime();
}

fn cmdTicks() void {
    vga.setColor(.light_grey, .black);
    vga.write("Ticks: ");
    pmm.printNum(@truncate(pit.getTicks()));
    vga.putChar('\n');
}

fn cmdPs() void {
    task.printTaskList();
}

fn cmdRun() void {
    vga.setColor(.light_grey, .black);
    vga.write("Spawning user tasks...\n");
    if (task.createUserTask(@intFromPtr(&task.userProgramHello), "hello")) |pid| {
        vga.setColor(.light_green, .black);
        vga.write("Created task 'hello' (pid=");
        pmm.printNum(pid);
        vga.write(")\n");
    }
    if (task.createUserTask(@intFromPtr(&task.userProgramCounter), "counter")) |pid| {
        vga.setColor(.light_green, .black);
        vga.write("Created task 'counter' (pid=");
        pmm.printNum(pid);
        vga.write(")\n");
    }
    vga.setColor(.yellow, .black);
    vga.write("Tasks scheduled. Use 'ps' to view.\n");
    vga.setColor(.white, .black);
    task.enableScheduling();
}

fn cmdDate() void {
    rtc.printDateTime();
}

fn cmdPaging() void {
    paging.printStatus();
}

fn cmdReboot() void {
    vga.setColor(.yellow, .black);
    vga.write("Rebooting...\n");
    idt.outb(0x64, 0xFE);
}

// ---- ファイルシステムコマンド ----

fn cmdLs() void {
    ramfs.printList();
}

fn cmdCat(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: cat <filename>\n");
        return;
    }
    // FAT16ディスクのファイル
    if (startsWith(args, "/disk/")) {
        const fname = args[6..];
        var buf: [2048]u8 = undefined;
        if (fat16.readFile(fname, &buf)) |len| {
            vga.write(buf[0..len]);
        } else {
            vga.setColor(.light_red, .black);
            vga.write("File not found on disk: ");
            vga.write(fname);
            vga.putChar('\n');
        }
        return;
    }
    if (ramfs.findByName(args)) |idx| {
        if (ramfs.getFile(idx)) |f| {
            vga.write(f.data[0..f.size]);
        }
    } else {
        vga.setColor(.light_red, .black);
        vga.write("File not found: ");
        vga.write(args);
        vga.putChar('\n');
    }
}

fn cmdWrite(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: write <filename> <text>\n");
        return;
    }
    // ファイル名とテキストを分割
    var sp: usize = args.len;
    for (args, 0..) |c, i| {
        if (c == ' ') {
            sp = i;
            break;
        }
    }
    if (sp >= args.len) {
        vga.write("Usage: write <filename> <text>\n");
        return;
    }
    const name = args[0..sp];
    const text = trim(args[sp + 1 ..]);

    const idx = ramfs.findByName(name) orelse ramfs.create(name) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Cannot create file (max reached)\n");
        return;
    };
    const written = ramfs.writeFile(idx, text);
    vga.setColor(.light_green, .black);
    vga.write("Wrote ");
    pmm.printNum(written);
    vga.write(" bytes to ");
    vga.write(name);
    vga.putChar('\n');
}

fn cmdRm(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: rm <filename>\n");
        return;
    }
    if (ramfs.findByName(args)) |idx| {
        ramfs.remove(idx);
        vga.setColor(.light_green, .black);
        vga.write("Removed: ");
        vga.write(args);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("File not found: ");
        vga.write(args);
        vga.putChar('\n');
    }
}

// ---- PCI / Disk / Network コマンド ----

fn cmdLspci() void {
    pci.printDevices();
}

fn cmdDisk() void {
    if (ata.isPresent()) {
        vga.setColor(.light_green, .black);
        vga.write("ATA Primary Master: detected\n");
        vga.setColor(.light_grey, .black);
        fat16.printInfo();
    } else {
        vga.setColor(.light_red, .black);
        vga.write("No ATA disk detected.\n");
        vga.setColor(.light_grey, .black);
        vga.write("Start QEMU with: -hda disk.img\n");
    }
}

fn cmdNet() void {
    if (!e1000.isInitialized()) {
        vga.setColor(.light_red, .black);
        vga.write("No network interface.\n");
        vga.setColor(.light_grey, .black);
        vga.write("Start QEMU with: -device e1000,netdev=n0 -netdev user,id=n0\n");
        return;
    }
    net.printStatus();
}

fn cmdPing(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: ping <ip>\n");
        return;
    }
    if (!e1000.isInitialized()) {
        vga.setColor(.light_red, .black);
        vga.write("No network interface.\n");
        return;
    }
    const ip = net.parseIp(args) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Invalid IP address\n");
        return;
    };
    net.ping(ip);
}

// ---- Phase 2 コマンド ----

fn cmdExec(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: exec <filename>\n");
        return;
    }
    _ = elf.exec(args);
}

fn cmdWhoami() void {
    vga.setColor(.light_green, .black);
    vga.write(user.getCurrentName());
    vga.putChar('\n');
}

fn cmdUsers() void {
    user.printUsers();
}

fn cmdSu(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: su <username>\n");
        return;
    }
    // パスワード入力は省略 (簡易実装)
    if (user.switchUser(args, args)) {
        vga.setColor(.light_green, .black);
        vga.write("Switched to ");
        vga.write(args);
        vga.putChar('\n');
    } else {
        // パスワードなし (root) でも試行
        if (user.switchUser(args, "")) {
            vga.setColor(.light_green, .black);
            vga.write("Switched to ");
            vga.write(args);
            vga.putChar('\n');
        } else {
            vga.setColor(.light_red, .black);
            vga.write("Authentication failed\n");
        }
    }
}

fn cmdTouch(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: touch <filename>\n");
        return;
    }
    if (ramfs.findByName(args) != null) {
        vga.write("File already exists\n");
        return;
    }
    if (ramfs.create(args) != null) {
        vga.setColor(.light_green, .black);
        vga.write("Created: ");
        vga.write(args);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Failed to create file\n");
    }
}

fn cmdCp(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: cp <src> <dst>\n");
        return;
    }
    var sp: usize = args.len;
    for (args, 0..) |c, i| {
        if (c == ' ') { sp = i; break; }
    }
    if (sp >= args.len) {
        vga.write("Usage: cp <src> <dst>\n");
        return;
    }
    const src = args[0..sp];
    const dst = trim(args[sp + 1 ..]);

    const src_idx = ramfs.findByName(src) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Source not found\n");
        return;
    };
    const file = ramfs.getFile(src_idx) orelse return;
    const dst_idx = ramfs.findByName(dst) orelse ramfs.create(dst) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Cannot create destination\n");
        return;
    };
    _ = ramfs.writeFile(dst_idx, file.data[0..file.size]);
    vga.setColor(.light_green, .black);
    vga.write("Copied ");
    vga.write(src);
    vga.write(" -> ");
    vga.write(dst);
    vga.putChar('\n');
}

fn cmdDwrite(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: dwrite <filename> <text>\n");
        return;
    }
    if (!ata.isPresent() or !fat16.isInitialized()) {
        vga.setColor(.light_red, .black);
        vga.write("No disk available\n");
        return;
    }
    var sp: usize = args.len;
    for (args, 0..) |c, i| {
        if (c == ' ') { sp = i; break; }
    }
    if (sp >= args.len) {
        vga.write("Usage: dwrite <filename> <text>\n");
        return;
    }
    const fname = args[0..sp];
    const text = trim(args[sp + 1 ..]);
    if (fat16.writeFile(fname, text)) {
        vga.setColor(.light_green, .black);
        vga.write("Written to disk: ");
        vga.write(fname);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Disk write failed\n");
    }
}

fn cmdStat(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: stat <filename>\n");
        return;
    }
    if (vfs.stat(args)) |s| {
        vga.setColor(.light_grey, .black);
        vga.write("  File: ");
        vga.write(args);
        vga.write("\n  Size: ");
        pmm.printNum(s.size);
        vga.write(" bytes\n  Type: ");
        switch (s.kind) {
            .file => vga.write("regular file"),
            .directory => vga.write("directory"),
            .pipe => vga.write("pipe"),
            .socket => vga.write("socket"),
        }
        vga.write("\n  Perm: 0");
        pmm.printNum(s.permissions >> 6 & 7);
        pmm.printNum(s.permissions >> 3 & 7);
        pmm.printNum(s.permissions & 7);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Not found: ");
        vga.write(args);
        vga.putChar('\n');
    }
}

fn cmdPipe() void {
    vga.setColor(.light_grey, .black);
    vga.write("Pipe demo: writing and reading...\n");
    if (vfs.openPipe()) |fds| {
        const msg = "Hello through pipe!";
        _ = vfs.write(fds[1], msg);
        var buf: [64]u8 = undefined;
        if (vfs.read(fds[0], &buf)) |n| {
            vga.setColor(.light_green, .black);
            vga.write("  Received: ");
            vga.write(buf[0..n]);
            vga.putChar('\n');
        }
        vfs.close(fds[0]);
        vfs.close(fds[1]);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Failed to create pipe\n");
    }
}

fn cmdTcp(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: tcp <ip:port>\n");
        return;
    }
    if (!e1000.isInitialized()) {
        vga.setColor(.light_red, .black);
        vga.write("No network interface\n");
        return;
    }
    // ip:port を分割
    var colon: usize = args.len;
    for (args, 0..) |c, i| {
        if (c == ':') { colon = i; break; }
    }
    if (colon >= args.len) {
        vga.write("Usage: tcp <ip:port>\n");
        return;
    }
    const ip = net.parseIp(args[0..colon]) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Invalid IP\n");
        return;
    };
    const port = parseU16(args[colon + 1 ..]) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Invalid port\n");
        return;
    };
    vga.setColor(.light_grey, .black);
    vga.write("Connecting to ");
    vga.write(args);
    vga.write("...\n");
    if (tcp.connect(ip, port, 12345)) |conn| {
        vga.setColor(.light_green, .black);
        vga.write("Connected! Sending data...\n");
        _ = tcp.send(conn, "GET / HTTP/1.0\r\nHost: test\r\n\r\n");

        var buf: [256]u8 = undefined;
        const n = tcp.recv(conn, &buf);
        if (n > 0) {
            vga.setColor(.light_cyan, .black);
            vga.write(buf[0..n]);
            vga.putChar('\n');
        }
        tcp.close(conn);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Connection failed\n");
    }
}

fn cmdFork() void {
    vga.setColor(.light_grey, .black);
    vga.write("Spawning fork test task...\n");
    if (task.createUserTask(@intFromPtr(&task.userProgramForkTest), "forktest")) |pid| {
        vga.setColor(.light_green, .black);
        vga.write("Created fork test (pid=");
        pmm.printNum(pid);
        vga.write(")\n");
        task.enableScheduling();
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Failed to create task\n");
    }
}

fn cmdKill(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: kill <pid>\n");
        return;
    }
    const pid = parseU16(args) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Invalid PID\n");
        return;
    };
    if (task.sendSignal(pid, task.SIG_KILL)) {
        vga.setColor(.light_green, .black);
        vga.write("Killed pid ");
        pmm.printNum(pid);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Process not found\n");
    }
}

fn parseU16(s: []const u8) ?u16 {
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
        if (val > 65535) return null;
    }
    if (s.len == 0) return null;
    return @truncate(val);
}

// ---- ユーティリティ ----

fn printHex(val: usize) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') : (end -= 1) {}
    return s[start..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}
