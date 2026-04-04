// VGA テキストモードドライバ — VT100 エスケープシーケンス対応

pub const Color = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_grey = 7,
    dark_grey = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;
const VGA_BUFFER = 0xB8000;

var row: usize = 0;
var col: usize = 0;
var color: u8 = makeColor(.light_grey, .black);
var buffer: [*]volatile u16 = @ptrFromInt(VGA_BUFFER);

// VT100 エスケープシーケンスパーサー状態
const EscState = enum { normal, esc, csi };
var esc_state: EscState = .normal;
var esc_params: [4]u16 = undefined;
var esc_param_count: usize = 0;
var esc_current: u16 = 0;
var esc_has_digit: bool = false;

fn makeColor(fg: Color, bg: Color) u8 {
    return @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
}

fn makeEntry(char: u8, col_attr: u8) u16 {
    return @as(u16, char) | (@as(u16, col_attr) << 8);
}

pub fn init() void {
    row = 0;
    col = 0;
    color = makeColor(.light_grey, .black);
    esc_state = .normal;
    clear();
}

pub fn clear() void {
    for (0..VGA_HEIGHT) |y| {
        for (0..VGA_WIDTH) |x| {
            buffer[y * VGA_WIDTH + x] = makeEntry(' ', color);
        }
    }
    row = 0;
    col = 0;
}

pub fn setColor(fg: Color, bg: Color) void {
    color = makeColor(fg, bg);
}

pub fn putChar(char: u8) void {
    switch (esc_state) {
        .normal => {
            if (char == 0x1B) { // ESC
                esc_state = .esc;
                return;
            }
            putRawChar(char);
        },
        .esc => {
            if (char == '[') {
                esc_state = .csi;
                esc_param_count = 0;
                esc_current = 0;
                esc_has_digit = false;
                return;
            }
            // 未知のエスケープ → 通常に戻る
            esc_state = .normal;
        },
        .csi => {
            if (char >= '0' and char <= '9') {
                esc_current = esc_current * 10 + (char - '0');
                esc_has_digit = true;
                return;
            }
            if (char == ';') {
                if (esc_param_count < 4) {
                    esc_params[esc_param_count] = esc_current;
                    esc_param_count += 1;
                }
                esc_current = 0;
                esc_has_digit = false;
                return;
            }
            // 最後のパラメータを保存
            if (esc_has_digit and esc_param_count < 4) {
                esc_params[esc_param_count] = esc_current;
                esc_param_count += 1;
            }
            handleCsi(char);
            esc_state = .normal;
        },
    }
}

fn handleCsi(cmd: u8) void {
    const p0 = if (esc_param_count > 0) esc_params[0] else 0;
    const p1 = if (esc_param_count > 1) esc_params[1] else 0;

    switch (cmd) {
        'H', 'f' => { // Cursor position (row;col)
            row = if (p0 > 0) @min(p0 - 1, VGA_HEIGHT - 1) else 0;
            col = if (p1 > 0) @min(p1 - 1, VGA_WIDTH - 1) else 0;
        },
        'A' => { // Cursor up
            const n = if (p0 > 0) p0 else 1;
            row -|= n;
        },
        'B' => { // Cursor down
            const n = if (p0 > 0) p0 else 1;
            row = @min(row + n, VGA_HEIGHT - 1);
        },
        'C' => { // Cursor forward
            const n = if (p0 > 0) p0 else 1;
            col = @min(col + n, VGA_WIDTH - 1);
        },
        'D' => { // Cursor back
            const n = if (p0 > 0) p0 else 1;
            col -|= n;
        },
        'J' => { // Erase display
            if (p0 == 2) {
                clear();
            } else if (p0 == 0) {
                // Erase from cursor to end
                var pos = row * VGA_WIDTH + col;
                while (pos < VGA_WIDTH * VGA_HEIGHT) : (pos += 1) {
                    buffer[pos] = makeEntry(' ', color);
                }
            }
        },
        'K' => { // Erase line
            if (p0 == 0) {
                // Erase from cursor to end of line
                var c = col;
                while (c < VGA_WIDTH) : (c += 1) {
                    buffer[row * VGA_WIDTH + c] = makeEntry(' ', color);
                }
            } else if (p0 == 2) {
                for (0..VGA_WIDTH) |x| {
                    buffer[row * VGA_WIDTH + x] = makeEntry(' ', color);
                }
            }
        },
        'm' => { // SGR (Select Graphic Rendition)
            if (esc_param_count == 0) {
                color = makeColor(.light_grey, .black); // Reset
            } else {
                var i: usize = 0;
                while (i < esc_param_count) : (i += 1) {
                    applySgr(esc_params[i]);
                }
            }
        },
        else => {}, // 未対応コマンドは無視
    }
}

