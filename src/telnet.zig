// Telnet client/server — RFC 854, RFC 855
//
// Implements the Telnet protocol with IAC command handling,
// option negotiation (ECHO, SGA, terminal type), and NVT line handling.

const tcp = @import("tcp.zig");
const net = @import("net.zig");
const e1000 = @import("e1000.zig");
const pit = @import("pit.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");

// ============================================================
// Telnet constants
// ============================================================

const TELNET_PORT: u16 = 23;

// IAC (Interpret As Command) byte
pub const IAC: u8 = 255;

// Telnet commands
pub const CMD_SE: u8 = 240; // End of subnegotiation
pub const CMD_NOP: u8 = 241; // No operation
pub const CMD_DM: u8 = 242; // Data Mark
pub const CMD_BRK: u8 = 243; // Break
pub const CMD_IP: u8 = 244; // Interrupt Process
pub const CMD_AO: u8 = 245; // Abort Output
pub const CMD_AYT: u8 = 246; // Are You There
pub const CMD_EC: u8 = 247; // Erase Character
pub const CMD_EL: u8 = 248; // Erase Line
pub const CMD_GA: u8 = 249; // Go Ahead
pub const CMD_SB: u8 = 250; // Subnegotiation Begin
pub const CMD_WILL: u8 = 251;
pub const CMD_WONT: u8 = 252;
pub const CMD_DO: u8 = 253;
pub const CMD_DONT: u8 = 254;

// Telnet options
pub const OPT_ECHO: u8 = 1;
pub const OPT_SGA: u8 = 3; // Suppress Go Ahead
pub const OPT_STATUS: u8 = 5;
pub const OPT_TIMING_MARK: u8 = 6;
pub const OPT_TERMINAL_TYPE: u8 = 24;
pub const OPT_WINDOW_SIZE: u8 = 31; // NAWS
pub const OPT_TERMINAL_SPEED: u8 = 32;
pub const OPT_LINEMODE: u8 = 34;

// ============================================================
// Session state
// ============================================================

pub const SessionState = enum(u8) {
    disconnected,
    connecting,
    connected,
    negotiating,
    established,
    closing,
};

// ============================================================
// Option state per session
// ============================================================

pub const OptionState = struct {
    // Local (our) options
    echo_local: bool, // We are echoing
    sga_local: bool, // We suppress go-ahead
    // Remote options
    echo_remote: bool, // Remote echoes
    sga_remote: bool, // Remote suppresses go-ahead
    terminal_type_sent: bool,
};

// ============================================================
// Telnet session
// ============================================================

const INPUT_BUF_SIZE = 512;
const OUTPUT_BUF_SIZE = 512;

pub const TelnetSession = struct {
    conn: ?*tcp.TcpConn,
    state: SessionState,
    remote_ip: u32,
    remote_port: u16,
    local_port: u16,
    options: OptionState,

    // Buffers
    input_buf: [INPUT_BUF_SIZE]u8,
    input_len: usize,
    output_buf: [OUTPUT_BUF_SIZE]u8,
    output_len: usize,

    // IAC parser state
    iac_state: IacParseState,
    iac_cmd: u8,

    // Statistics
    bytes_sent: u32,
    bytes_received: u32,
    commands_received: u32,
    is_server: bool,
};

const IacParseState = enum(u8) {
    normal,
    got_iac,
    got_cmd, // WILL/WONT/DO/DONT — waiting for option byte
    in_sub, // Inside subnegotiation (after SB)
    in_sub_iac, // Got IAC inside subnegotiation
};

// ============================================================
// Session pool
// ============================================================

const MAX_SESSIONS = 4;
var sessions: [MAX_SESSIONS]TelnetSession = undefined;
var sessions_initialized = false;

fn initSessions() void {
    if (sessions_initialized) return;
    for (&sessions) |*s| {
        s.state = .disconnected;
        s.conn = null;
        s.input_len = 0;
        s.output_len = 0;
        s.iac_state = .normal;
        s.bytes_sent = 0;
        s.bytes_received = 0;
        s.commands_received = 0;
        s.is_server = false;
    }
    sessions_initialized = true;
}

