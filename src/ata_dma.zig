// ATA DMA (Bus Master IDE) Driver
//
// Uses PCI Bus Master IDE (BM-IDE) for DMA transfers instead of PIO.
// DMA transfers allow the disk controller to transfer data directly
// to/from memory without CPU involvement per word.
//
// Key concepts:
//   - PCI BAR4 provides Bus Master register base
//   - PRDT (Physical Region Descriptor Table): list of memory regions
//   - PRD entry: 32-bit physical address, 16-bit byte count, EOT flag
//   - Command register controls start/stop and read/write direction
//   - Status register indicates active, error, and interrupt states
//
// Requires the IDE controller to be a PCI Bus Master capable device.

const idt = @import("idt.zig");
const pci = @import("pci.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");

// ---- ATA I/O Ports ----

const ATA_DATA: u16 = 0x1F0;
const ATA_ERROR: u16 = 0x1F1;
const ATA_FEATURES: u16 = 0x1F1;
const ATA_SECT_CNT: u16 = 0x1F2;
const ATA_LBA_LO: u16 = 0x1F3;
const ATA_LBA_MID: u16 = 0x1F4;
const ATA_LBA_HI: u16 = 0x1F5;
const ATA_DEVICE: u16 = 0x1F6;
const ATA_CMD: u16 = 0x1F7;
const ATA_STATUS: u16 = 0x1F7;
const ATA_ALT_STATUS: u16 = 0x3F6;

// ---- ATA Commands ----

const CMD_READ_DMA: u8 = 0xC8;
const CMD_WRITE_DMA: u8 = 0xCA;
const CMD_READ_DMA_EXT: u8 = 0x25; // LBA48
const CMD_WRITE_DMA_EXT: u8 = 0x35; // LBA48
const CMD_READ_PIO: u8 = 0x20;
const CMD_IDENTIFY: u8 = 0xEC;

// ---- ATA Status bits ----

const STATUS_ERR: u8 = 0x01;
const STATUS_DRQ: u8 = 0x08;
const STATUS_DF: u8 = 0x20;
const STATUS_BSY: u8 = 0x80;

// ---- Bus Master IDE Register Offsets (from BAR4) ----

const BM_CMD_PRIMARY: u16 = 0x00; // Command register
const BM_STATUS_PRIMARY: u16 = 0x02; // Status register
const BM_PRDT_PRIMARY: u16 = 0x04; // PRDT address register (32-bit)

const BM_CMD_SECONDARY: u16 = 0x08;
const BM_STATUS_SECONDARY: u16 = 0x0A;
const BM_PRDT_SECONDARY: u16 = 0x0C;

// ---- BM Command Register bits ----

const BM_CMD_START: u8 = 0x01; // Start Bus Master operation
const BM_CMD_READ: u8 = 0x08; // Direction: 0=write(mem->disk), 1=read(disk->mem)

// ---- BM Status Register bits ----

const BM_STATUS_ACTIVE: u8 = 0x01; // Bus Master active (DMA in progress)
const BM_STATUS_ERROR: u8 = 0x02; // Error occurred
const BM_STATUS_INTERRUPT: u8 = 0x04; // Interrupt received
const BM_STATUS_DRV0_DMA: u8 = 0x20; // Drive 0 DMA capable
const BM_STATUS_DRV1_DMA: u8 = 0x40; // Drive 1 DMA capable
const BM_STATUS_SIMPLEX: u8 = 0x80; // Simplex only (not both channels)

// ---- Physical Region Descriptor (PRD) Entry ----

pub const PrdEntry = extern struct {
    phys_addr: u32, // Physical address of memory region
    byte_count: u16, // Byte count (0 means 64KB)
    reserved: u8,
    flags: u8, // Bit 7 = EOT (End Of Table)
};

const PRD_EOT: u8 = 0x80;

// ---- PRDT (Physical Region Descriptor Table) ----

const MAX_PRD_ENTRIES = 8; // Maximum scatter/gather entries per transfer

// ---- State ----

