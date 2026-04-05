// ext2 ファイルシステム (読み取り専用) — スーパーブロック / inode / ディレクトリ解析

const ata = @import("ata.zig");
const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

// ext2 マジックナンバー
const EXT2_MAGIC: u16 = 0xEF53;

// スーパーブロック (1024 バイト, オフセット 1024 から)
const Superblock = extern struct {
    s_inodes_count: u32,
    s_blocks_count: u32,
    s_r_blocks_count: u32,
    s_free_blocks_count: u32,
    s_free_inodes_count: u32,
    s_first_data_block: u32,
    s_log_block_size: u32,
    s_log_frag_size: u32,
    s_blocks_per_group: u32,
    s_frags_per_group: u32,
    s_inodes_per_group: u32,
    s_mtime: u32,
    s_wtime: u32,
    s_mnt_count: u16,
    s_max_mnt_count: u16,
    s_magic: u16,
    // ... (残りは省略)
};

// inode 構造体 (128 バイト)
const Inode = extern struct {
    i_mode: u16,
    i_uid: u16,
    i_size: u32,
    i_atime: u32,
    i_ctime: u32,
    i_mtime: u32,
    i_dtime: u32,
    i_gid: u16,
    i_links_count: u16,
    i_blocks: u32,
    i_flags: u32,
    i_osd1: u32,
    i_block: [15]u32, // ブロックポインタ (直接12 + 間接3)
    // ...残りは省略
};

// ディレクトリエントリ
const DirEntry = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
    // name follows
};

// 解析結果
var valid: bool = false;
var block_size: u32 = 0;
var inode_size: u32 = 128;
var inodes_per_group: u32 = 0;
var blocks_per_group: u32 = 0;
var first_data_block: u32 = 0;
var total_inodes: u32 = 0;
var total_blocks: u32 = 0;
var free_blocks: u32 = 0;
var free_inodes: u32 = 0;

// ブロックグループディスクリプタ (BGD) — グループ0
var bgd_block_bitmap: u32 = 0;
var bgd_inode_bitmap: u32 = 0;
var bgd_inode_table: u32 = 0;

// エイリアス
var s_blocks_per_group: u32 = 0;
var s_inodes_per_group: u32 = 0;
var s_first_data_block: u32 = 0;

// セクタバッファ
var sector_buf: [4096]u8 align(4) = undefined;

pub fn init() void {
    valid = false;
    if (!ata.isPresent()) return;

    // スーパーブロックはオフセット 1024 (セクタ 2-3) にある
    if (!ata.readSectors(2, 2, &sector_buf)) return;

    // マジックナンバー確認 (スーパーブロック内オフセット 56)
    const magic = readU16(&sector_buf, 56);
    if (magic != EXT2_MAGIC) {
        serial.write("[EXT2] not ext2 (magic=0x");
        serial.writeHex(magic);
        serial.write(")\n");
        return;
    }

    total_inodes = readU32(&sector_buf, 0);
    total_blocks = readU32(&sector_buf, 4);
    free_blocks = readU32(&sector_buf, 12);
    free_inodes = readU32(&sector_buf, 16);
    first_data_block = readU32(&sector_buf, 20);

    const log_bs = readU32(&sector_buf, 24);
    block_size = @as(u32, 1024) << @truncate(log_bs);

    blocks_per_group = readU32(&sector_buf, 32);
    inodes_per_group = readU32(&sector_buf, 40);

    // inode size (rev >= 1 の場合 offset 88、そうでなければ 128)
    const rev = readU32(&sector_buf, 76);
    if (rev >= 1) {
        inode_size = readU16(&sector_buf, 88);
    } else {
        inode_size = 128;
    }

    // エイリアス設定
    s_blocks_per_group = blocks_per_group;
    s_inodes_per_group = inodes_per_group;
    s_first_data_block = first_data_block;

    // ブロックグループディスクリプタテーブル (BGD) を読む
    // BGD はスーパーブロックの次のブロックにある
    const bgd_block = if (block_size == 1024) @as(u32, 2) else @as(u32, 1);
    var bgd_buf: [4096]u8 align(4) = undefined;
    if (readBlock(bgd_block, &bgd_buf)) {
        bgd_block_bitmap = readU32(&bgd_buf, 0);
        bgd_inode_bitmap = readU32(&bgd_buf, 4);
        bgd_inode_table = readU32(&bgd_buf, 8);
    }

    valid = true;
    serial.write("[EXT2] detected, block_size=");
    serial.writeHex(block_size);
    serial.write("\n");
}

