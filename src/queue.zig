// Priority queue (min-heap) -- generic over element type
//
// A fixed-capacity min-heap suitable for scheduler ready queues, timer
// callbacks, or any scenario requiring efficient extraction of the
// smallest element.
//
// Usage:
//   const TimerQueue = PriorityQueue(TimerEntry, 64, compareTick);
//   var q: TimerQueue = .{};
//   q.insert(.{ .tick = 100, .callback = &fn }) catch {};

const vga = @import("vga.zig");
const serial = @import("serial.zig");

/// Create a priority queue type.
///   T   -- element type
///   N   -- maximum number of elements
///   cmp -- comptime comparison function: fn (T, T) bool
///          returns true when a should come before b (a < b for min-heap)
pub fn PriorityQueue(comptime T: type, comptime N: usize, comptime cmp: fn (T, T) bool) type {
    return struct {
        const Self = @This();
        const Capacity = N;

        data: [N]T = undefined,
        len: usize = 0,

        // ---- Core operations ----

        /// Insert an item into the heap. Returns false if the queue is full.
        pub fn insert(self: *Self, item: T) bool {
            if (self.len >= N) return false;
            self.data[self.len] = item;
            self.siftUp(self.len);
            self.len += 1;
            return true;
        }

        /// Remove and return the minimum element, or null if empty.
        pub fn extractMin(self: *Self) ?T {
            if (self.len == 0) return null;
            const min = self.data[0];
            self.len -= 1;
            if (self.len > 0) {
                self.data[0] = self.data[self.len];
                self.siftDown(0);
            }
            return min;
        }

        /// Peek at the minimum element without removing it.
        pub fn peek(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.data[0];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len >= N;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Remove all elements.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Remove the first element matching a predicate.
        /// Returns true if an element was removed.
        pub fn removeIf(self: *Self, predicate: *const fn (T) bool) bool {
            for (0..self.len) |i| {
                if (predicate(self.data[i])) {
                    self.removeAt(i);
                    return true;
                }
            }
            return false;
        }

        /// Remove element at a specific index and re-heapify.
        pub fn removeAt(self: *Self, idx: usize) void {
            if (idx >= self.len) return;
            self.len -= 1;
            if (idx < self.len) {
                self.data[idx] = self.data[self.len];
                // Element might need to go up or down
                if (idx > 0 and cmp(self.data[idx], self.data[parent(idx)])) {
                    self.siftUp(idx);
                } else {
                    self.siftDown(idx);
                }
            }
        }

        // ---- Heap internals ----

        fn parent(i: usize) usize {
            return (i -| 1) / 2;
        }

        fn leftChild(i: usize) usize {
            return 2 * i + 1;
        }

        fn rightChild(i: usize) usize {
            return 2 * i + 2;
        }

        fn siftUp(self: *Self, start: usize) void {
            var i = start;
            while (i > 0) {
                const p = parent(i);
                if (cmp(self.data[i], self.data[p])) {
                    const tmp = self.data[i];
                    self.data[i] = self.data[p];
                    self.data[p] = tmp;
                    i = p;
                } else {
                    break;
                }
            }
        }

        fn siftDown(self: *Self, start: usize) void {
            var i = start;
            while (true) {
                var smallest = i;
                const left = leftChild(i);
                const right = rightChild(i);

                if (left < self.len and cmp(self.data[left], self.data[smallest])) {
                    smallest = left;
                }
                if (right < self.len and cmp(self.data[right], self.data[smallest])) {
                    smallest = right;
                }

                if (smallest != i) {
                    const tmp = self.data[i];
                    self.data[i] = self.data[smallest];
                    self.data[smallest] = tmp;
                    i = smallest;
                } else {
                    break;
                }
            }
        }

        // ---- Display (for debugging) ----

        /// Print the number of elements and capacity.
        pub fn printStatus(self: *const Self) void {
            vga.write("PriorityQueue: ");
            printDec(self.len);
            vga.write("/");
            printDec(N);
            vga.write(" elements\n");
        }
    };
}

// ---- Example comparison functions for common use cases ----

/// Compare two u32 values (min-heap by value).
pub fn cmpU32(a: u32, b: u32) bool {
    return a < b;
}

/// Compare two u64 values (min-heap by value).
pub fn cmpU64(a: u64, b: u64) bool {
    return a < b;
}

/// A timer callback entry: fires at a given tick.
pub const TimerEntry = struct {
    fire_tick: u64,
    callback_id: u16,
    data: u32,
};

/// Compare timer entries by fire_tick (earlier fires first).
pub fn cmpTimerEntry(a: TimerEntry, b: TimerEntry) bool {
    return a.fire_tick < b.fire_tick;
}

/// A scheduler-ready entry: lower priority number = higher priority.
pub const SchedEntry = struct {
    pid: u16,
    priority: u8,
    time_slice: u16,
};

pub fn cmpSchedEntry(a: SchedEntry, b: SchedEntry) bool {
    return a.priority < b.priority;
}

// Concrete types for kernel use
pub const TimerQueue = PriorityQueue(TimerEntry, 64, cmpTimerEntry);
pub const SchedQueue = PriorityQueue(SchedEntry, 128, cmpSchedEntry);
pub const U32Queue = PriorityQueue(u32, 256, cmpU32);

// ---- Helper ----

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
