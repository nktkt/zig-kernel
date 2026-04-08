// 拡張シリアルポートドライバ — 全 4 COM ポート対応, FIFO/フロー制御
//
// COM1-COM4: 0x3F8, 0x2F8, 0x3E8, 0x2E8.
// ボーレート: 300〜115200. 16550 UART 検出 (FIFO).
// フロー制御: None, RTS/CTS, XON/XOFF.
// ループバックテスト, ポート情報表示.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- COM Port base addresses ----

const COM_PORTS = [4]u16{ 0x3F8, 0x2F8, 0x3E8, 0x2E8 };
const COM_NAMES = [4][]const u8{ "COM1", "COM2", "COM3", "COM4" };

// ---- UART Register offsets ----

const REG_DATA: u16 = 0x00; // Data (RBR/THR) / Divisor Latch Low (DLAB=1)
const REG_IER: u16 = 0x01; // Interrupt Enable / Divisor Latch High (DLAB=1)
const REG_IIR: u16 = 0x02; // Interrupt Identification (read)
const REG_FCR: u16 = 0x02; // FIFO Control (write)
const REG_LCR: u16 = 0x03; // Line Control
const REG_MCR: u16 = 0x04; // Modem Control
const REG_LSR: u16 = 0x05; // Line Status
const REG_MSR: u16 = 0x06; // Modem Status
const REG_SCR: u16 = 0x07; // Scratch register

// ---- Line Status Register bits ----

const LSR_DATA_READY: u8 = 0x01; // Data ready to read
const LSR_OVERRUN: u8 = 0x02; // Overrun error
const LSR_PARITY: u8 = 0x04; // Parity error
const LSR_FRAMING: u8 = 0x08; // Framing error
const LSR_BREAK: u8 = 0x10; // Break indicator
const LSR_THR_EMPTY: u8 = 0x20; // Transmitter Holding Register empty
const LSR_TSR_EMPTY: u8 = 0x40; // Transmitter Shift Register empty
const LSR_FIFO_ERR: u8 = 0x80; // Error in FIFO

// ---- Modem Control Register bits ----

const MCR_DTR: u8 = 0x01; // Data Terminal Ready
const MCR_RTS: u8 = 0x02; // Request To Send
const MCR_OUT1: u8 = 0x04; // Out 1
const MCR_OUT2: u8 = 0x08; // Out 2 (enable IRQ)
const MCR_LOOPBACK: u8 = 0x10; // Loopback mode

// ---- Modem Status Register bits ----

const MSR_DCTS: u8 = 0x01; // Delta CTS
const MSR_DDSR: u8 = 0x02; // Delta DSR
const MSR_TERI: u8 = 0x04; // Trailing Edge RI
const MSR_DDCD: u8 = 0x08; // Delta DCD
const MSR_CTS: u8 = 0x10; // Clear To Send
const MSR_DSR: u8 = 0x20; // Data Set Ready
const MSR_RI: u8 = 0x40; // Ring Indicator
const MSR_DCD: u8 = 0x80; // Data Carrier Detect

// ---- FIFO Control Register bits ----

const FCR_ENABLE: u8 = 0x01; // Enable FIFO
const FCR_CLEAR_RX: u8 = 0x02; // Clear receive FIFO
const FCR_CLEAR_TX: u8 = 0x04; // Clear transmit FIFO
const FCR_DMA_MODE: u8 = 0x08; // DMA mode select
const FCR_TRIGGER_1: u8 = 0x00; // Trigger level: 1 byte
const FCR_TRIGGER_4: u8 = 0x40; // Trigger level: 4 bytes
const FCR_TRIGGER_8: u8 = 0x80; // Trigger level: 8 bytes
const FCR_TRIGGER_14: u8 = 0xC0; // Trigger level: 14 bytes

// ---- Line Control Register bits ----

