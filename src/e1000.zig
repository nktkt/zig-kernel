// Intel E1000 NIC ドライバ — QEMU デフォルト NIC (82540EM)

const pci = @import("pci.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const VENDOR_INTEL: u16 = 0x8086;
const DEVICE_E1000: u16 = 0x100E;

// レジスタオフセット
const REG_CTRL: u32 = 0x0000;
const REG_STATUS: u32 = 0x0008;
const REG_EERD: u32 = 0x0014;
const REG_RCTL: u32 = 0x0100;
const REG_TCTL: u32 = 0x0400;
const REG_RDBAL: u32 = 0x2800;
const REG_RDLEN: u32 = 0x2808;
const REG_RDH: u32 = 0x2810;
const REG_RDT: u32 = 0x2818;
const REG_TDBAL: u32 = 0x3800;
const REG_TDLEN: u32 = 0x3808;
const REG_TDH: u32 = 0x3810;
const REG_TDT: u32 = 0x3818;
const REG_RAL: u32 = 0x5400;
const REG_RAH: u32 = 0x5404;

const NUM_RX: u32 = 8;
const NUM_TX: u32 = 8;
pub const BUF_SIZE = 2048;

const RxDesc = packed struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

const TxDesc = packed struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

var mmio_base: u32 = 0;
pub var mac: [6]u8 = undefined;

var rx_descs: [NUM_RX]RxDesc align(128) = undefined;
var tx_descs: [NUM_TX]TxDesc align(128) = undefined;
pub var rx_bufs: [NUM_RX][BUF_SIZE]u8 align(16) = undefined;
var tx_buf: [BUF_SIZE]u8 align(16) = undefined;

var rx_cur: u32 = 0;
var tx_cur: u32 = 0;
var ready: bool = false;

fn readReg(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    return ptr.*;
}

fn writeReg(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    ptr.* = val;
}

pub fn init() bool {
    const dev = pci.findDevice(VENDOR_INTEL, DEVICE_E1000) orelse return false;

    mmio_base = dev.bar0 & 0xFFFFFFF0;
    if (mmio_base == 0) return false;

    // MMIO 領域をページテーブルにマップ
    paging.mapMMIO(mmio_base);

    // PCI バスマスタリング有効化
    pci.enableBusMastering(dev.bus, dev.slot, dev.func);

    // デバイスリセット
    writeReg(REG_CTRL, readReg(REG_CTRL) | (1 << 26));
    busyWait(10000);
    // リセット完了待ち
    while (readReg(REG_CTRL) & (1 << 26) != 0) {}

    // リンクアップ
    writeReg(REG_CTRL, readReg(REG_CTRL) | (1 << 6)); // SLU

    // MAC アドレス読み取り
    const ral = readReg(REG_RAL);
    const rah = readReg(REG_RAH);
    if (ral != 0 or (rah & 0xFFFF) != 0) {
        mac[0] = @truncate(ral);
        mac[1] = @truncate(ral >> 8);
        mac[2] = @truncate(ral >> 16);
        mac[3] = @truncate(ral >> 24);
        mac[4] = @truncate(rah);
        mac[5] = @truncate(rah >> 8);
    } else {
        readMacEeprom();
    }

    // RX 初期化
    for (0..NUM_RX) |i| {
        rx_descs[i] = .{
            .addr = @intFromPtr(&rx_bufs[i]),
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }
    writeReg(REG_RDBAL, @intFromPtr(&rx_descs));
    writeReg(REG_RDLEN, NUM_RX * @sizeOf(RxDesc));
    writeReg(REG_RDH, 0);
    writeReg(REG_RDT, NUM_RX - 1);
    writeReg(REG_RCTL, (1 << 1) | // EN
        (1 << 3) | // UPE
        (1 << 4) | // MPE
        (1 << 15) | // BAM
        (1 << 26) // SECRC
    );

    // TX 初期化
    for (0..NUM_TX) |i| {
        tx_descs[i] = .{
            .addr = 0,
            .length = 0,
            .cso = 0,
            .cmd = 0,
            .status = 1,
            .css = 0,
            .special = 0,
        };
    }
    writeReg(REG_TDBAL, @intFromPtr(&tx_descs));
    writeReg(REG_TDLEN, NUM_TX * @sizeOf(TxDesc));
    writeReg(REG_TDH, 0);
    writeReg(REG_TDT, 0);
    writeReg(REG_TCTL, (1 << 1) | // EN
        (1 << 3) | // PSP
        (0x0F << 4) | // CT
        (0x40 << 12) // COLD
    );

    rx_cur = 0;
    tx_cur = 0;
    ready = true;

    serial.write("[E1000] MAC=");
    for (mac, 0..) |b, i| {
        if (i > 0) serial.putChar(':');
        const hex = "0123456789ABCDEF";
        serial.putChar(hex[b >> 4]);
        serial.putChar(hex[b & 0xF]);
    }
    serial.write("\n");

    return true;
}

fn readMacEeprom() void {
    for (0..3) |i| {
        writeReg(REG_EERD, 1 | (@as(u32, @truncate(i)) << 8));
        var val: u32 = 0;
        var timeout: u32 = 0;
        while (val & (1 << 4) == 0 and timeout < 10000) : (timeout += 1) {
            val = readReg(REG_EERD);
        }
        mac[i * 2] = @truncate(val >> 16);
        mac[i * 2 + 1] = @truncate(val >> 24);
    }
}

pub fn send(data: []const u8) void {
    if (!ready or data.len > BUF_SIZE) return;

    const cur = tx_cur;
    @memcpy(tx_buf[0..data.len], data);

    tx_descs[cur].addr = @intFromPtr(&tx_buf);
    tx_descs[cur].length = @truncate(data.len);
    tx_descs[cur].cmd = (1 << 0) | (1 << 1) | (1 << 3); // EOP | IFCS | RS
    tx_descs[cur].status = 0;

    tx_cur = (tx_cur + 1) % NUM_TX;
    writeReg(REG_TDT, tx_cur);

    // 送信完了待ち
    var timeout: u32 = 0;
    while (tx_descs[cur].status & 0xFF == 0 and timeout < 1000000) : (timeout += 1) {}
}

pub fn receive(buf: []u8) ?u16 {
    if (!ready) return null;

    const cur = rx_cur;
    if (rx_descs[cur].status & 1 == 0) return null; // DD なし

    const len = rx_descs[cur].length;
    if (len == 0 or len > buf.len) {
        rx_descs[cur].status = 0;
        const old = rx_cur;
        rx_cur = (rx_cur + 1) % NUM_RX;
        writeReg(REG_RDT, old);
        return null;
    }

    @memcpy(buf[0..len], rx_bufs[cur][0..len]);

    rx_descs[cur].status = 0;
    const old = rx_cur;
    rx_cur = (rx_cur + 1) % NUM_RX;
    writeReg(REG_RDT, old);

    return len;
}

pub fn isInitialized() bool {
    return ready;
}

fn busyWait(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        asm volatile ("pause");
    }
}
