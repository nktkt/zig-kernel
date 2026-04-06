// セキュリティ監査ログ
//
// カーネル内イベントの記録・フィルタリング・出力。
// 循環バッファ (64 エントリ) で最新イベントを保持。
// VGA とシリアルの両方に出力可能。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ===========================================================================
// 定数
// ===========================================================================

/// 監査ログの最大エントリ数 (循環バッファ)
const MAX_ENTRIES: usize = 64;

/// 詳細フィールドの最大長
const MAX_DETAILS: usize = 64;

// ===========================================================================
// イベントタイプ
// ===========================================================================

pub const EventType = enum(u8) {
    login = 0,
    logout = 1,
    file_access = 2,
    file_modify = 3,
    process_create = 4,
    process_exit = 5,
    permission_denied = 6,
    config_change = 7,
    network_connect = 8,
    syscall_blocked = 9,
    key_operation = 10,
    sandbox_violation = 11,

    pub fn name(self: EventType) []const u8 {
        return switch (self) {
            .login => "LOGIN",
            .logout => "LOGOUT",
            .file_access => "FILE_ACCESS",
            .file_modify => "FILE_MODIFY",
            .process_create => "PROC_CREATE",
            .process_exit => "PROC_EXIT",
            .permission_denied => "PERM_DENIED",
            .config_change => "CONFIG_CHG",
            .network_connect => "NET_CONNECT",
            .syscall_blocked => "SYSCALL_BLK",
            .key_operation => "KEY_OP",
            .sandbox_violation => "SANDBOX_VIO",
        };
    }

    /// イベントの重要度レベル
    pub fn severity(self: EventType) Severity {
        return switch (self) {
            .login, .logout => .info,
            .file_access => .info,
            .file_modify => .notice,
            .process_create, .process_exit => .info,
            .permission_denied => .warning,
            .config_change => .notice,
            .network_connect => .info,
            .syscall_blocked => .warning,
            .key_operation => .notice,
            .sandbox_violation => .warning,
        };
    }
};

/// 重要度レベル
pub const Severity = enum(u8) {
    info = 0,
    notice = 1,
    warning = 2,
    critical = 3,

    pub fn name(self: Severity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .notice => "NOTICE",
            .warning => "WARNING",
            .critical => "CRITICAL",
        };
    }
};

// ===========================================================================
// 監査エントリ
// ===========================================================================

pub const AuditEntry = struct {
    /// タイムスタンプ (PIT ticks)
    timestamp: u64,
    /// イベントタイプ
    event_type: EventType,
    /// ユーザー ID
    uid: u16,
    /// プロセス ID
    pid: u32,
    /// 詳細メッセージ
    details: [MAX_DETAILS]u8,
    details_len: usize,
    /// エントリが有効かどうか
    valid: bool,
};

// ===========================================================================
// 循環バッファ
// ===========================================================================

var entries: [MAX_ENTRIES]AuditEntry = initEntries();
var write_head: usize = 0;
var total_events: u64 = 0;

/// 各イベントタイプごとのカウンタ
var event_counts: [12]u32 = @splat(0);

/// シリアル出力の有効/無効
var serial_output_enabled: bool = true;

/// 最小出力重要度
var min_severity: Severity = .info;

fn initEntries() [MAX_ENTRIES]AuditEntry {
    var arr: [MAX_ENTRIES]AuditEntry = undefined;
    for (&arr) |*e| {
        e.valid = false;
        e.timestamp = 0;
        e.event_type = .login;
        e.uid = 0;
        e.pid = 0;
        e.details_len = 0;
        e.details = @splat(0);
    }
    return arr;
}

// ===========================================================================
// ログ API
// ===========================================================================

/// 監査イベントを記録
pub fn logEvent(event_type: EventType, uid: u16, pid: u32, details: []const u8) void {
    const entry = &entries[write_head];

    entry.valid = true;
    entry.timestamp = pit.getTicks();
    entry.event_type = event_type;
    entry.uid = uid;
    entry.pid = pid;
    entry.details_len = @min(details.len, MAX_DETAILS);
    @memcpy(entry.details[0..entry.details_len], details[0..entry.details_len]);
    if (entry.details_len < MAX_DETAILS) {
        @memset(entry.details[entry.details_len..MAX_DETAILS], 0);
    }

    // カウンタ更新
    const type_idx: usize = @intFromEnum(event_type);
    if (type_idx < event_counts.len) {
        event_counts[type_idx] += 1;
    }

    total_events += 1;
    write_head = (write_head + 1) % MAX_ENTRIES;

    // シリアル出力
    if (serial_output_enabled and
        @intFromEnum(event_type.severity()) >= @intFromEnum(min_severity))
    {
        writeEntrySerial(entry);
    }
}

/// 簡易ログ (uid=0, pid=0)
pub fn log(event_type: EventType, details: []const u8) void {
    logEvent(event_type, 0, 0, details);
}

/// シリアル出力の有効/無効を切り替え
pub fn setSerialOutput(enabled: bool) void {
    serial_output_enabled = enabled;
}

