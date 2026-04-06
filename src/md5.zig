// MD5 メッセージダイジェスト (RFC 1321)
//
// レガシー互換性のための MD5 実装。
// 注意: MD5 は暗号学的に安全ではない。チェックサム用途のみ推奨。
// ストリーミング API (init/update/final) とワンショット hash() を提供。

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// MD5 ブロックサイズ (512 bits = 64 bytes)
pub const BLOCK_SIZE: usize = 64;

/// MD5 ダイジェストサイズ (128 bits = 16 bytes)
pub const DIGEST_SIZE: usize = 16;

/// 初期状態 (A, B, C, D)
const INIT_A: u32 = 0x67452301;
const INIT_B: u32 = 0xEFCDAB89;
const INIT_C: u32 = 0x98BADCFE;
const INIT_D: u32 = 0x10325476;

/// sin テーブル (abs(sin(i+1)) * 2^32 の整数部, i=0..63)
const T: [64]u32 = .{
    // Round 1
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    // Round 2
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    // Round 3
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    // Round 4
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};

/// 各ラウンドのシフト量
const S: [64]u5 = .{
    // Round 1
    7, 12, 17, 22, 7, 12, 17, 22,
    7, 12, 17, 22, 7, 12, 17, 22,
    // Round 2
    5,  9, 14, 20, 5,  9, 14, 20,
    5,  9, 14, 20, 5,  9, 14, 20,
    // Round 3
    4, 11, 16, 23, 4, 11, 16, 23,
    4, 11, 16, 23, 4, 11, 16, 23,
    // Round 4
    6, 10, 15, 21, 6, 10, 15, 21,
    6, 10, 15, 21, 6, 10, 15, 21,
};

// ===========================================================================
// MD5 コンテキスト (ストリーミング API)
// ===========================================================================

pub const Context = struct {
    /// 現在のハッシュ状態 (A, B, C, D)
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    /// 未処理データのバッファ
    buffer: [BLOCK_SIZE]u8,
    /// バッファ内のデータ長
    buf_len: usize,
    /// 処理済みの合計バイト数
    total_len: u64,

    /// コンテキストを初期化
    pub fn init() Context {
        return .{
            .a = INIT_A,
            .b = INIT_B,
            .c = INIT_C,
            .d = INIT_D,
            .buffer = @splat(0),
            .buf_len = 0,
            .total_len = 0,
        };
    }

    /// データを追加 (ストリーミング)
    pub fn update(self: *Context, data: []const u8) void {
        var offset: usize = 0;
        self.total_len += data.len;

        // バッファの残りを埋める
        if (self.buf_len > 0) {
            const needed = BLOCK_SIZE - self.buf_len;
            if (data.len < needed) {
                @memcpy(self.buffer[self.buf_len .. self.buf_len + data.len], data);
                self.buf_len += data.len;
                return;
            }
            @memcpy(self.buffer[self.buf_len..BLOCK_SIZE], data[0..needed]);
            processBlock(self, &self.buffer);
            self.buf_len = 0;
            offset = needed;
        }

        // 完全なブロックを処理
        while (offset + BLOCK_SIZE <= data.len) {
            var block: [BLOCK_SIZE]u8 = undefined;
            @memcpy(&block, data[offset .. offset + BLOCK_SIZE]);
            processBlock(self, &block);
            offset += BLOCK_SIZE;
        }

        // 余りをバッファに保存
        const remaining = data.len - offset;
        if (remaining > 0) {
            @memcpy(self.buffer[0..remaining], data[offset .. offset + remaining]);
            self.buf_len = remaining;
        }
    }

    /// ハッシュを確定し、16 バイトのダイジェストを返す
    pub fn final(self: *Context) [DIGEST_SIZE]u8 {
        const total_bits: u64 = self.total_len * 8;

        // 0x80 バイトを追加
        self.buffer[self.buf_len] = 0x80;
        self.buf_len += 1;

        // パディング
        if (self.buf_len > 56) {
            @memset(self.buffer[self.buf_len..BLOCK_SIZE], 0);
            processBlock(self, &self.buffer);
            self.buf_len = 0;
        }

        @memset(self.buffer[self.buf_len..56], 0);

        // 長さ (ビット数) を little-endian で末尾 8 バイトに書き込み
        self.buffer[56] = @truncate(total_bits & 0xFF);
        self.buffer[57] = @truncate((total_bits >> 8) & 0xFF);
        self.buffer[58] = @truncate((total_bits >> 16) & 0xFF);
        self.buffer[59] = @truncate((total_bits >> 24) & 0xFF);
        self.buffer[60] = @truncate((total_bits >> 32) & 0xFF);
        self.buffer[61] = @truncate((total_bits >> 40) & 0xFF);
        self.buffer[62] = @truncate((total_bits >> 48) & 0xFF);
        self.buffer[63] = @truncate((total_bits >> 56) & 0xFF);

        processBlock(self, &self.buffer);

        // 状態を little-endian バイト列に変換
        var digest: [DIGEST_SIZE]u8 = undefined;
        packU32LE(&digest, 0, self.a);
        packU32LE(&digest, 4, self.b);
        packU32LE(&digest, 8, self.c);
        packU32LE(&digest, 12, self.d);

        return digest;
    }
};

// ===========================================================================
// ワンショット API
// ===========================================================================

/// データ全体の MD5 ハッシュを計算
pub fn hash(data: []const u8) [DIGEST_SIZE]u8 {
    var ctx = Context.init();
    ctx.update(data);
    return ctx.final();
}

