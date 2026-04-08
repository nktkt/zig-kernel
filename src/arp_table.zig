// Full ARP table with entry states, aging, proxy support, and statistics
//
// Implements RFC 826 ARP with RFC 4861-inspired state machine:
//   incomplete -> reachable -> stale -> delay -> probe -> failed
// Supports static entries, gratuitous ARP, proxy ARP, and per-entry aging.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const e1000 = @import("e1000.zig");
const net = @import("net.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_ENTRIES: usize = 64;
const REACHABLE_TIMEOUT_MS: u64 = 30_000; // 30 seconds
const STALE_MAX_RETRIES: u8 = 3;
const PROBE_INTERVAL_MS: u64 = 1_000; // 1 second between probes
const RESOLVE_TIMEOUT_MS: u64 = 3_000; // 3 seconds total for resolution
const RESOLVE_MAX_RETRIES: u8 = 3;
const DELAY_TIMEOUT_MS: u64 = 5_000; // 5 seconds in delay state

// ARP proxy table max entries
const MAX_PROXY_ENTRIES: usize = 8;

// ============================================================
// Types
// ============================================================

pub const EntryState = enum(u8) {
    incomplete,
    reachable,
    stale,
    delay,
    probe,
    failed,
};

pub const ArpEntry = struct {
    ip: u32 = 0,
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    state: EntryState = .incomplete,
    is_static: bool = false,
    valid: bool = false,
    timestamp: u64 = 0, // tick when last updated
    retries: u8 = 0,
    last_probe_tick: u64 = 0,
};

pub const ProxyEntry = struct {
    network: u32 = 0, // network address
    mask: u32 = 0, // subnet mask
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 }, // MAC to respond with
    active: bool = false,
};

pub const Stats = struct {
    requests_sent: u64 = 0,
    replies_received: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    adds: u64 = 0,
    evictions: u64 = 0,
    age_transitions: u64 = 0,
    proxy_replies: u64 = 0,
    gratuitous_sent: u64 = 0,
    failed_resolutions: u64 = 0,
};

// ============================================================
// State
// ============================================================

var entries: [MAX_ENTRIES]ArpEntry = [_]ArpEntry{.{}} ** MAX_ENTRIES;
var entry_count: usize = 0;
var stats: Stats = .{};

var proxy_entries: [MAX_PROXY_ENTRIES]ProxyEntry = [_]ProxyEntry{.{}} ** MAX_PROXY_ENTRIES;
var proxy_count: usize = 0;

// ============================================================
// Public API — Table management
// ============================================================

/// Add or update an ARP table entry.
/// If `is_static` is true, the entry never ages out.
pub fn add(ip: u32, mac: [6]u8, is_static: bool) void {
    const now = pit.getTicks();

    // Update existing entry
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            e.mac = mac;
            e.state = .reachable;
            e.is_static = is_static;
            e.timestamp = now;
            e.retries = 0;
            return;
        }
    }

    stats.adds += 1;

    // Find a free slot
    for (&entries) |*e| {
        if (!e.valid) {
            e.* = .{
                .ip = ip,
                .mac = mac,
                .state = .reachable,
                .is_static = is_static,
                .valid = true,
                .timestamp = now,
                .retries = 0,
                .last_probe_tick = 0,
            };
            entry_count += 1;
            return;
        }
    }

    // Table full — evict oldest non-static entry
    evictOldest();
    // Try again after eviction
    for (&entries) |*e| {
        if (!e.valid) {
            e.* = .{
                .ip = ip,
                .mac = mac,
                .state = .reachable,
                .is_static = is_static,
                .valid = true,
                .timestamp = now,
                .retries = 0,
                .last_probe_tick = 0,
            };
            entry_count += 1;
            return;
        }
    }
}

/// Look up an entry by IP address.
pub fn lookup(ip: u32) ?ArpEntry {
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            if (e.state == .reachable or e.state == .stale or e.state == .delay) {
                stats.cache_hits += 1;
                return e.*;
            }
        }
    }
    stats.cache_misses += 1;
    return null;
}

