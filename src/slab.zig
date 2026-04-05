// Slab メモリアロケータ — 固定サイズオブジェクト用の高速アロケータ
//
// カーネル内の頻繁に確保/解放されるオブジェクト (タスク記述子, ネットワークバッファ等)
// のために、ページ単位のスラブをビットマップで管理する。

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

const PAGE_SIZE = 4096;

// ---- 定数 ----

const MAX_CACHES = 8;
const MAX_SLABS_PER_CACHE = 4;
const MAX_NAME_LEN = 16;
const MAX_OBJECTS_PER_SLAB = 128; // PAGE_SIZE / 32 = 128 (最小オブジェクト)

// ---- Slab 構造体 ----
// 各 Slab は 1 ページ (4KB) のメモリを管理する

const Slab = struct {
    /// スラブの先頭物理アドレス (ページアラインド)
    page_addr: usize,
    /// このスラブ内のオブジェクト数
    capacity: usize,
    /// 使用中のオブジェクト数
    used_count: usize,
    /// ビットマップ: bit=1 → 使用中, bit=0 → 空き
    /// 128 objects max → 128 bits → 4 x u32
    bitmap: [4]u32,
    /// スラブが有効か
    active: bool,

    const Self = @This();

    /// 新しいスラブを初期化 (PMM からページを確保)
    fn create(obj_size: usize) ?Slab {
        const page = pmm.alloc() orelse return null;

        // ページをゼロクリア
        const ptr: [*]u8 = @ptrFromInt(page);
        for (0..PAGE_SIZE) |i| {
            ptr[i] = 0;
        }

        const cap = PAGE_SIZE / obj_size;
        const actual_cap = if (cap > MAX_OBJECTS_PER_SLAB) MAX_OBJECTS_PER_SLAB else cap;

        return Slab{
            .page_addr = page,
            .capacity = actual_cap,
            .used_count = 0,
            .bitmap = .{ 0, 0, 0, 0 },
            .active = true,
        };
    }

    /// ビットマップから空きスロットを探してアドレスを返す
    fn allocObj(self: *Self, obj_size: usize) ?*anyopaque {
        if (self.used_count >= self.capacity) return null;

        // ビットマップを走査して空きビットを探す
        for (&self.bitmap, 0..) |*word, word_idx| {
            if (word.* == 0xFFFFFFFF) continue;

            var bit: u5 = 0;
            while (true) : (bit += 1) {
                const obj_index = word_idx * 32 + @as(usize, bit);
                if (obj_index >= self.capacity) return null;

                if (word.* & (@as(u32, 1) << bit) == 0) {
                    // 空きスロット発見 → マーク
                    word.* |= (@as(u32, 1) << bit);
                    self.used_count += 1;
                    const offset = obj_index * obj_size;
                    return @ptrFromInt(self.page_addr + offset);
                }
                if (bit == 31) break;
            }
        }
        return null;
    }

    /// オブジェクトを解放 (ビットマップの該当ビットをクリア)
    fn freeObj(self: *Self, ptr: *anyopaque, obj_size: usize) bool {
        const addr = @intFromPtr(ptr);
        if (addr < self.page_addr or addr >= self.page_addr + PAGE_SIZE) {
            return false; // このスラブに属さない
        }

        const offset = addr - self.page_addr;
        if (offset % obj_size != 0) return false; // アラインメント不正

        const obj_index = offset / obj_size;
        if (obj_index >= self.capacity) return false;

        const word_idx = obj_index / 32;
        const bit: u5 = @truncate(obj_index % 32);

        if (self.bitmap[word_idx] & (@as(u32, 1) << bit) == 0) {
            return false; // 既に解放済み (double free 検知)
        }

        self.bitmap[word_idx] &= ~(@as(u32, 1) << bit);
        self.used_count -= 1;
        return true;
    }

    /// このスラブが空か (全オブジェクト未使用)
    fn isEmpty(self: *const Self) bool {
        return self.used_count == 0;
    }

    /// このスラブが満杯か
    fn isFull(self: *const Self) bool {
        return self.used_count >= self.capacity;
    }

    /// スラブを破棄 (ページを PMM に返却)
    fn destroy(self: *Self) void {
        if (self.active) {
            pmm.free(self.page_addr);
            self.active = false;
            self.used_count = 0;
            self.capacity = 0;
            self.bitmap = .{ 0, 0, 0, 0 };
        }
    }
};

// ---- SlabCache 構造体 ----
// 同一サイズのオブジェクト群を管理

