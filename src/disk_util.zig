// ディスクユーティリティ — セクタ操作とパーティションテーブル解析

const ata = @import("ata.zig");
const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");
const idt = @import("idt.zig");

// ---- ディスク統計 ----

var stat_reads: u32 = 0;
var stat_writes: u32 = 0;
var stat_errors: u32 = 0;
var stat_bytes_read: u32 = 0;
var stat_bytes_written: u32 = 0;

// ---- セクタ操作 ----

pub fn readSector(lba: u32, buf: *[512]u8) bool {
    if (!ata.isPresent()) {
        stat_errors += 1;
        return false;
    }
    const result = ata.readSectors(lba, 1, buf);
    if (result) {
        stat_reads += 1;
        stat_bytes_read += 512;
    } else {
        stat_errors += 1;
    }
    return result;
}

pub fn writeSector(lba: u32, data: *const [512]u8) bool {
    if (!ata.isPresent()) {
        stat_errors += 1;
        return false;
    }
    const result = ata.writeSectors(lba, 1, data);
    if (result) {
        stat_writes += 1;
        stat_bytes_written += 512;
    } else {
        stat_errors += 1;
    }
    return result;
}

// ---- セクタダンプ ----

pub fn dumpSector(lba: u32) void {
    var buf: [512]u8 = undefined;
    if (!readSector(lba, &buf)) {
        vga.setColor(.light_red, .black);
        vga.write("Error reading sector ");
        fmt.printDec(lba);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
        return;
    }

    vga.setColor(.yellow, .black);
    vga.write("Sector ");
    fmt.printDec(lba);
    vga.write(" (LBA 0x");
    fmt.printHex32(lba);
    vga.write("):\n");
    vga.setColor(.light_grey, .black);

    // 先頭 256 バイトのみ表示 (VGA の表示制限)
    const display_len: usize = @min(256, 512);
    fmt.hexdump(buf[0..display_len], @as(usize, lba) * 512);

    if (display_len < 512) {
        vga.setColor(.dark_grey, .black);
        vga.write("... (256 bytes shown of 512)\n");
        vga.setColor(.light_grey, .black);
    }
}

// ---- セクタフィル ----

pub fn fillSector(lba: u32, byte: u8) bool {
    var buf: [512]u8 = undefined;
    @memset(&buf, byte);
    return writeSector(lba, &buf);
}

// ---- セクタコピ��� ----

pub fn copySectors(src_lba: u32, dst_lba: u32, count: u32) bool {
    var buf: [512]u8 = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (!readSector(src_lba + i, &buf)) return false;
        if (!writeSector(dst_lba + i, &buf)) return false;
    }
    return true;
}

// ---- セクタ比較 ----

pub fn compareSectors(lba1: u32, lba2: u32) bool {
    var buf1: [512]u8 = undefined;
    var buf2: [512]u8 = undefined;
    if (!readSector(lba1, &buf1)) return false;
    if (!readSector(lba2, &buf2)) return false;

    for (&buf1, &buf2) |a, b| {
        if (a != b) return false;
    }
    return true;
}

// ---- MBR パーティション ----

pub const MbrPartition = struct {
    status: u8, // 0x80 = active, 0x00 = inactive
    type_id: u8,
    start_lba: u32,
    size_sectors: u32,
    start_chs: [3]u8,
    end_chs: [3]u8,
    present: bool,
};

pub fn readMbr() [4]MbrPartition {
    var partitions: [4]MbrPartition = undefined;

    for (&partitions) |*p| {
        p.present = false;
        p.status = 0;
        p.type_id = 0;
        p.start_lba = 0;
        p.size_sectors = 0;
        p.start_chs = [_]u8{ 0, 0, 0 };
        p.end_chs = [_]u8{ 0, 0, 0 };
    }

    var buf: [512]u8 = undefined;
    if (!readSector(0, &buf)) return partitions;

    // MBR 署名チェック
    if (buf[510] != 0x55 or buf[511] != 0xAA) {
        serial.write("[DISK] no MBR signature\n");
        return partitions;
    }

    // パーティションテーブルは 446 から 4 エントリ x 16 バイト
    for (0..4) |i| {
        const offset = 446 + i * 16;
        partitions[i].status = buf[offset];
        partitions[i].start_chs = .{ buf[offset + 1], buf[offset + 2], buf[offset + 3] };
        partitions[i].type_id = buf[offset + 4];
        partitions[i].end_chs = .{ buf[offset + 5], buf[offset + 6], buf[offset + 7] };
        partitions[i].start_lba = readU32(buf[offset + 8 .. offset + 12]);
        partitions[i].size_sectors = readU32(buf[offset + 12 .. offset + 16]);
        partitions[i].present = partitions[i].type_id != 0;
    }

    return partitions;
}

