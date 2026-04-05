// Simple packet filter firewall — rule-based allow/deny/log
//
// Evaluates rules in order (first match wins). Supports per-rule hit
// counters, default policy, and a predefined "basic" firewall rule set.
// Matched packets can be logged to serial for debugging.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const net_util = @import("net_util.zig");
const pit = @import("pit.zig");

// ============================================================
// Actions
// ============================================================

pub const Action = enum(u8) {
    allow,
    deny,
    log_allow, // log and allow
    log_deny, // log and deny
};

// ============================================================
// Direction
// ============================================================

pub const Direction = enum(u8) {
    inbound,
    outbound,
    any,
};

// ============================================================
// Protocol filter
// ============================================================

pub const Protocol = enum(u8) {
    any = 0,
    tcp = 6,
    udp = 17,
    icmp = 1,
};

// ============================================================
// Firewall rule
// ============================================================

pub const Rule = struct {
    action: Action,
    direction: Direction,
    protocol: Protocol,
    src_ip: u32,
    src_mask: u32,
    dst_ip: u32,
    dst_mask: u32,
    src_port: u16, // 0 = any
    dst_port: u16, // 0 = any
    active: bool,
    // Statistics
    hit_count: u64,
    last_hit_tick: u64,
    // Description (optional, for display)
    desc: [32]u8,
    desc_len: usize,
};

// ============================================================
// Rule table
// ============================================================

const MAX_RULES = 32;
var rules: [MAX_RULES]Rule = [_]Rule{.{
    .action = .allow,
    .direction = .any,
    .protocol = .any,
    .src_ip = 0,
    .src_mask = 0,
    .dst_ip = 0,
    .dst_mask = 0,
    .src_port = 0,
    .dst_port = 0,
    .active = false,
    .hit_count = 0,
    .last_hit_tick = 0,
    .desc = undefined,
    .desc_len = 0,
}} ** MAX_RULES;

var rule_count: usize = 0;

// ============================================================
// Default policy
// ============================================================

var default_policy: Action = .allow;

pub fn setDefaultPolicy(action: Action) void {
    default_policy = action;
}

pub fn getDefaultPolicy() Action {
    return default_policy;
}

// ============================================================
// Statistics
// ============================================================

var total_checked: u64 = 0;
var total_allowed: u64 = 0;
var total_denied: u64 = 0;
var total_logged: u64 = 0;

// ============================================================
// Rule management
// ============================================================

/// Add a rule to the firewall. Returns true on success.
pub fn addRule(rule: Rule) bool {
    for (&rules) |*r| {
        if (!r.active) {
            r.* = rule;
            r.active = true;
            r.hit_count = 0;
            r.last_hit_tick = 0;
            rule_count += 1;
            return true;
        }
    }
    return false; // table full
}

/// Add a simple rule with a description.
pub fn addSimpleRule(
    action: Action,
    dir: Direction,
    proto: Protocol,
    src_ip: u32,
    src_mask: u32,
    dst_ip: u32,
    dst_mask: u32,
    src_port: u16,
    dst_port: u16,
    desc: []const u8,
) bool {
    var r = Rule{
        .action = action,
        .direction = dir,
        .protocol = proto,
        .src_ip = src_ip,
        .src_mask = src_mask,
        .dst_ip = dst_ip,
        .dst_mask = dst_mask,
        .src_port = src_port,
        .dst_port = dst_port,
        .active = true,
        .hit_count = 0,
        .last_hit_tick = 0,
        .desc = undefined,
        .desc_len = 0,
    };

    const len = @min(desc.len, 32);
    for (0..len) |i| {
        r.desc[i] = desc[i];
    }
    r.desc_len = len;

    return addRule(r);
}

/// Remove a rule by index. Returns true on success.
pub fn removeRule(index: usize) bool {
    if (index >= MAX_RULES) return false;
    if (!rules[index].active) return false;

    rules[index].active = false;
    rule_count -|= 1;
    return true;
}

/// Clear all rules.
pub fn flushRules() void {
    for (&rules) |*r| {
        r.active = false;
    }
    rule_count = 0;
    total_checked = 0;
    total_allowed = 0;
    total_denied = 0;
    total_logged = 0;
}

/// Move a rule up in priority (swap with the previous active rule).
pub fn moveRuleUp(index: usize) bool {
    if (index == 0 or index >= MAX_RULES) return false;
    if (!rules[index].active) return false;

    // Find previous active rule
    var prev: usize = index;
    while (prev > 0) {
        prev -= 1;
        if (rules[prev].active) {
            // Swap
            const tmp = rules[prev];
            rules[prev] = rules[index];
            rules[index] = tmp;
            return true;
        }
    }
    return false;
}

