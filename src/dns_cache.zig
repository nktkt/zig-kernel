// DNS response caching with TTL-based expiry and negative caching
//
// Caches up to 16 DNS A-record lookups. Each entry stores a hostname (up to 64
// characters), the resolved IPv4 address, and a TTL. Entries are automatically
// expired by cleanExpired(). Negative caching stores NXDOMAIN results with a
// short TTL to avoid repeated failing lookups.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_ENTRIES: usize = 16;
pub const MAX_HOSTNAME_LEN: usize = 64;
pub const DEFAULT_TTL_SECS: u32 = 300; // 5 minutes
pub const NEGATIVE_TTL_SECS: u32 = 60; // 1 minute for NXDOMAIN
pub const MIN_TTL_SECS: u32 = 10; // Minimum TTL clamp
pub const MAX_TTL_SECS: u32 = 86400; // 24 hours maximum

// ============================================================
// Types
// ============================================================

pub const CacheEntryType = enum(u8) {
    positive, // Normal A record
    negative, // NXDOMAIN / no answer
};

pub const CacheEntry = struct {
    hostname: [MAX_HOSTNAME_LEN]u8 = @splat(0),
    hostname_len: u8 = 0,
    ip: u32 = 0,
    ttl: u32 = 0, // TTL in seconds as received
    timestamp: u64 = 0, // Tick when entry was stored
    entry_type: CacheEntryType = .positive,
    valid: bool = false,
    hit_count: u32 = 0, // How many times this entry was returned from cache
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    stores: u64 = 0,
    evictions: u64 = 0,
    expirations: u64 = 0,
    negative_hits: u64 = 0,
    negative_stores: u64 = 0,
};

// ============================================================
// State
// ============================================================

var entries: [MAX_ENTRIES]CacheEntry = [_]CacheEntry{.{}} ** MAX_ENTRIES;
var entry_count: usize = 0;
var stats: Stats = .{};

// ============================================================
// Public API
// ============================================================

/// Look up a hostname in the cache. Returns the IP if found and not expired.
/// Returns null for expired entries (which are cleaned up) and misses.
/// For negative cache entries, returns 0 (indicating NXDOMAIN).
pub fn lookup(hostname: []const u8) ?u32 {
    if (hostname.len == 0 or hostname.len > MAX_HOSTNAME_LEN) {
        stats.misses += 1;
        return null;
    }

    const now = pit.getTicks();

    for (&entries) |*e| {
        if (!e.valid) continue;
        if (!hostnameMatch(e, hostname)) continue;

        // Check TTL
        const age_ms = now -| e.timestamp;
        const age_secs = age_ms / 1000;
        if (age_secs >= e.ttl) {
            // Expired
            e.valid = false;
            entry_count -|= 1;
            stats.expirations += 1;
            stats.misses += 1;
            return null;
        }

        // Cache hit
        e.hit_count += 1;
        stats.hits += 1;
        if (e.entry_type == .negative) {
            stats.negative_hits += 1;
            return 0; // Sentinel for NXDOMAIN
        }
        return e.ip;
    }

    stats.misses += 1;
    return null;
}

/// Store a positive DNS result in the cache.
pub fn store(hostname: []const u8, ip: u32, ttl: u32) void {
    if (hostname.len == 0 or hostname.len > MAX_HOSTNAME_LEN) return;

    const clamped_ttl = clampTtl(ttl);
    const now = pit.getTicks();

    stats.stores += 1;

    // Update existing entry
    for (&entries) |*e| {
        if (e.valid and hostnameMatch(e, hostname)) {
            e.ip = ip;
            e.ttl = clamped_ttl;
            e.timestamp = now;
            e.entry_type = .positive;
            e.hit_count = 0;
            return;
        }
    }

    // Find free slot
    for (&entries) |*e| {
        if (!e.valid) {
            fillEntry(e, hostname, ip, clamped_ttl, now, .positive);
            entry_count += 1;
            return;
        }
    }

    // Cache full — evict LRU (lowest hit_count, then oldest)
    evictOne();
    for (&entries) |*e| {
        if (!e.valid) {
            fillEntry(e, hostname, ip, clamped_ttl, now, .positive);
            entry_count += 1;
            return;
        }
    }
}

