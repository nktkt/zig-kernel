// tmpfs — メモリバックドテンポラリファイルシステム (PMM ページ使用)

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

const MAX_INODES = 64;
const MAX_NAME = 28;
const MAX_FILE_SIZE = 4096; // 1 PMM ページ
const MAX_DIR_ENTRIES = 24;

// ---- 型定義 ----

pub const InodeKind = enum(u8) { free, file, directory };

pub const Stat = struct {
    size: usize,
    kind: InodeKind,
    permissions: u16, // rwxrwxrwx (9 bits) + setuid/setgid/sticky (3 bits)
    uid: u8,
    gid: u8,
    created: u64, // tick
    modified: u64, // tick
    inode_num: u8,
};

pub const DirEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    inode: u8,
    used: bool,
};

const Inode = struct {
    kind: InodeKind,
    size: usize,
    page_addr: usize, // PMM allocated page (files only)
    entries: [MAX_DIR_ENTRIES]DirEntry,
    parent: u8,
    permissions: u16,
    uid: u8,
    gid: u8,
    created: u64,
    modified: u64,
    link_count: u8,
};

// ---- グローバル状態 ----

var inodes: [MAX_INODES]Inode = undefined;
var initialized: bool = false;

// ---- 初期化 ----

pub fn init() void {
    for (&inodes) |*n| {
        n.kind = .free;
        n.size = 0;
        n.page_addr = 0;
        n.parent = 0;
        n.permissions = 0o755;
        n.uid = 0;
        n.gid = 0;
        n.created = 0;
        n.modified = 0;
        n.link_count = 0;
        for (&n.entries) |*e| e.used = false;
    }
    // inode 0 = root directory
    inodes[0].kind = .directory;
    inodes[0].parent = 0;
    inodes[0].permissions = 0o755;
    inodes[0].created = pit.getTicks();
    inodes[0].modified = pit.getTicks();
    inodes[0].link_count = 2; // . and self
    initialized = true;
    serial.write("[TMPFS] initialized\n");
}

// ---- inode 確保 ----

fn allocInode() ?u8 {
    for (&inodes, 0..) |*n, i| {
        if (n.kind == .free) return @truncate(i);
    }
    return null;
}

// ---- ファイル作成 ----

pub fn create(name: []const u8, parent: u32) ?u32 {
    if (!initialized) return null;
    if (name.len == 0 or name.len > MAX_NAME) return null;
    const par: u8 = @truncate(parent);
    if (par >= MAX_INODES or inodes[par].kind != .directory) return null;

    // 重複チェック
    if (lookupInDir(par, name) != null) return null;

    const ino = allocInode() orelse return null;

    // PMM ページ確保
    const page = pmm.alloc() orelse {
        return null;
    };

    // ページをゼロクリア
    const page_ptr: [*]u8 = @ptrFromInt(page);
    for (0..MAX_FILE_SIZE) |i| {
        page_ptr[i] = 0;
    }

    inodes[ino].kind = .file;
    inodes[ino].size = 0;
    inodes[ino].page_addr = page;
    inodes[ino].parent = par;
    inodes[ino].permissions = 0o644;
    inodes[ino].uid = 0;
    inodes[ino].gid = 0;
    inodes[ino].created = pit.getTicks();
    inodes[ino].modified = pit.getTicks();
    inodes[ino].link_count = 1;

    if (!addDirEntry(par, name, ino)) {
        pmm.free(page);
        inodes[ino].kind = .free;
        return null;
    }
    return ino;
}

// ---- ディレクトリ作成 ----

pub fn mkdir(name: []const u8, parent: u32) ?u32 {
    if (!initialized) return null;
    if (name.len == 0 or name.len > MAX_NAME) return null;
    const par: u8 = @truncate(parent);
    if (par >= MAX_INODES or inodes[par].kind != .directory) return null;

    if (lookupInDir(par, name) != null) return null;

    const ino = allocInode() orelse return null;

    inodes[ino].kind = .directory;
    inodes[ino].size = 0;
    inodes[ino].page_addr = 0;
    inodes[ino].parent = par;
    inodes[ino].permissions = 0o755;
    inodes[ino].uid = 0;
    inodes[ino].gid = 0;
    inodes[ino].created = pit.getTicks();
    inodes[ino].modified = pit.getTicks();
    inodes[ino].link_count = 2;
    for (&inodes[ino].entries) |*e| e.used = false;

    if (!addDirEntry(par, name, ino)) {
        inodes[ino].kind = .free;
        return null;
    }
    inodes[par].link_count += 1;
    return ino;
}

