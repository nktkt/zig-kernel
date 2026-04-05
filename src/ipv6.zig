// IPv6 basic support — address handling, header parsing, ICMPv6, link-local
//
// Provides IPv6 address structures, parsing/formatting, header construction,
// link-local address generation from MAC (EUI-64), ICMPv6 neighbor
// solicitation/advertisement, and pseudo-header checksum.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");
const e1000 = @import("e1000.zig");

// ============================================================
// IPv6 constants
// ============================================================

pub const IPV6_HEADER_LEN: usize = 40;
pub const IPV6_VERSION: u8 = 6;
pub const IPV6_DEFAULT_HOP_LIMIT: u8 = 64;

// Next Header values (same as IPv4 protocol numbers)
pub const NH_TCP: u8 = 6;
pub const NH_UDP: u8 = 17;
pub const NH_ICMPV6: u8 = 58;
pub const NH_NONE: u8 = 59;
pub const NH_FRAGMENT: u8 = 44;
pub const NH_HOP_BY_HOP: u8 = 0;

// ICMPv6 types
pub const ICMPV6_ECHO_REQUEST: u8 = 128;
pub const ICMPV6_ECHO_REPLY: u8 = 129;
pub const ICMPV6_NEIGHBOR_SOLICIT: u8 = 135;
pub const ICMPV6_NEIGHBOR_ADVERT: u8 = 136;
pub const ICMPV6_ROUTER_SOLICIT: u8 = 133;
pub const ICMPV6_ROUTER_ADVERT: u8 = 134;

// ============================================================
// IPv6 address (128-bit)
// ============================================================

pub const Ipv6Addr = struct {
    octets: [16]u8,

    pub const UNSPECIFIED = Ipv6Addr{ .octets = [_]u8{0} ** 16 };
    pub const LOOPBACK = blk: {
        var addr = Ipv6Addr{ .octets = [_]u8{0} ** 16 };
        addr.octets[15] = 1;
        break :blk addr;
    };

    /// Compare two IPv6 addresses for equality.
    pub fn eql(self: Ipv6Addr, other: Ipv6Addr) bool {
        for (self.octets, other.octets) |a, b| {
            if (a != b) return false;
        }
        return true;
    }
};

// Multicast all-nodes: ff02::1
pub const ALL_NODES_MULTICAST = blk: {
    var addr = Ipv6Addr{ .octets = [_]u8{0} ** 16 };
    addr.octets[0] = 0xFF;
    addr.octets[1] = 0x02;
    addr.octets[15] = 0x01;
    break :blk addr;
};

// Solicited-node multicast prefix: ff02::1:ff00:0/104
pub const SOLICITED_NODE_PREFIX = blk: {
    var addr = Ipv6Addr{ .octets = [_]u8{0} ** 16 };
    addr.octets[0] = 0xFF;
    addr.octets[1] = 0x02;
    addr.octets[11] = 0x01;
    addr.octets[12] = 0xFF;
    break :blk addr;
};

// ============================================================
// IPv6 header (40 bytes)
// ============================================================

pub const Ipv6Header = struct {
    version: u4,
    traffic_class: u8,
    flow_label: u20,
    payload_length: u16,
    next_header: u8,
    hop_limit: u8,
    src_addr: Ipv6Addr,
    dst_addr: Ipv6Addr,
};

// ============================================================
// Dual-stack support flag
// ============================================================

var dual_stack_enabled: bool = false;

pub fn enableDualStack() void {
    dual_stack_enabled = true;
}

pub fn disableDualStack() void {
    dual_stack_enabled = false;
}

pub fn isDualStackEnabled() bool {
    return dual_stack_enabled;
}

// ============================================================
// Local address (link-local generated from MAC)
// ============================================================

var local_link_addr: Ipv6Addr = Ipv6Addr.UNSPECIFIED;
var local_addr_valid: bool = false;

// ============================================================
// Address parsing: "::1", "fe80::1", "2001:db8::1"
// ============================================================