/// 2 つのハッシュ値を定時間比較
pub fn equal(a: [DIGEST_SIZE]u8, b: [DIGEST_SIZE]u8) bool {
    var diff: u8 = 0;
    for (a, b) |ab, bb| {
        diff |= ab ^ bb;
    }
    return diff == 0;
}

/// ハッシュ値を VGA に16進数表示
pub fn printHash(digest: [DIGEST_SIZE]u8) void {
    const hex = "0123456789abcdef";
    for (digest) |byte| {
        vga.putChar(hex[byte >> 4]);
        vga.putChar(hex[byte & 0x0F]);
    }
}

/// ハッシュ値をシリアルに16進数表示
pub fn printHashSerial(digest: [DIGEST_SIZE]u8) void {
    const hex = "0123456789abcdef";
    for (digest) |byte| {
        serial.putChar(hex[byte >> 4]);
        serial.putChar(hex[byte & 0x0F]);
    }
}

/// ハッシュ値を16進数文字列に変換
pub fn toHexString(digest: [DIGEST_SIZE]u8) [32]u8 {
    const hex = "0123456789abcdef";
    var out: [32]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2 + 0] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0F];
    }
    return out;
}

// ===========================================================================
// MD5 ブロック処理
// ===========================================================================

/// 1 ブロック (64 bytes) を処理
fn processBlock(ctx: *Context, block: *const [BLOCK_SIZE]u8) void {
    // ブロックを 16 個の 32-bit ワードに展開 (little-endian)
    var m: [16]u32 = undefined;
    for (0..16) |i| {
        const base = i * 4;
        m[i] = @as(u32, block[base]) |
            (@as(u32, block[base + 1]) << 8) |
            (@as(u32, block[base + 2]) << 16) |
            (@as(u32, block[base + 3]) << 24);
    }

    var a = ctx.a;
    var b = ctx.b;
    var c = ctx.c;
    var d = ctx.d;

    // 64 ステップ (4 ラウンド × 16 操作)
    for (0..64) |i| {
        var f_val: u32 = undefined;
        var g: usize = undefined;

        if (i < 16) {
            // Round 1: F(B, C, D) = (B AND C) OR (NOT B AND D)
            f_val = (b & c) | (~b & d);
            g = i;
        } else if (i < 32) {
            // Round 2: G(B, C, D) = (B AND D) OR (C AND NOT D)
            f_val = (d & b) | (c & ~d);
            g = (5 * i + 1) % 16;
        } else if (i < 48) {
            // Round 3: H(B, C, D) = B XOR C XOR D
            f_val = b ^ c ^ d;
            g = (3 * i + 5) % 16;
        } else {
            // Round 4: I(B, C, D) = C XOR (B OR NOT D)
            f_val = c ^ (b | ~d);
            g = (7 * i) % 16;
        }

        f_val = f_val +% a +% T[i] +% m[g];
        a = d;
        d = c;
        c = b;
        b = b +% rotl(f_val, S[i]);
    }

    ctx.a +%= a;
    ctx.b +%= b;
    ctx.c +%= c;
    ctx.d +%= d;
}

// ===========================================================================
// 内部ユーティリティ
// ===========================================================================

/// 左��ーテート (ランタイム対応)
fn rotl(x: u32, n: u5) u32 {
    const m: u5 = @truncate(32 - @as(u6, n));
    return (x << n) | (x >> m);
}

/// u32 を little-endian でバッファに書き込み
fn packU32LE(buf: *[DIGEST_SIZE]u8, offset: usize, val: u32) void {
    buf[offset + 0] = @truncate(val & 0xFF);
    buf[offset + 1] = @truncate((val >> 8) & 0xFF);
    buf[offset + 2] = @truncate((val >> 16) & 0xFF);
    buf[offset + 3] = @truncate((val >> 24) & 0xFF);
}

// ===========================================================================
// 表示ユーティリティ
// ===========================================================================

/// MD5 ハッシュの概要を VGA に出力
pub fn printDigest(data: []const u8) void {
    vga.setColor(.light_cyan, .black);
    vga.write("MD5: ");
    vga.setColor(.light_grey, .black);
    const digest = hash(data);
    printHash(digest);
    vga.putChar('\n');
}

/// MD5 ハッシュの概要をシリアルに出力
pub fn printDigestSerial(data: []const u8) void {
    serial.write("MD5: ");
    const digest = hash(data);
    printHashSerial(digest);
    serial.putChar('\n');
}

/// ダイジェストがゼロかどうか
pub fn isZero(digest: [DIGEST_SIZE]u8) bool {
    var acc: u8 = 0;
    for (digest) |b| {
        acc |= b;
    }
    return acc == 0;
}

/// ダイジェストをゼロで初期化
pub fn zeroDigest() [DIGEST_SIZE]u8 {
    return @splat(0);
}

/// デモ表示
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== MD5 Demo ===\n");

    vga.setColor(.light_grey, .black);
    vga.write("md5(\"\"):    ");
    const empty = hash("");
    printHash(empty);
    vga.putChar('\n');

    vga.write("md5(\"abc\"): ");
    const abc = hash("abc");
    printHash(abc);
    vga.putChar('\n');

    // ストリーミングデモ
    vga.write("stream(\"a\"+\"bc\"): ");
    var ctx = Context.init();
    ctx.update("a");
    ctx.update("bc");
    const streamed = ctx.final();
    printHash(streamed);
    vga.putChar('\n');

    // 一致確認
    vga.write("match: ");
    if (equal(abc, streamed)) {
        vga.setColor(.light_green, .black);
        vga.write("YES\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("NO\n");
    }
    vga.setColor(.light_grey, .black);
}
