// Panic Screen — カーネルパニック時のブルースクリーン表示
// レジスタダンプ、スタックトレース、エラーメッセージを表示

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;
const VGA_BUFFER = 0xB8000;

/// レジスタダンプ構造体
pub const Registers = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    ebp: u32 = 0,
    esp: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    cr0: u32 = 0,
    cr2: u32 = 0,
    cr3: u32 = 0,
};

/// 画面全体を指定色で塗りつぶす
fn fillScreen(fg: vga.Color, bg: vga.Color) void {
    const buf: [*]volatile u16 = @ptrFromInt(VGA_BUFFER);
    const attr: u8 = @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
    const entry: u16 = @as(u16, ' ') | (@as(u16, attr) << 8);
    for (0..VGA_HEIGHT * VGA_WIDTH) |i| {
        buf[i] = entry;
    }
}

/// 指定位置に文字列を書く (直接VGAバッファ操作)
fn writeAt(r: usize, c: usize, fg: vga.Color, bg: vga.Color, msg: []const u8) void {
    const buf: [*]volatile u16 = @ptrFromInt(VGA_BUFFER);
    const attr: u8 = @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
    var col = c;
    for (msg) |ch| {
        if (col >= VGA_WIDTH) break;
        buf[r * VGA_WIDTH + col] = @as(u16, ch) | (@as(u16, attr) << 8);
        col += 1;
    }
}

/// 指定位置に 32bit hex 値を書く
fn writeHexAt(r: usize, c: usize, fg: vga.Color, bg: vga.Color, val: u32) void {
    const hex = "0123456789ABCDEF";
    const buf: [*]volatile u16 = @ptrFromInt(VGA_BUFFER);
    const attr: u8 = @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
    var v = val;
    var col = c + 7; // 8桁の右端から
    var digits: usize = 8;
    while (digits > 0) : (digits -= 1) {
        if (col < VGA_WIDTH) {
            buf[r * VGA_WIDTH + col] = @as(u16, hex[v & 0xF]) | (@as(u16, attr) << 8);
        }
        v >>= 4;
        if (col > 0) col -= 1;
    }
}

/// 現在のレジスタ値を取得
pub fn captureRegisters() Registers {
    var regs: Registers = .{};

    regs.ebp = asm volatile ("" : [ebp] "={ebp}" (-> u32));
    regs.esp = asm volatile ("" : [esp] "={esp}" (-> u32));

    // CR レジスタ
    regs.cr0 = asm volatile ("mov %%cr0, %[cr0]" : [cr0] "=r" (-> u32));
    regs.cr2 = asm volatile ("mov %%cr2, %[cr2]" : [cr2] "=r" (-> u32));
    regs.cr3 = asm volatile ("mov %%cr3, %[cr3]" : [cr3] "=r" (-> u32));

    return regs;
}

/// パニック画面を表示 (Blue Screen of Death)
pub fn show(title: []const u8, msg: []const u8) void {
    // 割り込み無効化
    asm volatile ("cli");

    // シリアルに先に出力
    serial.write("\n!!! KERNEL PANIC !!!\n");
    serial.write("Title: ");
    serial.write(title);
    serial.write("\nMessage: ");
    serial.write(msg);
    serial.putChar('\n');

    // レジスタキャプチャ
    const regs = captureRegisters();

    // 画面を青で塗りつぶす
    fillScreen(.white, .blue);

    // ヘッダー
    writeAt(1, 2, .white, .blue, "*** KERNEL PANIC ***");

    // タイトル
    writeAt(3, 2, .yellow, .blue, title);

    // メッセージ
    writeAt(5, 2, .light_grey, .blue, msg);

    // レジスタダンプ
    writeAt(7, 2, .white, .blue, "Register Dump:");

    writeAt(8, 4, .light_cyan, .blue, "EAX=0x");
    writeHexAt(8, 10, .light_cyan, .blue, regs.eax);
    writeAt(8, 22, .light_cyan, .blue, "EBX=0x");
    writeHexAt(8, 28, .light_cyan, .blue, regs.ebx);
    writeAt(8, 40, .light_cyan, .blue, "ECX=0x");
    writeHexAt(8, 46, .light_cyan, .blue, regs.ecx);
    writeAt(8, 58, .light_cyan, .blue, "EDX=0x");
    writeHexAt(8, 64, .light_cyan, .blue, regs.edx);

    writeAt(9, 4, .light_cyan, .blue, "ESI=0x");
    writeHexAt(9, 10, .light_cyan, .blue, regs.esi);
    writeAt(9, 22, .light_cyan, .blue, "EDI=0x");
    writeHexAt(9, 28, .light_cyan, .blue, regs.edi);
    writeAt(9, 40, .light_cyan, .blue, "EBP=0x");
    writeHexAt(9, 46, .light_cyan, .blue, regs.ebp);
    writeAt(9, 58, .light_cyan, .blue, "ESP=0x");
    writeHexAt(9, 64, .light_cyan, .blue, regs.esp);

    writeAt(11, 2, .white, .blue, "Control Registers:");
    writeAt(12, 4, .light_cyan, .blue, "CR0=0x");
    writeHexAt(12, 10, .light_cyan, .blue, regs.cr0);
    writeAt(12, 22, .light_cyan, .blue, "CR2=0x");
    writeHexAt(12, 28, .light_cyan, .blue, regs.cr2);
    writeAt(12, 40, .light_cyan, .blue, "CR3=0x");
    writeHexAt(12, 46, .light_cyan, .blue, regs.cr3);

    // スタックダンプ (EBP ベースのフレームウォーク)
    writeAt(14, 2, .white, .blue, "Stack Trace (EBP chain):");
    var frame_ptr: ?[*]const u32 = @ptrFromInt(regs.ebp);
    var frame_row: usize = 15;
    var frame_count: usize = 0;
    while (frame_ptr != null and frame_count < 6 and frame_row < VGA_HEIGHT - 2) {
        const fp = frame_ptr.?;
        // fp[0] = 前の EBP, fp[1] = リターンアドレス
        const return_addr = fp[1];
        writeAt(frame_row, 4, .light_grey, .blue, "Frame ");
        writeAt(frame_row, 10, .light_grey, .blue, ": 0x");
        writeHexAt(frame_row, 14, .light_grey, .blue, return_addr);

        // 次のフレーム
        const next_ebp = fp[0];
        if (next_ebp == 0 or next_ebp < 0x1000) break;
        frame_ptr = @ptrFromInt(next_ebp);
        frame_row += 1;
        frame_count += 1;
    }

    // フッター
    writeAt(VGA_HEIGHT - 2, 2, .yellow, .blue, "System halted. Please reboot.");
    writeAt(VGA_HEIGHT - 1, 2, .dark_grey, .blue, "Press reset button or power cycle.");

    // システム停止
    while (true) {
        asm volatile ("hlt");
    }
}

/// ショートカット: アサーション失敗
pub fn assertFail(condition: []const u8) void {
    show("Assertion Failed", condition);
}

/// ショートカット: 一般的なカーネルパニック
pub fn panic(msg: []const u8) void {
    show("Kernel Panic", msg);
}
