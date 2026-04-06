// プロセス名前空間 (コンテナ風の隔離)
//
// PID, マウント, ネットワーク, ユーザー名前空間を提供。
// 各名前空間はメンバープロセスのリストを保持。
// 名前空間内のプロセスは隔離されたリソースビューを持つ。

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// 最大名前空間数
const MAX_NAMESPACES: usize = 8;

/// 名前空間あたりの最大メンバー数
const MAX_MEMBERS: usize = 16;

/// マウント名前空間のマウントテーブルサイズ
const MAX_MOUNTS: usize = 8;

/// マウントパスの最大長
const MAX_MOUNT_PATH: usize = 32;

// ===========================================================================
// 名前空間タイプ
// ===========================================================================

pub const NamespaceType = enum(u8) {
    pid = 0,
    mount = 1,
    network = 2,
    user_ns = 3,

    pub fn name(self: NamespaceType) []const u8 {
        return switch (self) {
            .pid => "PID",
            .mount => "MOUNT",
            .network => "NET",
            .user_ns => "USER",
        };
    }
};

// ===========================================================================
// マウントエントリ (マウント名前空間用)
// ===========================================================================

const MountEntry = struct {
    source: [MAX_MOUNT_PATH]u8,
    source_len: usize,
    target: [MAX_MOUNT_PATH]u8,
    target_len: usize,
    used: bool,
};

// ===========================================================================
// PID マッピング (PID 名前空間用)
// ===========================================================================

const PidMapping = struct {
    real_pid: u32,
    virtual_pid: u32,
    used: bool,
};

// ===========================================================================
// 名前空間構造体
// ===========================================================================

pub const Namespace = struct {
    /// 名前空間 ID
    id: u8,
    /// 名前空間タイプ
    ns_type: NamespaceType,
    /// メンバープロセス PID
    members: [MAX_MEMBERS]u32,
    member_count: usize,
    /// アクティブかどうか
    active: bool,
    /// PID マッピング (PID 名前空間用)
    pid_mappings: [MAX_MEMBERS]PidMapping,
    pid_mapping_count: usize,
    /// 次の仮想 PID
    next_virtual_pid: u32,
    /// マウントテーブル (マウント名前空間用)
    mounts: [MAX_MOUNTS]MountEntry,
    mount_count: usize,
    /// ネットワーク隔離フラグ (ネットワーク名前空間用)
    net_isolated: bool,
    /// UID マッピングオフセット (ユーザー名前空間用)
    uid_offset: u16,
};

// ===========================================================================
// グローバル名前空間テーブル
// ===========================================================================

var namespaces: [MAX_NAMESPACES]Namespace = initNamespaces();
var next_ns_id: u8 = 1;

fn initNamespaces() [MAX_NAMESPACES]Namespace {
    var arr: [MAX_NAMESPACES]Namespace = undefined;
    for (&arr) |*ns| {
        ns.active = false;
        ns.id = 0;
        ns.ns_type = .pid;
        ns.member_count = 0;
        ns.pid_mapping_count = 0;
        ns.next_virtual_pid = 1;
        ns.mount_count = 0;
        ns.net_isolated = false;
        ns.uid_offset = 0;
        for (&ns.members) |*m| m.* = 0;
        for (&ns.pid_mappings) |*pm| pm.used = false;
        for (&ns.mounts) |*me| me.used = false;
    }
    return arr;
}

// ===========================================================================
// 名前空間管理 API
// ===========================================================================

/// 新しい名前空間を作成
pub fn create(ns_type: NamespaceType) ?u8 {
    for (&namespaces) |*ns| {
        if (!ns.active) {
            ns.active = true;
            ns.id = next_ns_id;
            ns.ns_type = ns_type;
            ns.member_count = 0;
            ns.pid_mapping_count = 0;
            ns.next_virtual_pid = 1;
            ns.mount_count = 0;
            ns.net_isolated = (ns_type == .network);
            ns.uid_offset = 0;
            for (&ns.members) |*m| m.* = 0;
            for (&ns.pid_mappings) |*pm| pm.used = false;
            for (&ns.mounts) |*me| me.used = false;

            const id = next_ns_id;
            next_ns_id +%= 1;
            if (next_ns_id == 0) next_ns_id = 1;
            return id;
        }
    }
    return null; // テーブル満杯
}

