// VirtIO ネットワークデバイスドライバ — Legacy I/O ポートインターフェース
//
// PCI device 0x1AF4:0x1000. VirtIO legacy (transitional) I/O ポートベース.
// デバイスステータスネゴシエーション: ACKNOWLEDGE, DRIVER, FEATURES_OK, DRIVER_OK.
// Feature ネゴシエーション: MAC, STATUS, GUEST_CSUM.
// Virtqueue セットアップ (Rx=0, Tx=1).
// VirtIO net header (12 bytes) をパケットに付加.

const pci = @import("pci.zig");
const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");

// ---- PCI identification ----

const VIRTIO_VENDOR: u16 = 0x1AF4;
const VIRTIO_NET_DEV: u16 = 0x1000; // Transitional network device

// ---- VirtIO Legacy PCI register offsets (I/O space) ----

const VIRTIO_REG_DEVICE_FEATURES: u16 = 0x00; // 32-bit, read
const VIRTIO_REG_GUEST_FEATURES: u16 = 0x04; // 32-bit, write
const VIRTIO_REG_QUEUE_ADDR: u16 = 0x08; // 32-bit, write (PFN)
const VIRTIO_REG_QUEUE_SIZE: u16 = 0x0C; // 16-bit, read
const VIRTIO_REG_QUEUE_SELECT: u16 = 0x0E; // 16-bit, write
const VIRTIO_REG_QUEUE_NOTIFY: u16 = 0x10; // 16-bit, write
const VIRTIO_REG_DEVICE_STATUS: u16 = 0x12; // 8-bit, read/write
const VIRTIO_REG_ISR_STATUS: u16 = 0x13; // 8-bit, read (clears)

// Device-specific configuration starts at offset 0x14 (legacy)
const VIRTIO_NET_CFG_MAC: u16 = 0x14; // 6 bytes: MAC address
const VIRTIO_NET_CFG_STATUS: u16 = 0x1A; // 16-bit: link status

// ---- Device Status bits ----

const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_DEVICE_NEEDS_RESET: u8 = 64;
const STATUS_FAILED: u8 = 128;

// ---- VirtIO Net Feature bits ----

const VIRTIO_NET_F_CSUM: u32 = 1 << 0; // Host handles checksums
const VIRTIO_NET_F_GUEST_CSUM: u32 = 1 << 1; // Guest handles checksums
const VIRTIO_NET_F_MAC: u32 = 1 << 5; // Device has given MAC address
const VIRTIO_NET_F_GSO: u32 = 1 << 6; // Guest can handle GSO
const VIRTIO_NET_F_GUEST_TSO4: u32 = 1 << 7;
const VIRTIO_NET_F_GUEST_TSO6: u32 = 1 << 8;
const VIRTIO_NET_F_GUEST_ECN: u32 = 1 << 9;
const VIRTIO_NET_F_GUEST_UFO: u32 = 1 << 10;
const VIRTIO_NET_F_HOST_TSO4: u32 = 1 << 11;
const VIRTIO_NET_F_HOST_TSO6: u32 = 1 << 12;
const VIRTIO_NET_F_HOST_ECN: u32 = 1 << 13;
const VIRTIO_NET_F_HOST_UFO: u32 = 1 << 14;
const VIRTIO_NET_F_MRG_RXBUF: u32 = 1 << 15;
const VIRTIO_NET_F_STATUS: u32 = 1 << 16; // Device has link status
const VIRTIO_NET_F_CTRL_VQ: u32 = 1 << 17;
const VIRTIO_NET_F_CTRL_RX: u32 = 1 << 18;
const VIRTIO_NET_F_CTRL_VLAN: u32 = 1 << 19;
const VIRTIO_NET_F_CTRL_RX_EXTRA: u32 = 1 << 20;
const VIRTIO_NET_F_GUEST_ANNOUNCE: u32 = 1 << 21;

// ---- VirtIO Net Header (12 bytes, legacy) ----

