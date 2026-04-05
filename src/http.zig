// HTTP/1.0 クライアント — GET リクエスト送受信
//
// TCP コネクション上で HTTP/1.0 GET リクエストを構築・送信し、
// レスポンスのステータスライン・ヘッダ・ボディを解析する。

const tcp = @import("tcp.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");

// ---- 定数 ----

const MAX_BODY_LEN = 1024;
const MAX_HEADERS = 5;
const MAX_HEADER_NAME = 32;
const MAX_HEADER_VALUE = 64;
const MAX_STATUS_MSG = 32;
const MAX_REQUEST_LEN = 512;
const RECV_BUF_SIZE = 2048;

// ---- HTTP ヘッダ ----

pub const HttpHeader = struct {
    name: [MAX_HEADER_NAME]u8,
    name_len: usize,
    value: [MAX_HEADER_VALUE]u8,
    value_len: usize,
    used: bool,

    pub fn getName(self: *const HttpHeader) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getValue(self: *const HttpHeader) []const u8 {
        return self.value[0..self.value_len];
    }
};

// ---- HTTP レスポンス ----

pub const HttpResponse = struct {
    status_code: u16,
    status_msg: [MAX_STATUS_MSG]u8,
    status_msg_len: usize,
    headers: [MAX_HEADERS]HttpHeader,
    header_count: usize,
    body: [MAX_BODY_LEN]u8,
    body_len: usize,
    content_length: usize, // Content-Length ヘッダの値
    valid: bool,

    pub fn getStatusMsg(self: *const HttpResponse) []const u8 {
        return self.status_msg[0..self.status_msg_len];
    }

    pub fn getBody(self: *const HttpResponse) []const u8 {
        return self.body[0..self.body_len];
    }

    /// 指定名のヘッダ値を取得
    pub fn getHeader(self: *const HttpResponse, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |*h| {
            if (!h.used) continue;
            if (h.name_len == name.len and strEqlIgnoreCase(h.name[0..h.name_len], name)) {
                return h.value[0..h.value_len];
            }
        }
        return null;
    }
};

// ---- 公開 API ----

/// HTTP GET リクエストを送信し、レスポンスを返す
pub fn get(host_ip: u32, port: u16, path: []const u8) ?HttpResponse {
    // リクエスト文字列を構築
    var req_buf: [MAX_REQUEST_LEN]u8 = undefined;
    const req_len = buildGetRequest(&req_buf, host_ip, path) orelse return null;

    serial.write("[HTTP] connecting to ");
    serialPrintIp(host_ip);
    serial.putChar(':');
    serialPrintDec(port);
    serial.putChar('\n');

    // TCP 接続
    const local_port = allocEphemeralPort();
    const conn = tcp.connect(host_ip, port, local_port) orelse {
        serial.write("[HTTP] TCP connect failed\n");
        return null;
    };

    // リクエスト送信
    if (!tcp.send(conn, req_buf[0..req_len])) {
        serial.write("[HTTP] send failed\n");
        tcp.close(conn);
        return null;
    }

    serial.write("[HTTP] request sent, awaiting response...\n");

    // レスポンス受信 (複数回 recv でデータを集める)
    var recv_buf: [RECV_BUF_SIZE]u8 = undefined;
    var recv_total: usize = 0;

    // 最大 5 回受信を試みる
    var attempts: usize = 0;
    while (attempts < 5 and recv_total < RECV_BUF_SIZE) : (attempts += 1) {
        const n = tcp.recv(conn, recv_buf[recv_total..]);
        if (n == 0) {
            if (recv_total > 0) break; // データ受信済みなら終了
            continue;
        }
        recv_total += n;

        // ヘッダ終端 (\r\n\r\n) が見つかったら body 長を確認
        if (findHeaderEnd(recv_buf[0..recv_total])) |header_end| {
            // Content-Length に基づいてボディ全体を受信したか確認
            const cl = parseContentLength(recv_buf[0..header_end]);
            const body_received = recv_total - header_end;
            if (cl > 0 and body_received >= cl) break;
        }
    }

    tcp.close(conn);

    if (recv_total == 0) {
        serial.write("[HTTP] no response received\n");
        return null;
    }

    // レスポンス解析
    return parseResponse(recv_buf[0..recv_total]);
}

