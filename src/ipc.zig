// Inter-process communication subsystem -- message queues, shared memory, events
//
// Provides three IPC mechanisms for kernel tasks:
// 1. Message queues: named, fixed-size (64 byte) messages with priority ordering
// 2. Shared memory regions: named, up to 4KB, reference-counted attach/detach
// 3. Event flag groups: 32-bit flag sets with any/all wait semantics

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_MSG_QUEUES = 8;
pub const MAX_MSGS_PER_QUEUE = 16;
pub const MSG_SIZE = 64;
pub const MAX_NAME_LEN = 16;

pub const MAX_SHM_REGIONS = 8;
pub const MAX_SHM_SIZE = 4096;

pub const MAX_EVENT_GROUPS = 8;

// ---- Message Queue ----

const Message = struct {
    data: [MSG_SIZE]u8,
    len: u8,
    priority: u8, // higher = dequeue first
    valid: bool,
};

const MessageQueue = struct {
    active: bool,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    messages: [MAX_MSGS_PER_QUEUE]Message,
    msg_count: u8,
    // Statistics
    total_sent: u32,
    total_received: u32,
    peak_count: u8,
};

// ---- Shared Memory ----

const ShmRegion = struct {
    active: bool,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    buffer: [MAX_SHM_SIZE]u8,
    size: u16,
    attach_count: u8,
    // Statistics
    total_attaches: u32,
    total_detaches: u32,
};

// ---- Event Flags ----

const EventGroup = struct {
    active: bool,
    flags: u32,
    // Statistics
    total_sets: u32,
    total_clears: u32,
    total_waits: u32,
};

// ---- State ----

var msg_queues: [MAX_MSG_QUEUES]MessageQueue = undefined;
var shm_regions: [MAX_SHM_REGIONS]ShmRegion = undefined;
var event_groups: [MAX_EVENT_GROUPS]EventGroup = undefined;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    for (&msg_queues) |*mq| {
        mq.active = false;
        mq.name_len = 0;
        mq.msg_count = 0;
        mq.total_sent = 0;
        mq.total_received = 0;
        mq.peak_count = 0;
        for (&mq.messages) |*m| {
            m.valid = false;
            m.len = 0;
            m.priority = 0;
        }
        for (&mq.name) |*c| c.* = 0;
    }

    for (&shm_regions) |*shm| {
        shm.active = false;
        shm.name_len = 0;
        shm.size = 0;
        shm.attach_count = 0;
        shm.total_attaches = 0;
        shm.total_detaches = 0;
        for (&shm.name) |*c| c.* = 0;
        for (&shm.buffer) |*b| b.* = 0;
    }

    for (&event_groups) |*eg| {
        eg.active = false;
        eg.flags = 0;
        eg.total_sets = 0;
        eg.total_clears = 0;
        eg.total_waits = 0;
    }

    initialized = true;
    serial.write("[ipc] IPC subsystem initialized\n");
}

// =============================
// Message Queue API
// =============================

/// Create a named message queue. Returns queue ID or null if full.
pub fn mqCreate(name: []const u8) ?u8 {
    if (!initialized) return null;

    // Check for duplicate name
    for (&msg_queues) |*mq| {
        if (mq.active and nameEq(&mq.name, mq.name_len, name)) {
            return null;
        }
    }

    for (&msg_queues, 0..) |*mq, i| {
        if (!mq.active) {
            mq.active = true;
            mq.msg_count = 0;
            mq.total_sent = 0;
            mq.total_received = 0;
            mq.peak_count = 0;
            copyName(&mq.name, &mq.name_len, name);
            for (&mq.messages) |*m| m.valid = false;
            return @truncate(i);
        }
    }
    return null;
}

/// Send a message to a queue. Priority 0 = normal, higher = higher priority.
pub fn mqSend(id: u8, msg: []const u8, priority: u8) bool {
    if (!initialized or id >= MAX_MSG_QUEUES) return false;
    const mq = &msg_queues[id];
    if (!mq.active) return false;
    if (mq.msg_count >= MAX_MSGS_PER_QUEUE) return false;

    // Find a free message slot
    for (&mq.messages) |*m| {
        if (!m.valid) {
            m.valid = true;
            m.priority = priority;
            // Copy message data
            const copy_len = if (msg.len > MSG_SIZE) MSG_SIZE else msg.len;
            for (0..copy_len) |j| {
                m.data[j] = msg[j];
            }
            // Zero rest
            var k: usize = copy_len;
            while (k < MSG_SIZE) : (k += 1) {
                m.data[k] = 0;
            }
            m.len = @truncate(copy_len);
            mq.msg_count += 1;
            mq.total_sent += 1;
            if (mq.msg_count > mq.peak_count) {
                mq.peak_count = mq.msg_count;
            }
            return true;
        }
    }
    return false;
}

