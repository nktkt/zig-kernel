// AHCI (SATA) コントローラドライバ — Advanced Host Controller Interface
//
// PCI class 0x01, subclass 0x06. MMIO BAR5 (ABAR).
// HBA メモリレジスタ: CAP, GHC, IS, PI, VS.
// ポートレジスタ: CLB, FB, IS, IE, CMD, TFD, SIG, SSTS, SCTL, SERR, CI.
// ポート初期化: コマンドエンジン停止, CLB/FB 設定, 開始.
// IDENTIFY コマンドによるデバイス情報取得.

const pci = @import("pci.zig");
const paging = @import("paging.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- PCI identification ----

const AHCI_CLASS: u8 = 0x01; // Mass Storage Controller
const AHCI_SUBCLASS: u8 = 0x06; // SATA Controller
const AHCI_PROGIF: u8 = 0x01; // AHCI 1.0

// ---- HBA Memory Register offsets (Generic Host Control) ----

const HBA_CAP: u32 = 0x00; // Host Capabilities
const HBA_GHC: u32 = 0x04; // Global Host Control
const HBA_IS: u32 = 0x08; // Interrupt Status
const HBA_PI: u32 = 0x0C; // Ports Implemented
const HBA_VS: u32 = 0x10; // Version
const HBA_CCC_CTL: u32 = 0x14; // Command Completion Coalescing Control
const HBA_CCC_PORTS: u32 = 0x18; // CCC Ports
const HBA_EM_LOC: u32 = 0x1C; // Enclosure Management Location
const HBA_EM_CTL: u32 = 0x20; // Enclosure Management Control
const HBA_CAP2: u32 = 0x24; // Host Capabilities Extended
const HBA_BOHC: u32 = 0x28; // BIOS/OS Handoff Control

// ---- GHC bits ----

const GHC_HR: u32 = 1 << 0; // HBA Reset
const GHC_IE: u32 = 1 << 1; // Interrupt Enable
const GHC_AE: u32 = 1 << 31; // AHCI Enable

// ---- Port Register offsets (per-port, base = 0x100 + port*0x80) ----

const PORT_CLB: u32 = 0x00; // Command List Base Address (lower 32)
const PORT_CLBU: u32 = 0x04; // Command List Base Address (upper 32)
const PORT_FB: u32 = 0x08; // FIS Base Address (lower 32)
const PORT_FBU: u32 = 0x0C; // FIS Base Address (upper 32)
const PORT_IS: u32 = 0x10; // Interrupt Status
const PORT_IE: u32 = 0x14; // Interrupt Enable
const PORT_CMD: u32 = 0x18; // Command and Status
const PORT_TFD: u32 = 0x20; // Task File Data
const PORT_SIG: u32 = 0x24; // Signature
const PORT_SSTS: u32 = 0x28; // SATA Status (SCR0: SStatus)
const PORT_SCTL: u32 = 0x2C; // SATA Control (SCR2: SControl)
const PORT_SERR: u32 = 0x30; // SATA Error (SCR1: SError)
const PORT_SACT: u32 = 0x34; // SATA Active
const PORT_CI: u32 = 0x38; // Command Issue

// ---- Port CMD bits ----

const PORT_CMD_ST: u32 = 1 << 0; // Start
const PORT_CMD_SUD: u32 = 1 << 1; // Spin-Up Device
const PORT_CMD_POD: u32 = 1 << 2; // Power On Device
const PORT_CMD_FRE: u32 = 1 << 4; // FIS Receive Enable
const PORT_CMD_FR: u32 = 1 << 14; // FIS Receive Running
const PORT_CMD_CR: u32 = 1 << 15; // Command List Running
const PORT_CMD_ATAPI: u32 = 1 << 24; // Device is ATAPI
const PORT_CMD_ICC_ACTIVE: u32 = 1 << 28; // Interface Communication Control

// ---- Port TFD bits ----

const TFD_STS_BSY: u32 = 1 << 7;
const TFD_STS_DRQ: u32 = 1 << 3;
const TFD_STS_ERR: u32 = 1 << 0;

// ---- SATA Status (SSTS) ----

const SSTS_DET_MASK: u32 = 0x0F; // Device Detection
const SSTS_DET_PRESENT: u32 = 0x03; // Device present and PHY communication established
const SSTS_IPM_MASK: u32 = 0x0F00;
const SSTS_IPM_ACTIVE: u32 = 0x0100; // Interface in active state

// ---- Device Signatures ----

const SIG_ATA: u32 = 0x00000101; // SATA drive
const SIG_ATAPI: u32 = 0xEB140101; // SATAPI drive
const SIG_SEMB: u32 = 0xC33C0101; // Enclosure management bridge
const SIG_PM: u32 = 0x96690101; // Port multiplier

// ---- FIS Types ----

const FIS_TYPE_REG_H2D: u8 = 0x27; // Register FIS - Host to Device
const FIS_TYPE_REG_D2H: u8 = 0x34; // Register FIS - Device to Host
const FIS_TYPE_DMA_ACT: u8 = 0x39; // DMA Activate FIS
const FIS_TYPE_DMA_SETUP: u8 = 0x41; // DMA Setup FIS
const FIS_TYPE_DATA: u8 = 0x46; // Data FIS
const FIS_TYPE_BIST: u8 = 0x58; // BIST Activate FIS
const FIS_TYPE_PIO_SETUP: u8 = 0x5F; // PIO Setup FIS
const FIS_TYPE_DEV_BITS: u8 = 0xA1; // Set Device Bits FIS

// ---- ATA Commands ----

const ATA_CMD_IDENTIFY: u8 = 0xEC; // IDENTIFY DEVICE
const ATA_CMD_IDENTIFY_PACKET: u8 = 0xA1; // IDENTIFY PACKET DEVICE
const ATA_CMD_READ_DMA_EX: u8 = 0x25; // READ DMA EXT (48-bit LBA)
const ATA_CMD_WRITE_DMA_EX: u8 = 0x35; // WRITE DMA EXT

// ---- Command structures ----

const FisRegH2D = packed struct {
    fis_type: u8, // FIS_TYPE_REG_H2D
    pm_port_c: u8, // Port multiplier | Command bit
    command: u8, // ATA command
    feature_lo: u8,
    lba0: u8, // LBA 7:0
    lba1: u8, // LBA 15:8
    lba2: u8, // LBA 23:16
    device: u8, // Device register
    lba3: u8, // LBA 31:24
    lba4: u8, // LBA 39:32
    lba5: u8, // LBA 47:40
    feature_hi: u8,
    count_lo: u8, // Sector count 7:0
    count_hi: u8, // Sector count 15:8
    icc: u8,
    control: u8,
    reserved: [4]u8,
};

const HbaCmdHeader = packed struct {
    // DW0
    cfl: u8, // Command FIS length (in DWORDs), ATAPI, Write, Prefetchable bits
    prd_count_port: u8, // Reset, BIST, Clear Busy, Port Multiplier
    prdtl: u16, // Physical Region Descriptor Table Length

    // DW1
    prdbc: u32, // Physical Region Descriptor Byte Count

    // DW2-3
    ctba: u32, // Command Table Base Address (lower)
    ctbau: u32, // Command Table Base Address (upper)

    // DW4-7
    reserved: [4]u32,
};

const HbaPrdtEntry = packed struct {
    dba: u32, // Data Base Address (lower)
    dbau: u32, // Data Base Address (upper)
    reserved: u32,
    dbc_i: u32, // Byte Count (bit 31 = interrupt on completion)
};

// ---- Device types ----

pub const DeviceType = enum {
    none,
    ata,
    atapi,
    semb,
    pm,
};

// ---- Port info ----

pub const PortInfo = struct {
    port_num: u8,
    dev_type: DeviceType,
    sig: u32,
    ssts: u32,
    model: [40]u8,
    serial_num: [20]u8,
    firmware_rev: [8]u8,
    lba_sectors: u64,
    udma_supported: bool,
    identified: bool,
};

// ---- State ----

const MAX_PORTS = 32;

var abar: u32 = 0; // AHCI Base Address Register (MMIO)
var ready: bool = false;
var ahci_bus: u8 = 0;
var ahci_slot: u8 = 0;
var ahci_func: u8 = 0;
var num_ports: u8 = 0;
var ports_impl: u32 = 0;
var version_major: u8 = 0;
var version_minor: u8 = 0;
var num_cmd_slots: u8 = 0;

var port_info: [MAX_PORTS]PortInfo = @splat(PortInfo{
    .port_num = 0,
    .dev_type = .none,
    .sig = 0,
    .ssts = 0,
    .model = @splat(0),
    .serial_num = @splat(0),
    .firmware_rev = @splat(0),
    .lba_sectors = 0,
    .udma_supported = false,
    .identified = false,
});
var active_port_count: u8 = 0;

// Command list and FIS buffer (statically allocated, aligned)
// Each port needs: 1KB command list + 256B FIS receive area
var cmd_list_buf: [MAX_PORTS][1024]u8 align(1024) = @splat(@splat(0));
var fis_buf: [MAX_PORTS][256]u8 align(256) = @splat(@splat(0));

// Command table (one per port, 256 bytes aligned to 128)
var cmd_table_buf: [MAX_PORTS][256]u8 align(128) = @splat(@splat(0));

// Data buffer for IDENTIFY and read operations
var identify_buf: [512]u8 align(2) = @splat(0);

// ---- MMIO helpers ----

fn readMmio(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(abar + offset);
    return ptr.*;
}

fn writeMmio(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(abar + offset);
    ptr.* = val;
}

fn portBase(port: u8) u32 {
    return 0x100 + @as(u32, port) * 0x80;
}

fn readPort(port: u8, offset: u32) u32 {
    return readMmio(portBase(port) + offset);
}

fn writePort(port: u8, offset: u32, val: u32) void {
    writeMmio(portBase(port) + offset, val);
}

// ---- Initialization ----

pub fn init() void {
    ready = false;
    active_port_count = 0;

    // PCI デバイスをスキャン (class 0x01, subclass 0x06)
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

            if (class == AHCI_CLASS and subclass == AHCI_SUBCLASS) {
                // BAR5 (ABAR) に MMIO ベースアドレス
                const bar5 = pci.readConfig(0, slot, func, 0x24);
                if (bar5 & 0x01 == 0 and bar5 != 0) { // Memory space
                    abar = bar5 & 0xFFFFFFF0;
                    ahci_bus = 0;
                    ahci_slot = slot;
                    ahci_func = func;

                    // PCI バスマスタリング有効化
                    pci.enableBusMastering(0, slot, func);

                    // MMIO マップ
                    paging.mapMMIO(abar);

                    serial.write("[AHCI] found at slot=");
                    serial.writeHex(slot);
                    serial.write(" ABAR=0x");
                    serial.writeHex(abar);
                    serial.write("\n");

                    initController();
                    return;
                }
            }

            if (func == 0) {
                const hdr: u8 = @truncate(pci.readConfig(0, slot, 0, 0x0C) >> 16);
                if (hdr & 0x80 == 0) break;
            }
        }
    }

    serial.write("[AHCI] No controller found\n");
}

