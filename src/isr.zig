// CPU例外ハンドラ — GPF, ページフォルト等のトラップ処理

const vga = @import("vga.zig");
const serial = @import("serial.zig");

const exception_names = [_][]const u8{
    "Division by Zero",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 FP Error",
    "Alignment Check",
    "Machine Check",
    "SIMD FP Exception",
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
            : [cr2] "=r" (-> u32),
        );
        vga.write("  Fault addr: 0x");
        printHex(cr2);
        vga.putChar('\n');
    }

    if (error_code != 0) {
        vga.write("  Error code: 0x");
        printHex(error_code);
        vga.putChar('\n');
    }

    serial.write("[EXCEPTION] #");
    serial.writeHex(vector);
    serial.write(" err=");
    serial.writeHex(error_code);
    serial.write("\n");

    vga.setColor(.yellow, .black);
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
