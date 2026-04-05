// デバイスファイルシステム (/dev) — Unix 風デバイスノード
//
// /dev/null, /dev/zero, /dev/random, /dev/console, /dev/serial, /dev/mem
// をデバイスノードとして登録し、統一的な read/write インターフェースを提供する。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- 定数 ----

const MAX_DEVICES = 16;
const MAX_NAME_LEN = 16;

// ---- デバイス種別 ----

pub const DeviceType = enum(u8) {
    char_device,
    block_device,
};

// ---- Read/Write 関数ポインタ型 ----

pub const ReadFn = *const fn (buf: []u8) usize;
pub const WriteFn = *const fn (data: []const u8) usize;

// ---- DeviceNode 構造体 ----

pub const DeviceNode = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    dev_type: DeviceType,
    major: u8,
    minor: u8,
    read_fn: ?ReadFn,
    write_fn: ?WriteFn,
    active: bool,

    pub fn getName(self: *const DeviceNode) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ---- グローバル状態 ----

var devices: [MAX_DEVICES]DeviceNode = undefined;
var device_count: usize = 0;

// ---- LFSR 擬似乱数ジェネレータ (dev/random 用) ----

var lfsr_state: u32 = 0xACE1;

fn lfsrNext() u8 {
    // 32-bit Galois LFSR (taps: 32, 22, 2, 1)
    var state = lfsr_state;
    // シードにエントロピーを混ぜる (PIT ticks)
    state ^= @truncate(pit.getTicks());

    const bit: u32 = ((state >> 0) ^ (state >> 1) ^ (state >> 21) ^ (state >> 31)) & 1;
    state = (state >> 1) | (bit << 31);
    if (state == 0) state = 0xDEAD; // ゼロ状態回避
    lfsr_state = state;
    return @truncate(state & 0xFF);
}

// ---- キーボードバッファ (dev/console read 用) ----
// シンプルなリングバッファ。keyboard.zig から pushKey() で追加される想定。

const KBD_BUF_SIZE = 64;
var kbd_buf: [KBD_BUF_SIZE]u8 = undefined;
var kbd_head: usize = 0;
var kbd_tail: usize = 0;

/// 外部からキーボードバッファに1バイト追加
pub fn pushKey(ch: u8) void {
    const next = (kbd_head + 1) % KBD_BUF_SIZE;
    if (next == kbd_tail) return; // バッファフル
    kbd_buf[kbd_head] = ch;
    kbd_head = next;
}

fn popKey() ?u8 {
    if (kbd_tail == kbd_head) return null;
    const ch = kbd_buf[kbd_tail];
    kbd_tail = (kbd_tail + 1) % KBD_BUF_SIZE;
    return ch;
}

// ---- デバイス実装: /dev/null ----

fn nullRead(_: []u8) usize {
    return 0; // 常に EOF
}

fn nullWrite(data: []const u8) usize {
    return data.len; // 全て破棄
}

// ---- デバイス実装: /dev/zero ----

fn zeroRead(buf: []u8) usize {
    for (buf) |*b| {
        b.* = 0;
    }
    return buf.len;
}

fn zeroWrite(data: []const u8) usize {
    return data.len; // 破棄
}

// ---- デバイス実装: /dev/random ----

fn randomRead(buf: []u8) usize {
    for (buf) |*b| {
        b.* = lfsrNext();
    }
    return buf.len;
}

fn randomWrite(data: []const u8) usize {
    // エントロピープールに混ぜる (XOR)
    for (data) |b| {
        lfsr_state ^= @as(u32, b);
        _ = lfsrNext(); // 攪拌
    }
    return data.len;
}

// ---- デバイス実装: /dev/console ----

fn consoleRead(buf: []u8) usize {
    var count: usize = 0;
    for (buf) |*b| {
        if (popKey()) |ch| {
            b.* = ch;
            count += 1;
        } else break;
    }
    return count;
}

fn consoleWrite(data: []const u8) usize {
    vga.write(data);
    return data.len;
}

// ---- デバイス実装: /dev/serial ----

fn serialRead(_: []u8) usize {
    // シリアル入力は未実装 (COM1 受信は IRQ 経由が必要)
    return 0;
}

fn serialWrite(data: []const u8) usize {
    serial.write(data);
    return data.len;
}

// ---- デバイス実装: /dev/mem ----
// 物理メモリの直接読み書き (先頭 4KB のみ安全にアクセス可能)

const MEM_WINDOW = 4096;

fn memRead(buf: []u8) usize {
    const len = if (buf.len > MEM_WINDOW) MEM_WINDOW else buf.len;
    const mem: [*]const u8 = @ptrFromInt(0);
    for (0..len) |i| {
        buf[i] = mem[i];
    }
    return len;
}

