// ユーザー管理 — マルチユーザー認証とパーミッション

const vga = @import("vga.zig");

const MAX_USERS = 8;
const MAX_NAME = 16;
const MAX_PASS = 16;

pub const User = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    pass: [MAX_PASS]u8,
    pass_len: u8,
    uid: u16,
    gid: u16,
    used: bool,
};

var users: [MAX_USERS]User = undefined;
var current_uid: u16 = 0; // 0 = root

pub fn init() void {
    for (&users) |*u| {
        u.used = false;
    }
    // デフォルトユーザー
    _ = addUser("root", "", 0, 0);
    _ = addUser("guest", "guest", 1000, 1000);
    current_uid = 0; // root でスタート
}

pub fn addUser(name: []const u8, pass: []const u8, uid: u16, gid: u16) bool {
    for (&users) |*u| {
        if (!u.used) {
            u.used = true;
            u.uid = uid;
            u.gid = gid;
            u.name_len = @intCast(@min(name.len, MAX_NAME));
            @memcpy(u.name[0..u.name_len], name[0..u.name_len]);
            u.pass_len = @intCast(@min(pass.len, MAX_PASS));
            @memcpy(u.pass[0..u.pass_len], pass[0..u.pass_len]);
            return true;
        }
    }
    return false;
}

pub fn login(name: []const u8, pass: []const u8) bool {
    for (&users) |*u| {
        if (!u.used) continue;
        if (u.name_len != name.len) continue;
        if (!eql(u.name[0..u.name_len], name)) continue;
        // root は空パスワードでログイン可
        if (u.uid == 0 and u.pass_len == 0) {
            current_uid = 0;
            return true;
        }
        if (u.pass_len != pass.len) return false;
        if (eql(u.pass[0..u.pass_len], pass)) {
            current_uid = u.uid;
            return true;
        }
        return false;
    }
    return false;
}

pub fn switchUser(name: []const u8, pass: []const u8) bool {
    return login(name, pass);
}

pub fn getCurrentUid() u16 {
    return current_uid;
}

pub fn getCurrentName() []const u8 {
    for (&users) |*u| {
        if (u.used and u.uid == current_uid) {
            return u.name[0..u.name_len];
        }
    }
    return "unknown";
}

pub fn isRoot() bool {
    return current_uid == 0;
}

pub fn printUsers() void {
    vga.setColor(.yellow, .black);
    vga.write("UID   GID   NAME\n");
    vga.setColor(.light_grey, .black);
    for (&users) |*u| {
        if (!u.used) continue;
        printNum(u.uid);
        vga.write("     ");
        printNum(u.gid);
        vga.write("     ");
        if (u.uid == current_uid) {
            vga.setColor(.light_green, .black);
        }
        vga.write(u.name[0..u.name_len]);
        if (u.uid == current_uid) {
            vga.write(" *");
            vga.setColor(.light_grey, .black);
        }
        vga.putChar('\n');
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn printNum(n: u16) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [5]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