pub fn isValid() bool {
    return valid;
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("ext2 Filesystem:\n");
    vga.setColor(.light_grey, .black);
    if (!valid) {
        vga.write("  Not detected\n");
        return;
    }
    vga.write("  Block size:      ");
    pmm.printNum(block_size);
    vga.write(" bytes\n");
    vga.write("  Inode size:      ");
    pmm.printNum(inode_size);
    vga.write(" bytes\n");
    vga.write("  Total inodes:    ");
    pmm.printNum(total_inodes);
    vga.putChar('\n');
    vga.write("  Total blocks:    ");
    pmm.printNum(total_blocks);
    vga.putChar('\n');
    vga.write("  Free blocks:     ");
    pmm.printNum(free_blocks);
    vga.putChar('\n');
    vga.write("  Free inodes:     ");
    pmm.printNum(free_inodes);
    vga.putChar('\n');
    vga.write("  Inodes/group:    ");
    pmm.printNum(inodes_per_group);
    vga.putChar('\n');
    vga.write("  Blocks/group:    ");
    pmm.printNum(blocks_per_group);
    vga.putChar('\n');
}

/// inode 番号からinode データを読む
pub fn readInode(ino: u32) ?Inode {
    if (!valid or ino == 0) return null;

    const group = (ino - 1) / inodes_per_group;
    const index = (ino - 1) % inodes_per_group;

    // ブロックグループ記述子テーブル (スーパーブロックの次のブロック)
    const bgdt_block = first_data_block + 1;
    const bgdt_sector = bgdt_block * (block_size / 512);

    var bgd_buf: [512]u8 align(4) = undefined;
    const bgd_sector_offset = (group * 32) / 512;
    if (!ata.readSectors(@truncate(bgdt_sector + bgd_sector_offset), 1, &bgd_buf)) return null;

    const bgd_offset = (group * 32) % 512;
    const inode_table_block = readU32(&bgd_buf, bgd_offset + 8);

    // inode テーブルからinode を読む
    const inode_byte_offset = index * inode_size;
    const inode_sector = inode_table_block * (block_size / 512) + inode_byte_offset / 512;
    const inode_local_offset = inode_byte_offset % 512;

    var ino_buf: [1024]u8 align(4) = undefined;
    if (!ata.readSectors(@truncate(inode_sector), 2, &ino_buf)) return null;

    // inode 構造体を手動で読み取り
    const base = inode_local_offset;
    var inode: Inode = undefined;
    inode.i_mode = readU16(&ino_buf, base);
    inode.i_uid = readU16(&ino_buf, base + 2);
    inode.i_size = readU32(&ino_buf, base + 4);
    inode.i_atime = readU32(&ino_buf, base + 8);
    inode.i_ctime = readU32(&ino_buf, base + 12);
    inode.i_mtime = readU32(&ino_buf, base + 16);
    inode.i_dtime = readU32(&ino_buf, base + 20);
    inode.i_gid = readU16(&ino_buf, base + 24);
    inode.i_links_count = readU16(&ino_buf, base + 26);
    inode.i_blocks = readU32(&ino_buf, base + 28);
    inode.i_flags = readU32(&ino_buf, base + 32);
    inode.i_osd1 = readU32(&ino_buf, base + 36);
    for (0..15) |i| {
        inode.i_block[i] = readU32(&ino_buf, base + 40 + i * 4);
    }
    return inode;
}