/// 最小重要度を設定
pub fn setMinSeverity(sev: Severity) void {
    min_severity = sev;
}

// ===========================================================================
// 統計 API
// ===========================================================================

/// 特定イベントタイプのカウントを取得
pub fn getEventCount(event_type: EventType) u32 {
    const idx: usize = @intFromEnum(event_type);
    if (idx < event_counts.len) {
        return event_counts[idx];
    }
    return 0;
}

/// 全イベントの合計カウントを取得
pub fn getTotalEvents() u64 {
    return total_events;
}

/// カウンタをリセット
pub fn resetCounts() void {
    event_counts = @splat(0);
    total_events = 0;
}

// ===========================================================================
// 表示 API
// ===========================================================================

/// 最近のイベントを VGA に表示
pub fn printLog() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Audit Log ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    // 最新から遡って表示
    var i: usize = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        const idx = (write_head + MAX_ENTRIES - 1 - i) % MAX_ENTRIES;
        const entry = &entries[idx];
        if (!entry.valid) continue;

        printEntry(entry);
        count += 1;
        if (count >= 16) break; // 画面サイズに収まるよう制限
    }

    if (count == 0) {
        vga.write("  (no events)\n");
    }

    vga.setColor(.light_grey, .black);
    vga.write("Total: ");
    printDecU64(total_events);
    vga.write(" events\n");
}

/// 特定タイプのイベントを表示
pub fn printByType(event_type: EventType) void {
    vga.setColor(.yellow, .black);
    vga.write("=== Audit: ");
    vga.write(event_type.name());
    vga.write(" ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    var i: usize = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        const idx = (write_head + MAX_ENTRIES - 1 - i) % MAX_ENTRIES;
        const entry = &entries[idx];
        if (!entry.valid) continue;
        if (entry.event_type != event_type) continue;

        printEntry(entry);
        count += 1;
        if (count >= 16) break;
    }

    if (count == 0) {
        vga.write("  (no events of this type)\n");
    }
}

/// イベント統計を表示
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Audit Statistics ===\n");
    vga.setColor(.light_grey, .black);

    const event_types = [_]EventType{
        .login,          .logout,       .file_access,
        .file_modify,    .process_create, .process_exit,
        .permission_denied, .config_change, .network_connect,
        .syscall_blocked, .key_operation, .sandbox_violation,
    };

    for (event_types) |et| {
        const count = getEventCount(et);
        if (count > 0) {
            vga.write("  ");
            // 固定幅のタイプ名
            const name_str = et.name();
            vga.write(name_str);
            // パディング
            var pad: usize = 14;
            if (name_str.len < pad) {
                pad -= name_str.len;
            } else {
                pad = 1;
            }
            var p: usize = 0;
            while (p < pad) : (p += 1) {
                vga.putChar(' ');
            }
            printDecU32(count);
            vga.putChar('\n');
        }
    }

    vga.write("  Total: ");
    printDecU64(total_events);
    vga.putChar('\n');
}

// ===========================================================================
// エントリ表示ヘルパー
// ===========================================================================

/// 1 エントリを VGA に表示
fn printEntry(entry: *const AuditEntry) void {
    // 重要度に応じた色
    switch (entry.event_type.severity()) {
        .info => vga.setColor(.light_grey, .black),
        .notice => vga.setColor(.light_cyan, .black),
        .warning => vga.setColor(.yellow, .black),
        .critical => vga.setColor(.light_red, .black),
    }

    // タイムスタンプ (秒)
    vga.write("[");
    const secs = entry.timestamp / 1000;
    printDecU64(secs);
    vga.write("s] ");

    // イベントタイプ
    vga.write(entry.event_type.name());
    vga.write(" ");

    // UID/PID
    vga.setColor(.dark_grey, .black);
    vga.write("uid=");
    printDecU16(entry.uid);
    vga.write(" pid=");
    printDecU32(entry.pid);

    // 詳細
    if (entry.details_len > 0) {
        vga.setColor(.light_grey, .black);
        vga.write(" ");
        vga.write(entry.details[0..entry.details_len]);
    }

    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

/// 1 エントリをシリアルに出力
fn writeEntrySerial(entry: *const AuditEntry) void {
    serial.write("[AUDIT] ");
    serialPrintDec64(entry.timestamp / 1000);
    serial.write("s ");
    serial.write(entry.event_type.name());
    serial.write(" uid=");
    serialPrintDec(@as(usize, entry.uid));
    serial.write(" pid=");
    serialPrintDec(@as(usize, entry.pid));
    if (entry.details_len > 0) {
        serial.putChar(' ');
        serial.write(entry.details[0..entry.details_len]);
    }
    serial.putChar('\n');
}

// ===========================================================================
// 数値表示ヘルパー
// ===========================================================================

fn printDecU16(n: u16) void {
    printDecU32(@as(u32, n));
}

fn printDecU32(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDecU64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn serialPrintDec64(n: u64) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialPrintDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
