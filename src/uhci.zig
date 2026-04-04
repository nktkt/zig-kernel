// USB UHCI コントローラ検出 — PCI スキャン & レジスタ読み取り

const pci = @import("pci.zig");
const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// PCI クラス: Serial Bus Controller / USB / UHCI
const USB_CLASS: u8 = 0x0C;
const USB_SUBCLASS: u8 = 0x03;
const UHCI_PROGIF: u8 = 0x00;

// UHCI レジスタオフセット (I/O ベースから)
const USBCMD: u16 = 0x00;
const USBSTS: u16 = 0x02;
const USBINTR: u16 = 0x04;
const FRNUM: u16 = 0x06;

var io_base: u16 = 0;
var detected: bool = false;
var uhci_bus: u8 = 0;
var uhci_slot: u8 = 0;
var uhci_func: u8 = 0;
var vendor_id: u16 = 0;
var device_id: u16 = 0;

pub fn init() void {
    detected = false;
    io_base = 0;

    // PCI デバイスをスキャン
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        var func: u8 = 0;
        while (func < 8) : (func += 1) {
            const r0 = pci.readConfig(0, slot, func, 0x00);
            const vid: u16 = @truncate(r0);
            if (vid == 0xFFFF) {
                if (func == 0) break;
                continue;
            }

            const r2 = pci.readConfig(0, slot, func, 0x08);
            const class: u8 = @truncate(r2 >> 24);
            const subclass: u8 = @truncate(r2 >> 16);
            const progif: u8 = @truncate(r2 >> 8);

            if (class == USB_CLASS and subclass == USB_SUBCLASS and progif == UHCI_PROGIF) {
                // BAR4 (offset 0x20) に I/O ベースアドレス
                const bar4 = pci.readConfig(0, slot, func, 0x20);
                if (bar4 & 0x01 != 0) { // I/O space
                    io_base = @truncate(bar4 & 0xFFFC);
                    uhci_bus = 0;
                    uhci_slot = slot;
                    uhci_func = func;
                    vendor_id = vid;
                    device_id = @truncate(r0 >> 16);
                    detected = true;

                    serial.write("[UHCI] found at ");
                    serial.writeHex(slot);
                    serial.write(" io=0x");
                    serial.writeHex(io_base);
                    serial.write("\n");

                    // コントローラリセット
                    resetController();
                    return;
                }
            }

            // マルチファンクションでなければ func=0 のみ
            if (func == 0) {
                const hdr: u8 = @truncate(pci.readConfig(0, slot, 0, 0x0C) >> 16);
                if (hdr & 0x80 == 0) break;
            }
        }
    }
}

fn resetController() void {
    if (io_base == 0) return;

    // グローバルリセット
    idt.outw(io_base + USBCMD, 0x0004); // GRESET
    // 短い待機
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        asm volatile ("pause");
    }
    idt.outw(io_base + USBCMD, 0x0000); // リセット解除

    // ホストコントローラリセット
    idt.outw(io_base + USBCMD, 0x0002); // HCRESET
    i = 0;
    while (i < 10000) : (i += 1) {
        if (idt.inw(io_base + USBCMD) & 0x0002 == 0) break;
        asm volatile ("pause");
    }

    serial.write("[UHCI] reset complete\n");
}

pub fn isDetected() bool {
    return detected;
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("USB UHCI Controller:\n");
    vga.setColor(.light_grey, .black);
    if (!detected) {
        vga.write("  No UHCI controller found\n");
        return;
    }
    vga.write("  PCI: 00:");
    printHex8(uhci_slot);
    vga.putChar('.');
    vga.putChar('0' + uhci_func);
    vga.putChar('\n');
    vga.write("  Vendor: ");
    printHex16(vendor_id);
    vga.write("  Device: ");
    printHex16(device_id);
    vga.putChar('\n');
    vga.write("  I/O Base: 0x");
    printHex16(io_base);
    vga.putChar('\n');

    // レジスタ読み取り
    const cmd = idt.inw(io_base + USBCMD);
    const sts = idt.inw(io_base + USBSTS);
    const frnum = idt.inw(io_base + FRNUM);

    vga.write("  USBCMD: 0x");
    printHex16(cmd);
    vga.write("  USBSTS: 0x");
    printHex16(sts);
    vga.write("  FRNUM: 0x");
    printHex16(frnum);
    vga.putChar('\n');
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
