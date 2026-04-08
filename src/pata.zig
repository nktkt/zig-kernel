// Parallel ATA Enhanced Driver — ATAPI Packet Command Support
//
// Extends basic ATA support with ATAPI (ATA Packet Interface) commands
// for CD-ROM / DVD-ROM devices. ATAPI devices are detected by their
// signature (LBA_MID=0x14, LBA_HI=0xEB) after IDENTIFY.
//
// Supported ATAPI commands:
//   - INQUIRY (0x12): device identification
//   - READ CAPACITY (0x25): media size
//   - READ (10) (0x28): sector read
//   - TEST UNIT READY (0x00): check if media is present
//   - REQUEST SENSE (0x03): error information
//
// ATAPI uses the PACKET command (0xA0) to send 12-byte command packets.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- Channel base ports ----

const PRIMARY_IO: u16 = 0x1F0;
const PRIMARY_CTRL: u16 = 0x3F6;
const SECONDARY_IO: u16 = 0x170;
const SECONDARY_CTRL: u16 = 0x376;

// ---- Register offsets ----

const REG_DATA: u16 = 0x00;
const REG_ERROR: u16 = 0x01;
const REG_FEATURES: u16 = 0x01;
const REG_SECT_CNT: u16 = 0x02; // Also: Interrupt Reason for ATAPI
const REG_LBA_LO: u16 = 0x03;
const REG_LBA_MID: u16 = 0x04; // Also: byte count low for ATAPI
const REG_LBA_HI: u16 = 0x05; // Also: byte count high for ATAPI
const REG_DEVICE: u16 = 0x06;
const REG_COMMAND: u16 = 0x07;
const REG_STATUS: u16 = 0x07;

// ---- Status bits ----

const STATUS_ERR: u8 = 0x01;
const STATUS_DRQ: u8 = 0x08;
const STATUS_SRV: u8 = 0x10;
const STATUS_DF: u8 = 0x20;
const STATUS_RDY: u8 = 0x40;
const STATUS_BSY: u8 = 0x80;

// ---- ATA/ATAPI Commands ----

const CMD_IDENTIFY: u8 = 0xEC;
const CMD_IDENTIFY_PACKET: u8 = 0xA1;
const CMD_PACKET: u8 = 0xA0;

// ---- ATAPI SCSI Commands (within packet) ----

const SCSI_TEST_UNIT_READY: u8 = 0x00;
const SCSI_REQUEST_SENSE: u8 = 0x03;
const SCSI_INQUIRY: u8 = 0x12;
const SCSI_READ_CAPACITY: u8 = 0x25;
const SCSI_READ_10: u8 = 0x28;
const SCSI_MODE_SENSE_6: u8 = 0x1A;
const SCSI_GET_CONFIGURATION: u8 = 0x46;
const SCSI_GET_EVENT_STATUS: u8 = 0x4A;

// ---- ATAPI device signature ----

const ATAPI_SIG_MID: u8 = 0x14;
const ATAPI_SIG_HI: u8 = 0xEB;

// ---- Channel/Drive enums ----

pub const Channel = enum(u1) {
    primary = 0,
    secondary = 1,
};

pub const Drive = enum(u1) {
    master = 0,
    slave = 1,
};

// ---- Drive information ----

pub const DriveInfo = struct {
    channel: Channel,
    drive: Drive,
    present: bool,
    is_atapi: bool,
    model: [40]u8,
    serial_num: [20]u8,
    firmware_rev: [8]u8,
    removable: bool,
    cmd_packet_size: u8, // 12 or 16
    // ATAPI-specific
    atapi_type: AtapiDevType,
    sector_size: u32,
    sector_count: u32, // From READ CAPACITY
    size_mb: u32,
    media_present: bool,
};

pub const AtapiDevType = enum(u8) {
    direct_access = 0x00, // Hard disk
    sequential = 0x01, // Tape
    printer = 0x02,
    processor = 0x03,
    write_once = 0x04,
    cdrom = 0x05, // CD-ROM
    scanner = 0x06,
    optical = 0x07,
    medium_changer = 0x08,
    communications = 0x09,
    unknown = 0x1F,
    _,
};

// ---- Inquiry data ----

