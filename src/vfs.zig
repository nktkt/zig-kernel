// 仮想ファイルシステム — 統一的なファイル操作インタフェース

const ramfs = @import("ramfs.zig");
const fat16 = @import("fat16.zig");
const pipe = @import("pipe.zig");
const vga = @import("vga.zig");

pub const MAX_FDS = 32;

pub const FdKind = enum(u8) {
    none,
    ramfs,
    fat16_ro,
    pipe_read,
    pipe_write,
    socket,
};

pub const FileDesc = struct {
    kind: FdKind,
    index: u16, // ramfs index, pipe index, etc.
    offset: u32, // 現在の読み取り位置
    flags: u8, // 0x01=readable, 0x02=writable
};

var fd_table: [MAX_FDS]FileDesc = undefined;

pub fn init() void {
    for (&fd_table) |*fd| {
        fd.kind = .none;
    }
    // stdin(0), stdout(1), stderr(2) を予約
    fd_table[0] = .{ .kind = .none, .index = 0, .offset = 0, .flags = 0x01 };
    fd_table[1] = .{ .kind = .none, .index = 0, .offset = 0, .flags = 0x02 };
    fd_table[2] = .{ .kind = .none, .index = 0, .offset = 0, .flags = 0x02 };
}

fn allocFd() ?u32 {
    // 0-2 は予約済み
    for (fd_table[3..], 3..) |*fd, i| {
        if (fd.kind == .none) return @truncate(i);
    }
    return null;
}

pub fn open(path: []const u8, flags: u8) ?u32 {
    const fd_num = allocFd() orelse return null;

    // /disk/ プレフィクスで FAT16
    if (path.len > 6 and eql(path[0..6], "/disk/")) {
        // FAT16 は読み取り専用
        const fname = path[6..];
        // ファイル存在確認 (読んでみる)
        var check_buf: [2048]u8 = undefined;
        if (fat16.readFile(fname, &check_buf) != null) {
            fd_table[fd_num] = .{
                .kind = .fat16_ro,
                .index = 0, // FAT16 は名前ベースで都度読む
                .offset = 0,
                .flags = 0x01, // read-only
            };
            // パスを保存する手段がないため、fat16_ro は cat コマンドで直接使う
            return fd_num;
        }
        return null;
    }

    // RAMFS
    var idx: ?usize = ramfs.findByName(path);
    if (idx == null and (flags & 0x02 != 0)) {
        // 書き込みモードで新規作成
        idx = ramfs.create(path);
    }
    if (idx) |i| {
        fd_table[fd_num] = .{
            .kind = .ramfs,
            .index = @truncate(i),
            .offset = 0,
            .flags = flags,
        };
        return fd_num;
    }
    return null;
}

pub fn read(fd_num: u32, buf: []u8) ?usize {
    if (fd_num >= MAX_FDS) return null;
    const fd = &fd_table[fd_num];
    switch (fd.kind) {
        .ramfs => {
            const file = ramfs.getFile(fd.index) orelse return null;
            if (fd.offset >= file.size) return 0;
            const remaining = file.size - fd.offset;
            const len = @min(buf.len, remaining);
            @memcpy(buf[0..len], file.data[fd.offset .. fd.offset + len]);
            fd.offset += @truncate(len);
            return len;
        },
        .pipe_read => {
            return pipe.readPipe(fd.index, buf);
        },
        else => return null,
    }
}

pub fn write(fd_num: u32, data: []const u8) ?usize {
    if (fd_num >= MAX_FDS) return null;
    const fd = &fd_table[fd_num];
    switch (fd.kind) {
        .ramfs => {
            if (fd.flags & 0x02 == 0) return null; // not writable
            return ramfs.writeFile(fd.index, data);
        },
        .pipe_write => {
            return pipe.writePipe(fd.index, data);
        },
        else => return null,
    }
}

pub fn close(fd_num: u32) void {
    if (fd_num >= MAX_FDS or fd_num < 3) return;
    fd_table[fd_num].kind = .none;
}

pub fn stat(path: []const u8) ?FileStat {
    if (ramfs.findByName(path)) |idx| {
        if (ramfs.getFile(idx)) |f| {
            return .{
                .size = f.size,
                .kind = .file,
                .permissions = 0o644,
            };
        }
    }
    return null;
}

pub const FileKind = enum { file, directory, pipe, socket };

pub const FileStat = struct {
    size: usize,
    kind: FileKind,
    permissions: u16,
};

pub fn openPipe() ?[2]u32 {
    const pipe_idx = pipe.create() orelse return null;
    const read_fd = allocFd() orelse return null;
    const write_fd = allocFd() orelse {
        fd_table[read_fd].kind = .none;
        return null;
    };
    fd_table[read_fd] = .{
        .kind = .pipe_read,
        .index = pipe_idx,
        .offset = 0,
        .flags = 0x01,
    };
    fd_table[write_fd] = .{
        .kind = .pipe_write,
        .index = pipe_idx,
        .offset = 0,
        .flags = 0x02,
    };
    return .{ read_fd, write_fd };
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
