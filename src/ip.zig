// IPv4 protocol implementation — header construction/parsing, fragmentation,
// reassembly, routing table, checksum verification, and statistics.
//
// Follows RFC 791. Supports simple fragmentation (max 4 fragments, 8KB total)
// and a small routing table (8 routes) with longest-prefix-match lookup.

const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");

// ============================================================
// IP header constants
// ============================================================

pub const IP_VERSION: u8 = 4;
pub const IP_MIN_HEADER_LEN: usize = 20;
pub const IP_MAX_HEADER_LEN: usize = 60;
pub const IP_DEFAULT_TTL: u8 = 64;
pub const IP_MAX_PACKET: usize = 1500; // within Ethernet MTU

// Protocol numbers
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;
pub const PROTO_ICMPV6: u8 = 58;

// Fragment flags
pub const FLAG_DF: u16 = 0x4000; // Don't Fragment
pub const FLAG_MF: u16 = 0x2000; // More Fragments
pub const OFFSET_MASK: u16 = 0x1FFF;

// IP Options
pub const OPT_END: u8 = 0;
pub const OPT_NOP: u8 = 1;
pub const OPT_RECORD_ROUTE: u8 = 7;
pub const OPT_TIMESTAMP: u8 = 68;

// ============================================================
// Parsed IP header
// ============================================================

pub const IpHeader = struct {
    version: u4,
    ihl: u4, // header length in 32-bit words
    tos: u8, // Type of Service / DSCP + ECN
    total_length: u16,
    identification: u16,
    flags: u3,
    fragment_offset: u13,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src_ip: u32,
    dst_ip: u32,
    header_len: usize, // in bytes (ihl * 4)
    options_len: usize, // header_len - 20
};

// ============================================================
// IP Options parsed
// ============================================================

pub const IpOptions = struct {
    record_route: [9]u32, // up to 9 IP addresses
    rr_count: usize,
    timestamp_entries: [4]u32, // up to 4 timestamps
    ts_count: usize,
    has_record_route: bool,
    has_timestamp: bool,
};

// ============================================================
// IP routing table
// ============================================================

pub const Route = struct {
    destination: u32,
    netmask: u32,
    gateway: u32,
    metric: u16,
    active: bool,
};

const MAX_ROUTES = 8;
var routing_table: [MAX_ROUTES]Route = [_]Route{.{
    .destination = 0,
    .netmask = 0,
    .gateway = 0,
    .metric = 0,
    .active = false,
}} ** MAX_ROUTES;

// ============================================================
// Fragment reassembly
// ============================================================

const MAX_FRAGMENTS = 4;
const MAX_REASSEMBLY_SIZE = 8192; // 8KB max reassembled packet
const REASSEMBLY_TIMEOUT_MS = 10000; // 10 seconds

const FragmentEntry = struct {
    id: u16,
    src_ip: u32,
    dst_ip: u32,
    protocol: u8,
    buffer: [MAX_REASSEMBLY_SIZE]u8,
    received: [MAX_FRAGMENTS]bool,
    frag_offset: [MAX_FRAGMENTS]u16, // offset in 8-byte units
    frag_len: [MAX_FRAGMENTS]u16,
    frag_count: usize,
    total_len: usize, // known after last fragment received
    last_received: bool, // got fragment with MF=0
    start_tick: u64,
    active: bool,
};

const MAX_REASSEMBLY_ENTRIES = 4;
var reassembly_table: [MAX_REASSEMBLY_ENTRIES]FragmentEntry = undefined;

// ============================================================
// Statistics
// ============================================================

pub const IpStats = struct {
    packets_sent: u64,
    packets_received: u64,
    packets_forwarded: u64,
    packets_fragmented: u64,
    fragments_created: u64,
    packets_reassembled: u64,
    reassembly_timeouts: u32,
    checksum_errors: u32,
    header_errors: u32,
    ttl_exceeded: u32,
    no_route: u32,
    truncated: u32,
};

