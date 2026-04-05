// PS/2 キーボードドライバ — スキャンコード→ASCII + 特殊キー対応

const idt = @import("idt.zig");
const shell = @import("shell.zig");
const task = @import("task.zig");
const serial = @import("serial.zig");

const KBD_DATA_PORT = 0x60;

// 特殊キーコード (ASCII にない)
pub const KEY_UP: u8 = 0x80;
pub const KEY_DOWN: u8 = 0x81;
pub const KEY_LEFT: u8 = 0x82;
pub const KEY_RIGHT: u8 = 0x83;
pub const KEY_HOME: u8 = 0x84;
pub const KEY_END: u8 = 0x85;
pub const KEY_PGUP: u8 = 0x86;
pub const KEY_PGDN: u8 = 0x87;
pub const KEY_DEL: u8 = 0x88;
pub const KEY_F1: u8 = 0x89;
pub const KEY_F2: u8 = 0x8A;
pub const KEY_F3: u8 = 0x8B;

// Modifier keys state
var ctrl_held: bool = false;
var shift_held: bool = false;
var extended: bool = false;

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

// Shift 時のマッピング
const shift_table = [128]u8{
    0,    27,  '!', '@', '#', '$', '%', '^', '&', '*', // 0x00-0x09
    '(',  ')', '_', '+', 8,   '\t', 'Q', 'W', 'E', 'R', // 0x0A-0x13
    'T',  'Y', 'U', 'I', 'O', 'P',  '{', '}', '\n', 0, // 0x14-0x1D
    'A',  'S', 'D', 'F', 'G', 'H',  'J', 'K', 'L', ':', // 0x1E-0x27
    '"',  '~', 0,   '|', 'Z', 'X', 'C', 'V', 'B', 'N', // 0x28-0x31
    'M',  '<', '>', '?', 0,   '*',  0,   ' ', 0,   0, // 0x32-0x3B
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

    // E0 プレフィクス (拡張キー)
    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    if (extended) {
        extended = false;
        // 拡張キーのリリースは無視
        if (scancode & 0x80 != 0) return;

        const key: u8 = switch (scancode) {
            0x48 => KEY_UP,
            0x50 => KEY_DOWN,
            0x4B => KEY_LEFT,
            0x4D => KEY_RIGHT,
            0x47 => KEY_HOME,
            0x4F => KEY_END,
            0x49 => KEY_PGUP,
            0x51 => KEY_PGDN,
            0x53 => KEY_DEL,
            else => 0,
        };
        if (key != 0) shell.handleKey(key);
        return;
    }

    // Modifier keys
    if (scancode == 0x1D) { ctrl_held = true; return; }
    if (scancode == 0x9D) { ctrl_held = false; return; }
    if (scancode == 0x2A or scancode == 0x36) { shift_held = true; return; }
    if (scancode == 0xAA or scancode == 0xB6) { shift_held = false; return; }

    // キーリリース
    if (scancode & 0x80 != 0) return;

    // Ctrl+C → SIGINT
    if (ctrl_held and scancode == 0x2E) {
        serial.write("[kbd] Ctrl+C -> SIGINT\n");
        var i: u32 = 1;
        while (i < task.MAX_TASKS) : (i += 1) {
            if (task.getTask(i)) |t| {
                if (t.pid > 0) {
                    _ = task.sendSignal(t.pid, task.SIG_INT);
                }
            }
        }
        shell.handleKey('^');
        shell.handleKey('C');
        shell.handleKey('\n');
        return;
    }

    // Ctrl+D → EOF
    if (ctrl_held and scancode == 0x20) {
        shell.handleKey(4);
        return;
    }

    // Ctrl+L → clear
    if (ctrl_held and scancode == 0x26) {
        shell.handleKey(12); // form feed
        return;
    }

    // Function keys
    if (scancode >= 0x3B and scancode <= 0x3D) {
        shell.handleKey(KEY_F1 + @as(u8, @truncate(scancode - 0x3B)));
        return;
    }

    const table = if (shift_held) &shift_table else &scancode_table;
    const ascii = table[scancode];
    if (ascii != 0) {
        shell.handleKey(ascii);
    }
}
