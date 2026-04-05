// Virtual terminal manager -- multiple independent consoles
//
// Provides 4 virtual consoles, each with its own 80x25 character buffer,
// cursor position, color state, and scrollback history (50 lines).
// Switching between consoles saves/restores the VGA buffer contents.
// Each console maintains independent VT100 state for escape sequences.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const NUM_CONSOLES = 4;
pub const COLS = 80;
pub const ROWS = 25;
pub const SCREEN_SIZE = COLS * ROWS;
pub const SCROLLBACK_LINES = 50;
pub const SCROLLBACK_SIZE = COLS * SCROLLBACK_LINES;

// ---- VT100 escape state per console ----

const VtEscState = enum(u8) {
    normal = 0,
    esc = 1,
    csi = 2,
};

// ---- Console structure ----

const Console = struct {
    // Screen buffer (character + attribute pairs as u16)
    screen: [SCREEN_SIZE]u16,
    // Cursor position
    cursor_row: u8,
    cursor_col: u8,
    // Color attribute
    color: u8,
    // VT100 state
    esc_state: VtEscState,
    esc_params: [4]u16,
    esc_param_count: u8,
    esc_current: u16,
    esc_has_digit: bool,
    // Scrollback buffer (raw characters only, attribute stripped)
    scrollback: [SCROLLBACK_SIZE]u8,
    scrollback_write_line: u16, // next line to write in scrollback (circular)
    scrollback_count: u16, // total lines stored
    scroll_offset: u16, // how many lines scrolled back (0 = live view)
    // Active flag
    active: bool,
    // Statistics
    chars_written: u32,
};

// ---- State ----

var consoles: [NUM_CONSOLES]Console = undefined;
var active_console: u8 = 0;
var initialized: bool = false;

// VGA memory pointer
const VGA_BUFFER: usize = 0xB8000;

// ---- Initialization ----

pub fn init() void {
    for (&consoles, 0..) |*con, i| {
        initConsole(con);
        con.active = (i == 0); // first console is active
    }
    active_console = 0;
    initialized = true;

    // Write welcome message to each console
    var i: u8 = 0;
    while (i < NUM_CONSOLES) : (i += 1) {
        writeToConsole(i, "Console ");
        putCharToConsole(i, '1' + i);
        writeToConsole(i, " ready.\n");
    }

    serial.write("[vt] Virtual terminal manager initialized (");
    serialDec(NUM_CONSOLES);
    serial.write(" consoles)\n");
}

fn initConsole(con: *Console) void {
    // Fill screen with blank spaces (light grey on black)
    const blank = makeEntry(' ', makeColor(0x07));
    for (&con.screen) |*cell| {
        cell.* = blank;
    }
    con.cursor_row = 0;
    con.cursor_col = 0;
    con.color = makeColor(0x07); // light grey on black
    con.esc_state = .normal;
    con.esc_params = [_]u16{ 0, 0, 0, 0 };
    con.esc_param_count = 0;
    con.esc_current = 0;
    con.esc_has_digit = false;
    for (&con.scrollback) |*c| c.* = ' ';
    con.scrollback_write_line = 0;
    con.scrollback_count = 0;
    con.scroll_offset = 0;
    con.active = false;
    con.chars_written = 0;
}

// ---- Color helpers ----

fn makeColor(attr: u8) u8 {
    return attr;
}

fn makeEntry(char: u8, attr: u8) u16 {
    return @as(u16, char) | (@as(u16, attr) << 8);
}

// ---- Console switching ----

/// Save the current VGA buffer to the active console's screen buffer.
fn saveCurrentScreen() void {
    const buf: [*]volatile u16 = @ptrFromInt(VGA_BUFFER);
    const con = &consoles[active_console];
    for (0..SCREEN_SIZE) |i| {
        con.screen[i] = buf[i];
    }
}

/// Restore a console's screen buffer to VGA memory.
fn restoreScreen(console_id: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    const buf: [*]volatile u16 = @ptrFromInt(VGA_BUFFER);
    const con = &consoles[console_id];
    for (0..SCREEN_SIZE) |i| {
        buf[i] = con.screen[i];
    }
}

