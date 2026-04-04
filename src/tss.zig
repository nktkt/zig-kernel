// Task State Segment — Ring 3→0 遷移時にカーネルスタックを設定

const idt = @import("idt.zig");

// TSS 構造体 (104 bytes)
pub const TSS = extern struct {
    prev_tss: u32,
    esp0: u32,
    ss0: u32,
    esp1: u32,
    ss1: u32,
    esp2: u32,
    ss2: u32,
    cr3: u32,
    eip: u32,
    eflags: u32,
    eax: u32,
    ecx: u32,
    edx: u32,
    ebx: u32,
    esp: u32,
    ebp: u32,
    esi: u32,
    edi: u32,
    es: u32,
    cs: u32,
    ss: u32,
    ds: u32,
    fs: u32,
    gs: u32,
    ldt: u32,
    trap: u16,
    iomap_base: u16,
};

pub var tss: TSS = std.mem.zeroes(TSS);

const std = @import("std");

pub fn init(kernel_stack_top: u32) void {
    tss.ss0 = 0x10; // カーネルデータセグメント
    tss.esp0 = kernel_stack_top;
    tss.iomap_base = @sizeOf(TSS);

    // TSS セレクタをロード (GDT entry 5 = 0x28)
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (@as(u16, 0x28)),
    );
}

pub fn setKernelStack(stack_top: u32) void {
    tss.esp0 = stack_top;
}

pub fn getAddress() u32 {
    return @intFromPtr(&tss);
}

pub fn getSize() u32 {
    return @sizeOf(TSS);
}
