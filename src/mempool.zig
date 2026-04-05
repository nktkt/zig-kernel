// Fixed-size memory pool allocator
//
// Provides O(1) allocation and deallocation of fixed-size objects without
// fragmentation.  Each MemPool manages an array of N slots of type T,
// tracked by a free bitmap.  Ideal for kernel objects like tasks, file
// descriptors, network buffers, etc.

const vga = @import("vga.zig");
const serial = @import("serial.zig");

/// Create a fixed-size memory pool for objects of type T with N slots.
pub fn MemPool(comptime T: type, comptime N: usize) type {
    // Bitmap words needed (32 bits each)
    const BITMAP_WORDS = (N + 31) / 32;

    return struct {
        const Self = @This();
        const Capacity = N;
        const ObjSize = @sizeOf(T);

        /// Object storage
        objects: [N]T = undefined,

        /// Bitmap: bit=1 means slot is in use
        bitmap: [BITMAP_WORDS]u32 = [_]u32{0} ** BITMAP_WORDS,

        /// Number of allocated slots
        used_count: usize = 0,

        /// Total allocations (lifetime)
        total_allocs: u64 = 0,
        /// Total frees (lifetime)
        total_frees: u64 = 0,

        /// Initialize the pool (clear all slots).
        pub fn init(self: *Self) void {
            for (&self.bitmap) |*w| {
                w.* = 0;
            }
            self.used_count = 0;
            self.total_allocs = 0;
            self.total_frees = 0;
        }

        /// Reset the pool, freeing all objects.
        pub fn reset(self: *Self) void {
            self.init();
        }

        /// Allocate one object from the pool. Returns a pointer or null if full.
        /// The object is zero-initialized.
        pub fn alloc(self: *Self) ?*T {
            // Find a free bit
            for (&self.bitmap, 0..) |*word, wi| {
                if (word.* != 0xFFFFFFFF) {
                    // Find first zero bit
                    var bit: u5 = 0;
                    while (true) : (bit += 1) {
                        if (word.* & (@as(u32, 1) << bit) == 0) {
                            const idx = wi * 32 + bit;
                            if (idx >= N) return null;

                            // Mark as used
                            word.* |= @as(u32, 1) << bit;
                            self.used_count += 1;
                            self.total_allocs += 1;

                            // Zero-initialize the object
                            const ptr = &self.objects[idx];
                            const bytes: [*]u8 = @ptrCast(ptr);
                            for (0..ObjSize) |i| {
                                bytes[i] = 0;
                            }

                            return ptr;
                        }
                        if (bit == 31) break;
                    }
                }
            }
            return null;
        }

        /// Free an object back to the pool. The pointer must point to an
        /// object within this pool's storage array.
        pub fn free(self: *Self, ptr: *T) void {
            const base = @intFromPtr(&self.objects[0]);
            const addr = @intFromPtr(ptr);

            // Bounds check
            if (addr < base) {
                serial.write("[MEMPOOL] free: ptr below pool\n");
                return;
            }
            const offset = addr - base;
            if (ObjSize == 0) return; // zero-sized type guard
            const idx = offset / ObjSize;
            if (idx >= N) {
                serial.write("[MEMPOOL] free: ptr beyond pool\n");
                return;
            }

            // Alignment check
            if (offset % ObjSize != 0) {
                serial.write("[MEMPOOL] free: misaligned ptr\n");
                return;
            }

            const wi = idx / 32;
            const bit: u5 = @truncate(idx % 32);

            // Double-free check
            if (self.bitmap[wi] & (@as(u32, 1) << bit) == 0) {
                serial.write("[MEMPOOL] free: double free detected\n");
                return;
            }

            self.bitmap[wi] &= ~(@as(u32, 1) << bit);
            self.used_count -|= 1;
            self.total_frees += 1;
        }

        /// Number of available (free) slots.
        pub fn available(self: *const Self) usize {
            return N -| self.used_count;
        }

        /// Number of used (allocated) slots.
        pub fn used(self: *const Self) usize {
            return self.used_count;
        }

        /// Is the pool completely full?
        pub fn isFull(self: *const Self) bool {
            return self.used_count >= N;
        }

        /// Is the pool completely empty (no allocations)?
        pub fn isEmpty(self: *const Self) bool {
            return self.used_count == 0;
        }

        /// Check whether a pointer belongs to this pool.
        pub fn ownsPtr(self: *const Self, ptr: *const T) bool {
            const base = @intFromPtr(&self.objects[0]);
            const addr = @intFromPtr(ptr);
            if (addr < base) return false;
            const offset = addr - base;
            if (ObjSize == 0) return false;
            const idx = offset / ObjSize;
            return idx < N and offset % ObjSize == 0;
        }

        // ---- Display ----

        /// Print pool status.
        pub fn printStatus(self: *const Self) void {
            vga.setColor(.yellow, .black);
            vga.write("MemPool<");
            printDec(ObjSize);
            vga.write("B x ");
            printDec(N);
            vga.write(">:\n");
            vga.setColor(.light_grey, .black);

            vga.write("  Used:      ");
            printDec(self.used_count);
            vga.write("/");
            printDec(N);
            vga.putChar('\n');
            vga.write("  Available: ");
            printDec(self.available());
            vga.putChar('\n');
            vga.write("  Allocs:    ");
            printDec64(self.total_allocs);
            vga.putChar('\n');
            vga.write("  Frees:     ");
            printDec64(self.total_frees);
            vga.putChar('\n');

            // Utilization percentage
            if (N > 0) {
                const pct = (self.used_count * 100) / N;
                vga.write("  Utilization: ");
                printDec(pct);
                vga.write("%\n");
            }
        }

        /// Print the bitmap visually (. = free, # = used).
        pub fn printBitmap(self: *const Self) void {
            vga.setColor(.light_grey, .black);
            vga.write("  Bitmap [");
            for (0..N) |i| {
                const wi = i / 32;
                const bit: u5 = @truncate(i % 32);
                if (self.bitmap[wi] & (@as(u32, 1) << bit) != 0) {
                    vga.setColor(.light_red, .black);
                    vga.putChar('#');
                } else {
                    vga.setColor(.light_green, .black);
                    vga.putChar('.');
                }
            }
            vga.setColor(.light_grey, .black);
            vga.write("]\n");
        }
    };
}

// ---- Concrete pool types for kernel use ----

/// A small struct for testing / generic use
pub const SmallObj = struct {
    data: [16]u8 = [_]u8{0} ** 16,
    id: u32 = 0,
    flags: u32 = 0,
};

pub const SmallPool = MemPool(SmallObj, 64);

/// Network buffer descriptor pool
pub const NetBufDesc = struct {
    addr: u32 = 0,
    len: u16 = 0,
    flags: u16 = 0,
};

pub const NetBufPool = MemPool(NetBufDesc, 128);

// ---- Helpers ----

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

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
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
