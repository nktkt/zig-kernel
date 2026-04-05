const vga = @import("vga.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const heap = @import("heap.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");
const rtc = @import("rtc.zig");
const tss = @import("tss.zig");
const task = @import("task.zig");
const ramfs = @import("ramfs.zig");
const pci = @import("pci.zig");
const ata = @import("ata.zig");
const fat16 = @import("fat16.zig");
const e1000 = @import("e1000.zig");
const net = @import("net.zig");
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");
const vfs = @import("vfs.zig");
const pipe_mod = @import("pipe.zig");
const user = @import("user.zig");
const init_mod = @import("init.zig");
const env = @import("env.zig");
const shell = @import("shell.zig");
const acpi = @import("acpi.zig");
const smp = @import("smp.zig");
const mouse = @import("mouse.zig");
const blkdev = @import("blkdev.zig");
const ext2 = @import("ext2.zig");
const uhci = @import("uhci.zig");
const dns = @import("dns.zig");
const cmos = @import("cmos.zig");
const timer = @import("timer.zig");
const log = @import("log.zig");
const version = @import("version.zig");
const panic_screen = @import("panic_screen.zig");
const ringbuf = @import("ringbuf.zig");
const bitmap_mod = @import("bitmap.zig");
const string = @import("string.zig");
const list = @import("list.zig");

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

fn logInit(comptime name: []const u8, initFn: anytype) void {
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
    serial.write("\n=== Zig Kernel v1.0 boot ===\n");

    vga.setColor(.light_green, .black);
    vga.write("=================================\n");
    vga.write("  Zig Kernel v1.0\n");
    vga.write("=================================\n\n");

    logInit("[GDT] ", gdt.init);
    logInit("[IDT] ", idt.init);

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

    logInit("[PIT] ", pit.init);
    logInit("[HEAP]", heap.init);
    logInit("[PAGE]", paging.init);

    // TSS 初期化 (カーネルスタックトップを渡す)
    vga.setColor(.light_cyan, .black);
    vga.write("[TSS]  ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    const kstack_top = asm volatile ("" : [esp] "={esp}" (-> u32));
    tss.init(kstack_top);
    vga.setColor(.light_green, .black);
    vga.write("OK\n");

    logInit("[TASK]", task.init);
    logInit("[RAMF]", ramfs.init);
    logInit("[PCI] ", pci.init);
    logInit("[ATA] ", ata.init);
    logInit("[FAT] ", fat16.init);

    logInit("[VFS] ", vfs.init);
    logInit("[PIPE]", pipe_mod.init);
    logInit("[USER]", user.init);
    logInit("[ENV] ", env.init);

    // ネットワーク (E1000 があれば初期化)
    vga.setColor(.light_cyan, .black);
    vga.write("[NET]  ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    if (e1000.init()) {
        net.init();
        tcp.init();
        udp.init();
        vga.setColor(.light_green, .black);
        vga.write("OK\n");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("no NIC\n");
    }

    // Milestone 2
    logInit("[BLK] ", blkdev.init);
    logInit("[EXT2]", ext2.init);
    logInit("[ACPI]", acpi.init);
    logInit("[SMP] ", smp.init);
    logInit("[UHCI]", uhci.init);
    logInit("[MOUS]", mouse.init);

    // DNS (ネットワーク依存)
    if (e1000.isInitialized()) {
        logInit("[DNS] ", dns.init);
    }

    // Milestone 3: 追加サブシステム
    logInit("[CMOS]", cmos.init);
    logInit("[LOG] ", logSubInit);
    logInit("[VER] ", versionInit);

    // 強制参照: コンパイラが未使用インポートを検出しないよう
    _ = &timer.tickCallbacks;
    _ = &panic_screen.panic;
    _ = &ringbuf.RingBuffer;
    _ = &bitmap_mod.Bitmap;
    _ = &string.strlen;
    _ = &list.List;

    vga.setColor(.light_cyan, .black);
    vga.write("[MEM]  ");
    vga.setColor(.light_grey, .black);
    pmm.printStatus();

    vga.setColor(.light_cyan, .black);
    vga.write("[RTC]  ");
    rtc.printDateTime();

    vga.write("\n");
    vga.setColor(.yellow, .black);
    vga.write("Type 'help' for commands.\n\n");
    vga.setColor(.white, .black);

    // カーネル (PID=0) が init として機能
    // zombie 回収は timerSchedule 内で実行
    // シェルはカーネル内で直接実行 (キーボード IRQ 経由)
    shell.init();
}

fn logSubInit() void {
    log.setLevel(.info);
}

fn versionInit() void {
    version.printBanner();
}

// stack_top はリンカスクリプトで定義
