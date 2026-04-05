// 環境変数 — シェル用のキーバリューストア

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

const MAX_VARS = 16;
const MAX_KEY = 32;
const MAX_VAL = 64;

const EnvVar = struct {
    key: [MAX_KEY]u8,
    key_len: u8,
    val: [MAX_VAL]u8,
    val_len: u8,
    used: bool,
};

var vars: [MAX_VARS]EnvVar = undefined;

pub fn init() void {
    for (&vars) |*v| {
        v.used = false;
    }
    // デフォルト環境変数
    _ = set("USER", "root");
    _ = set("HOME", "/");
    _ = set("SHELL", "/bin/sh");
    _ = set("PATH", "/bin:/usr/bin");
    _ = set("TERM", "vt100");
    _ = set("HOSTNAME", "zig-os");
    _ = set("OS", "ZigKernel");
    _ = set("VERSION", "1.0");
}

pub fn get(key: []const u8) ?[]const u8 {
    for (&vars) |*v| {
        if (v.used and v.key_len == key.len and fmt.eql(v.key[0..v.key_len], key)) {
            return v.val[0..v.val_len];
        }
    }
    return null;
}

pub fn set(key: []const u8, val: []const u8) bool {
    if (key.len == 0 or key.len > MAX_KEY or val.len > MAX_VAL) return false;

    // 既存キーの更新
    for (&vars) |*v| {
        if (v.used and v.key_len == key.len and fmt.eql(v.key[0..v.key_len], key)) {
            v.val_len = @intCast(val.len);
            @memcpy(v.val[0..val.len], val);
            return true;
        }
    }

    // 新規作成
    for (&vars) |*v| {
        if (!v.used) {
            v.used = true;
            v.key_len = @intCast(key.len);
            @memcpy(v.key[0..key.len], key);
            v.val_len = @intCast(val.len);
            @memcpy(v.val[0..val.len], val);
            return true;
        }
    }
    return false;
}

pub fn unset(key: []const u8) bool {
    for (&vars) |*v| {
        if (v.used and v.key_len == key.len and fmt.eql(v.key[0..v.key_len], key)) {
            v.used = false;
            return true;
        }
    }
    return false;
}

pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("Environment Variables:\n");
    vga.setColor(.light_grey, .black);
    for (&vars) |*v| {
        if (!v.used) continue;
        vga.setColor(.light_cyan, .black);
        vga.write(v.key[0..v.key_len]);
        vga.setColor(.light_grey, .black);
        vga.putChar('=');
        vga.write(v.val[0..v.val_len]);
        vga.putChar('\n');
    }
}

/// 文字列内の $VAR を展開
pub fn expand(input: []const u8, output: *[256]u8) usize {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < input.len and out_len < 256) {
        if (input[i] == '$' and i + 1 < input.len) {
            // 変数名を取得
            i += 1;
            const name_start = i;
            while (i < input.len and ((input[i] >= 'A' and input[i] <= 'Z') or
                (input[i] >= 'a' and input[i] <= 'z') or
                input[i] == '_')) : (i += 1)
            {}
            const name = input[name_start..i];
            if (get(name)) |val| {
                const copy_len = @min(val.len, 256 - out_len);
                @memcpy(output[out_len .. out_len + copy_len], val[0..copy_len]);
                out_len += copy_len;
            }
        } else {
            output[out_len] = input[i];
            out_len += 1;
            i += 1;
        }
    }
    return out_len;
}
