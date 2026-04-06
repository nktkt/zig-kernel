// Enhanced random number generation — multiple PRNG algorithms
//
// Provides LCG, Xorshift32, Xorshift128, and LFSR16 generators.
// Seeding from PIT ticks. Utility functions for ranges, shuffling,
// random byte filling, and basic statistical testing (chi-squared).

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- LCG (Linear Congruential Generator) ----

pub const Lcg = struct {
    state: u32,

    pub fn init(seed: u32) Lcg {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    pub fn next(self: *Lcg) u32 {
        // Parameters from Numerical Recipes
        self.state = self.state *% 1664525 +% 1013904223;
        return self.state;
    }

    pub fn nextRange(self: *Lcg, min: u32, max: u32) u32 {
        if (min >= max) return min;
        return min + (self.next() % (max - min + 1));
    }
};

// ---- Xorshift32 ----

pub const Xorshift32 = struct {
    state: u32,

    pub fn init(seed: u32) Xorshift32 {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    pub fn next(self: *Xorshift32) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    pub fn nextRange(self: *Xorshift32, min: u32, max: u32) u32 {
        if (min >= max) return min;
        return min + (self.next() % (max - min + 1));
    }
};

// ---- Xorshift128 ----

pub const Xorshift128 = struct {
    state: [4]u32,

    pub fn init(seed: u32) Xorshift128 {
        // Initialize state from seed using splitmix-like expansion
        var s = if (seed == 0) @as(u32, 1) else seed;
        var result: Xorshift128 = undefined;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            s = s *% 2654435769 +% 1;
            result.state[i] = s;
        }
        return result;
    }

    pub fn next(self: *Xorshift128) u32 {
        var t = self.state[3];
        t ^= t << 11;
        t ^= t >> 8;

        self.state[3] = self.state[2];
        self.state[2] = self.state[1];
        self.state[1] = self.state[0];

        const s = self.state[0];
        t ^= s;
        t ^= s >> 19;
        self.state[0] = t;

        return t;
    }

    pub fn nextRange(self: *Xorshift128, min: u32, max: u32) u32 {
        if (min >= max) return min;
        return min + (self.next() % (max - min + 1));
    }
};

// ---- LFSR16 (16-bit Linear Feedback Shift Register) ----

pub const Lfsr16 = struct {
    state: u16,

    pub fn init(seed: u16) Lfsr16 {
        return .{ .state = if (seed == 0) 0xACE1 else seed };
    }

    pub fn next(self: *Lfsr16) u16 {
        // Taps at bits 16, 15, 13, 4 (maximal period: 65535)
        const bit: u16 = ((self.state >> 0) ^ (self.state >> 1) ^
            (self.state >> 3) ^ (self.state >> 12)) & 1;
        self.state = (self.state >> 1) | (bit << 15);
        return self.state;
    }

    pub fn nextRange(self: *Lfsr16, min: u16, max: u16) u16 {
        if (min >= max) return min;
        return min + (self.next() % (max - min + 1));
    }

    /// Get period length (should be 65535 for maximal LFSR).
    pub fn measurePeriod(self: *Lfsr16) u32 {
        const initial = self.state;
        var count: u32 = 0;
        while (true) {
            _ = self.next();
            count += 1;
            if (self.state == initial) return count;
            if (count >= 70000) return count; // safety limit
        }
    }
};

// ---- Global RNG state ----

var global_xorshift: Xorshift32 = Xorshift32.init(0xDEADBEEF);
var global_xorshift128: Xorshift128 = Xorshift128.init(0xDEADBEEF);
var entropy_pool: [32]u32 = undefined;
var entropy_idx: usize = 0;
var entropy_count: u32 = 0;
var initialized: bool = false;

// ---- Initialization ----

pub fn init() void {
    // Seed from PIT ticks
    const seed = @as(u32, @truncate(pit.getTicks())) ^ 0x12345678;
    global_xorshift = Xorshift32.init(seed);
    global_xorshift128 = Xorshift128.init(seed);

    // Initialize entropy pool
    for (&entropy_pool, 0..) |*e, i| {
        e.* = seed ^ @as(u32, @truncate(i)) *% 2654435761;
    }
    entropy_idx = 0;
    entropy_count = 0;
    initialized = true;

    serial.write("[random] RNG initialized with seed=");
    serialHex(seed);
    serial.write("\n");
}

/// Add entropy (e.g., from interrupt timing, keyboard input).
pub fn addEntropy(val: u32) void {
    entropy_pool[entropy_idx] ^= val;
    entropy_idx = (entropy_idx + 1) % entropy_pool.len;
    entropy_count += 1;

    // Mix into global state
    global_xorshift.state ^= val;
    if (global_xorshift.state == 0) global_xorshift.state = 1;
}

/// Re-seed from current PIT ticks.
pub fn reseed() void {
    const seed = @as(u32, @truncate(pit.getTicks()));
    addEntropy(seed);
    addEntropy(seed *% 2654435761);
}

// ---- Public random API ----

/// Generate a random u32.
pub fn rand() u32 {
    return global_xorshift.next();
}

/// Generate a random u32 using Xorshift128.
pub fn rand128() u32 {
    return global_xorshift128.next();
}

/// Generate a random number in [min, max].
pub fn randRange(min: u32, max: u32) u32 {
    if (min >= max) return min;
    return min + (rand() % (max - min + 1));
}

/// Generate fixed-point 0.0-1.0 (as u32 where 65536 = 1.0).
pub fn randFloat() u32 {
    return rand() & 0xFFFF; // 16-bit fraction, 65536 = 1.0
}

/// Fill a buffer with random bytes.
pub fn randomBytes(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const val = rand();
        const remain = buf.len - i;
        if (remain >= 4) {
            buf[i] = @truncate(val & 0xFF);
            buf[i + 1] = @truncate((val >> 8) & 0xFF);
            buf[i + 2] = @truncate((val >> 16) & 0xFF);
            buf[i + 3] = @truncate((val >> 24) & 0xFF);
            i += 4;
        } else {
            var v = val;
            while (i < buf.len) {
                buf[i] = @truncate(v & 0xFF);
                v >>= 8;
                i += 1;
            }
        }
    }
}

