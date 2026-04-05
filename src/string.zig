// String Utilities — libc 互換の文字列操作関数群
// freestanding 環境のため std は使用しない

/// null 終端文字列の長さを返す
pub fn strlen(s: [*]const u8) usize {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}

/// 2 つのスライスを辞書順で比較する
/// 戻り値: 負なら a < b, 正なら a > b, 0 なら等しい
pub fn strcmp(a: []const u8, b: []const u8) i32 {
    const min_len = if (a.len < b.len) a.len else b.len;
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        if (a[i] != b[i]) {
            return @as(i32, a[i]) - @as(i32, b[i]);
        }
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

/// 最大 n 文字まで比較する
pub fn strncmp(a: []const u8, b: []const u8, n: usize) i32 {
    const a_len = if (a.len < n) a.len else n;
    const b_len = if (b.len < n) b.len else n;
    return strcmp(a[0..a_len], b[0..b_len]);
}

/// スライス中で文字 c の最初の出現位置を返す
pub fn strchr(s: []const u8, c: u8) ?usize {
    for (s, 0..) |ch, i| {
        if (ch == c) return i;
    }
    return null;
}

/// スライス中で文字 c の最後の出現位置を返す
pub fn strrchr(s: []const u8, c: u8) ?usize {
    var last: ?usize = null;
    for (s, 0..) |ch, i| {
        if (ch == c) last = i;
    }
    return last;
}

/// メモリをバイト値で埋める
pub fn memset(dest: [*]u8, val: u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = val;
    }
}

/// メモリ領域を比較する
/// 戻り値: 0 なら等しい, 負なら a < b, 正なら a > b
pub fn memcmp(a: [*]const u8, b: [*]const u8, len: usize) i32 {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) {
            return @as(i32, a[i]) - @as(i32, b[i]);
        }
    }
    return 0;
}

/// メモリコピー (重複なし)
pub fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dest[i] = src[i];
    }
}

/// 文字列を i32 に変換する。先頭の '-' で負数対応。
/// 変換失敗時は null を返す。
pub fn atoi(s: []const u8) ?i32 {
    if (s.len == 0) return null;

    var idx: usize = 0;
    var negative = false;

    if (s[0] == '-') {
        negative = true;
        idx = 1;
        if (idx >= s.len) return null;
    } else if (s[0] == '+') {
        idx = 1;
        if (idx >= s.len) return null;
    }

    var result: i32 = 0;
    while (idx < s.len) : (idx += 1) {
        const c = s[idx];
        if (c < '0' or c > '9') return null;
        // オーバーフローチェック
        const digit: i32 = @intCast(c - '0');
        if (result > @divTrunc(2147483647, 10)) return null;
        result = result * 10 + digit;
    }
    return if (negative) -result else result;
}

/// i32 を 10 進文字列に変換してバッファに書き込む
/// 返り値: 書き込んだ文字列のスライス
pub fn itoa(n: i32, buf: []u8) []u8 {
    if (buf.len == 0) return buf[0..0];

    var val: u32 = undefined;
    var pos: usize = 0;

    if (n < 0) {
        buf[0] = '-';
        pos = 1;
        // -2147483648 のケース
        val = @bitCast(-n);
    } else {
        val = @intCast(n);
    }

    if (val == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            return buf[0 .. pos + 1];
        }
        return buf[0..pos];
    }

    // 逆順に数字を書く
    var tmp: [11]u8 = undefined;
    var tmp_len: usize = 0;
    var v = val;
    while (v > 0) {
        tmp[tmp_len] = @truncate('0' + v % 10);
        tmp_len += 1;
        v /= 10;
    }

    // 反転してバッファにコピー
    while (tmp_len > 0 and pos < buf.len) {
        tmp_len -= 1;
        buf[pos] = tmp[tmp_len];
        pos += 1;
    }

    return buf[0..pos];
}

/// 大文字に変換 (ASCII のみ)
pub fn toUpper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

/// 小文字に変換 (ASCII のみ)
pub fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// haystack が needle を含むかどうか
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    const limit = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (haystack[i + j] != needle[j]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// スライスの等価比較
pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

/// ASCII 文字が数字かどうか
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// ASCII 文字がアルファベットかどうか
pub fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// ASCII 文字が英数字かどうか
pub fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

/// ASCII 文字が空白文字かどうか
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// 文字列をすべて大文字に変換 (in-place)
pub fn toUpperStr(s: []u8) void {
    for (s) |*c| {
        c.* = toUpper(c.*);
    }
}

/// 文字列をすべて小文字に変換 (in-place)
pub fn toLowerStr(s: []u8) void {
    for (s) |*c| {
        c.* = toLower(c.*);
    }
}

/// 文字列を逆順にする (in-place)
pub fn reverse(s: []u8) void {
    if (s.len <= 1) return;
    var left: usize = 0;
    var right: usize = s.len - 1;
    while (left < right) {
        const tmp = s[left];
        s[left] = s[right];
        s[right] = tmp;
        left += 1;
        right -= 1;
    }
}
