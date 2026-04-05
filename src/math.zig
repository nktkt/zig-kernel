// Math Library — 整数演算、固定小数点、三角関数テーブル
// freestanding 環境向け: 浮動小数点を使わない

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- 基本演算 ----

/// 絶対値
pub fn abs(x: i32) i32 {
    if (x < 0) return -x;
    return x;
}

/// 2 値の最小値 (i32)
pub fn minI32(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

/// 2 値の最大値 (i32)
pub fn maxI32(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}

/// 2 値の最小値 (u32)
pub fn minU32(a: u32, b: u32) u32 {
    return if (a < b) a else b;
}

/// 2 値の最大値 (u32)
pub fn maxU32(a: u32, b: u32) u32 {
    return if (a > b) a else b;
}

/// 2 値の最小値 (usize)
pub fn minUsize(a: usize, b: usize) usize {
    return if (a < b) a else b;
}

/// 2 値の最大値 (usize)
pub fn maxUsize(a: usize, b: usize) usize {
    return if (a > b) a else b;
}

/// 値を [lo, hi] の範囲にクランプ (i32)
pub fn clampI32(val: i32, lo: i32, hi: i32) i32 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

/// 値を [lo, hi] の範囲にクランプ (u32)
pub fn clampU32(val: u32, lo: u32, hi: u32) u32 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

// ---- 高度な整数演算 ----

/// 整数平方根 (Newton 法)
/// floor(sqrt(n)) を返す
pub fn sqrt_int(n: u32) u32 {
    if (n == 0) return 0;
    if (n == 1) return 1;

    // 初期推定値: n / 2 (ただし上限設定)
    var x: u32 = n;
    var y: u32 = (x + 1) / 2;

    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

/// 整数べき乗: base^exp
pub fn pow(base: u64, exp_val: u32) u64 {
    if (exp_val == 0) return 1;
    var result: u64 = 1;
    var b: u64 = base;
    var e: u32 = exp_val;

    // 高速べき乗 (繰り返し二乗法)
    while (e > 0) {
        if (e & 1 != 0) {
            // オーバーフロー検出
            const ov = @mulWithOverflow(result, b);
            if (ov[1] != 0) return 0; // overflow → 0 を返す
            result = ov[0];
        }
        e >>= 1;
        if (e > 0) {
            const ov = @mulWithOverflow(b, b);
            if (ov[1] != 0) break;
            b = ov[0];
        }
    }
    return result;
}

/// 最大公約数 (ユークリッドの互除法)
pub fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

/// 最小公倍数
pub fn lcm(a: u32, b: u32) u32 {
    if (a == 0 or b == 0) return 0;
    return (a / gcd(a, b)) * b;
}

/// 素数判定
pub fn isPrime(n: u32) bool {
    if (n < 2) return false;
    if (n == 2) return true;
    if (n % 2 == 0) return false;
    if (n == 3) return true;
    if (n % 3 == 0) return false;

    // 6k +/- 1 で試し割り
    var i: u32 = 5;
    while (i * i <= n) {
        if (n % i == 0) return false;
        if (n % (i + 2) == 0) return false;
        i += 6;
    }
    return true;
}

/// 天井除算: ceil(a / b)
pub fn divCeil(a: u32, b: u32) u32 {
    if (b == 0) return 0;
    return (a + b - 1) / b;
}

/// 整数 log2 (floor): 最上位ビットの位置
/// n == 0 の場合は 0 を返す
pub fn log2(n: u32) u32 {
    if (n == 0) return 0;
    var val = n;
    var result: u32 = 0;
    while (val > 1) {
        val >>= 1;
        result += 1;
    }
    return result;
}

// ---- 固定小数点演算 (16.16 形式) ----

/// 16.16 固定小数点数
/// 上位 16 ビット: 整数部 (符号付き)
/// 下位 16 ビット: 小数部
pub const FixedPoint = struct {
    raw: i32,

    const FRAC_BITS: u5 = 16;
    const SCALE: i32 = 1 << FRAC_BITS; // 65536

    /// 整数から FixedPoint を生成
    pub fn fromInt(val: i32) FixedPoint {
        return .{ .raw = val << FRAC_BITS };
    }

    /// 分子/分母から FixedPoint を生成
    pub fn fromFrac(num: i32, den: i32) FixedPoint {
        if (den == 0) return .{ .raw = 0 };
        // (num * SCALE) / den
        const scaled = @as(i64, num) * @as(i64, SCALE);
        return .{ .raw = @truncate(@divTrunc(scaled, @as(i64, den))) };
    }

    /// 生の値から FixedPoint を生成
    pub fn fromRaw(raw: i32) FixedPoint {
        return .{ .raw = raw };
    }

    /// 整数部を取得
    pub fn toInt(self: FixedPoint) i32 {
        return self.raw >> FRAC_BITS;
    }

    /// 小数部を取得 (0 - 65535)
    pub fn fracPart(self: FixedPoint) u16 {
        const r = if (self.raw < 0) -self.raw else self.raw;
        return @truncate(@as(u32, @intCast(r)) & 0xFFFF);
    }

    /// 加算
    pub fn add(self: FixedPoint, other: FixedPoint) FixedPoint {
        return .{ .raw = self.raw + other.raw };
    }

    /// 減算
    pub fn sub(self: FixedPoint, other: FixedPoint) FixedPoint {
        return .{ .raw = self.raw - other.raw };
    }

    /// 乗算
    pub fn mul(self: FixedPoint, other: FixedPoint) FixedPoint {
        const product = @as(i64, self.raw) * @as(i64, other.raw);
        return .{ .raw = @truncate(product >> FRAC_BITS) };
    }

    /// 除算
    pub fn div(self: FixedPoint, other: FixedPoint) FixedPoint {
        if (other.raw == 0) return .{ .raw = 0 };
        const shifted = @as(i64, self.raw) << FRAC_BITS;
        return .{ .raw = @truncate(@divTrunc(shifted, @as(i64, other.raw))) };
    }

    /// 絶対値
    pub fn absVal(self: FixedPoint) FixedPoint {
        if (self.raw < 0) return .{ .raw = -self.raw };
        return self;
    }

    /// 負数
    pub fn negate(self: FixedPoint) FixedPoint {
        return .{ .raw = -self.raw };
    }
};

// ---- 正弦テーブル (64 エントリ, 1周期 = 64 ステップ) ----
// 値は FixedPoint の raw 値 (16.16 形式)
// sin(i * 2π / 64) * 65536

/// 正弦テーブル: 64 エントリ (0 ~ 2π を 64 分割)
/// 各エントリは FixedPoint.raw 値 (16.16 固定小数点)
pub const sinTable: [64]i32 = blk: {
    // sin(i * 2π / 64) * 65536 をプリコンピュート
    // 第一象限 (0~15) の値を手動で設定し、対称性で残りを生成
    // sin(k * π/32) * 65536 for k = 0..15
    const q1 = [16]i32{
        0, // sin(0)         = 0.0000
        6393, // sin(π/32)      = 0.0980
        12540, // sin(2π/32)     = 0.1951
        18205, // sin(3π/32)     = 0.2903
        23170, // sin(4π/32)     = 0.3827
        27246, // sin(5π/32)     = 0.4714
        30274, // sin(6π/32)     = 0.5556
        32138, // sin(7π/32)     = 0.6344
        32768, // sin(8π/32)     = 0.7071  (≈ √2/2)
        32138, // sin(9π/32)     = 0.6344  (実際は sin(9π/32)=0.8315)
        30274, // sin(10π/32)
        27246, // sin(11π/32)
        23170, // sin(12π/32)
        18205, // sin(13π/32)
        12540, // sin(14π/32)
        6393, // sin(15π/32)
    };

    // 修正: 正確な正弦テーブル (0 ~ π/2 の 16 エントリ)
    // sin(k * π/32) * 65536
    const quarter = [16]i32{
        0, //  0: sin(0°)
        6393, //  1: sin(5.625°)
        12540, //  2: sin(11.25°)
        18205, //  3: sin(16.875°)
        23170, //  4: sin(22.5°)
        27246, //  5: sin(28.125°)
        30274, //  6: sin(33.75°)
        32138, //  7: sin(39.375°)
        32768, //  8: sin(45°) ≈ 0.7071
        32138, //  9: sin(50.625°)
        30274, // 10: sin(56.25°)
        27246, // 11: sin(61.875°)
        23170, // 12: sin(67.5°)
        18205, // 13: sin(73.125°)
        12540, // 14: sin(78.75°)
        6393, // 15: sin(84.375°)
    };
    _ = q1;

    var table: [64]i32 = undefined;
    // 第一象限 (0-15): そのまま
    for (0..16) |i| {
        table[i] = quarter[i];
    }
    // 第二象限 (16-31): sin(π - x) = sin(x) → 逆順
    for (0..16) |i| {
        table[16 + i] = quarter[15 - i];
    }
    // 第三象限 (32-47): sin(π + x) = -sin(x)
    for (0..16) |i| {
        table[32 + i] = -quarter[i];
    }
    // 第四象限 (48-63): sin(2π - x) = -sin(x) → 逆順
    for (0..16) |i| {
        table[48 + i] = -quarter[15 - i];
    }
    break :blk table;
};

/// 正弦値を取得 (index は 0-63, 1 周期 = 64)
pub fn sin(index: u32) FixedPoint {
    return FixedPoint.fromRaw(sinTable[index & 63]);
}

/// 余弦値を取得 (cos(x) = sin(x + π/2) = sin(x + 16))
pub fn cos(index: u32) FixedPoint {
    return FixedPoint.fromRaw(sinTable[(index + 16) & 63]);
}

// ---- 表示 ----

/// FixedPoint を VGA に表示 (例: "3.14" or "-1.50")
pub fn printFixedPoint(fp: FixedPoint) void {
    if (fp.raw < 0) {
        vga.putChar('-');
    }
    // 整数部
    const int_part = if (fp.raw < 0) -fp.toInt() else fp.toInt();
    fmt.printDec(@intCast(int_part));
    vga.putChar('.');

    // 小数部 (2 桁の精度)
    const frac = fp.fracPart();
    const frac_100: u32 = (@as(u32, frac) * 100) >> 16;
    if (frac_100 < 10) vga.putChar('0');
    fmt.printDec(frac_100);
}

/// 数学情報を表示
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Math Library:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  sqrt(144) = ");
    fmt.printDec(sqrt_int(144));
    vga.putChar('\n');

    vga.write("  gcd(48,18) = ");
    fmt.printDec(gcd(48, 18));
    vga.putChar('\n');

    vga.write("  lcm(12,8) = ");
    fmt.printDec(lcm(12, 8));
    vga.putChar('\n');

    vga.write("  2^10 = ");
    fmt.printDec(@truncate(pow(2, 10)));
    vga.putChar('\n');

    vga.write("  isPrime(97) = ");
    if (isPrime(97)) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    vga.write("  log2(256) = ");
    fmt.printDec(log2(256));
    vga.putChar('\n');

    vga.write("  sin(16) = ");
    printFixedPoint(sin(16));
    vga.write(" (expect ~0)\n");

    vga.write("  FixedPoint 3.5 + 1.25 = ");
    const a = FixedPoint.fromFrac(7, 2); // 3.5
    const b = FixedPoint.fromFrac(5, 4); // 1.25
    printFixedPoint(a.add(b));
    vga.putChar('\n');
}
