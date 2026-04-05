// Window Manager -- Mode 13h (320x200) windowing system
// Manages up to 8 overlapping windows with title bars, borders, and z-ordering

const framebuf = @import("framebuf.zig");
const canvas = @import("canvas.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");

// ---- Constants ----

pub const MAX_WINDOWS = 8;
pub const TITLE_LEN = 16;
pub const TITLEBAR_HEIGHT: u32 = 12;
pub const BORDER_WIDTH: u32 = 1;
pub const CLOSE_BTN_SIZE: u32 = 8;
const SCREEN_W: u32 = 320;
const SCREEN_H: u32 = 200;

// Maximum content buffer: window content is rendered into this buffer
// then composited. Max window size 160x120 content area.
const MAX_CONTENT_W = 160;
const MAX_CONTENT_H = 120;
const CONTENT_BUF_SIZE = MAX_CONTENT_W * MAX_CONTENT_H;

// ---- Window Struct ----

pub const Window = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16, // total height including titlebar and border
    title: [TITLE_LEN]u8,
    title_len: u8,
    visible: bool,
    focused: bool,
    z_order: u8,
    active: bool,
    content_buf: [CONTENT_BUF_SIZE]u8,

    /// Get content area width (inside borders)
    pub fn contentWidth(self: *const Window) u16 {
        if (self.width <= 2 * @as(u16, BORDER_WIDTH)) return 0;
        return self.width - 2 * @as(u16, BORDER_WIDTH);
    }

    /// Get content area height (below titlebar, inside borders)
    pub fn contentHeight(self: *const Window) u16 {
        const overhead = @as(u16, TITLEBAR_HEIGHT) + 2 * @as(u16, BORDER_WIDTH);
        if (self.height <= overhead) return 0;
        return self.height - overhead;
    }

    /// Get content area X origin (screen coordinates)
    pub fn contentX(self: *const Window) u16 {
        return self.x + @as(u16, BORDER_WIDTH);
    }

    /// Get content area Y origin (screen coordinates)
    pub fn contentY(self: *const Window) u16 {
        return self.y + @as(u16, TITLEBAR_HEIGHT) + @as(u16, BORDER_WIDTH);
    }
};

// ---- Window Storage ----

var windows: [MAX_WINDOWS]Window = initWindows();
var window_count: u8 = 0;
var next_z: u8 = 0;

fn initWindows() [MAX_WINDOWS]Window {
    var ws: [MAX_WINDOWS]Window = undefined;
    for (&ws) |*w| {
        w.active = false;
        w.visible = false;
        w.focused = false;
        w.z_order = 0;
        w.x = 0;
        w.y = 0;
        w.width = 0;
        w.height = 0;
        w.title = @splat(0);
        w.title_len = 0;
        w.content_buf = @splat(0);
    }
    return ws;
}

// ---- Public API ----

/// Create a new window. Returns window ID (0-7) or null if no slots.
pub fn createWindow(title_str: []const u8, x: u16, y: u16, w: u16, h: u16) ?u8 {
    // Find free slot
    for (&windows, 0..) |*win, i| {
        if (!win.active) {
            win.active = true;
            win.visible = true;
            win.focused = false;
            win.x = x;
            win.y = y;
            win.width = w;
            win.height = h;
            win.z_order = next_z;
            next_z +%= 1;

            // Copy title
            win.title = @splat(0);
            const len = if (title_str.len > TITLE_LEN) TITLE_LEN else title_str.len;
            for (0..len) |j| {
                win.title[j] = title_str[j];
            }
            win.title_len = @truncate(len);

            // Clear content buffer
            win.content_buf = @splat(theme.getColor(.window_bg));

            window_count += 1;
            focusWindow(@truncate(i));
            return @truncate(i);
        }
    }
    return null;
}

/// Destroy a window
pub fn destroyWindow(id: u8) void {
    if (id >= MAX_WINDOWS) return;
    if (!windows[id].active) return;
    windows[id].active = false;
    windows[id].visible = false;
    windows[id].focused = false;
    if (window_count > 0) window_count -= 1;
}

/// Move a window to new position
pub fn moveWindow(id: u8, x: u16, y: u16) void {
    if (id >= MAX_WINDOWS) return;
    if (!windows[id].active) return;
    windows[id].x = x;
    windows[id].y = y;
}

