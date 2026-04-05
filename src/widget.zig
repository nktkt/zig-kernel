// GUI Widget Toolkit -- labels, buttons, checkboxes, progress bars, text inputs
// Widgets are attached to windows and render into window content buffers

const window = @import("window.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");
const canvas = @import("canvas.zig");
const framebuf = @import("framebuf.zig");

// ---- Constants ----

pub const MAX_WIDGETS = 32;
pub const TEXT_LEN = 32;

// ---- Widget Types ----

pub const WidgetType = enum(u8) {
    label = 0,
    button = 1,
    checkbox = 2,
    progress_bar = 3,
    text_input = 4,
};

// ---- Widget State ----

pub const WidgetState = struct {
    checked: bool,
    progress_val: u8,
    progress_max: u8,
    pressed: bool,
    cursor_pos: u8,
};

// ---- Widget Struct ----

pub const Widget = struct {
    wtype: WidgetType,
    x: u16, // local coords within parent window content
    y: u16,
    w: u16,
    h: u16,
    text: [TEXT_LEN]u8,
    text_len: u8,
    state: WidgetState,
    parent_window: u8,
    active: bool,
};

// ---- Widget Storage ----

var widgets: [MAX_WIDGETS]Widget = initWidgets();
var widget_count: u8 = 0;

fn initWidgets() [MAX_WIDGETS]Widget {
    var ws: [MAX_WIDGETS]Widget = undefined;
    for (&ws) |*w| {
        w.active = false;
        w.wtype = .label;
        w.x = 0;
        w.y = 0;
        w.w = 0;
        w.h = 0;
        w.text = @splat(0);
        w.text_len = 0;
        w.state = .{
            .checked = false,
            .progress_val = 0,
            .progress_max = 100,
            .pressed = false,
            .cursor_pos = 0,
        };
        w.parent_window = 0;
    }
    return ws;
}

// ---- Find free slot ----

fn findFreeSlot() ?u8 {
    for (&widgets, 0..) |*w, i| {
        if (!w.active) return @truncate(i);
    }
    return null;
}

fn copyText(dest: *[TEXT_LEN]u8, src: []const u8) u8 {
    const len = if (src.len > TEXT_LEN) TEXT_LEN else src.len;
    dest.* = @splat(0);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @truncate(len);
}

// ---- Public API: Creation ----

/// Create a label widget
pub fn createLabel(win: u8, x: u16, y: u16, text: []const u8) ?u8 {
    const slot = findFreeSlot() orelse return null;
    var w = &widgets[slot];
    w.active = true;
    w.wtype = .label;
    w.parent_window = win;
    w.x = x;
    w.y = y;
    w.w = @truncate(font.measureString(text));
    w.h = font.CHAR_HEIGHT;
    w.text_len = copyText(&w.text, text);
    w.state = .{ .checked = false, .progress_val = 0, .progress_max = 100, .pressed = false, .cursor_pos = 0 };
    widget_count += 1;
    return slot;
}

/// Create a button widget
pub fn createButton(win: u8, x: u16, y: u16, w: u16, h: u16, text: []const u8) ?u8 {
    const slot = findFreeSlot() orelse return null;
    var wg = &widgets[slot];
    wg.active = true;
    wg.wtype = .button;
    wg.parent_window = win;
    wg.x = x;
    wg.y = y;
    wg.w = w;
    wg.h = h;
    wg.text_len = copyText(&wg.text, text);
    wg.state = .{ .checked = false, .progress_val = 0, .progress_max = 100, .pressed = false, .cursor_pos = 0 };
    widget_count += 1;
    return slot;
}

/// Create a checkbox widget
pub fn createCheckbox(win: u8, x: u16, y: u16, text: []const u8, checked: bool) ?u8 {
    const slot = findFreeSlot() orelse return null;
    var w = &widgets[slot];
    w.active = true;
    w.wtype = .checkbox;
    w.parent_window = win;
    w.x = x;
    w.y = y;
    w.w = 10 + @as(u16, @truncate(font.measureString(text))); // box + gap + text
    w.h = 10;
    w.text_len = copyText(&w.text, text);
    w.state = .{ .checked = checked, .progress_val = 0, .progress_max = 100, .pressed = false, .cursor_pos = 0 };
    widget_count += 1;
    return slot;
}

