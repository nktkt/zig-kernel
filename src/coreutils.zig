// コアユーティリティ — 基本的なテキスト処理コマンド

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");

// ---- wc (ワードカウント) ----

pub const WcResult = struct {
    lines: usize,
    words: usize,
    chars: usize,
    bytes: usize,
};

pub fn wc(text: []const u8) WcResult {
    var result = WcResult{ .lines = 0, .words = 0, .chars = 0, .bytes = text.len };
    var in_word = false;

    for (text) |c| {
        result.chars += 1;
        if (c == '\n') result.lines += 1;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (in_word) {
                result.words += 1;
                in_word = false;
            }
        } else {
            in_word = true;
        }
    }
    if (in_word) result.words += 1;

    return result;
}

pub fn printWc(text: []const u8) void {
    const result = wc(text);
    vga.setColor(.light_cyan, .black);
    vga.write("  lines: ");
    vga.setColor(.white, .black);
    fmt.printDec(result.lines);
    vga.setColor(.light_cyan, .black);
    vga.write("  words: ");
    vga.setColor(.white, .black);
    fmt.printDec(result.words);
    vga.setColor(.light_cyan, .black);
    vga.write("  chars: ");
    vga.setColor(.white, .black);
    fmt.printDec(result.chars);
    vga.setColor(.light_cyan, .black);
    vga.write("  bytes: ");
    vga.setColor(.white, .black);
    fmt.printDec(result.bytes);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

// ---- head (先頭 n 行) ----

pub fn head(text: []const u8, n: usize) []const u8 {
    if (n == 0) return text[0..0];
    var lines: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            lines += 1;
            if (lines >= n) return text[0 .. i + 1];
        }
    }
    return text;
}

pub fn printHead(text: []const u8, n: usize) void {
    vga.write(head(text, n));
}

// ---- tail (末尾 n 行) ----

pub fn tail(text: []const u8, n: usize) []const u8 {
    if (n == 0 or text.len == 0) return text[0..0];

    // 全行数を数える
    var total_lines: usize = 0;
    for (text) |c| {
        if (c == '\n') total_lines += 1;
    }
    // 末尾が改行でない場合
    if (text.len > 0 and text[text.len - 1] != '\n') total_lines += 1;

    if (n >= total_lines) return text;

    // スキップする行数
    const skip = total_lines - n;
    var skipped: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            skipped += 1;
            if (skipped >= skip) return text[i + 1 ..];
        }
    }
    return text;
}

pub fn printTail(text: []const u8, n: usize) void {
    vga.write(tail(text, n));
}

// ---- grep (パターンマッチ行を表示) ----

pub fn grep(text: []const u8, pattern: []const u8) void {
    if (pattern.len == 0) {
        vga.write(text);
        return;
    }

    var line_start: usize = 0;
    var line_num: usize = 1;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = text[line_start..line_end];

            if (containsSubstring(line, pattern)) {
                vga.setColor(.yellow, .black);
                fmt.printDecPadded(line_num, 4);
                vga.setColor(.dark_grey, .black);
                vga.write(": ");
                // パターン部分をハイライト
                printHighlighted(line, pattern);
                vga.putChar('\n');
            }
            line_start = i + 1;
            line_num += 1;
        }
    }
    vga.setColor(.light_grey, .black);
}

// ---- uniq (重複行を除去して表示) ----

pub fn uniq(text: []const u8) void {
    var prev_start: usize = 0;
    var prev_end: usize = 0;
    var first = true;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = text[line_start..line_end];

            if (first or !eql(line, text[prev_start..prev_end])) {
                vga.write(line);
                vga.putChar('\n');
            }
            prev_start = line_start;
            prev_end = line_end;
            first = false;
            line_start = i + 1;
        }
    }
}

// ---- tr (文字変換) ----

pub fn tr(text: []const u8, from: []const u8, to: []const u8) void {
    for (text) |c| {
        var replaced = false;
        for (from, 0..) |fc, fi| {
            if (c == fc and fi < to.len) {
                vga.putChar(to[fi]);
                replaced = true;
                break;
            }
        }
        if (!replaced) vga.putChar(c);
    }
}

