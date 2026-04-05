// 初期化スクリプト実行エンジン — ブートスクリプトの解析と実行

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");
const env = @import("env.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

// ---- ブートログ ----

const MAX_LOG_ENTRIES = 32;
const MAX_LOG_MSG = 64;

const LogEntry = struct {
    msg: [MAX_LOG_MSG]u8,
    msg_len: u8,
    tick: u64,
    level: LogLevel,
    used: bool,
};

const LogLevel = enum(u8) {
    info,
    warn,
    err,
    ok,
};

var boot_log: [MAX_LOG_ENTRIES]LogEntry = undefined;
var log_count: usize = 0;
var script_running: bool = false;

// ---- 初期化 ----

pub fn init() void {
    for (&boot_log) |*entry| {
        entry.used = false;
        entry.msg_len = 0;
        entry.tick = 0;
    }
    log_count = 0;
    script_running = false;
}

// ---- ログ記録 ----

fn logMessage(msg: []const u8, level: LogLevel) void {
    if (log_count >= MAX_LOG_ENTRIES) return;
    var entry = &boot_log[log_count];
    entry.msg_len = @intCast(@min(msg.len, MAX_LOG_MSG));
    @memcpy(entry.msg[0..entry.msg_len], msg[0..entry.msg_len]);
    entry.tick = pit.getTicks();
    entry.level = level;
    entry.used = true;
    log_count += 1;
}

fn logInfo(msg: []const u8) void {
    logMessage(msg, .info);
}

fn logOk(msg: []const u8) void {
    logMessage(msg, .ok);
}

fn logWarn(msg: []const u8) void {
    logMessage(msg, .warn);
}

fn logErr(msg: []const u8) void {
    logMessage(msg, .err);
}

// ---- デフォルトスクリプト作成 ----

pub fn createDefaultScript() void {
    const script =
        "# ZigOS Init Script\n" ++
        "# Executed during boot\n" ++
        "\n" ++
        "echo Booting ZigOS...\n" ++
        "set HOSTNAME zig-os\n" ++
        "set TERM vt100\n" ++
        "set EDITOR ed\n" ++
        "echo System initialized.\n" ++
        "echo Welcome to ZigOS!\n";

    const idx = ramfs.create("init.sh") orelse {
        // 既存ファイルに書き込み
        if (ramfs.findByName("init.sh")) |existing| {
            _ = ramfs.writeFile(existing, script);
            logOk("Default init.sh updated");
            return;
        }
        logErr("Failed to create init.sh");
        return;
    };
    _ = ramfs.writeFile(idx, script);
    logOk("Default init.sh created");
}

// ---- ブートスクリプト実行 ----

pub fn runBootScript() void {
    logInfo("Boot script execution started");
    script_running = true;

    // init.sh を ramfs から読み込み
    const file_idx = ramfs.findByName("init.sh") orelse {
        logWarn("init.sh not found, creating default");
        createDefaultScript();
        // 再度読み込み
        const new_idx = ramfs.findByName("init.sh") orelse {
            logErr("Failed to load init.sh");
            script_running = false;
            return;
        };
        executeScript(new_idx);
        script_running = false;
        return;
    };

    executeScript(file_idx);
    script_running = false;
    logOk("Boot script execution completed");
}

fn executeScript(file_idx: usize) void {
    var buf: [2048]u8 = undefined;
    const len = ramfs.readFile(file_idx, &buf);
    if (len == 0) {
        logWarn("init.sh is empty");
        return;
    }

    const script = buf[0..len];

    // 行ごとに実行
    var line_start: usize = 0;
    var line_num: usize = 0;

    for (script, 0..) |c, i| {
        if (c == '\n' or i == script.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = trimLine(script[line_start..line_end]);
            line_num += 1;

            if (line.len > 0) {
                executeLine(line, line_num);
            }
            line_start = i + 1;
        }
    }
}

fn executeLine(line: []const u8, line_num: usize) void {
    // コメント行をスキップ
    if (line[0] == '#') return;

    // 空行をスキップ
    if (line.len == 0) return;

    // コマンドを解析
    const cmd = getCommand(line);
    const args = getArgs(line);

    if (eql(cmd, "echo")) {
        cmdEcho(args);
    } else if (eql(cmd, "set")) {
        cmdSet(args);
    } else if (eql(cmd, "sleep")) {
        cmdSleep(args);
    } else if (eql(cmd, "mount")) {
        cmdMount(args);
    } else if (eql(cmd, "run")) {
        cmdRun(args);
    } else if (eql(cmd, "hostname")) {
        cmdHostname(args);
    } else if (eql(cmd, "export")) {
        cmdSet(args); // export は set と同じ
    } else if (eql(cmd, "mkdir")) {
        cmdMkdir(args);
    } else if (eql(cmd, "touch")) {
        cmdTouch(args);
    } else {
        // 不明なコマンド
        _ = line_num;
        logWarn("Unknown command in init.sh");
        serial.write("[INIT] Unknown: ");
        serial.write(cmd);
        serial.write("\n");
    }
}

// ---- コマンド実装 ----

fn cmdEcho(args: []const u8) void {
    // 環境変数の展開
    var expanded: [256]u8 = undefined;
    const expanded_len = env.expand(args, &expanded);
    const msg = expanded[0..expanded_len];

    vga.setColor(.light_grey, .black);
    vga.write(msg);
    vga.putChar('\n');
    logInfo(msg);
}

fn cmdSet(args: []const u8) void {
    // "KEY VALUE" 形式
    const sep = indexOf(args, ' ') orelse {
        logWarn("set: missing value");
        return;
    };
    const key = args[0..sep];
    const val = if (sep + 1 < args.len) args[sep + 1 ..] else "";

    if (env.set(key, val)) {
        logOk("set variable");
    } else {
        logErr("set: failed");
    }
}

fn cmdSleep(args: []const u8) void {
    // ミリ秒単位のスリープ (PIT ベース)
    const ms = parseU32(args) orelse {
        logWarn("sleep: invalid duration");
        return;
    };
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        // busy wait
        asm volatile ("hlt");
    }
    logInfo("sleep completed");
}