var ip_stats: IpStats = .{
    .packets_sent = 0,
    .packets_received = 0,
    .packets_forwarded = 0,
    .packets_fragmented = 0,
    .fragments_created = 0,
    .packets_reassembled = 0,
    .reassembly_timeouts = 0,
    .checksum_errors = 0,
    .header_errors = 0,
    .ttl_exceeded = 0,
    .no_route = 0,
    .truncated = 0,
};

// Identification counter for outgoing packets
var next_id: u16 = 1;

// ============================================================
// Initialization
// ============================================================

pub fn init() void {
    for (&reassembly_table) |*e| {
        e.active = false;
    }
    next_id = @truncate(pit.getTicks() & 0xFFFF);
    if (next_id == 0) next_id = 1;

    // Add default route through gateway
    _ = addRoute(0, 0, net.GATEWAY_IP, 100);
    // Add connected route for local subnet
    _ = addRoute(net.OUR_IP & net.NETMASK, net.NETMASK, 0, 0);
}

// ============================================================
// IP header parsing
// ============================================================

/// Parse an IP header from raw packet data.
pub fn parseHeader(data: []const u8) ?IpHeader {
    if (data.len < IP_MIN_HEADER_LEN) return null;

    const ver_ihl = data[0];
    const version: u4 = @truncate(ver_ihl >> 4);
    const ihl: u4 = @truncate(ver_ihl & 0x0F);

    if (version != IP_VERSION) return null;
    if (ihl < 5) return null;

    const header_len: usize = @as(usize, ihl) * 4;
    if (data.len < header_len) return null;

    const total_length = net_util.getU16BE(data[2..4]);
    const id = net_util.getU16BE(data[4..6]);
    const flags_frag = net_util.getU16BE(data[6..8]);

    return IpHeader{
        .version = version,
        .ihl = ihl,
        .tos = data[1],
        .total_length = total_length,
        .identification = id,
        .flags = @truncate(flags_frag >> 13),
        .fragment_offset = @truncate(flags_frag & 0x1FFF),
        .ttl = data[8],
        .protocol = data[9],
        .checksum = net_util.getU16BE(data[10..12]),
        .src_ip = net_util.getU32BE(data[12..16]),
        .dst_ip = net_util.getU32BE(data[16..20]),
        .header_len = header_len,
        .options_len = header_len - IP_MIN_HEADER_LEN,
    };
}

/// Build an IP header into `buf`. Returns the header length in bytes.
pub fn buildHeader(buf: []u8, src_ip: u32, dst_ip: u32, protocol: u8, payload_len: usize, flags: u16) usize {
    if (buf.len < IP_MIN_HEADER_LEN) return 0;
    const total_len: u16 = @truncate(IP_MIN_HEADER_LEN + payload_len);

    buf[0] = 0x45; // version=4, IHL=5
    buf[1] = 0; // TOS
    net_util.putU16BE(buf[2..4], total_len);
    net_util.putU16BE(buf[4..6], next_id);
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    net_util.putU16BE(buf[6..8], flags);
    buf[8] = IP_DEFAULT_TTL;
    buf[9] = protocol;
    net_util.putU16BE(buf[10..12], 0); // checksum placeholder
    net_util.putU32BE(buf[12..16], src_ip);
    net_util.putU32BE(buf[16..20], dst_ip);

    // Compute IP header checksum
    const cksum = net_util.internetChecksum(buf[0..IP_MIN_HEADER_LEN]);
    net_util.putU16BE(buf[10..12], cksum);

    return IP_MIN_HEADER_LEN;
}

// ============================================================
// IP checksum verification
// ============================================================

/// Verify the IP header checksum. Returns true if valid.
pub fn verifyChecksum(data: []const u8) bool {
    if (data.len < IP_MIN_HEADER_LEN) return false;
    const ihl = @as(usize, data[0] & 0x0F) * 4;
    if (data.len < ihl) return false;
    return net_util.internetChecksum(data[0..ihl]) == 0;
}

