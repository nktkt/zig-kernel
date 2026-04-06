// Checksum — チェックサムアルゴリズム集
// Adler-32, Fletcher-16/32, XOR, Luhn, ISBN-10, CRC-16, パリティ, ハミング距離
// freestanding 環境向け

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Adler-32 ----
// RFC 1950 で使用される高速チェックサム
// zlib で採用

pub fn adler32(data: []const u8) u32 {
    const MOD_ADLER: u32 = 65521; // 65536 未満の最大素数

    var a: u32 = 1;
    var b: u32 = 0;

    for (data) |byte| {
        a = (a + @as(u32, byte)) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }

    return (b << 16) | a;
}

/// インクリメンタル Adler-32 更新
pub fn adler32Update(prev: u32, byte: u8) u32 {
    const MOD_ADLER: u32 = 65521;
    var a = prev & 0xFFFF;
    var b = (prev >> 16) & 0xFFFF;

    a = (a + @as(u32, byte)) % MOD_ADLER;
    b = (b + a) % MOD_ADLER;

    return (b << 16) | a;
}

// ---- Fletcher-16 ----

pub fn fletcher16(data: []const u8) u16 {
    var sum1: u16 = 0;
    var sum2: u16 = 0;

    for (data) |byte| {
        sum1 = (sum1 + @as(u16, byte)) % 255;
        sum2 = (sum2 + sum1) % 255;
    }

    return (sum2 << 8) | sum1;
}

// ---- Fletcher-32 ----

pub fn fletcher32(data: []const u8) u32 {
    var sum1: u32 = 0;
    var sum2: u32 = 0;

    // 16 ビット単位で処理
    var i: usize = 0;
    while (i < data.len) {
        var word: u32 = data[i];
        if (i + 1 < data.len) {
            word |= @as(u32, data[i + 1]) << 8;
        }
        sum1 = (sum1 + word) % 65535;
        sum2 = (sum2 + sum1) % 65535;
        i += 2;
    }

    return (sum2 << 16) | sum1;
}

// ---- XOR Checksum ----

pub fn xorChecksum(data: []const u8) u8 {
    var result: u8 = 0;
    for (data) |byte| {
        result ^= byte;
    }
    return result;
}

/// 16 ビット XOR チェックサム
pub fn xorChecksum16(data: []const u8) u16 {
    var result: u16 = 0;
    var i: usize = 0;
    while (i < data.len) {
        var word: u16 = data[i];
        if (i + 1 < data.len) {
            word |= @as(u16, data[i + 1]) << 8;
        }
        result ^= word;
        i += 2;
    }
    return result;
}

// ---- Luhn Algorithm ----
// クレジットカード番号等の検証

/// Luhn アルゴリズムで数字列を検証
/// digits は ASCII の '0'-'9' を含むスライス
pub fn luhn(digits: []const u8) bool {
    if (digits.len == 0) return false;

    var sum: u32 = 0;
    var is_double = false;

    // 右から左に処理
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        if (digits[i] < '0' or digits[i] > '9') return false;

        var d: u32 = digits[i] - '0';
        if (is_double) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
        is_double = !is_double;
    }

    return (sum % 10) == 0;
}

/// 数値で Luhn チェック
pub fn luhnU64(num: u64) bool {
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = num;

    if (val == 0) {
        buf[0] = '0';
        len = 1;
    } else {
        while (val > 0) {
            buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
            len += 1;
            val /= 10;
        }
        // 逆順にする
        var lo: usize = 0;
        var hi: usize = len - 1;
        while (lo < hi) {
            const tmp = buf[lo];
            buf[lo] = buf[hi];
            buf[hi] = tmp;
            lo += 1;
            hi -= 1;
        }
    }

    return luhn(buf[0..len]);
}

// ---- ISBN-10 ----

/// ISBN-10 チェックデジット検証
/// digits は 10 文字の ISBN (最後の 'X' は 10)
pub fn isbn10(digits: []const u8) bool {
    if (digits.len != 10) return false;

    var sum: u32 = 0;
    for (digits, 0..) |c, i| {
        var d: u32 = 0;
        if (c >= '0' and c <= '9') {
            d = c - '0';
        } else if (c == 'X' and i == 9) {
            d = 10;
        } else {
            return false;
        }
        sum += d * @as(u32, @truncate(10 - i));
    }

    return (sum % 11) == 0;
}

// ---- CRC-16 (CCITT) ----
// 多項式: x^16 + x^12 + x^5 + 1 (0x1021)

pub fn crc16(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;

    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;

        var bit: u32 = 0;
        while (bit < 8) : (bit += 1) {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc = crc << 1;
            }
        }
    }

    return crc;
}

