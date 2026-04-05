// BSD socket API layer — unified socket interface over TCP and UDP
//
// Provides a file-descriptor based API with socket(), bind(), listen(),
// accept(), connect(), send(), recv(), sendto(), recvfrom(), close(),
// shutdown(), getpeername(), getsockname(), and socket options.

const tcp = @import("tcp.zig");
const udp = @import("udp.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");

// ============================================================
// Address family / domain
// ============================================================

pub const AF_INET: i32 = 2;

// ============================================================
// Socket types
// ============================================================

pub const SOCK_STREAM: i32 = 1; // TCP
pub const SOCK_DGRAM: i32 = 2; // UDP
pub const SOCK_RAW: i32 = 3; // Raw IP

// ============================================================
// Protocol
// ============================================================

pub const IPPROTO_TCP: i32 = 6;
pub const IPPROTO_UDP: i32 = 17;
pub const IPPROTO_ICMP: i32 = 1;

// ============================================================
// Shutdown modes
// ============================================================

pub const SHUT_RD: i32 = 0;
pub const SHUT_WR: i32 = 1;
pub const SHUT_RDWR: i32 = 2;

// ============================================================
// Socket options
// ============================================================

pub const SO_REUSEADDR: i32 = 1;
pub const SO_KEEPALIVE: i32 = 2;
pub const SO_RCVTIMEO: i32 = 3;
pub const SO_SNDBUF: i32 = 4;
pub const SO_RCVBUF: i32 = 5;

// ============================================================
// Error codes
// ============================================================

pub const E_SUCCESS: i32 = 0;
pub const E_BADF: i32 = -9; // Bad file descriptor
pub const E_INVAL: i32 = -22; // Invalid argument
pub const E_NFILE: i32 = -23; // Too many open files
pub const E_AGAIN: i32 = -11; // Resource temporarily unavailable
pub const E_CONNREFUSED: i32 = -111;
pub const E_NOTCONN: i32 = -107;
pub const E_ISCONN: i32 = -106;
pub const E_ADDRINUSE: i32 = -98;
pub const E_ADDRNOTAVAIL: i32 = -99;
pub const E_AFNOSUPPORT: i32 = -97;
pub const E_PROTO: i32 = -71;
pub const E_OPNOTSUPP: i32 = -95;
pub const E_TIMEDOUT: i32 = -110;
pub const E_NOBUFS: i32 = -105;
pub const E_FAULT: i32 = -14;

// ============================================================
// Socket address
// ============================================================

pub const SockAddr = struct {
    ip: u32,
    port: u16,
};

// ============================================================
// RecvFrom result
// ============================================================

pub const RecvResult = struct {
    len: i32,
    from: SockAddr,
};

// ============================================================
// Socket state
// ============================================================

pub const SocketState = enum(u8) {
    unused,
    created,
    bound,
    listening,
    connecting,
    connected,
    closed,
};

// ============================================================
// Socket structure
// ============================================================

const Socket = struct {
    state: SocketState,
    sock_type: i32, // SOCK_STREAM / SOCK_DGRAM / SOCK_RAW
    protocol: i32,
    local_addr: SockAddr,
    remote_addr: SockAddr,
    // Underlying connections
    tcp_conn: ?*tcp.TcpConn,
    udp_sock: ?u16, // UDP socket index
    // Options
    reuse_addr: bool,
    keep_alive: bool,
    recv_timeout_ms: u32,
    // Backlog (for listening sockets)
    backlog: i32,
};

// ============================================================
// Socket table
// ============================================================

const MAX_SOCKETS = 16;
var socket_table: [MAX_SOCKETS]Socket = [_]Socket{.{
    .state = .unused,
    .sock_type = 0,
    .protocol = 0,
    .local_addr = .{ .ip = 0, .port = 0 },
    .remote_addr = .{ .ip = 0, .port = 0 },
    .tcp_conn = null,
    .udp_sock = null,
    .reuse_addr = false,
    .keep_alive = false,
    .recv_timeout_ms = 5000,
    .backlog = 0,
}} ** MAX_SOCKETS;

var next_ephemeral: u16 = 49152;

// ============================================================
// Last error code (per-thread in a real OS; global here)
// ============================================================

var last_errno: i32 = 0;

/// Get the last error code.
pub fn getErrno() i32 {
    return last_errno;
}

fn setErrno(e: i32) void {
    last_errno = e;
}

// ============================================================
// socket()
// ============================================================

