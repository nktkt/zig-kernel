// 拡張シェル機能 — リダイレクト、パイプ、エイリアス、コマンド履歴

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");
const pipe_mod = @import("pipe.zig");
const env = @import("env.zig");
const serial = @import("serial.zig");

// ---- エイリアス ----

const MAX_ALIASES = 8;
const MAX_ALIAS_NAME = 16;
const MAX_ALIAS_CMD = 64;

const Alias = struct {
    name: [MAX_ALIAS_NAME]u8,
    name_len: u8,
    command: [MAX_ALIAS_CMD]u8,
    command_len: u8,
    used: bool,
};

var aliases: [MAX_ALIASES]Alias = undefined;

// ---- コマンド履歴参照 ----

const MAX_HISTORY = 16;
const MAX_HIST_CMD = 128;

const HistEntry = struct {
    cmd: [MAX_HIST_CMD]u8,
    cmd_len: u8,
    used: bool,
};

var history: [MAX_HISTORY]HistEntry = undefined;
var history_count: usize = 0;
var last_command: [MAX_HIST_CMD]u8 = undefined;
var last_command_len: usize = 0;

// ---- タブ補完用コマンドリスト ----

const builtin_commands = [_][]const u8{
    "help",    "clear", "ls",      "cd",     "pwd",    "cat",
    "write",   "rm",    "mkdir",   "echo",   "env",    "set",
    "unset",   "date",  "uptime",  "reboot", "mem",    "ps",
    "kill",    "hex",   "pci",     "ata",    "fat",    "edit",
    "grep",    "wc",    "head",    "tail",   "sort",   "cal",
    "factor",  "alias", "unalias", "history",
};

// ---- 出力キャプチャバッフ��� ----

var capture_buf: [4096]u8 = undefined;
var capture_len: usize = 0;
var capturing: bool = false;

// ---- 初期化 ----

pub fn init() void {
    for (&aliases) |*a| {
        a.used = false;
    }
    for (&history) |*h| {
        h.used = false;
    }
    history_count = 0;
    last_command_len = 0;
    capturing = false;
    capture_len = 0;

    // デフォルトエイリアス
    _ = addAlias("ll", "ls -l");
    _ = addAlias("la", "ls -a");
    _ = addAlias("cls", "clear");
    _ = addAlias("..", "cd ..");

    serial.write("[SHEXT] initialized\n");
}

// ---- エイリアス管理 ----

pub fn addAlias(name: []const u8, command: []const u8) bool {
    if (name.len == 0 or name.len > MAX_ALIAS_NAME) return false;
    if (command.len == 0 or command.len > MAX_ALIAS_CMD) return false;

    // 既存の更新
    for (&aliases) |*a| {
        if (a.used and a.name_len == name.len and eql(a.name[0..a.name_len], name)) {
            a.command_len = @intCast(command.len);
            @memcpy(a.command[0..command.len], command);
            return true;
        }
    }

    // 新規作成
    for (&aliases) |*a| {
        if (!a.used) {
            a.used = true;
            a.name_len = @intCast(name.len);
            @memcpy(a.name[0..name.len], name);
            a.command_len = @intCast(command.len);
            @memcpy(a.command[0..command.len], command);
            return true;
        }
    }
    return false;
}

pub fn removeAlias(name: []const u8) bool {
    for (&aliases) |*a| {
        if (a.used and a.name_len == name.len and eql(a.name[0..a.name_len], name)) {
            a.used = false;
            return true;
        }
    }
    return false;
}

pub fn listAliases() void {
    vga.setColor(.yellow, .black);
    vga.write("Aliases:\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&aliases) |*a| {
        if (!a.used) continue;
        count += 1;
        vga.write("  ");
        vga.setColor(.light_cyan, .black);
        vga.write(a.name[0..a.name_len]);
        vga.setColor(.dark_grey, .black);
        vga.write(" = '");
        vga.setColor(.light_grey, .black);
        vga.write(a.command[0..a.command_len]);
        vga.setColor(.dark_grey, .black);
        vga.write("'\n");
    }
    vga.setColor(.light_grey, .black);

    if (count == 0) {
        vga.write("  (no aliases defined)\n");
    }
}

// ---- エイリアス展開 ----