/// Parse a text IPv6 address into an Ipv6Addr.
/// Supports "::" for zero-compression.
pub fn parseAddr(s: []const u8) ?Ipv6Addr {
    if (s.len == 0 or s.len > 39) return null;

    var addr = Ipv6Addr{ .octets = [_]u8{0} ** 16 };
    var groups: [8]u16 = [_]u16{0} ** 8;
    var group_idx: usize = 0;
    var double_colon_pos: ?usize = null;
    var current: u16 = 0;
    var has_digit = false;
    var i: usize = 0;

    while (i < s.len) {
        const c = s[i];
        if (c == ':') {
            if (i + 1 < s.len and s[i + 1] == ':') {
                // Double colon
                if (double_colon_pos != null) return null; // only one :: allowed
                if (has_digit) {
                    if (group_idx >= 8) return null;
                    groups[group_idx] = current;
                    group_idx += 1;
                }
                double_colon_pos = group_idx;
                current = 0;
                has_digit = false;
                i += 2;
                continue;
            } else {
                // Single colon
                if (!has_digit) return null;
                if (group_idx >= 8) return null;
                groups[group_idx] = current;
                group_idx += 1;
                current = 0;
                has_digit = false;
                i += 1;
                continue;
            }
        }

        const val = hexDigitVal(c) orelse return null;
        current = current * 16 + val;
        has_digit = true;
        i += 1;
    }

    // Handle last group
    if (has_digit) {
        if (group_idx >= 8) return null;
        groups[group_idx] = current;
        group_idx += 1;
    }

    // Expand ::
    if (double_colon_pos) |dc_pos| {
        if (group_idx > 8) return null;
        const groups_after_dc = group_idx - dc_pos;
        const zeros_to_insert = 8 - group_idx;

        // Shift groups after :: to the end
        var j: usize = 7;
        var src_idx: usize = group_idx;
        while (src_idx > dc_pos) {
            src_idx -= 1;
            groups[j] = groups[src_idx];
            if (j == 0) break;
            j -= 1;
        }
        _ = groups_after_dc;

        // Fill zeros
        var k: usize = dc_pos;
        while (k < dc_pos + zeros_to_insert) : (k += 1) {
            groups[k] = 0;
        }
    } else {
        if (group_idx != 8) return null;
    }

    // Convert groups to octets
    for (0..8) |g| {
        addr.octets[g * 2] = @truncate(groups[g] >> 8);
        addr.octets[g * 2 + 1] = @truncate(groups[g] & 0xFF);
    }

    return addr;
}

// ============================================================
// Address formatting
// ============================================================

/// Format an IPv6 address into a buffer.
/// Returns a slice of the buffer containing the formatted address.
/// Uses "::" compression for the longest run of zero groups.
pub fn formatAddr(addr: Ipv6Addr, buf: *[40]u8) []u8 {
    // Extract 16-bit groups
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = @as(u16, addr.octets[i * 2]) << 8 | addr.octets[i * 2 + 1];
    }

    // Find longest run of zeros for :: compression
    var best_start: usize = 8;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;

    for (0..8) |i| {
        if (groups[i] == 0) {
            if (run_len == 0) run_start = i;
            run_len += 1;
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
        } else {
            run_len = 0;
        }
    }

    // Only compress runs of 2 or more
    if (best_len < 2) {
        best_start = 8;
        best_len = 0;
    }

    var pos: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (i == best_start) {
            buf[pos] = ':';
            pos += 1;
            if (i == 0) {
                buf[pos] = ':';
                pos += 1;
            }
            i += best_len;
            if (i >= 8) {
                // Trailing ::
                if (pos < 2 or buf[pos - 1] != ':') {
                    buf[pos] = ':';
                    pos += 1;
                }
            }
            continue;
        }

        if (i > 0 and i != best_start + best_len) {
            buf[pos] = ':';
            pos += 1;
        } else if (i > 0 and i == best_start + best_len) {
            // Already have : from compression
        }

        pos = writeHexGroup(buf, pos, groups[i]);
        i += 1;
    }

    return buf[0..pos];
}

fn writeHexGroup(buf: *[40]u8, start: usize, val: u16) usize {
    const hex = "0123456789abcdef";
    var pos = start;

    // Skip leading zeros
    if (val == 0) {
        buf[pos] = '0';
        return pos + 1;
    }

    var started = false;
    if (val >= 0x1000) {
        buf[pos] = hex[(val >> 12) & 0xF];
        pos += 1;
        started = true;
    }
    if (started or val >= 0x100) {
        buf[pos] = hex[(val >> 8) & 0xF];
        pos += 1;
        started = true;
    }
    if (started or val >= 0x10) {
        buf[pos] = hex[(val >> 4) & 0xF];
        pos += 1;
    }
    buf[pos] = hex[val & 0xF];
    pos += 1;

    return pos;
}

// ============================================================
// Address classification
// ============================================================

/// Check if an address is link-local (fe80::/10).
pub fn isLinkLocal(addr: Ipv6Addr) bool {
    return addr.octets[0] == 0xFE and (addr.octets[1] & 0xC0) == 0x80;
}

