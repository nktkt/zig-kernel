// Allocator — アロケータフレームワーク (ストラテジーパターン)
// BumpAllocator, StackAllocator, FreeListAllocator, ArenaAllocator
// 固定バッファ上で動作, ヒープ不要

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const ALIGNMENT = 8; // 8 バイトアラインメント
pub const MAX_NAME_LEN = 16;

// ---- アロケータインターフェース ----

pub const AllocatorInterface = struct {
    alloc_fn: *const fn (ctx: *anyopaque, size: usize) ?[*]u8,
    free_fn: *const fn (ctx: *anyopaque, ptr: [*]u8, size: usize) void,
    reset_fn: *const fn (ctx: *anyopaque) void,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    ctx: *anyopaque,
};

// ---- アラインメントヘルパー ----

fn alignUp(val: usize, alignment: usize) usize {
    return (val + alignment - 1) & ~(alignment - 1);
}

// ---- Bump Allocator ----
// 最もシンプル: ポインタを進めるだけ。個別の free 不可

pub const BumpAllocator = struct {
    buffer: [*]u8 = undefined,
    capacity: usize = 0,
    offset: usize = 0,
    alloc_count: usize = 0,
    total_allocated: usize = 0,
    peak_usage: usize = 0,
    initialized: bool = false,

    /// バッファで初期化
    pub fn init(self: *BumpAllocator, buf: [*]u8, size: usize) void {
        self.buffer = buf;
        self.capacity = size;
        self.offset = 0;
        self.alloc_count = 0;
        self.total_allocated = 0;
        self.peak_usage = 0;
        self.initialized = true;
    }

    /// メモリ確保
    pub fn alloc(self: *BumpAllocator, size: usize) ?[*]u8 {
        if (!self.initialized) return null;
        if (size == 0) return null;

        const aligned_offset = alignUp(self.offset, ALIGNMENT);
        if (aligned_offset + size > self.capacity) return null;

        const ptr = self.buffer + aligned_offset;
        self.offset = aligned_offset + size;
        self.alloc_count += 1;
        self.total_allocated += size;

        if (self.offset > self.peak_usage) {
            self.peak_usage = self.offset;
        }

        return ptr;
    }

    /// 個別解放はサポートしない (何もしない)
    pub fn free(self: *BumpAllocator, ptr: [*]u8, size: usize) void {
        _ = self;
        _ = ptr;
        _ = size;
        // Bump allocator は個別解放不可
    }

    /// 全リセット
    pub fn reset(self: *BumpAllocator) void {
        self.offset = 0;
        self.alloc_count = 0;
    }

    /// 残り容量
    pub fn remaining(self: *const BumpAllocator) usize {
        return self.capacity - self.offset;
    }

    pub fn printStats(self: *const BumpAllocator) void {
        vga.write("  BumpAllocator:\n");
        vga.write("    capacity=");
        fmt.printDec(self.capacity);
        vga.write(" used=");
        fmt.printDec(self.offset);
        vga.write(" allocs=");
        fmt.printDec(self.alloc_count);
        vga.write(" peak=");
        fmt.printDec(self.peak_usage);
        vga.putChar('\n');
    }
};

// ---- Stack Allocator ----
// LIFO: 最後に確保したものから順に解放

