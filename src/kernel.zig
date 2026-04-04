const vga = @import("vga.zig");

// Multiboot1 header - QEMU が直接認識できる形式
const MULTIBOOT_MAGIC = 0x1BADB002;
const MULTIBOOT_ALIGN = 1 << 0; // モジュールをページ境界に配置
const MULTIBOOT_MEMINFO = 1 << 1; // メモリマップ情報を要求
const MULTIBOOT_FLAGS = MULTIBOOT_ALIGN | MULTIBOOT_MEMINFO;

export const multiboot_header align(4) linksection(".multiboot") = [3]u32{
    MULTIBOOT_MAGIC,
    MULTIBOOT_FLAGS,
    @truncate(0 -% (@as(u64, MULTIBOOT_MAGIC) + MULTIBOOT_FLAGS)), // checksum
};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov $stack_top, %%esp
        \\call kmain
        \\cli
        \\1: hlt
        \\jmp 1b
    );
}

export fn kmain() void {
    vga.init();
    vga.setColor(.light_green, .black);
    vga.write("=================================\n");
    vga.write("  Zig Minimal Kernel v0.1\n");
    vga.write("  Hello from kernel space!\n");
    vga.write("=================================\n");

    vga.setColor(.light_grey, .black);
    vga.write("\nKernel booted successfully.\n");
    vga.write("System halted.\n");
}

// stack_top はリンカスクリプトで定義
