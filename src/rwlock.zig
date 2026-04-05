// Read-Write Lock — 読み書きロックの実装
//
// 複数のリーダーが同時にロックを保持できるが、
// ライターは排他的にロックを取得する。
// ライター優先ポリシーにより、ライターの飢餓を防ぐ。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- 定数 ----

const MAX_RWLOCKS: usize = 8;
const MAX_NAME_LEN: usize = 16;
const MAX_READER_QUEUE: usize = 8;

// ---- ロック状態 ----

const LockState = enum(u8) {
    free, // 未使用スロット
    unlocked, // アロケート済み・ロックなし
    read_locked, // リーダーがロック中
    write_locked, // ライターがロック中
};

// ---- RWLock 構造�� ----

const RWLock = struct {
    state: LockState,
    readers_count: u32, // 現在のリーダー数
    writer_active: bool, // ライターがアクティブか
    write_waiter: bool, // ライターが待機中か (優先度のため)
    read_waiters: u32, // 読み取り待ちのスレッド数
    write_waiters: u32, // 書き込み待ちの��レッド数
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    // 統計
    read_acquires: u64, // 読み取りロック���得回数
    write_acquires: u64, // 書き込みロック取得回数
    read_contention: u64, // 読み取りで競合した回数
    write_contention: u64, // ���き込みで競合した回数
};

fn initRWLock() RWLock {
    return .{
        .state = .free,
        .readers_count = 0,
        .writer_active = false,
        .write_waiter = false,
        .read_waiters = 0,
        .write_waiters = 0,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .read_acquires = 0,
        .write_acquires = 0,
        .read_contention = 0,
        .write_contention = 0,
    };
}

// ---- グローバル状態 ----

var rwlocks: [MAX_RWLOCKS]RWLock = initAllRWLocks();
var total_created: u64 = 0;
var total_destroyed: u64 = 0;

fn initAllRWLocks() [MAX_RWLOCKS]RWLock {
    var arr: [MAX_RWLOCKS]RWLock = undefined;
    for (&arr) |*l| {
        l.* = initRWLock();
    }
    return arr;
}

// ---- ヘルパー ----

