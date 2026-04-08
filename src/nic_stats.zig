// Network interface statistics — per-NIC counters, throughput, ifconfig-style display
//
// Tracks tx/rx packets, bytes, errors, drops, collisions, multicast for up to
// 4 network interfaces. Provides throughput calculation and link speed display.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_NICS: usize = 4;
const THROUGHPUT_INTERVAL_MS: u64 = 1000; // 1 second window

// ============================================================
// Types
// ============================================================

pub const NicEvent = enum(u8) {
    tx_packet,
    rx_packet,
    tx_error,
    rx_error,
    tx_drop,
    rx_drop,
    collision,
    multicast_rx,
};

pub const LinkSpeed = enum(u16) {
    speed_10 = 10,
    speed_100 = 100,
    speed_1000 = 1000,
    unknown = 0,
};

pub const NicStats = struct {
    // Packet counters
    tx_packets: u64 = 0,
    rx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    rx_bytes: u64 = 0,

    // Error counters
    tx_errors: u64 = 0,
    rx_errors: u64 = 0,
    tx_dropped: u64 = 0,
    rx_dropped: u64 = 0,

    // Other
    collisions: u64 = 0,
    multicast: u64 = 0,

    // Throughput tracking (snapshot at last interval)
    prev_tx_bytes: u64 = 0,
    prev_rx_bytes: u64 = 0,
    prev_tx_packets: u64 = 0,
    prev_rx_packets: u64 = 0,
    last_throughput_tick: u64 = 0,

    // Computed throughput (bytes/sec and packets/sec)
    tx_bytes_per_sec: u64 = 0,
    rx_bytes_per_sec: u64 = 0,
    tx_pps: u64 = 0,
    rx_pps: u64 = 0,
};

pub const NicInfo = struct {
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    link_speed: LinkSpeed = .unknown,
    link_up: bool = false,
    active: bool = false,
    stats: NicStats = .{},
};

// ============================================================
// State
// ============================================================

var nics: [MAX_NICS]NicInfo = [_]NicInfo{.{}} ** MAX_NICS;
var nic_count: usize = 0;

// ============================================================
// Public API
// ============================================================

/// Register a NIC for statistics tracking. Returns the NIC id.
pub fn registerNic(name: []const u8, mac: [6]u8, speed: LinkSpeed) ?u8 {
    if (nic_count >= MAX_NICS) return null;
    const id: u8 = @intCast(nic_count);

    var info = &nics[nic_count];
    info.active = true;
    info.mac = mac;
    info.link_speed = speed;
    info.link_up = true;
    info.stats = .{};
    info.name_len = @intCast(@min(name.len, 16));
    @memcpy(info.name[0..info.name_len], name[0..info.name_len]);
    info.stats.last_throughput_tick = pit.getTicks();

    nic_count += 1;
    return id;
}

/// Update counters for a given NIC event.
pub fn update(nic_id: u8, event: NicEvent, bytes: u32) void {
    if (nic_id >= nic_count or !nics[nic_id].active) return;
    var s = &nics[nic_id].stats;

    switch (event) {
        .tx_packet => {
            s.tx_packets += 1;
            s.tx_bytes += bytes;
        },
        .rx_packet => {
            s.rx_packets += 1;
            s.rx_bytes += bytes;
        },
        .tx_error => {
            s.tx_errors += 1;
        },
        .rx_error => {
            s.rx_errors += 1;
        },
        .tx_drop => {
            s.tx_dropped += 1;
        },
        .rx_drop => {
            s.rx_dropped += 1;
        },
        .collision => {
            s.collisions += 1;
        },
        .multicast_rx => {
            s.multicast += 1;
            s.rx_packets += 1;
            s.rx_bytes += bytes;
        },
    }
}

/// Get stats for a NIC.
pub fn getStats(nic_id: u8) ?NicStats {
    if (nic_id >= nic_count or !nics[nic_id].active) return null;
    return nics[nic_id].stats;
}