/// Create a new socket. Returns a file descriptor (>= 0) or a negative error code.
pub fn socket(domain: i32, sock_type: i32, protocol: i32) ?i32 {
    if (domain != AF_INET) {
        setErrno(E_AFNOSUPPORT);
        return null;
    }

    if (sock_type != SOCK_STREAM and sock_type != SOCK_DGRAM and sock_type != SOCK_RAW) {
        setErrno(E_INVAL);
        return null;
    }

    // Auto-select protocol
    var proto = protocol;
    if (proto == 0) {
        proto = switch (sock_type) {
            SOCK_STREAM => IPPROTO_TCP,
            SOCK_DGRAM => IPPROTO_UDP,
            SOCK_RAW => IPPROTO_ICMP,
            else => 0,
        };
    }

    // Find free slot
    for (&socket_table, 0..) |*s, i| {
        if (s.state == .unused) {
            s.* = .{
                .state = .created,
                .sock_type = sock_type,
                .protocol = proto,
                .local_addr = .{ .ip = 0, .port = 0 },
                .remote_addr = .{ .ip = 0, .port = 0 },
                .tcp_conn = null,
                .udp_sock = null,
                .reuse_addr = false,
                .keep_alive = false,
                .recv_timeout_ms = 5000,
                .backlog = 0,
            };

            // For UDP, create underlying socket immediately
            if (sock_type == SOCK_DGRAM) {
                s.udp_sock = udp.create();
                if (s.udp_sock == null) {
                    s.state = .unused;
                    setErrno(E_NOBUFS);
                    return null;
                }
            }

            return @intCast(i);
        }
    }

    setErrno(E_NFILE);
    return null;
}

// ============================================================
// bind()
// ============================================================

/// Bind a socket to a local address and port. Returns 0 on success.
pub fn bind(fd: i32, addr: u32, port: u16) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.state != .created) {
        setErrno(E_INVAL);
        return E_INVAL;
    }

    // Check for port in use (unless SO_REUSEADDR)
    if (!s.reuse_addr and port != 0) {
        for (&socket_table) |*other| {
            if (other.state != .unused and other.local_addr.port == port) {
                setErrno(E_ADDRINUSE);
                return E_ADDRINUSE;
            }
        }
    }

    s.local_addr = .{ .ip = addr, .port = port };
    s.state = .bound;

    // Bind underlying UDP socket
    if (s.udp_sock) |usock| {
        _ = udp.bind(usock, port);
    }

    return E_SUCCESS;
}

// ============================================================
// listen()
// ============================================================

/// Mark a TCP socket as listening. Returns 0 on success.
pub fn listen_sock(fd: i32, backlog: i32) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.sock_type != SOCK_STREAM) {
        setErrno(E_OPNOTSUPP);
        return E_OPNOTSUPP;
    }

    if (s.state != .bound) {
        setErrno(E_INVAL);
        return E_INVAL;
    }

    s.backlog = if (backlog > 0) backlog else 1;
    s.state = .listening;
    return E_SUCCESS;
}

// ============================================================
// accept()
// ============================================================

/// Accept an incoming TCP connection on a listening socket.
/// Returns a new socket fd, or null on failure/timeout.
pub fn accept(fd: i32) ?i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return null;
    };

    if (s.state != .listening) {
        setErrno(E_INVAL);
        return null;
    }

    // In our kernel, TCP doesn't have a real listen/accept model.
    // We poll for incoming SYN and create a connection.
    // For now, return a blocking wait with timeout.
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < s.recv_timeout_ms) {
        // Poll for packets
        var rx_buf: [1500]u8 = undefined;
        if (e1000.receive(&rx_buf)) |len| {
            if (len >= 14) {
                net.handleIncoming(rx_buf[0..len]);
            }
        }
        // Check if we got a new TCP connection
        // (simplified: not fully implemented for passive open)
    }

    setErrno(E_TIMEDOUT);
    return null;
}

// ============================================================
// connect()
// ============================================================

/// Connect a socket to a remote address. Returns 0 on success.
pub fn connect_sock(fd: i32, addr: u32, port: u16) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.state == .connected) {
        setErrno(E_ISCONN);
        return E_ISCONN;
    }

    s.remote_addr = .{ .ip = addr, .port = port };

    switch (s.sock_type) {
        SOCK_STREAM => {
            // Assign ephemeral port if not bound
            if (s.local_addr.port == 0) {
                s.local_addr.port = allocEphemeralPort();
            }

            s.state = .connecting;
            const conn = tcp.connect(addr, port, s.local_addr.port) orelse {
                s.state = .created;
                setErrno(E_CONNREFUSED);
                return E_CONNREFUSED;
            };
            s.tcp_conn = conn;
            s.state = .connected;
            return E_SUCCESS;
        },
        SOCK_DGRAM => {
            // UDP "connect" just sets the default remote address
            s.state = .connected;
            return E_SUCCESS;
        },
        else => {
            setErrno(E_OPNOTSUPP);
            return E_OPNOTSUPP;
        },
    }
}

