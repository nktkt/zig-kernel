// RAM ファイルシステム — inode ベース、ディレクトリ階層対応

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");

const MAX_INODES = 32;
const MAX_NAME = 28;
pub const MAX_DATA = 2048;
const MAX_DIR_ENTRIES = 16;

pub const InodeKind = enum(u8) { free, file, directory };

pub const DirEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    inode: u8, // inode 番号
    used: bool,
};

pub const Inode = struct {
    kind: InodeKind,
    size: usize,
    data: [MAX_DATA]u8, // ファイルデータ
    entries: [MAX_DIR_ENTRIES]DirEntry, // ディレクトリエントリ
    parent: u8, // 親 inode 番号
};

var inodes: [MAX_INODES]Inode = undefined;
var cwd: u8 = 0; // カレントディレクトリ inode

pub fn init() void {
    for (&inodes) |*n| {
        n.kind = .free;
        n.size = 0;
        n.parent = 0;
        for (&n.entries) |*e| e.used = false;
    }
    // inode 0 = ルートディレクトリ
    inodes[0].kind = .directory;
    inodes[0].parent = 0;
    cwd = 0;

    // デフォルトファイル
    if (createFile("readme.txt", 0)) |idx| {
        const msg = "Welcome to ZigOS!\nUse 'write <name> <text>' to create files.\n";
        _ = writeFile(idx, msg);
    }
}

fn allocInode() ?u8 {
    for (&inodes, 0..) |*n, i| {
        if (n.kind == .free) return @truncate(i);
    }
    return null;
}

// ---- ファイル操作 ----

pub fn createFile(name: []const u8, dir: u8) ?usize {
    if (name.len == 0 or name.len > MAX_NAME) return null;
    if (lookupInDir(dir, name) != null) return null;

    const ino = allocInode() orelse return null;
    inodes[ino].kind = .file;
    inodes[ino].size = 0;
    inodes[ino].parent = dir;

    if (!addDirEntry(dir, name, ino)) {
        inodes[ino].kind = .free;
        return null;
    }
    return ino;
}

pub fn create(name: []const u8) ?usize {
    return createFile(name, cwd);
}

pub fn findByName(name: []const u8) ?usize {
    return lookupInDir(cwd, name);
}

pub fn readFile(idx: usize, buf: []u8) usize {
    if (idx >= MAX_INODES or inodes[idx].kind != .file) return 0;
    const len = @min(buf.len, inodes[idx].size);
    @memcpy(buf[0..len], inodes[idx].data[0..len]);
    return len;
}

pub fn writeFile(idx: usize, data: []const u8) usize {
    if (idx >= MAX_INODES or inodes[idx].kind != .file) return 0;
    const len = @min(data.len, MAX_DATA);
    @memcpy(inodes[idx].data[0..len], data[0..len]);
    inodes[idx].size = len;
    return len;
}

pub fn remove(idx: usize) void {
    if (idx >= MAX_INODES or idx == 0) return;
    if (inodes[idx].kind == .directory) {
        // ディレクトリが空でない場合は削除不可
        for (&inodes[idx].entries) |*e| {
            if (e.used) return;
        }
    }
    // 親ディレクトリからエントリ削除
    removeDirEntry(inodes[idx].parent, @truncate(idx));
    inodes[idx].kind = .free;
}

pub const File = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    data: [MAX_DATA]u8,
    size: usize,
    used: bool,
};

pub fn getFile(idx: usize) ?*const Inode {
    if (idx < MAX_INODES and inodes[idx].kind == .file) return &inodes[idx];
    return null;
}

// ---- ディレクトリ操作 ----

pub fn mkdir(name: []const u8) bool {
    return mkdirIn(name, cwd);
}

fn mkdirIn(name: []const u8, dir: u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    if (lookupInDir(dir, name) != null) return false;

    const ino = allocInode() orelse return false;
    inodes[ino].kind = .directory;
    inodes[ino].parent = dir;
    for (&inodes[ino].entries) |*e| e.used = false;

    if (!addDirEntry(dir, name, ino)) {
        inodes[ino].kind = .free;
        return false;
    }
    return true;
}

