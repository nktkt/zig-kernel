// Intel 8042 PS/2 コントローラドライバ — キーボード/マウスコントローラ管理
//
// ポート 0x60 (データ), 0x64 (ステータス/コマンド).
// コントローラコマンド: 設定読み書き, ポート有効/無効, セルフテスト, インターフェーステスト.
// 初期化手順: デバイス無効化 → バッファフラッシュ → 設定 → セルフテスト →
// インターフェーステスト → 再有効化.
// デュアルポート (ポート1=キーボード, ポート2=マウス) 検出.

const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- I/O Ports ----

const DATA_PORT: u16 = 0x60; // Data port (read/write)
const STATUS_PORT: u16 = 0x64; // Status register (read)
const COMMAND_PORT: u16 = 0x64; // Command register (write)

// ---- Status Register bits ----

const STATUS_OUTPUT_FULL: u8 = 0x01; // Output buffer full (data ready to read)
const STATUS_INPUT_FULL: u8 = 0x02; // Input buffer full (don't write yet)
const STATUS_SYSTEM: u8 = 0x04; // System flag (0=cold reboot, 1=warm)
const STATUS_COMMAND: u8 = 0x08; // 0=data written to 0x60, 1=command to 0x64
const STATUS_TIMEOUT: u8 = 0x40; // Timeout error
const STATUS_PARITY: u8 = 0x80; // Parity error

// ---- Controller Commands (written to 0x64) ----

const CMD_READ_CONFIG: u8 = 0x20; // Read configuration byte
const CMD_WRITE_CONFIG: u8 = 0x60; // Write configuration byte
const CMD_DISABLE_PORT2: u8 = 0xA7; // Disable second PS/2 port
const CMD_ENABLE_PORT2: u8 = 0xA8; // Enable second PS/2 port
const CMD_TEST_PORT2: u8 = 0xA9; // Test second PS/2 port
const CMD_SELF_TEST: u8 = 0xAA; // Controller self-test
const CMD_TEST_PORT1: u8 = 0xAB; // Test first PS/2 port
const CMD_DIAGNOSTIC: u8 = 0xAC; // Diagnostic dump
const CMD_DISABLE_PORT1: u8 = 0xAD; // Disable first PS/2 port
const CMD_ENABLE_PORT1: u8 = 0xAE; // Enable first PS/2 port
const CMD_READ_INPUT: u8 = 0xC0; // Read controller input port
const CMD_READ_OUTPUT: u8 = 0xD0; // Read controller output port
const CMD_WRITE_OUTPUT: u8 = 0xD1; // Write controller output port
const CMD_WRITE_PORT1_OUT: u8 = 0xD2; // Write to first port output buffer
const CMD_WRITE_PORT2_OUT: u8 = 0xD3; // Write to second port output buffer
const CMD_WRITE_PORT2_IN: u8 = 0xD4; // Write to second port input buffer

// ---- Configuration byte bits ----

const CFG_PORT1_IRQ: u8 = 0x01; // Port 1 interrupt enable (IRQ1)
const CFG_PORT2_IRQ: u8 = 0x02; // Port 2 interrupt enable (IRQ12)
const CFG_SYSTEM: u8 = 0x04; // System flag
const CFG_PORT1_CLOCK: u8 = 0x10; // Port 1 clock disable
const CFG_PORT2_CLOCK: u8 = 0x20; // Port 2 clock disable
const CFG_PORT1_TRANSLATE: u8 = 0x40; // Port 1 translation enable

// ---- Self-test results ----

const SELF_TEST_PASS: u8 = 0x55;
const SELF_TEST_FAIL: u8 = 0xFC;

// ---- Interface test results ----

const PORT_TEST_PASS: u8 = 0x00;
const PORT_TEST_CLOCK_LOW: u8 = 0x01;
const PORT_TEST_CLOCK_HIGH: u8 = 0x02;
const PORT_TEST_DATA_LOW: u8 = 0x03;
const PORT_TEST_DATA_HIGH: u8 = 0x04;

// ---- Device Commands (sent to devices via data port) ----

