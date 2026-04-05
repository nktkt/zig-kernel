// Network statistics and monitoring
//
// Centralized counters for bytes, packets, connections, and errors across
// all network protocols.  Call update() from each protocol module whenever
// data is sent or received to keep tallies accurate.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- Protocol identifiers ----

pub const Protocol = enum(u8) {
    ethernet = 0,
    arp = 1,
    ipv4 = 2,
    icmp = 3,
    tcp = 4,
    udp = 5,
    other = 6,
};

pub const Direction = enum(u1) {
    tx = 0,
    rx = 1,
};

const PROTO_COUNT = 7;

// ---- Per-protocol byte/packet counters ----

pub const ProtoCounters = struct {
    bytes_tx: u64 = 0,
    bytes_rx: u64 = 0,
    packets_tx: u64 = 0,
    packets_rx: u64 = 0,
};

var proto: [PROTO_COUNT]ProtoCounters = [_]ProtoCounters{.{}} ** PROTO_COUNT;

// ---- TCP connection tracking ----

pub const TcpStats = struct {
    active_opens: u32 = 0,
    passive_opens: u32 = 0,
    established: u32 = 0,
    closed: u32 = 0,
    resets: u32 = 0,
    retransmits: u32 = 0,
    current_established: u32 = 0,
};

var tcp_stats: TcpStats = .{};

// ---- UDP stats ----

pub const UdpStats = struct {
    datagrams_sent: u32 = 0,
    datagrams_received: u32 = 0,
    no_port_errors: u32 = 0,
};

var udp_stats: UdpStats = .{};

// ---- Error counters ----

pub const ErrorCounters = struct {
    checksum_errors: u32 = 0,
    timeout_errors: u32 = 0,
    refused_errors: u32 = 0,
    length_errors: u32 = 0,
    unknown_proto: u32 = 0,
    dropped: u32 = 0,
};

var errors: ErrorCounters = .{};

// ---- Global totals (aggregated) ----

var start_tick: u64 = 0;

pub fn init() void {
    start_tick = pit.getTicks();
}

// ---- Update API ----

/// Increment byte and packet counters for the given protocol and direction.
pub fn update(protocol: Protocol, direction: Direction, bytes: usize) void {
    const idx = @intFromEnum(protocol);
    if (idx >= PROTO_COUNT) return;

    switch (direction) {
        .tx => {
            proto[idx].bytes_tx += bytes;
            proto[idx].packets_tx += 1;
        },
        .rx => {
            proto[idx].bytes_rx += bytes;
            proto[idx].packets_rx += 1;
        },
    }
}

/// Record a TCP connection event.
pub fn tcpEvent(comptime event: enum { active_open, passive_open, established, closed, reset, retransmit }) void {
    switch (event) {
        .active_open => {
            tcp_stats.active_opens += 1;
            tcp_stats.current_established += 1;
        },
        .passive_open => {
            tcp_stats.passive_opens += 1;
            tcp_stats.current_established += 1;
        },
        .established => tcp_stats.established += 1,
        .closed => {
            tcp_stats.closed += 1;
            tcp_stats.current_established -|= 1;
        },
        .reset => {
            tcp_stats.resets += 1;
            tcp_stats.current_established -|= 1;
        },
        .retransmit => tcp_stats.retransmits += 1,
    }
}

/// Record a UDP event.
pub fn udpSent() void {
    udp_stats.datagrams_sent += 1;
}

pub fn udpReceived() void {
    udp_stats.datagrams_received += 1;
}

pub fn udpNoPort() void {
    udp_stats.no_port_errors += 1;
}

/// Record an error.
pub fn recordError(comptime kind: enum { checksum, timeout, refused, length, unknown_proto, dropped }) void {
    switch (kind) {
        .checksum => errors.checksum_errors += 1,
        .timeout => errors.timeout_errors += 1,
        .refused => errors.refused_errors += 1,
        .length => errors.length_errors += 1,
        .unknown_proto => errors.unknown_proto += 1,
        .dropped => errors.dropped += 1,
    }
}

// ---- Reset ----

/// Clear all statistics counters.
pub fn reset() void {
    for (&proto) |*p| {
        p.* = .{};
    }
    tcp_stats = .{};
    udp_stats = .{};
    errors = .{};
    start_tick = pit.getTicks();
}

// ---- Display ----

