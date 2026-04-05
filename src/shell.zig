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
const framebuf = @import("framebuf.zig");
const acpi = @import("acpi.zig");
const fmt = @import("fmt.zig");
const env = @import("env.zig");
const keyboard = @import("keyboard.zig");
const smp = @import("smp.zig");
const dns = @import("dns.zig");
const ext2 = @import("ext2.zig");
const uhci = @import("uhci.zig");
const blkdev = @import("blkdev.zig");
const cmos = @import("cmos.zig");
const timer = @import("timer.zig");
const log = @import("log.zig");
const version = @import("version.zig");

const MAX_INPUT = 256;
var input_buf: [MAX_INPUT]u8 = undefined;
var input_len: usize = 0;

// コマンド履歴
const HISTORY_SIZE = 8;
var history: [HISTORY_SIZE][MAX_INPUT]u8 = undefined;
var history_lens: [HISTORY_SIZE]usize = [_]usize{0} ** HISTORY_SIZE;
var history_count: usize = 0;
var history_pos: usize = 0; // 現在の閲覧位置
var history_browsing: bool = false;

// 最後に alloc したアドレスを記録
var last_page_alloc: ?usize = null;
var last_heap_alloc: ?[*]u8 = null;

pub fn init() void {
    input_len = 0;
    history_count = 0;
    history_browsing = false;
    printPrompt();
}

fn addHistory(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const idx = history_count % HISTORY_SIZE;
    @memcpy(history[idx][0..cmd.len], cmd);
    history_lens[idx] = cmd.len;
    history_count += 1;
    history_browsing = false;
}

fn clearInputLine() void {
    // 現在の入力を消去
    while (input_len > 0) {
        input_len -= 1;
        vga.backspace();
    }
}

fn setInput(s: []const u8) void {
    clearInputLine();
    const len = @min(s.len, MAX_INPUT - 1);
    @memcpy(input_buf[0..len], s[0..len]);
    input_len = len;
    vga.write(input_buf[0..input_len]);
}

