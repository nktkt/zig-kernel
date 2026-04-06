// NE2000/RTL8029 NIC ドライバ — DP8390 ベース Ethernet コントローラ
//
// PCI vendor 0x10EC, device 0x8029. DP8390 レジスタ互換.
// 3 ページのレジスタ空間 (0x00-0x0F). リモート DMA でバッファアクセス.
// リングバッファ方式の Rx 受信.

const pci = @import("pci.zig");
const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- PCI identification ----

const VENDOR_REALTEK: u16 = 0x10EC;
const DEVICE_RTL8029: u16 = 0x8029;

// Also support classic NE2000 clone IDs
const VENDOR_NE2000_CLONE: u16 = 0x1050; // Winbond
const DEVICE_NE2000_CLONE: u16 = 0x0940;

// ---- DP8390 register offsets (Page 0, read) ----

const REG_CR: u16 = 0x00; // Command Register
const REG_CLDA0: u16 = 0x01; // Current Local DMA Address 0
const REG_CLDA1: u16 = 0x02; // Current Local DMA Address 1
const REG_BNRY: u16 = 0x03; // Boundary Pointer
const REG_TSR: u16 = 0x04; // Transmit Status Register
const REG_NCR: u16 = 0x05; // Number of Collisions Register
const REG_FIFO: u16 = 0x06; // FIFO register
const REG_ISR: u16 = 0x07; // Interrupt Status Register
const REG_CRDA0: u16 = 0x08; // Current Remote DMA Address 0
const REG_CRDA1: u16 = 0x09; // Current Remote DMA Address 1
const REG_RSR: u16 = 0x0C; // Receive Status Register
const REG_CNTR0: u16 = 0x0D; // Tally Counter 0 (frame alignment errors)
const REG_CNTR1: u16 = 0x0E; // Tally Counter 1 (CRC errors)
const REG_CNTR2: u16 = 0x0F; // Tally Counter 2 (missed packets)

// ---- DP8390 register offsets (Page 0, write) ----

const REG_PSTART: u16 = 0x01; // Page Start Register
const REG_PSTOP: u16 = 0x02; // Page Stop Register
// BNRY = 0x03 (read/write)
const REG_TPSR: u16 = 0x04; // Transmit Page Start Register
const REG_TBCR0: u16 = 0x05; // Transmit Byte Count Register 0
const REG_TBCR1: u16 = 0x06; // Transmit Byte Count Register 1
// ISR = 0x07 (read/write)
const REG_RSAR0: u16 = 0x08; // Remote Start Address Register 0
const REG_RSAR1: u16 = 0x09; // Remote Start Address Register 1
const REG_RBCR0: u16 = 0x0A; // Remote Byte Count Register 0
const REG_RBCR1: u16 = 0x0B; // Remote Byte Count Register 1
const REG_RCR: u16 = 0x0C; // Receive Configuration Register
const REG_TCR: u16 = 0x0D; // Transmit Configuration Register
const REG_DCR: u16 = 0x0E; // Data Configuration Register
const REG_IMR: u16 = 0x0F; // Interrupt Mask Register

// ---- Page 1 registers (read/write) ----

const REG_PAR0: u16 = 0x01; // Physical Address Register 0-5
const REG_CURR: u16 = 0x07; // Current Page Register
const REG_MAR0: u16 = 0x08; // Multicast Address Register 0-7

// ---- Command Register bits ----

const CR_STOP: u8 = 0x01; // Stop controller
const CR_START: u8 = 0x02; // Start controller
const CR_TXP: u8 = 0x04; // Transmit Packet
const CR_DMA_READ: u8 = 0x08; // Remote DMA Read
const CR_DMA_WRITE: u8 = 0x10; // Remote DMA Write
const CR_DMA_SEND: u8 = 0x18; // Send Packet (remote DMA)
const CR_DMA_ABORT: u8 = 0x20; // Abort/Complete Remote DMA
const CR_PAGE0: u8 = 0x00; // Select register page 0
const CR_PAGE1: u8 = 0x40; // Select register page 1
const CR_PAGE2: u8 = 0x80; // Select register page 2