var bm_base: u16 = 0; // Bus Master I/O base (from PCI BAR4)
var dma_available: bool = false;
var ide_bus: u8 = 0;
var ide_slot: u8 = 0;
var ide_func: u8 = 0;
var ide_vendor: u16 = 0;
var ide_device: u16 = 0;
var disk_present: bool = false;

// Statically allocated PRDT (must be 4-byte aligned, not cross 64KB boundary)
var prdt: [MAX_PRD_ENTRIES]PrdEntry align(4) = @splat(PrdEntry{
    .phys_addr = 0,
    .byte_count = 0,
    .reserved = 0,
    .flags = 0,
});

// Transfer statistics
var dma_reads: u32 = 0;
var dma_writes: u32 = 0;
var dma_errors: u32 = 0;
var pio_reads: u32 = 0;

// ---- Initialization ----

/// Detect and initialize ATA DMA (Bus Master IDE).
pub fn init() void {
    dma_available = false;
    disk_present = false;
    dma_reads = 0;
    dma_writes = 0;
    dma_errors = 0;
    pio_reads = 0;

    // Find IDE controller in PCI (class 0x01, subclass 0x01)
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

            if (class == 0x01 and subclass == 0x01) {
                // IDE controller found
                // BAR4 = Bus Master I/O base
                const bar4 = pci.readConfig(0, slot, func, 0x20);
                if (bar4 & 0x01 != 0) { // I/O space
                    bm_base = @truncate(bar4 & 0xFFFC);
                    ide_bus = 0;
                    ide_slot = slot;
                    ide_func = func;
                    ide_vendor = vid;
                    ide_device = @truncate(r0 >> 16);

                    // Enable Bus Mastering in PCI command register
                    pci.enableBusMastering(0, slot, func);

                    dma_available = bm_base != 0;

                    serial.write("[ATA-DMA] found at ");
                    serialHex8(slot);
                    serial.write(" BM=0x");
                    serialHex16(bm_base);
                    serial.write("\n");

                    // Check if primary drive supports DMA
                    checkDmaCapability();

                    // Check disk presence
                    checkDiskPresence();
                    return;
                }
            }

            if (func == 0) {
                const hdr: u8 = @truncate(pci.readConfig(0, slot, 0, 0x0C) >> 16);
                if (hdr & 0x80 == 0) break;
            }
        }
    }

    serial.write("[ATA-DMA] no BM-IDE controller\n");
}

fn checkDmaCapability() void {
    if (bm_base == 0) return;

    // Read BM status to check DMA capability bits
    const status = idt.inb(bm_base + BM_STATUS_PRIMARY);

    if (status & BM_STATUS_DRV0_DMA != 0) {
        serial.write("[ATA-DMA] Drive 0 DMA capable\n");
    }
    if (status & BM_STATUS_DRV1_DMA != 0) {
        serial.write("[ATA-DMA] Drive 1 DMA capable\n");
    }
}

fn checkDiskPresence() void {
    idt.outb(ATA_DEVICE, 0xA0);
    ioWait();
    const st = idt.inb(ATA_STATUS);
    disk_present = (st != 0xFF and st != 0x00);
}

// ---- I/O Wait ----

fn ioWait() void {
    _ = idt.inb(ATA_ALT_STATUS);
    _ = idt.inb(ATA_ALT_STATUS);
    _ = idt.inb(ATA_ALT_STATUS);
    _ = idt.inb(ATA_ALT_STATUS);
}

fn waitReady() bool {
    var timeout: u32 = 0;
    while (timeout < 200000) : (timeout += 1) {
        const st = idt.inb(ATA_STATUS);
        if (st & STATUS_BSY == 0) return true;
    }
    return false;
}

fn waitDrq() bool {
    var timeout: u32 = 0;
    while (timeout < 200000) : (timeout += 1) {
        const st = idt.inb(ATA_STATUS);
        if (st & STATUS_ERR != 0) return false;
        if (st & STATUS_BSY == 0 and st & STATUS_DRQ != 0) return true;
    }
    return false;
}

// ---- PRDT Setup ----

