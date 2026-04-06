// Terminal emulator -- Character cell grid for GUI mode
// 80x25 cell grid with foreground/background colors.
// VT100/ANSI escape sequence processing. Renders to framebuffer.

const vga = @import("vga.zig");
const framebuf = @import("framebuf.zig");
const font_mod = @import("font.zig");

// ---- Constants ----

const TERM_WIDTH = 80;
const TERM_HEIGHT = 25;
const CELL_WIDTH = 8; // pixels (8x8 font)
const CELL_HEIGHT = 8;
const TAB_WIDTH = 8;
const MAX_ESC_PARAMS = 8;
const SCROLL_HISTORY = 4; // extra lines for scroll-back

// ---- Colors ----

/// Standard 16-color VGA palette as RGB values.
const color_palette = [16]u32{
    0x000000, // black
    0x0000AA, // blue
    0x00AA00, // green
    0x00AAAA, // cyan
    0xAA0000, // red
    0xAA00AA, // magenta
    0xAA5500, // brown
    0xAAAAAA, // light grey
    0x555555, // dark grey
    0x5555FF, // light blue
    0x55FF55, // light green
    0x55FFFF, // light cyan
    0xFF5555, // light red
    0xFF55FF, // light magenta
    0xFFFF55, // yellow
    0xFFFFFF, // white
};

// ---- Cell ----

pub const Cell = struct {
    char: u8,
    fg_color: u8, // index into color_palette
    bg_color: u8,
    dirty: bool,
};

// ---- Cursor ----

pub const Cursor = struct {
    row: usize,
    col: usize,
    visible: bool,
    blink_state: bool,
    blink_counter: u32,
};

// ---- Escape sequence parser state ----

const EscState = enum(u8) {
    normal,
    esc, // received ESC
    csi, // received ESC[
    osc, // received ESC]
};

// ---- Terminal state ----

var cells: [TERM_HEIGHT][TERM_WIDTH]Cell = undefined;
var cursor: Cursor = undefined;
var esc_state: EscState = .normal;
var esc_params: [MAX_ESC_PARAMS]u16 = undefined;
var esc_param_count: usize = 0;
var esc_current: u16 = 0;
var esc_has_digit: bool = false;

var default_fg: u8 = 7; // light grey
var default_bg: u8 = 0; // black
var current_fg: u8 = 7;
var current_bg: u8 = 0;
var bold: bool = false;

var initialized: bool = false;
var dirty_all: bool = true;

// Saved cursor position
var saved_row: usize = 0;
var saved_col: usize = 0;

// ---- Public API: Initialization ----

/// Initialize the terminal with the default 80x25 grid.
pub fn init(width: u32, height: u32) void {
    _ = width;
    _ = height;
    current_fg = default_fg;
    current_bg = default_bg;
    bold = false;
    esc_state = .normal;

    cursor = Cursor{
        .row = 0,
        .col = 0,
        .visible = true,
        .blink_state = true,
        .blink_counter = 0,
    };

    clear();
    initialized = true;
}

/// Clear the entire terminal.
pub fn clear() void {
    var row: usize = 0;
    while (row < TERM_HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < TERM_WIDTH) : (col += 1) {
            cells[row][col] = Cell{
                .char = ' ',
                .fg_color = current_fg,
                .bg_color = current_bg,
                .dirty = true,
            };
        }
    }
    cursor.row = 0;
    cursor.col = 0;
    dirty_all = true;
}

// ---- Public API: Output ----

/// Write a single character (processes escape sequences).
pub fn writeChar(c: u8) void {
    switch (esc_state) {
        .normal => processNormal(c),
        .esc => processEsc(c),
        .csi => processCsi(c),
        .osc => processOsc(c),
    }
}

/// Write a string.
pub fn writeString(s: []const u8) void {
    for (s) |c| {
        writeChar(c);
    }
}

// ---- Public API: Cursor ----

/// Set cursor position (0-based row, col).
pub fn setCursorPos(row: usize, col: usize) void {
    cursor.row = @min(row, TERM_HEIGHT - 1);
    cursor.col = @min(col, TERM_WIDTH - 1);
}

/// Get current cursor row.
pub fn getCursorRow() usize {
    return cursor.row;
}

/// Get current cursor col.
pub fn getCursorCol() usize {
    return cursor.col;
}

/// Toggle cursor visibility.
pub fn setCursorVisible(visible: bool) void {
    cursor.visible = visible;
}

/// Update cursor blink state (call periodically from timer).
pub fn tickCursor() void {
    cursor.blink_counter += 1;
    if (cursor.blink_counter >= 500) { // ~500ms blink
        cursor.blink_counter = 0;
        cursor.blink_state = !cursor.blink_state;
        if (cursor.visible) {
            cells[cursor.row][cursor.col].dirty = true;
        }
    }
}

