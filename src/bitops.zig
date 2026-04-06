// Bit Operations — ビット操作ユーティリティ
// popcount, clz, ctz, ffs, fls, 回転, ビットフィールド操作
// freestanding 環境向け: ソフトウェア実装

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 基本ビットカウント ----

/// Population count: セットビット数
pub fn popcount(x: u32) u32 {
    // Brian Kernighan のアルゴリズム
    var val = x;
    var count: u32 = 0;
    while (val != 0) {
        val &= val - 1; // 最下位セットビットをクリア
        count += 1;
    }
    return count;
}

/// Count Leading Zeros: 上位方向のゼロビット数
pub fn clz(x: u32) u32 {
    if (x == 0) return 32;
    var val = x;
    var n: u32 = 0;

    if (val & 0xFFFF0000 == 0) {
        n += 16;
        val <<= 16;
    }
    if (val & 0xFF000000 == 0) {
        n += 8;
        val <<= 8;
    }
    if (val & 0xF0000000 == 0) {
        n += 4;
        val <<= 4;
    }
    if (val & 0xC0000000 == 0) {
        n += 2;
        val <<= 2;
    }
    if (val & 0x80000000 == 0) {
        n += 1;
    }
    return n;
}

/// Count Trailing Zeros: 下位方向のゼロビット数
pub fn ctz(x: u32) u32 {
    if (x == 0) return 32;
    var val = x;
    var n: u32 = 0;

    if (val & 0x0000FFFF == 0) {
        n += 16;
        val >>= 16;
    }
    if (val & 0x000000FF == 0) {
        n += 8;
        val >>= 8;
    }
    if (val & 0x0000000F == 0) {
        n += 4;
        val >>= 4;
    }
    if (val & 0x00000003 == 0) {
        n += 2;
        val >>= 2;
    }
    if (val & 0x00000001 == 0) {
        n += 1;
    }
    return n;
}

/// Find First Set: 最下位セットビットの位置 (1-indexed, 0=なし)
pub fn ffs(x: u32) u32 {
    if (x == 0) return 0;
    return ctz(x) + 1;
}

/// Find Last Set: 最上位セットビットの位置 (1-indexed, 0=なし)
pub fn fls(x: u32) u32 {
    if (x == 0) return 0;
    return 32 - clz(x);
}

// ---- べき乗判定 ----

/// 2 のべき乗か
pub fn isPowerOf2(x: u32) bool {
    return x != 0 and (x & (x - 1)) == 0;
}

/// 次の 2 のべき乗 (x 以上)
pub fn nextPowerOf2(x: u32) u32 {
    if (x == 0) return 1;
    if (isPowerOf2(x)) return x;

    var val = x - 1;
    val |= val >> 1;
    val |= val >> 2;
    val |= val >> 4;
    val |= val >> 8;
    val |= val >> 16;
    return val + 1;
}

/// 2 のべき乗に切り上げ
pub fn roundUpPow2(x: u32) u32 {
    return nextPowerOf2(x);
}

/// 2 のべき乗に切り下げ
pub fn roundDownPow2(x: u32) u32 {
    if (x == 0) return 0;
    var val = x;
    val |= val >> 1;
    val |= val >> 2;
    val |= val >> 4;
    val |= val >> 8;
    val |= val >> 16;
    return val - (val >> 1);
}

// ---- ビット反転 / 回転 ----

/// ビット順序を反転
pub fn reverseBits(x: u32) u32 {
    var val = x;
    // swap odd and even bits
    val = ((val >> 1) & 0x55555555) | ((val & 0x55555555) << 1);
    // swap consecutive pairs
    val = ((val >> 2) & 0x33333333) | ((val & 0x33333333) << 2);
    // swap nibbles
    val = ((val >> 4) & 0x0F0F0F0F) | ((val & 0x0F0F0F0F) << 4);
    // swap bytes
    val = ((val >> 8) & 0x00FF00FF) | ((val & 0x00FF00FF) << 8);
    // swap halves
    val = (val >> 16) | (val << 16);
    return val;
}

/// 左回転
pub fn rotateLeft(x: u32, n: u5) u32 {
    if (n == 0) return x;
    const shift: u5 = @truncate(32 -% @as(u6, n));
    return (x << n) | (x >> shift);
}

