// Local APIC and I/O APIC Driver
//
// Local APIC: processor-local interrupt controller at 0xFEE00000.
// I/O APIC: routes external interrupts to local APICs, typically at 0xFEC00000.
// Provides timer setup, EOI, IPI sending, and IRQ redirection.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- Local APIC Registers (offsets from base) ----

const LAPIC_ID: u32 = 0x020; // Local APIC ID (R/W)
const LAPIC_VER: u32 = 0x030; // Local APIC Version (RO)
const LAPIC_TPR: u32 = 0x080; // Task Priority (R/W)
const LAPIC_APR: u32 = 0x090; // Arbitration Priority (RO)
const LAPIC_PPR: u32 = 0x0A0; // Processor Priority (RO)
const LAPIC_EOI: u32 = 0x0B0; // End of Interrupt (WO)
const LAPIC_RRD: u32 = 0x0C0; // Remote Read (RO)
const LAPIC_LDR: u32 = 0x0D0; // Logical Destination (R/W)
const LAPIC_DFR: u32 = 0x0E0; // Destination Format (R/W)
const LAPIC_SVR: u32 = 0x0F0; // Spurious Interrupt Vector (R/W)
const LAPIC_ISR_BASE: u32 = 0x100; // In-Service Register (RO, 8 regs)
const LAPIC_TMR_BASE: u32 = 0x180; // Trigger Mode Register (RO, 8 regs)
const LAPIC_IRR_BASE: u32 = 0x200; // Interrupt Request Register (RO, 8 regs)
const LAPIC_ESR: u32 = 0x280; // Error Status (RO)
const LAPIC_ICR_LO: u32 = 0x300; // Interrupt Command Register low (R/W)
const LAPIC_ICR_HI: u32 = 0x310; // Interrupt Command Register high (R/W)
const LAPIC_TIMER_LVT: u32 = 0x320; // Timer LVT (R/W)
const LAPIC_THERMAL_LVT: u32 = 0x330; // Thermal Monitor LVT (R/W)
const LAPIC_PERF_LVT: u32 = 0x340; // Performance Counter LVT (R/W)
const LAPIC_LINT0: u32 = 0x350; // LINT0 (R/W)
const LAPIC_LINT1: u32 = 0x360; // LINT1 (R/W)
const LAPIC_ERROR_LVT: u32 = 0x370; // Error LVT (R/W)
const LAPIC_TIMER_ICR: u32 = 0x380; // Timer Initial Count (R/W)
const LAPIC_TIMER_CCR: u32 = 0x390; // Timer Current Count (RO)
const LAPIC_TIMER_DCR: u32 = 0x3E0; // Timer Divide Config (R/W)

// ---- SVR bits ----

const SVR_ENABLE: u32 = 0x100; // APIC software enable

// ---- Timer LVT bits ----

const TIMER_PERIODIC: u32 = 0x20000; // Periodic mode
const TIMER_MASKED: u32 = 0x10000; // Masked (disabled)

// ---- Timer divider values ----

pub const TimerDivider = enum(u8) {
    div_2 = 0x00,
    div_4 = 0x01,
    div_8 = 0x02,
    div_16 = 0x03,
    div_32 = 0x08,
    div_64 = 0x09,
    div_128 = 0x0A,
    div_1 = 0x0B,
};

// ---- ICR Delivery Mode ----

pub const DeliveryMode = enum(u3) {
    fixed = 0,
    lowest_priority = 1,
    smi = 2,
    nmi = 4,
    init = 5,
    startup = 6,
};

// ---- I/O APIC Registers ----

const IOAPIC_REGSEL: u32 = 0x00; // Register Select (index)
const IOAPIC_WIN: u32 = 0x10; // Register Window (data)

// I/O APIC register indices
const IOAPIC_ID: u32 = 0x00;
const IOAPIC_VER: u32 = 0x01;
const IOAPIC_ARB: u32 = 0x02;
const IOAPIC_REDTBL_BASE: u32 = 0x10;

// ---- State ----

var lapic_base: u32 = 0xFEE00000;
var ioapic_base: u32 = 0xFEC00000;
var lapic_present: bool = false;
var ioapic_present: bool = false;
var lapic_id: u8 = 0;
var lapic_version: u8 = 0;
var lapic_max_lvt: u8 = 0;
var ioapic_id: u8 = 0;
var ioapic_version: u8 = 0;
var ioapic_max_redir: u8 = 0;
var timer_calibrated: bool = false;
var ticks_per_ms: u32 = 0;

// ---- LAPIC MMIO read/write ----

fn lapicRead(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(lapic_base + offset);
    return ptr.*;
}

