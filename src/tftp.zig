// TFTP client (Trivial File Transfer Protocol) — RFC 1350
//
// Implements TFTP read (RRQ) and write (WRQ) operations using UDP.
// Supports block-by-block transfer (512 bytes), retries, and error handling.

const udp = @import("udp.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");

// ============================================================
// TFTP constants
// ============================================================

const TFTP_PORT: u16 = 69;
const BLOCK_SIZE: usize = 512;
const MAX_RETRIES: u8 = 3;
const TIMEOUT_MS: u32 = 2000; // 2 seconds per retry
const MAX_FILENAME: usize = 128;

// ============================================================
// TFTP opcodes
// ============================================================

pub const OP_RRQ: u16 = 1; // Read Request
pub const OP_WRQ: u16 = 2; // Write Request
pub const OP_DATA: u16 = 3; // Data
pub const OP_ACK: u16 = 4; // Acknowledgment
pub const OP_ERROR: u16 = 5; // Error

// ============================================================
// TFTP error codes
// ============================================================

pub const ERR_UNDEFINED: u16 = 0;
pub const ERR_FILE_NOT_FOUND: u16 = 1;
pub const ERR_ACCESS_VIOLATION: u16 = 2;
pub const ERR_DISK_FULL: u16 = 3;
pub const ERR_ILLEGAL_OP: u16 = 4;
pub const ERR_UNKNOWN_TID: u16 = 5;
pub const ERR_FILE_EXISTS: u16 = 6;
pub const ERR_NO_SUCH_USER: u16 = 7;

// ============================================================
// Transfer statistics
// ============================================================

pub const TransferStats = struct {
    bytes_transferred: u32,
    blocks_transferred: u16,
    retries: u16,
    start_tick: u64,
    end_tick: u64,
    last_error: u16,
    last_server: u32,
    filename: [MAX_FILENAME]u8,
    filename_len: usize,
    succeeded: bool,
    direction: Direction,
};

pub const Direction = enum(u1) {
    download = 0,
    upload = 1,
};

var last_transfer: TransferStats = .{
    .bytes_transferred = 0,
    .blocks_transferred = 0,
    .retries = 0,
    .start_tick = 0,
    .end_tick = 0,
    .last_error = 0,
    .last_server = 0,
    .filename = undefined,
    .filename_len = 0,
    .succeeded = false,
    .direction = .download,
};

// Total transfer counters
var total_downloads: u32 = 0;
var total_uploads: u32 = 0;
var total_errors: u32 = 0;

// ============================================================
// Read file (download)
// ============================================================

