// RAM ファイルシステム — メモリ上のシンプルなファイル管理

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");

const MAX_FILES = 16;
const MAX_NAME = 32;
pub const MAX_DATA = 2048;

pub const File = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    data: [MAX_DATA]u8,
    size: usize,
    used: bool,
};

var files: [MAX_FILES]File = undefined;

pub fn init() void {
    for (&files) |*f| {
        f.used = false;
        f.size = 0;
        f.name_len = 0;
    }
    // デフォルトファイル
    if (create("readme.txt")) |idx| {
        const msg = "Welcome to ZigOS!\nUse 'write <name> <text>' to create files.\n";
        _ = writeFile(idx, msg);
    }
}

pub fn create(name: []const u8) ?usize {
    if (name.len == 0 or name.len > MAX_NAME) return null;
    if (findByName(name) != null) return null;
    for (&files, 0..) |*f, i| {
        if (!f.used) {
            f.used = true;
            f.name_len = @intCast(name.len);
            @memcpy(f.name[0..name.len], name);
            f.size = 0;
            return i;
        }
    }
    return null;
}

pub fn findByName(name: []const u8) ?usize {
    for (&files, 0..) |*f, i| {
        if (f.used and f.name_len == name.len) {
            if (eql(f.name[0..f.name_len], name)) return i;
        }
    }
    return null;
}

pub fn readFile(idx: usize, buf: []u8) usize {
    if (idx >= MAX_FILES or !files[idx].used) return 0;
    const len = @min(buf.len, files[idx].size);
    @memcpy(buf[0..len], files[idx].data[0..len]);
    return len;
}

pub fn writeFile(idx: usize, data: []const u8) usize {
    if (idx >= MAX_FILES or !files[idx].used) return 0;
    const len = @min(data.len, MAX_DATA);
    @memcpy(files[idx].data[0..len], data[0..len]);
    files[idx].size = len;
    return len;
}

pub fn remove(idx: usize) void {
    if (idx < MAX_FILES) {
        files[idx].used = false;
        files[idx].size = 0;
    }
}

pub fn getFile(idx: usize) ?*const File {
    if (idx < MAX_FILES and files[idx].used) return &files[idx];
    return null;
}

pub fn fileCount() usize {
    var count: usize = 0;
    for (&files) |*f| {
        if (f.used) count += 1;
    }
    return count;
}

pub fn printList() void {
    vga.setColor(.yellow, .black);
    vga.write("NAME                             SIZE\n");
    vga.setColor(.light_grey, .black);
    for (&files) |*f| {
        if (!f.used) continue;
        vga.write(f.name[0..f.name_len]);
        var pad = @as(usize, 33) -| f.name_len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
        pmm.printNum(f.size);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
    pmm.printNum(fileCount());
    vga.write(" file(s)\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
