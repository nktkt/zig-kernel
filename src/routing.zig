// Advanced routing — route table management, longest-prefix match, route cache
//
// Provides a 16-entry routing table with support for connected routes,
// static routes, default routes, route metrics, and a small lookup cache.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net = @import("net.zig");
const net_util = @import("net_util.zig");

// ============================================================
// Route flags
// ============================================================

pub const FLAG_UP: u8 = 0x01; // Route is usable
pub const FLAG_GATEWAY: u8 = 0x02; // Destination is a gateway
pub const FLAG_HOST: u8 = 0x04; // Host route (not network)
pub const FLAG_CONNECTED: u8 = 0x08; // Directly connected network
pub const FLAG_STATIC: u8 = 0x10; // Manually configured

// ============================================================
// Route entry
// ============================================================

pub const Route = struct {
    destination: u32,
    netmask: u32,
    gateway: u32,
    interface_id: u8,
    metric: u16,
    flags: u8,
    active: bool,
    // Statistics
    use_count: u32,
};

const MAX_ROUTES = 16;
var route_table: [MAX_ROUTES]Route = [_]Route{.{
    .destination = 0,
    .netmask = 0,
    .gateway = 0,
    .interface_id = 0,
    .metric = 0,
    .flags = 0,
    .active = false,
    .use_count = 0,
}} ** MAX_ROUTES;

var route_count: usize = 0;

// ============================================================
// Route cache
// ============================================================

const CACHE_SIZE = 8;

const CacheEntry = struct {
    dest_ip: u32,
    route_idx: usize, // index into route_table
    valid: bool,
};

var route_cache: [CACHE_SIZE]CacheEntry = [_]CacheEntry{.{
    .dest_ip = 0,
    .route_idx = 0,
    .valid = false,
}} ** CACHE_SIZE;

var cache_next: usize = 0; // round-robin replacement index
var cache_hits: u32 = 0;
var cache_misses: u32 = 0;

// ============================================================
// Initialization
// ============================================================

pub fn init() void {
    flushRoutes();
    invalidateCache();
}

// ============================================================
// Route management
// ============================================================

/// Add a route to the routing table. Returns true on success.
pub fn addRoute(route: Route) bool {
    // Check for duplicate
    for (&route_table) |*r| {
        if (r.active and r.destination == route.destination and r.netmask == route.netmask) {
            // Update existing route
            r.gateway = route.gateway;
            r.interface_id = route.interface_id;
            r.metric = route.metric;
            r.flags = route.flags;
            invalidateCache();
            return true;
        }
    }

    // Find empty slot
    for (&route_table) |*r| {
        if (!r.active) {
            r.* = route;
            r.active = true;
            r.use_count = 0;
            route_count += 1;
            invalidateCache();
            return true;
        }
    }
    return false; // table full
}

/// Add a simple static route.
pub fn addStaticRoute(dest: u32, mask: u32, gw: u32, metric: u16) bool {
    var flags: u8 = FLAG_UP | FLAG_STATIC;
    if (gw != 0) flags |= FLAG_GATEWAY;
    return addRoute(.{
        .destination = dest & mask,
        .netmask = mask,
        .gateway = gw,
        .interface_id = 0,
        .metric = metric,
        .flags = flags,
        .active = true,
        .use_count = 0,
    });
}

/// Add a connected route (directly attached network).
pub fn addConnectedRoute(network: u32, mask: u32, iface_id: u8) bool {
    return addRoute(.{
        .destination = network & mask,
        .netmask = mask,
        .gateway = 0,
        .interface_id = iface_id,
        .metric = 0,
        .flags = FLAG_UP | FLAG_CONNECTED,
        .active = true,
        .use_count = 0,
    });
}

/// Add a default route (0.0.0.0/0).
pub fn addDefaultRoute(gw: u32, metric: u16) bool {
    return addStaticRoute(0, 0, gw, metric);
}

/// Delete a route matching the given destination and mask.
pub fn delRoute(dest: u32, mask: u32) bool {
    for (&route_table) |*r| {
        if (r.active and r.destination == (dest & mask) and r.netmask == mask) {
            r.active = false;
            route_count -|= 1;
            invalidateCache();
            return true;
        }
    }
    return false;
}

/// Clear all routes.
pub fn flushRoutes() void {
    for (&route_table) |*r| {
        r.active = false;
    }
    route_count = 0;
    invalidateCache();
}

// ============================================================
// Route lookup
// ============================================================

/// Look up the best route for a destination IP using longest prefix match.
/// Uses the route cache for recently looked-up destinations.
pub fn lookup(dest_ip: u32) ?Route {
    // Check cache first
    for (&route_cache) |*ce| {
        if (ce.valid and ce.dest_ip == dest_ip) {
            const idx = ce.route_idx;
            if (idx < MAX_ROUTES and route_table[idx].active) {
                cache_hits += 1;
                route_table[idx].use_count += 1;
                return route_table[idx];
            }
            ce.valid = false; // stale
        }
    }

    cache_misses += 1;

    // Longest prefix match
    var best_idx: ?usize = null;
    var best_prefix: u8 = 0;
    var best_metric: u16 = 0xFFFF;

    for (&route_table, 0..) |*r, i| {
        if (!r.active) continue;
        if ((r.flags & FLAG_UP) == 0) continue;
        if ((dest_ip & r.netmask) == r.destination) {
            const prefix = net_util.maskToCidr(r.netmask);
            if (prefix > best_prefix or (prefix == best_prefix and r.metric < best_metric)) {
                best_idx = i;
                best_prefix = prefix;
                best_metric = r.metric;
            }
        }
    }

    if (best_idx) |idx| {
        route_table[idx].use_count += 1;

        // Add to cache
        route_cache[cache_next] = .{
            .dest_ip = dest_ip,
            .route_idx = idx,
            .valid = true,
        };
        cache_next = (cache_next + 1) % CACHE_SIZE;

        return route_table[idx];
    }

    return null;
}

