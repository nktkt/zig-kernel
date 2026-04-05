// TTY/ターミナルサブシステム — 複数仮想端末、入力バッファリング、エコー/正規モード
// tty0-tty3 の 4 つの仮想ターミナルをサポート

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");

// ---- 定数 ----

pub const MAX_TTYS = 4;
const INPUT_BUF_SIZE = 256;
const OUTPUT_BUF_SIZE = 2048;
const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;

// ---- TTY 構造体 ----

pub const Tty = struct {
    // 入力リングバッファ
    input_buf: [INPUT_BUF_SIZE]u8,
    input_head: usize,
    input_tail: usize,
    input_count: usize,

    // ラインエディット用バッファ (canonical モード)
    line_buf: [INPUT_BUF_SIZE]u8,
    line_len: usize,
    line_ready: bool, // Enter が押されてラインが準備完了

    // 画面バッファ (非アクティブ TTY の画面内容を保存)
    screen_buf: [VGA_WIDTH * VGA_HEIGHT]u16,
    cursor_row: usize,
    cursor_col: usize,

    // モード設定
    echo: bool, // エコーバック
    canonical: bool, // 正規モード (行単位) / raw モード (即時)
    active: bool, // この TTY が作成済みか

    // 統計
    chars_in: u32,
    chars_out: u32,
};

var ttys: [MAX_TTYS]Tty = undefined;
var active_tty: u8 = 0;
var initialized: bool = false;

// ---- 初期化 ----

pub fn init() void {
    for (&ttys, 0..) |*t, i| {
        t.input_head = 0;
        t.input_tail = 0;
        t.input_count = 0;
        t.line_len = 0;
        t.line_ready = false;
        t.cursor_row = 0;
        t.cursor_col = 0;
        t.echo = true;
        t.canonical = true;
        t.active = (i == 0); // tty0 のみ初期有効
        t.chars_in = 0;
        t.chars_out = 0;

        // 画面バッファを空白で初期化
        for (&t.screen_buf) |*cell| {
            cell.* = makeVgaEntry(' ', 0x07); // light_grey on black
        }
    }
    active_tty = 0;
    initialized = true;
}

// ---- 出力 ----

/// TTY に文字列を出力
pub fn write(tty_id: u8, data: []const u8) void {
    if (tty_id >= MAX_TTYS) return;
    const t = &ttys[tty_id];
    if (!t.active) return;

    for (data) |c| {
        putCharInternal(tty_id, c);
    }
    t.chars_out += @intCast(@min(data.len, 0xFFFFFFFF));
}

/// TTY に 1 文字出力
pub fn putChar(tty_id: u8, c: u8) void {
    if (tty_id >= MAX_TTYS) return;
    if (!ttys[tty_id].active) return;

    putCharInternal(tty_id, c);
    ttys[tty_id].chars_out += 1;
}

fn putCharInternal(tty_id: u8, c: u8) void {
    const t = &ttys[tty_id];

    if (tty_id == active_tty) {
        // アクティブ TTY → 直接 VGA に出力
        vga.putChar(c);
        t.cursor_row = vga.getRow();
        t.cursor_col = vga.getCol();
    } else {
        // 非アクティブ TTY → 画面バッファに書き込み
        switch (c) {
            '\n' => {
                t.cursor_col = 0;
                t.cursor_row += 1;
                if (t.cursor_row >= VGA_HEIGHT) {
                    scrollBuffer(t);
                }
            },
            '\r' => {
                t.cursor_col = 0;
            },
            '\t' => {
                t.cursor_col = (t.cursor_col + 8) & ~@as(usize, 7);
                if (t.cursor_col >= VGA_WIDTH) {
                    t.cursor_col = 0;
                    t.cursor_row += 1;
                    if (t.cursor_row >= VGA_HEIGHT) scrollBuffer(t);
                }
            },
            8 => { // backspace
                if (t.cursor_col > 0) t.cursor_col -= 1;
            },
            else => {
                t.screen_buf[t.cursor_row * VGA_WIDTH + t.cursor_col] =
                    makeVgaEntry(c, 0x07);
                t.cursor_col += 1;
                if (t.cursor_col >= VGA_WIDTH) {
                    t.cursor_col = 0;
                    t.cursor_row += 1;
                    if (t.cursor_row >= VGA_HEIGHT) scrollBuffer(t);
                }
            },
        }
    }
}