/// Fisher-Yates shuffle on a u32 slice.
pub fn shuffle(arr: []u32) void {
    if (arr.len <= 1) return;
    var i = arr.len - 1;
    while (i > 0) : (i -= 1) {
        const j = rand() % @as(u32, @truncate(i + 1));
        const tmp = arr[i];
        arr[i] = arr[j];
        arr[j] = tmp;
    }
}

/// Fisher-Yates shuffle on a u8 slice.
pub fn shuffleBytes(arr: []u8) void {
    if (arr.len <= 1) return;
    var i = arr.len - 1;
    while (i > 0) : (i -= 1) {
        const j = rand() % @as(u32, @truncate(i + 1));
        const tmp = arr[i];
        arr[i] = arr[@as(usize, @truncate(j))];
        arr[@as(usize, @truncate(j))] = tmp;
    }
}

// ---- /dev/random entropy pool ----

/// Read from entropy pool.
pub fn readEntropy(buf: []u8) usize {
    var i: usize = 0;
    while (i < buf.len) {
        // Mix pool into output
        const pool_val = entropy_pool[entropy_idx];
        entropy_idx = (entropy_idx + 1) % entropy_pool.len;

        const mixed = pool_val ^ rand();
        const remain = buf.len - i;
        if (remain >= 4) {
            buf[i] = @truncate(mixed & 0xFF);
            buf[i + 1] = @truncate((mixed >> 8) & 0xFF);
            buf[i + 2] = @truncate((mixed >> 16) & 0xFF);
            buf[i + 3] = @truncate((mixed >> 24) & 0xFF);
            i += 4;
        } else {
            var v = mixed;
            while (i < buf.len) {
                buf[i] = @truncate(v & 0xFF);
                v >>= 8;
                i += 1;
            }
        }
    }
    return buf.len;
}

