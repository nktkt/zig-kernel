// アーカイブユーティリティ — ファイルのパッケージングと検証

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

const ARCHIVE_MAGIC: u32 = 0x5A415243; // "ZARC"
const ARCHIVE_VERSION: u16 = 1;
const MAX_FILES = 16;
const MAX_NAME_LEN = 32;
const MAX_FILE_DATA = 2048; // ramfs MAX_DATA

// ---- CRC32 テーブル (IEEE 802.3) ----

const crc32_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var crc: u32 = @truncate(i);
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

fn calcCrc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        const index: u8 = @truncate((crc ^ b) & 0xFF);
        crc = (crc >> 8) ^ crc32_table[index];
    }
    return crc ^ 0xFFFFFFFF;
}

// ---- アーカイブヘッダー ----

pub const ArchiveHeader = struct {
    magic: u32,
    version: u16,
    entry_count: u16,
    total_size: u32,
    created_tick: u32,
    header_crc: u32,
};

const HEADER_SIZE = 16; // magic(4) + version(2) + entry_count(2) + total_size(4) + created_tick(4)

// ---- ファイルエントリ ----

pub const FileEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    size: u32,
    offset: u32, // アーカイブ先頭からのオフセット
    checksum: u32, // CRC32
};

const ENTRY_SIZE = MAX_NAME_LEN + 1 + 4 + 4 + 4; // 45 bytes

// ---- アーカイブ作成 ----

pub fn create(file_names: []const []const u8, buf: []u8) ?usize {
    if (file_names.len > MAX_FILES) return null;

    // データ領域のオフセットを計算
    const meta_size = HEADER_SIZE + 4 + ENTRY_SIZE * file_names.len; // header + header_crc + entries
    if (meta_size >= buf.len) return null;

    var entries: [MAX_FILES]FileEntry = undefined;
    var entry_count: usize = 0;
    var data_offset: u32 = @truncate(meta_size);

    // ファイルデータを収集
    for (file_names) |name| {
        if (entry_count >= MAX_FILES) break;

        const file_idx = ramfs.findByName(name) orelse continue;
        const inode = ramfs.getFile(file_idx) orelse continue;

        var entry = &entries[entry_count];
        // 名前をコピー
        @memset(&entry.name, 0);
        const name_copy_len: u8 = @intCast(@min(name.len, MAX_NAME_LEN));
        @memcpy(entry.name[0..name_copy_len], name[0..name_copy_len]);
        entry.name_len = name_copy_len;
        entry.size = @truncate(inode.size);
        entry.offset = data_offset;

        // ファイルデータをバッファにコピー
        if (data_offset + entry.size > buf.len) continue;
        const read_len = ramfs.readFile(file_idx, buf[@as(usize, data_offset) .. @as(usize, data_offset) + @as(usize, entry.size)]);
        _ = read_len;

        // CRC32 計算
        entry.checksum = calcCrc32(buf[@as(usize, data_offset) .. @as(usize, data_offset) + @as(usize, entry.size)]);

        data_offset += entry.size;
        entry_count += 1;
    }

    if (entry_count == 0) return null;

    // ヘッダーを書き込み
    var pos: usize = 0;
    writeU32(buf, pos, ARCHIVE_MAGIC);
    pos += 4;
    writeU16(buf, pos, ARCHIVE_VERSION);
    pos += 2;
    writeU16(buf, pos, @truncate(entry_count));
    pos += 2;
    writeU32(buf, pos, data_offset); // total_size
    pos += 4;
    writeU32(buf, pos, 0); // created_tick placeholder
    pos += 4;

    // ヘッダー CRC
    const header_crc = calcCrc32(buf[0..HEADER_SIZE]);
    writeU32(buf, pos, header_crc);
    pos += 4;

    // エントリを書き込み
    for (entries[0..entry_count]) |*entry| {
        @memcpy(buf[pos .. pos + MAX_NAME_LEN], &entry.name);
        pos += MAX_NAME_LEN;
        buf[pos] = entry.name_len;
        pos += 1;
        writeU32(buf, pos, entry.size);
        pos += 4;
        writeU32(buf, pos, entry.offset);
        pos += 4;
        writeU32(buf, pos, entry.checksum);
        pos += 4;
    }

    return data_offset;
}

