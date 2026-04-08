// Network interface management — ifconfig-style interface control
//
// Manages up to 4 network interfaces with per-interface IP, MAC, netmask,
// gateway, MTU, and flags. Includes automatic loopback interface setup.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");
const fmt = @import("fmt.zig");

// ============================================================
// Configuration
// ============================================================

pub const MAX_INTERFACES: usize = 4;
pub const MAX_NAME_LEN: usize = 8;
pub const DEFAULT_MTU: u16 = 1500;
pub const LOOPBACK_MTU: u16 = 65535;

// ============================================================
// Types
// ============================================================

pub const InterfaceFlags = packed struct(u16) {
    up: bool = false,
    running: bool = false,
    promisc: bool = false,
    multicast: bool = false,
    loopback: bool = false,
    broadcast: bool = false,
    _pad: u10 = 0,
};

pub const DriverOps = struct {
    send: ?*const fn ([]const u8) bool = null,
    get_mac: ?*const fn () [6]u8 = null,
    link_up: ?*const fn () bool = null,
};

pub const Interface = struct {
    name: [MAX_NAME_LEN]u8 = @splat(0),
    name_len: u8 = 0,
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    ip: u32 = 0,
    netmask: u32 = 0,
    gateway: u32 = 0,
    broadcast: u32 = 0,
    mtu: u16 = DEFAULT_MTU,
    flags: InterfaceFlags = .{},
    driver: DriverOps = .{},
    active: bool = false,

    // Statistics
    tx_packets: u64 = 0,
    rx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    rx_bytes: u64 = 0,
    tx_errors: u64 = 0,
    rx_errors: u64 = 0,
};

// ============================================================
// State
// ============================================================

var interfaces: [MAX_INTERFACES]Interface = [_]Interface{.{}} ** MAX_INTERFACES;
var iface_count: usize = 0;
var initialized: bool = false;

// ============================================================
// Public API
// ============================================================

/// Initialize the interface manager and create the loopback interface.
pub fn init() void {
    if (initialized) return;
    for (&interfaces) |*iface| {
        iface.active = false;
    }
    iface_count = 0;

    // Create loopback interface
    if (addInterface("lo", .{})) |lo_id| {
        setAddress(lo_id, ipAddr(127, 0, 0, 1), ipAddr(255, 0, 0, 0));
        interfaces[lo_id].mtu = LOOPBACK_MTU;
        interfaces[lo_id].flags.loopback = true;
        interfaces[lo_id].flags.up = true;
        interfaces[lo_id].flags.running = true;
    }

    initialized = true;
}

/// Add a new network interface. Returns the interface ID or null if full.
pub fn addInterface(name: []const u8, driver: DriverOps) ?u8 {
    if (iface_count >= MAX_INTERFACES) return null;
    if (name.len == 0 or name.len > MAX_NAME_LEN) return null;

    // Check for duplicate name
    for (interfaces[0..iface_count]) |*iface| {
        if (iface.active and nameMatch(iface, name)) return null;
    }

    const id: u8 = @intCast(iface_count);
    var iface = &interfaces[iface_count];

    iface.active = true;
    iface.name_len = @intCast(name.len);
    @memcpy(iface.name[0..name.len], name);
    if (name.len < MAX_NAME_LEN) {
        @memset(iface.name[name.len..], 0);
    }
    iface.driver = driver;
    iface.mtu = DEFAULT_MTU;
    iface.flags = .{};

    // Get MAC from driver if available
    if (driver.get_mac) |get_mac_fn| {
        iface.mac = get_mac_fn();
    }

    iface_count += 1;
    serial.write("[NET_IF] added interface: ");
    serial.write(name);
    serial.write("\n");

    return id;
}

/// Set IP address and netmask for an interface.
pub fn setAddress(id: u8, ip: u32, mask: u32) void {
    if (id >= iface_count or !interfaces[id].active) return;
    var iface = &interfaces[id];
    iface.ip = ip;
    iface.netmask = mask;
    // Calculate broadcast address
    iface.broadcast = (ip & mask) | (~mask);
    iface.flags.broadcast = true;
}

/// Set the default gateway for an interface.
pub fn setGateway(id: u8, gw: u32) void {
    if (id >= iface_count or !interfaces[id].active) return;
    interfaces[id].gateway = gw;
}