fn lapicWrite(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(lapic_base + offset);
    ptr.* = val;
}

// ---- I/O APIC MMIO read/write ----

fn ioapicRead(reg: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(ioapic_base + IOAPIC_REGSEL);
    const win: *volatile u32 = @ptrFromInt(ioapic_base + IOAPIC_WIN);
    sel.* = reg;
    return win.*;
}

fn ioapicWrite(reg: u32, val: u32) void {
    const sel: *volatile u32 = @ptrFromInt(ioapic_base + IOAPIC_REGSEL);
    const win: *volatile u32 = @ptrFromInt(ioapic_base + IOAPIC_WIN);
    sel.* = reg;
    win.* = val;
}

// ---- MSR access ----

fn readMsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return @as(u64, hi) << 32 | lo;
}

fn writeMsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
    );
}

// ---- Delay helper ----

fn delayMs(ms: u32) void {
    const start = pit.getTicks();
    while (pit.getTicks() - start < ms) {
        asm volatile ("pause");
    }
}

// ---- Public API ----

/// Detect APIC via MSR and initialize Local APIC.
pub fn init() void {
    lapic_present = false;
    ioapic_present = false;

    // Check APIC base MSR (IA32_APIC_BASE = 0x1B)
    const apic_msr = readMsr(0x1B);
    const base_phys = apic_msr & 0xFFFFF000;

    if (base_phys == 0) {
        serial.write("[APIC] No APIC base in MSR\n");
        return;
    }

    lapic_base = @truncate(base_phys);

    // Read APIC ID and version
    lapic_id = @truncate(lapicRead(LAPIC_ID) >> 24);
    const ver_reg = lapicRead(LAPIC_VER);
    lapic_version = @truncate(ver_reg);
    lapic_max_lvt = @truncate((ver_reg >> 16) + 1);

    // Enable APIC: set SVR enable bit and spurious vector 0xFF
    lapicWrite(LAPIC_SVR, SVR_ENABLE | 0xFF);

    // Set task priority to 0 (accept all interrupts)
    lapicWrite(LAPIC_TPR, 0);

    // Set flat model for logical destination
    lapicWrite(LAPIC_DFR, 0xFFFFFFFF); // flat model
    lapicWrite(LAPIC_LDR, (lapicRead(LAPIC_LDR) & 0x00FFFFFF) | (@as(u32, 1) << 24));

    // Mask LINT0 and LINT1
    lapicWrite(LAPIC_LINT0, TIMER_MASKED);
    lapicWrite(LAPIC_LINT1, TIMER_MASKED);

    // Mask timer initially
    lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED);

    lapic_present = true;

    // Try to detect I/O APIC (default address)
    initIoApic();

    serial.write("[APIC] Local APIC ID=");
    serialWriteDec(lapic_id);
    serial.write(" ver=0x");
    serialWriteHex8(lapic_version);
    serial.write(" LVT=");
    serialWriteDec(lapic_max_lvt);
    serial.write("\n");
}

fn initIoApic() void {
    // Read I/O APIC ID register to verify presence
    const id_reg = ioapicRead(IOAPIC_ID);
    ioapic_id = @truncate(id_reg >> 24);

    const ver_reg = ioapicRead(IOAPIC_VER);
    ioapic_version = @truncate(ver_reg);
    ioapic_max_redir = @truncate(ver_reg >> 16);

    // If version reads as 0 or 0xFF, probably not present
    if (ioapic_version == 0 or ioapic_version == 0xFF) {
        serial.write("[APIC] No I/O APIC at default address\n");
        return;
    }

    ioapic_present = true;

    serial.write("[APIC] I/O APIC ID=");
    serialWriteDec(ioapic_id);
    serial.write(" ver=0x");
    serialWriteHex8(ioapic_version);
    serial.write(" entries=");
    serialWriteDec(ioapic_max_redir + 1);
    serial.write("\n");
}

/// Send End-Of-Interrupt to the Local APIC.
pub fn sendEOI() void {
    if (!lapic_present) return;
    lapicWrite(LAPIC_EOI, 0);
}

/// Enable the Local APIC.
pub fn enable() void {
    if (!lapic_present) return;
    var svr = lapicRead(LAPIC_SVR);
    svr |= SVR_ENABLE;
    lapicWrite(LAPIC_SVR, svr);
}

/// Disable the Local APIC.
pub fn disable() void {
    if (!lapic_present) return;
    var svr = lapicRead(LAPIC_SVR);
    svr &= ~SVR_ENABLE;
    lapicWrite(LAPIC_SVR, svr);
}

