// Enhanced ARP cache with aging, eviction, and statistics
//
// Provides a 32-entry ARP table with tick-based timestamps and configurable TTL.
// Entries automatically expire after TTL_SECONDS (default 300s).  The age()
// function should be called periodically (e.g. once per second from the timer
// tick handler) to evict stale entries.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- Configuration ----

pub const MAX_ENTRIES: usize = 32;
pub const TTL_SECONDS: u64 = 300; // 5 minutes
const TTL_TICKS: u64 = TTL_SECONDS * 1000; // PIT runs at 1 kHz

// ---- Types ----

pub const ArpEntry = struct {
    ip: u32 = 0,
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    timestamp: u64 = 0, // tick at which the entry was added/refreshed
    valid: bool = false,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    adds: u64 = 0,
    flushes: u64 = 0,
    age_removals: u64 = 0,
};

// ---- State ----

var entries: [MAX_ENTRIES]ArpEntry = [_]ArpEntry{.{}} ** MAX_ENTRIES;
var entry_count: usize = 0;
var stats: Stats = .{};

// ---- Public API ----

/// Add or update an ARP cache entry.
pub fn add(ip: u32, mac: [6]u8) void {
    const now = pit.getTicks();

    // Update existing entry if present
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            e.mac = mac;
            e.timestamp = now;
            return;
        }
    }

    stats.adds += 1;

    // Find a free slot
    for (&entries) |*e| {
        if (!e.valid) {
            e.ip = ip;
            e.mac = mac;
            e.timestamp = now;
            e.valid = true;
            entry_count += 1;
            return;
        }
    }

    // Cache full -- evict the oldest entry
    var oldest_idx: usize = 0;
    var oldest_time: u64 = entries[0].timestamp;
    for (entries[1..], 1..) |e, i| {
        if (e.valid and e.timestamp < oldest_time) {
            oldest_time = e.timestamp;
            oldest_idx = i;
        }
    }

    stats.evictions += 1;
    entries[oldest_idx] = .{
        .ip = ip,
        .mac = mac,
        .timestamp = now,
        .valid = true,
    };
}

/// Look up the MAC address for a given IP.
pub fn lookup(ip: u32) ?[6]u8 {
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            stats.hits += 1;
            return e.mac;
        }
    }
    stats.misses += 1;
    return null;
}

/// Remove a specific IP from the cache.
pub fn remove(ip: u32) void {
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            e.valid = false;
            entry_count -|= 1;
            return;
        }
    }
}

/// Remove all entries that have exceeded their TTL.
pub fn age() void {
    const now = pit.getTicks();
    for (&entries) |*e| {
        if (e.valid) {
            if (now -| e.timestamp >= TTL_TICKS) {
                e.valid = false;
                entry_count -|= 1;
                stats.age_removals += 1;
            }
        }
    }
}

/// Clear every entry in the cache.
pub fn flush() void {
    for (&entries) |*e| {
        e.valid = false;
    }
    entry_count = 0;
    stats.flushes += 1;
}

/// Number of valid entries.
pub fn count() usize {
    return entry_count;
}

/// Get a copy of the statistics.
pub fn getStats() Stats {
    return stats;
}

/// Reset all statistics counters.
pub fn resetStats() void {
    stats = .{};
}

// ---- Display ----

/// Print each valid entry (IP, MAC, age in seconds).
pub fn printCache() void {
    const now = pit.getTicks();
    vga.setColor(.yellow, .black);
    vga.write("ARP Cache (");
    printDec(entry_count);
    vga.write("/");
    printDec(MAX_ENTRIES);
    vga.write(" entries):\n");
    vga.setColor(.light_grey, .black);

    if (entry_count == 0) {
        vga.write("  (empty)\n");
        return;
    }

    vga.write("  IP Address        MAC Address        Age(s)\n");
    for (&entries) |*e| {
        if (!e.valid) continue;
        vga.write("  ");
        printIp(e.ip);
        padTo(20);
        printMac(&e.mac);
        padTo(39);
        const age_secs = (now -| e.timestamp) / 1000;
        printDec(@truncate(age_secs));
        vga.putChar('\n');
    }
}

/// Print hit/miss/eviction statistics.
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("ARP Cache Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Hits:         ");
    printDec64(stats.hits);
    vga.putChar('\n');
    vga.write("  Misses:       ");
    printDec64(stats.misses);
    vga.putChar('\n');
    vga.write("  Adds:         ");
    printDec64(stats.adds);
    vga.putChar('\n');
    vga.write("  Evictions:    ");
    printDec64(stats.evictions);
    vga.putChar('\n');
    vga.write("  Age removals: ");
    printDec64(stats.age_removals);
    vga.putChar('\n');
    vga.write("  Flushes:      ");
    printDec64(stats.flushes);
    vga.putChar('\n');

    if (stats.hits + stats.misses > 0) {
        const total = stats.hits + stats.misses;
        const pct = (stats.hits * 100) / total;
        vga.write("  Hit rate:     ");
        printDec64(pct);
        vga.write("%\n");
    }
}

// ---- Internal helpers ----

var print_col: usize = 0;

fn padTo(target: usize) void {
    while (print_col < target) {
        vga.putChar(' ');
        print_col += 1;
    }
}

fn printIp(ip: u32) void {
    print_col = 2; // after "  " prefix
    printDecPart((ip >> 24) & 0xFF);
    vga.putChar('.');
    printDecPart((ip >> 16) & 0xFF);
    vga.putChar('.');
    printDecPart((ip >> 8) & 0xFF);
    vga.putChar('.');
    printDecPart(ip & 0xFF);
}

fn printDecPart(v: u32) void {
    if (v >= 100) {
        vga.putChar(@truncate('0' + v / 100));
        print_col += 1;
    }
    if (v >= 10) {
        vga.putChar(@truncate('0' + (v / 10) % 10));
        print_col += 1;
    }
    vga.putChar(@truncate('0' + v % 10));
    print_col += 1;
    // account for dot
    print_col += 1;
}

fn printMac(mac: *const [6]u8) void {
    const hex = "0123456789ABCDEF";
    for (mac, 0..) |b, i| {
        if (i > 0) {
            vga.putChar(':');
            print_col += 1;
        }
        vga.putChar(hex[b >> 4]);
        vga.putChar(hex[b & 0xF]);
        print_col += 2;
    }
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
