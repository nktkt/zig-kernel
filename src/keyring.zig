// 鍵管理 (Keyring)
//
// カーネル内鍵リング。対称鍵、パスワード、セッション鍵の管理。
// 鍵の追加・取得・削除・失効・有効期限管理。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const crypto = @import("crypto.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// 最大鍵数
const MAX_KEYS: usize = 16;

/// 鍵データの最大サイズ
const MAX_KEY_DATA: usize = 64;

/// 鍵ラベルの最大長
const MAX_KEY_LABEL: usize = 16;

/// 無期限を示す値
pub const NO_EXPIRY: u64 = 0;

// ===========================================================================
// 鍵タイプ
// ===========================================================================

pub const KeyType = enum(u8) {
    symmetric = 0,
    password = 1,
    session = 2,

    pub fn name(self: KeyType) []const u8 {
        return switch (self) {
            .symmetric => "symmetric",
            .password => "password",
            .session => "session",
        };
    }
};

/// 鍵の状態
pub const KeyState = enum(u8) {
    active = 0,
    revoked = 1,
    expired = 2,

    pub fn name(self: KeyState) []const u8 {
        return switch (self) {
            .active => "active",
            .revoked => "revoked",
            .expired => "expired",
        };
    }
};

// ===========================================================================
// 鍵構造体
// ===========================================================================

pub const Key = struct {
    /// 鍵 ID (ユニーク)
    id: u16,
    /// 鍵タイプ
    key_type: KeyType,
    /// 所有者 UID
    owner_uid: u16,
    /// 鍵データ
    data: [MAX_KEY_DATA]u8,
    data_len: usize,
    /// 鍵ラベル (オプション)
    label: [MAX_KEY_LABEL]u8,
    label_len: usize,
    /// 有効期限 (PIT ticks, 0 = 無期限)
    expiry_tick: u64,
    /// 作成時刻
    created_tick: u64,
    /// 鍵の状態
    state: KeyState,
    /// 使用中フラグ
    used: bool,
};

// ===========================================================================
// グローバル鍵リング
// ===========================================================================

var keys: [MAX_KEYS]Key = initKeys();
var next_key_id: u16 = 1;

fn initKeys() [MAX_KEYS]Key {
    var arr: [MAX_KEYS]Key = undefined;
    for (&arr) |*k| {
        k.used = false;
        k.id = 0;
        k.key_type = .symmetric;
        k.owner_uid = 0;
        k.data = @splat(0);
        k.data_len = 0;
        k.label = @splat(0);
        k.label_len = 0;
        k.expiry_tick = NO_EXPIRY;
        k.created_tick = 0;
        k.state = .active;
    }
    return arr;
}

// ===========================================================================
// 鍵管理 API
// ===========================================================================

/// 鍵を追加
pub fn addKey(key_type: KeyType, data: []const u8, owner: u16) ?u16 {
    // 期限切れ鍵を先に回収
    expireKeys();

    for (&keys) |*k| {
        if (!k.used) {
            k.used = true;
            k.id = next_key_id;
            k.key_type = key_type;
            k.owner_uid = owner;
            k.data_len = @min(data.len, MAX_KEY_DATA);
            @memcpy(k.data[0..k.data_len], data[0..k.data_len]);
            if (k.data_len < MAX_KEY_DATA) {
                @memset(k.data[k.data_len..MAX_KEY_DATA], 0);
            }
            k.label_len = 0;
            k.label = @splat(0);
            k.expiry_tick = NO_EXPIRY;
            k.created_tick = pit.getTicks();
            k.state = .active;

            const id = next_key_id;
            next_key_id +%= 1;
            if (next_key_id == 0) next_key_id = 1;
            return id;
        }
    }
    return null; // 満杯
}

