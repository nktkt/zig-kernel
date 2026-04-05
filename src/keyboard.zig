// PS/2 キーボードドライバ — スキャンコードを ASCII に変換してシェルに送る

const idt = @import("idt.zig");
const shell = @import("shell.zig");
const task = @import("task.zig");
const serial = @import("serial.zig");

const KBD_DATA_PORT = 0x60;

// Modifier keys state
var ctrl_held: bool = false;

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

    // Ctrl キーの状態追跡
    if (scancode == 0x1D) { // Left Ctrl press
        ctrl_held = true;
        return;
    }
    if (scancode == 0x9D) { // Left Ctrl release
        ctrl_held = false;
        return;
    }

    // キーリリース (bit 7) は無視
    if (scancode & 0x80 != 0) return;

    // Ctrl+C → SIGINT を全ユーザープロセスに送信
    if (ctrl_held and scancode == 0x2E) { // 'c' = scancode 0x2E
        serial.write("[kbd] Ctrl+C -> SIGINT\n");
        // 現在動作中のユーザータスク (pid > 0) に SIGINT を送信
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

    // Ctrl+D → EOF 表示
    if (ctrl_held and scancode == 0x20) { // 'd' = scancode 0x20
        shell.handleKey(4); // EOT
        return;
    }

    const ascii = scancode_table[scancode];
    if (ascii != 0) {
        shell.handleKey(ascii);
    }
}
