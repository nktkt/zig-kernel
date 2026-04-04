// ネットワークスタック — Ethernet / ARP / IPv4 / ICMP / UDP

const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

// 静的ネットワーク設定 (QEMU user-mode networking)
pub const OUR_IP = ipAddr(10, 0, 2, 16);
pub const GATEWAY_IP = ipAddr(10, 0, 2, 2);
pub const NETMASK = ipAddr(255, 255, 255, 0);

const BROADCAST_MAC = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// EtherType
const ETH_ARP: u16 = 0x0806;
const ETH_IP: u16 = 0x0800;

// IP プロトコル
const PROTO_ICMP: u8 = 1;
const PROTO_UDP: u8 = 17;

// ARP キャッシュ
const ARP_CACHE_SIZE = 8;
const ArpEntry = struct { ip: u32, mac: [6]u8, valid: bool };
var arp_cache: [ARP_CACHE_SIZE]ArpEntry = undefined;

// Ping 状態
var ping_replied: bool = false;
var ping_rtt_ms: u64 = 0;
var ping_seq: u16 = 0;

var pkt_buf: [1500]u8 = undefined;

pub fn init() void {
    for (&arp_cache) |*e| {
        e.valid = false;
    }
    ping_seq = 0;
}

// ---- パケット受信処理 ----

fn pollOnce() void {
    var rx_buf: [1500]u8 = undefined;
    if (e1000.receive(&rx_buf)) |len| {
        if (len >= 14) {
            handlePacket(rx_buf[0..len]);
        }
    }
}

fn handlePacket(data: []const u8) void {
    const ethertype = getU16BE(data[12..14]);
    const payload = data[14..];

    switch (ethertype) {
        ETH_ARP => handleArp(data[0..6], payload),
        ETH_IP => handleIp(payload),
        else => {},
    }
}

fn handleArp(src_mac: []const u8, data: []const u8) void {
    if (data.len < 28) return;
    const op = getU16BE(data[6..8]);
    const sender_ip = getU32BE(data[14..18]);
    const target_ip = getU32BE(data[24..28]);

    // 送信者を ARP キャッシュに登録
    arpCacheAdd(sender_ip, data[8..14]);

    if (op == 1 and target_ip == OUR_IP) {
        // ARP リクエストに応答
        sendArpReply(sender_ip, src_mac);
    }
}

fn handleIp(data: []const u8) void {
    if (data.len < 20) return;
    const ihl = (data[0] & 0x0F) * 4;
    if (data.len < ihl) return;
    const proto = data[9];
    const payload = data[ihl..];

    switch (proto) {
        PROTO_ICMP => handleIcmp(payload),
        else => {},
    }
}

fn handleIcmp(data: []const u8) void {
    if (data.len < 8) return;
    const icmp_type = data[0];
    if (icmp_type == 0) { // Echo Reply
        ping_replied = true;
    }
}

// ---- ARP ----

fn arpCacheAdd(ip: u32, mac_addr: []const u8) void {
    // 既存エントリ更新
    for (&arp_cache) |*e| {
        if (e.valid and e.ip == ip) {
            @memcpy(&e.mac, mac_addr[0..6]);
            return;
        }
    }
    // 空きスロットに追加
    for (&arp_cache) |*e| {
        if (!e.valid) {
            e.ip = ip;
            @memcpy(&e.mac, mac_addr[0..6]);
            e.valid = true;
            return;
        }
    }
}

fn arpLookup(ip: u32) ?[6]u8 {
    for (&arp_cache) |*e| {
        if (e.valid and e.ip == ip) return e.mac;
    }
    return null;
}

fn sendArpRequest(target_ip: u32) void {
    var pkt: [42]u8 = undefined;
    // Ethernet ヘッダ
    @memcpy(pkt[0..6], &BROADCAST_MAC);
    @memcpy(pkt[6..12], &e1000.mac);
    putU16BE(pkt[12..14], ETH_ARP);
    // ARP
    putU16BE(pkt[14..16], 1); // HW type: Ethernet
    putU16BE(pkt[16..18], 0x0800); // Proto: IPv4
    pkt[18] = 6;
    pkt[19] = 4;
    putU16BE(pkt[20..22], 1); // Operation: request
    @memcpy(pkt[22..28], &e1000.mac);
    putU32BE(pkt[28..32], OUR_IP);
    @memset(pkt[32..38], 0);
    putU32BE(pkt[38..42], target_ip);

    e1000.send(&pkt);
}

fn sendArpReply(target_ip: u32, target_mac: []const u8) void {
    var pkt: [42]u8 = undefined;
    @memcpy(pkt[0..6], target_mac[0..6]);
    @memcpy(pkt[6..12], &e1000.mac);
    putU16BE(pkt[12..14], ETH_ARP);
    putU16BE(pkt[14..16], 1);
    putU16BE(pkt[16..18], 0x0800);
    pkt[18] = 6;
    pkt[19] = 4;
    putU16BE(pkt[20..22], 2); // reply
    @memcpy(pkt[22..28], &e1000.mac);
    putU32BE(pkt[28..32], OUR_IP);
    @memcpy(pkt[32..38], target_mac[0..6]);
    putU32BE(pkt[38..42], target_ip);

    e1000.send(&pkt);
}

