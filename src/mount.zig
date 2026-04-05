// マウントポイント管理 — ファイルシステムのマウント・アンマウント

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- ファイルシステムタイプ ----

pub const FsType = enum(u8) {
    none,
    ramfs,
    fat16,
    ext2,
    devfs,
    procfs,
    tmpfs,
};

/// FsType から文字列名を取得
pub fn fsTypeName(fs: FsType) []const u8 {
    return switch (fs) {
        .none => "none",
        .ramfs => "ramfs",
        .fat16 => "fat16",
        .ext2 => "ext2",
        .devfs => "devfs",
        .procfs => "procfs",
        .tmpfs => "tmpfs",
    };
}

/// 文字列から FsType を解析
pub fn parseFsType(name: []const u8) ?FsType {
    const types = [_]struct { n: []const u8, t: FsType }{
        .{ .n = "ramfs", .t = .ramfs },
        .{ .n = "fat16", .t = .fat16 },
        .{ .n = "ext2", .t = .ext2 },
        .{ .n = "devfs", .t = .devfs },
        .{ .n = "procfs", .t = .procfs },
        .{ .n = "tmpfs", .t = .tmpfs },
    };
    for (types) |entry| {
        if (strEql(name, entry.n)) return entry.t;
    }
    return null;
}

// ---- マウントフラグ ----

pub const MF_RDONLY: u8 = 0x01; // 読み取り専用
pub const MF_RDWR: u8 = 0x00; // 読み書き可 (デフォルト)
pub const MF_NOEXEC: u8 = 0x02; // 実行不可
pub const MF_NOSUID: u8 = 0x04; // setuid 無視
pub const MF_NODEV: u8 = 0x08; // デバイスファイル無視

// ---- マウントポイント構造体 ----

const MAX_PATH = 32;

pub const MountPoint = struct {
    path: [MAX_PATH]u8,
    path_len: u8,
    fs_type: FsType,
    device: [MAX_PATH]u8,
    device_len: u8,
    flags: u8,
    used: bool,
};

const MAX_MOUNTS = 8;
var mount_table: [MAX_MOUNTS]MountPoint = initMountTable();

fn initMountTable() [MAX_MOUNTS]MountPoint {
    var table: [MAX_MOUNTS]MountPoint = undefined;
    for (&table) |*mp| {
        mp.path = [_]u8{0} ** MAX_PATH;
        mp.path_len = 0;
        mp.fs_type = .none;
        mp.device = [_]u8{0} ** MAX_PATH;
        mp.device_len = 0;
        mp.flags = 0;
        mp.used = false;
    }
    return table;
}

var mount_count: usize = 0;

// ---- 初期化 ----

pub fn init() void {
    // デフォルトマウントポイント
    _ = mount("/", .ramfs, "none", MF_RDWR);
    _ = mount("/dev", .devfs, "none", MF_RDWR);
    _ = mount("/proc", .procfs, "none", MF_RDONLY);

    serial.write("[mount] default mounts: / /dev /proc\n");
}

// ---- 公開 API ----

/// パスにファイルシステムをマウント
pub fn mount(path: []const u8, fs_type: FsType, device: []const u8, flags: u8) bool {
    // 既にマウント済みかチェック
    if (isMounted(path)) {
        serial.write("[mount] already mounted: ");
        serial.write(path);
        serial.write("\n");
        return false;
    }

    // 空きスロットを探す
    for (&mount_table) |*mp| {
        if (!mp.used) {
            mp.used = true;
            mp.fs_type = fs_type;
            mp.flags = flags;

            // パスをコピー
            const plen: u8 = @intCast(@min(path.len, MAX_PATH));
            @memcpy(mp.path[0..plen], path[0..plen]);
            mp.path_len = plen;

            // デバイスをコピー
            const dlen: u8 = @intCast(@min(device.len, MAX_PATH));
            @memcpy(mp.device[0..dlen], device[0..dlen]);
            mp.device_len = dlen;

            mount_count += 1;

            serial.write("[mount] mounted ");
            serial.write(fsTypeName(fs_type));
            serial.write(" on ");
            serial.write(path);
            serial.write("\n");

            return true;
        }
    }

    serial.write("[mount] no free slots\n");
    return false;
}

/// パスのファイルシステムをアンマウント
pub fn umount(path: []const u8) bool {
    // ルートはアンマウント不可
    if (path.len == 1 and path[0] == '/') {
        serial.write("[mount] cannot unmount /\n");
        return false;
    }

    for (&mount_table) |*mp| {
        if (!mp.used) continue;
        if (pathEql(mp, path)) {
            mp.used = false;
            mp.fs_type = .none;
            if (mount_count > 0) mount_count -= 1;

            serial.write("[mount] unmounted ");
            serial.write(path);
            serial.write("\n");
            return true;
        }
    }

    serial.write("[mount] not found: ");
    serial.write(path);
    serial.write("\n");
    return false;
}

