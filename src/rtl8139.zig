// RTL8139 NIC ドライバ — Realtek Fast Ethernet コントローラ
//
// PCI vendor 0x10EC, device 0x8139. I/O port ベース.
// レジスタ: MAC0-5, TxStatus0-3, TxAddr0-3, RxBuf, Command, IMR, ISR.
// Rx バッファは 8K+16+1500 のリングバッファ方式.

const pci = @import("pci.zig");
const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- PCI identification ----

const VENDOR_REALTEK: u16 = 0x10EC;
const DEVICE_RTL8139: u16 = 0x8139;

// ---- I/O register offsets ----

const REG_MAC0: u16 = 0x00; // MAC address bytes 0-3
const REG_MAC4: u16 = 0x04; // MAC address bytes 4-5
const REG_MAR0: u16 = 0x08; // Multicast filter 0-3
const REG_MAR4: u16 = 0x0C; // Multicast filter 4-7

const REG_TX_STATUS0: u16 = 0x10; // Tx status descriptor 0
const REG_TX_STATUS1: u16 = 0x14;
const REG_TX_STATUS2: u16 = 0x18;
const REG_TX_STATUS3: u16 = 0x1C;

const REG_TX_ADDR0: u16 = 0x20; // Tx buffer address 0
const REG_TX_ADDR1: u16 = 0x24;
const REG_TX_ADDR2: u16 = 0x28;
const REG_TX_ADDR3: u16 = 0x2C;

const REG_RX_BUF: u16 = 0x30; // Rx buffer start address
const REG_RX_EARLY_CNT: u16 = 0x34;
const REG_RX_EARLY_STATUS: u16 = 0x36;

const REG_COMMAND: u16 = 0x37; // Command register
const REG_CAPR: u16 = 0x38; // Current Address of Packet Read (Rx read ptr)
const REG_CBR: u16 = 0x3A; // Current Buffer Address (Rx write ptr)

const REG_IMR: u16 = 0x3C; // Interrupt Mask Register
const REG_ISR: u16 = 0x3E; // Interrupt Status Register

const REG_TX_CONFIG: u16 = 0x40; // Tx configuration
const REG_RX_CONFIG: u16 = 0x44; // Rx configuration

const REG_TIMER: u16 = 0x48; // Timer count register
const REG_RX_MISSED: u16 = 0x4C; // Missed packet counter

const REG_CONFIG0: u16 = 0x51; // Configuration register 0
const REG_CONFIG1: u16 = 0x52; // Configuration register 1

const REG_MEDIA_STATUS: u16 = 0x58; // Media status
const REG_BASIC_MODE_CTRL: u16 = 0x62; // Basic mode control
const REG_BASIC_MODE_STATUS: u16 = 0x64; // Basic mode status

// ---- Command register bits ----

const CMD_RX_EMPTY: u8 = 0x01; // Rx buffer empty
const CMD_TX_ENABLE: u8 = 0x04;
const CMD_RX_ENABLE: u8 = 0x08;
const CMD_RESET: u8 = 0x10; // Software reset

// ---- ISR/IMR bits ----

const INT_RX_OK: u16 = 0x0001;
const INT_RX_ERR: u16 = 0x0002;
const INT_TX_OK: u16 = 0x0004;
const INT_TX_ERR: u16 = 0x0008;
const INT_RX_OVERFLOW: u16 = 0x0010;
const INT_LINK_CHANGE: u16 = 0x0020;
const INT_RX_FIFO_OVER: u16 = 0x0040;
const INT_TIMEOUT: u16 = 0x4000;
const INT_SYSTEM_ERR: u16 = 0x8000;

// ---- Rx config bits ----