/// レスポンスを VGA に表示
pub fn printResponse(resp: *const HttpResponse) void {
    vga.setColor(.yellow, .black);
    vga.write("HTTP Response:\n");

    // ステータスライン
    vga.setColor(.light_cyan, .black);
    vga.write("  Status: ");
    vga.setColor(.white, .black);
    printDec(resp.status_code);
    vga.putChar(' ');
    vga.write(resp.getStatusMsg());
    vga.putChar('\n');

    // ヘッダ
    vga.setColor(.light_cyan, .black);
    vga.write("  Headers:\n");
    vga.setColor(.light_grey, .black);
    for (resp.headers[0..resp.header_count]) |*h| {
        if (!h.used) continue;
        vga.write("    ");
        vga.write(h.getName());
        vga.write(": ");
        vga.write(h.getValue());
        vga.putChar('\n');
    }

    // ボディ
    vga.setColor(.light_cyan, .black);
    vga.write("  Body (");
    printDec(resp.body_len);
    vga.write(" bytes):\n");
    vga.setColor(.light_grey, .black);

    if (resp.body_len > 0) {
        // 最大 256 バイトまで表示
        const display_len = if (resp.body_len > 256) 256 else resp.body_len;
        vga.write(resp.body[0..display_len]);
        if (resp.body_len > 256) {
            vga.write("\n    ... (truncated)");
        }
        vga.putChar('\n');
    }

    vga.setColor(.light_grey, .black);
}

// ---- リクエスト構築 ----

fn buildGetRequest(buf: *[MAX_REQUEST_LEN]u8, host_ip: u32, path: []const u8) ?usize {
    var pos: usize = 0;

    // "GET "
    pos = appendStr(buf, pos, "GET ");
    if (pos == 0) return null;

    // パス
    if (path.len == 0) {
        pos = appendStr(buf, pos, "/");
    } else {
        pos = appendSlice(buf, pos, path);
    }

    // " HTTP/1.0\r\n"
    pos = appendStr(buf, pos, " HTTP/1.0\r\n");

    // "Host: <ip>\r\n"
    pos = appendStr(buf, pos, "Host: ");
    pos = appendIp(buf, pos, host_ip);
    pos = appendStr(buf, pos, "\r\n");

    // "Connection: close\r\n"
    pos = appendStr(buf, pos, "Connection: close\r\n");

    // "User-Agent: ZigOS/1.0\r\n"
    pos = appendStr(buf, pos, "User-Agent: ZigOS/1.0\r\n");

    // 空行 (ヘッダ終端)
    pos = appendStr(buf, pos, "\r\n");

    return pos;
}

// ---- レスポンス解析 ----

fn parseResponse(data: []const u8) ?HttpResponse {
    var resp = HttpResponse{
        .status_code = 0,
        .status_msg = undefined,
        .status_msg_len = 0,
        .headers = undefined,
        .header_count = 0,
        .body = undefined,
        .body_len = 0,
        .content_length = 0,
        .valid = false,
    };
    for (&resp.headers) |*h| h.used = false;

    if (data.len < 12) return null; // 最低 "HTTP/1.0 200"

    // ステータスライン解析: "HTTP/1.x STATUS MESSAGE\r\n"
    const first_line_end = findCRLF(data, 0) orelse return null;
    const status_line = data[0..first_line_end];

    // "HTTP/" プレフィクス確認
    if (status_line.len < 12) return null;
    if (!startsWith(status_line, "HTTP/")) return null;

    // ステータスコードを探す (最初のスペースの後)
    const sp1 = indexOf(status_line, ' ') orelse return null;
    if (sp1 + 4 > status_line.len) return null;

    resp.status_code = parseU16(status_line[sp1 + 1 .. sp1 + 4]) orelse return null;

    // ステータスメッセージ
    if (sp1 + 5 < status_line.len) {
        const msg = status_line[sp1 + 5 ..];
        const msg_len = if (msg.len > MAX_STATUS_MSG) MAX_STATUS_MSG else msg.len;
        copySlice(&resp.status_msg, msg[0..msg_len]);
        resp.status_msg_len = msg_len;
    }

    // ヘッダ解析
    var offset = first_line_end + 2; // \r\n をスキップ
    while (offset < data.len and resp.header_count < MAX_HEADERS) {
        // 空行 = ヘッダ終端
        if (offset + 1 < data.len and data[offset] == '\r' and data[offset + 1] == '\n') {
            offset += 2;
            break;
        }

        const line_end = findCRLF(data, offset) orelse break;
        const line = data[offset..line_end];

        // "Name: Value" を分割
        if (indexOfInSlice(line, ':')) |colon| {
            var h = &resp.headers[resp.header_count];
            h.used = true;

            // ヘッダ名
            const name = line[0..colon];
            const name_len = if (name.len > MAX_HEADER_NAME) MAX_HEADER_NAME else name.len;
            copySlice(&h.name, name[0..name_len]);
            h.name_len = name_len;

            // ヘッダ値 (先頭空白をスキップ)
            var val_start = colon + 1;
            while (val_start < line.len and line[val_start] == ' ') val_start += 1;
            const value = line[val_start..];
            const val_len = if (value.len > MAX_HEADER_VALUE) MAX_HEADER_VALUE else value.len;
            copySlice(&h.value, value[0..val_len]);
            h.value_len = val_len;

            // Content-Length を記録
            if (strEqlIgnoreCase(name[0..name_len], "Content-Length")) {
                resp.content_length = parseUsize(value) orelse 0;
            }

            resp.header_count += 1;
        }

        offset = line_end + 2;
    }

    // ボディ
    if (offset < data.len) {
        const body_data = data[offset..];
        const copy_len = if (body_data.len > MAX_BODY_LEN) MAX_BODY_LEN else body_data.len;
        copySlice(&resp.body, body_data[0..copy_len]);
        resp.body_len = copy_len;
    }

    resp.valid = true;
    return resp;
}

