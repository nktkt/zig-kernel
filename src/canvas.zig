// 2D Drawing Primitives -- works on top of framebuf
// Bresenham line, midpoint circle, scanline fill, bezier curves, flood fill

const framebuf = @import("framebuf.zig");

// ---- Screen bounds ----

const SCREEN_W: u32 = 320;
const SCREEN_H: u32 = 200;

fn screenW() u32 {
    const w = framebuf.getWidth();
    return if (w == 0) SCREEN_W else w;
}

fn screenH() u32 {
    const h = framebuf.getHeight();
    return if (h == 0) SCREEN_H else h;
}

// ---- Bresenham's Line Algorithm ----

pub fn drawLine(x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    var px0 = x0;
    var py0 = y0;
    const px1 = x1;
    const py1 = y1;

    const dx = absI32(px1 - px0);
    const dy = -absI32(py1 - py0);
    var sx: i32 = if (px0 < px1) 1 else -1;
    var sy: i32 = if (py0 < py1) 1 else -1;
    var err = dx + dy;

    while (true) {
        plotClipped(px0, py0, color);

        if (px0 == px1 and py0 == py1) break;

        const e2 = 2 * err;
        if (e2 >= dy) {
            if (px0 == px1) break;
            err += dy;
            px0 += sx;
        }
        if (e2 <= dx) {
            if (py0 == py1) break;
            err += dx;
            py0 += sy;
        }
    }
    // Suppress unused capture warnings
    _ = &sx;
    _ = &sy;
}

// ---- Midpoint Circle Algorithm ----

pub fn drawCircle(cx: i32, cy: i32, r: i32, color: u32) void {
    if (r <= 0) return;
    var x: i32 = 0;
    var y: i32 = r;
    var d: i32 = 1 - r;

    while (x <= y) {
        plotClipped(cx + x, cy + y, color);
        plotClipped(cx - x, cy + y, color);
        plotClipped(cx + x, cy - y, color);
        plotClipped(cx - x, cy - y, color);
        plotClipped(cx + y, cy + x, color);
        plotClipped(cx - y, cy + x, color);
        plotClipped(cx + y, cy - x, color);
        plotClipped(cx - y, cy - x, color);

        if (d < 0) {
            d += 2 * x + 3;
        } else {
            d += 2 * (x - y) + 5;
            y -= 1;
        }
        x += 1;
    }
}

// ---- Filled Circle (scanline) ----

pub fn fillCircle(cx: i32, cy: i32, r: i32, color: u32) void {
    if (r <= 0) {
        plotClipped(cx, cy, color);
        return;
    }
    var y: i32 = -r;
    while (y <= r) : (y += 1) {
        // x^2 + y^2 <= r^2  =>  x <= sqrt(r^2 - y^2)
        // Use integer approximation
        const yy = y * y;
        const rr = r * r;
        if (yy > rr) continue;
        var x: i32 = 0;
        while (x * x <= rr - yy) : (x += 1) {}
        x -= 1;
        // Draw horizontal span from cx-x to cx+x at row cy+y
        drawHLine(cx - x, cx + x, cy + y, color);
    }
}

// ---- Triangle Outline ----

pub fn drawTriangle(x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    drawLine(x0, y0, x1, y1, color);
    drawLine(x1, y1, x2, y2, color);
    drawLine(x2, y2, x0, y0, color);
}

// ---- Filled Triangle (scanline) ----

