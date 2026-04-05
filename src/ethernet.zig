// Ethernet frame handling — build, parse, VLAN support, statistics
//
// Provides structured Ethernet frame construction and parsing, EtherType
// constants, VLAN (802.1Q) tagging/untagging, MAC address classification,
// and per-ethertype frame statistics.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");

// ============================================================
// EtherType constants
// ============================================================

pub const ETHER_IPV4: u16 = 0x0800;
pub const ETHER_ARP: u16 = 0x0806;
pub const ETHER_IPV6: u16 = 0x86DD;
pub const ETHER_VLAN: u16 = 0x8100;
pub const ETHER_LLDP: u16 = 0x88CC;

// ============================================================
// Ethernet header / frame constants
// ============================================================

pub const ETH_HEADER_LEN: usize = 14; // dst(6) + src(6) + ethertype(2)
pub const ETH_VLAN_HEADER_LEN: usize = 18; // dst(6) + src(6) + 0x8100(2) + TCI(2) + ethertype(2)
pub const ETH_MIN_FRAME: usize = 60; // Minimum frame size (no FCS)
pub const ETH_MAX_FRAME: usize = 1514; // Maximum frame size (no FCS)
pub const ETH_MTU: usize = 1500; // Maximum payload size
pub const ETH_VLAN_MTU: usize = 1500; // Same payload MTU with VLAN

pub const BROADCAST_MAC = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub const ZERO_MAC = [_]u8{ 0, 0, 0, 0, 0, 0 };

// ============================================================
// Parsed Ethernet frame
// ============================================================

pub const EthFrame = struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,
    vlan_id: u16, // 0 if no VLAN tag
    vlan_priority: u3, // PCP field from 802.1Q
    payload: []const u8,
    total_len: usize,
};

// ============================================================
// VLAN tag
// ============================================================

pub const VlanTag = struct {
    priority: u3, // PCP (Priority Code Point)
    dei: bool, // Drop Eligible Indicator
    vid: u12, // VLAN Identifier
};

// ============================================================
// Frame statistics
// ============================================================

pub const FrameStats = struct {
    frames_sent: u64,
    frames_received: u64,
    bytes_sent: u64,
    bytes_received: u64,
    errors_tx: u32,
    errors_rx: u32,
    // Per-ethertype counters
    ipv4_rx: u32,
    ipv4_tx: u32,
    arp_rx: u32,
    arp_tx: u32,
    ipv6_rx: u32,
    ipv6_tx: u32,
    vlan_rx: u32,
    other_rx: u32,
    multicast_rx: u32,
    broadcast_rx: u32,
};

var stats: FrameStats = .{
    .frames_sent = 0,
    .frames_received = 0,
    .bytes_sent = 0,
    .bytes_received = 0,
    .errors_tx = 0,
    .errors_rx = 0,
    .ipv4_rx = 0,
    .ipv4_tx = 0,
    .arp_rx = 0,
    .arp_tx = 0,
    .ipv6_rx = 0,
    .ipv6_tx = 0,
    .vlan_rx = 0,
    .other_rx = 0,
    .multicast_rx = 0,
    .broadcast_rx = 0,
};

// ============================================================
// Build an Ethernet frame
// ============================================================

/// Build a standard Ethernet II frame.
/// Returns the total frame length, or 0 on error.
pub fn buildFrame(dst_mac: [6]u8, src_mac: [6]u8, ethertype: u16, payload: []const u8, buf: []u8) usize {
    const total = ETH_HEADER_LEN + payload.len;
    if (total > buf.len) return 0;
    if (payload.len > ETH_MTU) return 0;

    // Destination MAC
    @memcpy(buf[0..6], &dst_mac);
    // Source MAC
    @memcpy(buf[6..12], &src_mac);
    // EtherType
    net_util.putU16BE(buf[12..14], ethertype);
    // Payload
    if (payload.len > 0) {
        @memcpy(buf[ETH_HEADER_LEN .. ETH_HEADER_LEN + payload.len], payload);
    }

    stats.frames_sent += 1;
    stats.bytes_sent += total;

    // Track per-ethertype
    switch (ethertype) {
        ETHER_IPV4 => stats.ipv4_tx += 1,
        ETHER_ARP => stats.arp_tx += 1,
        else => {},
    }

    return total;
}