// ============================================================
// send()
// ============================================================

/// Send data on a connected socket. Returns bytes sent or negative error.
pub fn send_data(fd: i32, data: []const u8) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.state != .connected) {
        setErrno(E_NOTCONN);
        return E_NOTCONN;
    }

    switch (s.sock_type) {
        SOCK_STREAM => {
            if (s.tcp_conn) |conn| {
                if (tcp.send(conn, data)) {
                    return @intCast(data.len);
                }
                setErrno(E_TIMEDOUT);
                return E_TIMEDOUT;
            }
            setErrno(E_NOTCONN);
            return E_NOTCONN;
        },
        SOCK_DGRAM => {
            return sendto(fd, data, s.remote_addr.ip, s.remote_addr.port);
        },
        else => {
            setErrno(E_OPNOTSUPP);
            return E_OPNOTSUPP;
        },
    }
}

// ============================================================
// recv()
// ============================================================

/// Receive data from a connected socket. Returns bytes received or negative error.
pub fn recv_data(fd: i32, buf: []u8) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.state != .connected and s.state != .bound) {
        setErrno(E_NOTCONN);
        return E_NOTCONN;
    }

    switch (s.sock_type) {
        SOCK_STREAM => {
            if (s.tcp_conn) |conn| {
                const n = tcp.recv(conn, buf);
                if (n > 0) return @intCast(n);
                setErrno(E_AGAIN);
                return E_AGAIN;
            }
            setErrno(E_NOTCONN);
            return E_NOTCONN;
        },
        SOCK_DGRAM => {
            if (s.udp_sock) |usock| {
                const n = udp.recvFrom(usock, buf);
                if (n > 0) return @intCast(n);
                setErrno(E_AGAIN);
                return E_AGAIN;
            }
            setErrno(E_NOTCONN);
            return E_NOTCONN;
        },
        else => {
            setErrno(E_OPNOTSUPP);
            return E_OPNOTSUPP;
        },
    }
}

// ============================================================
// sendto()
// ============================================================

/// Send data to a specific address (for SOCK_DGRAM).
/// Returns bytes sent or negative error.
pub fn sendto(fd: i32, data: []const u8, addr: u32, port: u16) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.sock_type != SOCK_DGRAM) {
        setErrno(E_OPNOTSUPP);
        return E_OPNOTSUPP;
    }

    if (s.udp_sock) |usock| {
        // Auto-bind if needed
        if (s.state == .created) {
            s.local_addr.port = allocEphemeralPort();
            _ = udp.bind(usock, s.local_addr.port);
            s.state = .bound;
        }

        if (udp.sendTo(usock, addr, port, data)) {
            return @intCast(data.len);
        }
        setErrno(E_NOBUFS);
        return E_NOBUFS;
    }

    setErrno(E_BADF);
    return E_BADF;
}

// ============================================================
// recvfrom()
// ============================================================

/// Receive data and sender address (for SOCK_DGRAM).
pub fn recvfrom(fd: i32, buf: []u8) RecvResult {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return .{ .len = E_BADF, .from = .{ .ip = 0, .port = 0 } };
    };

    if (s.sock_type != SOCK_DGRAM) {
        setErrno(E_OPNOTSUPP);
        return .{ .len = E_OPNOTSUPP, .from = .{ .ip = 0, .port = 0 } };
    }

    if (s.udp_sock) |usock| {
        const n = udp.recvFrom(usock, buf);
        if (n > 0) {
            return .{
                .len = @intCast(n),
                .from = .{ .ip = s.remote_addr.ip, .port = s.remote_addr.port },
            };
        }
        setErrno(E_AGAIN);
        return .{ .len = E_AGAIN, .from = .{ .ip = 0, .port = 0 } };
    }

    setErrno(E_BADF);
    return .{ .len = E_BADF, .from = .{ .ip = 0, .port = 0 } };
}

// ============================================================
// close()
// ============================================================

/// Close a socket and free resources. Returns 0 on success.
pub fn close(fd: i32) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    // Close underlying connections
    if (s.tcp_conn) |conn| {
        tcp.close(conn);
        s.tcp_conn = null;
    }
    if (s.udp_sock) |usock| {
        udp.close(usock);
        s.udp_sock = null;
    }

    s.state = .unused;
    return E_SUCCESS;
}