/// Store a negative (NXDOMAIN) result in the cache.
pub fn storeNegative(hostname: []const u8) void {
    if (hostname.len == 0 or hostname.len > MAX_HOSTNAME_LEN) return;

    const now = pit.getTicks();
    stats.negative_stores += 1;

    // Update existing
    for (&entries) |*e| {
        if (e.valid and hostnameMatch(e, hostname)) {
            e.ip = 0;
            e.ttl = NEGATIVE_TTL_SECS;
            e.timestamp = now;
            e.entry_type = .negative;
            e.hit_count = 0;
            return;
        }
    }

    // Find free slot
    for (&entries) |*e| {
        if (!e.valid) {
            fillEntry(e, hostname, 0, NEGATIVE_TTL_SECS, now, .negative);
            entry_count += 1;
            return;
        }
    }

    // Evict and store
    evictOne();
    for (&entries) |*e| {
        if (!e.valid) {
            fillEntry(e, hostname, 0, NEGATIVE_TTL_SECS, now, .negative);
            entry_count += 1;
            return;
        }
    }
}

/// Remove a specific hostname from the cache.
pub fn evict(hostname: []const u8) void {
    for (&entries) |*e| {
        if (e.valid and hostnameMatch(e, hostname)) {
            e.valid = false;
            entry_count -|= 1;
            return;
        }
    }
}

/// Remove all expired entries.
pub fn cleanExpired() void {
    const now = pit.getTicks();

    for (&entries) |*e| {
        if (!e.valid) continue;
        const age_secs = (now -| e.timestamp) / 1000;
        if (age_secs >= e.ttl) {
            e.valid = false;
            entry_count -|= 1;
            stats.expirations += 1;
        }
    }
}

/// Remove all entries.
pub fn flush() void {
    for (&entries) |*e| {
        e.valid = false;
    }
    entry_count = 0;
}

/// Get entry count.
pub fn count() usize {
    return entry_count;
}

/// Get statistics.
pub fn getStats() Stats {
    return stats;
}

/// Reset statistics.
pub fn resetStats() void {
    stats = .{};
}

// ============================================================
// Display
// ============================================================

/// Print the DNS cache contents with remaining TTL.
pub fn printCache() void {
    const now = pit.getTicks();

    vga.setColor(.yellow, .black);
    vga.write("DNS Cache (");
    printDec(entry_count);
    vga.write("/");
    printDec(MAX_ENTRIES);
    vga.write(" entries):\n");
    vga.setColor(.light_grey, .black);

    if (entry_count == 0) {
        vga.write("  (empty)\n");
        printStatistics();
        return;
    }

    vga.write("  Hostname                          IP Address        TTL(s)  Hits  Type\n");
    vga.write("  --------------------------------  ----------------  ------  ----  --------\n");

    for (&entries) |*e| {
        if (!e.valid) continue;

        vga.write("  ");
        // Hostname (padded to 34)
        vga.write(e.hostname[0..e.hostname_len]);
        var col: usize = e.hostname_len;
        while (col < 34) : (col += 1) vga.putChar(' ');

        // IP address (padded to 18)
        if (e.entry_type == .negative) {
            vga.write("(NXDOMAIN)        ");
        } else {
            var ip_buf: [16]u8 = undefined;
            const ip_len = writeIpToBuf(&ip_buf, e.ip);
            vga.write(ip_buf[0..ip_len]);
            var ic: usize = ip_len;
            while (ic < 18) : (ic += 1) vga.putChar(' ');
        }

        // Remaining TTL
        const age_secs = (now -| e.timestamp) / 1000;
        const remaining = if (e.ttl > age_secs) e.ttl - @as(u32, @truncate(age_secs)) else 0;
        printDecPadded(remaining, 6);

        // Hits
        vga.write("  ");
        printDecPadded(e.hit_count, 4);

        // Type
        vga.write("  ");
        switch (e.entry_type) {
            .positive => vga.write("positive"),
            .negative => vga.write("negative"),
        }
        vga.putChar('\n');
    }

    printStatistics();
}