// ============================================================
// Packet checking
// ============================================================

/// Check a packet against the firewall rules.
/// Returns the action to take (allow or deny).
pub fn checkPacket(
    direction: Direction,
    protocol: Protocol,
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
) Action {
    total_checked += 1;

    for (&rules) |*r| {
        if (!r.active) continue;

        if (matchRule(r, direction, protocol, src_ip, dst_ip, src_port, dst_port)) {
            r.hit_count += 1;
            r.last_hit_tick = pit.getTicks();

            const result = resolveAction(r.action);

            // Log if needed
            if (r.action == .log_allow or r.action == .log_deny) {
                logMatch(r, direction, protocol, src_ip, dst_ip, src_port, dst_port);
                total_logged += 1;
            }

            if (result == .allow or result == .log_allow) {
                total_allowed += 1;
            } else {
                total_denied += 1;
            }

            return result;
        }
    }

    // No rule matched: apply default policy
    if (default_policy == .allow or default_policy == .log_allow) {
        total_allowed += 1;
    } else {
        total_denied += 1;
    }

    return default_policy;
}

fn matchRule(
    r: *const Rule,
    direction: Direction,
    protocol: Protocol,
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
) bool {
    // Direction check
    if (r.direction != .any and r.direction != direction) return false;

    // Protocol check
    if (r.protocol != .any and r.protocol != protocol) return false;

    // Source IP check
    if (r.src_mask != 0) {
        if ((src_ip & r.src_mask) != (r.src_ip & r.src_mask)) return false;
    }

    // Destination IP check
    if (r.dst_mask != 0) {
        if ((dst_ip & r.dst_mask) != (r.dst_ip & r.dst_mask)) return false;
    }

    // Source port check
    if (r.src_port != 0 and src_port != r.src_port) return false;

    // Destination port check
    if (r.dst_port != 0 and dst_port != r.dst_port) return false;

    return true;
}

fn resolveAction(action: Action) Action {
    return switch (action) {
        .allow => .allow,
        .deny => .deny,
        .log_allow => .allow,
        .log_deny => .deny,
    };
}

// ============================================================
// Logging
// ============================================================

fn logMatch(
    r: *const Rule,
    direction: Direction,
    protocol: Protocol,
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
) void {
    serial.write("[FW] ");

    // Action
    switch (r.action) {
        .allow, .log_allow => serial.write("ALLOW "),
        .deny, .log_deny => serial.write("DENY  "),
    }

    // Direction
    switch (direction) {
        .inbound => serial.write("IN  "),
        .outbound => serial.write("OUT "),
        .any => serial.write("ANY "),
    }

    // Protocol
    switch (protocol) {
        .tcp => serial.write("TCP "),
        .udp => serial.write("UDP "),
        .icmp => serial.write("ICMP "),
        .any => serial.write("*   "),
    }

    // Source
    net_util.serialPrintIp(src_ip);
    serial.putChar(':');
    serialPrintDec(src_port);

    serial.write(" -> ");

    // Destination
    net_util.serialPrintIp(dst_ip);
    serial.putChar(':');
    serialPrintDec(dst_port);

    // Description
    if (r.desc_len > 0) {
        serial.write(" [");
        serial.write(r.desc[0..r.desc_len]);
        serial.write("]");
    }

    serial.write("\n");
}

// ============================================================
// Predefined rule sets
// ============================================================

/// Enable a basic firewall: block incoming connections except established,
/// allow all outgoing, allow ICMP.
pub fn enableBasicFirewall() void {
    flushRules();

    // Allow all outbound traffic
    _ = addSimpleRule(.allow, .outbound, .any, 0, 0, 0, 0, 0, 0, "allow outbound");

    // Allow ICMP (both directions)
    _ = addSimpleRule(.allow, .any, .icmp, 0, 0, 0, 0, 0, 0, "allow ICMP");

    // Allow inbound DNS responses (from port 53)
    _ = addSimpleRule(.allow, .inbound, .udp, 0, 0, 0, 0, 53, 0, "allow DNS resp");

    // Allow inbound DHCP
    _ = addSimpleRule(.allow, .inbound, .udp, 0, 0, 0, 0, 67, 0, "allow DHCP");

    // Log and deny all other inbound
    _ = addSimpleRule(.log_deny, .inbound, .any, 0, 0, 0, 0, 0, 0, "deny inbound");

    setDefaultPolicy(.allow);

    serial.write("[FW] basic firewall enabled\n");
}