fn initController() void {
    // バージョン読み取り
    const vs = readMmio(HBA_VS);
    version_major = @truncate(vs >> 16);
    version_minor = @truncate(vs);

    // Capabilities 読み取り
    const cap = readMmio(HBA_CAP);
    num_cmd_slots = @truncate(((cap >> 8) & 0x1F) + 1);
    const num_ports_cap: u8 = @truncate((cap & 0x1F) + 1);
    _ = num_ports_cap;

    // AHCI 有効化
    var ghc = readMmio(HBA_GHC);
    ghc |= GHC_AE;
    writeMmio(HBA_GHC, ghc);

    // ポート実装ビットマップ読み取り
    ports_impl = readMmio(HBA_PI);

    // 割り込みクリア
    writeMmio(HBA_IS, 0xFFFFFFFF);

    // 各ポートを初期化
    num_ports = 0;
    var port: u8 = 0;
    while (port < 32) : (port += 1) {
        if (ports_impl & (@as(u32, 1) << @truncate(port)) == 0) continue;

        const ssts = readPort(port, PORT_SSTS);
        const det = ssts & SSTS_DET_MASK;
        const ipm = ssts & SSTS_IPM_MASK;

        if (det != SSTS_DET_PRESENT or ipm != SSTS_IPM_ACTIVE) continue;

        // デバイスが接続されている
        initPort(port);

        // デバイスシグネチャ確認
        const sig = readPort(port, PORT_SIG);
        const dev_type = classifyDevice(sig);

        port_info[active_port_count] = .{
            .port_num = port,
            .dev_type = dev_type,
            .sig = sig,
            .ssts = ssts,
            .model = @splat(0),
            .serial_num = @splat(0),
            .firmware_rev = @splat(0),
            .lba_sectors = 0,
            .udma_supported = false,
            .identified = false,
        };

        // ATA デバイスなら IDENTIFY 実行
        if (dev_type == .ata or dev_type == .atapi) {
            identifyDevice(port, active_port_count);
        }

        active_port_count += 1;
        num_ports += 1;

        if (active_port_count >= MAX_PORTS) break;
    }

    ready = true;

    serial.write("[AHCI] v");
    serialDecU8(version_major);
    serial.putChar('.');
    serialDecU8(version_minor);
    serial.write(" ports=");
    serialDecU8(active_port_count);
    serial.write(" slots=");
    serialDecU8(num_cmd_slots);
    serial.write("\n");
}

