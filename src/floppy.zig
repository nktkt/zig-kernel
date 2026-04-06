// Floppy Disk Controller (FDC) Driver -- 82077AA compatible
//
// Controller I/O ports 0x3F0-0x3F7
// Uses DMA channel 2 for data transfers.
// Supports standard 3.5" 1.44MB floppy: 80 cylinders, 2 heads, 18 sectors/track.

const idt = @import("idt.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const dma = @import("dma.zig");

// ---- I/O Ports ----

const FDC_BASE: u16 = 0x3F0;

const STATUS_REG_A: u16 = FDC_BASE + 0; // 0x3F0 - read only
const STATUS_REG_B: u16 = FDC_BASE + 1; // 0x3F1 - read only
const DOR: u16 = FDC_BASE + 2; // 0x3F2 - Digital Output Register
const TAPE_DRIVE: u16 = FDC_BASE + 3; // 0x3F3 - Tape Drive Register
const MSR: u16 = FDC_BASE + 4; // 0x3F4 - Main Status Register (read)
const DSR: u16 = FDC_BASE + 4; // 0x3F4 - Data Rate Select (write)
const DATA_FIFO: u16 = FDC_BASE + 5; // 0x3F5 - Data Register
const DIR: u16 = FDC_BASE + 7; // 0x3F7 - Digital Input Register (read)
const CCR: u16 = FDC_BASE + 7; // 0x3F7 - Config Control Register (write)

// ---- MSR bits ----

const MSR_RQM: u8 = 0x80; // Request for Master (data register ready)
const MSR_DIO: u8 = 0x40; // Data I/O direction: 1=controller->CPU, 0=CPU->controller
const MSR_NDMA: u8 = 0x20; // Non-DMA mode
const MSR_BUSY: u8 = 0x10; // FDC busy
const MSR_ACTD: u8 = 0x08; // Drive 3 active
const MSR_ACTC: u8 = 0x04; // Drive 2 active
const MSR_ACTB: u8 = 0x02; // Drive 1 active
const MSR_ACTA: u8 = 0x01; // Drive 0 active

// ---- DOR bits ----

const DOR_MOTD: u8 = 0x80; // Motor on drive 3
const DOR_MOTC: u8 = 0x40; // Motor on drive 2
const DOR_MOTB: u8 = 0x20; // Motor on drive 1
const DOR_MOTA: u8 = 0x10; // Motor on drive 0
const DOR_IRQ: u8 = 0x08; // DMA/IRQ enable
const DOR_RESET: u8 = 0x04; // Reset (active low: 0=reset, 1=normal)

// ---- FDC Commands ----

const CMD_SPECIFY: u8 = 0x03;
const CMD_SENSE_STATUS: u8 = 0x04;
const CMD_WRITE_DATA: u8 = 0xC5; // MT + MFM + write
const CMD_READ_DATA: u8 = 0xE6; // MT + MFM + SK + read
const CMD_RECALIBRATE: u8 = 0x07;
const CMD_SENSE_INTERRUPT: u8 = 0x08;
const CMD_SEEK: u8 = 0x0F;
const CMD_VERSION: u8 = 0x10;

// ---- Geometry ----

pub const CYLINDERS: u8 = 80;
pub const HEADS: u8 = 2;
pub const SECTORS_PER_TRACK: u8 = 18;
pub const SECTOR_SIZE: u16 = 512;
pub const TOTAL_SECTORS: u32 = @as(u32, CYLINDERS) * HEADS * SECTORS_PER_TRACK;
pub const DISK_SIZE: u32 = TOTAL_SECTORS * SECTOR_SIZE; // 1,474,560 bytes

// ---- State ----

var initialized: bool = false;
var motor_on: bool = false;
var current_cylinder: u8 = 0;
var fdc_present: bool = false;
var fdc_version: u8 = 0;

// DMA buffer -- must be below 16MB and not cross a 64KB boundary
// We use a fixed address in low memory (assuming kernel has reserved this area)
const DMA_BUF_ADDR: u32 = 0x80000; // 512KB mark, safe area

// ---- Internal helpers ----

/// Wait until FDC is ready to accept a command byte.
fn waitReady() bool {
    var timeout: u32 = 0;
    while (timeout < 10000) : (timeout += 1) {
        const status = idt.inb(MSR);
        if (status & MSR_RQM != 0) return true;
    }
    return false; // timeout
}

/// Send a command byte to the FDC.
fn sendByte(val: u8) bool {
    if (!waitReady()) return false;
    // Ensure direction is CPU->FDC
    const status = idt.inb(MSR);
    if (status & MSR_DIO != 0) return false;
    idt.outb(DATA_FIFO, val);
    return true;
}

/// Read a result byte from the FDC.
fn readByte() ?u8 {
    if (!waitReady()) return null;
    const status = idt.inb(MSR);
    if (status & MSR_DIO == 0) return null;
    return idt.inb(DATA_FIFO);
}

/// Delay helper (ms).
fn delayMs(ms: u32) void {
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        asm volatile ("pause");
    }
}

