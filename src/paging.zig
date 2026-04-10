// ページング — 64-bit 4-level page tables (アイデンティティマッピング)

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");

const PAGE_SIZE = 4096;
const ENTRIES_PER_TABLE = 512;

// ページテーブルエントリのフラグ
const PAGE_PRESENT: u64 = 1 << 0;
const PAGE_WRITABLE: u64 = 1 << 1;
const PAGE_USER: u64 = 1 << 2;
const PAGE_PS: u64 = 1 << 7; // Page Size (2MB)
const PAGE_PCD: u64 = 1 << 4; // Cache Disable

// 4-level page tables for identity mapping first 4GB using 2MB pages
var pml4: [512]u64 align(4096) = @splat(0);
var pdpt: [512]u64 align(4096) = @splat(0);
var pd_tables: [4][512]u64 align(4096) = undefined;

pub fn init() void {
    // PML4[0] -> PDPT
    pml4[0] = @intFromPtr(&pdpt) | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;

    // Set up 4 page directories for 4GB identity mapping
    for (0..4) |i| {
        // PDPT[i] -> pd_tables[i]
        pdpt[i] = @intFromPtr(&pd_tables[i]) | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;

        // Each PD entry maps 2MB
        for (0..512) |j| {
            const phys_addr: u64 = @as(u64, i) * 0x40000000 + @as(u64, j) * 0x200000;
            pd_tables[i][j] = phys_addr | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER | PAGE_PS;
        }
    }

    // Load PML4 into CR3
    asm volatile ("mov %[pd], %%cr3"
        :
        : [pd] "r" (@intFromPtr(&pml4)),
    );
}

pub fn mapMMIO(phys_addr: u64) void {
    // With 4GB identity mapped using 2MB pages, MMIO below 4GB is already mapped.
    // For addresses above 4GB, we would need additional PDPT entries.
    // For now, handle addresses below 4GB by ensuring the correct PD entry
    // has cache-disable set.
    if (phys_addr < 0x100000000) {
        const gb_idx = phys_addr >> 30; // which GB (0-3)
        const pd_idx = (phys_addr >> 21) & 0x1FF; // which 2MB page within that GB
        const aligned = phys_addr & 0xFFFFFFFFFFE00000; // 2MB aligned
        pd_tables[@truncate(gb_idx)][@truncate(pd_idx)] = aligned | PAGE_PRESENT | PAGE_WRITABLE | PAGE_PS | PAGE_PCD;
    }

    // TLB フラッシュ
    asm volatile (
        \\mov %%cr3, %%rax
        \\mov %%rax, %%cr3
        :
        :
        : .{ .rax = true }
    );
}

pub fn isEnabled() bool {
    const cr0 = asm volatile ("mov %%cr0, %[cr0]"
        : [cr0] "=r" (-> u64),
    );
    return (cr0 & (1 << 31)) != 0;
}

pub fn printStatus() void {
    vga.setColor(.light_grey, .black);
    if (isEnabled()) {
        vga.write("Paging: enabled (identity mapped, 4GB, 2MB pages)\n");
    } else {
        vga.write("Paging: disabled\n");
    }
}