/// Download a file from a TFTP server.
/// Returns the number of bytes received, or null on failure.
pub fn readFile(server_ip: u32, filename: []const u8, buf: []u8) ?usize {
    if (!e1000.isInitialized()) return null;
    if (filename.len == 0 or filename.len > MAX_FILENAME) return null;
    if (buf.len == 0) return null;

    // Init transfer stats
    initTransferStats(server_ip, filename, .download);

    const sock = udp.create() orelse return null;
    defer udp.close(sock);

    const local_port: u16 = 10069 + @as(u16, @truncate(pit.getTicks() & 0xFF));
    _ = udp.bind(sock, local_port);

    // Build and send RRQ
    var req: [256]u8 = undefined;
    const req_len = buildRequest(OP_RRQ, filename, &req);

    if (!udp.sendTo(sock, server_ip, TFTP_PORT, req[0..req_len])) {
        serial.write("[TFTP] RRQ send failed\n");
        finishTransfer(false, ERR_UNDEFINED);
        return null;
    }

    serial.write("[TFTP] RRQ sent for '");
    serial.write(filename);
    serial.write("'\n");

    // Receive data blocks
    var total_bytes: usize = 0;
    var expected_block: u16 = 1;
    var server_port: u16 = 0; // TID assigned by server

    while (true) {
        // Receive with retry
        var resp: [BLOCK_SIZE + 4]u8 = undefined;
        var resp_len: usize = 0;
        var retry: u8 = 0;

        while (retry < MAX_RETRIES) {
            resp_len = udp.recvFrom(sock, &resp);
            if (resp_len >= 4) break;
            retry += 1;
            last_transfer.retries += 1;

            // Resend ACK for previous block (or re-send RRQ for first block)
            if (expected_block == 1) {
                _ = udp.sendTo(sock, server_ip, TFTP_PORT, req[0..req_len]);
            } else {
                var ack: [4]u8 = undefined;
                buildAck(expected_block - 1, &ack);
                _ = udp.sendTo(sock, server_ip, server_port, &ack);
            }
        }

        if (resp_len < 4) {
            serial.write("[TFTP] timeout waiting for data\n");
            finishTransfer(false, ERR_UNDEFINED);
            return null;
        }

        const opcode = net_util.getU16BE(resp[0..2]);

        // Handle error
        if (opcode == OP_ERROR) {
            const err_code = net_util.getU16BE(resp[2..4]);
            serial.write("[TFTP] error: ");
            serial.write(errorString(err_code));
            serial.write("\n");
            finishTransfer(false, err_code);
            return null;
        }

        if (opcode != OP_DATA) {
            serial.write("[TFTP] unexpected opcode\n");
            finishTransfer(false, ERR_ILLEGAL_OP);
            return null;
        }

        const block_num = net_util.getU16BE(resp[2..4]);

        // Remember server's ephemeral port (TID)
        if (expected_block == 1 and block_num == 1) {
            // The server port is captured via the UDP socket's remote tracking
            server_port = TFTP_PORT; // For simplicity, use initial port
        }

        if (block_num != expected_block) {
            // Duplicate or out-of-order: re-ACK
            var ack: [4]u8 = undefined;
            buildAck(block_num, &ack);
            _ = udp.sendTo(sock, server_ip, server_port, &ack);
            continue;
        }

        // Copy data
        const data_len = resp_len - 4;
        const copy_len = @min(data_len, buf.len - total_bytes);
        if (copy_len > 0) {
            for (0..copy_len) |i| {
                buf[total_bytes + i] = resp[4 + i];
            }
        }
        total_bytes += copy_len;
        last_transfer.blocks_transferred += 1;
        last_transfer.bytes_transferred = @truncate(total_bytes);

        // Send ACK
        var ack: [4]u8 = undefined;
        buildAck(block_num, &ack);
        _ = udp.sendTo(sock, server_ip, server_port, &ack);

        expected_block += 1;

        // Last block: data < 512 bytes
        if (data_len < BLOCK_SIZE) {
            break;
        }

        // Buffer full
        if (total_bytes >= buf.len) {
            break;
        }
    }

    finishTransfer(true, 0);
    total_downloads += 1;
    serial.write("[TFTP] download complete\n");
    return total_bytes;
}

// ============================================================
// Write file (upload)
// ============================================================

