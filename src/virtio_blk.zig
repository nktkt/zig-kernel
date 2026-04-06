// VirtIO ブロックデバイスドライバ — Legacy I/O ポートインターフェース
//
// PCI device 0x1AF4:0x1001. VirtIO legacy (transitional).
// デバイス設定: capacity, size_max, seg_max.
// リクエストタイプ: IN(read=0), OUT(write=1), FLUSH(4).
// VirtioBlkReq: type(32), reserved(32), sector(64) + data + status(8).

const pci = @import("pci.zig");
const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");

// ---- PCI identification ----

const VIRTIO_VENDOR: u16 = 0x1AF4;
const VIRTIO_BLK_DEV: u16 = 0x1001; // Transitional block device

// ---- VirtIO Legacy PCI register offsets (I/O space) ----

const VIRTIO_REG_DEVICE_FEATURES: u16 = 0x00;
const VIRTIO_REG_GUEST_FEATURES: u16 = 0x04;
const VIRTIO_REG_QUEUE_ADDR: u16 = 0x08;
const VIRTIO_REG_QUEUE_SIZE: u16 = 0x0C;
const VIRTIO_REG_QUEUE_SELECT: u16 = 0x0E;
const VIRTIO_REG_QUEUE_NOTIFY: u16 = 0x10;
const VIRTIO_REG_DEVICE_STATUS: u16 = 0x12;
const VIRTIO_REG_ISR_STATUS: u16 = 0x13;

// Device-specific config starts at offset 0x14 (legacy)
const VIRTIO_BLK_CFG_CAPACITY_LO: u16 = 0x14; // 32-bit
const VIRTIO_BLK_CFG_CAPACITY_HI: u16 = 0x18; // 32-bit
const VIRTIO_BLK_CFG_SIZE_MAX: u16 = 0x1C; // 32-bit
const VIRTIO_BLK_CFG_SEG_MAX: u16 = 0x20; // 32-bit
const VIRTIO_BLK_CFG_GEOMETRY: u16 = 0x24; // cylinders(16) + heads(8) + sectors(8)
const VIRTIO_BLK_CFG_BLK_SIZE: u16 = 0x28; // 32-bit (optional)

// ---- Device Status bits ----

const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_FAILED: u8 = 128;

// ---- VirtIO Block Feature bits ----

const VIRTIO_BLK_F_SIZE_MAX: u32 = 1 << 1; // Maximum size of any single segment
const VIRTIO_BLK_F_SEG_MAX: u32 = 1 << 2; // Maximum number of segments in a request
const VIRTIO_BLK_F_GEOMETRY: u32 = 1 << 4; // Disk-style geometry
const VIRTIO_BLK_F_RO: u32 = 1 << 5; // Read-only device
const VIRTIO_BLK_F_BLK_SIZE: u32 = 1 << 6; // Block size of disk
const VIRTIO_BLK_F_FLUSH: u32 = 1 << 9; // Cache flush command support
const VIRTIO_BLK_F_TOPOLOGY: u32 = 1 << 10; // Device reports topology

// ---- Block request types ----

const VIRTIO_BLK_T_IN: u32 = 0; // Read
const VIRTIO_BLK_T_OUT: u32 = 1; // Write
const VIRTIO_BLK_T_FLUSH: u32 = 4; // Flush

// ---- Block request status ----

const VIRTIO_BLK_S_OK: u8 = 0;
const VIRTIO_BLK_S_IOERR: u8 = 1;
const VIRTIO_BLK_S_UNSUPP: u8 = 2;

// ---- VirtIO Block Request Header ----

const VirtioBlkReqHdr = packed struct {
    req_type: u32,
    reserved: u32,
    sector: u64,
};

// ---- VirtQueue structures ----

const VirtqDesc = packed struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

const VirtqAvail = packed struct {
    flags: u16,
    idx: u16,
};

const VirtqUsedElem = packed struct {
    id: u32,
    len: u32,
};

const VirtqUsed = packed struct {
    flags: u16,
    idx: u16,
};

// ---- Queue constants ----