// ---- アーカイブ展開 ----

pub fn extract(archive_data: []const u8) void {
    if (archive_data.len < HEADER_SIZE + 4) {
        vga.write("Archive: too small\n");
        return;
    }

    // ヘッダー検証
    const magic = readU32(archive_data, 0);
    if (magic != ARCHIVE_MAGIC) {
        vga.write("Archive: invalid magic\n");
        return;
    }

    const entry_count = readU16Val(archive_data, 8);
    if (entry_count > MAX_FILES) {
        vga.write("Archive: too many entries\n");
        return;
    }

    var pos: usize = HEADER_SIZE + 4; // skip header + header_crc
    var extracted: usize = 0;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + ENTRY_SIZE > archive_data.len) break;

        const name_len = archive_data[pos + MAX_NAME_LEN];
        const name = archive_data[pos .. pos + @as(usize, name_len)];
        const size = readU32(archive_data, pos + MAX_NAME_LEN + 1);
        const offset = readU32(archive_data, pos + MAX_NAME_LEN + 5);
        const checksum = readU32(archive_data, pos + MAX_NAME_LEN + 9);

        pos += ENTRY_SIZE;

        // データ検証
        if (@as(usize, offset) + @as(usize, size) > archive_data.len) continue;
        const data = archive_data[@as(usize, offset) .. @as(usize, offset) + @as(usize, size)];
        const actual_crc = calcCrc32(data);

        if (actual_crc != checksum) {
            vga.setColor(.light_red, .black);
            vga.write("  CRC mismatch: ");
            vga.write(name);
            vga.putChar('\n');
            vga.setColor(.light_grey, .black);
            continue;
        }

        // ramfs にファイルを作成
        const file_idx = ramfs.create(name) orelse {
            // 既存ファイルを探す
            if (ramfs.findByName(name)) |existing| {
                _ = ramfs.writeFile(existing, data);
                extracted += 1;
            }
            continue;
        };
        _ = ramfs.writeFile(file_idx, data);
        extracted += 1;

        vga.setColor(.light_green, .black);
        vga.write("  Extracted: ");
        vga.setColor(.light_grey, .black);
        vga.write(name);
        vga.write(" (");
        fmt.printDec(size);
        vga.write(" bytes)\n");
    }

    vga.write("Extracted ");
    fmt.printDec(extracted);
    vga.write(" file(s)\n");
}

// ---- アーカイブ内容一覧 ----

pub fn list(archive_data: []const u8) void {
    if (archive_data.len < HEADER_SIZE + 4) {
        vga.write("Archive: too small\n");
        return;
    }

    const magic = readU32(archive_data, 0);
    if (magic != ARCHIVE_MAGIC) {
        vga.write("Archive: invalid magic\n");
        return;
    }

    const entry_count = readU16Val(archive_data, 8);
    const total_size = readU32(archive_data, 10);

    vga.setColor(.yellow, .black);
    vga.write("Archive Contents:\n");
    vga.write("NAME                             SIZE       CRC32\n");
    vga.setColor(.light_grey, .black);

    var pos: usize = HEADER_SIZE + 4;
    var i: usize = 0;
    var total_uncompressed: usize = 0;

    while (i < entry_count) : (i += 1) {
        if (pos + ENTRY_SIZE > archive_data.len) break;

        const name_len = archive_data[pos + MAX_NAME_LEN];
        const name = archive_data[pos .. pos + @as(usize, name_len)];
        const size = readU32(archive_data, pos + MAX_NAME_LEN + 1);
        const checksum = readU32(archive_data, pos + MAX_NAME_LEN + 9);

        pos += ENTRY_SIZE;

        vga.write(name);
        var pad = @as(usize, 33) -| name.len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
        fmt.printDecPadded(size, 10);
        vga.write("  ");
        fmt.printHex32(checksum);
        vga.putChar('\n');

        total_uncompressed += size;
    }

    vga.setColor(.dark_grey, .black);
    vga.write("---\n");
    vga.setColor(.light_grey, .black);
    fmt.printDec(entry_count);
    vga.write(" file(s), ");
    fmt.printSize(total_uncompressed);
    vga.write(" data, ");
    fmt.printSize(total_size);
    vga.write(" total\n");
}