/// Upload data to a TFTP server.
/// Returns true on success.
pub fn writeFile(server_ip: u32, filename: []const u8, data: []const u8) bool {
    if (!e1000.isInitialized()) return false;
    if (filename.len == 0 or filename.len > MAX_FILENAME) return false;

    // Init transfer stats
    initTransferStats(server_ip, filename, .upload);

    const sock = udp.create() orelse return false;
    defer udp.close(sock);

    const local_port: u16 = 10070 + @as(u16, @truncate(pit.getTicks() & 0xFF));
    _ = udp.bind(sock, local_port);

    // Build and send WRQ
    var req: [256]u8 = undefined;
    const req_len = buildRequest(OP_WRQ, filename, &req);

    if (!udp.sendTo(sock, server_ip, TFTP_PORT, req[0..req_len])) {
        serial.write("[TFTP] WRQ send failed\n");
        finishTransfer(false, ERR_UNDEFINED);
        return false;
    }

    serial.write("[TFTP] WRQ sent for '");
    serial.write(filename);
    serial.write("'\n");

    // Wait for ACK 0 (write request acknowledged)
    var resp: [BLOCK_SIZE + 4]u8 = undefined;
    var resp_len = udp.recvFrom(sock, &resp);
    if (resp_len < 4) {
        serial.write("[TFTP] no ACK for WRQ\n");
        finishTransfer(false, ERR_UNDEFINED);
        return false;
    }

    var opcode = net_util.getU16BE(resp[0..2]);
    if (opcode == OP_ERROR) {
        const err_code = net_util.getU16BE(resp[2..4]);
        finishTransfer(false, err_code);
        return false;
    }
    if (opcode != OP_ACK) {
        finishTransfer(false, ERR_ILLEGAL_OP);
        return false;
    }

    const server_port = TFTP_PORT;

    // Send data blocks
    var offset: usize = 0;
    var block_num: u16 = 1;

    while (true) {
        // Prepare data block
        const remaining = data.len - offset;
        const send_len = @min(remaining, BLOCK_SIZE);

        var data_pkt: [BLOCK_SIZE + 4]u8 = undefined;
        net_util.putU16BE(data_pkt[0..2], OP_DATA);
        net_util.putU16BE(data_pkt[2..4], block_num);
        if (send_len > 0) {
            for (0..send_len) |i| {
                data_pkt[4 + i] = data[offset + i];
            }
        }

        // Send with retry
        var retry: u8 = 0;
        var acked = false;

        while (retry < MAX_RETRIES) {
            if (!udp.sendTo(sock, server_ip, server_port, data_pkt[0 .. 4 + send_len])) {
                retry += 1;
                last_transfer.retries += 1;
                continue;
            }

            // Wait for ACK
            resp_len = udp.recvFrom(sock, &resp);
            if (resp_len >= 4) {
                opcode = net_util.getU16BE(resp[0..2]);
                if (opcode == OP_ACK) {
                    const ack_block = net_util.getU16BE(resp[2..4]);
                    if (ack_block == block_num) {
                        acked = true;
                        break;
                    }
                } else if (opcode == OP_ERROR) {
                    const err_code = net_util.getU16BE(resp[2..4]);
                    finishTransfer(false, err_code);
                    return false;
                }
            }

            retry += 1;
            last_transfer.retries += 1;
        }

        if (!acked) {
            serial.write("[TFTP] upload failed: ACK timeout\n");
            finishTransfer(false, ERR_UNDEFINED);
            return false;
        }

        last_transfer.blocks_transferred += 1;
        offset += send_len;
        last_transfer.bytes_transferred = @truncate(offset);
        block_num += 1;

        // Last block: sent < 512 bytes
        if (send_len < BLOCK_SIZE) {
            break;
        }
    }

    finishTransfer(true, 0);
    total_uploads += 1;
    serial.write("[TFTP] upload complete\n");
    return true;
}

// ============================================================
// Display
// ============================================================