/// Check if an address is the loopback address (::1).
pub fn isLoopback(addr: Ipv6Addr) bool {
    return addr.eql(Ipv6Addr.LOOPBACK);
}

/// Check if an address is the unspecified address (::).
pub fn isUnspecified(addr: Ipv6Addr) bool {
    return addr.eql(Ipv6Addr.UNSPECIFIED);
}

/// Check if an address is multicast (ff00::/8).
pub fn isMulticast(addr: Ipv6Addr) bool {
    return addr.octets[0] == 0xFF;
}

/// Check if an address is a global unicast address (2000::/3).
pub fn isGlobalUnicast(addr: Ipv6Addr) bool {
    return (addr.octets[0] & 0xE0) == 0x20;
}

/// Check if an address is a unique local address (fc00::/7).
pub fn isUniqueLocal(addr: Ipv6Addr) bool {
    return (addr.octets[0] & 0xFE) == 0xFC;
}

// ============================================================
// Link-local address from MAC (EUI-64)
// ============================================================

/// Generate a link-local IPv6 address from a MAC address using EUI-64.
/// fe80::XXYY:XXFF:FEXX:XXYY (with the U/L bit flipped)
pub fn linkLocalFromMac(mac: [6]u8) Ipv6Addr {
    var addr = Ipv6Addr{ .octets = [_]u8{0} ** 16 };

    // fe80:: prefix
    addr.octets[0] = 0xFE;
    addr.octets[1] = 0x80;

    // EUI-64 from MAC
    addr.octets[8] = mac[0] ^ 0x02; // flip U/L bit
    addr.octets[9] = mac[1];
    addr.octets[10] = mac[2];
    addr.octets[11] = 0xFF;
    addr.octets[12] = 0xFE;
    addr.octets[13] = mac[3];
    addr.octets[14] = mac[4];
    addr.octets[15] = mac[5];

    return addr;
}

/// Generate and store the local link-local address from the NIC's MAC.
pub fn initLinkLocal() void {
    local_link_addr = linkLocalFromMac(e1000.mac);
    local_addr_valid = true;
}

/// Get our link-local address.
pub fn getLinkLocal() ?Ipv6Addr {
    if (local_addr_valid) return local_link_addr;
    return null;
}

// ============================================================
// IPv6 header parsing
// ============================================================

/// Parse an IPv6 header from raw data.
pub fn parseHeader(data: []const u8) ?Ipv6Header {
    if (data.len < IPV6_HEADER_LEN) return null;

    const ver_tc_fl = net_util.getU32BE(data[0..4]);
    const version: u4 = @truncate(ver_tc_fl >> 28);
    if (version != IPV6_VERSION) return null;

    const traffic_class: u8 = @truncate((ver_tc_fl >> 20) & 0xFF);
    const flow_label: u20 = @truncate(ver_tc_fl & 0xFFFFF);

    var hdr: Ipv6Header = undefined;
    hdr.version = version;
    hdr.traffic_class = traffic_class;
    hdr.flow_label = flow_label;
    hdr.payload_length = net_util.getU16BE(data[4..6]);
    hdr.next_header = data[6];
    hdr.hop_limit = data[7];
    @memcpy(&hdr.src_addr.octets, data[8..24]);
    @memcpy(&hdr.dst_addr.octets, data[24..40]);

    return hdr;
}

/// Build an IPv6 header into `buf`. Returns 40 (header length).
pub fn buildHeader(buf: []u8, src: Ipv6Addr, dst: Ipv6Addr, next_header: u8, payload_len: u16) usize {
    if (buf.len < IPV6_HEADER_LEN) return 0;

    // Version(4) + Traffic Class(8) + Flow Label(20)
    const ver_tc_fl: u32 = (@as(u32, IPV6_VERSION) << 28);
    net_util.putU32BE(buf[0..4], ver_tc_fl);
    net_util.putU16BE(buf[4..6], payload_len);
    buf[6] = next_header;
    buf[7] = IPV6_DEFAULT_HOP_LIMIT;
    @memcpy(buf[8..24], &src.octets);
    @memcpy(buf[24..40], &dst.octets);

    return IPV6_HEADER_LEN;
}

// ============================================================
// IPv6 pseudo-header checksum
// ============================================================