/// Switch to a different virtual console.
pub fn switchTo(n: u8) void {
    if (!initialized or n >= NUM_CONSOLES) return;
    if (n == active_console) return;

    // Save current console state
    saveCurrentScreen();
    consoles[active_console].active = false;

    // Activate new console
    active_console = n;
    consoles[n].active = true;
    consoles[n].scroll_offset = 0; // reset scroll on switch

    // Restore new console to VGA
    restoreScreen(n);

    // Update hardware cursor
    updateHwCursor(n);

    serial.write("[vt] switched to console ");
    serial.putChar('1' + n);
    serial.write("\n");
}

fn updateHwCursor(console_id: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    const con = &consoles[console_id];
    const pos: u16 = @as(u16, con.cursor_row) * COLS + @as(u16, con.cursor_col);
    // VGA cursor registers (via I/O ports 0x3D4/0x3D5)
    outb(0x3D4, 0x0F);
    outb(0x3D5, @truncate(pos & 0xFF));
    outb(0x3D4, 0x0E);
    outb(0x3D5, @truncate((pos >> 8) & 0xFF));
}

// ---- Writing to consoles ----

/// Write a string to a specific console.
pub fn write(console_id: u8, text: []const u8) void {
    writeToConsole(console_id, text);
}

fn writeToConsole(console_id: u8, text: []const u8) void {
    if (console_id >= NUM_CONSOLES) return;
    for (text) |c| {
        putCharToConsole(console_id, c);
    }
}

/// Write a single character to a specific console.
pub fn putChar(console_id: u8, c: u8) void {
    putCharToConsole(console_id, c);
}

fn putCharToConsole(console_id: u8, c: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    const con = &consoles[console_id];

    // Handle VT100 escape sequences
    switch (con.esc_state) {
        .normal => {
            if (c == 0x1B) {
                con.esc_state = .esc;
                return;
            }
            putRawChar(con, console_id, c);
        },
        .esc => {
            if (c == '[') {
                con.esc_state = .csi;
                con.esc_param_count = 0;
                con.esc_current = 0;
                con.esc_has_digit = false;
            } else {
                con.esc_state = .normal;
            }
        },
        .csi => {
            if (c >= '0' and c <= '9') {
                con.esc_current = con.esc_current * 10 + (c - '0');
                con.esc_has_digit = true;
            } else if (c == ';') {
                if (con.esc_param_count < 4) {
                    con.esc_params[con.esc_param_count] = con.esc_current;
                    con.esc_param_count += 1;
                }
                con.esc_current = 0;
                con.esc_has_digit = false;
            } else {
                // End of CSI sequence
                if (con.esc_has_digit and con.esc_param_count < 4) {
                    con.esc_params[con.esc_param_count] = con.esc_current;
                    con.esc_param_count += 1;
                }
                handleCsi(con, c);
                con.esc_state = .normal;
            }
        },
    }
}

fn handleCsi(con: *Console, cmd: u8) void {
    const p0 = if (con.esc_param_count > 0) con.esc_params[0] else 0;
    const p1 = if (con.esc_param_count > 1) con.esc_params[1] else 0;

    switch (cmd) {
        'H', 'f' => {
            // Cursor position
            const row = if (p0 > 0) @as(u8, @truncate(p0 - 1)) else 0;
            const col = if (p1 > 0) @as(u8, @truncate(p1 - 1)) else 0;
            con.cursor_row = if (row >= ROWS) ROWS - 1 else row;
            con.cursor_col = if (col >= COLS) COLS - 1 else col;
        },
        'A' => {
            // Cursor up
            const n = if (p0 > 0) @as(u8, @truncate(p0)) else 1;
            if (con.cursor_row >= n) con.cursor_row -= n;
        },
        'B' => {
            // Cursor down
            const n = if (p0 > 0) @as(u8, @truncate(p0)) else 1;
            con.cursor_row = @min(con.cursor_row + n, ROWS - 1);
        },
        'C' => {
            // Cursor forward
            const n = if (p0 > 0) @as(u8, @truncate(p0)) else 1;
            con.cursor_col = @min(con.cursor_col + n, COLS - 1);
        },
        'D' => {
            // Cursor backward
            const n = if (p0 > 0) @as(u8, @truncate(p0)) else 1;
            if (con.cursor_col >= n) con.cursor_col -= n;
        },
        'J' => {
            // Erase display
            if (p0 == 2) {
                clearConsole(con);
            }
        },
        'K' => {
            // Erase line
            eraseLine(con, @truncate(p0));
        },
        'm' => {
            // SGR - Set Graphics Rendition
            handleSgr(con);
        },
        else => {},
    }
}

