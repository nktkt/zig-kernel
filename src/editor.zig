// Line-based text editor (ed-like) -- interactive line editor with ramfs integration
//
// Commands:
//   i       - enter insert mode (type lines, end with '.' on its own line)
//   a       - append after current line (insert mode after current)
//   p       - print all lines with line numbers
//   d <n>   - delete line n
//   g <n>   - goto line n (set current line)
//   s/old/new/ - substitute in current line
//   w <filename> - write to ramfs file
//   r <filename> - read from ramfs file
//   n       - print current line number
//   q       - quit editor

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");

// ---- Constants ----

const MAX_LINES = 64;
const MAX_LINE_LEN = 80;
const MAX_CMD_LEN = 128;

// ---- Buffer types ----

const Line = struct {
    chars: [MAX_LINE_LEN]u8,
    len: usize,
};

// ---- Editor state ----

var lines: [MAX_LINES]Line = undefined;
var line_count: usize = 0;
var current_line: usize = 0; // 0-based index of current line
var running: bool = false;
var insert_mode: bool = false;
var insert_after: usize = 0; // insertion point (insert before this index)

// Command input buffer
var cmd_buf: [MAX_CMD_LEN]u8 = undefined;
var cmd_len: usize = 0;

// File name we were opened with
var open_filename: [28]u8 = undefined;
var open_filename_len: usize = 0;

// ---- Key input buffer ----
// Keyboard IRQ pushes keys here; editor polls from it.

const KEY_BUF_SIZE = 64;
var key_buf: [KEY_BUF_SIZE]u8 = undefined;
var key_read: usize = 0;
var key_write: usize = 0;

pub fn pushKey(ch: u8) void {
    const next = (key_write + 1) % KEY_BUF_SIZE;
    if (next == key_read) return; // buffer full, drop
    key_buf[key_write] = ch;
    key_write = next;
}

fn popKey() ?u8 {
    if (key_read == key_write) return null;
    const ch = key_buf[key_read];
    key_read = (key_read + 1) % KEY_BUF_SIZE;
    return ch;
}

fn waitKey() u8 {
    while (true) {
        if (popKey()) |ch| return ch;
        // yield CPU while waiting
        asm volatile ("hlt");
    }
}

// ---- Initialization ----

fn clearBuffer() void {
    line_count = 0;
    current_line = 0;
    for (&lines) |*l| {
        l.len = 0;
        for (&l.chars) |*c| c.* = 0;
    }
}

// ---- Public entry point ----

/// Start the editor, optionally loading a file.
/// Pass empty string or filename. Blocks until user quits.
pub fn start(filename: []const u8) void {
    clearBuffer();
    key_read = 0;
    key_write = 0;
    cmd_len = 0;
    insert_mode = false;
    running = true;

    // Store filename
    open_filename_len = @min(filename.len, 28);
    if (open_filename_len > 0) {
        @memcpy(open_filename[0..open_filename_len], filename[0..open_filename_len]);
    }

    // Try to load file
    if (filename.len > 0) {
        loadFile(filename);
    }

    // Show banner
    vga.setColor(.light_cyan, .black);
    vga.write("-- ed editor --  ");
    if (open_filename_len > 0) {
        vga.write("\"");
        vga.write(open_filename[0..open_filename_len]);
        vga.write("\"  ");
    }
    fmt.printDec(line_count);
    vga.write(" lines\n");
    vga.setColor(.light_grey, .black);
    vga.write("Commands: i a p d<n> g<n> s/old/new/ w r n q\n");
    printPromptEd();

    // Main loop - poll for keys
    while (running) {
        const ch = waitKey();

        if (insert_mode) {
            handleInsertChar(ch);
        } else {
            handleCommandChar(ch);
        }
    }
}

/// Check if editor is currently running (for shell key dispatch).
pub fn isRunning() bool {
    return running;
}

// ---- Insert mode ----

