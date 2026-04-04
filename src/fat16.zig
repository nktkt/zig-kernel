// FAT16 ファイルシステムリーダー — ATA ディスクからファイルを読む

const ata = @import("ata.zig");
const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

var bytes_per_sector: u16 = 0;
var sectors_per_cluster: u8 = 0;
var reserved_sectors: u16 = 0;
var num_fats: u8 = 0;
var root_entry_count: u16 = 0;
var fat_size: u16 = 0;
var root_dir_sector: u32 = 0;
var data_start_sector: u32 = 0;
var initialized: bool = false;

var sector_buf: [512]u8 = undefined;

pub fn init() void {
    if (!ata.isPresent()) return;

    // ブートセクタ読み込み
    if (!ata.readSectors(0, 1, &sector_buf)) return;

    // FAT16 パラメータ解析
    bytes_per_sector = readU16(11);
    sectors_per_cluster = sector_buf[13];
    reserved_sectors = readU16(14);
    num_fats = sector_buf[16];
    root_entry_count = readU16(17);
    fat_size = readU16(22);

    if (bytes_per_sector != 512 or sectors_per_cluster == 0 or fat_size == 0) {
        serial.write("[FAT16] invalid parameters\n");
        return;
    }

    root_dir_sector = reserved_sectors + @as(u32, num_fats) * fat_size;
    const root_dir_sectors = (@as(u32, root_entry_count) * 32 + 511) / 512;
    data_start_sector = root_dir_sector + root_dir_sectors;

    initialized = true;
    serial.write("[FAT16] initialized\n");
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn printInfo() void {
    if (!initialized) {
        vga.write("FAT16: not initialized\n");
        return;
    }
    vga.write("FAT16: cluster=");
    pmm.printNum(sectors_per_cluster);
    vga.write(" sectors, root=");
    pmm.printNum(root_entry_count);
    vga.write(" entries\n");

    // ルートディレクトリのファイル一覧
    vga.setColor(.yellow, .black);
    vga.write("NAME         SIZE\n");
    vga.setColor(.light_grey, .black);

    const root_sectors = (@as(u32, root_entry_count) * 32 + 511) / 512;
    var s: u32 = 0;
    while (s < root_sectors) : (s += 1) {
        if (!ata.readSectors(root_dir_sector + s, 1, &sector_buf)) break;
        var e: usize = 0;
        while (e < 512) : (e += 32) {
            if (sector_buf[e] == 0) return; // ディレクトリ終端
            if (sector_buf[e] == 0xE5) continue; // 削除済み
            const attr = sector_buf[e + 11];
            if (attr & 0x08 != 0 or attr & 0x10 != 0) continue; // ボリュームラベル/ディレクトリ
            // ファイル名 (8.3)
            vga.write(sector_buf[e .. e + 8]);
            vga.putChar('.');
            vga.write(sector_buf[e + 8 .. e + 11]);
            vga.write("  ");
            const size = readU32At(&sector_buf, e + 28);
            pmm.printNum(size);
            vga.putChar('\n');
        }
    }
}

pub fn readFile(name: []const u8, buf: *[2048]u8) ?usize {
    if (!initialized) return null;

    // 8.3 フォーマットに変換
    var fname83: [11]u8 = [_]u8{' '} ** 11;
    var di: usize = 0;
    var ext = false;
    for (name) |c| {
        if (c == '.') {
            ext = true;
            di = 8;
            continue;
        }
        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (!ext and di < 8) {
            fname83[di] = upper;
            di += 1;
        } else if (ext and di < 11) {
            fname83[di] = upper;
            di += 1;
        }
    }

    // ルートディレクトリを検索
    const root_sectors = (@as(u32, root_entry_count) * 32 + 511) / 512;
    var s: u32 = 0;
    while (s < root_sectors) : (s += 1) {
        if (!ata.readSectors(root_dir_sector + s, 1, &sector_buf)) return null;
        var e: usize = 0;
        while (e < 512) : (e += 32) {
            if (sector_buf[e] == 0) return null;
            if (sector_buf[e] == 0xE5) continue;

            if (matchName(sector_buf[e .. e + 11], &fname83)) {
                const cluster = readU16At(&sector_buf, e + 26);
                const size = readU32At(&sector_buf, e + 28);
                return readClusterChain(cluster, size, buf);
            }
        }
    }
    return null;
}

fn readClusterChain(start_cluster: u16, file_size: u32, buf: *[2048]u8) ?usize {
    var cluster = start_cluster;
    var bytes_read: usize = 0;
    const max_read = @min(file_size, 2048);

    while (bytes_read < max_read) {
        if (cluster < 2 or cluster >= 0xFFF8) break;

        const sector = data_start_sector + @as(u32, cluster - 2) * sectors_per_cluster;
        var cs: u8 = 0;
        while (cs < sectors_per_cluster and bytes_read < max_read) : (cs += 1) {
            if (!ata.readSectors(sector + cs, 1, &sector_buf)) return null;
            const chunk = @min(512, max_read - bytes_read);
            @memcpy(buf[bytes_read .. bytes_read + chunk], sector_buf[0..chunk]);
            bytes_read += chunk;
        }

        // FAT から次のクラスタを読む
        cluster = readFatEntry(cluster) orelse break;
    }
    return bytes_read;
}

fn readFatEntry(cluster: u16) ?u16 {
    const fat_offset = @as(u32, cluster) * 2;
    const fat_sector = reserved_sectors + fat_offset / 512;
    const offset: usize = @truncate(fat_offset % 512);

    if (!ata.readSectors(fat_sector, 1, &sector_buf)) return null;
    return readU16At(&sector_buf, offset);
}

// ---- 書き込みサポート ----

pub fn writeFile(name: []const u8, data: []const u8) bool {
    if (!initialized) return false;

    var fname83: [11]u8 = [_]u8{' '} ** 11;
    toFat83(name, &fname83);

    // ルートディレクトリでエントリを探す (既存 or 空きスロット)
    const root_sectors = (@as(u32, root_entry_count) * 32 + 511) / 512;
    var found_sector: u32 = 0;
    var found_offset: usize = 0;
    var found = false;
    var empty_sector: u32 = 0;
    var empty_offset: usize = 0;
    var has_empty = false;

    var s: u32 = 0;
    while (s < root_sectors) : (s += 1) {
        if (!ata.readSectors(root_dir_sector + s, 1, &sector_buf)) return false;
        var e: usize = 0;
        while (e < 512) : (e += 32) {
            if (sector_buf[e] == 0 or sector_buf[e] == 0xE5) {
                if (!has_empty) {
                    empty_sector = s;
                    empty_offset = e;
                    has_empty = true;
                }
                if (sector_buf[e] == 0) break;
                continue;
            }
            if (matchName(sector_buf[e .. e + 11], &fname83)) {
                // 既存: 古いクラスタを解放
                const old_cluster = readU16At(&sector_buf, e + 26);
                freeClusterChain(old_cluster);
                found_sector = s;
                found_offset = e;
                found = true;
            }
        }
        if (found) break;
    }

    // 新しいクラスタにデータを書き込み
    const cluster = allocCluster() orelse return false;
    const sector = data_start_sector + @as(u32, cluster - 2) * sectors_per_cluster;
    @memset(&sector_buf, 0);
    const write_len = @min(data.len, 512);
    @memcpy(sector_buf[0..write_len], data[0..write_len]);
    if (!ata.writeSectors(sector, 1, &sector_buf)) return false;

    // FAT エントリ更新 (EOF マーク)
    writeFatEntry(cluster, 0xFFFF);

    // ディレクトリエントリ更新
    const dir_s = if (found) found_sector else empty_sector;
    const dir_e = if (found) found_offset else empty_offset;
    if (!found and !has_empty) return false;

    if (!ata.readSectors(root_dir_sector + dir_s, 1, &sector_buf)) return false;
    @memcpy(sector_buf[dir_e .. dir_e + 11], &fname83);
    sector_buf[dir_e + 11] = 0x20; // Archive
    // 時間/日付 (固定値)
    writeU16At(&sector_buf, dir_e + 22, 0);
    writeU16At(&sector_buf, dir_e + 24, 0x5921); // 2024-09-01
    writeU16At(&sector_buf, dir_e + 26, cluster);
    writeU32At(&sector_buf, dir_e + 28, @truncate(data.len));
    return ata.writeSectors(root_dir_sector + dir_s, 1, &sector_buf);
}

pub fn deleteFile(name: []const u8) bool {
    if (!initialized) return false;

    var fname83: [11]u8 = [_]u8{' '} ** 11;
    toFat83(name, &fname83);

    const root_sectors = (@as(u32, root_entry_count) * 32 + 511) / 512;
    var s: u32 = 0;
    while (s < root_sectors) : (s += 1) {
        if (!ata.readSectors(root_dir_sector + s, 1, &sector_buf)) return false;
        var e: usize = 0;
        while (e < 512) : (e += 32) {
            if (sector_buf[e] == 0) return false;
            if (sector_buf[e] == 0xE5) continue;
            if (matchName(sector_buf[e .. e + 11], &fname83)) {
                const cluster = readU16At(&sector_buf, e + 26);
                freeClusterChain(cluster);
                sector_buf[e] = 0xE5; // 削除マーク
                return ata.writeSectors(root_dir_sector + s, 1, &sector_buf);
            }
        }
    }
    return false;
}

fn toFat83(name: []const u8, out: *[11]u8) void {
    var di: usize = 0;
    var ext = false;
    for (name) |c| {
        if (c == '.') {
            ext = true;
            di = 8;
            continue;
        }
        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (!ext and di < 8) {
            out[di] = upper;
            di += 1;
        } else if (ext and di < 11) {
            out[di] = upper;
            di += 1;
        }
    }
}

fn allocCluster() ?u16 {
    // FAT テーブルを走査して空きクラスタを探す
    const total_clusters: u16 = @truncate((@as(u32, fat_size) * 512) / 2);
    var c: u16 = 2;
    while (c < total_clusters) : (c += 1) {
        if ((readFatEntry(c) orelse continue) == 0) return c;
    }
    return null;
}

fn freeClusterChain(start: u16) void {
    var cluster = start;
    while (cluster >= 2 and cluster < 0xFFF8) {
        const next = readFatEntry(cluster) orelse break;
        writeFatEntry(cluster, 0);
        cluster = next;
    }
}

fn writeFatEntry(cluster: u16, value: u16) void {
    const fat_offset = @as(u32, cluster) * 2;
    const fat_sect = reserved_sectors + fat_offset / 512;
    const offset: usize = @truncate(fat_offset % 512);

    if (!ata.readSectors(fat_sect, 1, &sector_buf)) return;
    writeU16At(&sector_buf, offset, value);
    _ = ata.writeSectors(fat_sect, 1, &sector_buf);

    // 2nd FAT コピー更新
    if (num_fats > 1) {
        _ = ata.writeSectors(fat_sect + fat_size, 1, &sector_buf);
    }
}

fn writeU16At(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val);
    buf[offset + 1] = @truncate(val >> 8);
}

fn writeU32At(buf: []u8, offset: usize, val: u32) void {
    buf[offset] = @truncate(val);
    buf[offset + 1] = @truncate(val >> 8);
    buf[offset + 2] = @truncate(val >> 16);
    buf[offset + 3] = @truncate(val >> 24);
}

fn matchName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn readU16(offset: usize) u16 {
    return @as(u16, sector_buf[offset]) | (@as(u16, sector_buf[offset + 1]) << 8);
}

fn readU16At(buf: []const u8, offset: usize) u16 {
    return @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
}

fn readU32At(buf: []const u8, offset: usize) u32 {
    return @as(u32, buf[offset]) |
        (@as(u32, buf[offset + 1]) << 8) |
        (@as(u32, buf[offset + 2]) << 16) |
        (@as(u32, buf[offset + 3]) << 24);
}
