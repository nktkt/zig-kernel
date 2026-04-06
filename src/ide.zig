// IDE コントローラドライバ — プライマリ/セカンダリチャネル, マスター/スレーブ検出
//
// プライマリ: I/O 0x1F0, Control 0x3F6
// セカンダリ: I/O 0x170, Control 0x376
// IDENTIFY コマンドによるドライブ情報取得: モデル, シリアル, ファームウェア,
// LBA セクタ数, DMA サポート.
// 最大 4 ドライブ (Primary Master/Slave, Secondary Master/Slave).

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Channel base ports ----

const PRIMARY_IO: u16 = 0x1F0;
const PRIMARY_CTRL: u16 = 0x3F6;
const SECONDARY_IO: u16 = 0x170;
const SECONDARY_CTRL: u16 = 0x376;

// ---- Register offsets from IO base ----

const REG_DATA: u16 = 0x00;
const REG_ERROR: u16 = 0x01; // Read: error, Write: features
const REG_FEATURES: u16 = 0x01;
const REG_SECT_CNT: u16 = 0x02;
const REG_LBA_LO: u16 = 0x03;
const REG_LBA_MID: u16 = 0x04;
const REG_LBA_HI: u16 = 0x05;
const REG_DEVICE: u16 = 0x06; // Drive/Head select
const REG_COMMAND: u16 = 0x07; // Write: command
const REG_STATUS: u16 = 0x07; // Read: status

// ---- Status register bits ----

const STATUS_ERR: u8 = 0x01;
const STATUS_IDX: u8 = 0x02;
const STATUS_CORR: u8 = 0x04;
const STATUS_DRQ: u8 = 0x08;
const STATUS_SRV: u8 = 0x10;
const STATUS_DF: u8 = 0x20;
const STATUS_RDY: u8 = 0x40;
const STATUS_BSY: u8 = 0x80;

// ---- ATA Commands ----

const CMD_IDENTIFY: u8 = 0xEC;
const CMD_IDENTIFY_PACKET: u8 = 0xA1;
const CMD_READ_PIO: u8 = 0x20;
const CMD_READ_PIO_EXT: u8 = 0x24;
const CMD_WRITE_PIO: u8 = 0x30;
const CMD_WRITE_PIO_EXT: u8 = 0x34;
const CMD_FLUSH: u8 = 0xE7;
const CMD_FLUSH_EXT: u8 = 0xEA;

// ---- Channel & Drive indices ----

pub const Channel = enum(u1) {
    primary = 0,
    secondary = 1,
};

pub const Drive = enum(u1) {
    master = 0,
    slave = 1,
};

// ---- Drive info ----

pub const DriveInfo = struct {
    channel: Channel,
    drive: Drive,
    present: bool,
    is_atapi: bool,
    model: [40]u8,
    serial_num: [20]u8,
    firmware_rev: [8]u8,
    lba28_sectors: u32,
    lba48_sectors: u64,
    supports_lba48: bool,
    supports_dma: bool,
    supports_udma: bool,
    udma_mode: u8, // Highest supported UDMA mode
    multisector_count: u8, // Max sectors per multi-sector transfer
    cylinders: u16,
    heads: u8,
    sectors_per_track: u8,
    size_mb: u32, // Calculated size in MB
};

const NUM_DRIVES = 4;
var drives: [NUM_DRIVES]DriveInfo = @splat(DriveInfo{
    .channel = .primary,
    .drive = .master,
    .present = false,
    .is_atapi = false,
    .model = @splat(0),
    .serial_num = @splat(0),
    .firmware_rev = @splat(0),
    .lba28_sectors = 0,
    .lba48_sectors = 0,
    .supports_lba48 = false,
    .supports_dma = false,
    .supports_udma = false,
    .udma_mode = 0,
    .multisector_count = 0,
    .cylinders = 0,
    .heads = 0,
    .sectors_per_track = 0,
    .size_mb = 0,
});
var detected_count: u8 = 0;

// IDENTIFY buffer
var identify_buf: [512]u8 align(2) = @splat(0);

// ---- Helpers ----

fn ioBase(ch: Channel) u16 {
    return switch (ch) {
        .primary => PRIMARY_IO,
        .secondary => SECONDARY_IO,
    };
}

fn ctrlBase(ch: Channel) u16 {
    return switch (ch) {
        .primary => PRIMARY_CTRL,
        .secondary => SECONDARY_CTRL,
    };
}

fn driveIndex(ch: Channel, drv: Drive) usize {
    return @as(usize, @intFromEnum(ch)) * 2 + @intFromEnum(drv);
}