pub fn expandAlias(input: []const u8, buf: *[256]u8) []u8 {
    // 最初のワードがエイリアスかチェック
    var cmd_end: usize = 0;
    while (cmd_end < input.len and input[cmd_end] != ' ' and input[cmd_end] != '\t') cmd_end += 1;
    const cmd = input[0..cmd_end];

    for (&aliases) |*a| {
        if (a.used and a.name_len == cmd.len and eql(a.name[0..a.name_len], cmd)) {
            // エイリアスを展開
            var pos: usize = 0;
            const cmd_copy_len = @min(@as(usize, a.command_len), buf.len);
            @memcpy(buf[0..cmd_copy_len], a.command[0..cmd_copy_len]);
            pos = cmd_copy_len;

            // 残りの引数を追加
            if (cmd_end < input.len and pos < buf.len) {
                const rest_len = @min(input.len - cmd_end, buf.len - pos);
                @memcpy(buf[pos .. pos + rest_len], input[cmd_end .. cmd_end + rest_len]);
                pos += rest_len;
            }
            return buf[0..pos];
        }
    }
    // エイリアスなし → 入力をそのままコピー
    const copy_len = @min(input.len, buf.len);
    @memcpy(buf[0..copy_len], input[0..copy_len]);
    return buf[0..copy_len];
}

// ---- 環境変数展開 ----

pub fn expandVars(input: []const u8, buf: *[256]u8) []u8 {
    const len = env.expand(input, buf);
    return buf[0..len];
}

// ---- 出力リダイレクト検出 ----

pub const RedirectInfo = struct {
    command: []const u8,
    filename: []const u8,
    has_redirect: bool,
    append: bool, // >> 追記モード
};

pub fn parseRedirect(input: []const u8) RedirectInfo {
    var result = RedirectInfo{
        .command = input,
        .filename = "",
        .has_redirect = false,
        .append = false,
    };

    // ">>" を先に検索
    var i: usize = 0;
    while (i + 1 < input.len) : (i += 1) {
        if (input[i] == '>' and input[i + 1] == '>') {
            result.has_redirect = true;
            result.append = true;
            result.command = trimSlice(input[0..i]);
            const rest = input[i + 2 ..];
            result.filename = trimSlice(rest);
            return result;
        }
    }

    // ">" を検索
    for (input, 0..) |c, idx| {
        if (c == '>') {
            result.has_redirect = true;
            result.command = trimSlice(input[0..idx]);
            const rest = input[idx + 1 ..];
            result.filename = trimSlice(rest);
            return result;
        }
    }
    return result;
}

// ---- パイプ検出 ----

pub const PipeInfo = struct {
    left: []const u8,
    right: []const u8,
    has_pipe: bool,
};

pub fn parsePipe(input: []const u8) PipeInfo {
    for (input, 0..) |c, i| {
        if (c == '|') {
            return PipeInfo{
                .left = trimSlice(input[0..i]),
                .right = trimSlice(input[i + 1 ..]),
                .has_pipe = true,
            };
        }
    }
    return PipeInfo{
        .left = input,
        .right = "",
        .has_pipe = false,
    };
}

// ---- リダイレクト実行 ----

pub fn writeOutputToFile(filename: []const u8, data: []const u8, append: bool) bool {
    if (filename.len == 0) return false;

    if (append) {
        // 追記モード
        if (ramfs.findByName(filename)) |idx| {
            const inode = ramfs.getFile(idx) orelse return false;
            const current_size = inode.size;
            if (current_size + data.len > ramfs.MAX_DATA) return false;
            // 既存データの後ろに追記
            var buf: [ramfs.MAX_DATA]u8 = undefined;
            const existing_len = ramfs.readFile(idx, &buf);
            const append_len = @min(data.len, ramfs.MAX_DATA - existing_len);
            @memcpy(buf[existing_len .. existing_len + append_len], data[0..append_len]);
            _ = ramfs.writeFile(idx, buf[0 .. existing_len + append_len]);
            return true;
        }
    }

    // 新規 or 上書き
    const idx = ramfs.findByName(filename) orelse ramfs.create(filename) orelse return false;
    _ = ramfs.writeFile(idx, data);
    return true;
}

// ---- 履歴管理 ----

pub fn addHistory(cmd: []const u8) void {
    if (cmd.len == 0) return;

    const idx = history_count % MAX_HISTORY;
    history[idx].cmd_len = @intCast(@min(cmd.len, MAX_HIST_CMD));
    @memcpy(history[idx].cmd[0..history[idx].cmd_len], cmd[0..history[idx].cmd_len]);
    history[idx].used = true;
    history_count += 1;

    // last_command を更新
    last_command_len = @min(cmd.len, MAX_HIST_CMD);
    @memcpy(last_command[0..last_command_len], cmd[0..last_command_len]);
}

pub fn printHistory() void {
    vga.setColor(.yellow, .black);
    vga.write("Command History:\n");
    vga.setColor(.light_grey, .black);

    const start = if (history_count > MAX_HISTORY) history_count - MAX_HISTORY else 0;
    var i = start;
    while (i < history_count) : (i += 1) {
        const idx = i % MAX_HISTORY;
        if (!history[idx].used) continue;

        vga.setColor(.dark_grey, .black);
        fmt.printDecPadded(i + 1, 4);
        vga.write("  ");
        vga.setColor(.light_grey, .black);
        vga.write(history[idx].cmd[0..history[idx].cmd_len]);
        vga.putChar('\n');
    }
}