// ---- Motor control ----

pub fn motorStart() void {
    if (motor_on) return;
    // Enable drive 0 motor, IRQ, and take out of reset
    idt.outb(DOR, DOR_MOTA | DOR_IRQ | DOR_RESET | 0x00);
    // Wait for motor to spin up (~500ms)
    delayMs(500);
    motor_on = true;
}

pub fn motorStop() void {
    // Keep IRQ enabled and out of reset, but turn off motor
    idt.outb(DOR, DOR_IRQ | DOR_RESET);
    motor_on = false;
}

// ---- Sense Interrupt ----

const SenseResult = struct {
    st0: u8,
    cylinder: u8,
};

fn senseInterrupt() ?SenseResult {
    if (!sendByte(CMD_SENSE_INTERRUPT)) return null;
    const st0 = readByte() orelse return null;
    const cyl = readByte() orelse return null;
    return SenseResult{ .st0 = st0, .cylinder = cyl };
}

// ---- Reset ----

fn resetController() bool {
    // Enter reset state
    idt.outb(DOR, 0x00);
    delayMs(10);
    // Exit reset state, enable IRQ
    idt.outb(DOR, DOR_IRQ | DOR_RESET);
    delayMs(10);

    // After reset, controller sends 4 sense interrupts (one per drive)
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        _ = senseInterrupt();
    }

    // Set data rate to 500 kbps (1.44MB)
    idt.outb(CCR, 0x00);

    // Specify: step rate=3ms, head unload=240ms, head load=16ms, DMA mode
    if (!sendByte(CMD_SPECIFY)) return false;
    if (!sendByte(0xDF)) return false; // SRT=3ms, HUT=240ms
    if (!sendByte(0x02)) return false; // HLT=16ms, DMA mode

    return true;
}

// ---- Seek ----

pub fn seek(cylinder: u8) bool {
    if (!initialized) return false;
    if (cylinder >= CYLINDERS) return false;
    if (cylinder == current_cylinder) return true;

    motorStart();

    // Send seek command
    if (!sendByte(CMD_SEEK)) return false;
    if (!sendByte(0x00)) return false; // head 0, drive 0
    if (!sendByte(cylinder)) return false;

    // Wait for seek to complete
    delayMs(15);

    // Sense interrupt to get result
    const result = senseInterrupt() orelse return false;

    // Check ST0: bits 5-6 should be 00 (normal termination) and seek end bit set
    if (result.st0 & 0xC0 != 0x00) return false;
    if (result.cylinder != cylinder) return false;

    current_cylinder = cylinder;
    return true;
}

/// Recalibrate: seek to cylinder 0.
pub fn recalibrate() bool {
    motorStart();

    if (!sendByte(CMD_RECALIBRATE)) return false;
    if (!sendByte(0x00)) return false; // drive 0

    delayMs(20);

    const result = senseInterrupt() orelse return false;
    current_cylinder = 0;

    return result.cylinder == 0;
}

// ---- DMA setup ----

fn setupDmaRead() void {
    dma.setupChannel(2, DMA_BUF_ADDR, SECTOR_SIZE - 1, .single, .write, false);
}

fn setupDmaWrite() void {
    dma.setupChannel(2, DMA_BUF_ADDR, SECTOR_SIZE - 1, .single, .read, false);
}

// ---- Read / Write sector ----

/// Read a sector at CHS address into buf. Returns true on success.
pub fn readSector(cyl: u8, head: u8, sector: u8, buf: *[512]u8) bool {
    if (!initialized) return false;
    if (cyl >= CYLINDERS or head >= HEADS or sector == 0 or sector > SECTORS_PER_TRACK) return false;

    motorStart();

    if (!seek(cyl)) return false;

    // Setup DMA for reading
    setupDmaRead();

    // Issue read command
    if (!sendByte(CMD_READ_DATA)) return false;
    if (!sendByte((head << 2) | 0x00)) return false; // head, drive 0
    if (!sendByte(cyl)) return false;
    if (!sendByte(head)) return false;
    if (!sendByte(sector)) return false;
    if (!sendByte(0x02)) return false; // 512 bytes/sector
    if (!sendByte(SECTORS_PER_TRACK)) return false; // end of track
    if (!sendByte(0x1B)) return false; // gap3 length
    if (!sendByte(0xFF)) return false; // data length (unused for 512)

    // Wait for completion
    delayMs(50);

    // Read 7 result bytes
    var result: [7]u8 = undefined;
    for (&result) |*r| {
        r.* = readByte() orelse return false;
    }

    // Check ST0 for errors
    if (result[0] & 0xC0 != 0x00) return false;

    // Copy from DMA buffer to user buffer
    const src: [*]const u8 = @ptrFromInt(DMA_BUF_ADDR);
    for (buf, 0..) |*b, i| {
        b.* = src[i];
    }

    return true;
}