/// ブロックをセクタバッファに読む
fn readBlock(block_num: u32, buf: [*]u8) bool {
    if (block_num == 0) return false;
    const sector = block_num * (block_size / 512);
    const count: u8 = @truncate(block_size / 512);
    return ata.readSectors(@truncate(sector), count, buf);
}

/// ルートディレクトリ (inode 2) を表示
pub fn listRoot() void {
    readDir(2);
}

/// ディレクトリの中身を表示
pub fn readDir(ino: u32) void {
    const inode = readInode(ino) orelse {
        vga.write("  Cannot read inode\n");
        return;
    };

    // 直接ブロックのみ走査
    var block_idx: usize = 0;
    while (block_idx < 12 and inode.i_block[block_idx] != 0) : (block_idx += 1) {
        var blk_buf: [4096]u8 align(4) = undefined;
        if (!readBlock(inode.i_block[block_idx], &blk_buf)) continue;

        var off: usize = 0;
        while (off + 8 <= block_size) {
            const d_inode = readU32(&blk_buf, off);
            const rec_len = readU16(&blk_buf, off + 4);
            const name_len = blk_buf[off + 6];
            const file_type = blk_buf[off + 7];

            if (rec_len == 0) break;
            if (d_inode != 0 and name_len > 0 and off + 8 + name_len <= block_size) {
                // タイプ表示
                if (file_type == 2) {
                    vga.setColor(.light_cyan, .black);
                    vga.write("dir   ");
                } else {
                    vga.setColor(.light_grey, .black);
                    vga.write("file  ");
                }
                vga.write(blk_buf[off + 8 .. off + 8 + name_len]);
                vga.putChar('\n');
            }
            off += rec_len;
        }
    }
}

/// ファイル名でルートディレクトリ内を検索して読む
pub fn readFile(name: []const u8, buf: []u8) ?usize {
    if (!valid) return null;

    // ルートディレクトリ (inode 2) を検索
    const root = readInode(2) orelse return null;
    const target_ino = findInDir(&root, name) orelse return null;
    return readFileData(target_ino, buf);
}

fn findInDir(inode: *const Inode, name: []const u8) ?u32 {
    var block_idx: usize = 0;
    while (block_idx < 12 and inode.i_block[block_idx] != 0) : (block_idx += 1) {
        var blk_buf: [4096]u8 align(4) = undefined;
        if (!readBlock(inode.i_block[block_idx], &blk_buf)) continue;

        var off: usize = 0;
        while (off + 8 <= block_size) {
            const d_inode = readU32(&blk_buf, off);
            const rec_len = readU16(&blk_buf, off + 4);
            const name_len = blk_buf[off + 6];

            if (rec_len == 0) break;
            if (d_inode != 0 and name_len == name.len and off + 8 + name_len <= block_size) {
                if (eql(blk_buf[off + 8 .. off + 8 + name_len], name)) {
                    return d_inode;
                }
            }
            off += rec_len;
        }
    }
    return null;
}

/// inode のデータを読む (直接ブロック + 単間接ブロック)
pub fn readFileData(ino: u32, buf: []u8) ?usize {
    const inode = readInode(ino) orelse return null;
    const size = @min(inode.i_size, @as(u32, @truncate(buf.len)));
    var read_total: usize = 0;

    // 直接ブロック (0-11)
    var i: usize = 0;
    while (i < 12 and inode.i_block[i] != 0 and read_total < size) : (i += 1) {
        var blk_buf: [4096]u8 align(4) = undefined;
        if (!readBlock(inode.i_block[i], &blk_buf)) break;
        const copy_len = @min(block_size, size - @as(u32, @truncate(read_total)));
        @memcpy(buf[read_total .. read_total + copy_len], blk_buf[0..copy_len]);
        read_total += copy_len;
    }

    // 単間接ブロック (i_block[12])
    if (read_total < size and inode.i_block[12] != 0) {
        var indirect_buf: [4096]u8 align(4) = undefined;
        if (readBlock(inode.i_block[12], &indirect_buf)) {
            const ptrs = block_size / 4;
            var j: usize = 0;
            while (j < ptrs and read_total < size) : (j += 1) {
                const blk = readU32(&indirect_buf, j * 4);
                if (blk == 0) break;
                var blk_buf: [4096]u8 align(4) = undefined;
                if (!readBlock(blk, &blk_buf)) break;
                const copy_len = @min(block_size, size - @as(u32, @truncate(read_total)));
                @memcpy(buf[read_total .. read_total + copy_len], blk_buf[0..copy_len]);
                read_total += copy_len;
            }
        }
    }

    return read_total;
}

