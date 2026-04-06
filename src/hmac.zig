// HMAC — Hash-based Message Authentication Code (RFC 2104)
//
// SHA-256 ベースの HMAC 実装。
// HMAC(K, m) = H((K' XOR opad) || H((K' XOR ipad) || m))
// ipad = 0x36 繰り返し, opad = 0x5C 繰り返し

const sha256 = @import("sha256.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// HMAC-SHA256 のブロックサイズ (SHA-256 のブロックサイズに合わせる)
pub const BLOCK_SIZE: usize = 64;

/// HMAC-SHA256 の出力サイズ (SHA-256 のダイジェストサイズ)
pub const MAC_SIZE: usize = sha256.DIGEST_SIZE;

/// inner padding バイト
const IPAD_BYTE: u8 = 0x36;

/// outer padding バイト
const OPAD_BYTE: u8 = 0x5C;

// ===========================================================================
// HMAC-SHA256 コンテキスト (ストリーミング API)
// ===========================================================================

pub const Context = struct {
    /// inner hash コンテキスト
    inner: sha256.Context,
    /// outer key (opad XOR key) — final 時に使用
    outer_key_pad: [BLOCK_SIZE]u8,

    /// HMAC コンテキストを初期化
    pub fn init(key: []const u8) Context {
        var ctx: Context = undefined;

        // キーの条件付け: ブロックサイズより長い場合はハッシュ
        var key_block: [BLOCK_SIZE]u8 = @splat(0);
        if (key.len > BLOCK_SIZE) {
            const key_hash = sha256.hash(key);
            @memcpy(key_block[0..sha256.DIGEST_SIZE], &key_hash);
        } else {
            @memcpy(key_block[0..key.len], key);
        }

        // ipad = key XOR 0x36
        var ipad: [BLOCK_SIZE]u8 = undefined;
        for (0..BLOCK_SIZE) |i| {
            ipad[i] = key_block[i] ^ IPAD_BYTE;
        }

        // opad = key XOR 0x5C
        for (0..BLOCK_SIZE) |i| {
            ctx.outer_key_pad[i] = key_block[i] ^ OPAD_BYTE;
        }

        // inner hash を開始: H(ipad || ...)
        ctx.inner = sha256.Context.init();
        ctx.inner.update(&ipad);

        return ctx;
    }

    /// メッセージデータを追加
    pub fn update(self: *Context, data: []const u8) void {
        self.inner.update(data);
    }

    /// HMAC を確定し、MAC 値を返す
    pub fn final(self: *Context) [MAC_SIZE]u8 {
        // inner_hash = H(ipad || message)
        const inner_hash = self.inner.final();

        // outer_hash = H(opad || inner_hash)
        var outer_ctx = sha256.Context.init();
        outer_ctx.update(&self.outer_key_pad);
        outer_ctx.update(&inner_hash);
        return outer_ctx.final();
    }
};

// ===========================================================================
// ワンショット API
// ===========================================================================

/// HMAC-SHA256 を計算
pub fn hmacSha256(key: []const u8, message: []const u8) [MAC_SIZE]u8 {
    var ctx = Context.init(key);
    ctx.update(message);
    return ctx.final();
}

/// HMAC を検証 (定時間比較)
pub fn verify(key: []const u8, message: []const u8, expected_mac: [MAC_SIZE]u8) bool {
    const computed = hmacSha256(key, message);
    return constantTimeEqual(&computed, &expected_mac);
}

/// 定時間比較 (タイミングサイドチャネル対策)
fn constantTimeEqual(a: *const [MAC_SIZE]u8, b: *const [MAC_SIZE]u8) bool {
    var diff: u8 = 0;
    for (a, b) |ab, bb| {
        diff |= ab ^ bb;
    }
    return diff == 0;
}

// ===========================================================================
// キー条件付けユーティリティ
// ===========================================================================

/// キーがブロックサイズに対して適切かどうかを判定
pub fn isKeyValid(key: []const u8) bool {
    // 空キーは非推奨だが技術的には有効
    return key.len > 0;
}

/// キーの条件付けを行い、BLOCK_SIZE のキーブロックを返す
pub fn conditionKey(key: []const u8) [BLOCK_SIZE]u8 {
    var key_block: [BLOCK_SIZE]u8 = @splat(0);
    if (key.len > BLOCK_SIZE) {
        const key_hash = sha256.hash(key);
        @memcpy(key_block[0..sha256.DIGEST_SIZE], &key_hash);
    } else {
        @memcpy(key_block[0..key.len], key);
    }
    return key_block;
}

// ===========================================================================
// 表示ユーティリティ
// ===========================================================================

/// HMAC 値を VGA に16進数表示
pub fn printMac(mac: [MAC_SIZE]u8) void {
    const hex = "0123456789abcdef";
    for (mac) |byte| {
        vga.putChar(hex[byte >> 4]);
        vga.putChar(hex[byte & 0x0F]);
    }
}

/// HMAC 値をシリアルに16進数表示
pub fn printMacSerial(mac: [MAC_SIZE]u8) void {
    const hex = "0123456789abcdef";
    for (mac) |byte| {
        serial.putChar(hex[byte >> 4]);
        serial.putChar(hex[byte & 0x0F]);
    }
}

/// HMAC のデモ表示
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== HMAC-SHA256 Demo ===\n");

    const key = "secret-key";
    const msg = "Hello, World!";

    vga.setColor(.light_grey, .black);
    vga.write("key: \"secret-key\"\n");
    vga.write("msg: \"Hello, World!\"\n");
    vga.write("HMAC: ");
    const mac = hmacSha256(key, msg);
    printMac(mac);
    vga.putChar('\n');

    // 検証デモ
    vga.write("verify: ");
    if (verify(key, msg, mac)) {
        vga.setColor(.light_green, .black);
        vga.write("OK\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("FAIL\n");
    }

    // 改ざん検出デモ
    vga.setColor(.light_grey, .black);
    vga.write("tamper check: ");
    if (!verify(key, "Tampered!", mac)) {
        vga.setColor(.light_green, .black);
        vga.write("detected\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("missed!\n");
    }

    vga.setColor(.light_grey, .black);
}

/// HMAC-SHA256 の概要をシリアルに出力
pub fn printHmacInfo(key: []const u8, message: []const u8) void {
    serial.write("HMAC-SHA256: key_len=");
    serialPrintDec(key.len);
    serial.write(" msg_len=");
    serialPrintDec(message.len);
    serial.write(" mac=");
    const mac = hmacSha256(key, message);
    printMacSerial(mac);
    serial.putChar('\n');
}

/// 数値をシリアルに出力
fn serialPrintDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}
