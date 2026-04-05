// Extended CMOS/RTC — CMOS RAM の拡張レジスタ読み書き
// ブートカウント、拡張メモリ情報、バッテリーステータス等

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");

const CMOS_ADDR = 0x70;
const CMOS_DATA = 0x71;

// CMOS RAM オフセット
const BOOT_COUNT_OFFSET = 0x20; // ブートカウント格納用 (カスタム)
const EXT_MEM_LOW = 0x17; // 拡張メモリ (KB, low byte)
const EXT_MEM_HIGH = 0x18; // 拡張メモリ (KB, high byte)
const STATUS_REG_A = 0x0A;
const STATUS_REG_B = 0x0B;
const STATUS_REG_D = 0x0D; // バッテリーステータス

var initialized: bool = false;
var boot_count: u8 = 0;

/// CMOS レジスタを NMI-safe に読む
fn readCmos(reg: u8) u8 {
    // NMI を無効化しながら読む (ビット7 = NMI disable)
    idt.outb(CMOS_ADDR, reg | 0x80);
    return idt.inb(CMOS_DATA);
}

/// CMOS レジスタに NMI-safe に書く
fn writeCmos(reg: u8, val: u8) void {
    idt.outb(CMOS_ADDR, reg | 0x80);
    idt.outb(CMOS_DATA, val);
}

/// CMOS が更新中かどうか
fn isUpdating() bool {
    return (readCmos(STATUS_REG_A) & 0x80) != 0;
}

pub fn init() void {
    // 更新中でないことを確認
    while (isUpdating()) {}

    // ブートカウントを読み出してインクリメント
    boot_count = readCmos(BOOT_COUNT_OFFSET);
    initialized = true;
}

/// ブートカウントを取得
pub fn getBootCount() u8 {
    return boot_count;
}

/// ブートカウントをインクリメントして CMOS に保存
pub fn incrBootCount() void {
    if (boot_count < 255) {
        boot_count += 1;
    }
    writeCmos(BOOT_COUNT_OFFSET, boot_count);
}

/// 拡張メモリサイズ (KB) を取得
pub fn getExtMemoryKB() u16 {
    while (isUpdating()) {}
    const low: u16 = readCmos(EXT_MEM_LOW);
    const high: u16 = readCmos(EXT_MEM_HIGH);
    return (high << 8) | low;
}

/// バッテリーステータスを取得
/// true: バッテリー正常 (CMOS データ有効)
pub fn isBatteryOk() bool {
    return (readCmos(STATUS_REG_D) & 0x80) != 0;
}

/// CMOS 情報を VGA に表示
pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("CMOS Information:\n");
    vga.setColor(.light_grey, .black);

    // バッテリーステータス
    vga.write("  Battery:     ");
    if (isBatteryOk()) {
        vga.setColor(.light_green, .black);
        vga.write("OK\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("LOW/DEAD\n");
    }
    vga.setColor(.light_grey, .black);

    // 拡張メモリ
    vga.write("  Ext Memory:  ");
    const ext_kb = getExtMemoryKB();
    pmm.printNum(ext_kb);
    vga.write(" KB");
    if (ext_kb >= 1024) {
        vga.write(" (");
        pmm.printNum(ext_kb / 1024);
        vga.write(" MB)");
    }
    vga.putChar('\n');

    // ブートカウント
    vga.write("  Boot Count:  ");
    pmm.printNum(boot_count);
    vga.putChar('\n');

    // ステータスレジスタ
    vga.write("  Status A:    0x");
    fmt.printHex8(readCmos(STATUS_REG_A));
    vga.putChar('\n');
    vga.write("  Status B:    0x");
    fmt.printHex8(readCmos(STATUS_REG_B));
    vga.putChar('\n');
}
