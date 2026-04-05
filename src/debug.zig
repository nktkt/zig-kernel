// Debug utilities -- register dumps, memory dumps, assertions, tracing
//
// Provides low-level debugging tools for kernel development:
//   - CPU register dump (general purpose, control, flags)
//   - Stack dump
//   - Arbitrary memory hexdump
//   - Software breakpoint (INT 3)
//   - Function entry/exit tracing
//   - Serial log with timestamps
//   - Kernel assertions

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const idt = @import("idt.zig");

// ---- Register dump ----

/// Read and display all general-purpose registers plus CR0-CR4 and EFLAGS.
pub fn dumpRegisters() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Register Dump ===\n");
    vga.setColor(.light_grey, .black);

    // Read general-purpose registers via inline asm.
    // We read EBP and ESP specially since they change at each call frame.
    const eax = asm volatile ("" : [r] "={eax}" (-> u32));
    const ebx = asm volatile ("" : [r] "={ebx}" (-> u32));
    const ecx = asm volatile ("" : [r] "={ecx}" (-> u32));
    const edx = asm volatile ("" : [r] "={edx}" (-> u32));
    const esi = asm volatile ("" : [r] "={esi}" (-> u32));
    const edi = asm volatile ("" : [r] "={edi}" (-> u32));
    const ebp = asm volatile ("" : [r] "={ebp}" (-> u32));
    const esp = asm volatile ("" : [r] "={esp}" (-> u32));

    vga.write("  EAX=0x");
    printHex32(eax);
    vga.write("  EBX=0x");
    printHex32(ebx);
    vga.putChar('\n');
    vga.write("  ECX=0x");
    printHex32(ecx);
    vga.write("  EDX=0x");
    printHex32(edx);
    vga.putChar('\n');
    vga.write("  ESI=0x");
    printHex32(esi);
    vga.write("  EDI=0x");
    printHex32(edi);
    vga.putChar('\n');
    vga.write("  EBP=0x");
    printHex32(ebp);
    vga.write("  ESP=0x");
    printHex32(esp);
    vga.putChar('\n');

    // EFLAGS
    const eflags = readEflags();
    vga.write("  EFLAGS=0x");
    printHex32(eflags);
    vga.write(" [");
    if (eflags & (1 << 0) != 0) vga.write("CF ");
    if (eflags & (1 << 2) != 0) vga.write("PF ");
    if (eflags & (1 << 6) != 0) vga.write("ZF ");
    if (eflags & (1 << 7) != 0) vga.write("SF ");
    if (eflags & (1 << 9) != 0) vga.write("IF ");
    if (eflags & (1 << 10) != 0) vga.write("DF ");
    if (eflags & (1 << 11) != 0) vga.write("OF ");
    vga.write("]\n");

    // Control registers
    const cr0 = readCr0();
    const cr2 = readCr2();
    const cr3 = readCr3();
    const cr4 = readCr4();

    vga.write("  CR0=0x");
    printHex32(cr0);
    vga.write(" [");
    if (cr0 & (1 << 0) != 0) vga.write("PE ");
    if (cr0 & (1 << 31) != 0) vga.write("PG ");
    if (cr0 & (1 << 16) != 0) vga.write("WP ");
    vga.write("]\n");

    vga.write("  CR2=0x");
    printHex32(cr2);
    vga.write(" (page fault addr)\n");

    vga.write("  CR3=0x");
    printHex32(cr3);
    vga.write(" (page dir)\n");

    vga.write("  CR4=0x");
    printHex32(cr4);
    vga.putChar('\n');

    // Also log to serial
    serial.write("[DEBUG] Register dump complete\n");
}

fn readEflags() u32 {
    return asm volatile (
        \\pushfd
        \\pop %%eax
        : [r] "={eax}" (-> u32),
    );
}

fn readCr0() u32 {
    return asm volatile ("mov %%cr0, %[r]"
        : [r] "=r" (-> u32),
    );
}

fn readCr2() u32 {
    return asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u32),
    );
}

fn readCr3() u32 {
    return asm volatile ("mov %%cr3, %[r]"
        : [r] "=r" (-> u32),
    );
}

fn readCr4() u32 {
    return asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u32),
    );
}

// ---- Stack dump ----

/// Dump n 32-bit words from the current stack pointer.
pub fn dumpStack(n: usize) void {
    const esp = asm volatile ("" : [r] "={esp}" (-> u32));
    vga.setColor(.yellow, .black);
    vga.write("=== Stack Dump (ESP=0x");
    printHex32(esp);
    vga.write(") ===\n");
    vga.setColor(.light_grey, .black);

    const stack_ptr: [*]const u32 = @ptrFromInt(esp);
    const words = @min(n, 64); // cap at 64 words for safety

    for (0..words) |i| {
        const addr = esp + @as(u32, @truncate(i * 4));
        vga.write("  0x");
        printHex32(addr);
        vga.write(": 0x");
        printHex32(stack_ptr[i]);
        vga.putChar('\n');
    }
}

// ---- Memory hexdump ----

