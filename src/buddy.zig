// Buddy allocator — べき乗サイズのページレベル割り当て
//
// 7 つのオーダー (order 0..6) を管理:
//   order 0 = 1 page  (4KB)
//   order 1 = 2 pages (8KB)
//   order 2 = 4 pages (16KB)
//   order 3 = 8 pages (32KB)
//   order 4 = 16 pages (64KB)
//   order 5 = 32 pages (128KB)
//   order 6 = 64 pages (256KB)
//
// 各オーダーのフリーリスト、ブロック分割、バディ結合を実装。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- 定数 ----

const PAGE_SIZE: u32 = 4096;
const MAX_ORDER: usize = 7; // orders 0..6
const MAX_BLOCKS: usize = 256; // ブロック追跡ビットマップの最大エントリ数
const MAX_FREE_PER_ORDER: usize = 64; // 各オーダーのフリーリスト最大数

// ---- フリーリストエントリ ----
// 各オーダーに対して、空きブロックのアドレスを配列で保持

const FreeList = struct {
    addrs: [MAX_FREE_PER_ORDER]u32,
    count: usize,

    fn initFreeList() FreeList {
        return .{
            .addrs = [_]u32{0} ** MAX_FREE_PER_ORDER,
            .count = 0,
        };
    }

    fn push(self: *FreeList, addr: u32) bool {
        if (self.count >= MAX_FREE_PER_ORDER) return false;
        self.addrs[self.count] = addr;
        self.count += 1;
        return true;
    }

    fn pop(self: *FreeList) ?u32 {
        if (self.count == 0) return null;
        self.count -= 1;
        return self.addrs[self.count];
    }

    /// 指定アドレスをリストから削除 (バディ結合時に使用)
    fn remove(self: *FreeList, addr: u32) bool {
        for (0..self.count) |i| {
            if (self.addrs[i] == addr) {
                // 末尾で上書き
                self.count -= 1;
                if (i < self.count) {
                    self.addrs[i] = self.addrs[self.count];
                }
                return true;
            }
        }
        return false;
    }

    fn contains(self: *const FreeList, addr: u32) bool {
        for (0..self.count) |i| {
            if (self.addrs[i] == addr) return true;
        }
        return false;
    }
};

// ---- ブロック追跡ビットマップ ----
// bit=1 → 割り当て済み, bit=0 → 空きまたは未使用

const BITMAP_WORDS: usize = (MAX_BLOCKS + 31) / 32;

var block_bitmap: [BITMAP_WORDS]u32 = [_]u32{0} ** BITMAP_WORDS;

fn setBitmapBit(index: usize) void {
    if (index >= MAX_BLOCKS) return;
    const word = index / 32;
    const bit: u5 = @truncate(index % 32);
    block_bitmap[word] |= @as(u32, 1) << bit;
}

fn clearBitmapBit(index: usize) void {
    if (index >= MAX_BLOCKS) return;
    const word = index / 32;
    const bit: u5 = @truncate(index % 32);
    block_bitmap[word] &= ~(@as(u32, 1) << bit);
}

fn testBitmapBit(index: usize) bool {
    if (index >= MAX_BLOCKS) return false;
    const word = index / 32;
    const bit: u5 = @truncate(index % 32);
    return (block_bitmap[word] & (@as(u32, 1) << bit)) != 0;
}

/// アドレスからブロックインデックスに変換 (order 0 基準)
fn addrToBlockIndex(addr: u32) usize {
    if (addr < base_address) return 0;
    return @as(usize, (addr - base_address) / PAGE_SIZE);
}

// ---- グローバル状態 ----

var free_lists: [MAX_ORDER]FreeList = initFreeLists();
var base_address: u32 = 0;
var total_managed_pages: usize = 0;
var allocated_pages: usize = 0;
var initialized: bool = false;

// 統計
var total_allocs: u64 = 0;
var total_frees: u64 = 0;
var split_count: u64 = 0;
var merge_count: u64 = 0;

fn initFreeLists() [MAX_ORDER]FreeList {
    var lists: [MAX_ORDER]FreeList = undefined;
    for (&lists) |*l| {
        l.* = FreeList.initFreeList();
    }
    return lists;
}

// ---- 初期化 ----