pub const StackAllocator = struct {
    buffer: [*]u8 = undefined,
    capacity: usize = 0,
    offset: usize = 0,
    alloc_count: usize = 0,
    // 各割り当てのサイズを記録するスタック
    sizes: [128]usize = @splat(0),
    size_top: usize = 0,
    total_allocated: usize = 0,
    total_freed: usize = 0,
    initialized: bool = false,

    pub fn init(self: *StackAllocator, buf: [*]u8, size: usize) void {
        self.buffer = buf;
        self.capacity = size;
        self.offset = 0;
        self.alloc_count = 0;
        self.size_top = 0;
        self.total_allocated = 0;
        self.total_freed = 0;
        self.initialized = true;
    }

    pub fn alloc(self: *StackAllocator, size: usize) ?[*]u8 {
        if (!self.initialized) return null;
        if (size == 0) return null;

        const aligned_offset = alignUp(self.offset, ALIGNMENT);
        const actual_size = alignUp(size, ALIGNMENT);
        if (aligned_offset + actual_size > self.capacity) return null;
        if (self.size_top >= 128) return null;

        const ptr = self.buffer + aligned_offset;
        self.sizes[self.size_top] = actual_size;
        self.size_top += 1;
        self.offset = aligned_offset + actual_size;
        self.alloc_count += 1;
        self.total_allocated += size;

        return ptr;
    }

    /// LIFO 解放: 最後に確保した領域のみ解放可能
    pub fn free(self: *StackAllocator, ptr: [*]u8, size: usize) void {
        _ = size;
        if (!self.initialized) return;
        if (self.size_top == 0) return;

        const last_size = self.sizes[self.size_top - 1];
        const expected_ptr = self.buffer + (self.offset - last_size);

        if (ptr == expected_ptr) {
            self.offset -= last_size;
            self.size_top -= 1;
            self.alloc_count -= 1;
            self.total_freed += last_size;
        }
        // LIFO 順序でなければ無視
    }

    pub fn reset(self: *StackAllocator) void {
        self.offset = 0;
        self.alloc_count = 0;
        self.size_top = 0;
    }

    pub fn printStats(self: *const StackAllocator) void {
        vga.write("  StackAllocator:\n");
        vga.write("    capacity=");
        fmt.printDec(self.capacity);
        vga.write(" used=");
        fmt.printDec(self.offset);
        vga.write(" allocs=");
        fmt.printDec(self.alloc_count);
        vga.write(" total_alloc=");
        fmt.printDec(self.total_allocated);
        vga.write(" total_free=");
        fmt.printDec(self.total_freed);
        vga.putChar('\n');
    }
};

// ---- Free List Allocator ----
// 明示的フリーリスト: first-fit / best-fit / worst-fit 戦略

pub const FitStrategy = enum(u8) {
    first_fit = 0,
    best_fit = 1,
    worst_fit = 2,
};

const FreeBlock = struct {
    offset: usize = 0, // バッファ内のオフセット
    size: usize = 0,
    active: bool = false,
    next: u16 = 0xFFFF, // 次のフリーブロックインデックス
};

