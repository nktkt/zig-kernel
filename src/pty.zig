// 疑似端末 (PTY) — マスター/スレーブペアによるターミナルエミュレーション

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

const MAX_PTYS = 4;
const RING_BUF_SIZE = 256;

// ---- ターミナル属性 ----

pub const TermMode = enum(u8) {
    canonical, // 行バッファモード (改行まで蓄積)
    raw, // 生モード (即座に転送)
    echo_only, // エコーのみ
};

pub const Attr = struct {
    mode: TermMode,
    echo: bool, // 入力をエコーバック
    icrnl: bool, // CR -> NL 変換
    onlcr: bool, // NL -> CR+NL 変換
    isig: bool, // シグナル文字の処理 (Ctrl+C 等)
    icanon: bool, // canonical モード
    opost: bool, // 出力処理
    erase_char: u8, // バックスペース文字
    kill_char: u8, // 行キル文字
    eof_char: u8, // EOF 文字
    intr_char: u8, // 割り込み文字 (Ctrl+C)
};

pub const WinSize = struct {
    rows: u16,
    cols: u16,
};

// ---- リングバッファ ----

const RingBuffer = struct {
    buf: [RING_BUF_SIZE]u8,
    read_pos: usize,
    write_pos: usize,
    count: usize,

    fn init_buf() RingBuffer {
        return .{
            .buf = [_]u8{0} ** RING_BUF_SIZE,
            .read_pos = 0,
            .write_pos = 0,
            .count = 0,
        };
    }

    fn writeOne(self: *RingBuffer, byte: u8) bool {
        if (self.count >= RING_BUF_SIZE) return false;
        self.buf[self.write_pos] = byte;
        self.write_pos = (self.write_pos + 1) % RING_BUF_SIZE;
        self.count += 1;
        return true;
    }

    fn readOne(self: *RingBuffer) ?u8 {
        if (self.count == 0) return null;
        const byte = self.buf[self.read_pos];
        self.read_pos = (self.read_pos + 1) % RING_BUF_SIZE;
        self.count -= 1;
        return byte;
    }

    fn available(self: *const RingBuffer) usize {
        return self.count;
    }

    fn freeSpace(self: *const RingBuffer) usize {
        return RING_BUF_SIZE - self.count;
    }

    fn flush(self: *RingBuffer) void {
        self.read_pos = 0;
        self.write_pos = 0;
        self.count = 0;
    }

    fn peek(self: *const RingBuffer) ?u8 {
        if (self.count == 0) return null;
        return self.buf[self.read_pos];
    }
};

// ---- PTY ペア ----

const PtyPair = struct {
    used: bool,
    master_to_slave: RingBuffer, // マスターが書き込み -> スレーブが読み取り
    slave_to_master: RingBuffer, // スレーブが書き込み -> マスターが読み取り
    attr: Attr,
    winsize: WinSize,
    master_open: bool,
    slave_open: bool,
    created: u64, // 作成時のtick
    session_id: u8, // セッション ID
    // canonical モード用の行バッファ
    line_buf: [RING_BUF_SIZE]u8,
    line_len: usize,
};

// ---- グローバル状態 ----

var ptys: [MAX_PTYS]PtyPair = undefined;
var initialized: bool = false;

// ---- デフォルト属性 ----

fn defaultAttr() Attr {
    return .{
        .mode = .canonical,
        .echo = true,
        .icrnl = true,
        .onlcr = true,
        .isig = true,
        .icanon = true,
        .opost = true,
        .erase_char = 0x7F, // DEL
        .kill_char = 0x15, // Ctrl+U
        .eof_char = 0x04, // Ctrl+D
        .intr_char = 0x03, // Ctrl+C
    };
}

fn defaultWinSize() WinSize {
    return .{
        .rows = 25,
        .cols = 80,
    };
}

// ---- 初期化 ----

pub fn init() void {
    for (&ptys) |*p| {
        p.used = false;
        p.master_to_slave = RingBuffer.init_buf();
        p.slave_to_master = RingBuffer.init_buf();
        p.attr = defaultAttr();
        p.winsize = defaultWinSize();
        p.master_open = false;
        p.slave_open = false;
        p.created = 0;
        p.session_id = 0;
        p.line_len = 0;
    }
    initialized = true;
    serial.write("[PTY] initialized\n");
}

// ---- マスター開設 ----