// ============================================================
// IP options parsing
// ============================================================

/// Parse IP options from header bytes beyond the base 20 bytes.
pub fn parseOptions(data: []const u8, header_len: usize) IpOptions {
    var opts = IpOptions{
        .record_route = [_]u32{0} ** 9,
        .rr_count = 0,
        .timestamp_entries = [_]u32{0} ** 4,
        .ts_count = 0,
        .has_record_route = false,
        .has_timestamp = false,
    };

    if (header_len <= IP_MIN_HEADER_LEN) return opts;
    const options_data = data[IP_MIN_HEADER_LEN..header_len];

    var i: usize = 0;
    while (i < options_data.len) {
        const opt_type = options_data[i];
        if (opt_type == OPT_END) break;
        if (opt_type == OPT_NOP) {
            i += 1;
            continue;
        }

        // Multi-byte option: type(1) + length(1) + data
        if (i + 1 >= options_data.len) break;
        const opt_len = options_data[i + 1];
        if (opt_len < 2 or i + opt_len > options_data.len) break;

        switch (opt_type) {
            OPT_RECORD_ROUTE => {
                opts.has_record_route = true;
                // pointer(1) + route data
                if (opt_len >= 3) {
                    var j: usize = 3; // skip type, length, pointer
                    while (j + 3 < opt_len and opts.rr_count < 9) {
                        opts.record_route[opts.rr_count] = net_util.getU32BE(options_data[i + j ..][0..4]);
                        opts.rr_count += 1;
                        j += 4;
                    }
                }
            },
            OPT_TIMESTAMP => {
                opts.has_timestamp = true;
                if (opt_len >= 4) {
                    var j: usize = 4; // skip type, length, pointer, overflow+flag
                    while (j + 3 < opt_len and opts.ts_count < 4) {
                        opts.timestamp_entries[opts.ts_count] = net_util.getU32BE(options_data[i + j ..][0..4]);
                        opts.ts_count += 1;
                        j += 4;
                    }
                }
            },
            else => {},
        }

        i += opt_len;
    }

    return opts;
}

// ============================================================
// IP routing table management
// ============================================================

/// Add a route to the routing table.
pub fn addRoute(dest: u32, mask: u32, gateway: u32, metric: u16) bool {
    for (&routing_table) |*r| {
        if (!r.active) {
            r.* = .{
                .destination = dest & mask,
                .netmask = mask,
                .gateway = gateway,
                .metric = metric,
                .active = true,
            };
            return true;
        }
    }
    return false; // table full
}

/// Remove a route matching the given destination.
pub fn removeRoute(dest: u32) bool {
    for (&routing_table) |*r| {
        if (r.active and r.destination == dest) {
            r.active = false;
            return true;
        }
    }
    return false;
}

/// Find the best route for a destination IP using longest prefix match.
pub fn findRoute(dest_ip: u32) ?Route {
    var best: ?Route = null;
    var best_prefix: u8 = 0;
    var best_metric: u16 = 0xFFFF;

    for (&routing_table) |*r| {
        if (!r.active) continue;
        if ((dest_ip & r.netmask) == r.destination) {
            const prefix = net_util.maskToCidr(r.netmask);
            if (prefix > best_prefix or (prefix == best_prefix and r.metric < best_metric)) {
                best = r.*;
                best_prefix = prefix;
                best_metric = r.metric;
            }
        }
    }

    return best;
}