const LCR_5BIT: u8 = 0x00;
const LCR_6BIT: u8 = 0x01;
const LCR_7BIT: u8 = 0x02;
const LCR_8BIT: u8 = 0x03;
const LCR_1STOP: u8 = 0x00;
const LCR_2STOP: u8 = 0x04;
const LCR_PARITY_NONE: u8 = 0x00;
const LCR_PARITY_ODD: u8 = 0x08;
const LCR_PARITY_EVEN: u8 = 0x18;
const LCR_PARITY_MARK: u8 = 0x28;
const LCR_PARITY_SPACE: u8 = 0x38;
const LCR_DLAB: u8 = 0x80; // Divisor Latch Access Bit

// ---- Baud rate divisors (based on 115200 / baud) ----

pub const BaudRate = enum(u16) {
    baud_300 = 384,
    baud_1200 = 96,
    baud_2400 = 48,
    baud_4800 = 24,
    baud_9600 = 12,
    baud_19200 = 6,
    baud_38400 = 3,
    baud_57600 = 2,
    baud_115200 = 1,
};

// ---- Flow control types ----

pub const FlowControl = enum {
    none,
    rts_cts,
    xon_xoff,
};

// ---- XON/XOFF characters ----

const XON: u8 = 0x11; // DC1 (Ctrl-Q)
const XOFF: u8 = 0x13; // DC3 (Ctrl-S)

// ---- UART type detection ----

pub const UartType = enum {
    uart_8250,
    uart_16450,
    uart_16550,
    uart_16550a,
    unknown,
};

// ---- Per-port state ----

const PortState = struct {
    base: u16,
    initialized: bool,
    baud_rate: BaudRate,
    flow_control: FlowControl,
    uart_type: UartType,
    is_present: bool,
    xoff_received: bool, // For XON/XOFF flow control
    has_fifo: bool,
};

var ports: [4]PortState = @splat(PortState{
    .base = 0,
    .initialized = false,
    .baud_rate = .baud_9600,
    .flow_control = .none,
    .uart_type = .unknown,
    .is_present = false,
    .xoff_received = false,
    .has_fifo = false,
});

// ---- Initialization ----

/// Initialize a specific COM port with the given baud rate
pub fn initPort(port_num: u8, baud: BaudRate) bool {
    if (port_num >= 4) return false;

    const base = COM_PORTS[port_num];
    const divisor = @intFromEnum(baud);

    // Check if port exists (write to scratch register and read back)
    idt.outb(base + REG_SCR, 0xAA);
    if (idt.inb(base + REG_SCR) != 0xAA) {
        ports[port_num].is_present = false;
        return false;
    }

    ports[port_num].base = base;
    ports[port_num].is_present = true;
    ports[port_num].baud_rate = baud;

    // Disable all interrupts
    idt.outb(base + REG_IER, 0x00);

    // Enable DLAB (Divisor Latch Access Bit) to set baud rate
    idt.outb(base + REG_LCR, LCR_DLAB);

    // Set divisor
    idt.outb(base + REG_DATA, @truncate(divisor)); // Low byte
    idt.outb(base + REG_IER, @truncate(divisor >> 8)); // High byte

    // Set 8N1 (8 data bits, no parity, 1 stop bit)
    idt.outb(base + REG_LCR, LCR_8BIT | LCR_1STOP | LCR_PARITY_NONE);

    // Detect UART type and enable FIFO if 16550+
    ports[port_num].uart_type = detectUartType(base);

    if (ports[port_num].uart_type == .uart_16550a or
        ports[port_num].uart_type == .uart_16550)
    {
        // Enable FIFO, clear buffers, 14-byte trigger
        idt.outb(base + REG_FCR, FCR_ENABLE | FCR_CLEAR_RX | FCR_CLEAR_TX | FCR_TRIGGER_14);
        ports[port_num].has_fifo = true;
    } else {
        idt.outb(base + REG_FCR, 0x00); // Disable FIFO
        ports[port_num].has_fifo = false;
    }

    // Set MCR: DTR + RTS + OUT2
    idt.outb(base + REG_MCR, MCR_DTR | MCR_RTS | MCR_OUT2);

    ports[port_num].flow_control = .none;
    ports[port_num].xoff_received = false;
    ports[port_num].initialized = true;

    return true;
}

