// Programmable Interval Timer (PIT) — 約1ms間隔のタイマー割り込み

const idt = @import("idt.zig");
const vga = @import("vga.zig");

const PIT_CHANNEL0 = 0x40;
const PIT_CMD = 0x43;
const PIT_FREQ = 1193182; // PIT の基準周波数 (Hz)
const TARGET_HZ = 1000; // 1ms 間隔

var ticks: u64 = 0;

pub fn init() void {
    // チャネル0, ローバイト/ハイバイト, レートジェネレータ, バイナリ
    idt.outb(PIT_CMD, 0x36);

    const divisor: u16 = PIT_FREQ / TARGET_HZ;
    idt.outb(PIT_CHANNEL0, @truncate(divisor & 0xFF));
    idt.outb(PIT_CHANNEL0, @truncate((divisor >> 8) & 0xFF));
}

pub fn tick() void {
    ticks += 1;
}

pub fn getTicks() u64 {
    return ticks;
}

pub fn getUptimeSecs() u32 {
    return @truncate(ticks / TARGET_HZ);
}

pub fn printUptime() void {
    const total_secs = getUptimeSecs();
    const hours = total_secs / 3600;
    const mins = (total_secs % 3600) / 60;
    const secs = total_secs % 60;

    vga.setColor(.light_grey, .black);
    vga.write("Uptime: ");
    printPadded(hours);
    vga.putChar(':');
    printPadded(mins);
    vga.putChar(':');
    printPadded(secs);
    vga.putChar('\n');
}

fn printPadded(val: u32) void {
    if (val < 10) vga.putChar('0');
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
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