fn memWrite(data: []const u8) usize {
    const len = if (data.len > MEM_WINDOW) MEM_WINDOW else data.len;
    const mem: [*]u8 = @ptrFromInt(0);
    for (0..len) |i| {
        mem[i] = data[i];
    }
    return len;
}

// ---- デバイス登録 ----

fn registerDevice(
    name: []const u8,
    dev_type: DeviceType,
    major: u8,
    minor: u8,
    read_fn: ?ReadFn,
    write_fn: ?WriteFn,
) ?*DeviceNode {
    if (device_count >= MAX_DEVICES) return null;
    if (name.len == 0 or name.len > MAX_NAME_LEN) return null;

    var dev = &devices[device_count];
    dev.active = true;
    dev.dev_type = dev_type;
    dev.major = major;
    dev.minor = minor;
    dev.read_fn = read_fn;
    dev.write_fn = write_fn;

    const copy_len = if (name.len > MAX_NAME_LEN) MAX_NAME_LEN else name.len;
    for (0..copy_len) |i| {
        dev.name[i] = name[i];
    }
    dev.name_len = copy_len;

    device_count += 1;
    return dev;
}

// ---- 公開 API ----

/// devfs を初期化し、デフォルトデバイスを登録
pub fn init() void {
    for (&devices) |*d| {
        d.active = false;
        d.name_len = 0;
    }
    device_count = 0;
    kbd_head = 0;
    kbd_tail = 0;
    lfsr_state = 0xACE1;

    // デフォルトデバイスを登録
    // major: 1 = メモリ系, 4 = tty/console, 5 = serial
    _ = registerDevice("null", .char_device, 1, 3, &nullRead, &nullWrite);
    _ = registerDevice("zero", .char_device, 1, 5, &zeroRead, &zeroWrite);
    _ = registerDevice("random", .char_device, 1, 8, &randomRead, &randomWrite);
    _ = registerDevice("console", .char_device, 4, 0, &consoleRead, &consoleWrite);
    _ = registerDevice("serial", .char_device, 5, 0, &serialRead, &serialWrite);
    _ = registerDevice("mem", .char_device, 1, 1, &memRead, &memWrite);

    serial.write("[DEVFS] initialized: ");
    serialPrintDec(device_count);
    serial.write(" devices\n");
}

/// 名前でデバイスノードを開く
pub fn open(name: []const u8) ?*DeviceNode {
    for (devices[0..device_count]) |*d| {
        if (!d.active) continue;
        if (d.name_len == name.len and strEql(d.name[0..d.name_len], name)) {
            return d;
        }
    }
    return null;
}

/// デバイスからデータを読む
pub fn read(dev: *DeviceNode, buf: []u8) usize {
    if (!dev.active) return 0;
    if (dev.read_fn) |rfn| {
        return rfn(buf);
    }
    return 0;
}

/// デバイスにデータを書く
pub fn write(dev: *DeviceNode, data: []const u8) usize {
    if (!dev.active) return 0;
    if (dev.write_fn) |wfn| {
        return wfn(data);
    }
    return 0;
}

/// major/minor 番号でデバイスを検索
pub fn findByNumber(major: u8, minor: u8) ?*DeviceNode {
    for (devices[0..device_count]) |*d| {
        if (d.active and d.major == major and d.minor == minor) {
            return d;
        }
    }
    return null;
}

/// デバイスを新規登録 (外部からの追加用)
pub fn addDevice(
    name: []const u8,
    dev_type: DeviceType,
    major: u8,
    minor: u8,
    read_fn: ?ReadFn,
    write_fn: ?WriteFn,
) ?*DeviceNode {
    return registerDevice(name, dev_type, major, minor, read_fn, write_fn);
}

/// 登録済み全デバイスを表示
pub fn printDevices() void {
    vga.setColor(.yellow, .black);
    vga.write("Device Nodes (/dev):\n");
    vga.setColor(.light_cyan, .black);
    vga.write("TYPE   MAJOR  MINOR  NAME\n");
    vga.setColor(.light_grey, .black);

    for (devices[0..device_count]) |*d| {
        if (!d.active) continue;

        // タイプ
        switch (d.dev_type) {
            .char_device => vga.write("char   "),
            .block_device => vga.write("block  "),
        }

        // major
        printDecPadded(d.major, 5);
        vga.write("  ");

        // minor
        printDecPadded(d.minor, 5);
        vga.write("  ");

        // 名前
        vga.write(d.name[0..d.name_len]);
        vga.putChar('\n');
    }

    vga.setColor(.light_green, .black);
    printDec(device_count);
    vga.write(" device(s) registered\n");
    vga.setColor(.light_grey, .black);
}

/// デバイス数を取得
pub fn deviceCount() usize {
    return device_count;
}

// ---- ユーティリティ ----

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
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

fn printDecPadded(n_val: usize, width: usize) void {
    var digits: usize = 0;
    var tmp = n_val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec(n_val);
}

fn serialPrintDec(n: usize) void {
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