pub fn chdir(name: []const u8) bool {
    if (eql(name, "..")) {
        cwd = inodes[cwd].parent;
        return true;
    }
    if (eql(name, "/")) {
        cwd = 0;
        return true;
    }
    // パス解決
    const ino = resolvePath(name) orelse return false;
    if (inodes[ino].kind != .directory) return false;
    cwd = @truncate(ino);
    return true;
}

pub fn getCwd() u8 {
    return cwd;
}

pub fn getCwdPath(buf: *[128]u8) usize {
    if (cwd == 0) {
        buf[0] = '/';
        return 1;
    }
    // 逆順でパスを構築
    var parts: [8]u8 = undefined; // inode chain
    var depth: usize = 0;
    var c = cwd;
    while (c != 0 and depth < 8) {
        parts[depth] = c;
        depth += 1;
        c = inodes[c].parent;
    }
    var pos: usize = 0;
    var d = depth;
    while (d > 0) {
        d -= 1;
        buf[pos] = '/';
        pos += 1;
        // inode の名前を親から取得
        const name = getInodeName(inodes[parts[d]].parent, parts[d]);
        if (name.len > 0 and pos + name.len < 128) {
            @memcpy(buf[pos .. pos + name.len], name);
            pos += name.len;
        }
    }
    if (pos == 0) {
        buf[0] = '/';
        pos = 1;
    }
    return pos;
}

fn getInodeName(dir: u8, ino: u8) []const u8 {
    for (&inodes[dir].entries) |*e| {
        if (e.used and e.inode == ino) {
            return e.name[0..e.name_len];
        }
    }
    return "";
}

// ---- パス解決 ----

pub fn resolvePath(path: []const u8) ?usize {
    if (path.len == 0) return cwd;

    var dir: u8 = cwd;
    if (path[0] == '/') dir = 0;

    var start: usize = 0;
    while (start < path.len) {
        while (start < path.len and path[start] == '/') start += 1;
        if (start >= path.len) break;
        var end = start;
        while (end < path.len and path[end] != '/') end += 1;
        const component = path[start..end];

        if (eql(component, ".")) {
            // 現在のディレクトリ
        } else if (eql(component, "..")) {
            dir = inodes[dir].parent;
        } else {
            const ino = lookupInDir(dir, component) orelse return null;
            dir = @truncate(ino);
        }
        start = end;
    }
    return dir;
}

// ---- ディレクトリエントリ操作 ----

fn lookupInDir(dir: u8, name: []const u8) ?usize {
    if (dir >= MAX_INODES or inodes[dir].kind != .directory) return null;
    for (&inodes[dir].entries) |*e| {
        if (e.used and e.name_len == name.len and eql(e.name[0..e.name_len], name)) {
            return e.inode;
        }
    }
    return null;
}

fn addDirEntry(dir: u8, name: []const u8, ino: u8) bool {
    if (dir >= MAX_INODES or inodes[dir].kind != .directory) return false;
    for (&inodes[dir].entries) |*e| {
        if (!e.used) {
            e.used = true;
            e.inode = ino;
            e.name_len = @intCast(@min(name.len, MAX_NAME));
            @memcpy(e.name[0..e.name_len], name[0..e.name_len]);
            return true;
        }
    }
    return false;
}

fn removeDirEntry(dir: u8, ino: u8) void {
    if (dir >= MAX_INODES) return;
    for (&inodes[dir].entries) |*e| {
        if (e.used and e.inode == ino) {
            e.used = false;
            return;
        }
    }
}

// ---- 表示 ----

pub fn fileCount() usize {
    var count: usize = 0;
    for (&inodes[cwd].entries) |*e| {
        if (e.used) count += 1;
    }
    return count;
}

pub fn printList() void {
    vga.setColor(.yellow, .black);
    vga.write("TYPE  NAME                         SIZE\n");
    vga.setColor(.light_grey, .black);
    for (&inodes[cwd].entries) |*e| {
        if (!e.used) continue;
        const ino = &inodes[e.inode];
        if (ino.kind == .directory) {
            vga.setColor(.light_cyan, .black);
            vga.write("dir   ");
        } else {
            vga.setColor(.light_grey, .black);
            vga.write("file  ");
        }
        vga.write(e.name[0..e.name_len]);
        var pad = @as(usize, 29) -| e.name_len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
        if (ino.kind == .file) {
            pmm.printNum(ino.size);
        } else {
            vga.write("-");
        }
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
    pmm.printNum(fileCount());
    vga.write(" item(s)\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
