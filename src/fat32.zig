// FAT32 ファイルシステムリーダー — ATA ディスクからファイルを読む

const ata = @import("ata.zig");
const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- BPB (BIOS Parameter Block) ----

const BPB = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    root_entry_count: u16, // FAT32 では 0
    total_sectors_16: u16,
    media_type: u8,
    fat_size_16: u16, // FAT32 では 0
    sectors_per_track: u16,
    num_heads: u16,
    hidden_sectors: u32,
    total_sectors_32: u32,
};

// ---- FAT32 拡張 BPB ----

const ExtBPB = struct {
    fat_size_32: u32,
    ext_flags: u16,
    fs_version: u16,
    root_cluster: u32,
    fs_info_sector: u16,
    backup_boot_sector: u16,
    volume_id: u32,
    volume_label: [11]u8,
    fs_type: [8]u8,
};

// ---- FSInfo 構造体 ----

const FSInfo = struct {
    free_cluster_count: u32,
    next_free_cluster: u32,
};

// ---- FAT32 エントリ定数 ----

const FAT32_EOC: u32 = 0x0FFFFFF8; // End of chain marker
const FAT32_FREE: u32 = 0x00000000;
const FAT32_BAD: u32 = 0x0FFFFFF7;
const FAT32_MASK: u32 = 0x0FFFFFFF; // 上位 4 ビットはマスク

// ---- LFN (Long Filename) 定数 ----

const LFN_ATTR: u8 = 0x0F;
const LFN_LAST_ENTRY: u8 = 0x40;
const MAX_LFN_LEN = 255;

// ---- グローバル状態 ----

var bpb: BPB = undefined;
var ext_bpb: ExtBPB = undefined;
var fs_info: FSInfo = undefined;
var data_start_sector: u32 = 0;
var initialized: bool = false;
var valid: bool = false;

var sector_buf: [512]u8 = undefined;
var fat_cache_sector: u32 = 0xFFFFFFFF;
var fat_cache: [512]u8 = undefined;

// ---- 初期化 ----

pub fn init() void {
    if (!ata.isPresent()) return;

    // ブートセクタ読み込み
    if (!ata.readSectors(0, 1, &sector_buf)) return;

    // ブートセクタ署名チェック
    if (sector_buf[510] != 0x55 or sector_buf[511] != 0xAA) {
        serial.write("[FAT32] no boot signature\n");
        return;
    }

    // BPB 解析
    bpb.bytes_per_sector = readU16(11);
    bpb.sectors_per_cluster = sector_buf[13];
    bpb.reserved_sectors = readU16(14);
    bpb.num_fats = sector_buf[16];
    bpb.root_entry_count = readU16(17);
    bpb.total_sectors_16 = readU16(19);
    bpb.media_type = sector_buf[21];
    bpb.fat_size_16 = readU16(22);
    bpb.sectors_per_track = readU16(24);
    bpb.num_heads = readU16(26);
    bpb.hidden_sectors = readU32(28);
    bpb.total_sectors_32 = readU32(32);

    // FAT32 判別: FAT16 の fat_size が 0 かつ root_entry_count が 0
    if (bpb.fat_size_16 != 0 or bpb.root_entry_count != 0) {
        serial.write("[FAT32] not a FAT32 volume (FAT16 detected)\n");
        return;
    }

    if (bpb.bytes_per_sector != 512 or bpb.sectors_per_cluster == 0) {
        serial.write("[FAT32] invalid parameters\n");
        return;
    }

    // FAT32 拡張 BPB
    ext_bpb.fat_size_32 = readU32(36);
    ext_bpb.ext_flags = readU16(40);
    ext_bpb.fs_version = readU16(42);
    ext_bpb.root_cluster = readU32(44);
    ext_bpb.fs_info_sector = readU16(48);
    ext_bpb.backup_boot_sector = readU16(50);
    ext_bpb.volume_id = readU32(67);
    @memcpy(&ext_bpb.volume_label, sector_buf[71..82]);
    @memcpy(&ext_bpb.fs_type, sector_buf[82..90]);

    if (ext_bpb.fat_size_32 == 0) {
        serial.write("[FAT32] invalid FAT size\n");
        return;
    }

    // データ領域の開始セクタ
    data_start_sector = bpb.reserved_sectors + @as(u32, bpb.num_fats) * ext_bpb.fat_size_32;

    // FSInfo セクタ読み込み
    fs_info.free_cluster_count = 0xFFFFFFFF;
    fs_info.next_free_cluster = 0xFFFFFFFF;
    if (ext_bpb.fs_info_sector > 0 and ext_bpb.fs_info_sector < bpb.reserved_sectors) {
        if (ata.readSectors(ext_bpb.fs_info_sector, 1, &sector_buf)) {
            // FSInfo 署名チェック
            if (readU32(0) == 0x41615252 and readU32(484) == 0x61417272) {
                fs_info.free_cluster_count = readU32(488);
                fs_info.next_free_cluster = readU32(492);
            }
        }
    }

    fat_cache_sector = 0xFFFFFFFF;
    initialized = true;
    valid = true;
    serial.write("[FAT32] initialized\n");
}

