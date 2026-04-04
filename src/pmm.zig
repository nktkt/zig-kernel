// Physical Memory Manager — ビットマップ方式のページフレームアロケータ

const vga = @import("vga.zig");

const PAGE_SIZE = 4096;
const MAX_PAGES = 1024 * 1024; // 4GB / 4KB = 1M pages
const BITMAP_SIZE = MAX_PAGES / 32;

var bitmap: [BITMAP_SIZE]u32 = @splat(0xFFFFFFFF); // 全て使用中で初期化
var total_pages: usize = 0;
var used_pages: usize = 0;
var max_page: usize = 0; // スキャン範囲の上限

pub fn init(mem_upper_kb: usize) void {
    // mem_upper_kb: 1MB 以上の利用可能メモリ (KB)
    total_pages = mem_upper_kb / 4; // 4KB ページ数
    used_pages = total_pages;

    // 1MB 以降のメモリを空きとしてマーク
    const start_page = 0x100000 / PAGE_SIZE; // 256 (= 1MB / 4KB)
    max_page = start_page + total_pages;

    var i: usize = start_page;
    while (i < max_page) : (i += 1) {
        clearBit(i);
        used_pages -= 1;
    }

    // カーネル領域 (1MB - 2MB) を予約
    const kernel_pages = 256; // 1MB 分
    i = start_page;
    while (i < start_page + kernel_pages) : (i += 1) {
        setBit(i);
        used_pages += 1;
    }
}

pub fn alloc() ?usize {
    const scan_words = if (max_page > 0) (max_page + 31) / 32 else BITMAP_SIZE;
    for (bitmap[0..scan_words], 0..) |entry, idx| {
        if (entry != 0xFFFFFFFF) {
            // 空きビットを探す
            var bit: u5 = 0;
            while (true) : (bit += 1) {
                if (entry & (@as(u32, 1) << bit) == 0) {
                    const page = idx * 32 + bit;
                    setBit(page);
                    used_pages += 1;
                    return page * PAGE_SIZE;
                }
                if (bit == 31) break;
            }
        }
    }
    return null;
}

pub fn free(addr: usize) void {
    const page = addr / PAGE_SIZE;
    clearBit(page);
    used_pages -= 1;
}

pub fn freeCount() usize {
    if (total_pages > used_pages) {
        return total_pages - used_pages;
    }
    return 0;
}

pub fn printStatus() void {
    vga.write("Memory: ");
    printNum(freeCount() * 4);
    vga.write("KB free / ");
    printNum(total_pages * 4);
    vga.write("KB total\n");
}

fn setBit(page: usize) void {
    bitmap[page / 32] |= @as(u32, 1) << @truncate(page % 32);
}

fn clearBit(page: usize) void {
    bitmap[page / 32] &= ~(@as(u32, 1) << @truncate(page % 32));
}

pub fn printNum(n: usize) void {
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
