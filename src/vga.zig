const std = @import("std");

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
    clear();
}

pub fn clear() void {
    for (0..VGA_HEIGHT) |y| {
        for (0..VGA_WIDTH) |x| {
            buffer[y * VGA_WIDTH + x] = makeEntry(' ', color);
        }
    }
}

pub fn setColor(fg: Color, bg: Color) void {
    color = makeColor(fg, bg);
}

pub fn putChar(char: u8) void {
    if (char == '\n') {
        col = 0;
        row += 1;
        if (row >= VGA_HEIGHT) {
            scroll();
        }
        return;
    }

    buffer[row * VGA_WIDTH + col] = makeEntry(char, color);
    col += 1;
    if (col >= VGA_WIDTH) {
        col = 0;
        row += 1;
        if (row >= VGA_HEIGHT) {
            scroll();
        }
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