/// 右回転
pub fn rotateRight(x: u32, n: u5) u32 {
    if (n == 0) return x;
    const shift: u5 = @truncate(32 -% @as(u6, n));
    return (x >> n) | (x << shift);
}

// ---- ビットフィールド操作 ----

/// ビット抽出: x の offset 位置から len ビットを取得
pub fn extractBits(x: u32, offset: u5, len: u5) u32 {
    if (len == 0) return 0;
    const mask: u32 = (@as(u32, 1) << len) - 1;
    return (x >> offset) & mask;
}

/// ビット挿入: x の offset 位置に val の下位 len ビットを挿入
pub fn insertBits(x: u32, val: u32, offset: u5, len: u5) u32 {
    if (len == 0) return x;
    const mask: u32 = (@as(u32, 1) << len) - 1;
    const clear_mask = ~(mask << offset);
    return (x & clear_mask) | ((val & mask) << offset);
}

/// 特定ビットをセット
pub fn setBit(x: u32, bit: u5) u32 {
    return x | (@as(u32, 1) << bit);
}

/// 特定ビットをクリア
pub fn clearBit(x: u32, bit: u5) u32 {
    return x & ~(@as(u32, 1) << bit);
}

/// 特定ビットをトグル
pub fn toggleBit(x: u32, bit: u5) u32 {
    return x ^ (@as(u32, 1) << bit);
}

/// 特定ビットをテスト
pub fn testBit(x: u32, bit: u5) bool {
    return (x & (@as(u32, 1) << bit)) != 0;
}

// ---- バイト操作 ----

/// バイト順序を反転 (エンディアン変換)
pub fn byteSwap32(x: u32) u32 {
    return ((x & 0xFF000000) >> 24) |
        ((x & 0x00FF0000) >> 8) |
        ((x & 0x0000FF00) << 8) |
        ((x & 0x000000FF) << 24);
}

/// 16 ビットのバイトスワップ
pub fn byteSwap16(x: u16) u16 {
    return (x >> 8) | (x << 8);
}

// ---- ビットマスク生成 ----

/// 下位 n ビットのマスク
pub fn maskLow(n: u5) u32 {
    if (n == 0) return 0;
    if (n >= 32) return 0xFFFFFFFF;
    return (@as(u32, 1) << n) - 1;
}

/// ビット範囲 [lo, hi] のマスク (inclusive)
pub fn maskRange(lo: u5, hi: u5) u32 {
    if (lo > hi) return 0;
    const width: u5 = hi - lo + 1;
    return maskLow(width) << lo;
}

// ---- ハミング距離 ----

/// 2 値のハミング距離 (異なるビット数)
pub fn hammingDistance(a: u32, b: u32) u32 {
    return popcount(a ^ b);
}

// ---- パリティ ----

/// 偶数パリティ: セットビット数が偶数なら true
pub fn evenParity(x: u32) bool {
    return (popcount(x) & 1) == 0;
}

/// 奇数パリティ: セットビット数が奇数なら true
pub fn oddParity(x: u32) bool {
    return (popcount(x) & 1) == 1;
}

// ---- 整数 log2 ----

/// floor(log2(x)), x == 0 の場合は 0
pub fn log2Floor(x: u32) u32 {
    if (x == 0) return 0;
    return 31 - clz(x);
}

/// ceil(log2(x)), x <= 1 の場合は 0
pub fn log2Ceil(x: u32) u32 {
    if (x <= 1) return 0;
    return log2Floor(x - 1) + 1;
}

// ---- ビットフィールド構造体ヘルパー ----

pub const BitField = struct {
    value: u32 = 0,

    pub fn get(self: BitField, offset: u5, len: u5) u32 {
        return extractBits(self.value, offset, len);
    }

    pub fn set(self: *BitField, val: u32, offset: u5, len: u5) void {
        self.value = insertBits(self.value, val, offset, len);
    }

    pub fn setBitAt(self: *BitField, bit: u5) void {
        self.value = setBit(self.value, bit);
    }

    pub fn clearBitAt(self: *BitField, bit: u5) void {
        self.value = clearBit(self.value, bit);
    }

    pub fn testBitAt(self: BitField, bit: u5) bool {
        return testBit(self.value, bit);
    }

    pub fn print(self: BitField) void {
        printBinary(self.value);
    }
};