/// Determine the next-hop IP address for a given destination.
pub fn getNextHop(dest_ip: u32) u32 {
    if (lookup(dest_ip)) |route| {
        if (route.gateway != 0) return route.gateway;
        return dest_ip; // directly connected
    }
    return net.GATEWAY_IP; // fallback
}

// ============================================================
// Route cache management
// ============================================================

fn invalidateCache() void {
    for (&route_cache) |*ce| {
        ce.valid = false;
    }
    cache_hits = 0;
    cache_misses = 0;
    cache_next = 0;
}

// ============================================================
// Trace / debug
// ============================================================

/// Show the route decision path for a destination IP.
pub fn tracePath(dest_ip: u32) void {
    vga.setColor(.yellow, .black);
    vga.write("Route trace for ");
    net_util.printIp(dest_ip);
    vga.write(":\n");
    vga.setColor(.light_grey, .black);

    var match_count: usize = 0;

    for (&route_table, 0..) |*r, i| {
        if (!r.active) continue;
        if ((r.flags & FLAG_UP) == 0) continue;
        if ((dest_ip & r.netmask) != r.destination) continue;

        match_count += 1;
        vga.write("  [");
        net_util.printDec(i);
        vga.write("] ");
        printRouteShort(r);
        vga.putChar('\n');
    }

    if (match_count == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  No matching route found.\n");
        vga.setColor(.light_grey, .black);
        return;
    }

    // Show selected route
    if (lookup(dest_ip)) |route| {
        vga.setColor(.light_green, .black);
        vga.write("  -> Selected: ");
        printRouteShort(&route);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
}

fn printRouteShort(r: *const Route) void {
    net_util.printIp(r.destination);
    vga.putChar('/');
    net_util.printDec(net_util.maskToCidr(r.netmask));
    if (r.gateway != 0) {
        vga.write(" via ");
        net_util.printIp(r.gateway);
    } else {
        vga.write(" direct");
    }
    vga.write(" metric ");
    net_util.printDec(r.metric);

    // Flags
    vga.write(" [");
    if (r.flags & FLAG_UP != 0) vga.putChar('U');
    if (r.flags & FLAG_GATEWAY != 0) vga.putChar('G');
    if (r.flags & FLAG_HOST != 0) vga.putChar('H');
    if (r.flags & FLAG_CONNECTED != 0) vga.putChar('C');
    if (r.flags & FLAG_STATIC != 0) vga.putChar('S');
    vga.putChar(']');
}

// ============================================================
// Display
// ============================================================

/// Print a formatted routing table to VGA.
pub fn printTable() void {
    vga.setColor(.yellow, .black);
    vga.write("Routing Table (");
    net_util.printDec(route_count);
    vga.write(" routes):\n");

    vga.setColor(.light_cyan, .black);
    vga.write("  Destination       Gateway         Mask            Met  Flg  Uses\n");
    vga.setColor(.light_grey, .black);

    for (&route_table) |*r| {
        if (!r.active) continue;

        vga.write("  ");
        printIpPadded(r.destination, 16);
        vga.write("  ");
        if (r.gateway == 0) {
            vga.write("*               ");
        } else {
            printIpPadded(r.gateway, 16);
        }
        vga.write("  ");
        printIpPadded(r.netmask, 16);
        vga.write("  ");
        printDecPadded(r.metric, 3);
        vga.write("  ");

        // Flags
        if (r.flags & FLAG_UP != 0) vga.putChar('U') else vga.putChar('-');
        if (r.flags & FLAG_GATEWAY != 0) vga.putChar('G') else vga.putChar('-');
        if (r.flags & FLAG_HOST != 0) vga.putChar('H') else vga.putChar('-');
        if (r.flags & FLAG_CONNECTED != 0) vga.putChar('C') else vga.putChar('-');

        vga.write("  ");
        net_util.printDec(r.use_count);
        vga.putChar('\n');
    }

    // Cache stats
    vga.setColor(.dark_grey, .black);
    vga.write("  Cache: hits=");
    net_util.printDec(cache_hits);
    vga.write(" misses=");
    net_util.printDec(cache_misses);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

// ============================================================
// Helpers
// ============================================================

fn printIpPadded(ip: u32, width: usize) void {
    var buf: [16]u8 = undefined;
    const s = net_util.ipToStr(ip, &buf);
    vga.write(s);
    var pad = width -| s.len;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
}

fn printDecPadded(val: usize, width: usize) void {
    // Count digits
    var digits: usize = 1;
    var tmp = val;
    while (tmp >= 10) {
        tmp /= 10;
        digits += 1;
    }
    var pad = width -| digits;
    while (pad > 0) {
        vga.putChar(' ');
        pad -= 1;
    }
    net_util.printDec(val);
}
