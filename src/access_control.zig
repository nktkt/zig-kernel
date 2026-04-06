// アクセス制御リスト (ACL)
//
// ファイル単位の ACL 管理。ユーザー/グループ/その他のパーミッション。
// 最大 32 ファイル、各ファイル最大 8 ACL エントリ。

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// 最大追跡ファイル数
const MAX_FILES: usize = 32;

/// ファイルあたりの最大 ACL エントリ数
const MAX_ENTRIES_PER_FILE: usize = 8;

/// パス最大長
const MAX_PATH: usize = 64;

// ===========================================================================
// パーミッションビット
// ===========================================================================

pub const PERM_READ: u16 = 0x04;
pub const PERM_WRITE: u16 = 0x02;
pub const PERM_EXEC: u16 = 0x01;
pub const PERM_RWX: u16 = PERM_READ | PERM_WRITE | PERM_EXEC;
pub const PERM_NONE: u16 = 0x00;

// ===========================================================================
// ACL 型定義
// ===========================================================================

/// ACL エントリの対象タイプ
pub const SubjectType = enum(u8) {
    user = 0,
    group = 1,
    other = 2,
};

/// ACL エントリのアクション
pub const AclAction = enum(u8) {
    allow = 0,
    deny = 1,
};

/// ACL エントリ
pub const AclEntry = struct {
    subject_type: SubjectType,
    subject_id: u16, // UID or GID (other の場合は 0)
    permissions: u16, // rwx ビットマスク
    action: AclAction,
    used: bool,
};

/// ファイルの ACL
pub const FileAcl = struct {
    path: [MAX_PATH]u8,
    path_len: usize,
    entries: [MAX_ENTRIES_PER_FILE]AclEntry,
    entry_count: usize,
    is_directory: bool,
    /// デフォルト ACL (ディレクトリの子に継承)
    default_perms: u16,
    default_perms_set: bool,
    used: bool,
};

// ===========================================================================
// グローバル ACL テーブル
// ===========================================================================

var file_acls: [MAX_FILES]FileAcl = initFileAcls();

fn initFileAcls() [MAX_FILES]FileAcl {
    var arr: [MAX_FILES]FileAcl = undefined;
    for (&arr) |*f| {
        f.used = false;
        f.path_len = 0;
        f.entry_count = 0;
        f.is_directory = false;
        f.default_perms = PERM_NONE;
        f.default_perms_set = false;
        f.path = @splat(0);
        for (&f.entries) |*e| {
            e.used = false;
        }
    }
    return arr;
}

// ===========================================================================
// ACL 管理 API
// ===========================================================================

/// パスの ACL エントリを設定 (既存エントリは更新)
pub fn setAcl(path: []const u8, entry: AclEntry) bool {
    const file = findOrCreateFile(path);
    if (file == null) return false;

    const f = file.?;

    // 既存エントリを検索 (同じ subject_type + subject_id)
    for (f.entries[0..f.entry_count]) |*e| {
        if (e.used and
            e.subject_type == entry.subject_type and
            e.subject_id == entry.subject_id)
        {
            e.permissions = entry.permissions;
            e.action = entry.action;
            return true;
        }
    }

    // 新しいエントリを追加
    if (f.entry_count >= MAX_ENTRIES_PER_FILE) return false;

    f.entries[f.entry_count] = .{
        .subject_type = entry.subject_type,
        .subject_id = entry.subject_id,
        .permissions = entry.permissions,
        .action = entry.action,
        .used = true,
    };
    f.entry_count += 1;
    return true;
}

/// パスの ACL エントリを削除 (subject で指定)
pub fn removeAcl(path: []const u8, subject_type: SubjectType, subject_id: u16) bool {
    const file = findFile(path);
    if (file == null) return false;

    var f = file.?;
    for (f.entries[0..f.entry_count], 0..) |*e, i| {
        if (e.used and
            e.subject_type == subject_type and
            e.subject_id == subject_id)
        {
            // 末尾のエントリで上書き
            if (i < f.entry_count - 1) {
                f.entries[i] = f.entries[f.entry_count - 1];
            }
            f.entries[f.entry_count - 1].used = false;
            f.entry_count -= 1;
            return true;
        }
    }
    return false;
}

/// アクセス権をチェック
pub fn checkAccess(
    path: []const u8,
    uid: u16,
    gid: u16,
    requested_perm: u16,
) bool {
    const file = findFile(path);
    if (file == null) return true; // ACL 未設定 = 許可

    const f = file.?;

    // root (uid=0) は常に許可
    if (uid == 0) return true;

    // deny ルールを先にチェック
    for (f.entries[0..f.entry_count]) |e| {
        if (!e.used) continue;
        if (e.action != .deny) continue;

        if (matchesSubject(e, uid, gid)) {
            if ((e.permissions & requested_perm) != 0) {
                return false; // 明示的 deny
            }
        }
    }

    // allow ルールをチェック
    for (f.entries[0..f.entry_count]) |e| {
        if (!e.used) continue;
        if (e.action != .allow) continue;

        if (matchesSubject(e, uid, gid)) {
            if ((e.permissions & requested_perm) == requested_perm) {
                return true; // 明示的 allow
            }
        }
    }

    // デフォルト: パーミッションなし
    return false;
}

/// 実効パーミッションを取得
pub fn getEffectivePermissions(path: []const u8, uid: u16, gid: u16) u16 {
    const file = findFile(path);
    if (file == null) return PERM_RWX; // ACL 未設定 = フルアクセス

    const f = file.?;

    // root は常にフルアクセス
    if (uid == 0) return PERM_RWX;

    var allowed: u16 = 0;
    var denied: u16 = 0;

    for (f.entries[0..f.entry_count]) |e| {
        if (!e.used) continue;

        if (matchesSubject(e, uid, gid)) {
            switch (e.action) {
                .allow => allowed |= e.permissions,
                .deny => denied |= e.permissions,
            }
        }
    }

    // deny が優先
    return allowed & ~denied;
}