// ---- 読み取り ----

pub fn read(ino: u32, buf: []u8, offset: usize, len: usize) usize {
    if (!initialized) return 0;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind != .file) return 0;
    if (inodes[idx].page_addr == 0) return 0;
    if (offset >= inodes[idx].size) return 0;

    const available = inodes[idx].size - offset;
    const to_read = @min(len, @min(available, buf.len));
    const page_ptr: [*]const u8 = @ptrFromInt(inodes[idx].page_addr);
    @memcpy(buf[0..to_read], page_ptr[offset .. offset + to_read]);
    return to_read;
}

// ---- 書き込み ----

pub fn write(ino: u32, data: []const u8, offset: usize) usize {
    if (!initialized) return 0;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind != .file) return 0;
    if (inodes[idx].page_addr == 0) return 0;
    if (offset >= MAX_FILE_SIZE) return 0;

    const space = MAX_FILE_SIZE - offset;
    const to_write = @min(data.len, space);
    const page_ptr: [*]u8 = @ptrFromInt(inodes[idx].page_addr);
    @memcpy(page_ptr[offset .. offset + to_write], data[0..to_write]);

    const new_end = offset + to_write;
    if (new_end > inodes[idx].size) {
        inodes[idx].size = new_end;
    }
    inodes[idx].modified = pit.getTicks();
    return to_write;
}

// ---- 削除 ----

pub fn unlink(ino: u32) void {
    if (!initialized) return;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or idx == 0) return; // root は削除不可

    if (inodes[idx].kind == .directory) {
        // ディレクトリが空でない場合は削除不可
        for (&inodes[idx].entries) |*e| {
            if (e.used) return;
        }
        // 親のリンクカウント減少
        if (inodes[idx].parent < MAX_INODES) {
            if (inodes[inodes[idx].parent].link_count > 0) {
                inodes[inodes[idx].parent].link_count -= 1;
            }
        }
    }

    // ファイルの場合はページを解放
    if (inodes[idx].kind == .file and inodes[idx].page_addr != 0) {
        pmm.free(inodes[idx].page_addr);
        inodes[idx].page_addr = 0;
    }

    // 親ディレクトリからエントリ削除
    removeDirEntry(inodes[idx].parent, idx);
    inodes[idx].kind = .free;
}

// ---- stat ----

pub fn stat(ino: u32) ?Stat {
    if (!initialized) return null;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind == .free) return null;

    return Stat{
        .size = inodes[idx].size,
        .kind = inodes[idx].kind,
        .permissions = inodes[idx].permissions,
        .uid = inodes[idx].uid,
        .gid = inodes[idx].gid,
        .created = inodes[idx].created,
        .modified = inodes[idx].modified,
        .inode_num = idx,
    };
}

// ---- readdir ----

pub fn readdir(ino: u32) void {
    if (!initialized) return;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind != .directory) return;

    vga.setColor(.yellow, .black);
    vga.write("PERM       TYPE  NAME                     SIZE\n");
    vga.setColor(.light_grey, .black);

    for (&inodes[idx].entries) |*e| {
        if (!e.used) continue;
        const child = &inodes[e.inode];

        // パーミッション表示
        printPermBits(child.permissions);
        vga.write("  ");

        if (child.kind == .directory) {
            vga.setColor(.light_cyan, .black);
            vga.write("dir   ");
        } else {
            vga.setColor(.light_grey, .black);
            vga.write("file  ");
        }
        vga.write(e.name[0..e.name_len]);
        var pad = @as(usize, 25) -| e.name_len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
        if (child.kind == .file) {
            fmt.printDec(child.size);
        } else {
            vga.putChar('-');
        }
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
}

// ---- printTree ----

