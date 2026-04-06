// プロセスサンドボックス
//
// ポリシーベースのプロセス隔離。
// システムコール制限、パスアクセス制限、リソース制限を提供。
// 定義済みサンドボックス: minimal, standard, full。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const audit = @import("audit.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// 最大サンドボックス数
const MAX_SANDBOXES: usize = 8;

/// サンドボックスあたりの最大プロセス数
const MAX_SANDBOX_PROCS: usize = 8;

/// ポリシーあたりの許可パス最大数
const MAX_ALLOWED_PATHS: usize = 4;

/// パスの最大長
const MAX_PATH_LEN: usize = 48;

/// サンドボックス名の最大長
const MAX_NAME_LEN: usize = 16;

// ===========================================================================
// システムコールビットマスク
// ===========================================================================

/// 個別システムコールのビット位置
pub const SYSCALL_EXIT: u32 = 1 << 0;
pub const SYSCALL_READ: u32 = 1 << 1;
pub const SYSCALL_WRITE: u32 = 1 << 2;
pub const SYSCALL_OPEN: u32 = 1 << 3;
pub const SYSCALL_CLOSE: u32 = 1 << 4;
pub const SYSCALL_FORK: u32 = 1 << 5;
pub const SYSCALL_EXEC: u32 = 1 << 6;
pub const SYSCALL_GETPID: u32 = 1 << 7;
pub const SYSCALL_KILL: u32 = 1 << 8;
pub const SYSCALL_MMAP: u32 = 1 << 9;
pub const SYSCALL_MUNMAP: u32 = 1 << 10;
pub const SYSCALL_SOCKET: u32 = 1 << 11;
pub const SYSCALL_CONNECT: u32 = 1 << 12;
pub const SYSCALL_SEND: u32 = 1 << 13;
pub const SYSCALL_RECV: u32 = 1 << 14;
pub const SYSCALL_SIGRETURN: u32 = 1 << 15;

/// 定義済みシステムコールセット
pub const SYSCALLS_MINIMAL: u32 = SYSCALL_EXIT;
pub const SYSCALLS_BASIC_IO: u32 = SYSCALL_EXIT | SYSCALL_READ | SYSCALL_WRITE | SYSCALL_SIGRETURN;
pub const SYSCALLS_STANDARD: u32 = SYSCALLS_BASIC_IO | SYSCALL_OPEN | SYSCALL_CLOSE | SYSCALL_GETPID;
pub const SYSCALLS_FULL: u32 = 0xFFFFFFFF;

// ===========================================================================
// アクションタイプ
// ===========================================================================

pub const ActionType = enum(u8) {
    syscall = 0,
    file_access = 1,
    memory_alloc = 2,
    file_open = 3,
    network = 4,

    pub fn name(self: ActionType) []const u8 {
        return switch (self) {
            .syscall => "syscall",
            .file_access => "file",
            .memory_alloc => "memory",
            .file_open => "open",
            .network => "network",
        };
    }
};

// ===========================================================================
// サンドボックスポリシー
// ===========================================================================

pub const Policy = struct {
    /// 許可するシステムコールのビットマスク
    allowed_syscalls: u32,
    /// 許可するパス (最大 4)
    allowed_paths: [MAX_ALLOWED_PATHS][MAX_PATH_LEN]u8,
    allowed_path_lens: [MAX_ALLOWED_PATHS]usize,
    allowed_path_count: usize,
    /// メモリページ数の上限
    max_memory_pages: u32,
    /// オープンファイル数の上限
    max_files: u16,
    /// ネットワークアクセスの許可
    network_allowed: bool,
};

// ===========================================================================
// サンドボックス構造体
// ===========================================================================

pub const Sandbox = struct {
    /// サンドボックス ID
    id: u8,
    /// サンドボックス名
    sb_name: [MAX_NAME_LEN]u8,
    name_len: usize,
    /// ポリシー
    policy: Policy,
    /// 所属プロセス
    processes: [MAX_SANDBOX_PROCS]u32,
    process_count: usize,
    /// リソース使用量トラッキング
    current_memory_pages: u32,
    current_open_files: u16,
    /// 違反カウント
    violation_count: u32,
    /// アクティブフラグ
    active: bool,
};

// ===========================================================================
// グローバルサンドボックステーブル
// ===========================================================================

var sandboxes: [MAX_SANDBOXES]Sandbox = initSandboxes();
var next_sb_id: u8 = 1;

fn initSandboxes() [MAX_SANDBOXES]Sandbox {
    var arr: [MAX_SANDBOXES]Sandbox = undefined;
    for (&arr) |*sb| {
        sb.active = false;
        sb.id = 0;
        sb.sb_name = @splat(0);
        sb.name_len = 0;
        sb.process_count = 0;
        sb.current_memory_pages = 0;
        sb.current_open_files = 0;
        sb.violation_count = 0;
        for (&sb.processes) |*p| p.* = 0;
        sb.policy = emptyPolicy();
    }
    return arr;
}

