// パス操作ユーティリティ — ファイルパスの解析と操作

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- PathComponents ----

pub const PathComponents = struct {
    root: []const u8, // "/" or ""
    dir: []const u8, // directory part
    base: []const u8, // filename with extension
    ext: []const u8, // extension without dot
};

// ---- basename ----

pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    // 末尾のスラッシュを除去
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";

    // 最後のスラッシュを検索
    var i = end;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 .. end];
    }
    return path[0..end];
}

// ---- dirname ----

pub fn dirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    // 末尾のスラッシュを除去
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";

    // 最後のスラッシュを検索
    var i = end;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            // 先頭スラッシュの場合
            if (i == 0) return "/";
            return path[0..i];
        }
    }
    return ".";
}

// ---- extension ----

pub fn extension(path: []const u8) []const u8 {
    const base = basename(path);
    // 最後のドットを検索
    var i = base.len;
    while (i > 0) {
        i -= 1;
        if (base[i] == '.') {
            if (i == 0) return ""; // ".hidden" にはマッチしない
            return base[i + 1 .. base.len];
        }
    }
    return "";
}

// ---- join ----

pub fn join(a: []const u8, b: []const u8, buf: []u8) []u8 {
    if (a.len == 0) {
        const len = @min(b.len, buf.len);
        @memcpy(buf[0..len], b[0..len]);
        return buf[0..len];
    }
    if (b.len == 0) {
        const len = @min(a.len, buf.len);
        @memcpy(buf[0..len], a[0..len]);
        return buf[0..len];
    }

    // b が絶対パスなら b をそのまま返す
    if (b[0] == '/') {
        const len = @min(b.len, buf.len);
        @memcpy(buf[0..len], b[0..len]);
        return buf[0..len];
    }

    var pos: usize = 0;
    const a_len = @min(a.len, buf.len);
    @memcpy(buf[0..a_len], a[0..a_len]);
    pos = a_len;

    // a の末尾にスラッシュがなければ追加
    if (pos > 0 and buf[pos - 1] != '/' and pos < buf.len) {
        buf[pos] = '/';
        pos += 1;
    }

    const b_len = @min(b.len, buf.len - pos);
    @memcpy(buf[pos .. pos + b_len], b[0..b_len]);
    pos += b_len;
    return buf[0..pos];
}

// ---- normalize ----

pub fn normalize(path: []const u8, buf: []u8) []u8 {
    if (path.len == 0) {
        if (buf.len > 0) {
            buf[0] = '.';
            return buf[0..1];
        }
        return buf[0..0];
    }

    const is_abs = path[0] == '/';

    // コンポーネントを分割してスタックに積む
    var components: [32]Span = undefined;
    var comp_count: usize = 0;

    var start: usize = 0;
    while (start < path.len) {
        while (start < path.len and path[start] == '/') start += 1;
        if (start >= path.len) break;
        var end = start;
        while (end < path.len and path[end] != '/') end += 1;
        const component = path[start..end];

        if (eql(component, ".")) {
            // skip
        } else if (eql(component, "..")) {
            if (comp_count > 0 and !eql(extractSpan(path, components[comp_count - 1]), "..")) {
                comp_count -= 1;
            } else if (!is_abs) {
                if (comp_count < 32) {
                    components[comp_count] = .{ .s = start, .e = end };
                    comp_count += 1;
                }
            }
        } else {
            if (comp_count < 32) {
                components[comp_count] = .{ .s = start, .e = end };
                comp_count += 1;
            }
        }
        start = end;
    }

    // 結果を構築
    var pos: usize = 0;
    if (is_abs) {
        if (pos < buf.len) {
            buf[pos] = '/';
            pos += 1;
        }
    }

    for (components[0..comp_count], 0..) |comp, idx| {
        if (idx > 0 and pos < buf.len) {
            buf[pos] = '/';
            pos += 1;
        }
        const c = path[comp.s..comp.e];
        const copy_len = @min(c.len, buf.len - pos);
        @memcpy(buf[pos .. pos + copy_len], c[0..copy_len]);
        pos += copy_len;
    }

    if (pos == 0) {
        if (buf.len > 0) {
            buf[0] = '.';
            return buf[0..1];
        }
    }
    return buf[0..pos];
}