fn printStatistics() void {
    vga.setColor(.yellow, .black);
    vga.write("\nDNS Cache Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Hits:            ");
    printDec64(stats.hits);
    vga.putChar('\n');
    vga.write("  Misses:          ");
    printDec64(stats.misses);
    vga.putChar('\n');
    vga.write("  Stores:          ");
    printDec64(stats.stores);
    vga.putChar('\n');
    vga.write("  Evictions:       ");
    printDec64(stats.evictions);
    vga.putChar('\n');
    vga.write("  Expirations:     ");
    printDec64(stats.expirations);
    vga.putChar('\n');
    vga.write("  Negative hits:   ");
    printDec64(stats.negative_hits);
    vga.putChar('\n');
    vga.write("  Negative stores: ");
    printDec64(stats.negative_stores);
    vga.putChar('\n');

    if (stats.hits + stats.misses > 0) {
        const total = stats.hits + stats.misses;
        const pct = (stats.hits * 100) / total;
        vga.write("  Hit rate:        ");
        printDec64(pct);
        vga.write("%\n");
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn hostnameMatch(entry: *const CacheEntry, hostname: []const u8) bool {
    if (entry.hostname_len != hostname.len) return false;
    const stored = entry.hostname[0..entry.hostname_len];
    for (stored, hostname) |a, b| {
        // Case-insensitive comparison
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (la != lb) return false;
    }
    return true;
}

fn fillEntry(e: *CacheEntry, hostname: []const u8, ip: u32, ttl: u32, now: u64, etype: CacheEntryType) void {
    e.hostname_len = @intCast(hostname.len);
    @memcpy(e.hostname[0..hostname.len], hostname);
    // Clear remaining bytes
    if (hostname.len < MAX_HOSTNAME_LEN) {
        @memset(e.hostname[hostname.len..], 0);
    }
    e.ip = ip;
    e.ttl = ttl;
    e.timestamp = now;
    e.entry_type = etype;
    e.valid = true;
    e.hit_count = 0;
}

fn clampTtl(ttl: u32) u32 {
    if (ttl < MIN_TTL_SECS) return MIN_TTL_SECS;
    if (ttl > MAX_TTL_SECS) return MAX_TTL_SECS;
    return ttl;
}

fn evictOne() void {
    // Prefer evicting negative entries first
    var worst_idx: ?usize = null;
    var worst_score: u64 = ~@as(u64, 0);

    for (&entries, 0..) |*e, i| {
        if (!e.valid) continue;

        // Score: lower is worse (more evictable)
        // Negative entries get score 0
        // Positive entries scored by hit_count * remaining_ttl
        var score: u64 = 0;
        if (e.entry_type == .negative) {
            score = 0;
        } else {
            score = @as(u64, e.hit_count) + 1;
        }

        if (score < worst_score) {
            worst_score = score;
            worst_idx = i;
        }
    }

    if (worst_idx) |idx| {
        entries[idx].valid = false;
        entry_count -|= 1;
        stats.evictions += 1;
    }
}

fn writeIpToBuf(buf: *[16]u8, ip: u32) usize {
    var pos: usize = 0;
    pos = writeOctet(buf, pos, @truncate((ip >> 24) & 0xFF));
    buf[pos] = '.';
    pos += 1;
    pos = writeOctet(buf, pos, @truncate((ip >> 16) & 0xFF));
    buf[pos] = '.';
    pos += 1;
    pos = writeOctet(buf, pos, @truncate((ip >> 8) & 0xFF));
    buf[pos] = '.';
    pos += 1;
    pos = writeOctet(buf, pos, @truncate(ip & 0xFF));
    return pos;
}

fn writeOctet(buf: *[16]u8, start: usize, val: u8) usize {
    var pos = start;
    if (val >= 100) {
        buf[pos] = '0' + val / 100;
        pos += 1;
    }
    if (val >= 10) {
        buf[pos] = '0' + (val / 10) % 10;
        pos += 1;
    }
    buf[pos] = '0' + val % 10;
    pos += 1;
    return pos;
}

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
