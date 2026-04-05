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
const slab = @import("slab.zig");
const devfs = @import("devfs.zig");
const http = @import("http.zig");
const tar = @import("tar.zig");
const crypto = @import("crypto.zig");
const procfs = @import("procfs.zig");
const tty = @import("tty.zig");
const test_suite = @import("test_suite.zig");
const ksh = @import("ksh.zig");
const math = @import("math.zig");
const editor = @import("editor.zig");
const game = @import("game.zig");
const config = @import("config.zig");
const scheduler_rr = @import("scheduler_rr.zig");
const mmu = @import("mmu.zig");
const arp_cache = @import("arp_cache.zig");
const icmp = @import("icmp.zig");
const netstat = @import("netstat.zig");
const virtio = @import("virtio.zig");
const power = @import("power.zig");
const errno = @import("errno.zig");
const queue_mod = @import("queue.zig");
const hashtable = @import("hashtable.zig");
const mempool = @import("mempool.zig");
const debug = @import("debug.zig");
const syscall_table = @import("syscall_table.zig");
const capability = @import("capability.zig");
const mount_mod = @import("mount.zig");
const futex = @import("futex.zig");
const pci_db = @import("pci_db.zig");
const time_mod = @import("time.zig");
const regex = @import("regex.zig");
const sort_mod = @import("sort.zig");
const base64 = @import("base64.zig");
const json = @import("json.zig");
const utf8 = @import("utf8.zig");
const compress = @import("compress.zig");
const color = @import("color.zig");
const bench = @import("bench.zig");
const canvas_mod = @import("canvas.zig");
const window_mod = @import("window.zig");
const widget_mod = @import("widget.zig");
const event_mod = @import("event.zig");
const theme_mod = @import("theme.zig");
const font_mod = @import("font.zig");
const buddy_mod = @import("buddy.zig");
const vma_mod = @import("vma.zig");
const workqueue_mod = @import("workqueue.zig");
const kobject_mod = @import("kobject.zig");
const sysctl_mod = @import("sysctl.zig");
const interrupt_mod = @import("interrupt.zig");
const kthread_mod = @import("kthread.zig");
const semaphore_mod = @import("semaphore.zig");
const rwlock_mod = @import("rwlock.zig");
const cache_mod = @import("cache.zig");
const tmpfs_mod = @import("tmpfs.zig");
const fat32_mod = @import("fat32.zig");
const path_mod = @import("path.zig");
const permission_mod = @import("permission.zig");
const pty_mod = @import("pty.zig");
const coreutils_mod = @import("coreutils.zig");
const archive_mod = @import("archive.zig");
const disk_util_mod = @import("disk_util.zig");
const init_script_mod = @import("init_script.zig");
const shell_ext_mod = @import("shell_ext.zig");
const ip_mod = @import("ip.zig");
const ntp_mod = @import("ntp.zig");
const tftp_mod = @import("tftp.zig");
const telnet_mod = @import("telnet.zig");
const socket_api_mod = @import("socket_api.zig");
const ipv6_mod = @import("ipv6.zig");
const firewall_mod = @import("firewall.zig");
const ethernet_mod = @import("ethernet.zig");
const routing_mod = @import("routing.zig");
const net_util_mod = @import("net_util.zig");
const scheduler_cfs_mod = @import("scheduler_cfs.zig");
const signal_handler_mod = @import("signal_handler.zig");
const elf_parser_mod = @import("elf_parser.zig");
const ipc_mod = @import("ipc.zig");
const vt_mod = @import("vt.zig");
const watchdog_mod = @import("watchdog.zig");
const pool_alloc_mod = @import("pool_alloc.zig");
const profiler_mod = @import("profiler.zig");
const ioctl_mod = @import("ioctl.zig");
const ksym_mod = @import("ksym.zig");

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
    _ = &slab.createCache;
    _ = &devfs.open;
    _ = &http.get;
    _ = &tar.parse;
    _ = &crypto.crc32;
    _ = &procfs.readFile;
    _ = &tty.write;
    _ = &test_suite.runAll;
    _ = &ksh.execute;
    _ = &math.sqrt_int;
    _ = &editor.start;
    _ = &game.startGuessing;
    _ = &config.get;
    _ = &scheduler_rr.setPriority;
    _ = &mmu.allocForProcess;
    _ = &arp_cache.lookup;
    _ = &icmp.sendEchoRequest;
    _ = &netstat.printSummary;
    _ = &virtio.printDevices;
    _ = &power.printPowerInfo;
    _ = &errno.strerror;
    _ = &queue_mod.TimerQueue;
    _ = &hashtable.Map32;
    _ = &mempool.SmallPool;
    _ = &debug.dumpRegisters;
    _ = &syscall_table.printTable;
    _ = &capability.hasCapability;
    _ = &mount_mod.printMounts;
    _ = &futex.printStatus;
    _ = &pci_db.getVendorName;
    _ = &time_mod.printNow;
    _ = &regex.compile;
    _ = &sort_mod.quickSort;
    _ = &base64.encode;
    _ = &json.parse;
    _ = &utf8.decodeChar;
    _ = &compress.rleEncode;
    _ = &color.rgbToHsv;
    _ = &bench.runAll;
    _ = &canvas_mod.drawLine;
    _ = &window_mod.createWindow;
    _ = &widget_mod.createLabel;
    _ = &event_mod.push;
    _ = &theme_mod.setTheme;
    _ = &font_mod.drawChar8x8;
    _ = &buddy_mod.printStatus;
    _ = &vma_mod.printAllVmas;
    _ = &workqueue_mod.processWork;
    _ = &kobject_mod.printAll;
    _ = &sysctl_mod.printAll;
    _ = &interrupt_mod.printIrqStats;
    _ = &kthread_mod.printThreads;
    _ = &semaphore_mod.printAll;
    _ = &rwlock_mod.printStatus;
    _ = &cache_mod.printAllStats;
    _ = &tmpfs_mod.create;
    _ = &fat32_mod.printInfo;
    _ = &path_mod.basename;
    _ = &permission_mod.check;
    _ = &pty_mod.openMaster;
    _ = &coreutils_mod.wc;
    _ = &archive_mod.create;
    _ = &disk_util_mod.readSector;
    _ = &init_script_mod.runBootScript;
    _ = &shell_ext_mod.addAlias;
    _ = &ip_mod.sendPacket;
    _ = &ntp_mod.sync;
    _ = &tftp_mod.readFile;
    _ = &telnet_mod.connect;
    _ = &socket_api_mod.socket;
    _ = &ipv6_mod.parseAddr;
    _ = &firewall_mod.checkPacket;
    _ = &ethernet_mod.buildFrame;
    _ = &routing_mod.lookup;
    _ = &net_util_mod.htons;
    _ = &scheduler_cfs_mod.pickNext;
    _ = &signal_handler_mod.sendSignal;
    _ = &elf_parser_mod.parseElf;
    _ = &ipc_mod.mqCreate;
    _ = &vt_mod.switchTo;
    _ = &watchdog_mod.check;
    _ = &pool_alloc_mod.alloc;
    _ = &profiler_mod.beginProfile;
    _ = &ioctl_mod.dispatch;
    _ = &ksym_mod.lookupByAddr;

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
