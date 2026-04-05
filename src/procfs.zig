// /proc ファイルシステム — 仮想ファイルによるカーネル情報提供
// 読み取り専用。各ファイルはアクセス時に動的生成される。

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const task = @import("task.zig");
const version = @import("version.zig");
const serial = @import("serial.zig");

// ---- 設定 ----

const MAX_PROC_FILES = 16;
const MAX_NAME = 16;

// カーネルコマンドライン (ブート時に設定可能)
var cmdline_buf: [128]u8 = [_]u8{0} ** 128;
var cmdline_len: usize = 0;

// デバイス登録テーブル
const MAX_DEVICES = 16;

const DeviceEntry = struct {
    name: [24]u8,
    name_len: u8,
    dev_type: [16]u8,
    type_len: u8,
    used: bool,
};

var devices: [MAX_DEVICES]DeviceEntry = undefined;
var device_count: usize = 0;

// コンテキストスイッチカウンタ
var context_switches: u64 = 0;

// ---- procfs ファイルエントリ ----

const ProcFile = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    generator: *const fn ([]u8) usize,
    used: bool,
};

var proc_files: [MAX_PROC_FILES]ProcFile = undefined;
var file_count: usize = 0;

// ---- 初期化 ----

pub fn init() void {
    for (&proc_files) |*f| f.used = false;
    for (&devices) |*d| d.used = false;
    device_count = 0;
    context_switches = 0;

    // デフォルトコマンドライン
    const default_cmd = "root=/dev/ram0 console=ttyS0";
    @memcpy(cmdline_buf[0..default_cmd.len], default_cmd);
    cmdline_len = default_cmd.len;

    // 仮想ファイル登録
    _ = registerFile("version", genVersion);
    _ = registerFile("uptime", genUptime);
    _ = registerFile("meminfo", genMeminfo);
    _ = registerFile("cpuinfo", genCpuinfo);
    _ = registerFile("cmdline", genCmdline);
    _ = registerFile("stat", genStat);
    _ = registerFile("mounts", genMounts);
    _ = registerFile("devices", genDevices);

    // デフォルトデバイス登録
    registerDevice("ram0", "block");
    registerDevice("ttyS0", "char");
    registerDevice("tty0", "char");
    registerDevice("vga0", "char");
    registerDevice("kbd0", "input");
}

fn registerFile(name: []const u8, gen: *const fn ([]u8) usize) bool {
    if (file_count >= MAX_PROC_FILES) return false;
    var entry = &proc_files[file_count];
    entry.used = true;
    entry.name_len = @intCast(@min(name.len, MAX_NAME));
    @memcpy(entry.name[0..entry.name_len], name[0..entry.name_len]);
    entry.generator = gen;
    file_count += 1;
    return true;
}

/// デバイスを登録する
pub fn registerDevice(name: []const u8, dev_type: []const u8) void {
    if (device_count >= MAX_DEVICES) return;
    var d = &devices[device_count];
    d.used = true;
    d.name_len = @intCast(@min(name.len, 24));
    @memcpy(d.name[0..d.name_len], name[0..d.name_len]);
    d.type_len = @intCast(@min(dev_type.len, 16));
    @memcpy(d.dev_type[0..d.type_len], dev_type[0..d.type_len]);
    device_count += 1;
}

/// コンテキストスイッチカウンタをインクリメント
pub fn incrementContextSwitches() void {
    context_switches += 1;
}

/// カーネルコマンドラインを設定
pub fn setCmdline(cmd: []const u8) void {
    const len = @min(cmd.len, cmdline_buf.len);
    @memcpy(cmdline_buf[0..len], cmd[0..len]);
    cmdline_len = len;
}

// ---- 公開 API ----

/// proc ファイルを読み取る。ファイル名が存在しない場合は null を返す。
pub fn readFile(name: []const u8, buf: []u8) ?usize {
    for (proc_files[0..file_count]) |*f| {
        if (f.used and f.name_len == name.len and eql(f.name[0..f.name_len], name)) {
            return f.generator(buf);
        }
    }
    return null;
}

