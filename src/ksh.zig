// Kernel Shell Script (ksh) — シンプルなスクリプトインタプリタ
// ramfs 上のスクリプトファイルを実行。変数、条件分岐、ループをサポート。

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");
const serial = @import("serial.zig");
const shell = @import("shell.zig");

// ---- 定数 ----

const MAX_VARS = 16;
const MAX_VAR_NAME = 16;
const MAX_VAR_VALUE = 64;
const MAX_NESTING = 4;
const MAX_LINE_LEN = 256;
const MAX_LINES = 128;

// ---- 変数テーブル ----

const Variable = struct {
    name: [MAX_VAR_NAME]u8,
    name_len: usize,
    value: [MAX_VAR_VALUE]u8,
    value_len: usize,
    used: bool,
};

var variables: [MAX_VARS]Variable = undefined;
var var_count: usize = 0;

// ---- 制御フロー状態 ----

const BlockKind = enum(u8) {
    none,
    if_true, // if 条件が true → 実行中
    if_false, // if 条件が false → スキップ中
    repeat_block, // repeat ループ
};

const BlockState = struct {
    kind: BlockKind,
    start_line: usize, // ループの開始行
    remaining: usize, // repeat の残り回数
};

// ---- エラーハンドリング ----

var had_error: bool = false;
var error_line: usize = 0;
var error_msg_buf: [64]u8 = undefined;
var error_msg_len: usize = 0;

// ---- 初期化 ----

fn resetState() void {
    for (&variables) |*v| v.used = false;
    var_count = 0;
    had_error = false;
    error_line = 0;
    error_msg_len = 0;
}

// ---- 公開 API ----

/// スクリプトテキストを直接実行する
pub fn execute(script_text: []const u8) void {
    resetState();

    serial.write("[ksh] executing script (");
    printNum(script_text.len);
    serial.write(" bytes)\n");

    // 行に分割
    var lines: [MAX_LINES]Line = undefined;
    var line_count: usize = 0;
    splitLines(script_text, &lines, &line_count);

    // 実行
    executeScript(script_text, &lines, line_count);

    if (had_error) {
        vga.setColor(.light_red, .black);
        vga.write("ksh: error at line ");
        fmt.printDec(error_line + 1);
        vga.write(": ");
        vga.write(error_msg_buf[0..error_msg_len]);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
    }
}

/// ramfs からスクリプトファイルを読み込んで実行する
pub fn executeFile(filename: []const u8) void {
    const idx = ramfs.findByName(filename);
    if (idx == null) {
        vga.setColor(.light_red, .black);
        vga.write("ksh: file not found: ");
        vga.write(filename);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
        return;
    }

    var buf: [2048]u8 = undefined;
    const len = ramfs.readFile(idx.?, &buf);
    if (len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("ksh: empty script: ");
        vga.write(filename);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("ksh: running ");
    vga.write(filename);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);

    execute(buf[0..len]);
}

// ---- 行の分割 ----

const Line = struct {
    start: usize,
    len: usize,
};

fn splitLines(text: []const u8, lines: *[MAX_LINES]Line, count: *usize) void {
    var pos: usize = 0;
    var n: usize = 0;
    while (pos < text.len and n < MAX_LINES) {
        // 行の開始
        const start = pos;
        while (pos < text.len and text[pos] != '\n') pos += 1;
        lines[n] = .{ .start = start, .len = pos - start };
        n += 1;
        if (pos < text.len) pos += 1; // skip '\n'
    }
    count.* = n;
}

// ---- 行実行エンジン ----

