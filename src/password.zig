// パスワードハッシュと検証
//
// ソルト生成、反復ハッシュ (PBKDF2 風)、パスワード強度チェック。
// SHA-256 ベースの鍵導出を使用。

const sha256 = @import("sha256.zig");
const crypto = @import("crypto.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// ソルトサイズ (128 bits)
pub const SALT_SIZE: usize = 16;

/// ハッシュサイズ (SHA-256 = 32 bytes)
pub const HASH_SIZE: usize = sha256.DIGEST_SIZE;

/// デフォルトの反復回数
pub const DEFAULT_ITERATIONS: u32 = 1000;

/// 最小パスワード長
pub const MIN_PASSWORD_LEN: usize = 4;

/// 最大パスワード長
pub const MAX_PASSWORD_LEN: usize = 64;

// ===========================================================================
// パスワード強度
// ===========================================================================

pub const Strength = enum(u8) {
    weak = 0,
    medium = 1,
    strong = 2,

    pub fn name(self: Strength) []const u8 {
        return switch (self) {
            .weak => "weak",
            .medium => "medium",
            .strong => "strong",
        };
    }
};

/// パスワード強度情報
pub const StrengthInfo = struct {
    strength: Strength,
    has_length: bool, // 8文字以上
    has_uppercase: bool,
    has_lowercase: bool,
    has_digit: bool,
    has_special: bool,
    score: u8, // 0-5 のスコア
};

// ===========================================================================
// ソルト生成
// ===========================================================================

/// PRNG からソルトを生成
pub fn generateSalt() [SALT_SIZE]u8 {
    var salt: [SALT_SIZE]u8 = undefined;
    crypto.randFill(&salt);
    return salt;
}

/// 指定シードでソルトを生成 (再現可能)
pub fn generateSaltWithSeed(seed_val: u32) [SALT_SIZE]u8 {
    const old_state = getSavedState();
    crypto.seed(seed_val);
    var salt: [SALT_SIZE]u8 = undefined;
    crypto.randFill(&salt);
    crypto.seed(old_state);
    return salt;
}

/// 現在の PRNG 状態を保存用に取得 (crypto.rand() を呼んで推測)
fn getSavedState() u32 {
    // 軽量な方法: 現在の rand 値をシードとして使用
    return crypto.rand();
}

// ===========================================================================
// パスワードハッシュ (PBKDF2 風の反復ハッシュ)
// ===========================================================================

/// パスワードをハッシュ化 (salt + password を N 回反復ハッシュ)
///
/// derived_key = H^N(salt || password)
/// ここで H^N は SHA-256 を N 回適用
pub fn hashPassword(password: []const u8, salt: [SALT_SIZE]u8, iterations: u32) [HASH_SIZE]u8 {
    // 初回: H(salt || password)
    var ctx = sha256.Context.init();
    ctx.update(&salt);
    ctx.update(password);
    var result = ctx.final();

    // 反復: H(prev_hash || salt || password)
    var i: u32 = 1;
    while (i < iterations) : (i += 1) {
        var iter_ctx = sha256.Context.init();
        iter_ctx.update(&result);
        iter_ctx.update(&salt);
        iter_ctx.update(password);
        const next = iter_ctx.final();
        // XOR 累積 (PBKDF2 方式)
        for (0..HASH_SIZE) |j| {
            result[j] ^= next[j];
        }
    }

    return result;
}

/// パスワードを検証
pub fn verifyPassword(
    password: []const u8,
    salt: [SALT_SIZE]u8,
    iterations: u32,
    stored_hash: [HASH_SIZE]u8,
) bool {
    const computed = hashPassword(password, salt, iterations);
    return constantTimeEqual(&computed, &stored_hash);
}

/// 定時間比較
fn constantTimeEqual(a: *const [HASH_SIZE]u8, b: *const [HASH_SIZE]u8) bool {
    var diff: u8 = 0;
    for (a, b) |ab, bb| {
        diff |= ab ^ bb;
    }
    return diff == 0;
}

// ===========================================================================
// パスワード強度チェック
// ===========================================================================

/// パスワードの強度をチェック
pub fn checkStrength(password: []const u8) Strength {
    const info = analyzeStrength(password);
    return info.strength;
}

/// パスワードの強度を詳細分析
pub fn analyzeStrength(password: []const u8) StrengthInfo {
    var info: StrengthInfo = .{
        .strength = .weak,
        .has_length = false,
        .has_uppercase = false,
        .has_lowercase = false,
        .has_digit = false,
        .has_special = false,
        .score = 0,
    };

    if (password.len == 0) return info;

    // 長さチェック
    info.has_length = password.len >= 8;
    if (info.has_length) info.score += 1;

    // 文字種別チェック
    for (password) |c| {
        if (c >= 'A' and c <= 'Z') {
            if (!info.has_uppercase) {
                info.has_uppercase = true;
                info.score += 1;
            }
        } else if (c >= 'a' and c <= 'z') {
            if (!info.has_lowercase) {
                info.has_lowercase = true;
                info.score += 1;
            }
        } else if (c >= '0' and c <= '9') {
            if (!info.has_digit) {
                info.has_digit = true;
                info.score += 1;
            }
        } else {
            // 特殊文字 (ASCII 印字可能文字のうち英数字以外)
            if (!info.has_special) {
                info.has_special = true;
                info.score += 1;
            }
        }
    }

    // 強度判定
    if (info.score >= 4 and info.has_length) {
        info.strength = .strong;
    } else if (info.score >= 2) {
        info.strength = .medium;
    } else {
        info.strength = .weak;
    }

    return info;
}

// ===========================================================================
// パスワードストレージ (最大 8 エントリ)
// ===========================================================================

const MAX_STORED: usize = 8;

const StoredPassword = struct {
    uid: u16,
    salt: [SALT_SIZE]u8,
    hash_val: [HASH_SIZE]u8,
    iterations: u32,
    used: bool,
};

var stored_passwords: [MAX_STORED]StoredPassword = initStored();

fn initStored() [MAX_STORED]StoredPassword {
    var arr: [MAX_STORED]StoredPassword = undefined;
    for (&arr) |*entry| {
        entry.used = false;
        entry.uid = 0;
        entry.salt = @splat(0);
        entry.hash_val = @splat(0);
        entry.iterations = 0;
    }
    return arr;
}

/// UID のパスワードを登録
pub fn storePassword(uid: u16, password: []const u8) bool {
    // 既存エントリを検索
    for (&stored_passwords) |*entry| {
        if (entry.used and entry.uid == uid) {
            const salt = generateSalt();
            entry.salt = salt;
            entry.iterations = DEFAULT_ITERATIONS;
            entry.hash_val = hashPassword(password, salt, DEFAULT_ITERATIONS);
            return true;
        }
    }
    // 空きスロットを検索
    for (&stored_passwords) |*entry| {
        if (!entry.used) {
            entry.used = true;
            entry.uid = uid;
            entry.salt = generateSalt();
            entry.iterations = DEFAULT_ITERATIONS;
            entry.hash_val = hashPassword(password, entry.salt, DEFAULT_ITERATIONS);
            return true;
        }
    }
    return false; // ストレージ満杯
}

/// UID のパスワードを検証
pub fn authenticateUser(uid: u16, password: []const u8) bool {
    for (&stored_passwords) |*entry| {
        if (entry.used and entry.uid == uid) {
            return verifyPassword(password, entry.salt, entry.iterations, entry.hash_val);
        }
    }
    return false; // UID 未登録
}

/// UID のパスワードを削除
pub fn removePassword(uid: u16) bool {
    for (&stored_passwords) |*entry| {
        if (entry.used and entry.uid == uid) {
            entry.used = false;
            entry.salt = @splat(0);
            entry.hash_val = @splat(0);
            return true;
        }
    }
    return false;
}

// ===========================================================================
// 表示ユーティリティ
// ===========================================================================

/// パスワード強度を VGA に表示
pub fn printStrength(password: []const u8) void {
    const info = analyzeStrength(password);

    vga.setColor(.light_cyan, .black);
    vga.write("Password strength: ");

    switch (info.strength) {
        .weak => {
            vga.setColor(.light_red, .black);
            vga.write("WEAK");
        },
        .medium => {
            vga.setColor(.yellow, .black);
            vga.write("MEDIUM");
        },
        .strong => {
            vga.setColor(.light_green, .black);
            vga.write("STRONG");
        },
    }

    vga.setColor(.light_grey, .black);
    vga.write(" (score: ");
    printDecU8(info.score);
    vga.write("/5)\n");

    // 詳細
    printCheckMark(info.has_length, "8+ characters");
    printCheckMark(info.has_uppercase, "uppercase");
    printCheckMark(info.has_lowercase, "lowercase");
    printCheckMark(info.has_digit, "digits");
    printCheckMark(info.has_special, "special chars");
}

fn printCheckMark(ok: bool, label: []const u8) void {
    vga.write("  ");
    if (ok) {
        vga.setColor(.light_green, .black);
        vga.write("[+] ");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("[-] ");
    }
    vga.setColor(.light_grey, .black);
    vga.write(label);
    vga.putChar('\n');
}

/// 格納済みパスワード一覧を表示
pub fn printStored() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Stored Passwords ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&stored_passwords) |*entry| {
        if (entry.used) {
            vga.write("  UID ");
            printDecU16(entry.uid);
            vga.write(": iterations=");
            printDecU32(entry.iterations);
            vga.write(" salt=");
            printHexBytes(entry.salt[0..4]);
            vga.write("...\n");
            count += 1;
        }
    }

    if (count == 0) {
        vga.write("  (none)\n");
    }
}

/// ハッシュ値を VGA に16進数表示
pub fn printPasswordHash(h: [HASH_SIZE]u8) void {
    const hex = "0123456789abcdef";
    for (h) |byte| {
        vga.putChar(hex[byte >> 4]);
        vga.putChar(hex[byte & 0x0F]);
    }
}

fn printHexBytes(data: []const u8) void {
    const hex = "0123456789abcdef";
    for (data) |byte| {
        vga.putChar(hex[byte >> 4]);
        vga.putChar(hex[byte & 0x0F]);
    }
}

fn printDecU8(n: u8) void {
    printDecU32(@as(u32, n));
}

fn printDecU16(n: u16) void {
    printDecU32(@as(u32, n));
}

fn printDecU32(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
