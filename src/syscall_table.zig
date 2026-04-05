// システムコールテーブル — 全 syscall の登録・参照・検証

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- システムコール番号 ----

pub const SYS_EXIT = 0;
pub const SYS_WRITE = 1;
pub const SYS_GETPID = 2;
pub const SYS_YIELD = 3;
pub const SYS_SLEEP = 4;
pub const SYS_FORK = 5;
pub const SYS_WAIT = 6;
pub const SYS_KILL = 7;
pub const SYS_GETPPID = 8;
pub const SYS_OPEN = 9;
pub const SYS_READ = 10;
pub const SYS_CLOSE = 11;
pub const SYS_FWRITE = 12;
pub const SYS_STAT = 13;
pub const SYS_LSEEK = 14;
pub const SYS_DUP = 15;
pub const SYS_DUP2 = 16;
pub const SYS_PIPE = 17;
pub const SYS_MKDIR = 18;
pub const SYS_RMDIR = 19;
pub const SYS_CHDIR = 20;
pub const SYS_GETCWD = 21;
pub const SYS_UNLINK = 22;
pub const SYS_RENAME = 23;
pub const SYS_CHMOD = 24;
pub const SYS_GETUID = 25;
pub const SYS_SETUID = 26;
pub const SYS_GETGID = 27;
pub const SYS_TIME = 28;
pub const SYS_BRK = 29;
pub const SYS_MMAP = 30;
pub const SYS_MUNMAP = 31;
pub const SYS_SOCKET = 32;
pub const SYS_BIND = 33;
pub const SYS_LISTEN = 34;
pub const SYS_ACCEPT = 35;
pub const SYS_CONNECT = 36;
pub const SYS_SEND = 37;
pub const SYS_RECV = 38;
pub const SYS_SHUTDOWN = 39;

pub const SYSCALL_COUNT = 40;

// ---- ハンドラ関数型 ----

pub const HandlerFn = *const fn (u32, u32, u32) u32;

// ---- SyscallEntry ----

pub const SyscallEntry = struct {
    number: u8,
    name: []const u8,
    description: []const u8,
    handler: ?HandlerFn,
    arg_count: u8,
    implemented: bool,
};

// ---- テーブル定義 ----

