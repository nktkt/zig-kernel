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
const autotest = @import("autotest.zig");
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
const sha256_mod = @import("sha256.zig");
const md5_mod = @import("md5.zig");
const hmac_mod = @import("hmac.zig");
const password_mod = @import("password.zig");
const access_control_mod = @import("access_control.zig");
const audit_mod = @import("audit.zig");
const namespace_mod = @import("namespace.zig");
const seccomp_mod = @import("seccomp.zig");
const keyring_mod = @import("keyring.zig");
const sandbox_mod = @import("sandbox.zig");
const pcspkr_mod = @import("pcspkr.zig");
const dma_mod = @import("dma.zig");
const floppy_mod = @import("floppy.zig");
const hda_mod = @import("hda.zig");
const input_mod = @import("input.zig");
const multiboot_mod = @import("multiboot.zig");
const cpuid_info_mod = @import("cpuid_info.zig");
const apic_mod = @import("apic.zig");
const pit_ext_mod = @import("pit_ext.zig");
const power_mgmt_mod = @import("power_mgmt.zig");
const rbtree_mod = @import("rbtree.zig");
const avl_mod = @import("avl.zig");
const trie_mod = @import("trie.zig");
const graph_mod = @import("graph.zig");
const matrix_mod = @import("matrix.zig");
const statemachine_mod = @import("statemachine.zig");
const scheduler_ml_mod = @import("scheduler_ml.zig");
const allocator_mod = @import("allocator.zig");
const bitops_mod = @import("bitops.zig");
const checksum_mod = @import("checksum.zig");
const sched_deadline_mod = @import("sched_deadline.zig");
const process_tree_mod = @import("process_tree.zig");
const resource_mod = @import("resource.zig");
const accounting_mod = @import("accounting.zig");
const loadavg_mod = @import("loadavg.zig");
const syslog_mod = @import("syslog.zig");
const console_cmd_mod = @import("console_cmd.zig");
const random_mod = @import("random.zig");
const hex_mod = @import("hex.zig");
const scheduler_lottery_mod = @import("scheduler_lottery.zig");
const bmp_mod = @import("bmp.zig");
const wav_mod = @import("wav.zig");
const ini_mod = @import("ini.zig");
const csv_mod = @import("csv.zig");
const xml_mod = @import("xml.zig");
const template_mod = @import("template.zig");
const test_runner_mod = @import("test_runner.zig");
const perf_counter_mod = @import("perf_counter.zig");
const locale_mod = @import("locale.zig");
const terminal_mod = @import("terminal.zig");
const rtl8139_mod = @import("rtl8139.zig");
const ne2000_mod = @import("ne2000.zig");
const ahci_mod = @import("ahci.zig");
const virtio_net_mod = @import("virtio_net.zig");
const virtio_blk_mod = @import("virtio_blk.zig");
const ide_mod = @import("ide.zig");
const i8042_mod = @import("i8042.zig");
const pit_speaker_mod = @import("pit_speaker.zig");
const cga_mod = @import("cga.zig");
const serial_ext_mod = @import("serial_ext.zig");
const arp_table_mod = @import("arp_table.zig");
const tcp_options_mod = @import("tcp_options.zig");
const nic_stats_mod = @import("nic_stats.zig");
const dns_cache_mod = @import("dns_cache.zig");
const net_interface_mod = @import("net_interface.zig");
const proc_status_mod = @import("proc_status.zig");
const sched_stats_mod = @import("sched_stats.zig");
const swap_mod = @import("swap.zig");
const page_cache_mod = @import("page_cache.zig");
const block_io_mod = @import("block_io.zig");
const ata_dma_mod = @import("ata_dma.zig");
const vesa_mod = @import("vesa.zig");
const pata_mod = @import("pata.zig");
const acpi_tables_mod = @import("acpi_tables.zig");
const usb_desc_mod = @import("usb_desc.zig");
const ohci_mod = @import("ohci.zig");
const msi_mod = @import("msi.zig");
const ioapic_mod = @import("ioapic.zig");
const pit_calibrate_mod = @import("pit_calibrate.zig");
const mmio_mod = @import("mmio.zig");

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

// Page tables for the 32-bit boot stub to set up before entering Long Mode.
// Identity-maps the first 1GB using 2MB pages.
export var boot_pml4: [512]u64 align(4096) = @splat(0);
export var boot_pdpt: [512]u64 align(4096) = @splat(0);
export var boot_pd: [512]u64 align(4096) = @splat(0);

