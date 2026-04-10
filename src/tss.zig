// Task State Segment — 64-bit TSS for Ring 3→0 transitions

const idt = @import("idt.zig");
const std = @import("std");

// 64-bit TSS structure (104 bytes)
pub const TSS64 = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0, // Stack pointer for Ring 0
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0, // Interrupt Stack Table entries
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = 0,
};

pub var tss: TSS64 = .{};

pub fn init(kernel_stack_top: u64) void {
    tss.rsp0 = kernel_stack_top;
    tss.iomap_base = @sizeOf(TSS64);

    // TSS セレクタをロード (GDT entry 5 = 0x28)
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (@as(u16, 0x28)),
    );
}

pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}

pub fn getAddress() u64 {
    return @intFromPtr(&tss);
}

pub fn getSize() u32 {
    return @sizeOf(TSS64);
}
