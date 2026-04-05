// フォーマットユーティリティ — VGA/シリアル向け数値・文字列整形

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- 10進数 ----

pub fn printDec(n: usize) void {
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

pub fn printDecSigned(n: i32) void {
    if (n < 0) {
        vga.putChar('-');
        printDec(@intCast(-n));
    } else {
        printDec(@intCast(n));
    }
}

pub fn printDecPadded(n: usize, width: usize) void {
    // 数値の桁数を数える
    var digits: usize = 0;
    var tmp = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    // パディング
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec(n);
}

// ---- 16進数 ----

pub fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
}

pub fn printHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 12]);
    vga.putChar(hex[(val >> 8) & 0xF]);
    vga.putChar(hex[(val >> 4) & 0xF]);
    vga.putChar(hex[val & 0xF]);
}

pub fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

// ---- バイトサイズ ----

pub fn printSize(bytes: usize) void {
    if (bytes >= 1024 * 1024) {
        printDec(bytes / (1024 * 1024));
        vga.write(" MB");
    } else if (bytes >= 1024) {
        printDec(bytes / 1024);
        vga.write(" KB");
    } else {
        printDec(bytes);
        vga.write(" B");
    }
}

// ---- 文字列ユーティリティ ----

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') : (end -= 1) {}
    return s[start..end];
}

pub fn indexOf(s: []const u8, char: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == char) return i;
    }
    return null;
}

// ---- 数値パーサー ----

pub fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const new = @mulWithOverflow(val, 10);
        if (new[1] != 0) return null;
        const add = @addWithOverflow(new[0], c - '0');
        if (add[1] != 0) return null;
        val = add[0];
    }
    return val;
}

// ---- hexdump ----

pub fn hexdump(data: []const u8, base_addr: usize) void {
    var offset: usize = 0;
    while (offset < data.len) {
        // アドレス
        printHex32(@truncate(base_addr + offset));
        vga.write("  ");

        // 16バイト分の hex
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (offset + i < data.len) {
                printHex8(data[offset + i]);
                vga.putChar(' ');
            } else {
                vga.write("   ");
            }
            if (i == 7) vga.putChar(' ');
        }
        vga.write(" |");

        // ASCII 表示
        i = 0;
        while (i < 16 and offset + i < data.len) : (i += 1) {
            const c = data[offset + i];
            if (c >= 0x20 and c < 0x7F) {
                vga.putChar(c);
            } else {
                vga.putChar('.');
            }
        }
        vga.write("|\n");

        offset += 16;
    }
}

// ---- IP アドレス表示 ----

pub fn printIp(ip: u32) void {
    printDec((ip >> 24) & 0xFF);
    vga.putChar('.');
    printDec((ip >> 16) & 0xFF);
    vga.putChar('.');
    printDec((ip >> 8) & 0xFF);
    vga.putChar('.');
    printDec(ip & 0xFF);
}

pub fn printMac(mac: [6]u8) void {
    for (mac, 0..) |b, i| {
        if (i > 0) vga.putChar(':');
        printHex8(b);
    }
}

// ---- バー表示 ----

pub fn printBar(used: usize, total: usize, width: usize) void {
    if (total == 0) return;
    const filled = (used * width) / total;
    vga.putChar('[');
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            vga.putChar('#');
        } else {
            vga.putChar('-');
        }
    }
    vga.putChar(']');
}