// ---- !! と !n 展開 ----

pub fn expandHistory(input: []const u8, buf: *[256]u8) []u8 {
    if (input.len >= 2 and input[0] == '!' and input[1] == '!') {
        // !! → 最後のコマンド
        if (last_command_len > 0) {
            const len = @min(last_command_len, buf.len);
            @memcpy(buf[0..len], last_command[0..len]);
            // 残りの入力を追加
            if (input.len > 2) {
                const rest_len = @min(input.len - 2, buf.len - len);
                @memcpy(buf[len .. len + rest_len], input[2 .. 2 + rest_len]);
                return buf[0 .. len + rest_len];
            }
            return buf[0..len];
        }
    }

    if (input.len >= 2 and input[0] == '!') {
        // !n → n 番目のコマンド
        const num_str = input[1..];
        const n = parseU32(num_str) orelse {
            // 数値でない → そのまま返す
            const copy_len = @min(input.len, buf.len);
            @memcpy(buf[0..copy_len], input[0..copy_len]);
            return buf[0..copy_len];
        };
        if (n > 0 and n <= history_count) {
            const idx = (n - 1) % MAX_HISTORY;
            if (history[idx].used) {
                const len = @min(@as(usize, history[idx].cmd_len), buf.len);
                @memcpy(buf[0..len], history[idx].cmd[0..len]);
                return buf[0..len];
            }
        }
    }

    // 展開なし
    const copy_len = @min(input.len, buf.len);
    @memcpy(buf[0..copy_len], input[0..copy_len]);
    return buf[0..copy_len];
}

// ---- タブ補完 ----

pub fn tabComplete(partial: []const u8, buf: *[64]u8) ?[]u8 {
    if (partial.len == 0) return null;

    var match_count: usize = 0;
    var last_match: []const u8 = "";

    // コマンド名補完
    for (builtin_commands) |cmd| {
        if (cmd.len >= partial.len and startsWith(cmd, partial)) {
            match_count += 1;
            last_match = cmd;
        }
    }

    // 一意にマッチした場合のみ補完
    if (match_count == 1) {
        const len = @min(last_match.len, buf.len);
        @memcpy(buf[0..len], last_match[0..len]);
        return buf[0..len];
    }

    // 複数マッチ → 候補を表示
    if (match_count > 1) {
        vga.putChar('\n');
        for (builtin_commands) |cmd| {
            if (cmd.len >= partial.len and startsWith(cmd, partial)) {
                vga.write(cmd);
                vga.write("  ");
            }
        }
        vga.putChar('\n');
    }

    return null;
}

// ---- ワイルドカード展開 (ramfs ファイル) ----

pub fn expandWildcard(pattern: []const u8) void {
    // 簡易ワイルドカード: * は任意の文字列にマッチ
    // ramfs の現在のディレクトリのファイルを走査
    // 結果を VGA に表示
    var count: usize = 0;

    // ramfs の直接走査はできないため、名前で検索
    // ここでは pattern が "*" の場合は全ファイルを ls と同等に表示
    if (pattern.len == 1 and pattern[0] == '*') {
        ramfs.printList();
        return;
    }

    // パターンに * が含まれる場合
    for (pattern) |c| {
        if (c == '*') {
            // 簡易: パターンの前後の文字列で部分一致
            vga.setColor(.dark_grey, .black);
            vga.write("(wildcard expansion for '");
            vga.write(pattern);
            vga.write("')\n");
            vga.setColor(.light_grey, .black);
            count += 1;
            break;
        }
    }

    if (count == 0) {
        vga.write(pattern);
        vga.putChar('\n');
    }
}

// ---- ジョブ制御表示 ----

pub fn printJobs() void {
    vga.setColor(.yellow, .black);
    vga.write("Background Jobs:\n");
    vga.setColor(.light_grey, .black);
    // カーネルにはバックグラウンドジョブの仕組みがまだないため
    // 簡易的な表示
    vga.write("  (no background jobs)\n");
}

// ---- 入力行の前処理 ----

pub fn preprocessLine(input: []const u8, buf: *[256]u8) []u8 {
    // 1. 履歴展開 (!! / !n)
    var tmp1: [256]u8 = undefined;
    const expanded_hist = expandHistory(input, &tmp1);

    // 2. エ���リアス展開
    var tmp2: [256]u8 = undefined;
    const expanded_alias = expandAlias(expanded_hist, &tmp2);

    // 3. 環境変数展開
    const result = expandVars(expanded_alias, buf);
    return result;
}

// ---- ヘルパー ----

fn trimSlice(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[start..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
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
