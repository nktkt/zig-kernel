// ICMP (Internet Control Message Protocol) module
//
// Standalone ICMP handling refactored from net.zig.
// Supports Echo Request/Reply, Destination Unreachable, TTL Exceeded, and
// basic traceroute functionality via incrementing TTL echo requests.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");

// ---- ICMP message types ----

pub const TYPE_ECHO_REPLY: u8 = 0;
pub const TYPE_DEST_UNREACHABLE: u8 = 3;
pub const TYPE_ECHO_REQUEST: u8 = 8;
pub const TYPE_TTL_EXCEEDED: u8 = 11;

// ---- Destination Unreachable codes ----
pub const CODE_NET_UNREACHABLE: u8 = 0;
pub const CODE_HOST_UNREACHABLE: u8 = 1;
pub const CODE_PROTO_UNREACHABLE: u8 = 2;
pub const CODE_PORT_UNREACHABLE: u8 = 3;

// ---- Ping statistics ----

pub const PingStats = struct {
    sent: u32 = 0,
    received: u32 = 0,
    lost: u32 = 0,
    min_rtt: u64 = 0xFFFF_FFFF_FFFF_FFFF,
    max_rtt: u64 = 0,
    total_rtt: u64 = 0,
    last_seq: u16 = 0,
    last_id: u16 = 0,
};

// ---- Error statistics ----

pub const ErrorStats = struct {
    dest_unreachable: u32 = 0,
    ttl_exceeded: u32 = 0,
    unknown: u32 = 0,
};

var ping_stats: PingStats = .{};
var error_stats: ErrorStats = .{};

var reply_received: bool = false;
var reply_tick: u64 = 0;
var send_tick: u64 = 0;

// ---- Echo Request / Reply ----

/// Build and send an ICMP Echo Request packet.
/// Returns true if the packet was queued for sending.
pub fn sendEchoRequest(dst_ip: u32, seq: u16, id: u16) bool {
    return sendEchoRequestWithTtl(dst_ip, seq, id, 64);
}

/// Send an echo request with a specific TTL value (for traceroute).
pub fn sendEchoRequestWithTtl(dst_ip: u32, seq: u16, id: u16, ttl: u8) bool {
    // Resolve next-hop MAC
    const next_hop = if ((dst_ip ^ net.OUR_IP) & net.NETMASK != 0) net.GATEWAY_IP else dst_ip;
    const dst_mac = net.arpLookupPub(next_hop) orelse return false;

    const icmp_data_len: usize = 32;
    const icmp_len: usize = 8 + icmp_data_len;
    const ip_len: usize = 20 + icmp_len;
    const total_len: usize = 14 + ip_len;

    var pkt: [128]u8 = undefined;

    // Ethernet header
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    net.putU16BE(pkt[12..14], 0x0800); // ETH_IP

    // IPv4 header
    pkt[14] = 0x45;
    pkt[15] = 0;
    net.putU16BE(pkt[16..18], @truncate(ip_len));
    net.putU16BE(pkt[18..20], seq); // identification
    net.putU16BE(pkt[20..22], 0); // flags + fragment
    pkt[22] = ttl;
    pkt[23] = 1; // PROTO_ICMP
    net.putU16BE(pkt[24..26], 0); // checksum placeholder
    net.putU32BE(pkt[26..30], net.OUR_IP);
    net.putU32BE(pkt[30..34], dst_ip);
    // IP checksum
    const ip_cksum = net.calcChecksumPub(pkt[14..34]);
    net.putU16BE(pkt[24..26], ip_cksum);

    // ICMP Echo Request
    pkt[34] = TYPE_ECHO_REQUEST;
    pkt[35] = 0; // code
    net.putU16BE(pkt[36..38], 0); // checksum placeholder
    net.putU16BE(pkt[38..40], id);
    net.putU16BE(pkt[40..42], seq);

    // Data payload (incrementing bytes)
    for (0..icmp_data_len) |i| {
        pkt[42 + i] = @truncate(i);
    }

    // ICMP checksum
    const icmp_cksum = net.calcChecksumPub(pkt[34 .. 34 + icmp_len]);
    net.putU16BE(pkt[36..38], icmp_cksum);

    e1000.send(pkt[0..total_len]);

    send_tick = pit.getTicks();
    reply_received = false;

    ping_stats.sent += 1;
    ping_stats.last_seq = seq;
    ping_stats.last_id = id;

    return true;
}