/// Print the routing table to VGA.
pub fn printRoutingTable() void {
    vga.setColor(.yellow, .black);
    vga.write("IP Routing Table:\n");
    vga.setColor(.light_cyan, .black);
    vga.write("  Destination       Netmask           Gateway         Metric\n");
    vga.setColor(.light_grey, .black);

    for (&routing_table) |*r| {
        if (!r.active) continue;

        vga.write("  ");
        printIpPadded(r.destination, 16);
        vga.write("  ");
        printIpPadded(r.netmask, 16);
        vga.write("  ");
        if (r.gateway == 0) {
            vga.write("*               ");
        } else {
            printIpPadded(r.gateway, 16);
        }
        vga.write("  ");
        net_util.printDec(r.metric);
        vga.putChar('\n');
    }
}

// ============================================================
// IP fragmentation
// ============================================================

/// Fragment a large IP payload into multiple Ethernet frames and send them.
/// Returns true if all fragments were sent successfully.
pub fn fragmentAndSend(dst_ip: u32, protocol: u8, payload: []const u8) bool {
    if (payload.len == 0) return false;
    const max_payload = IP_MAX_PACKET - IP_MIN_HEADER_LEN; // ~1480

    // If it fits in a single packet, no fragmentation needed
    if (payload.len <= max_payload) {
        return sendPacket(dst_ip, protocol, payload);
    }

    // Fragment offset granularity is 8 bytes
    const frag_data_size = (max_payload / 8) * 8; // 1480 -> 1480 (already aligned)
    var offset: usize = 0;
    var frag_num: usize = 0;
    const id = next_id;
    next_id +%= 1;

    while (offset < payload.len and frag_num < MAX_FRAGMENTS) {
        const remaining = payload.len - offset;
        const this_len = if (remaining > frag_data_size) frag_data_size else remaining;
        const more_fragments = (offset + this_len < payload.len);
        const frag_offset_val: u16 = @truncate(offset / 8);
        const flags: u16 = if (more_fragments) FLAG_MF | frag_offset_val else frag_offset_val;

        var pkt: [1500]u8 = undefined;

        // Build Ethernet + IP header
        const next_hop = resolveNextHop(dst_ip);
        const dst_mac = net.arpLookupPub(next_hop) orelse return false;

        // Ethernet header
        @memcpy(pkt[0..6], &dst_mac);
        @memcpy(pkt[6..12], &e1000.mac);
        net_util.putU16BE(pkt[12..14], 0x0800);

        // IP header
        const ip_total: u16 = @truncate(IP_MIN_HEADER_LEN + this_len);
        pkt[14] = 0x45;
        pkt[15] = 0;
        net_util.putU16BE(pkt[16..18], ip_total);
        net_util.putU16BE(pkt[18..20], id);
        net_util.putU16BE(pkt[20..22], flags);
        pkt[22] = IP_DEFAULT_TTL;
        pkt[23] = protocol;
        net_util.putU16BE(pkt[24..26], 0);
        net_util.putU32BE(pkt[26..30], net.OUR_IP);
        net_util.putU32BE(pkt[30..34], dst_ip);
        const cksum = net_util.internetChecksum(pkt[14..34]);
        net_util.putU16BE(pkt[24..26], cksum);

        // Payload fragment
        @memcpy(pkt[34 .. 34 + this_len], payload[offset .. offset + this_len]);

        const total = 14 + IP_MIN_HEADER_LEN + this_len;
        e1000.send(pkt[0..total]);

        ip_stats.fragments_created += 1;
        offset += this_len;
        frag_num += 1;
    }

    ip_stats.packets_fragmented += 1;
    return offset >= payload.len;
}

// ============================================================
// Fragment reassembly
// ============================================================