/// ヘッダ終端 (\r\n\r\n) の位置を返す (ボディ開始位置)
fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and
            data[i + 2] == '\r' and data[i + 3] == '\n')
        {
            return i + 4;
        }
    }
    return null;
}

/// ヘッダ部分から Content-Length を解析
fn parseContentLength(header_data: []const u8) usize {
    // "Content-Length: " を検索
    const needle = "Content-Length: ";
    var i: usize = 0;
    while (i + needle.len < header_data.len) : (i += 1) {
        if (matchIgnoreCase(header_data[i .. i + needle.len], needle)) {
            const start = i + needle.len;
            var end = start;
            while (end < header_data.len and header_data[end] >= '0' and header_data[end] <= '9') {
                end += 1;
            }
            return parseUsize(header_data[start..end]) orelse 0;
        }
    }
    return 0;
}

// ---- エフェメラルポート割当 ----

var next_port: u16 = 49152;

fn allocEphemeralPort() u16 {
    const port = next_port;
    next_port +%= 1;
    if (next_port < 49152) next_port = 49152;
    return port;
}

// ---- 文字列/バッファユーティリティ ----

fn appendStr(buf: *[MAX_REQUEST_LEN]u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > MAX_REQUEST_LEN) return pos;
    for (s, 0..) |c, i| {
        buf[pos + i] = c;
    }
    return pos + s.len;
}

fn appendSlice(buf: *[MAX_REQUEST_LEN]u8, pos: usize, s: []const u8) usize {
    return appendStr(buf, pos, s);
}

fn appendIp(buf: *[MAX_REQUEST_LEN]u8, pos: usize, ip: u32) usize {
    var p = pos;
    p = appendDecNum(buf, p, (ip >> 24) & 0xFF);
    if (p + 1 > MAX_REQUEST_LEN) return p;
    buf[p] = '.';
    p += 1;
    p = appendDecNum(buf, p, (ip >> 16) & 0xFF);
    if (p + 1 > MAX_REQUEST_LEN) return p;
    buf[p] = '.';
    p += 1;
    p = appendDecNum(buf, p, (ip >> 8) & 0xFF);
    if (p + 1 > MAX_REQUEST_LEN) return p;
    buf[p] = '.';
    p += 1;
    p = appendDecNum(buf, p, ip & 0xFF);
    return p;
}

fn appendDecNum(buf: *[MAX_REQUEST_LEN]u8, pos: usize, val: u32) usize {
    if (val == 0) {
        if (pos >= MAX_REQUEST_LEN) return pos;
        buf[pos] = '0';
        return pos + 1;
    }
    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        tmp[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    if (pos + len > MAX_REQUEST_LEN) return pos;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[pos + i] = tmp[len - 1 - i];
    }
    return pos + len;
}

fn findCRLF(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n') return i;
    }
    return null;
}

fn indexOf(data: []const u8, ch: u8) ?usize {
    for (data, 0..) |c, i| {
        if (c == ch) return i;
    }
    return null;
}

fn indexOfInSlice(data: []const u8, ch: u8) ?usize {
    return indexOf(data, ch);
}

fn copySlice(dst: []u8, src: []const u8) void {
    const len = if (src.len > dst.len) dst.len else src.len;
    for (0..len) |i| {
        dst[i] = src[i];
    }
}

fn startsWith(data: []const u8, prefix: []const u8) bool {
    if (data.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (data[i] != c) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn strEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn matchIgnoreCase(a: []const u8, b: []const u8) bool {
    return strEqlIgnoreCase(a, b);
}

fn parseU16(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var val: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn parseUsize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var val: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn serialPrintDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialPrintIp(ip: u32) void {
    serialPrintDec((ip >> 24) & 0xFF);
    serial.putChar('.');
    serialPrintDec((ip >> 16) & 0xFF);
    serial.putChar('.');
    serialPrintDec((ip >> 8) & 0xFF);
    serial.putChar('.');
    serialPrintDec(ip & 0xFF);
}
