// TCP option parsing and generation (RFC 793, RFC 1323, RFC 2018, RFC 7323)
//
// Supports: End-of-Options (0), NOP (1), MSS (2), Window Scale (3),
// SACK Permitted (4), SACK (5), Timestamp (8).
// Provides both parsing from incoming segments and generation for outgoing.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ============================================================
// TCP Option kind constants
// ============================================================

pub const OPT_END: u8 = 0;
pub const OPT_NOP: u8 = 1;
pub const OPT_MSS: u8 = 2;
pub const OPT_WINDOW_SCALE: u8 = 3;
pub const OPT_SACK_PERMITTED: u8 = 4;
pub const OPT_SACK: u8 = 5;
pub const OPT_TIMESTAMP: u8 = 8;

// Option lengths (total including kind and length bytes)
pub const MSS_LEN: u8 = 4;
pub const WSCALE_LEN: u8 = 3;
pub const SACK_PERM_LEN: u8 = 2;
pub const TIMESTAMP_LEN: u8 = 10;

// Default values
pub const DEFAULT_MSS: u16 = 536; // RFC 879 default for IPv4
pub const MAX_MSS: u16 = 1460; // Typical for Ethernet (1500 - 40)
pub const MAX_WINDOW_SCALE: u8 = 14; // RFC 7323 max
pub const MAX_SACK_BLOCKS: usize = 4; // Max SACK blocks per segment

// ============================================================
// Types
// ============================================================

pub const SackBlock = struct {
    left_edge: u32 = 0, // first sequence number in block
    right_edge: u32 = 0, // sequence number just past end of block
};

pub const Timestamps = struct {
    ts_val: u32 = 0, // Timestamp Value (sender's clock)
    ts_ecr: u32 = 0, // Timestamp Echo Reply (echoed sender)
};

pub const TcpOptions = struct {
    // MSS option
    mss_present: bool = false,
    mss: u16 = DEFAULT_MSS,

    // Window scale option
    wscale_present: bool = false,
    window_scale: u8 = 0,

    // SACK permitted (SYN only)
    sack_permitted: bool = false,

    // SACK blocks
    sack_count: u8 = 0,
    sack_blocks: [MAX_SACK_BLOCKS]SackBlock = [_]SackBlock{.{}} ** MAX_SACK_BLOCKS,

    // Timestamps
    timestamps_present: bool = false,
    timestamps: Timestamps = .{},

    // Parsing stats
    unknown_options: u8 = 0,
    parse_errors: u8 = 0,
};

// ============================================================
// Statistics
// ============================================================

pub const OptionStats = struct {
    parsed_count: u64 = 0,
    built_count: u64 = 0,
    mss_seen: u64 = 0,
    wscale_seen: u64 = 0,
    sack_perm_seen: u64 = 0,
    sack_seen: u64 = 0,
    timestamp_seen: u64 = 0,
    parse_errors: u64 = 0,
};

var stats: OptionStats = .{};

// ============================================================
// Parsing
// ============================================================