/// メモリ領域からバディアロケータを初期化
/// base_addr: 管理領域の先頭物理アドレス (ページアラインド)
/// total_pages_count: 管理するページ数
pub fn init(base_addr: u32, total_pages_count: usize) void {
    base_address = base_addr;
    total_managed_pages = total_pages_count;
    allocated_pages = 0;
    total_allocs = 0;
    total_frees = 0;
    split_count = 0;
    merge_count = 0;

    // フリーリスト初期化
    for (&free_lists) |*fl| {
        fl.* = FreeList.initFreeList();
    }

    // ビットマップクリア
    for (&block_bitmap) |*w| {
        w.* = 0;
    }

    // 可能な限り大きなオーダーでフリーリストに追加
    var remaining = total_pages_count;
    var addr = base_addr;

    while (remaining > 0) {
        // 現在のアドレスに対して最大のオーダーを見つける
        var order: usize = MAX_ORDER - 1;
        while (order > 0) : (order -= 1) {
            const block_pages = pagesForOrder(order);
            if (block_pages <= remaining) {
                // アドレスがこのオーダーのアラインメントを満たすかチェック
                const alignment = block_pages * PAGE_SIZE;
                if (addr % alignment == 0) {
                    break;
                }
            }
        }

        // order 0 でも残りがあればそれを使う
        const block_pages = pagesForOrder(order);
        if (block_pages > remaining) {
            // 残りページが order 0 未満の場合は終了
            if (order == 0) break;
            order = 0;
            const bp = pagesForOrder(0);
            if (bp > remaining) break;
        }

        const actual_pages = pagesForOrder(order);
        _ = free_lists[order].push(addr);
        addr += @as(u32, @truncate(actual_pages)) * PAGE_SIZE;
        remaining -= actual_pages;
    }

    initialized = true;

    serial.write("[buddy] init: base=0x");
    serial.writeHex(base_addr);
    serial.write(" pages=");
    serial.writeHex(total_pages_count);
    serial.write("\n");
}

// ---- ヘルパー関数 ----

/// オーダーに対するページ数 (2^order)
fn pagesForOrder(order: usize) usize {
    return @as(usize, 1) << @truncate(order);
}

/// オーダーに対するバイト数
fn bytesForOrder(order: usize) u32 {
    return @as(u32, 1) << @truncate(order + 12); // 2^order * 4096
}

/// バディアドレスを計算
/// あるブロックのアドレスとオーダーから、そのバディのアドレスを返す
pub fn getBuddy(addr: u32, order: usize) u32 {
    const block_size = bytesForOrder(order);
    return addr ^ block_size; // XOR でバディを算出
}

/// 2つのバディのうち低いアドレスを返す (マージ後の親ブロックアドレス)
fn parentAddr(addr: u32, order: usize) u32 {
    const block_size = bytesForOrder(order);
    return addr & ~(block_size * 2 - 1);
}

// ---- 割り当て ----

/// 2^order ページを割り当てて先頭物理アドレスを返す
/// order: 0=4KB, 1=8KB, 2=16KB, ... 6=256KB
pub fn alloc(order: usize) ?u32 {
    if (!initialized) return null;
    if (order >= MAX_ORDER) return null;

    // 要求オーダー以上のフリーリストを探す
    var current_order = order;
    while (current_order < MAX_ORDER) : (current_order += 1) {
        if (free_lists[current_order].count > 0) {
            break;
        }
    }

    // 空きブロックが見つからない
    if (current_order >= MAX_ORDER) return null;

    // フリーリストからブロックを取得
    const addr = free_lists[current_order].pop() orelse return null;

    // 必要に応じて分割 (大きいブロックを小さくする)
    var split_order = current_order;
    while (split_order > order) {
        split_order -= 1;
        // 上半分をフリーリストに追加
        const buddy_addr = addr + bytesForOrder(split_order);
        _ = free_lists[split_order].push(buddy_addr);
        split_count += 1;
    }

    // ビットマップにマーク
    const block_idx = addrToBlockIndex(addr);
    setBitmapBit(block_idx);

    allocated_pages += pagesForOrder(order);
    total_allocs += 1;

    return addr;
}

// ---- 解放 ----

/// 2^order ページのブロックを解放 (バディが空きなら結合)
pub fn free(addr: u32, order: usize) void {
    if (!initialized) return;
    if (order >= MAX_ORDER) return;

    // ビットマップをクリア
    const block_idx = addrToBlockIndex(addr);
    clearBitmapBit(block_idx);

    allocated_pages -|= pagesForOrder(order);
    total_frees += 1;

    // バディとの結合を試みる
    var current_addr = addr;
    var current_order = order;

    while (current_order < MAX_ORDER - 1) {
        const buddy_addr = getBuddy(current_addr, current_order);

        // バディが管理領域内かチェック
        if (buddy_addr < base_address) break;
        const buddy_end = buddy_addr + bytesForOrder(current_order);
        const managed_end = base_address + @as(u32, @truncate(total_managed_pages)) * PAGE_SIZE;
        if (buddy_end > managed_end) break;

        // バディがフリーリストにあるかチェック
        if (!free_lists[current_order].contains(buddy_addr)) {
            break;
        }

        // バディも空き → 結合
        _ = free_lists[current_order].remove(buddy_addr);
        merge_count += 1;

        // 親ブロックのアドレス (2つのうち低い方)
        current_addr = parentAddr(current_addr, current_order);
        current_order += 1;
    }

    // 結合後のブロックをフリーリストに追加
    _ = free_lists[current_order].push(current_addr);
}