/// Setup PRDT for a single contiguous buffer.
fn setupPrdt(phys_addr: u32, byte_count: u32) void {
    // Split into entries (each max 64KB, must not cross 64KB boundary)
    var remaining = byte_count;
    var addr = phys_addr;
    var idx: usize = 0;

    while (remaining > 0 and idx < MAX_PRD_ENTRIES) {
        // Check 64KB boundary
        const boundary = (addr + 0x10000) & 0xFFFF0000;
        const to_boundary = boundary - addr;
        var chunk = remaining;
        if (chunk > 0x10000) chunk = 0x10000;
        if (chunk > to_boundary) chunk = to_boundary;

        prdt[idx] = .{
            .phys_addr = addr,
            .byte_count = if (chunk >= 0x10000) 0 else @truncate(chunk),
            .reserved = 0,
            .flags = 0,
        };

        addr += chunk;
        remaining -= chunk;
        idx += 1;
    }

    // Set EOT on last entry
    if (idx > 0) {
        prdt[idx - 1].flags = PRD_EOT;
    }
}

// ---- DMA Transfer ----

/// Read sectors using DMA. Returns true on success.
/// `lba`: starting LBA (28-bit), `count`: number of sectors (1-255),
/// `buf`: pointer to buffer (must be physically contiguous, 4-byte aligned).
pub fn readDMA(lba: u32, count: u8, buf: [*]u8) bool {
    if (!dma_available or !disk_present or count == 0) return false;

    const byte_count: u32 = @as(u32, count) * 512;
    const buf_addr = @intFromPtr(buf);

    // Setup PRDT
    setupPrdt(@truncate(buf_addr), byte_count);

    // Stop any existing DMA
    idt.outb(bm_base + BM_CMD_PRIMARY, 0);

    // Clear status (write 1 to clear error and interrupt bits)
    idt.outb(bm_base + BM_STATUS_PRIMARY, BM_STATUS_ERROR | BM_STATUS_INTERRUPT);

    // Set PRDT address
    idt.outl(bm_base + BM_PRDT_PRIMARY, @intFromPtr(&prdt));

    // Set direction to read (disk -> memory)
    idt.outb(bm_base + BM_CMD_PRIMARY, BM_CMD_READ);

    // Setup ATA registers for DMA READ
    idt.outb(ATA_DEVICE, 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)));
    ioWait();
    idt.outb(ATA_FEATURES, 0); // No features
    idt.outb(ATA_SECT_CNT, count);
    idt.outb(ATA_LBA_LO, @truncate(lba));
    idt.outb(ATA_LBA_MID, @truncate(lba >> 8));
    idt.outb(ATA_LBA_HI, @truncate(lba >> 16));

    // Issue DMA READ command
    idt.outb(ATA_CMD, CMD_READ_DMA);

    // Start Bus Master DMA
    idt.outb(bm_base + BM_CMD_PRIMARY, BM_CMD_START | BM_CMD_READ);

    // Wait for completion
    if (!waitDmaComplete()) {
        // Stop DMA on error
        idt.outb(bm_base + BM_CMD_PRIMARY, 0);
        idt.outb(bm_base + BM_STATUS_PRIMARY, BM_STATUS_ERROR | BM_STATUS_INTERRUPT);
        dma_errors += 1;
        return false;
    }

    // Stop DMA
    idt.outb(bm_base + BM_CMD_PRIMARY, 0);

    // Clear interrupt bit
    idt.outb(bm_base + BM_STATUS_PRIMARY, BM_STATUS_INTERRUPT);

    dma_reads += 1;
    return true;
}