/// Resize a window
pub fn resizeWindow(id: u8, w: u16, h: u16) void {
    if (id >= MAX_WINDOWS) return;
    if (!windows[id].active) return;
    windows[id].width = w;
    windows[id].height = h;
}

/// Bring a window to front and give it focus
pub fn focusWindow(id: u8) void {
    if (id >= MAX_WINDOWS) return;
    if (!windows[id].active) return;

    // Remove focus from all windows
    for (&windows) |*w| {
        w.focused = false;
    }

    // Give this window the highest z-order and focus
    windows[id].focused = true;
    windows[id].z_order = next_z;
    next_z +%= 1;
}

/// Draw a single window (border, titlebar, content)
pub fn drawWindow(id: u8) void {
    if (id >= MAX_WINDOWS) return;
    const win = &windows[id];
    if (!win.active or !win.visible) return;

    const wx: u32 = win.x;
    const wy: u32 = win.y;
    const ww: u32 = win.width;
    const wh: u32 = win.height;

    // Border
    const border_color: u32 = theme.getColor(.window_border);
    framebuf.drawRect(wx, wy, ww, wh, border_color);

    // Title bar background
    const tb_color: u32 = if (win.focused) theme.getColor(.titlebar_bg) else theme.getColor(.shadow);
    framebuf.fillRect(wx + BORDER_WIDTH, wy + BORDER_WIDTH, ww -| (2 * BORDER_WIDTH), TITLEBAR_HEIGHT -| BORDER_WIDTH, tb_color);

    // Title text (centered in titlebar)
    const title_slice = win.title[0..win.title_len];
    const text_w = font.measureString(title_slice);
    const title_fg: u32 = theme.getColor(.titlebar_fg);
    const content_w = ww -| (2 * BORDER_WIDTH);
    var tx: u32 = wx + BORDER_WIDTH;
    if (text_w < content_w) {
        tx = wx + BORDER_WIDTH + (content_w - text_w) / 2;
    }
    const ty: u32 = wy + BORDER_WIDTH + 2; // 2px padding from top
    font.drawString8x8(tx, ty, title_slice, title_fg);

    // Close button (top-right corner of titlebar)
    const close_x = wx + ww -| (BORDER_WIDTH + CLOSE_BTN_SIZE + 1);
    const close_y = wy + BORDER_WIDTH + 1;
    const close_bg: u32 = theme.getColor(.close_btn);
    const close_fg: u32 = theme.getColor(.close_btn_fg);
    framebuf.fillRect(close_x, close_y, CLOSE_BTN_SIZE, CLOSE_BTN_SIZE, close_bg);
    // Draw X in close button
    canvas.drawLine(@intCast(close_x + 1), @intCast(close_y + 1), @intCast(close_x + CLOSE_BTN_SIZE - 2), @intCast(close_y + CLOSE_BTN_SIZE - 2), close_fg);
    canvas.drawLine(@intCast(close_x + CLOSE_BTN_SIZE - 2), @intCast(close_y + 1), @intCast(close_x + 1), @intCast(close_y + CLOSE_BTN_SIZE - 2), close_fg);

    // Content area background
    const cx: u32 = win.contentX();
    const cy: u32 = win.contentY();
    const cw: u32 = win.contentWidth();
    const ch: u32 = win.contentHeight();
    const bg_color: u32 = theme.getColor(.window_bg);
    framebuf.fillRect(cx, cy, cw, ch, bg_color);

    // Blit content buffer to screen
    blitContent(id);
}

/// Render all visible windows (back-to-front by z_order)
pub fn renderAll() void {
    // Fill desktop background
    const desktop_color: u32 = theme.getColor(.desktop_bg);
    framebuf.fillRect(0, 0, SCREEN_W, SCREEN_H, desktop_color);

    // Build sorted order by z_order
    var order: [MAX_WINDOWS]u8 = undefined;
    var n: u8 = 0;
    for (0..MAX_WINDOWS) |i| {
        if (windows[i].active and windows[i].visible) {
            order[n] = @truncate(i);
            n += 1;
        }
    }

    // Simple insertion sort by z_order (ascending = back to front)
    if (n > 1) {
        var i: u8 = 1;
        while (i < n) : (i += 1) {
            var j: u8 = i;
            while (j > 0 and windows[order[j]].z_order < windows[order[j - 1]].z_order) {
                const tmp = order[j];
                order[j] = order[j - 1];
                order[j - 1] = tmp;
                j -= 1;
            }
        }
    }

    // Draw each window
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        drawWindow(order[i]);
    }
}