fn initPort(port: u8) void {
    // コマンドエンジン停止
    stopCommandEngine(port);

    // コマンドリストベースアドレス設定
    const clb_addr = @intFromPtr(&cmd_list_buf[port]);
    writePort(port, PORT_CLB, @truncate(clb_addr));
    writePort(port, PORT_CLBU, 0);

    // FIS ベースアドレス設定
    const fb_addr = @intFromPtr(&fis_buf[port]);
    writePort(port, PORT_FB, @truncate(fb_addr));
    writePort(port, PORT_FBU, 0);

    // コマンドリストバッファクリア
    for (&cmd_list_buf[port]) |*b| b.* = 0;
    for (&fis_buf[port]) |*b| b.* = 0;

    // コマンドヘッダにコマンドテーブルアドレスを設定
    const cmd_hdr: *align(1) HbaCmdHeader = @ptrCast(&cmd_list_buf[port]);
    cmd_hdr.ctba = @truncate(@intFromPtr(&cmd_table_buf[port]));
    cmd_hdr.ctbau = 0;

    // ポートの割り込みステータスクリア
    writePort(port, PORT_IS, 0xFFFFFFFF);

    // SERR クリア
    writePort(port, PORT_SERR, 0xFFFFFFFF);

    // 割り込み有効化 (全イベント)
    writePort(port, PORT_IE, 0xFFFFFFFF);

    // コマンドエンジン開始
    startCommandEngine(port);
}