/// テーブル駆動 CRC-16
const crc16_table: [256]u16 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u16 = undefined;
    for (0..256) |i| {
        var crc: u16 = @as(u16, @truncate(i)) << 8;
        for (0..8) |_| {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc = crc << 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

pub fn crc16Fast(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        const idx: u8 = @truncate((crc >> 8) ^ @as(u16, byte));
        crc = (crc << 8) ^ crc16_table[idx];
    }
    return crc;
}

// ---- パリティ ----

/// 偶数パリティ: セットビット数が偶数なら true
pub fn parity(x: u32) bool {
    var val = x;
    val ^= val >> 16;
    val ^= val >> 8;
    val ^= val >> 4;
    val ^= val >> 2;
    val ^= val >> 1;
    return (val & 1) == 0;
}

/// バイト配列の偶数パリティ
pub fn parityBytes(data: []const u8) bool {
    var p: u8 = 0;
    for (data) |byte| {
        p ^= byte;
    }
    // p のパリティを計算
    var val: u32 = p;
    val ^= val >> 4;
    val ^= val >> 2;
    val ^= val >> 1;
    return (val & 1) == 0;
}

// ---- ハミング距離 ----

/// 2 つの値のハミング距離
pub fn hammingDistance(a: u32, b: u32) u32 {
    var xor_val = a ^ b;
    var count: u32 = 0;
    while (xor_val != 0) {
        xor_val &= xor_val - 1;
        count += 1;
    }
    return count;
}

/// バイト配列のハミング距離
pub fn hammingDistanceBytes(a: []const u8, b: []const u8) u32 {
    const len = if (a.len < b.len) a.len else b.len;
    var dist: u32 = 0;
    for (0..len) |i| {
        dist += hammingDistance(@as(u32, a[i]), @as(u32, b[i]));
    }
    return dist;
}

// ---- Internet Checksum (RFC 1071) ----
// IP, TCP, UDP ヘッダチェックサム

pub fn internetChecksum(data: []const u8) u16 {
    var sum: u32 = 0;

    var i: usize = 0;
    while (i + 1 < data.len) {
        const word: u32 = @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
        sum += word;
        i += 2;
    }

    // 奇数バイトの処理
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // キャリーの折り返し
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}

// ---- 一括表示 ----

/// 全チェックサムを計算して表示
pub fn printChecksums(data: []const u8) void {
    vga.setColor(.yellow, .black);
    vga.write("Checksums for ");
    fmt.printDec(data.len);
    vga.write(" bytes:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Adler-32:     0x");
    fmt.printHex32(adler32(data));
    vga.putChar('\n');

    vga.write("  Fletcher-16:  0x");
    fmt.printHex16(fletcher16(data));
    vga.putChar('\n');

    vga.write("  Fletcher-32:  0x");
    fmt.printHex32(fletcher32(data));
    vga.putChar('\n');

    vga.write("  XOR-8:        0x");
    fmt.printHex8(xorChecksum(data));
    vga.putChar('\n');

    vga.write("  CRC-16:       0x");
    fmt.printHex16(crc16(data));
    vga.putChar('\n');

    vga.write("  CRC-16(fast): 0x");
    fmt.printHex16(crc16Fast(data));
    vga.putChar('\n');

    vga.write("  Internet:     0x");
    fmt.printHex16(internetChecksum(data));
    vga.putChar('\n');

    vga.write("  Parity(even): ");
    if (parityBytes(data)) vga.write("OK") else vga.write("FAIL");
    vga.putChar('\n');
}

// ---- デモ ----

pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Checksum Demo ===\n");
    vga.setColor(.light_grey, .black);

    // テストデータ
    const test_data = "Hello, World!";
    vga.write("Data: '");
    vga.write(test_data);
    vga.write("'\n\n");

    printChecksums(test_data);

    // Luhn
    vga.write("\nLuhn algorithm:\n");
    vga.write("  '4539148803436467' valid = ");
    if (luhn("4539148803436467")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    vga.write("  '1234567890' valid = ");
    if (luhn("1234567890")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    vga.write("  '0' valid = ");
    if (luhn("0")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    // ISBN-10
    vga.write("\nISBN-10:\n");
    vga.write("  '0306406152' valid = ");
    if (isbn10("0306406152")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    vga.write("  '0471958697' valid = ");
    if (isbn10("0471958697")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    // ハミング距離
    vga.write("\nHamming distance:\n");
    vga.write("  dist(0xFF, 0x0F) = ");
    fmt.printDec(hammingDistance(0xFF, 0x0F));
    vga.putChar('\n');

    vga.write("  dist(0xA5, 0x5A) = ");
    fmt.printDec(hammingDistance(0xA5, 0x5A));
    vga.putChar('\n');

    // パリティ
    vga.write("\nParity:\n");
    vga.write("  parity(0x7) = ");
    if (parity(0x7)) vga.write("even") else vga.write("odd");
    vga.putChar('\n');

    vga.write("  parity(0xF) = ");
    if (parity(0xF)) vga.write("even") else vga.write("odd");
    vga.putChar('\n');

    // CRC 比較
    vga.write("\nCRC comparison:\n");
    const c1 = crc16(test_data);
    const c2 = crc16Fast(test_data);
    vga.write("  crc16 = 0x");
    fmt.printHex16(c1);
    vga.write(", crc16Fast = 0x");
    fmt.printHex16(c2);
    vga.write(if (c1 == c2) " (match)\n" else " (MISMATCH!)\n");
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Checksum Module:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Adler-32, Fletcher-16/32, XOR, CRC-16\n");
    vga.write("  Luhn, ISBN-10, Internet Checksum\n");
    vga.write("  Parity, Hamming distance\n");
}