/// Process a mouse click at screen coordinates
/// Returns: window ID that was clicked, or null
pub fn handleClick(mx: u16, my: u16) ?u8 {
    // Check windows from front to back (highest z_order first)
    var best_id: ?u8 = null;
    var best_z: u8 = 0;

    for (&windows, 0..) |*w, i| {
        if (!w.active or !w.visible) continue;
        if (mx >= w.x and mx < w.x + w.width and my >= w.y and my < w.y + w.height) {
            if (best_id == null or w.z_order > best_z) {
                best_id = @truncate(i);
                best_z = w.z_order;
            }
        }
    }

    if (best_id) |id| {
        const win = &windows[id];

        // Check if click is on close button
        const close_x = win.x + win.width -| (@as(u16, BORDER_WIDTH) + @as(u16, CLOSE_BTN_SIZE) + 1);
        const close_y = win.y + @as(u16, BORDER_WIDTH) + 1;
        if (mx >= close_x and mx < close_x + @as(u16, CLOSE_BTN_SIZE) and
            my >= close_y and my < close_y + @as(u16, CLOSE_BTN_SIZE))
        {
            destroyWindow(id);
            return id;
        }

        // Check if click is on title bar (for dragging/focus)
        if (my >= win.y and my < win.y + @as(u16, TITLEBAR_HEIGHT)) {
            focusWindow(id);
            return id;
        }

        // Click is in content area
        focusWindow(id);
        return id;
    }

    return null;
}

/// Write text into a window's content buffer at local coordinates
pub fn writeText(id: u8, lx: u16, ly: u16, text: []const u8, color: u8) void {
    if (id >= MAX_WINDOWS) return;
    const win = &windows[id];
    if (!win.active) return;

    const cw: u32 = win.contentWidth();
    const ch: u32 = win.contentHeight();
    if (cw == 0 or ch == 0) return;

    // Write text characters into content buffer using 8x8 font layout
    var cx: u32 = lx;
    for (text) |c| {
        if (c == '\n') continue;
        if (c < 32 or c > 126) continue;

        // Render glyph bits into content buffer
        renderGlyphToBuf(&win.content_buf, cw, ch, cx, ly, c, color);
        cx += font.CHAR_WIDTH;
        if (cx + font.CHAR_WIDTH > cw) break;
    }
}

/// Clear a window's content area with a color
pub fn clearContent(id: u8, color: u8) void {
    if (id >= MAX_WINDOWS) return;
    if (!windows[id].active) return;
    windows[id].content_buf = @splat(color);
}

/// Set a pixel in a window's content buffer
pub fn setContentPixel(id: u8, lx: u16, ly: u16, color: u8) void {
    if (id >= MAX_WINDOWS) return;
    const win = &windows[id];
    if (!win.active) return;
    const cw: u32 = win.contentWidth();
    const ch: u32 = win.contentHeight();
    if (lx >= cw or ly >= ch) return;
    const off: usize = @as(usize, ly) * @as(usize, cw) + @as(usize, lx);
    if (off < CONTENT_BUF_SIZE) {
        win.content_buf[off] = color;
    }
}

/// Get a window pointer (read-only) for inspection
pub fn getWindow(id: u8) ?*const Window {
    if (id >= MAX_WINDOWS) return null;
    if (!windows[id].active) return null;
    return &windows[id];
}

/// Get mutable window pointer
pub fn getWindowMut(id: u8) ?*Window {
    if (id >= MAX_WINDOWS) return null;
    if (!windows[id].active) return null;
    return &windows[id];
}

/// Get number of active windows
pub fn getWindowCount() u8 {
    return window_count;
}

/// Check if a point is inside a window's content area (screen coords)
pub fn isInContent(id: u8, sx: u16, sy: u16) bool {
    if (id >= MAX_WINDOWS) return false;
    const win = &windows[id];
    if (!win.active) return false;
    const cx = win.contentX();
    const cy = win.contentY();
    return sx >= cx and sx < cx + win.contentWidth() and sy >= cy and sy < cy + win.contentHeight();
}