const DEV_RESET: u8 = 0xFF; // Reset device
const DEV_DISABLE_SCAN: u8 = 0xF5; // Disable scanning
const DEV_ENABLE_SCAN: u8 = 0xF4; // Enable scanning
const DEV_IDENTIFY: u8 = 0xF2; // Identify device
const DEV_SET_DEFAULTS: u8 = 0xF6; // Set default parameters
const DEV_ACK: u8 = 0xFA; // Acknowledgment

// ---- State ----

var initialized: bool = false;
var has_port1: bool = false; // First PS/2 port present
var has_port2: bool = false; // Second PS/2 port present (dual-channel)
var is_dual_channel: bool = false;
var config_byte: u8 = 0;
var self_test_passed: bool = false;
var port1_test_passed: bool = false;
var port2_test_passed: bool = false;

// Device identification
var port1_device_type: DeviceType = .unknown;
var port2_device_type: DeviceType = .unknown;

pub const DeviceType = enum {
    unknown,
    keyboard_at,
    keyboard_mf2,
    keyboard_mf2_translated,
    mouse_standard,
    mouse_scroll,
    mouse_5button,
    none,
};

// ---- Wait helpers ----

fn waitInput() bool {
    // Wait until input buffer is empty (safe to write)
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if (idt.inb(STATUS_PORT) & STATUS_INPUT_FULL == 0) return true;
    }
    return false;
}

fn waitOutput() bool {
    // Wait until output buffer is full (data ready to read)
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if (idt.inb(STATUS_PORT) & STATUS_OUTPUT_FULL != 0) return true;
    }
    return false;
}

fn flushOutput() void {
    // Flush the output buffer (read and discard any pending data)
    var count: u32 = 0;
    while (count < 16) : (count += 1) {
        if (idt.inb(STATUS_PORT) & STATUS_OUTPUT_FULL == 0) break;
        _ = idt.inb(DATA_PORT);
    }
}

// ---- Controller command interface ----

pub fn sendCommand(cmd: u8) void {
    _ = waitInput();
    idt.outb(COMMAND_PORT, cmd);
}

pub fn sendData(port: u8, data: u8) void {
    if (port == 2) {
        // Write to second port via controller command
        sendCommand(CMD_WRITE_PORT2_IN);
    }
    _ = waitInput();
    idt.outb(DATA_PORT, data);
}

pub fn readData() ?u8 {
    if (!waitOutput()) return null;
    return idt.inb(DATA_PORT);
}

fn readConfigByte() u8 {
    sendCommand(CMD_READ_CONFIG);
    return readData() orelse 0;
}

fn writeConfigByte(val: u8) void {
    sendCommand(CMD_WRITE_CONFIG);
    _ = waitInput();
    idt.outb(DATA_PORT, val);
}

// ---- Initialization ----