/// Get full NIC info.
pub fn getNicInfo(nic_id: u8) ?NicInfo {
    if (nic_id >= nic_count or !nics[nic_id].active) return null;
    return nics[nic_id];
}

/// Reset stats for a NIC.
pub fn resetStats(nic_id: u8) void {
    if (nic_id >= nic_count or !nics[nic_id].active) return;
    nics[nic_id].stats = .{};
    nics[nic_id].stats.last_throughput_tick = pit.getTicks();
}

/// Set link status.
pub fn setLinkUp(nic_id: u8, up: bool) void {
    if (nic_id >= nic_count) return;
    nics[nic_id].link_up = up;
}

/// Set link speed.
pub fn setLinkSpeed(nic_id: u8, speed: LinkSpeed) void {
    if (nic_id >= nic_count) return;
    nics[nic_id].link_speed = speed;
}

/// Get number of registered NICs.
pub fn getNicCount() usize {
    return nic_count;
}

// ============================================================
// Throughput calculation — call periodically (e.g. once/sec)
// ============================================================

/// Update throughput calculations for all NICs.
pub fn updateThroughput() void {
    const now = pit.getTicks();

    for (nics[0..nic_count]) |*nic| {
        if (!nic.active) continue;
        var s = &nic.stats;

        const elapsed = now -| s.last_throughput_tick;
        if (elapsed < THROUGHPUT_INTERVAL_MS) continue;

        // Calculate rates (per second)
        const delta_tx_bytes = s.tx_bytes -| s.prev_tx_bytes;
        const delta_rx_bytes = s.rx_bytes -| s.prev_rx_bytes;
        const delta_tx_pkts = s.tx_packets -| s.prev_tx_packets;
        const delta_rx_pkts = s.rx_packets -| s.prev_rx_packets;

        const elapsed_secs = elapsed / 1000;
        if (elapsed_secs > 0) {
            s.tx_bytes_per_sec = delta_tx_bytes / elapsed_secs;
            s.rx_bytes_per_sec = delta_rx_bytes / elapsed_secs;
            s.tx_pps = delta_tx_pkts / elapsed_secs;
            s.rx_pps = delta_rx_pkts / elapsed_secs;
        }

        // Snapshot current values
        s.prev_tx_bytes = s.tx_bytes;
        s.prev_rx_bytes = s.rx_bytes;
        s.prev_tx_packets = s.tx_packets;
        s.prev_rx_packets = s.rx_packets;
        s.last_throughput_tick = now;
    }
}

// ============================================================
// Display — ifconfig-style
// ============================================================

/// Print stats for a specific NIC.
pub fn printStats(nic_id: u8) void {
    if (nic_id >= nic_count or !nics[nic_id].active) {
        vga.write("NIC not found\n");
        return;
    }

    const nic = &nics[nic_id];
    const s = &nic.stats;

    // Interface name and flags
    vga.setColor(.light_green, .black);
    vga.write(nic.name[0..nic.name_len]);
    vga.setColor(.light_grey, .black);
    vga.write(": flags=");
    if (nic.link_up) {
        vga.write("<UP,RUNNING>");
    } else {
        vga.write("<DOWN>");
    }
    vga.write("  mtu 1500\n");

    // MAC address
    vga.write("        ether ");
    printMac(&nic.mac);
    vga.putChar('\n');

    // Link speed
    vga.write("        speed ");
    switch (nic.link_speed) {
        .speed_10 => vga.write("10 Mbps"),
        .speed_100 => vga.write("100 Mbps"),
        .speed_1000 => vga.write("1000 Mbps"),
        .unknown => vga.write("unknown"),
    }
    vga.putChar('\n');

    // RX stats
    vga.write("        RX packets ");
    printDec64(s.rx_packets);
    vga.write("  bytes ");
    printDec64(s.rx_bytes);
    vga.write(" (");
    printSize(s.rx_bytes);
    vga.write(")\n");

    vga.write("        RX errors ");
    printDec64(s.rx_errors);
    vga.write("  dropped ");
    printDec64(s.rx_dropped);
    vga.write("  multicast ");
    printDec64(s.multicast);
    vga.putChar('\n');

    // TX stats
    vga.write("        TX packets ");
    printDec64(s.tx_packets);
    vga.write("  bytes ");
    printDec64(s.tx_bytes);
    vga.write(" (");
    printSize(s.tx_bytes);
    vga.write(")\n");

    vga.write("        TX errors ");
    printDec64(s.tx_errors);
    vga.write("  dropped ");
    printDec64(s.tx_dropped);
    vga.write("  collisions ");
    printDec64(s.collisions);
    vga.putChar('\n');

    vga.putChar('\n');
}

