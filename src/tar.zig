// TAR アーカイブリーダー — ustar フォーマット対応
//
// メモリ上の tar データを読み取り、エントリの一覧表示や
// 個別ファイルの抽出を行う。ramfs のデータと連携可能。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- 定数 ----

const BLOCK_SIZE = 512;
const USTAR_MAGIC = "ustar";
const MAX_NAME_LEN = 100;
const MAX_PREFIX_LEN = 155;
const MAX_FULL_PATH = 256;

// ---- TAR ヘッダ (512 バイト, POSIX ustar フォーマット) ----

pub const TarHeader = extern struct {
    name: [100]u8, // ファイル名
    mode: [8]u8, // パーミッション (8進数 ASCII)
    uid: [8]u8, // ユーザ ID
    gid: [8]u8, // グループ ID
    size: [12]u8, // ファイルサイズ (8進数 ASCII)
    mtime: [12]u8, // 変更時刻 (Unix timestamp, 8進数)
    checksum: [8]u8, // ヘッダチェックサム
    typeflag: u8, // エントリ種別
    linkname: [100]u8, // リンク先名
    magic: [6]u8, // "ustar\0"
    version: [2]u8, // "00"
    uname: [32]u8, // ユーザ名
    gname: [32]u8, // グループ名
    devmajor: [8]u8, // デバイス major
    devminor: [8]u8, // デバイス minor
    prefix: [155]u8, // ファイル名プレフィクス
    _padding: [12]u8, // パディング (合計 512 バイト)
};

// typeflag 値
pub const TYPE_FILE = '0'; // 通常ファイル
pub const TYPE_FILE_ALT = 0; // 古い形式の通常ファイル
pub const TYPE_HARDLINK = '1';
pub const TYPE_SYMLINK = '2';
pub const TYPE_CHARDEV = '3';
pub const TYPE_BLOCKDEV = '4';
pub const TYPE_DIR = '5'; // ディレクトリ
pub const TYPE_FIFO = '6';

// ---- TAR エントリ ----

