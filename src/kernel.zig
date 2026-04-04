const vga = @import("vga.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const heap = @import("heap.zig");
const shell = @import("shell.zig");

// Multiboot1 header
const MULTIBOOT_MAGIC = 0x1BADB002;
const MULTIBOOT_ALIGN = 1 << 0;
const MULTIBOOT_MEMINFO = 1 << 1;
const MULTIBOOT_FLAGS = MULTIBOOT_ALIGN | MULTIBOOT_MEMINFO;

export const multiboot_header align(4) linksection(".multiboot") = [3]u32{
    MULTIBOOT_MAGIC,
    MULTIBOOT_FLAGS,
    @truncate(0 -% (@as(u64, MULTIBOOT_MAGIC) + MULTIBOOT_FLAGS)),
};

// Multiboot info structure (部分的)
const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32, // KB (0 - 640KB)
    mem_upper: u32, // KB (1MB 以降)
};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov $stack_top, %%esp
        \\push %%ebx
        \\call kmain
        \\1: hlt
        \\jmp 1b
    );
}

export fn kmain(mb_info_addr: u32) void {
    vga.init();

    vga.setColor(.light_green, .black);
    vga.write("=================================\n");
    vga.write("  Zig Kernel v0.3\n");
    vga.write("=================================\n\n");

    vga.setColor(.light_cyan, .black);
    vga.write("[GDT] ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    gdt.init();
    vga.setColor(.light_green, .black);
    vga.write("OK\n");

    vga.setColor(.light_cyan, .black);
    vga.write("[IDT] ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    idt.init();
    vga.setColor(.light_green, .black);
    vga.write("OK\n");

    vga.setColor(.light_cyan, .black);
    vga.write("[PMM] ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    if (mb_info_addr != 0) {
        const mb_info: *const MultibootInfo = @ptrFromInt(mb_info_addr);
        if (mb_info.flags & 0x1 != 0) {
            pmm.init(mb_info.mem_upper);
        }
    }
    vga.setColor(.light_green, .black);
    vga.write("OK\n");

    vga.setColor(.light_cyan, .black);
    vga.write("[PIT] ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    pit.init();
    vga.setColor(.light_green, .black);
    vga.write("OK\n");

    vga.setColor(.light_cyan, .black);
    vga.write("[HEAP]");
    vga.setColor(.light_grey, .black);
    vga.write(" Initializing... ");
    heap.init();
    vga.setColor(.light_green, .black);
    vga.write("OK\n");

    vga.setColor(.light_cyan, .black);
    vga.write("[MEM] ");
    vga.setColor(.light_grey, .black);
    pmm.printStatus();

    vga.write("\n");
    vga.setColor(.yellow, .black);
    vga.write("Type 'help' for available commands.\n\n");
    vga.setColor(.white, .black);

    shell.init();
}

// stack_top はリンカスクリプトで定義
