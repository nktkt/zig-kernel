// NTP client (Network Time Protocol) — RFC 5905 simplified
//
// Sends NTP requests (v4, client mode) to synchronize system time.
// Supports a pool of 4 configurable server IPs, offset/delay calculation,
// and leap second indicator parsing.

const udp = @import("udp.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");

// ============================================================
// NTP constants
// ============================================================

const NTP_PORT: u16 = 123;
const NTP_PACKET_SIZE: usize = 48;
const NTP_VERSION: u8 = 4;
const NTP_MODE_CLIENT: u8 = 3;
const NTP_MODE_SERVER: u8 = 4;

// NTP epoch: 1900-01-01 00:00:00 UTC
// Unix epoch: 1970-01-01 00:00:00 UTC
// Difference: 70 years worth of seconds (including 17 leap years)
const NTP_UNIX_OFFSET: u32 = 2208988800;

// ============================================================
// Leap Indicator values
// ============================================================

pub const LEAP_NONE: u2 = 0; // No warning
pub const LEAP_LAST_61: u2 = 1; // Last minute has 61 seconds
pub const LEAP_LAST_59: u2 = 2; // Last minute has 59 seconds
pub const LEAP_ALARM: u2 = 3; // Clock not synchronized

// ============================================================
// NTP timestamp (64-bit: 32-bit seconds + 32-bit fraction)
// ============================================================

pub const NtpTimestamp = struct {
    seconds: u32,
    fraction: u32,
};

// ============================================================
// NTP packet structure (48 bytes)
// ============================================================

pub const NtpPacket = struct {
    li_vn_mode: u8, // LI(2) | VN(3) | Mode(3)
    stratum: u8,
    poll: u8,
    precision: i8,
    root_delay: u32,
    root_dispersion: u32,
    reference_id: u32,
    reference_ts: NtpTimestamp,
    origin_ts: NtpTimestamp,
    receive_ts: NtpTimestamp,
    transmit_ts: NtpTimestamp,
};

// ============================================================
// Sync state
// ============================================================

pub const SyncStatus = enum(u8) {
    unsynchronized,
    synchronized,
    stale, // last sync was too long ago
};

const SyncState = struct {
    status: SyncStatus,
    offset_sec: i32, // clock offset in seconds (signed)
    offset_frac: u32, // fractional part of offset
    delay_ms: u32, // round-trip delay in milliseconds
    stratum: u8,
    leap: u2,
    reference_id: u32,
    last_sync_tick: u64,
    last_server_ip: u32,
    sync_count: u32,
    error_count: u32,
    // Timestamps from last exchange
    origin_ts: NtpTimestamp,
    receive_ts: NtpTimestamp,
    transmit_ts: NtpTimestamp,
    dest_ts: NtpTimestamp,
};

var state: SyncState = .{
    .status = .unsynchronized,
    .offset_sec = 0,
    .offset_frac = 0,
    .delay_ms = 0,
    .stratum = 0,
    .leap = LEAP_ALARM,
    .reference_id = 0,
    .last_sync_tick = 0,
    .last_server_ip = 0,
    .sync_count = 0,
    .error_count = 0,
    .origin_ts = .{ .seconds = 0, .fraction = 0 },
    .receive_ts = .{ .seconds = 0, .fraction = 0 },
    .transmit_ts = .{ .seconds = 0, .fraction = 0 },
    .dest_ts = .{ .seconds = 0, .fraction = 0 },
};

// ============================================================
// Server pool
// ============================================================

const MAX_SERVERS = 4;
var server_pool: [MAX_SERVERS]u32 = [_]u32{
    ipAddr(10, 0, 2, 2), // QEMU default gateway (may have NTP)
    ipAddr(216, 239, 35, 0), // time.google.com
    ipAddr(132, 163, 96, 1), // time.nist.gov
    ipAddr(129, 6, 15, 28), // time-a.nist.gov
};
var server_count: usize = 1; // Only first one likely works in QEMU

/// Set a server IP in the pool.
pub fn setServer(index: usize, ip: u32) void {
    if (index < MAX_SERVERS) {
        server_pool[index] = ip;
        if (index >= server_count) server_count = index + 1;
    }
}

/// Get a server IP from the pool.
pub fn getServer(index: usize) ?u32 {
    if (index < server_count) return server_pool[index];
    return null;
}

// ============================================================
// NTP sync
// ============================================================

