// Version & Build Info — カーネルバージョン情報
// ビルドターゲット、バージョン番号、起動バナー

const vga = @import("vga.zig");
const serial = @import("serial.zig");

/// メジャーバージョン
pub const MAJOR: u8 = 1;
/// マイナーバージョン
pub const MINOR: u8 = 2;
/// パッチバージョン
pub const PATCH: u8 = 0;

/// ビルド日時 (手動)
pub const BUILD_DATE = "2026-04-05";

/// ソースファイル数
pub const SOURCE_FILES: u32 = 96;

/// 総コード行数 (概算)
pub const TOTAL_LOC: u32 = 30000;

/// シェルコマンド数
pub const SHELL_COMMANDS: u32 = 80;

/// サブシステム数
pub const SUBSYSTEMS: u32 = 45;

/// コミット数
pub const COMMITS: u32 = 22;

/// リポジトリURL
pub const REPO_URL = "https://github.com/nktkt/zig-kernel";

/// ライセンス
pub const LICENSE = "MIT";

/// 作者
pub const AUTHOR = "nktkt";

/// 説明
pub const DESCRIPTION = "x86 OS kernel written from scratch in Zig";

/// コードネーム
pub const CODENAME = "Phoenix";

/// カーネル名
pub const KERNEL_NAME = "ZigOS";
/// ビルドターゲット
pub const BUILD_TARGET = "x86-freestanding";
/// アーキテクチャ
pub const ARCH = "i686";

/// バージョン文字列 "1.0.0"
pub fn getVersionString() []const u8 {
    return "1.0.0";
}

/// ビルドターゲット文字列
pub fn getBuildTarget() []const u8 {
    return BUILD_TARGET;
}

/// アーキテクチャ文字列
pub fn getArch() []const u8 {
    return ARCH;
}

/// カーネル名を返す
pub fn getName() []const u8 {
    return KERNEL_NAME;
}

/// バージョン情報を VGA に表示
pub fn printVersion() void {
    vga.setColor(.yellow, .black);
    vga.write("Kernel Version:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Name:    ");
    vga.write(KERNEL_NAME);
    vga.putChar('\n');
    vga.write("  Version: ");
    vga.write(getVersionString());
    vga.putChar('\n');
    vga.write("  Target:  ");
    vga.write(BUILD_TARGET);
    vga.putChar('\n');
    vga.write("  Arch:    ");
    vga.write(ARCH);
    vga.putChar('\n');
}

/// 起動時バナーを表示
pub fn printBanner() void {
    vga.setColor(.light_cyan, .black);
    vga.write("  _______ _        ____   _____  \n");
    vga.write(" |___  (_) |      / __ \\ / ____| \n");
    vga.write("    / / _| | __ | |  | | (___   \n");
    vga.write("   / / | | |/ _ \\| |  | |\\___ \\  \n");
    vga.write("  / /__| | | (_) | |__| |____) | \n");
    vga.write(" /_____|_|_|\\___/ \\____/|_____/  \n");
    vga.setColor(.light_grey, .black);
    vga.write("  ");
    vga.write(KERNEL_NAME);
    vga.write(" v");
    vga.write(getVersionString());
    vga.write(" (");
    vga.write(BUILD_TARGET);
    vga.write(")\n\n");

    // シリアルにもバナー出力
    serial.write("\n=== ");
    serial.write(KERNEL_NAME);
    serial.write(" v");
    serial.write(getVersionString());
    serial.write(" ===\n");
}

/// 簡易バージョン文字列を VGA に出力 (1行)
pub fn printShort() void {
    vga.write(KERNEL_NAME);
    vga.write(" v");
    vga.write(getVersionString());
}

/// ビルド情報を詳細に表示
pub fn printBuildInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Build Information:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Kernel:      ");
    vga.write(KERNEL_NAME);
    vga.write(" v");
    vga.write(getVersionString());
    vga.putChar('\n');
    vga.write("  Target:      ");
    vga.write(BUILD_TARGET);
    vga.putChar('\n');
    vga.write("  Arch:        ");
    vga.write(ARCH);
    vga.putChar('\n');
    vga.write("  Language:    Zig 0.15\n");
    vga.write("  Optimize:    ReleaseSafe\n");
    vga.write("  Red Zone:    disabled\n");
    vga.write("  SSE/AVX:     disabled\n");
    vga.write("  Boot:        Multiboot1\n");
    vga.write("  Stack:       16 KB (linker)\n");
    vga.write("  Page Size:   4 KB\n");
    vga.write("  Max Tasks:   16\n");
    vga.write("  Max Files:   32 (ramfs)\n");
    vga.write("  Max FDs:     32\n");
    vga.write("  Timer:       PIT 1 kHz\n");
    vga.write("  Serial:      COM1 38400 baud\n");
    vga.write("  NIC:         Intel E1000\n");
    vga.write("  Disk:        ATA PIO (LBA28)\n");
    vga.write("  Display:     VGA Text 80x25\n");
    vga.write("  Graphics:    VGA Mode 13h 320x200\n");
    vga.write("  Keyboard:    PS/2 scancode set 1\n");
    vga.write("  Mouse:       PS/2 (IRQ12)\n");
}

/// カーネルの機能一覧を表示
pub fn printFeatures() void {
    vga.setColor(.yellow, .black);
    vga.write("Kernel Features:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Core:     ");
    vga.setColor(.light_green, .black);
    vga.write("GDT IDT TSS PMM Heap Paging VMM PIT RTC\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Process:  ");
    vga.setColor(.light_green, .black);
    vga.write("Scheduler Fork Wait Exit Signals Zombie-Reap\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Syscall:  ");
    vga.setColor(.light_green, .black);
    vga.write("INT-0x80 (40 defined, 9 implemented)\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Memory:   ");
    vga.setColor(.light_green, .black);
    vga.write("Bitmap-PMM First-Fit-Heap Slab MemPool\n");

    vga.setColor(.light_grey, .black);
    vga.write("  FS:       ");
    vga.setColor(.light_green, .black);
    vga.write("RAMFS FAT16-RW ext2-RO VFS DevFS ProcFS\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Network:  ");
    vga.setColor(.light_green, .black);
    vga.write("E1000 ARP IPv4 ICMP TCP UDP DNS DHCP HTTP\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Drivers:  ");
    vga.setColor(.light_green, .black);
    vga.write("PCI ATA PS/2-Kbd PS/2-Mouse VGA Serial UHCI\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Security: ");
    vga.setColor(.light_green, .black);
    vga.write("Multi-User Capabilities UID/GID\n");

    vga.setColor(.light_grey, .black);
    vga.write("  GUI:      ");
    vga.setColor(.light_green, .black);
    vga.write("Mode13h Canvas Window-Mgr Widgets Themes\n");

    vga.setColor(.light_grey, .black);
    vga.write("  IPC:      ");
    vga.setColor(.light_green, .black);
    vga.write("Pipe Signals Futex Events\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Libs:     ");
    vga.setColor(.light_green, .black);
    vga.write("String Math Regex JSON Base64 Crypto Sort\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Debug:    ");
    vga.setColor(.light_green, .black);
    vga.write("Panic BSOD Stack-Trace ISR-0-19 Log Serial\n");

    vga.setColor(.light_grey, .black);
    vga.write("  Apps:     ");
    vga.setColor(.light_green, .black);
    vga.write("Shell(80+cmds) Editor Game Script Benchmark\n");

    vga.setColor(.light_grey, .black);
}