fn handleSgr(con: *Console) void {
    if (con.esc_param_count == 0) {
        con.color = 0x07; // reset
        return;
    }
    var i: u8 = 0;
    while (i < con.esc_param_count) : (i += 1) {
        const p = con.esc_params[i];
        switch (p) {
            0 => con.color = 0x07, // reset
            1 => con.color |= 0x08, // bold (bright)
            30 => con.color = (con.color & 0xF8) | 0x00, // black fg
            31 => con.color = (con.color & 0xF8) | 0x04, // red fg
            32 => con.color = (con.color & 0xF8) | 0x02, // green fg
            33 => con.color = (con.color & 0xF8) | 0x06, // yellow fg
            34 => con.color = (con.color & 0xF8) | 0x01, // blue fg
            35 => con.color = (con.color & 0xF8) | 0x05, // magenta fg
            36 => con.color = (con.color & 0xF8) | 0x03, // cyan fg
            37 => con.color = (con.color & 0xF8) | 0x07, // white fg
            else => {},
        }
    }
}

fn putRawChar(con: *Console, console_id: u8, c: u8) void {
    con.chars_written += 1;

    switch (c) {
        '\n' => {
            // Save current line to scrollback before advancing
            saveLineToScrollback(con);
            con.cursor_col = 0;
            if (con.cursor_row >= ROWS - 1) {
                scrollConsoleUp(con);
            } else {
                con.cursor_row += 1;
            }
        },
        '\r' => {
            con.cursor_col = 0;
        },
        '\t' => {
            const next_tab = (con.cursor_col + 8) & ~@as(u8, 7);
            con.cursor_col = if (next_tab >= COLS) COLS - 1 else next_tab;
        },
        0x08 => {
            // Backspace
            if (con.cursor_col > 0) {
                con.cursor_col -= 1;
                const pos = @as(usize, con.cursor_row) * COLS + @as(usize, con.cursor_col);
                con.screen[pos] = makeEntry(' ', con.color);
            }
        },
        else => {
            if (c >= 0x20) {
                const pos = @as(usize, con.cursor_row) * COLS + @as(usize, con.cursor_col);
                con.screen[pos] = makeEntry(c, con.color);

                con.cursor_col += 1;
                if (con.cursor_col >= COLS) {
                    con.cursor_col = 0;
                    if (con.cursor_row >= ROWS - 1) {
                        scrollConsoleUp(con);
                    } else {
                        con.cursor_row += 1;
                    }
                }
            }
        },
    }

    // If this is the active console, also write to VGA
    if (console_id == active_console and con.scroll_offset == 0) {
        restoreScreen(console_id);
        updateHwCursor(console_id);
    }
}

fn scrollConsoleUp(con: *Console) void {
    // Save top line to scrollback
    saveLineToScrollback(con);

    // Shift all lines up by one
    for (0..(ROWS - 1)) |row| {
        for (0..COLS) |col| {
            con.screen[row * COLS + col] = con.screen[(row + 1) * COLS + col];
        }
    }
    // Clear bottom line
    const blank = makeEntry(' ', con.color);
    for (0..COLS) |col| {
        con.screen[(ROWS - 1) * COLS + col] = blank;
    }
}

