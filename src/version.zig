// Version & Build Info — カーネルバージョン情報
// ビルドターゲット、バージョン番号、起動バナー

const vga = @import("vga.zig");
const serial = @import("serial.zig");

/// メジャーバージョン
pub const MAJOR: u8 = 1;
/// マイナーバージョン
pub const MINOR: u8 = 0;
/// パッチバージョン
pub const PATCH: u8 = 0;

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
