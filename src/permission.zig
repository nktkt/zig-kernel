// ファイルパーミッションシステム — Unix 風の rwxrwxrwx + 特殊ビット

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- パーミッションビット定数 ----

// 基本パーミッション (9 ビット)
pub const S_IRUSR: u16 = 0o400; // owner read
pub const S_IWUSR: u16 = 0o200; // owner write
pub const S_IXUSR: u16 = 0o100; // owner execute
pub const S_IRGRP: u16 = 0o040; // group read
pub const S_IWGRP: u16 = 0o020; // group write
pub const S_IXGRP: u16 = 0o010; // group execute
pub const S_IROTH: u16 = 0o004; // other read
pub const S_IWOTH: u16 = 0o002; // other write
pub const S_IXOTH: u16 = 0o001; // other execute

// 特殊ビット (3 ビット)
pub const S_ISUID: u16 = 0o4000; // set-user-ID
pub const S_ISGID: u16 = 0o2000; // set-group-ID
pub const S_ISVTX: u16 = 0o1000; // sticky bit

// 組み合わせ
pub const S_IRWXU: u16 = S_IRUSR | S_IWUSR | S_IXUSR; // owner rwx
pub const S_IRWXG: u16 = S_IRGRP | S_IWGRP | S_IXGRP; // group rwx
pub const S_IRWXO: u16 = S_IROTH | S_IWOTH | S_IXOTH; // other rwx

// ---- アクセスタイプ ----

pub const Access = enum(u8) {
    READ = 4,
    WRITE = 2,
    EXEC = 1,
};

// ---- umask ----

pub var umask_val: u16 = 0o022;

// ---- よく使うモード ----

pub const MODE_644: u16 = 0o644; // rw-r--r--
pub const MODE_755: u16 = 0o755; // rwxr-xr-x
pub const MODE_777: u16 = 0o777; // rwxrwxrwx
pub const MODE_700: u16 = 0o700; // rwx------
pub const MODE_600: u16 = 0o600; // rw-------
pub const MODE_444: u16 = 0o444; // r--r--r--
pub const MODE_555: u16 = 0o555; // r-xr-xr-x
pub const MODE_750: u16 = 0o750; // rwxr-x---
pub const MODE_640: u16 = 0o640; // rw-r-----

// ---- パーミッションチェック ----

pub fn check(file_perm: u16, uid: u8, gid: u8, file_uid: u8, file_gid: u8, access: Access) bool {
    // root は常にアクセス可能
    if (uid == 0) return true;

    const access_bits: u16 = @intFromEnum(access);

    // owner チェック
    if (uid == file_uid) {
        const owner_bits = (file_perm >> 6) & 0o7;
        return (owner_bits & access_bits) == access_bits;
    }

    // group チェック
    if (gid == file_gid) {
        const group_bits = (file_perm >> 3) & 0o7;
        return (group_bits & access_bits) == access_bits;
    }

    // other チェック
    const other_bits = file_perm & 0o7;
    return (other_bits & access_bits) == access_bits;
}

// ---- 複合アクセスチェック ----

pub fn checkMultiple(file_perm: u16, uid: u8, gid: u8, file_uid: u8, file_gid: u8, read: bool, write_flag: bool, exec: bool) bool {
    if (read and !check(file_perm, uid, gid, file_uid, file_gid, .READ)) return false;
    if (write_flag and !check(file_perm, uid, gid, file_uid, file_gid, .WRITE)) return false;
    if (exec and !check(file_perm, uid, gid, file_uid, file_gid, .EXEC)) return false;
    return true;
}

// ---- toOctal ----

pub fn toOctal(perm: u16) u16 {
    // 既にオクタル表現なのでそのまま返す
    return perm & 0o7777;
}

// ---- fromOctal ----

pub fn fromOctal(octal: u16) u16 {
    return octal & 0o7777;
}

// ---- toString ----

pub fn toString(perm: u16, buf: *[10]u8) []u8 {
    // "rwxrwxrwx" (9 文字) + 特殊ビット反映

    // Owner
    buf[0] = if (perm & S_IRUSR != 0) 'r' else '-';
    buf[1] = if (perm & S_IWUSR != 0) 'w' else '-';
    if (perm & S_ISUID != 0) {
        buf[2] = if (perm & S_IXUSR != 0) 's' else 'S';
    } else {
        buf[2] = if (perm & S_IXUSR != 0) 'x' else '-';
    }

    // Group
    buf[3] = if (perm & S_IRGRP != 0) 'r' else '-';
    buf[4] = if (perm & S_IWGRP != 0) 'w' else '-';
    if (perm & S_ISGID != 0) {
        buf[5] = if (perm & S_IXGRP != 0) 's' else 'S';
    } else {
        buf[5] = if (perm & S_IXGRP != 0) 'x' else '-';
    }

    // Other
    buf[6] = if (perm & S_IROTH != 0) 'r' else '-';
    buf[7] = if (perm & S_IWOTH != 0) 'w' else '-';
    if (perm & S_ISVTX != 0) {
        buf[8] = if (perm & S_IXOTH != 0) 't' else 'T';
    } else {
        buf[8] = if (perm & S_IXOTH != 0) 'x' else '-';
    }

    buf[9] = 0;
    return buf[0..9];
}

// ---- fromString ----