pub const InquiryData = struct {
    peripheral_type: u8,
    removable: bool,
    version: u8,
    vendor: [8]u8,
    product: [16]u8,
    revision: [4]u8,
};

// ---- State ----

const NUM_DRIVES = 4;
var drives: [NUM_DRIVES]DriveInfo = @splat(DriveInfo{
    .channel = .primary,
    .drive = .master,
    .present = false,
    .is_atapi = false,
    .model = @splat(0),
    .serial_num = @splat(0),
    .firmware_rev = @splat(0),
    .removable = false,
    .cmd_packet_size = 12,
    .atapi_type = .unknown,
    .sector_size = 2048,
    .sector_count = 0,
    .size_mb = 0,
    .media_present = false,
});
var detected_count: u8 = 0;
var identify_buf: [512]u8 align(2) = @splat(0);
var packet_buf: [2048]u8 align(2) = @splat(0);

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
    const ctrl = ctrlBase(ch);
    _ = idt.inb(ctrl);
    _ = idt.inb(ctrl);
    _ = idt.inb(ctrl);
    _ = idt.inb(ctrl);
}

fn waitBsy(ch: Channel) bool {
    const base = ioBase(ch);
    var timeout: u32 = 0;
    while (timeout < 200000) : (timeout += 1) {
        const st = idt.inb(base + REG_STATUS);
        if (st & STATUS_BSY == 0) return true;
    }
    return false;
}

fn waitDrq(ch: Channel) bool {
    const base = ioBase(ch);
    var timeout: u32 = 0;
    while (timeout < 200000) : (timeout += 1) {
        const st = idt.inb(base + REG_STATUS);
        if (st & STATUS_ERR != 0) return false;
        if (st & STATUS_BSY == 0 and st & STATUS_DRQ != 0) return true;
    }
    return false;
}

fn selectDrive(ch: Channel, drv: Drive) void {
    const base = ioBase(ch);
    const sel: u8 = if (drv == .slave) 0xB0 else 0xA0;
    idt.outb(base + REG_DEVICE, sel);
    ioWait(ch);
}

// ---- Initialization ----

pub fn init() void {
    detected_count = 0;

    // Disable interrupts on both channels
    idt.outb(PRIMARY_CTRL, 0x02);
    idt.outb(SECONDARY_CTRL, 0x02);

    detectDrive(.primary, .master);
    detectDrive(.primary, .slave);
    detectDrive(.secondary, .master);
    detectDrive(.secondary, .slave);

    serial.write("[PATA] ");
    serialDecU8(detected_count);
    serial.write(" ATAPI drive(s)\n");
}

fn detectDrive(ch: Channel, drv: Drive) void {
    const base = ioBase(ch);
    const idx = driveIndex(ch, drv);

    drives[idx].channel = ch;
    drives[idx].drive = drv;
    drives[idx].present = false;
    drives[idx].is_atapi = false;

    selectDrive(ch, drv);

    // Check for device presence
    const st = idt.inb(base + REG_STATUS);
    if (st == 0xFF or st == 0x00) return;

    // Send IDENTIFY
    idt.outb(base + REG_SECT_CNT, 0);
    idt.outb(base + REG_LBA_LO, 0);
    idt.outb(base + REG_LBA_MID, 0);
    idt.outb(base + REG_LBA_HI, 0);
    idt.outb(base + REG_COMMAND, CMD_IDENTIFY);
    ioWait(ch);

    var status = idt.inb(base + REG_STATUS);
    if (status == 0) return;

    // Wait for BSY
    if (!waitBsy(ch)) return;

    // Check ATAPI signature
    const mid = idt.inb(base + REG_LBA_MID);
    const hi = idt.inb(base + REG_LBA_HI);

    if (mid == ATAPI_SIG_MID and hi == ATAPI_SIG_HI) {
        // ATAPI device detected
        drives[idx].is_atapi = true;

        // Send IDENTIFY PACKET DEVICE
        idt.outb(base + REG_COMMAND, CMD_IDENTIFY_PACKET);
        ioWait(ch);

        status = idt.inb(base + REG_STATUS);
        if (status == 0) return;

        if (!waitDrq(ch)) return;

        // Read 512 bytes
        var w: usize = 0;
        while (w < 256) : (w += 1) {
            const word = idt.inw(base + REG_DATA);
            identify_buf[w * 2] = @truncate(word);
            identify_buf[w * 2 + 1] = @truncate(word >> 8);
        }

        parseIdentify(idx);
        drives[idx].present = true;
        detected_count += 1;

        // Try to get more info via ATAPI commands
        inquiry(ch, drv, idx);
        readCapacityCmd(ch, drv, idx);

        serial.write("[PATA] ");
        if (ch == .primary) serial.write("Pri") else serial.write("Sec");
        serial.write(if (drv == .master) " Master: ATAPI " else " Slave:  ATAPI ");
        serialPrintStr(&drives[idx].model);
        serial.write("\n");
    }
    // Non-ATAPI drives are handled by ide.zig, skip here
}