fn handleInsertChar(ch: u8) void {
    switch (ch) {
        '\n' => {
            vga.putChar('\n');
            // Check if the line is just '.'
            if (cmd_len == 1 and cmd_buf[0] == '.') {
                insert_mode = false;
                vga.setColor(.light_cyan, .black);
                vga.write("-- end insert --\n");
                vga.setColor(.light_grey, .black);
                printPromptEd();
                cmd_len = 0;
                return;
            }
            // Insert the line
            if (line_count < MAX_LINES) {
                insertLineAt(insert_after, cmd_buf[0..cmd_len]);
                current_line = insert_after;
                insert_after += 1;
            } else {
                vga.setColor(.light_red, .black);
                vga.write("? buffer full\n");
                vga.setColor(.light_grey, .black);
            }
            cmd_len = 0;
        },
        8 => { // backspace
            if (cmd_len > 0) {
                cmd_len -= 1;
                vga.backspace();
            }
        },
        else => {
            if (ch >= 0x80) return; // ignore special keys
            if (cmd_len < MAX_CMD_LEN - 1 and cmd_len < MAX_LINE_LEN) {
                cmd_buf[cmd_len] = ch;
                cmd_len += 1;
                vga.putChar(ch);
            }
        },
    }
}

// ---- Command mode ----

fn handleCommandChar(ch: u8) void {
    switch (ch) {
        '\n' => {
            vga.putChar('\n');
            if (cmd_len > 0) {
                processCommand(cmd_buf[0..cmd_len]);
            }
            cmd_len = 0;
            if (running) {
                printPromptEd();
            }
        },
        8 => { // backspace
            if (cmd_len > 0) {
                cmd_len -= 1;
                vga.backspace();
            }
        },
        else => {
            if (ch >= 0x80) return; // ignore special keys
            if (cmd_len < MAX_CMD_LEN - 1) {
                cmd_buf[cmd_len] = ch;
                cmd_len += 1;
                vga.putChar(ch);
            }
        },
    }
}

fn printPromptEd() void {
    vga.setColor(.yellow, .black);
    vga.write("ed> ");
    vga.setColor(.white, .black);
}

// ---- Command processing ----

fn processCommand(input: []const u8) void {
    const cmd = trimSlice(input);
    if (cmd.len == 0) return;

    // q - quit
    if (cmd.len == 1 and cmd[0] == 'q') {
        running = false;
        vga.setColor(.light_cyan, .black);
        vga.write("Bye.\n");
        vga.setColor(.light_grey, .black);
        return;
    }

    // i - insert mode (before current line)
    if (cmd.len == 1 and cmd[0] == 'i') {
        enterInsertMode(current_line);
        return;
    }

    // a - append after current line
    if (cmd.len == 1 and cmd[0] == 'a') {
        const after = if (line_count == 0) 0 else current_line + 1;
        enterInsertMode(after);
        return;
    }

    // p - print all lines
    if (cmd.len == 1 and cmd[0] == 'p') {
        cmdPrint();
        return;
    }

    // n - print current line number
    if (cmd.len == 1 and cmd[0] == 'n') {
        cmdPrintLineNum();
        return;
    }

    // d <n> - delete line n
    if (cmd[0] == 'd') {
        cmdDelete(cmd);
        return;
    }

    // g <n> - goto line n
    if (cmd[0] == 'g') {
        cmdGoto(cmd);
        return;
    }

    // s/old/new/ - substitute
    if (cmd[0] == 's' and cmd.len > 1 and cmd[1] == '/') {
        cmdSubstitute(cmd);
        return;
    }

    // w <filename> - write
    if (cmd[0] == 'w') {
        cmdWrite(cmd);
        return;
    }

    // r <filename> - read
    if (cmd[0] == 'r') {
        cmdRead(cmd);
        return;
    }

    vga.setColor(.light_red, .black);
    vga.write("? unknown command\n");
    vga.setColor(.light_grey, .black);
}

fn enterInsertMode(at: usize) void {
    insert_mode = true;
    insert_after = at;
    cmd_len = 0;
    vga.setColor(.light_cyan, .black);
    vga.write("-- insert mode (end with '.') --\n");
    vga.setColor(.light_grey, .black);
}

// ---- Print ----

fn cmdPrint() void {
    if (line_count == 0) {
        vga.write("(empty buffer)\n");
        return;
    }
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        // Current line indicator
        if (i == current_line) {
            vga.setColor(.light_green, .black);
            vga.write("> ");
        } else {
            vga.write("  ");
        }
        // Line number (1-based)
        vga.setColor(.dark_grey, .black);
        printDecPadded3(i + 1);
        vga.setColor(.light_grey, .black);
        vga.write("| ");
        vga.write(lines[i].chars[0..lines[i].len]);
        vga.putChar('\n');
    }
    vga.setColor(.dark_grey, .black);
    fmt.printDec(line_count);
    vga.write(" line(s)\n");
    vga.setColor(.light_grey, .black);
}

fn printDecPadded3(n: usize) void {
    if (n < 10) {
        vga.write("  ");
    } else if (n < 100) {
        vga.putChar(' ');
    }
    fmt.printDec(n);
}