pub const FreeListAllocator = struct {
    buffer: [*]u8 = undefined,
    capacity: usize = 0,
    strategy: FitStrategy = .first_fit,
    blocks: [128]FreeBlock = [_]FreeBlock{.{}} ** 128,
    free_head: u16 = 0xFFFF,
    alloc_count: usize = 0,
    total_allocated: usize = 0,
    total_freed: usize = 0,
    fragmentation_count: usize = 0,
    initialized: bool = false,

    pub fn init(self: *FreeListAllocator, buf: [*]u8, size: usize) void {
        self.buffer = buf;
        self.capacity = size;
        self.alloc_count = 0;
        self.total_allocated = 0;
        self.total_freed = 0;
        self.fragmentation_count = 0;

        // 全体を 1 つのフリーブロックにする
        self.blocks[0] = .{
            .offset = 0,
            .size = size,
            .active = true,
            .next = 0xFFFF,
        };
        self.free_head = 0;
        self.initialized = true;
    }

    pub fn setStrategy(self: *FreeListAllocator, strategy: FitStrategy) void {
        self.strategy = strategy;
    }

    fn allocBlock(self: *FreeListAllocator) ?u16 {
        for (0..128) |i| {
            if (!self.blocks[i].active) {
                self.blocks[i].active = true;
                return @truncate(i);
            }
        }
        return null;
    }

    pub fn alloc(self: *FreeListAllocator, size: usize) ?[*]u8 {
        if (!self.initialized) return null;
        if (size == 0) return null;

        const actual_size = alignUp(size, ALIGNMENT);

        // 戦略に応じてブロックを選択
        const selected = switch (self.strategy) {
            .first_fit => self.findFirstFit(actual_size),
            .best_fit => self.findBestFit(actual_size),
            .worst_fit => self.findWorstFit(actual_size),
        };

        const block_idx = selected orelse return null;
        const block_offset = self.blocks[block_idx].offset;
        const block_size = self.blocks[block_idx].size;

        if (block_size > actual_size + ALIGNMENT) {
            // 分割: 残りを新しいフリーブロックに
            self.blocks[block_idx].offset = block_offset + actual_size;
            self.blocks[block_idx].size = block_size - actual_size;
        } else {
            // ブロック全体を使用: フリーリストから削除
            self.removeFromFreeList(block_idx);
            self.blocks[block_idx].active = false;
        }

        self.alloc_count += 1;
        self.total_allocated += actual_size;
        return self.buffer + block_offset;
    }

    fn findFirstFit(self: *const FreeListAllocator, size: usize) ?u16 {
        var idx = self.free_head;
        while (idx != 0xFFFF) {
            if (self.blocks[idx].size >= size) return idx;
            idx = self.blocks[idx].next;
        }
        return null;
    }

    fn findBestFit(self: *const FreeListAllocator, size: usize) ?u16 {
        var best: ?u16 = null;
        var best_size: usize = 0xFFFFFFFF;

        var idx = self.free_head;
        while (idx != 0xFFFF) {
            if (self.blocks[idx].size >= size and self.blocks[idx].size < best_size) {
                best = idx;
                best_size = self.blocks[idx].size;
            }
            idx = self.blocks[idx].next;
        }
        return best;
    }

    fn findWorstFit(self: *const FreeListAllocator, size: usize) ?u16 {
        var worst: ?u16 = null;
        var worst_size: usize = 0;

        var idx = self.free_head;
        while (idx != 0xFFFF) {
            if (self.blocks[idx].size >= size and self.blocks[idx].size > worst_size) {
                worst = idx;
                worst_size = self.blocks[idx].size;
            }
            idx = self.blocks[idx].next;
        }
        return worst;
    }

    fn removeFromFreeList(self: *FreeListAllocator, target: u16) void {
        if (self.free_head == target) {
            self.free_head = self.blocks[target].next;
            return;
        }

        var idx = self.free_head;
        while (idx != 0xFFFF) {
            if (self.blocks[idx].next == target) {
                self.blocks[idx].next = self.blocks[target].next;
                return;
            }
            idx = self.blocks[idx].next;
        }
    }

    pub fn free(self: *FreeListAllocator, ptr: [*]u8, size: usize) void {
        if (!self.initialized) return;
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buffer);
        const actual_size = alignUp(size, ALIGNMENT);

        // 新しいフリーブロックを作成
        const new_idx = self.allocBlock() orelse return;
        self.blocks[new_idx].offset = offset;
        self.blocks[new_idx].size = actual_size;
        self.blocks[new_idx].next = self.free_head;
        self.free_head = new_idx;

        self.alloc_count -= 1;
        self.total_freed += actual_size;
        self.fragmentation_count += 1;

        // 隣接ブロックの結合 (簡易版)
        self.coalesce();
    }

    fn coalesce(self: *FreeListAllocator) void {
        // O(n^2) だが小規模なので問題なし
        var merged = true;
        while (merged) {
            merged = false;
            var idx = self.free_head;
            while (idx != 0xFFFF) {
                var other = self.blocks[idx].next;
                while (other != 0xFFFF) {
                    // idx の直後に other があるか
                    if (self.blocks[idx].offset + self.blocks[idx].size == self.blocks[other].offset) {
                        self.blocks[idx].size += self.blocks[other].size;
                        self.removeFromFreeList(other);
                        self.blocks[other].active = false;
                        merged = true;
                        break;
                    }
                    // other の直後に idx があるか
                    if (self.blocks[other].offset + self.blocks[other].size == self.blocks[idx].offset) {
                        self.blocks[idx].offset = self.blocks[other].offset;
                        self.blocks[idx].size += self.blocks[other].size;
                        self.removeFromFreeList(other);
                        self.blocks[other].active = false;
                        merged = true;
                        break;
                    }
                    other = self.blocks[other].next;
                }
                if (merged) break;
                idx = self.blocks[idx].next;
            }
        }
    }

    pub fn reset(self: *FreeListAllocator) void {
        for (&self.blocks) |*b| {
            b.active = false;
        }
        self.blocks[0] = .{
            .offset = 0,
            .size = self.capacity,
            .active = true,
            .next = 0xFFFF,
        };
        self.free_head = 0;
        self.alloc_count = 0;
    }

    pub fn printStats(self: *const FreeListAllocator) void {
        vga.write("  FreeListAllocator (");
        switch (self.strategy) {
            .first_fit => vga.write("first-fit"),
            .best_fit => vga.write("best-fit"),
            .worst_fit => vga.write("worst-fit"),
        }
        vga.write("):\n");
        vga.write("    capacity=");
        fmt.printDec(self.capacity);
        vga.write(" allocs=");
        fmt.printDec(self.alloc_count);
        vga.write(" total_alloc=");
        fmt.printDec(self.total_allocated);
        vga.write(" total_free=");
        fmt.printDec(self.total_freed);
        vga.write(" frags=");
        fmt.printDec(self.fragmentation_count);
        vga.putChar('\n');

        // フリーブロック一覧
        var free_count: usize = 0;
        var total_free: usize = 0;
        var idx = self.free_head;
        while (idx != 0xFFFF) {
            free_count += 1;
            total_free += self.blocks[idx].size;
            idx = self.blocks[idx].next;
        }
        vga.write("    free_blocks=");
        fmt.printDec(free_count);
        vga.write(" free_bytes=");
        fmt.printDec(total_free);
        vga.putChar('\n');
    }
};

