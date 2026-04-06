// 8237 DMA Controller Driver -- ISA DMA channels 0-7
//
// Channels 0-3: 8-bit transfers (master controller, ports 0x00-0x0F)
// Channels 4-7: 16-bit transfers (slave controller, ports 0xC0-0xDF)
// Channel 4 is cascade (used internally), not available for devices.
// Page registers set the upper address bits (A16-A23).
// Commonly used for floppy (ch2) and sound (ch1).

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- DMA transfer modes ----

pub const TransferType = enum(u2) {
    verify = 0, // pseudo-transfer, no actual data movement
    write = 1, // write to memory (device -> memory)
    read = 2, // read from memory (memory -> device)
};

pub const TransferMode = enum(u2) {
    demand = 0,
    single = 1,
    block = 2,
    cascade = 3,
};

// ---- Port addresses ----

// Master controller (channels 0-3): base address ports
const MASTER_ADDR = [4]u16{ 0x00, 0x02, 0x04, 0x06 };
const MASTER_COUNT = [4]u16{ 0x01, 0x03, 0x05, 0x07 };
const MASTER_STATUS: u16 = 0x08;
const MASTER_CMD: u16 = 0x08;
const MASTER_REQUEST: u16 = 0x09;
const MASTER_SINGLE_MASK: u16 = 0x0A;
const MASTER_MODE: u16 = 0x0B;
const MASTER_FLIP_FLOP: u16 = 0x0C;
const MASTER_TEMP: u16 = 0x0D; // master reset (write) / temp register (read)
const MASTER_CLEAR_MASK: u16 = 0x0E;
const MASTER_MULTI_MASK: u16 = 0x0F;

// Slave controller (channels 4-7): base address ports
const SLAVE_ADDR = [4]u16{ 0xC0, 0xC4, 0xC8, 0xCC };
const SLAVE_COUNT = [4]u16{ 0xC2, 0xC6, 0xCA, 0xCE };
const SLAVE_STATUS: u16 = 0xD0;
const SLAVE_CMD: u16 = 0xD0;
const SLAVE_REQUEST: u16 = 0xD2;
const SLAVE_SINGLE_MASK: u16 = 0xD4;
const SLAVE_MODE: u16 = 0xD6;
const SLAVE_FLIP_FLOP: u16 = 0xD8;
const SLAVE_TEMP: u16 = 0xDA;
const SLAVE_CLEAR_MASK: u16 = 0xDC;
const SLAVE_MULTI_MASK: u16 = 0xDE;

// Page registers for each channel
const PAGE_REGS = [8]u16{
    0x87, // channel 0
    0x83, // channel 1
    0x81, // channel 2
    0x82, // channel 3
    0x8F, // channel 4 (cascade, not usable)
    0x8B, // channel 5
    0x89, // channel 6
    0x8A, // channel 7
};

// ---- Internal state ----

var channel_active: [8]bool = .{ false, false, false, false, false, false, false, false };
var channel_masked: [8]bool = .{ true, true, true, true, true, true, true, true };

// ---- Helper functions ----

fn isSlave(channel: u8) bool {
    return channel >= 4;
}

fn channelIdx(channel: u8) u8 {
    return channel & 0x03;
}

fn getAddrPort(channel: u8) u16 {
    if (isSlave(channel)) return SLAVE_ADDR[channelIdx(channel)];
    return MASTER_ADDR[channelIdx(channel)];
}

fn getCountPort(channel: u8) u16 {
    if (isSlave(channel)) return SLAVE_COUNT[channelIdx(channel)];
    return MASTER_COUNT[channelIdx(channel)];
}

fn getSingleMaskPort(channel: u8) u16 {
    if (isSlave(channel)) return SLAVE_SINGLE_MASK;
    return MASTER_SINGLE_MASK;
}

fn getModePort(channel: u8) u16 {
    if (isSlave(channel)) return SLAVE_MODE;
    return MASTER_MODE;
}

fn getFlipFlopPort(channel: u8) u16 {
    if (isSlave(channel)) return SLAVE_FLIP_FLOP;
    return MASTER_FLIP_FLOP;
}

// ---- Public API ----

/// Mask (disable) a DMA channel.
pub fn maskChannel(channel: u8) void {
    if (channel > 7 or channel == 4) return;
    // Set mask bit: bit 2 = set mask, bits 0-1 = channel index
    const idx: u8 = channelIdx(channel);
    idt.outb(getSingleMaskPort(channel), 0x04 | idx);
    channel_masked[channel] = true;
}

/// Unmask (enable) a DMA channel.
pub fn unmaskChannel(channel: u8) void {
    if (channel > 7 or channel == 4) return;
    // Clear mask bit: bit 2 = 0, bits 0-1 = channel index
    const idx: u8 = channelIdx(channel);
    idt.outb(getSingleMaskPort(channel), idx);
    channel_masked[channel] = false;
}

/// Reset the flip-flop for the given controller (master or slave).
fn resetFlipFlop(channel: u8) void {
    idt.outb(getFlipFlopPort(channel), 0x00); // any value resets
}

