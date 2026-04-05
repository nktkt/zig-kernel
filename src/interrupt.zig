// 高度な割り込み管理 — 共有 IRQ、統計、トップ/ボトムハーフ処理
//
// 基本的な IDT ハンドラの上位レイヤーとして機能し、
// IRQ ごとの複数ハンドラ登録、統計追跡、
// クリティカルセクション管理を提供する。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const idt = @import("idt.zig");
const pit = @import("pit.zig");

// ---- 定数 ----

const MAX_IRQS: usize = 16; // ISA IRQ 0-15
const MAX_HANDLERS_PER_IRQ: usize = 4; // 共有 IRQ 用
const MAX_NAME_LEN: usize = 16;
const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

// ---- IRQ ハンドラの型 ----

/// IRQ ハンドラ関数の型
/// 戻り値: true = この IRQ を処理した, false = 次のハンドラに委譲
pub const IrqHandler = *const fn () bool;

// ---- ボトムハーフ (遅延処理) の型 ----

pub const BottomHalfFn = *const fn () void;

// ---- ハンドラエントリ ----

const HandlerEntry = struct {
    handler: ?IrqHandler,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    active: bool,
    call_count: u64,
};

fn initHandlerEntry() HandlerEntry {
    return .{
        .handler = null,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .active = false,
        .call_count = 0,
    };
}

// ---- IRQ 統計 ----

const IrqStats = struct {
    total_count: u64, // 割り込み発生回数
    last_tick: u64, // 最後の発生 tick
    spurious_count: u64, // スプリアス割り込み回数
    handlers: [MAX_HANDLERS_PER_IRQ]HandlerEntry,
    handler_count: usize,
    enabled: bool, // PIC でマスクされているか
    bottom_half: ?BottomHalfFn, // ボトムハーフ処理
    bottom_half_pending: bool, // ボトムハーフ未処理フラグ
};

fn initIrqStats() IrqStats {
    var stats: IrqStats = undefined;
    stats.total_count = 0;
    stats.last_tick = 0;
    stats.spurious_count = 0;
    stats.handler_count = 0;
    stats.enabled = false;
    stats.bottom_half = null;
    stats.bottom_half_pending = false;
    for (&stats.handlers) |*h| {
        h.* = initHandlerEntry();
    }
    return stats;
}

// ---- グローバル状態 ----

var irq_stats: [MAX_IRQS]IrqStats = initAllStats();
var nesting_depth: u32 = 0; // 割り込みネストカウンタ
var total_interrupts: u64 = 0;
var total_spurious: u64 = 0;

fn initAllStats() [MAX_IRQS]IrqStats {
    var stats: [MAX_IRQS]IrqStats = undefined;
    for (&stats) |*s| {
        s.* = initIrqStats();
    }
    // IRQ 0 (timer) と IRQ 1 (keyboard) はデフォルトで有効
    stats[0].enabled = true;
    stats[1].enabled = true;
    return stats;
}

// ---- ヘルパー ----