const REQ_QUEUE: u16 = 0;
const QUEUE_SIZE: u16 = 128;
const PAGE_SIZE: u32 = 4096;
const SECTOR_SIZE: usize = 512;

// ---- Queue state ----

const QueueState = struct {
    desc: [*]volatile VirtqDesc,
    avail: *volatile VirtqAvail,
    avail_ring: [*]volatile u16,
    used: *volatile VirtqUsed,
    used_ring: [*]volatile VirtqUsedElem,
    size: u16,
    free_head: u16,
    last_used_idx: u16,
    num_free: u16,
};

// ---- State ----

var io_base: u16 = 0;
var ready: bool = false;
var pci_bus: u8 = 0;
var pci_slot: u8 = 0;
var pci_func: u8 = 0;
var device_features: u32 = 0;
var negotiated_features: u32 = 0;
var capacity: u64 = 0; // In 512-byte sectors
var size_max: u32 = 0;
var seg_max: u32 = 0;
var blk_size: u32 = 512;
var is_readonly: bool = false;
var has_flush: bool = false;

var req_queue: QueueState = undefined;

// Request buffers (statically allocated)
var req_hdr: VirtioBlkReqHdr align(16) = undefined;
var req_status: u8 align(16) = 0;
var data_buf: [SECTOR_SIZE * 256]u8 align(16) = @splat(0); // Max 128KB

// Statistics
var read_ops: u32 = 0;
var write_ops: u32 = 0;
var errors: u32 = 0;

// ---- I/O helpers ----

fn readReg8(offset: u16) u8 {
    return idt.inb(io_base + offset);
}

fn writeReg8(offset: u16, val: u8) void {
    idt.outb(io_base + offset, val);
}

fn readReg16(offset: u16) u16 {
    return idt.inw(io_base + offset);
}

fn writeReg16(offset: u16, val: u16) void {
    idt.outw(io_base + offset, val);
}

fn readReg32(offset: u16) u32 {
    return idt.inl(io_base + offset);
}

fn writeReg32(offset: u16, val: u32) void {
    idt.outl(io_base + offset, val);
}

// ---- Initialization ----