pub fn openMaster() ?u8 {
    if (!initialized) return null;

    for (&ptys, 0..) |*p, i| {
        if (!p.used) {
            p.used = true;
            p.master_open = true;
            p.slave_open = false;
            p.master_to_slave.flush();
            p.slave_to_master.flush();
            p.attr = defaultAttr();
            p.winsize = defaultWinSize();
            p.created = pit.getTicks();
            p.session_id = @truncate(i);
            p.line_len = 0;
            return @truncate(i);
        }
    }
    return null;
}

// ---- スレーブ開設 ----

pub fn openSlave(master_id: u8) ?u8 {
    if (!initialized) return null;
    if (master_id >= MAX_PTYS) return null;
    if (!ptys[master_id].used or !ptys[master_id].master_open) return null;

    ptys[master_id].slave_open = true;
    return master_id; // スレーブ ID = マスター ID
}

// ---- マスターから読み取り (スレーブが書いたデータ) ----

pub fn readMaster(id: u8, buf: []u8) usize {
    if (id >= MAX_PTYS or !ptys[id].used or !ptys[id].master_open) return 0;
    const p = &ptys[id];

    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        const byte = p.slave_to_master.readOne() orelse break;
        buf[bytes_read] = byte;
        bytes_read += 1;
    }
    return bytes_read;
}

// ---- マスターへ書き込み (スレーブが読むデータ) ----

pub fn writeMaster(id: u8, data: []const u8) usize {
    if (id >= MAX_PTYS or !ptys[id].used or !ptys[id].master_open) return 0;
    const p = &ptys[id];

    var written: usize = 0;
    for (data) |byte| {
        var ch = byte;

        // CR -> NL 変換
        if (p.attr.icrnl and ch == '\r') ch = '\n';

        if (!p.master_to_slave.writeOne(ch)) break;
        written += 1;

        // canonical モードでの行処理
        if (p.attr.icanon and ch == '\n') {
            // 行バッファをフラッシュ (すでにリングバッファに入れている)
        }

        // エコー
        if (p.attr.echo and p.slave_open) {
            if (p.attr.onlcr and ch == '\n') {
                _ = p.slave_to_master.writeOne('\r');
            }
            _ = p.slave_to_master.writeOne(ch);
        }
    }
    return written;
}

// ---- スレーブから読み取り (マスターが書いたデータ) ----

pub fn readSlave(id: u8, buf: []u8) usize {
    if (id >= MAX_PTYS or !ptys[id].used or !ptys[id].slave_open) return 0;
    const p = &ptys[id];

    if (p.attr.icanon) {
        // canonical モード: 改行が来るまで待つ
        // ただしノンブロッキングなので、改行があるかチェック
        if (!hasNewline(&p.master_to_slave)) return 0;

        // 改行まで読み取り
        var bytes_read: usize = 0;
        while (bytes_read < buf.len) {
            const byte = p.master_to_slave.readOne() orelse break;
            buf[bytes_read] = byte;
            bytes_read += 1;
            if (byte == '\n') break;
        }
        return bytes_read;
    } else {
        // raw モード: 即座に返す
        var bytes_read: usize = 0;
        while (bytes_read < buf.len) {
            const byte = p.master_to_slave.readOne() orelse break;
            buf[bytes_read] = byte;
            bytes_read += 1;
        }
        return bytes_read;
    }
}

// ---- スレーブへ書き込み (マスターが読むデータ) ----

pub fn writeSlave(id: u8, data: []const u8) usize {
    if (id >= MAX_PTYS or !ptys[id].used or !ptys[id].slave_open) return 0;
    const p = &ptys[id];

    var written: usize = 0;
    for (data) |byte| {
        const ch = byte;
        // 出力処理
        if (p.attr.opost and p.attr.onlcr and ch == '\n') {
            if (!p.slave_to_master.writeOne('\r')) break;
        }
        if (!p.slave_to_master.writeOne(ch)) break;
        written += 1;
    }
    return written;
}

// ---- 汎用 read/write (ID ベース) ----

pub fn read(id: u8, buf: []u8) usize {
    // マスター側の読み取りとして使う
    return readMaster(id, buf);
}

pub fn write(id: u8, data: []const u8) usize {
    // マスター側の書き込みとして使う
    return writeMaster(id, data);
}

// ---- 属性 ----

pub fn setAttr(id: u8, attr: Attr) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].attr = attr;
}