fn saveLineToScrollback(con: *Console) void {
    const dst_off = @as(usize, con.scrollback_write_line) * COLS;
    // Extract just the character from each screen cell (top row)
    for (0..COLS) |col| {
        const cell = con.screen[col]; // always save the top visible line
        con.scrollback[dst_off + col] = @truncate(cell & 0xFF);
    }
    con.scrollback_write_line += 1;
    if (con.scrollback_write_line >= SCROLLBACK_LINES) {
        con.scrollback_write_line = 0;
    }
    if (con.scrollback_count < SCROLLBACK_LINES) {
        con.scrollback_count += 1;
    }
}

fn eraseLine(con: *Console, mode: u8) void {
    const blank = makeEntry(' ', con.color);
    const row_start = @as(usize, con.cursor_row) * COLS;

    switch (mode) {
        0 => {
            // Erase from cursor to end of line
            var col: usize = con.cursor_col;
            while (col < COLS) : (col += 1) {
                con.screen[row_start + col] = blank;
            }
        },
        1 => {
            // Erase from start to cursor
            var col: usize = 0;
            while (col <= con.cursor_col) : (col += 1) {
                con.screen[row_start + col] = blank;
            }
        },
        2 => {
            // Erase whole line
            for (0..COLS) |col| {
                con.screen[row_start + col] = blank;
            }
        },
        else => {},
    }
}

// ---- Console operations ----

/// Clear a console.
pub fn clear(console_id: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    clearConsole(&consoles[console_id]);
    if (console_id == active_console) {
        restoreScreen(console_id);
        updateHwCursor(console_id);
    }
}

fn clearConsole(con: *Console) void {
    const blank = makeEntry(' ', con.color);
    for (&con.screen) |*cell| cell.* = blank;
    con.cursor_row = 0;
    con.cursor_col = 0;
}

/// Scroll up to view scrollback history.
pub fn scrollUp(console_id: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    const con = &consoles[console_id];
    if (con.scroll_offset < con.scrollback_count) {
        con.scroll_offset += 1;
    }
    // In a full implementation, we would render the scrollback view here.
    // For now, just track the offset.
}

/// Scroll down (toward live view).
pub fn scrollDown(console_id: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    const con = &consoles[console_id];
    if (con.scroll_offset > 0) {
        con.scroll_offset -= 1;
    }
    if (con.scroll_offset == 0 and console_id == active_console) {
        restoreScreen(console_id);
    }
}

/// Get the currently active console number.
pub fn getActive() u8 {
    return active_console;
}

/// Set color for a console.
pub fn setColor(console_id: u8, fg: u8, bg: u8) void {
    if (console_id >= NUM_CONSOLES) return;
    consoles[console_id].color = (bg << 4) | (fg & 0x0F);
}

/// Get cursor position.
pub fn getCursor(console_id: u8) struct { row: u8, col: u8 } {
    if (console_id >= NUM_CONSOLES) return .{ .row = 0, .col = 0 };
    const con = &consoles[console_id];
    return .{ .row = con.cursor_row, .col = con.cursor_col };
}

// ---- Status display ----

/// Print status of all virtual consoles.
pub fn printStatus() void {
    if (!initialized) {
        vga.write("VT not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Virtual Terminals ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  #  Active  Cursor    Color  Scrollback  Chars\n");
    vga.setColor(.light_grey, .black);

    var i: u8 = 0;
    while (i < NUM_CONSOLES) : (i += 1) {
        const con = &consoles[i];
        vga.write("  ");
        vga.putChar('1' + i);
        vga.write("  ");
        if (i == active_console) {
            vga.setColor(.light_green, .black);
            vga.write("  *   ");
        } else {
            vga.write("      ");
        }
        vga.setColor(.light_grey, .black);

        // Cursor position
        vga.write("  ");
        fmt.printDecPadded(@as(usize, con.cursor_row), 2);
        vga.putChar(',');
        fmt.printDecPadded(@as(usize, con.cursor_col), 2);
        vga.write("   0x");
        fmt.printHex8(con.color);
        vga.write("   ");
        fmt.printDecPadded(@as(usize, con.scrollback_count), 3);
        vga.write("/");
        fmt.printDec(SCROLLBACK_LINES);
        vga.write("     ");
        fmt.printDec(@as(usize, con.chars_written));
        vga.putChar('\n');
    }
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- I/O port helper ----

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

fn serialDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
