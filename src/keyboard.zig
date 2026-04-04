// PS/2 キーボードドライバ — スキャンコードを ASCII に変換してシェルに送る

const idt = @import("idt.zig");
const shell = @import("shell.zig");

const KBD_DATA_PORT = 0x60;

// US キーボードレイアウト (スキャンコードセット 1)
const scancode_table = [128]u8{
    0,    27,  '1', '2', '3', '4', '5', '6', '7', '8', // 0x00-0x09
    '9',  '0', '-', '=', 8,   '\t', 'q', 'w', 'e', 'r', // 0x0A-0x13
    't',  'y', 'u', 'i', 'o', 'p',  '[', ']', '\n', 0, // 0x14-0x1D
    'a',  's', 'd', 'f', 'g', 'h',  'j', 'k', 'l', ';', // 0x1E-0x27
    '\'', '`', 0,   '\\', 'z', 'x', 'c', 'v', 'b', 'n', // 0x28-0x31
    'm',  ',', '.', '/', 0,   '*',  0,   ' ', 0,   0, // 0x32-0x3B
    0,    0,   0,   0,   0,   0,    0,   0,   0,   0, // 0x3C-0x45
    0,    0,   0,   0,   0,   0,    0,   0,   0,   0, // 0x46-0x4F
    0,    0,   0,   0,   0,   0,    0,   0,   0,   0, // 0x50-0x59
    0,    0,   0,   0,   0,   0,    0,   0,   0,   0, // 0x5A-0x63
    0,    0,   0,   0,   0,   0,    0,   0,   0,   0, // 0x64-0x6D
    0,    0,   0,   0,   0,   0,    0,   0,   0,   0, // 0x6E-0x77
    0,    0,   0,   0,   0,   0,    0,   0,             // 0x78-0x7F
};

pub fn handleIrq() void {
    const scancode = idt.inb(KBD_DATA_PORT);

    // キーリリース (bit 7) は無視
    if (scancode & 0x80 != 0) return;

    const ascii = scancode_table[scancode];
    if (ascii != 0) {
        shell.handleKey(ascii);
    }
}