const syscall_table: [SYSCALL_COUNT]SyscallEntry = .{
    // 0: exit
    .{
        .number = SYS_EXIT,
        .name = "exit",
        .description = "Terminate process with status code",
        .handler = null,
        .arg_count = 1,
        .implemented = true,
    },
    // 1: write
    .{
        .number = SYS_WRITE,
        .name = "write",
        .description = "Write buffer to file descriptor",
        .handler = null,
        .arg_count = 3,
        .implemented = true,
    },
    // 2: getpid
    .{
        .number = SYS_GETPID,
        .name = "getpid",
        .description = "Get current process ID",
        .handler = null,
        .arg_count = 0,
        .implemented = true,
    },
    // 3: yield
    .{
        .number = SYS_YIELD,
        .name = "yield",
        .description = "Yield CPU to another process",
        .handler = null,
        .arg_count = 0,
        .implemented = true,
    },
    // 4: sleep
    .{
        .number = SYS_SLEEP,
        .name = "sleep",
        .description = "Sleep for specified milliseconds",
        .handler = null,
        .arg_count = 1,
        .implemented = true,
    },
    // 5: fork
    .{
        .number = SYS_FORK,
        .name = "fork",
        .description = "Create child process (copy-on-write)",
        .handler = null,
        .arg_count = 0,
        .implemented = true,
    },
    // 6: wait
    .{
        .number = SYS_WAIT,
        .name = "wait",
        .description = "Wait for child process to terminate",
        .handler = null,
        .arg_count = 0,
        .implemented = true,
    },
    // 7: kill
    .{
        .number = SYS_KILL,
        .name = "kill",
        .description = "Send signal to process",
        .handler = null,
        .arg_count = 2,
        .implemented = true,
    },
    // 8: getppid
    .{
        .number = SYS_GETPPID,
        .name = "getppid",
        .description = "Get parent process ID",
        .handler = null,
        .arg_count = 0,
        .implemented = true,
    },
    // 9: open
    .{
        .number = SYS_OPEN,
        .name = "open",
        .description = "Open file by path, return fd",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 10: read
    .{
        .number = SYS_READ,
        .name = "read",
        .description = "Read from file descriptor into buffer",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 11: close
    .{
        .number = SYS_CLOSE,
        .name = "close",
        .description = "Close file descriptor",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 12: fwrite
    .{
        .number = SYS_FWRITE,
        .name = "fwrite",
        .description = "Write buffer to file descriptor",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 13: stat
    .{
        .number = SYS_STAT,
        .name = "stat",
        .description = "Get file status information",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 14: lseek
    .{
        .number = SYS_LSEEK,
        .name = "lseek",
        .description = "Reposition file offset",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 15: dup
    .{
        .number = SYS_DUP,
        .name = "dup",
        .description = "Duplicate file descriptor",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 16: dup2
    .{
        .number = SYS_DUP2,
        .name = "dup2",
        .description = "Duplicate fd to specific number",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 17: pipe
    .{
        .number = SYS_PIPE,
        .name = "pipe",
        .description = "Create unidirectional pipe",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 18: mkdir
    .{
        .number = SYS_MKDIR,
        .name = "mkdir",
        .description = "Create directory",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 19: rmdir
    .{
        .number = SYS_RMDIR,
        .name = "rmdir",
        .description = "Remove empty directory",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 20: chdir
    .{
        .number = SYS_CHDIR,
        .name = "chdir",
        .description = "Change working directory",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 21: getcwd
    .{
        .number = SYS_GETCWD,
        .name = "getcwd",
        .description = "Get current working directory",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 22: unlink
    .{
        .number = SYS_UNLINK,
        .name = "unlink",
        .description = "Delete file by path",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 23: rename
    .{
        .number = SYS_RENAME,
        .name = "rename",
        .description = "Rename file or directory",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 24: chmod
    .{
        .number = SYS_CHMOD,
        .name = "chmod",
        .description = "Change file permissions",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 25: getuid
    .{
        .number = SYS_GETUID,
        .name = "getuid",
        .description = "Get current user ID",
        .handler = null,
        .arg_count = 0,
        .implemented = false,
    },
    // 26: setuid
    .{
        .number = SYS_SETUID,
        .name = "setuid",
        .description = "Set user ID (requires privilege)",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 27: getgid
    .{
        .number = SYS_GETGID,
        .name = "getgid",
        .description = "Get current group ID",
        .handler = null,
        .arg_count = 0,
        .implemented = false,
    },
    // 28: time
    .{
        .number = SYS_TIME,
        .name = "time",
        .description = "Get current Unix timestamp",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 29: brk
    .{
        .number = SYS_BRK,
        .name = "brk",
        .description = "Adjust process data segment size",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
    // 30: mmap
    .{
        .number = SYS_MMAP,
        .name = "mmap",
        .description = "Map memory region",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 31: munmap
    .{
        .number = SYS_MUNMAP,
        .name = "munmap",
        .description = "Unmap memory region",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 32: socket
    .{
        .number = SYS_SOCKET,
        .name = "socket",
        .description = "Create network socket",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 33: bind
    .{
        .number = SYS_BIND,
        .name = "bind",
        .description = "Bind socket to address",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 34: listen
    .{
        .number = SYS_LISTEN,
        .name = "listen",
        .description = "Mark socket as listening",
        .handler = null,
        .arg_count = 2,
        .implemented = false,
    },
    // 35: accept
    .{
        .number = SYS_ACCEPT,
        .name = "accept",
        .description = "Accept incoming connection",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 36: connect
    .{
        .number = SYS_CONNECT,
        .name = "connect",
        .description = "Connect to remote address",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 37: send
    .{
        .number = SYS_SEND,
        .name = "send",
        .description = "Send data on connected socket",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 38: recv
    .{
        .number = SYS_RECV,
        .name = "recv",
        .description = "Receive data from socket",
        .handler = null,
        .arg_count = 3,
        .implemented = false,
    },
    // 39: shutdown
    .{
        .number = SYS_SHUTDOWN,
        .name = "shutdown",
        .description = "Shut down socket communication",
        .handler = null,
        .arg_count = 1,
        .implemented = false,
    },
};

// ---- 公開 API ----

/// syscall 番号から名前を取得
pub fn getSyscallName(num: usize) []const u8 {
    if (num >= SYSCALL_COUNT) return "unknown";
    return syscall_table[num].name;
}

/// syscall 番号から説明を取得
pub fn getSyscallDescription(num: usize) []const u8 {
    if (num >= SYSCALL_COUNT) return "unknown";
    return syscall_table[num].description;
}

/// syscall テーブルの要素数を返す
pub fn getSyscallCount() usize {
    return SYSCALL_COUNT;
}

/// syscall 番号が有効かチェック
pub fn isValid(num: usize) bool {
    return num < SYSCALL_COUNT;
}

/// syscall が実装済みかチェック
pub fn isImplemented(num: usize) bool {
    if (num >= SYSCALL_COUNT) return false;
    return syscall_table[num].implemented;
}

/// syscall の引数個数を取得
pub fn getArgCount(num: usize) u8 {
    if (num >= SYSCALL_COUNT) return 0;
    return syscall_table[num].arg_count;
}

/// syscall エントリを取得
pub fn getEntry(num: usize) ?*const SyscallEntry {
    if (num >= SYSCALL_COUNT) return null;
    return &syscall_table[num];
}

/// ハンドラを登録 (後から外部モジュールが登録可能)
pub fn registerHandler(num: usize, handler: HandlerFn) bool {
    if (num >= SYSCALL_COUNT) return false;
    // comptime テーブルは直接書き換えられないので、
    // ランタイムテーブルを使用する
    runtime_handlers[num] = handler;
    return true;
}

/// ランタイムハンドラテーブル
var runtime_handlers: [SYSCALL_COUNT]?HandlerFn = [_]?HandlerFn{null} ** SYSCALL_COUNT;

/// ランタイムハンドラでディスパッチ
pub fn dispatch(num: usize, arg1: u32, arg2: u32, arg3: u32) ?u32 {
    if (num >= SYSCALL_COUNT) return null;
    if (runtime_handlers[num]) |handler| {
        return handler(arg1, arg2, arg3);
    }
    return null;
}

/// 名前から syscall 番号を検索
pub fn findByName(name: []const u8) ?usize {
    for (syscall_table, 0..) |entry, i| {
        if (strEql(entry.name, name)) return i;
    }
    return null;
}

/// 全 syscall テーブルを表示
pub fn printTable() void {
    vga.setColor(.yellow, .black);
    vga.write("NUM  NAME         ARGS  STATUS       DESCRIPTION\n");
    vga.setColor(.light_grey, .black);

    for (syscall_table) |entry| {
        // 番号
        printDecPadded(entry.number, 3);
        vga.write("  ");

        // 名前 (12文字パディング)
        vga.write(entry.name);
        padTo(entry.name.len, 13);

        // 引数個数
        vga.putChar('0' + entry.arg_count);
        vga.write("     ");

        // 実装状況
        if (entry.implemented) {
            vga.setColor(.light_green, .black);
            vga.write("implemented  ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("stub         ");
        }
        vga.setColor(.light_grey, .black);

        // 説明
        vga.write(entry.description);
        vga.putChar('\n');
    }

    // サマリー
    vga.putChar('\n');
    var impl_count: usize = 0;
    for (syscall_table) |entry| {
        if (entry.implemented) impl_count += 1;
    }
    vga.setColor(.light_cyan, .black);
    printDec(impl_count);
    vga.write("/");
    printDec(SYSCALL_COUNT);
    vga.write(" syscalls implemented\n");
    vga.setColor(.light_grey, .black);
}

/// 実装済み syscall のみ表示
pub fn printImplemented() void {
    vga.setColor(.yellow, .black);
    vga.write("Implemented syscalls:\n");
    vga.setColor(.light_grey, .black);

    for (syscall_table) |entry| {
        if (!entry.implemented) continue;
        vga.write("  ");
        printDecPadded(entry.number, 3);
        vga.write("  ");
        vga.write(entry.name);
        vga.putChar('\n');
    }
}

/// 未実装 syscall のみ表示
pub fn printStubs() void {
    vga.setColor(.yellow, .black);
    vga.write("Stub (unimplemented) syscalls:\n");
    vga.setColor(.dark_grey, .black);

    for (syscall_table) |entry| {
        if (entry.implemented) continue;
        vga.write("  ");
        printDecPadded(entry.number, 3);
        vga.write("  ");
        vga.write(entry.name);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
}

/// シリアルにテーブルダンプ
pub fn dumpToSerial() void {
    serial.write("=== Syscall Table ===\n");
    for (syscall_table) |entry| {
        serial.write("  ");
        serial.writeHex(entry.number);
        serial.write(" ");
        serial.write(entry.name);
        serial.write(" args=");
        serial.writeHex(entry.arg_count);
        if (entry.implemented) {
            serial.write(" [OK]");
        } else {
            serial.write(" [STUB]");
        }
        serial.write("\n");
    }
}

// ---- 内部ヘルパ ----

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDecPadded(n: u8, width: usize) void {
    var digits: usize = 0;
    var tmp: u8 = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    // 左パディング
    var pad = width -| digits;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
    if (n == 0) {
        vga.putChar('0');
    } else {
        var buf: [3]u8 = undefined;
        var len: usize = 0;
        var val = n;
        while (val > 0) {
            buf[len] = '0' + val % 10;
            len += 1;
            val /= 10;
        }
        while (len > 0) {
            len -= 1;
            vga.putChar(buf[len]);
        }
    }
}

fn padTo(current: usize, target: usize) void {
    var i = current;
    while (i < target) {
        vga.putChar(' ');
        i += 1;
    }
}