fn detectUartType(base: u16) UartType {
    // Try enabling FIFO
    idt.outb(base + REG_FCR, FCR_ENABLE);

    // Read IIR to check FIFO status
    const iir = idt.inb(base + REG_IIR);

    // Disable FIFO for now
    idt.outb(base + REG_FCR, 0x00);

    // Check bits 6-7 of IIR for FIFO status
    const fifo_bits = iir & 0xC0;

    if (fifo_bits == 0xC0) {
        return .uart_16550a; // Working FIFO
    } else if (fifo_bits == 0x80) {
        return .uart_16550; // Broken FIFO (old 16550)
    }

    // Check for scratch register (16450 has it, 8250 doesn't)
    idt.outb(base + REG_SCR, 0x55);
    if (idt.inb(base + REG_SCR) == 0x55) {
        return .uart_16450;
    }

    return .uart_8250;
}

fn uartTypeName(ut: UartType) []const u8 {
    return switch (ut) {
        .uart_8250 => "8250",
        .uart_16450 => "16450",
        .uart_16550 => "16550",
        .uart_16550a => "16550A",
        .unknown => "Unknown",
    };
}

// ---- Flow control ----

/// Set flow control type for a port
pub fn setFlowControl(port_num: u8, fc: FlowControl) void {
    if (port_num >= 4 or !ports[port_num].initialized) return;

    ports[port_num].flow_control = fc;
    const base = ports[port_num].base;

    switch (fc) {
        .none => {
            // Set MCR: DTR + RTS + OUT2
            idt.outb(base + REG_MCR, MCR_DTR | MCR_RTS | MCR_OUT2);
        },
        .rts_cts => {
            // RTS/CTS: Assert RTS, monitor CTS before sending
            idt.outb(base + REG_MCR, MCR_DTR | MCR_RTS | MCR_OUT2);
        },
        .xon_xoff => {
            ports[port_num].xoff_received = false;
        },
    }
}

// ---- Data transfer ----

/// Check if data is available to read
pub fn available(port_num: u8) bool {
    if (port_num >= 4 or !ports[port_num].initialized) return false;
    return (idt.inb(ports[port_num].base + REG_LSR) & LSR_DATA_READY) != 0;
}

/// Non-blocking read of a single character
pub fn readChar(port_num: u8) ?u8 {
    if (port_num >= 4 or !ports[port_num].initialized) return null;

    const base = ports[port_num].base;
    if (idt.inb(base + REG_LSR) & LSR_DATA_READY == 0) return null;

    const ch = idt.inb(base + REG_DATA);

    // Handle XON/XOFF if applicable
    if (ports[port_num].flow_control == .xon_xoff) {
        if (ch == XOFF) {
            ports[port_num].xoff_received = true;
            return null; // Don't return control char
        } else if (ch == XON) {
            ports[port_num].xoff_received = false;
            return null;
        }
    }

    return ch;
}

/// Write a single character (blocking)
pub fn writeChar(port_num: u8, ch: u8) void {
    if (port_num >= 4 or !ports[port_num].initialized) return;

    const base = ports[port_num].base;

    // Check flow control
    switch (ports[port_num].flow_control) {
        .rts_cts => {
            // Wait for CTS to be asserted
            var timeout: u32 = 0;
            while (timeout < 100000) : (timeout += 1) {
                if (idt.inb(base + REG_MSR) & MSR_CTS != 0) break;
            }
        },
        .xon_xoff => {
            // Wait until XOFF is cleared
            var timeout: u32 = 0;
            while (ports[port_num].xoff_received and timeout < 100000) : (timeout += 1) {
                // Check for XON in the meantime
                if (idt.inb(base + REG_LSR) & LSR_DATA_READY != 0) {
                    const rx = idt.inb(base + REG_DATA);
                    if (rx == XON) ports[port_num].xoff_received = false;
                }
            }
        },
        .none => {},
    }

    // Wait for THR to be empty
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if (idt.inb(base + REG_LSR) & LSR_THR_EMPTY != 0) break;
    }

    idt.outb(base + REG_DATA, ch);
}

