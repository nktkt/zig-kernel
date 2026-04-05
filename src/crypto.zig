// 暗号ユーティリティ — CRC32, FNV-1a, XOR 暗号, ハッシュ, LCG 乱数
//
// 注意: simpleHash, xorEncrypt は暗号学的に安全ではない。
// チェックサム、データ検証、デバッグ用途向け。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ===========================================================================
// CRC32 (IEEE 802.3 多項式: 0xEDB88320, reflected)
// ===========================================================================

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

/// CRC32 チェックサムを計算
pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        const index: u8 = @truncate((crc ^ b) & 0xFF);
        crc = (crc >> 8) ^ crc32_table[index];
    }
    return crc ^ 0xFFFFFFFF;
}

/// CRC32 を段階的に計算 (初期値を渡す)
pub fn crc32Update(prev_crc: u32, data: []const u8) u32 {
    var crc = prev_crc ^ 0xFFFFFFFF; // un-finalize
    for (data) |b| {
        const index: u8 = @truncate((crc ^ b) & 0xFF);
        crc = (crc >> 8) ^ crc32_table[index];
    }
    return crc ^ 0xFFFFFFFF;
}

// ===========================================================================
// FNV-1a ハッシュ (32-bit)
// ===========================================================================

const FNV_OFFSET_BASIS: u32 = 0x811C9DC5;
const FNV_PRIME: u32 = 0x01000193;

/// FNV-1a 32-bit ハッシュを計算
pub fn fnv1a(data: []const u8) u32 {
    var hash: u32 = FNV_OFFSET_BASIS;
    for (data) |b| {
        hash ^= b;
        hash *%= FNV_PRIME;
    }
    return hash;
}

/// FNV-1a ハッシュを段階的に計算
pub fn fnv1aUpdate(prev_hash: u32, data: []const u8) u32 {
    var hash = prev_hash;
    for (data) |b| {
        hash ^= b;
        hash *%= FNV_PRIME;
    }
    return hash;
}

// ===========================================================================
// XOR 暗号 (対称鍵ストリーム暗号)
// ===========================================================================

/// XOR 暗号化 (data XOR key[i % key_len] => out)
pub fn xorEncrypt(data: []const u8, key: []const u8, out: []u8) void {
    if (key.len == 0) return;
    const len = if (data.len < out.len) data.len else out.len;
    for (0..len) |i| {
        out[i] = data[i] ^ key[i % key.len];
    }
}

/// XOR 復号 (暗号化と同じ操作)
pub fn xorDecrypt(data: []const u8, key: []const u8, out: []u8) void {
    xorEncrypt(data, key, out); // XOR は対称
}

/// インプレース XOR 暗号化/復号
pub fn xorInPlace(buf: []u8, key: []const u8) void {
    if (key.len == 0) return;
    for (buf, 0..) |*b, i| {
        b.* ^= key[i % key.len];
    }
}

// ===========================================================================
// simpleHash — 16 バイトダイジェスト (非暗号学的)
// ===========================================================================
//
// MD5 に似た構造だが大幅に簡略化。
// データ検証やフィンガープリント用途向け。

/// 16 バイトの簡易ハッシュを計算
pub fn simpleHash(data: []const u8) [16]u8 {
    // 4 つの 32-bit 状態変数
    var s0: u32 = 0x67452301;
    var s1: u32 = 0xEFCDAB89;
    var s2: u32 = 0x98BADCFE;
    var s3: u32 = 0x10325476;

    // データ長を混ぜる
    const data_len: u32 = @truncate(data.len);
    s0 +%= data_len;
    s3 ^= data_len *% 0x5BD1E995;

    // データを 4 バイトずつ処理
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        var k: u32 = @as(u32, data[i]) |
            (@as(u32, data[i + 1]) << 8) |
            (@as(u32, data[i + 2]) << 16) |
            (@as(u32, data[i + 3]) << 24);

        k *%= 0x5BD1E995;
        k ^= k >> 13;
        k *%= 0x5BD1E995;

        s0 ^= k;
        s0 = rotl(s0, 5) +% s1;
        s1 = rotl(s1, 7) ^ s2;
        s2 = rotl(s2, 11) +% s3;
        s3 = rotl(s3, 13) ^ s0;
    }

    // 残りバイトの処理
    if (i < data.len) {
        var remainder: u32 = 0;
        var shift: u5 = 0;
        while (i < data.len) : (i += 1) {
            remainder |= @as(u32, data[i]) << shift;
            if (shift < 24) {
                shift += 8;
            }
        }
        s0 ^= remainder;
        s0 *%= 0x5BD1E995;
    }

    // ファイナライズ (avalanche)
    s0 ^= s0 >> 13;
    s0 *%= 0x5BD1E995;
    s0 ^= s0 >> 15;

    s1 ^= s1 >> 13;
    s1 *%= 0xC2B2AE35;
    s1 ^= s1 >> 16;

    s2 ^= s2 >> 13;
    s2 *%= 0x85EBCA6B;
    s2 ^= s2 >> 15;

    s3 ^= s3 >> 13;
    s3 *%= 0xCC9E2D51;
    s3 ^= s3 >> 16;

    // 状態を 16 バイト配列にパック (little-endian)
    var result: [16]u8 = undefined;
    packU32LE(&result, 0, s0);
    packU32LE(&result, 4, s1);
    packU32LE(&result, 8, s2);
    packU32LE(&result, 12, s3);

    return result;
}