fn stopCommandEngine(port: u8) void {
    var cmd = readPort(port, PORT_CMD);

    // ST (Start) ビットクリア
    cmd &= ~PORT_CMD_ST;
    writePort(port, PORT_CMD, cmd);

    // CR (Command List Running) がクリアされるまで待つ
    var timeout: u32 = 0;
    while (timeout < 500000) : (timeout += 1) {
        if (readPort(port, PORT_CMD) & PORT_CMD_CR == 0) break;
        asm volatile ("pause");
    }

    // FRE (FIS Receive Enable) クリア
    cmd = readPort(port, PORT_CMD);
    cmd &= ~PORT_CMD_FRE;
    writePort(port, PORT_CMD, cmd);

    // FR (FIS Receive Running) がクリアされるまで待つ
    timeout = 0;
    while (timeout < 500000) : (timeout += 1) {
        if (readPort(port, PORT_CMD) & PORT_CMD_FR == 0) break;
        asm volatile ("pause");
    }
}

fn startCommandEngine(port: u8) void {
    // BSY と DRQ がクリアされるまで待つ
    var timeout: u32 = 0;
    while (timeout < 500000) : (timeout += 1) {
        const tfd = readPort(port, PORT_TFD);
        if (tfd & (TFD_STS_BSY | TFD_STS_DRQ) == 0) break;
        asm volatile ("pause");
    }

    // FRE を先にセット
    var cmd = readPort(port, PORT_CMD);
    cmd |= PORT_CMD_FRE;
    writePort(port, PORT_CMD, cmd);

    // ST をセット
    cmd = readPort(port, PORT_CMD);
    cmd |= PORT_CMD_ST;
    writePort(port, PORT_CMD, cmd);
}

fn classifyDevice(sig: u32) DeviceType {
    return switch (sig) {
        SIG_ATA => .ata,
        SIG_ATAPI => .atapi,
        SIG_SEMB => .semb,
        SIG_PM => .pm,
        else => .none,
    };
}

fn deviceTypeName(dt: DeviceType) []const u8 {
    return switch (dt) {
        .ata => "SATA",
        .atapi => "SATAPI",
        .semb => "SEMB",
        .pm => "Port Multiplier",
        .none => "None",
    };
}

// ---- IDENTIFY command ----

