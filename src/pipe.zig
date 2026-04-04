// パイプ IPC — プロセス間のデータストリーム

const MAX_PIPES = 8;
const PIPE_BUF_SIZE = 512;

pub const Pipe = struct {
    buf: [PIPE_BUF_SIZE]u8,
    read_pos: usize,
    write_pos: usize,
    count: usize,
    used: bool,
};

var pipes: [MAX_PIPES]Pipe = undefined;

pub fn init() void {
    for (&pipes) |*p| {
        p.used = false;
        p.count = 0;
        p.read_pos = 0;
        p.write_pos = 0;
    }
}

pub fn create() ?u16 {
    for (&pipes, 0..) |*p, i| {
        if (!p.used) {
            p.used = true;
            p.count = 0;
            p.read_pos = 0;
            p.write_pos = 0;
            return @truncate(i);
        }
    }
    return null;
}

pub fn writePipe(idx: u16, data: []const u8) usize {
    if (idx >= MAX_PIPES or !pipes[idx].used) return 0;
    const p = &pipes[idx];

    var written: usize = 0;
    for (data) |byte| {
        if (p.count >= PIPE_BUF_SIZE) break; // バッファフル
        p.buf[p.write_pos] = byte;
        p.write_pos = (p.write_pos + 1) % PIPE_BUF_SIZE;
        p.count += 1;
        written += 1;
    }
    return written;
}

pub fn readPipe(idx: u16, buf: []u8) usize {
    if (idx >= MAX_PIPES or !pipes[idx].used) return 0;
    const p = &pipes[idx];

    var bytes_read: usize = 0;
    while (bytes_read < buf.len and p.count > 0) {
        buf[bytes_read] = p.buf[p.read_pos];
        p.read_pos = (p.read_pos + 1) % PIPE_BUF_SIZE;
        p.count -= 1;
        bytes_read += 1;
    }
    return bytes_read;
}

pub fn destroy(idx: u16) void {
    if (idx < MAX_PIPES) {
        pipes[idx].used = false;
    }
}

pub fn available(idx: u16) usize {
    if (idx >= MAX_PIPES or !pipes[idx].used) return 0;
    return pipes[idx].count;
}