// ---- 表示 ----

/// 32 ビット値をバイナリ文字列で表示
pub fn printBinary(x: u32) void {
    var i: u5 = 31;
    while (true) {
        if ((x >> i) & 1 == 1) {
            vga.putChar('1');
        } else {
            vga.putChar('0');
        }
        // 8 ビットごとにスペース
        if (i > 0 and i % 8 == 0) {
            vga.putChar(' ');
        }
        if (i == 0) break;
        i -= 1;
    }
}

/// 8 ビット値をバイナリで表示
pub fn printBinary8(x: u8) void {
    var i: u3 = 7;
    while (true) {
        if ((x >> i) & 1 == 1) {
            vga.putChar('1');
        } else {
            vga.putChar('0');
        }
        if (i == 0) break;
        i -= 1;
    }
}

/// ビット操作の結果を表示
pub fn printBitInfo(label: []const u8, val: u32) void {
    vga.write("  ");
    vga.write(label);
    vga.write(" = 0x");
    fmt.printHex32(val);
    vga.write(" = ");
    printBinary(val);
    vga.putChar('\n');
}

// ---- デモ ----

pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Bit Operations Demo ===\n");
    vga.setColor(.light_grey, .black);

    const val: u32 = 0xDEADBEEF;
    vga.write("Value: 0x");
    fmt.printHex32(val);
    vga.write(" = ");
    printBinary(val);
    vga.putChar('\n');

    vga.write("  popcount = ");
    fmt.printDec(popcount(val));
    vga.putChar('\n');

    vga.write("  clz = ");
    fmt.printDec(clz(val));
    vga.putChar('\n');

    vga.write("  ctz = ");
    fmt.printDec(ctz(val));
    vga.putChar('\n');

    vga.write("  ffs = ");
    fmt.printDec(ffs(val));
    vga.putChar('\n');

    vga.write("  fls = ");
    fmt.printDec(fls(val));
    vga.putChar('\n');

    const val2: u32 = 0x100;
    vga.write("\nValue: 0x");
    fmt.printHex32(val2);
    vga.putChar('\n');

    vga.write("  isPowerOf2 = ");
    if (isPowerOf2(val2)) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    vga.write("  nextPowerOf2(100) = ");
    fmt.printDec(nextPowerOf2(100));
    vga.putChar('\n');

    vga.write("  log2Floor(256) = ");
    fmt.printDec(log2Floor(256));
    vga.putChar('\n');

    // ビット反転
    vga.write("\nreverseBits(0x80000001): ");
    printBitInfo("result", reverseBits(0x80000001));

    // 回転
    vga.write("rotateLeft(0xFF, 4): ");
    printBitInfo("result", rotateLeft(0xFF, 4));

    // ビットフィールド
    vga.write("\nBitField operations:\n");
    var bf = BitField{};
    bf.set(0x0F, 4, 4); // bits [4:7] = 0x0F
    bf.set(0x03, 0, 2); // bits [0:1] = 0x03
    vga.write("  After set: ");
    bf.print();
    vga.write(" (0x");
    fmt.printHex32(bf.value);
    vga.write(")\n");

    vga.write("  get(4,4) = ");
    fmt.printDec(bf.get(4, 4));
    vga.putChar('\n');

    // ハミング距離
    vga.write("\nhammingDistance(0xFF, 0x0F) = ");
    fmt.printDec(hammingDistance(0xFF, 0x0F));
    vga.putChar('\n');

    // パリティ
    vga.write("evenParity(0x7) = ");
    if (evenParity(0x7)) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    // バイトスワップ
    vga.write("byteSwap32(0x12345678) = 0x");
    fmt.printHex32(byteSwap32(0x12345678));
    vga.putChar('\n');
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Bit Operations:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  popcount, clz, ctz, ffs, fls\n");
    vga.write("  rotate, reverse, extract, insert\n");
    vga.write("  BitField struct helper\n");
}
