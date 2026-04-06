// Unified Input Subsystem -- abstract input events from keyboard and mouse
//
// Provides a unified event queue for keyboard and mouse events.
// Supports scancode -> keycode -> character mapping.
// Device registry for up to 4 input devices.

const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- Event types ----

pub const EventType = enum(u8) {
    key_press = 0,
    key_release = 1,
    mouse_move = 2,
    mouse_button_down = 3,
    mouse_button_up = 4,
    scroll = 5,
};

// ---- Mouse buttons ----

pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
};

// ---- Key codes (virtual) ----

pub const KeyCode = enum(u8) {
    // Printable ASCII range (mapped directly)
    key_none = 0,
    key_escape = 1,
    key_1 = 2,
    key_2 = 3,
    key_3 = 4,
    key_4 = 5,
    key_5 = 6,
    key_6 = 7,
    key_7 = 8,
    key_8 = 9,
    key_9 = 10,
    key_0 = 11,
    key_minus = 12,
    key_equals = 13,
    key_backspace = 14,
    key_tab = 15,
    key_q = 16,
    key_w = 17,
    key_e = 18,
    key_r = 19,
    key_t = 20,
    key_y = 21,
    key_u = 22,
    key_i = 23,
    key_o = 24,
    key_p = 25,
    key_left_bracket = 26,
    key_right_bracket = 27,
    key_enter = 28,
    key_left_ctrl = 29,
    key_a = 30,
    key_s = 31,
    key_d = 32,
    key_f = 33,
    key_g = 34,
    key_h = 35,
    key_j = 36,
    key_k = 37,
    key_l = 38,
    key_semicolon = 39,
    key_quote = 40,
    key_backtick = 41,
    key_left_shift = 42,
    key_backslash = 43,
    key_z = 44,
    key_x = 45,
    key_c = 46,
    key_v = 47,
    key_b = 48,
    key_n = 49,
    key_m = 50,
    key_comma = 51,
    key_period = 52,
    key_slash = 53,
    key_right_shift = 54,
    key_kp_multiply = 55,
    key_left_alt = 56,
    key_space = 57,
    key_caps_lock = 58,
    key_f1 = 59,
    key_f2 = 60,
    key_f3 = 61,
    key_f4 = 62,
    key_f5 = 63,
    key_f6 = 64,
    key_f7 = 65,
    key_f8 = 66,
    key_f9 = 67,
    key_f10 = 68,
    key_num_lock = 69,
    key_scroll_lock = 70,
    // Extended keys
    key_up = 72,
    key_down = 80,
    key_left = 75,
    key_right = 77,
    key_home = 71,
    key_end = 79,
    key_page_up = 73,
    key_page_down = 81,
    key_insert = 82,
    key_delete = 83,
    key_f11 = 87,
    key_f12 = 88,
    _,
};

// ---- Input Event ----

pub const InputEvent = struct {
    event_type: EventType,
    code: u16, // KeyCode or MouseButton encoded
    value: i32, // key: 0/1, mouse_move: delta, scroll: delta
    timestamp: u32, // PIT ticks
};

// ---- Event Queue (ring buffer, 32 events) ----

const QUEUE_SIZE = 32;

var event_queue: [QUEUE_SIZE]InputEvent = @splat(InputEvent{
    .event_type = .key_press,
    .code = 0,
    .value = 0,
    .timestamp = 0,
});
var queue_head: usize = 0;
var queue_tail: usize = 0;
var queue_count: usize = 0;

/// Push an event into the queue. Returns false if full.
pub fn pushEvent(ev: InputEvent) bool {
    if (queue_count >= QUEUE_SIZE) return false;
    event_queue[queue_tail] = ev;
    queue_tail = (queue_tail + 1) % QUEUE_SIZE;
    queue_count += 1;
    return true;
}

/// Poll for the next event. Returns null if queue is empty.
pub fn pollEvent() ?InputEvent {
    if (queue_count == 0) return null;
    const ev = event_queue[queue_head];
    queue_head = (queue_head + 1) % QUEUE_SIZE;
    queue_count -= 1;
    return ev;
}

