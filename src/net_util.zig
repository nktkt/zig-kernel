// Network utility functions — byte order, checksums, IP/MAC formatting, subnet math
//
// Provides reusable primitives that other networking modules depend on:
// byte-swap helpers, internet checksum, IP and MAC address parsing/formatting,
// subnet calculations, and well-known port/protocol name lookups.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ============================================================
// Byte order conversion (network = big-endian, host = little-endian on x86)
// ============================================================

/// Convert a 16-bit value from host to network byte order.
pub fn htons(val: u16) u16 {
    return @byteSwap(val);
}

/// Convert a 32-bit value from host to network byte order.
pub fn htonl(val: u32) u32 {
    return @byteSwap(val);
}

/// Convert a 16-bit value from network to host byte order.
pub fn ntohs(val: u16) u16 {
    return @byteSwap(val);
}

/// Convert a 32-bit value from network to host byte order.
pub fn ntohl(val: u32) u32 {
    return @byteSwap(val);
}

// ============================================================
// Internet checksum (RFC 1071)
// ============================================================

/// Compute the one's complement checksum over `data`.
/// Used for IP, ICMP, TCP, and UDP header checksums.
pub fn internetChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u32, data[i]) << 8 | data[i + 1];
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

/// Incremental checksum update: given old checksum, old 16-bit word, new 16-bit word,
/// return updated checksum without re-scanning the entire buffer.
pub fn checksumAdjust(old_cksum: u16, old_val: u16, new_val: u16) u16 {
    var sum: u32 = @as(u32, ~old_cksum) & 0xFFFF;
    sum +%= @as(u32, ~old_val) & 0xFFFF;
    sum +%= @as(u32, new_val);
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

// ============================================================
// IP address utilities
// ============================================================

/// Construct a 32-bit IPv4 address from four octets (host byte order, big-endian layout).
pub fn ipAddr(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}

/// Format an IPv4 address into a human-readable string like "10.0.2.16".
/// Returns a slice into `buf` with the formatted address.
pub fn ipToStr(ip: u32, buf: *[16]u8) []u8 {
    var pos: usize = 0;
    pos = appendDecU8(buf, pos, @truncate((ip >> 24) & 0xFF));
    buf[pos] = '.';
    pos += 1;
    pos = appendDecU8(buf, pos, @truncate((ip >> 16) & 0xFF));
    buf[pos] = '.';
    pos += 1;
    pos = appendDecU8(buf, pos, @truncate((ip >> 8) & 0xFF));
    buf[pos] = '.';
    pos += 1;
    pos = appendDecU8(buf, pos, @truncate(ip & 0xFF));
    return buf[0..pos];
}

/// Parse a dotted-decimal IPv4 string like "10.0.2.16" into a 32-bit address.
pub fn strToIp(s: []const u8) ?u32 {
    var parts: [4]u32 = undefined;
    var idx: usize = 0;
    var num: u32 = 0;
    var has_digit = false;

    for (s) |c| {
        if (c == '.') {
            if (!has_digit or idx >= 3) return null;
            if (num > 255) return null;
            parts[idx] = num;
            idx += 1;
            num = 0;
            has_digit = false;
        } else if (c >= '0' and c <= '9') {
            num = num * 10 + (c - '0');
            has_digit = true;
        } else {
            return null;
        }
    }
    if (!has_digit or idx != 3 or num > 255) return null;
    parts[3] = num;

    return ipAddr(@truncate(parts[0]), @truncate(parts[1]), @truncate(parts[2]), @truncate(parts[3]));
}

/// Print an IP address to VGA.
pub fn printIp(ip: u32) void {
    var buf: [16]u8 = undefined;
    const s = ipToStr(ip, &buf);
    vga.write(s);
}

/// Print an IP address to serial.
pub fn serialPrintIp(ip: u32) void {
    var buf: [16]u8 = undefined;
    const s = ipToStr(ip, &buf);
    serial.write(s);
}

// ============================================================
// Subnet calculations
// ============================================================

/// Return the network address for a given IP and netmask.
pub fn networkAddr(ip: u32, mask: u32) u32 {
    return ip & mask;
}

/// Return the broadcast address for a given IP and netmask.
pub fn broadcastAddr(ip: u32, mask: u32) u32 {
    return (ip & mask) | (~mask);
}

/// Return the number of usable host addresses for a given netmask.
pub fn hostCount(mask: u32) u32 {
    const total = ~mask;
    if (total < 2) return 0; // point-to-point or /32
    return total - 1; // exclude network and broadcast
}

/// Check whether `ip` belongs to the subnet defined by `network` and `mask`.
pub fn isInSubnet(ip: u32, network: u32, mask: u32) bool {
    return (ip & mask) == (network & mask);
}

/// Convert a CIDR prefix length (e.g. 24) to a netmask (e.g. 0xFFFFFF00).
pub fn cidrToMask(cidr: u8) u32 {
    if (cidr == 0) return 0;
    if (cidr >= 32) return 0xFFFFFFFF;
    return ~((@as(u32, 1) << @truncate(32 - cidr)) - 1);
}

/// Convert a netmask to a CIDR prefix length.
pub fn maskToCidr(mask: u32) u8 {
    var count: u8 = 0;
    var m = mask;
    while (m & 0x80000000 != 0) {
        count += 1;
        m <<= 1;
    }
    return count;
}

// ============================================================
// Port utilities
// ============================================================

/// Return true if the port is a privileged/well-known port (< 1024).
pub fn isPrivilegedPort(port: u16) bool {
    return port < 1024;
}

/// Return a human-readable name for a well-known port, or "unknown".
pub fn portName(port: u16) []const u8 {
    return switch (port) {
        7 => "echo",
        20 => "ftp-data",
        21 => "ftp",
        22 => "ssh",
        23 => "telnet",
        25 => "smtp",
        53 => "dns",
        67 => "dhcp-server",
        68 => "dhcp-client",
        69 => "tftp",
        80 => "http",
        110 => "pop3",
        123 => "ntp",
        143 => "imap",
        443 => "https",
        993 => "imaps",
        995 => "pop3s",
        8080 => "http-alt",
        else => "unknown",
    };
}

// ============================================================
// Protocol name lookup
// ============================================================

/// Return a human-readable name for an IP protocol number.
pub fn protoName(num: u8) []const u8 {
    return switch (num) {
        1 => "ICMP",
        2 => "IGMP",
        6 => "TCP",
        17 => "UDP",
        41 => "IPv6",
        47 => "GRE",
        50 => "ESP",
        51 => "AH",
        58 => "ICMPv6",
        89 => "OSPF",
        132 => "SCTP",
        else => "unknown",
    };
}

// ============================================================
// MAC address utilities
// ============================================================

/// Format a 6-byte MAC address into "XX:XX:XX:XX:XX:XX".
pub fn formatMac(mac: [6]u8, buf: *[18]u8) []u8 {
    const hex = "0123456789ABCDEF";
    var pos: usize = 0;
    for (mac, 0..) |b, i| {
        if (i > 0) {
            buf[pos] = ':';
            pos += 1;
        }
        buf[pos] = hex[b >> 4];
        pos += 1;
        buf[pos] = hex[b & 0xF];
        pos += 1;
    }
    return buf[0..pos];
}

/// Parse a MAC address string "XX:XX:XX:XX:XX:XX" into 6 bytes.
pub fn parseMac(s: []const u8) ?[6]u8 {
    if (s.len != 17) return null;
    var mac: [6]u8 = undefined;
    var idx: usize = 0;
    var i: usize = 0;
    while (idx < 6) : (idx += 1) {
        if (idx > 0) {
            if (i >= s.len or s[i] != ':') return null;
            i += 1;
        }
        if (i + 1 >= s.len) return null;
        const hi = hexVal(s[i]) orelse return null;
        const lo = hexVal(s[i + 1]) orelse return null;
        mac[idx] = hi << 4 | lo;
        i += 2;
    }
    return mac;
}

/// Check if a MAC address is the broadcast address (FF:FF:FF:FF:FF:FF).
pub fn isBroadcast(mac: [6]u8) bool {
    for (mac) |b| {
        if (b != 0xFF) return false;
    }
    return true;
}

/// Check if a MAC address is multicast (bit 0 of first octet is 1, not broadcast).
pub fn isMulticast(mac: [6]u8) bool {
    if (isBroadcast(mac)) return false;
    return (mac[0] & 0x01) != 0;
}

/// Check if a MAC address is unicast.
pub fn isUnicast(mac: [6]u8) bool {
    return (mac[0] & 0x01) == 0;
}

/// Generate a locally-administered random MAC address using PIT ticks as entropy.
pub fn randomMac() [6]u8 {
    var mac: [6]u8 = undefined;
    var seed: u32 = @truncate(pit.getTicks() *% 1103515245 +% 12345);
    for (&mac) |*b| {
        seed = seed *% 1103515245 +% 12345;
        b.* = @truncate((seed >> 16) & 0xFF);
    }
    // Set locally administered bit, clear multicast bit
    mac[0] = (mac[0] & 0xFE) | 0x02;
    return mac;
}

/// Print a MAC address to VGA.
pub fn printMac(mac: [6]u8) void {
    var buf: [18]u8 = undefined;
    const s = formatMac(mac, &buf);
    vga.write(s);
}

// ============================================================
// Big-endian buffer helpers (convenience wrappers)
// ============================================================

pub fn putU16BE(buf: *[2]u8, val: u16) void {
    buf[0] = @truncate(val >> 8);
    buf[1] = @truncate(val);
}

pub fn putU32BE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}