fn ioWait(ch: Channel) void {
    // 4 回の control port read で ~400ns 待機
    const ctrl = ctrlBase(ch);
    _ = idt.inb(ctrl);
    _ = idt.inb(ctrl);
    _ = idt.inb(ctrl);
    _ = idt.inb(ctrl);
}

fn waitBsy(ch: Channel) bool {
    const base = ioBase(ch);
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        const st = idt.inb(base + REG_STATUS);
        if (st & STATUS_BSY == 0) return true;
    }
    return false;
}

fn waitReady(ch: Channel) bool {
    const base = ioBase(ch);
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        const st = idt.inb(base + REG_STATUS);
        if (st & STATUS_ERR != 0) return false;
        if (st & STATUS_BSY == 0 and st & STATUS_DRQ != 0) return true;
    }
    return false;
}

fn selectDrive(ch: Channel, drv: Drive) void {
    const base = ioBase(ch);
    // 0xA0 = master, 0xB0 = slave (bits 5+7 set, bit 4 = slave select)
    const sel: u8 = if (drv == .slave) 0xB0 else 0xA0;
    idt.outb(base + REG_DEVICE, sel);
    ioWait(ch); // Wait for drive select to take effect
}

fn softReset(ch: Channel) void {
    const ctrl = ctrlBase(ch);
    idt.outb(ctrl, 0x04); // SRST bit
    ioWait(ch);
    ioWait(ch);
    idt.outb(ctrl, 0x00); // Clear SRST
    ioWait(ch);
    ioWait(ch);
}

// ---- Initialization ----

pub fn init() void {
    detected_count = 0;

    // Disable interrupts on both channels
    idt.outb(PRIMARY_CTRL, 0x02); // nIEN = 1
    idt.outb(SECONDARY_CTRL, 0x02);

    // Detect all 4 possible drives
    detectDrive(.primary, .master);
    detectDrive(.primary, .slave);
    detectDrive(.secondary, .master);
    detectDrive(.secondary, .slave);

    serial.write("[IDE] ");
    serialDecU8(detected_count);
    serial.write(" drive(s) detected\n");
}

fn detectDrive(ch: Channel, drv: Drive) void {
    const base = ioBase(ch);
    const idx = driveIndex(ch, drv);

    drives[idx].channel = ch;
    drives[idx].drive = drv;
    drives[idx].present = false;

    // Select drive
    selectDrive(ch, drv);

    // Check for device presence
    const st = idt.inb(base + REG_STATUS);
    if (st == 0xFF or st == 0x00) return; // No device (floating bus)

    // Send IDENTIFY command
    idt.outb(base + REG_SECT_CNT, 0);
    idt.outb(base + REG_LBA_LO, 0);
    idt.outb(base + REG_LBA_MID, 0);
    idt.outb(base + REG_LBA_HI, 0);
    idt.outb(base + REG_COMMAND, CMD_IDENTIFY);

    ioWait(ch);

    // Check status
    var status = idt.inb(base + REG_STATUS);
    if (status == 0) return; // No device

    // Wait for BSY to clear
    var timeout: u32 = 0;
    while (status & STATUS_BSY != 0 and timeout < 100000) : (timeout += 1) {
        status = idt.inb(base + REG_STATUS);
    }
    if (timeout >= 100000) return;

    // Check if ATAPI: LBA_MID/HI will be non-zero
    const lba_mid = idt.inb(base + REG_LBA_MID);
    const lba_hi = idt.inb(base + REG_LBA_HI);

    if (lba_mid != 0 or lba_hi != 0) {
        // Might be ATAPI (0x14/0xEB) or SATA (0x3C/0xC3) or unknown
        if (lba_mid == 0x14 and lba_hi == 0xEB) {
            // ATAPI device — send IDENTIFY PACKET DEVICE
            idt.outb(base + REG_COMMAND, CMD_IDENTIFY_PACKET);
            ioWait(ch);
            drives[idx].is_atapi = true;
        } else {
            return; // Unknown device type
        }
    }

    // Wait for DRQ
    if (!waitReady(ch)) return;

    // Read 512 bytes of IDENTIFY data
    for (&identify_buf, 0..) |*b, i| {
        _ = b;
        _ = i;
    }

    var w: usize = 0;
    while (w < 256) : (w += 1) {
        const word = idt.inw(base + REG_DATA);
        identify_buf[w * 2] = @truncate(word);
        identify_buf[w * 2 + 1] = @truncate(word >> 8);
    }

    // Parse IDENTIFY data
    parseIdentify(idx);

    drives[idx].present = true;
    detected_count += 1;

    // Log to serial
    serial.write("[IDE] ");
    if (ch == .primary) serial.write("Pri") else serial.write("Sec");
    serial.write(if (drv == .master) " Master: " else " Slave:  ");
    serialPrintStr(&drives[idx].model);
    serial.write("\n");
}