fn scrollBuffer(t: *Tty) void {
    // 1行分上にスクロール
    for (1..VGA_HEIGHT) |y| {
        for (0..VGA_WIDTH) |x| {
            t.screen_buf[(y - 1) * VGA_WIDTH + x] = t.screen_buf[y * VGA_WIDTH + x];
        }
    }
    // 最終行をクリア
    for (0..VGA_WIDTH) |x| {
        t.screen_buf[(VGA_HEIGHT - 1) * VGA_WIDTH + x] = makeVgaEntry(' ', 0x07);
    }
    t.cursor_row = VGA_HEIGHT - 1;
}

// ---- 入力 ----

/// キーボードから TTY への入力 (IRQ ハンドラから呼ばれる)
pub fn inputChar(tty_id: u8, c: u8) void {
    if (tty_id >= MAX_TTYS) return;
    const t = &ttys[tty_id];
    if (!t.active) return;

    t.chars_in += 1;

    if (t.canonical) {
        // 正規モード: ラインバッファにためる
        switch (c) {
            '\n' => {
                // Enter: ラインバッファの内容を入力バッファにコピー
                if (t.echo) putCharInternal(tty_id, '\n');
                var i: usize = 0;
                while (i < t.line_len) : (i += 1) {
                    pushInput(t, t.line_buf[i]);
                }
                pushInput(t, '\n');
                t.line_len = 0;
                t.line_ready = true;
            },
            8 => { // backspace
                if (t.line_len > 0) {
                    t.line_len -= 1;
                    if (t.echo) {
                        putCharInternal(tty_id, 8);
                        putCharInternal(tty_id, ' ');
                        putCharInternal(tty_id, 8);
                    }
                }
            },
            else => {
                if (t.line_len < INPUT_BUF_SIZE - 1) {
                    t.line_buf[t.line_len] = c;
                    t.line_len += 1;
                    if (t.echo) putCharInternal(tty_id, c);
                }
            },
        }
    } else {
        // raw モード: 即座に入力バッファへ
        pushInput(t, c);
        if (t.echo) putCharInternal(tty_id, c);
    }
}

fn pushInput(t: *Tty, c: u8) void {
    if (t.input_count >= INPUT_BUF_SIZE) return; // バッファフル
    t.input_buf[t.input_tail] = c;
    t.input_tail = (t.input_tail + 1) % INPUT_BUF_SIZE;
    t.input_count += 1;
}

/// TTY から入力を読み取る
/// 戻り値: 読み取ったバイト数
pub fn read(tty_id: u8, buf: []u8) usize {
    if (tty_id >= MAX_TTYS) return 0;
    const t = &ttys[tty_id];
    if (!t.active) return 0;

    var bytes_read: usize = 0;
    while (bytes_read < buf.len and t.input_count > 0) {
        buf[bytes_read] = t.input_buf[t.input_head];
        t.input_head = (t.input_head + 1) % INPUT_BUF_SIZE;
        t.input_count -= 1;
        bytes_read += 1;
    }
    if (t.canonical) t.line_ready = false;
    return bytes_read;
}

/// 入力バッファに待機中のバイト数
pub fn inputAvailable(tty_id: u8) usize {
    if (tty_id >= MAX_TTYS) return 0;
    return ttys[tty_id].input_count;
}

// ---- モード設定 ----

/// エコーの有効/無効を設定
pub fn setEcho(tty_id: u8, on: bool) void {
    if (tty_id >= MAX_TTYS) return;
    ttys[tty_id].echo = on;
}

/// 正規モード/raw モードを設定
pub fn setCanonical(tty_id: u8, on: bool) void {
    if (tty_id >= MAX_TTYS) return;
    ttys[tty_id].canonical = on;
}

/// エコー状態を取得
pub fn getEcho(tty_id: u8) bool {
    if (tty_id >= MAX_TTYS) return false;
    return ttys[tty_id].echo;
}

/// 正規モード状態を取得
pub fn getCanonical(tty_id: u8) bool {
    if (tty_id >= MAX_TTYS) return false;
    return ttys[tty_id].canonical;
}