/// Send an NTP request to the given server and process the response.
/// Returns true if synchronization succeeded.
pub fn sync(server_ip: u32) bool {
    if (!e1000.isInitialized()) return false;

    const sock = udp.create() orelse return false;
    defer udp.close(sock);

    // Bind to an ephemeral port
    const local_port: u16 = 10123 + @as(u16, @truncate(pit.getTicks() & 0xFF));
    _ = udp.bind(sock, local_port);

    // Build NTP request
    var pkt: [NTP_PACKET_SIZE]u8 = @splat(0);
    // LI=0, VN=4, Mode=3 (client)
    pkt[0] = (NTP_VERSION << 3) | NTP_MODE_CLIENT;

    // Set transmit timestamp (T1): use PIT ticks as a rough NTP timestamp
    const t1_ticks = pit.getTicks();
    const t1_sec: u32 = @truncate(t1_ticks / 1000 + NTP_UNIX_OFFSET);
    const t1_frac: u32 = @truncate((t1_ticks % 1000) * 4294967); // rough fraction

    net_util.putU32BE(pkt[40..44], t1_sec);
    net_util.putU32BE(pkt[44..48], t1_frac);

    state.origin_ts = .{ .seconds = t1_sec, .fraction = t1_frac };

    // Send request
    if (!udp.sendTo(sock, server_ip, NTP_PORT, &pkt)) {
        serial.write("[NTP] send failed\n");
        state.error_count += 1;
        return false;
    }

    serial.write("[NTP] request sent to ");
    net_util.serialPrintIp(server_ip);
    serial.write("\n");

    // Receive response
    var resp: [NTP_PACKET_SIZE]u8 = undefined;
    const resp_len = udp.recvFrom(sock, &resp);
    const t4_ticks = pit.getTicks();

    if (resp_len < NTP_PACKET_SIZE) {
        serial.write("[NTP] no response or too short\n");
        state.error_count += 1;
        return false;
    }

    // Parse response
    return processResponse(&resp, t1_ticks, t4_ticks, server_ip);
}

/// Attempt to sync with all servers in the pool until one succeeds.
pub fn syncPool() bool {
    var i: usize = 0;
    while (i < server_count) : (i += 1) {
        if (server_pool[i] != 0) {
            if (sync(server_pool[i])) return true;
        }
    }
    return false;
}

// ============================================================
// Time query
// ============================================================

/// Get the NTP-corrected Unix timestamp, or null if not synchronized.
pub fn getTime() ?u32 {
    if (state.status == .unsynchronized) return null;

    // Check staleness: if last sync was more than 1 hour ago, mark stale
    const elapsed = pit.getTicks() -| state.last_sync_tick;
    if (elapsed > 3600 * 1000) {
        state.status = .stale;
    }

    // Compute current time from PIT ticks + offset
    const now_ticks = pit.getTicks();
    const base_sec: u32 = @truncate(now_ticks / 1000);
    const adjusted: i64 = @as(i64, base_sec) + @as(i64, state.offset_sec);
    if (adjusted < 0) return null;
    return @truncate(@as(u64, @bitCast(adjusted)));
}

/// Get the sync status.
pub fn getStatus() SyncStatus {
    return state.status;
}

/// Get the round-trip delay in milliseconds.
pub fn getDelay() u32 {
    return state.delay_ms;
}

/// Get the clock offset in seconds.
pub fn getOffset() i32 {
    return state.offset_sec;
}

// ============================================================
// NTP timestamp conversion
// ============================================================

/// Convert an NTP timestamp (seconds since 1900) to a Unix timestamp (seconds since 1970).
pub fn ntpToUnix(ntp_sec: u32) u32 {
    if (ntp_sec < NTP_UNIX_OFFSET) return 0;
    return ntp_sec - NTP_UNIX_OFFSET;
}

/// Convert a Unix timestamp to an NTP timestamp.
pub fn unixToNtp(unix_sec: u32) u32 {
    return unix_sec +% NTP_UNIX_OFFSET;
}

/// Break a Unix timestamp into year/month/day/hour/min/sec (simplified).
pub fn unixToDateTime(unix: u32) DateTime {
    var remaining = unix;
    const sec: u8 = @truncate(remaining % 60);
    remaining /= 60;
    const min: u8 = @truncate(remaining % 60);
    remaining /= 60;
    const hour: u8 = @truncate(remaining % 24);
    remaining /= 24;

    // Days since 1970-01-01
    var days = remaining;
    var year: u16 = 1970;
    while (true) {
        const ydays: u32 = if (isLeapYear(year)) 366 else 365;
        if (days < ydays) break;
        days -= ydays;
        year += 1;
    }

    const mdays = if (isLeapYear(year)) leap_month_days else normal_month_days;
    var month: u8 = 1;
    while (month <= 12) {
        if (days < mdays[month - 1]) break;
        days -= mdays[month - 1];
        month += 1;
    }

    return .{
        .year = year,
        .month = month,
        .day = @truncate(days + 1),
        .hour = hour,
        .minute = min,
        .second = sec,
    };
}

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

const normal_month_days = [12]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const leap_month_days = [12]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

// ============================================================
// Display
// ============================================================