pub fn fillTriangle(x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    // Sort vertices by y: v0.y <= v1.y <= v2.y
    var vx0 = x0;
    var vy0 = y0;
    var vx1 = x1;
    var vy1 = y1;
    var vx2 = x2;
    var vy2 = y2;

    if (vy0 > vy1) {
        swap(&vx0, &vx1);
        swap(&vy0, &vy1);
    }
    if (vy0 > vy2) {
        swap(&vx0, &vx2);
        swap(&vy0, &vy2);
    }
    if (vy1 > vy2) {
        swap(&vx1, &vx2);
        swap(&vy1, &vy2);
    }

    if (vy2 == vy0) {
        // Degenerate: horizontal line
        var minx = minI32(vx0, minI32(vx1, vx2));
        var maxx = maxI32(vx0, maxI32(vx1, vx2));
        drawHLine(minx, maxx, vy0, color);
        _ = &minx;
        _ = &maxx;
        return;
    }

    // Scanline fill
    var y: i32 = vy0;
    while (y <= vy2) : (y += 1) {
        var xa: i32 = undefined;
        var xb: i32 = undefined;

        // Edge from v0 to v2 always spans the full height
        if (vy2 != vy0) {
            xa = vx0 + @divTrunc((y - vy0) * (vx2 - vx0), (vy2 - vy0));
        } else {
            xa = vx0;
        }

        // Second edge depends on which half we're in
        if (y < vy1) {
            // Upper half: v0 to v1
            if (vy1 != vy0) {
                xb = vx0 + @divTrunc((y - vy0) * (vx1 - vx0), (vy1 - vy0));
            } else {
                xb = vx0;
            }
        } else {
            // Lower half: v1 to v2
            if (vy2 != vy1) {
                xb = vx1 + @divTrunc((y - vy1) * (vx2 - vx1), (vy2 - vy1));
            } else {
                xb = vx1;
            }
        }

        if (xa > xb) swap(&xa, &xb);
        drawHLine(xa, xb, y, color);
    }
}

// ---- Ellipse Outline (Midpoint Algorithm) ----

pub fn drawEllipse(cx: i32, cy: i32, rx: i32, ry: i32, color: u32) void {
    if (rx <= 0 or ry <= 0) return;

    var x: i32 = 0;
    var y: i32 = ry;

    // Region 1: slope < 1
    const rx2: i64 = @as(i64, rx) * @as(i64, rx);
    const ry2: i64 = @as(i64, ry) * @as(i64, ry);
    var px: i64 = 0;
    var py: i64 = 2 * rx2 * @as(i64, y);
    var d1: i64 = ry2 - rx2 * @as(i64, ry) + @divTrunc(rx2, 4);

    while (px < py) {
        plotClipped(cx + x, cy + y, color);
        plotClipped(cx - x, cy + y, color);
        plotClipped(cx + x, cy - y, color);
        plotClipped(cx - x, cy - y, color);

        x += 1;
        px += 2 * ry2;
        if (d1 < 0) {
            d1 += ry2 + px;
        } else {
            y -= 1;
            py -= 2 * rx2;
            d1 += ry2 + px - py;
        }
    }

    // Region 2: slope >= 1
    var d2: i64 = ry2 * @as(i64, (2 * x + 1)) * @as(i64, (2 * x + 1));
    d2 = @divTrunc(d2, 4) + rx2 * @as(i64, (y - 1)) * @as(i64, (y - 1)) - rx2 * ry2;

    while (y >= 0) {
        plotClipped(cx + x, cy + y, color);
        plotClipped(cx - x, cy + y, color);
        plotClipped(cx + x, cy - y, color);
        plotClipped(cx - x, cy - y, color);

        y -= 1;
        py -= 2 * rx2;
        if (d2 > 0) {
            d2 += rx2 - py;
        } else {
            x += 1;
            px += 2 * ry2;
            d2 += rx2 - py + px;
        }
    }
}

// ---- Polygon from Point Array ----

pub const Point = struct {
    x: i32,
    y: i32,
};

pub fn drawPolygon(points: []const Point, color: u32) void {
    if (points.len < 2) return;
    var i: usize = 0;
    while (i < points.len - 1) : (i += 1) {
        drawLine(points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, color);
    }
    // Close the polygon
    drawLine(points[points.len - 1].x, points[points.len - 1].y, points[0].x, points[0].y, color);
}

// ---- Stack-based Flood Fill ----
// Max 256 entries on the fill stack (suitable for small areas in Mode 13h)

const FLOOD_STACK_SIZE = 256;