// ---- ISR bits ----

const ISR_PRX: u8 = 0x01; // Packet Received
const ISR_PTX: u8 = 0x02; // Packet Transmitted
const ISR_RXE: u8 = 0x04; // Receive Error
const ISR_TXE: u8 = 0x08; // Transmit Error
const ISR_OVW: u8 = 0x10; // Overwrite Warning (ring buffer overflow)
const ISR_CNT: u8 = 0x20; // Counter Overflow
const ISR_RDC: u8 = 0x40; // Remote DMA Complete
const ISR_RST: u8 = 0x80; // Reset Status

// ---- DCR bits ----

const DCR_WTS: u8 = 0x01; // Word Transfer Select (1 = word, 0 = byte)
const DCR_BOS: u8 = 0x02; // Byte Order Select
const DCR_LAS: u8 = 0x04; // Long Address Select
const DCR_LS: u8 = 0x08; // Loopback Select (0 = normal)
const DCR_AR: u8 = 0x10; // Auto-Initialize Remote
const DCR_FT1: u8 = 0x40; // FIFO Threshold Select

// ---- RCR bits ----

const RCR_SEP: u8 = 0x01; // Save Errored Packets
const RCR_AR: u8 = 0x02; // Accept Runt Packets
const RCR_AB: u8 = 0x04; // Accept Broadcast
const RCR_AM: u8 = 0x08; // Accept Multicast
const RCR_PRO: u8 = 0x10; // Promiscuous mode
const RCR_MON: u8 = 0x20; // Monitor mode

// ---- TCR bits ----

const TCR_LB0: u8 = 0x02; // Loopback mode
const TCR_NORMAL: u8 = 0x00; // Normal operation

// ---- NE2000 memory layout ----
// NE2000 has 16KB of onboard SRAM (pages 0x40-0x7F for 8-bit, 0x40-0xFF for 16-bit)

const MEM_START: u8 = 0x40; // Start of NIC memory (page)
const MEM_STOP: u8 = 0x80; // End of NIC memory (page), 16KB
const TX_START: u8 = 0x40; // Tx buffer start page
const TX_PAGES: u8 = 6; // 6 pages = 1536 bytes (max Ethernet frame)
const RX_START: u8 = 0x46; // Rx ring buffer start page
const RX_STOP: u8 = 0x80; // Rx ring buffer stop page

const NE_DATA_PORT: u16 = 0x10; // NE2000 data port (offset from base)
const NE_RESET_PORT: u16 = 0x1F; // NE2000 reset port

// ---- State ----

var io_base: u16 = 0;
var mac: [6]u8 = undefined;
var ready: bool = false;
var next_pkt: u8 = RX_START + 1; // Next expected Rx page
var pci_bus: u8 = 0;
var pci_slot: u8 = 0;
var pci_func: u8 = 0;
var is_16bit: bool = true; // NE2000 16-bit mode

// Statistics
var rx_packets: u32 = 0;
var tx_packets: u32 = 0;
var rx_errors: u32 = 0;
var tx_errors: u32 = 0;

// ---- I/O helpers ----

fn readReg(offset: u16) u8 {
    return idt.inb(io_base + offset);
}

fn writeReg(offset: u16, val: u8) void {
    idt.outb(io_base + offset, val);
}

fn readData16() u16 {
    return idt.inw(io_base + NE_DATA_PORT);
}

fn writeData16(val: u16) void {
    idt.outw(io_base + NE_DATA_PORT, val);
}

fn readData8() u8 {
    return idt.inb(io_base + NE_DATA_PORT);
}

fn writeData8(val: u8) void {
    idt.outb(io_base + NE_DATA_PORT, val);
}

fn selectPage(page: u8) void {
    const cr = readReg(REG_CR);
    writeReg(REG_CR, (cr & 0x3F) | page);
}

// ---- Remote DMA operations ----