const RX_ACCEPT_ALL: u32 = 0x0001; // Accept all packets (promiscuous)
const RX_ACCEPT_PHYS_MATCH: u32 = 0x0002; // Accept physical match
const RX_ACCEPT_MULTICAST: u32 = 0x0004; // Accept multicast
const RX_ACCEPT_BROADCAST: u32 = 0x0008; // Accept broadcast
const RX_ACCEPT_RUNT: u32 = 0x0010; // Accept runt (< 64 bytes)
const RX_ACCEPT_ERR: u32 = 0x0020; // Accept error packets
const RX_WRAP: u32 = 0x0080; // Rx buffer wrap mode (1 = no wrap)
const RX_MAX_DMA_UNLIMITED: u32 = 0x0700; // Max DMA burst = unlimited
const RX_FIFO_THRESH_NONE: u32 = 0xE000; // Rx FIFO threshold = no threshold
const RX_BUF_LEN_8K: u32 = 0x0000; // 8K + 16 byte buffer
const RX_BUF_LEN_16K: u32 = 0x0800;
const RX_BUF_LEN_32K: u32 = 0x1000;
const RX_BUF_LEN_64K: u32 = 0x1800;

// ---- Tx config ----

const TX_IFG_NORMAL: u32 = 0x03000000; // Inter-frame gap: normal
const TX_MAX_DMA_256: u32 = 0x00000400; // Max DMA burst 256 bytes
const TX_MAX_DMA_512: u32 = 0x00000500;
const TX_MAX_DMA_1024: u32 = 0x00000600;

// ---- Tx status bits ----

const TX_OWN: u32 = 1 << 13; // Driver owns (clear to send)
const TX_THRESHOLD: u32 = 0x30 << 16; // Early Tx threshold (48*32=1536 bytes)
const TX_SIZE_MASK: u32 = 0x1FFF; // Packet size mask (bits 12:0)
const TX_STATUS_OK: u32 = 1 << 15; // Tx completed OK
const TX_STATUS_UNDERRUN: u32 = 1 << 14;
const TX_STATUS_ABORT: u32 = 1 << 30;
const TX_HOST_OWNS: u32 = 1 << 13;

// ---- Rx packet header ----

const RX_HDR_ROK: u16 = 0x0001; // Receive OK
const RX_HDR_FAE: u16 = 0x0002; // Frame alignment error
const RX_HDR_CRC: u16 = 0x0004; // CRC error
const RX_HDR_LONG: u16 = 0x0008; // Long packet (> 4K)
const RX_HDR_RUNT: u16 = 0x0010; // Runt packet (< 64 bytes)
const RX_HDR_ISE: u16 = 0x0020; // Invalid symbol error
const RX_HDR_BAR: u16 = 0x2000; // Broadcast
const RX_HDR_PAM: u16 = 0x4000; // Physical address matched
const RX_HDR_MAR: u16 = 0x8000; // Multicast

// ---- Buffer sizes ----

const RX_BUF_SIZE: usize = 8192 + 16 + 1500; // 8K + 16 header + 1500 overflow
const RX_BUF_PAD: usize = 16; // Packet header padding
const TX_BUF_SIZE: usize = 1536; // Max Ethernet frame
const NUM_TX_DESC: usize = 4; // 4 Tx descriptors

// ---- State ----

var io_base: u16 = 0;
var mac: [6]u8 = undefined;
var ready: bool = false;
var pci_bus: u8 = 0;
var pci_slot: u8 = 0;
var pci_func: u8 = 0;

// Rx ring buffer (8K + 16 + 1500 bytes)
var rx_buffer: [RX_BUF_SIZE]u8 align(16) = @splat(0);
var rx_offset: u16 = 0; // Current read position in ring buffer

// Tx buffers (4 descriptors, round-robin)
var tx_buffers: [NUM_TX_DESC][TX_BUF_SIZE]u8 align(16) = @splat(@splat(0));
var tx_cur: u8 = 0; // Current Tx descriptor index

