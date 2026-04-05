// I/O control interface -- IOCTL number encoding/decoding and dispatch
//
// Provides a Linux-compatible IOCTL numbering scheme:
//   bits 31-30: direction (none, read, write, read/write)
//   bits 29-16: data size (14 bits)
//   bits 15-8:  type/magic number (8 bits)
//   bits 7-0:   command number (8 bits)
//
// Includes predefined IOCTLs for TTY, block device, network, and file
// operations, plus a device handler registry for dispatching IOCTLs.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Direction constants ----

pub const IOC_NONE: u2 = 0;
pub const IOC_READ: u2 = 1; // kernel writes / userspace reads
pub const IOC_WRITE: u2 = 2; // userspace writes / kernel reads
pub const IOC_RDWR: u2 = 3; // bidirectional

// ---- IOCTL number construction/deconstruction ----

/// Construct an IOCTL number from components.
/// type_num: 8-bit device type / magic number
/// nr: 8-bit command number
/// dir: 2-bit direction (IOC_NONE, IOC_READ, IOC_WRITE, IOC_RDWR)
/// size: 14-bit data structure size
pub fn makeIoctl(type_num: u8, nr: u8, dir: u2, size: u14) u32 {
    return (@as(u32, dir) << 30) |
        (@as(u32, size) << 16) |
        (@as(u32, type_num) << 8) |
        @as(u32, nr);
}

/// Extract the direction from an IOCTL number.
pub fn iocDir(request: u32) u2 {
    return @truncate(request >> 30);
}

/// Extract the data size from an IOCTL number.
pub fn iocSize(request: u32) u14 {
    return @truncate((request >> 16) & 0x3FFF);
}

/// Extract the type/magic number from an IOCTL number.
pub fn iocType(request: u32) u8 {
    return @truncate((request >> 8) & 0xFF);
}

/// Extract the command number from an IOCTL number.
pub fn iocNr(request: u32) u8 {
    return @truncate(request & 0xFF);
}

// ---- Device types ----

pub const TYPE_TTY: u8 = 'T';
pub const TYPE_BLOCK: u8 = 'B';
pub const TYPE_NET: u8 = 'N';
pub const TYPE_FILE: u8 = 'F';

// ---- Predefined TTY IOCTLs ----

/// Get terminal attributes
pub const TCGETS = makeIoctl(TYPE_TTY, 0x01, IOC_READ, 60);
/// Set terminal attributes
pub const TCSETS = makeIoctl(TYPE_TTY, 0x02, IOC_WRITE, 60);
/// Get window size
pub const TIOCGWINSZ = makeIoctl(TYPE_TTY, 0x03, IOC_READ, 8);
/// Set window size
pub const TIOCSWINSZ = makeIoctl(TYPE_TTY, 0x04, IOC_WRITE, 8);
/// Get process group
pub const TIOCGPGRP = makeIoctl(TYPE_TTY, 0x05, IOC_READ, 4);
/// Set process group
pub const TIOCSPGRP = makeIoctl(TYPE_TTY, 0x06, IOC_WRITE, 4);
/// Get exclusive mode
pub const TIOCEXCL = makeIoctl(TYPE_TTY, 0x07, IOC_NONE, 0);
/// Release exclusive mode
pub const TIOCNXCL = makeIoctl(TYPE_TTY, 0x08, IOC_NONE, 0);

// ---- Predefined Block device IOCTLs ----

/// Get device size (in 512-byte sectors)
pub const BLKGETSIZE = makeIoctl(TYPE_BLOCK, 0x01, IOC_READ, 8);
/// Flush buffer cache
pub const BLKFLSBUF = makeIoctl(TYPE_BLOCK, 0x02, IOC_NONE, 0);
/// Re-read partition table
pub const BLKRRPART = makeIoctl(TYPE_BLOCK, 0x03, IOC_NONE, 0);
/// Get physical block size
pub const BLKBSZGET = makeIoctl(TYPE_BLOCK, 0x04, IOC_READ, 4);
/// Set read-ahead
pub const BLKRASET = makeIoctl(TYPE_BLOCK, 0x05, IOC_WRITE, 4);

// ---- Predefined Network IOCTLs ----

/// Get interface address
pub const SIOCGIFADDR = makeIoctl(TYPE_NET, 0x01, IOC_READ, 32);
/// Set interface address
pub const SIOCSIFADDR = makeIoctl(TYPE_NET, 0x02, IOC_WRITE, 32);
/// Get interface flags
pub const SIOCGIFFLAGS = makeIoctl(TYPE_NET, 0x03, IOC_READ, 32);
/// Set interface flags
pub const SIOCSIFFLAGS = makeIoctl(TYPE_NET, 0x04, IOC_WRITE, 32);
/// Get interface netmask
pub const SIOCGIFNETMASK = makeIoctl(TYPE_NET, 0x05, IOC_READ, 32);
/// Get interface hardware address
pub const SIOCGIFHWADDR = makeIoctl(TYPE_NET, 0x06, IOC_READ, 32);
/// Get routing table
pub const SIOCGRTTAB = makeIoctl(TYPE_NET, 0x07, IOC_READ, 64);