fn identifyDevice(port: u8, info_idx: u8) void {
    // コマンドテーブルクリア
    for (&cmd_table_buf[port]) |*b| b.* = 0;

    // FIS setup (Register H2D)
    const cmd_table: [*]u8 = &cmd_table_buf[port];
    cmd_table[0] = FIS_TYPE_REG_H2D;
    cmd_table[1] = 0x80; // Command bit set
    cmd_table[2] = ATA_CMD_IDENTIFY;
    cmd_table[3] = 0; // Features

    // PRDT entry: point to identify buffer
    // PRDT starts at offset 0x80 in command table
    const prdt: *align(1) HbaPrdtEntry = @ptrCast(cmd_table + 0x80);
    prdt.dba = @truncate(@intFromPtr(&identify_buf));
    prdt.dbau = 0;
    prdt.reserved = 0;
    prdt.dbc_i = 511; // 512 bytes - 1

    // Command header setup
    const cmd_hdr: *align(1) HbaCmdHeader = @ptrCast(&cmd_list_buf[port]);
    cmd_hdr.cfl = 5; // FIS length in DWORDs (20 bytes / 4)
    cmd_hdr.prd_count_port = 0; // No reset/BIST
    cmd_hdr.prdtl = 1; // 1 PRDT entry

    // Clear identify buffer
    for (&identify_buf) |*b| b.* = 0;

    // Issue command (slot 0)
    writePort(port, PORT_CI, 1);

    // 完了待ち
    var timeout: u32 = 0;
    while (timeout < 1000000) : (timeout += 1) {
        if (readPort(port, PORT_CI) & 1 == 0) break;
        const is = readPort(port, PORT_IS);
        if (is & (1 << 30) != 0) { // Task File Error
            writePort(port, PORT_IS, is);
            return;
        }
        asm volatile ("pause");
    }

    // IDENTIFY データ解析
    parseIdentifyData(info_idx);
}

fn parseIdentifyData(info_idx: u8) void {
    const words: [*]const u16 = @alignCast(@ptrCast(&identify_buf));

    // Serial number: words 10-19 (20 bytes, ATA string format = byte-swapped)
    extractAtaString(words, 10, 20, &port_info[info_idx].serial_num);

    // Firmware revision: words 23-26 (8 bytes)
    extractAtaString(words, 23, 8, &port_info[info_idx].firmware_rev);

    // Model number: words 27-46 (40 bytes)
    extractAtaString(words, 27, 40, &port_info[info_idx].model);

    // LBA48 sector count: words 100-103
    const lba48_lo: u64 = @as(u64, words[100]) | (@as(u64, words[101]) << 16);
    const lba48_hi: u64 = @as(u64, words[102]) | (@as(u64, words[103]) << 16);
    port_info[info_idx].lba_sectors = lba48_lo | (lba48_hi << 32);

    // If LBA48 is 0, fall back to LBA28: words 60-61
    if (port_info[info_idx].lba_sectors == 0) {
        port_info[info_idx].lba_sectors = @as(u64, words[60]) | (@as(u64, words[61]) << 16);
    }

    // UDMA support: word 88
    const udma_modes = words[88];
    port_info[info_idx].udma_supported = (udma_modes & 0x3F) != 0;

    port_info[info_idx].identified = true;
}

fn extractAtaString(words: [*]const u16, start_word: usize, len: usize, out: []u8) void {
    // ATA strings are stored as big-endian words
    var i: usize = 0;
    while (i < len) : (i += 2) {
        const word_idx = start_word + i / 2;
        const w = words[word_idx];
        if (i < out.len) out[i] = @truncate(w >> 8);
        if (i + 1 < out.len) out[i + 1] = @truncate(w);
    }
    // Trim trailing spaces
    var end: usize = len;
    while (end > 0 and (end > out.len or out[end - 1] == ' ' or out[end - 1] == 0)) {
        end -= 1;
    }
    // Zero-fill the rest
    while (end < out.len) : (end += 1) {
        out[end] = 0;
    }
}

// ---- Read sectors ----

