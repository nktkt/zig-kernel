// CPU例外ハンドラ — GPF, ページフォルト等のトラップ処理 + panic + スタックトレース (64-bit)

const vga = @import("vga.zig");
const serial = @import("serial.zig");

const exception_names = [_][]const u8{
    "Division by Zero",        // 0
    "Debug",                   // 1
    "NMI",                     // 2
    "Breakpoint",              // 3
    "Overflow",                // 4
    "Bound Range Exceeded",    // 5
    "Invalid Opcode",          // 6
    "Device Not Available",    // 7
    "Double Fault",            // 8
    "Coprocessor Overrun",     // 9
    "Invalid TSS",             // 10
    "Segment Not Present",     // 11
    "Stack-Segment Fault",     // 12
    "General Protection Fault", // 13
    "Page Fault",              // 14
    "Reserved",                // 15
    "x87 FP Error",            // 16
    "Alignment Check",         // 17
    "Machine Check",           // 18
    "SIMD FP Exception",       // 19
};

pub fn handler(vector: u32, error_code: u32) void {
    vga.setColor(.light_red, .black);
    vga.write("\n!!! EXCEPTION: ");
    if (vector < exception_names.len) {
        vga.write(exception_names[vector]);
    } else {
        vga.write("Unknown");
    }
    vga.write(" (#");
    printDec(vector);
    vga.write(")\n");

    if (vector == 14) {
        const cr2 = asm volatile ("mov %%cr2, %[cr2]"
            : [cr2] "=r" (-> u64),
        );
        vga.write("  Fault addr: 0x");
        printHex64(cr2);
        vga.putChar('\n');

        // Page fault error code bits
        vga.write("  Cause: ");
        if (error_code & 1 != 0) vga.write("protection ") else vga.write("not-present ");
        if (error_code & 2 != 0) vga.write("write ") else vga.write("read ");
        if (error_code & 4 != 0) vga.write("user") else vga.write("kernel");
        vga.putChar('\n');
    }

    if (error_code != 0) {
        vga.write("  Error code: 0x");
        printHex(error_code);
        vga.putChar('\n');
    }

    // スタックトレース (RBP chain)
    vga.setColor(.yellow, .black);
    vga.write("  Stack trace:\n");
    vga.setColor(.light_grey, .black);
    var rbp: u64 = asm volatile ("mov %%rbp, %[rbp]"
        : [rbp] "=r" (-> u64),
    );
    var depth: usize = 0;
    while (rbp != 0 and depth < 10) {
        // rbp+8 = return address
        const frame: [*]const u64 = @ptrFromInt(@as(usize, @truncate(rbp)));
        // 安全チェック: カーネルメモリ範囲内か
        if (rbp < 0x100000 or rbp >= 0x8000000) break;
        const ret_addr = frame[1];
        if (ret_addr == 0) break;
        vga.write("    [");
        printDec32(@truncate(depth));
        vga.write("] 0x");
        printHex64(ret_addr);
        vga.putChar('\n');
        rbp = frame[0]; // 前のフレームの RBP
        depth += 1;
    }

    serial.write("[EXCEPTION] #");
    serial.writeHex(vector);
    serial.write(" err=");
    serial.writeHex(error_code);
    serial.write("\n");

    halt();
}

/// カーネルパニック — 致命的エラーで停止
pub fn panic(msg: []const u8) void {
    vga.setColor(.light_red, .black);
    vga.write("\n!!! KERNEL PANIC: ");
    vga.write(msg);
    vga.putChar('\n');

    serial.write("[PANIC] ");
    serial.write(msg);
    serial.write("\n");

    // スタックトレース
    vga.setColor(.yellow, .black);
    vga.write("  Stack trace:\n");
    vga.setColor(.light_grey, .black);
    var rbp: u64 = asm volatile ("mov %%rbp, %[rbp]"
        : [rbp] "=r" (-> u64),
    );
    var depth: usize = 0;
    while (rbp != 0 and depth < 10) {
        if (rbp < 0x100000 or rbp >= 0x8000000) break;
        const frame: [*]const u64 = @ptrFromInt(@as(usize, @truncate(rbp)));
        const ret_addr = frame[1];
        if (ret_addr == 0) break;
        vga.write("    [");
        printDec32(@truncate(depth));
        vga.write("] 0x");
        printHex64(ret_addr);
        vga.putChar('\n');
        serial.write("  [");
        serial.writeHex(@truncate(ret_addr));
        serial.write("]\n");
        rbp = frame[0];
        depth += 1;
    }

    halt();
}

fn halt() void {
    vga.setColor(.dark_grey, .black);
    vga.write("  System halted.\n");
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

fn printHex(val: u32) void {
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

fn printHex64(val: u64) void {
    const hex = "0123456789ABCDEF";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@truncate(v & 0xF)];
        v >>= 4;
    }
    vga.write(&buf);
}

fn printDec(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDec32(n: u32) void {
    printDec(n);
}