/// Print NTP sync status to VGA.
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("NTP Status:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Status:     ");
    switch (state.status) {
        .unsynchronized => {
            vga.setColor(.light_red, .black);
            vga.write("UNSYNCHRONIZED\n");
        },
        .synchronized => {
            vga.setColor(.light_green, .black);
            vga.write("SYNCHRONIZED\n");
        },
        .stale => {
            vga.setColor(.yellow, .black);
            vga.write("STALE\n");
        },
    }
    vga.setColor(.light_grey, .black);

    vga.write("  Server:     ");
    if (state.last_server_ip != 0) {
        net_util.printIp(state.last_server_ip);
    } else {
        vga.write("(none)");
    }
    vga.putChar('\n');

    vga.write("  Stratum:    ");
    net_util.printDec(state.stratum);
    vga.putChar('\n');

    vga.write("  Offset:     ");
    if (state.offset_sec < 0) {
        vga.putChar('-');
        net_util.printDec(@as(usize, @intCast(-state.offset_sec)));
    } else {
        net_util.printDec(@as(usize, @intCast(state.offset_sec)));
    }
    vga.write(" sec\n");

    vga.write("  Delay:      ");
    net_util.printDec(state.delay_ms);
    vga.write(" ms\n");

    vga.write("  Leap:       ");
    switch (state.leap) {
        LEAP_NONE => vga.write("none"),
        LEAP_LAST_61 => vga.write("+1 sec"),
        LEAP_LAST_59 => vga.write("-1 sec"),
        LEAP_ALARM => vga.write("alarm (unsync)"),
    }
    vga.putChar('\n');

    vga.write("  Syncs:      ");
    net_util.printDec(state.sync_count);
    vga.write("  Errors: ");
    net_util.printDec(state.error_count);
    vga.putChar('\n');

    // Show current time if synchronized
    if (getTime()) |unix| {
        const dt = unixToDateTime(unix);
        vga.write("  Time (UTC): ");
        printDecPad2(dt.year);
        vga.putChar('-');
        printDecPad2(dt.month);
        vga.putChar('-');
        printDecPad2(dt.day);
        vga.putChar(' ');
        printDecPad2(dt.hour);
        vga.putChar(':');
        printDecPad2(dt.minute);
        vga.putChar(':');
        printDecPad2(dt.second);
        vga.putChar('\n');
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn processResponse(resp: *const [NTP_PACKET_SIZE]u8, t1_ticks: u64, t4_ticks: u64, server_ip: u32) bool {
    const li_vn_mode = resp[0];
    const mode: u3 = @truncate(li_vn_mode & 0x07);
    const leap: u2 = @truncate(li_vn_mode >> 6);

    // Validate: should be server mode
    if (mode != NTP_MODE_SERVER and mode != 4) {
        serial.write("[NTP] unexpected mode\n");
        state.error_count += 1;
        return false;
    }

    const stratum = resp[1];
    if (stratum == 0) {
        serial.write("[NTP] kiss-o-death (stratum 0)\n");
        state.error_count += 1;
        return false;
    }

    // Extract timestamps (T2 = receive, T3 = transmit)
    const t2_sec = net_util.getU32BE(resp[32..36]);
    const t2_frac = net_util.getU32BE(resp[36..40]);
    const t3_sec = net_util.getU32BE(resp[40..44]);
    const t3_frac = net_util.getU32BE(resp[44..48]);
    _ = t2_frac;
    _ = t3_frac;

    // Reference ID
    const ref_id = net_util.getU32BE(resp[12..16]);

    // T1 and T4 are in PIT ticks; convert to rough NTP seconds
    const t1_sec: u32 = @truncate(t1_ticks / 1000 + NTP_UNIX_OFFSET);
    const t4_sec: u32 = @truncate(t4_ticks / 1000 + NTP_UNIX_OFFSET);

    // Round-trip delay: d = (T4 - T1) - (T3 - T2)
    const rtt_local: i64 = @as(i64, t4_sec) - @as(i64, t1_sec);
    const rtt_server: i64 = @as(i64, t3_sec) - @as(i64, t2_sec);
    var delay: i64 = rtt_local - rtt_server;
    if (delay < 0) delay = 0;

    // Clock offset: theta = ((T2 - T1) + (T3 - T4)) / 2
    const off1: i64 = @as(i64, t2_sec) - @as(i64, t1_sec);
    const off2: i64 = @as(i64, t3_sec) - @as(i64, t4_sec);
    const offset: i64 = @divTrunc(off1 + off2, 2);

    // Update state
    state.status = .synchronized;
    state.offset_sec = @truncate(offset);
    state.delay_ms = @truncate(@as(u64, @bitCast(delay)) * 1000);
    state.stratum = stratum;
    state.leap = leap;
    state.reference_id = ref_id;
    state.last_sync_tick = t4_ticks;
    state.last_server_ip = server_ip;
    state.sync_count += 1;
    state.receive_ts = .{ .seconds = t2_sec, .fraction = 0 };
    state.transmit_ts = .{ .seconds = t3_sec, .fraction = 0 };
    state.dest_ts = .{ .seconds = t4_sec, .fraction = 0 };

    serial.write("[NTP] synchronized, offset=");
    if (offset < 0) {
        serial.write("-");
    }
    serial.write("s\n");

    return true;
}

fn printDecPad2(val: anytype) void {
    const v: usize = @intCast(val);
    if (v < 10) vga.putChar('0');
    net_util.printDec(v);
}

fn ipAddr(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}