/// Handle an incoming ICMP Echo Reply.
pub fn handleEchoReply(data: []const u8) void {
    if (data.len < 8) return;
    if (data[0] != TYPE_ECHO_REPLY) return;

    reply_received = true;
    reply_tick = pit.getTicks();
    const rtt = reply_tick -| send_tick;

    ping_stats.received += 1;
    ping_stats.total_rtt += rtt;

    if (rtt < ping_stats.min_rtt) ping_stats.min_rtt = rtt;
    if (rtt > ping_stats.max_rtt) ping_stats.max_rtt = rtt;
}

/// Handle ICMP error messages (Destination Unreachable, TTL Exceeded).
pub fn handleError(data: []const u8) void {
    if (data.len < 8) return;
    const icmp_type = data[0];

    switch (icmp_type) {
        TYPE_DEST_UNREACHABLE => {
            error_stats.dest_unreachable += 1;
            serial.write("[ICMP] Destination unreachable\n");
        },
        TYPE_TTL_EXCEEDED => {
            error_stats.ttl_exceeded += 1;
            serial.write("[ICMP] TTL exceeded\n");
        },
        else => {
            error_stats.unknown += 1;
        },
    }
}

/// Process incoming ICMP packet (dispatcher).
pub fn handlePacket(data: []const u8) void {
    if (data.len < 8) return;
    const icmp_type = data[0];

    switch (icmp_type) {
        TYPE_ECHO_REPLY => handleEchoReply(data),
        TYPE_DEST_UNREACHABLE, TYPE_TTL_EXCEEDED => handleError(data),
        else => {},
    }
}

/// Check whether the last echo request got a reply.
pub fn gotReply() bool {
    return reply_received;
}

/// Get the RTT (in ticks/ms) of the last received reply.
pub fn lastRtt() u64 {
    return reply_tick -| send_tick;
}

// ---- Traceroute ----

/// Send echo requests with incrementing TTL from 1..max_hops.
/// Each hop is logged to VGA.  This is a best-effort display; actual
/// responses depend on intermediate routers.
pub fn traceroute(dst_ip: u32, max_hops: u8) void {
    vga.setColor(.yellow, .black);
    vga.write("Traceroute to ");
    printIp(dst_ip);
    vga.write(", max ");
    printDec(@as(usize, max_hops));
    vga.write(" hops\n");
    vga.setColor(.light_grey, .black);

    var hop: u8 = 1;
    while (hop <= max_hops) : (hop += 1) {
        printDec(@as(usize, hop));
        vga.write("  ");

        reply_received = false;
        if (!sendEchoRequestWithTtl(dst_ip, hop, 0xABCD, hop)) {
            vga.write("* (send failed)\n");
            continue;
        }

        // Wait briefly for reply (up to 2 seconds)
        const start = pit.getTicks();
        while (pit.getTicks() -| start < 2000) {
            if (reply_received) break;
        }

        if (reply_received) {
            const rtt = reply_tick -| send_tick;
            printDec(@truncate(rtt));
            vga.write(" ms\n");
        } else {
            vga.write("* (timeout)\n");
        }
    }
}

// ---- Statistics ----

pub fn resetStats() void {
    ping_stats = .{};
    error_stats = .{};
}

pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("ICMP Ping Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Sent:     ");
    printDec(@as(usize, ping_stats.sent));
    vga.putChar('\n');
    vga.write("  Received: ");
    printDec(@as(usize, ping_stats.received));
    vga.putChar('\n');

    const lost = ping_stats.sent -| ping_stats.received;
    vga.write("  Lost:     ");
    printDec(@as(usize, lost));
    vga.putChar('\n');

    if (ping_stats.received > 0) {
        vga.write("  Min RTT:  ");
        printDec64(ping_stats.min_rtt);
        vga.write(" ms\n");
        vga.write("  Max RTT:  ");
        printDec64(ping_stats.max_rtt);
        vga.write(" ms\n");
        vga.write("  Avg RTT:  ");
        printDec64(ping_stats.total_rtt / @as(u64, ping_stats.received));
        vga.write(" ms\n");
    }

    vga.setColor(.yellow, .black);
    vga.write("ICMP Errors:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  Dest unreachable: ");
    printDec(@as(usize, error_stats.dest_unreachable));
    vga.putChar('\n');
    vga.write("  TTL exceeded:     ");
    printDec(@as(usize, error_stats.ttl_exceeded));
    vga.putChar('\n');
    vga.write("  Unknown:          ");
    printDec(@as(usize, error_stats.unknown));
    vga.putChar('\n');
}

// ---- Helpers ----

fn printIp(ip: u32) void {
    printDec((ip >> 24) & 0xFF);
    vga.putChar('.');
    printDec((ip >> 16) & 0xFF);
    vga.putChar('.');
    printDec((ip >> 8) & 0xFF);
    vga.putChar('.');
    printDec(ip & 0xFF);
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