fn allocSession() ?*TelnetSession {
    initSessions();
    for (&sessions) |*s| {
        if (s.state == .disconnected) {
            s.input_len = 0;
            s.output_len = 0;
            s.iac_state = .normal;
            s.iac_cmd = 0;
            s.bytes_sent = 0;
            s.bytes_received = 0;
            s.commands_received = 0;
            s.options = .{
                .echo_local = false,
                .sga_local = false,
                .echo_remote = false,
                .sga_remote = false,
                .terminal_type_sent = false,
            };
            return s;
        }
    }
    return null;
}

// ============================================================
// Client: connect
// ============================================================

/// Connect to a Telnet server. Returns a session handle or null.
pub fn connect(ip: u32, port: u16) ?*TelnetSession {
    if (!e1000.isInitialized()) return null;

    const session = allocSession() orelse return null;

    const local_port: u16 = 10023 + @as(u16, @truncate(pit.getTicks() & 0xFF));
    session.remote_ip = ip;
    session.remote_port = port;
    session.local_port = local_port;
    session.state = .connecting;
    session.is_server = false;

    serial.write("[TELNET] connecting to ");
    net_util.serialPrintIp(ip);
    serial.write("\n");

    const conn = tcp.connect(ip, port, local_port) orelse {
        session.state = .disconnected;
        serial.write("[TELNET] TCP connect failed\n");
        return null;
    };

    session.conn = conn;
    session.state = .connected;

    // Initiate negotiation: we want remote to echo, suppress go-ahead
    sendCommand(session, CMD_DO, OPT_ECHO);
    sendCommand(session, CMD_DO, OPT_SGA);
    sendCommand(session, CMD_WILL, OPT_TERMINAL_TYPE);

    session.state = .negotiating;

    // Brief wait for negotiation responses
    const start = pit.getTicks();
    asm volatile ("sti");
    while (pit.getTicks() -| start < 500) {
        pollSession(session);
    }

    session.state = .established;
    serial.write("[TELNET] session established\n");
    return session;
}

// ============================================================
// Server: listen (accept one connection)
// ============================================================

/// Listen for a single incoming Telnet connection on the given port.
/// This is a simplified server that waits for one client.
pub fn listen(port: u16) ?*TelnetSession {
    if (!e1000.isInitialized()) return null;

    const session = allocSession() orelse return null;
    session.remote_ip = 0;
    session.remote_port = 0;
    session.local_port = port;
    session.state = .connecting;
    session.is_server = true;

    serial.write("[TELNET] listening on port ");
    serial.writeHex(port);
    serial.write("\n");

    // In our simple kernel, we poll for incoming TCP connections
    // For now, we just set up and return the session in listening state
    session.state = .negotiating;

    return session;
}

// ============================================================
// Data transfer
// ============================================================

/// Process incoming data: parse IAC commands, store clean data in input buffer.
pub fn processInput(session: *TelnetSession, data: []const u8) void {
    for (data) |byte| {
        session.bytes_received += 1;

        switch (session.iac_state) {
            .normal => {
                if (byte == IAC) {
                    session.iac_state = .got_iac;
                } else {
                    // Normal data: NVT newline handling
                    appendInput(session, byte);
                }
            },
            .got_iac => {
                switch (byte) {
                    IAC => {
                        // Escaped IAC (literal 0xFF)
                        appendInput(session, IAC);
                        session.iac_state = .normal;
                    },
                    CMD_WILL, CMD_WONT, CMD_DO, CMD_DONT => {
                        session.iac_cmd = byte;
                        session.iac_state = .got_cmd;
                    },
                    CMD_SB => {
                        session.iac_state = .in_sub;
                    },
                    CMD_SE => {
                        session.iac_state = .normal;
                    },
                    CMD_NOP, CMD_GA => {
                        session.iac_state = .normal;
                    },
                    CMD_AYT => {
                        // Respond to "Are You There"
                        const resp = [_]u8{ '[', 'Y', 'e', 's', ']', '\r', '\n' };
                        sendRaw(session, &resp);
                        session.iac_state = .normal;
                    },
                    else => {
                        session.commands_received += 1;
                        session.iac_state = .normal;
                    },
                }
            },
            .got_cmd => {
                // byte is the option code
                handleNegotiation(session, session.iac_cmd, byte);
                session.commands_received += 1;
                session.iac_state = .normal;
            },
            .in_sub => {
                if (byte == IAC) {
                    session.iac_state = .in_sub_iac;
                }
                // Otherwise skip subnegotiation data
            },
            .in_sub_iac => {
                if (byte == CMD_SE) {
                    session.iac_state = .normal;
                } else {
                    session.iac_state = .in_sub;
                }
            },
        }
    }
}