fn copyName(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

fn nameMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ---- 公開 API ----

/// IRQ ハンドラを登録 (共有 IRQ 対応)
pub fn registerHandler(irq: u8, handler: IrqHandler, name: []const u8) bool {
    if (irq >= MAX_IRQS) return false;

    const stats = &irq_stats[irq];

    // 空きスロットを探す
    for (&stats.handlers) |*h| {
        if (!h.active) {
            h.handler = handler;
            h.name_len = copyName(&h.name, name);
            h.active = true;
            h.call_count = 0;
            stats.handler_count += 1;

            serial.write("[irq] registered handler \"");
            serial.write(name);
            serial.write("\" for IRQ ");
            serial.writeHex(irq);
            serial.write("\n");

            return true;
        }
    }

    serial.write("[irq] no free handler slots for IRQ ");
    serial.writeHex(irq);
    serial.write("\n");
    return false;
}

/// IRQ ハンドラを登録解除
pub fn unregisterHandler(irq: u8, handler: IrqHandler) bool {
    if (irq >= MAX_IRQS) return false;

    const stats = &irq_stats[irq];

    for (&stats.handlers) |*h| {
        if (h.active and h.handler == handler) {
            h.active = false;
            h.handler = null;
            stats.handler_count -|= 1;
            return true;
        }
    }
    return false;
}

/// 名前で IRQ ハンドラを登録解除
pub fn unregisterByName(irq: u8, name: []const u8) bool {
    if (irq >= MAX_IRQS) return false;

    const stats = &irq_stats[irq];

    for (&stats.handlers) |*h| {
        if (h.active and nameMatch(h.name[0..h.name_len], name)) {
            h.active = false;
            h.handler = null;
            stats.handler_count -|= 1;
            return true;
        }
    }
    return false;
}

/// ボトムハーフハンドラを登録
pub fn registerBottomHalf(irq: u8, handler: BottomHalfFn) bool {
    if (irq >= MAX_IRQS) return false;
    irq_stats[irq].bottom_half = handler;
    return true;
}

/// IRQ 発生時のディスパッチ (トップハーフ)
/// IDT ハンドラから呼ばれることを想定
pub fn dispatch(irq: u8) void {
    if (irq >= MAX_IRQS) return;

    nesting_depth += 1;
    total_interrupts += 1;

    const stats = &irq_stats[irq];
    stats.total_count += 1;
    stats.last_tick = pit.getTicks();

    // スプリアス割り込み検出 (IRQ 7, 15)
    if (irq == 7 or irq == 15) {
        if (!isRealIrq(irq)) {
            stats.spurious_count += 1;
            total_spurious += 1;
            nesting_depth -|= 1;
            // IRQ 15 の場合は PIC1 に EOI を送る必要がある
            if (irq == 15) {
                idt.outb(PIC1_CMD, 0x20);
            }
            return;
        }
    }

    // ハンドラチェーンを実行
    var handled = false;
    for (&stats.handlers) |*h| {
        if (h.active) {
            if (h.handler) |handler| {
                if (handler()) {
                    h.call_count += 1;
                    handled = true;
                    break; // 処理されたら終了
                }
                h.call_count += 1;
            }
        }
    }

    if (!handled and stats.handler_count > 0) {
        serial.write("[irq] unhandled IRQ ");
        serial.writeHex(irq);
        serial.write("\n");
    }

    // ボトムハーフをスケジュール
    if (stats.bottom_half != null) {
        stats.bottom_half_pending = true;
    }

    nesting_depth -|= 1;
}

/// ボトムハーフの実行 (割り込みコンテキスト外から呼ばれる)
pub fn processBottomHalves() void {
    for (&irq_stats) |*stats| {
        if (stats.bottom_half_pending) {
            stats.bottom_half_pending = false;
            if (stats.bottom_half) |bh| {
                bh();
            }
        }
    }
}

/// スプリアス割り込み検出: ISR レジスタをチェック
fn isRealIrq(irq: u8) bool {
    if (irq == 7) {
        // PIC1 の ISR を読む
        idt.outb(PIC1_CMD, 0x0B);
        const isr_val = idt.inb(PIC1_CMD);
        return (isr_val & 0x80) != 0;
    } else if (irq == 15) {
        // PIC2 の ISR を読む
        idt.outb(PIC2_CMD, 0x0B);
        const isr_val = idt.inb(PIC2_CMD);
        return (isr_val & 0x80) != 0;
    }
    return true;
}

// ---- IRQ マスク制御 ----

/// IRQ を有効化 (PIC マスク解除)
pub fn enableIrq(irq: u8) void {
    if (irq >= MAX_IRQS) return;

    irq_stats[irq].enabled = true;

    if (irq < 8) {
        const mask = idt.inb(PIC1_DATA);
        idt.outb(PIC1_DATA, mask & ~(@as(u8, 1) << @truncate(irq)));
    } else {
        const mask = idt.inb(PIC2_DATA);
        idt.outb(PIC2_DATA, mask & ~(@as(u8, 1) << @truncate(irq - 8)));
        // PIC2 が使われる場合、PIC1 の IRQ2 (cascade) も有効化
        const mask1 = idt.inb(PIC1_DATA);
        idt.outb(PIC1_DATA, mask1 & ~@as(u8, 4));
    }
}

/// IRQ を無効化 (PIC マスク設定)
pub fn disableIrq(irq: u8) void {
    if (irq >= MAX_IRQS) return;

    irq_stats[irq].enabled = false;

    if (irq < 8) {
        const mask = idt.inb(PIC1_DATA);
        idt.outb(PIC1_DATA, mask | (@as(u8, 1) << @truncate(irq)));
    } else {
        const mask = idt.inb(PIC2_DATA);
        idt.outb(PIC2_DATA, mask | (@as(u8, 1) << @truncate(irq - 8)));
    }
}

/// IRQ が有効かチェック
pub fn isIrqEnabled(irq: u8) bool {
    if (irq >= MAX_IRQS) return false;
    return irq_stats[irq].enabled;
}

// ---- クリティカルセクション ----

/// クリティカルセクションに入る (割り込み無効化)
/// 戻り値: 以前の EFLAGS (割り込みフラグの保存)
pub fn enterCritical() u32 {
    const eflags = asm volatile (
        \\pushf
        \\pop %[result]
        \\cli
        : [result] "=r" (-> u32),
    );
    return eflags;
}

/// クリティカルセクションから出る (割り込み状態を復元)
pub fn leaveCritical(saved: u32) void {
    if (saved & 0x200 != 0) {
        // IF ビットが設定されていた → 割り込みを再有効化
        asm volatile ("sti");
    }
}

/// 割り込みネストの深さ
pub fn getNestingDepth() u32 {
    return nesting_depth;
}

/// 割り込みコンテキスト内かチェック
pub fn inInterruptContext() bool {
    return nesting_depth > 0;
}

// ---- 統計 ----

/// IRQ の発生回数を取得
pub fn getIrqCount(irq: u8) u64 {
    if (irq >= MAX_IRQS) return 0;
    return irq_stats[irq].total_count;
}

/// IRQ のスプリアス回数を取得
pub fn getSpuriousCount(irq: u8) u64 {
    if (irq >= MAX_IRQS) return 0;
    return irq_stats[irq].spurious_count;
}

/// 全割り込み回数
pub fn getTotalInterrupts() u64 {
    return total_interrupts;
}

/// 全スプリアス回数
pub fn getTotalSpurious() u64 {
    return total_spurious;
}

// ---- 表示 ----

/// IRQ 統計を表示
pub fn printIrqStats() void {
    vga.setColor(.yellow, .black);
    vga.write("=== IRQ Statistics ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  IRQ  Count        Spurious  Enabled  Handlers\n");
    vga.write("  ---  -----------  --------  -------  --------\n");

    for (0..MAX_IRQS) |irq| {
        const stats = &irq_stats[irq];
        // アクティブな IRQ のみ表示
        if (stats.total_count == 0 and stats.handler_count == 0 and !stats.enabled) continue;

        vga.write("  ");
        fmt.printDecPadded(irq, 3);
        vga.write("  ");
        fmt.printDecPadded(@truncate(stats.total_count), 11);
        vga.write("  ");
        fmt.printDecPadded(@truncate(stats.spurious_count), 8);
        vga.write("  ");
        if (stats.enabled) {
            vga.setColor(.light_green, .black);
            vga.write("yes    ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("no     ");
        }
        vga.setColor(.light_grey, .black);
        vga.write("  ");

        // ハンドラ名を表示
        var first = true;
        for (&stats.handlers) |*h| {
            if (h.active) {
                if (!first) vga.write(", ");
                vga.write(h.name[0..h.name_len]);
                first = false;
            }
        }
        vga.putChar('\n');
    }

    vga.write("\n  Total interrupts: ");
    fmt.printDec(@truncate(total_interrupts));
    vga.write("  Spurious: ");
    fmt.printDec(@truncate(total_spurious));
    vga.write("  Nesting depth: ");
    fmt.printDec(nesting_depth);
    vga.putChar('\n');
}

/// 特定 IRQ の詳細を表示
pub fn printIrqDetail(irq: u8) void {
    if (irq >= MAX_IRQS) {
        vga.write("  Invalid IRQ number.\n");
        return;
    }

    const stats = &irq_stats[irq];

    vga.setColor(.yellow, .black);
    vga.write("=== IRQ ");
    fmt.printDec(irq);
    vga.write(" Detail ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Total count:    ");
    fmt.printDec(@truncate(stats.total_count));
    vga.write("\n  Spurious count: ");
    fmt.printDec(@truncate(stats.spurious_count));
    vga.write("\n  Last tick:      ");
    fmt.printDec(@truncate(stats.last_tick));
    vga.write("\n  Enabled:        ");
    if (stats.enabled) vga.write("yes") else vga.write("no");
    vga.write("\n  Bottom half:    ");
    if (stats.bottom_half != null) vga.write("registered") else vga.write("none");
    vga.write("\n  Handlers (");
    fmt.printDec(stats.handler_count);
    vga.write("):\n");

    for (&stats.handlers) |*h| {
        if (h.active) {
            vga.write("    - ");
            vga.write(h.name[0..h.name_len]);
            vga.write(" (calls=");
            fmt.printDec(@truncate(h.call_count));
            vga.write(")\n");
        }
    }
}
