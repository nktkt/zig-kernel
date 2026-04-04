// TCP 実装 — 簡易的な TCP ステートマシン (接続・送受信・切断)

const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

pub const TcpState = enum(u8) {
    closed,
    syn_sent,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
};

pub const TcpConn = struct {
    state: TcpState,
    local_port: u16,
    remote_port: u16,
    remote_ip: u32,
    seq_num: u32,
    ack_num: u32,
    recv_buf: [1024]u8,
    recv_len: usize,
    used: bool,
};

const MAX_CONNS = 4;
var conns: [MAX_CONNS]TcpConn = undefined;

pub fn init() void {
    for (&conns) |*c| {
        c.used = false;
        c.state = .closed;
        c.recv_len = 0;
    }
}

pub fn connect(remote_ip: u32, remote_port: u16, local_port: u16) ?*TcpConn {
    // 空きコネクションを探す
    var conn: ?*TcpConn = null;
    for (&conns) |*c| {
        if (!c.used) {
            conn = c;
            break;
        }
    }
    const c = conn orelse return null;

    c.* = .{
        .state = .syn_sent,
        .local_port = local_port,
        .remote_port = remote_port,
        .remote_ip = remote_ip,
        .seq_num = getInitialSeq(),
        .ack_num = 0,
        .recv_buf = undefined,
        .recv_len = 0,
        .used = true,
    };

    // SYN 送信
    sendTcpPacket(c, 0x02, &.{}); // SYN flag
    c.seq_num += 1;

    // SYN-ACK 待ち (3秒)
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < 3000) {
        pollTcp();
        if (c.state == .established) return c;
    }

    c.used = false;
    c.state = .closed;
    return null;
}

pub fn send(c: *TcpConn, data: []const u8) bool {
    if (c.state != .established) return false;

    sendTcpPacket(c, 0x18, data); // PSH | ACK
    c.seq_num += @truncate(data.len);

    // ACK 待ち
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < 2000) {
        pollTcp();
    }
    return true;
}

pub fn recv(c: *TcpConn, buf: []u8) usize {
    if (c.state != .established and c.state != .close_wait) return 0;

    // ポーリング
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < 2000) {
        pollTcp();
        if (c.recv_len > 0) break;
    }

    const len = @min(buf.len, c.recv_len);
    @memcpy(buf[0..len], c.recv_buf[0..len]);
    // 残りデータをシフト
    if (len < c.recv_len) {
        var i: usize = 0;
        while (i < c.recv_len - len) : (i += 1) {
            c.recv_buf[i] = c.recv_buf[i + len];
        }
    }
    c.recv_len -= len;
    return len;
}

pub fn close(c: *TcpConn) void {
    if (c.state == .established) {
        sendTcpPacket(c, 0x11, &.{}); // FIN | ACK
        c.seq_num += 1;
        c.state = .fin_wait_1;

        const start = pit.getTicks();
        asm volatile ("sti");
        while (pit.getTicks() -| start < 2000) {
            pollTcp();
            if (c.state == .closed) break;
        }
    }
    c.used = false;
    c.state = .closed;
}

// ---- 受信処理 ----

pub fn handleTcpPacket(src_ip: u32, data: []const u8) void {
    if (data.len < 20) return;
    const src_port = net.getU16BE(data[0..2]);
    const dst_port = net.getU16BE(data[2..4]);
    const seq = net.getU32BE(data[4..8]);
    const ack = net.getU32BE(data[8..12]);
    const data_off = @as(usize, (data[12] >> 4)) * 4;
    const flags: u8 = data[13];

    // コネクション検索
    for (&conns) |*c| {
        if (!c.used) continue;
        if (c.remote_ip != src_ip or c.remote_port != src_port or c.local_port != dst_port) continue;

        switch (c.state) {
            .syn_sent => {
                if (flags & 0x12 == 0x12) { // SYN + ACK
                    c.ack_num = seq + 1;
                    c.seq_num = ack;
                    c.state = .established;
                    sendTcpPacket(c, 0x10, &.{}); // ACK
                    serial.write("[TCP] connected\n");
                }
            },
            .established => {
                if (flags & 0x01 != 0) { // FIN
                    c.ack_num = seq + 1;
                    sendTcpPacket(c, 0x10, &.{}); // ACK
                    c.state = .close_wait;
                    // 自動的に FIN を返す
                    sendTcpPacket(c, 0x11, &.{}); // FIN+ACK
                    c.seq_num += 1;
                    c.state = .last_ack;
                } else if (flags & 0x10 != 0) { // ACK (データ含む可能性)
                    if (data.len > data_off) {
                        const payload = data[data_off..];
                        const space = c.recv_buf.len - c.recv_len;
                        const copy_len = @min(payload.len, space);
                        @memcpy(c.recv_buf[c.recv_len .. c.recv_len + copy_len], payload[0..copy_len]);
                        c.recv_len += copy_len;
                        c.ack_num = seq + @as(u32, @truncate(payload.len));
                        sendTcpPacket(c, 0x10, &.{}); // ACK
                    }
                }
            },
            .fin_wait_1 => {
                if (flags & 0x10 != 0) { // ACK
                    c.state = .fin_wait_2;
                }
                if (flags & 0x01 != 0) { // FIN
                    c.ack_num = seq + 1;
                    sendTcpPacket(c, 0x10, &.{});
                    c.state = .closed;
                    c.used = false;
                }
            },
            .fin_wait_2 => {
                if (flags & 0x01 != 0) { // FIN
                    c.ack_num = seq + 1;
                    sendTcpPacket(c, 0x10, &.{});
                    c.state = .closed;
                    c.used = false;
                }
            },
            .last_ack => {
                if (flags & 0x10 != 0) { // ACK
                    c.state = .closed;
                    c.used = false;
                }
            },
            else => {},
        }
        return;
    }
}