/// Print the last transfer status to VGA.
pub fn printStatus() void {
    vga.setColor(.yellow, .black);
    vga.write("TFTP Transfer Status:\n");
    vga.setColor(.light_grey, .black);

    if (last_transfer.filename_len == 0) {
        vga.write("  No transfers yet.\n");
        return;
    }

    vga.write("  File:     ");
    vga.write(last_transfer.filename[0..last_transfer.filename_len]);
    vga.putChar('\n');

    vga.write("  Server:   ");
    if (last_transfer.last_server != 0) {
        net_util.printIp(last_transfer.last_server);
    }
    vga.putChar('\n');

    vga.write("  Direction: ");
    switch (last_transfer.direction) {
        .download => vga.write("Download"),
        .upload => vga.write("Upload"),
    }
    vga.putChar('\n');

    vga.write("  Status:   ");
    if (last_transfer.succeeded) {
        vga.setColor(.light_green, .black);
        vga.write("SUCCESS");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("FAILED (");
        vga.write(errorString(last_transfer.last_error));
        vga.putChar(')');
    }
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);

    vga.write("  Bytes:    ");
    net_util.printDec(last_transfer.bytes_transferred);
    vga.putChar('\n');

    vga.write("  Blocks:   ");
    net_util.printDec(last_transfer.blocks_transferred);
    vga.putChar('\n');

    vga.write("  Retries:  ");
    net_util.printDec(last_transfer.retries);
    vga.putChar('\n');

    // Time elapsed
    const elapsed_ms = last_transfer.end_tick -| last_transfer.start_tick;
    vga.write("  Time:     ");
    net_util.printDec(@truncate(elapsed_ms));
    vga.write(" ms\n");

    // Throughput
    if (elapsed_ms > 0 and last_transfer.bytes_transferred > 0) {
        const bytes_per_sec = @as(u64, last_transfer.bytes_transferred) * 1000 / elapsed_ms;
        vga.write("  Speed:    ");
        net_util.printDec64(bytes_per_sec);
        vga.write(" B/s\n");
    }

    // Totals
    vga.setColor(.dark_grey, .black);
    vga.write("  Total downloads: ");
    net_util.printDec(total_downloads);
    vga.write("  uploads: ");
    net_util.printDec(total_uploads);
    vga.write("  errors: ");
    net_util.printDec(total_errors);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

// ============================================================
// Error string lookup
// ============================================================

pub fn errorString(code: u16) []const u8 {
    return switch (code) {
        ERR_UNDEFINED => "Undefined error",
        ERR_FILE_NOT_FOUND => "File not found",
        ERR_ACCESS_VIOLATION => "Access violation",
        ERR_DISK_FULL => "Disk full",
        ERR_ILLEGAL_OP => "Illegal TFTP operation",
        ERR_UNKNOWN_TID => "Unknown transfer ID",
        ERR_FILE_EXISTS => "File already exists",
        ERR_NO_SUCH_USER => "No such user",
        else => "Unknown error",
    };
}

// ============================================================
// Internal helpers
// ============================================================

fn buildRequest(opcode: u16, filename: []const u8, buf: *[256]u8) usize {
    var pos: usize = 0;

    // Opcode
    net_util.putU16BE(buf[0..2], opcode);
    pos = 2;

    // Filename (null-terminated)
    const name_len = @min(filename.len, 200);
    for (0..name_len) |i| {
        buf[pos + i] = filename[i];
    }
    pos += name_len;
    buf[pos] = 0;
    pos += 1;

    // Mode: "octet" (binary, null-terminated)
    const mode = "octet";
    for (mode) |c| {
        buf[pos] = c;
        pos += 1;
    }
    buf[pos] = 0;
    pos += 1;

    return pos;
}

fn buildAck(block_num: u16, buf: *[4]u8) void {
    net_util.putU16BE(buf[0..2], OP_ACK);
    net_util.putU16BE(buf[2..4], block_num);
}

fn initTransferStats(server_ip: u32, filename: []const u8, dir: Direction) void {
    last_transfer = .{
        .bytes_transferred = 0,
        .blocks_transferred = 0,
        .retries = 0,
        .start_tick = pit.getTicks(),
        .end_tick = 0,
        .last_error = 0,
        .last_server = server_ip,
        .filename = undefined,
        .filename_len = 0,
        .succeeded = false,
        .direction = dir,
    };

    const len = @min(filename.len, MAX_FILENAME);
    for (0..len) |i| {
        last_transfer.filename[i] = filename[i];
    }
    last_transfer.filename_len = len;
}

fn finishTransfer(success: bool, err: u16) void {
    last_transfer.end_tick = pit.getTicks();
    last_transfer.succeeded = success;
    last_transfer.last_error = err;
    if (!success) total_errors += 1;
}