/// Process an incoming IP fragment and attempt reassembly.
/// Returns reassembled payload slice if complete, null otherwise.
pub fn reassembleFragment(header: IpHeader, data: []const u8) ?[]const u8 {
    const frag_offset = @as(u16, header.fragment_offset);
    const more_frags = (header.flags & 1) != 0; // MF flag

    // Find existing reassembly entry
    var entry: ?*FragmentEntry = null;
    for (&reassembly_table) |*e| {
        if (e.active and e.id == header.identification and
            e.src_ip == header.src_ip and e.dst_ip == header.dst_ip)
        {
            entry = e;
            break;
        }
    }

    // Create new entry if not found
    if (entry == null) {
        for (&reassembly_table) |*e| {
            if (!e.active) {
                e.active = true;
                e.id = header.identification;
                e.src_ip = header.src_ip;
                e.dst_ip = header.dst_ip;
                e.protocol = header.protocol;
                e.frag_count = 0;
                e.total_len = 0;
                e.last_received = false;
                e.start_tick = pit.getTicks();
                for (&e.received) |*r| r.* = false;
                entry = e;
                break;
            }
        }
    }

    const e = entry orelse return null;

    // Check timeout
    if (pit.getTicks() -| e.start_tick > REASSEMBLY_TIMEOUT_MS) {
        e.active = false;
        ip_stats.reassembly_timeouts += 1;
        return null;
    }

    // Store this fragment
    if (e.frag_count >= MAX_FRAGMENTS) return null;

    const payload_data = data[header.header_len..];
    const byte_offset = @as(usize, frag_offset) * 8;
    if (byte_offset + payload_data.len > MAX_REASSEMBLY_SIZE) return null;

    // Copy into reassembly buffer
    for (payload_data, 0..) |b, i| {
        e.buffer[byte_offset + i] = b;
    }

    e.frag_offset[e.frag_count] = frag_offset;
    e.frag_len[e.frag_count] = @truncate(payload_data.len);
    e.received[e.frag_count] = true;
    e.frag_count += 1;

    if (!more_frags) {
        e.last_received = true;
        e.total_len = byte_offset + payload_data.len;
    }

    // Check if reassembly is complete
    if (e.last_received) {
        // Verify we have all fragments by checking coverage
        // Simple check: all fragment slots are filled
        var complete = true;
        var expected: usize = 0;
        for (0..e.frag_count) |i| {
            if (!e.received[i]) {
                complete = false;
                break;
            }
            expected += e.frag_len[i];
        }

        if (complete and expected == e.total_len) {
            ip_stats.packets_reassembled += 1;
            const result = e.buffer[0..e.total_len];
            e.active = false;
            return result;
        }
    }

    return null;
}

/// Clean up timed-out reassembly entries.
pub fn cleanupReassembly() void {
    const now = pit.getTicks();
    for (&reassembly_table) |*e| {
        if (e.active and (now -| e.start_tick > REASSEMBLY_TIMEOUT_MS)) {
            e.active = false;
            ip_stats.reassembly_timeouts += 1;
        }
    }
}

// ============================================================
// Send an IP packet
// ============================================================

/// Construct a complete IP packet and send it over Ethernet.
/// Handles ARP resolution and next-hop selection.
pub fn sendPacket(dst_ip: u32, protocol: u8, payload: []const u8) bool {
    if (!e1000.isInitialized()) return false;
    if (payload.len > IP_MAX_PACKET - IP_MIN_HEADER_LEN) {
        return fragmentAndSend(dst_ip, protocol, payload);
    }

    var pkt: [1500]u8 = undefined;

    // Resolve next hop
    const next_hop = resolveNextHop(dst_ip);
    const dst_mac = net.arpLookupPub(next_hop) orelse {
        ip_stats.no_route += 1;
        return false;
    };

    // Ethernet header
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    net_util.putU16BE(pkt[12..14], 0x0800);

    // IP header
    const hdr_len = buildHeader(pkt[14..], net.OUR_IP, dst_ip, protocol, payload.len, FLAG_DF);
    if (hdr_len == 0) return false;

    // Payload
    const ip_start = 14 + hdr_len;
    if (payload.len > 0) {
        @memcpy(pkt[ip_start .. ip_start + payload.len], payload);
    }

    const total = ip_start + payload.len;
    e1000.send(pkt[0..total]);
    ip_stats.packets_sent += 1;

    return true;
}

