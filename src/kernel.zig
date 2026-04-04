const vga = @import("vga.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const heap = @import("heap.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");
const rtc = @import("rtc.zig");
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

const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
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

fn initSubsystem(comptime name: []const u8, initFn: anytype) void {
    vga.setColor(.light_cyan, .black);
    vga.write(name);
    vga.setColor(.light_grey, .black);
    vga.write(" Initializing... ");
    initFn();
    vga.setColor(.light_green, .black);
    vga.write("OK\n");
    serial.write(name ++ " OK\n");
}

export fn kmain(mb_info_addr: u32) void {
    vga.init();
    serial.init();

    serial.write("\n=== Zig Kernel v0.4 boot ===\n");

    vga.setColor(.light_green, .black);
    vga.write("=================================\n");
    vga.write("  Zig Kernel v0.4\n");
    vga.write("=================================\n\n");

    initSubsystem("[GDT] ", gdt.init);
    initSubsystem("[IDT] ", idt.init);

    // PMM (Multiboot 情報が必要)
    vga.setColor(.light_cyan, .black);
    vga.write("[PMM]  ");
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
    serial.write("[PMM]  OK\n");

    initSubsystem("[PIT] ", pit.init);
    initSubsystem("[HEAP]", heap.init);
    initSubsystem("[PAGE]", paging.init);

    vga.setColor(.light_cyan, .black);
    vga.write("[MEM]  ");
    vga.setColor(.light_grey, .black);
    pmm.printStatus();

    vga.setColor(.light_cyan, .black);
    vga.write("[RTC]  ");
    rtc.printDateTime();

    vga.write("\n");
    vga.setColor(.yellow, .black);
    vga.write("Type 'help' for available commands.\n\n");
    vga.setColor(.white, .black);

    shell.init();
}

// stack_top はリンカスクリプトで定義