fn resolveArp(ip: u32) ?[6]u8 {
    if (arpLookup(ip)) |m| return m;

    sendArpRequest(ip);

    // シェルは IRQ1 ハンドラ内で動くため IF=0。
    // タイマーティックを進めるために sti する。
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < 2000) {
        pollOnce();
        if (arpLookup(ip)) |m| return m;
    }
    return null;
}

// ---- ICMP Ping ----

pub fn ping(target_ip: u32) void {
    // 同一サブネット判定
    const next_hop = if ((target_ip ^ OUR_IP) & NETMASK != 0) GATEWAY_IP else target_ip;

    vga.setColor(.light_grey, .black);
    vga.write("PING ");
    printIp(target_ip);
    vga.write(" ...\n");

    const dst_mac = resolveArp(next_hop) orelse {
        vga.setColor(.light_red, .black);
        vga.write("ARP resolution failed for ");
        printIp(next_hop);
        vga.putChar('\n');
        return;
    };

    ping_seq += 1;
    ping_replied = false;

    // ICMP Echo Request 構築
    const icmp_len: usize = 8 + 32; // ヘッダ + 32バイトデータ
    const ip_len: usize = 20 + icmp_len;
    const total_len: usize = 14 + ip_len;

    var pkt: [128]u8 = undefined;

    // Ethernet
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    putU16BE(pkt[12..14], ETH_IP);

    // IPv4
    pkt[14] = 0x45; // version=4, IHL=5
    pkt[15] = 0;
    putU16BE(pkt[16..18], @truncate(ip_len));
    putU16BE(pkt[18..20], ping_seq);
    putU16BE(pkt[20..22], 0); // flags + frag
    pkt[22] = 64; // TTL
    pkt[23] = PROTO_ICMP;
    putU16BE(pkt[24..26], 0); // checksum placeholder
    putU32BE(pkt[26..30], OUR_IP);
    putU32BE(pkt[30..34], target_ip);
    // IP チェックサム
    const ip_cksum = calcChecksum(pkt[14..34]);
    putU16BE(pkt[24..26], ip_cksum);

    // ICMP Echo Request
    pkt[34] = 8; // type: echo request
    pkt[35] = 0; // code
    putU16BE(pkt[36..38], 0); // checksum placeholder
    putU16BE(pkt[38..40], 0x1234); // identifier
    putU16BE(pkt[40..42], ping_seq);
    // データ
    for (0..32) |i| {
        pkt[42 + i] = @truncate(i);
    }
    // ICMP チェックサム
    const icmp_cksum = calcChecksum(pkt[34 .. 34 + icmp_len]);
    putU16BE(pkt[36..38], icmp_cksum);

    e1000.send(pkt[0..total_len]);
    const start_tick = pit.getTicks();

    // 応答待ち (3秒) — sti でタイマー割り込みを有効化
    asm volatile ("sti");
    while (pit.getTicks() -| start_tick < 3000) {
        pollOnce();
        if (ping_replied) break;
    }

    if (ping_replied) {
        const elapsed = pit.getTicks() -| start_tick;
        vga.setColor(.light_green, .black);
        vga.write("Reply from ");
        printIp(target_ip);
        vga.write(": time=");
        pmm.printNum(@truncate(elapsed));
        vga.write("ms\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Request timed out.\n");
    }
}

// ---- ステータス表示 ----

pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("Network Status:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  MAC: ");
    for (e1000.mac, 0..) |b, i| {
        if (i > 0) vga.putChar(':');
        printHex8(b);
    }
    vga.putChar('\n');
    vga.write("  IP:  ");
    printIp(OUR_IP);
    vga.putChar('\n');
    vga.write("  GW:  ");
    printIp(GATEWAY_IP);
    vga.putChar('\n');
}

// ---- IP パーサー ----

pub fn parseIp(s: []const u8) ?u32 {
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

// ---- ユーティリティ ----

fn ipAddr(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}

fn printIp(ip: u32) void {
    pmm.printNum((ip >> 24) & 0xFF);
    vga.putChar('.');
    pmm.printNum((ip >> 16) & 0xFF);
    vga.putChar('.');
    pmm.printNum((ip >> 8) & 0xFF);
    vga.putChar('.');
    pmm.printNum(ip & 0xFF);
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn putU16BE(buf: *[2]u8, val: u16) void {
    buf[0] = @truncate(val >> 8);
    buf[1] = @truncate(val);
}

fn putU32BE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}

fn getU16BE(buf: []const u8) u16 {
    return @as(u16, buf[0]) << 8 | buf[1];
}

fn getU32BE(buf: []const u8) u32 {
    return @as(u32, buf[0]) << 24 | @as(u32, buf[1]) << 16 | @as(u32, buf[2]) << 8 | buf[3];
}

fn calcChecksum(data: []const u8) u16 {
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