/// Convert screen coordinates to window-local content coordinates
pub fn screenToLocal(id: u8, sx: u16, sy: u16) ?[2]u16 {
    if (id >= MAX_WINDOWS) return null;
    const win = &windows[id];
    if (!win.active) return null;
    const cx = win.contentX();
    const cy = win.contentY();
    if (sx < cx or sy < cy) return null;
    const lx = sx - cx;
    const ly = sy - cy;
    if (lx >= win.contentWidth() or ly >= win.contentHeight()) return null;
    return .{ lx, ly };
}

// ---- Demo ----

/// Create 3 sample windows and render them
pub fn demo() void {
    // Window 1: Main
    if (createWindow("Main", 10, 10, 120, 80)) |id| {
        clearContent(id, theme.getColor(.window_bg));
        writeText(id, 4, 4, "Hello!", 0);
        writeText(id, 4, 14, "Window 1", 1);
    }

    // Window 2: Info
    if (createWindow("Info", 80, 40, 100, 70)) |id| {
        clearContent(id, theme.getColor(.window_bg));
        writeText(id, 4, 4, "320x200", 4);
        writeText(id, 4, 14, "Mode 13h", 2);
    }

    // Window 3: Status
    if (createWindow("Status", 150, 20, 130, 90)) |id| {
        clearContent(id, theme.getColor(.window_bg));
        writeText(id, 4, 4, "OK", 10);
    }

    renderAll();
}

// ---- Internal Helpers ----

/// Blit a window's content buffer to the screen framebuffer
fn blitContent(id: u8) void {
    if (id >= MAX_WINDOWS) return;
    const win = &windows[id];
    if (!win.active or !win.visible) return;

    const cx: u32 = win.contentX();
    const cy: u32 = win.contentY();
    const cw: u32 = win.contentWidth();
    const ch: u32 = win.contentHeight();

    var py: u32 = 0;
    while (py < ch) : (py += 1) {
        var px: u32 = 0;
        while (px < cw) : (px += 1) {
            const off: usize = py * @as(usize, cw) + px;
            if (off < CONTENT_BUF_SIZE) {
                framebuf.putPixel(cx + px, cy + py, win.content_buf[off]);
            }
        }
    }
}

/// Render an 8x8 font glyph into a content buffer
fn renderGlyphToBuf(buf: []u8, buf_w: u32, buf_h: u32, gx: u32, gy: u32, char: u8, color: u8) void {
    if (char < 32 or char > 126) return;

    // Access the font data through the public draw function
    // Instead, we manually render using the 8x8 font patterns
    // We replicate the font lookup here to write into the buffer directly
    var row: u32 = 0;
    while (row < 8) : (row += 1) {
        if (gy + row >= buf_h) break;
        var col: u32 = 0;
        while (col < 8) : (col += 1) {
            if (gx + col >= buf_w) break;
            // We need to check the font bit -- use font module's drawChar
            // Since we can't directly access font data, we'll use a helper approach:
            // Write a colored pixel at the buffer position
            const off: usize = (gy + row) * @as(usize, buf_w) + (gx + col);
            if (off < buf.len) {
                // Check font bit by calling a rendering test
                // Actually, let's use a simpler approach: render to screen then copy
                // Better: embed a minimal glyph check
                if (getGlyphBit(char, row, col)) {
                    buf[off] = color;
                }
            }
        }
    }
}

/// Check if a specific bit in an 8x8 glyph is set
/// Uses the same font data as font.zig
fn getGlyphBit(char: u8, row: u32, col: u32) bool {
    if (char < 32 or char > 126) return false;
    if (row >= 8 or col >= 8) return false;
    const idx: usize = char - 32;
    const bits = mini_font[idx][@intCast(row)];
    return (bits & (@as(u8, 0x80) >> @truncate(col))) != 0;
}

// Minimal inline 8x8 font for content buffer rendering
// This duplicates a subset; full set matches font.zig
const mini_font: [95][8]u8 = initMiniFont();

