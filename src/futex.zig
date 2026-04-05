// Futex — 高速ユーザー空間ミューテックス

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const task = @import("task.zig");

// ---- 定数 ----

const MAX_FUTEXES = 16;
const MAX_WAITERS = 8;

/// Futex の状態
const FutexState = enum(u8) {
    free, // 未使用
    unlocked, // アロケート済み・ロックなし
    locked, // ロック中
};

/// Futex 構造体
pub const Futex = struct {
    state: FutexState,
    value: u32, // ユーザー空間から見える値
    owner_pid: u32, // ロック保持者の PID (0=なし)
    wait_queue: [MAX_WAITERS]u32, // 待機中 PID (0=空)
    waiter_count: u8,
    name: [16]u8,
    name_len: u8,
    lock_count: u32, // ロック取得回数 (統計用)
    contention_count: u32, // 競合回数 (統計用)
};

var futexes: [MAX_FUTEXES]Futex = initFutexes();

fn initFutexes() [MAX_FUTEXES]Futex {
    var table: [MAX_FUTEXES]Futex = undefined;
    for (&table) |*f| {
        f.state = .free;
        f.value = 0;
        f.owner_pid = 0;
        f.wait_queue = [_]u32{0} ** MAX_WAITERS;
        f.waiter_count = 0;
        f.name = [_]u8{0} ** 16;
        f.name_len = 0;
        f.lock_count = 0;
        f.contention_count = 0;
    }
    return table;
}

// ---- 公開 API ----

/// 新しい futex を作成して ID を返す
pub fn create() ?u8 {
    return createNamed("futex");
}

/// 名前付き futex を作成
pub fn createNamed(name: []const u8) ?u8 {
    for (&futexes, 0..) |*f, i| {
        if (f.state == .free) {
            f.state = .unlocked;
            f.value = 0;
            f.owner_pid = 0;
            f.waiter_count = 0;
            f.lock_count = 0;
            f.contention_count = 0;
            for (&f.wait_queue) |*w| w.* = 0;

            const nlen: u8 = @intCast(@min(name.len, 16));
            @memcpy(f.name[0..nlen], name[0..nlen]);
            f.name_len = nlen;

            serial.write("[futex] created id=");
            serial.writeHex(i);
            serial.write(" name=");
            serial.write(name);
            serial.write("\n");

            return @intCast(i);
        }
    }
    return null;
}

/// futex を破棄
pub fn destroy(id: u8) void {
    if (id >= MAX_FUTEXES) return;
    const f = &futexes[id];
    if (f.state == .free) return;

    // 待機者を全て起こす
    wakeAll(id);

    f.state = .free;
    f.value = 0;
    f.owner_pid = 0;
    f.waiter_count = 0;

    serial.write("[futex] destroyed id=");
    serial.writeHex(id);
    serial.write("\n");
}

/// futex wait: *futex == expected なら呼び出し元をスリープ
/// 戻り値: true=正常に待機から復帰, false=値が異なるため待機しなかった
pub fn wait(id: u8, expected_val: u32) bool {
    if (id >= MAX_FUTEXES) return false;
    const f = &futexes[id];
    if (f.state == .free) return false;

    // 値チェック: アトミックに行うべきだが、カーネル内なので割り込み禁止で代替
    asm volatile ("cli");

    if (f.value != expected_val) {
        asm volatile ("sti");
        return false; // 値が変わっている = 再試行すべき
    }

    // 待機キューに追加
    const pid = task.getCurrentPid();
    if (!addWaiter(f, pid)) {
        asm volatile ("sti");
        return false; // キュー満杯
    }

    f.contention_count +|= 1;

    asm volatile ("sti");

    // yield して再スケジュールを待つ
    // 実際の sleep は wake で解除される
    task.yield();

    return true;
}

/// 最大 count 個の待機者を起こす
pub fn wake(id: u8, count: u32) void {
    if (id >= MAX_FUTEXES) return;
    const f = &futexes[id];
    if (f.state == .free) return;

    asm volatile ("cli");

    var woken: u32 = 0;
    for (&f.wait_queue) |*w| {
        if (woken >= count) break;
        if (w.* != 0) {
            // PID を ready 状態に
            if (task.getTask(w.*)) |t| {
                if (t.state == .waiting or t.state == .ready) {
                    t.state = .ready;
                }
            }
            w.* = 0;
            if (f.waiter_count > 0) f.waiter_count -= 1;
            woken += 1;
        }
    }

    asm volatile ("sti");
}

/// 全待機者を起こす
pub fn wakeAll(id: u8) void {
    wake(id, MAX_WAITERS);
}

/// ノンブロッキングロック試行
pub fn tryLock(id: u8) bool {
    if (id >= MAX_FUTEXES) return false;
    const f = &futexes[id];
    if (f.state == .free) return false;

    asm volatile ("cli");

    if (f.state == .unlocked or f.value == 0) {
        f.state = .locked;
        f.value = 1;
        f.owner_pid = task.getCurrentPid();
        f.lock_count +|= 1;
        asm volatile ("sti");
        return true;
    }

    asm volatile ("sti");
    return false;
}