// ---- Predefined File IOCTLs ----

/// Set close-on-exec
pub const FIOCLEX = makeIoctl(TYPE_FILE, 0x01, IOC_NONE, 0);
/// Clear close-on-exec
pub const FIONCLEX = makeIoctl(TYPE_FILE, 0x02, IOC_NONE, 0);
/// Get number of bytes ready to read
pub const FIONREAD = makeIoctl(TYPE_FILE, 0x03, IOC_READ, 4);
/// Set non-blocking
pub const FIONBIO = makeIoctl(TYPE_FILE, 0x04, IOC_WRITE, 4);
/// Set async notification
pub const FIOASYNC = makeIoctl(TYPE_FILE, 0x05, IOC_WRITE, 4);

// ---- Handler registry ----

pub const MAX_HANDLERS = 16;

/// Handler function: takes fd, request, arg. Returns result code.
pub const HandlerFn = *const fn (i32, u32, u32) i32;

const HandlerEntry = struct {
    active: bool,
    device_type: u8,
    handler: ?HandlerFn,
    name: [16]u8,
    name_len: u8,
};

var handlers: [MAX_HANDLERS]HandlerEntry = undefined;
var handler_count: u8 = 0;
var initialized: bool = false;

// Error codes
pub const ENOTTY: i32 = -25; // Inappropriate ioctl for device
pub const EINVAL: i32 = -22; // Invalid argument
pub const ENODEV: i32 = -19; // No such device

// ---- Initialization ----

pub fn init() void {
    for (&handlers) |*h| {
        h.active = false;
        h.device_type = 0;
        h.handler = null;
        h.name_len = 0;
        for (&h.name) |*c| c.* = 0;
    }
    handler_count = 0;
    initialized = true;
    serial.write("[ioctl] I/O control interface initialized\n");
}

// ---- Handler registration ----

/// Register a handler for a device type.
pub fn registerHandler(device_type: u8, name: []const u8, handler: HandlerFn) bool {
    if (!initialized) return false;
    if (handler_count >= MAX_HANDLERS) return false;

    // Check for duplicate
    for (&handlers) |*h| {
        if (h.active and h.device_type == device_type) return false;
    }

    for (&handlers) |*h| {
        if (!h.active) {
            h.active = true;
            h.device_type = device_type;
            h.handler = handler;
            const copy_len = if (name.len > 16) 16 else name.len;
            for (0..copy_len) |i| {
                h.name[i] = name[i];
            }
            var i: usize = copy_len;
            while (i < 16) : (i += 1) h.name[i] = 0;
            h.name_len = @truncate(copy_len);
            handler_count += 1;
            return true;
        }
    }
    return false;
}

/// Unregister a handler for a device type.
pub fn unregisterHandler(device_type: u8) bool {
    if (!initialized) return false;
    for (&handlers) |*h| {
        if (h.active and h.device_type == device_type) {
            h.active = false;
            handler_count -= 1;
            return true;
        }
    }
    return false;
}

// ---- Dispatch ----

/// Dispatch an IOCTL request to the appropriate device handler.
/// The device type is inferred from the IOCTL number's type field.
/// Returns the handler's result, or ENOTTY if no handler found.
pub fn dispatch(fd: i32, request: u32, arg: u32) i32 {
    if (!initialized) return ENODEV;

    const dev_type = iocType(request);

    for (&handlers) |*h| {
        if (h.active and h.device_type == dev_type) {
            if (h.handler) |handler_fn| {
                return handler_fn(fd, request, arg);
            }
        }
    }

    return ENOTTY;
}

// ---- Debug / Display ----

