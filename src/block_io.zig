// Block I/O request queue — elevator scheduling, merging, deadline
//
// Manages a queue of block I/O requests. Implements the elevator algorithm
// (sorting by sector), request merging, deadline scheduling (timeout after
// 500ms), and dispatch to device drivers.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const blkdev = @import("blkdev.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_REQUESTS: usize = 32;
const DEADLINE_MS: u64 = 500;
const MAX_MERGE_SECTORS: u8 = 16; // Max sectors after merge

// ============================================================
// Types
// ============================================================

pub const Direction = enum(u8) {
    read,
    write,
};

pub const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    urgent = 3,
};

pub const RequestState = enum(u8) {
    pending,
    dispatched,
    completed,
    failed,
};

pub const BioCallback = *const fn (req_id: u16, success: bool) void;

pub const BioRequest = struct {
    // Request identity
    id: u16 = 0,
    device: u8 = 0,
    sector: u32 = 0,
    count: u8 = 1, // Number of sectors
    direction: Direction = .read,
    priority: Priority = .normal,

    // Data
    buffer: [*]u8 = undefined,
    buffer_valid: bool = false,

    // Callback
    callback: ?BioCallback = null,

    // State
    state: RequestState = .pending,
    submit_tick: u64 = 0, // When submitted
    dispatch_tick: u64 = 0, // When dispatched to device
    complete_tick: u64 = 0, // When completed

    // Queue management
    valid: bool = false,
};

pub const Stats = struct {
    requests_submitted: u64 = 0,
    requests_completed: u64 = 0,
    requests_failed: u64 = 0,
    requests_merged: u64 = 0,
    reads_dispatched: u64 = 0,
    writes_dispatched: u64 = 0,
    total_sectors_read: u64 = 0,
    total_sectors_written: u64 = 0,
    deadline_expirations: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    total_completed_for_avg: u64 = 0,
};

// ============================================================
// State
// ============================================================

var requests: [MAX_REQUESTS]BioRequest = [_]BioRequest{.{}} ** MAX_REQUESTS;
var queue_count: usize = 0;
var next_id: u16 = 1;
var stats: Stats = .{};

// Elevator state
var elevator_pos: u32 = 0; // Current head position (sector)
var elevator_up: bool = true; // Direction (true = ascending)

// ============================================================
// Public API
// ============================================================

/// Submit a block I/O request. Returns the request ID or null if queue full.
pub fn submit(device: u8, sector: u32, count_in: u8, direction: Direction, buffer: [*]u8, callback: ?BioCallback, priority: Priority) ?u16 {
    const now = pit.getTicks();
    stats.requests_submitted += 1;

    // Try to merge with existing request first
    if (tryMerge(device, sector, count_in, direction, buffer)) {
        stats.requests_merged += 1;
        return 0; // Merged, no new ID
    }

    // Find free slot
    var slot: ?usize = null;
    for (&requests, 0..) |*r, i| {
        if (!r.valid) {
            slot = i;
            break;
        }
    }

    if (slot == null) {
        // Queue full — try to process some requests first
        processOne();
        for (&requests, 0..) |*r, i| {
            if (!r.valid) {
                slot = i;
                break;
            }
        }
    }

    if (slot == null) return null;

    const id = next_id;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;

    const r = &requests[slot.?];
    r.* = .{
        .id = id,
        .device = device,
        .sector = sector,
        .count = count_in,
        .direction = direction,
        .buffer = buffer,
        .buffer_valid = true,
        .callback = callback,
        .priority = priority,
        .state = .pending,
        .submit_tick = now,
        .valid = true,
    };

    queue_count += 1;
    return id;
}

/// Process all pending requests in the queue.
pub fn processQueue() void {
    // Check deadlines first — urgent expired requests
    checkDeadlines();

    // Process requests using elevator algorithm
    while (hasPending()) {
        processOne();
    }
}

/// Process a single request (the best candidate by elevator algorithm).
pub fn processOne() void {
    const idx = selectNextRequest() orelse return;
    dispatchRequest(idx);
}

/// Get queue depth (number of pending requests).
pub fn queueDepth() usize {
    var count: usize = 0;
    for (&requests) |*r| {
        if (r.valid and r.state == .pending) count += 1;
    }
    return count;
}

/// Cancel a pending request.
pub fn cancel(req_id: u16) bool {
    for (&requests) |*r| {
        if (r.valid and r.id == req_id and r.state == .pending) {
            r.state = .failed;
            r.valid = false;
            queue_count -|= 1;
            if (r.callback) |cb| {
                cb(r.id, false);
            }
            return true;
        }
    }
    return false;
}

/// Get statistics.
pub fn getStats() Stats {
    return stats;
}

/// Reset statistics.
pub fn resetStats() void {
    stats = .{};
}