pub fn getU16BE(buf: []const u8) u16 {
    return @as(u16, buf[0]) << 8 | buf[1];
}

pub fn getU32BE(buf: []const u8) u32 {
    return @as(u32, buf[0]) << 24 | @as(u32, buf[1]) << 16 | @as(u32, buf[2]) << 8 | buf[3];
}

// ============================================================
// Display utilities
// ============================================================

/// Print a decimal number to VGA.
pub fn printDec(n: usize) void {
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

pub fn printDec64(n: u64) void {
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

/// Print a hex byte (2 digits) to VGA.
pub fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

/// Print a 32-bit hex value to VGA.
pub fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    vga.write("0x");
    var i: u5 = 28;
    while (true) {
        vga.putChar(hex[@truncate((val >> i) & 0xF)]);
        if (i == 0) break;
        i -= 4;
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @truncate(c - '0');
    if (c >= 'A' and c <= 'F') return @truncate(c - 'A' + 10);
    if (c >= 'a' and c <= 'f') return @truncate(c - 'a' + 10);
    return null;
}

fn appendDecU8(buf: *[16]u8, start: usize, val: u8) usize {
    if (val == 0) {
        buf[start] = '0';
        return start + 1;
    }
    var tmp: [3]u8 = undefined;
    var len: usize = 0;
    var v: u8 = val;
    while (v > 0) {
        tmp[len] = '0' + v % 10;
        len += 1;
        v /= 10;
    }
    var pos = start;
    while (len > 0) {
        len -= 1;
        buf[pos] = tmp[len];
        pos += 1;
    }
    return pos;
}