/// Get entropy count (number of entropy additions).
pub fn getEntropyCount() u32 {
    return entropy_count;
}

// ---- Statistical tests ----

/// Chi-squared uniformity test. Generates n samples in [0, buckets-1]
/// and computes chi-squared statistic. Returns chi2 * 100 (fixed-point).
pub fn chiSquaredTest(n: u32, buckets: u32) u32 {
    if (buckets == 0 or n == 0) return 0;
    if (buckets > 64) return 0; // limit

    var counts: [64]u32 = @splat(0);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const val = rand() % buckets;
        counts[val] += 1;
    }

    // Expected count per bucket
    const expected_x100 = (n * 100) / buckets;

    // chi2 = sum((observed - expected)^2 / expected)
    // We compute chi2 * 100 for fixed-point
    var chi2_x100: u32 = 0;
    var b: u32 = 0;
    while (b < buckets) : (b += 1) {
        const obs_x100 = counts[b] * 100;
        if (obs_x100 >= expected_x100) {
            const diff = obs_x100 - expected_x100;
            chi2_x100 += (diff * diff) / expected_x100;
        } else {
            const diff = expected_x100 - obs_x100;
            chi2_x100 += (diff * diff) / expected_x100;
        }
    }

    return chi2_x100;
}

// ---- Display ----

/// Print RNG state information.
pub fn printState() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Random Number Generator State ===\n");

    vga.setColor(.light_grey, .black);
    vga.write("Xorshift32 state: 0x");
    fmt.printHex32(global_xorshift.state);
    vga.putChar('\n');

    vga.write("Xorshift128 state: [");
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i > 0) vga.write(", ");
        vga.write("0x");
        fmt.printHex32(global_xorshift128.state[i]);
    }
    vga.write("]\n");

    vga.write("Entropy additions: ");
    fmt.printDec(@as(usize, entropy_count));
    vga.putChar('\n');

    // Show some random values
    vga.setColor(.light_cyan, .black);
    vga.write("\nSample output (Xorshift32):\n");
    vga.setColor(.light_grey, .black);

    var sample_rng = Xorshift32.init(global_xorshift.state);
    i = 0;
    while (i < 8) : (i += 1) {
        vga.write("  0x");
        fmt.printHex32(sample_rng.next());
        if (i % 4 == 3) {
            vga.putChar('\n');
        } else {
            vga.write("  ");
        }
    }

    // Quick chi-squared test
    vga.setColor(.light_cyan, .black);
    vga.write("\nChi-squared test (1000 samples, 16 buckets):\n");
    vga.setColor(.light_grey, .black);
    const chi2 = chiSquaredTest(1000, 16);
    vga.write("  chi2 * 100 = ");
    fmt.printDec(@as(usize, chi2));
    vga.write("  (expected ~1500 for 15 df)\n");

    // Quality assessment
    vga.write("  Quality: ");
    if (chi2 < 3000) {
        vga.setColor(.light_green, .black);
        vga.write("GOOD\n");
    } else if (chi2 < 6000) {
        vga.setColor(.yellow, .black);
        vga.write("ACCEPTABLE\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("POOR\n");
    }
}

/// Print all available RNG algorithms.
pub fn printAlgorithms() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Available RNG Algorithms ===\n\n");

    vga.setColor(.yellow, .black);
    vga.write("Algorithm      Period           State Size\n");
    vga.setColor(.light_grey, .black);

    vga.write("LCG            2^32             4 bytes\n");
    vga.write("Xorshift32     2^32 - 1         4 bytes\n");
    vga.write("Xorshift128    2^128 - 1        16 bytes\n");
    vga.write("LFSR16         2^16 - 1         2 bytes\n");
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Helpers ----

fn serialHex(val: u32) void {
    const hex = "0123456789ABCDEF";
    serial.write("0x");
    var v = val;
    var buf: [8]u8 = undefined;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| serial.putChar(c);
}