/// Process a received IP packet: verify checksum, handle fragments, dispatch.
pub fn receivePacket(data: []const u8) void {
    const header = parseHeader(data) orelse {
        ip_stats.header_errors += 1;
        return;
    };

    // Verify checksum
    if (!verifyChecksum(data)) {
        ip_stats.checksum_errors += 1;
        return;
    }

    // Check TTL
    if (header.ttl == 0) {
        ip_stats.ttl_exceeded += 1;
        return;
    }

    // Check if packet is truncated
    if (data.len < header.total_length) {
        ip_stats.truncated += 1;
        return;
    }

    ip_stats.packets_received += 1;

    // Handle fragmented packets
    if (header.fragment_offset != 0 or (header.flags & 1) != 0) {
        _ = reassembleFragment(header, data);
        return;
    }

    // Non-fragmented packet: pass to upper layer
    // (handled by net.zig dispatcher)
}

// ============================================================
// Statistics
// ============================================================

/// Get current IP statistics.
pub fn getStats() IpStats {
    return ip_stats;
}

/// Reset all IP statistics.
pub fn resetStats() void {
    ip_stats = .{
        .packets_sent = 0,
        .packets_received = 0,
        .packets_forwarded = 0,
        .packets_fragmented = 0,
        .fragments_created = 0,
        .packets_reassembled = 0,
        .reassembly_timeouts = 0,
        .checksum_errors = 0,
        .header_errors = 0,
        .ttl_exceeded = 0,
        .no_route = 0,
        .truncated = 0,
    };
}

/// Print IP statistics to VGA.
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("IPv4 Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Sent:         ");
    net_util.printDec64(ip_stats.packets_sent);
    vga.putChar('\n');
    vga.write("  Received:     ");
    net_util.printDec64(ip_stats.packets_received);
    vga.putChar('\n');
    vga.write("  Forwarded:    ");
    net_util.printDec64(ip_stats.packets_forwarded);
    vga.putChar('\n');
    vga.write("  Fragmented:   ");
    net_util.printDec64(ip_stats.packets_fragmented);
    vga.putChar('\n');
    vga.write("  Frags created:");
    net_util.printDec64(ip_stats.fragments_created);
    vga.putChar('\n');
    vga.write("  Reassembled:  ");
    net_util.printDec64(ip_stats.packets_reassembled);
    vga.putChar('\n');

    vga.setColor(.light_red, .black);
    vga.write("  Errors:\n");
    vga.setColor(.light_grey, .black);
    vga.write("    Checksum:   ");
    net_util.printDec(ip_stats.checksum_errors);
    vga.putChar('\n');
    vga.write("    Header:     ");
    net_util.printDec(ip_stats.header_errors);
    vga.putChar('\n');
    vga.write("    TTL exceed: ");
    net_util.printDec(ip_stats.ttl_exceeded);
    vga.putChar('\n');
    vga.write("    No route:   ");
    net_util.printDec(ip_stats.no_route);
    vga.putChar('\n');
    vga.write("    Truncated:  ");
    net_util.printDec(ip_stats.truncated);
    vga.putChar('\n');
    vga.write("    Reasm tout: ");
    net_util.printDec(ip_stats.reassembly_timeouts);
    vga.putChar('\n');
}

// ============================================================
// Internal helpers
// ============================================================

fn resolveNextHop(dst_ip: u32) u32 {
    // Check routing table first
    if (findRoute(dst_ip)) |route| {
        if (route.gateway != 0) return route.gateway;
    }
    // Same subnet -> direct, otherwise -> default gateway
    if ((dst_ip ^ net.OUR_IP) & net.NETMASK == 0) return dst_ip;
    return net.GATEWAY_IP;
}

fn printIpPadded(ip: u32, width: usize) void {
    var buf: [16]u8 = undefined;
    const s = net_util.ipToStr(ip, &buf);
    vga.write(s);
    // Pad to width
    var pad = width -| s.len;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
}