/// ラベル付きで鍵を追加
pub fn addKeyLabeled(
    key_type: KeyType,
    data: []const u8,
    owner: u16,
    label: []const u8,
) ?u16 {
    const id = addKey(key_type, data, owner);
    if (id == null) return null;

    const k = findKeyMut(id.?);
    if (k != null) {
        k.?.label_len = @min(label.len, MAX_KEY_LABEL);
        @memcpy(k.?.label[0..k.?.label_len], label[0..k.?.label_len]);
    }
    return id;
}

/// 有効期限付きで鍵を追加
pub fn addKeyWithExpiry(
    key_type: KeyType,
    data: []const u8,
    owner: u16,
    ttl_ticks: u64,
) ?u16 {
    const id = addKey(key_type, data, owner);
    if (id == null) return null;

    const k = findKeyMut(id.?);
    if (k != null) {
        k.?.expiry_tick = pit.getTicks() + ttl_ticks;
    }
    return id;
}

/// 鍵を取得 (読み取り専用)
pub fn getKey(id: u16) ?*const Key {
    for (&keys) |*k| {
        if (k.used and k.id == id and k.state == .active) {
            // 期限チェック
            if (k.expiry_tick != NO_EXPIRY and pit.getTicks() > k.expiry_tick) {
                k.state = .expired;
                return null;
            }
            return k;
        }
    }
    return null;
}

/// 鍵を削除
pub fn removeKey(id: u16) bool {
    for (&keys) |*k| {
        if (k.used and k.id == id) {
            // データをゼロクリア (セキュリティ)
            @memset(&k.data, 0);
            k.data_len = 0;
            k.used = false;
            return true;
        }
    }
    return false;
}

/// 鍵を失効 (削除はしないが使用不可にする)
pub fn revokeKey(id: u16) bool {
    const k = findKeyMut(id);
    if (k == null) return false;
    k.?.state = .revoked;
    return true;
}

/// タイプで鍵を検索 (最初に見つかった鍵の ID を返す)
pub fn searchByType(key_type: KeyType) ?u16 {
    expireKeys();
    for (&keys) |*k| {
        if (k.used and k.key_type == key_type and k.state == .active) {
            return k.id;
        }
    }
    return null;
}

/// ラベルで鍵を検索
pub fn searchByLabel(label: []const u8) ?u16 {
    expireKeys();
    for (&keys) |*k| {
        if (k.used and k.state == .active and k.label_len == label.len) {
            if (strEql(k.label[0..k.label_len], label)) {
                return k.id;
            }
        }
    }
    return null;
}

/// 所有者の鍵をすべて削除
pub fn removeByOwner(owner_uid: u16) u32 {
    var removed: u32 = 0;
    for (&keys) |*k| {
        if (k.used and k.owner_uid == owner_uid) {
            @memset(&k.data, 0);
            k.used = false;
            removed += 1;
        }
    }
    return removed;
}

// ===========================================================================
// セッション鍵
// ===========================================================================

/// ログイン時のセッション鍵を生成
pub fn createSessionKey(owner_uid: u16, ttl_ticks: u64) ?u16 {
    // PRNG からランダムデータを生成
    var session_data: [32]u8 = undefined;
    crypto.randFill(&session_data);

    return addKeyWithExpiry(.session, &session_data, owner_uid, ttl_ticks);
}

/// 指定 UID のアクティブなセッション鍵を取得
pub fn getSessionKey(owner_uid: u16) ?u16 {
    expireKeys();
    for (&keys) |*k| {
        if (k.used and
            k.key_type == .session and
            k.owner_uid == owner_uid and
            k.state == .active)
        {
            return k.id;
        }
    }
    return null;
}

/// 指定 UID のセッション鍵をすべて失効
pub fn revokeSessionKeys(owner_uid: u16) u32 {
    var count: u32 = 0;
    for (&keys) |*k| {
        if (k.used and
            k.key_type == .session and
            k.owner_uid == owner_uid and
            k.state == .active)
        {
            k.state = .revoked;
            count += 1;
        }
    }
    return count;
}

