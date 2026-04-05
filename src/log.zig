// Kernel Logging Subsystem — レベル付きカーネルログ
// VGA (色分け) とシリアルポートに同時出力

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");

/// ログレベル
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn color(self: Level) vga.Color {
        return switch (self) {
            .debug => .dark_grey,
            .info => .light_cyan,
            .warn => .yellow,
            .err => .light_red,
            .fatal => .light_red,
        };
    }
};

/// 現在の最小ログレベル (これ未満のログは出力されない)
var min_level: Level = .info;

/// ログエントリのカウンタ
var log_count: u32 = 0;

/// 最小ログレベルを設定
pub fn setLevel(level: Level) void {
    min_level = level;
}

/// 現在の最小ログレベルを取得
pub fn getLevel() Level {
    return min_level;
}

/// メッセージを出力する
pub fn log(level: Level, msg: []const u8) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

    log_count += 1;

    // VGA 出力 (色分け)
    const prev_color = level.color();
    vga.setColor(prev_color, .black);
    vga.putChar('[');
    vga.write(level.name());
    vga.write("] ");
    vga.setColor(.light_grey, .black);
    vga.write(msg);
    vga.putChar('\n');

    // シリアル出力
    serial.putChar('[');
    serial.write(level.name());
    serial.write("] ");
    serial.write(msg);
    serial.putChar('\n');
}

/// メッセージと 16 進値を出力する
pub fn logHex(level: Level, msg: []const u8, val: u32) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

    log_count += 1;

    // VGA 出力
    vga.setColor(level.color(), .black);
    vga.putChar('[');
    vga.write(level.name());
    vga.write("] ");
    vga.setColor(.light_grey, .black);
    vga.write(msg);
    vga.write("0x");
    fmt.printHex32(val);
    vga.putChar('\n');

    // シリアル出力
    serial.putChar('[');
    serial.write(level.name());
    serial.write("] ");
    serial.write(msg);
    serial.writeHex(val);
    serial.putChar('\n');
}

/// メッセージと 10 進値を出力する
pub fn logDec(level: Level, msg: []const u8, val: usize) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

    log_count += 1;

    vga.setColor(level.color(), .black);
    vga.putChar('[');
    vga.write(level.name());
    vga.write("] ");
    vga.setColor(.light_grey, .black);
    vga.write(msg);
    pmm.printNum(val);
    vga.putChar('\n');

    serial.putChar('[');
    serial.write(level.name());
    serial.write("] ");
    serial.write(msg);
    serial.writeHex(val);
    serial.putChar('\n');
}

/// 便利関数: デバッグ
pub fn debug(msg: []const u8) void {
    log(.debug, msg);
}

/// 便利関数: 情報
pub fn info(msg: []const u8) void {
    log(.info, msg);
}

/// 便利関数: 警告
pub fn warn(msg: []const u8) void {
    log(.warn, msg);
}

/// 便利関数: エラー
pub fn err(msg: []const u8) void {
    log(.err, msg);
}

/// 便利関数: 致命的エラー
pub fn fatal(msg: []const u8) void {
    log(.fatal, msg);
}

/// 現在のログ統計を表示
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("Log Status:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Level:    ");
    vga.write(min_level.name());
    vga.putChar('\n');
    vga.write("  Messages: ");
    pmm.printNum(log_count);
    vga.putChar('\n');
}

/// レベル名文字列から Level に変換
pub fn parseLevel(name: []const u8) ?Level {
    if (eql(name, "debug")) return .debug;
    if (eql(name, "info")) return .info;
    if (eql(name, "warn")) return .warn;
    if (eql(name, "err")) return .err;
    if (eql(name, "error")) return .err;
    if (eql(name, "fatal")) return .fatal;
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
