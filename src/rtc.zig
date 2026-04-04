// RTC (Real Time Clock) — CMOS から日時を取得

const idt = @import("idt.zig");
const vga = @import("vga.zig");

const CMOS_ADDR = 0x70;
const CMOS_DATA = 0x71;

fn readCmos(reg: u8) u8 {
    idt.outb(CMOS_ADDR, reg);
    return idt.inb(CMOS_DATA);
}

fn bcdToBin(bcd: u8) u8 {
    return (bcd & 0x0F) + (bcd >> 4) * 10;
}

fn isUpdating() bool {
    idt.outb(CMOS_ADDR, 0x0A);
    return (idt.inb(CMOS_DATA) & 0x80) != 0;
}

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn read() DateTime {
    // RTC 更新中でないことを確認
    while (isUpdating()) {}

    const reg_b = readCmos(0x0B);
    const is_bcd = (reg_b & 0x04) == 0;

    var sec = readCmos(0x00);
    var min = readCmos(0x02);
    var hour = readCmos(0x04);
    var day = readCmos(0x07);
    var month = readCmos(0x08);
    var year_lo = readCmos(0x09);

    if (is_bcd) {
        sec = bcdToBin(sec);
        min = bcdToBin(min);
        hour = bcdToBin(hour);
        day = bcdToBin(day);
        month = bcdToBin(month);
        year_lo = bcdToBin(year_lo);
    }

    return .{
        .year = @as(u16, 2000) + year_lo,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = min,
        .second = sec,
    };
}

pub fn printDateTime() void {
    const dt = read();
    vga.setColor(.light_grey, .black);

    // 日付: YYYY-MM-DD
    printPadded16(dt.year);
    vga.putChar('-');
    printPadded(dt.month);
    vga.putChar('-');
    printPadded(dt.day);
    vga.putChar(' ');

    // 時刻: HH:MM:SS (UTC)
    printPadded(dt.hour);
    vga.putChar(':');
    printPadded(dt.minute);
    vga.putChar(':');
    printPadded(dt.second);
    vga.write(" UTC\n");
}

fn printPadded(val: u8) void {
    if (val < 10) vga.putChar('0');
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [3]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = '0' + v % 10;
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printPadded16(val: u16) void {
    var buf: [5]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