/// 登録済み proc ファイル一覧を VGA に表示
pub fn listFiles() void {
    vga.setColor(.yellow, .black);
    vga.write("/proc files:\n");
    vga.setColor(.light_grey, .black);
    for (proc_files[0..file_count]) |*f| {
        if (!f.used) continue;
        vga.write("  ");
        vga.write(f.name[0..f.name_len]);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
    printNum(file_count);
    vga.write(" file(s)\n");
}

/// proc ファイルの内容を VGA に表示
pub fn printFile(name: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (readFile(name, &buf)) |len| {
        vga.write(buf[0..len]);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("procfs: file not found: ");
        vga.write(name);
        vga.putChar('\n');
    }
}

// ---- ジェネレータ関数 ----

fn genVersion(buf: []u8) usize {
    const name = version.getName();
    const ver = version.getVersionString();
    const target = version.getBuildTarget();
    const arch = version.getArch();

    var pos: usize = 0;
    pos = appendStr(buf, pos, name);
    pos = appendStr(buf, pos, " version ");
    pos = appendStr(buf, pos, ver);
    pos = appendStr(buf, pos, " (");
    pos = appendStr(buf, pos, target);
    pos = appendStr(buf, pos, ", ");
    pos = appendStr(buf, pos, arch);
    pos = appendStr(buf, pos, ")\n");
    pos = appendStr(buf, pos, "Compiler: Zig 0.15\n");
    return pos;
}

fn genUptime(buf: []u8) usize {
    const secs = pit.getUptimeSecs();
    var pos: usize = 0;
    pos = appendDec(buf, pos, secs);
    pos = appendStr(buf, pos, " seconds\n");

    // 読みやすい形式も追加
    const hours = secs / 3600;
    const mins = (secs % 3600) / 60;
    const s = secs % 60;
    pos = appendStr(buf, pos, "up ");
    pos = appendDec(buf, pos, hours);
    pos = appendStr(buf, pos, "h ");
    pos = appendDec(buf, pos, mins);
    pos = appendStr(buf, pos, "m ");
    pos = appendDec(buf, pos, s);
    pos = appendStr(buf, pos, "s\n");
    return pos;
}

fn genMeminfo(buf: []u8) usize {
    const total = pmm.totalCount() * 4; // KB
    const free_pages = pmm.freeCount() * 4; // KB
    const used = total - free_pages;

    var pos: usize = 0;
    pos = appendStr(buf, pos, "MemTotal:    ");
    pos = appendDecPadded(buf, pos, total, 8);
    pos = appendStr(buf, pos, " KB\n");
    pos = appendStr(buf, pos, "MemFree:     ");
    pos = appendDecPadded(buf, pos, free_pages, 8);
    pos = appendStr(buf, pos, " KB\n");
    pos = appendStr(buf, pos, "MemUsed:     ");
    pos = appendDecPadded(buf, pos, used, 8);
    pos = appendStr(buf, pos, " KB\n");

    // ページ単位
    pos = appendStr(buf, pos, "Pages total: ");
    pos = appendDecPadded(buf, pos, pmm.totalCount(), 8);
    pos = appendStr(buf, pos, "\n");
    pos = appendStr(buf, pos, "Pages free:  ");
    pos = appendDecPadded(buf, pos, pmm.freeCount(), 8);
    pos = appendStr(buf, pos, "\n");
    return pos;
}

fn genCpuinfo(buf: []u8) usize {
    var pos: usize = 0;

    // CPUID 命令で CPU ベンダー文字列を取得
    var vendor: [12]u8 = undefined;
    getCpuVendor(&vendor);

    pos = appendStr(buf, pos, "vendor_id   : ");
    pos = appendStr(buf, pos, &vendor);
    pos = appendStr(buf, pos, "\n");

    // モデル情報
    pos = appendStr(buf, pos, "cpu family  : x86\n");
    pos = appendStr(buf, pos, "arch        : i686\n");

    // CPUID 機能フラグ (EAX=1, EDX)
    var features_edx: u32 = 0;
    var features_ecx: u32 = 0;
    getCpuFeatures(&features_edx, &features_ecx);

    pos = appendStr(buf, pos, "flags       :");
    if (features_edx & (1 << 0) != 0) pos = appendStr(buf, pos, " fpu");
    if (features_edx & (1 << 4) != 0) pos = appendStr(buf, pos, " tsc");
    if (features_edx & (1 << 5) != 0) pos = appendStr(buf, pos, " msr");
    if (features_edx & (1 << 6) != 0) pos = appendStr(buf, pos, " pae");
    if (features_edx & (1 << 8) != 0) pos = appendStr(buf, pos, " cx8");
    if (features_edx & (1 << 9) != 0) pos = appendStr(buf, pos, " apic");
    if (features_edx & (1 << 15) != 0) pos = appendStr(buf, pos, " cmov");
    if (features_edx & (1 << 23) != 0) pos = appendStr(buf, pos, " mmx");
    if (features_edx & (1 << 25) != 0) pos = appendStr(buf, pos, " sse");
    if (features_edx & (1 << 26) != 0) pos = appendStr(buf, pos, " sse2");
    if (features_ecx & (1 << 0) != 0) pos = appendStr(buf, pos, " sse3");
    pos = appendStr(buf, pos, "\n");
    return pos;
}

fn genCmdline(buf: []u8) usize {
    var pos: usize = 0;
    pos = appendStr(buf, pos, cmdline_buf[0..cmdline_len]);
    pos = appendStr(buf, pos, "\n");
    return pos;
}

fn genStat(buf: []u8) usize {
    var pos: usize = 0;

    // プロセス数
    var proc_count: usize = 0;
    var running_count: usize = 0;
    for (0..task.MAX_TASKS) |i| {
        if (task.getTask(@truncate(i))) |t| {
            if (t.state != .unused and t.state != .terminated and t.state != .zombie) {
                proc_count += 1;
                if (t.state == .running) running_count += 1;
            }
        }
    }

    pos = appendStr(buf, pos, "processes     : ");
    pos = appendDec(buf, pos, proc_count);
    pos = appendStr(buf, pos, "\n");
    pos = appendStr(buf, pos, "procs_running : ");
    pos = appendDec(buf, pos, running_count);
    pos = appendStr(buf, pos, "\n");
    pos = appendStr(buf, pos, "ctxt          : ");
    pos = appendDec(buf, pos, @truncate(context_switches));
    pos = appendStr(buf, pos, "\n");
    pos = appendStr(buf, pos, "uptime_ticks  : ");
    pos = appendDec(buf, pos, @truncate(pit.getTicks()));
    pos = appendStr(buf, pos, "\n");
    pos = appendStr(buf, pos, "boot_time     : 0\n");
    return pos;
}

fn genMounts(buf: []u8) usize {
    var pos: usize = 0;
    pos = appendStr(buf, pos, "ramfs    /     ramfs   rw 0 0\n");
    pos = appendStr(buf, pos, "procfs   /proc procfs  ro 0 0\n");
    pos = appendStr(buf, pos, "fat16    /mnt  vfat    rw 0 0\n");
    pos = appendStr(buf, pos, "ext2     /ext  ext2    rw 0 0\n");
    return pos;
}

fn genDevices(buf: []u8) usize {
    var pos: usize = 0;
    pos = appendStr(buf, pos, "Registered devices:\n");
    for (devices[0..MAX_DEVICES]) |*d| {
        if (!d.used) continue;
        pos = appendStr(buf, pos, "  ");
        pos = appendStr(buf, pos, d.dev_type[0..d.type_len]);
        pos = appendStr(buf, pos, "  ");
        pos = appendStr(buf, pos, d.name[0..d.name_len]);
        pos = appendStr(buf, pos, "\n");
    }
    return pos;
}

// ---- CPUID ヘルパー ----

fn getCpuVendor(out: *[12]u8) void {
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [b] "={ebx}" (ebx),
          [d] "={edx}" (edx),
          [c] "={ecx}" (ecx),
        : [eax] "{eax}" (@as(u32, 0)),
    );
    // EBX, EDX, ECX の順に 12 バイト
    out[0] = @truncate(ebx);
    out[1] = @truncate(ebx >> 8);
    out[2] = @truncate(ebx >> 16);
    out[3] = @truncate(ebx >> 24);
    out[4] = @truncate(edx);
    out[5] = @truncate(edx >> 8);
    out[6] = @truncate(edx >> 16);
    out[7] = @truncate(edx >> 24);
    out[8] = @truncate(ecx);
    out[9] = @truncate(ecx >> 8);
    out[10] = @truncate(ecx >> 16);
    out[11] = @truncate(ecx >> 24);
}