/// Receive a message from a queue (highest priority first, then FIFO).
/// Copies data into buf and returns number of bytes, or null if empty.
pub fn mqReceive(id: u8, buf: []u8) ?usize {
    if (!initialized or id >= MAX_MSG_QUEUES) return null;
    const mq = &msg_queues[id];
    if (!mq.active or mq.msg_count == 0) return null;

    // Find highest priority message (first one found at that priority)
    var best: ?*Message = null;
    var best_prio: u8 = 0;

    for (&mq.messages) |*m| {
        if (m.valid) {
            if (best == null or m.priority > best_prio) {
                best = m;
                best_prio = m.priority;
            }
        }
    }

    if (best) |m| {
        const copy_len = if (@as(usize, m.len) > buf.len) buf.len else @as(usize, m.len);
        for (0..copy_len) |j| {
            buf[j] = m.data[j];
        }
        m.valid = false;
        mq.msg_count -= 1;
        mq.total_received += 1;
        return copy_len;
    }

    return null;
}

/// Get current message count in a queue.
pub fn mqCount(id: u8) u8 {
    if (id >= MAX_MSG_QUEUES) return 0;
    const mq = &msg_queues[id];
    if (!mq.active) return 0;
    return mq.msg_count;
}

/// Destroy a message queue.
pub fn mqDestroy(id: u8) bool {
    if (!initialized or id >= MAX_MSG_QUEUES) return false;
    const mq = &msg_queues[id];
    if (!mq.active) return false;
    mq.active = false;
    mq.msg_count = 0;
    return true;
}

/// Find a message queue by name.
pub fn mqFind(name: []const u8) ?u8 {
    for (&msg_queues, 0..) |*mq, i| {
        if (mq.active and nameEq(&mq.name, mq.name_len, name)) {
            return @truncate(i);
        }
    }
    return null;
}

// =============================
// Shared Memory API
// =============================

/// Create a named shared memory region. Returns region ID or null.
pub fn shmCreate(name: []const u8, size: u16) ?u8 {
    if (!initialized) return null;
    if (size == 0 or size > MAX_SHM_SIZE) return null;

    // Check for duplicate name
    for (&shm_regions) |*shm| {
        if (shm.active and nameEq(&shm.name, shm.name_len, name)) {
            return null;
        }
    }

    for (&shm_regions, 0..) |*shm, i| {
        if (!shm.active) {
            shm.active = true;
            shm.size = size;
            shm.attach_count = 0;
            shm.total_attaches = 0;
            shm.total_detaches = 0;
            copyName(&shm.name, &shm.name_len, name);
            // Zero the buffer
            for (&shm.buffer) |*b| b.* = 0;
            return @truncate(i);
        }
    }
    return null;
}

/// Attach to a shared memory region. Returns a pointer to the buffer.
pub fn shmAttach(id: u8) ?[*]u8 {
    if (!initialized or id >= MAX_SHM_REGIONS) return null;
    const shm = &shm_regions[id];
    if (!shm.active) return null;

    shm.attach_count += 1;
    shm.total_attaches += 1;
    return &shm.buffer;
}

/// Detach from a shared memory region.
pub fn shmDetach(id: u8) bool {
    if (!initialized or id >= MAX_SHM_REGIONS) return false;
    const shm = &shm_regions[id];
    if (!shm.active or shm.attach_count == 0) return false;

    shm.attach_count -= 1;
    shm.total_detaches += 1;
    return true;
}

/// Destroy a shared memory region (only if no attachments).
pub fn shmDestroy(id: u8) bool {
    if (!initialized or id >= MAX_SHM_REGIONS) return false;
    const shm = &shm_regions[id];
    if (!shm.active) return false;
    if (shm.attach_count > 0) return false; // still attached

    shm.active = false;
    return true;
}

/// Find a shared memory region by name.
pub fn shmFind(name: []const u8) ?u8 {
    for (&shm_regions, 0..) |*shm, i| {
        if (shm.active and nameEq(&shm.name, shm.name_len, name)) {
            return @truncate(i);
        }
    }
    return null;
}

/// Get the size of a shared memory region.
pub fn shmSize(id: u8) u16 {
    if (id >= MAX_SHM_REGIONS) return 0;
    const shm = &shm_regions[id];
    if (!shm.active) return 0;
    return shm.size;
}

// =============================
// Event Flags API
// =============================

/// Create an event flag group. Returns group ID or null.
pub fn eventCreate() ?u8 {
    if (!initialized) return null;
    for (&event_groups, 0..) |*eg, i| {
        if (!eg.active) {
            eg.active = true;
            eg.flags = 0;
            eg.total_sets = 0;
            eg.total_clears = 0;
            eg.total_waits = 0;
            return @truncate(i);
        }
    }
    return null;
}

/// Set flags in an event group (OR operation).
pub fn eventSet(id: u8, flags: u32) bool {
    if (!initialized or id >= MAX_EVENT_GROUPS) return false;
    const eg = &event_groups[id];
    if (!eg.active) return false;
    eg.flags |= flags;
    eg.total_sets += 1;
    return true;
}

/// Clear flags in an event group.
pub fn eventClear(id: u8, flags: u32) bool {
    if (!initialized or id >= MAX_EVENT_GROUPS) return false;
    const eg = &event_groups[id];
    if (!eg.active) return false;
    eg.flags &= ~flags;
    eg.total_clears += 1;
    return true;
}