/// プロセスを名前空間に追加
pub fn enter(ns_id: u8, pid: u32) bool {
    const ns = findNamespace(ns_id);
    if (ns == null) return false;

    var n = ns.?;

    // 既にメンバーか確認
    for (n.members[0..n.member_count]) |m| {
        if (m == pid) return true; // 既にメンバー
    }

    if (n.member_count >= MAX_MEMBERS) return false;

    n.members[n.member_count] = pid;
    n.member_count += 1;

    // PID 名前空間の場合、PID マッピングを追加
    if (n.ns_type == .pid) {
        if (n.pid_mapping_count < MAX_MEMBERS) {
            n.pid_mappings[n.pid_mapping_count] = .{
                .real_pid = pid,
                .virtual_pid = n.next_virtual_pid,
                .used = true,
            };
            n.pid_mapping_count += 1;
            n.next_virtual_pid += 1;
        }
    }

    return true;
}

/// プロセスを名前空間から削除
pub fn leave(ns_id: u8, pid: u32) void {
    const ns = findNamespace(ns_id);
    if (ns == null) return;

    var n = ns.?;

    // メンバーリストから削除
    for (n.members[0..n.member_count], 0..) |m, i| {
        if (m == pid) {
            // 末尾で上書き
            if (i < n.member_count - 1) {
                n.members[i] = n.members[n.member_count - 1];
            }
            n.member_count -= 1;
            break;
        }
    }

    // PID マッピングも削除
    if (n.ns_type == .pid) {
        for (n.pid_mappings[0..n.pid_mapping_count], 0..) |*pm, i| {
            if (pm.used and pm.real_pid == pid) {
                pm.used = false;
                if (i < n.pid_mapping_count - 1) {
                    n.pid_mappings[i] = n.pid_mappings[n.pid_mapping_count - 1];
                }
                n.pid_mapping_count -= 1;
                break;
            }
        }
    }
}

/// プロセスが属する名前空間を取得
pub fn getNamespace(pid: u32, ns_type: NamespaceType) ?u8 {
    for (&namespaces) |*ns| {
        if (!ns.active) continue;
        if (ns.ns_type != ns_type) continue;

        for (ns.members[0..ns.member_count]) |m| {
            if (m == pid) return ns.id;
        }
    }
    return null;
}

/// プロセスが指定タイプの名前空間で隔離されているか
pub fn isIsolated(pid: u32, ns_type: NamespaceType) bool {
    return getNamespace(pid, ns_type) != null;
}

/// 名前空間を破棄
pub fn destroy(ns_id: u8) bool {
    const ns = findNamespace(ns_id);
    if (ns == null) return false;
    ns.?.active = false;
    ns.?.member_count = 0;
    return true;
}

// ===========================================================================
// PID 名前空間 API
// ===========================================================================

/// 実 PID から仮想 PID を取得
pub fn getVirtualPid(ns_id: u8, real_pid: u32) ?u32 {
    const ns = findNamespace(ns_id);
    if (ns == null) return null;
    if (ns.?.ns_type != .pid) return null;

    for (ns.?.pid_mappings[0..ns.?.pid_mapping_count]) |pm| {
        if (pm.used and pm.real_pid == real_pid) {
            return pm.virtual_pid;
        }
    }
    return null;
}

/// 仮想 PID から実 PID を取得
pub fn getRealPid(ns_id: u8, virtual_pid: u32) ?u32 {
    const ns = findNamespace(ns_id);
    if (ns == null) return null;
    if (ns.?.ns_type != .pid) return null;

    for (ns.?.pid_mappings[0..ns.?.pid_mapping_count]) |pm| {
        if (pm.used and pm.virtual_pid == virtual_pid) {
            return pm.real_pid;
        }
    }
    return null;
}

// ===========================================================================
// マウント名前空間 API
// ===========================================================================