fn parseIdentify(idx: usize) void {
    const words: [*]const u16 = @alignCast(@ptrCast(&identify_buf));

    // General configuration: word 0
    // Bit 15 = 0 for ATA, 1 for ATAPI

    // Cylinders: word 1
    drives[idx].cylinders = words[1];

    // Heads: word 3
    drives[idx].heads = @truncate(words[3]);

    // Sectors per track: word 6
    drives[idx].sectors_per_track = @truncate(words[6]);

    // Serial number: words 10-19 (20 chars)
    extractAtaString(words, 10, 20, &drives[idx].serial_num);

    // Firmware revision: words 23-26 (8 chars)
    extractAtaString(words, 23, 8, &drives[idx].firmware_rev);

    // Model number: words 27-46 (40 chars)
    extractAtaString(words, 27, 40, &drives[idx].model);

    // Max sectors per multi-sector transfer: word 47 (low byte)
    drives[idx].multisector_count = @truncate(words[47]);

    // Capabilities: word 49
    const caps = words[49];
    drives[idx].supports_dma = (caps & (1 << 8)) != 0; // DMA supported

    // LBA28 sector count: words 60-61
    drives[idx].lba28_sectors = @as(u32, words[60]) | (@as(u32, words[61]) << 16);

    // Command sets: word 83
    const cmd_sets = words[83];
    drives[idx].supports_lba48 = (cmd_sets & (1 << 10)) != 0; // LBA48 supported

    // LBA48 sector count: words 100-103
    if (drives[idx].supports_lba48) {
        const lba48_lo: u64 = @as(u64, words[100]) | (@as(u64, words[101]) << 16);
        const lba48_hi: u64 = @as(u64, words[102]) | (@as(u64, words[103]) << 16);
        drives[idx].lba48_sectors = lba48_lo | (lba48_hi << 32);
    }

    // UDMA modes: word 88
    const udma_modes = words[88];
    if (udma_modes & 0x3F != 0) {
        drives[idx].supports_udma = true;
        // Find highest supported mode
        var mode: u8 = 5;
        while (mode > 0) : (mode -= 1) {
            if (udma_modes & (@as(u16, 1) << @truncate(mode)) != 0) {
                drives[idx].udma_mode = mode;
                break;
            }
        }
        if (mode == 0 and udma_modes & 1 != 0) {
            drives[idx].udma_mode = 0;
        }
    }

    // Calculate size in MB
    const total_sectors: u64 = if (drives[idx].supports_lba48 and drives[idx].lba48_sectors > 0)
        drives[idx].lba48_sectors
    else
        drives[idx].lba28_sectors;
    drives[idx].size_mb = @truncate(total_sectors / 2048);
}

fn extractAtaString(words: [*]const u16, start_word: usize, len: usize, out: []u8) void {
    var i: usize = 0;
    while (i < len) : (i += 2) {
        const word_idx = start_word + i / 2;
        const w = words[word_idx];
        // ATA strings are big-endian within each word
        if (i < out.len) out[i] = @truncate(w >> 8);
        if (i + 1 < out.len) out[i + 1] = @truncate(w);
    }
    // Trim trailing spaces
    var end: usize = if (len < out.len) len else out.len;
    while (end > 0 and (out[end - 1] == ' ' or out[end - 1] == 0)) {
        end -= 1;
    }
    while (end < out.len) : (end += 1) {
        out[end] = 0;
    }
}

// ---- Read sectors ----

pub fn readSectors(ch: Channel, drv: Drive, lba: u32, count: u8, buf: [*]u8) bool {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present or count == 0) return false;

    const base = ioBase(ch);

    // Select drive + LBA mode + upper 4 bits of LBA
    const drv_sel: u8 = 0xE0 | (if (drv == .slave) @as(u8, 0x10) else 0) | @as(u8, @truncate((lba >> 24) & 0x0F));
    idt.outb(base + REG_DEVICE, drv_sel);
    ioWait(ch);

    idt.outb(base + REG_SECT_CNT, count);
    idt.outb(base + REG_LBA_LO, @truncate(lba));
    idt.outb(base + REG_LBA_MID, @truncate(lba >> 8));
    idt.outb(base + REG_LBA_HI, @truncate(lba >> 16));
    idt.outb(base + REG_COMMAND, CMD_READ_PIO);

    var sect: u32 = 0;
    while (sect < count) : (sect += 1) {
        if (!waitReady(ch)) return false;

        const offset = sect * 512;
        var w: u32 = 0;
        while (w < 256) : (w += 1) {
            const word = idt.inw(base + REG_DATA);
            buf[offset + w * 2] = @truncate(word);
            buf[offset + w * 2 + 1] = @truncate(word >> 8);
        }
    }
    return true;
}