/// Write sectors using DMA. Returns true on success.
pub fn writeDMA(lba: u32, count: u8, buf: [*]const u8) bool {
    if (!dma_available or !disk_present or count == 0) return false;

    const byte_count: u32 = @as(u32, count) * 512;
    const buf_addr = @intFromPtr(buf);

    // Setup PRDT
    setupPrdt(@truncate(buf_addr), byte_count);

    // Stop DMA
    idt.outb(bm_base + BM_CMD_PRIMARY, 0);

    // Clear status
    idt.outb(bm_base + BM_STATUS_PRIMARY, BM_STATUS_ERROR | BM_STATUS_INTERRUPT);

    // Set PRDT address
    idt.outl(bm_base + BM_PRDT_PRIMARY, @intFromPtr(&prdt));

    // Set direction to write (memory -> disk): clear read bit
    idt.outb(bm_base + BM_CMD_PRIMARY, 0);

    // Setup ATA registers for DMA WRITE
    idt.outb(ATA_DEVICE, 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)));
    ioWait();
    idt.outb(ATA_FEATURES, 0);
    idt.outb(ATA_SECT_CNT, count);
    idt.outb(ATA_LBA_LO, @truncate(lba));
    idt.outb(ATA_LBA_MID, @truncate(lba >> 8));
    idt.outb(ATA_LBA_HI, @truncate(lba >> 16));

    // Issue DMA WRITE command
    idt.outb(ATA_CMD, CMD_WRITE_DMA);

    // Start Bus Master DMA (write direction = bit 3 clear)
    idt.outb(bm_base + BM_CMD_PRIMARY, BM_CMD_START);

    // Wait for completion
    if (!waitDmaComplete()) {
        idt.outb(bm_base + BM_CMD_PRIMARY, 0);
        idt.outb(bm_base + BM_STATUS_PRIMARY, BM_STATUS_ERROR | BM_STATUS_INTERRUPT);
        dma_errors += 1;
        return false;
    }

    // Stop DMA
    idt.outb(bm_base + BM_CMD_PRIMARY, 0);
    idt.outb(bm_base + BM_STATUS_PRIMARY, BM_STATUS_INTERRUPT);

    dma_writes += 1;
    return true;
}

/// Wait for DMA transfer to complete.
fn waitDmaComplete() bool {
    const start = pit.getTicks();
    const timeout: u64 = 5000; // 5 second timeout

    while (pit.getTicks() - start < timeout) {
        const bm_status = idt.inb(bm_base + BM_STATUS_PRIMARY);

        // Check for error
        if (bm_status & BM_STATUS_ERROR != 0) return false;

        // Check for interrupt (transfer complete)
        if (bm_status & BM_STATUS_INTERRUPT != 0) {
            // Also check ATA status
            const ata_status = idt.inb(ATA_STATUS);
            if (ata_status & STATUS_ERR != 0) return false;
            if (ata_status & STATUS_BSY == 0) return true;
        }

        asm volatile ("pause");
    }

    return false; // Timeout
}

// ---- PIO Fallback (for comparison) ----

/// Read sectors using PIO (for performance comparison).
pub fn readPIO(lba: u32, count: u8, buf: [*]u8) bool {
    if (!disk_present or count == 0) return false;

    idt.outb(ATA_DEVICE, 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)));
    idt.outb(ATA_SECT_CNT, count);
    idt.outb(ATA_LBA_LO, @truncate(lba));
    idt.outb(ATA_LBA_MID, @truncate(lba >> 8));
    idt.outb(ATA_LBA_HI, @truncate(lba >> 16));
    idt.outb(ATA_CMD, CMD_READ_PIO);

    var sect: u32 = 0;
    while (sect < count) : (sect += 1) {
        if (!waitDrq()) return false;

        const offset = sect * 512;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const word = idt.inw(ATA_DATA);
            buf[offset + i * 2] = @truncate(word);
            buf[offset + i * 2 + 1] = @truncate(word >> 8);
        }
    }
    pio_reads += 1;
    return true;
}