const Span = struct { s: usize, e: usize };

fn extractSpan(path: []const u8, span: Span) []const u8 {
    return path[span.s..span.e];
}

// ---- isAbsolute / isRelative ----

pub fn isAbsolute(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

pub fn isRelative(path: []const u8) bool {
    return !isAbsolute(path);
}

// ---- split ----

pub fn split(path: []const u8) PathComponents {
    return PathComponents{
        .root = if (isAbsolute(path)) "/" else "",
        .dir = dirname(path),
        .base = basename(path),
        .ext = extension(path),
    };
}

// ---- depth ----

pub fn depth(path: []const u8) usize {
    if (path.len == 0) return 0;

    var count: usize = 0;
    var start: usize = 0;
    while (start < path.len) {
        while (start < path.len and path[start] == '/') start += 1;
        if (start >= path.len) break;
        var end = start;
        while (end < path.len and path[end] != '/') end += 1;
        count += 1;
        start = end;
    }
    return count;
}

// ---- parent ----

pub fn parent(path: []const u8, buf: []u8) []u8 {
    const dir = dirname(path);
    const len = @min(dir.len, buf.len);
    @memcpy(buf[0..len], dir[0..len]);
    return buf[0..len];
}

// ---- matches (simple glob) ----

pub fn matches(path: []const u8, pattern: []const u8) bool {
    return globMatch(path, 0, pattern, 0);
}

fn globMatch(text: []const u8, ti: usize, pattern: []const u8, pi: usize) bool {
    var t = ti;
    var p = pi;

    while (p < pattern.len) {
        if (pattern[p] == '*') {
            p += 1;
            // * は任意の文字列にマッチ
            // 残りのパターンが空なら即マッチ
            if (p >= pattern.len) return true;
            // テキストの各位置からマッチを試行
            while (t <= text.len) {
                if (globMatch(text, t, pattern, p)) return true;
                t += 1;
            }
            return false;
        } else if (pattern[p] == '?') {
            // ? は任意の 1 文字にマッチ
            if (t >= text.len) return false;
            t += 1;
            p += 1;
        } else {
            if (t >= text.len) return false;
            if (text[t] != pattern[p]) return false;
            t += 1;
            p += 1;
        }
    }
    return t == text.len;
}

// ---- hasExtension ----

pub fn hasExtension(path: []const u8, ext: []const u8) bool {
    const file_ext = extension(path);
    return eql(file_ext, ext);
}

// ---- filenameWithoutExtension ----

pub fn stem(path: []const u8) []const u8 {
    const base = basename(path);
    var i = base.len;
    while (i > 0) {
        i -= 1;
        if (base[i] == '.') {
            if (i == 0) return base;
            return base[0..i];
        }
    }
    return base;
}

// ---- startsWith ----

pub fn startsWith(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    return eql(path[0..prefix.len], prefix);
}

// ---- endsWith ----

pub fn endsWith(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    return eql(path[path.len - suffix.len ..], suffix);
}

// ---- printPath (display path info) ----

pub fn printPath(path: []const u8) void {
    vga.setColor(.yellow, .black);
    vga.write("Path Analysis:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Path:      ");
    vga.write(path);
    vga.putChar('\n');

    vga.write("  Dirname:   ");
    vga.write(dirname(path));
    vga.putChar('\n');

    vga.write("  Basename:  ");
    vga.write(basename(path));
    vga.putChar('\n');

    vga.write("  Extension: ");
    const ext = extension(path);
    if (ext.len > 0) {
        vga.write(ext);
    } else {
        vga.write("(none)");
    }
    vga.putChar('\n');

    vga.write("  Stem:      ");
    vga.write(stem(path));
    vga.putChar('\n');

    vga.write("  Depth:     ");
    fmt.printDec(depth(path));
    vga.putChar('\n');

    vga.write("  Absolute:  ");
    if (isAbsolute(path)) {
        vga.write("yes");
    } else {
        vga.write("no");
    }
    vga.putChar('\n');
}

// ---- ヘルパー ----

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