pub fn init() bool {
    const dev = pci.findDevice(VIRTIO_VENDOR, VIRTIO_BLK_DEV) orelse {
        serial.write("[VIRTIO-BLK] Device not found\n");
        return false;
    };

    pci_bus = dev.bus;
    pci_slot = dev.slot;
    pci_func = dev.func;

    const bar0 = dev.bar0;
    if (bar0 & 0x01 == 0) {
        serial.write("[VIRTIO-BLK] BAR0 is not I/O space\n");
        return false;
    }
    io_base = @truncate(bar0 & 0xFFFC);
    if (io_base == 0) return false;

    pci.enableBusMastering(pci_bus, pci_slot, pci_func);

    // 1. Reset
    writeReg8(VIRTIO_REG_DEVICE_STATUS, 0);

    // 2. Acknowledge
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);

    // 3. Driver
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // 4. Read features
    device_features = readReg32(VIRTIO_REG_DEVICE_FEATURES);

    // 5. Negotiate features
    negotiated_features = 0;
    if (device_features & VIRTIO_BLK_F_SIZE_MAX != 0) {
        negotiated_features |= VIRTIO_BLK_F_SIZE_MAX;
    }
    if (device_features & VIRTIO_BLK_F_SEG_MAX != 0) {
        negotiated_features |= VIRTIO_BLK_F_SEG_MAX;
    }
    if (device_features & VIRTIO_BLK_F_BLK_SIZE != 0) {
        negotiated_features |= VIRTIO_BLK_F_BLK_SIZE;
    }
    if (device_features & VIRTIO_BLK_F_FLUSH != 0) {
        negotiated_features |= VIRTIO_BLK_F_FLUSH;
        has_flush = true;
    }
    is_readonly = (device_features & VIRTIO_BLK_F_RO) != 0;

    writeReg32(VIRTIO_REG_GUEST_FEATURES, negotiated_features);

    // 6. Features OK
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

    const status = readReg8(VIRTIO_REG_DEVICE_STATUS);
    if (status & STATUS_FEATURES_OK == 0) {
        serial.write("[VIRTIO-BLK] Features not accepted\n");
        writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // 7. Read device configuration
    readDeviceConfig();

    // 8. Setup request queue
    if (!setupQueue(REQ_QUEUE, &req_queue)) {
        serial.write("[VIRTIO-BLK] Queue setup failed\n");
        writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // 9. Driver OK
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    ready = true;

    serial.write("[VIRTIO-BLK] capacity=");
    serial.writeHex(@truncate(capacity));
    serial.write(" sectors, IO=0x");
    serialHex16(io_base);
    serial.write("\n");

    return true;
}

fn readDeviceConfig() void {
    // Capacity (in 512-byte sectors)
    const cap_lo: u64 = readReg32(VIRTIO_BLK_CFG_CAPACITY_LO);
    const cap_hi: u64 = readReg32(VIRTIO_BLK_CFG_CAPACITY_HI);
    capacity = cap_lo | (cap_hi << 32);

    if (negotiated_features & VIRTIO_BLK_F_SIZE_MAX != 0) {
        size_max = readReg32(VIRTIO_BLK_CFG_SIZE_MAX);
    }
    if (negotiated_features & VIRTIO_BLK_F_SEG_MAX != 0) {
        seg_max = readReg32(VIRTIO_BLK_CFG_SEG_MAX);
    }
    if (negotiated_features & VIRTIO_BLK_F_BLK_SIZE != 0) {
        blk_size = readReg32(VIRTIO_BLK_CFG_BLK_SIZE);
        if (blk_size == 0) blk_size = 512;
    }
}

fn setupQueue(queue_idx: u16, qs: *QueueState) bool {
    writeReg16(VIRTIO_REG_QUEUE_SELECT, queue_idx);

    const size = readReg16(VIRTIO_REG_QUEUE_SIZE);
    if (size == 0) return false;

    const actual_size: u16 = if (size > QUEUE_SIZE) QUEUE_SIZE else size;
    qs.size = actual_size;

    // Calculate layout
    const desc_size = @as(u32, actual_size) * @sizeOf(VirtqDesc);
    const avail_size = 6 + @as(u32, actual_size) * 2;
    const used_offset_unaligned = desc_size + avail_size;
    const used_offset = (used_offset_unaligned + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    const used_size = 6 + @as(u32, actual_size) * 8;
    const total_size = used_offset + used_size;

    const num_pages = (total_size + PAGE_SIZE - 1) / PAGE_SIZE;
    var base_addr: u32 = 0;

    if (pmm.alloc()) |page| {
        base_addr = page;
    } else {
        return false;
    }

    var p: u32 = 1;
    while (p < num_pages) : (p += 1) {
        _ = pmm.alloc();
    }

    // Zero memory
    const base_bytes: [*]volatile u8 = @ptrFromInt(base_addr);
    for (0..total_size) |i| {
        base_bytes[i] = 0;
    }

    qs.desc = @ptrFromInt(base_addr);
    qs.avail = @ptrFromInt(base_addr + desc_size);
    qs.avail_ring = @ptrFromInt(base_addr + desc_size + 4);
    qs.used = @ptrFromInt(base_addr + used_offset);
    qs.used_ring = @ptrFromInt(base_addr + used_offset + 4);
    qs.free_head = 0;
    qs.last_used_idx = 0;
    qs.num_free = actual_size;

    // Chain free descriptors
    var i: u16 = 0;
    while (i < actual_size) : (i += 1) {
        qs.desc[i].next = i + 1;
        qs.desc[i].flags = 0;
    }

    qs.avail.flags = 0;
    qs.avail.idx = 0;

    writeReg32(VIRTIO_REG_QUEUE_ADDR, base_addr / PAGE_SIZE);
    return true;
}

// ---- Block operations ----

fn doBlockOp(req_type: u32, sector: u64, count: u16, buf: [*]u8) bool {
    if (!ready) return false;
    if (req_queue.num_free < 3) return false; // Need 3 descriptors: hdr + data + status

    const byte_count = @as(u32, count) * SECTOR_SIZE;

    // Setup request header
    req_hdr = .{
        .req_type = req_type,
        .reserved = 0,
        .sector = sector,
    };
    req_status = 0xFF; // Sentinel

    // Allocate 3 chained descriptors
    const d0 = req_queue.free_head;
    const d1 = req_queue.desc[d0].next;
    const d2 = req_queue.desc[d1].next;
    req_queue.free_head = req_queue.desc[d2].next;
    req_queue.num_free -= 3;

    // Descriptor 0: request header (device reads)
    req_queue.desc[d0].addr = @intFromPtr(&req_hdr);
    req_queue.desc[d0].len = @sizeOf(VirtioBlkReqHdr);
    req_queue.desc[d0].flags = VRING_DESC_F_NEXT;
    req_queue.desc[d0].next = d1;

    // Descriptor 1: data buffer
    req_queue.desc[d1].addr = @intFromPtr(buf);
    req_queue.desc[d1].len = byte_count;
    if (req_type == VIRTIO_BLK_T_IN) {
        req_queue.desc[d1].flags = VRING_DESC_F_NEXT | VRING_DESC_F_WRITE;
    } else {
        req_queue.desc[d1].flags = VRING_DESC_F_NEXT;
    }
    req_queue.desc[d1].next = d2;

    // Descriptor 2: status byte (device writes)
    req_queue.desc[d2].addr = @intFromPtr(&req_status);
    req_queue.desc[d2].len = 1;
    req_queue.desc[d2].flags = VRING_DESC_F_WRITE;
    req_queue.desc[d2].next = 0;

    // Add to available ring
    const avail_idx = req_queue.avail.idx;
    req_queue.avail_ring[avail_idx % req_queue.size] = d0;
    req_queue.avail.idx = avail_idx +% 1;

    // Notify device
    writeReg16(VIRTIO_REG_QUEUE_NOTIFY, REQ_QUEUE);

    // Wait for completion
    var timeout: u32 = 0;
    while (timeout < 2000000) : (timeout += 1) {
        if (req_queue.used.idx != req_queue.last_used_idx) {
            req_queue.last_used_idx = req_queue.used.idx;
            _ = readReg8(VIRTIO_REG_ISR_STATUS); // Clear ISR

            // Reclaim descriptors
            req_queue.desc[d2].next = req_queue.free_head;
            req_queue.desc[d1].next = d2;
            req_queue.desc[d0].next = d1;
            req_queue.free_head = d0;
            req_queue.num_free += 3;

            if (req_status == VIRTIO_BLK_S_OK) {
                return true;
            }
            errors += 1;
            return false;
        }
        asm volatile ("pause");
    }

    // Timeout — try to reclaim anyway
    req_queue.desc[d2].next = req_queue.free_head;
    req_queue.desc[d1].next = d2;
    req_queue.desc[d0].next = d1;
    req_queue.free_head = d0;
    req_queue.num_free += 3;
    errors += 1;
    return false;
}

pub fn readSectors(lba: u64, count: u16, buf: [*]u8) bool {
    if (count == 0) return false;
    if (lba + count > capacity) return false;

    const result = doBlockOp(VIRTIO_BLK_T_IN, lba, count, buf);
    if (result) read_ops += 1;
    return result;
}

pub fn writeSectors(lba: u64, count: u16, data: [*]u8) bool {
    if (!ready or is_readonly) return false;
    if (count == 0) return false;
    if (lba + count > capacity) return false;

    const result = doBlockOp(VIRTIO_BLK_T_OUT, lba, count, data);
    if (result) write_ops += 1;
    return result;
}

pub fn flush() bool {
    if (!ready or !has_flush) return false;

    // Flush uses a request with no data
    if (req_queue.num_free < 2) return false;

    req_hdr = .{
        .req_type = VIRTIO_BLK_T_FLUSH,
        .reserved = 0,
        .sector = 0,
    };
    req_status = 0xFF;

    const d0 = req_queue.free_head;
    const d1 = req_queue.desc[d0].next;
    req_queue.free_head = req_queue.desc[d1].next;
    req_queue.num_free -= 2;

    // Header
    req_queue.desc[d0].addr = @intFromPtr(&req_hdr);
    req_queue.desc[d0].len = @sizeOf(VirtioBlkReqHdr);
    req_queue.desc[d0].flags = VRING_DESC_F_NEXT;
    req_queue.desc[d0].next = d1;

    // Status
    req_queue.desc[d1].addr = @intFromPtr(&req_status);
    req_queue.desc[d1].len = 1;
    req_queue.desc[d1].flags = VRING_DESC_F_WRITE;
    req_queue.desc[d1].next = 0;

    const avail_idx = req_queue.avail.idx;
    req_queue.avail_ring[avail_idx % req_queue.size] = d0;
    req_queue.avail.idx = avail_idx +% 1;

    writeReg16(VIRTIO_REG_QUEUE_NOTIFY, REQ_QUEUE);

    var timeout: u32 = 0;
    while (timeout < 2000000) : (timeout += 1) {
        if (req_queue.used.idx != req_queue.last_used_idx) {
            req_queue.last_used_idx = req_queue.used.idx;
            _ = readReg8(VIRTIO_REG_ISR_STATUS);
            req_queue.desc[d1].next = req_queue.free_head;
            req_queue.desc[d0].next = d1;
            req_queue.free_head = d0;
            req_queue.num_free += 2;
            return req_status == VIRTIO_BLK_S_OK;
        }
        asm volatile ("pause");
    }

    req_queue.desc[d1].next = req_queue.free_head;
    req_queue.desc[d0].next = d1;
    req_queue.free_head = d0;
    req_queue.num_free += 2;
    return false;
}

// ---- Query ----

pub fn getCapacity() u64 {
    return capacity;
}

pub fn getBlockSize() u32 {
    return blk_size;
}

pub fn isInitialized() bool {
    return ready;
}

pub fn isReadOnly() bool {
    return is_readonly;
}

// ---- Display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("VirtIO Block Device:\n");
    vga.setColor(.light_grey, .black);

    if (!ready) {
        vga.write("  Not initialized\n");
        return;
    }

    vga.write("  PCI: 00:");
    printHex8(pci_slot);
    vga.putChar('.');
    vga.putChar('0' + pci_func);
    vga.write("  I/O: 0x");
    printHex16(io_base);
    vga.putChar('\n');

    // Capacity
    const mb = capacity / 2048;
    vga.write("  Capacity: ");
    printDec64(mb);
    vga.write(" MB (");
    printDec64(capacity);
    vga.write(" sectors)\n");

    vga.write("  Block Size: ");
    printDec32(blk_size);
    vga.write(" bytes\n");

    vga.write("  Read-Only: ");
    if (is_readonly) vga.write("Yes") else vga.write("No");
    vga.write("  Flush: ");
    if (has_flush) vga.write("Yes") else vga.write("No");
    vga.putChar('\n');

    vga.write("  Features: 0x");
    printHex32(negotiated_features);
    vga.write("  Status: 0x");
    printHex8(readReg8(VIRTIO_REG_DEVICE_STATUS));
    vga.putChar('\n');

    vga.write("  Queue: size=");
    printDec32(req_queue.size);
    vga.write(" free=");
    printDec32(req_queue.num_free);
    vga.putChar('\n');

    vga.write("  Reads: ");
    printDec32(read_ops);
    vga.write("  Writes: ");
    printDec32(write_ops);
    vga.write("  Errors: ");
    printDec32(errors);
    vga.putChar('\n');
}

// ---- Helpers ----

fn serialHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[@as(u4, @truncate(val >> 12))]);
    serial.putChar(hex[@as(u4, @truncate(val >> 8))]);
    serial.putChar(hex[@as(u4, @truncate(val >> 4))]);
    serial.putChar(hex[@as(u4, @truncate(val))]);
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

fn printHex32(val: u32) void {
    printHex16(@truncate(val >> 16));
    printHex16(@truncate(val));
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
