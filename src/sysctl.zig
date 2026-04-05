// System Control (sysctl) — カーネルランタイムパラメータの管理
//
// Linux の /proc/sys に相当する機能。カーネルの動作パラメータを
// パス形式の名前 (例: "kernel.version") で参照・変更できる。
// 読み取り専用パラメータと読み書きパラメータをサポート。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");

// ---- 定数 ----

const MAX_PARAMS: usize = 32;
const MAX_NAME_LEN: usize = 32;
const MAX_STR_LEN: usize = 32;

// ---- パラメータタイプ ----

pub const ParamType = enum(u8) {
    integer,
    string,
    boolean,
};

// ---- 値の共用体 ----

pub const SysctlValue = union {
    int_val: i32,
    str_val: [MAX_STR_LEN]u8,
    bool_val: bool,
};

// ---- Sysctl エントリ ----

const SysctlEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    param_type: ParamType,
    value: SysctlValue,
    str_len: u8, // string の場合の実際の長さ
    min_val: i32, // integer の場合の最小値
    max_val: i32, // integer の場合の最大値
    readonly: bool,
    active: bool,
    write_count: u32, // 書き込み回数
    read_count: u32, // 読み込み回数
};

fn initEntry() SysctlEntry {
    return .{
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .param_type = .integer,
        .value = .{ .int_val = 0 },
        .str_len = 0,
        .min_val = 0,
        .max_val = 0x7FFFFFFF,
        .readonly = false,
        .active = false,
        .write_count = 0,
        .read_count = 0,
    };
}

// ---- グローバル状態 ----

var params: [MAX_PARAMS]SysctlEntry = initAllParams();
var param_count: usize = 0;
var initialized: bool = false;

fn initAllParams() [MAX_PARAMS]SysctlEntry {
    var entries: [MAX_PARAMS]SysctlEntry = undefined;
    for (&entries) |*e| {
        e.* = initEntry();
    }
    return entries;
}

// ---- ヘルパー ----

