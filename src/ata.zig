// ATA PIO ドライバ — プライマリIDEのセクタ読み出し

const idt = @import("idt.zig");
const serial = @import("serial.zig");

const ATA_DATA: u16 = 0x1F0;
const ATA_ERROR: u16 = 0x1F1;
const ATA_SECT_CNT: u16 = 0x1F2;
const ATA_LBA_LO: u16 = 0x1F3;
const ATA_LBA_MID: u16 = 0x1F4;
const ATA_LBA_HI: u16 = 0x1F5;
const ATA_DEVICE: u16 = 0x1F6;
const ATA_CMD: u16 = 0x1F7;
const ATA_STATUS: u16 = 0x1F7;

const CMD_READ: u8 = 0x20;
const STATUS_BSY: u8 = 0x80;
const STATUS_DRQ: u8 = 0x08;
const STATUS_ERR: u8 = 0x01;

var present: bool = false;

pub fn init() void {
    // プライマリマスターの検出
    idt.outb(ATA_DEVICE, 0xA0);
    ioWait();
    const st = idt.inb(ATA_STATUS);
    if (st == 0xFF or st == 0x00) {
        present = false;
        serial.write("[ATA] no disk\n");
        return;
    }
    present = true;
    serial.write("[ATA] disk detected\n");
}

pub fn isPresent() bool {
    return present;
}

pub fn readSectors(lba: u32, count: u8, buf: [*]u8) bool {
    if (!present or count == 0) return false;

    // LBA28 モード
    idt.outb(ATA_DEVICE, 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)));
    idt.outb(ATA_SECT_CNT, count);
    idt.outb(ATA_LBA_LO, @truncate(lba));
    idt.outb(ATA_LBA_MID, @truncate(lba >> 8));
    idt.outb(ATA_LBA_HI, @truncate(lba >> 16));
    idt.outb(ATA_CMD, CMD_READ);

    var sect: u32 = 0;
    while (sect < count) : (sect += 1) {
        // BSY が解除されるまで待つ
        if (!waitReady()) return false;

        // 256 ワード (512 バイト) 読み込み
        const offset = sect * 512;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const word = idt.inw(ATA_DATA);
            buf[offset + i * 2] = @truncate(word);
            buf[offset + i * 2 + 1] = @truncate(word >> 8);
        }
    }
    return true;
}

fn waitReady() bool {
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        const st = idt.inb(ATA_STATUS);
        if (st & STATUS_ERR != 0) return false;
        if (st & STATUS_BSY == 0 and st & STATUS_DRQ != 0) return true;
    }
    return false;
}

fn ioWait() void {
    // 4回の I/O ポートリードで ~400ns 待機
    _ = idt.inb(0x3F6);
    _ = idt.inb(0x3F6);
    _ = idt.inb(0x3F6);
    _ = idt.inb(0x3F6);
}
