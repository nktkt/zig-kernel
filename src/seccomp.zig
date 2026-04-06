// Seccomp 風システムコールフィルタリング
//
// プロセスごとのシステムコールフィルタリング。
// モード: disabled (フィルタなし), strict (最小限のみ), filter (カスタムルール)。
// 各プロセスに最大 16 ルールを設定可能。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const audit = @import("audit.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// 最大追跡プロセス数
const MAX_PROCESSES: usize = 16;

/// プロセスあたりの最大フィルタルール数
const MAX_RULES: usize = 16;

/// strict モードで許可するシステムコール
const STRICT_WHITELIST = [_]u16{
    SYS_EXIT, // exit
    SYS_READ, // read
    SYS_WRITE, // write
    SYS_SIGRETURN, // sigreturn
};

/// 既知のシステムコール番号
pub const SYS_EXIT: u16 = 1;
pub const SYS_READ: u16 = 3;
pub const SYS_WRITE: u16 = 4;
pub const SYS_OPEN: u16 = 5;
pub const SYS_CLOSE: u16 = 6;
pub const SYS_FORK: u16 = 7;
pub const SYS_EXEC: u16 = 11;
pub const SYS_SIGRETURN: u16 = 15;
pub const SYS_GETPID: u16 = 20;
pub const SYS_KILL: u16 = 37;
pub const SYS_MMAP: u16 = 90;
pub const SYS_MUNMAP: u16 = 91;
pub const SYS_SOCKET: u16 = 97;
pub const SYS_CONNECT: u16 = 98;
pub const SYS_SEND: u16 = 100;
pub const SYS_RECV: u16 = 101;

// ===========================================================================
// 型定義
// ===========================================================================

/// フィルタモード
pub const Mode = enum(u8) {
    disabled = 0,
    strict = 1,
    filter = 2,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .disabled => "DISABLED",
            .strict => "STRICT",
            .filter => "FILTER",
        };
    }
};

/// フィルタアクション
pub const Action = enum(u8) {
    allow = 0,
    deny = 1,
    log_only = 2,
    kill = 3,

    pub fn name(self: Action) []const u8 {
        return switch (self) {
            .allow => "ALLOW",
            .deny => "DENY",
            .log_only => "LOG",
            .kill => "KILL",
        };
    }
};

/// フィルタルール
pub const Rule = struct {
    syscall_num: u16,
    action: Action,
    used: bool,
};

/// プロセスのフィルタ設定
pub const ProcessFilter = struct {
    pid: u32,
    mode: Mode,
    rules: [MAX_RULES]Rule,
    rule_count: usize,
    violation_count: u32,
    active: bool,
};

// ===========================================================================
// グローバルフィルタテーブル
// ===========================================================================

var filters: [MAX_PROCESSES]ProcessFilter = initFilters();
/// グローバル違反カウント
var total_violations: u64 = 0;

fn initFilters() [MAX_PROCESSES]ProcessFilter {
    var arr: [MAX_PROCESSES]ProcessFilter = undefined;
    for (&arr) |*f| {
        f.active = false;
        f.pid = 0;
        f.mode = .disabled;
        f.rule_count = 0;
        f.violation_count = 0;
        for (&f.rules) |*r| {
            r.used = false;
            r.syscall_num = 0;
            r.action = .deny;
        }
    }
    return arr;
}

// ===========================================================================
// フィルタ管理 API
// ===========================================================================

/// プロセスのフィルタモードを設定
pub fn setMode(pid: u32, mode: Mode) bool {
    var f = findOrCreateFilter(pid);
    if (f == null) return false;

    f.?.mode = mode;

    // strict モードの場合、ホワイトリストをルールとして登録
    if (mode == .strict) {
        f.?.rule_count = 0;
        for (&f.?.rules) |*r| r.used = false;

        for (STRICT_WHITELIST, 0..) |syscall_num, i| {
            if (i >= MAX_RULES) break;
            f.?.rules[i] = .{
                .syscall_num = syscall_num,
                .action = .allow,
                .used = true,
            };
            f.?.rule_count += 1;
        }
    }

    return true;
}

