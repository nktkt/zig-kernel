// Global Descriptor Table — CPU のメモリセグメント保護設定

const tss_mod = @import("tss.zig");

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

const GdtPtr = packed struct {
    limit: u16,
    base: u32,
};

var gdt_entries: [6]GdtEntry = undefined; // +1 for TSS
var gdt_ptr: GdtPtr = undefined;

fn makeEntry(base: u32, limit: u32, access: u8, gran: u8) GdtEntry {
    return .{
        .base_low = @truncate(base & 0xFFFF),
        .base_mid = @truncate((base >> 16) & 0xFF),
        .base_high = @truncate((base >> 24) & 0xFF),
        .limit_low = @truncate(limit & 0xFFFF),
        .access = access,
        .granularity = @truncate(((limit >> 16) & 0x0F) | (gran & 0xF0)),
    };
}

pub fn init() void {
    gdt_entries[0] = makeEntry(0, 0, 0, 0); // Null
    gdt_entries[1] = makeEntry(0, 0xFFFFFFFF, 0x9A, 0xCF); // Kernel code
    gdt_entries[2] = makeEntry(0, 0xFFFFFFFF, 0x92, 0xCF); // Kernel data
    gdt_entries[3] = makeEntry(0, 0xFFFFFFFF, 0xFA, 0xCF); // User code (DPL=3)
    gdt_entries[4] = makeEntry(0, 0xFFFFFFFF, 0xF2, 0xCF); // User data (DPL=3)

    // TSS エントリ (0x28)
    const tss_base = tss_mod.getAddress();
    const tss_limit = tss_mod.getSize() - 1;
    gdt_entries[5] = makeEntry(tss_base, tss_limit, 0x89, 0x00);

    gdt_ptr = .{
        .limit = @as(u16, @sizeOf(@TypeOf(gdt_entries))) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    asm volatile (
        \\lgdt (%[gdt])
        \\mov $0x10, %%eax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [gdt] "r" (&gdt_ptr),
        : .{ .eax = true, .memory = true }
    );
}
