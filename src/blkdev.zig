// ブロックデバイス抽象化レイヤ — 統一的なセクタ I/O

const ata = @import("ata.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

pub const ReadFn = *const fn (u32, u8, [*]u8) bool;
pub const WriteFn = *const fn (u32, u8, [*]const u8) bool;

pub const BlockDev = struct {
    name: [16]u8,
    name_len: u8,
    read_fn: ReadFn,
    write_fn: WriteFn,
    sector_size: u32,
    sector_count: u32,
    present: bool,
};

const MAX_DEVICES = 4;
var devices: [MAX_DEVICES]BlockDev = undefined;
var device_count: usize = 0;

pub fn init() void {
    device_count = 0;
    for (&devices) |*d| d.present = false;

    // ATA プライマリマスターを登録
    if (ata.isPresent()) {
        registerDevice("hda", ata.readSectors, ata.writeSectors, 512, 0);
    }
}

fn registerDevice(name: []const u8, read_fn: ReadFn, write_fn: WriteFn, sector_size: u32, sector_count: u32) void {
    if (device_count >= MAX_DEVICES) return;
    var dev = &devices[device_count];
    dev.name_len = @intCast(@min(name.len, 16));
    @memcpy(dev.name[0..dev.name_len], name[0..dev.name_len]);
    dev.read_fn = read_fn;
    dev.write_fn = write_fn;
    dev.sector_size = sector_size;
    dev.sector_count = sector_count;
    dev.present = true;
    device_count += 1;

    serial.write("[BLK] registered: ");
    serial.write(name);
    serial.write("\n");
}

pub fn read(id: usize, lba: u32, count: u8, buf: [*]u8) bool {
    if (id >= device_count or !devices[id].present) return false;
    return devices[id].read_fn(lba, count, buf);
}

pub fn write(id: usize, lba: u32, count: u8, buf: [*]const u8) bool {
    if (id >= device_count or !devices[id].present) return false;
    return devices[id].write_fn(lba, count, buf);
}

pub fn getDevice(id: usize) ?*const BlockDev {
    if (id < device_count and devices[id].present) return &devices[id];
    return null;
}

pub fn getDeviceCount() usize {
    return device_count;
}

pub fn printDevices() void {
    vga.setColor(.yellow, .black);
    vga.write("Block Devices:\n");
    vga.setColor(.light_grey, .black);
    if (device_count == 0) {
        vga.write("  No block devices\n");
        return;
    }
    for (devices[0..device_count], 0..) |*dev, i| {
        if (!dev.present) continue;
        vga.write("  ");
        printDec(i);
        vga.write(": ");
        vga.write(dev.name[0..dev.name_len]);
        vga.write("  sector_size=");
        printDec(dev.sector_size);
        if (dev.sector_count > 0) {
            vga.write("  sectors=");
            printDec(dev.sector_count);
        }
        vga.putChar('\n');
    }
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
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
