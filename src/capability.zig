// プロセスケーパビリティ — Linux 風の権限管理システム

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const user = @import("user.zig");
const task = @import("task.zig");

// ---- ケーパビリティフラグ (ビット位置) ----

pub const CAP_SYS_ADMIN: u5 = 0; // システム管理全般
pub const CAP_NET_RAW: u5 = 1; // RAW ソケット
pub const CAP_NET_BIND: u5 = 2; // 特権ポート (< 1024) にバインド
pub const CAP_SYS_BOOT: u5 = 3; // リブート権限
pub const CAP_SYS_TIME: u5 = 4; // システム時刻変更
pub const CAP_KILL: u5 = 5; // 任意プロセスへのシグナル送信
pub const CAP_SETUID: u5 = 6; // UID 変更
pub const CAP_CHOWN: u5 = 7; // ファイルオーナー変更
pub const CAP_DAC_OVERRIDE: u5 = 8; // ファイルパーミッション無視
pub const CAP_SYS_PTRACE: u5 = 9; // 他プロセスのトレース
pub const CAP_MKNOD: u5 = 10; // デバイスノード作成
pub const CAP_FOWNER: u5 = 11; // ファイルオーナーチェック無視

pub const CAP_COUNT = 12;

/// 全ケーパビリティマスク
pub const CAP_ALL: u32 = (1 << CAP_COUNT) - 1;

// ---- プロセスごとのケーパビリティテーブル ----

const MAX_PROCS = task.MAX_TASKS;

const CapEntry = struct {
    pid: u32,
    effective: u32, // 実効ケーパビリティマスク
    permitted: u32, // 許可ケーパビリティマスク
    inheritable: u32, // 継承ケーパビリティマスク
    used: bool,
};

var cap_table: [MAX_PROCS]CapEntry = initTable();

fn initTable() [MAX_PROCS]CapEntry {
    var table: [MAX_PROCS]CapEntry = undefined;
    for (&table) |*entry| {
        entry.pid = 0;
        entry.effective = 0;
        entry.permitted = 0;
        entry.inheritable = 0;
        entry.used = false;
    }
    return table;
}

// ---- 操作種別 (checkPermission 用) ----

pub const Operation = enum(u8) {
    kill_process, // CAP_KILL が必要
    change_uid, // CAP_SETUID が必要
    change_owner, // CAP_CHOWN が必要
    bind_port, // CAP_NET_BIND が必要
    raw_socket, // CAP_NET_RAW が必要
    set_time, // CAP_SYS_TIME が必要
    reboot, // CAP_SYS_BOOT が必要
    admin, // CAP_SYS_ADMIN が必要
    file_override, // CAP_DAC_OVERRIDE が必要
    ptrace, // CAP_SYS_PTRACE が必要
    create_device, // CAP_MKNOD が必要
    file_owner, // CAP_FOWNER が必要
};

/// 操作に必要なケーパビリティを返す
fn requiredCap(op: Operation) u5 {
    return switch (op) {
        .kill_process => CAP_KILL,
        .change_uid => CAP_SETUID,
        .change_owner => CAP_CHOWN,
        .bind_port => CAP_NET_BIND,
        .raw_socket => CAP_NET_RAW,
        .set_time => CAP_SYS_TIME,
        .reboot => CAP_SYS_BOOT,
        .admin => CAP_SYS_ADMIN,
        .file_override => CAP_DAC_OVERRIDE,
        .ptrace => CAP_SYS_PTRACE,
        .create_device => CAP_MKNOD,
        .file_owner => CAP_FOWNER,
    };
}

// ---- 初期化 ----

pub fn init() void {
    // PID=0 (カーネル) に全ケーパビリティ付与
    grantAllForPid(0);
}

/// PID に全ケーパビリティを付与
fn grantAllForPid(pid: u32) void {
    const entry = findOrCreate(pid);
    if (entry) |e| {
        e.effective = CAP_ALL;
        e.permitted = CAP_ALL;
        e.inheritable = CAP_ALL;
    }
}

// ---- 公開 API ----

/// PID が特定のケーパビリティを持つか
pub fn hasCapability(pid: u32, cap: u5) bool {
    // root (uid=0) は常に全権限
    if (user.getCurrentUid() == 0 and pid == task.getCurrentPid()) return true;

    if (findEntry(pid)) |entry| {
        return (entry.effective & capBit(cap)) != 0;
    }
    return false;
}

/// PID にケーパビリティを付与
pub fn grantCapability(pid: u32, cap: u5) void {
    const entry = findOrCreate(pid);
    if (entry) |e| {
        e.effective |= capBit(cap);
        e.permitted |= capBit(cap);

        serial.write("[cap] grant ");
        serial.write(capabilityName(cap));
        serial.write(" to pid=");
        serial.writeHex(pid);
        serial.write("\n");
    }
}

/// PID からケーパビリティを剥奪
pub fn revokeCapability(pid: u32, cap: u5) void {
    if (findEntry(pid)) |entry| {
        entry.effective &= ~capBit(cap);

        serial.write("[cap] revoke ");
        serial.write(capabilityName(cap));
        serial.write(" from pid=");
        serial.writeHex(pid);
        serial.write("\n");
    }
}