/// Write a sector at CHS address from buf. Returns true on success.
pub fn writeSector(cyl: u8, head: u8, sector: u8, buf: *const [512]u8) bool {
    if (!initialized) return false;
    if (cyl >= CYLINDERS or head >= HEADS or sector == 0 or sector > SECTORS_PER_TRACK) return false;

    motorStart();

    if (!seek(cyl)) return false;

    // Copy user data to DMA buffer
    const dst: [*]volatile u8 = @ptrFromInt(DMA_BUF_ADDR);
    for (buf, 0..) |b, i| {
        dst[i] = b;
    }

    // Setup DMA for writing
    setupDmaWrite();

    // Issue write command
    if (!sendByte(CMD_WRITE_DATA)) return false;
    if (!sendByte((head << 2) | 0x00)) return false;
    if (!sendByte(cyl)) return false;
    if (!sendByte(head)) return false;
    if (!sendByte(sector)) return false;
    if (!sendByte(0x02)) return false;
    if (!sendByte(SECTORS_PER_TRACK)) return false;
    if (!sendByte(0x1B)) return false;
    if (!sendByte(0xFF)) return false;

    // Wait for completion
    delayMs(50);

    // Read 7 result bytes
    var result: [7]u8 = undefined;
    for (&result) |*r| {
        r.* = readByte() orelse return false;
    }

    return result[0] & 0xC0 == 0x00;
}

// ---- LBA helpers ----

/// Convert LBA to CHS. Returns {cylinder, head, sector}.
pub fn lbaToChs(lba: u32) struct { cyl: u8, head: u8, sector: u8 } {
    const spt: u32 = SECTORS_PER_TRACK;
    const hpc: u32 = HEADS;
    return .{
        .cyl = @truncate(lba / (spt * hpc)),
        .head = @truncate((lba / spt) % hpc),
        .sector = @truncate((lba % spt) + 1),
    };
}

/// Read a sector by LBA address.
pub fn readLba(lba: u32, buf: *[512]u8) bool {
    if (lba >= TOTAL_SECTORS) return false;
    const chs = lbaToChs(lba);
    return readSector(chs.cyl, chs.head, chs.sector, buf);
}

/// Write a sector by LBA address.
pub fn writeLba(lba: u32, buf: *const [512]u8) bool {
    if (lba >= TOTAL_SECTORS) return false;
    const chs = lbaToChs(lba);
    return writeSector(chs.cyl, chs.head, chs.sector, buf);
}

// ---- Detection / Init ----

/// Check if a floppy controller is present.
pub fn isPresent() bool {
    return fdc_present;
}

/// Initialize the floppy disk controller.
pub fn init() void {
    initialized = false;
    fdc_present = false;
    motor_on = false;
    current_cylinder = 0;

    // Try to detect FDC by sending VERSION command
    if (!sendByte(CMD_VERSION)) {
        serial.write("[FLOPPY] No FDC detected (timeout)\n");
        return;
    }
    const ver = readByte();
    if (ver) |v| {
        fdc_version = v;
        fdc_present = true;
    } else {
        serial.write("[FLOPPY] No FDC detected (no response)\n");
        return;
    }

    // Reset and configure
    if (!resetController()) {
        serial.write("[FLOPPY] FDC reset failed\n");
        return;
    }

    // Recalibrate to cylinder 0
    if (!recalibrate()) {
        serial.write("[FLOPPY] Recalibrate failed\n");
        // Not fatal -- continue anyway
    }

    initialized = true;
    serial.write("[FLOPPY] FDC initialized, version=0x");
    serialWriteHex8(fdc_version);
    serial.write("\n");
}

fn serialWriteHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0x0F]);
}

// ---- Info display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Floppy Disk Controller\n");
    vga.setColor(.light_grey, .black);

    if (!fdc_present) {
        vga.write("  No FDC detected\n");
        return;
    }

    vga.write("  Controller: 82077AA compatible\n");
    vga.write("  Version: 0x");
    fmt.printHex8(fdc_version);
    vga.putChar('\n');

    vga.write("  Geometry: ");
    fmt.printDec(CYLINDERS);
    vga.write(" cyl, ");
    fmt.printDec(HEADS);
    vga.write(" heads, ");
    fmt.printDec(SECTORS_PER_TRACK);
    vga.write(" sec/trk\n");

    vga.write("  Capacity: ");
    fmt.printDec(DISK_SIZE / 1024);
    vga.write(" KB (1.44 MB)\n");

    vga.write("  Motor: ");
    if (motor_on) {
        vga.setColor(.light_green, .black);
        vga.write("ON\n");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("OFF\n");
    }
    vga.setColor(.light_grey, .black);

    vga.write("  Current cylinder: ");
    fmt.printDec(current_cylinder);
    vga.putChar('\n');

    vga.write("  MSR: 0x");
    fmt.printHex8(idt.inb(MSR));
    vga.putChar('\n');
}

/// Return whether the driver is initialized and ready.
pub fn isReady() bool {
    return initialized and fdc_present;
}
