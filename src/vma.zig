// Virtual Memory Area (VMA) 管理 — プロセスごとの仮想メモリ領域追跡
//
// 各プロセスの仮想アドレス空間を VMA のリストとして管理。
// テキスト、データ、BSS、ヒープ、スタック、mmap 等の領域を追跡し、
// ページフォルト時のアクセス権限チェックと領域管理を行う。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");

// ---- 定数 ----

const MAX_PROCESSES: usize = 4;
const MAX_VMAS_PER_PROC: usize = 16;
const MAX_NAME_LEN: usize = 16;
const PAGE_SIZE: u32 = 4096;

// ---- VMA フラグ ----

pub const VMA_READ: u32 = 1 << 0;
pub const VMA_WRITE: u32 = 1 << 1;
pub const VMA_EXEC: u32 = 1 << 2;
pub const VMA_SHARED: u32 = 1 << 3;
pub const VMA_GROWSDOWN: u32 = 1 << 4; // スタック領域 (下方成長)
pub const VMA_ANONYMOUS: u32 = 1 << 5; // 無名マッピング
pub const VMA_FIXED: u32 = 1 << 6; // 固定アドレス

// 便利な組み合わせ
pub const VMA_RW: u32 = VMA_READ | VMA_WRITE;
pub const VMA_RX: u32 = VMA_READ | VMA_EXEC;
pub const VMA_RWX: u32 = VMA_READ | VMA_WRITE | VMA_EXEC;

// ---- アクセスタイプ (ページフォルト処理用) ----

pub const AccessType = enum(u8) {
    read,
    write,
    exec,
};

// ---- VMA 構造体 ----

pub const Vma = struct {
    start: u32, // 開始アドレス (ページアラインド)
    end: u32, // 終了アドレス (排他的, ページアラインド)
    flags: u32, // VMA_READ | VMA_WRITE | ...
    file_offset: u32, // ファイルマッピングのオフセット
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    active: bool,
    // 統計
    fault_count: u32, // ページフォルト回数
    page_count: u32, // マップ済みページ数
};

fn initVma() Vma {
    return .{
        .start = 0,
        .end = 0,
        .flags = 0,
        .file_offset = 0,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .active = false,
        .fault_count = 0,
        .page_count = 0,
    };
}

// ---- プロセスごとの VMA テーブル ----

const ProcessVmaTable = struct {
    vmas: [MAX_VMAS_PER_PROC]Vma,
    pid: u32,
    active: bool,
    vma_count: usize,
    total_faults: u32,
};

fn initProcessVmaTable() ProcessVmaTable {
    var table: ProcessVmaTable = undefined;
    for (&table.vmas) |*v| {
        v.* = initVma();
    }
    table.pid = 0;
    table.active = false;
    table.vma_count = 0;
    table.total_faults = 0;
    return table;
}

var proc_tables: [MAX_PROCESSES]ProcessVmaTable = initAllTables();

fn initAllTables() [MAX_PROCESSES]ProcessVmaTable {
    var tables: [MAX_PROCESSES]ProcessVmaTable = undefined;
    for (&tables) |*t| {
        t.* = initProcessVmaTable();
    }
    return tables;
}

// ---- ヘルパー ----

/// PID からプロセステーブルを検索 (なければ空きスロットに割り当て)
fn findOrCreateProcTable(pid: u32) ?*ProcessVmaTable {
    // 既存を検索
    for (&proc_tables) |*t| {
        if (t.active and t.pid == pid) return t;
    }
    // 空きスロットに作成
    for (&proc_tables) |*t| {
        if (!t.active) {
            t.active = true;
            t.pid = pid;
            t.vma_count = 0;
            t.total_faults = 0;
            return t;
        }
    }
    return null;
}

/// PID からプロセステーブルを検索
fn findProcTable(pid: u32) ?*ProcessVmaTable {
    for (&proc_tables) |*t| {
        if (t.active and t.pid == pid) return t;
    }
    return null;
}

/// アドレスがページアラインドか
fn isPageAligned(addr: u32) bool {
    return (addr % PAGE_SIZE) == 0;
}