// ---- TTY 切り替え ----

/// 現在のアクティブ TTY を取得
pub fn getActive() u8 {
    return active_tty;
}

/// アクティブ TTY を切り替える
pub fn switchTo(tty_id: u8) void {
    if (tty_id >= MAX_TTYS) return;
    if (tty_id == active_tty) return;

    // 現在の TTY の画面を保存
    saveScreen(active_tty);

    // TTY を有効化
    if (!ttys[tty_id].active) {
        ttys[tty_id].active = true;
    }

    active_tty = tty_id;

    // 新しい TTY の画面を復元
    restoreScreen(tty_id);

    // シリアル通知
    serial.write("[tty] switched to tty");
    serial.putChar('0' + tty_id);
    serial.putChar('\n');
}

fn saveScreen(tty_id: u8) void {
    if (tty_id >= MAX_TTYS) return;
    const t = &ttys[tty_id];

    // VGA バッファから画面内容をコピー
    const vga_buf: [*]volatile u16 = @ptrFromInt(0xB8000);
    for (0..VGA_WIDTH * VGA_HEIGHT) |i| {
        t.screen_buf[i] = vga_buf[i];
    }
    t.cursor_row = vga.getRow();
    t.cursor_col = vga.getCol();
}

fn restoreScreen(tty_id: u8) void {
    if (tty_id >= MAX_TTYS) return;
    const t = &ttys[tty_id];

    // 画面バッファの内容を VGA に書き戻す
    const vga_buf: [*]volatile u16 = @ptrFromInt(0xB8000);
    for (0..VGA_WIDTH * VGA_HEIGHT) |i| {
        vga_buf[i] = t.screen_buf[i];
    }
    vga.setCursor(t.cursor_row, t.cursor_col);
}

// ---- TTY 管理 ----

/// TTY を有効化
pub fn enable(tty_id: u8) void {
    if (tty_id >= MAX_TTYS) return;
    ttys[tty_id].active = true;
}

/// TTY を無効化
pub fn disable(tty_id: u8) void {
    if (tty_id >= MAX_TTYS) return;
    if (tty_id == active_tty) return; // アクティブ TTY は無効化不可
    ttys[tty_id].active = false;
}

/// TTY が有効かどうか
pub fn isEnabled(tty_id: u8) bool {
    if (tty_id >= MAX_TTYS) return false;
    return ttys[tty_id].active;
}

/// 入力バッファをクリア
pub fn flushInput(tty_id: u8) void {
    if (tty_id >= MAX_TTYS) return;
    const t = &ttys[tty_id];
    t.input_head = 0;
    t.input_tail = 0;
    t.input_count = 0;
    t.line_len = 0;
    t.line_ready = false;
}

// ---- 情報表示 ----

/// TTY ステータスを VGA に表示
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("TTY Status:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Active: tty");
    vga.putChar('0' + active_tty);
    vga.putChar('\n');
    vga.putChar('\n');

    vga.write("  ID  State      Echo  Canon  In     Out\n");
    vga.write("  --- ---------- ----- ------ ------ ------\n");

    for (&ttys, 0..) |*t, i| {
        vga.write("  tty");
        vga.putChar('0' + @as(u8, @truncate(i)));
        if (i == active_tty) {
            vga.setColor(.light_green, .black);
            vga.write(" active    ");
            vga.setColor(.light_grey, .black);
        } else if (t.active) {
            vga.write(" enabled   ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write(" disabled  ");
            vga.setColor(.light_grey, .black);
        }

        if (t.echo) vga.write("on    ") else vga.write("off   ");
        if (t.canonical) vga.write("on     ") else vga.write("off    ");
        printNum(t.chars_in);
        padTo(6);
        vga.write(" ");
        printNum(t.chars_out);
        vga.putChar('\n');
    }
}

fn padTo(width: usize) void {
    // 簡易パディング (実装は固定幅)
    _ = width;
}

fn printNum(n: u32) void {
    pmm.printNum(n);
}

fn makeVgaEntry(char: u8, attr: u8) u16 {
    return @as(u16, char) | (@as(u16, attr) << 8);
}
