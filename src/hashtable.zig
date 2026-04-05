// Hash table with open addressing and linear probing
//
// Fixed-size hash table suitable for kernel use (no heap allocation).
// Uses FNV-1a for hashing byte-slice keys.

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- FNV-1a hash ----

pub const FNV_OFFSET: u32 = 0x811C9DC5;
pub const FNV_PRIME: u32 = 0x01000193;

/// FNV-1a hash of a byte slice, producing a 32-bit value.
pub fn fnv1a(data: []const u8) u32 {
    var h: u32 = FNV_OFFSET;
    for (data) |byte| {
        h ^= @as(u32, byte);
        h *%= FNV_PRIME;
    }
    return h;
}

/// Hash a u32 key (spread bits via FNV-1a over the 4 bytes).
pub fn hashU32(key: u32) u32 {
    var h: u32 = FNV_OFFSET;
    h ^= key & 0xFF;
    h *%= FNV_PRIME;
    h ^= (key >> 8) & 0xFF;
    h *%= FNV_PRIME;
    h ^= (key >> 16) & 0xFF;
    h *%= FNV_PRIME;
    h ^= (key >> 24) & 0xFF;
    h *%= FNV_PRIME;
    return h;
}

// ---- Bucket state ----

const BucketState = enum(u8) {
    empty = 0,
    occupied = 1,
    deleted = 2, // tombstone for linear probing
};

// ---- Hash table (fixed key = u32, value = V, N buckets) ----