/// Compute the IPv6 pseudo-header checksum for TCP/UDP/ICMPv6.
pub fn pseudoHeaderChecksum(src: Ipv6Addr, dst: Ipv6Addr, next_header: u8, payload_len: u16, payload: []const u8) u16 {
    var sum: u32 = 0;

    // Source address (16 bytes)
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        sum += @as(u32, src.octets[i]) << 8 | src.octets[i + 1];
    }

    // Destination address (16 bytes)
    i = 0;
    while (i < 16) : (i += 2) {
        sum += @as(u32, dst.octets[i]) << 8 | dst.octets[i + 1];
    }

    // Upper-layer packet length (32-bit)
    sum += @as(u32, payload_len);

    // Next header (zero-padded to 32-bit, only lower byte)
    sum += @as(u32, next_header);

    // Payload
    i = 0;
    while (i + 1 < payload.len) : (i += 2) {
        sum += @as(u32, payload[i]) << 8 | payload[i + 1];
    }
    if (i < payload.len) {
        sum += @as(u32, payload[i]) << 8;
    }

    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

// ============================================================
// ICMPv6 Neighbor Solicitation / Advertisement (basic)
// ============================================================

/// Build an ICMPv6 Neighbor Solicitation message.
/// Target is the address being queried.
pub fn buildNeighborSolicitation(target: Ipv6Addr, buf: []u8) usize {
    // ICMPv6 NS: type(1) + code(1) + checksum(2) + reserved(4) + target(16) = 24
    // + source link-layer address option (8)
    const NS_LEN: usize = 32;
    if (buf.len < NS_LEN) return 0;

    buf[0] = ICMPV6_NEIGHBOR_SOLICIT;
    buf[1] = 0; // code
    net_util.putU16BE(buf[2..4], 0); // checksum placeholder
    @memset(buf[4..8], 0); // reserved
    @memcpy(buf[8..24], &target.octets); // target address

    // Source Link-Layer Address option (type=1, length=1 in 8-byte units)
    buf[24] = 1; // type: source link-layer
    buf[25] = 1; // length: 1 (= 8 bytes)
    @memcpy(buf[26..32], &e1000.mac);

    // Compute checksum with pseudo-header
    if (local_addr_valid) {
        // Solicited-node multicast for target
        var dest = SOLICITED_NODE_PREFIX;
        dest.octets[13] = target.octets[13];
        dest.octets[14] = target.octets[14];
        dest.octets[15] = target.octets[15];

        const cksum = pseudoHeaderChecksum(local_link_addr, dest, NH_ICMPV6, @truncate(NS_LEN), buf[0..NS_LEN]);
        net_util.putU16BE(buf[2..4], cksum);
    }

    return NS_LEN;
}

/// Build an ICMPv6 Neighbor Advertisement message.
pub fn buildNeighborAdvertisement(target: Ipv6Addr, solicited: bool, buf: []u8) usize {
    // ICMPv6 NA: type(1) + code(1) + checksum(2) + flags(4) + target(16) = 24
    // + target link-layer address option (8)
    const NA_LEN: usize = 32;
    if (buf.len < NA_LEN) return 0;

    buf[0] = ICMPV6_NEIGHBOR_ADVERT;
    buf[1] = 0;
    net_util.putU16BE(buf[2..4], 0); // checksum placeholder

    // Flags: R(router)=0, S(solicited), O(override)=1
    var flags: u32 = 0x20000000; // Override flag
    if (solicited) flags |= 0x40000000; // Solicited flag
    net_util.putU32BE(buf[4..8], flags);

    @memcpy(buf[8..24], &target.octets);

    // Target Link-Layer Address option
    buf[24] = 2; // type: target link-layer
    buf[25] = 1; // length: 1 (= 8 bytes)
    @memcpy(buf[26..32], &e1000.mac);

    return NA_LEN;
}

// ============================================================
// Display
// ============================================================

/// Print an IPv6 address to VGA.
pub fn printAddr(addr: Ipv6Addr) void {
    var buf: [40]u8 = undefined;
    const s = formatAddr(addr, &buf);
    vga.write(s);
}

/// Print IPv6 status to VGA.
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("IPv6 Status:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Dual-stack: ");
    if (dual_stack_enabled) {
        vga.setColor(.light_green, .black);
        vga.write("enabled\n");
    } else {
        vga.setColor(.dark_grey, .black);
        vga.write("disabled\n");
    }
    vga.setColor(.light_grey, .black);

    vga.write("  Link-local: ");
    if (local_addr_valid) {
        printAddr(local_link_addr);
    } else {
        vga.write("(not configured)");
    }
    vga.putChar('\n');
}

// ============================================================
// Helpers
// ============================================================

fn hexDigitVal(c: u8) ?u16 {
    if (c >= '0' and c <= '9') return @as(u16, c - '0');
    if (c >= 'a' and c <= 'f') return @as(u16, c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @as(u16, c - 'A' + 10);
    return null;
}