fn remoteDmaRead(src_addr: u16, length: u16, buf: []u8) void {
    // Complete any pending DMA
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_ABORT | CR_START);

    // Set remote DMA byte count
    writeReg(REG_RBCR0, @truncate(length));
    writeReg(REG_RBCR1, @truncate(length >> 8));

    // Set remote start address
    writeReg(REG_RSAR0, @truncate(src_addr));
    writeReg(REG_RSAR1, @truncate(src_addr >> 8));

    // Start remote DMA read
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_READ | CR_START);

    // Read data
    if (is_16bit) {
        var i: usize = 0;
        const words = (length + 1) / 2;
        while (i < words) : (i += 1) {
            const word = readData16();
            const off = i * 2;
            if (off < buf.len) buf[off] = @truncate(word);
            if (off + 1 < buf.len) buf[off + 1] = @truncate(word >> 8);
        }
    } else {
        for (0..length) |i| {
            if (i < buf.len) buf[i] = readData8();
        }
    }

    // Wait for DMA complete
    var timeout: u32 = 0;
    while (timeout < 50000) : (timeout += 1) {
        if (readReg(REG_ISR) & ISR_RDC != 0) break;
    }
    writeReg(REG_ISR, ISR_RDC); // Clear RDC
}

fn remoteDmaWrite(dst_addr: u16, data: []const u8) void {
    // Complete any pending DMA
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_ABORT | CR_START);

    // ISR RDC クリア
    writeReg(REG_ISR, ISR_RDC);

    const length: u16 = @truncate(data.len);

    // Set byte count
    writeReg(REG_RBCR0, @truncate(length));
    writeReg(REG_RBCR1, @truncate(length >> 8));

    // Set remote start address
    writeReg(REG_RSAR0, @truncate(dst_addr));
    writeReg(REG_RSAR1, @truncate(dst_addr >> 8));

    // Start remote DMA write
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_WRITE | CR_START);

    // Write data
    if (is_16bit) {
        var i: usize = 0;
        while (i < data.len) : (i += 2) {
            const lo: u16 = data[i];
            const hi: u16 = if (i + 1 < data.len) data[i + 1] else 0;
            writeData16(lo | (hi << 8));
        }
    } else {
        for (data) |b| {
            writeData8(b);
        }
    }

    // Wait for DMA complete
    var timeout: u32 = 0;
    while (timeout < 50000) : (timeout += 1) {
        if (readReg(REG_ISR) & ISR_RDC != 0) break;
    }
    writeReg(REG_ISR, ISR_RDC);
}

// ---- Initialization ----

