// シリアルポート (COM1) — デバッグ出力

const idt = @import("idt.zig");

const COM1 = 0x3F8;

const shell = @import("shell.zig");

pub fn init() void {
    idt.outb(COM1 + 1, 0x00); // 割り込み無効化
    idt.outb(COM1 + 3, 0x80); // DLAB 有効化
    idt.outb(COM1 + 0, 0x03); // 38400 baud (lo)
    idt.outb(COM1 + 1, 0x00); // 38400 baud (hi)
    idt.outb(COM1 + 3, 0x03); // 8N1
    idt.outb(COM1 + 2, 0x07); // FIFO 有効化 (トリガーレベル=1バイト)
    idt.outb(COM1 + 4, 0x0B); // RTS/DSR 設定
    // 受信割り込み有効化 (IRQ4)
    idt.outb(COM1 + 1, 0x01); // Received Data Available interrupt
}

/// シリアル受信データがあるか
pub fn hasData() bool {
    return (idt.inb(COM1 + 5) & 0x01) != 0;
}

/// シリアルから 1 バイト読み取り
pub fn readChar() u8 {
    return idt.inb(COM1);
}

/// IRQ4 ハンドラ: COM1 受信 → シェルに送る
pub fn handleIrq() void {
    pollInput();
}

/// タイマーからポーリング: COM1 にデータがあればシェルに送る
pub fn pollInput() void {
    var count: u8 = 0;
    while (hasData() and count < 8) : (count += 1) {
        const c = readChar();
        if (c == '\r' or c == '\n') {
            shell.handleKey('\n');
        } else if (c == 0x7F or c == 0x08) {
            shell.handleKey(8);
        } else if (c >= 0x20) {
            shell.handleKey(c);
        }
    }
}

fn isTransmitEmpty() bool {
    return (idt.inb(COM1 + 5) & 0x20) != 0;
}

pub fn putChar(c: u8) void {
    while (!isTransmitEmpty()) {}
    idt.outb(COM1, c);
}

pub fn write(msg: []const u8) void {
    for (msg) |c| {
        if (c == '\n') putChar('\r');
        putChar(c);
    }
}

pub fn writeHex(val: usize) void {
    const hex = "0123456789ABCDEF";
    write("0x");
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| putChar(c);
}
