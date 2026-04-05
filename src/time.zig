// 時間管理 — RTC ベースのタイムキーピング・Unix タイムスタンプ・アラーム

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const rtc = @import("rtc.zig");
const pit = @import("pit.zig");

// ---- DateTime (rtc.DateTime と互換) ----

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    day_of_week: u8, // 0=Sun, 1=Mon, ..., 6=Sat
};

// ---- 定数 ----

/// 月ごとの日数 (平年)
const days_per_month = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// 月ごとの累積日数 (1月1日 = 0)
const cumulative_days = [12]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

// ---- 基本時刻取得 ----

/// 現在の日時を取得 (RTC から)
pub fn now() DateTime {
    const raw = rtc.read();
    const dow = dayOfWeek(raw.year, raw.month, raw.day);
    return .{
        .year = raw.year,
        .month = raw.month,
        .day = raw.day,
        .hour = raw.hour,
        .minute = raw.minute,
        .second = raw.second,
        .day_of_week = dow,
    };
}

/// カーネル起動からの経過ミリ秒
pub fn uptimeMs() u64 {
    return pit.getTicks();
}

/// カーネル起動からの経過秒
pub fn uptimeSecs() u32 {
    return @truncate(pit.getTicks() / 1000);
}

// ---- うるう年・月の日数 ----

/// うるう年判定
pub fn isLeapYear(year: u16) bool {
    if (year % 4 != 0) return false;
    if (year % 100 != 0) return true;
    if (year % 400 != 0) return false;
    return true;
}

/// 月の日数を返す (1-12)
pub fn daysInMonth(month: u8, year: u16) u8 {
    if (month < 1 or month > 12) return 0;
    if (month == 2 and isLeapYear(year)) return 29;
    return days_per_month[month - 1];
}

/// 年の日数を返す
pub fn daysInYear(year: u16) u16 {
    return if (isLeapYear(year)) 366 else 365;
}

// ---- 曜日計算 (Zeller の公式の変形 / Tomohiko Sakamoto) ----

/// 曜日を計算 (0=Sun, 1=Mon, ..., 6=Sat)
pub fn dayOfWeek(year: u16, month: u8, day: u8) u8 {
    // Tomohiko Sakamoto のアルゴリズム
    const t = [12]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y = year;
    if (month < 3) y -= 1;
    const uy: u32 = y;
    const result = (uy + uy / 4 - uy / 100 + uy / 400 + t[month - 1] + day) % 7;
    return @truncate(result);
}

/// 曜日名を返す
pub fn dayName(dow: u8) []const u8 {
    return switch (dow) {
        0 => "Sun",
        1 => "Mon",
        2 => "Tue",
        3 => "Wed",
        4 => "Thu",
        5 => "Fri",
        6 => "Sat",
        else => "???",
    };
}

/// 月名を返す
pub fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        12 => "Dec",
        else => "???",
    };
}

// ---- Unix タイムスタンプ変換 ----

/// DateTime を Unix タイムスタンプに変換 (1970-01-01 00:00:00 UTC 基準)
pub fn toTimestamp(dt: DateTime) u32 {
    // 1970 年から dt.year までの日数を計算
    var days: u32 = 0;

    // 年の加算
    var y: u16 = 1970;
    while (y < dt.year) : (y += 1) {
        days += daysInYear(y);
    }

    // 月の加算 (1月 = 0 日)
    if (dt.month >= 2) {
        days += cumulative_days[dt.month - 1];
        // うるう年で 3 月以降なら +1
        if (dt.month > 2 and isLeapYear(dt.year)) {
            days += 1;
        }
    }

    // 日の加算
    if (dt.day > 0) days += dt.day - 1;

    // 秒に変換
    var secs: u32 = days * 86400;
    secs += @as(u32, dt.hour) * 3600;
    secs += @as(u32, dt.minute) * 60;
    secs += dt.second;

    return secs;
}

/// Unix タイムスタンプを DateTime に変換
pub fn fromTimestamp(ts: u32) DateTime {
    var remaining = ts;

    // 秒・分・時を取り出す
    const second: u8 = @truncate(remaining % 60);
    remaining /= 60;
    const minute: u8 = @truncate(remaining % 60);
    remaining /= 60;
    const hour: u8 = @truncate(remaining % 24);
    remaining /= 24;

    // remaining = 1970-01-01 からの日数
    var year: u16 = 1970;
    while (true) {
        const dy = daysInYear(year);
        if (remaining < dy) break;
        remaining -= dy;
        year += 1;
    }

    // remaining = 年内の日数 (0 ベース)
    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        const dm = daysInMonth(month, year);
        if (remaining < dm) break;
        remaining -= dm;
    }

    const day: u8 = @truncate(remaining + 1);
    const dow = dayOfWeek(year, month, day);

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .day_of_week = dow,
    };
}