pub fn writeSectors(ch: Channel, drv: Drive, lba: u32, count: u8, buf: [*]const u8) bool {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present or count == 0) return false;

    const base = ioBase(ch);

    const drv_sel: u8 = 0xE0 | (if (drv == .slave) @as(u8, 0x10) else 0) | @as(u8, @truncate((lba >> 24) & 0x0F));
    idt.outb(base + REG_DEVICE, drv_sel);
    ioWait(ch);

    idt.outb(base + REG_SECT_CNT, count);
    idt.outb(base + REG_LBA_LO, @truncate(lba));
    idt.outb(base + REG_LBA_MID, @truncate(lba >> 8));
    idt.outb(base + REG_LBA_HI, @truncate(lba >> 16));
    idt.outb(base + REG_COMMAND, CMD_WRITE_PIO);

    var sect: u32 = 0;
    while (sect < count) : (sect += 1) {
        if (!waitReady(ch)) return false;

        const offset = sect * 512;
        var w: u32 = 0;
        while (w < 256) : (w += 1) {
            const lo: u16 = buf[offset + w * 2];
            const hi: u16 = buf[offset + w * 2 + 1];
            idt.outw(base + REG_DATA, lo | (hi << 8));
        }
    }

    // Flush cache
    idt.outb(base + REG_COMMAND, CMD_FLUSH);
    _ = waitBsy(ch);
    return true;
}

// ---- Query ----

pub fn getDriveInfo(ch: Channel, drv: Drive) ?*const DriveInfo {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present) return null;
    return &drives[idx];
}

pub fn getDriveCount() u8 {
    return detected_count;
}

// ---- Display ----

pub fn printDrives() void {
    vga.setColor(.yellow, .black);
    vga.write("IDE Drives (");
    printDecU8(detected_count);
    vga.write(" detected):\n");
    vga.setColor(.light_grey, .black);

    if (detected_count == 0) {
        vga.write("  No drives found\n");
        return;
    }

    vga.write("  CH  DRV    MODEL                                    SIZE\n");
    vga.write("  -------------------------------------------------------\n");

    for (&drives) |*d| {
        if (!d.present) continue;

        vga.write("  ");
        if (d.channel == .primary) vga.write("Pri") else vga.write("Sec");
        vga.write(" ");
        if (d.drive == .master) vga.write("Master") else vga.write("Slave ");
        vga.write(" ");

        // Model (truncate to 37 chars for display)
        var model_len: usize = 0;
        for (d.model) |c| {
            if (c == 0) break;
            model_len += 1;
        }
        const display_len = if (model_len > 37) 37 else model_len;
        for (d.model[0..display_len]) |c| {
            if (c == 0) break;
            vga.putChar(c);
        }
        // Pad to 37
        var pad = 37 -| display_len;
        while (pad > 0) : (pad -= 1) {
            vga.putChar(' ');
        }
        vga.write(" ");

        // Size
        if (d.size_mb >= 1024) {
            printDec32(d.size_mb / 1024);
            vga.write(" GB");
        } else {
            printDec32(d.size_mb);
            vga.write(" MB");
        }
        vga.putChar('\n');

        // Detail line
        vga.write("        Serial: ");
        printStr(&d.serial_num);
        vga.write("  FW: ");
        printStr(&d.firmware_rev);
        vga.putChar('\n');

        vga.write("        LBA28: ");
        printDec32(d.lba28_sectors);
        if (d.supports_lba48) {
            vga.write("  LBA48: ");
            printDec64(d.lba48_sectors);
        }
        vga.putChar('\n');

        vga.write("        DMA: ");
        if (d.supports_dma) vga.write("Yes") else vga.write("No");
        if (d.supports_udma) {
            vga.write("  UDMA ");
            printDecU8(d.udma_mode);
        }
        if (d.is_atapi) vga.write("  [ATAPI]");
        vga.putChar('\n');

        vga.write("        C/H/S: ");
        printDec32(d.cylinders);
        vga.putChar('/');
        printDecU8(d.heads);
        vga.putChar('/');
        printDecU8(d.sectors_per_track);
        vga.putChar('\n');
    }
}

// ---- Helpers ----

fn printStr(str: []const u8) void {
    for (str) |c| {
        if (c == 0) break;
        vga.putChar(c);
    }
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printDecU8(val: u8) void {
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

fn printDec32(n: anytype) void {
    const val: u32 = @intCast(n);
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

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn serialDecU8(val: u8) void {
    if (val == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}

fn serialPrintStr(str: []const u8) void {
    for (str) |c| {
        if (c == 0) break;
        serial.putChar(c);
    }
}