// ============================================================
// shutdown()
// ============================================================

/// Partially shut down a socket. Returns 0 on success.
pub fn shutdown(fd: i32, how: i32) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    if (s.state != .connected) {
        setErrno(E_NOTCONN);
        return E_NOTCONN;
    }

    switch (how) {
        SHUT_RD, SHUT_WR, SHUT_RDWR => {
            if (how == SHUT_RDWR) {
                return close(fd);
            }
            // Partial shutdown: mark state but keep socket
            return E_SUCCESS;
        },
        else => {
            setErrno(E_INVAL);
            return E_INVAL;
        },
    }
}

// ============================================================
// getpeername() / getsockname()
// ============================================================

/// Get the remote address of a connected socket.
pub fn getpeername(fd: i32) ?SockAddr {
    const s = getSocket(fd) orelse return null;
    if (s.state != .connected) return null;
    return s.remote_addr;
}

/// Get the local address of a socket.
pub fn getsockname(fd: i32) ?SockAddr {
    const s = getSocket(fd) orelse return null;
    if (s.state == .unused) return null;
    return s.local_addr;
}

// ============================================================
// setsockopt() / getsockopt()
// ============================================================

/// Set a socket option. Returns 0 on success.
pub fn setsockopt(fd: i32, option: i32, value: u32) i32 {
    const s = getSocket(fd) orelse {
        setErrno(E_BADF);
        return E_BADF;
    };

    switch (option) {
        SO_REUSEADDR => s.reuse_addr = (value != 0),
        SO_KEEPALIVE => s.keep_alive = (value != 0),
        SO_RCVTIMEO => s.recv_timeout_ms = value,
        else => {
            setErrno(E_INVAL);
            return E_INVAL;
        },
    }

    return E_SUCCESS;
}

/// Get a socket option value.
pub fn getsockopt(fd: i32, option: i32) ?u32 {
    const s = getSocket(fd) orelse return null;

    return switch (option) {
        SO_REUSEADDR => if (s.reuse_addr) @as(u32, 1) else @as(u32, 0),
        SO_KEEPALIVE => if (s.keep_alive) @as(u32, 1) else @as(u32, 0),
        SO_RCVTIMEO => s.recv_timeout_ms,
        else => null,
    };
}

// ============================================================
// Status / debug
// ============================================================

/// Print all open sockets to VGA.
pub fn printSockets() void {
    vga.setColor(.yellow, .black);
    vga.write("Open Sockets:\n");
    vga.setColor(.light_cyan, .black);
    vga.write("  FD  Type    State       Local             Remote\n");
    vga.setColor(.light_grey, .black);

    for (&socket_table, 0..) |*s, i| {
        if (s.state == .unused) continue;

        vga.write("  ");
        net_util.printDec(i);
        if (i < 10) vga.write(" ");
        vga.write("  ");

        // Type
        switch (s.sock_type) {
            SOCK_STREAM => vga.write("TCP     "),
            SOCK_DGRAM => vga.write("UDP     "),
            SOCK_RAW => vga.write("RAW     "),
            else => vga.write("???     "),
        }

        // State
        switch (s.state) {
            .unused => vga.write("UNUSED      "),
            .created => vga.write("CREATED     "),
            .bound => vga.write("BOUND       "),
            .listening => vga.write("LISTENING   "),
            .connecting => vga.write("CONNECTING  "),
            .connected => vga.write("CONNECTED   "),
            .closed => vga.write("CLOSED      "),
        }

        // Local addr
        if (s.local_addr.port != 0) {
            net_util.printIp(s.local_addr.ip);
            vga.putChar(':');
            net_util.printDec(s.local_addr.port);
        } else {
            vga.write("*:*");
        }

        vga.write("  ");

        // Remote addr
        if (s.remote_addr.port != 0) {
            net_util.printIp(s.remote_addr.ip);
            vga.putChar(':');
            net_util.printDec(s.remote_addr.port);
        } else {
            vga.write("*:*");
        }

        vga.putChar('\n');
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn getSocket(fd: i32) ?*Socket {
    if (fd < 0 or fd >= MAX_SOCKETS) return null;
    const idx: usize = @intCast(fd);
    if (socket_table[idx].state == .unused) return null;
    return &socket_table[idx];
}

fn allocEphemeralPort() u16 {
    const port = next_ephemeral;
    next_ephemeral +%= 1;
    if (next_ephemeral < 49152) next_ephemeral = 49152;
    return port;
}