pub const SlabCache = struct {
    /// キャッシュ名
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    /// オブジェクトサイズ (バイト)
    object_size: usize,
    /// スラブ配列
    slabs: [MAX_SLABS_PER_CACHE]Slab,
    /// アクティブなスラブ数
    slab_count: usize,
    /// このキャッシュが使用中か
    active: bool,
    /// 統計
    total_allocs: usize,
    total_frees: usize,

    const Self = @This();

    /// オブジェクトを確保
    pub fn allocObject(self: *Self) ?*anyopaque {
        // 既存スラブから空きを探す
        for (self.slabs[0..self.slab_count]) |*slab| {
            if (!slab.active or slab.isFull()) continue;
            if (slab.allocObj(self.object_size)) |ptr| {
                self.total_allocs += 1;
                return ptr;
            }
        }

        // 空きなし → 新しいスラブを追加
        if (self.slab_count >= MAX_SLABS_PER_CACHE) {
            return null; // スラブ上限
        }

        var new_slab = Slab.create(self.object_size) orelse return null;
        const ptr = new_slab.allocObj(self.object_size);
        self.slabs[self.slab_count] = new_slab;
        self.slab_count += 1;

        if (ptr != null) {
            self.total_allocs += 1;
        }
        return ptr;
    }

    /// オブジェクトを解放
    pub fn freeObject(self: *Self, ptr: *anyopaque) bool {
        for (self.slabs[0..self.slab_count]) |*slab| {
            if (!slab.active) continue;
            if (slab.freeObj(ptr, self.object_size)) {
                self.total_frees += 1;
                return true;
            }
        }
        return false; // どのスラブにも属さない
    }

    /// 使用中のオブジェクト数
    pub fn usedCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.slabs[0..self.slab_count]) |*slab| {
            if (slab.active) count += slab.used_count;
        }
        return count;
    }

    /// 総容量 (オブジェクト数)
    pub fn totalCapacity(self: *const Self) usize {
        var cap: usize = 0;
        for (self.slabs[0..self.slab_count]) |*slab| {
            if (slab.active) cap += slab.capacity;
        }
        return cap;
    }

    /// 空のスラブを回収 (shrink)
    pub fn reclaimEmpty(self: *Self) usize {
        var reclaimed: usize = 0;
        // 後方からスキャンして空スラブを破棄 (最低 1 つは残す)
        var i: usize = self.slab_count;
        while (i > 1) {
            i -= 1;
            if (self.slabs[i].active and self.slabs[i].isEmpty()) {
                self.slabs[i].destroy();
                reclaimed += 1;
                // 末尾の場合、slab_count を縮小
                if (i == self.slab_count - 1) {
                    self.slab_count -= 1;
                }
            }
        }
        return reclaimed;
    }

    /// キャッシュ名を取得
    pub fn getName(self: *const Self) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ---- グローバル状態 ----

var caches: [MAX_CACHES]SlabCache = undefined;
var cache_count: usize = 0;
var initialized: bool = false;

// ---- デフォルトキャッシュサイズ ----

const default_sizes = [6]usize{ 32, 64, 128, 256, 512, 1024 };
const default_names = [6][]const u8{ "slab-32", "slab-64", "slab-128", "slab-256", "slab-512", "slab-1024" };

// ---- 公開 API ----

/// slab アロケータを初期化し、デフォルトキャッシュを作成する
pub fn init() void {
    // 全キャッシュを非アクティブに初期化
    for (&caches) |*c| {
        c.active = false;
        c.slab_count = 0;
        c.object_size = 0;
        c.total_allocs = 0;
        c.total_frees = 0;
        c.name_len = 0;
        for (&c.slabs) |*s| {
            s.active = false;
        }
    }
    cache_count = 0;

    // デフォルトキャッシュを作成
    for (default_sizes, default_names) |size, name| {
        _ = createCache(name, size);
    }

    initialized = true;
    serial.write("[SLAB] initialized: ");
    serialPrintDec(cache_count);
    serial.write(" caches\n");
}

/// 名前とオブジェクトサイズを指定してキャッシュを作成
pub fn createCache(name: []const u8, obj_size: usize) ?*SlabCache {
    if (cache_count >= MAX_CACHES) return null;
    if (obj_size == 0 or obj_size > PAGE_SIZE) return null;

    // アラインメント: 最低 8 バイト境界に切り上げ
    const aligned_size = alignUp(obj_size, 8);

    var cache = &caches[cache_count];
    cache.active = true;
    cache.object_size = aligned_size;
    cache.slab_count = 0;
    cache.total_allocs = 0;
    cache.total_frees = 0;

    // 名前をコピー
    const copy_len = if (name.len > MAX_NAME_LEN) MAX_NAME_LEN else name.len;
    for (0..copy_len) |i| {
        cache.name[i] = name[i];
    }
    cache.name_len = copy_len;

    // 初期スラブを 1 つ確保
    if (Slab.create(aligned_size)) |slab| {
        cache.slabs[0] = slab;
        cache.slab_count = 1;
    } else {
        cache.active = false;
        return null;
    }

    cache_count += 1;
    return cache;
}