// ---- チェックサム検証 ----

pub fn verify(archive_data: []const u8) bool {
    if (archive_data.len < HEADER_SIZE + 4) return false;

    const magic = readU32(archive_data, 0);
    if (magic != ARCHIVE_MAGIC) return false;

    // ヘッダー CRC 検証
    const stored_header_crc = readU32(archive_data, HEADER_SIZE);
    const actual_header_crc = calcCrc32(archive_data[0..HEADER_SIZE]);
    if (stored_header_crc != actual_header_crc) {
        vga.setColor(.light_red, .black);
        vga.write("Header CRC mismatch!\n");
        vga.setColor(.light_grey, .black);
        return false;
    }

    const entry_count = readU16Val(archive_data, 8);
    var pos: usize = HEADER_SIZE + 4;
    var all_ok = true;
    var i: usize = 0;

    while (i < entry_count) : (i += 1) {
        if (pos + ENTRY_SIZE > archive_data.len) return false;

        const name_len = archive_data[pos + MAX_NAME_LEN];
        const name = archive_data[pos .. pos + @as(usize, name_len)];
        const size = readU32(archive_data, pos + MAX_NAME_LEN + 1);
        const offset = readU32(archive_data, pos + MAX_NAME_LEN + 5);
        const checksum = readU32(archive_data, pos + MAX_NAME_LEN + 9);

        pos += ENTRY_SIZE;

        if (@as(usize, offset) + @as(usize, size) > archive_data.len) {
            vga.setColor(.light_red, .black);
            vga.write("  FAIL: ");
            vga.write(name);
            vga.write(" (out of bounds)\n");
            all_ok = false;
            continue;
        }

        const data = archive_data[@as(usize, offset) .. @as(usize, offset) + @as(usize, size)];
        const actual_crc = calcCrc32(data);

        if (actual_crc == checksum) {
            vga.setColor(.light_green, .black);
            vga.write("  OK:   ");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("  FAIL: ");
            all_ok = false;
        }
        vga.setColor(.light_grey, .black);
        vga.write(name);
        vga.write(" (CRC=");
        fmt.printHex32(checksum);
        vga.write(")\n");
    }

    return all_ok;
}

// ---- アーカイブメタデータ表示 ----