// Statistics
var rx_packets: u32 = 0;
var tx_packets: u32 = 0;
var rx_errors: u32 = 0;
var tx_errors: u32 = 0;
var rx_bytes: u32 = 0;
var tx_bytes: u32 = 0;

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
    const dev = pci.findDevice(VENDOR_REALTEK, DEVICE_RTL8139) orelse {
        serial.write("[RTL8139] Device not found\n");
        return false;
    };

    pci_bus = dev.bus;
    pci_slot = dev.slot;
    pci_func = dev.func;

    // BAR0 から I/O ベースアドレス取得
    const bar0 = dev.bar0;
    if (bar0 & 0x01 == 0) {
        serial.write("[RTL8139] BAR0 is not I/O space\n");
        return false;
    }
    io_base = @truncate(bar0 & 0xFFFC);
    if (io_base == 0) return false;

    // PCI バスマスタリング有効化
    pci.enableBusMastering(pci_bus, pci_slot, pci_func);

    // ソフトウェアリセット
    if (!softwareReset()) {
        serial.write("[RTL8139] Reset failed\n");
        return false;
    }

    // MAC アドレス読み取り
    readMacAddress();

    // Rx バッファ設定
    setupRxBuffer();

    // Tx 設定
    setupTxBuffers();

    // 割り込みマスク設定 (Rx OK, Tx OK, Rx error, Tx error, overflow)
    writeReg16(REG_IMR, INT_RX_OK | INT_TX_OK | INT_RX_ERR | INT_TX_ERR | INT_RX_OVERFLOW);

    // Rx 設定: accept all + broadcast + physical match + wrap + 8K buffer
    const rx_config = RX_ACCEPT_ALL |
        RX_ACCEPT_PHYS_MATCH |
        RX_ACCEPT_BROADCAST |
        RX_ACCEPT_MULTICAST |
        RX_WRAP |
        RX_MAX_DMA_UNLIMITED |
        RX_FIFO_THRESH_NONE |
        RX_BUF_LEN_8K;
    writeReg32(REG_RX_CONFIG, rx_config);

    // Tx 設定: normal IFG + max DMA 1024
    writeReg32(REG_TX_CONFIG, TX_IFG_NORMAL | TX_MAX_DMA_1024);

    // マルチキャストフィルタ: 全て受信
    writeReg32(REG_MAR0, 0xFFFFFFFF);
    writeReg32(REG_MAR4, 0xFFFFFFFF);

    // Tx/Rx 有効化
    writeReg8(REG_COMMAND, CMD_TX_ENABLE | CMD_RX_ENABLE);

    // ISR クリア
    writeReg16(REG_ISR, 0xFFFF);

    rx_offset = 0;
    tx_cur = 0;
    rx_packets = 0;
    tx_packets = 0;
    rx_errors = 0;
    tx_errors = 0;
    rx_bytes = 0;
    tx_bytes = 0;
    ready = true;

    serial.write("[RTL8139] MAC=");
    printMacSerial();
    serial.write(" IO=0x");
    serialHex16(io_base);
    serial.write("\n");

    return true;
}

fn softwareReset() bool {
    writeReg8(REG_COMMAND, CMD_RESET);

    // リセット完了待ち (CMD_RESET ビットがクリアされるまで)
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if (readReg8(REG_COMMAND) & CMD_RESET == 0) {
            return true;
        }
        asm volatile ("pause");
    }
    return false;
}

fn readMacAddress() void {
    // I/O ポートから直接 MAC アドレスを読む
    mac[0] = readReg8(REG_MAC0 + 0);
    mac[1] = readReg8(REG_MAC0 + 1);
    mac[2] = readReg8(REG_MAC0 + 2);
    mac[3] = readReg8(REG_MAC0 + 3);
    mac[4] = readReg8(REG_MAC4 + 0);
    mac[5] = readReg8(REG_MAC4 + 1);
}

fn setupRxBuffer() void {
    // Rx バッファの物理アドレスをレジスタに設定
    const rx_phys = @intFromPtr(&rx_buffer);
    writeReg32(REG_RX_BUF, @truncate(rx_phys));

    // CAPR をリセット (Rx 読み出し位置)
    writeReg16(REG_CAPR, 0);

    // バッファクリア
    for (&rx_buffer) |*b| {
        b.* = 0;
    }
}

fn setupTxBuffers() void {
    // 4 つの Tx バッファアドレスをセット
    const tx_addr_regs = [4]u16{ REG_TX_ADDR0, REG_TX_ADDR1, REG_TX_ADDR2, REG_TX_ADDR3 };
    for (tx_addr_regs) |reg| {
        writeReg32(reg, 0);
    }
}