/// Set up the Local APIC timer.
/// `vector`: interrupt vector for timer
/// `divider`: timer divider
/// `initial_count`: initial countdown value
/// `periodic`: if true, timer repeats
pub fn setupTimer(vector: u8, divider: TimerDivider, initial_count: u32, periodic: bool) void {
    if (!lapic_present) return;

    // Set divider
    lapicWrite(LAPIC_TIMER_DCR, @intFromEnum(divider));

    // Configure LVT timer entry
    var lvt: u32 = vector;
    if (periodic) {
        lvt |= TIMER_PERIODIC;
    }
    lapicWrite(LAPIC_TIMER_LVT, lvt);

    // Set initial count (starts the timer)
    lapicWrite(LAPIC_TIMER_ICR, initial_count);
}

/// Stop the APIC timer.
pub fn stopTimer() void {
    if (!lapic_present) return;
    lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED);
    lapicWrite(LAPIC_TIMER_ICR, 0);
}

/// Calibrate APIC timer using PIT (measures ticks per ms).
pub fn calibrateTimer() void {
    if (!lapic_present) return;

    // Set divider to 16
    lapicWrite(LAPIC_TIMER_DCR, @intFromEnum(TimerDivider.div_16));
    // Set a large initial count
    lapicWrite(LAPIC_TIMER_ICR, 0xFFFFFFFF);
    // Unmask timer (one-shot)
    lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED);

    // Start counting
    lapicWrite(LAPIC_TIMER_LVT, 0xFF); // dummy vector, masked
    lapicWrite(LAPIC_TIMER_ICR, 0xFFFFFFFF);

    // Wait 100ms using PIT
    delayMs(100);

    // Read remaining count
    const remaining = lapicRead(LAPIC_TIMER_CCR);
    const elapsed = 0xFFFFFFFF - remaining;

    // ticks per ms = elapsed / 100
    ticks_per_ms = elapsed / 100;
    timer_calibrated = true;

    // Stop timer
    lapicWrite(LAPIC_TIMER_LVT, TIMER_MASKED);

    serial.write("[APIC] Timer calibrated: ");
    serial.writeHex(ticks_per_ms);
    serial.write(" ticks/ms\n");
}

/// Get the current APIC timer count.
pub fn getTimerCount() u32 {
    return lapicRead(LAPIC_TIMER_CCR);
}

/// Read the APIC ID of the current processor.
pub fn getId() u8 {
    if (!lapic_present) return 0;
    return @truncate(lapicRead(LAPIC_ID) >> 24);
}

/// Send an Inter-Processor Interrupt.
pub fn sendIPI(dest_apic_id: u8, vector: u8) void {
    if (!lapic_present) return;

    // Set destination in ICR high
    lapicWrite(LAPIC_ICR_HI, @as(u32, dest_apic_id) << 24);

    // Send: fixed delivery, physical destination, assert, edge
    lapicWrite(LAPIC_ICR_LO, vector | (1 << 14)); // assert
}

/// Send an INIT IPI to a target processor.
pub fn sendInitIPI(dest_apic_id: u8) void {
    if (!lapic_present) return;

    lapicWrite(LAPIC_ICR_HI, @as(u32, dest_apic_id) << 24);
    // INIT | assert | edge | physical
    lapicWrite(LAPIC_ICR_LO, 0x00004500);

    delayMs(10);
}

/// Send a STARTUP IPI to a target processor.
pub fn sendStartupIPI(dest_apic_id: u8, vector_page: u8) void {
    if (!lapic_present) return;

    lapicWrite(LAPIC_ICR_HI, @as(u32, dest_apic_id) << 24);
    // STARTUP | assert | edge | physical | vector
    lapicWrite(LAPIC_ICR_LO, 0x00004600 | vector_page);
}

// ---- I/O APIC redirection ----

/// Set an IRQ redirection entry in the I/O APIC.
/// Maps an ISA IRQ to an interrupt vector on a target APIC.
pub fn setIrqRedirection(irq: u8, vector: u8, dest_apic_id: u8) void {
    if (!ioapic_present) return;
    if (irq > ioapic_max_redir) return;

    const reg_lo = IOAPIC_REDTBL_BASE + @as(u32, irq) * 2;
    const reg_hi = reg_lo + 1;

    // High: destination APIC ID in bits 24-31
    ioapicWrite(reg_hi, @as(u32, dest_apic_id) << 24);

    // Low: vector, fixed delivery, physical dest, active high, edge triggered, not masked
    ioapicWrite(reg_lo, vector);
}