/// マウント名前空間にマウントポイントを追加
pub fn addMount(ns_id: u8, source: []const u8, target: []const u8) bool {
    const ns = findNamespace(ns_id);
    if (ns == null) return false;

    var n = ns.?;
    if (n.ns_type != .mount) return false;
    if (n.mount_count >= MAX_MOUNTS) return false;

    var entry = &n.mounts[n.mount_count];
    entry.used = true;
    entry.source_len = @min(source.len, MAX_MOUNT_PATH);
    @memcpy(entry.source[0..entry.source_len], source[0..entry.source_len]);
    entry.target_len = @min(target.len, MAX_MOUNT_PATH);
    @memcpy(entry.target[0..entry.target_len], target[0..entry.target_len]);
    n.mount_count += 1;

    return true;
}

/// マウント名前空間のマウントテーブルを表示
pub fn printMounts(ns_id: u8) void {
    const ns = findNamespace(ns_id);
    if (ns == null) {
        vga.write("  namespace not found\n");
        return;
    }

    const n = ns.?;
    if (n.ns_type != .mount) {
        vga.write("  not a mount namespace\n");
        return;
    }

    for (n.mounts[0..n.mount_count]) |me| {
        if (!me.used) continue;
        vga.write("  ");
        vga.write(me.source[0..me.source_len]);
        vga.write(" -> ");
        vga.write(me.target[0..me.target_len]);
        vga.putChar('\n');
    }
}

// ===========================================================================
// ユーザー名前空間 API
// ===========================================================================

/// ユーザー名前空間の UID オフセットを設定
pub fn setUidOffset(ns_id: u8, offset: u16) bool {
    const ns = findNamespace(ns_id);
    if (ns == null) return false;
    if (ns.?.ns_type != .user_ns) return false;
    ns.?.uid_offset = offset;
    return true;
}

/// ユーザー名前空間内での仮想 UID を取得
pub fn getVirtualUid(ns_id: u8, real_uid: u16) ?u16 {
    const ns = findNamespace(ns_id);
    if (ns == null) return null;
    if (ns.?.ns_type != .user_ns) return null;
    if (real_uid < ns.?.uid_offset) return null;
    return real_uid - ns.?.uid_offset;
}

// ===========================================================================
// 表示
// ===========================================================================

/// 全名前空間を表示
pub fn printNamespaces() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Namespaces ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&namespaces) |*ns| {
        if (!ns.active) continue;

        vga.setColor(.light_cyan, .black);
        vga.write("  NS#");
        printDecU8(ns.id);
        vga.write(" [");
        vga.write(ns.ns_type.name());
        vga.write("] ");

        vga.setColor(.light_grey, .black);
        vga.write("members: ");
        printDecU32(@as(u32, @truncate(ns.member_count)));

        if (ns.ns_type == .pid) {
            vga.write(" vpid_next=");
            printDecU32(ns.next_virtual_pid);
        } else if (ns.ns_type == .mount) {
            vga.write(" mounts=");
            printDecU32(@as(u32, @truncate(ns.mount_count)));
        } else if (ns.ns_type == .network) {
            vga.write(if (ns.net_isolated) " isolated" else " shared");
        } else if (ns.ns_type == .user_ns) {
            vga.write(" uid_off=");
            printDecU16(ns.uid_offset);
        }

        vga.putChar('\n');

        // メンバー PID を表示
        if (ns.member_count > 0) {
            vga.setColor(.dark_grey, .black);
            vga.write("    pids: ");
            for (ns.members[0..ns.member_count], 0..) |m, i| {
                if (i > 0) vga.write(", ");
                printDecU32(m);
            }
            vga.putChar('\n');
        }

        count += 1;
    }

    if (count == 0) {
        vga.write("  (no namespaces)\n");
    }

    vga.setColor(.light_grey, .black);
}

/// 名前空間の概要をシリアルに出力
pub fn printNamespacesSerial() void {
    serial.write("[NS] Active namespaces:\n");
    for (&namespaces) |*ns| {
        if (!ns.active) continue;
        serial.write("  NS#");
        serialPrintDec(@as(usize, ns.id));
        serial.write(" type=");
        serial.write(ns.ns_type.name());
        serial.write(" members=");
        serialPrintDec(ns.member_count);
        serial.putChar('\n');
    }
}

// ===========================================================================
// 内部ヘルパー
// ===========================================================================

fn findNamespace(ns_id: u8) ?*Namespace {
    for (&namespaces) |*ns| {
        if (ns.active and ns.id == ns_id) return ns;
    }
    return null;
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

fn serialPrintDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}