// ---- Arena Allocator ----
// 一括解放のみ可能: 個別 free なし, reset で全解放

pub const ArenaAllocator = struct {
    buffer: [*]u8 = undefined,
    capacity: usize = 0,
    offset: usize = 0,
    alloc_count: usize = 0,
    total_allocated: usize = 0,
    reset_count: usize = 0,
    initialized: bool = false,

    pub fn init(self: *ArenaAllocator, buf: [*]u8, size: usize) void {
        self.buffer = buf;
        self.capacity = size;
        self.offset = 0;
        self.alloc_count = 0;
        self.total_allocated = 0;
        self.reset_count = 0;
        self.initialized = true;
    }

    pub fn alloc(self: *ArenaAllocator, size: usize) ?[*]u8 {
        if (!self.initialized) return null;
        if (size == 0) return null;

        const aligned_offset = alignUp(self.offset, ALIGNMENT);
        if (aligned_offset + size > self.capacity) return null;

        const ptr = self.buffer + aligned_offset;
        self.offset = aligned_offset + size;
        self.alloc_count += 1;
        self.total_allocated += size;
        return ptr;
    }

    /// 個別解放は何もしない
    pub fn free(self: *ArenaAllocator, ptr: [*]u8, size: usize) void {
        _ = self;
        _ = ptr;
        _ = size;
    }

    /// 全解放
    pub fn reset(self: *ArenaAllocator) void {
        self.offset = 0;
        self.alloc_count = 0;
        self.reset_count += 1;
    }

    pub fn printStats(self: *const ArenaAllocator) void {
        vga.write("  ArenaAllocator:\n");
        vga.write("    capacity=");
        fmt.printDec(self.capacity);
        vga.write(" used=");
        fmt.printDec(self.offset);
        vga.write(" allocs=");
        fmt.printDec(self.alloc_count);
        vga.write(" total_alloc=");
        fmt.printDec(self.total_allocated);
        vga.write(" resets=");
        fmt.printDec(self.reset_count);
        vga.putChar('\n');
    }
};

// ---- ベンチマーク ----

pub const BenchResult = struct {
    alloc_ops: usize = 0,
    free_ops: usize = 0,
    failed_allocs: usize = 0,
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
};