// ---- ユーティリティ ----

fn readU16(buf: [*]const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn readU32(buf: [*]const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ---- 書き込みサポート ----

fn writeBlock(block_num: u32, buf: *const [4096]u8) bool {
    if (block_size == 0 or block_num == 0) return false;
    const sector = block_num * (block_size / 512);
    return ata.writeSectors(sector, @truncate(block_size / 512), buf);
}

/// ブロックビットマップから空きブロックを割り当て
fn allocBlock() ?u32 {
    if (!valid) return null;
    // ブロックグループ0のビットマップだけ探索 (簡易版)
    var bitmap_buf: [4096]u8 align(4) = undefined;
    if (!readBlock(bgd_block_bitmap, &bitmap_buf)) return null;

    var bit: u32 = 0;
    while (bit < s_blocks_per_group) : (bit += 1) {
        const byte_idx = bit / 8;
        const bit_idx: u3 = @truncate(bit % 8);
        if (byte_idx >= block_size) break;
        if (bitmap_buf[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
            // 空きブロック発見 → マーク
            bitmap_buf[byte_idx] |= @as(u8, 1) << bit_idx;
            if (!writeBlock(bgd_block_bitmap, &bitmap_buf)) return null;
            return s_first_data_block + bit;
        }
    }
    return null;
}

/// inode ビットマップから空き inode を割り当て
fn allocInode() ?u32 {
    if (!valid) return null;
    var bitmap_buf: [4096]u8 align(4) = undefined;
    if (!readBlock(bgd_inode_bitmap, &bitmap_buf)) return null;

    var bit: u32 = 0;
    while (bit < s_inodes_per_group) : (bit += 1) {
        const byte_idx = bit / 8;
        const bit_idx: u3 = @truncate(bit % 8);
        if (byte_idx >= block_size) break;
        if (bitmap_buf[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
            bitmap_buf[byte_idx] |= @as(u8, 1) << bit_idx;
            if (!writeBlock(bgd_inode_bitmap, &bitmap_buf)) return null;
            return bit + 1; // inode 番号は 1-based
        }
    }
    return null;
}

/// inode をディスクに書き戻す
fn writeInode(ino: u32, inode_data: [128]u8) bool {
    if (!valid or ino == 0) return false;
    const idx = ino - 1;
    const group = idx / s_inodes_per_group;
    _ = group;
    const local_idx = idx % s_inodes_per_group;
    const inode_block = bgd_inode_table + (local_idx * inode_size) / block_size;
    const offset_in_block = (local_idx * inode_size) % block_size;

    var blk_buf: [4096]u8 align(4) = undefined;
    if (!readBlock(inode_block, &blk_buf)) return false;
    @memcpy(blk_buf[offset_in_block .. offset_in_block + @min(inode_size, 128)], inode_data[0..@min(inode_size, 128)]);
    return writeBlock(inode_block, &blk_buf);
}

/// ext2 にファイルを作成して書き込み (ルートディレクトリに追加)
pub fn createAndWrite(name: []const u8, data: []const u8) bool {
    if (!valid) return false;
    if (name.len == 0 or name.len > 255) return false;

    // 1. ブロック割り当て (データ用)
    const data_block = allocBlock() orelse return false;

    // 2. inode 割り当て
    const ino = allocInode() orelse return false;

    // 3. データブロックに書き込み
    var data_buf: [4096]u8 align(4) = undefined;
    @memset(&data_buf, 0);
    const write_len = @min(data.len, block_size);
    @memcpy(data_buf[0..write_len], data[0..write_len]);
    if (!writeBlock(data_block, &data_buf)) return false;

    // 4. inode 構築
    var inode_data: [128]u8 = [_]u8{0} ** 128;
    // i_mode = 0x81A4 (regular file, 644)
    inode_data[0] = 0xA4;
    inode_data[1] = 0x81;
    // i_size
    inode_data[4] = @truncate(data.len);
    inode_data[5] = @truncate(data.len >> 8);
    inode_data[6] = @truncate(data.len >> 16);
    inode_data[7] = @truncate(data.len >> 24);
    // i_links_count = 1
    inode_data[26] = 1;
    // i_blocks = block_size / 512
    const blocks_count = block_size / 512;
    inode_data[28] = @truncate(blocks_count);
    // i_block[0] = data_block
    inode_data[40] = @truncate(data_block);
    inode_data[41] = @truncate(data_block >> 8);
    inode_data[42] = @truncate(data_block >> 16);
    inode_data[43] = @truncate(data_block >> 24);

    if (!writeInode(ino, inode_data)) return false;

    // 5. ルートディレクトリにエントリ追加
    return addDirEntry(2, ino, name); // inode 2 = root directory
}

/// ディレクトリにエントリを追加
fn addDirEntry(dir_ino: u32, new_ino: u32, name: []const u8) bool {
    // ルートディレクトリの inode を読む
    var inode_buf: [128]u8 = undefined;
    const inode = readInodeRaw(dir_ino, &inode_buf) orelse return false;

    // ディレクトリの最初のブロックを読む
    const dir_block = readU32(inode[40..].ptr, 0); // i_block[0]
    if (dir_block == 0) return false;

    var blk_buf: [4096]u8 align(4) = undefined;
    if (!readBlock(dir_block, &blk_buf)) return false;

    // 既存エントリの末尾を探す
    var off: usize = 0;
    while (off + 8 < block_size) {
        const entry_inode = readU32(&blk_buf, off);
        const rec_len = readU16(&blk_buf, off + 4);
        if (rec_len == 0) break;
        const name_len_val = blk_buf[off + 6];
        const actual_size = ((8 + @as(usize, name_len_val) + 3) / 4) * 4;

        if (entry_inode == 0 or rec_len >= actual_size + 12 + name.len) {
            if (entry_inode != 0) {
                // 既存エントリの rec_len を縮小
                const new_rec_len: u16 = @truncate(actual_size);
                blk_buf[off + 4] = @truncate(new_rec_len);
                blk_buf[off + 5] = @truncate(new_rec_len >> 8);
                off += actual_size;
            }
            // 新エントリを書き込み
            const remaining: u16 = @truncate(block_size - off);
            blk_buf[off] = @truncate(new_ino);
            blk_buf[off + 1] = @truncate(new_ino >> 8);
            blk_buf[off + 2] = @truncate(new_ino >> 16);
            blk_buf[off + 3] = @truncate(new_ino >> 24);
            blk_buf[off + 4] = @truncate(remaining);
            blk_buf[off + 5] = @truncate(remaining >> 8);
            blk_buf[off + 6] = @truncate(name.len);
            blk_buf[off + 7] = 1; // file type: regular file
            @memcpy(blk_buf[off + 8 .. off + 8 + name.len], name);
            return writeBlock(dir_block, &blk_buf);
        }
        off += rec_len;
    }
    return false;
}

fn readInodeRaw(ino: u32, buf: *[128]u8) ?[*]const u8 {
    if (!valid or ino == 0) return null;
    const idx = ino - 1;
    const local_idx = idx % s_inodes_per_group;
    const inode_block = bgd_inode_table + (local_idx * inode_size) / block_size;
    const offset_in_block = (local_idx * inode_size) % block_size;

    var blk_buf: [4096]u8 align(4) = undefined;
    if (!readBlock(inode_block, &blk_buf)) return null;
    @memcpy(buf, blk_buf[offset_in_block .. offset_in_block + 128]);
    return buf;
}