/// フィルタルールを追加
pub fn addRule(pid: u32, syscall_num: u16, action: Action) bool {
    const f = findOrCreateFilter(pid);
    if (f == null) return false;

    const pf = f.?;

    // 既存ルールを更新
    for (pf.rules[0..pf.rule_count]) |*r| {
        if (r.used and r.syscall_num == syscall_num) {
            r.action = action;
            return true;
        }
    }

    // 新規ルール追加
    if (pf.rule_count >= MAX_RULES) return false;

    pf.rules[pf.rule_count] = .{
        .syscall_num = syscall_num,
        .action = action,
        .used = true,
    };
    pf.rule_count += 1;
    return true;
}

/// ルールを削除
pub fn removeRule(pid: u32, syscall_num: u16) bool {
    const f = findFilter(pid);
    if (f == null) return false;

    var pf = f.?;
    for (pf.rules[0..pf.rule_count], 0..) |*r, i| {
        if (r.used and r.syscall_num == syscall_num) {
            if (i < pf.rule_count - 1) {
                pf.rules[i] = pf.rules[pf.rule_count - 1];
            }
            pf.rules[pf.rule_count - 1].used = false;
            pf.rule_count -= 1;
            return true;
        }
    }
    return false;
}

/// システムコールをチェック
pub fn checkSyscall(pid: u32, syscall_num: u16) Action {
    const f = findFilter(pid);
    if (f == null) return .allow; // フィルタなし

    const pf = f.?;

    switch (pf.mode) {
        .disabled => return .allow,
        .strict => {
            // ホワイトリストにあるか
            for (STRICT_WHITELIST) |allowed| {
                if (syscall_num == allowed) return .allow;
            }
            // ホワイトリスト外 = kill
            logViolation(pid, syscall_num, .kill);
            return .kill;
        },
        .filter => {
            // カスタムルールを検索
            for (pf.rules[0..pf.rule_count]) |r| {
                if (r.used and r.syscall_num == syscall_num) {
                    if (r.action == .deny or r.action == .kill) {
                        logViolation(pid, syscall_num, r.action);
                    } else if (r.action == .log_only) {
                        logViolation(pid, syscall_num, .log_only);
                    }
                    return r.action;
                }
            }
            // ルールにないシステムコール → デフォルト deny
            logViolation(pid, syscall_num, .deny);
            return .deny;
        },
    }
}

/// プロセスのフィルタを削除
pub fn removeFilter(pid: u32) bool {
    const f = findFilter(pid);
    if (f == null) return false;
    f.?.active = false;
    return true;
}

// ===========================================================================
// 違反ログ
// ===========================================================================

fn logViolation(pid: u32, syscall_num: u16, action: Action) void {
    total_violations += 1;

    // フィルタの違反カウントを更新
    const f = findFilter(pid);
    if (f != null) {
        f.?.violation_count += 1;
    }

    // 監査ログにも記録
    var detail_buf: [64]u8 = @splat(0);
    var detail_len: usize = 0;
    detail_len = writeSyscallDetail(&detail_buf, syscall_num, action);

    audit.logEvent(.syscall_blocked, 0, pid, detail_buf[0..detail_len]);
}

fn writeSyscallDetail(buf: *[64]u8, syscall_num: u16, action: Action) usize {
    const prefix = "syscall=";
    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    // 数値をバッファに書き込み
    pos += writeDecToBuf(buf[pos..], @as(u32, syscall_num));

    const act_str = " action=";
    if (pos + act_str.len < 64) {
        @memcpy(buf[pos .. pos + act_str.len], act_str);
        pos += act_str.len;
    }
    const action_name = action.name();
    const copy_len = @min(action_name.len, 64 - pos);
    if (copy_len > 0) {
        @memcpy(buf[pos .. pos + copy_len], action_name[0..copy_len]);
        pos += copy_len;
    }

    return pos;
}