// ---- Line number ----

fn cmdPrintLineNum() void {
    if (line_count == 0) {
        vga.write("(no lines)\n");
        return;
    }
    fmt.printDec(current_line + 1);
    vga.write(" / ");
    fmt.printDec(line_count);
    vga.putChar('\n');
}

// ---- Delete ----

fn cmdDelete(cmd: []const u8) void {
    // "d" alone deletes current line, "d <n>" deletes line n
    var num: usize = current_line + 1; // default: current (1-based)
    if (cmd.len > 1) {
        const arg = trimSlice(cmd[1..]);
        if (parseUsize(arg)) |n| {
            num = n;
        } else {
            vga.setColor(.light_red, .black);
            vga.write("? invalid line number\n");
            vga.setColor(.light_grey, .black);
            return;
        }
    }
    if (num == 0 or num > line_count) {
        vga.setColor(.light_red, .black);
        vga.write("? line out of range\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    deleteLineAt(num - 1);
    vga.write("Deleted line ");
    fmt.printDec(num);
    vga.putChar('\n');
    // Adjust current line
    if (line_count == 0) {
        current_line = 0;
    } else if (current_line >= line_count) {
        current_line = line_count - 1;
    }
}

// ---- Goto ----

fn cmdGoto(cmd: []const u8) void {
    if (cmd.len < 2) {
        vga.setColor(.light_red, .black);
        vga.write("? usage: g <n>\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    const arg = trimSlice(cmd[1..]);
    const num = parseUsize(arg) orelse {
        vga.setColor(.light_red, .black);
        vga.write("? invalid line number\n");
        vga.setColor(.light_grey, .black);
        return;
    };
    if (num == 0 or num > line_count) {
        vga.setColor(.light_red, .black);
        vga.write("? line out of range\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    current_line = num - 1;
    // Print the line
    vga.write(lines[current_line].chars[0..lines[current_line].len]);
    vga.putChar('\n');
}

// ---- Substitute ----

fn cmdSubstitute(cmd: []const u8) void {
    // s/old/new/
    if (line_count == 0) {
        vga.setColor(.light_red, .black);
        vga.write("? no lines\n");
        vga.setColor(.light_grey, .black);
        return;
    }

    // Parse: skip 's', then find delimiters
    if (cmd.len < 4) { // minimum: s///
        vga.setColor(.light_red, .black);
        vga.write("? bad substitute\n");
        vga.setColor(.light_grey, .black);
        return;
    }

    const delim = cmd[1]; // should be '/'
    // Find second delimiter
    var second: ?usize = null;
    var i: usize = 2;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == delim) {
            second = i;
            break;
        }
    }
    if (second == null) {
        vga.setColor(.light_red, .black);
        vga.write("? bad substitute\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    const sep2 = second.?;

    // Find third delimiter (optional)
    var third: usize = cmd.len;
    i = sep2 + 1;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == delim) {
            third = i;
            break;
        }
    }

    const old = cmd[2..sep2];
    const new = cmd[sep2 + 1 .. third];

    if (old.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("? empty pattern\n");
        vga.setColor(.light_grey, .black);
        return;
    }

    // Perform substitution on current line
    const line = &lines[current_line];
    if (substituteInLine(line, old, new)) {
        vga.write(line.chars[0..line.len]);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("? pattern not found\n");
        vga.setColor(.light_grey, .black);
    }
}

fn substituteInLine(line: *Line, old: []const u8, new: []const u8) bool {
    // Find first occurrence of old in line
    if (old.len > line.len) return false;
    if (line.len == 0) return false;

    var pos: ?usize = null;
    const limit = line.len - old.len + 1;
    var j: usize = 0;
    while (j < limit) : (j += 1) {
        if (sliceEql(line.chars[j .. j + old.len], old)) {
            pos = j;
            break;
        }
    }

    if (pos == null) return false;
    const p = pos.?;

    // Build new line content
    var tmp: [MAX_LINE_LEN]u8 = undefined;
    var tmp_len: usize = 0;

    // Copy before match
    if (p > 0) {
        @memcpy(tmp[0..p], line.chars[0..p]);
        tmp_len = p;
    }

    // Copy replacement
    const copy_new = @min(new.len, MAX_LINE_LEN - tmp_len);
    @memcpy(tmp[tmp_len .. tmp_len + copy_new], new[0..copy_new]);
    tmp_len += copy_new;

    // Copy after match
    const after_start = p + old.len;
    const after_len = @min(line.len - after_start, MAX_LINE_LEN - tmp_len);
    if (after_len > 0) {
        @memcpy(tmp[tmp_len .. tmp_len + after_len], line.chars[after_start .. after_start + after_len]);
        tmp_len += after_len;
    }

    @memcpy(line.chars[0..tmp_len], tmp[0..tmp_len]);
    line.len = tmp_len;
    return true;
}

// ---- Write ----

fn cmdWrite(cmd: []const u8) void {
    var fname: []const u8 = open_filename[0..open_filename_len];
    if (cmd.len > 1) {
        const arg = trimSlice(cmd[1..]);
        if (arg.len > 0) {
            fname = arg;
            // Update stored filename
            open_filename_len = @min(arg.len, 28);
            @memcpy(open_filename[0..open_filename_len], arg[0..open_filename_len]);
        }
    }
    if (fname.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("? no filename\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    saveFile(fname);
}

// ---- Read ----

fn cmdRead(cmd: []const u8) void {
    if (cmd.len < 2) {
        vga.setColor(.light_red, .black);
        vga.write("? usage: r <filename>\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    const arg = trimSlice(cmd[1..]);
    if (arg.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("? no filename\n");
        vga.setColor(.light_grey, .black);
        return;
    }
    clearBuffer();
    loadFile(arg);
    vga.write("\"");
    vga.write(arg);
    vga.write("\" ");
    fmt.printDec(line_count);
    vga.write(" lines\n");
}

// ---- File I/O ----

fn loadFile(filename: []const u8) void {
    const idx = ramfs.findByName(filename) orelse return;
    var buf: [ramfs.MAX_DATA]u8 = undefined;
    const size = ramfs.readFile(idx, &buf);
    if (size == 0) return;

    // Parse into lines
    line_count = 0;
    var pos: usize = 0;
    while (pos < size and line_count < MAX_LINES) {
        var end = pos;
        while (end < size and buf[end] != '\n') : (end += 1) {}

        const len = @min(end - pos, MAX_LINE_LEN);
        @memcpy(lines[line_count].chars[0..len], buf[pos .. pos + len]);
        lines[line_count].len = len;
        line_count += 1;

        pos = end;
        if (pos < size and buf[pos] == '\n') pos += 1;
    }
    current_line = 0;
}

fn saveFile(filename: []const u8) void {
    // Serialize lines into buffer
    var buf: [ramfs.MAX_DATA]u8 = undefined;
    var pos: usize = 0;

    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        const len = lines[i].len;
        if (pos + len + 1 > ramfs.MAX_DATA) break;
        @memcpy(buf[pos .. pos + len], lines[i].chars[0..len]);
        pos += len;
        buf[pos] = '\n';
        pos += 1;
    }

    // Find or create file
    const idx = ramfs.findByName(filename) orelse (ramfs.create(filename) orelse {
        vga.setColor(.light_red, .black);
        vga.write("? cannot create file\n");
        vga.setColor(.light_grey, .black);
        return;
    });

    const written = ramfs.writeFile(idx, buf[0..pos]);
    vga.write("\"");
    vga.write(filename);
    vga.write("\" ");
    fmt.printDec(line_count);
    vga.write(" lines, ");
    fmt.printDec(written);
    vga.write(" bytes written\n");
}

// ---- Line manipulation ----

fn insertLineAt(idx: usize, text: []const u8) void {
    if (line_count >= MAX_LINES) return;

    // Shift lines down
    var i: usize = line_count;
    while (i > idx) : (i -= 1) {
        lines[i] = lines[i - 1];
    }

    // Insert new line
    const len = @min(text.len, MAX_LINE_LEN);
    @memcpy(lines[idx].chars[0..len], text[0..len]);
    lines[idx].len = len;
    line_count += 1;
}

fn deleteLineAt(idx: usize) void {
    if (idx >= line_count) return;

    // Shift lines up
    var i: usize = idx;
    while (i + 1 < line_count) : (i += 1) {
        lines[i] = lines[i + 1];
    }
    line_count -= 1;
}

// ---- Utility ----

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trimSlice(s: []const u8) []const u8 {
    var s_start: usize = 0;
    while (s_start < s.len and s[s_start] == ' ') : (s_start += 1) {}
    var end: usize = s.len;
    while (end > s_start and s[end - 1] == ' ') : (end -= 1) {}
    return s[s_start..end];
}

fn parseUsize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var val: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}