// ---- 情報取得 ----

/// 現在の空きページ数を返す
pub fn availablePages() usize {
    var total: usize = 0;
    for (0..MAX_ORDER) |order| {
        total += free_lists[order].count * pagesForOrder(order);
    }
    return total;
}

/// 割り当て済みページ数
pub fn allocatedPages() usize {
    return allocated_pages;
}

/// 管理ページ総数
pub fn totalPages() usize {
    return total_managed_pages;
}

/// 空きブロック数 (全オーダー合計)
pub fn totalFreeBlocks() usize {
    var total: usize = 0;
    for (0..MAX_ORDER) |order| {
        total += free_lists[order].count;
    }
    return total;
}

/// 特定オーダーの空きブロック数
pub fn freeBlocksForOrder(order: usize) usize {
    if (order >= MAX_ORDER) return 0;
    return free_lists[order].count;
}

/// 統計情報を取得
pub fn getAllocCount() u64 {
    return total_allocs;
}

pub fn getFreeCount() u64 {
    return total_frees;
}

pub fn getSplitCount() u64 {
    return split_count;
}

pub fn getMergeCount() u64 {
    return merge_count;
}

// ---- 表示 ----

/// 各オーダーの空きブロック数を表示
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Buddy Allocator Status ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Base address: 0x");
    fmt.printHex32(base_address);
    vga.write("\n  Managed pages: ");
    fmt.printDec(total_managed_pages);
    vga.write("  Allocated: ");
    fmt.printDec(allocated_pages);
    vga.write("  Available: ");
    fmt.printDec(availablePages());
    vga.putChar('\n');

    vga.write("\n  Order | Size     | Free blocks\n");
    vga.write("  ------+----------+------------\n");

    for (0..MAX_ORDER) |order| {
        vga.write("    ");
        fmt.printDec(order);
        vga.write("   | ");
        printBlockSize(order);
        vga.write(" | ");
        fmt.printDec(free_lists[order].count);
        vga.putChar('\n');
    }

    vga.write("\n  Statistics:\n");
    vga.write("    Total allocs: ");
    printU64(total_allocs);
    vga.write("    Total frees:  ");
    printU64(total_frees);
    vga.write("    Splits:       ");
    printU64(split_count);
    vga.write("    Merges:       ");
    printU64(merge_count);
    vga.putChar('\n');
}

fn printBlockSize(order: usize) void {
    const sizes = [MAX_ORDER][]const u8{
        "  4KB ", "  8KB ", " 16KB ", " 32KB ",
        " 64KB ", "128KB ", "256KB ",
    };
    if (order < MAX_ORDER) {
        vga.write(sizes[order]);
    }
}

fn printU64(val: u64) void {
    fmt.printDec(@truncate(val));
    vga.putChar('\n');
}

// ---- デバッグ ----

/// フリーリストの内容をシリアルにダンプ
pub fn dumpFreeLists() void {
    serial.write("[buddy] free list dump:\n");
    for (0..MAX_ORDER) |order| {
        serial.write("  order ");
        serial.writeHex(order);
        serial.write(": ");
        serial.writeHex(free_lists[order].count);
        serial.write(" blocks");
        for (0..free_lists[order].count) |i| {
            serial.write(" 0x");
            serial.writeHex(free_lists[order].addrs[i]);
        }
        serial.write("\n");
    }
}

/// ビットマップの使用状況をシリアルにダンプ
pub fn dumpBitmap() void {
    serial.write("[buddy] bitmap dump:\n");
    for (block_bitmap, 0..) |word, i| {
        if (word != 0) {
            serial.write("  word[");
            serial.writeHex(i);
            serial.write("] = 0x");
            serial.writeHex(word);
            serial.write("\n");
        }
    }
}

/// 指定アドレスが割り当て済みかチェック
pub fn isAllocated(addr: u32) bool {
    const idx = addrToBlockIndex(addr);
    return testBitmapBit(idx);
}

/// リセット (テスト用)
pub fn reset() void {
    for (&free_lists) |*fl| {
        fl.* = FreeList.initFreeList();
    }
    for (&block_bitmap) |*w| {
        w.* = 0;
    }
    base_address = 0;
    total_managed_pages = 0;
    allocated_pages = 0;
    total_allocs = 0;
    total_frees = 0;
    split_count = 0;
    merge_count = 0;
    initialized = false;
}