export fn _start() callconv(.naked) noreturn {
    // The entire body is inline assembly. We start in 32-bit protected mode
    // (Multiboot1 entry) and transition to 64-bit Long Mode.
    asm volatile (
        \\.code32
        \\
        \\ // Save multiboot info pointer (EBX) into EDI for later
        \\ mov %%ebx, %%edi
        \\
        \\ // Set up a temporary 32-bit stack
        \\ mov $stack_top, %%esp
        \\
        \\ // ----- Set up 4-level page tables for identity mapping first 1GB -----
        \\ // Zero the page table arrays (they are in BSS so should be zero,
        \\ // but be safe)
        \\
        \\ // pml4[0] = &pdpt | 0x03 (Present + Write)
        \\ mov $boot_pdpt, %%eax
        \\ or $0x03, %%eax
        \\ mov $boot_pml4, %%ecx
        \\ mov %%eax, (%%ecx)
        \\ movl $0, 4(%%ecx)
        \\
        \\ // pdpt[0] = &pd | 0x03 (Present + Write)
        \\ mov $boot_pd, %%eax
        \\ or $0x03, %%eax
        \\ mov $boot_pdpt, %%ecx
        \\ mov %%eax, (%%ecx)
        \\ movl $0, 4(%%ecx)
        \\
        \\ // pd[0..511] = i*2MB | 0x83 (Present + Write + PageSize)
        \\ mov $boot_pd, %%ecx
        \\ xor %%eax, %%eax       // physical address starts at 0
        \\ mov $512, %%edx
        \\1:
        \\ mov %%eax, (%%ecx)
        \\ orl $0x83, (%%ecx)     // Present + Write + PS (2MB page)
        \\ movl $0, 4(%%ecx)
        \\ add $8, %%ecx
        \\ add $0x200000, %%eax   // next 2MB
        \\ dec %%edx
        \\ jnz 1b
        \\
        \\ // ----- Load PML4 into CR3 -----
        \\ mov $boot_pml4, %%eax
        \\ mov %%eax, %%cr3
        \\
        \\ // ----- Enable PAE (CR4 bit 5) -----
        \\ mov %%cr4, %%eax
        \\ or $0x20, %%eax
        \\ mov %%eax, %%cr4
        \\
        \\ // ----- Enable Long Mode (EFER MSR 0xC0000080, bit 8) -----
        \\ mov $0xC0000080, %%ecx
        \\ rdmsr
        \\ or $0x100, %%eax
        \\ wrmsr
        \\
        \\ // ----- Enable Paging (CR0 bit 31) -----
        \\ mov %%cr0, %%eax
        \\ or $0x80000000, %%eax
        \\ mov %%eax, %%cr0
        \\
        \\ // ----- Load 64-bit GDT and far jump to 64-bit code -----
        \\ lgdt gdt64_ptr
        \\ ljmp $0x08, $long_mode_entry
        \\
        \\.align 16
        \\gdt64:
        \\ .quad 0                      // null descriptor
        \\ .quad 0x00AF9A000000FFFF     // 64-bit kernel code (L=1, D=0)
        \\ .quad 0x00CF92000000FFFF     // 64-bit kernel data
        \\ .quad 0x00AFFA000000FFFF     // 64-bit user code (DPL=3)
        \\ .quad 0x00CFF2000000FFFF     // 64-bit user data (DPL=3)
        \\gdt64_ptr:
        \\ .word gdt64_ptr - gdt64 - 1
        \\ .long gdt64
        \\
        \\.code64
        \\long_mode_entry:
        \\ // Load data segment registers with 64-bit data selector (0x10)
        \\ mov $0x10, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ mov %%ax, %%ss
        \\
        \\ // Set up 64-bit stack
        \\ movabs $stack_top, %%rsp
        \\
        \\ // EDI already contains multiboot info pointer (zero-extended to RDI)
        \\ // Call kmain(mb_info_addr: u64)
        \\ call kmain
        \\
        \\ // Halt loop
        \\2: cli
        \\ hlt
        \\ jmp 2b
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

export fn kmain(mb_info_addr: u64) void {
    vga.init();
    serial.init();
    serial.write("\n=== Zig Kernel v1.0 boot (x86_64) ===\n");

    vga.setColor(.light_green, .black);
    vga.write("=================================\n");
    vga.write("  Zig Kernel v1.0 (64-bit)\n");
    vga.write("=================================\n\n");

    logInit("[GDT] ", gdt.init);
    logInit("[IDT] ", idt.init);

    vga.setColor(.light_cyan, .black);
    vga.write("[PMM]  ");
    vga.setColor(.light_grey, .black);
    vga.write("Initializing... ");
    if (mb_info_addr != 0) {
        const mb_info: *const MultibootInfo = @ptrFromInt(@as(usize, @truncate(mb_info_addr)));
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
    const kstack_top = asm volatile ("" : [rsp] "={rsp}" (-> u64));
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
    _ = &sha256_mod.hash;
    _ = &md5_mod.hash;
    _ = &hmac_mod.hmacSha256;
    _ = &password_mod.hashPassword;
    _ = &access_control_mod.checkAccess;
    _ = &audit_mod.logEvent;
    _ = &namespace_mod.create;
    _ = &seccomp_mod.checkSyscall;
    _ = &keyring_mod.addKey;
    _ = &sandbox_mod.createSandbox;
    _ = &pcspkr_mod.beep;
    _ = &dma_mod.setupChannel;
    _ = &floppy_mod.readSector;
    _ = &hda_mod.getCodecCount;
    _ = &input_mod.pollEvent;
    _ = &multiboot_mod.printInfo;
    _ = &cpuid_info_mod.printAll;
    _ = &apic_mod.sendEOI;
    _ = &pit_ext_mod.usleep;
    _ = &power_mgmt_mod.printPowerStats;
    _ = &rbtree_mod.demo;
    _ = &avl_mod.demo;
    _ = &trie_mod.demo;
    _ = &graph_mod.demo;
    _ = &matrix_mod.demo;
    _ = &statemachine_mod.demo;
    _ = &scheduler_ml_mod.demo;
    _ = &allocator_mod.demo;
    _ = &bitops_mod.demo;
    _ = &checksum_mod.demo;
    _ = &sched_deadline_mod.printTasks;
    _ = &process_tree_mod.printTree;
    _ = &resource_mod.printLimits;
    _ = &accounting_mod.printSystemAccounting;
    _ = &loadavg_mod.printLoadAvg;
    _ = &syslog_mod.printLog;
    _ = &console_cmd_mod.top;
    _ = &random_mod.printState;
    _ = &hex_mod.xxd;
    _ = &scheduler_lottery_mod.printLottery;
    _ = &bmp_mod.parse;
    _ = &wav_mod.parse;
    _ = &ini_mod.parse;
    _ = &csv_mod.parse;
    _ = &xml_mod.parse;
    _ = &template_mod.render;
    _ = &test_runner_mod.runAll;
    _ = &perf_counter_mod.printAll;
    _ = &locale_mod.setLocale;
    _ = &terminal_mod.init;
    _ = &rtl8139_mod.printInfo;
    _ = &ne2000_mod.printInfo;
    _ = &ahci_mod.printInfo;
    _ = &virtio_net_mod.printInfo;
    _ = &virtio_blk_mod.printInfo;
    _ = &ide_mod.printDrives;
    _ = &i8042_mod.printStatus;
    _ = &pit_speaker_mod.playTone;
    _ = &cga_mod.printModeInfo;
    _ = &serial_ext_mod.printAllPorts;
    _ = &arp_table_mod.printTable;
    _ = &tcp_options_mod.parseOptions;
    _ = &nic_stats_mod.printAllStats;
    _ = &dns_cache_mod.printCache;
    _ = &net_interface_mod.printInterfaces;
    _ = &proc_status_mod.printAll;
    _ = &sched_stats_mod.printStats;
    _ = &swap_mod.printStatus;
    _ = &page_cache_mod.printStats;
    _ = &block_io_mod.printQueueStatus;
    _ = &ata_dma_mod.printInfo;
    _ = &vesa_mod.printInfo;
    _ = &pata_mod.printDrives;
    _ = &acpi_tables_mod.printAllTables;
    _ = &usb_desc_mod.printDescriptors;
    _ = &ohci_mod.printInfo;
    _ = &msi_mod.printMsiInfo;
    _ = &ioapic_mod.printRedirectionTable;
    _ = &pit_calibrate_mod.printCalibration;
    _ = &mmio_mod.printRegions;

    vga.setColor(.light_cyan, .black);
    vga.write("[MEM]  ");
    vga.setColor(.light_grey, .black);
    pmm.printStatus();

    vga.setColor(.light_cyan, .black);
    vga.write("[RTC]  ");
    rtc.printDateTime();

    // ブート時自動テスト (最小)
    vga.setColor(.yellow, .black);
    vga.write("[TEST] Starting...\n");
    serial.write("[TEST] Starting...\n");
    autotest.run();
    serial.write("[TEST] Done.\n");

    vga.write("\n");
    vga.setColor(.yellow, .black);
    vga.write("Type 'help' for commands.\n\n");
    vga.setColor(.white, .black);

    shell.init();
}

fn logSubInit() void {
    log.setLevel(.info);
}

fn versionInit() void {
    version.printBanner();
}

// stack_top はリンカスクリプトで定義