// ---- Send ----

pub fn send(data: []const u8) void {
    if (!ready) return;
    if (data.len == 0 or data.len > TX_BUF_SIZE) return;

    const desc_idx: usize = tx_cur;

    // データをバッファにコピー
    @memcpy(tx_buffers[desc_idx][0..data.len], data);

    // パディング: 最小 60 バイト (Ethernet minimum without FCS)
    var send_len = data.len;
    if (send_len < 60) {
        for (tx_buffers[desc_idx][send_len..60]) |*b| {
            b.* = 0;
        }
        send_len = 60;
    }

    // Tx アドレスレジスタにバッファアドレスを設定
    const tx_addr_reg = REG_TX_ADDR0 + @as(u16, desc_idx) * 4;
    writeReg32(tx_addr_reg, @truncate(@intFromPtr(&tx_buffers[desc_idx])));

    // Tx ステータスレジスタにサイズとしきい値を設定 (OWN ビット = 0 でカード所有)
    const tx_status_reg = REG_TX_STATUS0 + @as(u16, desc_idx) * 4;
    const status_val: u32 = (@as(u32, @truncate(send_len)) & TX_SIZE_MASK) | TX_THRESHOLD;
    writeReg32(tx_status_reg, status_val);

    // 送信完了待ち
    var timeout: u32 = 0;
    while (timeout < 500000) : (timeout += 1) {
        const st = readReg32(tx_status_reg);
        if (st & TX_STATUS_OK != 0) {
            tx_packets += 1;
            tx_bytes += @truncate(send_len);
            break;
        }
        if (st & TX_STATUS_ABORT != 0) {
            tx_errors += 1;
            break;
        }
        asm volatile ("pause");
    }

    // 次のディスクリプタへ
    tx_cur = @truncate((@as(u16, tx_cur) + 1) % NUM_TX_DESC);
}

// ---- Receive ----

pub fn receive(buf: []u8) ?u16 {
    if (!ready) return null;

    // コマンドレジスタチェック: バッファ空？
    if (readReg8(REG_COMMAND) & CMD_RX_EMPTY != 0) {
        return null;
    }

    // ISR チェック
    const isr = readReg16(REG_ISR);
    if (isr & INT_RX_OK != 0) {
        // Rx OK ビットをクリア
        writeReg16(REG_ISR, INT_RX_OK);
    }
    if (isr & INT_RX_ERR != 0) {
        writeReg16(REG_ISR, INT_RX_ERR);
        rx_errors += 1;
    }

    // リングバッファからパケットヘッダを読み取る
    // ヘッダ形式: [status:16][length:16][data...]
    const offset: usize = rx_offset;

    // ステータスワードとパケット長を読む
    const hdr_status: u16 = @as(u16, rx_buffer[offset % RX_BUF_SIZE]) |
        (@as(u16, rx_buffer[(offset + 1) % RX_BUF_SIZE]) << 8);
    const pkt_len: u16 = @as(u16, rx_buffer[(offset + 2) % RX_BUF_SIZE]) |
        (@as(u16, rx_buffer[(offset + 3) % RX_BUF_SIZE]) << 8);

    // 有効性チェック
    if (hdr_status & RX_HDR_ROK == 0) {
        // エラーパケット — スキップ
        if (pkt_len > 0 and pkt_len < RX_BUF_SIZE) {
            advanceRxOffset(pkt_len);
        }
        rx_errors += 1;
        return null;
    }

    // パケット長の妥当性チェック (CRC 4 バイトを含む)
    if (pkt_len < 8 or pkt_len > 1518 + 4) {
        advanceRxOffset(pkt_len);
        rx_errors += 1;
        return null;
    }

    // 実データ長 (CRC 4 バイトを除く)
    const data_len = pkt_len - 4;
    if (data_len > buf.len) {
        advanceRxOffset(pkt_len);
        return null;
    }

    // ヘッダ (4 バイト) の後のデータをコピー
    const data_start = offset + 4;
    var i: usize = 0;
    while (i < data_len) : (i += 1) {
        buf[i] = rx_buffer[(data_start + i) % RX_BUF_SIZE];
    }

    advanceRxOffset(pkt_len);

    rx_packets += 1;
    rx_bytes += @truncate(data_len);

    return @truncate(data_len);
}