/// 実行メインループ (スクリプトテキストを保持)
fn executeScript(text: []const u8, lines: *[MAX_LINES]Line, line_count: usize) void {
    var stack: [MAX_NESTING]BlockState = undefined;
    var depth: usize = 0;
    var pc: usize = 0;

    for (&stack) |*s| {
        s.kind = .none;
        s.start_line = 0;
        s.remaining = 0;
    }

    while (pc < line_count) {
        if (had_error) return;

        const line = lines[pc];
        const raw = text[line.start .. line.start + line.len];
        const trimmed = trim(raw);

        pc += 1;

        // 空行・コメント行はスキップ
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        // スキップ中 (if_false) のチェック
        if (depth > 0 and stack[depth - 1].kind == .if_false) {
            // endif だけ処理
            if (eql(trimmed, "endif")) {
                depth -= 1;
            } else if (startsWith(trimmed, "if ")) {
                // ネストした if → depth を増やしてスキップ続行
                if (depth < MAX_NESTING) {
                    stack[depth] = .{ .kind = .if_false, .start_line = 0, .remaining = 0 };
                    depth += 1;
                }
            }
            continue;
        }

        // 制御構文の処理
        if (eql(trimmed, "endif")) {
            if (depth > 0 and (stack[depth - 1].kind == .if_true or stack[depth - 1].kind == .if_false)) {
                depth -= 1;
            } else {
                setError(pc - 1, "unexpected endif");
                return;
            }
            continue;
        }

        if (eql(trimmed, "endrepeat")) {
            if (depth > 0 and stack[depth - 1].kind == .repeat_block) {
                if (stack[depth - 1].remaining > 1) {
                    stack[depth - 1].remaining -= 1;
                    pc = stack[depth - 1].start_line; // ループ先頭に戻る
                } else {
                    depth -= 1; // ループ終了
                }
            } else {
                setError(pc - 1, "unexpected endrepeat");
                return;
            }
            continue;
        }

        if (startsWith(trimmed, "if ")) {
            if (depth >= MAX_NESTING) {
                setError(pc - 1, "max nesting depth exceeded");
                return;
            }
            const cond_str = trimmed[3..];
            const result = evaluateCondition(cond_str);
            stack[depth] = .{
                .kind = if (result) .if_true else .if_false,
                .start_line = 0,
                .remaining = 0,
            };
            depth += 1;
            continue;
        }

        if (startsWith(trimmed, "repeat ")) {
            if (depth >= MAX_NESTING) {
                setError(pc - 1, "max nesting depth exceeded");
                return;
            }
            const count_str = trim(trimmed[7..]);
            const expanded = expandVarsSlice(count_str);
            const n = parseU32(expanded) orelse 0;
            if (n == 0) {
                // 0 回 → endrepeat までスキップ
                var skip_depth: usize = 1;
                while (pc < line_count and skip_depth > 0) {
                    const skip_line = lines[pc];
                    const skip_trimmed = trim(text[skip_line.start .. skip_line.start + skip_line.len]);
                    if (startsWith(skip_trimmed, "repeat ")) skip_depth += 1;
                    if (eql(skip_trimmed, "endrepeat")) skip_depth -= 1;
                    pc += 1;
                }
            } else {
                stack[depth] = .{
                    .kind = .repeat_block,
                    .start_line = pc, // endrepeat 後に戻る行
                    .remaining = n,
                };
                depth += 1;
            }
            continue;
        }

        // 変数代入: VAR=value
        if (findChar(trimmed, '=')) |eq_pos| {
            if (eq_pos > 0 and eq_pos < trimmed.len - 1) {
                const var_name = trimmed[0..eq_pos];
                const var_value = trimmed[eq_pos + 1 ..];
                // 変数名が英数字のみかチェック
                if (isValidVarName(var_name)) {
                    const expanded_val = expandVarsSlice(var_value);
                    setVariable(var_name, expanded_val);
                    continue;
                }
            }
            // 等号が先頭や単独の場合 → コマンドとして実行
        }

        // 通常コマンド行: 変数展開して shell.execute に渡す
        const expanded_line = expandVarsSlice(trimmed);
        shell.executeCommand(expanded_line);
    }

    // スタックが空でない場合はエラー
    if (depth > 0) {
        setError(line_count, "unclosed block (missing endif/endrepeat)");
    }
}

// ---- 条件評価 ----

fn evaluateCondition(cond: []const u8) bool {
    const trimmed = trim(cond);

    // exists <filename>
    if (startsWith(trimmed, "exists ")) {
        const filename = trim(trimmed[7..]);
        const expanded = expandVarsSlice(filename);
        return ramfs.findByName(expanded) != null;
    }

    // eq <a> <b>
    if (startsWith(trimmed, "eq ")) {
        const rest = trim(trimmed[3..]);
        // スペースで 2 つの引数に分割
        if (findChar(rest, ' ')) |sp| {
            const a = expandVarsSlice(rest[0..sp]);
            const b = expandVarsSlice(trim(rest[sp + 1 ..]));
            return eql(a, b);
        }
        return false;
    }

    // 不明な条件は false
    return false;
}