// ===========================================================================
// LCG 擬似乱数ジェネレータ
// ===========================================================================
//
// Numerical Recipes の LCG パラメータ:
//   state = state * 1664525 + 1013904223

const LCG_A: u32 = 1664525;
const LCG_C: u32 = 1013904223;

var lcg_state: u32 = 0x12345678;

/// LCG シードを設定
pub fn seed(s: u32) void {
    lcg_state = if (s == 0) 0x12345678 else s;
}

/// PIT ticks をエントロピー源としてシードを自動設定
pub fn seedFromTimer() void {
    const t = pit.getTicks();
    lcg_state = @truncate(t ^ (t >> 16));
    if (lcg_state == 0) lcg_state = 0xDEADBEEF;
}

/// 32-bit 擬似乱数を生成
pub fn rand() u32 {
    lcg_state = lcg_state *% LCG_A +% LCG_C;
    return lcg_state;
}

/// 指定範囲 [0, max) の乱数を生成
pub fn randRange(max: u32) u32 {
    if (max == 0) return 0;
    return rand() % max;
}

/// バッファをランダムデータで埋める
pub fn randFill(buf: []u8) void {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        const r = rand();
        buf[i] = @truncate(r & 0xFF);
        buf[i + 1] = @truncate((r >> 8) & 0xFF);
        buf[i + 2] = @truncate((r >> 16) & 0xFF);
        buf[i + 3] = @truncate((r >> 24) & 0xFF);
    }
    // 残りバイト
    if (i < buf.len) {
        var r = rand();
        while (i < buf.len) : (i += 1) {
            buf[i] = @truncate(r & 0xFF);
            r >>= 8;
        }
    }
}

// ===========================================================================
// 表示ユーティリティ
// ===========================================================================

/// ハッシュ値を16進数文字列として VGA に出力
pub fn printHash(hash: []const u8) void {
    const hex = "0123456789abcdef";
    for (hash) |b| {
        vga.putChar(hex[b >> 4]);
        vga.putChar(hex[b & 0x0F]);
    }
}

/// ハッシュ値を16進数文字列としてシリアルに出力
pub fn printHashSerial(hash: []const u8) void {
    const hex = "0123456789abcdef";
    for (hash) |b| {
        serial.putChar(hex[b >> 4]);
        serial.putChar(hex[b & 0x0F]);
    }
}

/// u32 を16進数で VGA に出力
pub fn printHex32(val: u32) void {
    const hex = "0123456789abcdef";
    var v = val;
    var buf: [8]u8 = undefined;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, v & 0xF)];
        v >>= 4;
    }
    vga.write(&buf);
}

/// CRC32 とハッシュの概要を表示
pub fn printDigest(data: []const u8) void {
    vga.setColor(.light_cyan, .black);
    vga.write("Digest of ");
    printDec(data.len);
    vga.write(" bytes:\n");

    vga.setColor(.light_grey, .black);
    vga.write("  CRC32:  0x");
    printHex32(crc32(data));
    vga.putChar('\n');

    vga.write("  FNV-1a: 0x");
    printHex32(fnv1a(data));
    vga.putChar('\n');

    vga.write("  Hash:   ");
    const hash = simpleHash(data);
    printHash(&hash);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
}

// ===========================================================================
// 内部ユーティリティ
// ===========================================================================

fn rotl(x: u32, comptime n: u5) u32 {
    return (x << n) | (x >> (32 - n));
}

fn packU32LE(buf: *[16]u8, offset: usize, val: u32) void {
    buf[offset] = @truncate(val & 0xFF);
    buf[offset + 1] = @truncate((val >> 8) & 0xFF);
    buf[offset + 2] = @truncate((val >> 16) & 0xFF);
    buf[offset + 3] = @truncate((val >> 24) & 0xFF);
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