/// Dump `len` bytes starting at `addr` in classic hexdump format.
/// Displays 16 bytes per line with hex values and ASCII representation.
pub fn dumpMemory(addr: u32, len: usize) void {
    const safe_len = @min(len, 512); // cap for safety

    vga.setColor(.yellow, .black);
    vga.write("=== Memory Dump (0x");
    printHex32(addr);
    vga.write(", ");
    printDec(safe_len);
    vga.write(" bytes) ===\n");
    vga.setColor(.light_grey, .black);

    const ptr: [*]const u8 = @ptrFromInt(addr);
    var offset: usize = 0;

    while (offset < safe_len) {
        // Address
        vga.write("  ");
        printHex32(addr + @as(u32, @truncate(offset)));
        vga.write(": ");

        // Hex bytes
        const line_len = @min(16, safe_len - offset);
        for (0..16) |i| {
            if (i == 8) vga.putChar(' '); // extra space at midpoint
            if (i < line_len) {
                printHex8(ptr[offset + i]);
                vga.putChar(' ');
            } else {
                vga.write("   ");
            }
        }

        // ASCII
        vga.write(" |");
        for (0..line_len) |i| {
            const c = ptr[offset + i];
            if (c >= 0x20 and c < 0x7F) {
                vga.putChar(c);
            } else {
                vga.putChar('.');
            }
        }
        vga.write("|\n");

        offset += 16;
    }
}

// ---- Software breakpoint ----

/// Execute INT 3 (software breakpoint).
/// Useful when running under a debugger (GDB, BOCHS debugger).
pub fn breakpoint() void {
    serial.write("[DEBUG] Breakpoint hit\n");
    asm volatile ("int $0x03");
}

// ---- Function tracing ----

const MAX_TRACE_DEPTH: usize = 16;
var trace_depth: usize = 0;
var tracing_enabled: bool = false;

/// Enable or disable function tracing output.
pub fn setTracing(enabled: bool) void {
    tracing_enabled = enabled;
    trace_depth = 0;
}

/// Log function entry. Call at the start of a function being traced.
pub fn traceEntry(comptime name: []const u8) void {
    if (!tracing_enabled) return;

    const tick = pit.getTicks();
    serial.write("[TRACE ");
    serialWriteDec(@truncate(tick));
    serial.write("] ");

    // Indent
    for (0..trace_depth) |_| serial.write("  ");
    serial.write("-> ");
    serial.write(name);
    serial.write("\n");

    if (trace_depth < MAX_TRACE_DEPTH) trace_depth += 1;
}

/// Log function exit. Call at the end of a function being traced.
pub fn traceExit(comptime name: []const u8) void {
    if (!tracing_enabled) return;

    if (trace_depth > 0) trace_depth -= 1;

    const tick = pit.getTicks();
    serial.write("[TRACE ");
    serialWriteDec(@truncate(tick));
    serial.write("] ");

    for (0..trace_depth) |_| serial.write("  ");
    serial.write("<- ");
    serial.write(name);
    serial.write("\n");
}

/// Shorthand: log entry of a function (use comptime name for no overhead
/// when tracing is disabled at compile time).
pub fn traceFunction(comptime name: []const u8) void {
    traceEntry(name);
}

// ---- Serial log with timestamp ----

/// Write a timestamped message to the serial port.
pub fn serialLog(comptime msg: []const u8) void {
    const tick = pit.getTicks();
    const secs: u32 = @truncate(tick / 1000);
    const ms: u32 = @truncate(tick % 1000);

    serial.write("[");
    serialWriteDecPadded(secs, 6);
    serial.write(".");
    serialWriteDecPadded(ms, 3);
    serial.write("] ");
    serial.write(msg);
    serial.write("\n");
}

/// Write a timestamped message with a runtime string suffix.
pub fn serialLogDyn(prefix: []const u8, suffix: []const u8) void {
    const tick = pit.getTicks();
    const secs: u32 = @truncate(tick / 1000);
    const ms: u32 = @truncate(tick % 1000);

    serial.write("[");
    serialWriteDecPadded(secs, 6);
    serial.write(".");
    serialWriteDecPadded(ms, 3);
    serial.write("] ");
    serial.write(prefix);
    serial.write(suffix);
    serial.write("\n");
}

// ---- Kernel assertion ----

/// Assert a condition. If false, display the message and halt.
pub fn assertKernel(condition: bool, comptime msg: []const u8) void {
    if (!condition) {
        // Display on VGA
        vga.setColor(.white, .red);
        vga.write("\n!!! KERNEL ASSERTION FAILED !!!\n");
        vga.write(msg);
        vga.write("\n");

        // Log to serial
        serial.write("[ASSERT] FAILED: ");
        serial.write(msg);
        serial.write("\n");

        // Dump registers for debugging context
        dumpRegisters();

        // Halt
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    }
}

// ---- Helpers ----

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| vga.putChar(c);
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
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

fn serialWriteDec(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialWriteDecPadded(n: u32, width: usize) void {
    // Count digits
    var digits: usize = 1;
    var tmp = n;
    while (tmp >= 10) {
        tmp /= 10;
        digits += 1;
    }
    var pad = width -| digits;
    while (pad > 0) {
        serial.putChar('0');
        pad -= 1;
    }
    serialWriteDec(n);
}