/// Build a VLAN-tagged (802.1Q) Ethernet frame.
/// Returns the total frame length, or 0 on error.
pub fn buildVlanFrame(dst_mac: [6]u8, src_mac: [6]u8, vlan: VlanTag, ethertype: u16, payload: []const u8, buf: []u8) usize {
    const total = ETH_VLAN_HEADER_LEN + payload.len;
    if (total > buf.len) return 0;
    if (payload.len > ETH_VLAN_MTU) return 0;

    // Destination MAC
    @memcpy(buf[0..6], &dst_mac);
    // Source MAC
    @memcpy(buf[6..12], &src_mac);
    // VLAN TPID
    net_util.putU16BE(buf[12..14], ETHER_VLAN);
    // TCI: PCP(3) | DEI(1) | VID(12)
    const tci: u16 = (@as(u16, vlan.priority) << 13) |
        (if (vlan.dei) @as(u16, 1) << 12 else @as(u16, 0)) |
        @as(u16, vlan.vid);
    net_util.putU16BE(buf[14..16], tci);
    // EtherType
    net_util.putU16BE(buf[16..18], ethertype);
    // Payload
    if (payload.len > 0) {
        @memcpy(buf[ETH_VLAN_HEADER_LEN .. ETH_VLAN_HEADER_LEN + payload.len], payload);
    }

    stats.frames_sent += 1;
    stats.bytes_sent += total;

    return total;
}

// ============================================================
// Parse an Ethernet frame
// ============================================================

/// Parse raw bytes into an EthFrame structure.
/// Returns null if the data is too short for a valid frame.
pub fn parseFrame(data: []const u8) ?EthFrame {
    if (data.len < ETH_HEADER_LEN) return null;

    var frame: EthFrame = undefined;
    @memcpy(&frame.dst_mac, data[0..6]);
    @memcpy(&frame.src_mac, data[6..12]);

    const raw_type = net_util.getU16BE(data[12..14]);

    if (raw_type == ETHER_VLAN) {
        // 802.1Q tagged frame
        if (data.len < ETH_VLAN_HEADER_LEN) return null;
        const tci = net_util.getU16BE(data[14..16]);
        frame.vlan_priority = @truncate((tci >> 13) & 0x7);
        frame.vlan_id = @truncate(tci & 0xFFF);
        frame.ethertype = net_util.getU16BE(data[16..18]);
        frame.payload = data[ETH_VLAN_HEADER_LEN..];
        frame.total_len = data.len;

        stats.vlan_rx += 1;
    } else {
        frame.ethertype = raw_type;
        frame.vlan_id = 0;
        frame.vlan_priority = 0;
        frame.payload = data[ETH_HEADER_LEN..];
        frame.total_len = data.len;
    }

    // Update stats
    stats.frames_received += 1;
    stats.bytes_received += data.len;

    switch (frame.ethertype) {
        ETHER_IPV4 => stats.ipv4_rx += 1,
        ETHER_ARP => stats.arp_rx += 1,
        ETHER_IPV6 => stats.ipv6_rx += 1,
        else => stats.other_rx += 1,
    }

    if (net_util.isBroadcast(frame.dst_mac)) {
        stats.broadcast_rx += 1;
    } else if (net_util.isMulticast(frame.dst_mac)) {
        stats.multicast_rx += 1;
    }

    return frame;
}

// ============================================================
// VLAN tag / untag helpers
// ============================================================

/// Strip a VLAN tag from a tagged frame, producing an untagged frame.
/// Returns new length, or 0 on error.
pub fn untagVlan(data: []u8, len: usize) usize {
    if (len < ETH_VLAN_HEADER_LEN) return 0;
    const raw_type = net_util.getU16BE(data[12..14]);
    if (raw_type != ETHER_VLAN) return len; // already untagged

    // Copy inner ethertype over the VLAN TPID+TCI
    const inner_type_0 = data[16];
    const inner_type_1 = data[17];
    data[12] = inner_type_0;
    data[13] = inner_type_1;

    // Shift payload left by 4 bytes
    const payload_start: usize = ETH_VLAN_HEADER_LEN;
    const new_payload_start: usize = ETH_HEADER_LEN;
    const payload_len = len - payload_start;
    var i: usize = 0;
    while (i < payload_len) : (i += 1) {
        data[new_payload_start + i] = data[payload_start + i];
    }

    return len - 4;
}

/// Insert a VLAN tag into an untagged frame. `buf` must have room for 4 extra bytes.
/// Returns new length, or 0 on error.
pub fn tagVlan(data: []u8, len: usize, buf_cap: usize, vlan: VlanTag) usize {
    if (len < ETH_HEADER_LEN) return 0;
    if (len + 4 > buf_cap) return 0;

    // Shift payload right by 4 bytes
    const payload_len = len - ETH_HEADER_LEN;
    var i: usize = payload_len;
    while (i > 0) {
        i -= 1;
        data[ETH_VLAN_HEADER_LEN + i] = data[ETH_HEADER_LEN + i];
    }

    // Save original ethertype
    const orig_type_0 = data[12];
    const orig_type_1 = data[13];

    // Insert VLAN TPID
    net_util.putU16BE(data[12..14], ETHER_VLAN);
    // Insert TCI
    const tci: u16 = (@as(u16, vlan.priority) << 13) |
        (if (vlan.dei) @as(u16, 1) << 12 else @as(u16, 0)) |
        @as(u16, vlan.vid);
    net_util.putU16BE(data[14..16], tci);
    // Restore original ethertype
    data[16] = orig_type_0;
    data[17] = orig_type_1;

    return len + 4;
}

