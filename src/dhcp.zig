// DHCP クライアント — DISCOVER / OFFER / REQUEST / ACK

const udp = @import("udp.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

const DHCP_SERVER_PORT: u16 = 67;
const DHCP_CLIENT_PORT: u16 = 68;
const BROADCAST_IP: u32 = 0xFFFFFFFF;

// DHCP メッセージタイプ
const DHCP_DISCOVER: u8 = 1;
const DHCP_OFFER: u8 = 2;
const DHCP_REQUEST: u8 = 3;
const DHCP_ACK: u8 = 5;

// DHCP マジッククッキー
const MAGIC_COOKIE = [4]u8{ 99, 130, 83, 99 };

pub const DhcpLease = struct {
    ip: u32,
    gateway: u32,
    netmask: u32,
    dns: u32,
    server_ip: u32,
};

var xid: u32 = 0x12345678;

pub fn discover() ?DhcpLease {
    if (!e1000.isInitialized()) return null;

    const sock = udp.create() orelse return null;
    defer udp.close(sock);
    _ = udp.bind(sock, DHCP_CLIENT_PORT);

    xid +%= 1;

    // DHCP DISCOVER 送信
    var disc_pkt: [300]u8 = @splat(0);
    buildDiscover(&disc_pkt);

    if (!udp.sendTo(sock, BROADCAST_IP, DHCP_SERVER_PORT, &disc_pkt)) {
        serial.write("[DHCP] DISCOVER send failed\n");
        return null;
    }
    serial.write("[DHCP] DISCOVER sent\n");

    // OFFER 受信
    var resp: [512]u8 = undefined;
    const resp_len = udp.recvFrom(sock, &resp);
    if (resp_len < 240) {
        serial.write("[DHCP] no OFFER received\n");
        return null;
    }

    var lease = DhcpLease{
        .ip = 0,
        .gateway = 0,
        .netmask = 0,
        .dns = 0,
        .server_ip = 0,
    };

    var msg_type: u8 = 0;
    parseOptions(resp[0..resp_len], &lease, &msg_type);

    if (msg_type != DHCP_OFFER) {
        serial.write("[DHCP] not an OFFER\n");
        return null;
    }

    // offered IP (yiaddr at offset 16)
    lease.ip = net.getU32BE(resp[16..20]);
    lease.server_ip = net.getU32BE(resp[20..24]);

    serial.write("[DHCP] OFFER received\n");

    // DHCP REQUEST 送信
    var req_pkt: [300]u8 = @splat(0);
    buildRequest(&req_pkt, lease.ip, lease.server_ip);

    if (!udp.sendTo(sock, BROADCAST_IP, DHCP_SERVER_PORT, &req_pkt)) {
        serial.write("[DHCP] REQUEST send failed\n");
        return null;
    }
    serial.write("[DHCP] REQUEST sent\n");

    // ACK 受信
    var ack_resp: [512]u8 = undefined;
    const ack_len = udp.recvFrom(sock, &ack_resp);
    if (ack_len < 240) {
        serial.write("[DHCP] no ACK received\n");
        return null;
    }

    var ack_type: u8 = 0;
    parseOptions(ack_resp[0..ack_len], &lease, &ack_type);
    if (ack_type != DHCP_ACK) {
        serial.write("[DHCP] not an ACK\n");
        return null;
    }

    lease.ip = net.getU32BE(ack_resp[16..20]);
    serial.write("[DHCP] ACK received, lease acquired\n");

    return lease;
}

fn buildDiscover(pkt: *[300]u8) void {
    pkt[0] = 1; // op: BOOTREQUEST
    pkt[1] = 1; // htype: Ethernet
    pkt[2] = 6; // hlen: MAC size
    pkt[3] = 0; // hops
    net.putU32BE(pkt[4..8], xid); // xid
    // secs, flags
    net.putU16BE(pkt[8..10], 0);
    net.putU16BE(pkt[10..12], 0x8000); // broadcast flag
    // ciaddr, yiaddr, siaddr, giaddr = 0 (already zeroed)
    // chaddr (MAC)
    @memcpy(pkt[28..34], &e1000.mac);

    // マジッククッキー at offset 236
    @memcpy(pkt[236..240], &MAGIC_COOKIE);

    // オプション
    var off: usize = 240;
    // Option 53: DHCP Message Type = DISCOVER
    pkt[off] = 53;
    pkt[off + 1] = 1;
    pkt[off + 2] = DHCP_DISCOVER;
    off += 3;

    // Option 55: Parameter Request List
    pkt[off] = 55;
    pkt[off + 1] = 3;
    pkt[off + 2] = 1; // Subnet Mask
    pkt[off + 3] = 3; // Router
    pkt[off + 4] = 6; // DNS
    off += 5;

    // End
    pkt[off] = 255;
}

fn buildRequest(pkt: *[300]u8, requested_ip: u32, server_ip: u32) void {
    pkt[0] = 1; // BOOTREQUEST
    pkt[1] = 1;
    pkt[2] = 6;
    pkt[3] = 0;
    net.putU32BE(pkt[4..8], xid);
    net.putU16BE(pkt[10..12], 0x8000);
    @memcpy(pkt[28..34], &e1000.mac);
    @memcpy(pkt[236..240], &MAGIC_COOKIE);

    var off: usize = 240;
    // Option 53: DHCP_REQUEST
    pkt[off] = 53;
    pkt[off + 1] = 1;
    pkt[off + 2] = DHCP_REQUEST;
    off += 3;

    // Option 50: Requested IP
    pkt[off] = 50;
    pkt[off + 1] = 4;
    net.putU32BE(pkt[off + 2 ..][0..4], requested_ip);
    off += 6;

    // Option 54: Server Identifier
    pkt[off] = 54;
    pkt[off + 1] = 4;
    net.putU32BE(pkt[off + 2 ..][0..4], server_ip);
    off += 6;

    // End
    pkt[off] = 255;
}

fn parseOptions(data: []const u8, lease: *DhcpLease, msg_type: *u8) void {
    if (data.len < 240) return;
    // マジッククッキー確認
    if (data[236] != 99 or data[237] != 130 or data[238] != 83 or data[239] != 99) return;

    var off: usize = 240;
    while (off + 2 <= data.len) {
        const opt = data[off];
        if (opt == 255) break; // End
        if (opt == 0) {
            off += 1;
            continue;
        } // Pad
        const olen = data[off + 1];
        off += 2;
        if (off + olen > data.len) break;

        switch (opt) {
            53 => { // DHCP Message Type
                if (olen >= 1) msg_type.* = data[off];
            },
            1 => { // Subnet Mask
                if (olen >= 4) lease.netmask = net.getU32BE(data[off..][0..4]);
            },
            3 => { // Router
                if (olen >= 4) lease.gateway = net.getU32BE(data[off..][0..4]);
            },
            6 => { // DNS Server
                if (olen >= 4) lease.dns = net.getU32BE(data[off..][0..4]);
            },
            54 => { // Server Identifier
                if (olen >= 4) lease.server_ip = net.getU32BE(data[off..][0..4]);
            },
            else => {},
        }
        off += olen;
    }
}