/// Benchmark: compare PIO vs DMA read time for a given number of sectors.
pub fn benchmarkTransfer(lba: u32, count: u8, buf: [*]u8) void {
    // PIO benchmark
    const pio_start = pit.getTicks();
    var pio_ok = false;
    var pio_i: u32 = 0;
    while (pio_i < 10) : (pio_i += 1) {
        pio_ok = readPIO(lba, count, buf);
        if (!pio_ok) break;
    }
    const pio_ticks = pit.getTicks() - pio_start;

    // DMA benchmark
    const dma_start = pit.getTicks();
    var dma_ok = false;
    var dma_i: u32 = 0;
    while (dma_i < 10) : (dma_i += 1) {
        dma_ok = readDMA(lba, count, buf);
        if (!dma_ok) break;
    }
    const dma_ticks = pit.getTicks() - dma_start;

    vga.write("  PIO:  ");
    if (pio_ok) {
        printDec64(pio_ticks);
        vga.write(" ms (10 reads)\n");
    } else {
        vga.write("FAILED\n");
    }

    vga.write("  DMA:  ");
    if (dma_ok) {
        printDec64(dma_ticks);
        vga.write(" ms (10 reads)\n");
    } else {
        vga.write("FAILED\n");
    }

    if (pio_ok and dma_ok and dma_ticks > 0) {
        if (dma_ticks < pio_ticks) {
            const speedup = (pio_ticks * 100) / dma_ticks;
            vga.write("  DMA is ");
            printDec64(speedup);
            vga.write("% of PIO time (faster)\n");
        } else {
            vga.write("  DMA not faster (possibly PIO-only controller)\n");
        }
    }
}

// ---- Query ----

/// Check if DMA is available.
pub fn isDmaAvailable() bool {
    return dma_available;
}

/// Check if disk is present.
pub fn isDiskPresent() bool {
    return disk_present;
}

/// Get the Bus Master I/O base.
pub fn getBmBase() u16 {
    return bm_base;
}

/// Get DMA read count.
pub fn getDmaReads() u32 {
    return dma_reads;
}

/// Get DMA write count.
pub fn getDmaWrites() u32 {
    return dma_writes;
}

/// Get DMA error count.
pub fn getDmaErrors() u32 {
    return dma_errors;
}

/// Get the BM status register.
pub fn getBmStatus() u8 {
    if (bm_base == 0) return 0;
    return idt.inb(bm_base + BM_STATUS_PRIMARY);
}

// ---- Display ----

/// Print ATA DMA information.
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("ATA DMA (Bus Master IDE) Info:\n");
    vga.setColor(.light_grey, .black);

    if (!dma_available) {
        vga.write("  DMA not available\n");
        return;
    }

    vga.write("  PCI:        00:");
    printHex8(ide_slot);
    vga.putChar('.');
    printDecU8(ide_func);
    vga.write("  VID:DID ");
    printHex16(ide_vendor);
    vga.putChar(':');
    printHex16(ide_device);
    vga.putChar('\n');

    vga.write("  BM Base:    0x");
    printHex16(bm_base);
    vga.putChar('\n');

    // BM Status
    const status = getBmStatus();
    vga.write("  BM Status:  0x");
    printHex8(status);
    vga.write(" [");
    if (status & BM_STATUS_ACTIVE != 0) vga.write("ACTIVE ");
    if (status & BM_STATUS_ERROR != 0) vga.write("ERROR ");
    if (status & BM_STATUS_INTERRUPT != 0) vga.write("IRQ ");
    if (status & BM_STATUS_DRV0_DMA != 0) vga.write("DRV0-DMA ");
    if (status & BM_STATUS_DRV1_DMA != 0) vga.write("DRV1-DMA ");
    if (status & BM_STATUS_SIMPLEX != 0) vga.write("SIMPLEX ");
    vga.write("]\n");

    vga.write("  Disk:       ");
    if (disk_present) {
        vga.setColor(.light_green, .black);
        vga.write("Present\n");
    } else {
        vga.write("Not detected\n");
    }
    vga.setColor(.light_grey, .black);

    // PRDT address
    vga.write("  PRDT:       0x");
    printHex32(@truncate(@intFromPtr(&prdt)));
    vga.putChar('\n');

    // Statistics
    vga.write("  Statistics:\n");
    vga.write("    DMA reads:  ");
    printDec32(dma_reads);
    vga.putChar('\n');
    vga.write("    DMA writes: ");
    printDec32(dma_writes);
    vga.putChar('\n');
    vga.write("    DMA errors: ");
    printDec32(dma_errors);
    vga.putChar('\n');
    vga.write("    PIO reads:  ");
    printDec32(pio_reads);
    vga.putChar('\n');
}

// ---- Internal helpers ----

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
}

fn printHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;
    var v = val;
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
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

fn serialHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0xF]);
}

fn serialHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;
    var v = val;
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| serial.putChar(c);
}