/// Wait for flags. If wait_all is true, all specified flags must be set.
/// Returns the current flags if condition is met, 0 otherwise.
/// (Non-blocking -- in a real OS this would block the task.)
pub fn eventWait(id: u8, flags: u32, wait_all: bool) u32 {
    if (!initialized or id >= MAX_EVENT_GROUPS) return 0;
    const eg = &event_groups[id];
    if (!eg.active) return 0;

    eg.total_waits += 1;

    if (wait_all) {
        // All specified flags must be set
        if ((eg.flags & flags) == flags) {
            return eg.flags;
        }
    } else {
        // Any specified flag must be set
        if ((eg.flags & flags) != 0) {
            return eg.flags;
        }
    }

    return 0;
}

/// Get current event flags.
pub fn eventGet(id: u8) u32 {
    if (id >= MAX_EVENT_GROUPS) return 0;
    const eg = &event_groups[id];
    if (!eg.active) return 0;
    return eg.flags;
}

/// Destroy an event flag group.
pub fn eventDestroy(id: u8) bool {
    if (!initialized or id >= MAX_EVENT_GROUPS) return false;
    const eg = &event_groups[id];
    if (!eg.active) return false;
    eg.active = false;
    return true;
}

// =============================
// Display
// =============================

/// Print all IPC objects and their status.
pub fn printIpc() void {
    if (!initialized) {
        vga.write("IPC not initialized.\n");
        return;
    }

    // Message Queues
    vga.setColor(.light_cyan, .black);
    vga.write("=== Message Queues ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  ID  Name             Msgs  Peak  Sent  Recv\n");
    vga.setColor(.light_grey, .black);

    var any_mq = false;
    for (&msg_queues, 0..) |*mq, i| {
        if (!mq.active) continue;
        any_mq = true;
        vga.write("  ");
        fmt.printDecPadded(i, 2);
        vga.write("  ");
        printNameField(&mq.name, mq.name_len, 16);
        vga.write(" ");
        fmt.printDecPadded(@as(usize, mq.msg_count), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, mq.peak_count), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, mq.total_sent), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, mq.total_received), 4);
        vga.putChar('\n');
    }
    if (!any_mq) vga.write("  (none)\n");

    // Shared Memory
    vga.setColor(.light_cyan, .black);
    vga.write("\n=== Shared Memory ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  ID  Name             Size   Attach  TotA  TotD\n");
    vga.setColor(.light_grey, .black);

    var any_shm = false;
    for (&shm_regions, 0..) |*shm, i| {
        if (!shm.active) continue;
        any_shm = true;
        vga.write("  ");
        fmt.printDecPadded(i, 2);
        vga.write("  ");
        printNameField(&shm.name, shm.name_len, 16);
        vga.write(" ");
        fmt.printDecPadded(@as(usize, shm.size), 5);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, shm.attach_count), 6);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, shm.total_attaches), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, shm.total_detaches), 4);
        vga.putChar('\n');
    }
    if (!any_shm) vga.write("  (none)\n");

    // Event Flags
    vga.setColor(.light_cyan, .black);
    vga.write("\n=== Event Flag Groups ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  ID  Flags       Sets  Clears  Waits\n");
    vga.setColor(.light_grey, .black);

    var any_ev = false;
    for (&event_groups, 0..) |*eg, i| {
        if (!eg.active) continue;
        any_ev = true;
        vga.write("  ");
        fmt.printDecPadded(i, 2);
        vga.write("  0x");
        fmt.printHex32(eg.flags);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, eg.total_sets), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, eg.total_clears), 6);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, eg.total_waits), 4);
        vga.putChar('\n');
    }
    if (!any_ev) vga.write("  (none)\n");
}

// ---- Helper functions ----

fn copyName(dest: *[MAX_NAME_LEN]u8, dest_len: *u8, src: []const u8) void {
    const copy_len = if (src.len > MAX_NAME_LEN) MAX_NAME_LEN else src.len;
    for (0..copy_len) |i| {
        dest[i] = src[i];
    }
    var i: usize = copy_len;
    while (i < MAX_NAME_LEN) : (i += 1) {
        dest[i] = 0;
    }
    dest_len.* = @truncate(copy_len);
}

fn nameEq(stored: *const [MAX_NAME_LEN]u8, stored_len: u8, name: []const u8) bool {
    if (@as(usize, stored_len) != name.len) return false;
    for (0..name.len) |i| {
        if (stored[i] != name[i]) return false;
    }
    return true;
}

fn printNameField(name: *const [MAX_NAME_LEN]u8, name_len: u8, width: usize) void {
    var printed: usize = 0;
    if (name_len > 0) {
        const len = @as(usize, name_len);
        const to_print = if (len > width) width else len;
        vga.write(name[0..to_print]);
        printed = to_print;
    }
    while (printed < width) : (printed += 1) {
        vga.putChar(' ');
    }
}