const VirtioNetHdr = packed struct {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
    // Legacy: no num_buffers field (that's in modern)
    // Pad to 12 bytes for legacy without MRG_RXBUF
    pad: u16,
};

const NET_HDR_SIZE: usize = @sizeOf(VirtioNetHdr);

// ---- VirtQueue descriptor (spec 2.4) ----

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
    // ring[] follows (variable length)
};

const VirtqUsedElem = packed struct {
    id: u32,
    len: u32,
};

const VirtqUsed = packed struct {
    flags: u16,
    idx: u16,
    // ring[] follows (variable length)
};

// ---- Queue constants ----

const RX_QUEUE: u16 = 0;
const TX_QUEUE: u16 = 1;
const QUEUE_SIZE: u16 = 128; // We'll use at most 128 entries
const PAGE_SIZE: u32 = 4096;

const MAX_PKT_SIZE: usize = 1514 + NET_HDR_SIZE; // Ethernet MTU + net header

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
    base_page: u32, // physical page of allocation
};

// ---- State ----

var io_base: u16 = 0;
var mac: [6]u8 = undefined;
var ready: bool = false;
var pci_bus: u8 = 0;
var pci_slot: u8 = 0;
var pci_func: u8 = 0;
var device_features: u32 = 0;
var negotiated_features: u32 = 0;
var has_link_status: bool = false;

var rx_queue: QueueState = undefined;
var tx_queue: QueueState = undefined;

// Buffers for Rx/Tx
var rx_bufs: [QUEUE_SIZE][MAX_PKT_SIZE]u8 align(16) = @splat(@splat(0));
var tx_buf: [MAX_PKT_SIZE]u8 align(16) = @splat(0);

