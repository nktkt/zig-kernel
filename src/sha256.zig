// SHA-256 暗号学的ハッシュ関数
//
// FIPS 180-4 準拠の SHA-256 実装。
// ストリーミング API (init/update/final) とワンショット hash() を提供。

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// SHA-256 ブロックサイズ (512 bits = 64 bytes)
pub const BLOCK_SIZE: usize = 64;

/// SHA-256 ダイジェストサイズ (256 bits = 32 bytes)
pub const DIGEST_SIZE: usize = 32;

/// 初期ハッシュ値 (最初の8つの素数の平方根の小数部分)
const H_INIT: [8]u32 = .{
    0x6a09e667, // sqrt(2)
    0xbb67ae85, // sqrt(3)
    0x3c6ef372, // sqrt(5)
    0xa54ff53a, // sqrt(7)
    0x510e527f, // sqrt(11)
    0x9b05688c, // sqrt(13)
    0x1f83d9ab, // sqrt(17)
    0x5be0cd19, // sqrt(19)
};

/// ラウンド定数 (最初の64個の素数の立方根の小数部分)
const K: [64]u32 = .{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

// ===========================================================================
// SHA-256 コンテキスト (ストリーミング API)
// ===========================================================================

pub const Context = struct {
    /// 現在のハッシュ状態 (8 x 32-bit ワード)
    state: [8]u32,
    /// 未処理データのバッファ (最大 64 バイト)
    buffer: [BLOCK_SIZE]u8,
    /// バッファ内のデータ長
    buf_len: usize,
    /// 処理済みの合計バイト数
    total_len: u64,

    /// コンテキストを初期化
    pub fn init() Context {
        return .{
            .state = H_INIT,
            .buffer = @splat(0),
            .buf_len = 0,
            .total_len = 0,
        };
    }

    /// データを追加 (ストリーミング)
    pub fn update(self: *Context, data: []const u8) void {
        var offset: usize = 0;
        self.total_len += data.len;

        // バッファに残りがある場合、まずバッファを埋める
        if (self.buf_len > 0) {
            const needed = BLOCK_SIZE - self.buf_len;
            if (data.len < needed) {
                // データが足りない — バッファに追加して終了
                @memcpy(self.buffer[self.buf_len .. self.buf_len + data.len], data);
                self.buf_len += data.len;
                return;
            }
            // バッファを満たしてブロック処理
            @memcpy(self.buffer[self.buf_len..BLOCK_SIZE], data[0..needed]);
            processBlock(&self.state, &self.buffer);
            self.buf_len = 0;
            offset = needed;
        }

        // 残りデータから完全なブロックを処理
        while (offset + BLOCK_SIZE <= data.len) {
            var block: [BLOCK_SIZE]u8 = undefined;
            @memcpy(&block, data[offset .. offset + BLOCK_SIZE]);
            processBlock(&self.state, &block);
            offset += BLOCK_SIZE;
        }

        // 余りをバッファに保存
        const remaining = data.len - offset;
        if (remaining > 0) {
            @memcpy(self.buffer[0..remaining], data[offset .. offset + remaining]);
            self.buf_len = remaining;
        }
    }

    /// ハッシュを確定し、32 バイトのダイジェストを返す
    pub fn final(self: *Context) [DIGEST_SIZE]u8 {
        // パディング: 1 ビット + ゼロ + 64-bit 長さ (big-endian)
        const total_bits: u64 = self.total_len * 8;

        // 0x80 バイトを追加
        self.buffer[self.buf_len] = 0x80;
        self.buf_len += 1;

        // パディングゼロ埋め
        if (self.buf_len > 56) {
            // 長さフィールドが収まらない — 現ブロックをゼロ埋めして処理
            @memset(self.buffer[self.buf_len..BLOCK_SIZE], 0);
            processBlock(&self.state, &self.buffer);
            self.buf_len = 0;
        }

        // 56 バイトまでゼロ埋め
        @memset(self.buffer[self.buf_len..56], 0);

        // 長さ (ビット数) を big-endian で末尾 8 バイトに書き込み
        self.buffer[56] = @truncate((total_bits >> 56) & 0xFF);
        self.buffer[57] = @truncate((total_bits >> 48) & 0xFF);
        self.buffer[58] = @truncate((total_bits >> 40) & 0xFF);
        self.buffer[59] = @truncate((total_bits >> 32) & 0xFF);
        self.buffer[60] = @truncate((total_bits >> 24) & 0xFF);
        self.buffer[61] = @truncate((total_bits >> 16) & 0xFF);
        self.buffer[62] = @truncate((total_bits >> 8) & 0xFF);
        self.buffer[63] = @truncate(total_bits & 0xFF);

        processBlock(&self.state, &self.buffer);

        // 状態を big-endian バイト列に変換
        var digest: [DIGEST_SIZE]u8 = undefined;
        for (self.state, 0..) |word, i| {
            digest[i * 4 + 0] = @truncate((word >> 24) & 0xFF);
            digest[i * 4 + 1] = @truncate((word >> 16) & 0xFF);
            digest[i * 4 + 2] = @truncate((word >> 8) & 0xFF);
            digest[i * 4 + 3] = @truncate(word & 0xFF);
        }

        return digest;
    }
};

// ===========================================================================
// ワンショット API
// ===========================================================================

/// データ全体の SHA-256 ハッシュを計算
pub fn hash(data: []const u8) [DIGEST_SIZE]u8 {
    var ctx = Context.init();
    ctx.update(data);
    return ctx.final();
}

/// 2 つのハッシュ値を定時間比較 (タイミングサイドチャネル対策)
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
pub fn toHexString(digest: [DIGEST_SIZE]u8) [64]u8 {
    const hex = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2 + 0] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0F];
    }
    return out;
}