/// Save current cursor position.
pub fn saveCursor() void {
    saved_row = cursor.row;
    saved_col = cursor.col;
}

/// Restore saved cursor position.
pub fn restoreCursor() void {
    cursor.row = saved_row;
    cursor.col = saved_col;
}

// ---- Public API: Scrolling ----

/// Scroll the terminal up by one line.
pub fn scrollUp() void {
    var row: usize = 0;
    while (row < TERM_HEIGHT - 1) : (row += 1) {
        cells[row] = cells[row + 1];
    }
    // Clear last line
    var col: usize = 0;
    while (col < TERM_WIDTH) : (col += 1) {
        cells[TERM_HEIGHT - 1][col] = Cell{
            .char = ' ',
            .fg_color = current_fg,
            .bg_color = current_bg,
            .dirty = true,
        };
    }
    dirty_all = true;
}

/// Scroll the terminal down by one line.
pub fn scrollDown() void {
    var row: usize = TERM_HEIGHT - 1;
    while (row > 0) : (row -= 1) {
        cells[row] = cells[row - 1];
    }
    // Clear first line
    var col: usize = 0;
    while (col < TERM_WIDTH) : (col += 1) {
        cells[0][col] = Cell{
            .char = ' ',
            .fg_color = current_fg,
            .bg_color = current_bg,
            .dirty = true,
        };
    }
    dirty_all = true;
}

// ---- Public API: Rendering ----

/// Render the terminal cell grid to framebuffer at (fb_x, fb_y).
pub fn renderToFramebuf(fb_x: u32, fb_y: u32) void {
    if (!framebuf.isAvailable()) return;

    var row: usize = 0;
    while (row < TERM_HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < TERM_WIDTH) : (col += 1) {
            const cell = &cells[row][col];
            if (!cell.dirty and !dirty_all) continue;

            const px = fb_x + @as(u32, @truncate(col)) * CELL_WIDTH;
            const py = fb_y + @as(u32, @truncate(row)) * CELL_HEIGHT;

            // Draw background
            const bg = color_palette[cell.bg_color & 0xF];
            var dy: u32 = 0;
            while (dy < CELL_HEIGHT) : (dy += 1) {
                var dx: u32 = 0;
                while (dx < CELL_WIDTH) : (dx += 1) {
                    framebuf.putPixel(px + dx, py + dy, bg);
                }
            }

            // Draw character
            if (cell.char >= 32 and cell.char <= 126) {
                const fg = color_palette[cell.fg_color & 0xF];
                font_mod.drawChar8x8(px, py, cell.char, fg);
            }

            // Cursor
            if (cursor.visible and cursor.blink_state and
                row == cursor.row and col == cursor.col)
            {
                const cursor_color = color_palette[current_fg & 0xF];
                // Underline cursor (last 2 rows)
                var cy: u32 = CELL_HEIGHT - 2;
                while (cy < CELL_HEIGHT) : (cy += 1) {
                    var cx: u32 = 0;
                    while (cx < CELL_WIDTH) : (cx += 1) {
                        framebuf.putPixel(px + cx, py + cy, cursor_color);
                    }
                }
            }

            cell.dirty = false;
        }
    }
    dirty_all = false;
}

/// Render only dirty cells (for performance).
pub fn renderDirty(fb_x: u32, fb_y: u32) void {
    renderToFramebuf(fb_x, fb_y);
}

/// Get the pixel dimensions of the terminal.
pub fn getPixelWidth() u32 {
    return TERM_WIDTH * CELL_WIDTH;
}

pub fn getPixelHeight() u32 {
    return TERM_HEIGHT * CELL_HEIGHT;
}

// ---- Public API: Direct cell access ----

/// Get a cell at (row, col).
pub fn getCell(row: usize, col: usize) *const Cell {
    if (row >= TERM_HEIGHT or col >= TERM_WIDTH) {
        return &cells[0][0]; // fallback
    }
    return &cells[row][col];
}

/// Set a cell directly.
pub fn setCell(row: usize, col: usize, char: u8, fg: u8, bg: u8) void {
    if (row >= TERM_HEIGHT or col >= TERM_WIDTH) return;
    cells[row][col] = Cell{
        .char = char,
        .fg_color = fg,
        .bg_color = bg,
        .dirty = true,
    };
}

/// Set terminal colors for subsequent output.
pub fn setColors(fg: u8, bg: u8) void {
    current_fg = fg & 0xF;
    current_bg = bg & 0xF;
}

/// Get the grid width.
pub fn getWidth() usize {
    return TERM_WIDTH;
}