pub fn printPartitions() void {
    vga.setColor(.yellow, .black);
    vga.write("Partition Table (MBR):\n");
    vga.write("#  STATUS  TYPE                 START LBA   SIZE (sectors)\n");
    vga.setColor(.light_grey, .black);

    const parts = readMbr();
    var found = false;

    for (parts, 0..) |p, i| {
        if (!p.present) continue;
        found = true;

        fmt.printDec(i + 1);
        vga.write("  ");

        // Status
        if (p.status == 0x80) {
            vga.setColor(.light_green, .black);
            vga.write("Active  ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("Inact   ");
        }
        vga.setColor(.light_grey, .black);

        // Type
        const type_name = getPartitionType(p.type_id);
        vga.write(type_name);
        var pad = @as(usize, 21) -| type_name.len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');

        // Start LBA
        fmt.printDecPadded(p.start_lba, 11);
        vga.write("  ");

        // Size
        fmt.printDecPadded(p.size_sectors, 14);
        vga.write(" (");
        // サイズを MB で表示
        const size_mb = (@as(u64, p.size_sectors) * 512) / (1024 * 1024);
        fmt.printDec(@truncate(size_mb));
        vga.write(" MB)");
        vga.putChar('\n');
    }

    if (!found) {
        vga.write("  No partitions found\n");
    }
}

// ---- パーティションタイプ名 ----

pub fn getPartitionType(type_byte: u8) []const u8 {
    return switch (type_byte) {
        0x00 => "Empty",
        0x01 => "FAT12",
        0x04 => "FAT16 (<32MB)",
        0x05 => "Extended",
        0x06 => "FAT16 (>32MB)",
        0x07 => "NTFS/HPFS",
        0x0B => "FAT32 (CHS)",
        0x0C => "FAT32 (LBA)",
        0x0E => "FAT16 (LBA)",
        0x0F => "Extended (LBA)",
        0x11 => "Hidden FAT12",
        0x14 => "Hidden FAT16",
        0x1B => "Hidden FAT32",
        0x1C => "Hidden FAT32 LBA",
        0x1E => "Hidden FAT16 LBA",
        0x27 => "WinRE",
        0x42 => "Dynamic Disk",
        0x82 => "Linux swap",
        0x83 => "Linux",
        0x85 => "Linux extended",
        0x8E => "Linux LVM",
        0xA5 => "FreeBSD",
        0xA6 => "OpenBSD",
        0xA9 => "NetBSD",
        0xAF => "MacOS HFS+",
        0xBE => "Solaris boot",
        0xBF => "Solaris",
        0xEE => "GPT Protective",
        0xEF => "EFI System",
        0xFD => "Linux RAID",
        else => "Unknown",
    };
}

// ---- ディスク統計表示 ----

pub fn printDiskStats() void {
    vga.setColor(.yellow, .black);
    vga.write("Disk I/O Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Reads:          ");
    fmt.printDec(stat_reads);
    vga.putChar('\n');

    vga.write("  Writes:         ");
    fmt.printDec(stat_writes);
    vga.putChar('\n');

    vga.write("  Errors:         ");
    if (stat_errors > 0) {
        vga.setColor(.light_red, .black);
    }
    fmt.printDec(stat_errors);
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    vga.write("  Bytes read:     ");
    fmt.printSize(stat_bytes_read);
    vga.putChar('\n');

    vga.write("  Bytes written:  ");
    fmt.printSize(stat_bytes_written);
    vga.putChar('\n');

    // 合計
    vga.write("  Total I/O:      ");
    fmt.printSize(stat_bytes_read + stat_bytes_written);
    vga.putChar('\n');
}

pub fn resetStats() void {
    stat_reads = 0;
    stat_writes = 0;
    stat_errors = 0;
    stat_bytes_read = 0;
    stat_bytes_written = 0;
}

// ---- S.M.A.R.T. ステータス (簡易) ----

pub fn smartStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("S.M.A.R.T. Status:\n");
    vga.setColor(.light_grey, .black);

    if (!ata.isPresent()) {
        vga.write("  No disk detected\n");
        return;
    }

    // ATA ステータスレジスタを読み取り
    const status = idt.inb(0x1F7);

    vga.write("  Status register: 0x");
    fmt.printHex8(status);
    vga.putChar('\n');

    vga.write("  BSY:  ");
    if (status & 0x80 != 0) {
        vga.setColor(.yellow, .black);
        vga.write("Yes");
    } else {
        vga.setColor(.light_green, .black);
        vga.write("No");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    vga.write("  DRDY: ");
    if (status & 0x40 != 0) {
        vga.setColor(.light_green, .black);
        vga.write("Yes");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("No");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    vga.write("  DRQ:  ");
    if (status & 0x08 != 0) {
        vga.write("Yes");
    } else {
        vga.write("No");
    }
    vga.putChar('\n');

    vga.write("  ERR:  ");
    if (status & 0x01 != 0) {
        vga.setColor(.light_red, .black);
        vga.write("Yes");
        // エラーレジスタも読む
        const err = idt.inb(0x1F1);
        vga.setColor(.light_grey, .black);
        vga.write(" (0x");
        fmt.printHex8(err);
        vga.write(")");
    } else {
        vga.setColor(.light_green, .black);
        vga.write("No");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    vga.write("  DF:   ");
    if (status & 0x20 != 0) {
        vga.setColor(.light_red, .black);
        vga.write("Device Fault!");
    } else {
        vga.setColor(.light_green, .black);
        vga.write("OK");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    // 全体判定
    vga.write("\n  Overall: ");
    if (status & 0x21 != 0) {
        vga.setColor(.light_red, .black);
        vga.write("FAIL");
    } else if (status & 0x40 != 0) {
        vga.setColor(.light_green, .black);
        vga.write("PASSED");
    } else {
        vga.setColor(.yellow, .black);
        vga.write("UNKNOWN");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');
}

// ---- セクタ検索 (バイトパターン) ----

pub fn searchSector(lba: u32, pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    var buf: [512]u8 = undefined;
    if (!readSector(lba, &buf)) return false;

    var i: usize = 0;
    while (i + pattern.len <= 512) : (i += 1) {
        var found = true;
        for (pattern, 0..) |p, j| {
            if (buf[i + j] != p) {
                found = false;
                break;
            }
        }
        if (found) return true;
    }
    return false;
}

// ---- バイト読み取りヘルパー ----

fn readU32(data: []const u8) u32 {
    return @as(u32, data[0]) |
        (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 24);
}