// ---- cut (フィールド��出) ----

pub fn cut(text: []const u8, delimiter: u8, field: usize) void {
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = text[line_start..line_end];

            // フィールドを抽出
            var current_field: usize = 1;
            var field_start: usize = 0;
            var found = false;

            for (line, 0..) |lc, li| {
                if (lc == delimiter) {
                    if (current_field == field) {
                        vga.write(line[field_start..li]);
                        vga.putChar('\n');
                        found = true;
                        break;
                    }
                    current_field += 1;
                    field_start = li + 1;
                }
            }
            if (!found and current_field == field and field_start < line.len) {
                vga.write(line[field_start..]);
                vga.putChar('\n');
            }
            line_start = i + 1;
        }
    }
}

// ---- rev (各行を反転) ----

pub fn rev(text: []const u8) void {
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = text[line_start..line_end];

            // 逆順で出力
            var j = line.len;
            while (j > 0) {
                j -= 1;
                vga.putChar(line[j]);
            }
            vga.putChar('\n');
            line_start = i + 1;
        }
    }
}

// ---- nl (行番号付与) ----

pub fn nl(text: []const u8) void {
    var line_num: usize = 1;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = text[line_start..line_end];

            vga.setColor(.dark_grey, .black);
            fmt.printDecPadded(line_num, 6);
            vga.write("  ");
            vga.setColor(.light_grey, .black);
            vga.write(line);
            vga.putChar('\n');

            line_num += 1;
            line_start = i + 1;
        }
    }
}

// ---- tac (行順序を反転) ----

pub fn tac(text: []const u8) void {
    // 行の開始位置を記録
    var line_starts: [256]usize = undefined;
    var line_ends: [256]usize = undefined;
    var line_count: usize = 0;
    var start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const end = if (c == '\n') i else i + 1;
            if (line_count < 256) {
                line_starts[line_count] = start;
                line_ends[line_count] = end;
                line_count += 1;
            }
            start = i + 1;
        }
    }

    // 逆順で出力
    var i = line_count;
    while (i > 0) {
        i -= 1;
        vga.write(text[line_starts[i]..line_ends[i]]);
        vga.putChar('\n');
    }
}

// ---- yes (テキストを繰り返し出力) ----

pub fn yes(text: []const u8, count: usize) void {
    const msg = if (text.len > 0) text else "y";
    var i: usize = 0;
    while (i < count) : (i += 1) {
        vga.write(msg);
        vga.putChar('\n');
    }
}

// ---- seq (連番出力) ----

pub fn seq(start_val: i32, end_val: i32, step_val: i32) void {
    if (step_val == 0) return;

    var current = start_val;
    if (step_val > 0) {
        while (current <= end_val) {
            fmt.printDecSigned(current);
            vga.putChar('\n');
            const result = @addWithOverflow(current, step_val);
            if (result[1] != 0) break;
            current = result[0];
        }
    } else {
        while (current >= end_val) {
            fmt.printDecSigned(current);
            vga.putChar('\n');
            const result = @addWithOverflow(current, step_val);
            if (result[1] != 0) break;
            current = result[0];
        }
    }
}

// ---- cal (カレンダー表示) ----

pub fn cal() void {
    // PIT ticks からおおよその日付を推定するのは困難なので
    // RTC は別モジュールにあるため、固定的なカレンダーを表示
    // ここでは現在月のテンプレートを表示
    vga.setColor(.yellow, .black);
    vga.write("      Calendar\n");
    vga.setColor(.light_cyan, .black);
    vga.write(" Su Mo Tu We Th Fr Sa\n");
    vga.setColor(.light_grey, .black);

    // 簡易: 1日が月曜日の31日月を仮定
    var day: u8 = 1;
    // 月曜日始まり -> 2 スペース分インデント (日曜は空)
    vga.write("     ");
    var dow: u8 = 1; // 0=Sun, 1=Mon

    while (day <= 31) {
        if (day < 10) vga.putChar(' ');
        printU8(day);
        vga.putChar(' ');

        dow += 1;
        if (dow >= 7) {
            dow = 0;
            vga.putChar('\n');
        }
        day += 1;
    }
    if (dow != 0) vga.putChar('\n');
}