pub fn init() bool {
    // PCI デバイス検出 (RTL8029)
    const dev = pci.findDevice(VENDOR_REALTEK, DEVICE_RTL8029) orelse {
        serial.write("[NE2000] Device not found\n");
        return false;
    };

    pci_bus = dev.bus;
    pci_slot = dev.slot;
    pci_func = dev.func;

    // BAR0 から I/O ベースアドレス取得
    const bar0 = dev.bar0;
    if (bar0 & 0x01 == 0) {
        serial.write("[NE2000] BAR0 is not I/O space\n");
        return false;
    }
    io_base = @truncate(bar0 & 0xFFFC);
    if (io_base == 0) return false;

    // PCI バスマスタリング有効化
    pci.enableBusMastering(pci_bus, pci_slot, pci_func);

    // NIC リセット
    resetChip();

    // Stop モードに設定
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_ABORT | CR_STOP);

    // リセット完了待ち
    var timeout: u32 = 0;
    while (timeout < 50000) : (timeout += 1) {
        if (readReg(REG_ISR) & ISR_RST != 0) break;
    }

    // Data Configuration Register: word transfer, FIFO threshold 8 bytes
    writeReg(REG_DCR, DCR_WTS | DCR_FT1 | DCR_LS);

    // Clear remote byte count
    writeReg(REG_RBCR0, 0);
    writeReg(REG_RBCR1, 0);

    // Receive Configuration: Accept broadcast + multicast
    writeReg(REG_RCR, RCR_AB | RCR_AM);

    // Transmit Configuration: Internal loopback (for init)
    writeReg(REG_TCR, TCR_LB0);

    // Set Rx ring buffer boundaries
    writeReg(REG_PSTART, RX_START);
    writeReg(REG_BNRY, RX_START);
    writeReg(REG_PSTOP, RX_STOP);

    // Clear all ISR flags
    writeReg(REG_ISR, 0xFF);

    // Set Interrupt Mask
    writeReg(REG_IMR, ISR_PRX | ISR_PTX | ISR_RXE | ISR_TXE | ISR_OVW);

    // Read MAC address from NIC PROM (at address 0x0000 in NIC memory)
    var prom_buf: [32]u8 = undefined;
    remoteDmaRead(0x0000, 32, &prom_buf);

    // NE2000 stores MAC doubled for 16-bit mode: AA AA BB BB CC CC ...
    mac[0] = prom_buf[0];
    mac[1] = prom_buf[2];
    mac[2] = prom_buf[4];
    mac[3] = prom_buf[6];
    mac[4] = prom_buf[8];
    mac[5] = prom_buf[10];

    // Switch to Page 1 to set physical address
    selectPage(CR_PAGE1);
    writeReg(REG_PAR0 + 0, mac[0]);
    writeReg(REG_PAR0 + 1, mac[1]);
    writeReg(REG_PAR0 + 2, mac[2]);
    writeReg(REG_PAR0 + 3, mac[3]);
    writeReg(REG_PAR0 + 4, mac[4]);
    writeReg(REG_PAR0 + 5, mac[5]);

    // Set multicast filter to accept all
    var m: u16 = 0;
    while (m < 8) : (m += 1) {
        writeReg(REG_MAR0 + m, 0xFF);
    }

    // Set current page pointer (CURR points to next free Rx page)
    writeReg(REG_CURR, RX_START + 1);
    next_pkt = RX_START + 1;

    // Switch back to Page 0
    selectPage(CR_PAGE0);

    // Set Tx configuration: normal mode
    writeReg(REG_TCR, TCR_NORMAL);

    // Start the NIC
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_ABORT | CR_START);

    ready = true;

    serial.write("[NE2000] MAC=");
    printMacSerial();
    serial.write(" IO=0x");
    serialHex16(io_base);
    serial.write("\n");

    return true;
}

fn resetChip() void {
    // Read then write the reset port
    const reset_val = idt.inb(io_base + NE_RESET_PORT);
    idt.outb(io_base + NE_RESET_PORT, reset_val);

    // Wait for reset to complete (~10ms)
    var i: u32 = 0;
    while (i < 50000) : (i += 1) {
        asm volatile ("pause");
    }
}

// ---- Send ----

pub fn send(data: []const u8) void {
    if (!ready) return;
    if (data.len == 0 or data.len > 1500) return;

    var send_len = data.len;
    if (send_len < 60) send_len = 60; // Minimum Ethernet frame

    // Wait for previous Tx to complete
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        const cr = readReg(REG_CR);
        if (cr & CR_TXP == 0) break;
    }

    // Write packet to NIC memory via Remote DMA
    const tx_addr: u16 = @as(u16, TX_START) << 8;

    // If packet is less than 60 bytes, we need to pad it
    if (data.len < 60) {
        var padded: [60]u8 = @splat(0);
        @memcpy(padded[0..data.len], data);
        remoteDmaWrite(tx_addr, &padded);
    } else {
        remoteDmaWrite(tx_addr, data);
    }

    // Set Tx page start
    writeReg(REG_TPSR, TX_START);

    // Set Tx byte count
    writeReg(REG_TBCR0, @truncate(send_len));
    writeReg(REG_TBCR1, @truncate(send_len >> 8));

    // Issue transmit command
    writeReg(REG_CR, CR_PAGE0 | CR_DMA_ABORT | CR_TXP | CR_START);

    // Wait for Tx complete
    timeout = 0;
    while (timeout < 200000) : (timeout += 1) {
        const isr = readReg(REG_ISR);
        if (isr & ISR_PTX != 0) {
            writeReg(REG_ISR, ISR_PTX);
            tx_packets += 1;
            return;
        }
        if (isr & ISR_TXE != 0) {
            writeReg(REG_ISR, ISR_TXE);
            tx_errors += 1;
            return;
        }
        asm volatile ("pause");
    }
    tx_errors += 1;
}