/// パスに一致するマウントポイントを検索
/// 最長一致 (longest prefix match) で解決
pub fn findMount(path: []const u8) ?*MountPoint {
    var best: ?*MountPoint = null;
    var best_len: u8 = 0;

    for (&mount_table) |*mp| {
        if (!mp.used) continue;
        const mpath = mp.path[0..mp.path_len];

        // パスがマウントポイントで始まるかチェック
        if (startsWith(path, mpath)) {
            // 完全一致か、マウントポイント直後が '/' であること
            if (mpath.len == path.len or
                mpath.len == 1 or // root "/"
                (path.len > mpath.len and path[mpath.len] == '/'))
            {
                if (mp.path_len > best_len) {
                    best = mp;
                    best_len = mp.path_len;
                }
            }
        }
    }
    return best;
}

/// パスを処理するファイルシステムタイプを解決
pub fn resolveFs(path: []const u8) FsType {
    if (findMount(path)) |mp| {
        return mp.fs_type;
    }
    return .none;
}

/// パスがマウントされているかチェック
pub fn isMounted(path: []const u8) bool {
    for (&mount_table) |*mp| {
        if (!mp.used) continue;
        if (pathEql(mp, path)) return true;
    }
    return false;
}

/// マウントポイントが読み取り専用かチェック
pub fn isReadOnly(path: []const u8) bool {
    if (findMount(path)) |mp| {
        return (mp.flags & MF_RDONLY) != 0;
    }
    return false;
}

/// マウントポイントが実行不可かチェック
pub fn isNoExec(path: []const u8) bool {
    if (findMount(path)) |mp| {
        return (mp.flags & MF_NOEXEC) != 0;
    }
    return false;
}

/// マウントテーブルを表示 (/proc/mounts 風)
pub fn printMounts() void {
    vga.setColor(.yellow, .black);
    vga.write("DEVICE           MOUNT        TYPE    FLAGS\n");
    vga.setColor(.light_grey, .black);

    for (&mount_table) |*mp| {
        if (!mp.used) continue;

        // デバイス
        vga.write(mp.device[0..mp.device_len]);
        padTo(mp.device_len, 17);

        // マウントポイント
        vga.write(mp.path[0..mp.path_len]);
        padTo(mp.path_len, 13);

        // FS タイプ
        const type_name = fsTypeName(mp.fs_type);
        vga.write(type_name);
        padTo(type_name.len, 8);

        // フラグ
        if (mp.flags & MF_RDONLY != 0) {
            vga.write("ro");
        } else {
            vga.write("rw");
        }
        if (mp.flags & MF_NOEXEC != 0) {
            vga.write(",noexec");
        }
        if (mp.flags & MF_NOSUID != 0) {
            vga.write(",nosuid");
        }
        if (mp.flags & MF_NODEV != 0) {
            vga.write(",nodev");
        }
        vga.putChar('\n');
    }

    // サマリー
    vga.setColor(.light_cyan, .black);
    printDec(mount_count);
    vga.write(" filesystem(s) mounted\n");
    vga.setColor(.light_grey, .black);
}

/// シリアルにマウントテーブルダンプ
pub fn dumpToSerial() void {
    serial.write("=== Mount Table ===\n");
    for (&mount_table) |*mp| {
        if (!mp.used) continue;
        serial.write(mp.device[0..mp.device_len]);
        serial.write(" on ");
        serial.write(mp.path[0..mp.path_len]);
        serial.write(" type ");
        serial.write(fsTypeName(mp.fs_type));
        serial.write("\n");
    }
}

/// マウント数を取得
pub fn getMountCount() usize {
    return mount_count;
}

/// フラグ文字列を解析 ("ro", "rw", "noexec" など)
pub fn parseFlags(flag_str: []const u8) u8 {
    var flags: u8 = 0;
    // 簡易パーサ: カンマ区切りオプション
    var start: usize = 0;
    var i: usize = 0;
    while (i <= flag_str.len) : (i += 1) {
        if (i == flag_str.len or flag_str[i] == ',') {
            const token = flag_str[start..i];
            if (strEql(token, "ro")) {
                flags |= MF_RDONLY;
            } else if (strEql(token, "noexec")) {
                flags |= MF_NOEXEC;
            } else if (strEql(token, "nosuid")) {
                flags |= MF_NOSUID;
            } else if (strEql(token, "nodev")) {
                flags |= MF_NODEV;
            }
            start = i + 1;
        }
    }
    return flags;
}

// ---- 内部ヘルパ ----

fn pathEql(mp: *const MountPoint, path: []const u8) bool {
    if (mp.path_len != path.len) return false;
    return strEql(mp.path[0..mp.path_len], path);
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |c, i| {
        if (haystack[i] != c) return false;
    }
    return true;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn padTo(current: usize, target: usize) void {
    var i = current;
    while (i < target) {
        vga.putChar(' ');
        i += 1;
    }
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
