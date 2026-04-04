// Interrupt Descriptor Table — 割り込みハンドラの登録と PIC 制御

const vga = @import("vga.zig");
const keyboard = @import("keyboard.zig");
const pit = @import("pit.zig");
const task = @import("task.zig");

const IdtEntry = packed struct {
    base_low: u16,
    sel: u16,
    zero: u8 = 0,
    flags: u8,
    base_high: u16,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u32,
};

var idt_entries: [256]IdtEntry = @splat(IdtEntry{
    .base_low = 0,
    .sel = 0,
    .zero = 0,
    .flags = 0,
    .base_high = 0,
});
var idt_ptr: IdtPtr = undefined;

fn setGate(n: u8, base: u32) void {
    idt_entries[n] = .{
        .base_low = @truncate(base & 0xFFFF),
        .base_high = @truncate((base >> 16) & 0xFFFF),
        .sel = 0x08,
        .flags = 0x8E, // present, DPL=0, 32-bit interrupt gate
    };
}

fn setGateUser(n: u8, base: u32) void {
    idt_entries[n] = .{
        .base_low = @truncate(base & 0xFFFF),
        .base_high = @truncate((base >> 16) & 0xFFFF),
        .sel = 0x08,
        .flags = 0xEE, // present, DPL=3, 32-bit interrupt gate
    };
}

fn picRemap() void {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20);
    outb(0xA1, 0x28);
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    outb(0x21, 0xFC);
    outb(0xA1, 0xFF);
}

pub fn init() void {
    picRemap();
    setGate(32, @intFromPtr(&irq0Stub));
    setGate(33, @intFromPtr(&irq1Stub));
    setGateUser(0x80, @intFromPtr(&syscallStub)); // INT 0x80 (DPL=3)

    idt_ptr = .{
        .limit = @as(u16, @sizeOf(@TypeOf(idt_entries))) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile ("lidt (%[idt])"
        :
        : [idt] "r" (&idt_ptr),
    );
    asm volatile ("sti");
}

// IRQ0: タイマー割り込み (コンテキストスイッチ対応)
fn irq0Stub() callconv(.naked) void {
    asm volatile (
        \\pusha
        \\mov %%esp, %%eax
        \\push %%eax
        \\call irq0Dispatch
        \\mov %%eax, %%esp
        \\popa
        \\iret
    );
}

export fn irq0Dispatch(esp: u32) u32 {
    pit.tick();
    outb(0x20, 0x20);
    return task.timerSchedule(esp);
}

// IRQ1: キーボード
fn irq1Stub() callconv(.naked) void {
    asm volatile (
        \\pusha
        \\call irq1Dispatch
        \\popa
        \\iret
    );
}

export fn irq1Dispatch() void {
    keyboard.handleIrq();
    outb(0x20, 0x20);
}

// INT 0x80: システムコール
fn syscallStub() callconv(.naked) void {
    asm volatile (
        \\push %%edx
        \\push %%ecx
        \\push %%ebx
        \\push %%eax
        \\call syscallDispatch
        \\add $16, %%esp
        \\iret
    );
}

pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}