fn applySgr(code: u16) void {
    // ANSI SGR → VGA color mapping
    const ansi_to_vga = [8]Color{ .black, .red, .green, .brown, .blue, .magenta, .cyan, .light_grey };
    const ansi_to_vga_bright = [8]Color{ .dark_grey, .light_red, .light_green, .yellow, .light_blue, .light_magenta, .light_cyan, .white };

    switch (code) {
        0 => color = makeColor(.light_grey, .black), // Reset
        1 => { // Bold (brighten foreground)
            const fg: u4 = @truncate(color & 0x0F);
            color = (color & 0xF0) | (fg | 0x08);
        },
        30...37 => { // Foreground
            const fg = ansi_to_vga[code - 30];
            color = (color & 0xF0) | @as(u8, @intFromEnum(fg));
        },
        40...47 => { // Background
            const bg = ansi_to_vga[code - 40];
            color = (color & 0x0F) | (@as(u8, @intFromEnum(bg)) << 4);
        },
        90...97 => { // Bright foreground
            const fg = ansi_to_vga_bright[code - 90];
            color = (color & 0xF0) | @as(u8, @intFromEnum(fg));
        },
        else => {},
    }
}

fn putRawChar(char: u8) void {
    switch (char) {
        '\n' => {
            col = 0;
            row += 1;
            if (row >= VGA_HEIGHT) scroll();
        },
        '\r' => {
            col = 0;
        },
        '\t' => {
            col = (col + 8) & ~@as(usize, 7);
            if (col >= VGA_WIDTH) {
                col = 0;
                row += 1;
                if (row >= VGA_HEIGHT) scroll();
            }
        },
        8 => { // Backspace
            if (col > 0) col -= 1;
        },
        else => {
            buffer[row * VGA_WIDTH + col] = makeEntry(char, color);
            col += 1;
            if (col >= VGA_WIDTH) {
                col = 0;
                row += 1;
                if (row >= VGA_HEIGHT) scroll();
            }
        },
    }
}

pub fn write(msg: []const u8) void {
    for (msg) |char| {
        putChar(char);
    }
}

pub fn backspace() void {
    if (col > 0) {
        col -= 1;
    } else if (row > 0) {
        row -= 1;
        col = VGA_WIDTH - 1;
    }
    buffer[row * VGA_WIDTH + col] = makeEntry(' ', color);
}

pub fn setCursor(r: usize, c: usize) void {
    row = @min(r, VGA_HEIGHT - 1);
    col = @min(c, VGA_WIDTH - 1);
}

pub fn getRow() usize {
    return row;
}

pub fn getCol() usize {
    return col;
}

fn scroll() void {
    for (1..VGA_HEIGHT) |y| {
        for (0..VGA_WIDTH) |x| {
            buffer[(y - 1) * VGA_WIDTH + x] = buffer[y * VGA_WIDTH + x];
        }
    }
    for (0..VGA_WIDTH) |x| {
        buffer[(VGA_HEIGHT - 1) * VGA_WIDTH + x] = makeEntry(' ', color);
    }
    row = VGA_HEIGHT - 1;
}