fn getCpuFeatures(edx_out: *u32, ecx_out: *u32) void {
    var edx: u32 = undefined;
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [d] "={edx}" (edx),
          [c] "={ecx}" (ecx),
        : [eax] "{eax}" (@as(u32, 1)),
        : .{ .ebx = true });
    edx_out.* = edx;
    ecx_out.* = ecx;
}

// ---- バッファ書き込みヘルパー ----

fn appendStr(buf: []u8, pos: usize, s: []const u8) usize {
    const avail = buf.len - pos;
    const len = @min(s.len, avail);
    if (len == 0) return pos;
    @memcpy(buf[pos .. pos + len], s[0..len]);
    return pos + len;
}

fn appendDec(buf: []u8, pos: usize, n: usize) usize {
    if (n == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            return pos + 1;
        }
        return pos;
    }
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        tmp[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    var p = pos;
    while (len > 0 and p < buf.len) {
        len -= 1;
        buf[p] = tmp[len];
        p += 1;
    }
    return p;
}

fn appendDecPadded(buf: []u8, pos: usize, n: usize, width: usize) usize {
    // 桁数を数える
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
    var p = pos;
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0 and p < buf.len) : (pad -= 1) {
            buf[p] = ' ';
            p += 1;
        }
    }
    return appendDec(buf, p, n);
}

fn printNum(n: usize) void {
    pmm.printNum(n);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