fn advanceRxOffset(pkt_len: u16) void {
    // 次のパケットへ: ヘッダ (4) + パケット長を 4 バイトアライン
    const total = @as(usize, pkt_len) + 4; // 4 byte header
    const aligned = (total + 3) & ~@as(usize, 3); // 4-byte alignment
    rx_offset = @truncate((@as(usize, rx_offset) + aligned) % RX_BUF_SIZE);
    // CAPR を更新 (ハードウェアに読み出し位置を通知)
    // RTL8139 の CAPR は「次に読む位置 - 16」を設定する
    const capr_val: u16 = rx_offset -% 16;
    writeReg16(REG_CAPR, capr_val);
}

// ---- Query functions ----

pub fn getMac() [6]u8 {
    return mac;
}

pub fn isInitialized() bool {
    return ready;
}

pub fn getLinkStatus() bool {
    if (!ready) return false;
    const media = readReg8(REG_MEDIA_STATUS);
    // bit 2: link status (0 = link, 1 = no link — inverted)
    return (media & 0x04) == 0;
}

pub fn getSpeed() u16 {
    if (!ready) return 0;
    const bms = readReg16(REG_BASIC_MODE_STATUS);
    // Simple heuristic: if link up, assume 100Mbps or 10Mbps
    if (bms & (1 << 14) != 0) return 100; // 100BASE-TX capable
    return 10;
}

// ---- Statistics ----

pub fn getRxPackets() u32 {
    return rx_packets;
}

pub fn getTxPackets() u32 {
    return tx_packets;
}

pub fn getRxErrors() u32 {
    return rx_errors;
}

pub fn getTxErrors() u32 {
    return tx_errors;
}

pub fn getRxBytes() u32 {
    return rx_bytes;
}

pub fn getTxBytes() u32 {
    return tx_bytes;
}

pub fn getMissedPackets() u32 {
    if (!ready) return 0;
    return readReg32(REG_RX_MISSED);
}

// ---- Display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("RTL8139 Network Controller:\n");
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

    // Link status
    vga.write("  Link: ");
    if (getLinkStatus()) {
        vga.setColor(.light_green, .black);
        vga.write("UP ");
        printDec(getSpeed());
        vga.write("Mbps");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("DOWN");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    // Statistics
    vga.write("  Rx: ");
    printDec(rx_packets);
    vga.write(" pkts, ");
    printDec(rx_bytes);
    vga.write(" bytes, ");
    printDec(rx_errors);
    vga.write(" errors\n");

    vga.write("  Tx: ");
    printDec(tx_packets);
    vga.write(" pkts, ");
    printDec(tx_bytes);
    vga.write(" bytes, ");
    printDec(tx_errors);
    vga.write(" errors\n");

    vga.write("  Missed: ");
    printDec(getMissedPackets());
    vga.putChar('\n');

    // Register dump
    vga.write("  CMD: 0x");
    printHex8(readReg8(REG_COMMAND));
    vga.write("  IMR: 0x");
    printHex16(readReg16(REG_IMR));
    vga.write("  ISR: 0x");
    printHex16(readReg16(REG_ISR));
    vga.putChar('\n');

    vga.write("  RxConfig: 0x");
    printHex32(readReg32(REG_RX_CONFIG));
    vga.write("  TxConfig: 0x");
    printHex32(readReg32(REG_TX_CONFIG));
    vga.putChar('\n');

    vga.write("  CAPR: 0x");
    printHex16(readReg16(REG_CAPR));
    vga.write("  CBR: 0x");
    printHex16(readReg16(REG_CBR));
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

fn printHex32(val: u32) void {
    printHex16(@truncate(val >> 16));
    printHex16(@truncate(val));
}

fn printDec(n: u32) void {
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