// ---- factor (素因数分解) ----

pub fn factor(n: u32) void {
    if (n < 2) {
        fmt.printDec(n);
        vga.write(": ");
        fmt.printDec(n);
        vga.putChar('\n');
        return;
    }

    fmt.printDec(n);
    vga.write(": ");

    var val = n;
    var divisor: u32 = 2;
    var first = true;

    while (divisor * divisor <= val) {
        while (val % divisor == 0) {
            if (!first) vga.write(" * ");
            fmt.printDec(divisor);
            val /= divisor;
            first = false;
        }
        divisor += 1;
    }
    if (val > 1) {
        if (!first) vga.write(" * ");
        fmt.printDec(val);
    }
    vga.putChar('\n');
}

// ---- sort (行をソートして表示) ----

pub fn sortLines(text: []const u8) void {
    // 行を分割
    var line_starts: [128]usize = undefined;
    var line_ends: [128]usize = undefined;
    var line_count: usize = 0;
    var start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n' or i == text.len - 1) {
            const end = if (c == '\n') i else i + 1;
            if (line_count < 128) {
                line_starts[line_count] = start;
                line_ends[line_count] = end;
                line_count += 1;
            }
            start = i + 1;
        }
    }

    // バブルソート
    if (line_count > 1) {
        var i: usize = 0;
        while (i < line_count - 1) : (i += 1) {
            var j: usize = 0;
            while (j < line_count - 1 - i) : (j += 1) {
                const a = text[line_starts[j]..line_ends[j]];
                const b = text[line_starts[j + 1]..line_ends[j + 1]];
                if (strCmp(a, b) > 0) {
                    // swap
                    const tmp_s = line_starts[j];
                    const tmp_e = line_ends[j];
                    line_starts[j] = line_starts[j + 1];
                    line_ends[j] = line_ends[j + 1];
                    line_starts[j + 1] = tmp_s;
                    line_ends[j + 1] = tmp_e;
                }
            }
        }
    }

    for (0..line_count) |i| {
        vga.write(text[line_starts[i]..line_ends[i]]);
        vga.putChar('\n');
    }
}

// ---- basename / dirname (パス操作) ----

pub fn printBasename(path: []const u8) void {
    var last_slash: usize = 0;
    var found = false;
    for (path, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found = true;
        }
    }
    if (found) {
        vga.write(path[last_slash + 1 ..]);
    } else {
        vga.write(path);
    }
    vga.putChar('\n');
}

pub fn printDirname(path: []const u8) void {
    var last_slash: usize = 0;
    var found = false;
    for (path, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found = true;
        }
    }
    if (found) {
        if (last_slash == 0) {
            vga.write("/");
        } else {
            vga.write(path[0..last_slash]);
        }
    } else {
        vga.write(".");
    }
    vga.putChar('\n');
}

// ---- ヘルパー ----

fn containsSubstring(text: []const u8, pattern: []const u8) bool {
    if (pattern.len > text.len) return false;
    if (pattern.len == 0) return true;
    var i: usize = 0;
    while (i + pattern.len <= text.len) : (i += 1) {
        if (eql(text[i .. i + pattern.len], pattern)) return true;
    }
    return false;
}

fn printHighlighted(line: []const u8, pattern: []const u8) void {
    var i: usize = 0;
    while (i < line.len) {
        if (i + pattern.len <= line.len and eql(line[i .. i + pattern.len], pattern)) {
            vga.setColor(.light_red, .black);
            vga.write(pattern);
            vga.setColor(.light_grey, .black);
            i += pattern.len;
        } else {
            vga.putChar(line[i]);
            i += 1;
        }
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn strCmp(a: []const u8, b: []const u8) i32 {
    const min_len = @min(a.len, b.len);
    for (0..min_len) |i| {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn printU8(val: u8) void {
    if (val >= 10) {
        vga.putChar('0' + val / 10);
    }
    vga.putChar('0' + val % 10);
}