/// Get the grid height.
pub fn getHeight() usize {
    return TERM_HEIGHT;
}

// ---- Escape sequence processing ----

fn processNormal(c: u8) void {
    switch (c) {
        0x1B => { // ESC
            esc_state = .esc;
        },
        '\n' => { // Line feed
            cursor.row += 1;
            cursor.col = 0;
            if (cursor.row >= TERM_HEIGHT) {
                scrollUp();
                cursor.row = TERM_HEIGHT - 1;
            }
        },
        '\r' => { // Carriage return
            cursor.col = 0;
        },
        '\t' => { // Tab
            cursor.col = (cursor.col + TAB_WIDTH) & ~@as(usize, TAB_WIDTH - 1);
            if (cursor.col >= TERM_WIDTH) {
                cursor.col = TERM_WIDTH - 1;
            }
        },
        8 => { // Backspace
            if (cursor.col > 0) {
                cursor.col -= 1;
                cells[cursor.row][cursor.col].char = ' ';
                cells[cursor.row][cursor.col].dirty = true;
            }
        },
        7 => { // Bell (BEL)
            handleBell();
        },
        else => { // Printable character
            if (cursor.col >= TERM_WIDTH) {
                cursor.col = 0;
                cursor.row += 1;
                if (cursor.row >= TERM_HEIGHT) {
                    scrollUp();
                    cursor.row = TERM_HEIGHT - 1;
                }
            }
            cells[cursor.row][cursor.col] = Cell{
                .char = c,
                .fg_color = if (bold) (current_fg | 0x08) else current_fg,
                .bg_color = current_bg,
                .dirty = true,
            };
            cursor.col += 1;
        },
    }
}

fn processEsc(c: u8) void {
    switch (c) {
        '[' => {
            esc_state = .csi;
            esc_param_count = 0;
            esc_current = 0;
            esc_has_digit = false;
        },
        ']' => {
            esc_state = .osc;
        },
        '7' => { // Save cursor
            saveCursor();
            esc_state = .normal;
        },
        '8' => { // Restore cursor
            restoreCursor();
            esc_state = .normal;
        },
        'D' => { // Index (scroll up)
            cursor.row += 1;
            if (cursor.row >= TERM_HEIGHT) {
                scrollUp();
                cursor.row = TERM_HEIGHT - 1;
            }
            esc_state = .normal;
        },
        'M' => { // Reverse index (scroll down)
            if (cursor.row == 0) {
                scrollDown();
            } else {
                cursor.row -= 1;
            }
            esc_state = .normal;
        },
        'c' => { // Reset
            resetTerminal();
            esc_state = .normal;
        },
        else => {
            esc_state = .normal;
        },
    }
}

fn processCsi(c: u8) void {
    if (c >= '0' and c <= '9') {
        esc_current = esc_current * 10 + (c - '0');
        esc_has_digit = true;
        return;
    }
    if (c == ';') {
        if (esc_param_count < MAX_ESC_PARAMS) {
            esc_params[esc_param_count] = esc_current;
            esc_param_count += 1;
        }
        esc_current = 0;
        esc_has_digit = false;
        return;
    }

    // Final parameter
    if (esc_has_digit and esc_param_count < MAX_ESC_PARAMS) {
        esc_params[esc_param_count] = esc_current;
        esc_param_count += 1;
    }

    handleCsiCommand(c);
    esc_state = .normal;
}

fn processOsc(c: u8) void {
    // OSC sequences: ignore until BEL or ST
    if (c == 7 or c == '\\') { // BEL or ST
        esc_state = .normal;
    }
}