/// Create a progress bar widget
pub fn createProgressBar(win: u8, x: u16, y: u16, w: u16, value: u8, max_val: u8) ?u8 {
    const slot = findFreeSlot() orelse return null;
    var wg = &widgets[slot];
    wg.active = true;
    wg.wtype = .progress_bar;
    wg.parent_window = win;
    wg.x = x;
    wg.y = y;
    wg.w = w;
    wg.h = 10;
    wg.text_len = 0;
    wg.text = @splat(0);
    wg.state = .{
        .checked = false,
        .progress_val = value,
        .progress_max = if (max_val == 0) 100 else max_val,
        .pressed = false,
        .cursor_pos = 0,
    };
    widget_count += 1;
    return slot;
}

/// Create a text input widget
pub fn createTextInput(win: u8, x: u16, y: u16, w: u16) ?u8 {
    const slot = findFreeSlot() orelse return null;
    var wg = &widgets[slot];
    wg.active = true;
    wg.wtype = .text_input;
    wg.parent_window = win;
    wg.x = x;
    wg.y = y;
    wg.w = w;
    wg.h = 12;
    wg.text = @splat(0);
    wg.text_len = 0;
    wg.state = .{ .checked = false, .progress_val = 0, .progress_max = 100, .pressed = false, .cursor_pos = 0 };
    widget_count += 1;
    return slot;
}

/// Destroy a widget
pub fn destroyWidget(id: u8) void {
    if (id >= MAX_WIDGETS) return;
    if (!widgets[id].active) return;
    widgets[id].active = false;
    if (widget_count > 0) widget_count -= 1;
}

// ---- Public API: Drawing ----

/// Draw a widget into its parent window's content
pub fn drawWidget(id: u8) void {
    if (id >= MAX_WIDGETS) return;
    const wg = &widgets[id];
    if (!wg.active) return;

    const win_id = wg.parent_window;

    switch (wg.wtype) {
        .label => drawLabel(wg, win_id),
        .button => drawButton(wg, win_id),
        .checkbox => drawCheckbox(wg, win_id),
        .progress_bar => drawProgressBar(wg, win_id),
        .text_input => drawTextInput(wg, win_id),
    }
}

/// Draw all widgets belonging to a specific window
pub fn drawAllWidgets(win_id: u8) void {
    for (&widgets, 0..) |*wg, i| {
        if (wg.active and wg.parent_window == win_id) {
            drawWidget(@truncate(i));
        }
    }
}

// ---- Public API: Interaction ----

/// Handle a click on a widget (local coordinates within parent window)
/// Returns true if the click was consumed
pub fn handleWidgetClick(id: u8, lx: u16, ly: u16) bool {
    if (id >= MAX_WIDGETS) return false;
    var wg = &widgets[id];
    if (!wg.active) return false;

    // Check if click is within widget bounds
    if (lx < wg.x or ly < wg.y) return false;
    if (lx >= wg.x + wg.w or ly >= wg.y + wg.h) return false;

    switch (wg.wtype) {
        .button => {
            wg.state.pressed = true;
            return true;
        },
        .checkbox => {
            wg.state.checked = !wg.state.checked;
            return true;
        },
        .text_input => {
            // Focus the text input (mark pressed)
            wg.state.pressed = true;
            return true;
        },
        else => return false,
    }
}

/// Find which widget was clicked in a window (local coords)
/// Returns widget ID or null
pub fn findWidgetAt(win_id: u8, lx: u16, ly: u16) ?u8 {
    for (&widgets, 0..) |*wg, i| {
        if (!wg.active or wg.parent_window != win_id) continue;
        if (lx >= wg.x and lx < wg.x + wg.w and ly >= wg.y and ly < wg.y + wg.h) {
            return @truncate(i);
        }
    }
    return null;
}

// ---- Public API: State Accessors ----

pub fn setChecked(id: u8, val: bool) void {
    if (id >= MAX_WIDGETS) return;
    if (!widgets[id].active) return;
    widgets[id].state.checked = val;
}

pub fn getChecked(id: u8) bool {
    if (id >= MAX_WIDGETS) return false;
    if (!widgets[id].active) return false;
    return widgets[id].state.checked;
}

pub fn setProgress(id: u8, val: u8) void {
    if (id >= MAX_WIDGETS) return;
    if (!widgets[id].active) return;
    widgets[id].state.progress_val = val;
}