// ---- 日時フォーマット ----

/// "YYYY-MM-DD HH:MM:SS" にフォーマット (19 文字)
pub fn formatDate(dt: DateTime, buf: *[19]u8) void {
    // YYYY
    writeDecPadded4(buf[0..4], dt.year);
    buf[4] = '-';
    // MM
    writeDecPadded2(buf[5..7], dt.month);
    buf[7] = '-';
    // DD
    writeDecPadded2(buf[8..10], dt.day);
    buf[10] = ' ';
    // HH
    writeDecPadded2(buf[11..13], dt.hour);
    buf[13] = ':';
    // MM
    writeDecPadded2(buf[14..16], dt.minute);
    buf[16] = ':';
    // SS
    writeDecPadded2(buf[17..19], dt.second);
}

/// "3 hours ago", "2 days ago" 等の相対時間文字列
/// buf に書き込んで使用した長さを返す
pub fn formatRelative(seconds: u32, buf: *[32]u8) usize {
    if (seconds < 60) {
        return writeRelative(buf, seconds, "second");
    } else if (seconds < 3600) {
        return writeRelative(buf, seconds / 60, "minute");
    } else if (seconds < 86400) {
        return writeRelative(buf, seconds / 3600, "hour");
    } else if (seconds < 2592000) {
        return writeRelative(buf, seconds / 86400, "day");
    } else if (seconds < 31536000) {
        return writeRelative(buf, seconds / 2592000, "month");
    } else {
        return writeRelative(buf, seconds / 31536000, "year");
    }
}

fn writeRelative(buf: *[32]u8, val: u32, unit: []const u8) usize {
    var pos: usize = 0;

    // 数値を書き込む
    if (val == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var tmp: [10]u8 = undefined;
        var len: usize = 0;
        var v = val;
        while (v > 0) {
            tmp[len] = @truncate('0' + v % 10);
            len += 1;
            v /= 10;
        }
        while (len > 0) {
            len -= 1;
            buf[pos] = tmp[len];
            pos += 1;
        }
    }

    buf[pos] = ' ';
    pos += 1;

    // 単位
    for (unit) |c| {
        if (pos >= 32) break;
        buf[pos] = c;
        pos += 1;
    }

    // 複数形
    if (val != 1 and pos < 32) {
        buf[pos] = 's';
        pos += 1;
    }

    // " ago"
    const ago = " ago";
    for (ago) |c| {
        if (pos >= 32) break;
        buf[pos] = c;
        pos += 1;
    }

    return pos;
}

// ---- 2つの DateTime の差分 ----

/// 2 つの DateTime の差分を秒で返す (a - b)
pub fn diffSeconds(a: DateTime, b: DateTime) i32 {
    const ta: i32 = @intCast(toTimestamp(a));
    const tb: i32 = @intCast(toTimestamp(b));
    return ta - tb;
}

// ---- アラーム (タイマーホイール) ----

pub const AlarmCallback = *const fn () void;

const AlarmEntry = struct {
    active: bool,
    target_ts: u32, // 発火する Unix タイムスタンプ
    callback: ?AlarmCallback,
    name: [16]u8,
    name_len: u8,
    fired: bool, // 発火済みフラグ
};

const MAX_ALARMS = 4;
var alarms: [MAX_ALARMS]AlarmEntry = initAlarms();

fn initAlarms() [MAX_ALARMS]AlarmEntry {
    var table: [MAX_ALARMS]AlarmEntry = undefined;
    for (&table) |*a| {
        a.active = false;
        a.target_ts = 0;
        a.callback = null;
        a.name = [_]u8{0} ** 16;
        a.name_len = 0;
        a.fired = false;
    }
    return table;
}

/// 指定日時にアラームを設定
pub fn setAlarm(dt: DateTime, callback: AlarmCallback) ?usize {
    return setAlarmNamed(dt, callback, "alarm");
}

