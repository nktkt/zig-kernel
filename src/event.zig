// Event Queue System -- ring buffer event queue with dispatch
// Supports mouse, keyboard, timer, window, and custom events

const pit = @import("pit.zig");

// ---- Event Types ----

pub const EventType = enum(u8) {
    mouse_click = 0,
    mouse_move = 1,
    key_press = 2,
    key_release = 3,
    timer = 4,
    window_close = 5,
    window_focus = 6,
    custom = 7,
};

pub const event_type_count = 8;

// ---- Event Struct ----

pub const Event = struct {
    etype: EventType,
    x: i16,
    y: i16,
    key: u8,
    window_id: u8,
    timestamp: u32,
    data: u32, // custom data field
};

// ---- Ring Buffer (64 events) ----

const QUEUE_SIZE = 64;

var queue: [QUEUE_SIZE]Event = @splat(Event{
    .etype = .custom,
    .x = 0,
    .y = 0,
    .key = 0,
    .window_id = 0,
    .timestamp = 0,
    .data = 0,
});
var head: usize = 0;
var tail: usize = 0;
var event_count: usize = 0;

// ---- Queue Operations ----

/// Push an event onto the queue. Returns false if queue is full.
pub fn push(event: Event) bool {
    if (event_count >= QUEUE_SIZE) return false;
    queue[tail] = event;
    tail = (tail + 1) % QUEUE_SIZE;
    event_count += 1;
    return true;
}

/// Pop the next event from the queue. Returns null if empty.
pub fn pop() ?Event {
    if (event_count == 0) return null;
    const ev = queue[head];
    head = (head + 1) % QUEUE_SIZE;
    event_count -= 1;
    return ev;
}

/// Peek at the next event without removing it. Returns null if empty.
pub fn peek() ?Event {
    if (event_count == 0) return null;
    return queue[head];
}

/// Check if the queue is empty
pub fn isEmpty() bool {
    return event_count == 0;
}

/// Check if the queue is full
pub fn isFull() bool {
    return event_count >= QUEUE_SIZE;
}

/// Get current number of events in queue
pub fn count() usize {
    return event_count;
}

/// Clear all events from the queue
pub fn flush() void {
    head = 0;
    tail = 0;
    event_count = 0;
}

/// Blocking wait for an event with timeout (in milliseconds).
/// Returns null if timeout expires with no event.
/// Uses PIT tick count for timing.
pub fn waitForEvent(timeout_ms: u32) ?Event {
    const start_tick = pit.getTicks();
    const ticks_needed: u64 = timeout_ms; // PIT is ~1ms per tick

    while (true) {
        if (event_count > 0) {
            return pop();
        }

        const elapsed = pit.getTicks() -% start_tick;
        if (elapsed >= ticks_needed) {
            return null;
        }

        // Brief busy-wait; in a real OS we'd halt until next IRQ
        asm volatile ("hlt");
    }
}

// ---- Event Construction Helpers ----

/// Create a mouse click event
pub fn mouseClick(x: i16, y: i16, button: u8) Event {
    return .{
        .etype = .mouse_click,
        .x = x,
        .y = y,
        .key = button,
        .window_id = 0,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a mouse move event
pub fn mouseMove(x: i16, y: i16) Event {
    return .{
        .etype = .mouse_move,
        .x = x,
        .y = y,
        .key = 0,
        .window_id = 0,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a key press event
pub fn keyPress(key: u8) Event {
    return .{
        .etype = .key_press,
        .x = 0,
        .y = 0,
        .key = key,
        .window_id = 0,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a key release event
pub fn keyRelease(key: u8) Event {
    return .{
        .etype = .key_release,
        .x = 0,
        .y = 0,
        .key = key,
        .window_id = 0,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a timer event
pub fn timerEvent() Event {
    return .{
        .etype = .timer,
        .x = 0,
        .y = 0,
        .key = 0,
        .window_id = 0,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a window close event
pub fn windowClose(win_id: u8) Event {
    return .{
        .etype = .window_close,
        .x = 0,
        .y = 0,
        .key = 0,
        .window_id = win_id,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a window focus event
pub fn windowFocus(win_id: u8) Event {
    return .{
        .etype = .window_focus,
        .x = 0,
        .y = 0,
        .key = 0,
        .window_id = win_id,
        .timestamp = @truncate(pit.getTicks()),
        .data = 0,
    };
}

/// Create a custom event
pub fn customEvent(data: u32) Event {
    return .{
        .etype = .custom,
        .x = 0,
        .y = 0,
        .key = 0,
        .window_id = 0,
        .timestamp = @truncate(pit.getTicks()),
        .data = data,
    };
}

// ---- Handler Registration & Dispatch ----

const MAX_HANDLERS = 16;

pub const HandlerFn = *const fn (Event) void;

const HandlerEntry = struct {
    etype: EventType,
    handler: HandlerFn,
    active: bool,
};

var handlers: [MAX_HANDLERS]HandlerEntry = @splat(HandlerEntry{
    .etype = .custom,
    .handler = &nullHandler,
    .active = false,
});
var handler_count: usize = 0;

fn nullHandler(_: Event) void {}

/// Register a handler for a specific event type.
/// Returns the handler slot index, or null if no slots available.
pub fn registerHandler(etype: EventType, handler: HandlerFn) ?u8 {
    if (handler_count >= MAX_HANDLERS) return null;

    // Find a free slot
    for (&handlers, 0..) |*h, i| {
        if (!h.active) {
            h.etype = etype;
            h.handler = handler;
            h.active = true;
            handler_count += 1;
            return @truncate(i);
        }
    }
    return null;
}

/// Unregister a handler by slot index
pub fn unregisterHandler(slot: u8) void {
    if (slot >= MAX_HANDLERS) return;
    if (handlers[slot].active) {
        handlers[slot].active = false;
        handler_count -= 1;
    }
}

/// Dispatch all pending events to registered handlers.
/// Each event is popped and sent to all matching handlers.
pub fn dispatch() void {
    while (pop()) |ev| {
        for (&handlers) |*h| {
            if (h.active and h.etype == ev.etype) {
                h.handler(ev);
            }
        }
    }
}

/// Dispatch a single event to matching handlers without queue involvement
pub fn dispatchDirect(ev: Event) void {
    for (&handlers) |*h| {
        if (h.active and h.etype == ev.etype) {
            h.handler(ev);
        }
    }
}

/// Reset all handlers and clear the queue
pub fn reset() void {
    flush();
    for (&handlers) |*h| {
        h.active = false;
        h.handler = &nullHandler;
    }
    handler_count = 0;
}