pub fn handleKey(char: u8) void {
    switch (char) {
        '\n' => {
            vga.putChar('\n');
            if (input_len > 0) {
                addHistory(input_buf[0..input_len]);
                // 環境変数展開
                var expanded: [256]u8 = undefined;
                const exp_len = env.expand(input_buf[0..input_len], &expanded);
                execute(expanded[0..exp_len]);
            }
            input_len = 0;
            history_browsing = false;
            printPrompt();
        },
        8 => { // backspace
            if (input_len > 0) {
                input_len -= 1;
                vga.backspace();
            }
        },
        12 => { // Ctrl+L → clear
            vga.init();
            printPrompt();
        },
        keyboard.KEY_UP => { // 上矢印 → 履歴を遡る
            if (history_count > 0) {
                if (!history_browsing) {
                    history_pos = history_count;
                    history_browsing = true;
                }
                if (history_pos > 0) {
                    history_pos -= 1;
                    const idx = history_pos % HISTORY_SIZE;
                    setInput(history[idx][0..history_lens[idx]]);
                }
            }
        },
        keyboard.KEY_DOWN => { // 下矢印 → 履歴を進む
            if (history_browsing) {
                if (history_pos + 1 < history_count) {
                    history_pos += 1;
                    const idx = history_pos % HISTORY_SIZE;
                    setInput(history[idx][0..history_lens[idx]]);
                } else {
                    history_pos = history_count;
                    clearInputLine();
                }
            }
        },
        else => {
            // 特殊キーは無視
            if (char >= 0x80) return;
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
    vga.putChar(':');
    vga.setColor(.light_blue, .black);
    var path_buf: [128]u8 = undefined;
    const plen = ramfs.getCwdPath(&path_buf);
    vga.write(path_buf[0..plen]);
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
    } else if (eql(cmd, "mkdir")) {
        cmdMkdir(args);
    } else if (eql(cmd, "cd")) {
        cmdCd(args);
    } else if (eql(cmd, "pwd")) {
        cmdPwd();
    } else if (eql(cmd, "fork")) {
        cmdFork();
    } else if (eql(cmd, "kill")) {
        cmdKill(args);
    } else if (eql(cmd, "acpi")) {
        cmdAcpi();
    } else if (eql(cmd, "shutdown")) {
        cmdShutdown();
    } else if (eql(cmd, "smp")) {
        cmdSmp();
    } else if (eql(cmd, "dns")) {
        cmdDns(args);
    } else if (eql(cmd, "ext2")) {
        cmdExt2();
    } else if (eql(cmd, "usb")) {
        cmdUsb();
    } else if (eql(cmd, "blk")) {
        cmdBlk();
    } else if (eql(cmd, "gui")) {
        cmdGui();
    } else if (eql(cmd, "echo")) {
        cmdEcho(args);
    } else if (eql(cmd, "env")) {
        cmdEnv();
    } else if (eql(cmd, "set")) {
        cmdSet(args);
    } else if (eql(cmd, "sysinfo")) {
        cmdSysinfo();
    } else if (eql(cmd, "hexdump")) {
        cmdHexdump(args);
    } else if (eql(cmd, "sleep")) {
        cmdSleep(args);
    } else if (eql(cmd, "history")) {
        cmdHistory();
    } else if (eql(cmd, "cmos")) {
        cmdCmos();
    } else if (eql(cmd, "timers")) {
        cmdTimers();
    } else if (eql(cmd, "version")) {
        cmdVersion();
    } else if (eql(cmd, "log")) {
        cmdLog(args);
    } else if (eql(cmd, "benchmark")) {
        cmdBenchmark();
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
    vga.write("  mkdir <d> - Create directory\n");
    vga.write("  cd <d>  - Change directory\n");
    vga.write("  pwd     - Print working directory\n");
    vga.write("  fork    - Fork test (parent+child)\n");
    vga.write("  kill <pid> - Kill process\n");
    vga.write("  reboot  - Reboot system\n");
    vga.write("  acpi    - ACPI info\n");
    vga.write("  shutdown - ACPI shutdown\n");
    vga.write("  smp     - CPU/SMP info\n");
    vga.write("  dns <h> - DNS resolve\n");
    vga.write("  ext2    - ext2 filesystem info\n");
    vga.write("  usb     - USB controller info\n");
    vga.write("  blk     - Block devices\n");
    vga.write("  gui     - Graphics demo (Mode 13h)\n");
    vga.write("  echo <t> - Print text\n");
    vga.write("  env     - Environment variables\n");
    vga.write("  set <k>=<v> - Set env variable\n");
    vga.write("  sysinfo - System information\n");
    vga.write("  hexdump <f> - Hex dump of file\n");
    vga.write("  sleep <ms> - Sleep milliseconds\n");
    vga.write("  history - Command history\n");
    vga.write("  cmos    - CMOS/RTC info\n");
    vga.write("  timers  - Active timers\n");
    vga.write("  version - Kernel version\n");
    vga.write("  log <l> - Set log level\n");
    vga.write("  benchmark - Memory benchmark\n");
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

fn cmdMkdir(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: mkdir <name>\n");
        return;
    }
    if (ramfs.mkdir(args)) {
        vga.setColor(.light_green, .black);
        vga.write("Created directory: ");
        vga.write(args);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Failed to create directory\n");
    }
}

fn cmdCd(args: []const u8) void {
    if (args.len == 0) {
        _ = ramfs.chdir("/");
        return;
    }
    if (!ramfs.chdir(args)) {
        vga.setColor(.light_red, .black);
        vga.write("No such directory: ");
        vga.write(args);
        vga.putChar('\n');
    }
}

fn cmdPwd() void {
    var buf: [128]u8 = undefined;
    const len = ramfs.getCwdPath(&buf);
    vga.write(buf[0..len]);
    vga.putChar('\n');
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

// ---- Milestone 2 コマンド ----

fn cmdAcpi() void {
    acpi.printInfo();
}

fn cmdShutdown() void {
    vga.setColor(.yellow, .black);
    vga.write("Shutting down...\n");
    acpi.shutdown();
}

fn cmdSmp() void {
    smp.printInfo();
}

fn cmdDns(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: dns <hostname>\n");
        return;
    }
    if (!e1000.isInitialized()) {
        vga.setColor(.light_red, .black);
        vga.write("No network interface\n");
        return;
    }
    vga.setColor(.light_grey, .black);
    vga.write("Resolving ");
    vga.write(args);
    vga.write("...\n");
    if (dns.resolve(args)) |ip| {
        vga.setColor(.light_green, .black);
        vga.write("  IP: ");
        pmm.printNum((ip >> 24) & 0xFF);
        vga.putChar('.');
        pmm.printNum((ip >> 16) & 0xFF);
        vga.putChar('.');
        pmm.printNum((ip >> 8) & 0xFF);
        vga.putChar('.');
        pmm.printNum(ip & 0xFF);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  Resolution failed\n");
    }
}

fn cmdExt2() void {
    ext2.printInfo();
    if (ext2.isValid()) {
        vga.setColor(.yellow, .black);
        vga.write("Root directory:\n");
        vga.setColor(.light_grey, .black);
        ext2.listRoot();
    }
}

fn cmdUsb() void {
    uhci.printInfo();
}

fn cmdBlk() void {
    blkdev.printDevices();
}

fn cmdEcho(args: []const u8) void {
    vga.write(args);
    vga.putChar('\n');
}

fn cmdEnv() void {
    env.printAll();
}

fn cmdSet(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: set KEY=VALUE\n");
        return;
    }
    if (fmt.indexOf(args, '=')) |eq_pos| {
        const key = args[0..eq_pos];
        const val = if (eq_pos + 1 < args.len) args[eq_pos + 1 ..] else "";
        if (env.set(key, val)) {
            vga.setColor(.light_green, .black);
            vga.write(key);
            vga.putChar('=');
            vga.write(val);
            vga.putChar('\n');
        } else {
            vga.setColor(.light_red, .black);
            vga.write("Failed to set variable\n");
        }
    } else {
        vga.write("Usage: set KEY=VALUE\n");
    }
}

fn cmdSysinfo() void {
    vga.setColor(.light_cyan, .black);
    vga.write("        ___       \n");
    vga.write("       /   \\      ");
    vga.setColor(.white, .black);
    vga.write(user.getCurrentName());
    vga.putChar('@');
    if (env.get("HOSTNAME")) |h| vga.write(h);
    vga.putChar('\n');

    vga.setColor(.light_cyan, .black);
    vga.write("      |  Z  |     ");
    vga.setColor(.light_grey, .black);
    vga.write("OS:      ");
    if (env.get("OS")) |v| vga.write(v);
    vga.putChar('\n');

    vga.setColor(.light_cyan, .black);
    vga.write("      |     |     ");
    vga.setColor(.light_grey, .black);
    vga.write("Kernel:  Zig Kernel v");
    if (env.get("VERSION")) |v| vga.write(v);
    vga.putChar('\n');

    vga.setColor(.light_cyan, .black);
    vga.write("       \\___/      ");
    vga.setColor(.light_grey, .black);
    vga.write("Shell:   ");
    if (env.get("SHELL")) |v| vga.write(v);
    vga.putChar('\n');

    vga.setColor(.light_cyan, .black);
    vga.write("                  ");
    vga.setColor(.light_grey, .black);
    vga.write("Term:    ");
    if (env.get("TERM")) |v| vga.write(v);
    vga.putChar('\n');

    vga.write("                  Uptime:  ");
    pit.printUptime();

    vga.write("                  Memory:  ");
    pmm.printNum(pmm.freeCount() * 4);
    vga.write("KB / ");
    pmm.printNum(pmm.totalCount() * 4);
    vga.write("KB\n");

    vga.write("                  CPU:     x86 (");
    pmm.printNum(smp.getCpuCount());
    vga.write(" core)\n");

    vga.write("                  Net:     ");
    if (e1000.isInitialized()) {
        fmt.printMac(e1000.mac);
    } else {
        vga.write("none");
    }
    vga.putChar('\n');

    // カラーパレット
    vga.write("                  ");
    inline for (0..8) |c| {
        vga.setColor(@enumFromInt(c), @enumFromInt(c));
        vga.write("  ");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');
    vga.write("                  ");
    inline for (8..16) |c| {
        vga.setColor(@enumFromInt(c), @enumFromInt(c));
        vga.write("  ");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');
}

fn cmdHexdump(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: hexdump <filename>\n");
        return;
    }
    if (ramfs.findByName(args)) |idx| {
        if (ramfs.getFile(idx)) |f| {
            fmt.hexdump(f.data[0..f.size], 0);
        }
    } else {
        vga.setColor(.light_red, .black);
        vga.write("File not found: ");
        vga.write(args);
        vga.putChar('\n');
    }
}

fn cmdSleep(args: []const u8) void {
    if (args.len == 0) {
        vga.write("Usage: sleep <ms>\n");
        return;
    }
    const ms = fmt.parseU32(args) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Invalid number\n");
        return;
    };
    vga.setColor(.light_grey, .black);
    vga.write("Sleeping ");
    pmm.printNum(ms);
    vga.write("ms...\n");
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < ms) {
        asm volatile ("hlt");
    }
    vga.setColor(.light_green, .black);
    vga.write("Done.\n");
}