pub fn fromString(str: []const u8) ?u16 {
    if (str.len < 9) return null;

    var perm: u16 = 0;

    // Owner
    if (str[0] == 'r') perm |= S_IRUSR;
    if (str[1] == 'w') perm |= S_IWUSR;
    if (str[2] == 'x' or str[2] == 's') perm |= S_IXUSR;
    if (str[2] == 's' or str[2] == 'S') perm |= S_ISUID;

    // Group
    if (str[3] == 'r') perm |= S_IRGRP;
    if (str[4] == 'w') perm |= S_IWGRP;
    if (str[5] == 'x' or str[5] == 's') perm |= S_IXGRP;
    if (str[5] == 's' or str[5] == 'S') perm |= S_ISGID;

    // Other
    if (str[6] == 'r') perm |= S_IROTH;
    if (str[7] == 'w') perm |= S_IWOTH;
    if (str[8] == 'x' or str[8] == 't') perm |= S_IXOTH;
    if (str[8] == 't' or str[8] == 'T') perm |= S_ISVTX;

    return perm;
}

// ---- chmod ----

pub fn chmod(_: u16, mode: u16) u16 {
    // mode を直接設定
    return mode & 0o7777;
}

// ---- chmod symbolic ----

pub fn chmodAdd(perm: u16, bits: u16) u16 {
    return (perm | bits) & 0o7777;
}

pub fn chmodRemove(perm: u16, bits: u16) u16 {
    return (perm & ~bits) & 0o7777;
}

pub fn chmodToggle(perm: u16, bits: u16) u16 {
    return (perm ^ bits) & 0o7777;
}

// ---- applyUmask ----

pub fn applyUmask(perm: u16) u16 {
    return perm & ~umask_val & 0o7777;
}

// ---- setUmask ----

pub fn setUmask(mask: u16) void {
    umask_val = mask & 0o7777;
}

// ---- getUmask ----

pub fn getUmask() u16 {
    return umask_val;
}

// ---- parseOctalString ----

pub fn parseOctalString(str: []const u8) ?u16 {
    if (str.len == 0 or str.len > 4) return null;
    var val: u16 = 0;
    for (str) |c| {
        if (c < '0' or c > '7') return null;
        val = val * 8 + (c - '0');
    }
    return val;
}

// ---- printPermission (colored) ----

pub fn printPermission(perm: u16) void {
    var buf: [10]u8 = undefined;
    const str = toString(perm, &buf);

    // Owner (赤系)
    vga.setColor(.light_red, .black);
    vga.write(str[0..3]);

    // Group (緑系)
    vga.setColor(.light_green, .black);
    vga.write(str[3..6]);

    // Other (青系)
    vga.setColor(.light_blue, .black);
    vga.write(str[6..9]);

    // オクタル表示
    vga.setColor(.dark_grey, .black);
    vga.write(" (");
    printOctal(perm);
    vga.putChar(')');

    vga.setColor(.light_grey, .black);
}

fn printOctal(val: u16) void {
    const masked = val & 0o7777;

    // 特殊ビットがあれば 4 桁
    if (masked > 0o777) {
        vga.putChar('0' + @as(u8, @truncate((masked >> 9) & 0o7)));
    }
    vga.putChar('0' + @as(u8, @truncate((masked >> 6) & 0o7)));
    vga.putChar('0' + @as(u8, @truncate((masked >> 3) & 0o7)));
    vga.putChar('0' + @as(u8, @truncate(masked & 0o7)));
}

// ---- printPermissionTable ----

pub fn printPermissionTable() void {
    vga.setColor(.yellow, .black);
    vga.write("Permission Reference:\n");
    vga.setColor(.light_grey, .black);

    const modes = [_]struct { mode: u16, desc: []const u8 }{
        .{ .mode = 0o755, .desc = "Standard executable" },
        .{ .mode = 0o644, .desc = "Standard file" },
        .{ .mode = 0o777, .desc = "Full access" },
        .{ .mode = 0o700, .desc = "Owner only" },
        .{ .mode = 0o600, .desc = "Owner read/write" },
        .{ .mode = 0o444, .desc = "Read only" },
        .{ .mode = 0o555, .desc = "Read/execute" },
        .{ .mode = 0o750, .desc = "Owner full, group r/x" },
        .{ .mode = 0o4755, .desc = "Setuid executable" },
        .{ .mode = 0o2755, .desc = "Setgid executable" },
        .{ .mode = 0o1777, .desc = "Sticky bit (e.g. /tmp)" },
    };

    for (modes) |m| {
        vga.write("  ");
        printPermission(m.mode);
        vga.write("  ");
        vga.write(m.desc);
        vga.putChar('\n');
    }
}

// ---- isReadable / isWritable / isExecutable ----

pub fn isReadable(perm: u16, who: u2) bool {
    const shift: u4 = switch (who) {
        0 => 6, // owner
        1 => 3, // group
        2 => 0, // other
        3 => 0,
    };
    return ((perm >> shift) & 0o4) != 0;
}

pub fn isWritable(perm: u16, who: u2) bool {
    const shift: u4 = switch (who) {
        0 => 6,
        1 => 3,
        2 => 0,
        3 => 0,
    };
    return ((perm >> shift) & 0o2) != 0;
}

pub fn isExecutable(perm: u16, who: u2) bool {
    const shift: u4 = switch (who) {
        0 => 6,
        1 => 3,
        2 => 0,
        3 => 0,
    };
    return ((perm >> shift) & 0o1) != 0;
}

// ---- hasSetuid / hasSetgid / hasSticky ----

pub fn hasSetuid(perm: u16) bool {
    return (perm & S_ISUID) != 0;
}

pub fn hasSetgid(perm: u16) bool {
    return (perm & S_ISGID) != 0;
}

pub fn hasSticky(perm: u16) bool {
    return (perm & S_ISVTX) != 0;
}

// ---- printUmask ----

pub fn printUmask() void {
    vga.write("umask: ");
    printOctal(umask_val);
    vga.putChar('\n');
    vga.write("  Default file mode:  ");
    printPermission(applyUmask(0o666));
    vga.putChar('\n');
    vga.write("  Default dir mode:   ");
    printPermission(applyUmask(0o777));
    vga.putChar('\n');
}
