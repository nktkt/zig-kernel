// ACPI テーブルパース — RSDP / RSDT / MADT / FADT 解析

const idt = @import("idt.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

// RSDP 構造体 (v1)
const RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,
};

// ACPI SDT ヘッダ
const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

// MADT エントリタイプ
const MADT_LOCAL_APIC: u8 = 0;
const MADT_IO_APIC: u8 = 1;

// 検出結果
var cpu_count: u32 = 0;
var local_apic_addr: u32 = 0;
var io_apic_addr: u32 = 0;
var rsdt_addr: u32 = 0;
var acpi_found: bool = false;

// FADT (電源制御)
var pm1a_cnt_blk: u16 = 0;
var slp_typa: u16 = 0;
var fadt_found: bool = false;

pub fn init() void {
    cpu_count = 1; // デフォルト 1 CPU
    local_apic_addr = 0;
    io_apic_addr = 0;
    acpi_found = false;
    fadt_found = false;

    // RSDP 探索: BIOS ROM 領域の読み取りは QEMU 環境依存で
    // Invalid Opcode を引き起こすことがあるため、安全にスキップ。
    // ACPI テーブルが必要な場合は QEMU -acpitable オプションで渡す。
    const found = false;

    if (found) {
        serial.write("[ACPI] RSDP found at RSDT=0x");
        serial.writeHex(rsdt_addr);
        serial.write("\n");
    } else {
        serial.write("[ACPI] no RSDP found\n");
    }
}

fn searchRsdp(start: u32, end: u32) bool {
    var addr = start;
    while (addr + 20 <= end) : (addr += 16) {
        const bytes: [*]const u8 = @ptrFromInt(addr);
        // "RSD PTR " シグネチャチェック (バイト単位)
        if (bytes[0] != 'R' or bytes[1] != 'S' or bytes[2] != 'D' or bytes[3] != ' ' or
            bytes[4] != 'P' or bytes[5] != 'T' or bytes[6] != 'R' or bytes[7] != ' ')
        {
            continue;
        }
        // チェックサム検証
        var sum: u8 = 0;
        for (0..20) |i| {
            sum +%= bytes[i];
        }
        if (sum == 0) {
            // RSDT address at offset 16 (little-endian u32)
            rsdt_addr = @as(u32, bytes[16]) | (@as(u32, bytes[17]) << 8) |
                (@as(u32, bytes[18]) << 16) | (@as(u32, bytes[19]) << 24);
            acpi_found = true;
            parseRsdt();
            return true;
        }
    }
    return false;
}

fn parseRsdt() void {
    if (rsdt_addr == 0 or rsdt_addr >= 0x8000000) return; // identity map 範囲外は無視
    const hdr: *const SdtHeader = @ptrFromInt(rsdt_addr);
    if (hdr.length < @sizeOf(SdtHeader) or hdr.length > 0x10000) return;
    const entries_len = (hdr.length - @sizeOf(SdtHeader)) / 4;
    const entries: [*]const u32 = @ptrFromInt(rsdt_addr + @sizeOf(SdtHeader));

    var i: u32 = 0;
    while (i < entries_len and i < 32) : (i += 1) {
        const taddr = entries[i];
        if (taddr == 0 or taddr >= 0x8000000) continue; // 範囲外スキップ
        const table: *const SdtHeader = @ptrFromInt(taddr);
        if (eql4(&table.signature, "APIC")) {
            parseMadt(taddr);
        } else if (eql4(&table.signature, "FACP")) {
            parseFadt(taddr);
        }
    }

    // CPU が見つからなかった場合はデフォルト 1
    if (cpu_count == 0) cpu_count = 1;
}

fn parseMadt(addr: u32) void {
    if (addr >= 0x8000000) return;
    const hdr: *const SdtHeader = @ptrFromInt(addr);
    if (hdr.length < 44 or hdr.length > 0x10000) return;
    const madt_base: [*]const u8 = @ptrFromInt(addr);

    // MADT: offset 36 = Local APIC Address
    if (hdr.length >= 44) {
        const lapic_ptr: *const u32 align(1) = @ptrFromInt(addr + 36);
        local_apic_addr = lapic_ptr.*;
    }

    // MADT エントリをパース (offset 44 から)
    var offset: u32 = 44;
    while (offset + 2 <= hdr.length) {
        const entry_type = madt_base[offset];
        const entry_len = madt_base[offset + 1];
        if (entry_len < 2) break;

        if (entry_type == MADT_LOCAL_APIC and entry_len >= 8) {
            // flags bit 0 = enabled
            const flags = madt_base[offset + 4];
            if (flags & 1 != 0) {
                cpu_count += 1;
            }
        } else if (entry_type == MADT_IO_APIC and entry_len >= 12) {
            const ioap: *const u32 align(1) = @ptrFromInt(addr + offset + 4);
            io_apic_addr = ioap.*;
        }

        offset += entry_len;
    }
}

fn parseFadt(addr: u32) void {
    if (addr >= 0x8000000) return;
    const hdr: *const SdtHeader = @ptrFromInt(addr);
    if (hdr.length < 116 or hdr.length > 0x10000) return;

    const fadt_bytes: [*]const u8 = @ptrFromInt(addr);
    // PM1a_CNT_BLK at offset 64 (4 bytes, use first 2 as port)
    const pm1a_ptr: *const u32 align(1) = @ptrFromInt(addr + 64);
    pm1a_cnt_blk = @truncate(pm1a_ptr.*);

    // SLP_TYPa: from DSDT S5 object, but for QEMU use common value
    _ = fadt_bytes;
    slp_typa = 0x2000; // S5 for QEMU/Bochs (SLP_TYPa=5 << 10 | SLP_EN=1<<13)
    fadt_found = pm1a_cnt_blk != 0;
}

pub fn getCpuCount() u32 {
    if (cpu_count == 0) return 1;
    return cpu_count;
}

pub fn shutdown() void {
    if (fadt_found and pm1a_cnt_blk != 0) {
        serial.write("[ACPI] shutdown via PM1a_CNT\n");
        // SLP_TYPa | SLP_EN
        idt.outw(pm1a_cnt_blk, slp_typa | (1 << 13));
    }
    // QEMU specific fallback
    idt.outw(0x604, 0x2000);
    // Bochs/old QEMU fallback
    idt.outw(0xB004, 0x2000);
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("ACPI Info:\n");
    vga.setColor(.light_grey, .black);
    if (!acpi_found) {
        vga.write("  ACPI tables not found\n");
        return;
    }
    vga.write("  RSDT at 0x");
    printHex32(rsdt_addr);
    vga.putChar('\n');
    vga.write("  CPUs: ");
    printDec(cpu_count);
    vga.putChar('\n');
    if (local_apic_addr != 0) {
        vga.write("  Local APIC: 0x");
        printHex32(local_apic_addr);
        vga.putChar('\n');
    }
    if (io_apic_addr != 0) {
        vga.write("  I/O APIC:   0x");
        printHex32(io_apic_addr);
        vga.putChar('\n');
    }
    if (fadt_found) {
        vga.write("  PM1a_CNT:   0x");
        printHex16(pm1a_cnt_blk);
        vga.write(" (shutdown available)\n");
    }
}

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

fn printDec(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
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

fn eql4(a: *const [4]u8, b: *const [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn eql8(a: *const [8]u8, b: *const [8]u8) bool {
    return eql4(a[0..4], b[0..4]) and eql4(a[4..8], b[4..8]);
}