// ===========================================================================
// SHA-256 ブロック処理 (圧縮関数)
// ===========================================================================

/// 1 ブロック (64 bytes) を処理
fn processBlock(state: *[8]u32, block: *const [BLOCK_SIZE]u8) void {
    // メッセージスケジュール W[0..63]
    var w: [64]u32 = undefined;

    // W[0..15] はブロックから big-endian で読み取り
    for (0..16) |i| {
        const base = i * 4;
        w[i] = (@as(u32, block[base]) << 24) |
            (@as(u32, block[base + 1]) << 16) |
            (@as(u32, block[base + 2]) << 8) |
            @as(u32, block[base + 3]);
    }

    // W[16..63] はメッセージ拡張
    for (16..64) |i| {
        const s0 = sigma0(w[i - 15]);
        const s1 = sigma1(w[i - 2]);
        w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
    }

    // 作業変数を初期化
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    // 64 ラウンドの圧縮
    for (0..64) |i| {
        const s1 = bigSigma1(e);
        const ch_val = ch(e, f, g);
        const temp1 = h +% s1 +% ch_val +% K[i] +% w[i];
        const s0 = bigSigma0(a);
        const maj_val = maj(a, b, c);
        const temp2 = s0 +% maj_val;

        h = g;
        g = f;
        f = e;
        e = d +% temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 +% temp2;
    }

    // 中間ハッシュに加算
    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}

// ===========================================================================
// SHA-256 論理関数
// ===========================================================================

/// 右ローテート
inline fn rotr(x: u32, comptime n: u5) u32 {
    const m: u5 = @truncate(32 - @as(u6, n));
    return (x >> n) | (x << m);
}

/// Ch(x, y, z) = (x AND y) XOR (NOT x AND z)
inline fn ch(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (~x & z);
}

/// Maj(x, y, z) = (x AND y) XOR (x AND z) XOR (y AND z)
inline fn maj(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

/// Sigma_0(x) = ROTR^2(x) XOR ROTR^13(x) XOR ROTR^22(x)
inline fn bigSigma0(x: u32) u32 {
    return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
}

/// Sigma_1(x) = ROTR^6(x) XOR ROTR^11(x) XOR ROTR^25(x)
inline fn bigSigma1(x: u32) u32 {
    return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
}

/// sigma_0(x) = ROTR^7(x) XOR ROTR^18(x) XOR SHR^3(x)
inline fn sigma0(x: u32) u32 {
    return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
}

/// sigma_1(x) = ROTR^17(x) XOR ROTR^19(x) XOR SHR^10(x)
inline fn sigma1(x: u32) u32 {
    return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
}

// ===========================================================================
// ダイジェスト表示ユーティリティ
// ===========================================================================

/// SHA-256 ハッシュの概要を VGA に出力
pub fn printDigest(data: []const u8) void {
    vga.setColor(.light_cyan, .black);
    vga.write("SHA-256: ");
    vga.setColor(.light_grey, .black);
    const digest = hash(data);
    printHash(digest);
    vga.putChar('\n');
}

/// SHA-256 ハッシュの概要をシリアルに出力
pub fn printDigestSerial(data: []const u8) void {
    serial.write("SHA-256: ");
    const digest = hash(data);
    printHashSerial(digest);
    serial.putChar('\n');
}

/// 複数データの連続ハッシュをデモ表示
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== SHA-256 Demo ===\n");

    vga.setColor(.light_grey, .black);
    vga.write("hash(\"\"):    ");
    const empty = hash("");
    printHash(empty);
    vga.putChar('\n');

    vga.write("hash(\"abc\"): ");
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

// ===========================================================================
// バイト配列ユーティリティ
// ===========================================================================

/// バイト配列を別の配列にコピー
pub fn copyDigest(src: [DIGEST_SIZE]u8) [DIGEST_SIZE]u8 {
    var dst: [DIGEST_SIZE]u8 = undefined;
    @memcpy(&dst, &src);
    return dst;
}

/// ダイジェストをゼロで初期化
pub fn zeroDigest() [DIGEST_SIZE]u8 {
    return @splat(0);
}

/// ダイジェストがゼロかどうか
pub fn isZero(digest: [DIGEST_SIZE]u8) bool {
    var acc: u8 = 0;
    for (digest) |b| {
        acc |= b;
    }
    return acc == 0;
}

/// 2 つのダイジェストを XOR
pub fn xorDigest(a: [DIGEST_SIZE]u8, b: [DIGEST_SIZE]u8) [DIGEST_SIZE]u8 {
    var result: [DIGEST_SIZE]u8 = undefined;
    for (a, b, 0..) |ab, bb, i| {
        result[i] = ab ^ bb;
    }
    return result;
}

/// SHA-256 の HMAC 用ブロックサイズを返す
pub fn blockSize() usize {
    return BLOCK_SIZE;
}

/// SHA-256 のダイジェストサイズを返す
pub fn digestSize() usize {
    return DIGEST_SIZE;
}