pub fn isValid() bool {
    return valid;
}

pub fn isInitialized() bool {
    return initialized;
}

// ---- クラスタ -> セクタ変換 ----

fn clusterToSector(cluster: u32) u32 {
    return data_start_sector + (cluster - 2) * @as(u32, bpb.sectors_per_cluster);
}

// ---- FAT テーブル読み取り ----

fn readFatEntry(cluster: u32) ?u32 {
    const fat_offset = cluster * 4;
    const fat_sector = bpb.reserved_sectors + fat_offset / 512;
    const offset: usize = @truncate(fat_offset % 512);

    // FAT キャッシュ
    if (fat_sector != fat_cache_sector) {
        if (!ata.readSectors(fat_sector, 1, &fat_cache)) return null;
        fat_cache_sector = fat_sector;
    }

    const entry = readU32From(&fat_cache, offset) & FAT32_MASK;
    return entry;
}

// ---- クラスタチェーン走査 ----

fn isEndOfChain(cluster: u32) bool {
    return cluster >= FAT32_EOC or cluster == 0;
}

fn getClusterChainLength(start_cluster: u32) usize {
    var cluster = start_cluster;
    var count: usize = 0;
    while (!isEndOfChain(cluster) and count < 1024) {
        count += 1;
        cluster = readFatEntry(cluster) orelse break;
    }
    return count;
}

// ---- ディレクトリ読み取り ----