// Statistics
var rx_packets: u32 = 0;
var tx_packets: u32 = 0;

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
    // PCI デバイス検出
    const dev = pci.findDevice(VIRTIO_VENDOR, VIRTIO_NET_DEV) orelse {
        serial.write("[VIRTIO-NET] Device not found\n");
        return false;
    };

    pci_bus = dev.bus;
    pci_slot = dev.slot;
    pci_func = dev.func;

    // BAR0 から I/O ベースアドレス取得
    const bar0 = dev.bar0;
    if (bar0 & 0x01 == 0) {
        serial.write("[VIRTIO-NET] BAR0 is not I/O space\n");
        return false;
    }
    io_base = @truncate(bar0 & 0xFFFC);
    if (io_base == 0) return false;

    // PCI バスマスタリング有効化
    pci.enableBusMastering(pci_bus, pci_slot, pci_func);

    // ---- Device status negotiation ----

    // 1. Reset device
    writeReg8(VIRTIO_REG_DEVICE_STATUS, 0);

    // 2. Acknowledge
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);

    // 3. Driver
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // 4. Read device features
    device_features = readReg32(VIRTIO_REG_DEVICE_FEATURES);

    // 5. Negotiate features
    negotiated_features = 0;
    if (device_features & VIRTIO_NET_F_MAC != 0) {
        negotiated_features |= VIRTIO_NET_F_MAC;
    }
    if (device_features & VIRTIO_NET_F_STATUS != 0) {
        negotiated_features |= VIRTIO_NET_F_STATUS;
        has_link_status = true;
    }
    if (device_features & VIRTIO_NET_F_GUEST_CSUM != 0) {
        negotiated_features |= VIRTIO_NET_F_GUEST_CSUM;
    }

    // Write accepted features
    writeReg32(VIRTIO_REG_GUEST_FEATURES, negotiated_features);

    // 6. Features OK
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

    // Verify features OK
    const status = readReg8(VIRTIO_REG_DEVICE_STATUS);
    if (status & STATUS_FEATURES_OK == 0) {
        serial.write("[VIRTIO-NET] Features not accepted\n");
        writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // 7. Setup Rx queue (queue 0)
    if (!setupQueue(RX_QUEUE, &rx_queue)) {
        serial.write("[VIRTIO-NET] Rx queue setup failed\n");
        writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // 8. Setup Tx queue (queue 1)
    if (!setupQueue(TX_QUEUE, &tx_queue)) {
        serial.write("[VIRTIO-NET] Tx queue setup failed\n");
        writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // 9. Populate Rx queue with buffers
    populateRxQueue();

    // 10. Read MAC address
    if (negotiated_features & VIRTIO_NET_F_MAC != 0) {
        mac[0] = readReg8(VIRTIO_NET_CFG_MAC + 0);
        mac[1] = readReg8(VIRTIO_NET_CFG_MAC + 1);
        mac[2] = readReg8(VIRTIO_NET_CFG_MAC + 2);
        mac[3] = readReg8(VIRTIO_NET_CFG_MAC + 3);
        mac[4] = readReg8(VIRTIO_NET_CFG_MAC + 4);
        mac[5] = readReg8(VIRTIO_NET_CFG_MAC + 5);
    } else {
        // Generate a random-ish MAC
        mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    }

    // 11. Driver OK
    writeReg8(VIRTIO_REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    ready = true;

    serial.write("[VIRTIO-NET] MAC=");
    printMacSerial();
    serial.write(" IO=0x");
    serialHex16(io_base);
    serial.write(" features=0x");
    serial.writeHex(negotiated_features);
    serial.write("\n");

    return true;
}

fn setupQueue(queue_idx: u16, qs: *QueueState) bool {
    // Select queue
    writeReg16(VIRTIO_REG_QUEUE_SELECT, queue_idx);

    // Read queue size
    const size = readReg16(VIRTIO_REG_QUEUE_SIZE);
    if (size == 0) return false;

    // Use smaller of device size and our max
    const actual_size: u16 = if (size > QUEUE_SIZE) QUEUE_SIZE else size;
    qs.size = actual_size;

    // Calculate queue memory layout (legacy virtio)
    // Descriptor table: 16 * size bytes, aligned to 16
    // Available ring: 6 + 2*size bytes, after descriptors
    // Used ring: 6 + 8*size bytes, page-aligned after available
    const desc_size = @as(u32, actual_size) * @sizeOf(VirtqDesc);
    const avail_size = 6 + @as(u32, actual_size) * 2;
    const used_offset_unaligned = desc_size + avail_size;
    const used_offset = (used_offset_unaligned + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    const used_size = 6 + @as(u32, actual_size) * 8;
    const total_size = used_offset + used_size;

    // Allocate pages
    const num_pages = (total_size + PAGE_SIZE - 1) / PAGE_SIZE;
    var base_addr: u32 = 0;

    // Allocate contiguous pages from PMM
    if (pmm.alloc()) |page| {
        base_addr = page;
    } else {
        return false;
    }

    // Allocate additional pages if needed
    var p: u32 = 1;
    while (p < num_pages) : (p += 1) {
        _ = pmm.alloc();
    }

    // Zero the memory
    const base_bytes: [*]volatile u8 = @ptrFromInt(base_addr);
    for (0..total_size) |i| {
        base_bytes[i] = 0;
    }

    // Set up pointers
    qs.desc = @ptrFromInt(base_addr);
    qs.avail = @ptrFromInt(base_addr + desc_size);
    qs.avail_ring = @ptrFromInt(base_addr + desc_size + 4); // Skip flags + idx
    qs.used = @ptrFromInt(base_addr + used_offset);
    qs.used_ring = @ptrFromInt(base_addr + used_offset + 4); // Skip flags + idx
    qs.base_page = base_addr;
    qs.free_head = 0;
    qs.last_used_idx = 0;
    qs.num_free = actual_size;

    // Chain free descriptors
    var i: u16 = 0;
    while (i < actual_size) : (i += 1) {
        qs.desc[i].next = i + 1;
        qs.desc[i].flags = 0;
    }

    // Initialize avail ring
    qs.avail.flags = 0;
    qs.avail.idx = 0;

    // Tell device the queue address (in pages)
    writeReg32(VIRTIO_REG_QUEUE_ADDR, base_addr / PAGE_SIZE);

    return true;
}

fn populateRxQueue() void {
    // Add buffers to Rx queue for receiving packets
    var i: u16 = 0;
    const max_bufs: u16 = if (rx_queue.size > QUEUE_SIZE) QUEUE_SIZE else rx_queue.size;
    while (i < max_bufs and rx_queue.num_free > 0) : (i += 1) {
        const desc_idx = rx_queue.free_head;
        rx_queue.free_head = rx_queue.desc[desc_idx].next;
        rx_queue.num_free -= 1;

        rx_queue.desc[desc_idx].addr = @intFromPtr(&rx_bufs[i]);
        rx_queue.desc[desc_idx].len = MAX_PKT_SIZE;
        rx_queue.desc[desc_idx].flags = VRING_DESC_F_WRITE; // Device writes to this buffer
        rx_queue.desc[desc_idx].next = 0;

        // Add to available ring
        const avail_idx = rx_queue.avail.idx;
        rx_queue.avail_ring[avail_idx % rx_queue.size] = desc_idx;
        rx_queue.avail.idx = avail_idx +% 1;
    }

    // Notify device
    writeReg16(VIRTIO_REG_QUEUE_NOTIFY, RX_QUEUE);
}

// ---- Send ----

pub fn send(data: []const u8) void {
    if (!ready) return;
    if (data.len == 0 or data.len + NET_HDR_SIZE > MAX_PKT_SIZE) return;
    if (tx_queue.num_free == 0) return;

    // Build packet with net header
    const net_hdr: *VirtioNetHdr = @alignCast(@ptrCast(&tx_buf));
    net_hdr.flags = 0;
    net_hdr.gso_type = 0; // VIRTIO_NET_HDR_GSO_NONE
    net_hdr.hdr_len = 0;
    net_hdr.gso_size = 0;
    net_hdr.csum_start = 0;
    net_hdr.csum_offset = 0;
    net_hdr.pad = 0;

    // Copy data after header
    @memcpy(tx_buf[NET_HDR_SIZE..][0..data.len], data);

    const total_len = NET_HDR_SIZE + data.len;

    // Get a free descriptor
    const desc_idx = tx_queue.free_head;
    tx_queue.free_head = tx_queue.desc[desc_idx].next;
    tx_queue.num_free -= 1;

    // Set up descriptor
    tx_queue.desc[desc_idx].addr = @intFromPtr(&tx_buf);
    tx_queue.desc[desc_idx].len = @truncate(total_len);
    tx_queue.desc[desc_idx].flags = 0; // Device reads from this buffer
    tx_queue.desc[desc_idx].next = 0;

    // Add to available ring
    const avail_idx = tx_queue.avail.idx;
    tx_queue.avail_ring[avail_idx % tx_queue.size] = desc_idx;
    tx_queue.avail.idx = avail_idx +% 1;

    // Notify device
    writeReg16(VIRTIO_REG_QUEUE_NOTIFY, TX_QUEUE);

    // Wait for completion
    var timeout: u32 = 0;
    while (timeout < 500000) : (timeout += 1) {
        if (tx_queue.used.idx != tx_queue.last_used_idx) {
            // Reclaim descriptor
            tx_queue.last_used_idx = tx_queue.used.idx;
            tx_queue.desc[desc_idx].next = tx_queue.free_head;
            tx_queue.free_head = desc_idx;
            tx_queue.num_free += 1;
            tx_packets += 1;
            return;
        }
        asm volatile ("pause");
    }
}

// ---- Receive ----

pub fn receive(buf: []u8) ?u16 {
    if (!ready) return null;

    // Check if device has returned any buffers
    if (rx_queue.used.idx == rx_queue.last_used_idx) return null;

    // Read ISR to clear (legacy)
    _ = readReg8(VIRTIO_REG_ISR_STATUS);

    // Get used element
    const used_elem = rx_queue.used_ring[rx_queue.last_used_idx % rx_queue.size];
    const desc_idx = @as(u16, @truncate(used_elem.id));
    const total_len = used_elem.len;

    rx_queue.last_used_idx +%= 1;

    // Skip net header, copy data
    if (total_len <= NET_HDR_SIZE) {
        // Reclaim and re-add buffer
        reclaimRxDesc(desc_idx);
        return null;
    }

    const data_len = total_len - @as(u32, NET_HDR_SIZE);
    if (data_len > buf.len) {
        reclaimRxDesc(desc_idx);
        return null;
    }

    // Copy data from Rx buffer (after net header)
    const src_addr = rx_queue.desc[desc_idx].addr + NET_HDR_SIZE;
    const src: [*]const u8 = @ptrFromInt(@as(usize, @truncate(src_addr)));
    @memcpy(buf[0..@as(usize, @truncate(data_len))], src[0..@as(usize, @truncate(data_len))]);

    // Reclaim buffer
    reclaimRxDesc(desc_idx);

    rx_packets += 1;
    return @truncate(data_len);
}

fn reclaimRxDesc(desc_idx: u16) void {
    // Re-add descriptor to available ring
    rx_queue.desc[desc_idx].flags = VRING_DESC_F_WRITE;
    rx_queue.desc[desc_idx].len = MAX_PKT_SIZE;

    const avail_idx = rx_queue.avail.idx;
    rx_queue.avail_ring[avail_idx % rx_queue.size] = desc_idx;
    rx_queue.avail.idx = avail_idx +% 1;

    // Notify device
    writeReg16(VIRTIO_REG_QUEUE_NOTIFY, RX_QUEUE);
}

// ---- Query ----

pub fn getMac() [6]u8 {
    return mac;
}

pub fn isInitialized() bool {
    return ready;
}

pub fn getLinkStatus() bool {
    if (!ready or !has_link_status) return false;
    const status = readReg16(VIRTIO_NET_CFG_STATUS);
    return (status & 1) != 0; // bit 0 = link up
}

// ---- Display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("VirtIO Network Device:\n");
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

    vga.write("  MAC: ");
    for (mac, 0..) |b, idx| {
        if (idx > 0) vga.putChar(':');
        printHex8(b);
    }
    vga.putChar('\n');

    vga.write("  Features: 0x");
    printHex32(negotiated_features);
    vga.write(" (device: 0x");
    printHex32(device_features);
    vga.write(")\n");

    vga.write("  Status: 0x");
    printHex8(readReg8(VIRTIO_REG_DEVICE_STATUS));

    if (has_link_status) {
        vga.write("  Link: ");
        if (getLinkStatus()) {
            vga.setColor(.light_green, .black);
            vga.write("UP");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("DOWN");
        }
        vga.setColor(.light_grey, .black);
    }
    vga.putChar('\n');

    vga.write("  Rx Queue: size=");
    printDec(rx_queue.size);
    vga.write(" free=");
    printDec(rx_queue.num_free);
    vga.putChar('\n');

    vga.write("  Tx Queue: size=");
    printDec(tx_queue.size);
    vga.write(" free=");
    printDec(tx_queue.num_free);
    vga.putChar('\n');

    vga.write("  Rx: ");
    printDec(rx_packets);
    vga.write(" pkts  Tx: ");
    printDec(tx_packets);
    vga.write(" pkts\n");
}

// ---- Helpers ----

fn printMacSerial() void {
    const hex = "0123456789ABCDEF";
    for (mac, 0..) |b, i| {
        if (i > 0) serial.putChar(':');
        serial.putChar(hex[b >> 4]);
        serial.putChar(hex[b & 0xF]);
    }
}

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

fn printDec(n: anytype) void {
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