pub fn printTree(ino: u32, depth: u32) void {
    if (!initialized) return;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind != .directory) return;

    for (&inodes[idx].entries) |*e| {
        if (!e.used) continue;

        // インデント
        var d: u32 = 0;
        while (d < depth) : (d += 1) {
            vga.write("  ");
        }
        vga.write("|-- ");

        const child = &inodes[e.inode];
        if (child.kind == .directory) {
            vga.setColor(.light_cyan, .black);
            vga.write(e.name[0..e.name_len]);
            vga.write("/\n");
            vga.setColor(.light_grey, .black);
            // 再帰
            printTree(e.inode, depth + 1);
        } else {
            vga.setColor(.light_grey, .black);
            vga.write(e.name[0..e.name_len]);
            vga.write(" (");
            fmt.printDec(child.size);
            vga.write(")\n");
        }
    }
}

// ---- lookup ----

pub fn lookup(parent: u32, name: []const u8) ?u32 {
    if (!initialized) return null;
    const par: u8 = @truncate(parent);
    const result = lookupInDir(par, name);
    if (result) |r| return @as(u32, r);
    return null;
}

// ---- chmod / chown ----

pub fn chmod(ino: u32, permissions: u16) bool {
    if (!initialized) return false;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind == .free) return false;
    inodes[idx].permissions = permissions & 0o7777;
    inodes[idx].modified = pit.getTicks();
    return true;
}

pub fn chown(ino: u32, uid: u8, gid: u8) bool {
    if (!initialized) return false;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind == .free) return false;
    inodes[idx].uid = uid;
    inodes[idx].gid = gid;
    inodes[idx].modified = pit.getTicks();
    return true;
}

// ---- rename ----

pub fn rename(ino: u32, new_name: []const u8) bool {
    if (!initialized) return false;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind == .free) return false;
    if (new_name.len == 0 or new_name.len > MAX_NAME) return false;

    const par = inodes[idx].parent;
    // 親ディレクトリのエントリ名を更新
    for (&inodes[par].entries) |*e| {
        if (e.used and e.inode == idx) {
            e.name_len = @intCast(new_name.len);
            @memcpy(e.name[0..new_name.len], new_name);
            return true;
        }
    }
    return false;
}

// ---- truncate ----

pub fn truncate(ino: u32, new_size: usize) bool {
    if (!initialized) return false;
    const idx: u8 = @truncate(ino);
    if (idx >= MAX_INODES or inodes[idx].kind != .file) return false;
    if (new_size > MAX_FILE_SIZE) return false;

    if (new_size < inodes[idx].size and inodes[idx].page_addr != 0) {
        // ゼロフィル
        const page_ptr: [*]u8 = @ptrFromInt(inodes[idx].page_addr);
        var i = new_size;
        while (i < inodes[idx].size) : (i += 1) {
            page_ptr[i] = 0;
        }
    }
    inodes[idx].size = new_size;
    inodes[idx].modified = pit.getTicks();
    return true;
}

// ---- info ----

pub fn printInfo() void {
    if (!initialized) {
        vga.write("tmpfs: not initialized\n");
        return;
    }
    vga.setColor(.yellow, .black);
    vga.write("tmpfs Information:\n");
    vga.setColor(.light_grey, .black);

    var file_count: usize = 0;
    var dir_count: usize = 0;
    var total_size: usize = 0;

    for (&inodes) |*n| {
        if (n.kind == .file) {
            file_count += 1;
            total_size += n.size;
        } else if (n.kind == .directory) {
            dir_count += 1;
        }
    }

    vga.write("  Files:       ");
    fmt.printDec(file_count);
    vga.putChar('\n');
    vga.write("  Directories: ");
    fmt.printDec(dir_count);
    vga.putChar('\n');
    vga.write("  Total size:  ");
    fmt.printSize(total_size);
    vga.putChar('\n');
    vga.write("  Max inodes:  ");
    fmt.printDec(MAX_INODES);
    vga.putChar('\n');
    vga.write("  Max file:    ");
    fmt.printDec(MAX_FILE_SIZE);
    vga.write(" bytes\n");
}

pub fn isInitialized() bool {
    return initialized;
}

// ---- 内部ヘルパー ----

fn lookupInDir(dir: u8, name: []const u8) ?u8 {
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
            inodes[dir].modified = pit.getTicks();
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
            inodes[dir].modified = pit.getTicks();
            return;
        }
    }
}

fn printPermBits(perm: u16) void {
    const chars = "rwxrwxrwx";
    var i: u4 = 9;
    while (i > 0) {
        i -= 1;
        if (perm & (@as(u16, 1) << i) != 0) {
            vga.putChar(chars[8 - @as(usize, i)]);
        } else {
            vga.putChar('-');
        }
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