/// Parse TCP options from a raw byte slice.
/// The `data` slice should contain only the options portion of the TCP header
/// (i.e., after the 20-byte fixed header, up to data_offset * 4 bytes total).
pub fn parseOptions(data: []const u8) TcpOptions {
    var opts: TcpOptions = .{};
    var pos: usize = 0;
    stats.parsed_count += 1;

    while (pos < data.len) {
        const kind = data[pos];

        if (kind == OPT_END) break;
        if (kind == OPT_NOP) {
            pos += 1;
            continue;
        }

        // All other options have at least a length byte
        if (pos + 1 >= data.len) {
            opts.parse_errors += 1;
            stats.parse_errors += 1;
            break;
        }

        const opt_len = data[pos + 1];
        if (opt_len < 2 or pos + opt_len > data.len) {
            opts.parse_errors += 1;
            stats.parse_errors += 1;
            break;
        }

        switch (kind) {
            OPT_MSS => {
                if (opt_len == MSS_LEN and pos + 4 <= data.len) {
                    opts.mss = @as(u16, data[pos + 2]) << 8 | data[pos + 3];
                    opts.mss_present = true;
                    stats.mss_seen += 1;
                } else {
                    opts.parse_errors += 1;
                }
            },
            OPT_WINDOW_SCALE => {
                if (opt_len == WSCALE_LEN and pos + 3 <= data.len) {
                    opts.window_scale = data[pos + 2];
                    if (opts.window_scale > MAX_WINDOW_SCALE) {
                        opts.window_scale = MAX_WINDOW_SCALE;
                    }
                    opts.wscale_present = true;
                    stats.wscale_seen += 1;
                } else {
                    opts.parse_errors += 1;
                }
            },
            OPT_SACK_PERMITTED => {
                if (opt_len == SACK_PERM_LEN) {
                    opts.sack_permitted = true;
                    stats.sack_perm_seen += 1;
                }
            },
            OPT_SACK => {
                parseSackBlocks(data[pos..pos + opt_len], &opts);
                stats.sack_seen += 1;
            },
            OPT_TIMESTAMP => {
                if (opt_len == TIMESTAMP_LEN and pos + 10 <= data.len) {
                    opts.timestamps.ts_val = readU32BE(data[pos + 2 ..]);
                    opts.timestamps.ts_ecr = readU32BE(data[pos + 6 ..]);
                    opts.timestamps_present = true;
                    stats.timestamp_seen += 1;
                } else {
                    opts.parse_errors += 1;
                }
            },
            else => {
                opts.unknown_options += 1;
            },
        }

        pos += opt_len;
    }

    return opts;
}

fn parseSackBlocks(data: []const u8, opts: *TcpOptions) void {
    if (data.len < 2) return;
    const payload_len = data[1];
    if (payload_len < 2) return;
    const block_bytes = payload_len - 2;
    // Each SACK block is 8 bytes (4 left + 4 right)
    const num_blocks = block_bytes / 8;
    if (num_blocks == 0) return;

    var count: u8 = 0;
    var off: usize = 2;
    while (count < MAX_SACK_BLOCKS and count < num_blocks) : (count += 1) {
        if (off + 8 > data.len) break;
        opts.sack_blocks[count] = .{
            .left_edge = readU32BE(data[off..]),
            .right_edge = readU32BE(data[off + 4 ..]),
        };
        off += 8;
    }
    opts.sack_count = count;
}

// ============================================================
// Generation
// ============================================================

/// Build TCP options into `buf`. Returns the number of bytes written.
/// The output is padded to a 4-byte boundary with NOP/END as needed.
pub fn buildOptions(opts: *const TcpOptions, buf: []u8) usize {
    var pos: usize = 0;
    stats.built_count += 1;

    // MSS
    if (opts.mss_present) {
        if (pos + 4 <= buf.len) {
            buf[pos] = OPT_MSS;
            buf[pos + 1] = MSS_LEN;
            buf[pos + 2] = @truncate(opts.mss >> 8);
            buf[pos + 3] = @truncate(opts.mss & 0xFF);
            pos += 4;
        }
    }

    // Window scale
    if (opts.wscale_present) {
        // NOP padding for alignment
        if (pos + 4 <= buf.len) {
            buf[pos] = OPT_NOP;
            pos += 1;
            buf[pos] = OPT_WINDOW_SCALE;
            buf[pos + 1] = WSCALE_LEN;
            buf[pos + 2] = opts.window_scale;
            pos += 3;
        }
    }

    // SACK permitted
    if (opts.sack_permitted) {
        if (pos + 2 <= buf.len) {
            buf[pos] = OPT_SACK_PERMITTED;
            buf[pos + 1] = SACK_PERM_LEN;
            pos += 2;
        }
    }

    // SACK blocks
    if (opts.sack_count > 0) {
        const sack_len: u8 = 2 + opts.sack_count * 8;
        if (pos + sack_len <= buf.len) {
            // NOP NOP padding before SACK
            if (pos + 2 + sack_len <= buf.len) {
                buf[pos] = OPT_NOP;
                buf[pos + 1] = OPT_NOP;
                pos += 2;
            }
            buf[pos] = OPT_SACK;
            buf[pos + 1] = sack_len;
            pos += 2;
            var i: u8 = 0;
            while (i < opts.sack_count) : (i += 1) {
                writeU32BE(buf[pos..], opts.sack_blocks[i].left_edge);
                pos += 4;
                writeU32BE(buf[pos..], opts.sack_blocks[i].right_edge);
                pos += 4;
            }
        }
    }

    // Timestamps
    if (opts.timestamps_present) {
        if (pos + 12 <= buf.len) {
            // NOP NOP padding for alignment
            buf[pos] = OPT_NOP;
            buf[pos + 1] = OPT_NOP;
            pos += 2;
            buf[pos] = OPT_TIMESTAMP;
            buf[pos + 1] = TIMESTAMP_LEN;
            writeU32BE(buf[pos + 2 ..], opts.timestamps.ts_val);
            writeU32BE(buf[pos + 6 ..], opts.timestamps.ts_ecr);
            pos += 10;
        }
    }

    // Pad to 4-byte boundary with END/NOP
    while (pos % 4 != 0 and pos < buf.len) {
        buf[pos] = OPT_END;
        pos += 1;
    }

    return pos;
}