pub fn listDir(cluster: u32) void {
    if (!initialized) return;

    vga.setColor(.yellow, .black);
    vga.write("NAME                             SIZE       TYPE\n");
    vga.setColor(.light_grey, .black);

    var cur_cluster = cluster;
    var lfn_buf: [MAX_LFN_LEN]u8 = undefined;
    var lfn_len: usize = 0;
    var has_lfn = false;

    while (!isEndOfChain(cur_cluster)) {
        const sector = clusterToSector(cur_cluster);
        var s: u8 = 0;
        while (s < bpb.sectors_per_cluster) : (s += 1) {
            if (!ata.readSectors(sector + @as(u32, s), 1, &sector_buf)) return;

            var e: usize = 0;
            while (e < 512) : (e += 32) {
                if (sector_buf[e] == 0) return; // ディレクトリ終端
                if (sector_buf[e] == 0xE5) { // 削除済み
                    has_lfn = false;
                    lfn_len = 0;
                    continue;
                }

                const attr = sector_buf[e + 11];

                // LFN エントリ処理
                if (attr == LFN_ATTR) {
                    const seq = sector_buf[e] & 0x3F;
                    const is_last = (sector_buf[e] & LFN_LAST_ENTRY) != 0;
                    if (is_last) {
                        lfn_len = 0;
                        has_lfn = true;
                    }
                    // LFN 文字を抽出 (UCS-2 -> ASCII)
                    extractLfnChars(sector_buf[e .. e + 32], seq, &lfn_buf, &lfn_len);
                    continue;
                }

                // . と .. はスキップ
                if (sector_buf[e] == '.' and (sector_buf[e + 1] == ' ' or sector_buf[e + 1] == '.')) {
                    has_lfn = false;
                    lfn_len = 0;
                    continue;
                }

                // ボリュームラベルはスキップ
                if (attr & 0x08 != 0) {
                    has_lfn = false;
                    lfn_len = 0;
                    continue;
                }

                // ファイル/ディレクトリ表示
                if (has_lfn and lfn_len > 0) {
                    vga.write(lfn_buf[0..lfn_len]);
                    var pad = @as(usize, 33) -| lfn_len;
                    while (pad > 0) : (pad -= 1) vga.putChar(' ');
                } else {
                    // 8.3 ファイル名
                    printShortName(sector_buf[e .. e + 11]);
                }

                const file_size = readU32From(&sector_buf, e + 28);
                const is_dir = (attr & 0x10) != 0;

                if (!is_dir) {
                    fmt.printDecPadded(file_size, 10);
                } else {
                    vga.write("         -");
                }
                vga.write("  ");
                if (is_dir) {
                    vga.setColor(.light_cyan, .black);
                    vga.write("<DIR>");
                    vga.setColor(.light_grey, .black);
                } else {
                    vga.write("<FILE>");
                }
                vga.putChar('\n');

                has_lfn = false;
                lfn_len = 0;
            }
        }
        cur_cluster = readFatEntry(cur_cluster) orelse break;
    }
}

// ---- ファイル読み取り ----

pub fn readFile(name: []const u8, buf: []u8) ?usize {
    if (!initialized) return null;

    // ルートディレクトリからファイルを検索
    const result = findFileInDir(ext_bpb.root_cluster, name) orelse return null;
    const start_cluster = result.cluster;
    const file_size = result.size;

    return readClusterChain(start_cluster, file_size, buf);
}

const FindResult = struct {
    cluster: u32,
    size: u32,
};

fn findFileInDir(dir_cluster: u32, name: []const u8) ?FindResult {
    var cur_cluster = dir_cluster;
    var lfn_buf: [MAX_LFN_LEN]u8 = undefined;
    var lfn_len: usize = 0;
    var has_lfn = false;

    // 8.3 フォーマットにも変換
    var fname83: [11]u8 = [_]u8{' '} ** 11;
    toFat83(name, &fname83);

    while (!isEndOfChain(cur_cluster)) {
        const sector = clusterToSector(cur_cluster);
        var s: u8 = 0;
        while (s < bpb.sectors_per_cluster) : (s += 1) {
            if (!ata.readSectors(sector + @as(u32, s), 1, &sector_buf)) return null;

            var e: usize = 0;
            while (e < 512) : (e += 32) {
                if (sector_buf[e] == 0) return null;
                if (sector_buf[e] == 0xE5) {
                    has_lfn = false;
                    lfn_len = 0;
                    continue;
                }

                const attr = sector_buf[e + 11];

                if (attr == LFN_ATTR) {
                    const is_last = (sector_buf[e] & LFN_LAST_ENTRY) != 0;
                    const seq = sector_buf[e] & 0x3F;
                    if (is_last) {
                        lfn_len = 0;
                        has_lfn = true;
                    }
                    extractLfnChars(sector_buf[e .. e + 32], seq, &lfn_buf, &lfn_len);
                    continue;
                }

                // マッチチェック (LFN)
                var match = false;
                if (has_lfn and lfn_len > 0) {
                    match = eqlCaseInsensitive(lfn_buf[0..lfn_len], name);
                }

                // マッチチェック (8.3)
                if (!match) {
                    match = matchName83(sector_buf[e .. e + 11], &fname83);
                }

                if (match) {
                    const cluster_hi: u32 = readU16From(&sector_buf, e + 20);
                    const cluster_lo: u32 = readU16From(&sector_buf, e + 26);
                    const cluster_num = (cluster_hi << 16) | cluster_lo;
                    const size = readU32From(&sector_buf, e + 28);
                    return FindResult{ .cluster = cluster_num, .size = size };
                }

                has_lfn = false;
                lfn_len = 0;
            }
        }
        cur_cluster = readFatEntry(cur_cluster) orelse break;
    }
    return null;
}

