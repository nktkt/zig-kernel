// PCI バスエニュメレーション — デバイスの検出と設定

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

const CONFIG_ADDR: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

pub const PciDevice = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    bar0: u32,
    irq: u8,
};

const MAX_DEVICES = 32;
var devices: [MAX_DEVICES]PciDevice = undefined;
var device_count: usize = 0;

fn makeAddr(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    return @as(u32, 1) << 31 |
        @as(u32, bus) << 16 |
        @as(u32, slot) << 11 |
        @as(u32, func) << 8 |
        @as(u32, offset & 0xFC);
}

pub fn readConfig(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    idt.outl(CONFIG_ADDR, makeAddr(bus, slot, func, offset));
    return idt.inl(CONFIG_DATA);
}

pub fn writeConfig(bus: u8, slot: u8, func: u8, offset: u8, val: u32) void {
    idt.outl(CONFIG_ADDR, makeAddr(bus, slot, func, offset));
    idt.outl(CONFIG_DATA, val);
}

pub fn enableBusMastering(bus: u8, slot: u8, func: u8) void {
    const cmd = readConfig(bus, slot, func, 0x04);
    writeConfig(bus, slot, func, 0x04, cmd | 0x07); // IO + Mem + BusMaster
}

pub fn init() void {
    device_count = 0;
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        const r0 = readConfig(0, slot, 0, 0x00);
        const vendor: u16 = @truncate(r0);
        if (vendor == 0xFFFF) continue;

        addDevice(0, slot, 0);

        // マルチファンクションチェック
        const hdr: u8 = @truncate(readConfig(0, slot, 0, 0x0C) >> 16);
        if (hdr & 0x80 != 0) {
            var func: u8 = 1;
            while (func < 8) : (func += 1) {
                const v: u16 = @truncate(readConfig(0, slot, func, 0x00));
                if (v != 0xFFFF) addDevice(0, slot, func);
            }
        }
    }
    serial.write("[PCI] ");
    serial.writeHex(device_count);
    serial.write(" devices\n");
}

fn addDevice(bus: u8, slot: u8, func: u8) void {
    if (device_count >= MAX_DEVICES) return;
    const r0 = readConfig(bus, slot, func, 0x00);
    const r2 = readConfig(bus, slot, func, 0x08);
    const bar0 = readConfig(bus, slot, func, 0x10);
    const r15 = readConfig(bus, slot, func, 0x3C);

    devices[device_count] = .{
        .bus = bus,
        .slot = slot,
        .func = func,
        .vendor_id = @truncate(r0),
        .device_id = @truncate(r0 >> 16),
        .class = @truncate(r2 >> 24),
        .subclass = @truncate(r2 >> 16),
        .bar0 = bar0,
        .irq = @truncate(r15),
    };
    device_count += 1;
}

pub fn findDevice(vendor: u16, device: u16) ?*const PciDevice {
    for (devices[0..device_count]) |*dev| {
        if (dev.vendor_id == vendor and dev.device_id == device) return dev;
    }
    return null;
}

pub fn getDeviceCount() usize {
    return device_count;
}

pub fn printDevices() void {
    vga.setColor(.yellow, .black);
    vga.write("BUS:SL.FN  VENDOR:DEVICE  CLASS\n");
    vga.setColor(.light_grey, .black);
    for (devices[0..device_count]) |*dev| {
        printHex8(dev.bus);
        vga.putChar(':');
        printHex8(dev.slot);
        vga.putChar('.');
        vga.putChar('0' + dev.func);
        vga.write("    ");
        printHex16(dev.vendor_id);
        vga.putChar(':');
        printHex16(dev.device_id);
        vga.write("     ");
        printHex8(dev.class);
        vga.putChar(':');
        printHex8(dev.subclass);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
    printDec(device_count);
    vga.write(" device(s)\n");
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printHex16(val: u16) void {
    printHex8(@truncate(val >> 8));
    printHex8(@truncate(val));
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