/// キャッシュからオブジェクトを確保
pub fn alloc(cache: *SlabCache) ?*anyopaque {
    if (!cache.active) return null;
    return cache.allocObject();
}

/// キャッシュにオブジェクトを返却
pub fn free(cache: *SlabCache, ptr: *anyopaque) void {
    if (!cache.active) return;
    _ = cache.freeObject(ptr);
}

/// サイズに最適なデフォルトキャッシュからメモリを確保
pub fn allocBySize(size: usize) ?*anyopaque {
    const cache = findCacheForSize(size) orelse return null;
    return alloc(cache);
}

/// サイズとポインタからデフォルトキャッシュに返却
pub fn freeBySize(ptr: *anyopaque, size: usize) void {
    const cache = findCacheForSize(size) orelse return;
    free(cache, ptr);
}

/// 指定サイズに対応するデフォルトキャッシュを探す
fn findCacheForSize(size: usize) ?*SlabCache {
    for (&caches, 0..) |*c, i| {
        if (i >= cache_count) break;
        if (c.active and c.object_size >= size) {
            return c;
        }
    }
    return null;
}

/// 名前でキャッシュを検索
pub fn findCacheByName(name: []const u8) ?*SlabCache {
    for (&caches, 0..) |*c, i| {
        if (i >= cache_count) break;
        if (c.active and c.name_len == name.len) {
            if (strEql(c.name[0..c.name_len], name)) {
                return c;
            }
        }
    }
    return null;
}

/// 全キャッシュの使用状況を表示
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Slab Allocator Status:\n");
    vga.setColor(.light_cyan, .black);
    vga.write("CACHE            SIZE  SLABS  USED/TOTAL  ALLOCS  FREES\n");
    vga.setColor(.light_grey, .black);

    for (&caches, 0..) |*c, i| {
        if (i >= cache_count) break;
        if (!c.active) continue;

        // 名前
        vga.write(c.name[0..c.name_len]);
        padTo(c.name_len, 17);

        // オブジェクトサイズ
        printDecPadded(c.object_size, 4);
        vga.write("  ");

        // スラブ数
        printDecPadded(c.slab_count, 5);
        vga.write("  ");

        // 使用中/総容量
        const used = c.usedCount();
        const total = c.totalCapacity();
        printDecPadded(used, 4);
        vga.putChar('/');
        printDecPadded(total, 4);
        vga.write("   ");

        // allocs/frees
        printDecPadded(c.total_allocs, 6);
        vga.write("  ");
        printDecPadded(c.total_frees, 5);
        vga.putChar('\n');
    }

    // サマリー
    vga.setColor(.light_green, .black);
    vga.write("Total: ");
    printDec(cache_count);
    vga.write(" caches, ");
    printDec(totalSlabPages());
    vga.write(" pages (");
    printDec(totalSlabPages() * 4);
    vga.write(" KB)\n");
    vga.setColor(.light_grey, .black);
}

/// 全キャッシュの空スラブを回収
pub fn reclaimAll() usize {
    var total: usize = 0;
    for (&caches, 0..) |*c, i| {
        if (i >= cache_count) break;
        if (c.active) {
            total += c.reclaimEmpty();
        }
    }
    return total;
}

/// キャッシュ数を取得
pub fn cacheCount() usize {
    return cache_count;
}

/// 使用中のスラブページ総数
fn totalSlabPages() usize {
    var pages: usize = 0;
    for (&caches, 0..) |*c, i| {
        if (i >= cache_count) break;
        if (!c.active) continue;
        for (c.slabs[0..c.slab_count]) |*s| {
            if (s.active) pages += 1;
        }
    }
    return pages;
}

// ---- ユーティリティ ----

fn alignUp(val: usize, alignment: usize) usize {
    return (val + alignment - 1) & ~(alignment - 1);
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn padTo(current: usize, target: usize) void {
    if (current < target) {
        var remaining = target - current;
        while (remaining > 0) : (remaining -= 1) {
            vga.putChar(' ');
        }
    }
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

fn printDecPadded(n: usize, width: usize) void {
    // 桁数を計算
    var digits: usize = 0;
    var tmp = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    // パディング
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec(n);
}

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