fn readClusterChain(start_cluster: u32, file_size: u32, buf: []u8) ?usize {
    var cluster = start_cluster;
    var bytes_read: usize = 0;
    const max_read = @min(@as(usize, file_size), buf.len);

    while (bytes_read < max_read) {
        if (isEndOfChain(cluster)) break;

        const sector = clusterToSector(cluster);
        var cs: u8 = 0;
        while (cs < bpb.sectors_per_cluster and bytes_read < max_read) : (cs += 1) {
            if (!ata.readSectors(sector + @as(u32, cs), 1, &sector_buf)) return null;
            const chunk = @min(512, max_read - bytes_read);
            @memcpy(buf[bytes_read .. bytes_read + chunk], sector_buf[0..chunk]);
            bytes_read += chunk;
        }

        cluster = readFatEntry(cluster) orelse break;
    }
    return bytes_read;
}

// ---- 情報表示 ----

pub fn printInfo() void {
    if (!initialized) {
        vga.write("FAT32: not initialized\n");
        return;
    }
    vga.setColor(.yellow, .black);
    vga.write("FAT32 Volume Information:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Volume Label:    ");
    printTrimmed(&ext_bpb.volume_label);
    vga.putChar('\n');

    vga.write("  FS Type:         ");
    printTrimmed(&ext_bpb.fs_type);
    vga.putChar('\n');

    vga.write("  Volume ID:       ");
    fmt.printHex32(ext_bpb.volume_id);
    vga.putChar('\n');

    vga.write("  Bytes/Sector:    ");
    fmt.printDec(bpb.bytes_per_sector);
    vga.putChar('\n');

    vga.write("  Sect/Cluster:    ");
    fmt.printDec(bpb.sectors_per_cluster);
    vga.putChar('\n');

    vga.write("  Reserved Sect:   ");
    fmt.printDec(bpb.reserved_sectors);
    vga.putChar('\n');

    vga.write("  FATs:            ");
    fmt.printDec(bpb.num_fats);
    vga.putChar('\n');

    vga.write("  FAT Size:        ");
    fmt.printDec(ext_bpb.fat_size_32);
    vga.write(" sectors\n");

    vga.write("  Root Cluster:    ");
    fmt.printDec(ext_bpb.root_cluster);
    vga.putChar('\n');

    vga.write("  Total Sectors:   ");
    fmt.printDec(bpb.total_sectors_32);
    vga.putChar('\n');

    vga.write("  Data Start:      ");
    fmt.printDec(data_start_sector);
    vga.putChar('\n');

    if (fs_info.free_cluster_count != 0xFFFFFFFF) {
        vga.write("  Free Clusters:   ");
        fmt.printDec(fs_info.free_cluster_count);
        vga.putChar('\n');

        // 空き容量計算
        const free_bytes = @as(usize, fs_info.free_cluster_count) * @as(usize, bpb.sectors_per_cluster) * 512;
        vga.write("  Free Space:      ");
        fmt.printSize(free_bytes);
        vga.putChar('\n');
    }

    if (ext_bpb.fs_info_sector > 0) {
        vga.write("  FSInfo Sector:   ");
        fmt.printDec(ext_bpb.fs_info_sector);
        vga.putChar('\n');
    }

    if (ext_bpb.backup_boot_sector > 0) {
        vga.write("  Backup Boot:     ");
        fmt.printDec(ext_bpb.backup_boot_sector);
        vga.putChar('\n');
    }
}