/// ブロッキングロック: 取得できるまでリトライ
pub fn lock(id: u8) void {
    if (id >= MAX_FUTEXES) return;

    // スピンロック的リトライ (最大 32 回)
    var spins: u32 = 0;
    while (spins < 32) : (spins += 1) {
        if (tryLock(id)) return;
    }

    // スピンで取れなかったら wait + retry
    var retries: u32 = 0;
    while (retries < 100) : (retries += 1) {
        if (tryLock(id)) return;
        _ = wait(id, 1); // value==1 (locked) ならスリープ
    }

    // 最終手段: 強制取得 (デッドロック防止)
    serial.write("[futex] forced lock id=");
    serial.writeHex(id);
    serial.write("\n");

    asm volatile ("cli");
    const f = &futexes[id];
    f.state = .locked;
    f.value = 1;
    f.owner_pid = task.getCurrentPid();
    f.lock_count +|= 1;
    asm volatile ("sti");
}

/// アンロック: ロック解除して待機者を1つ起こす
pub fn unlock(id: u8) void {
    if (id >= MAX_FUTEXES) return;
    const f = &futexes[id];
    if (f.state != .locked) return;

    asm volatile ("cli");

    // 現在の PID がオーナーかチェック
    const pid = task.getCurrentPid();
    if (f.owner_pid != 0 and f.owner_pid != pid) {
        asm volatile ("sti");
        serial.write("[futex] unlock denied: not owner\n");
        return;
    }

    f.state = .unlocked;
    f.value = 0;
    f.owner_pid = 0;

    asm volatile ("sti");

    // 待機者を 1 つ起こす
    wake(id, 1);
}

/// futex の値を直接設定 (低レベル操作)
pub fn setValue(id: u8, val: u32) void {
    if (id >= MAX_FUTEXES) return;
    if (futexes[id].state == .free) return;
    futexes[id].value = val;
}

/// futex の値を取得
pub fn getValue(id: u8) u32 {
    if (id >= MAX_FUTEXES) return 0;
    return futexes[id].value;
}

/// 全 futex のステータスを表示
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("ID  STATE      VALUE  OWNER  WAITERS  LOCKS  NAME\n");
    vga.setColor(.light_grey, .black);

    var active: usize = 0;
    for (&futexes, 0..) |*f, i| {
        if (f.state == .free) continue;
        active += 1;

        // ID
        printDecPadded(i, 2);
        vga.write("  ");

        // State
        switch (f.state) {
            .free => {},
            .unlocked => {
                vga.setColor(.light_green, .black);
                vga.write("unlocked  ");
            },
            .locked => {
                vga.setColor(.light_red, .black);
                vga.write("locked    ");
            },
        }
        vga.setColor(.light_grey, .black);

        // Value
        printDecPadded(f.value, 5);
        vga.write("  ");

        // Owner
        if (f.owner_pid != 0) {
            printDecPadded(f.owner_pid, 5);
        } else {
            vga.write("    -");
        }
        vga.write("  ");

        // Waiters
        printDecPadded(f.waiter_count, 7);
        vga.write("  ");

        // Lock count
        printDecPadded(f.lock_count, 5);
        vga.write("  ");

        // Name
        vga.write(f.name[0..f.name_len]);
        vga.putChar('\n');

        // 待機者詳細
        if (f.waiter_count > 0) {
            vga.setColor(.dark_grey, .black);
            vga.write("     waiters: ");
            var first = true;
            for (f.wait_queue) |w| {
                if (w != 0) {
                    if (!first) vga.write(", ");
                    vga.write("pid=");
                    printDec(w);
                    first = false;
                }
            }
            vga.putChar('\n');
            vga.setColor(.light_grey, .black);
        }
    }

    if (active == 0) {
        vga.write("  (no active futexes)\n");
    } else {
        vga.setColor(.light_cyan, .black);
        printDec(active);
        vga.write("/");
        printDec(MAX_FUTEXES);
        vga.write(" futex slots in use\n");
        vga.setColor(.light_grey, .black);
    }
}

// ---- 内部ヘルパ ----

fn addWaiter(f: *Futex, pid: u32) bool {
    // 重複チェック
    for (f.wait_queue) |w| {
        if (w == pid) return true; // 既に待機中
    }
    // 空きスロットに追加
    for (&f.wait_queue) |*w| {
        if (w.* == 0) {
            w.* = pid;
            f.waiter_count += 1;
            return true;
        }
    }
    return false; // キュー満杯
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

fn printDecPadded(n: usize, width: usize) void {
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
    var pad = width -| digits;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
    if (n == 0) {
        vga.putChar('0');
    } else {
        var buf2: [10]u8 = undefined;
        var len: usize = 0;
        var val = n;
        while (val > 0) {
            buf2[len] = @truncate('0' + val % 10);
            len += 1;
            val /= 10;
        }
        while (len > 0) {
            len -= 1;
            vga.putChar(buf2[len]);
        }
    }
}
