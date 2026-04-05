// Generic LRU Cache — 汎用 LRU キャッシュの実装
//
// 固定サイズのキーバリューキャッシュ。エントリ数がいっぱいになると
// 最も長くアクセスされていないエントリ (LRU) を退避する。
// ブロックキャッシュと DNS キャッシュのインスタンスを提供。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- 定数 ----

const VALUE_SIZE: usize = 64; // 値のバッファサイズ

// ---- キャッシュエントリ ----

fn CacheEntry() type {
    return struct {
        key: u32,
        value: [VALUE_SIZE]u8,
        value_len: u8,
        valid: bool,
        access_tick: u64,
        write_tick: u64, // 書き込み時刻
        dirty: bool, // ライトバック用
    };
}

fn initCacheEntry() CacheEntry() {
    return .{
        .key = 0,
        .value = [_]u8{0} ** VALUE_SIZE,
        .value_len = 0,
        .valid = false,
        .access_tick = 0,
        .write_tick = 0,
        .dirty = false,
    };
}

// ---- 汎用キャッシュ構造体 ----

pub fn Cache(comptime N: usize) type {
    return struct {
        const Self = @This();

        entries: [N]CacheEntry(),
        name: [16]u8,
        name_len: u8,
        // 統計
        hits: u64,
        misses: u64,
        evictions: u64,
        writes: u64,
        invalidations: u64,

        pub fn init(name: []const u8) Self {
            var self: Self = undefined;
            for (&self.entries) |*e| {
                e.* = initCacheEntry();
            }
            self.name = [_]u8{0} ** 16;
            const len = @min(name.len, 16);
            for (0..len) |i| {
                self.name[i] = name[i];
            }
            self.name_len = @intCast(len);
            self.hits = 0;
            self.misses = 0;
            self.evictions = 0;
            self.writes = 0;
            self.invalidations = 0;
            return self;
        }

        /// キーに対応する値を取得 (LRU アクセス時刻を更新)
        pub fn get(self: *Self, key: u32) ?[]const u8 {
            for (&self.entries) |*e| {
                if (e.valid and e.key == key) {
                    e.access_tick = pit.getTicks();
                    self.hits += 1;
                    return e.value[0..e.value_len];
                }
            }
            self.misses += 1;
            return null;
        }

        /// キーに対応する値を設定 (満杯なら LRU を退避)
        pub fn put(self: *Self, key: u32, value: []const u8) void {
            const now = pit.getTicks();
            self.writes += 1;

            // 既存エントリの更新
            for (&self.entries) |*e| {
                if (e.valid and e.key == key) {
                    copyValue(&e.value, &e.value_len, value);
                    e.access_tick = now;
                    e.write_tick = now;
                    e.dirty = true;
                    return;
                }
            }

            // 空きエントリを探す
            for (&self.entries) |*e| {
                if (!e.valid) {
                    e.key = key;
                    copyValue(&e.value, &e.value_len, value);
                    e.valid = true;
                    e.access_tick = now;
                    e.write_tick = now;
                    e.dirty = true;
                    return;
                }
            }

            // LRU エントリを退避
            var lru_idx: usize = 0;
            var lru_tick: u64 = self.entries[0].access_tick;
            for (self.entries[1..], 1..) |e, i| {
                if (e.access_tick < lru_tick) {
                    lru_tick = e.access_tick;
                    lru_idx = i;
                }
            }

            self.evictions += 1;
            self.entries[lru_idx].key = key;
            copyValue(&self.entries[lru_idx].value, &self.entries[lru_idx].value_len, value);
            self.entries[lru_idx].access_tick = now;
            self.entries[lru_idx].write_tick = now;
            self.entries[lru_idx].dirty = true;
        }

        /// キーに対応するエントリを無効化
        pub fn invalidate(self: *Self, key: u32) bool {
            for (&self.entries) |*e| {
                if (e.valid and e.key == key) {
                    e.valid = false;
                    self.invalidations += 1;
                    return true;
                }
            }
            return false;
        }

        /// 全エントリをフラッシュ (クリア)
        pub fn flush(self: *Self) void {
            for (&self.entries) |*e| {
                e.valid = false;
            }
            self.invalidations += self.validCount();
        }

        /// 有効エントリ数
        pub fn validCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.entries) |*e| {
                if (e.valid) count += 1;
            }
            return count;
        }

        /// ダーティエントリ数
        pub fn dirtyCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.entries) |*e| {
                if (e.valid and e.dirty) count += 1;
            }
            return count;
        }

        /// ヒット率を計算 (パーセント * 100)
        pub fn hitRate(self: *const Self) u32 {
            const total = self.hits + self.misses;
            if (total == 0) return 0;
            return @truncate((self.hits * 10000) / total);
        }

        /// 全ダーティエントリをクリーンにマーク
        pub fn markClean(self: *Self) void {
            for (&self.entries) |*e| {
                e.dirty = false;
            }
        }

        /// キャッシュ統計を表示
        pub fn printStats(self: *const Self) void {
            vga.setColor(.yellow, .black);
            vga.write("=== Cache: ");
            vga.write(self.name[0..self.name_len]);
            vga.write(" ===\n");
            vga.setColor(.light_grey, .black);

            vga.write("  Capacity:      ");
            fmt.printDec(N);
            vga.write("\n  Valid entries:  ");
            fmt.printDec(self.validCount());
            vga.write("\n  Dirty entries:  ");
            fmt.printDec(self.dirtyCount());
            vga.write("\n  Hits:          ");
            printU64(self.hits);
            vga.write("  Misses:        ");
            printU64(self.misses);
            vga.write("  Hit rate:      ");
            printHitRate(self.hitRate());
            vga.write("  Evictions:     ");
            printU64(self.evictions);
            vga.write("  Writes:        ");
            printU64(self.writes);
            vga.write("  Invalidations: ");
            printU64(self.invalidations);
        }

        /// エントリ一覧を表示
        pub fn printEntries(self: *const Self) void {
            vga.write("  Key        Len  Dirty  Access tick\n");
            vga.write("  ---------  ---  -----  ----------\n");

            for (&self.entries) |*e| {
                if (!e.valid) continue;

                vga.write("  0x");
                fmt.printHex32(e.key);
                vga.write("  ");
                fmt.printDecPadded(e.value_len, 3);
                vga.write("  ");
                if (e.dirty) {
                    vga.setColor(.light_red, .black);
                    vga.write("yes  ");
                } else {
                    vga.write("no   ");
                }
                vga.setColor(.light_grey, .black);
                vga.write("  ");
                fmt.printDec(@truncate(e.access_tick));
                vga.putChar('\n');
            }
        }
    };
}