fn pollTcp() void {
    var rx_buf: [1500]u8 = undefined;
    if (e1000.receive(&rx_buf)) |len| {
        if (len >= 14) {
            net.handleIncoming(rx_buf[0..len]);
        }
    }
}

fn sendTcpPacket(c: *TcpConn, flags: u8, payload: []const u8) void {
    var pkt: [1500]u8 = undefined;

    // ARP 解決
    const next_hop = if ((c.remote_ip ^ net.OUR_IP) & net.NETMASK != 0) net.GATEWAY_IP else c.remote_ip;
    const dst_mac = net.arpLookupPub(next_hop) orelse return;

    // Ethernet
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    net.putU16BE(pkt[12..14], 0x0800);

    // TCP ヘッダサイズ
    const tcp_header_len: usize = 20;
    const ip_len = 20 + tcp_header_len + payload.len;
    const total = 14 + ip_len;

    // IPv4
    pkt[14] = 0x45;
    pkt[15] = 0;
    net.putU16BE(pkt[16..18], @truncate(ip_len));
    net.putU16BE(pkt[18..20], 0);
    net.putU16BE(pkt[20..22], 0x4000); // DF
    pkt[22] = 64; // TTL
    pkt[23] = 6; // TCP
    net.putU16BE(pkt[24..26], 0);
    net.putU32BE(pkt[26..30], net.OUR_IP);
    net.putU32BE(pkt[30..34], c.remote_ip);
    const ip_cksum = net.calcChecksumPub(pkt[14..34]);
    net.putU16BE(pkt[24..26], ip_cksum);

    // TCP
    const tcp_start: usize = 34;
    net.putU16BE(pkt[tcp_start .. tcp_start + 2], c.local_port);
    net.putU16BE(pkt[tcp_start + 2 .. tcp_start + 4], c.remote_port);
    net.putU32BE(pkt[tcp_start + 4 .. tcp_start + 8], c.seq_num);
    net.putU32BE(pkt[tcp_start + 8 .. tcp_start + 12], c.ack_num);
    pkt[tcp_start + 12] = 0x50; // data offset = 5 (20 bytes)
    pkt[tcp_start + 13] = flags;
    net.putU16BE(pkt[tcp_start + 14 .. tcp_start + 16], 8192); // window
    net.putU16BE(pkt[tcp_start + 16 .. tcp_start + 18], 0); // checksum placeholder
    net.putU16BE(pkt[tcp_start + 18 .. tcp_start + 20], 0); // urgent ptr

    // ペイロード
    if (payload.len > 0) {
        @memcpy(pkt[tcp_start + 20 .. tcp_start + 20 + payload.len], payload);
    }

    // TCP チェックサム (疑似ヘッダ含む)
    const tcp_cksum = calcTcpChecksum(pkt[tcp_start .. tcp_start + tcp_header_len + payload.len], net.OUR_IP, c.remote_ip);
    net.putU16BE(pkt[tcp_start + 16 .. tcp_start + 18], tcp_cksum);

    e1000.send(pkt[0..total]);
}

fn calcTcpChecksum(tcp_data: []const u8, src_ip: u32, dst_ip: u32) u16 {
    var sum: u32 = 0;
    // 疑似ヘッダ
    sum += (src_ip >> 16) & 0xFFFF;
    sum += src_ip & 0xFFFF;
    sum += (dst_ip >> 16) & 0xFFFF;
    sum += dst_ip & 0xFFFF;
    sum += 6; // TCP protocol
    sum += @as(u32, @truncate(tcp_data.len));
    // TCP データ
    var i: usize = 0;
    while (i + 1 < tcp_data.len) : (i += 2) {
        sum += @as(u32, tcp_data[i]) << 8 | tcp_data[i + 1];
    }
    if (i < tcp_data.len) {
        sum += @as(u32, tcp_data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

fn getInitialSeq() u32 {
    return @truncate(pit.getTicks() *% 1103515245 +% 12345);
}