pub fn getProgress(id: u8) u8 {
    if (id >= MAX_WIDGETS) return 0;
    if (!widgets[id].active) return 0;
    return widgets[id].state.progress_val;
}

pub fn setText(id: u8, text: []const u8) void {
    if (id >= MAX_WIDGETS) return;
    if (!widgets[id].active) return;
    widgets[id].text_len = copyText(&widgets[id].text, text);
}

pub fn getText(id: u8) []const u8 {
    if (id >= MAX_WIDGETS) return &[_]u8{};
    if (!widgets[id].active) return &[_]u8{};
    return widgets[id].text[0..widgets[id].text_len];
}

/// Append a character to a text input widget
pub fn appendChar(id: u8, c: u8) void {
    if (id >= MAX_WIDGETS) return;
    var wg = &widgets[id];
    if (!wg.active or wg.wtype != .text_input) return;
    if (wg.text_len >= TEXT_LEN) return;
    wg.text[wg.text_len] = c;
    wg.text_len += 1;
    wg.state.cursor_pos = wg.text_len;
}

/// Delete the last character from a text input widget
pub fn deleteChar(id: u8) void {
    if (id >= MAX_WIDGETS) return;
    var wg = &widgets[id];
    if (!wg.active or wg.wtype != .text_input) return;
    if (wg.text_len == 0) return;
    wg.text_len -= 1;
    wg.text[wg.text_len] = 0;
    wg.state.cursor_pos = wg.text_len;
}

/// Get widget count
pub fn getWidgetCount() u8 {
    return widget_count;
}

// ---- Internal Drawing Functions ----

fn drawLabel(wg: *const Widget, win_id: u8) void {
    const text_color = theme.getColor(.text_color);
    window.writeText(win_id, wg.x, wg.y, wg.text[0..wg.text_len], text_color);
}

fn drawButton(wg: *const Widget, win_id: u8) void {
    const bg = if (wg.state.pressed) theme.getColor(.button_hover) else theme.getColor(.button_bg);
    const fg = theme.getColor(.button_fg);
    const shadow = theme.getColor(.shadow);

    // Fill button background
    var dy: u16 = 0;
    while (dy < wg.h) : (dy += 1) {
        var dx: u16 = 0;
        while (dx < wg.w) : (dx += 1) {
            window.setContentPixel(win_id, wg.x + dx, wg.y + dy, bg);
        }
    }

    // Border (top and left = highlight, bottom and right = shadow)
    const highlight = theme.getColor(.highlight);
    // Top edge
    var i: u16 = 0;
    while (i < wg.w) : (i += 1) {
        window.setContentPixel(win_id, wg.x + i, wg.y, highlight);
    }
    // Left edge
    i = 0;
    while (i < wg.h) : (i += 1) {
        window.setContentPixel(win_id, wg.x, wg.y + i, highlight);
    }
    // Bottom edge
    i = 0;
    while (i < wg.w) : (i += 1) {
        window.setContentPixel(win_id, wg.x + i, wg.y + wg.h -| 1, shadow);
    }
    // Right edge
    i = 0;
    while (i < wg.h) : (i += 1) {
        window.setContentPixel(win_id, wg.x + wg.w -| 1, wg.y + i, shadow);
    }

    // Center text
    const text_w: u16 = @truncate(font.measureString(wg.text[0..wg.text_len]));
    var tx: u16 = wg.x + 2;
    if (text_w < wg.w) {
        tx = wg.x + (wg.w - text_w) / 2;
    }
    const ty = wg.y + (wg.h -| font.CHAR_HEIGHT) / 2;
    window.writeText(win_id, tx, ty, wg.text[0..wg.text_len], fg);
}