/// BumpAllocator のベンチマーク
pub fn benchmarkBump(buf: [*]u8, buf_size: usize, ops: usize) BenchResult {
    var bump: BumpAllocator = .{};
    bump.init(buf, buf_size);

    var result = BenchResult{};
    const name = "Bump";
    for (name, 0..) |c, i| result.name[i] = c;
    result.name_len = name.len;

    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const size = 16 + (i % 48); // 16-63 バイト
        if (bump.alloc(size) != null) {
            result.alloc_ops += 1;
        } else {
            result.failed_allocs += 1;
            bump.reset();
        }
    }
    return result;
}

/// ArenaAllocator のベンチマーク
pub fn benchmarkArena(buf: [*]u8, buf_size: usize, ops: usize) BenchResult {
    var arena: ArenaAllocator = .{};
    arena.init(buf, buf_size);

    var result = BenchResult{};
    const name = "Arena";
    for (name, 0..) |c, i| result.name[i] = c;
    result.name_len = name.len;

    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const size = 16 + (i % 48);
        if (arena.alloc(size) != null) {
            result.alloc_ops += 1;
        } else {
            result.failed_allocs += 1;
            arena.reset();
            result.free_ops += 1;
        }
    }
    return result;
}

// ---- デモ ----

// 静的バッファ
var demo_buf: [4096]u8 = undefined;

pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Allocator Demo ===\n");
    vga.setColor(.light_grey, .black);

    // Bump Allocator
    vga.write("\n1. Bump Allocator:\n");
    var bump: BumpAllocator = .{};
    bump.init(&demo_buf, 1024);
    _ = bump.alloc(64);
    _ = bump.alloc(128);
    _ = bump.alloc(32);
    bump.printStats();

    // Stack Allocator
    vga.write("\n2. Stack Allocator:\n");
    var stack: StackAllocator = .{};
    stack.init(&demo_buf, 1024);
    const p1 = stack.alloc(64) orelse &demo_buf;
    _ = stack.alloc(128);
    const p3 = stack.alloc(32) orelse &demo_buf;
    stack.free(p3, 32); // LIFO OK
    stack.free(p1, 64); // LIFO 違反 → 無視
    stack.printStats();

    // Free List Allocator
    vga.write("\n3. FreeList Allocator (best-fit):\n");
    var flist: FreeListAllocator = .{};
    flist.init(&demo_buf, 2048);
    flist.setStrategy(.best_fit);
    const fa = flist.alloc(64) orelse &demo_buf;
    _ = flist.alloc(128);
    const fc = flist.alloc(32) orelse &demo_buf;
    flist.free(fa, 64); // 任意の順序で解放可能
    flist.free(fc, 32);
    _ = flist.alloc(48); // best-fit: 32 バイトの穴に入る?
    flist.printStats();

    // Arena Allocator
    vga.write("\n4. Arena Allocator:\n");
    var arena: ArenaAllocator = .{};
    arena.init(&demo_buf, 1024);
    _ = arena.alloc(100);
    _ = arena.alloc(200);
    _ = arena.alloc(300);
    arena.printStats();
    arena.reset();
    vga.write("  After reset: used=");
    fmt.printDec(arena.offset);
    vga.putChar('\n');

    // ベンチマーク
    vga.write("\n5. Benchmark (100 ops each):\n");
    const bump_bench = benchmarkBump(&demo_buf, 4096, 100);
    const arena_bench = benchmarkArena(&demo_buf, 4096, 100);

    vga.write("  ");
    vga.write(bump_bench.name[0..bump_bench.name_len]);
    vga.write(": allocs=");
    fmt.printDec(bump_bench.alloc_ops);
    vga.write(" failed=");
    fmt.printDec(bump_bench.failed_allocs);
    vga.putChar('\n');

    vga.write("  ");
    vga.write(arena_bench.name[0..arena_bench.name_len]);
    vga.write(": allocs=");
    fmt.printDec(arena_bench.alloc_ops);
    vga.write(" failed=");
    fmt.printDec(arena_bench.failed_allocs);
    vga.putChar('\n');
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Allocator Framework:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Types: Bump, Stack, FreeList, Arena\n");
    vga.write("  Strategies: first-fit, best-fit, worst-fit\n");
    vga.write("  Alignment: 8 bytes\n");
}