/// Send data to the remote end with IAC escaping.
/// Any 0xFF bytes in data are doubled to escape them.
pub fn sendData(session: *TelnetSession, data: []const u8) void {
    if (session.state != .established and session.state != .negotiating) return;

    // Build escaped output
    var out: [OUTPUT_BUF_SIZE]u8 = undefined;
    var pos: usize = 0;

    for (data) |byte| {
        if (byte == IAC) {
            if (pos + 2 > OUTPUT_BUF_SIZE) {
                flushOutput(session, out[0..pos]);
                pos = 0;
            }
            out[pos] = IAC;
            pos += 1;
            out[pos] = IAC;
            pos += 1;
        } else {
            if (pos + 1 > OUTPUT_BUF_SIZE) {
                flushOutput(session, out[0..pos]);
                pos = 0;
            }
            out[pos] = byte;
            pos += 1;
        }
    }

    if (pos > 0) {
        flushOutput(session, out[0..pos]);
    }
}

/// Send data with NVT newline conversion: \n -> \r\n
pub fn sendLine(session: *TelnetSession, data: []const u8) void {
    var out: [OUTPUT_BUF_SIZE]u8 = undefined;
    var pos: usize = 0;

    for (data) |byte| {
        if (byte == '\n') {
            if (pos + 2 > OUTPUT_BUF_SIZE) {
                sendData(session, out[0..pos]);
                pos = 0;
            }
            out[pos] = '\r';
            pos += 1;
            out[pos] = '\n';
            pos += 1;
        } else {
            if (pos + 1 > OUTPUT_BUF_SIZE) {
                sendData(session, out[0..pos]);
                pos = 0;
            }
            out[pos] = byte;
            pos += 1;
        }
    }

    if (pos > 0) {
        sendData(session, out[0..pos]);
    }
}

/// Read available data from the session input buffer.
/// Returns number of bytes copied.
pub fn readInput(session: *TelnetSession, buf: []u8) usize {
    // Poll for new data first
    pollSession(session);

    const len = @min(buf.len, session.input_len);
    if (len == 0) return 0;

    @memcpy(buf[0..len], session.input_buf[0..len]);

    // Shift remaining data
    if (len < session.input_len) {
        var i: usize = 0;
        while (i < session.input_len - len) : (i += 1) {
            session.input_buf[i] = session.input_buf[i + len];
        }
    }
    session.input_len -= len;
    return len;
}

// ============================================================
// Session management
// ============================================================

/// Close a Telnet session.
pub fn closeSession(session: *TelnetSession) void {
    if (session.conn) |conn| {
        session.state = .closing;
        tcp.close(conn);
        session.conn = null;
    }
    session.state = .disconnected;
    serial.write("[TELNET] session closed\n");
}

/// Print session status to VGA.
pub fn printSession(session: *const TelnetSession) void {
    vga.setColor(.yellow, .black);
    vga.write("Telnet Session:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  State:    ");
    switch (session.state) {
        .disconnected => vga.write("DISCONNECTED"),
        .connecting => vga.write("CONNECTING"),
        .connected => vga.write("CONNECTED"),
        .negotiating => vga.write("NEGOTIATING"),
        .established => {
            vga.setColor(.light_green, .black);
            vga.write("ESTABLISHED");
        },
        .closing => vga.write("CLOSING"),
    }
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);

    vga.write("  Role:     ");
    if (session.is_server) vga.write("Server") else vga.write("Client");
    vga.putChar('\n');

    vga.write("  Remote:   ");
    if (session.remote_ip != 0) {
        net_util.printIp(session.remote_ip);
        vga.putChar(':');
        net_util.printDec(session.remote_port);
    } else {
        vga.write("(none)");
    }
    vga.putChar('\n');

    vga.write("  Local:    port ");
    net_util.printDec(session.local_port);
    vga.putChar('\n');

    // Options
    vga.write("  Options:  ");
    if (session.options.echo_remote) vga.write("ECHO ");
    if (session.options.sga_remote) vga.write("SGA ");
    if (session.options.terminal_type_sent) vga.write("TTYPE ");
    vga.putChar('\n');

    // Stats
    vga.write("  TX bytes: ");
    net_util.printDec(session.bytes_sent);
    vga.write("  RX bytes: ");
    net_util.printDec(session.bytes_received);
    vga.putChar('\n');
    vga.write("  Commands: ");
    net_util.printDec(session.commands_received);
    vga.putChar('\n');
    vga.write("  Input buf:");
    net_util.printDec(session.input_len);
    vga.write("/");
    net_util.printDec(INPUT_BUF_SIZE);
    vga.putChar('\n');
}