fn emptyPolicy() Policy {
    var p: Policy = undefined;
    p.allowed_syscalls = 0;
    p.allowed_path_count = 0;
    p.max_memory_pages = 0;
    p.max_files = 0;
    p.network_allowed = false;
    for (&p.allowed_paths) |*ap| ap.* = @splat(0);
    p.allowed_path_lens = @splat(0);
    return p;
}

// ===========================================================================
// 定義済みポリシー
// ===========================================================================

/// 最小限ポリシー (exit のみ)
pub fn minimalPolicy() Policy {
    var p = emptyPolicy();
    p.allowed_syscalls = SYSCALLS_MINIMAL;
    p.max_memory_pages = 1;
    p.max_files = 0;
    p.network_allowed = false;
    return p;
}

/// 標準ポリシー (基本 I/O)
pub fn standardPolicy() Policy {
    var p = emptyPolicy();
    p.allowed_syscalls = SYSCALLS_STANDARD;
    p.max_memory_pages = 64;
    p.max_files = 8;
    p.network_allowed = false;
    return p;
}

/// フルアクセスポリシー
pub fn fullPolicy() Policy {
    var p = emptyPolicy();
    p.allowed_syscalls = SYSCALLS_FULL;
    p.max_memory_pages = 0xFFFFFFFF;
    p.max_files = 0xFFFF;
    p.network_allowed = true;
    return p;
}

// ===========================================================================
// サンドボックス管理 API
// ===========================================================================

/// サンドボックスを作���
pub fn createSandbox(policy: Policy) ?u8 {
    for (&sandboxes) |*sb| {
        if (!sb.active) {
            sb.active = true;
            sb.id = next_sb_id;
            sb.policy = policy;
            sb.process_count = 0;
            sb.current_memory_pages = 0;
            sb.current_open_files = 0;
            sb.violation_count = 0;
            sb.sb_name = @splat(0);
            sb.name_len = 0;
            for (&sb.processes) |*p| p.* = 0;

            const id = next_sb_id;
            next_sb_id +%= 1;
            if (next_sb_id == 0) next_sb_id = 1;
            return id;
        }
    }
    return null;
}

/// 名前付きサンドボックスを作成
pub fn createNamedSandbox(policy: Policy, sb_name: []const u8) ?u8 {
    const id = createSandbox(policy);
    if (id == null) return null;

    const sb = findSandbox(id.?);
    if (sb != null) {
        sb.?.name_len = @min(sb_name.len, MAX_NAME_LEN);
        @memcpy(sb.?.sb_name[0..sb.?.name_len], sb_name[0..sb.?.name_len]);
    }
    return id;
}

/// プロセスをサンドボックスに追加
pub fn enterSandbox(pid: u32, sandbox_id: u8) bool {
    const sb = findSandbox(sandbox_id);
    if (sb == null) return false;

    var s = sb.?;

    // 既に参加しているか確認
    for (s.processes[0..s.process_count]) |p| {
        if (p == pid) return true;
    }

    if (s.process_count >= MAX_SANDBOX_PROCS) return false;

    s.processes[s.process_count] = pid;
    s.process_count += 1;
    return true;
}

/// プロセスをサンドボックスから削除
pub fn leaveSandbox(pid: u32, sandbox_id: u8) bool {
    const sb = findSandbox(sandbox_id);
    if (sb == null) return false;

    var s = sb.?;

    for (s.processes[0..s.process_count], 0..) |p, i| {
        if (p == pid) {
            if (i < s.process_count - 1) {
                s.processes[i] = s.processes[s.process_count - 1];
            }
            s.process_count -= 1;
            return true;
        }
    }
    return false;
}

/// ポリシーチェック
pub fn checkPolicy(pid: u32, action: ActionType, resource: u32) bool {
    // プロセスが属するサンドボックスを検索
    const sb = findSandboxByPid(pid);
    if (sb == null) return true; // サンドボックス外 = 許可

    var s = sb.?;

    const allowed = switch (action) {
        .syscall => (s.policy.allowed_syscalls & resource) != 0,
        .file_access => s.current_open_files < s.policy.max_files,
        .memory_alloc => s.current_memory_pages + resource <= s.policy.max_memory_pages,
        .file_open => s.current_open_files < s.policy.max_files,
        .network => s.policy.network_allowed,
    };

    if (!allowed) {
        s.violation_count += 1;
        // 監査ログ
        audit.logEvent(.sandbox_violation, 0, pid, action.name());
    }

    return allowed;
}

/// ファイルパスへのアクセスをチェック
pub fn checkPathAccess(pid: u32, path: []const u8) bool {
    const sb = findSandboxByPid(pid);
    if (sb == null) return true;

    const s = sb.?;
    if (s.policy.allowed_path_count == 0) return true; // パス制限なし

    for (0..s.policy.allowed_path_count) |i| {
        const allowed = s.policy.allowed_paths[i][0..s.policy.allowed_path_lens[i]];
        if (pathStartsWith(path, allowed)) return true;
    }

    return false;
}