fn copyNameBuf(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

fn copyStrBuf(dst: *[MAX_STR_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_STR_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

fn nameMatch(entry_name: []const u8, search: []const u8) bool {
    if (entry_name.len != search.len) return false;
    for (entry_name, search) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn findEntry(name: []const u8) ?*SysctlEntry {
    for (&params) |*e| {
        if (e.active and nameMatch(e.name[0..e.name_len], name)) {
            return e;
        }
    }
    return null;
}

fn findFreeSlot() ?*SysctlEntry {
    for (&params) |*e| {
        if (!e.active) return e;
    }
    return null;
}

// ---- 登録ヘルパー ----

fn registerInt(name: []const u8, value: i32, min_val: i32, max_val: i32, readonly: bool) bool {
    const entry = findFreeSlot() orelse return false;
    entry.* = initEntry();
    entry.name_len = copyNameBuf(&entry.name, name);
    entry.param_type = .integer;
    entry.value = .{ .int_val = value };
    entry.min_val = min_val;
    entry.max_val = max_val;
    entry.readonly = readonly;
    entry.active = true;
    param_count += 1;
    return true;
}

fn registerStr(name: []const u8, value: []const u8, readonly: bool) bool {
    const entry = findFreeSlot() orelse return false;
    entry.* = initEntry();
    entry.name_len = copyNameBuf(&entry.name, name);
    entry.param_type = .string;
    entry.str_len = copyStrBuf(&entry.value.str_val, value);
    entry.readonly = readonly;
    entry.active = true;
    param_count += 1;
    return true;
}

fn registerBool(name: []const u8, value: bool, readonly: bool) bool {
    const entry = findFreeSlot() orelse return false;
    entry.* = initEntry();
    entry.name_len = copyNameBuf(&entry.name, name);
    entry.param_type = .boolean;
    entry.value = .{ .bool_val = value };
    entry.readonly = readonly;
    entry.active = true;
    param_count += 1;
    return true;
}

// ---- 初期化 ----

/// デフォルトパラメータを登録
pub fn init() void {
    if (initialized) return;

    // kernel.*
    _ = registerStr("kernel.version", "1.0.0", true);
    _ = registerStr("kernel.hostname", "zigkernel", false);
    _ = registerStr("kernel.ostype", "ZigOS", true);
    _ = registerInt("kernel.pid_max", 256, 16, 32768, false);
    _ = registerInt("kernel.hz", 1000, 100, 10000, true);
    _ = registerBool("kernel.sysrq", true, false);

    // vm.*
    _ = registerInt("vm.total_pages", @intCast(pmm.totalCount()), 0, 0x7FFFFFFF, true);
    _ = registerInt("vm.free_pages", @intCast(pmm.freeCount()), 0, 0x7FFFFFFF, true);
    _ = registerInt("vm.heap_size", 65536, 0, 0x7FFFFFFF, true);
    _ = registerInt("vm.overcommit", 0, 0, 2, false);
    _ = registerInt("vm.swappiness", 60, 0, 100, false);

    // net.ipv4.*
    _ = registerBool("net.ipv4.ip_forward", false, false);
    _ = registerInt("net.ipv4.ttl_default", 64, 1, 255, false);
    _ = registerInt("net.ipv4.tcp_max_syn", 128, 1, 65535, false);

    // fs.*
    _ = registerInt("fs.file_max", 256, 16, 65535, false);
    _ = registerInt("fs.inode_max", 1024, 64, 65535, false);

    // debug.*
    _ = registerInt("debug.log_level", 3, 0, 7, false);
    _ = registerBool("debug.trace_enabled", false, false);
    _ = registerBool("debug.serial_enabled", true, false);

    initialized = true;
    serial.write("[sysctl] initialized with ");
    serial.writeHex(param_count);
    serial.write(" parameters\n");
}

// ---- 公開 API ----

/// パラメータの値を取得
pub fn get(name: []const u8) ?SysctlValue {
    const entry = findEntry(name) orelse return null;
    entry.read_count += 1;
    return entry.value;
}

/// パラメータの値を整数で取得
pub fn getInt(name: []const u8) ?i32 {
    const entry = findEntry(name) orelse return null;
    if (entry.param_type != .integer) return null;
    entry.read_count += 1;
    return entry.value.int_val;
}

/// パラメータの値を文字列で取得
pub fn getStr(name: []const u8) ?[]const u8 {
    const entry = findEntry(name) orelse return null;
    if (entry.param_type != .string) return null;
    entry.read_count += 1;
    return entry.value.str_val[0..entry.str_len];
}

/// パラメータの値をブール値で取得
pub fn getBool(name: []const u8) ?bool {
    const entry = findEntry(name) orelse return null;
    if (entry.param_type != .boolean) return null;
    entry.read_count += 1;
    return entry.value.bool_val;
}

/// パラメータの値を設定 (整数)
pub fn set(name: []const u8, value: i32) bool {
    const entry = findEntry(name) orelse return false;
    if (entry.readonly) {
        serial.write("[sysctl] ");
        serial.write(name);
        serial.write(" is read-only\n");
        return false;
    }
    if (entry.param_type != .integer) return false;

    // 範囲チェック
    if (value < entry.min_val or value > entry.max_val) {
        serial.write("[sysctl] value out of range for ");
        serial.write(name);
        serial.write("\n");
        return false;
    }

    entry.value = .{ .int_val = value };
    entry.write_count += 1;
    return true;
}

/// パラメータの値を設定 (文字列)
pub fn setStr(name: []const u8, value: []const u8) bool {
    const entry = findEntry(name) orelse return false;
    if (entry.readonly) return false;
    if (entry.param_type != .string) return false;

    entry.str_len = copyStrBuf(&entry.value.str_val, value);
    entry.write_count += 1;
    return true;
}

/// パラメータの値を設定 (ブール値)
pub fn setBool(name: []const u8, value: bool) bool {
    const entry = findEntry(name) orelse return false;
    if (entry.readonly) return false;
    if (entry.param_type != .boolean) return false;

    entry.value = .{ .bool_val = value };
    entry.write_count += 1;
    return true;
}

/// パラメータが存在するか
pub fn exists(name: []const u8) bool {
    return findEntry(name) != null;
}

/// パラメータが読み取り専用か
pub fn isReadonly(name: []const u8) bool {
    const entry = findEntry(name) orelse return false;
    return entry.readonly;
}

/// パラメータのタイプを取得
pub fn getType(name: []const u8) ?ParamType {
    const entry = findEntry(name) orelse return null;
    return entry.param_type;
}

/// パラメータ数を返す
pub fn count() usize {
    return param_count;
}

// ---- 表示 ----

/// 全パラメータを表示
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Sysctl Parameters ===\n");
    vga.setColor(.light_grey, .black);

    for (&params) |*e| {
        if (!e.active) continue;

        // 名前
        vga.write("  ");
        vga.write(e.name[0..e.name_len]);

        // パディング (名前を30文字幅に揃える)
        if (e.name_len < 28) {
            var pad: usize = 28 - @as(usize, e.name_len);
            while (pad > 0) : (pad -= 1) vga.putChar(' ');
        }

        vga.write(" = ");

        // 値
        switch (e.param_type) {
            .integer => {
                if (e.value.int_val < 0) {
                    vga.putChar('-');
                    fmt.printDec(@intCast(-e.value.int_val));
                } else {
                    fmt.printDec(@intCast(e.value.int_val));
                }
            },
            .string => {
                vga.write("\"");
                vga.write(e.value.str_val[0..e.str_len]);
                vga.write("\"");
            },
            .boolean => {
                if (e.value.bool_val) {
                    vga.write("true");
                } else {
                    vga.write("false");
                }
            },
        }

        // 属性
        if (e.readonly) {
            vga.setColor(.dark_grey, .black);
            vga.write(" (ro)");
            vga.setColor(.light_grey, .black);
        }

        vga.putChar('\n');
    }

    vga.write("\n  Total parameters: ");
    fmt.printDec(param_count);
    vga.putChar('\n');
}

/// 特定のプレフィックスに一致するパラメータを表示
pub fn printPrefix(prefix: []const u8) void {
    vga.setColor(.yellow, .black);
    vga.write("=== Sysctl: ");
    vga.write(prefix);
    vga.write("* ===\n");
    vga.setColor(.light_grey, .black);

    var found: usize = 0;
    for (&params) |*e| {
        if (!e.active) continue;
        if (e.name_len < prefix.len) continue;

        // プレフィックスマッチ
        var match = true;
        for (prefix, 0..) |c, i| {
            if (e.name[i] != c) {
                match = false;
                break;
            }
        }
        if (!match) continue;

        vga.write("  ");
        vga.write(e.name[0..e.name_len]);
        vga.write(" = ");

        switch (e.param_type) {
            .integer => {
                if (e.value.int_val < 0) {
                    vga.putChar('-');
                    fmt.printDec(@intCast(-e.value.int_val));
                } else {
                    fmt.printDec(@intCast(e.value.int_val));
                }
            },
            .string => {
                vga.write("\"");
                vga.write(e.value.str_val[0..e.str_len]);
                vga.write("\"");
            },
            .boolean => {
                if (e.value.bool_val) vga.write("true") else vga.write("false");
            },
        }

        if (e.readonly) {
            vga.setColor(.dark_grey, .black);
            vga.write(" (ro)");
            vga.setColor(.light_grey, .black);
        }
        vga.putChar('\n');
        found += 1;
    }

    if (found == 0) {
        vga.write("  No matching parameters.\n");
    }
}

/// vm.free_pages を更新 (PMM から最新値を取得)
pub fn refreshVmStats() void {
    const entry = findEntry("vm.free_pages") orelse return;
    entry.value = .{ .int_val = @intCast(pmm.freeCount()) };
}