fn parseIdentify(idx: usize) void {
    const words: [*]const u16 = @alignCast(@ptrCast(&identify_buf));

    // General configuration: word 0
    const gen_config = words[0];
    drives[idx].removable = (gen_config & (1 << 7)) != 0;
    drives[idx].cmd_packet_size = if (gen_config & 0x03 == 0) 12 else 16;

    // Device type: bits 12:8 of word 0
    const dev_type: u8 = @truncate((gen_config >> 8) & 0x1F);
    drives[idx].atapi_type = @enumFromInt(dev_type);

    // Serial number: words 10-19
    extractAtaString(words, 10, 20, &drives[idx].serial_num);

    // Firmware revision: words 23-26
    extractAtaString(words, 23, 8, &drives[idx].firmware_rev);

    // Model number: words 27-46
    extractAtaString(words, 27, 40, &drives[idx].model);
}

fn extractAtaString(words: [*]const u16, start_word: usize, len: usize, out: []u8) void {
    var i: usize = 0;
    while (i < len) : (i += 2) {
        const w = words[start_word + i / 2];
        if (i < out.len) out[i] = @truncate(w >> 8);
        if (i + 1 < out.len) out[i + 1] = @truncate(w);
    }
    var end: usize = if (len < out.len) len else out.len;
    while (end > 0 and (out[end - 1] == ' ' or out[end - 1] == 0)) {
        end -= 1;
    }
    while (end < out.len) : (end += 1) {
        out[end] = 0;
    }
}

// ---- ATAPI Packet Command ----

fn sendPacketCmd(ch: Channel, drv: Drive, cmd: [12]u8, buf_size: u16) bool {
    const base = ioBase(ch);

    selectDrive(ch, drv);

    // Setup for packet command
    idt.outb(base + REG_FEATURES, 0); // No DMA, no overlap
    idt.outb(base + REG_LBA_MID, @truncate(buf_size & 0xFF));
    idt.outb(base + REG_LBA_HI, @truncate(buf_size >> 8));
    idt.outb(base + REG_COMMAND, CMD_PACKET);

    // Wait for DRQ (ready to receive packet)
    if (!waitDrq(ch)) return false;

    // Send 12-byte command packet as 6 words
    var i: usize = 0;
    while (i < 12) : (i += 2) {
        const lo: u16 = cmd[i];
        const hi: u16 = cmd[i + 1];
        idt.outw(base + REG_DATA, lo | (hi << 8));
    }

    return true;
}

/// INQUIRY command — get device identification.
pub fn inquiry(ch: Channel, drv: Drive, idx: usize) void {
    var cmd: [12]u8 = @splat(0);
    cmd[0] = SCSI_INQUIRY;
    cmd[4] = 36; // Allocation length

    if (!sendPacketCmd(ch, drv, cmd, 36)) return;
    if (!waitDrq(ch)) return;

    const base = ioBase(ch);
    var buf: [36]u8 = @splat(0);
    var w: usize = 0;
    while (w < 18) : (w += 1) {
        const word = idt.inw(base + REG_DATA);
        if (w * 2 < 36) buf[w * 2] = @truncate(word);
        if (w * 2 + 1 < 36) buf[w * 2 + 1] = @truncate(word >> 8);
    }

    // Parse inquiry data
    drives[idx].atapi_type = @enumFromInt(buf[0] & 0x1F);
    drives[idx].removable = (buf[1] & 0x80) != 0;
}