pub fn HashTable(comptime V: type, comptime N: usize) type {
    return struct {
        const Self = @This();
        const Capacity = N;

        const Bucket = struct {
            key: u32 = 0,
            value: V = undefined,
            state: BucketState = .empty,
        };

        buckets: [N]Bucket = [_]Bucket{.{}} ** N,
        entry_count: usize = 0,

        // ---- Core operations ----

        /// Insert or update a key-value pair. Returns false if the table is full.
        pub fn put(self: *Self, key: u32, value: V) bool {
            // Check if key already exists (update in-place)
            const h = hashU32(key) % N;
            var idx = h;
            var tombstone: ?usize = null;
            var probes: usize = 0;

            while (probes < N) : (probes += 1) {
                switch (self.buckets[idx].state) {
                    .empty => {
                        // Use tombstone slot if available, otherwise this empty slot
                        const target = tombstone orelse idx;
                        self.buckets[target] = .{
                            .key = key,
                            .value = value,
                            .state = .occupied,
                        };
                        self.entry_count += 1;
                        return true;
                    },
                    .occupied => {
                        if (self.buckets[idx].key == key) {
                            self.buckets[idx].value = value;
                            return true; // updated
                        }
                    },
                    .deleted => {
                        if (tombstone == null) tombstone = idx;
                    },
                }
                idx = (idx + 1) % N;
            }

            // Table is full (no empty or tombstone slots found with matching key)
            if (tombstone) |t| {
                self.buckets[t] = .{
                    .key = key,
                    .value = value,
                    .state = .occupied,
                };
                self.entry_count += 1;
                return true;
            }
            return false;
        }

        /// Look up a value by key.
        pub fn get(self: *const Self, key: u32) ?V {
            const h = hashU32(key) % N;
            var idx = h;
            var probes: usize = 0;

            while (probes < N) : (probes += 1) {
                switch (self.buckets[idx].state) {
                    .empty => return null,
                    .occupied => {
                        if (self.buckets[idx].key == key) {
                            return self.buckets[idx].value;
                        }
                    },
                    .deleted => {},
                }
                idx = (idx + 1) % N;
            }
            return null;
        }

        /// Remove a key from the table. Returns true if found and removed.
        pub fn remove(self: *Self, key: u32) bool {
            const h = hashU32(key) % N;
            var idx = h;
            var probes: usize = 0;

            while (probes < N) : (probes += 1) {
                switch (self.buckets[idx].state) {
                    .empty => return false,
                    .occupied => {
                        if (self.buckets[idx].key == key) {
                            self.buckets[idx].state = .deleted;
                            self.entry_count -= 1;
                            return true;
                        }
                    },
                    .deleted => {},
                }
                idx = (idx + 1) % N;
            }
            return false;
        }

        /// Check if a key exists.
        pub fn contains(self: *const Self, key: u32) bool {
            return self.get(key) != null;
        }

        /// Number of entries in the table.
        pub fn count(self: *const Self) usize {
            return self.entry_count;
        }

        /// Remove all entries.
        pub fn clear(self: *Self) void {
            for (&self.buckets) |*b| {
                b.state = .empty;
            }
            self.entry_count = 0;
        }

        /// Load factor as a percentage (0-100).
        pub fn loadFactor(self: *const Self) usize {
            return (self.entry_count * 100) / N;
        }

        // ---- Iterator ----

        pub const Entry = struct {
            key: u32,
            value: V,
        };

        pub const Iterator = struct {
            table: *const Self,
            index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < N) {
                    const idx = self.index;
                    self.index += 1;
                    if (self.table.buckets[idx].state == .occupied) {
                        return Entry{
                            .key = self.table.buckets[idx].key,
                            .value = self.table.buckets[idx].value,
                        };
                    }
                }
                return null;
            }
        };

        /// Return an iterator over all occupied entries.
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .table = self };
        }

        // ---- Display ----

        /// Print table contents with bucket indices.
        pub fn printTable(self: *const Self) void {
            vga.setColor(.yellow, .black);
            vga.write("HashTable (");
            printDec(self.entry_count);
            vga.write("/");
            printDec(N);
            vga.write(" entries, load ");
            printDec(self.loadFactor());
            vga.write("%)\n");
            vga.setColor(.light_grey, .black);

            if (self.entry_count == 0) {
                vga.write("  (empty)\n");
                return;
            }

            vga.write("  Bucket  Key         State\n");
            for (self.buckets, 0..) |b, i| {
                if (b.state == .occupied) {
                    vga.write("  ");
                    printDecPadded(i, 6);
                    vga.write("  0x");
                    printHex32(b.key);
                    vga.write("  occupied\n");
                }
            }
        }

        /// Print collision statistics.
        pub fn printStats(self: *const Self) void {
            var occupied: usize = 0;
            var deleted: usize = 0;
            var empty: usize = 0;
            var max_chain: usize = 0;
            var current_chain: usize = 0;

            for (self.buckets) |b| {
                switch (b.state) {
                    .empty => {
                        empty += 1;
                        if (current_chain > max_chain) max_chain = current_chain;
                        current_chain = 0;
                    },
                    .occupied => {
                        occupied += 1;
                        current_chain += 1;
                    },
                    .deleted => {
                        deleted += 1;
                        current_chain += 1;
                    },
                }
            }
            if (current_chain > max_chain) max_chain = current_chain;

            vga.setColor(.yellow, .black);
            vga.write("HashTable Stats:\n");
            vga.setColor(.light_grey, .black);
            vga.write("  Capacity:    ");
            printDec(N);
            vga.putChar('\n');
            vga.write("  Occupied:    ");
            printDec(occupied);
            vga.putChar('\n');
            vga.write("  Deleted:     ");
            printDec(deleted);
            vga.putChar('\n');
            vga.write("  Empty:       ");
            printDec(empty);
            vga.putChar('\n');
            vga.write("  Max chain:   ");
            printDec(max_chain);
            vga.putChar('\n');
            vga.write("  Load factor: ");
            printDec(self.loadFactor());
            vga.write("%\n");
        }
    };
}

// ---- Concrete types for kernel use ----

/// Hash table mapping u32 keys to u32 values, 64 buckets
pub const Map32 = HashTable(u32, 64);

/// Hash table mapping u32 keys to u32 values, 256 buckets
pub const Map256 = HashTable(u32, 256);

/// Hash table mapping u32 keys to boolean, 128 buckets (set-like)
pub const Set128 = HashTable(bool, 128);

// ---- Helpers ----

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| vga.putChar(c);
}

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

fn printDecPadded(n: usize, width: usize) void {
    // Count digits
    var digits: usize = 1;
    var tmp = n;
    while (tmp >= 10) {
        tmp /= 10;
        digits += 1;
    }
    var pad = width -| digits;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
    printDec(n);
}