// ============================================================
// MAC address classification
// ============================================================

/// Check if MAC is broadcast.
pub fn isBroadcastMac(mac: [6]u8) bool {
    return net_util.isBroadcast(mac);
}

/// Check if MAC is multicast (group bit set, not broadcast).
pub fn isMulticastMac(mac: [6]u8) bool {
    return net_util.isMulticast(mac);
}

/// Check if MAC is unicast.
pub fn isUnicastMac(mac: [6]u8) bool {
    return net_util.isUnicast(mac);
}

// ============================================================
// EtherType name lookup
// ============================================================

/// Return a human-readable name for an EtherType value.
pub fn etherTypeName(et: u16) []const u8 {
    return switch (et) {
        ETHER_IPV4 => "IPv4",
        ETHER_ARP => "ARP",
        ETHER_IPV6 => "IPv6",
        ETHER_VLAN => "VLAN",
        ETHER_LLDP => "LLDP",
        else => "Other",
    };
}

// ============================================================
// MTU helpers
// ============================================================

/// Check if a payload fits within standard Ethernet MTU.
pub fn fitsInMtu(payload_len: usize) bool {
    return payload_len <= ETH_MTU;
}

/// Check if a complete frame (with header) fits within max frame size.
pub fn fitsInFrame(total_len: usize) bool {
    return total_len <= ETH_MAX_FRAME;
}

// ============================================================
// Statistics
// ============================================================

/// Reset all frame statistics.
pub fn resetStats() void {
    stats = .{
        .frames_sent = 0,
        .frames_received = 0,
        .bytes_sent = 0,
        .bytes_received = 0,
        .errors_tx = 0,
        .errors_rx = 0,
        .ipv4_rx = 0,
        .ipv4_tx = 0,
        .arp_rx = 0,
        .arp_tx = 0,
        .ipv6_rx = 0,
        .ipv6_tx = 0,
        .vlan_rx = 0,
        .other_rx = 0,
        .multicast_rx = 0,
        .broadcast_rx = 0,
    };
}

/// Record a transmit error.
pub fn recordTxError() void {
    stats.errors_tx += 1;
}

/// Record a receive error.
pub fn recordRxError() void {
    stats.errors_rx += 1;
}

/// Get current stats snapshot.
pub fn getStats() FrameStats {
    return stats;
}

/// Print Ethernet frame statistics to VGA.
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("Ethernet Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Frames TX:    ");
    net_util.printDec64(stats.frames_sent);
    vga.write("  RX: ");
    net_util.printDec64(stats.frames_received);
    vga.putChar('\n');

    vga.write("  Bytes  TX:    ");
    net_util.printDec64(stats.bytes_sent);
    vga.write("  RX: ");
    net_util.printDec64(stats.bytes_received);
    vga.putChar('\n');

    vga.write("  Errors TX:    ");
    net_util.printDec(stats.errors_tx);
    vga.write("  RX: ");
    net_util.printDec(stats.errors_rx);
    vga.putChar('\n');

    vga.setColor(.light_cyan, .black);
    vga.write("  By EtherType:\n");
    vga.setColor(.light_grey, .black);

    vga.write("    IPv4  TX: ");
    net_util.printDec(stats.ipv4_tx);
    vga.write("  RX: ");
    net_util.printDec(stats.ipv4_rx);
    vga.putChar('\n');

    vga.write("    ARP   TX: ");
    net_util.printDec(stats.arp_tx);
    vga.write("  RX: ");
    net_util.printDec(stats.arp_rx);
    vga.putChar('\n');

    vga.write("    IPv6  RX: ");
    net_util.printDec(stats.ipv6_rx);
    vga.putChar('\n');

    vga.write("    VLAN  RX: ");
    net_util.printDec(stats.vlan_rx);
    vga.putChar('\n');

    vga.write("    Other RX: ");
    net_util.printDec(stats.other_rx);
    vga.putChar('\n');

    vga.write("  Multicast RX: ");
    net_util.printDec(stats.multicast_rx);
    vga.write("  Broadcast RX: ");
    net_util.printDec(stats.broadcast_rx);
    vga.putChar('\n');
}