/// Resolve an IP to a MAC address, sending ARP requests if not cached.
/// Blocks with retries until resolution succeeds or times out.
pub fn resolve(ip: u32) ?[6]u8 {
    // Check cache first
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            if (e.state == .reachable or e.state == .stale or e.state == .delay) {
                stats.cache_hits += 1;
                // If stale, transition to delay to trigger re-verification
                if (e.state == .stale) {
                    e.state = .delay;
                    e.timestamp = pit.getTicks();
                }
                return e.mac;
            }
        }
    }

    stats.cache_misses += 1;

    // Create incomplete entry
    createIncompleteEntry(ip);

    // Send ARP requests with retries
    var retry: u8 = 0;
    while (retry < RESOLVE_MAX_RETRIES) : (retry += 1) {
        sendArpRequest(ip);
        stats.requests_sent += 1;

        // Wait for reply
        const start = pit.getTicks();
        while (pit.getTicks() -| start < RESOLVE_TIMEOUT_MS / RESOLVE_MAX_RETRIES) {
            // Check if entry was resolved
            for (&entries) |*e| {
                if (e.valid and e.ip == ip and e.state == .reachable) {
                    return e.mac;
                }
            }
            // Small busy-wait
            asm volatile ("pause");
        }
    }

    // Resolution failed
    for (&entries) |*e| {
        if (e.valid and e.ip == ip and e.state == .incomplete) {
            e.state = .failed;
            e.timestamp = pit.getTicks();
        }
    }
    stats.failed_resolutions += 1;
    return null;
}

/// Called when an ARP reply is received.
pub fn handleReply(ip: u32, mac: [6]u8) void {
    stats.replies_received += 1;
    const now = pit.getTicks();

    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            e.mac = mac;
            e.state = .reachable;
            e.timestamp = now;
            e.retries = 0;
            return;
        }
    }
    // New entry from unsolicited reply
    add(ip, mac, false);
}