/// Get a human-readable name for a known IOCTL request.
pub fn ioctlName(request: u32) []const u8 {
    // TTY IOCTLs
    if (request == TCGETS) return "TCGETS";
    if (request == TCSETS) return "TCSETS";
    if (request == TIOCGWINSZ) return "TIOCGWINSZ";
    if (request == TIOCSWINSZ) return "TIOCSWINSZ";
    if (request == TIOCGPGRP) return "TIOCGPGRP";
    if (request == TIOCSPGRP) return "TIOCSPGRP";
    if (request == TIOCEXCL) return "TIOCEXCL";
    if (request == TIOCNXCL) return "TIOCNXCL";

    // Block IOCTLs
    if (request == BLKGETSIZE) return "BLKGETSIZE";
    if (request == BLKFLSBUF) return "BLKFLSBUF";
    if (request == BLKRRPART) return "BLKRRPART";
    if (request == BLKBSZGET) return "BLKBSZGET";
    if (request == BLKRASET) return "BLKRASET";

    // Network IOCTLs
    if (request == SIOCGIFADDR) return "SIOCGIFADDR";
    if (request == SIOCSIFADDR) return "SIOCSIFADDR";
    if (request == SIOCGIFFLAGS) return "SIOCGIFFLAGS";
    if (request == SIOCSIFFLAGS) return "SIOCSIFFLAGS";
    if (request == SIOCGIFNETMASK) return "SIOCGIFNETMASK";
    if (request == SIOCGIFHWADDR) return "SIOCGIFHWADDR";
    if (request == SIOCGRTTAB) return "SIOCGRTTAB";

    // File IOCTLs
    if (request == FIOCLEX) return "FIOCLEX";
    if (request == FIONCLEX) return "FIONCLEX";
    if (request == FIONREAD) return "FIONREAD";
    if (request == FIONBIO) return "FIONBIO";
    if (request == FIOASYNC) return "FIOASYNC";

    return "UNKNOWN";
}

/// Print detailed information about an IOCTL number.
pub fn printIoctlInfo(request: u32) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== IOCTL Info ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Request: 0x");
    fmt.printHex32(request);
    vga.putChar('\n');

    vga.write("Name:    ");
    vga.setColor(.white, .black);
    vga.write(ioctlName(request));
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);

    vga.write("Dir:     ");
    const dir = iocDir(request);
    switch (dir) {
        IOC_NONE => vga.write("NONE"),
        IOC_READ => vga.write("READ"),
        IOC_WRITE => vga.write("WRITE"),
        IOC_RDWR => vga.write("READ/WRITE"),
    }
    vga.putChar('\n');

    vga.write("Type:    0x");
    fmt.printHex8(iocType(request));
    vga.write(" ('");
    const t = iocType(request);
    if (t >= 0x20 and t < 0x7F) {
        vga.putChar(t);
    } else {
        vga.putChar('?');
    }
    vga.write("')\n");

    vga.write("Number:  ");
    fmt.printDec(@as(usize, iocNr(request)));
    vga.putChar('\n');

    vga.write("Size:    ");
    fmt.printDec(@as(usize, iocSize(request)));
    vga.write(" bytes\n");
}

/// Print all registered handlers.
pub fn printHandlers() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== IOCTL Handlers ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  Type  Name\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    for (&handlers) |*h| {
        if (!h.active) continue;
        any = true;
        vga.write("  0x");
        fmt.printHex8(h.device_type);
        vga.write("  ");
        if (h.name_len > 0) {
            vga.write(h.name[0..h.name_len]);
        } else {
            vga.write("(unnamed)");
        }
        vga.putChar('\n');
    }
    if (!any) {
        vga.write("  (no handlers registered)\n");
    }
}

/// Print a summary of all defined IOCTLs.
pub fn printAllIoctls() void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Defined IOCTLs ===\n");
    vga.setColor(.light_grey, .black);

    const items = [_]struct { name: []const u8, val: u32 }{
        .{ .name = "TCGETS", .val = TCGETS },
        .{ .name = "TCSETS", .val = TCSETS },
        .{ .name = "TIOCGWINSZ", .val = TIOCGWINSZ },
        .{ .name = "TIOCSWINSZ", .val = TIOCSWINSZ },
        .{ .name = "BLKGETSIZE", .val = BLKGETSIZE },
        .{ .name = "BLKFLSBUF", .val = BLKFLSBUF },
        .{ .name = "BLKRRPART", .val = BLKRRPART },
        .{ .name = "SIOCGIFADDR", .val = SIOCGIFADDR },
        .{ .name = "SIOCSIFADDR", .val = SIOCSIFADDR },
        .{ .name = "SIOCGIFFLAGS", .val = SIOCGIFFLAGS },
        .{ .name = "FIOCLEX", .val = FIOCLEX },
        .{ .name = "FIONCLEX", .val = FIONCLEX },
        .{ .name = "FIONREAD", .val = FIONREAD },
    };

    for (items) |item| {
        vga.write("  ");
        var printed: usize = 0;
        for (item.name) |_| printed += 1;
        vga.write(item.name);
        while (printed < 16) : (printed += 1) vga.putChar(' ');
        vga.write("0x");
        fmt.printHex32(item.val);
        vga.putChar('\n');
    }
}