// ============================================================
// Option negotiation
// ============================================================

fn handleNegotiation(session: *TelnetSession, cmd: u8, option: u8) void {
    switch (cmd) {
        CMD_WILL => {
            // Remote wants to enable an option
            switch (option) {
                OPT_ECHO => {
                    session.options.echo_remote = true;
                    sendCommand(session, CMD_DO, OPT_ECHO);
                },
                OPT_SGA => {
                    session.options.sga_remote = true;
                    sendCommand(session, CMD_DO, OPT_SGA);
                },
                else => {
                    // Refuse unknown options
                    sendCommand(session, CMD_DONT, option);
                },
            }
        },
        CMD_WONT => {
            switch (option) {
                OPT_ECHO => session.options.echo_remote = false,
                OPT_SGA => session.options.sga_remote = false,
                else => {},
            }
        },
        CMD_DO => {
            // Remote asks us to enable an option
            switch (option) {
                OPT_TERMINAL_TYPE => {
                    sendCommand(session, CMD_WILL, OPT_TERMINAL_TYPE);
                    // Send terminal type subnegotiation if asked
                    if (!session.options.terminal_type_sent) {
                        sendTerminalType(session);
                        session.options.terminal_type_sent = true;
                    }
                },
                OPT_SGA => {
                    session.options.sga_local = true;
                    sendCommand(session, CMD_WILL, OPT_SGA);
                },
                OPT_ECHO => {
                    session.options.echo_local = true;
                    sendCommand(session, CMD_WILL, OPT_ECHO);
                },
                else => {
                    sendCommand(session, CMD_WONT, option);
                },
            }
        },
        CMD_DONT => {
            switch (option) {
                OPT_ECHO => session.options.echo_local = false,
                OPT_SGA => session.options.sga_local = false,
                else => {},
            }
        },
        else => {},
    }
}

fn sendCommand(session: *TelnetSession, cmd: u8, option: u8) void {
    const data = [_]u8{ IAC, cmd, option };
    sendRaw(session, &data);
}

fn sendTerminalType(session: *TelnetSession) void {
    // IAC SB TERMINAL-TYPE IS <type> IAC SE
    const terminal = "VT100";
    var buf: [32]u8 = undefined;
    buf[0] = IAC;
    buf[1] = CMD_SB;
    buf[2] = OPT_TERMINAL_TYPE;
    buf[3] = 0; // IS
    for (terminal, 0..) |c, i| {
        buf[4 + i] = c;
    }
    buf[4 + terminal.len] = IAC;
    buf[5 + terminal.len] = CMD_SE;
    sendRaw(session, buf[0 .. 6 + terminal.len]);
}

// ============================================================
// Low-level I/O
// ============================================================

fn sendRaw(session: *TelnetSession, data: []const u8) void {
    if (session.conn) |conn| {
        _ = tcp.send(conn, data);
        session.bytes_sent += @truncate(data.len);
    }
}

fn flushOutput(session: *TelnetSession, data: []const u8) void {
    sendRaw(session, data);
}

fn appendInput(session: *TelnetSession, byte: u8) void {
    if (session.input_len < INPUT_BUF_SIZE) {
        session.input_buf[session.input_len] = byte;
        session.input_len += 1;
    }
}

fn pollSession(session: *TelnetSession) void {
    if (session.conn) |conn| {
        var buf: [256]u8 = undefined;
        const n = tcp.recv(conn, &buf);
        if (n > 0) {
            processInput(session, buf[0..n]);
        }
    }
}