/// Print all NIC stats.
pub fn printAllStats() void {
    vga.setColor(.yellow, .black);
    vga.write("Network Interface Statistics:\n");
    vga.setColor(.light_grey, .black);

    if (nic_count == 0) {
        vga.write("  No network interfaces registered.\n");
        return;
    }

    var i: u8 = 0;
    while (i < nic_count) : (i += 1) {
        printStats(i);
    }
}

/// Print throughput for all NICs.
pub fn printThroughput() void {
    vga.setColor(.yellow, .black);
    vga.write("Network Throughput:\n");
    vga.setColor(.light_grey, .black);

    if (nic_count == 0) {
        vga.write("  No network interfaces.\n");
        return;
    }

    vga.write("  Interface   TX B/s     RX B/s     TX pps   RX pps\n");
    vga.write("  ---------   --------   --------   ------   ------\n");

    for (nics[0..nic_count]) |*nic| {
        if (!nic.active) continue;

        vga.write("  ");
        vga.write(nic.name[0..nic.name_len]);
        padTo(14, nic.name_len + 2);

        printDecPadded(nic.stats.tx_bytes_per_sec, 8);
        vga.write("   ");
        printDecPadded(nic.stats.rx_bytes_per_sec, 8);
        vga.write("   ");
        printDecPadded(nic.stats.tx_pps, 6);
        vga.write("   ");
        printDecPadded(nic.stats.rx_pps, 6);
        vga.putChar('\n');
    }

    // Link speed utilization
    vga.putChar('\n');
    for (nics[0..nic_count]) |*nic| {
        if (!nic.active or nic.link_speed == .unknown) continue;
        const link_bps = @as(u64, @intFromEnum(nic.link_speed)) * 1_000_000 / 8;
        if (link_bps == 0) continue;

        const total_bps = nic.stats.tx_bytes_per_sec + nic.stats.rx_bytes_per_sec;
        const utilization_pct = (total_bps * 100) / link_bps;

        vga.write("  ");
        vga.write(nic.name[0..nic.name_len]);
        vga.write(" utilization: ");
        printDec64(utilization_pct);
        vga.write("% of ");
        printDec64(@intFromEnum(nic.link_speed));
        vga.write(" Mbps\n");
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn printMac(mac: *const [6]u8) void {
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        if (i > 0) vga.putChar(':');
        vga.putChar(hex[b >> 4]);
        vga.putChar(hex[b & 0xF]);
    }
}

fn printSize(bytes: u64) void {
    if (bytes >= 1024 * 1024 * 1024) {
        printDec64(bytes / (1024 * 1024 * 1024));
        vga.write(" GB");
    } else if (bytes >= 1024 * 1024) {
        printDec64(bytes / (1024 * 1024));
        vga.write(" MB");
    } else if (bytes >= 1024) {
        printDec64(bytes / 1024);
        vga.write(" KB");
    } else {
        printDec64(bytes);
        vga.write(" B");
    }
}

fn padTo(target: usize, current: usize) void {
    var col = current;
    while (col < target) : (col += 1) {
        vga.putChar(' ');
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

fn printDecPadded(n: u64, width: usize) void {
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
    var pad = if (digits < width) width - digits else 0;
    while (pad > 0) : (pad -= 1) {
        vga.putChar(' ');
    }
    printDec64(n);
}