fn handleCsiCommand(cmd: u8) void {
    const p0 = if (esc_param_count > 0) esc_params[0] else 0;
    const p1 = if (esc_param_count > 1) esc_params[1] else 0;

    switch (cmd) {
        'H', 'f' => { // Cursor position
            const row = if (p0 > 0) p0 - 1 else 0;
            const col = if (p1 > 0) p1 - 1 else 0;
            setCursorPos(row, col);
        },
        'A' => { // Cursor up
            const n: usize = if (p0 > 0) p0 else 1;
            cursor.row -|= n;
        },
        'B' => { // Cursor down
            const n: usize = if (p0 > 0) p0 else 1;
            cursor.row = @min(cursor.row + n, TERM_HEIGHT - 1);
        },
        'C' => { // Cursor forward
            const n: usize = if (p0 > 0) p0 else 1;
            cursor.col = @min(cursor.col + n, TERM_WIDTH - 1);
        },
        'D' => { // Cursor back
            const n: usize = if (p0 > 0) p0 else 1;
            cursor.col -|= n;
        },
        'E' => { // Cursor next line
            const n: usize = if (p0 > 0) p0 else 1;
            cursor.row = @min(cursor.row + n, TERM_HEIGHT - 1);
            cursor.col = 0;
        },
        'F' => { // Cursor prev line
            const n: usize = if (p0 > 0) p0 else 1;
            cursor.row -|= n;
            cursor.col = 0;
        },
        'G' => { // Cursor to column
            const col: usize = if (p0 > 0) p0 - 1 else 0;
            cursor.col = @min(col, TERM_WIDTH - 1);
        },
        'J' => { // Erase display
            eraseDisplay(p0);
        },
        'K' => { // Erase line
            eraseLine(p0);
        },
        'S' => { // Scroll up
            const n = if (p0 > 0) p0 else 1;
            var i: u16 = 0;
            while (i < n) : (i += 1) scrollUp();
        },
        'T' => { // Scroll down
            const n = if (p0 > 0) p0 else 1;
            var i: u16 = 0;
            while (i < n) : (i += 1) scrollDown();
        },
        'm' => { // SGR
            handleSgr();
        },
        's' => saveCursor(),
        'u' => restoreCursor(),
        'h' => { // Set mode
            if (p0 == 25) cursor.visible = true; // Show cursor
        },
        'l' => { // Reset mode
            if (p0 == 25) cursor.visible = false; // Hide cursor
        },
        else => {},
    }
}

fn handleSgr() void {
    if (esc_param_count == 0) {
        // Reset
        current_fg = default_fg;
        current_bg = default_bg;
        bold = false;
        return;
    }

    const ansi_to_vga = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };

    var i: usize = 0;
    while (i < esc_param_count) : (i += 1) {
        const code = esc_params[i];
        switch (code) {
            0 => {
                current_fg = default_fg;
                current_bg = default_bg;
                bold = false;
            },
            1 => bold = true,
            22 => bold = false,
            7 => { // Reverse video
                const tmp = current_fg;
                current_fg = current_bg;
                current_bg = tmp;
            },
            27 => { // Undo reverse
                const tmp = current_fg;
                current_fg = current_bg;
                current_bg = tmp;
            },
            30...37 => current_fg = ansi_to_vga[code - 30],
            39 => current_fg = default_fg,
            40...47 => current_bg = ansi_to_vga[code - 40],
            49 => current_bg = default_bg,
            90...97 => current_fg = ansi_to_vga[code - 90] + 8,
            100...107 => current_bg = ansi_to_vga[code - 100] + 8,
            else => {},
        }
    }
}

fn eraseDisplay(mode: u16) void {
    switch (mode) {
        0 => { // Erase from cursor to end
            // Current line from cursor
            var col = cursor.col;
            while (col < TERM_WIDTH) : (col += 1) {
                clearCell(cursor.row, col);
            }
            // Remaining lines
            var row = cursor.row + 1;
            while (row < TERM_HEIGHT) : (row += 1) {
                col = 0;
                while (col < TERM_WIDTH) : (col += 1) {
                    clearCell(row, col);
                }
            }
        },
        1 => { // Erase from start to cursor
            var row: usize = 0;
            while (row < cursor.row) : (row += 1) {
                var col: usize = 0;
                while (col < TERM_WIDTH) : (col += 1) {
                    clearCell(row, col);
                }
            }
            var col: usize = 0;
            while (col <= cursor.col) : (col += 1) {
                clearCell(cursor.row, col);
            }
        },
        2, 3 => { // Erase entire display
            clear();
        },
        else => {},
    }
}

fn eraseLine(mode: u16) void {
    switch (mode) {
        0 => { // Erase from cursor to end of line
            var col = cursor.col;
            while (col < TERM_WIDTH) : (col += 1) {
                clearCell(cursor.row, col);
            }
        },
        1 => { // Erase from start to cursor
            var col: usize = 0;
            while (col <= cursor.col) : (col += 1) {
                clearCell(cursor.row, col);
            }
        },
        2 => { // Erase entire line
            var col: usize = 0;
            while (col < TERM_WIDTH) : (col += 1) {
                clearCell(cursor.row, col);
            }
        },
        else => {},
    }
}

fn clearCell(row: usize, col: usize) void {
    if (row >= TERM_HEIGHT or col >= TERM_WIDTH) return;
    cells[row][col] = Cell{
        .char = ' ',
        .fg_color = current_fg,
        .bg_color = current_bg,
        .dirty = true,
    };
}

fn resetTerminal() void {
    current_fg = default_fg;
    current_bg = default_bg;
    bold = false;
    cursor.visible = true;
    clear();
}

fn handleBell() void {
    // In kernel context, we could trigger the PC speaker (pcspkr).
    // For now, just mark it as a no-op visual bell (invert briefly).
    // A real implementation would call pcspkr.beep().
}