pub fn init() void {
    initialized = false;
    has_port1 = false;
    has_port2 = false;
    self_test_passed = false;
    port1_test_passed = false;
    port2_test_passed = false;
    port1_device_type = .unknown;
    port2_device_type = .unknown;

    // Step 1: Disable both PS/2 ports
    sendCommand(CMD_DISABLE_PORT1);
    sendCommand(CMD_DISABLE_PORT2);

    // Step 2: Flush output buffer
    flushOutput();

    // Step 3: Read and modify configuration byte
    config_byte = readConfigByte();

    // Disable IRQs and translation for now
    var new_config = config_byte;
    new_config &= ~(CFG_PORT1_IRQ | CFG_PORT2_IRQ | CFG_PORT1_TRANSLATE);
    writeConfigByte(new_config);

    // Check if dual-channel: if port 2 clock was disabled, it's single channel
    // Re-read config after disabling port 2
    is_dual_channel = (config_byte & CFG_PORT2_CLOCK) != 0;
    // A more reliable test: enable port 2 and check if clock bit clears
    sendCommand(CMD_ENABLE_PORT2);
    const cfg2 = readConfigByte();
    if (cfg2 & CFG_PORT2_CLOCK == 0) {
        is_dual_channel = true;
    } else {
        is_dual_channel = false;
    }
    sendCommand(CMD_DISABLE_PORT2);

    // Step 4: Controller self-test
    sendCommand(CMD_SELF_TEST);
    if (readData()) |result| {
        if (result == SELF_TEST_PASS) {
            self_test_passed = true;
        } else {
            serial.write("[8042] Self-test FAILED (0x");
            serialHex8(result);
            serial.write(")\n");
            // Self-test may reset config, re-write it
            writeConfigByte(new_config);
        }
    }

    // After self-test, controller may have been reset — re-write config
    writeConfigByte(new_config);

    // Step 5: Interface tests

    // Test port 1
    sendCommand(CMD_TEST_PORT1);
    if (readData()) |result| {
        if (result == PORT_TEST_PASS) {
            port1_test_passed = true;
            has_port1 = true;
        }
    }

    // Test port 2 (if dual-channel)
    if (is_dual_channel) {
        sendCommand(CMD_TEST_PORT2);
        if (readData()) |result| {
            if (result == PORT_TEST_PASS) {
                port2_test_passed = true;
                has_port2 = true;
            }
        }
    }

    // Step 6: Enable working ports
    if (has_port1) {
        sendCommand(CMD_ENABLE_PORT1);
        new_config |= CFG_PORT1_IRQ;
    }
    if (has_port2) {
        sendCommand(CMD_ENABLE_PORT2);
        new_config |= CFG_PORT2_IRQ;
    }

    // Enable translation for port 1 (scancode set 2 -> set 1)
    if (has_port1) {
        new_config |= CFG_PORT1_TRANSLATE;
    }

    writeConfigByte(new_config);
    config_byte = new_config;

    // Step 7: Reset devices
    if (has_port1) {
        resetDevice(1);
        identifyDevice(1);
    }
    if (has_port2) {
        resetDevice(2);
        identifyDevice(2);
    }

    initialized = true;

    serial.write("[8042] Self-test: ");
    if (self_test_passed) serial.write("PASS") else serial.write("FAIL");
    serial.write(" Port1: ");
    if (has_port1) serial.write("OK") else serial.write("--");
    serial.write(" Port2: ");
    if (has_port2) serial.write("OK") else serial.write("--");
    serial.write("\n");
}

fn resetDevice(port: u8) void {
    sendData(port, DEV_RESET);

    // Wait for ACK
    if (readData()) |ack| {
        if (ack == DEV_ACK) {
            // Wait for self-test result (0xAA = pass)
            _ = readData();
        }
    }
}

fn identifyDevice(port: u8) void {
    // Disable scanning first
    sendData(port, DEV_DISABLE_SCAN);
    _ = readData(); // ACK

    // Send identify command
    sendData(port, DEV_IDENTIFY);
    if (readData()) |ack| {
        if (ack != DEV_ACK) {
            // No ACK — probably AT keyboard (they don't respond to identify)
            if (port == 1) {
                port1_device_type = .keyboard_at;
            } else {
                port2_device_type = .keyboard_at;
            }
            // Re-enable scanning
            sendData(port, DEV_ENABLE_SCAN);
            _ = readData();
            return;
        }
    } else {
        if (port == 1) port1_device_type = .none else port2_device_type = .none;
        return;
    }

    // Read identification bytes
    var id_bytes: [2]u8 = .{ 0, 0 };
    var id_count: u8 = 0;

    if (readData()) |b1| {
        id_bytes[0] = b1;
        id_count = 1;
        if (readData()) |b2| {
            id_bytes[1] = b2;
            id_count = 2;
        }
    }

    // Classify device
    const dev_type = classifyDevice(id_bytes, id_count);
    if (port == 1) {
        port1_device_type = dev_type;
    } else {
        port2_device_type = dev_type;
    }

    // Re-enable scanning
    sendData(port, DEV_ENABLE_SCAN);
    _ = readData();
}