pub const TarEntry = struct {
    /// フルパス名
    name: [MAX_FULL_PATH]u8,
    name_len: usize,
    /// ファイルサイズ
    size: usize,
    /// ディレクトリか
    is_dir: bool,
    /// エントリ種別
    typeflag: u8,
    /// パーミッション
    mode: u32,
    /// 変更時刻
    mtime: u32,
    /// データポインタ (ヘッダの次のブロックから)
    data: [*]const u8,
    /// データの有効な長さ
    data_len: usize,

    pub fn getName(self: *const TarEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getData(self: *const TarEntry) []const u8 {
        return self.data[0..self.data_len];
    }
};

// ---- TAR イテレータ ----

pub const TarIterator = struct {
    data: [*]const u8,
    data_len: usize,
    offset: usize,

    /// 次のエントリを返す。アーカイブ終端で null を返す。
    pub fn next(self: *TarIterator) ?TarEntry {
        while (self.offset + BLOCK_SIZE <= self.data_len) {
            const header_ptr = self.data + self.offset;

            // 空ブロック (2 つ連続) = アーカイブ終端
            if (isZeroBlock(header_ptr)) {
                // 次も空ブロックか確認
                if (self.offset + 2 * BLOCK_SIZE <= self.data_len) {
                    if (isZeroBlock(header_ptr + BLOCK_SIZE)) {
                        return null; // アーカイブ終端
                    }
                }
                self.offset += BLOCK_SIZE;
                continue;
            }

            const header: *const TarHeader = @ptrCast(@alignCast(header_ptr));

            // ustar マジック確認
            if (!verifyMagic(header)) {
                // マジックなし → 古い tar か破損。スキップして次を試す
                self.offset += BLOCK_SIZE;
                continue;
            }

            // チェックサム検証
            if (!verifyChecksum(header_ptr[0..BLOCK_SIZE])) {
                self.offset += BLOCK_SIZE;
                continue;
            }

            // エントリ情報を構築
            var entry: TarEntry = undefined;
            entry.size = parseOctal(&header.size);
            entry.typeflag = header.typeflag;
            entry.is_dir = (header.typeflag == TYPE_DIR);
            entry.mode = @truncate(parseOctal(&header.mode));
            entry.mtime = @truncate(parseOctal(&header.mtime));

            // フルパス名を構築 (prefix + name)
            entry.name_len = buildFullPath(&entry.name, &header.prefix, &header.name);

            // データポインタ
            const data_offset = self.offset + BLOCK_SIZE;
            if (data_offset <= self.data_len) {
                entry.data = self.data + data_offset;
                entry.data_len = if (data_offset + entry.size <= self.data_len)
                    entry.size
                else
                    self.data_len - data_offset;
            } else {
                entry.data = self.data + self.offset; // フォールバック
                entry.data_len = 0;
            }

            // 次のエントリへオフセットを進める
            // データブロック数 = ceil(size / 512)
            const data_blocks = (entry.size + BLOCK_SIZE - 1) / BLOCK_SIZE;
            self.offset = data_offset + data_blocks * BLOCK_SIZE;

            return entry;
        }
        return null; // データ終端
    }

    /// イテレータをリセット
    pub fn reset(self: *TarIterator) void {
        self.offset = 0;
    }
};

// ---- 公開 API ----

/// メモリ上の tar データからイテレータを生成
pub fn parse(data: []const u8) TarIterator {
    return TarIterator{
        .data = data.ptr,
        .data_len = data.len,
        .offset = 0,
    };
}

/// アーカイブ内容を一覧表示
pub fn listArchive(data: []const u8) void {
    var iter = parse(data);
    var count: usize = 0;
    var total_size: usize = 0;

    vga.setColor(.yellow, .black);
    vga.write("TAR Archive Contents:\n");
    vga.setColor(.light_cyan, .black);
    vga.write("TYPE  MODE    SIZE       NAME\n");
    vga.setColor(.light_grey, .black);

    while (iter.next()) |entry| {
        // タイプ表示
        if (entry.is_dir) {
            vga.setColor(.light_cyan, .black);
            vga.write("dir   ");
        } else if (entry.typeflag == TYPE_SYMLINK) {
            vga.setColor(.light_magenta, .black);
            vga.write("link  ");
        } else {
            vga.setColor(.light_grey, .black);
            vga.write("file  ");
        }

        // パーミッション (8進数)
        vga.setColor(.light_grey, .black);
        printOctalPadded(entry.mode, 6);
        vga.write("  ");

        // サイズ
        printDecPadded(entry.size, 9);
        vga.write("  ");

        // 名前
        if (entry.is_dir) {
            vga.setColor(.light_cyan, .black);
        } else {
            vga.setColor(.white, .black);
        }
        vga.write(entry.getName());
        vga.putChar('\n');

        count += 1;
        total_size += entry.size;
    }

    vga.setColor(.light_green, .black);
    printDec(count);
    vga.write(" entries, ");
    printDec(total_size);
    vga.write(" bytes total\n");
    vga.setColor(.light_grey, .black);
}

/// アーカイブから指定ファイルを抽出
/// 成功時: buf に書き込んだバイト数を返す
pub fn extractFile(data: []const u8, name: []const u8, buf: []u8) ?usize {
    var iter = parse(data);

    while (iter.next()) |entry| {
        if (entry.name_len == name.len and strEql(entry.name[0..entry.name_len], name)) {
            if (entry.is_dir) return null; // ディレクトリは抽出不可

            const copy_len = if (entry.data_len > buf.len) buf.len else entry.data_len;
            for (0..copy_len) |i| {
                buf[i] = entry.data[i];
            }
            return copy_len;
        }
    }
    return null; // ファイルが見つからない
}

/// アーカイブ内のファイル数を返す
pub fn countEntries(data: []const u8) usize {
    var iter = parse(data);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    return count;
}

/// 指定ファイルが存在するか確認
pub fn contains(data: []const u8, name: []const u8) bool {
    var iter = parse(data);
    while (iter.next()) |entry| {
        if (entry.name_len == name.len and strEql(entry.name[0..entry.name_len], name)) {
            return true;
        }
    }
    return false;
}

// ---- 8進数パーサー ----

fn parseOctal(field: []const u8) usize {
    var val: usize = 0;
    for (field) |c| {
        if (c == 0 or c == ' ') continue; // NUL/空白を無視
        if (c < '0' or c > '7') continue; // 非8進数を無視
        val = val * 8 + (c - '0');
    }
    return val;
}

// ---- ustar マジック検証 ----

fn verifyMagic(header: *const TarHeader) bool {
    // "ustar" (5文字) を確認
    if (header.magic[0] != 'u') return false;
    if (header.magic[1] != 's') return false;
    if (header.magic[2] != 't') return false;
    if (header.magic[3] != 'a') return false;
    if (header.magic[4] != 'r') return false;
    return true;
}

// ---- チェックサム検証 ----

fn verifyChecksum(block: []const u8) bool {
    if (block.len < BLOCK_SIZE) return false;

    // ヘッダのチェックサム値を読む
    const stored = parseOctal(block[148..156]);

    // チェックサム計算: チェックサムフィールドを空白 (0x20) として合計
    var sum: usize = 0;
    for (block[0..BLOCK_SIZE], 0..) |b, i| {
        if (i >= 148 and i < 156) {
            sum += 0x20; // チェックサムフィールド → 空白
        } else {
            sum += b;
        }
    }

    return sum == stored;
}

// ---- ゼロブロック判定 ----

fn isZeroBlock(ptr: [*]const u8) bool {
    for (0..BLOCK_SIZE) |i| {
        if (ptr[i] != 0) return false;
    }
    return true;
}

// ---- フルパス構築 ----

fn buildFullPath(dst: *[MAX_FULL_PATH]u8, prefix: *const [155]u8, name: *const [100]u8) usize {
    var pos: usize = 0;

    // prefix (空でなければ)
    const prefix_len = nullStrLen(prefix);
    if (prefix_len > 0) {
        const copy_len = if (prefix_len > MAX_FULL_PATH - 2) MAX_FULL_PATH - 2 else prefix_len;
        for (0..copy_len) |i| {
            dst[pos] = prefix[i];
            pos += 1;
        }
        if (pos < MAX_FULL_PATH) {
            dst[pos] = '/';
            pos += 1;
        }
    }

    // name
    const name_len = nullStrLen(name);
    const remaining = MAX_FULL_PATH - pos;
    const copy_len = if (name_len > remaining) remaining else name_len;
    for (0..copy_len) |i| {
        dst[pos] = name[i];
        pos += 1;
    }

    return pos;
}

/// NUL 終端文字列の長さを返す
fn nullStrLen(s: []const u8) usize {
    for (s, 0..) |c, i| {
        if (c == 0) return i;
    }
    return s.len;
}

// ---- ユーティリティ ----

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDecPadded(n_val: usize, width: usize) void {
    var digits: usize = 0;
    var tmp = n_val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec(n_val);
}

fn printOctalPadded(val: u32, width: usize) void {
    // 8進数に変換
    if (val == 0) {
        var pad = width;
        while (pad > 1) : (pad -= 1) vga.putChar(' ');
        vga.putChar('0');
        return;
    }
    var buf: [12]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 8);
        len += 1;
        v /= 8;
    }
    if (len < width) {
        var pad = width - len;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