/// Peek at the next event without removing it.
pub fn peekEvent() ?InputEvent {
    if (queue_count == 0) return null;
    return event_queue[queue_head];
}

/// Get number of events in queue.
pub fn eventCount() usize {
    return queue_count;
}

/// Flush all events.
pub fn flushEvents() void {
    queue_head = 0;
    queue_tail = 0;
    queue_count = 0;
}

// ---- Input device registry ----

pub const DeviceType = enum(u8) {
    keyboard = 0,
    mouse = 1,
    touchpad = 2,
    gamepad = 3,
};

pub const InputDevice = struct {
    name: [32]u8,
    name_len: u8,
    device_type: DeviceType,
    active: bool,
    event_count: u32, // total events generated
};

const MAX_DEVICES = 4;

var devices: [MAX_DEVICES]InputDevice = @splat(InputDevice{
    .name = @splat(0),
    .name_len = 0,
    .device_type = .keyboard,
    .active = false,
    .event_count = 0,
});
var device_count: u8 = 0;

/// Register an input device. Returns device index or null if full.
pub fn registerDevice(name: []const u8, dtype: DeviceType) ?u8 {
    if (device_count >= MAX_DEVICES) return null;

    const idx = device_count;
    var dev = &devices[idx];
    dev.active = true;
    dev.device_type = dtype;
    dev.event_count = 0;
    dev.name_len = 0;

    // Copy name
    const copy_len = if (name.len > 32) 32 else name.len;
    for (name[0..copy_len], 0..) |c, i| {
        dev.name[i] = c;
    }
    dev.name_len = @truncate(copy_len);

    device_count += 1;
    return idx;
}

/// Unregister a device by index.
pub fn unregisterDevice(idx: u8) void {
    if (idx >= MAX_DEVICES) return;
    devices[idx].active = false;
}

// ---- Mouse state ----

pub const MouseState = struct {
    x: i32,
    y: i32,
    buttons: u8, // bit 0=left, 1=right, 2=middle
    scroll: i32,
};

var mouse_state: MouseState = .{
    .x = 0,
    .y = 0,
    .buttons = 0,
    .scroll = 0,
};

pub fn getMouseState() MouseState {
    return mouse_state;
}

/// Update mouse position (called from mouse IRQ handler).
pub fn updateMousePosition(dx: i32, dy: i32) void {
    mouse_state.x += dx;
    mouse_state.y += dy;

    // Clamp to screen bounds
    if (mouse_state.x < 0) mouse_state.x = 0;
    if (mouse_state.y < 0) mouse_state.y = 0;
    if (mouse_state.x > 639) mouse_state.x = 639;
    if (mouse_state.y > 479) mouse_state.y = 479;

    // Push event
    _ = pushEvent(.{
        .event_type = .mouse_move,
        .code = 0,
        .value = (@as(i32, dx) << 16) | (dy & 0xFFFF),
        .timestamp = @truncate(pit.getTicks()),
    });
}

/// Update mouse button state.
pub fn updateMouseButton(button: MouseButton, pressed: bool) void {
    const bit: u8 = @as(u8, 1) << @intFromEnum(button);
    if (pressed) {
        mouse_state.buttons |= bit;
    } else {
        mouse_state.buttons &= ~bit;
    }

    _ = pushEvent(.{
        .event_type = if (pressed) .mouse_button_down else .mouse_button_up,
        .code = @intFromEnum(button),
        .value = if (pressed) @as(i32, 1) else @as(i32, 0),
        .timestamp = @truncate(pit.getTicks()),
    });
}

/// Update scroll wheel.
pub fn updateScroll(delta: i32) void {
    mouse_state.scroll += delta;
    _ = pushEvent(.{
        .event_type = .scroll,
        .code = 0,
        .value = delta,
        .timestamp = @truncate(pit.getTicks()),
    });
}

// ---- Keyboard mapping ----