pub fn getAttr(id: u8) Attr {
    if (id >= MAX_PTYS or !ptys[id].used) return defaultAttr();
    return ptys[id].attr;
}

// ---- ウィンドウサイズ ----

pub fn setWinSize(id: u8, rows: u16, cols: u16) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].winsize.rows = rows;
    ptys[id].winsize.cols = cols;
}

pub fn getWinSize(id: u8) WinSize {
    if (id >= MAX_PTYS or !ptys[id].used) return defaultWinSize();
    return ptys[id].winsize;
}

// ---- モード切替 ----

pub fn setRawMode(id: u8) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].attr.mode = .raw;
    ptys[id].attr.echo = false;
    ptys[id].attr.icanon = false;
    ptys[id].attr.isig = false;
    ptys[id].attr.icrnl = false;
    ptys[id].attr.opost = false;
}

pub fn setCanonicalMode(id: u8) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].attr.mode = .canonical;
    ptys[id].attr.echo = true;
    ptys[id].attr.icanon = true;
    ptys[id].attr.isig = true;
    ptys[id].attr.icrnl = true;
    ptys[id].attr.opost = true;
}

// ---- 閉じる ----

pub fn close(id: u8) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].master_open = false;
    ptys[id].slave_open = false;
    ptys[id].used = false;
    ptys[id].master_to_slave.flush();
    ptys[id].slave_to_master.flush();
}

pub fn closeMaster(id: u8) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].master_open = false;
    if (!ptys[id].slave_open) {
        ptys[id].used = false;
    }
}

pub fn closeSlave(id: u8) void {
    if (id >= MAX_PTYS or !ptys[id].used) return;
    ptys[id].slave_open = false;
    if (!ptys[id].master_open) {
        ptys[id].used = false;
    }
}

// ---- バッファ状態 ----

pub fn masterReadable(id: u8) usize {
    if (id >= MAX_PTYS or !ptys[id].used) return 0;
    return ptys[id].slave_to_master.available();
}

pub fn slaveReadable(id: u8) usize {
    if (id >= MAX_PTYS or !ptys[id].used) return 0;
    return ptys[id].master_to_slave.available();
}

// ---- 表示 ----

pub fn printPtys() void {
    if (!initialized) {
        vga.write("PTY: not initialized\n");
        return;
    }

    vga.setColor(.yellow, .black);
    vga.write("ID  STATE     MODE        WINSIZE   M->S   S->M   AGE\n");
    vga.setColor(.light_grey, .black);

    var active: usize = 0;
    for (&ptys, 0..) |*p, i| {
        if (!p.used) continue;
        active += 1;

        // ID
        fmt.printDec(i);
        vga.write("   ");

        // State
        if (p.master_open and p.slave_open) {
            vga.setColor(.light_green, .black);
            vga.write("open      ");
        } else if (p.master_open) {
            vga.setColor(.yellow, .black);
            vga.write("master    ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("closing   ");
        }
        vga.setColor(.light_grey, .black);

        // Mode
        switch (p.attr.mode) {
            .canonical => vga.write("canonical   "),
            .raw => vga.write("raw         "),
            .echo_only => vga.write("echo        "),
        }

        // Window size
        fmt.printDec(p.winsize.rows);
        vga.putChar('x');
        fmt.printDec(p.winsize.cols);
        vga.write("   ");

        // Buffer counts
        fmt.printDecPadded(p.master_to_slave.available(), 4);
        vga.write("   ");
        fmt.printDecPadded(p.slave_to_master.available(), 4);
        vga.write("   ");

        // Age
        const age_ticks = pit.getTicks() - p.created;
        const age_secs = age_ticks / 1000;
        fmt.printDec(age_secs);
        vga.write("s");
        vga.putChar('\n');
    }

    if (active == 0) {
        vga.write("  No active PTYs\n");
    }

    vga.setColor(.light_grey, .black);
    vga.write("Active: ");
    fmt.printDec(active);
    vga.write("/");
    fmt.printDec(MAX_PTYS);
    vga.putChar('\n');
}

// ---- ヘルパー ----

fn hasNewline(rb: *const RingBuffer) bool {
    if (rb.count == 0) return false;
    var pos = rb.read_pos;
    var i: usize = 0;
    while (i < rb.count) : (i += 1) {
        if (rb.buf[pos] == '\n') return true;
        pos = (pos + 1) % RING_BUF_SIZE;
    }
    return false;
}
