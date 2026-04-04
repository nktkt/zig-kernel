// UDP 実装 — コネクションレスデータグラム送受信

const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

pub const UdpSocket = struct {
    local_port: u16,
    remote_ip: u32,
    remote_port: u16,
    recv_buf: [512]u8,
    recv_len: usize,
    bound: bool,
    used: bool,
};

const MAX_SOCKETS = 8;
var sockets: [MAX_SOCKETS]UdpSocket = undefined;

pub fn init() void {
    for (&sockets) |*s| {
        s.used = false;
        s.bound = false;
        s.recv_len = 0;
    }
}

pub fn create() ?u16 {
    for (&sockets, 0..) |*s, i| {
        if (!s.used) {
            s.* = .{
                .local_port = 0,
                .remote_ip = 0,
                .remote_port = 0,
                .recv_buf = undefined,
                .recv_len = 0,
                .bound = false,
                .used = true,
            };
            return @truncate(i);
        }
    }
    return null;
}

pub fn bind(idx: u16, port: u16) bool {
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    sockets[idx].local_port = port;
    sockets[idx].bound = true;
    return true;
}

pub fn sendTo(idx: u16, dst_ip: u32, dst_port: u16, data: []const u8) bool {
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return false;
    const s = &sockets[idx];
    if (!s.bound) {
        s.local_port = 10000 + @as(u16, @truncate(pit.getTicks() & 0xFFFF));
        s.bound = true;
    }

    return sendUdpPacket(s.local_port, dst_ip, dst_port, data);
}

pub fn recvFrom(idx: u16, buf: []u8) usize {
    if (idx >= MAX_SOCKETS or !sockets[idx].used) return 0;
    const s = &sockets[idx];

    // ポーリング
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < 2000) {
        var rx_buf: [1500]u8 = undefined;
        if (e1000.receive(&rx_buf)) |len| {
            if (len >= 14) net.handleIncoming(rx_buf[0..len]);
        }
        if (s.recv_len > 0) break;
    }

    const len = @min(buf.len, s.recv_len);
    @memcpy(buf[0..len], s.recv_buf[0..len]);
    s.recv_len = 0;
    return len;
}

pub fn close(idx: u16) void {
    if (idx < MAX_SOCKETS) {
        sockets[idx].used = false;
    }
}

// ---- 受信処理 ----

pub fn handleUdpPacket(src_ip: u32, data: []const u8) void {
    if (data.len < 8) return;
    const src_port = net.getU16BE(data[0..2]);
    const dst_port = net.getU16BE(data[2..4]);
    const udp_len = net.getU16BE(data[4..6]);
    _ = src_port;

    if (udp_len < 8 or udp_len > data.len) return;
    const payload = data[8..udp_len];

    // 宛先ポートに一致するソケットを探す
    for (&sockets) |*s| {
        if (s.used and s.bound and s.local_port == dst_port) {
            const space = s.recv_buf.len - s.recv_len;
            const copy_len = @min(payload.len, space);
            @memcpy(s.recv_buf[s.recv_len .. s.recv_len + copy_len], payload[0..copy_len]);
            s.recv_len += copy_len;
            s.remote_ip = src_ip;
            return;
        }
    }
}

fn sendUdpPacket(src_port: u16, dst_ip: u32, dst_port: u16, data: []const u8) bool {
    if (!e1000.isInitialized()) return false;

    var pkt: [1500]u8 = undefined;
    const next_hop = if ((dst_ip ^ net.OUR_IP) & net.NETMASK != 0) net.GATEWAY_IP else dst_ip;
    const dst_mac = net.arpLookupPub(next_hop) orelse return false;

    // Ethernet
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    net.putU16BE(pkt[12..14], 0x0800);

    const udp_len: u16 = @truncate(8 + data.len);
    const ip_len: u16 = 20 + udp_len;
    const total: usize = 14 + ip_len;

    // IPv4
    pkt[14] = 0x45;
    pkt[15] = 0;
    net.putU16BE(pkt[16..18], ip_len);
    net.putU16BE(pkt[18..20], 0);
    net.putU16BE(pkt[20..22], 0x4000);
    pkt[22] = 64;
    pkt[23] = 17; // UDP
    net.putU16BE(pkt[24..26], 0);
    net.putU32BE(pkt[26..30], net.OUR_IP);
    net.putU32BE(pkt[30..34], dst_ip);
    const ip_cksum = net.calcChecksumPub(pkt[14..34]);
    net.putU16BE(pkt[24..26], ip_cksum);

    // UDP
    net.putU16BE(pkt[34..36], src_port);
    net.putU16BE(pkt[36..38], dst_port);
    net.putU16BE(pkt[38..40], udp_len);
    net.putU16BE(pkt[40..42], 0); // checksum (optional for UDP)
    if (data.len > 0) {
        @memcpy(pkt[42 .. 42 + data.len], data);
    }

    e1000.send(pkt[0..total]);
    return true;
}
