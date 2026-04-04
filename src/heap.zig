// ヒープアロケータ — 可変サイズの動的メモリ確保 (first-fit 方式)

const pmm = @import("pmm.zig");
const vga = @import("vga.zig");

const PAGE_SIZE = 4096;
const HEADER_SIZE = @sizeOf(BlockHeader);

const BlockHeader = struct {
    size: usize, // ヘッダを含まないデータサイズ
    used: bool,
    next: ?*BlockHeader,
};

var heap_start: usize = 0;
var heap_end: usize = 0;
var free_list: ?*BlockHeader = null;
var total_allocated: usize = 0;
var allocation_count: usize = 0;

pub fn init() void {
    // PMM から初期ヒープ用に 4 ページ (16KB) 確保
    if (pmm.alloc()) |addr| {
        heap_start = addr;
        // 連続 4 ページ確保
        _ = pmm.alloc();
        _ = pmm.alloc();
        _ = pmm.alloc();
        heap_end = addr + PAGE_SIZE * 4;

        const header: *BlockHeader = @ptrFromInt(heap_start);
        header.* = .{
            .size = PAGE_SIZE * 4 - HEADER_SIZE,
            .used = false,
            .next = null,
        };
        free_list = header;
    }
}

pub fn alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    // 4 バイトアラインメント
    const aligned_size = (size + 3) & ~@as(usize, 3);

    var current = free_list;
    while (current) |block| {
        if (!block.used and block.size >= aligned_size) {
            // ブロックが十分大きければ分割
            if (block.size >= aligned_size + HEADER_SIZE + 16) {
                const new_block: *BlockHeader = @ptrFromInt(@intFromPtr(block) + HEADER_SIZE + aligned_size);
                new_block.* = .{
                    .size = block.size - aligned_size - HEADER_SIZE,
                    .used = false,
                    .next = block.next,
                };
                block.size = aligned_size;
                block.next = new_block;
            }
            block.used = true;
            total_allocated += block.size;
            allocation_count += 1;
            return @ptrFromInt(@intFromPtr(block) + HEADER_SIZE);
        }
        current = block.next;
    }
    return null;
}

pub fn free(ptr: [*]u8) void {
    const header: *BlockHeader = @ptrFromInt(@intFromPtr(ptr) - HEADER_SIZE);
    if (!header.used) return;

    header.used = false;
    total_allocated -= header.size;
    allocation_count -= 1;

    // 隣接する空きブロックの結合
    var current = free_list;
    while (current) |block| {
        if (!block.used) {
            if (block.next) |next| {
                if (!next.used) {
                    block.size += HEADER_SIZE + next.size;
                    block.next = next.next;
                    continue; // 連続結合を試みる
                }
            }
        }
        current = block.next;
    }
}

pub fn printStatus() void {
    vga.setColor(.light_grey, .black);
    vga.write("Heap: ");
    printNum(total_allocated);
    vga.write(" bytes used, ");
    printNum(allocation_count);
    vga.write(" allocations, ");
    printNum(heap_end - heap_start);
    vga.write(" bytes total\n");
}

fn printNum(n: usize) void {
    pmm.printNum(n);
}