/// Set up a DMA channel for a transfer.
/// `addr`: physical address of the DMA buffer (must be below 16MB for ISA).
///         For 16-bit channels (4-7), address is in 16-bit words.
/// `count`: number of bytes (or words for 16-bit channels) to transfer minus 1.
/// `mode`: transfer mode (single, block, demand).
/// `transfer`: transfer direction (read, write, verify).
/// `auto_init`: if true, the channel auto-reinitializes after transfer.
pub fn setupChannel(
    channel: u8,
    addr: u32,
    count: u16,
    mode: TransferMode,
    transfer: TransferType,
    auto_init: bool,
) void {
    if (channel > 7 or channel == 4) return;

    // Mask the channel during setup
    maskChannel(channel);

    // Reset flip-flop
    resetFlipFlop(channel);

    // Set address (low byte, high byte)
    const addr_port = getAddrPort(channel);
    if (isSlave(channel)) {
        // 16-bit channels: address is shifted right by 1
        const word_addr: u16 = @truncate((addr >> 1) & 0xFFFF);
        idt.outb(addr_port, @truncate(word_addr & 0xFF));
        idt.outb(addr_port, @truncate((word_addr >> 8) & 0xFF));
    } else {
        idt.outb(addr_port, @truncate(addr & 0xFF));
        idt.outb(addr_port, @truncate((addr >> 8) & 0xFF));
    }

    // Reset flip-flop again for count
    resetFlipFlop(channel);

    // Set count (low byte, high byte) -- count is length - 1
    const count_port = getCountPort(channel);
    idt.outb(count_port, @truncate(count & 0xFF));
    idt.outb(count_port, @truncate((count >> 8) & 0xFF));

    // Set page register (bits 16-23 of address)
    const page: u8 = @truncate((addr >> 16) & 0xFF);
    idt.outb(PAGE_REGS[channel], page);

    // Set mode register
    const mode_byte: u8 = channelIdx(channel) |
        (@as(u8, @intFromEnum(transfer)) << 2) |
        (if (auto_init) @as(u8, 0x10) else @as(u8, 0x00)) |
        (@as(u8, @intFromEnum(mode)) << 6);
    idt.outb(getModePort(channel), mode_byte);

    channel_active[channel] = true;

    // Unmask the channel
    unmaskChannel(channel);
}

/// Read the status register of the controller for a given channel.
/// Returns the full 8-bit status register.
/// Bits 0-3: channel 0-3 has reached terminal count.
/// Bits 4-7: channel 0-3 has a DMA request pending.
pub fn readStatus(channel: u8) u8 {
    if (isSlave(channel)) {
        return idt.inb(SLAVE_STATUS);
    }
    return idt.inb(MASTER_STATUS);
}

/// Check if a transfer has completed (terminal count reached) for a channel.
pub fn isComplete(channel: u8) bool {
    if (channel > 7 or channel == 4) return false;
    const status = readStatus(channel);
    const bit: u3 = @truncate(channelIdx(channel) & 0x07);
    return (status & (@as(u8, 1) << bit)) != 0;
}

/// Master reset of a DMA controller (master or slave).
pub fn resetController(slave: bool) void {
    if (slave) {
        idt.outb(SLAVE_TEMP, 0x00);
    } else {
        idt.outb(MASTER_TEMP, 0x00);
    }
}

/// Initialize both DMA controllers.
pub fn init() void {
    // Reset both controllers
    resetController(false);
    resetController(true);

    // Mask all channels
    var ch: u8 = 0;
    while (ch < 8) : (ch += 1) {
        if (ch != 4) maskChannel(ch);
    }

    // Clear all active flags
    for (&channel_active) |*a| a.* = false;

    serial.write("[DMA] 8237 controllers initialized\n");
}

/// Mask all channels on both controllers.
pub fn maskAll() void {
    idt.outb(MASTER_MULTI_MASK, 0x0F); // mask channels 0-3
    idt.outb(SLAVE_MULTI_MASK, 0x0F); // mask channels 4-7
    for (&channel_masked) |*m| m.* = true;
}

/// Unmask all channels on both controllers.
pub fn unmaskAll() void {
    idt.outb(MASTER_CLEAR_MASK, 0x00);
    idt.outb(SLAVE_CLEAR_MASK, 0x00);
    for (&channel_masked) |*m| m.* = false;
}

// ---- Debug / Status display ----

pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("DMA Controller Status\n");
    vga.setColor(.light_grey, .black);

    const master_status = idt.inb(MASTER_STATUS);
    const slave_status = idt.inb(SLAVE_STATUS);

    vga.write("  Master status: 0x");
    fmt.printHex8(master_status);
    vga.write("  Slave status: 0x");
    fmt.printHex8(slave_status);
    vga.putChar('\n');

    vga.write("  CH  MASKED  ACTIVE  TC\n");

    var ch: u8 = 0;
    while (ch < 8) : (ch += 1) {
        if (ch == 4) {
            ch += 1;
            if (ch >= 8) break;
        }
        vga.write("  ");
        fmt.printDec(ch);
        vga.write("   ");
        if (channel_masked[ch]) {
            vga.write("yes     ");
        } else {
            vga.write("no      ");
        }
        if (channel_active[ch]) {
            vga.write("yes     ");
        } else {
            vga.write("no      ");
        }
        if (isComplete(ch)) {
            vga.write("done");
        } else {
            vga.write("-");
        }
        vga.putChar('\n');
    }
}

/// Get whether a channel is currently active (has been set up).
pub fn isChannelActive(channel: u8) bool {
    if (channel > 7) return false;
    return channel_active[channel];
}

/// Get whether a channel is masked.
pub fn isChannelMasked(channel: u8) bool {
    if (channel > 7) return true;
    return channel_masked[channel];
}