// ---- ルートディレクトリ一覧 ----

pub fn listRoot() void {
    if (!initialized) return;
    listDir(ext_bpb.root_cluster);
}

// ---- 空き容量 ----

pub fn freeSpace() usize {
    if (!initialized) return 0;
    if (fs_info.free_cluster_count == 0xFFFFFFFF) return 0;
    return @as(usize, fs_info.free_cluster_count) * @as(usize, bpb.sectors_per_cluster) * 512;
}

pub fn totalSpace() usize {
    if (!initialized) return 0;
    return @as(usize, bpb.total_sectors_32) * 512;
}

// ---- LFN ヘルパー ----

fn extractLfnChars(entry: []const u8, seq: u8, lfn_buf: *[MAX_LFN_LEN]u8, lfn_len: *usize) void {
    _ = seq;
    // LFN は逆順で格納されるため、先頭に追加
    // 簡易実装: 順序無視でバッファ末尾に追記し、後で並べ替えない
    // 各 LFN エントリは 13 UCS-2 文字を含む
    const offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

    for (offsets) |off| {
        if (off + 1 >= entry.len) break;
        const lo = entry[off];
        const hi = entry[off + 1];
        if (lo == 0xFF and hi == 0xFF) break; // padding
        if (lo == 0 and hi == 0) break; // terminator
        // ASCII のみサポート
        if (hi == 0 and lo >= 0x20 and lo < 0x7F) {
            if (lfn_len.* < MAX_LFN_LEN) {
                lfn_buf[lfn_len.*] = lo;
                lfn_len.* += 1;
            }
        }
    }
}

fn printShortName(name83: []const u8) void {
    // ファイル名部分 (スペースを除去)
    var name_end: usize = 8;
    while (name_end > 0 and name83[name_end - 1] == ' ') name_end -= 1;
    vga.write(name83[0..name_end]);

    // 拡張子部分
    var ext_end: usize = 11;
    while (ext_end > 8 and name83[ext_end - 1] == ' ') ext_end -= 1;
    if (ext_end > 8) {
        vga.putChar('.');
        vga.write(name83[8..ext_end]);
        // パディング
        const total = name_end + 1 + (ext_end - 8);
        var pad = @as(usize, 33) -| total;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    } else {
        var pad = @as(usize, 33) -| name_end;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
}

fn toFat83(name: []const u8, out: *[11]u8) void {
    var di: usize = 0;
    var in_ext = false;
    for (name) |c| {
        if (c == '.') {
            in_ext = true;
            di = 8;
            continue;
        }
        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (!in_ext and di < 8) {
            out[di] = upper;
            di += 1;
        } else if (in_ext and di < 11) {
            out[di] = upper;
            di += 1;
        }
    }
}

fn matchName83(a: []const u8, b: []const u8) bool {
    if (a.len < 11 or b.len < 11) return false;
    for (0..11) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn eqlCaseInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn printTrimmed(data: []const u8) void {
    var end = data.len;
    while (end > 0 and data[end - 1] == ' ') end -= 1;
    if (end > 0) vga.write(data[0..end]);
}

// ---- バイト読み取りヘルパー ----

fn readU16(offset: usize) u16 {
    return @as(u16, sector_buf[offset]) | (@as(u16, sector_buf[offset + 1]) << 8);
}

fn readU32(offset: usize) u32 {
    return @as(u32, sector_buf[offset]) |
        (@as(u32, sector_buf[offset + 1]) << 8) |
        (@as(u32, sector_buf[offset + 2]) << 16) |
        (@as(u32, sector_buf[offset + 3]) << 24);
}

fn readU16From(buf: []const u8, offset: usize) u16 {
    return @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
}

fn readU32From(buf: []const u8, offset: usize) u32 {
    return @as(u32, buf[offset]) |
        (@as(u32, buf[offset + 1]) << 8) |
        (@as(u32, buf[offset + 2]) << 16) |
        (@as(u32, buf[offset + 3]) << 24);
}
