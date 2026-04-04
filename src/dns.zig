// DNS リゾルバ — A レコード問い合わせ

const udp = @import("udp.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// DNS サーバ (QEMU default)
var dns_server: u32 = 0;
const DNS_PORT: u16 = 53;

// DNS ヘッダフラグ
const QR_QUERY: u16 = 0x0000;
const OPCODE_STD: u16 = 0x0000;
const RD_FLAG: u16 = 0x0100; // Recursion Desired
const QTYPE_A: u16 = 1; // A record
const QCLASS_IN: u16 = 1; // Internet

var query_id: u16 = 0x1234;

pub fn init() void {
    // QEMU user-mode networking の DNS サーバ
    dns_server = ipAddr(10, 0, 2, 3);
}

pub fn setServer(ip: u32) void {
    dns_server = ip;
}

/// ホスト名を解決して IP アドレスを返す (ホストバイトオーダー)
pub fn resolve(hostname: []const u8) ?u32 {
    if (!e1000.isInitialized()) return null;
    if (hostname.len == 0 or hostname.len > 200) return null;

    // UDP ソケット作成
    const sock = udp.create() orelse return null;
    defer udp.close(sock);
    _ = udp.bind(sock, 10053);

    // DNS クエリ構築
    var pkt: [512]u8 = undefined;
    query_id +%= 1;
    const qid = query_id;

    // ヘッダ (12 バイト)
    net.putU16BE(pkt[0..2], qid); // ID
    net.putU16BE(pkt[2..4], RD_FLAG); // Flags: RD=1
    net.putU16BE(pkt[4..6], 1); // QDCOUNT = 1
    net.putU16BE(pkt[6..8], 0); // ANCOUNT
    net.putU16BE(pkt[8..10], 0); // NSCOUNT
    net.putU16BE(pkt[10..12], 0); // ARCOUNT

    // Question セクション: ドメイン名エンコード
    var off: usize = 12;
    off = encodeName(pkt[off..], hostname) + off;

    net.putU16BE(pkt[off..][0..2], QTYPE_A);
    off += 2;
    net.putU16BE(pkt[off..][0..2], QCLASS_IN);
    off += 2;

    // 送信
    if (!udp.sendTo(sock, dns_server, DNS_PORT, pkt[0..off])) {
        serial.write("[DNS] send failed\n");
        return null;
    }

    // 応答受信
    var resp: [512]u8 = undefined;
    const resp_len = udp.recvFrom(sock, &resp);
    if (resp_len < 12) {
        serial.write("[DNS] no response\n");
        return null;
    }

    return parseResponse(resp[0..resp_len], qid);
}

/// ドメイン名を DNS ワイヤ形式にエンコード
fn encodeName(buf: []u8, name: []const u8) usize {
    var pos: usize = 0;
    var label_start: usize = 0;

    for (name, 0..) |c, i| {
        if (c == '.') {
            const label_len = i - label_start;
            if (label_len == 0 or label_len > 63) return 0;
            buf[pos] = @truncate(label_len);
            pos += 1;
            @memcpy(buf[pos .. pos + label_len], name[label_start..i]);
            pos += label_len;
            label_start = i + 1;
        }
    }
    // 最後のラベル
    const label_len = name.len - label_start;
    if (label_len > 0) {
        buf[pos] = @truncate(label_len);
        pos += 1;
        @memcpy(buf[pos .. pos + label_len], name[label_start..name.len]);
        pos += label_len;
    }
    buf[pos] = 0; // 終端
    pos += 1;
    return pos;
}

/// DNS 応答をパースして A レコードの IP を返す
fn parseResponse(data: []const u8, expected_id: u16) ?u32 {
    if (data.len < 12) return null;

    const resp_id = net.getU16BE(data[0..2]);
    if (resp_id != expected_id) return null;

    const flags = net.getU16BE(data[2..4]);
    if (flags & 0x8000 == 0) return null; // QR bit なし
    if (flags & 0x000F != 0) return null; // RCODE != 0

    const ancount = net.getU16BE(data[6..8]);
    if (ancount == 0) return null;

    // Question セクションをスキップ
    var off: usize = 12;
    off = skipName(data, off);
    off += 4; // QTYPE + QCLASS

    // Answer セクションをパース
    var i: u16 = 0;
    while (i < ancount and off + 12 <= data.len) : (i += 1) {
        off = skipName(data, off);
        if (off + 10 > data.len) return null;

        const rtype = net.getU16BE(data[off..][0..2]);
        off += 2;
        off += 2; // CLASS
        off += 4; // TTL
        const rdlength = net.getU16BE(data[off..][0..2]);
        off += 2;

        if (rtype == QTYPE_A and rdlength == 4 and off + 4 <= data.len) {
            return net.getU32BE(data[off..][0..4]);
        }

        off += rdlength;
    }
    return null;
}

/// DNS 名前フィールドをスキップ (圧縮ポインタ対応)
fn skipName(data: []const u8, start: usize) usize {
    var off = start;
    while (off < data.len) {
        const len = data[off];
        if (len == 0) {
            return off + 1;
        }
        if (len & 0xC0 == 0xC0) {
            // 圧縮ポインタ (2 バイト)
            return off + 2;
        }
        off += 1 + len;
    }
    return off;
}

fn ipAddr(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}