fn writeDecToBuf(buf: []u8, n: u32) usize {
    if (buf.len == 0) return 0;
    if (n == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        tmp[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    const write_len = @min(len, buf.len);
    for (0..write_len) |i| {
        buf[i] = tmp[len - 1 - i];
    }
    return write_len;
}

// ===========================================================================
// 統計
// ===========================================================================

/// グローバル違反カウントを取得
pub fn getTotalViolations() u64 {
    return total_violations;
}

/// プロセスの違反カウントを取得
pub fn getViolationCount(pid: u32) u32 {
    const f = findFilter(pid);
    if (f == null) return 0;
    return f.?.violation_count;
}

/// システムコール番号の名前を取得
pub fn syscallName(num: u16) []const u8 {
    return switch (num) {
        SYS_EXIT => "exit",
        SYS_READ => "read",
        SYS_WRITE => "write",
        SYS_OPEN => "open",
        SYS_CLOSE => "close",
        SYS_FORK => "fork",
        SYS_EXEC => "exec",
        SYS_SIGRETURN => "sigreturn",
        SYS_GETPID => "getpid",
        SYS_KILL => "kill",
        SYS_MMAP => "mmap",
        SYS_MUNMAP => "munmap",
        SYS_SOCKET => "socket",
        SYS_CONNECT => "connect",
        SYS_SEND => "send",
        SYS_RECV => "recv",
        else => "unknown",
    };
}

// ===========================================================================
// 表示
// ===========================================================================

/// プロセスのフィルタを表示
pub fn printFilters(pid: u32) void {
    const f = findFilter(pid);
    if (f == null) {
        vga.setColor(.dark_grey, .black);
        vga.write("  No filter for PID ");
        printDecU32(pid);
        vga.putChar('\n');
        return;
    }

    const pf = f.?;
    vga.setColor(.light_cyan, .black);
    vga.write("Seccomp filter PID=");
    printDecU32(pid);
    vga.write(" mode=");
    vga.write(pf.mode.name());
    vga.write(" violations=");
    printDecU32(pf.violation_count);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    if (pf.rule_count == 0) {
        vga.write("  (no rules)\n");
        return;
    }

    for (pf.rules[0..pf.rule_count]) |r| {
        if (!r.used) continue;
        vga.write("  syscall ");
        printDecU16(r.syscall_num);
        vga.write(" (");
        vga.write(syscallName(r.syscall_num));
        vga.write(") -> ");

        switch (r.action) {
            .allow => {
                vga.setColor(.light_green, .black);
                vga.write("ALLOW");
            },
            .deny => {
                vga.setColor(.light_red, .black);
                vga.write("DENY");
            },
            .log_only => {
                vga.setColor(.yellow, .black);
                vga.write("LOG");
            },
            .kill => {
                vga.setColor(.light_red, .black);
                vga.write("KILL");
            },
        }
        vga.setColor(.light_grey, .black);
        vga.putChar('\n');
    }
}

/// 全プロセスのフィルタ概要を表示
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Seccomp Filters ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&filters) |*f| {
        if (f.active) {
            printFilters(f.pid);
            count += 1;
        }
    }

    if (count == 0) {
        vga.write("  (no filters active)\n");
    }

    vga.write("Total violations: ");
    printDecU64(total_violations);
    vga.putChar('\n');
}

// ===========================================================================
// 内部ヘルパー
// ===========================================================================

fn findFilter(pid: u32) ?*ProcessFilter {
    for (&filters) |*f| {
        if (f.active and f.pid == pid) return f;
    }
    return null;
}

fn findOrCreateFilter(pid: u32) ?*ProcessFilter {
    // 既存を検索
    const existing = findFilter(pid);
    if (existing != null) return existing;

    // 空きスロットに作成
    for (&filters) |*f| {
        if (!f.active) {
            f.active = true;
            f.pid = pid;
            f.mode = .disabled;
            f.rule_count = 0;
            f.violation_count = 0;
            for (&f.rules) |*r| r.used = false;
            return f;
        }
    }
    return null;
}

fn printDecU16(n: u16) void {
    printDecU32(@as(u32, n));
}

fn printDecU32(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
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
        vga.putChar(buf[len]);
    }
}

fn printDecU64(n: u64) void {
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