/// Set the MTU for an interface.
pub fn setMtu(id: u8, mtu: u16) void {
    if (id >= iface_count or !interfaces[id].active) return;
    if (mtu < 68) return; // IPv4 minimum MTU
    interfaces[id].mtu = mtu;
}

/// Set MAC address for an interface.
pub fn setMac(id: u8, mac: [6]u8) void {
    if (id >= iface_count or !interfaces[id].active) return;
    interfaces[id].mac = mac;
}

/// Bring an interface up.
pub fn ifUp(id: u8) void {
    if (id >= iface_count or !interfaces[id].active) return;
    var iface = &interfaces[id];
    iface.flags.up = true;

    // Check link status from driver
    if (iface.driver.link_up) |link_fn| {
        iface.flags.running = link_fn();
    } else {
        iface.flags.running = true;
    }

    serial.write("[NET_IF] ");
    serial.write(iface.name[0..iface.name_len]);
    serial.write(" UP\n");
}

/// Bring an interface down.
pub fn ifDown(id: u8) void {
    if (id >= iface_count or !interfaces[id].active) return;
    var iface = &interfaces[id];
    iface.flags.up = false;
    iface.flags.running = false;

    serial.write("[NET_IF] ");
    serial.write(iface.name[0..iface.name_len]);
    serial.write(" DOWN\n");
}

/// Enable/disable promiscuous mode.
pub fn setPromisc(id: u8, enable: bool) void {
    if (id >= iface_count or !interfaces[id].active) return;
    interfaces[id].flags.promisc = enable;
}

/// Enable/disable multicast.
pub fn setMulticast(id: u8, enable: bool) void {
    if (id >= iface_count or !interfaces[id].active) return;
    interfaces[id].flags.multicast = enable;
}

/// Look up an interface by name.
pub fn getInterface(name: []const u8) ?*Interface {
    for (interfaces[0..iface_count]) |*iface| {
        if (iface.active and nameMatch(iface, name)) {
            return iface;
        }
    }
    return null;
}

/// Get an interface by ID.
pub fn getInterfaceById(id: u8) ?*Interface {
    if (id >= iface_count or !interfaces[id].active) return null;
    return &interfaces[id];
}

/// Check if an interface is up.
pub fn isUp(id: u8) bool {
    if (id >= iface_count or !interfaces[id].active) return false;
    return interfaces[id].flags.up;
}

/// Check if an interface is running (link active).
pub fn isRunning(id: u8) bool {
    if (id >= iface_count or !interfaces[id].active) return false;
    return interfaces[id].flags.running;
}

/// Get the default gateway from the first interface that has one set.
pub fn getDefaultGateway() ?u32 {
    for (interfaces[0..iface_count]) |*iface| {
        if (iface.active and iface.flags.up and iface.gateway != 0) {
            return iface.gateway;
        }
    }
    return null;
}

/// Find which interface should route a given destination IP.
pub fn routeForIp(dest_ip: u32) ?u8 {
    // Check for loopback
    if ((dest_ip >> 24) == 127) {
        for (interfaces[0..iface_count], 0..) |*iface, i| {
            if (iface.active and iface.flags.loopback) {
                return @intCast(i);
            }
        }
    }

    // Check for directly connected networks
    for (interfaces[0..iface_count], 0..) |*iface, i| {
        if (!iface.active or !iface.flags.up or iface.flags.loopback) continue;
        if (iface.netmask != 0 and (dest_ip & iface.netmask) == (iface.ip & iface.netmask)) {
            return @intCast(i);
        }
    }

    // Default: first interface with a gateway
    for (interfaces[0..iface_count], 0..) |*iface, i| {
        if (iface.active and iface.flags.up and iface.gateway != 0) {
            return @intCast(i);
        }
    }

    return null;
}

/// Send a packet through an interface.
pub fn sendPacket(id: u8, data: []const u8) bool {
    if (id >= iface_count or !interfaces[id].active) return false;
    var iface = &interfaces[id];
    if (!iface.flags.up or !iface.flags.running) return false;

    if (iface.driver.send) |send_fn| {
        if (send_fn(data)) {
            iface.tx_packets += 1;
            iface.tx_bytes += data.len;
            return true;
        } else {
            iface.tx_errors += 1;
            return false;
        }
    }

    // Loopback: just count the packet
    if (iface.flags.loopback) {
        iface.tx_packets += 1;
        iface.tx_bytes += data.len;
        iface.rx_packets += 1;
        iface.rx_bytes += data.len;
        return true;
    }

    return false;
}