/// Write a string
pub fn writeString(port_num: u8, msg: []const u8) void {
    for (msg) |c| {
        if (c == '\n') writeChar(port_num, '\r');
        writeChar(port_num, c);
    }
}

/// Read a string (up to max_len bytes, non-blocking)
pub fn readString(port_num: u8, buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len) {
        if (readChar(port_num)) |ch| {
            buf[len] = ch;
            len += 1;
        } else {
            break;
        }
    }
    return len;
}

// ---- Loopback test ----

/// Perform a loopback self-test on the specified port
/// Returns true if the test passes
pub fn selfTest(port_num: u8) bool {
    if (port_num >= 4 or !ports[port_num].is_present) return false;

    const base = COM_PORTS[port_num];

    // Save current MCR
    const saved_mcr = idt.inb(base + REG_MCR);

    // Enable loopback mode
    idt.outb(base + REG_MCR, MCR_LOOPBACK | MCR_OUT2);

    // Test with multiple bytes
    const test_bytes = [_]u8{ 0xAA, 0x55, 0xFF, 0x00, 0x42 };
    var passed: bool = true;

    for (test_bytes) |test_byte| {
        // Wait for THR empty
        var timeout: u32 = 0;
        while (timeout < 10000) : (timeout += 1) {
            if (idt.inb(base + REG_LSR) & LSR_THR_EMPTY != 0) break;
        }

        // Send test byte
        idt.outb(base + REG_DATA, test_byte);

        // Wait for data ready
        timeout = 0;
        while (timeout < 10000) : (timeout += 1) {
            if (idt.inb(base + REG_LSR) & LSR_DATA_READY != 0) break;
        }

        // Read back
        const received = idt.inb(base + REG_DATA);
        if (received != test_byte) {
            passed = false;
            break;
        }
    }

    // Restore MCR
    idt.outb(base + REG_MCR, saved_mcr);

    return passed;
}

// ---- Query ----

/// Check if a port is initialized
pub fn isInitialized(port_num: u8) bool {
    if (port_num >= 4) return false;
    return ports[port_num].initialized;
}

/// Check if a port is present (hardware exists)
pub fn isPresent(port_num: u8) bool {
    if (port_num >= 4) return false;
    // Quick check
    const base = COM_PORTS[port_num];
    idt.outb(base + REG_SCR, 0xAA);
    return idt.inb(base + REG_SCR) == 0xAA;
}

/// Get the UART type for a port
pub fn getUartType(port_num: u8) UartType {
    if (port_num >= 4) return .unknown;
    return ports[port_num].uart_type;
}

// ---- Display ----