/// ポリシーに許可パスを追加
pub fn addAllowedPath(sandbox_id: u8, path: []const u8) bool {
    const sb = findSandbox(sandbox_id);
    if (sb == null) return false;

    var s = sb.?;
    if (s.policy.allowed_path_count >= MAX_ALLOWED_PATHS) return false;

    const idx = s.policy.allowed_path_count;
    const copy_len = @min(path.len, MAX_PATH_LEN);
    @memcpy(s.policy.allowed_paths[idx][0..copy_len], path[0..copy_len]);
    s.policy.allowed_path_lens[idx] = copy_len;
    s.policy.allowed_path_count += 1;
    return true;
}

/// リソース使用量を更新 (メモリ)
pub fn trackMemory(pid: u32, pages: u32) void {
    const sb = findSandboxByPid(pid);
    if (sb != null) {
        sb.?.current_memory_pages += pages;
    }
}

/// リソース使用量を更新 (ファイル)
pub fn trackFileOpen(pid: u32) void {
    const sb = findSandboxByPid(pid);
    if (sb != null) {
        sb.?.current_open_files += 1;
    }
}

/// ファイルクローズ時
pub fn trackFileClose(pid: u32) void {
    const sb = findSandboxByPid(pid);
    if (sb != null and sb.?.current_open_files > 0) {
        sb.?.current_open_files -= 1;
    }
}

/// サンドボックスを破棄
pub fn destroySandbox(sandbox_id: u8) bool {
    const sb = findSandbox(sandbox_id);
    if (sb == null) return false;
    sb.?.active = false;
    return true;
}

// ===========================================================================
// 表示
// ===========================================================================

/// サンドボックスの詳細を表示
pub fn printSandbox(id: u8) void {
    const sb = findSandbox(id);
    if (sb == null) {
        vga.write("  sandbox not found\n");
        return;
    }

    const s = sb.?;
    vga.setColor(.light_cyan, .black);
    vga.write("Sandbox#");
    printDecU8(s.id);
    if (s.name_len > 0) {
        vga.write(" \"");
        vga.write(s.sb_name[0..s.name_len]);
        vga.write("\"");
    }
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  syscalls: 0x");
    printHex32(s.policy.allowed_syscalls);
    vga.putChar('\n');
    vga.write("  max_mem:  ");
    printDecU32(s.policy.max_memory_pages);
    vga.write(" pages (used: ");
    printDecU32(s.current_memory_pages);
    vga.write(")\n");
    vga.write("  max_files: ");
    printDecU16(s.policy.max_files);
    vga.write(" (used: ");
    printDecU16(s.current_open_files);
    vga.write(")\n");
    vga.write("  network:  ");
    if (s.policy.network_allowed) {
        vga.setColor(.light_green, .black);
        vga.write("allowed\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("blocked\n");
    }
    vga.setColor(.light_grey, .black);
    vga.write("  violations: ");
    printDecU32(s.violation_count);
    vga.putChar('\n');

    // 許可パス
    if (s.policy.allowed_path_count > 0) {
        vga.write("  paths:\n");
        for (0..s.policy.allowed_path_count) |i| {
            vga.write("    ");
            vga.write(s.policy.allowed_paths[i][0..s.policy.allowed_path_lens[i]]);
            vga.putChar('\n');
        }
    }

    // プロセス
    if (s.process_count > 0) {
        vga.write("  processes: ");
        for (s.processes[0..s.process_count], 0..) |p, i| {
            if (i > 0) vga.write(", ");
            printDecU32(p);
        }
        vga.putChar('\n');
    }
}

/// 全サンドボックスを表示
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Sandboxes ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&sandboxes) |*sb| {
        if (sb.active) {
            printSandbox(sb.id);
            count += 1;
        }
    }

    if (count == 0) {
        vga.write("  (no sandboxes)\n");
    }
}

// ===========================================================================
// 内部ヘルパー
// ===========================================================================

fn findSandbox(id: u8) ?*Sandbox {
    for (&sandboxes) |*sb| {
        if (sb.active and sb.id == id) return sb;
    }
    return null;
}

fn findSandboxByPid(pid: u32) ?*Sandbox {
    for (&sandboxes) |*sb| {
        if (!sb.active) continue;
        for (sb.processes[0..sb.process_count]) |p| {
            if (p == pid) return sb;
        }
    }
    return null;
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (path[0..prefix.len], prefix) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn printDecU8(n: u8) void {
    printDecU32(@as(u32, n));
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

fn printHex32(val: u32) void {
    const hex = "0123456789abcdef";
    var v = val;
    var buf_arr: [8]u8 = undefined;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf_arr[i] = hex[@as(usize, v & 0xF)];
        v >>= 4;
    }
    vga.write(&buf_arr);
}