/// Record a received packet on an interface.
pub fn recordRx(id: u8, bytes: u32) void {
    if (id >= iface_count or !interfaces[id].active) return;
    interfaces[id].rx_packets += 1;
    interfaces[id].rx_bytes += bytes;
}

/// Get the number of interfaces.
pub fn getInterfaceCount() usize {
    return iface_count;
}

// ============================================================
// Display — ifconfig-style output
// ============================================================

/// Print all interface information.
pub fn printInterfaces() void {
    vga.setColor(.yellow, .black);
    vga.write("Network Interfaces:\n\n");
    vga.setColor(.light_grey, .black);

    if (iface_count == 0) {
        vga.write("  No interfaces configured.\n");
        return;
    }

    var i: u8 = 0;
    while (i < iface_count) : (i += 1) {
        if (!interfaces[i].active) continue;
        printOneInterface(&interfaces[i]);
    }
}

fn printOneInterface(iface: *const Interface) void {
    // Interface name and flags
    vga.setColor(.light_green, .black);
    vga.write(iface.name[0..iface.name_len]);
    vga.setColor(.light_grey, .black);
    vga.write(": flags=<");
    printFlags(iface.flags);
    vga.write(">  mtu ");
    printDec(@as(u64, iface.mtu));
    vga.putChar('\n');

    // IP address line
    if (iface.ip != 0) {
        vga.write("        inet ");
        printIp(iface.ip);
        vga.write("  netmask ");
        printIp(iface.netmask);
        if (iface.flags.broadcast and !iface.flags.loopback) {
            vga.write("  broadcast ");
            printIp(iface.broadcast);
        }
        vga.putChar('\n');
    }

    // Gateway line
    if (iface.gateway != 0) {
        vga.write("        gateway ");
        printIp(iface.gateway);
        vga.putChar('\n');
    }

    // MAC address line (not for loopback)
    if (!iface.flags.loopback) {
        vga.write("        ether ");
        printMac(&iface.mac);
        vga.putChar('\n');
    }

    // Packet statistics
    vga.write("        RX packets ");
    printDec(iface.rx_packets);
    vga.write("  bytes ");
    printDec(iface.rx_bytes);
    vga.putChar('\n');
    vga.write("        TX packets ");
    printDec(iface.tx_packets);
    vga.write("  bytes ");
    printDec(iface.tx_bytes);
    vga.putChar('\n');
    if (iface.tx_errors > 0 or iface.rx_errors > 0) {
        vga.write("        errors TX ");
        printDec(iface.tx_errors);
        vga.write("  RX ");
        printDec(iface.rx_errors);
        vga.putChar('\n');
    }
    vga.putChar('\n');
}

fn printFlags(flags: InterfaceFlags) void {
    var count: u32 = 0;
    if (flags.up) {
        if (count > 0) vga.putChar(',');
        vga.write("UP");
        count += 1;
    }
    if (flags.running) {
        if (count > 0) vga.putChar(',');
        vga.write("RUNNING");
        count += 1;
    }
    if (flags.loopback) {
        if (count > 0) vga.putChar(',');
        vga.write("LOOPBACK");
        count += 1;
    }
    if (flags.broadcast) {
        if (count > 0) vga.putChar(',');
        vga.write("BROADCAST");
        count += 1;
    }
    if (flags.multicast) {
        if (count > 0) vga.putChar(',');
        vga.write("MULTICAST");
        count += 1;
    }
    if (flags.promisc) {
        if (count > 0) vga.putChar(',');
        vga.write("PROMISC");
        count += 1;
    }
}

// ============================================================
// Internal helpers
// ============================================================

fn nameMatch(iface: *const Interface, name: []const u8) bool {
    if (iface.name_len != name.len) return false;
    const stored = iface.name[0..iface.name_len];
    for (stored, name) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn ipAddr(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}

fn printIp(ip: u32) void {
    printDec((ip >> 24) & 0xFF);
    vga.putChar('.');
    printDec((ip >> 16) & 0xFF);
    vga.putChar('.');
    printDec((ip >> 8) & 0xFF);
    vga.putChar('.');
    printDec(ip & 0xFF);
}

fn printMac(mac: *const [6]u8) void {
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        if (i > 0) vga.putChar(':');
        vga.putChar(hex[b >> 4]);
        vga.putChar(hex[b & 0xF]);
    }
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