// ---- 変数操作 ----

fn setVariable(name: []const u8, value: []const u8) void {
    // 既存変数を更新
    for (&variables) |*v| {
        if (v.used and v.name_len == name.len and eql(v.name[0..v.name_len], name)) {
            const vlen = @min(value.len, MAX_VAR_VALUE);
            @memcpy(v.value[0..vlen], value[0..vlen]);
            v.value_len = vlen;
            return;
        }
    }
    // 新規変数
    if (var_count >= MAX_VARS) return;
    for (&variables) |*v| {
        if (!v.used) {
            v.used = true;
            const nlen = @min(name.len, MAX_VAR_NAME);
            @memcpy(v.name[0..nlen], name[0..nlen]);
            v.name_len = nlen;
            const vlen = @min(value.len, MAX_VAR_VALUE);
            @memcpy(v.value[0..vlen], value[0..vlen]);
            v.value_len = vlen;
            var_count += 1;
            return;
        }
    }
}

fn getVariable(name: []const u8) ?[]const u8 {
    for (&variables) |*v| {
        if (v.used and v.name_len == name.len and eql(v.name[0..v.name_len], name)) {
            return v.value[0..v.value_len];
        }
    }
    return null;
}

/// $VAR 形式の変数を展開する
/// 内部バッファに展開結果を格納して返す
var expand_buf: [MAX_LINE_LEN]u8 = undefined;

fn expandVarsSlice(input: []const u8) []const u8 {
    var out_len: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_len < MAX_LINE_LEN) {
        if (input[i] == '$' and i + 1 < input.len) {
            // 変数名を読み取る
            i += 1;
            const name_start = i;
            while (i < input.len and isVarChar(input[i])) i += 1;
            const var_name = input[name_start..i];

            if (getVariable(var_name)) |val| {
                const copy_len = @min(val.len, MAX_LINE_LEN - out_len);
                @memcpy(expand_buf[out_len .. out_len + copy_len], val[0..copy_len]);
                out_len += copy_len;
            }
            // 見つからない場合は空文字列に展開
        } else {
            expand_buf[out_len] = input[i];
            out_len += 1;
            i += 1;
        }
    }
    return expand_buf[0..out_len];
}

fn isVarChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn isValidVarName(name: []const u8) bool {
    if (name.len == 0) return false;
    // 先頭は英字またはアンダースコア
    if (!isAlpha(name[0]) and name[0] != '_') return false;
    for (name) |c| {
        if (!isVarChar(c)) return false;
    }
    return true;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ---- エラーハンドリング ----

fn setError(line: usize, msg: []const u8) void {
    had_error = true;
    error_line = line;
    error_msg_len = @min(msg.len, error_msg_buf.len);
    @memcpy(error_msg_buf[0..error_msg_len], msg[0..error_msg_len]);
}

// ---- ユーティリティ ----

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') : (end -= 1) {}
    return s[start..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

fn findChar(s: []const u8, c: u8) ?usize {
    for (s, 0..) |ch, i| {
        if (ch == c) return i;
    }
    return null;
}

fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn printNum(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}

/// スクリプト情報を表示
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("KSH Script Engine:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Variables:    ");
    fmt.printDec(var_count);
    vga.write("/");
    fmt.printDec(MAX_VARS);
    vga.putChar('\n');
    vga.write("  Max nesting:  ");
    fmt.printDec(MAX_NESTING);
    vga.putChar('\n');
    vga.write("  Max lines:    ");
    fmt.printDec(MAX_LINES);
    vga.putChar('\n');
    vga.write("  Syntax:\n");
    vga.write("    # comment\n");
    vga.write("    VAR=value\n");
    vga.write("    if exists <file>\n");
    vga.write("    if eq <a> <b>\n");
    vga.write("    endif\n");
    vga.write("    repeat <n>\n");
    vga.write("    endrepeat\n");
    vga.write("    <shell command>\n");

    // 現在の変数一覧
    if (var_count > 0) {
        vga.write("  Current variables:\n");
        for (&variables) |*v| {
            if (!v.used) continue;
            vga.write("    $");
            vga.write(v.name[0..v.name_len]);
            vga.write(" = ");
            vga.write(v.value[0..v.value_len]);
            vga.putChar('\n');
        }
    }
}
