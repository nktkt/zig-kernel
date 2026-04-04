// 簡易シェル — コマンドライン入力と実行

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const heap = @import("heap.zig");
const paging = @import("paging.zig");
const rtc = @import("rtc.zig");
const serial = @import("serial.zig");
const idt = @import("idt.zig");

const MAX_INPUT = 256;
var input_buf: [MAX_INPUT]u8 = undefined;
var input_len: usize = 0;

// 最後に alloc したアドレスを記録
var last_page_alloc: ?usize = null;
var last_heap_alloc: ?[*]u8 = null;

pub fn init() void {
    input_len = 0;
    printPrompt();
}

pub fn handleKey(char: u8) void {
    switch (char) {
        '\n' => {
            vga.putChar('\n');
            if (input_len > 0) {
                execute(input_buf[0..input_len]);
            }
            input_len = 0;
            printPrompt();
        },
        8 => { // backspace
            if (input_len > 0) {
                input_len -= 1;
                vga.backspace();
            }
        },
        else => {
            if (input_len < MAX_INPUT - 1) {
                input_buf[input_len] = char;
                input_len += 1;
                vga.putChar(char);
            }
        },
    }
}

fn printPrompt() void {
    vga.setColor(.light_cyan, .black);
    vga.write("zig-os");
    vga.setColor(.light_grey, .black);
    vga.write("> ");
    vga.setColor(.white, .black);
}

fn execute(input: []const u8) void {
    const cmd = trim(input);
    if (cmd.len == 0) return;

    if (eql(cmd, "help")) {
        cmdHelp();
    } else if (eql(cmd, "clear")) {
        cmdClear();
    } else if (eql(cmd, "mem")) {
        cmdMem();
    } else if (eql(cmd, "alloc")) {
        cmdAlloc();
    } else if (eql(cmd, "free")) {
        cmdFree();
    } else if (eql(cmd, "malloc")) {
        cmdMalloc();
    } else if (eql(cmd, "mfree")) {
        cmdMfree();
    } else if (eql(cmd, "heap")) {
        cmdHeap();
    } else if (eql(cmd, "uptime")) {
        cmdUptime();
    } else if (eql(cmd, "ticks")) {
        cmdTicks();
    } else if (eql(cmd, "date")) {
        cmdDate();
    } else if (eql(cmd, "paging")) {
        cmdPaging();
    } else if (eql(cmd, "reboot")) {
        cmdReboot();
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Unknown command: ");
        vga.write(cmd);
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);
        vga.write("Type 'help' for available commands.\n");
    }
    vga.setColor(.white, .black);
}

fn cmdHelp() void {
    vga.setColor(.yellow, .black);
    vga.write("Available commands:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  help    - Show this message\n");
    vga.write("  clear   - Clear the screen\n");
    vga.write("  mem     - Physical memory status\n");
    vga.write("  heap    - Heap allocator status\n");
    vga.write("  alloc   - Allocate a 4KB page (PMM)\n");
    vga.write("  free    - Free last allocated page\n");
    vga.write("  malloc  - Allocate 64 bytes (heap)\n");
    vga.write("  mfree   - Free last heap allocation\n");
    vga.write("  uptime  - Show system uptime\n");
    vga.write("  ticks   - Show raw tick count\n");
    vga.write("  date    - Show current date/time\n");
    vga.write("  paging  - Show paging status\n");
    vga.write("  reboot  - Reboot the system\n");
}

fn cmdClear() void {
    vga.init();
}

fn cmdMem() void {
    pmm.printStatus();
}

fn cmdHeap() void {
    heap.printStatus();
}

fn cmdAlloc() void {
    if (pmm.alloc()) |addr| {
        last_page_alloc = addr;
        vga.setColor(.light_green, .black);
        vga.write("Allocated page at 0x");
        printHex(addr);
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Out of memory!\n");
    }
}

fn cmdFree() void {
    if (last_page_alloc) |addr| {
        pmm.free(addr);
        vga.setColor(.light_green, .black);
        vga.write("Freed page at 0x");
        printHex(addr);
        vga.putChar('\n');
        last_page_alloc = null;
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Nothing to free. Use 'alloc' first.\n");
    }
}

fn cmdMalloc() void {
    if (heap.alloc(64)) |ptr| {
        last_heap_alloc = ptr;
        vga.setColor(.light_green, .black);
        vga.write("Allocated 64 bytes at 0x");
        printHex(@intFromPtr(ptr));
        vga.putChar('\n');
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Heap allocation failed!\n");
    }
}

fn cmdMfree() void {
    if (last_heap_alloc) |ptr| {
        heap.free(ptr);
        vga.setColor(.light_green, .black);
        vga.write("Freed heap allocation at 0x");
        printHex(@intFromPtr(ptr));
        vga.putChar('\n');
        last_heap_alloc = null;
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Nothing to free. Use 'malloc' first.\n");
    }
}

fn cmdUptime() void {
    pit.printUptime();
}

fn cmdTicks() void {
    vga.setColor(.light_grey, .black);
    vga.write("Ticks: ");
    pmm.printNum(@truncate(pit.getTicks()));
    vga.putChar('\n');
}

fn cmdDate() void {
    rtc.printDateTime();
}

fn cmdPaging() void {
    paging.printStatus();
}

fn cmdReboot() void {
    vga.setColor(.yellow, .black);
    vga.write("Rebooting...\n");
    idt.outb(0x64, 0xFE);
}

// ---- ユーティリティ ----

fn printHex(val: usize) void {
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

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') : (end -= 1) {}
    return s[start..end];
}