/// IDENTIFY PACKET — returns drive info for an ATAPI device.
pub fn identifyPacket(ch: Channel, drv: Drive) ?DriveInfo {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present or !drives[idx].is_atapi) return null;
    return drives[idx];
}

/// READ CAPACITY — get total sector count and sector size.
pub fn readCapacity(ch: Channel, drv: Drive) ?u32 {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present or !drives[idx].is_atapi) return null;
    if (drives[idx].sector_count > 0) return drives[idx].sector_count;
    return null;
}

fn readCapacityCmd(ch: Channel, drv: Drive, idx: usize) void {
    var cmd: [12]u8 = @splat(0);
    cmd[0] = SCSI_READ_CAPACITY;

    if (!sendPacketCmd(ch, drv, cmd, 8)) return;
    if (!waitDrq(ch)) return;

    const base = ioBase(ch);
    var buf: [8]u8 = @splat(0);
    var w: usize = 0;
    while (w < 4) : (w += 1) {
        const word = idt.inw(base + REG_DATA);
        if (w * 2 < 8) buf[w * 2] = @truncate(word);
        if (w * 2 + 1 < 8) buf[w * 2 + 1] = @truncate(word >> 8);
    }

    // READ CAPACITY returns big-endian values
    const last_lba = @as(u32, buf[0]) << 24 | @as(u32, buf[1]) << 16 |
        @as(u32, buf[2]) << 8 | @as(u32, buf[3]);
    const block_size = @as(u32, buf[4]) << 24 | @as(u32, buf[5]) << 16 |
        @as(u32, buf[6]) << 8 | @as(u32, buf[7]);

    if (last_lba > 0 and block_size > 0) {
        drives[idx].sector_count = last_lba + 1;
        drives[idx].sector_size = block_size;
        drives[idx].media_present = true;
        const total_bytes: u64 = @as(u64, drives[idx].sector_count) * block_size;
        drives[idx].size_mb = @truncate(total_bytes / (1024 * 1024));
    }
}

/// Read a sector from an ATAPI device using READ(10).
pub fn readSectorATAPI(ch: Channel, drv: Drive, lba: u32, buf: [*]u8) bool {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present or !drives[idx].is_atapi) return false;

    const base = ioBase(ch);
    const sector_size = drives[idx].sector_size;
    if (sector_size == 0 or sector_size > 2048) return false;

    // Build READ(10) command
    var cmd: [12]u8 = @splat(0);
    cmd[0] = SCSI_READ_10;
    cmd[2] = @truncate(lba >> 24); // LBA (big-endian)
    cmd[3] = @truncate(lba >> 16);
    cmd[4] = @truncate(lba >> 8);
    cmd[5] = @truncate(lba);
    cmd[7] = 0; // Transfer length high
    cmd[8] = 1; // Transfer length low (1 sector)

    if (!sendPacketCmd(ch, drv, cmd, @truncate(sector_size))) return false;
    if (!waitDrq(ch)) return false;

    // Read data
    const words = sector_size / 2;
    var w: u32 = 0;
    while (w < words) : (w += 1) {
        const word = idt.inw(base + REG_DATA);
        buf[w * 2] = @truncate(word);
        buf[w * 2 + 1] = @truncate(word >> 8);
    }

    return true;
}

/// TEST UNIT READY — check if media is present.
pub fn testUnitReady(ch: Channel, drv: Drive) bool {
    var cmd: [12]u8 = @splat(0);
    cmd[0] = SCSI_TEST_UNIT_READY;

    if (!sendPacketCmd(ch, drv, cmd, 0)) return false;
    if (!waitBsy(ch)) return false;

    const base = ioBase(ch);
    const status = idt.inb(base + REG_STATUS);
    return (status & STATUS_ERR) == 0;
}