/// One-line summary: total bytes TX/RX.
pub fn printSummary() void {
    var total_tx: u64 = 0;
    var total_rx: u64 = 0;
    var total_pkt_tx: u64 = 0;
    var total_pkt_rx: u64 = 0;
    for (&proto) |*p| {
        total_tx += p.bytes_tx;
        total_rx += p.bytes_rx;
        total_pkt_tx += p.packets_tx;
        total_pkt_rx += p.packets_rx;
    }
    vga.setColor(.light_cyan, .black);
    vga.write("Net: TX ");
    printBytes(total_tx);
    vga.write(" (");
    printDec64(total_pkt_tx);
    vga.write(" pkts), RX ");
    printBytes(total_rx);
    vga.write(" (");
    printDec64(total_pkt_rx);
    vga.write(" pkts)\n");
    vga.setColor(.light_grey, .black);
}

/// Full statistics display with per-protocol breakdown.
pub fn printDetailed() void {
    const elapsed = (pit.getTicks() -| start_tick) / 1000;

    vga.setColor(.yellow, .black);
    vga.write("Network Statistics (");
    printDec64(elapsed);
    vga.write("s uptime)\n");
    vga.setColor(.light_grey, .black);

    // Per-protocol table
    vga.write("  Protocol   TX Bytes    RX Bytes    TX Pkts   RX Pkts\n");

    const names = [_][]const u8{ "Ethernet", "ARP     ", "IPv4    ", "ICMP    ", "TCP     ", "UDP     ", "Other   " };
    for (names, 0..) |name, i| {
        vga.write("  ");
        vga.write(name);
        vga.write("  ");
        printPadded64(proto[i].bytes_tx, 10);
        vga.write("  ");
        printPadded64(proto[i].bytes_rx, 10);
        vga.write("  ");
        printPadded64(proto[i].packets_tx, 8);
        vga.write("  ");
        printPadded64(proto[i].packets_rx, 8);
        vga.putChar('\n');
    }

    // TCP connections
    vga.setColor(.yellow, .black);
    vga.write("  TCP Connections:\n");
    vga.setColor(.light_grey, .black);
    vga.write("    Active opens:  ");
    printDec(@as(usize, tcp_stats.active_opens));
    vga.write("  Passive opens: ");
    printDec(@as(usize, tcp_stats.passive_opens));
    vga.putChar('\n');
    vga.write("    Established:   ");
    printDec(@as(usize, tcp_stats.established));
    vga.write("  Current:       ");
    printDec(@as(usize, tcp_stats.current_established));
    vga.putChar('\n');
    vga.write("    Closed:        ");
    printDec(@as(usize, tcp_stats.closed));
    vga.write("  Resets:        ");
    printDec(@as(usize, tcp_stats.resets));
    vga.putChar('\n');
    vga.write("    Retransmits:   ");
    printDec(@as(usize, tcp_stats.retransmits));
    vga.putChar('\n');

    // UDP
    vga.setColor(.yellow, .black);
    vga.write("  UDP:\n");
    vga.setColor(.light_grey, .black);
    vga.write("    Sent: ");
    printDec(@as(usize, udp_stats.datagrams_sent));
    vga.write("  Received: ");
    printDec(@as(usize, udp_stats.datagrams_received));
    vga.write("  No-port: ");
    printDec(@as(usize, udp_stats.no_port_errors));
    vga.putChar('\n');

    // Errors
    vga.setColor(.yellow, .black);
    vga.write("  Errors:\n");
    vga.setColor(.light_grey, .black);
    vga.write("    Checksum: ");
    printDec(@as(usize, errors.checksum_errors));
    vga.write("  Timeout: ");
    printDec(@as(usize, errors.timeout_errors));
    vga.write("  Refused: ");
    printDec(@as(usize, errors.refused_errors));
    vga.putChar('\n');
    vga.write("    Length:   ");
    printDec(@as(usize, errors.length_errors));
    vga.write("  Unknown: ");
    printDec(@as(usize, errors.unknown_proto));
    vga.write("  Dropped: ");
    printDec(@as(usize, errors.dropped));
    vga.putChar('\n');
}

// ---- Helpers ----

fn printBytes(n: u64) void {
    if (n < 1024) {
        printDec64(n);
        vga.write(" B");
    } else if (n < 1024 * 1024) {
        printDec64(n / 1024);
        vga.write(" KB");
    } else {
        printDec64(n / (1024 * 1024));
        vga.write(" MB");
    }
}

fn printPadded64(val: u64, width: usize) void {
    // Count digits
    var digits: usize = 1;
    var tmp = val;
    while (tmp >= 10) {
        tmp /= 10;
        digits += 1;
    }
    // Pad
    var pad = width -| digits;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
    printDec64(val);
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