fn cmdMount(args: []const u8) void {
    // 簡易: ログに記録するだけ
    _ = args;
    logInfo("mount (simulated)");
}

fn cmdRun(args: []const u8) void {
    // 別のスクリプトを実行
    const file_idx = ramfs.findByName(args) orelse {
        logErr("run: file not found");
        return;
    };
    logInfo("run sub-script");
    executeScript(file_idx);
}

fn cmdHostname(args: []const u8) void {
    if (args.len > 0) {
        _ = env.set("HOSTNAME", args);
        logOk("hostname set");
    } else {
        // 表示
        if (env.get("HOSTNAME")) |h| {
            vga.write(h);
            vga.putChar('\n');
        }
    }
}

fn cmdMkdir(args: []const u8) void {
    if (args.len > 0) {
        if (ramfs.mkdir(args)) {
            logOk("mkdir done");
        } else {
            logWarn("mkdir: failed");
        }
    }
}

fn cmdTouch(args: []const u8) void {
    if (args.len > 0) {
        _ = ramfs.create(args);
        logInfo("touch done");
    }
}

// ---- ブートログ表示 ----

pub fn printBootLog() void {
    vga.setColor(.yellow, .black);
    vga.write("Boot Log:\n");
    vga.write("TICK       LEVEL  MESSAGE\n");
    vga.setColor(.light_grey, .black);

    for (boot_log[0..log_count]) |*entry| {
        if (!entry.used) continue;

        // Tick
        fmt.printDecPadded(truncU64(entry.tick), 10);
        vga.write("  ");

        // Level
        switch (entry.level) {
            .info => {
                vga.setColor(.light_cyan, .black);
                vga.write("INFO ");
            },
            .ok => {
                vga.setColor(.light_green, .black);
                vga.write("OK   ");
            },
            .warn => {
                vga.setColor(.yellow, .black);
                vga.write("WARN ");
            },
            .err => {
                vga.setColor(.light_red, .black);
                vga.write("ERR  ");
            },
        }

        vga.setColor(.light_grey, .black);
        vga.write("  ");
        vga.write(entry.msg[0..entry.msg_len]);
        vga.putChar('\n');
    }

    if (log_count == 0) {
        vga.write("  (no boot log entries)\n");
    } else {
        vga.setColor(.dark_grey, .black);
        fmt.printDec(log_count);
        vga.write(" entries\n");
        vga.setColor(.light_grey, .black);
    }
}

// ---- スクリプト編集 (エディタ起動) ----

pub fn editBootScript() void {
    // init.sh が存在しなければ作成
    if (ramfs.findByName("init.sh") == null) {
        createDefaultScript();
    }
    vga.write("Use 'edit init.sh' to edit the boot script.\n");
}

// ---- スクリプト表示 ----

pub fn printBootScript() void {
    const file_idx = ramfs.findByName("init.sh") orelse {
        vga.write("init.sh not found.\n");
        return;
    };

    var buf: [2048]u8 = undefined;
    const len = ramfs.readFile(file_idx, &buf);
    if (len == 0) {
        vga.write("init.sh is empty.\n");
        return;
    }

    vga.setColor(.yellow, .black);
    vga.write("=== init.sh ===\n");
    vga.setColor(.light_grey, .black);

    // 行番号付きで表示
    var line_num: usize = 1;
    var line_start: usize = 0;
    const script = buf[0..len];

    for (script, 0..) |c, i| {
        if (c == '\n' or i == script.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = script[line_start..line_end];

            vga.setColor(.dark_grey, .black);
            fmt.printDecPadded(line_num, 3);
            vga.write("  ");

            if (line.len > 0 and line[0] == '#') {
                vga.setColor(.dark_grey, .black);
            } else {
                vga.setColor(.light_grey, .black);
            }
            vga.write(line);
            vga.putChar('\n');

            line_num += 1;
            line_start = i + 1;
        }
    }
    vga.setColor(.light_grey, .black);
}

pub fn isRunning() bool {
    return script_running;
}

pub fn getLogCount() usize {
    return log_count;
}

// ---- ヘルパー ----

fn getCommand(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == ' ' or c == '\t') return line[0..i];
    }
    return line;
}

fn getArgs(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == ' ' or c == '\t') {
            var start = i + 1;
            while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
            return line[start..];
        }
    }
    return line[line.len..];
}

fn trimLine(line: []const u8) []const u8 {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    var end = line.len;
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) end -= 1;
    return line[start..end];
}

fn indexOf(s: []const u8, char: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == char) return i;
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

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn truncU64(val: u64) usize {
    return @truncate(val);
}