pub fn readSectors(port_idx: u8, lba: u64, count: u16, buf: [*]u8) bool {
    if (!ready or port_idx >= active_port_count) return false;
    if (count == 0) return false;

    const port = port_info[port_idx].port_num;

    // コマンドテーブルクリア
    for (&cmd_table_buf[port]) |*b| b.* = 0;

    // FIS setup: READ DMA EXT
    const cmd_table: [*]u8 = &cmd_table_buf[port];
    cmd_table[0] = FIS_TYPE_REG_H2D;
    cmd_table[1] = 0x80; // Command bit
    cmd_table[2] = ATA_CMD_READ_DMA_EX;
    cmd_table[3] = 0; // Features

    // LBA
    cmd_table[4] = @truncate(lba); // LBA 7:0
    cmd_table[5] = @truncate(lba >> 8); // LBA 15:8
    cmd_table[6] = @truncate(lba >> 16); // LBA 23:16
    cmd_table[7] = 0x40; // Device: LBA mode
    cmd_table[8] = @truncate(lba >> 24); // LBA 31:24
    cmd_table[9] = @truncate(lba >> 32); // LBA 39:32
    cmd_table[10] = @truncate(lba >> 40); // LBA 47:40
    cmd_table[11] = 0; // Features high

    // Count
    cmd_table[12] = @truncate(count); // Count low
    cmd_table[13] = @truncate(count >> 8); // Count high

    // PRDT entry
    const prdt: *align(1) HbaPrdtEntry = @ptrCast(cmd_table + 0x80);
    prdt.dba = @truncate(@intFromPtr(buf));
    prdt.dbau = 0;
    prdt.reserved = 0;
    prdt.dbc_i = @as(u32, count) * 512 - 1; // Byte count - 1

    // Command header
    const cmd_hdr: *align(1) HbaCmdHeader = @ptrCast(&cmd_list_buf[port]);
    cmd_hdr.cfl = 5;
    cmd_hdr.prd_count_port = 0;
    cmd_hdr.prdtl = 1;
    cmd_hdr.prdbc = 0;

    // Issue command
    writePort(port, PORT_CI, 1);

    // 完了待ち
    var timeout: u32 = 0;
    while (timeout < 2000000) : (timeout += 1) {
        if (readPort(port, PORT_CI) & 1 == 0) return true;
        const is = readPort(port, PORT_IS);
        if (is & (1 << 30) != 0) {
            writePort(port, PORT_IS, is);
            return false;
        }
        asm volatile ("pause");
    }
    return false;
}

// ---- Query ----

pub fn getPortCount() u8 {
    return active_port_count;
}

pub fn isInitialized() bool {
    return ready;
}

pub fn getPortInfo(idx: u8) ?*const PortInfo {
    if (idx >= active_port_count) return null;
    return &port_info[idx];
}

// ---- Display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("AHCI SATA Controller:\n");
    vga.setColor(.light_grey, .black);

    if (!ready) {
        vga.write("  Not initialized (no controller found)\n");
        return;
    }

    vga.write("  PCI: 00:");
    printHex8(ahci_slot);
    vga.putChar('.');
    vga.putChar('0' + ahci_func);
    vga.write("  ABAR: 0x");
    printHex32(abar);
    vga.putChar('\n');

    vga.write("  Version: ");
    printDec(version_major);
    vga.putChar('.');
    printDec(version_minor);
    vga.write("  Cmd Slots: ");
    printDec(num_cmd_slots);
    vga.write("  Ports: ");
    printDec(active_port_count);
    vga.putChar('\n');

    vga.write("  Ports Implemented: 0x");
    printHex32(ports_impl);
    vga.putChar('\n');

    if (active_port_count == 0) {
        vga.write("  No active ports\n");
        return;
    }

    // ポート詳細
    var i: u8 = 0;
    while (i < active_port_count) : (i += 1) {
        const pi = &port_info[i];
        vga.write("  Port ");
        printDec(pi.port_num);
        vga.write(": ");
        vga.setColor(.light_cyan, .black);
        vga.write(deviceTypeName(pi.dev_type));
        vga.setColor(.light_grey, .black);

        if (pi.identified) {
            vga.write("  Model: ");
            printStr(&pi.model);
            vga.putChar('\n');

            vga.write("    Serial: ");
            printStr(&pi.serial_num);
            vga.write("  FW: ");
            printStr(&pi.firmware_rev);
            vga.putChar('\n');

            vga.write("    Capacity: ");
            const sectors = pi.lba_sectors;
            const mb = sectors / 2048; // sectors * 512 / (1024*1024)
            printDec64(mb);
            vga.write(" MB (");
            printDec64(sectors);
            vga.write(" sectors)\n");

            vga.write("    UDMA: ");
            if (pi.udma_supported) vga.write("Yes") else vga.write("No");
            vga.putChar('\n');
        } else {
            vga.write("  (not identified)\n");
        }
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