/// Print detailed info about a specific port
pub fn printPortInfo(port_num: u8) void {
    if (port_num >= 4) return;

    const base = COM_PORTS[port_num];

    vga.setColor(.yellow, .black);
    vga.write(COM_NAMES[port_num]);
    vga.write(" (0x");
    printHex16(base);
    vga.write("):\n");
    vga.setColor(.light_grey, .black);

    // Check presence
    idt.outb(base + REG_SCR, 0xAA);
    const present = idt.inb(base + REG_SCR) == 0xAA;

    vga.write("  Present: ");
    if (present) {
        vga.setColor(.light_green, .black);
        vga.write("Yes");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("No");
        vga.setColor(.light_grey, .black);
        vga.putChar('\n');
        return;
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    if (ports[port_num].initialized) {
        vga.write("  UART: ");
        vga.write(uartTypeName(ports[port_num].uart_type));
        vga.write("  FIFO: ");
        if (ports[port_num].has_fifo) vga.write("Yes") else vga.write("No");
        vga.putChar('\n');

        vga.write("  Baud: ");
        printBaudRate(ports[port_num].baud_rate);
        vga.write("  Flow: ");
        switch (ports[port_num].flow_control) {
            .none => vga.write("None"),
            .rts_cts => vga.write("RTS/CTS"),
            .xon_xoff => vga.write("XON/XOFF"),
        }
        vga.putChar('\n');
    } else {
        vga.write("  (not initialized)\n");
    }

    // Register dump
    const lsr = idt.inb(base + REG_LSR);
    const msr = idt.inb(base + REG_MSR);
    const mcr = idt.inb(base + REG_MCR);
    const iir = idt.inb(base + REG_IIR);

    vga.write("  LSR: 0x");
    printHex8(lsr);
    vga.write(" [");
    if (lsr & LSR_DATA_READY != 0) vga.write("DR ") else vga.write("   ");
    if (lsr & LSR_THR_EMPTY != 0) vga.write("THRE ") else vga.write("     ");
    if (lsr & LSR_OVERRUN != 0) vga.write("OE ") else vga.write("   ");
    vga.write("]\n");

    vga.write("  MSR: 0x");
    printHex8(msr);
    vga.write(" [");
    if (msr & MSR_CTS != 0) vga.write("CTS ") else vga.write("    ");
    if (msr & MSR_DSR != 0) vga.write("DSR ") else vga.write("    ");
    if (msr & MSR_DCD != 0) vga.write("DCD ") else vga.write("    ");
    if (msr & MSR_RI != 0) vga.write("RI") else vga.write("  ");
    vga.write("]\n");

    vga.write("  MCR: 0x");
    printHex8(mcr);
    vga.write("  IIR: 0x");
    printHex8(iir);
    vga.putChar('\n');
}

/// Print summary of all 4 COM ports
pub fn printAllPorts() void {
    vga.setColor(.yellow, .black);
    vga.write("Serial Ports:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  PORT  ADDR    PRESENT  UART      BAUD     FIFO  FLOW\n");
    vga.write("  -------------------------------------------------------\n");

    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const base = COM_PORTS[i];

        vga.write("  ");
        vga.write(COM_NAMES[i]);
        vga.write("  0x");
        printHex16(base);
        vga.write("  ");

        idt.outb(base + REG_SCR, 0xAA);
        const present = idt.inb(base + REG_SCR) == 0xAA;

        if (present) {
            vga.setColor(.light_green, .black);
            vga.write("Yes     ");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("No      ");
        }
        vga.setColor(.light_grey, .black);

        if (ports[i].initialized) {
            // UART type (pad to 10 chars)
            const ut_name = uartTypeName(ports[i].uart_type);
            vga.write(ut_name);
            var pad = 10 -| ut_name.len;
            while (pad > 0) : (pad -= 1) vga.putChar(' ');

            // Baud
            printBaudRate(ports[i].baud_rate);
            vga.write("  ");

            // FIFO
            if (ports[i].has_fifo) vga.write("Yes ") else vga.write("No  ");
            vga.write("  ");

            // Flow
            switch (ports[i].flow_control) {
                .none => vga.write("None"),
                .rts_cts => vga.write("HW"),
                .xon_xoff => vga.write("SW"),
            }
        } else {
            vga.write("--");
        }
        vga.putChar('\n');
    }
}

// ---- Helpers ----

fn printBaudRate(baud: BaudRate) void {
    switch (baud) {
        .baud_300 => vga.write("300"),
        .baud_1200 => vga.write("1200"),
        .baud_2400 => vga.write("2400"),
        .baud_4800 => vga.write("4800"),
        .baud_9600 => vga.write("9600"),
        .baud_19200 => vga.write("19200"),
        .baud_38400 => vga.write("38400"),
        .baud_57600 => vga.write("57600"),
        .baud_115200 => vga.write("115200"),
    }
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printHex16(val: u16) void {
    printHex8(@truncate(val >> 8));
    printHex8(@truncate(val));
}