/// Mask an IRQ in the I/O APIC.
pub fn maskIrq(irq: u8) void {
    if (!ioapic_present) return;
    if (irq > ioapic_max_redir) return;

    const reg_lo = IOAPIC_REDTBL_BASE + @as(u32, irq) * 2;
    var entry = ioapicRead(reg_lo);
    entry |= (1 << 16); // set mask bit
    ioapicWrite(reg_lo, entry);
}

/// Unmask an IRQ in the I/O APIC.
pub fn unmaskIrq(irq: u8) void {
    if (!ioapic_present) return;
    if (irq > ioapic_max_redir) return;

    const reg_lo = IOAPIC_REDTBL_BASE + @as(u32, irq) * 2;
    var entry = ioapicRead(reg_lo);
    entry &= ~@as(u32, 1 << 16); // clear mask bit
    ioapicWrite(reg_lo, entry);
}

/// Read an I/O APIC redirection entry.
pub fn readRedirection(irq: u8) ?u64 {
    if (!ioapic_present) return null;
    if (irq > ioapic_max_redir) return null;

    const reg_lo = IOAPIC_REDTBL_BASE + @as(u32, irq) * 2;
    const reg_hi = reg_lo + 1;

    const lo = ioapicRead(reg_lo);
    const hi = ioapicRead(reg_hi);
    return @as(u64, hi) << 32 | lo;
}

// ---- Status ----

pub fn isPresent() bool {
    return lapic_present;
}

pub fn isIoApicPresent() bool {
    return ioapic_present;
}

// ---- Info display ----

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("APIC Information\n");
    vga.setColor(.light_grey, .black);

    if (!lapic_present) {
        vga.write("  Local APIC: not detected\n");
        return;
    }

    vga.write("  Local APIC:\n");
    vga.write("    Base: 0x");
    fmt.printHex32(lapic_base);
    vga.putChar('\n');
    vga.write("    ID: ");
    fmt.printDec(lapic_id);
    vga.putChar('\n');
    vga.write("    Version: 0x");
    fmt.printHex8(lapic_version);
    vga.putChar('\n');
    vga.write("    Max LVT entries: ");
    fmt.printDec(lapic_max_lvt);
    vga.putChar('\n');

    // SVR
    const svr = lapicRead(LAPIC_SVR);
    vga.write("    SVR: 0x");
    fmt.printHex32(svr);
    vga.write(" (");
    if (svr & SVR_ENABLE != 0) {
        vga.setColor(.light_green, .black);
        vga.write("enabled");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("disabled");
    }
    vga.setColor(.light_grey, .black);
    vga.write(")\n");

    // Timer
    vga.write("    Timer ICR: ");
    fmt.printDec(lapicRead(LAPIC_TIMER_ICR));
    vga.write("  CCR: ");
    fmt.printDec(lapicRead(LAPIC_TIMER_CCR));
    vga.putChar('\n');

    if (timer_calibrated) {
        vga.write("    Timer calibration: ");
        fmt.printDec(ticks_per_ms);
        vga.write(" ticks/ms\n");
    }

    // I/O APIC
    if (!ioapic_present) {
        vga.write("  I/O APIC: not detected\n");
        return;
    }

    vga.write("  I/O APIC:\n");
    vga.write("    Base: 0x");
    fmt.printHex32(ioapic_base);
    vga.putChar('\n');
    vga.write("    ID: ");
    fmt.printDec(ioapic_id);
    vga.putChar('\n');
    vga.write("    Version: 0x");
    fmt.printHex8(ioapic_version);
    vga.putChar('\n');
    vga.write("    Max redirections: ");
    fmt.printDec(@as(usize, ioapic_max_redir) + 1);
    vga.putChar('\n');

    // Print first few redirection entries
    vga.write("    Redirection table:\n");
    var irq: u8 = 0;
    while (irq <= ioapic_max_redir and irq < 16) : (irq += 1) {
        const entry = readRedirection(irq) orelse continue;
        const vec: u8 = @truncate(entry);
        const masked = (entry & (1 << 16)) != 0;

        vga.write("      IRQ ");
        if (irq < 10) vga.putChar(' ');
        fmt.printDec(irq);
        vga.write(": vec=0x");
        fmt.printHex8(vec);
        if (masked) {
            vga.setColor(.dark_grey, .black);
            vga.write(" (masked)");
        } else {
            vga.setColor(.light_green, .black);
            vga.write(" (active)");
        }
        vga.setColor(.light_grey, .black);
        vga.putChar('\n');
    }
}

// ---- Serial helpers ----

fn serialWriteHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0x0F]);
}

fn serialWriteDec(val: u8) void {
    if (val >= 100) serial.putChar('0' + val / 100);
    if (val >= 10) serial.putChar('0' + (val / 10) % 10);
    serial.putChar('0' + val % 10);
}