fn initMiniFont() [95][8]u8 {
    var data: [95][8]u8 = @splat([_]u8{0} ** 8);

    // Space (32) - all zeros
    data[1] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 }; // !
    data[2] = .{ 0x6C, 0x6C, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00 }; // "
    data[3] = .{ 0x24, 0x7E, 0x24, 0x24, 0x7E, 0x24, 0x00, 0x00 }; // #
    data[4] = .{ 0x18, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x18, 0x00 }; // $
    data[5] = .{ 0x62, 0x64, 0x08, 0x10, 0x26, 0x46, 0x00, 0x00 }; // %
    data[6] = .{ 0x38, 0x44, 0x38, 0x3A, 0x44, 0x3A, 0x00, 0x00 }; // &
    data[7] = .{ 0x18, 0x18, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00 }; // '
    data[8] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 }; // (
    data[9] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 }; // )
    data[10] = .{ 0x00, 0x24, 0x18, 0x7E, 0x18, 0x24, 0x00, 0x00 }; // *
    data[11] = .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 }; // +
    data[12] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ,
    data[13] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 }; // -
    data[14] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 }; // .
    data[15] = .{ 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00, 0x00 }; // /
    data[16] = .{ 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00 }; // 0
    data[17] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 }; // 1
    data[18] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x30, 0x60, 0x7E, 0x00 }; // 2
    data[19] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 }; // 3
    data[20] = .{ 0x0C, 0x1C, 0x2C, 0x4C, 0x7E, 0x0C, 0x0C, 0x00 }; // 4
    data[21] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // 5
    data[22] = .{ 0x3C, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // 6
    data[23] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00 }; // 7
    data[24] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 }; // 8
    data[25] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00 }; // 9
    data[26] = .{ 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00 }; // :
    data[27] = .{ 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x30, 0x00 }; // ;
    data[28] = .{ 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 }; // <
    data[29] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 }; // =
    data[30] = .{ 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00 }; // >
    data[31] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 }; // ?
    data[32] = .{ 0x3C, 0x66, 0x6E, 0x6A, 0x6E, 0x60, 0x3C, 0x00 }; // @
    data[33] = .{ 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 }; // A
    data[34] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 }; // B
    data[35] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 }; // C
    data[36] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 }; // D
    data[37] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 }; // E
    data[38] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // F
    data[39] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 }; // G
    data[40] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 }; // H
    data[41] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // I
    data[42] = .{ 0x1E, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // J
    data[43] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 }; // K
    data[44] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 }; // L
    data[45] = .{ 0xC6, 0xEE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0x00 }; // M
    data[46] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 }; // N
    data[47] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // O
    data[48] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // P
    data[49] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 }; // Q
    data[50] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 }; // R
    data[51] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 }; // S
    data[52] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 }; // T
    data[53] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // U
    data[54] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // V
    data[55] = .{ 0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 }; // W
    data[56] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 }; // X
    data[57] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 }; // Y
    data[58] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 }; // Z
    data[59] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 }; // [
    data[60] = .{ 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x00, 0x00 }; // backslash
    data[61] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 }; // ]
    data[62] = .{ 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00 }; // ^
    data[63] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00 }; // _
    data[64] = .{ 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 }; // `
    data[65] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 }; // a
    data[66] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 }; // b
    data[67] = .{ 0x00, 0x00, 0x3C, 0x60, 0x60, 0x60, 0x3C, 0x00 }; // c
    data[68] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // d
    data[69] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 }; // e
    data[70] = .{ 0x0E, 0x18, 0x18, 0x3E, 0x18, 0x18, 0x18, 0x00 }; // f
    data[71] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // g
    data[72] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // h
    data[73] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // i
    data[74] = .{ 0x06, 0x00, 0x0E, 0x06, 0x06, 0x06, 0x66, 0x3C }; // j
    data[75] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 }; // k
    data[76] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // l
    data[77] = .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 }; // m
    data[78] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // n
    data[79] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // o
    data[80] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 }; // p
    data[81] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 }; // q
    data[82] = .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 }; // r
    data[83] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 }; // s
    data[84] = .{ 0x18, 0x18, 0x7E, 0x18, 0x18, 0x18, 0x0E, 0x00 }; // t
    data[85] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // u
    data[86] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // v
    data[87] = .{ 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xFE, 0x6C, 0x00 }; // w
    data[88] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 }; // x
    data[89] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // y
    data[90] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // z
    data[91] = .{ 0x0C, 0x18, 0x18, 0x30, 0x18, 0x18, 0x0C, 0x00 }; // {
    data[92] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 }; // |
    data[93] = .{ 0x30, 0x18, 0x18, 0x0C, 0x18, 0x18, 0x30, 0x00 }; // }
    data[94] = .{ 0x00, 0x00, 0x32, 0x4C, 0x00, 0x00, 0x00, 0x00 }; // ~

    return data;
}