fn copyName(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

// ---- 公��� API ----

/// RWLock ��作成
pub fn create() ?u8 {
    return createNamed("rwlock");
}

/// 名前付き RWLock を作成
pub fn createNamed(name: []const u8) ?u8 {
    for (&rwlocks, 0..) |*l, i| {
        if (l.state == .free) {
            l.* = initRWLock();
            l.state = .unlocked;
            l.name_len = copyName(&l.name, name);
            total_created += 1;

            serial.write("[rwlock] created id=");
            serial.writeHex(i);
            serial.write(" name=");
            serial.write(name);
            serial.write("\n");

            return @truncate(i);
        }
    }
    return null;
}

/// RWLock を破棄
pub fn destroy(id: u8) void {
    if (id >= MAX_RWLOCKS) return;
    if (rwlocks[id].state == .free) return;

    if (rwlocks[id].readers_count > 0 or rwlocks[id].writer_active) {
        serial.write("[rwlock] warning: destroying active lock id=");
        serial.writeHex(id);
        serial.write("\n");
    }

    rwlocks[id].state = .free;
    total_destroyed += 1;
}

/// 読み取りロックを取得 (共有)
/// ライターがアクティブまたは待機中の場合はブロック
pub fn readLock(id: u8) bool {
    if (id >= MAX_RWLOCKS) return false;
    const lock = &rwlocks[id];
    if (lock.state == .free) return false;

    // ライター優先: ライターが待機中なら読み取りもブロック
    if (lock.writer_active or lock.write_waiter) {
        lock.read_contention += 1;
        lock.read_waiters += 1;
        // 実際のカーネルではここでスレッドをブロックする
        // 簡易実装: スピンウェイト (制限付き)
        var spin: u32 = 0;
        while (spin < 10000) : (spin += 1) {
            if (!lock.writer_active and !lock.write_waiter) break;
            asm volatile ("pause");
        }
        lock.read_waiters -|= 1;
        if (lock.writer_active) return false; // タイムアウト
    }

    lock.readers_count += 1;
    lock.state = .read_locked;
    lock.read_acquires += 1;
    return true;
}

/// 読み取りロックを解放
pub fn readUnlock(id: u8) void {
    if (id >= MAX_RWLOCKS) return;
    const lock = &rwlocks[id];
    if (lock.state == .free) return;
    if (lock.readers_count == 0) return;

    lock.readers_count -= 1;
    if (lock.readers_count == 0) {
        lock.state = .unlocked;
    }
}

/// 書���込みロックを取得 (排他)
pub fn writeLock(id: u8) bool {
    if (id >= MAX_RWLOCKS) return false;
    const lock = &rwlocks[id];
    if (lock.state == .free) return false;

    if (lock.writer_active or lock.readers_count > 0) {
        lock.write_contention += 1;
        lock.write_waiters += 1;
        lock.write_waiter = true;
        // スピンウェイト (制限付き)
        var spin: u32 = 0;
        while (spin < 10000) : (spin += 1) {
            if (!lock.writer_active and lock.readers_count == 0) break;
            asm volatile ("pause");
        }
        lock.write_waiters -|= 1;
        if (lock.write_waiters == 0) lock.write_waiter = false;
        if (lock.writer_active or lock.readers_count > 0) return false; // タイムアウト
    }

    lock.writer_active = true;
    lock.state = .write_locked;
    lock.write_acquires += 1;
    return true;
}

/// 書き込みロックを解放
pub fn writeUnlock(id: u8) void {
    if (id >= MAX_RWLOCKS) return;
    const lock = &rwlocks[id];
    if (lock.state == .free) return;
    if (!lock.writer_active) return;

    lock.writer_active = false;
    lock.state = .unlocked;
}

/// 読み取りロックの試行 (ノンブロッキング)
pub fn tryReadLock(id: u8) bool {
    if (id >= MAX_RWLOCKS) return false;
    const lock = &rwlocks[id];
    if (lock.state == .free) return false;

    // ライターがアクティブまたは待機中なら失敗
    if (lock.writer_active or lock.write_waiter) return false;

    lock.readers_count += 1;
    lock.state = .read_locked;
    lock.read_acquires += 1;
    return true;
}

/// 書き込みロックの試行 (ノンブロッキング)
pub fn tryWriteLock(id: u8) bool {
    if (id >= MAX_RWLOCKS) return false;
    const lock = &rwlocks[id];
    if (lock.state == .free) return false;

    // 他のリーダーまたはライターがいたら失敗
    if (lock.writer_active or lock.readers_count > 0) return false;

    lock.writer_active = true;
    lock.state = .write_locked;
    lock.write_acquires += 1;
    return true;
}

/// ロックを読み取りから書き込みにアップグレード (自分だけがリーダーの場合)
pub fn upgrade(id: u8) bool {
    if (id >= MAX_RWLOCKS) return false;
    const lock = &rwlocks[id];
    if (lock.state == .free) return false;

    // 自分だけ���リーダーの場合のみアップグレード可能
    if (lock.readers_count != 1 or lock.writer_active) return false;

    lock.readers_count = 0;
    lock.writer_active = true;
    lock.state = .write_locked;
    lock.write_acquires += 1;
    return true;
}

/// ロックを書き込みから読み取りにダウングレード
pub fn downgrade(id: u8) void {
    if (id >= MAX_RWLOCKS) return;
    const lock = &rwlocks[id];
    if (lock.state == .free) return;
    if (!lock.writer_active) return;

    lock.writer_active = false;
    lock.readers_count = 1;
    lock.state = .read_locked;
    lock.read_acquires += 1;
}

// ---- 情報取得 ----

/// リーダー数を取得
pub fn getReaderCount(id: u8) ?u32 {
    if (id >= MAX_RWLOCKS) return null;
    if (rwlocks[id].state == .free) return null;
    return rwlocks[id].readers_count;
}

/// ライターがアクティブか
pub fn isWriteLocked(id: u8) bool {
    if (id >= MAX_RWLOCKS) return false;
    return rwlocks[id].writer_active;
}

/// ロック状態を取得
pub fn getState(id: u8) ?LockState {
    if (id >= MAX_RWLOCKS) return null;
    if (rwlocks[id].state == .free) return null;
    return rwlocks[id].state;
}

// ---- 表示 ----

/// 全 RWLock の状態を表示
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Read-Write Locks ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  ID  Name             State       Readers  Writer  R-Wait  W-Wait\n");
    vga.write("  --  ---------------  ----------  -------  ------  ------  ------\n");

    var count: usize = 0;
    for (&rwlocks, 0..) |*l, i| {
        if (l.state == .free) continue;

        vga.write("  ");
        fmt.printDecPadded(i, 2);
        vga.write("  ");
        vga.write(l.name[0..l.name_len]);
        if (l.name_len < 15) {
            var pad: usize = 15 - @as(usize, l.name_len);
            while (pad > 0) : (pad -= 1) vga.putChar(' ');
        }
        vga.write("  ");
        printLockState(l.state);
        vga.write("  ");
        fmt.printDecPadded(l.readers_count, 7);
        vga.write("  ");
        if (l.writer_active) {
            vga.setColor(.light_red, .black);
            vga.write("yes   ");
        } else {
            vga.write("no    ");
        }
        vga.setColor(.light_grey, .black);
        vga.write("  ");
        fmt.printDecPadded(l.read_waiters, 6);
        vga.write("  ");
        fmt.printDecPadded(l.write_waiters, 6);
        vga.putChar('\n');
        count += 1;
    }

    if (count == 0) {
        vga.write("  No active rwlocks.\n");
    }

    vga.write("\n  Total created: ");
    fmt.printDec(@truncate(total_created));
    vga.write("  Destroyed: ");
    fmt.printDec(@truncate(total_destroyed));
    vga.putChar('\n');

    // 競合統計
    vga.write("  Contention summary:\n");
    for (&rwlocks, 0..) |*l, i| {
        if (l.state == .free) continue;
        if (l.read_contention > 0 or l.write_contention > 0) {
            vga.write("    Lock ");
            fmt.printDec(i);
            vga.write(" (");
            vga.write(l.name[0..l.name_len]);
            vga.write("): read_contention=");
            fmt.printDec(@truncate(l.read_contention));
            vga.write(" write_contention=");
            fmt.printDec(@truncate(l.write_contention));
            vga.putChar('\n');
        }
    }
}

fn printLockState(state: LockState) void {
    switch (state) {
        .free => vga.write("free      "),
        .unlocked => vga.write("unlocked  "),
        .read_locked => {
            vga.setColor(.light_green, .black);
            vga.write("read_lock ");
            vga.setColor(.light_grey, .black);
        },
        .write_locked => {
            vga.setColor(.light_red, .black);
            vga.write("write_lock");
            vga.setColor(.light_grey, .black);
        },
    }
}