/// 名前付きアラームを設定
pub fn setAlarmNamed(dt: DateTime, callback: AlarmCallback, name: []const u8) ?usize {
    for (&alarms, 0..) |*a, i| {
        if (!a.active) {
            a.active = true;
            a.target_ts = toTimestamp(dt);
            a.callback = callback;
            a.fired = false;
            const nlen: u8 = @intCast(@min(name.len, 16));
            @memcpy(a.name[0..nlen], name[0..nlen]);
            a.name_len = nlen;

            serial.write("[time] alarm set for ts=");
            serial.writeHex(a.target_ts);
            serial.write("\n");

            return i;
        }
    }
    return null;
}

/// N 秒後にアラームを設定 (相対時間)
pub fn setAlarmAfter(secs: u32, callback: AlarmCallback) ?usize {
    const current = now();
    const current_ts = toTimestamp(current);
    const target = fromTimestamp(current_ts + secs);
    return setAlarm(target, callback);
}

/// アラームをキャンセル
pub fn cancelAlarm(slot: usize) void {
    if (slot >= MAX_ALARMS) return;
    alarms[slot].active = false;
}

/// アラームチェック: 定期的に呼ばれるべき (PIT tick から)
pub fn checkAlarms() void {
    const current = now();
    const current_ts = toTimestamp(current);

    for (&alarms) |*a| {
        if (a.active and !a.fired and current_ts >= a.target_ts) {
            a.fired = true;
            if (a.callback) |cb| {
                cb();
            }
            a.active = false;
        }
    }
}

/// アラーム一覧を表示
pub fn printAlarms() void {
    vga.setColor(.yellow, .black);
    vga.write("Active Alarms:\n");
    vga.setColor(.light_grey, .black);

    var found = false;
    for (&alarms, 0..) |*a, i| {
        if (a.active) {
            found = true;
            vga.write("  [");
            printDec(i);
            vga.write("] ");
            vga.write(a.name[0..a.name_len]);
            vga.write(" at ts=");
            printDec(a.target_ts);
            if (a.fired) {
                vga.setColor(.dark_grey, .black);
                vga.write(" (fired)");
                vga.setColor(.light_grey, .black);
            }
            vga.putChar('\n');
        }
    }
    if (!found) {
        vga.write("  (none)\n");
    }
}

// ---- 表示関数 ----

/// 現在時刻をフォーマットして表示
pub fn printNow() void {
    const dt = now();
    var buf: [19]u8 = undefined;
    formatDate(dt, &buf);

    vga.setColor(.light_cyan, .black);
    vga.write(dayName(dt.day_of_week));
    vga.write(" ");
    vga.write(&buf);
    vga.write(" UTC\n");
    vga.setColor(.light_grey, .black);
}

/// Uptime を表示
pub fn printUptime() void {
    const up_sec = uptimeSecs();
    const hours = up_sec / 3600;
    const mins = (up_sec % 3600) / 60;
    const secs = up_sec % 60;

    vga.setColor(.light_cyan, .black);
    vga.write("Uptime: ");
    vga.setColor(.light_grey, .black);
    printDec(hours);
    vga.write("h ");
    printDec(mins);
    vga.write("m ");
    printDec(secs);
    vga.write("s\n");
}

/// タイムスタンプ変換テスト
pub fn selfTest() void {
    // Epoch
    const epoch = fromTimestamp(0);
    const expect_epoch = (epoch.year == 1970 and epoch.month == 1 and epoch.day == 1);

    vga.setColor(.light_cyan, .black);
    vga.write("Time self-test: ");
    if (expect_epoch) {
        vga.setColor(.light_green, .black);
        vga.write("epoch OK, ");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("epoch FAIL, ");
    }

    // 往復テスト: now -> ts -> dt
    const current = now();
    const ts = toTimestamp(current);
    const back = fromTimestamp(ts);
    const roundtrip = (back.year == current.year and back.month == current.month and back.day == current.day and back.hour == current.hour and back.minute == current.minute);

    if (roundtrip) {
        vga.setColor(.light_green, .black);
        vga.write("roundtrip OK\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("roundtrip FAIL\n");
    }
    vga.setColor(.light_grey, .black);
}

// ---- 内部ヘルパ ----

fn writeDecPadded2(buf: *[2]u8, val: u8) void {
    buf[0] = '0' + val / 10;
    buf[1] = '0' + val % 10;
}

fn writeDecPadded4(buf: *[4]u8, val: u16) void {
    buf[0] = @truncate('0' + val / 1000);
    buf[1] = @truncate('0' + (val / 100) % 10);
    buf[2] = @truncate('0' + (val / 10) % 10);
    buf[3] = @truncate('0' + val % 10);
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
