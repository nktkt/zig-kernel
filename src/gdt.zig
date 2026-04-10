// Global Descriptor Table — 64-bit Long Mode GDT

const tss_mod = @import("tss.zig");

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

// 64-bit GDT pointer: 16-bit limit + 64-bit base
const GdtPtr = packed struct {
    limit: u16,
    base: u64,
};

// 7 entries: null, kernel code, kernel data, user code, user data, TSS low, TSS high
var gdt_entries: [7]GdtEntry = undefined;
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
    gdt_entries[1] = makeEntry(0, 0xFFFFFFFF, 0x9A, 0xAF); // Kernel code (L=1, D=0)
    gdt_entries[2] = makeEntry(0, 0xFFFFFFFF, 0x92, 0xCF); // Kernel data
    gdt_entries[3] = makeEntry(0, 0xFFFFFFFF, 0xFA, 0xAF); // User code (DPL=3, L=1)
    gdt_entries[4] = makeEntry(0, 0xFFFFFFFF, 0xF2, 0xCF); // User data (DPL=3)

    // 64-bit TSS entry: occupies TWO consecutive GdtEntry slots (16 bytes)
    const tss_addr = tss_mod.getAddress();
    const tss_limit = tss_mod.getSize() - 1;
    const tss_base: u64 = tss_addr;

    // Low 8 bytes: standard TSS descriptor
    gdt_entries[5] = .{
        .limit_low = @truncate(tss_limit & 0xFFFF),
        .base_low = @truncate(tss_base & 0xFFFF),
        .base_mid = @truncate((tss_base >> 16) & 0xFF),
        .access = 0x89, // Present, 64-bit available TSS
        .granularity = @truncate((tss_limit >> 16) & 0x0F),
        .base_high = @truncate((tss_base >> 24) & 0xFF),
    };

    // High 8 bytes: upper 32 bits of base address + reserved
    const upper_base: u32 = @truncate(tss_base >> 32);
    gdt_entries[6] = @bitCast([8]u8{
        @truncate(upper_base & 0xFF),
        @truncate((upper_base >> 8) & 0xFF),
        @truncate((upper_base >> 16) & 0xFF),
        @truncate((upper_base >> 24) & 0xFF),
        0, 0, 0, 0,
    });

    gdt_ptr = .{
        .limit = @as(u16, @sizeOf(@TypeOf(gdt_entries))) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    asm volatile (
        \\lgdt (%[gdt])
        \\mov $0x10, %%rax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [gdt] "r" (&gdt_ptr),
        : .{ .rax = true, .memory = true }
    );
}