/// Remove a specific entry.
pub fn remove(ip: u32) void {
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) {
            e.valid = false;
            entry_count -|= 1;
            return;
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

/// Remove all dynamic (non-static) entries.
pub fn flushDynamic() void {
    for (&entries) |*e| {
        if (e.valid and !e.is_static) {
            e.valid = false;
            entry_count -|= 1;
        }
    }
}

// ============================================================
// Aging — call periodically (e.g. once per second)
// ============================================================

/// Age all entries: reachable->stale after timeout, stale->failed after retries.
pub fn age() void {
    const now = pit.getTicks();

    for (&entries) |*e| {
        if (!e.valid or e.is_static) continue;

        const elapsed = now -| e.timestamp;

        switch (e.state) {
            .reachable => {
                if (elapsed >= REACHABLE_TIMEOUT_MS) {
                    e.state = .stale;
                    e.timestamp = now;
                    stats.age_transitions += 1;
                }
            },
            .stale => {
                // Stale entries wait for traffic to trigger delay->probe
                // If untouched for too long, move to failed
                if (elapsed >= REACHABLE_TIMEOUT_MS) {
                    e.state = .failed;
                    e.timestamp = now;
                    stats.age_transitions += 1;
                }
            },
            .delay => {
                if (elapsed >= DELAY_TIMEOUT_MS) {
                    e.state = .probe;
                    e.timestamp = now;
                    e.retries = 0;
                    stats.age_transitions += 1;
                }
            },
            .probe => {
                if (elapsed >= PROBE_INTERVAL_MS) {
                    if (e.retries >= STALE_MAX_RETRIES) {
                        e.state = .failed;
                        e.timestamp = now;
                        stats.age_transitions += 1;
                    } else {
                        sendArpRequest(e.ip);
                        stats.requests_sent += 1;
                        e.retries += 1;
                        e.timestamp = now;
                    }
                }
            },
            .failed => {
                // Clean up failed entries after a grace period
                if (elapsed >= REACHABLE_TIMEOUT_MS) {
                    e.valid = false;
                    entry_count -|= 1;
                }
            },
            .incomplete => {
                // Incomplete entries that haven't resolved
                if (elapsed >= RESOLVE_TIMEOUT_MS) {
                    e.state = .failed;
                    e.timestamp = now;
                    stats.age_transitions += 1;
                }
            },
        }
    }
}

// ============================================================
// Gratuitous ARP
// ============================================================

/// Send a gratuitous ARP to announce our IP/MAC mapping.
pub fn sendGratuitousArp(our_ip: u32) void {
    if (!e1000.isInitialized()) return;
    var pkt: [42]u8 = undefined;
    const broadcast = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

    // Ethernet header
    @memcpy(pkt[0..6], &broadcast);
    @memcpy(pkt[6..12], &e1000.mac);
    net.putU16BE(pkt[12..14], 0x0806); // ARP

    // ARP payload
    net.putU16BE(pkt[14..16], 1); // HW type: Ethernet
    net.putU16BE(pkt[16..18], 0x0800); // Proto: IPv4
    pkt[18] = 6; // HW addr len
    pkt[19] = 4; // Proto addr len
    net.putU16BE(pkt[20..22], 1); // Op: request (gratuitous)
    @memcpy(pkt[22..28], &e1000.mac); // Sender MAC
    net.putU32BE(pkt[28..32], our_ip); // Sender IP
    @memcpy(pkt[32..38], &broadcast); // Target MAC (broadcast)
    net.putU32BE(pkt[38..42], our_ip); // Target IP = Sender IP

    e1000.send(&pkt);
    stats.gratuitous_sent += 1;
}

// ============================================================
// ARP Proxy
// ============================================================

/// Add a proxy ARP entry: respond to ARP requests for IPs in the given subnet.
pub fn addProxy(network_ip: u32, mask: u32, respond_mac: [6]u8) bool {
    if (proxy_count >= MAX_PROXY_ENTRIES) return false;

    // Check for duplicate
    for (proxy_entries[0..proxy_count]) |*pe| {
        if (pe.active and pe.network == network_ip and pe.mask == mask) {
            pe.mac = respond_mac;
            return true;
        }
    }

    for (&proxy_entries) |*pe| {
        if (!pe.active) {
            pe.network = network_ip;
            pe.mask = mask;
            pe.mac = respond_mac;
            pe.active = true;
            proxy_count += 1;
            return true;
        }
    }
    return false;
}

/// Remove a proxy ARP entry.
pub fn removeProxy(network_ip: u32, mask: u32) void {
    for (&proxy_entries) |*pe| {
        if (pe.active and pe.network == network_ip and pe.mask == mask) {
            pe.active = false;
            proxy_count -|= 1;
            return;
        }
    }
}

/// Check if we should proxy-respond for the given IP.
pub fn proxyLookup(ip: u32) ?[6]u8 {
    for (&proxy_entries) |*pe| {
        if (pe.active) {
            if ((ip & pe.mask) == (pe.network & pe.mask)) {
                stats.proxy_replies += 1;
                return pe.mac;
            }
        }
    }
    return null;
}

/// Handle an incoming ARP request: check if we should proxy-reply.
pub fn handleProxyRequest(target_ip: u32, sender_ip: u32, sender_mac: [6]u8) void {
    if (proxyLookup(target_ip)) |proxy_mac| {
        sendArpReplyTo(target_ip, proxy_mac, sender_ip, sender_mac);
    }
}

// ============================================================
// Display
// ============================================================

/// Print the full ARP table with state and age.
pub fn printTable() void {
    const now = pit.getTicks();
    vga.setColor(.yellow, .black);
    vga.write("ARP Table (");
    printDec(entry_count);
    vga.write("/");
    printDec(MAX_ENTRIES);
    vga.write(" entries):\n");
    vga.setColor(.light_grey, .black);

    if (entry_count == 0) {
        vga.write("  (empty)\n");
        printProxyTable();
        printStatistics();
        return;
    }

    vga.write("  IP Address        MAC Address        State       Age(s)  Type\n");
    vga.write("  ---------------   -----------------  ----------  ------  ------\n");

    for (&entries) |*e| {
        if (!e.valid) continue;
        vga.write("  ");
        printIpPadded(e.ip, 18);
        printMac(&e.mac);
        vga.write("  ");
        printStatePadded(e.state, 12);
        const age_secs = (now -| e.timestamp) / 1000;
        printDecPadded(age_secs, 6);
        vga.write("  ");
        if (e.is_static) {
            vga.write("static");
        } else {
            vga.write("dynamic");
        }
        vga.putChar('\n');
    }

    printProxyTable();
    printStatistics();
}

fn printProxyTable() void {
    if (proxy_count == 0) return;

    vga.setColor(.yellow, .black);
    vga.write("\nProxy ARP entries:\n");
    vga.setColor(.light_grey, .black);

    for (&proxy_entries) |*pe| {
        if (!pe.active) continue;
        vga.write("  Network: ");
        fmt.printIp(pe.network);
        vga.write("/");
        printMaskBits(pe.mask);
        vga.write("  MAC: ");
        printMac(&pe.mac);
        vga.putChar('\n');
    }
}

fn printStatistics() void {
    vga.setColor(.yellow, .black);
    vga.write("\nARP Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Requests sent:     ");
    printDec64(stats.requests_sent);
    vga.putChar('\n');
    vga.write("  Replies received:  ");
    printDec64(stats.replies_received);
    vga.putChar('\n');
    vga.write("  Cache hits:        ");
    printDec64(stats.cache_hits);
    vga.putChar('\n');
    vga.write("  Cache misses:      ");
    printDec64(stats.cache_misses);
    vga.putChar('\n');
    vga.write("  Adds:              ");
    printDec64(stats.adds);
    vga.putChar('\n');
    vga.write("  Evictions:         ");
    printDec64(stats.evictions);
    vga.putChar('\n');
    vga.write("  State transitions: ");
    printDec64(stats.age_transitions);
    vga.putChar('\n');
    vga.write("  Gratuitous sent:   ");
    printDec64(stats.gratuitous_sent);
    vga.putChar('\n');
    vga.write("  Proxy replies:     ");
    printDec64(stats.proxy_replies);
    vga.putChar('\n');
    vga.write("  Failed resolves:   ");
    printDec64(stats.failed_resolutions);
    vga.putChar('\n');

    if (stats.cache_hits + stats.cache_misses > 0) {
        const total = stats.cache_hits + stats.cache_misses;
        const pct = (stats.cache_hits * 100) / total;
        vga.write("  Hit rate:          ");
        printDec64(pct);
        vga.write("%\n");
    }
}

/// Get a copy of the statistics.
pub fn getStats() Stats {
    return stats;
}

/// Reset statistics counters.
pub fn resetStats() void {
    stats = .{};
}

/// Get the entry count.
pub fn count() usize {
    return entry_count;
}

// ============================================================
// Internal helpers
// ============================================================

fn createIncompleteEntry(ip: u32) void {
    const now = pit.getTicks();
    // Check if already exists
    for (&entries) |*e| {
        if (e.valid and e.ip == ip) return;
    }
    // Find free slot
    for (&entries) |*e| {
        if (!e.valid) {
            e.* = .{
                .ip = ip,
                .mac = .{ 0, 0, 0, 0, 0, 0 },
                .state = .incomplete,
                .is_static = false,
                .valid = true,
                .timestamp = now,
                .retries = 0,
                .last_probe_tick = now,
            };
            entry_count += 1;
            return;
        }
    }
}

fn evictOldest() void {
    var oldest_idx: ?usize = null;
    var oldest_time: u64 = ~@as(u64, 0);

    for (&entries, 0..) |*e, i| {
        if (e.valid and !e.is_static) {
            // Prefer evicting failed entries first
            if (e.state == .failed) {
                e.valid = false;
                entry_count -|= 1;
                stats.evictions += 1;
                return;
            }
            if (e.timestamp < oldest_time) {
                oldest_time = e.timestamp;
                oldest_idx = i;
            }
        }
    }

    if (oldest_idx) |idx| {
        entries[idx].valid = false;
        entry_count -|= 1;
        stats.evictions += 1;
    }
}

fn sendArpRequest(target_ip: u32) void {
    if (!e1000.isInitialized()) return;
    var pkt: [42]u8 = undefined;
    const broadcast = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

    @memcpy(pkt[0..6], &broadcast);
    @memcpy(pkt[6..12], &e1000.mac);
    net.putU16BE(pkt[12..14], 0x0806);

    net.putU16BE(pkt[14..16], 1); // HW type
    net.putU16BE(pkt[16..18], 0x0800); // Proto type
    pkt[18] = 6; // HW addr len
    pkt[19] = 4; // Proto addr len
    net.putU16BE(pkt[20..22], 1); // Op: request
    @memcpy(pkt[22..28], &e1000.mac);
    net.putU32BE(pkt[28..32], net.OUR_IP);
    @memset(pkt[32..38], 0);
    net.putU32BE(pkt[38..42], target_ip);

    e1000.send(&pkt);
}

fn sendArpReplyTo(sender_ip: u32, sender_mac: [6]u8, target_ip: u32, target_mac: [6]u8) void {
    if (!e1000.isInitialized()) return;
    var pkt: [42]u8 = undefined;

    @memcpy(pkt[0..6], &target_mac);
    @memcpy(pkt[6..12], &sender_mac);
    net.putU16BE(pkt[12..14], 0x0806);

    net.putU16BE(pkt[14..16], 1);
    net.putU16BE(pkt[16..18], 0x0800);
    pkt[18] = 6;
    pkt[19] = 4;
    net.putU16BE(pkt[20..22], 2); // Op: reply
    @memcpy(pkt[22..28], &sender_mac);
    net.putU32BE(pkt[28..32], sender_ip);
    @memcpy(pkt[32..38], &target_mac);
    net.putU32BE(pkt[38..42], target_ip);

    e1000.send(&pkt);
}

// ============================================================
// Print helpers
// ============================================================

fn printIpPadded(ip: u32, width: usize) void {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    pos = writeDecToBuf(&buf, pos, (ip >> 24) & 0xFF);
    buf[pos] = '.';
    pos += 1;
    pos = writeDecToBuf(&buf, pos, (ip >> 16) & 0xFF);
    buf[pos] = '.';
    pos += 1;
    pos = writeDecToBuf(&buf, pos, (ip >> 8) & 0xFF);
    buf[pos] = '.';
    pos += 1;
    pos = writeDecToBuf(&buf, pos, ip & 0xFF);
    vga.write(buf[0..pos]);
    // Pad
    var col = pos;
    while (col < width) : (col += 1) {
        vga.putChar(' ');
    }
}

fn writeDecToBuf(buf: *[16]u8, start: usize, val: u32) usize {
    var pos = start;
    if (val >= 100) {
        buf[pos] = @truncate('0' + val / 100);
        pos += 1;
    }
    if (val >= 10) {
        buf[pos] = @truncate('0' + (val / 10) % 10);
        pos += 1;
    }
    buf[pos] = @truncate('0' + val % 10);
    pos += 1;
    return pos;
}

fn printMac(mac: *const [6]u8) void {
    const hex = "0123456789ABCDEF";
    for (mac, 0..) |b, i| {
        if (i > 0) vga.putChar(':');
        vga.putChar(hex[b >> 4]);
        vga.putChar(hex[b & 0xF]);
    }
}

fn printStatePadded(state: EntryState, width: usize) void {
    const name: []const u8 = switch (state) {
        .incomplete => "INCOMPLETE",
        .reachable => "REACHABLE",
        .stale => "STALE",
        .delay => "DELAY",
        .probe => "PROBE",
        .failed => "FAILED",
    };
    vga.write(name);
    var col = name.len;
    while (col < width) : (col += 1) {
        vga.putChar(' ');
    }
}

fn printMaskBits(mask: u32) void {
    var bits: u32 = 0;
    var m = mask;
    while (m != 0) : (m <<= 1) {
        if (m & 0x80000000 != 0) bits += 1 else break;
    }
    printDec(bits);
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

fn printDecPadded(n: u64, width: usize) void {
    // Count digits
    var digits: usize = 0;
    var tmp = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    // Right-align
    var pad = if (digits < width) width - digits else 0;
    while (pad > 0) : (pad -= 1) {
        vga.putChar(' ');
    }
    printDec(n);
}