fn classifyDevice(id: [2]u8, count: u8) DeviceType {
    if (count == 0) return .keyboard_at; // AT keyboard (no ID)

    if (count >= 2) {
        if (id[0] == 0xAB) {
            return switch (id[1]) {
                0x41, 0xC1 => .keyboard_mf2_translated,
                0x83 => .keyboard_mf2,
                else => .keyboard_mf2,
            };
        }
    }

    if (count >= 1) {
        return switch (id[0]) {
            0x00 => .mouse_standard,
            0x03 => .mouse_scroll,
            0x04 => .mouse_5button,
            else => .unknown,
        };
    }

    return .unknown;
}

fn deviceTypeName(dt: DeviceType) []const u8 {
    return switch (dt) {
        .keyboard_at => "AT Keyboard",
        .keyboard_mf2 => "MF2 Keyboard",
        .keyboard_mf2_translated => "MF2 Keyboard (translated)",
        .mouse_standard => "Standard Mouse",
        .mouse_scroll => "Scroll Mouse",
        .mouse_5button => "5-Button Mouse",
        .none => "None",
        .unknown => "Unknown",
    };
}

// ---- Query ----

pub fn isPort1Available() bool {
    return has_port1;
}

pub fn isPort2Available() bool {
    return has_port2;
}

pub fn isDualChannel() bool {
    return is_dual_channel;
}

pub fn getPort1Type() DeviceType {
    return port1_device_type;
}

pub fn getPort2Type() DeviceType {
    return port2_device_type;
}

// ---- Display ----

pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("8042 PS/2 Controller:\n");
    vga.setColor(.light_grey, .black);

    if (!initialized) {
        vga.write("  Not initialized\n");
        return;
    }

    // Self-test
    vga.write("  Self-test: ");
    if (self_test_passed) {
        vga.setColor(.light_green, .black);
        vga.write("PASS (0x55)");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("FAIL");
    }
    vga.setColor(.light_grey, .black);
    vga.putChar('\n');

    // Configuration
    vga.write("  Config: 0x");
    printHex8(config_byte);
    vga.write("  Dual-channel: ");
    if (is_dual_channel) vga.write("Yes") else vga.write("No");
    vga.putChar('\n');

    // Current status register
    const status = idt.inb(STATUS_PORT);
    vga.write("  Status: 0x");
    printHex8(status);
    vga.write(" [");
    if (status & STATUS_OUTPUT_FULL != 0) vga.write("OUT ") else vga.write("    ");
    if (status & STATUS_INPUT_FULL != 0) vga.write("IN ") else vga.write("   ");
    if (status & STATUS_SYSTEM != 0) vga.write("SYS ") else vga.write("    ");
    if (status & STATUS_TIMEOUT != 0) vga.write("TMO ") else vga.write("    ");
    if (status & STATUS_PARITY != 0) vga.write("PAR") else vga.write("   ");
    vga.write("]\n");

    // Port 1
    vga.write("  Port 1: ");
    if (has_port1) {
        vga.setColor(.light_green, .black);
        vga.write("OK");
        vga.setColor(.light_grey, .black);
        vga.write(" - ");
        vga.write(deviceTypeName(port1_device_type));
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("Not available");
        vga.setColor(.light_grey, .black);
    }
    vga.putChar('\n');

    // Port 2
    vga.write("  Port 2: ");
    if (has_port2) {
        vga.setColor(.light_green, .black);
        vga.write("OK");
        vga.setColor(.light_grey, .black);
        vga.write(" - ");
        vga.write(deviceTypeName(port2_device_type));
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("Not available");
        vga.setColor(.light_grey, .black);
    }
    vga.putChar('\n');

    // IRQ status
    vga.write("  IRQs: Port1(IRQ1)=");
    if (config_byte & CFG_PORT1_IRQ != 0) vga.write("ON") else vga.write("OFF");
    vga.write("  Port2(IRQ12)=");
    if (config_byte & CFG_PORT2_IRQ != 0) vga.write("ON") else vga.write("OFF");
    vga.write("  Translation=");
    if (config_byte & CFG_PORT1_TRANSLATE != 0) vga.write("ON") else vga.write("OFF");
    vga.putChar('\n');
}

// ---- Helpers ----

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn serialHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    serial.putChar(hex[val >> 4]);
    serial.putChar(hex[val & 0xF]);
}
