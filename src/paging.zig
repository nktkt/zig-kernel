// ページング — 仮想メモリ管理 (アイデンティティマッピング)

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");

const PAGE_SIZE = 4096;
const ENTRIES_PER_TABLE = 1024;

// ページディレクトリ/テーブルエントリのフラグ
const PAGE_PRESENT: u32 = 1 << 0;
const PAGE_WRITABLE: u32 = 1 << 1;
const PAGE_USER: u32 = 1 << 2;

var page_directory: [ENTRIES_PER_TABLE]u32 align(PAGE_SIZE) = @splat(0);

// 最初の 4MB 分のページテーブル (カーネル + VGA 用)
var first_table: [ENTRIES_PER_TABLE]u32 align(PAGE_SIZE) = undefined;

pub fn init() void {
    // 最初の 4MB をアイデンティティマップ (仮想 = 物理)
    for (0..ENTRIES_PER_TABLE) |i| {
        first_table[i] = @as(u32, @truncate(i * PAGE_SIZE)) | PAGE_PRESENT | PAGE_WRITABLE;
    }

    // ページディレクトリにテーブルを登録
    page_directory[0] = @intFromPtr(&first_table) | PAGE_PRESENT | PAGE_WRITABLE;

    // 追加のアイデンティティマップ: 4MB-132MB (利用可能メモリ領域)
    // 4MB ページ (PSE) を使用
    var i: usize = 1;
    while (i < 33) : (i += 1) { // 33 * 4MB = 132MB
        page_directory[i] = @as(u32, @truncate(i * 4 * 1024 * 1024)) | PAGE_PRESENT | PAGE_WRITABLE | (1 << 7); // PS bit
    }

    // CR3 にページディレクトリのアドレスを設定
    asm volatile ("mov %[pd], %%cr3"
        :
        : [pd] "r" (@as(u32, @intFromPtr(&page_directory))),
    );

    // CR4 の PSE (Page Size Extension) を有効化
    var cr4: u32 = 0;
    cr4 = asm volatile ("mov %%cr4, %[cr4]"
        : [cr4] "=r" (-> u32),
    );
    cr4 |= (1 << 4); // PSE bit
    asm volatile ("mov %[cr4], %%cr4"
        :
        : [cr4] "r" (cr4),
    );

    // CR0 の PG (Paging) ビットを有効化
    var cr0: u32 = 0;
    cr0 = asm volatile ("mov %%cr0, %[cr0]"
        : [cr0] "=r" (-> u32),
    );
    cr0 |= (1 << 31); // PG bit
    asm volatile ("mov %[cr0], %%cr0"
        :
        : [cr0] "r" (cr0),
    );
}

pub fn isEnabled() bool {
    const cr0 = asm volatile ("mov %%cr0, %[cr0]"
        : [cr0] "=r" (-> u32),
    );
    return (cr0 & (1 << 31)) != 0;
}

pub fn printStatus() void {
    vga.setColor(.light_grey, .black);
    if (isEnabled()) {
        vga.write("Paging: enabled (identity mapped, 132MB)\n");
    } else {
        vga.write("Paging: disabled\n");
    }
}