pub fn floodFill(x: i32, y: i32, new_color: u32) void {
    const sw = screenW();
    const sh = screenH();

    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= sw or uy >= sh) return;

    const old_color = framebuf.getPixel(ux, uy);
    if (old_color == new_color) return;

    var stack: [FLOOD_STACK_SIZE][2]i32 = undefined;
    var sp: usize = 0;

    // Push starting pixel
    stack[0] = .{ x, y };
    sp = 1;

    while (sp > 0) {
        sp -= 1;
        const px = stack[sp][0];
        const py = stack[sp][1];

        if (px < 0 or py < 0) continue;
        const upx: u32 = @intCast(px);
        const upy: u32 = @intCast(py);
        if (upx >= sw or upy >= sh) continue;

        if (framebuf.getPixel(upx, upy) != old_color) continue;

        framebuf.putPixel(upx, upy, new_color);

        // Push neighbors (4-connected)
        if (sp + 4 <= FLOOD_STACK_SIZE) {
            stack[sp] = .{ px + 1, py };
            sp += 1;
            stack[sp] = .{ px - 1, py };
            sp += 1;
            stack[sp] = .{ px, py + 1 };
            sp += 1;
            stack[sp] = .{ px, py - 1 };
            sp += 1;
        }
    }
}

// ---- Quadratic Bezier Curve ----

pub fn drawBezier(x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    // Evaluate quadratic bezier B(t) = (1-t)^2*P0 + 2(1-t)t*P1 + t^2*P2
    // Using fixed-point with 256 steps
    const steps: i32 = 64;
    var prev_x: i32 = x0;
    var prev_y: i32 = y0;

    var i: i32 = 1;
    while (i <= steps) : (i += 1) {
        // t = i / steps, using scaled arithmetic (scale = steps)
        const t = i;
        const mt = steps - t; // (1-t) scaled

        // B(t) = mt^2*P0 + 2*mt*t*P1 + t^2*P2, all divided by steps^2
        const denom = steps * steps;
        const bx = @divTrunc(mt * mt * x0 + 2 * mt * t * x1 + t * t * x2, denom);
        const by = @divTrunc(mt * mt * y0 + 2 * mt * t * y1 + t * t * y2, denom);

        drawLine(prev_x, prev_y, bx, by, color);
        prev_x = bx;
        prev_y = by;
    }
}

// ---- Utility Functions ----

/// Draw a clipped pixel (signed coordinates)
fn plotClipped(x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= screenW() or uy >= screenH()) return;
    framebuf.putPixel(ux, uy, color);
}

/// Draw horizontal line from xa to xb at row y (clipped)
fn drawHLine(xa: i32, xb: i32, y: i32, color: u32) void {
    if (y < 0 or y >= @as(i32, @intCast(screenH()))) return;
    var start = xa;
    var end = xb;
    if (start > end) swap(&start, &end);
    if (end < 0) return;
    const sw_i: i32 = @intCast(screenW());
    if (start >= sw_i) return;
    if (start < 0) start = 0;
    if (end >= sw_i) end = sw_i - 1;

    var x: i32 = start;
    while (x <= end) : (x += 1) {
        framebuf.putPixel(@intCast(x), @intCast(y), color);
    }
}

fn swap(a: *i32, b: *i32) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

fn absI32(x: i32) i32 {
    return if (x < 0) -x else x;
}

fn minI32(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

fn maxI32(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}

// ---- Demo ----

/// Draw some shapes to demonstrate canvas primitives
pub fn demo() void {
    // Line from corners
    drawLine(0, 0, 100, 60, 15);
    drawLine(0, 60, 100, 0, 14);

    // Circle
    drawCircle(160, 100, 30, 10);
    fillCircle(250, 50, 20, 4);

    // Triangle
    drawTriangle(200, 150, 250, 180, 180, 180, 11);
    fillTriangle(30, 130, 80, 170, 10, 170, 2);

    // Ellipse
    drawEllipse(160, 100, 50, 25, 13);

    // Bezier
    drawBezier(10, 10, 80, 190, 310, 10, 14);

    // Polygon (pentagon)
    const pent = [5]Point{
        .{ .x = 280, .y = 100 },
        .{ .x = 310, .y = 120 },
        .{ .x = 300, .y = 150 },
        .{ .x = 260, .y = 150 },
        .{ .x = 250, .y = 120 },
    };
    drawPolygon(&pent, 9);
}