/// ページアラインに切り上げ
fn pageAlignUp(addr: u32) u32 {
    return (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

/// ページアラインに切り下げ
fn pageAlignDown(addr: u32) u32 {
    return addr & ~(PAGE_SIZE - 1);
}

/// 名前をコピー
fn copyName(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

/// 2 つの VMA が隣接しているかチェック
fn isAdjacent(a: *const Vma, b: *const Vma) bool {
    return a.end == b.start or b.end == a.start;
}

/// 2 つの VMA が重複しているかチェック
fn overlaps(start1: u32, end1: u32, start2: u32, end2: u32) bool {
    return start1 < end2 and start2 < end1;
}

// ---- 名前比較 ----

fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ---- 公開 API ----

/// VMA を追加
pub fn addVma(pid: u32, start: u32, end: u32, flags: u32, name: []const u8) bool {
    if (start >= end) return false;

    const table = findOrCreateProcTable(pid) orelse return false;

    // 重複チェック
    for (&table.vmas) |*v| {
        if (v.active and overlaps(start, end, v.start, v.end)) {
            serial.write("[vma] overlap detected for pid=");
            serial.writeHex(pid);
            serial.write("\n");
            return false;
        }
    }

    // 空きスロットを探す
    for (&table.vmas) |*v| {
        if (!v.active) {
            v.start = pageAlignDown(start);
            v.end = pageAlignUp(end);
            v.flags = flags;
            v.file_offset = 0;
            v.active = true;
            v.fault_count = 0;
            v.page_count = 0;
            v.name_len = copyName(&v.name, name);
            table.vma_count += 1;
            return true;
        }
    }

    return false; // スロット不足
}

/// アドレスを含む VMA を削除
pub fn removeVma(pid: u32, addr: u32) bool {
    const table = findProcTable(pid) orelse return false;

    for (&table.vmas) |*v| {
        if (v.active and addr >= v.start and addr < v.end) {
            v.active = false;
            table.vma_count -|= 1;
            return true;
        }
    }
    return false;
}

/// 指定アドレスを含む VMA を検索
pub fn findVma(pid: u32, addr: u32) ?*Vma {
    const table = findProcTable(pid) orelse return null;

    for (&table.vmas) |*v| {
        if (v.active and addr >= v.start and addr < v.end) {
            return v;
        }
    }
    return null;
}

/// アドレスに対するアクセス権限をチェック
pub fn checkPermission(pid: u32, addr: u32, access_type: AccessType) bool {
    const v = findVma(pid, addr) orelse return false;

    return switch (access_type) {
        .read => (v.flags & VMA_READ) != 0,
        .write => (v.flags & VMA_WRITE) != 0,
        .exec => (v.flags & VMA_EXEC) != 0,
    };
}

/// ページフォルト処理
/// addr にマッピングがあり、書き込み許可があるかチェック。
/// 有効な VMA が存在すれば true (ページの割り当てはここでは行わない, 上位レイヤーが担当)
pub fn handleFault(pid: u32, addr: u32, write: bool) bool {
    const table = findProcTable(pid) orelse return false;
    table.total_faults += 1;

    const v = findVma(pid, addr) orelse {
        serial.write("[vma] fault: no VMA for addr=0x");
        serial.writeHex(addr);
        serial.write(" pid=");
        serial.writeHex(pid);
        serial.write("\n");
        return false;
    };

    v.fault_count += 1;

    // 書き込みフォルトで書き込み不可の場合は拒否
    if (write and (v.flags & VMA_WRITE) == 0) {
        serial.write("[vma] write fault denied at 0x");
        serial.writeHex(addr);
        serial.write("\n");
        return false;
    }

    // 読み込みフォルトで読み込み不可の場合は拒否
    if (!write and (v.flags & VMA_READ) == 0) {
        serial.write("[vma] read fault denied at 0x");
        serial.writeHex(addr);
        serial.write("\n");
        return false;
    }

    // ページを割り当て (demand paging)
    v.page_count += 1;

    serial.write("[vma] fault handled at 0x");
    serial.writeHex(addr);
    serial.write(" pid=");
    serial.writeHex(pid);
    serial.write("\n");
    return true;
}

/// VMA のマージ: 隣接する同じフラグの VMA を結合
pub fn mergeAdjacent(pid: u32) usize {
    const table = findProcTable(pid) orelse return 0;
    var merged: usize = 0;

    var i: usize = 0;
    while (i < MAX_VMAS_PER_PROC) : (i += 1) {
        if (!table.vmas[i].active) continue;

        var j: usize = i + 1;
        while (j < MAX_VMAS_PER_PROC) : (j += 1) {
            if (!table.vmas[j].active) continue;

            // 同じフラグで隣接している場合にマージ
            if (table.vmas[i].flags == table.vmas[j].flags) {
                if (table.vmas[i].end == table.vmas[j].start) {
                    // i の end を j の end に拡張
                    table.vmas[i].end = table.vmas[j].end;
                    table.vmas[i].fault_count += table.vmas[j].fault_count;
                    table.vmas[i].page_count += table.vmas[j].page_count;
                    table.vmas[j].active = false;
                    table.vma_count -|= 1;
                    merged += 1;
                } else if (table.vmas[j].end == table.vmas[i].start) {
                    // i の start を j の start に縮小
                    table.vmas[i].start = table.vmas[j].start;
                    table.vmas[i].fault_count += table.vmas[j].fault_count;
                    table.vmas[i].page_count += table.vmas[j].page_count;
                    table.vmas[j].active = false;
                    table.vma_count -|= 1;
                    merged += 1;
                }
            }
        }
    }
    return merged;
}

/// VMA の分割: 部分的な unmap のために VMA を2つに分割
/// addr: 分割ポイント (この位置で切断)
pub fn splitVma(pid: u32, addr: u32) bool {
    const table = findProcTable(pid) orelse return false;

    // 分割対象の VMA を探す
    var target_idx: ?usize = null;
    for (&table.vmas, 0..) |*v, i| {
        if (v.active and addr > v.start and addr < v.end) {
            target_idx = i;
            break;
        }
    }

    const idx = target_idx orelse return false;

    // 空きスロットを探す
    var free_idx: ?usize = null;
    for (&table.vmas, 0..) |*v, i| {
        if (!v.active) {
            free_idx = i;
            break;
        }
    }

    const new_idx = free_idx orelse return false;

    const aligned_addr = pageAlignUp(addr);

    // 新しい VMA (後半部分)
    table.vmas[new_idx] = table.vmas[idx]; // コピー
    table.vmas[new_idx].start = aligned_addr;
    table.vmas[new_idx].fault_count = 0;
    table.vmas[new_idx].page_count = 0;

    // 元の VMA (前半部分) の end を更新
    table.vmas[idx].end = aligned_addr;

    table.vma_count += 1;
    return true;
}

// ---- 共通 VMA テンプレート ----

/// テキストセグメント VMA を追加
pub fn addTextVma(pid: u32, start: u32, end: u32) bool {
    return addVma(pid, start, end, VMA_READ | VMA_EXEC, ".text");
}

/// データセグメント VMA を追加
pub fn addDataVma(pid: u32, start: u32, end: u32) bool {
    return addVma(pid, start, end, VMA_RW, ".data");
}

/// BSS セグメント VMA を追加
pub fn addBssVma(pid: u32, start: u32, end: u32) bool {
    return addVma(pid, start, end, VMA_RW | VMA_ANONYMOUS, ".bss");
}

/// ヒープ VMA を追加
pub fn addHeapVma(pid: u32, start: u32, end: u32) bool {
    return addVma(pid, start, end, VMA_RW | VMA_ANONYMOUS, "heap");
}

/// スタック VMA を追加
pub fn addStackVma(pid: u32, start: u32, end: u32) bool {
    return addVma(pid, start, end, VMA_RW | VMA_GROWSDOWN | VMA_ANONYMOUS, "stack");
}

/// mmap VMA を追加
pub fn addMmapVma(pid: u32, start: u32, end: u32, flags: u32) bool {
    return addVma(pid, start, end, flags | VMA_ANONYMOUS, "mmap");
}

// ---- 表示 ----

/// 特定プロセスの VMA を表示
pub fn printVmas(pid: u32) void {
    const table = findProcTable(pid) orelse {
        vga.write("  No VMAs for pid ");
        fmt.printDec(pid);
        vga.putChar('\n');
        return;
    };

    vga.setColor(.yellow, .black);
    vga.write("=== VMAs for PID ");
    fmt.printDec(pid);
    vga.write(" ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Start      End        Flags  Name\n");
    vga.write("  ---------  ---------  -----  ----\n");

    for (&table.vmas) |*v| {
        if (!v.active) continue;

        vga.write("  0x");
        fmt.printHex32(v.start);
        vga.write("  0x");
        fmt.printHex32(v.end);
        vga.write("  ");
        printFlags(v.flags);
        vga.write("  ");
        vga.write(v.name[0..v.name_len]);
        vga.write(" (faults=");
        fmt.printDec(v.fault_count);
        vga.write(" pages=");
        fmt.printDec(v.page_count);
        vga.write(")\n");
    }

    vga.write("  Total VMAs: ");
    fmt.printDec(table.vma_count);
    vga.write("  Total faults: ");
    fmt.printDec(table.total_faults);
    vga.putChar('\n');
}

/// 全プロセスの VMA を表示
pub fn printAllVmas() void {
    vga.setColor(.yellow, .black);
    vga.write("=== All VMAs ===\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    for (&proc_tables) |*t| {
        if (t.active) {
            printVmas(t.pid);
            any = true;
        }
    }

    if (!any) {
        vga.write("  No active VMA tables.\n");
    }
}

fn printFlags(flags: u32) void {
    if (flags & VMA_READ != 0) vga.putChar('r') else vga.putChar('-');
    if (flags & VMA_WRITE != 0) vga.putChar('w') else vga.putChar('-');
    if (flags & VMA_EXEC != 0) vga.putChar('x') else vga.putChar('-');
    if (flags & VMA_SHARED != 0) vga.putChar('s') else vga.putChar('p');
    if (flags & VMA_GROWSDOWN != 0) vga.putChar('d') else vga.putChar(' ');
}

// ---- プロセステーブルの解放 ----

/// プロセスの全 VMA を解放
pub fn destroyProcess(pid: u32) void {
    const table = findProcTable(pid) orelse return;

    for (&table.vmas) |*v| {
        v.active = false;
    }
    table.active = false;
    table.vma_count = 0;
}

/// プロセスの VMA 数を返す
pub fn vmaCount(pid: u32) usize {
    const table = findProcTable(pid) orelse return 0;
    return table.vma_count;
}

/// プロセスの合計マップ済みページ数を返す
pub fn totalMappedPages(pid: u32) usize {
    const table = findProcTable(pid) orelse return 0;
    var total: usize = 0;
    for (&table.vmas) |*v| {
        if (v.active) {
            total += v.page_count;
        }
    }
    return total;
}

/// VMA のファイルオフセットを設定
pub fn setFileOffset(pid: u32, addr: u32, offset: u32) bool {
    const v = findVma(pid, addr) orelse return false;
    v.file_offset = offset;
    return true;
}