/// Build SYN options: MSS + Window Scale + SACK Permitted + Timestamp.
/// Returns the number of bytes written to `buf`.
pub fn buildSynOptions(mss: u16, wscale: u8, buf: []u8) usize {
    var opts: TcpOptions = .{};
    opts.mss_present = true;
    opts.mss = mss;
    opts.wscale_present = true;
    opts.window_scale = if (wscale > MAX_WINDOW_SCALE) MAX_WINDOW_SCALE else wscale;
    opts.sack_permitted = true;
    return buildOptions(&opts, buf);
}

/// Build SYN-ACK options in response to received SYN options.
/// Performs MSS negotiation and window scale matching.
pub fn buildSynAckOptions(received: *const TcpOptions, our_mss: u16, our_wscale: u8, buf: []u8) usize {
    var opts: TcpOptions = .{};

    // MSS negotiation: use minimum of ours and theirs
    opts.mss_present = true;
    if (received.mss_present) {
        opts.mss = if (our_mss < received.mss) our_mss else received.mss;
    } else {
        opts.mss = our_mss;
    }

    // Window scale: only offer if peer offered
    if (received.wscale_present) {
        opts.wscale_present = true;
        opts.window_scale = if (our_wscale > MAX_WINDOW_SCALE) MAX_WINDOW_SCALE else our_wscale;
    }

    // SACK permitted: only if peer requested
    if (received.sack_permitted) {
        opts.sack_permitted = true;
    }

    // Timestamps: echo if peer sent
    if (received.timestamps_present) {
        opts.timestamps_present = true;
        opts.timestamps.ts_ecr = received.timestamps.ts_val;
        // ts_val would be set by caller with current clock
    }

    return buildOptions(&opts, buf);
}

// ============================================================
// MSS negotiation helpers
// ============================================================

/// Negotiate MSS from both ends. Returns the effective MSS.
pub fn negotiateMss(our_mss: u16, peer_mss: u16) u16 {
    const effective = if (our_mss < peer_mss) our_mss else peer_mss;
    // Clamp to minimum reasonable MSS
    return if (effective < 64) 64 else effective;
}

/// Calculate appropriate MSS for a given MTU.
pub fn mssFromMtu(mtu: u16) u16 {
    // MTU - IP header (20) - TCP header (20)
    if (mtu <= 40) return 64;
    return mtu - 40;
}

/// Calculate effective window size with scaling.
pub fn scaledWindow(window: u16, scale: u8) u32 {
    if (scale > MAX_WINDOW_SCALE) return @as(u32, window) << MAX_WINDOW_SCALE;
    return @as(u32, window) << @intCast(scale);
}

/// Compute a suggested window scale factor for a desired receive buffer size.
pub fn calcWindowScale(desired_buf_size: u32) u8 {
    if (desired_buf_size <= 65535) return 0;
    var scale: u8 = 0;
    var size = desired_buf_size;
    while (size > 65535 and scale < MAX_WINDOW_SCALE) {
        size >>= 1;
        scale += 1;
    }
    return scale;
}

// ============================================================
// Timestamp helpers
// ============================================================