// ===========================================================================
// 有効期限管理
// ===========================================================================

/// 期限切れ鍵を処理
pub fn expireKeys() void {
    const now = pit.getTicks();
    for (&keys) |*k| {
        if (k.used and k.state == .active and
            k.expiry_tick != NO_EXPIRY and now > k.expiry_tick)
        {
            k.state = .expired;
        }
    }
}

/// 失効・期限切れ鍵を削除してスロットを空ける
pub fn purgeInactive() u32 {
    var purged: u32 = 0;
    for (&keys) |*k| {
        if (k.used and (k.state == .revoked or k.state == .expired)) {
            @memset(&k.data, 0);
            k.used = false;
            purged += 1;
        }
    }
    return purged;
}

// ===========================================================================
// 統計
// ===========================================================================

/// アクティブな鍵の数を取得
pub fn getActiveCount() u32 {
    expireKeys();
    var count: u32 = 0;
    for (&keys) |*k| {
        if (k.used and k.state == .active) count += 1;
    }
    return count;
}

/// 全鍵の数を取得 (失効・期限切れ含む)
pub fn getTotalCount() u32 {
    var count: u32 = 0;
    for (&keys) |*k| {
        if (k.used) count += 1;
    }
    return count;
}

// ===========================================================================
// 表示
// ===========================================================================

/// 全鍵を表示
pub fn printKeys() void {
    expireKeys();

    vga.setColor(.yellow, .black);
    vga.write("=== Keyring ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&keys) |*k| {
        if (!k.used) continue;

        // 状態に応じた色
        switch (k.state) {
            .active => vga.setColor(.light_green, .black),
            .revoked => vga.setColor(.light_red, .black),
            .expired => vga.setColor(.dark_grey, .black),
        }

        vga.write("  key#");
        printDecU16(k.id);
        vga.write(" [");
        vga.write(k.key_type.name());
        vga.write("] ");

        vga.setColor(.light_grey, .black);
        vga.write("owner=");
        printDecU16(k.owner_uid);
        vga.write(" len=");
        printDecU32(@as(u32, @truncate(k.data_len)));
        vga.write(" state=");
        vga.write(k.state.name());

        // ラベル
        if (k.label_len > 0) {
            vga.write(" \"");
            vga.write(k.label[0..k.label_len]);
            vga.write("\"");
        }

        // 有効期限
        if (k.expiry_tick != NO_EXPIRY) {
            const now = pit.getTicks();
            if (now < k.expiry_tick) {
                vga.write(" ttl=");
                printDecU64((k.expiry_tick - now) / 1000);
                vga.write("s");
            } else {
                vga.setColor(.dark_grey, .black);
                vga.write(" (expired)");
            }
        }

        vga.putChar('\n');
        count += 1;
    }

    if (count == 0) {
        vga.write("  (empty)\n");
    }

    vga.setColor(.light_grey, .black);
    vga.write("Active: ");
    printDecU32(getActiveCount());
    vga.write("/");
    printDecU32(@as(u32, MAX_KEYS));
    vga.putChar('\n');
}

/// 鍵情報をシリアルに出力
pub fn printKeysSerial() void {
    expireKeys();
    serial.write("[KEYRING] ");
    serialPrintDec(@as(usize, getActiveCount()));
    serial.write(" active keys\n");

    for (&keys) |*k| {
        if (!k.used) continue;
        serial.write("  key#");
        serialPrintDec(@as(usize, k.id));
        serial.write(" type=");
        serial.write(k.key_type.name());
        serial.write(" state=");
        serial.write(k.state.name());
        serial.putChar('\n');
    }
}

// ===========================================================================
// 内部ヘルパー
// ===========================================================================

fn findKeyMut(id: u16) ?*Key {
    for (&keys) |*k| {
        if (k.used and k.id == id) return k;
    }
    return null;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
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

fn printDecU64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
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

fn serialPrintDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
