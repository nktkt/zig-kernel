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
    // 再送制御
    rto_ms: u32, // Retransmission Timeout (ms)
    retries: u8, // 再送回数
    last_send_tick: u64, // 最後の送信時刻
    unacked_seq: u32, // 未ACKのシーケンス番号
    // 輻輳制御
    cwnd: u16, // Congestion Window (segments)
    ssthresh: u16, // Slow Start Threshold
    // TIME_WAIT
    time_wait_start: u64,
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
        .rto_ms = 1000, // 初期 RTO = 1秒
        .retries = 0,
        .last_send_tick = pit.getTicks(),
        .unacked_seq = 0,
        .cwnd = 1, // slow start: 1 segment
        .ssthresh = 8, // 初期閾値
        .time_wait_start = 0,
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

    const saved_seq = c.seq_num;
    c.unacked_seq = saved_seq;
    sendTcpPacket(c, 0x18, data); // PSH | ACK
    c.seq_num += @truncate(data.len);
    c.last_send_tick = pit.getTicks();

    // ACK 待ち + 再送ロジック
    c.retries = 0;
    asm volatile ("sti");
    while (c.retries < 5) {
        const start = pit.getTicks();
        while (pit.getTicks() -| start < c.rto_ms) {
            pollTcp();
            // ACK 確認 (相手がデータを確認した)
            if (c.unacked_seq != saved_seq) {
                // ACK 受信成功 → 輻輳ウィンドウ拡大
                if (c.cwnd < c.ssthresh) {
                    c.cwnd += 1; // slow start: 指数増加
                } else {
                    c.cwnd += 1; // congestion avoidance: 線形増加
                }
                // RTO をリセット (成功時は短く)
                if (c.rto_ms > 200) c.rto_ms -= 100;
                return true;
            }
        }
        // タイムアウト → 再送
        c.retries += 1;
        c.rto_ms = @min(c.rto_ms * 2, 8000); // exponential backoff
        c.ssthresh = @max(c.cwnd / 2, 1); // 輻輳検出 → 閾値半減
        c.cwnd = 1; // slow start に戻る
        c.seq_num = saved_seq; // シーケンス巻き戻し
        sendTcpPacket(c, 0x18, data); // 再送
        c.seq_num += @truncate(data.len);
        c.last_send_tick = pit.getTicks();
        serial.write("[TCP] retransmit #");
        serial.writeHex(c.retries);
        serial.write("\n");
    }
    return false; // 再送限界
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
                // ACK 処理 → unacked_seq を更新 (再送タイマーリセット用)
                if (flags & 0x10 != 0 and ack > c.unacked_seq) {
                    c.unacked_seq = ack;
                }
                if (flags & 0x01 != 0) { // FIN
                    c.ack_num = seq + 1;
                    sendTcpPacket(c, 0x10, &.{});
                    c.state = .close_wait;
                    sendTcpPacket(c, 0x11, &.{});
                    c.seq_num += 1;
                    c.state = .last_ack;
                } else if (data.len > data_off) { // データあり
                    const payload = data[data_off..];
                    const space = c.recv_buf.len - c.recv_len;
                    const copy_len = @min(payload.len, space);
                    @memcpy(c.recv_buf[c.recv_len .. c.recv_len + copy_len], payload[0..copy_len]);
                    c.recv_len += copy_len;
                    c.ack_num = seq + @as(u32, @truncate(payload.len));
                    sendTcpPacket(c, 0x10, &.{});
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
                    c.state = .time_wait;
                    c.time_wait_start = pit.getTicks();
                }
            },
            .time_wait => {
                // TIME_WAIT 中の遅延 FIN に対して ACK を再送
                if (flags & 0x01 != 0) {
                    sendTcpPacket(c, 0x10, &.{});
                }
                // 2MSL (4秒) 経過で CLOSED
                if (pit.getTicks() -| c.time_wait_start > 4000) {
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