/// PID の実効ケーパビリティマスクを取得
pub fn getCapabilities(pid: u32) u32 {
    if (findEntry(pid)) |entry| {
        return entry.effective;
    }
    return 0;
}

/// PID の許可ケーパビリティマスクを取得
pub fn getPermitted(pid: u32) u32 {
    if (findEntry(pid)) |entry| {
        return entry.permitted;
    }
    return 0;
}

/// 操作が許可されているかチェック
pub fn checkPermission(pid: u32, op: Operation) bool {
    return hasCapability(pid, requiredCap(op));
}

/// 子プロセス作成時にケーパビリティを継承
pub fn inheritCapabilities(parent_pid: u32, child_pid: u32) void {
    if (findEntry(parent_pid)) |parent| {
        const child = findOrCreate(child_pid);
        if (child) |c| {
            // inheritable マスクに基づいて継承
            c.effective = parent.effective & parent.inheritable;
            c.permitted = parent.permitted & parent.inheritable;
            c.inheritable = parent.inheritable;
        }
    }
}

/// プロセス終了時にエントリを解放
pub fn releaseCapabilities(pid: u32) void {
    if (findEntry(pid)) |entry| {
        entry.used = false;
        entry.effective = 0;
        entry.permitted = 0;
        entry.inheritable = 0;
    }
}

/// ケーパビリティのビット番号から名前を返す
pub fn capabilityName(cap: u5) []const u8 {
    return switch (cap) {
        CAP_SYS_ADMIN => "CAP_SYS_ADMIN",
        CAP_NET_RAW => "CAP_NET_RAW",
        CAP_NET_BIND => "CAP_NET_BIND",
        CAP_SYS_BOOT => "CAP_SYS_BOOT",
        CAP_SYS_TIME => "CAP_SYS_TIME",
        CAP_KILL => "CAP_KILL",
        CAP_SETUID => "CAP_SETUID",
        CAP_CHOWN => "CAP_CHOWN",
        CAP_DAC_OVERRIDE => "CAP_DAC_OVERRIDE",
        CAP_SYS_PTRACE => "CAP_SYS_PTRACE",
        CAP_MKNOD => "CAP_MKNOD",
        CAP_FOWNER => "CAP_FOWNER",
        else => "CAP_UNKNOWN",
    };
}

/// PID のケーパビリティを VGA に表示
pub fn printCapabilities(pid: u32) void {
    vga.setColor(.yellow, .black);
    vga.write("Capabilities for PID ");
    printDec(pid);
    vga.write(":\n");
    vga.setColor(.light_grey, .black);

    const mask = getCapabilities(pid);

    if (mask == 0) {
        vga.write("  (none)\n");
        return;
    }

    if (mask == CAP_ALL) {
        vga.setColor(.light_green, .black);
        vga.write("  ALL capabilities (full root)\n");
        vga.setColor(.light_grey, .black);
        return;
    }

    var i: u5 = 0;
    while (i < CAP_COUNT) : (i += 1) {
        if (mask & capBit(i) != 0) {
            vga.setColor(.light_green, .black);
            vga.write("  [+] ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("  [-] ");
        }
        vga.write(capabilityName(i));
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);

    // サマリー
    var count: usize = 0;
    var j: u5 = 0;
    while (j < CAP_COUNT) : (j += 1) {
        if (mask & capBit(j) != 0) count += 1;
    }
    printDec(count);
    vga.write("/");
    printDec(CAP_COUNT);
    vga.write(" capabilities granted\n");
}

/// 全プロセスのケーパビリティ概要を表示
pub fn printSummary() void {
    vga.setColor(.yellow, .black);
    vga.write("PID   EFFECTIVE    PERMITTED    INHERITABLE\n");
    vga.setColor(.light_grey, .black);

    for (&cap_table) |*entry| {
        if (!entry.used) continue;
        printDecPadded(entry.pid, 5);
        vga.write("  ");
        printHex32(entry.effective);
        vga.write("     ");
        printHex32(entry.permitted);
        vga.write("     ");
        printHex32(entry.inheritable);
        vga.putChar('\n');
    }
}

// ---- 内部ヘルパ ----

fn capBit(cap: u5) u32 {
    return @as(u32, 1) << cap;
}

fn findEntry(pid: u32) ?*CapEntry {
    for (&cap_table) |*entry| {
        if (entry.used and entry.pid == pid) return entry;
    }
    return null;
}

fn findOrCreate(pid: u32) ?*CapEntry {
    // 既存エントリを探す
    if (findEntry(pid)) |entry| return entry;

    // 空きスロットに新規作成
    for (&cap_table) |*entry| {
        if (!entry.used) {
            entry.used = true;
            entry.pid = pid;
            entry.effective = 0;
            entry.permitted = 0;
            entry.inheritable = 0;
            return entry;
        }
    }
    return null;
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

fn printDecPadded(n: u32, width: usize) void {
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
    var pad = width -| digits;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
    if (n == 0) {
        vga.putChar('0');
    } else {
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
}

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    vga.write("0x");
    var i: u5 = 28;
    while (true) {
        const nibble: u4 = @truncate(val >> i);
        vga.putChar(hex[nibble]);
        if (i == 0) break;
        i -= 4;
    }
}