pub fn printInfo(archive_data: []const u8) void {
    if (archive_data.len < HEADER_SIZE + 4) {
        vga.write("Archive: too small\n");
        return;
    }

    const magic = readU32(archive_data, 0);
    const version = readU16Val(archive_data, 4);
    const entry_count = readU16Val(archive_data, 8);
    const total_size = readU32(archive_data, 10);

    vga.setColor(.yellow, .black);
    vga.write("Archive Metadata:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Magic:       0x");
    fmt.printHex32(magic);
    if (magic == ARCHIVE_MAGIC) {
        vga.setColor(.light_green, .black);
        vga.write(" (valid)");
    } else {
        vga.setColor(.light_red, .black);
        vga.write(" (invalid)");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    vga.write("  Version:     ");
    fmt.printDec(version);
    vga.putChar('\n');

    vga.write("  Entries:     ");
    fmt.printDec(entry_count);
    vga.write("/");
    fmt.printDec(MAX_FILES);
    vga.putChar('\n');

    vga.write("  Total Size:  ");
    fmt.printSize(total_size);
    vga.putChar('\n');

    vga.write("  Header CRC:  ");
    if (archive_data.len >= HEADER_SIZE + 4) {
        fmt.printHex32(readU32(archive_data, HEADER_SIZE));
    }
    vga.putChar('\n');
}

// ---- ファイル追加 (既存アーカイブに) ----

pub fn addFile(archive: []u8, archive_len: *usize, name: []const u8, data: []const u8) bool {
    if (archive_len.* < HEADER_SIZE + 4) return false;
    if (name.len > MAX_NAME_LEN or name.len == 0) return false;

    const magic = readU32(archive, 0);
    if (magic != ARCHIVE_MAGIC) return false;

    var entry_count = readU16Val(archive, 8);
    if (entry_count >= MAX_FILES) return false;

    // 新しいエントリの位置
    var entry_pos = HEADER_SIZE + 4 + ENTRY_SIZE * @as(usize, entry_count);
    const data_offset = archive_len.*;

    // データが収まるか確認
    if (data_offset + data.len + ENTRY_SIZE > archive.len) return false;

    // エントリを追加するため、既存データを後ろにシフト
    // 新しいエントリ位置に書き込み
    // (簡易実装: エントリ領域の後にデータがある前提)

    // データを書き込み
    @memcpy(archive[data_offset .. data_offset + data.len], data);

    // エントリを書き込み
    @memset(archive[entry_pos .. entry_pos + MAX_NAME_LEN], 0);
    @memcpy(archive[entry_pos .. entry_pos + name.len], name);
    entry_pos += MAX_NAME_LEN;
    archive[entry_pos] = @intCast(name.len);
    entry_pos += 1;
    writeU32(archive, entry_pos, @truncate(data.len));
    entry_pos += 4;
    writeU32(archive, entry_pos, @truncate(data_offset));
    entry_pos += 4;
    writeU32(archive, entry_pos, calcCrc32(data));

    // ヘッダー更新
    entry_count += 1;
    writeU16(archive, 8, entry_count);
    writeU32(archive, 10, @truncate(data_offset + data.len));

    // ヘッダー CRC 更新
    const header_crc = calcCrc32(archive[0..HEADER_SIZE]);
    writeU32(archive, HEADER_SIZE, header_crc);

    archive_len.* = data_offset + data.len;
    return true;
}

// ---- ファイル削除 (名前で検索) ----

pub fn removeFile(archive: []u8, archive_len: *usize, name: []const u8) bool {
    if (archive_len.* < HEADER_SIZE + 4) return false;

    const magic = readU32(archive, 0);
    if (magic != ARCHIVE_MAGIC) return false;

    var entry_count = readU16Val(archive, 8);
    if (entry_count == 0) return false;

    var pos: usize = HEADER_SIZE + 4;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + ENTRY_SIZE > archive_len.*) return false;
        const name_len = archive[pos + MAX_NAME_LEN];
        const entry_name = archive[pos .. pos + @as(usize, name_len)];

        if (eql(entry_name, name)) {
            // エントリを削除: 後続エントリを前にシフト
            const next_pos = pos + ENTRY_SIZE;
            const remaining = ENTRY_SIZE * (entry_count - i - 1);
            if (remaining > 0) {
                // コピー (重なるかもしれないので手動)
                var k: usize = 0;
                while (k < remaining) : (k += 1) {
                    archive[pos + k] = archive[next_pos + k];
                }
            }
            entry_count -= 1;
            writeU16(archive, 8, entry_count);
            // ヘッダー CRC 更新
            const header_crc = calcCrc32(archive[0..HEADER_SIZE]);
            writeU32(archive, HEADER_SIZE, header_crc);
            return true;
        }
        pos += ENTRY_SIZE;
    }
    return false;
}

// ---- バイト操作ヘルパー ----

fn writeU32(buf: []u8, offset: usize, val: u32) void {
    buf[offset] = @truncate(val);
    buf[offset + 1] = @truncate(val >> 8);
    buf[offset + 2] = @truncate(val >> 16);
    buf[offset + 3] = @truncate(val >> 24);
}

fn writeU16(buf: []u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val);
    buf[offset + 1] = @truncate(val >> 8);
}

fn readU32(buf: []const u8, offset: usize) u32 {
    return @as(u32, buf[offset]) |
        (@as(u32, buf[offset + 1]) << 8) |
        (@as(u32, buf[offset + 2]) << 16) |
        (@as(u32, buf[offset + 3]) << 24);
}

fn readU16Val(buf: []const u8, offset: usize) u16 {
    return @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
