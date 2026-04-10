// Interrupt Descriptor Table — 64-bit IDT entries (16 bytes each)

const vga = @import("vga.zig");
const keyboard = @import("keyboard.zig");
const pit = @import("pit.zig");
const task = @import("task.zig");
const isr = @import("isr.zig");

const IdtEntry = packed struct {
    offset_low: u16, // bits 0-15 of handler
    selector: u16, // code segment selector
    ist: u8, // IST index (bits 0-2), rest zero
    flags: u8, // type + DPL + Present
    offset_mid: u16, // bits 16-31 of handler
    offset_high: u32, // bits 32-63 of handler
    reserved: u32, // must be zero
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt_entries: [256]IdtEntry = @splat(IdtEntry{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .flags = 0,
    .offset_mid = 0,
    .offset_high = 0,
    .reserved = 0,
});
var idt_ptr: IdtPtr = undefined;

fn setGate(n: u8, base: u64) void {
    idt_entries[n] = .{
        .offset_low = @truncate(base & 0xFFFF),
        .selector = 0x08,
        .ist = 0,
        .flags = 0x8E, // present, DPL=0, 64-bit interrupt gate
        .offset_mid = @truncate((base >> 16) & 0xFFFF),
        .offset_high = @truncate((base >> 32) & 0xFFFFFFFF),
        .reserved = 0,
    };
}

fn setGateUser(n: u8, base: u64) void {
    idt_entries[n] = .{
        .offset_low = @truncate(base & 0xFFFF),
        .selector = 0x08,
        .ist = 0,
        .flags = 0xEE, // present, DPL=3, 64-bit interrupt gate
        .offset_mid = @truncate((base >> 16) & 0xFFFF),
        .offset_high = @truncate((base >> 32) & 0xFFFFFFFF),
        .reserved = 0,
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

    // CPU 例外 (ISR 0-19)
    setGate(0, @intFromPtr(&isr0Stub));
    setGate(1, @intFromPtr(&isr1Stub));
    setGate(2, @intFromPtr(&isr2Stub));
    setGate(3, @intFromPtr(&isr3Stub));
    setGate(4, @intFromPtr(&isr4Stub));
    setGate(5, @intFromPtr(&isr5Stub));
    setGate(6, @intFromPtr(&isr6Stub));
    setGate(7, @intFromPtr(&isr7Stub));
    setGate(8, @intFromPtr(&isr8Stub));
    setGate(10, @intFromPtr(&isr10Stub));
    setGate(11, @intFromPtr(&isr11Stub));
    setGate(12, @intFromPtr(&isr12Stub));
    setGate(13, @intFromPtr(&isr13Stub));
    setGate(14, @intFromPtr(&isr14Stub));
    setGate(16, @intFromPtr(&isr16Stub));
    setGate(17, @intFromPtr(&isr17Stub));
    setGate(18, @intFromPtr(&isr18Stub));
    setGate(19, @intFromPtr(&isr19Stub));

    // IRQ + syscall
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
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rsi
        \\push %%rdi
        \\push %%rbp
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\mov %%rsp, %%rdi
        \\call irq0Dispatch64
        \\mov %%rax, %%rsp
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rbp
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\iretq
    );
}

export fn irq0Dispatch64(rsp: u64) u64 {
    pit.tick();
    outb(0x20, 0x20);
    return task.timerSchedule(rsp);
}

// IRQ1: キーボード
fn irq1Stub() callconv(.naked) void {
    asm volatile (
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rsi
        \\push %%rdi
        \\push %%rbp
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\call irq1Dispatch
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rbp
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\iretq
    );
}

export fn irq1Dispatch() void {
    keyboard.handleIrq();
    outb(0x20, 0x20);
}

// INT 0x80: システムコール
// In 64-bit: args in RAX(num), RBX(a1), RCX(a2), RDX(a3)
fn syscallStub() callconv(.naked) void {
    asm volatile (
        \\push %%rdx
        \\push %%rcx
        \\push %%rbx
        \\push %%rax
        \\mov %%rax, %%rdi
        \\mov %%rbx, %%rsi
        \\mov %%rcx, %%rdx
        // RDX already has arg3 but we pushed it; reload from stack
        \\mov 24(%%rsp), %%rcx
        \\call syscallDispatch64
        \\add $8, %%rsp
        \\pop %%rbx
        \\pop %%rcx
        \\pop %%rdx
        \\iretq
    );
}

// CPU例外スタブ (64-bit: no pusha, use individual pushes; halt after handler)
fn isr0Stub() callconv(.naked) void {
    asm volatile ("push $0\n push $0\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b");
}
fn isr6Stub() callconv(.naked) void {
    asm volatile ("push $0\n push $6\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b");
}
fn isr8Stub() callconv(.naked) void {
    asm volatile ("push $8\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b");
}
fn isr13Stub() callconv(.naked) void {
    asm volatile ("push $13\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b");
}
fn isr14Stub() callconv(.naked) void {
    asm volatile ("push $14\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b");
}
// Additional exception stubs
fn isr1Stub() callconv(.naked) void { asm volatile ("push $0\n push $1\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr2Stub() callconv(.naked) void { asm volatile ("push $0\n push $2\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr3Stub() callconv(.naked) void { asm volatile ("push $0\n push $3\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr4Stub() callconv(.naked) void { asm volatile ("push $0\n push $4\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr5Stub() callconv(.naked) void { asm volatile ("push $0\n push $5\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr7Stub() callconv(.naked) void { asm volatile ("push $0\n push $7\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr16Stub() callconv(.naked) void { asm volatile ("push $0\n push $16\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr18Stub() callconv(.naked) void { asm volatile ("push $0\n push $18\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr19Stub() callconv(.naked) void { asm volatile ("push $0\n push $19\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr10Stub() callconv(.naked) void { asm volatile ("push $10\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr11Stub() callconv(.naked) void { asm volatile ("push $11\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr12Stub() callconv(.naked) void { asm volatile ("push $12\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }
fn isr17Stub() callconv(.naked) void { asm volatile ("push $17\n call isrCommonHandler\n cli\n 1: hlt\n jmp 1b"); }

export fn isrCommonHandler(vector: u64, error_code: u64) void {
    isr.handler(@truncate(vector), @truncate(error_code));
}

// ---- I/O ポート操作 ----
// Port I/O instructions are the same in 64-bit mode

pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
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