/// Build a timestamp echo: set ts_ecr to the peer's ts_val.
pub fn buildTimestampEcho(peer_ts_val: u32, our_clock: u32) Timestamps {
    return .{
        .ts_val = our_clock,
        .ts_ecr = peer_ts_val,
    };
}

/// Calculate RTT from a returned timestamp echo.
/// Returns RTT in timestamp-clock units.
pub fn rttFromTimestamp(our_sent_ts: u32, current_ts: u32) u32 {
    return current_ts -% our_sent_ts;
}

// ============================================================
// Display
// ============================================================

/// Print parsed TCP options.
pub fn printOptions(opts: *const TcpOptions) void {
    vga.setColor(.yellow, .black);
    vga.write("TCP Options:\n");
    vga.setColor(.light_grey, .black);

    if (opts.mss_present) {
        vga.write("  MSS:            ");
        printDec(opts.mss);
        vga.putChar('\n');
    }
    if (opts.wscale_present) {
        vga.write("  Window Scale:   ");
        printDec(opts.window_scale);
        vga.write(" (x");
        printDec(@as(u32, 1) << @intCast(opts.window_scale));
        vga.write(")\n");
    }
    if (opts.sack_permitted) {
        vga.write("  SACK Permitted: yes\n");
    }
    if (opts.sack_count > 0) {
        vga.write("  SACK Blocks:    ");
        printDec(opts.sack_count);
        vga.putChar('\n');
        var i: u8 = 0;
        while (i < opts.sack_count) : (i += 1) {
            vga.write("    [");
            printDec(opts.sack_blocks[i].left_edge);
            vga.write(" - ");
            printDec(opts.sack_blocks[i].right_edge);
            vga.write("]\n");
        }
    }
    if (opts.timestamps_present) {
        vga.write("  Timestamp Val:  ");
        printDec(opts.timestamps.ts_val);
        vga.putChar('\n');
        vga.write("  Timestamp Ecr:  ");
        printDec(opts.timestamps.ts_ecr);
        vga.putChar('\n');
    }
    if (opts.unknown_options > 0) {
        vga.write("  Unknown opts:   ");
        printDec(opts.unknown_options);
        vga.putChar('\n');
    }
    if (opts.parse_errors > 0) {
        vga.write("  Parse errors:   ");
        printDec(opts.parse_errors);
        vga.putChar('\n');
    }
}

/// Print option statistics.
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("TCP Option Statistics:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Parsed:         ");
    printDec(stats.parsed_count);
    vga.putChar('\n');
    vga.write("  Built:          ");
    printDec(stats.built_count);
    vga.putChar('\n');
    vga.write("  MSS seen:       ");
    printDec(stats.mss_seen);
    vga.putChar('\n');
    vga.write("  WScale seen:    ");
    printDec(stats.wscale_seen);
    vga.putChar('\n');
    vga.write("  SACK perm seen: ");
    printDec(stats.sack_perm_seen);
    vga.putChar('\n');
    vga.write("  SACK seen:      ");
    printDec(stats.sack_seen);
    vga.putChar('\n');
    vga.write("  Timestamp seen: ");
    printDec(stats.timestamp_seen);
    vga.putChar('\n');
    vga.write("  Parse errors:   ");
    printDec(stats.parse_errors);
    vga.putChar('\n');
}

pub fn getOptionStats() OptionStats {
    return stats;
}

pub fn resetOptionStats() void {
    stats = .{};
}

// ============================================================
// Internal helpers
// ============================================================

fn readU32BE(data: []const u8) u32 {
    if (data.len < 4) return 0;
    return @as(u32, data[0]) << 24 |
        @as(u32, data[1]) << 16 |
        @as(u32, data[2]) << 8 |
        data[3];
}

fn writeU32BE(buf: []u8, val: u32) void {
    if (buf.len < 4) return;
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate((val >> 16) & 0xFF);
    buf[2] = @truncate((val >> 8) & 0xFF);
    buf[3] = @truncate(val & 0xFF);
}

fn printDec(n: anytype) void {
    const v_init: u64 = @intCast(n);
    if (v_init == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = v_init;
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