/// Scancode set 1 to KeyCode mapping.
const scancode_to_keycode = [128]u8{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  // 0x00-0x09
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19, // 0x0A-0x13
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, // 0x14-0x1D
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39, // 0x1E-0x27
    40, 41, 42, 43, 44, 45, 46, 47, 48, 49, // 0x28-0x31
    50, 51, 52, 53, 54, 55, 56, 57, 58, 59, // 0x32-0x3B
    60, 61, 62, 63, 64, 65, 66, 67, 68, 69, // 0x3C-0x45
    70, 71, 72, 73, 74, 75, 76, 77, 78, 79, // 0x46-0x4F
    80, 81, 82, 83, 0,  0,  0,  87, 88, 0,  // 0x50-0x59
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x5A-0x63
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x64-0x6D
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x6E-0x77
    0,  0,  0,  0,  0,  0,  0,  0,            // 0x78-0x7F
};

/// KeyCode to ASCII character (lowercase, no modifiers).
const keycode_to_char = [90]u8{
    0,   0,   '1', '2', '3', '4', '5', '6', '7', '8', // 0-9
    '9', '0', '-', '=', 8,   '\t', 'q', 'w', 'e', 'r', // 10-19
    't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,  // 20-29
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', // 30-39
    '\'', '`', 0,  '\\', 'z', 'x', 'c', 'v', 'b', 'n', // 40-49
    'm', ',', '.', '/', 0,   '*', 0,   ' ', 0,   0,   // 50-59
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   // 60-69
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   // 70-79
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   // 80-89
};

/// Convert a scancode to a KeyCode.
pub fn scancodeToKeycode(scancode: u8) KeyCode {
    if (scancode >= 128) return .key_none;
    const kc = scancode_to_keycode[scancode];
    return @enumFromInt(kc);
}

/// Convert a KeyCode to an ASCII character. Returns 0 for non-printable.
pub fn keycodeToChar(kc: KeyCode) u8 {
    const idx = @intFromEnum(kc);
    if (idx >= 90) return 0;
    return keycode_to_char[idx];
}

/// Push a keyboard event (from IRQ handler).
pub fn pushKeyEvent(scancode: u8) void {
    const released = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;
    const kc = scancodeToKeycode(code);

    _ = pushEvent(.{
        .event_type = if (released) .key_release else .key_press,
        .code = @intFromEnum(kc),
        .value = if (released) @as(i32, 0) else @as(i32, 1),
        .timestamp = @truncate(pit.getTicks()),
    });
}

// ---- Debug / status ----

pub fn printDevices() void {
    vga.setColor(.yellow, .black);
    vga.write("Input Devices\n");
    vga.setColor(.light_grey, .black);

    if (device_count == 0) {
        vga.write("  No input devices registered\n");
        return;
    }

    vga.write("  IDX  TYPE       NAME                 EVENTS\n");

    var i: u8 = 0;
    while (i < device_count) : (i += 1) {
        const dev = &devices[i];
        if (!dev.active) continue;

        vga.write("  ");
        fmt.printDec(i);
        vga.write("    ");

        switch (dev.device_type) {
            .keyboard => vga.write("keyboard  "),
            .mouse => vga.write("mouse     "),
            .touchpad => vga.write("touchpad  "),
            .gamepad => vga.write("gamepad   "),
        }

        // Print name
        const name_slice = dev.name[0..dev.name_len];
        vga.write(name_slice);
        // Pad
        var pad: u8 = dev.name_len;
        while (pad < 22) : (pad += 1) vga.putChar(' ');

        fmt.printDec(dev.event_count);
        vga.putChar('\n');
    }

    vga.write("  Event queue: ");
    fmt.printDec(queue_count);
    vga.write("/");
    fmt.printDec(QUEUE_SIZE);
    vga.putChar('\n');

    vga.write("  Mouse: x=");
    printSigned(mouse_state.x);
    vga.write(" y=");
    printSigned(mouse_state.y);
    vga.write(" buttons=0x");
    fmt.printHex8(mouse_state.buttons);
    vga.putChar('\n');
}

fn printSigned(val: i32) void {
    if (val < 0) {
        vga.putChar('-');
        fmt.printDec(@intCast(-val));
    } else {
        fmt.printDec(@intCast(val));
    }
}