/// Flush the queue (cancel all pending).
pub fn flushQueue() void {
    for (&requests) |*r| {
        if (r.valid and r.state == .pending) {
            r.state = .failed;
            r.valid = false;
            if (r.callback) |cb| {
                cb(r.id, false);
            }
        }
    }
    queue_count = 0;
}

// ============================================================
// Display
// ============================================================

/// Print queue status.
pub fn printQueueStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("Block I/O Queue Status:\n\n");
    vga.setColor(.light_grey, .black);

    // Summary
    const pending = queueDepth();
    vga.write("  Queue depth:        ");
    printDec(pending);
    vga.write("/");
    printDec(MAX_REQUESTS);
    vga.putChar('\n');
    vga.write("  Elevator position:  sector ");
    printDec(elevator_pos);
    if (elevator_up) {
        vga.write(" (ascending)\n");
    } else {
        vga.write(" (descending)\n");
    }

    // Stats
    vga.write("  Submitted:          ");
    printDec64(stats.requests_submitted);
    vga.putChar('\n');
    vga.write("  Completed:          ");
    printDec64(stats.requests_completed);
    vga.putChar('\n');
    vga.write("  Failed:             ");
    printDec64(stats.requests_failed);
    vga.putChar('\n');
    vga.write("  Merged:             ");
    printDec64(stats.requests_merged);
    vga.putChar('\n');
    vga.write("  Reads dispatched:   ");
    printDec64(stats.reads_dispatched);
    vga.putChar('\n');
    vga.write("  Writes dispatched:  ");
    printDec64(stats.writes_dispatched);
    vga.putChar('\n');
    vga.write("  Sectors read:       ");
    printDec64(stats.total_sectors_read);
    vga.putChar('\n');
    vga.write("  Sectors written:    ");
    printDec64(stats.total_sectors_written);
    vga.putChar('\n');
    vga.write("  Deadline expires:   ");
    printDec64(stats.deadline_expirations);
    vga.putChar('\n');

    // Average latency
    if (stats.total_completed_for_avg > 0) {
        const avg_lat = stats.total_latency_ms / stats.total_completed_for_avg;
        vga.write("  Avg latency:        ");
        printDec64(avg_lat);
        vga.write(" ms\n");
        vga.write("  Max latency:        ");
        printDec64(stats.max_latency_ms);
        vga.write(" ms\n");
    }

    // Pending requests detail
    if (pending > 0) {
        vga.setColor(.yellow, .black);
        vga.write("\nPending Requests:\n");
        vga.setColor(.light_grey, .black);
        vga.write("  ID    Dev  Sector     Count  Dir    Pri     Age(ms)\n");
        vga.write("  ----  ---  --------   -----  -----  ------  -------\n");

        const now = pit.getTicks();
        for (&requests) |*r| {
            if (!r.valid or r.state != .pending) continue;

            vga.write("  ");
            printDecPadded(r.id, 4);
            vga.write("  ");
            printDecPadded(@as(u64, r.device), 3);
            vga.write("  ");
            printDecPadded(r.sector, 8);
            vga.write("   ");
            printDecPadded(@as(u64, r.count), 5);
            vga.write("  ");
            switch (r.direction) {
                .read => vga.write("read "),
                .write => vga.write("write"),
            }
            vga.write("  ");
            switch (r.priority) {
                .low => vga.write("low   "),
                .normal => vga.write("normal"),
                .high => vga.write("high  "),
                .urgent => vga.write("urgent"),
            }
            vga.write("  ");
            const age = now -| r.submit_tick;
            printDecPadded(age, 7);
            vga.putChar('\n');
        }
    }
}

// ============================================================
// Elevator algorithm — select next request
// ============================================================