// ---- Receive ----

pub fn receive(buf: []u8) ?u16 {
    if (!ready) return null;

    // Check ISR for received packet
    const isr = readReg(REG_ISR);
    if (isr & ISR_RXE != 0) {
        writeReg(REG_ISR, ISR_RXE);
        rx_errors += 1;
    }

    // Read CURR from page 1
    selectPage(CR_PAGE1);
    const curr = readReg(REG_CURR);
    selectPage(CR_PAGE0);

    // If boundary == current - 1, no packets
    const bnry = readReg(REG_BNRY);
    var next = bnry + 1;
    if (next >= RX_STOP) next = RX_START;

    if (next == curr) return null;

    // Read packet header (4 bytes): status, next_page, length_lo, length_hi
    var hdr: [4]u8 = undefined;
    const hdr_addr: u16 = @as(u16, next) << 8;
    remoteDmaRead(hdr_addr, 4, &hdr);

    const rx_status = hdr[0];
    const next_page = hdr[1];
    const pkt_len: u16 = @as(u16, hdr[2]) | (@as(u16, hdr[3]) << 8);

    // Validate
    if (rx_status & 0x01 == 0) {
        // Error in received packet
        rx_errors += 1;
        writeReg(REG_BNRY, if (next_page > RX_START) next_page - 1 else RX_STOP - 1);
        next_pkt = next_page;
        return null;
    }

    // Length includes the 4-byte header
    if (pkt_len < 8 or pkt_len > 1522) {
        writeReg(REG_BNRY, if (next_page > RX_START) next_page - 1 else RX_STOP - 1);
        next_pkt = next_page;
        rx_errors += 1;
        return null;
    }

    const data_len = pkt_len - 4; // Subtract header
    if (data_len > buf.len) {
        writeReg(REG_BNRY, if (next_page > RX_START) next_page - 1 else RX_STOP - 1);
        next_pkt = next_page;
        return null;
    }

    // Read packet data (starting after 4-byte header)
    const data_addr = hdr_addr + 4;
    remoteDmaRead(data_addr, @truncate(data_len), buf[0..data_len]);

    // Update boundary register
    next_pkt = next_page;
    writeReg(REG_BNRY, if (next_pkt > RX_START) next_pkt - 1 else RX_STOP - 1);

    // Clear Rx ISR
    writeReg(REG_ISR, ISR_PRX);

    rx_packets += 1;
    return @truncate(data_len);
}

// ---- Query ----

pub fn getMac() [6]u8 {
    return mac;
}

pub fn isInitialized() bool {
    return ready;
}

// ---- Display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("NE2000/RTL8029 Network Controller:\n");
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

    vga.write("  Mode: ");
    if (is_16bit) vga.write("16-bit") else vga.write("8-bit");
    vga.putChar('\n');

    // Ring buffer status
    selectPage(CR_PAGE1);
    const curr = readReg(REG_CURR);
    selectPage(CR_PAGE0);
    const bnry = readReg(REG_BNRY);

    vga.write("  Rx Ring: BNRY=0x");
    printHex8(bnry);
    vga.write(" CURR=0x");
    printHex8(curr);
    vga.write(" [");
    printHex8(RX_START);
    vga.putChar('-');
    printHex8(RX_STOP);
    vga.write("]\n");

    vga.write("  Rx: ");
    printDec(rx_packets);
    vga.write(" pkts, ");
    printDec(rx_errors);
    vga.write(" errors\n");

    vga.write("  Tx: ");
    printDec(tx_packets);
    vga.write(" pkts, ");
    printDec(tx_errors);
    vga.write(" errors\n");

    // Tally counters
    const fae = readReg(REG_CNTR0);
    const crc = readReg(REG_CNTR1);
    const missed = readReg(REG_CNTR2);
    vga.write("  Tally: FAE=");
    printDec(fae);
    vga.write(" CRC=");
    printDec(crc);
    vga.write(" Missed=");
    printDec(missed);
    vga.putChar('\n');
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