fn drawCheckbox(wg: *const Widget, win_id: u8) void {
    const box_size: u16 = 8;
    const cb_bg = theme.getColor(.checkbox_bg);
    const border = theme.getColor(.window_border);

    // Draw checkbox box
    var dy: u16 = 0;
    while (dy < box_size) : (dy += 1) {
        var dx: u16 = 0;
        while (dx < box_size) : (dx += 1) {
            if (dx == 0 or dx == box_size - 1 or dy == 0 or dy == box_size - 1) {
                window.setContentPixel(win_id, wg.x + dx, wg.y + dy, border);
            } else {
                window.setContentPixel(win_id, wg.x + dx, wg.y + dy, cb_bg);
            }
        }
    }

    // Draw checkmark if checked
    if (wg.state.checked) {
        const check_color = theme.getColor(.checkbox_check);
        // Simple X checkmark inside the box
        window.setContentPixel(win_id, wg.x + 2, wg.y + 2, check_color);
        window.setContentPixel(win_id, wg.x + 3, wg.y + 3, check_color);
        window.setContentPixel(win_id, wg.x + 4, wg.y + 4, check_color);
        window.setContentPixel(win_id, wg.x + 5, wg.y + 5, check_color);
        window.setContentPixel(win_id, wg.x + 5, wg.y + 2, check_color);
        window.setContentPixel(win_id, wg.x + 4, wg.y + 3, check_color);
        window.setContentPixel(win_id, wg.x + 3, wg.y + 4, check_color);
        window.setContentPixel(win_id, wg.x + 2, wg.y + 5, check_color);
    }

    // Draw label text
    const text_color = theme.getColor(.text_color);
    window.writeText(win_id, wg.x + box_size + 3, wg.y, wg.text[0..wg.text_len], text_color);
}

fn drawProgressBar(wg: *const Widget, win_id: u8) void {
    const bg = theme.getColor(.progress_bg);
    const fill = theme.getColor(.progress_fill);
    const border = theme.getColor(.window_border);

    // Background
    var dy: u16 = 0;
    while (dy < wg.h) : (dy += 1) {
        var dx: u16 = 0;
        while (dx < wg.w) : (dx += 1) {
            if (dx == 0 or dx == wg.w - 1 or dy == 0 or dy == wg.h - 1) {
                window.setContentPixel(win_id, wg.x + dx, wg.y + dy, border);
            } else {
                window.setContentPixel(win_id, wg.x + dx, wg.y + dy, bg);
            }
        }
    }

    // Fill bar proportional to progress
    if (wg.state.progress_max > 0 and wg.w > 2) {
        const inner_w: u32 = @as(u32, wg.w) - 2;
        const fill_w: u32 = (inner_w * @as(u32, wg.state.progress_val)) / @as(u32, wg.state.progress_max);
        dy = 1;
        while (dy < wg.h - 1) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < fill_w) : (dx += 1) {
                window.setContentPixel(win_id, wg.x + 1 + @as(u16, @truncate(dx)), wg.y + dy, fill);
            }
        }
    }
}

fn drawTextInput(wg: *const Widget, win_id: u8) void {
    const bg = theme.getColor(.input_bg);
    const border = theme.getColor(.input_border);
    const text_color = theme.getColor(.input_text);

    // Background with border
    var dy: u16 = 0;
    while (dy < wg.h) : (dy += 1) {
        var dx: u16 = 0;
        while (dx < wg.w) : (dx += 1) {
            if (dx == 0 or dx == wg.w - 1 or dy == 0 or dy == wg.h - 1) {
                window.setContentPixel(win_id, wg.x + dx, wg.y + dy, border);
            } else {
                window.setContentPixel(win_id, wg.x + dx, wg.y + dy, bg);
            }
        }
    }

    // Text content
    if (wg.text_len > 0) {
        window.writeText(win_id, wg.x + 2, wg.y + 2, wg.text[0..wg.text_len], text_color);
    }

    // Cursor (blinking simulated as always-on here)
    if (wg.state.pressed) {
        const cursor_x = wg.x + 2 + @as(u16, wg.state.cursor_pos) * font.CHAR_WIDTH;
        if (cursor_x < wg.x + wg.w - 2) {
            var cy: u16 = 0;
            while (cy < font.CHAR_HEIGHT) : (cy += 1) {
                window.setContentPixel(win_id, cursor_x, wg.y + 2 + cy, text_color);
            }
        }
    }
}

// ---- Demo ----

/// Create sample widgets in a window to demonstrate the toolkit
pub fn demo(win_id: u8) void {
    // Label
    _ = createLabel(win_id, 4, 2, "Widgets Demo");

    // Button
    _ = createButton(win_id, 4, 14, 50, 14, "Click");

    // Checkbox
    _ = createCheckbox(win_id, 60, 14, "Opt", true);

    // Progress bar
    _ = createProgressBar(win_id, 4, 32, 80, 65, 100);

    // Text input
    if (createTextInput(win_id, 4, 46, 80)) |ti| {
        setText(ti, "Hello");
    }

    // Draw all widgets
    drawAllWidgets(win_id);
}