/// ディレクトリのデフォルト ACL を設定
pub fn setDefaultPerms(path: []const u8, perms: u16) bool {
    const file = findOrCreateFile(path);
    if (file == null) return false;

    const f = file.?;
    f.is_directory = true;
    f.default_perms = perms;
    f.default_perms_set = true;
    return true;
}

/// ディレクトリのデフォルト ACL を取得
pub fn getDefaultPerms(path: []const u8) ?u16 {
    const file = findFile(path);
    if (file == null) return null;
    const f = file.?;
    if (!f.default_perms_set) return null;
    return f.default_perms;
}

/// 親ディレクトリのデフォルト ACL を継承
pub fn inheritFromParent(child_path: []const u8, parent_path: []const u8) bool {
    const parent_perms = getDefaultPerms(parent_path);
    if (parent_perms == null) return false;

    const entry = AclEntry{
        .subject_type = .other,
        .subject_id = 0,
        .permissions = parent_perms.?,
        .action = .allow,
        .used = true,
    };
    return setAcl(child_path, entry);
}

/// ファイルの ACL をすべて削除
pub fn clearAcl(path: []const u8) bool {
    const idx = findFileIndex(path);
    if (idx == null) return false;
    file_acls[idx.?].used = false;
    file_acls[idx.?].entry_count = 0;
    return true;
}

// ===========================================================================
// 表示
// ===========================================================================

/// ファイルの ACL を表示
pub fn printAcl(path: []const u8) void {
    const file = findFile(path);
    if (file == null) {
        vga.setColor(.dark_grey, .black);
        vga.write("  No ACL for: ");
        vga.write(path);
        vga.putChar('\n');
        return;
    }

    const f = file.?;
    vga.setColor(.light_cyan, .black);
    vga.write("ACL for: ");
    vga.write(path);
    if (f.is_directory) vga.write(" (dir)");
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    if (f.entry_count == 0) {
        vga.write("  (empty)\n");
        return;
    }

    for (f.entries[0..f.entry_count]) |e| {
        if (!e.used) continue;
        vga.write("  ");

        // アクション
        switch (e.action) {
            .allow => {
                vga.setColor(.light_green, .black);
                vga.write("ALLOW ");
            },
            .deny => {
                vga.setColor(.light_red, .black);
                vga.write("DENY  ");
            },
        }

        // 対象
        vga.setColor(.light_grey, .black);
        switch (e.subject_type) {
            .user => {
                vga.write("user:");
                printDecU16(e.subject_id);
            },
            .group => {
                vga.write("group:");
                printDecU16(e.subject_id);
            },
            .other => {
                vga.write("other");
            },
        }

        // パーミッション
        vga.write(" ");
        printPerms(e.permissions);
        vga.putChar('\n');
    }

    if (f.default_perms_set) {
        vga.setColor(.yellow, .black);
        vga.write("  default: ");
        printPerms(f.default_perms);
        vga.putChar('\n');
    }

    vga.setColor(.light_grey, .black);
}

/// 全ファイルの ACL を表示
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Access Control Lists ===\n");

    var count: usize = 0;
    for (&file_acls) |*f| {
        if (f.used) {
            printAcl(f.path[0..f.path_len]);
            count += 1;
        }
    }

    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no ACLs configured)\n");
    }

    vga.setColor(.light_grey, .black);
}

// ===========================================================================
// 内部ヘルパー
// ===========================================================================

/// サブジェクトが ACL エントリにマッチするか
fn matchesSubject(entry: AclEntry, uid: u16, gid: u16) bool {
    return switch (entry.subject_type) {
        .user => entry.subject_id == uid,
        .group => entry.subject_id == gid,
        .other => true,
    };
}

/// パスでファイル ACL を検索
fn findFile(path: []const u8) ?*FileAcl {
    const idx = findFileIndex(path);
    if (idx == null) return null;
    return &file_acls[idx.?];
}

/// パスでファイル ACL のインデックスを検索
fn findFileIndex(path: []const u8) ?usize {
    for (&file_acls, 0..) |*f, i| {
        if (f.used and f.path_len == path.len) {
            if (strEql(f.path[0..f.path_len], path)) {
                return i;
            }
        }
    }
    return null;
}

/// パスでファイル ACL を検索、なければ作成
fn findOrCreateFile(path: []const u8) ?*FileAcl {
    // 既存を検索
    const existing = findFile(path);
    if (existing != null) return existing;

    // 空きスロットに作成
    for (&file_acls) |*f| {
        if (!f.used) {
            f.used = true;
            f.path_len = @min(path.len, MAX_PATH);
            @memcpy(f.path[0..f.path_len], path[0..f.path_len]);
            f.entry_count = 0;
            f.is_directory = false;
            f.default_perms = PERM_NONE;
            f.default_perms_set = false;
            for (&f.entries) |*e| {
                e.used = false;
            }
            return f;
        }
    }
    return null; // テーブル満杯
}

/// 文字列比較
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// パーミッション文字列を表示 (rwx)
fn printPerms(perms: u16) void {
    if (perms & PERM_READ != 0) {
        vga.putChar('r');
    } else {
        vga.putChar('-');
    }
    if (perms & PERM_WRITE != 0) {
        vga.putChar('w');
    } else {
        vga.putChar('-');
    }
    if (perms & PERM_EXEC != 0) {
        vga.putChar('x');
    } else {
        vga.putChar('-');
    }
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