fn selectNextRequest() ?usize {
    // First: check for deadline-expired requests (urgent)
    const now = pit.getTicks();
    var deadline_idx: ?usize = null;
    var deadline_oldest: u64 = ~@as(u64, 0);

    for (&requests, 0..) |*r, i| {
        if (!r.valid or r.state != .pending) continue;
        if (now -| r.submit_tick >= DEADLINE_MS and r.submit_tick < deadline_oldest) {
            deadline_oldest = r.submit_tick;
            deadline_idx = i;
        }
    }
    if (deadline_idx != null) {
        stats.deadline_expirations += 1;
        return deadline_idx;
    }

    // High-priority requests next
    var best_high: ?usize = null;
    for (&requests, 0..) |*r, i| {
        if (r.valid and r.state == .pending and r.priority == .urgent) {
            if (best_high == null) best_high = i;
        }
    }
    if (best_high != null) return best_high;

    // Elevator: find closest request in current direction
    var best_idx: ?usize = null;
    var best_distance: u64 = ~@as(u64, 0);

    for (&requests, 0..) |*r, i| {
        if (!r.valid or r.state != .pending) continue;

        if (elevator_up) {
            if (r.sector >= elevator_pos) {
                const dist = @as(u64, r.sector - elevator_pos);
                if (dist < best_distance) {
                    best_distance = dist;
                    best_idx = i;
                }
            }
        } else {
            if (r.sector <= elevator_pos) {
                const dist = @as(u64, elevator_pos - r.sector);
                if (dist < best_distance) {
                    best_distance = dist;
                    best_idx = i;
                }
            }
        }
    }

    // If no request in current direction, reverse
    if (best_idx == null) {
        elevator_up = !elevator_up;

        for (&requests, 0..) |*r, i| {
            if (!r.valid or r.state != .pending) continue;

            if (elevator_up) {
                if (r.sector >= elevator_pos) {
                    const dist = @as(u64, r.sector - elevator_pos);
                    if (dist < best_distance) {
                        best_distance = dist;
                        best_idx = i;
                    }
                }
            } else {
                if (r.sector <= elevator_pos) {
                    const dist = @as(u64, elevator_pos - r.sector);
                    if (dist < best_distance) {
                        best_distance = dist;
                        best_idx = i;
                    }
                }
            }
        }
    }

    // Still nothing? Just take any pending request
    if (best_idx == null) {
        for (&requests, 0..) |*r, i| {
            if (r.valid and r.state == .pending) {
                best_idx = i;
                break;
            }
        }
    }

    return best_idx;
}

// ============================================================
// Request merging
// ============================================================

fn tryMerge(device: u8, sector: u32, count_in: u8, direction: Direction, buffer: [*]u8) bool {
    _ = buffer; // Buffer pointer merging is complex; just check adjacency
    for (&requests) |*r| {
        if (!r.valid or r.state != .pending) continue;
        if (r.device != device or r.direction != direction) continue;

        // Forward merge: new request is immediately after existing
        if (sector == r.sector + r.count) {
            const new_count = @as(u16, r.count) + count_in;
            if (new_count <= MAX_MERGE_SECTORS) {
                r.count = @truncate(new_count);
                return true;
            }
        }

        // Backward merge: new request is immediately before existing
        if (sector + count_in == r.sector) {
            const new_count = @as(u16, r.count) + count_in;
            if (new_count <= MAX_MERGE_SECTORS) {
                r.sector = sector;
                r.count = @truncate(new_count);
                return true;
            }
        }
    }
    return false;
}

// ============================================================
// Deadline checking
// ============================================================

fn checkDeadlines() void {
    const now = pit.getTicks();
    for (&requests) |*r| {
        if (!r.valid or r.state != .pending) continue;
        if (now -| r.submit_tick >= DEADLINE_MS) {
            // Boost priority
            r.priority = .urgent;
        }
    }
}

// ============================================================
// Dispatch
// ============================================================

fn dispatchRequest(idx: usize) void {
    var r = &requests[idx];
    r.state = .dispatched;
    r.dispatch_tick = pit.getTicks();

    var success = false;
    switch (r.direction) {
        .read => {
            if (r.buffer_valid) {
                success = blkdev.read(r.device, r.sector, r.count, r.buffer);
            }
            stats.reads_dispatched += 1;
            stats.total_sectors_read += r.count;
        },
        .write => {
            if (r.buffer_valid) {
                success = blkdev.write(r.device, r.sector, r.count, @ptrCast(@constCast(r.buffer)));
            }
            stats.writes_dispatched += 1;
            stats.total_sectors_written += r.count;
        },
    }

    r.complete_tick = pit.getTicks();
    elevator_pos = r.sector + r.count; // Update head position

    if (success) {
        r.state = .completed;
        stats.requests_completed += 1;
    } else {
        r.state = .failed;
        stats.requests_failed += 1;
    }

    // Latency tracking
    const latency = r.complete_tick -| r.submit_tick;
    stats.total_latency_ms += latency;
    stats.total_completed_for_avg += 1;
    if (latency > stats.max_latency_ms) {
        stats.max_latency_ms = latency;
    }

    // Invoke callback
    if (r.callback) |cb| {
        cb(r.id, success);
    }

    // Free the slot
    r.valid = false;
    queue_count -|= 1;
}

fn hasPending() bool {
    for (&requests) |*r| {
        if (r.valid and r.state == .pending) return true;
    }
    return false;
}

// ============================================================
// Internal helpers
// ============================================================

fn printDec(n: anytype) void {
    const v_init: u64 = @intCast(n);
    if (v_init == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = v_init;
    while (v > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(v % 10)));
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDec64(n: u64) void {
    printDec(n);
}

fn printDecPadded(n: anytype, width: usize) void {
    const val: u64 = @intCast(n);
    var digits: usize = 0;
    var tmp = val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    var pad = if (digits < width) width - digits else 0;
    while (pad > 0) : (pad -= 1) {
        vga.putChar(' ');
    }
    printDec(val);
}