/// REQUEST SENSE — get error info from last command.
pub fn requestSense(ch: Channel, drv: Drive) ?u8 {
    var cmd: [12]u8 = @splat(0);
    cmd[0] = SCSI_REQUEST_SENSE;
    cmd[4] = 18; // Allocation length

    if (!sendPacketCmd(ch, drv, cmd, 18)) return null;
    if (!waitDrq(ch)) return null;

    const base = ioBase(ch);
    var buf: [18]u8 = @splat(0);
    var w: usize = 0;
    while (w < 9) : (w += 1) {
        const word = idt.inw(base + REG_DATA);
        if (w * 2 < 18) buf[w * 2] = @truncate(word);
        if (w * 2 + 1 < 18) buf[w * 2 + 1] = @truncate(word >> 8);
    }

    // Sense key is at byte 2 (bits 3:0)
    return buf[2] & 0x0F;
}

/// Detect media change on a drive.
pub fn detectMediaChange(ch: Channel, drv: Drive) bool {
    // After a media change, TEST UNIT READY will fail with UNIT ATTENTION
    if (testUnitReady(ch, drv)) return false;

    if (requestSense(ch, drv)) |sense_key| {
        return sense_key == 0x06; // UNIT ATTENTION = media changed
    }
    return false;
}

// ---- Query ----

/// Get drive info for a specific channel/drive.
pub fn getDriveInfo(ch: Channel, drv: Drive) ?*const DriveInfo {
    const idx = driveIndex(ch, drv);
    if (!drives[idx].present) return null;
    return &drives[idx];
}

/// Get the count of detected ATAPI drives.
pub fn getDriveCount() u8 {
    return detected_count;
}

/// Get the ATAPI device type name.
pub fn getDevTypeName(dev_type: AtapiDevType) []const u8 {
    return switch (dev_type) {
        .direct_access => "Direct Access",
        .sequential => "Sequential",
        .printer => "Printer",
        .processor => "Processor",
        .write_once => "Write-Once",
        .cdrom => "CD-ROM",
        .scanner => "Scanner",
        .optical => "Optical",
        .medium_changer => "Medium Changer",
        .communications => "Communications",
        .unknown => "Unknown",
        _ => "Reserved",
    };
}

// ---- Display ----

/// Print all detected ATAPI drives.
pub fn printDrives() void {
    vga.setColor(.yellow, .black);
    vga.write("ATAPI Drives (");
    printDecU8(detected_count);
    vga.write(" detected):\n");
    vga.setColor(.light_grey, .black);

    if (detected_count == 0) {
        vga.write("  No ATAPI drives found\n");
        return;
    }

    for (&drives) |*d| {
        if (!d.present or !d.is_atapi) continue;

        vga.write("  ");
        if (d.channel == .primary) vga.write("Pri") else vga.write("Sec");
        vga.write(" ");
        if (d.drive == .master) vga.write("Master") else vga.write("Slave ");
        vga.write("  ");

        // Type
        vga.write("[");
        vga.write(getDevTypeName(d.atapi_type));
        vga.write("]");
        if (d.removable) vga.write(" (Removable)");
        vga.putChar('\n');

        // Model
        vga.write("    Model:    ");
        printStr(&d.model);
        vga.putChar('\n');

        // Serial
        vga.write("    Serial:   ");
        printStr(&d.serial_num);
        vga.write("  FW: ");
        printStr(&d.firmware_rev);
        vga.putChar('\n');

        // Capacity
        vga.write("    Sector:   ");
        printDec32(d.sector_size);
        vga.write(" bytes  Sectors: ");
        printDec32(d.sector_count);
        vga.putChar('\n');

        if (d.size_mb > 0) {
            vga.write("    Capacity: ");
            if (d.size_mb >= 1024) {
                printDec32(d.size_mb / 1024);
                vga.write(" GB\n");
            } else {
                printDec32(d.size_mb);
                vga.write(" MB\n");
            }
        }

        vga.write("    Media:    ");
        if (d.media_present) {
            vga.setColor(.light_green, .black);
            vga.write("Present");
        } else {
            vga.write("Not Present");
        }
        vga.setColor(.light_grey, .black);
        vga.putChar('\n');

        vga.write("    Packet:   ");
        printDecU8(d.cmd_packet_size);
        vga.write(" bytes\n");
    }
}

// ---- Internal helpers ----

fn printStr(str: []const u8) void {
    for (str) |c| {
        if (c == 0) break;
        vga.putChar(c);
    }
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

fn printDec32(n: u32) void {
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