fn cmdHistory() void {
    vga.setColor(.yellow, .black);
    vga.write("Command History:\n");
    vga.setColor(.light_grey, .black);
    const start = if (history_count > HISTORY_SIZE) history_count - HISTORY_SIZE else 0;
    var i = start;
    while (i < history_count) : (i += 1) {
        const idx = i % HISTORY_SIZE;
        vga.write("  ");
        pmm.printNum(i + 1);
        vga.write("  ");
        vga.write(history[idx][0..history_lens[idx]]);
        vga.putChar('\n');
    }
}

fn cmdGui() void {
    vga.setColor(.light_grey, .black);
    vga.write("Switching to graphics mode...\n");
    framebuf.demo();
    // キー入力待ち → テキストモードに戻る (次のキーボード IRQ で)
    // hlt で待機し、次のキー入力で戻る
    asm volatile ("sti; hlt");
    framebuf.exitMode13h();
    vga.init();
    vga.setColor(.light_green, .black);
    vga.write("Returned to text mode.\n");
}

fn cmdCmos() void {
    cmos.printInfo();
}

fn cmdTimers() void {
    timer.printTimers();
}

fn cmdVersion() void {
    version.printVersion();
}

fn cmdLog(args: []const u8) void {
    if (args.len == 0) {
        log.printStatus();
        vga.setColor(.light_grey, .black);
        vga.write("Usage: log <debug|info|warn|err|fatal>\n");
        return;
    }
    if (log.parseLevel(args)) |level| {
        log.setLevel(level);
        vga.setColor(.light_green, .black);
        vga.write("Log level set to: ");
        vga.write(level.name());
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Invalid log level: ");
        vga.write(args);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
        vga.write("Valid levels: debug, info, warn, err, fatal\n");
    }
}

fn cmdBenchmark() void {
    timer.benchmark("memory_rw", &timer.memBenchmark);
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