// ---- ヘルパー ----

fn copyValue(dst: *[VALUE_SIZE]u8, dst_len: *u8, src: []const u8) void {
    const len: u8 = @truncate(@min(src.len, VALUE_SIZE));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    dst_len.* = len;
}

fn printU64(val: u64) void {
    fmt.printDec(@truncate(val));
    vga.putChar('\n');
}

fn printHitRate(rate_hundredths: u32) void {
    const whole = rate_hundredths / 100;
    const frac = rate_hundredths % 100;
    fmt.printDec(whole);
    vga.putChar('.');
    if (frac < 10) vga.putChar('0');
    fmt.printDec(frac);
    vga.write("%\n");
}

// ---- インスタンス ----

/// ブロックキャッシュ: ディスクブロックのキャッシュ (16 エントリ)
pub var block_cache: Cache(16) = Cache(16).init("block");

/// DNS キャッシュ: 名前解決のキャッシュ (8 エントリ)
pub var dns_cache: Cache(8) = Cache(8).init("dns");

// ---- 便利関数 ----

/// ブロックキャッシュからの読み取り
pub fn readBlock(block_num: u32) ?[]const u8 {
    return block_cache.get(block_num);
}

/// ブロックキャッシュへの書き込み
pub fn writeBlock(block_num: u32, data: []const u8) void {
    block_cache.put(block_num, data);
}

/// DNS キャッシュからの読み取り
pub fn lookupDns(name_hash: u32) ?[]const u8 {
    return dns_cache.get(name_hash);
}

/// DNS キャッシュへの書き込み
pub fn cacheDns(name_hash: u32, ip_data: []const u8) void {
    dns_cache.put(name_hash, ip_data);
}

/// 全キャッシュの統計を表示
pub fn printAllStats() void {
    block_cache.printStats();
    vga.putChar('\n');
    dns_cache.printStats();
}