/// Disable firewall: flush all rules, set default allow.
pub fn disableFirewall() void {
    flushRules();
    setDefaultPolicy(.allow);
    serial.write("[FW] firewall disabled\n");
}

// ============================================================
// Display
// ============================================================

/// Print all firewall rules with hit counts.
pub fn printRules() void {
    vga.setColor(.yellow, .black);
    vga.write("Firewall Rules (");
    net_util.printDec(rule_count);
    vga.write(" active):\n");

    vga.setColor(.light_cyan, .black);
    vga.write("  #  Action  Dir  Proto  Source            Dest              Hits\n");
    vga.setColor(.light_grey, .black);

    var display_idx: usize = 0;
    for (&rules, 0..) |*r, i| {
        if (!r.active) continue;
        _ = i;

        vga.write("  ");
        printDecPadded(display_idx, 2);
        vga.write("  ");

        // Action
        switch (r.action) {
            .allow => {
                vga.setColor(.light_green, .black);
                vga.write("ALLOW ");
            },
            .deny => {
                vga.setColor(.light_red, .black);
                vga.write("DENY  ");
            },
            .log_allow => {
                vga.setColor(.light_green, .black);
                vga.write("LOG+A ");
            },
            .log_deny => {
                vga.setColor(.light_red, .black);
                vga.write("LOG+D ");
            },
        }
        vga.setColor(.light_grey, .black);

        // Direction
        switch (r.direction) {
            .inbound => vga.write(" IN  "),
            .outbound => vga.write(" OUT "),
            .any => vga.write(" ANY "),
        }

        // Protocol
        switch (r.protocol) {
            .tcp => vga.write("  TCP "),
            .udp => vga.write("  UDP "),
            .icmp => vga.write(" ICMP "),
            .any => vga.write("  ANY "),
        }

        // Source
        vga.write(" ");
        if (r.src_mask == 0 and r.src_port == 0) {
            vga.write("*                 ");
        } else {
            printIpPort(r.src_ip, r.src_port, 18);
        }

        // Destination
        if (r.dst_mask == 0 and r.dst_port == 0) {
            vga.write("*                 ");
        } else {
            printIpPort(r.dst_ip, r.dst_port, 18);
        }

        // Hits
        net_util.printDec64(r.hit_count);

        // Description
        if (r.desc_len > 0) {
            vga.setColor(.dark_grey, .black);
            vga.write(" ");
            vga.write(r.desc[0..r.desc_len]);
            vga.setColor(.light_grey, .black);
        }

        vga.putChar('\n');
        display_idx += 1;
    }

    // Default policy
    vga.setColor(.light_cyan, .black);
    vga.write("  Default: ");
    switch (default_policy) {
        .allow, .log_allow => {
            vga.setColor(.light_green, .black);
            vga.write("ALLOW");
        },
        .deny, .log_deny => {
            vga.setColor(.light_red, .black);
            vga.write("DENY");
        },
    }
    vga.putChar('\n');

    // Summary stats
    vga.setColor(.dark_grey, .black);
    vga.write("  Checked: ");
    net_util.printDec64(total_checked);
    vga.write("  Allowed: ");
    net_util.printDec64(total_allowed);
    vga.write("  Denied: ");
    net_util.printDec64(total_denied);
    vga.write("  Logged: ");
    net_util.printDec64(total_logged);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

// ============================================================
// Helpers
// ============================================================

fn printIpPort(ip: u32, port: u16, width: usize) void {
    var buf: [16]u8 = undefined;
    var written: usize = 0;

    if (ip == 0) {
        vga.putChar('*');
        written = 1;
    } else {
        const s = net_util.ipToStr(ip, &buf);
        vga.write(s);
        written = s.len;
    }

    if (port != 0) {
        vga.putChar(':');
        written += 1;
        // Count digits of port
        var digits: usize = 1;
        var tmp: u16 = port;
        while (tmp >= 10) {
            tmp /= 10;
            digits += 1;
        }
        net_util.printDec(port);
        written += digits;
    }

    // Pad
    while (written < width) {
        vga.putChar(' ');
        written += 1;
    }
}

fn printDecPadded(val: usize, width: usize) void {
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

fn serialPrintDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
