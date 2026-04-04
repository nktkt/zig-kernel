// PS/2 マウスドライバ — IRQ12 ハンドラと 3 バイトパケットパース

const idt = @import("idt.zig");
const serial = @import("serial.zig");

const CMD_PORT: u16 = 0x64;
const DATA_PORT: u16 = 0x60;

// マウス状態
var mouse_x: i32 = 320; // 画面中央
var mouse_y: i32 = 240;
var mouse_buttons: u8 = 0;

// パケットバッファ
var packet: [3]u8 = undefined;
var packet_idx: u8 = 0;

const SCREEN_W: i32 = 640;
const SCREEN_H: i32 = 480;

pub fn init() void {
    mouse_x = SCREEN_W / 2;
    mouse_y = SCREEN_H / 2;
    mouse_buttons = 0;
    packet_idx = 0;

    // コントローラの準備待ち
    waitWrite();
    idt.outb(CMD_PORT, 0xA8); // 補助デバイス有効化

    waitWrite();
    idt.outb(CMD_PORT, 0x20); // コマンドバイト読み取り
    waitRead();
    const status = idt.inb(DATA_PORT);

    waitWrite();
    idt.outb(CMD_PORT, 0x60); // コマンドバイト書き込み
    waitWrite();
    idt.outb(DATA_PORT, status | 0x02); // IRQ12 有効化

    // マウスデフォルト設定
    mouseWrite(0xFF); // リセット
    _ = mouseRead(); // ACK
    _ = mouseRead(); // self-test result
    _ = mouseRead(); // device ID

    mouseWrite(0xF6); // デフォルト設定
    _ = mouseRead(); // ACK

    mouseWrite(0xF4); // データ送信有効化
    _ = mouseRead(); // ACK

    // IRQ12 を PIC で有効化 (slave PIC bit 4)
    const mask = idt.inb(0xA1);
    idt.outb(0xA1, mask & ~@as(u8, 0x10));

    serial.write("[MOUSE] PS/2 mouse initialized\n");
}

fn waitWrite() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (idt.inb(CMD_PORT) & 0x02 == 0) return;
    }
}

fn waitRead() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (idt.inb(CMD_PORT) & 0x01 != 0) return;
    }
}

fn mouseWrite(data: u8) void {
    waitWrite();
    idt.outb(CMD_PORT, 0xD4); // 補助デバイスへ書き込み
    waitWrite();
    idt.outb(DATA_PORT, data);
}

fn mouseRead() u8 {
    waitRead();
    return idt.inb(DATA_PORT);
}

/// IRQ12 から呼ばれるハンドラ
pub fn handleIrq() void {
    const data = idt.inb(DATA_PORT);

    if (packet_idx == 0 and data & 0x08 == 0) {
        // 同期ずれ: bit 3 が立っていなければ先頭バイトではない
        return;
    }

    packet[packet_idx] = data;
    packet_idx += 1;

    if (packet_idx >= 3) {
        packet_idx = 0;
        processPacket();
    }
}

fn processPacket() void {
    mouse_buttons = packet[0] & 0x07;

    // X 方向移動量 (符号付き)
    var dx: i32 = packet[1];
    if (packet[0] & 0x10 != 0) dx -= 256; // X 符号ビット

    // Y 方向移動量 (符号付き、反転)
    var dy: i32 = packet[2];
    if (packet[0] & 0x20 != 0) dy -= 256; // Y 符号ビット

    mouse_x += dx;
    mouse_y -= dy; // PS/2 の Y は反転

    // クランプ
    if (mouse_x < 0) mouse_x = 0;
    if (mouse_x >= SCREEN_W) mouse_x = SCREEN_W - 1;
    if (mouse_y < 0) mouse_y = 0;
    if (mouse_y >= SCREEN_H) mouse_y = SCREEN_H - 1;
}

pub fn getX() i32 {
    return mouse_x;
}

pub fn getY() i32 {
    return mouse_y;
}

pub fn getButtons() u8 {
    return mouse_buttons;
}
