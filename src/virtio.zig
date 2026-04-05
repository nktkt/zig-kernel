// VirtIO device detection and common structures
//
// Scans the PCI bus for VirtIO devices (vendor 0x1AF4, device IDs 0x1000-0x107F)
// and exposes the VirtQueue structure used by all VirtIO device types (network,
// block, console, etc.).

const pci = @import("pci.zig");
const idt = @import("idt.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");

// ---- VirtIO PCI identification ----

pub const VIRTIO_VENDOR: u16 = 0x1AF4;
pub const VIRTIO_DEV_MIN: u16 = 0x1000;
pub const VIRTIO_DEV_MAX: u16 = 0x107F;

// ---- Device type mapping (transitional device IDs) ----

pub const DeviceType = enum(u16) {
    network = 1,
    block = 2,
    console = 3,
    entropy = 4,
    balloon = 5,
    io_memory = 6,
    rpmsg = 7,
    scsi = 8,
    ninep = 9,
    wlan = 10,
    rproc_serial = 11,
    caif = 12,
    gpu = 16,
    input = 18,
    vsock = 19,
    crypto = 20,
    unknown = 0xFFFF,
};

/// Map a PCI device_id to a VirtIO device type.
/// Transitional devices: type = device_id - 0x0FFF
/// Modern devices (>= 0x1040): type = device_id - 0x1040 + 1
pub fn deviceType(device_id: u16) DeviceType {
    if (device_id >= 0x1000 and device_id <= 0x103F) {
        const t = device_id - 0x0FFF;
        return switch (t) {
            1 => .network,
            2 => .block,
            3 => .console,
            4 => .entropy,
            5 => .balloon,
            6 => .io_memory,
            7 => .rpmsg,
            8 => .scsi,
            9 => .ninep,
            10 => .wlan,
            11 => .rproc_serial,
            12 => .caif,
            16 => .gpu,
            18 => .input,
            19 => .vsock,
            20 => .crypto,
            else => .unknown,
        };
    } else if (device_id >= 0x1040 and device_id <= 0x107F) {
        const t = device_id - 0x1040 + 1;
        return switch (t) {
            1 => .network,
            2 => .block,
            3 => .console,
            4 => .entropy,
            else => .unknown,
        };
    }
    return .unknown;
}

pub fn deviceTypeName(dt: DeviceType) []const u8 {
    return switch (dt) {
        .network => "Network",
        .block => "Block",
        .console => "Console",
        .entropy => "Entropy (RNG)",
        .balloon => "Balloon",
        .io_memory => "IO Memory",
        .rpmsg => "Rpmsg",
        .scsi => "SCSI",
        .ninep => "9P Transport",
        .wlan => "WLAN",
        .rproc_serial => "Rproc Serial",
        .caif => "CAIF",
        .gpu => "GPU",
        .input => "Input",
        .vsock => "Vsock",
        .crypto => "Crypto",
        .unknown => "Unknown",
    };
}

// ---- VirtQueue structures (VirtIO spec v1.0 sec 2.4) ----

pub const VIRTQ_DESC_F_NEXT: u16 = 1;
pub const VIRTQ_DESC_F_WRITE: u16 = 2;
pub const VIRTQ_DESC_F_INDIRECT: u16 = 4;

pub const VirtqDesc = extern struct {
    addr: u64, // physical address of buffer
    len: u32, // length of buffer
    flags: u16, // VIRTQ_DESC_F_*
    next: u16, // next descriptor index (if flags & NEXT)
};

pub const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [256]u16, // up to queue_size entries
};

pub const VirtqUsedElem = extern struct {
    id: u32, // index of start of used descriptor chain
    len: u32, // total bytes written to the descriptor chain
};

pub const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [256]VirtqUsedElem,
};

// ---- VirtQueue management ----

pub const QUEUE_SIZE: usize = 256;

pub const VirtQueue = struct {
    desc: ?[*]volatile VirtqDesc = null,
    avail: ?*volatile VirtqAvail = null,
    used: ?*volatile VirtqUsed = null,
    queue_size: u16 = 0,
    free_head: u16 = 0,
    num_free: u16 = 0,
    last_used_idx: u16 = 0,

    /// Initialize a VirtQueue, allocating memory for desc/avail/used.
    /// In a real driver this would use page-aligned DMA memory from PMM.
    pub fn setup(self: *VirtQueue, size: u16) void {
        self.queue_size = size;
        self.free_head = 0;
        self.num_free = size;
        self.last_used_idx = 0;

        // Attempt to allocate a page for descriptors
        if (pmm.alloc()) |page| {
            self.desc = @ptrFromInt(page);
            // Zero the descriptor table
            const desc_bytes: [*]volatile u8 = @ptrFromInt(page);
            for (0..(@as(usize, size) * @sizeOf(VirtqDesc))) |i| {
                desc_bytes[i] = 0;
            }
            // Chain free descriptors
            var i: u16 = 0;
            while (i < size) : (i += 1) {
                if (self.desc) |d| {
                    d[i].next = i + 1;
                }
            }
        }

        // Allocate avail ring
        if (pmm.alloc()) |page| {
            self.avail = @ptrFromInt(page);
            if (self.avail) |a| {
                a.flags = 0;
                a.idx = 0;
            }
        }

        // Allocate used ring
        if (pmm.alloc()) |page| {
            self.used = @ptrFromInt(page);
            if (self.used) |u| {
                u.flags = 0;
                u.idx = 0;
            }
        }

        serial.write("[VIRTIO] Queue setup: size=");
        serial.writeHex(@as(usize, size));
        serial.write("\n");
    }

    /// Return number of free descriptors.
    pub fn freeCount(self: *const VirtQueue) u16 {
        return self.num_free;
    }
};

// ---- Detected devices ----

const MAX_VIRTIO_DEVICES = 8;

pub const VirtioDevice = struct {
    bus: u8 = 0,
    slot: u8 = 0,
    func: u8 = 0,
    device_id: u16 = 0,
    dev_type: DeviceType = .unknown,
    bar0: u32 = 0,
    irq: u8 = 0,
    valid: bool = false,
};

var found_devices: [MAX_VIRTIO_DEVICES]VirtioDevice = [_]VirtioDevice{.{}} ** MAX_VIRTIO_DEVICES;
var found_count: usize = 0;

// ---- Init / Scan ----

/// Scan all PCI devices for VirtIO vendor ID and record them.
pub fn init() void {
    found_count = 0;

    // Walk PCI bus 0 (same approach as pci.zig)
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        scanSlot(0, slot);
    }

    serial.write("[VIRTIO] Found ");
    serial.writeHex(found_count);
    serial.write(" VirtIO device(s)\n");
}

fn scanSlot(bus: u8, slot: u8) void {
    const r0 = pci.readConfig(bus, slot, 0, 0x00);
    const vendor: u16 = @truncate(r0);
    if (vendor != VIRTIO_VENDOR) return;

    const device_id: u16 = @truncate(r0 >> 16);
    if (device_id < VIRTIO_DEV_MIN or device_id > VIRTIO_DEV_MAX) return;

    addDevice(bus, slot, 0, device_id);

    // Check multi-function
    const hdr: u8 = @truncate(pci.readConfig(bus, slot, 0, 0x0C) >> 16);
    if (hdr & 0x80 != 0) {
        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            const v: u16 = @truncate(pci.readConfig(bus, slot, func, 0x00));
            if (v == VIRTIO_VENDOR) {
                const did: u16 = @truncate(pci.readConfig(bus, slot, func, 0x00) >> 16);
                if (did >= VIRTIO_DEV_MIN and did <= VIRTIO_DEV_MAX) {
                    addDevice(bus, slot, func, did);
                }
            }
        }
    }
}

fn addDevice(bus: u8, slot: u8, func: u8, device_id: u16) void {
    if (found_count >= MAX_VIRTIO_DEVICES) return;

    const bar0 = pci.readConfig(bus, slot, func, 0x10);
    const irq_reg = pci.readConfig(bus, slot, func, 0x3C);

    found_devices[found_count] = .{
        .bus = bus,
        .slot = slot,
        .func = func,
        .device_id = device_id,
        .dev_type = deviceType(device_id),
        .bar0 = bar0,
        .irq = @truncate(irq_reg),
        .valid = true,
    };
    found_count += 1;
}

/// Get number of detected VirtIO devices.
pub fn getCount() usize {
    return found_count;
}

/// Get a reference to a detected device by index.
pub fn getDevice(idx: usize) ?*const VirtioDevice {
    if (idx >= found_count) return null;
    return &found_devices[idx];
}

// ---- Display ----

/// Print all detected VirtIO devices.
pub fn printDevices() void {
    vga.setColor(.yellow, .black);
    vga.write("VirtIO Devices (");
    printDec(found_count);
    vga.write("):\n");
    vga.setColor(.light_grey, .black);

    if (found_count == 0) {
        vga.write("  (none detected)\n");
        return;
    }

    vga.write("  BUS:SL.FN  DevID   Type           BAR0       IRQ\n");
    for (found_devices[0..found_count]) |dev| {
        vga.write("  ");
        printHex8(dev.bus);
        vga.putChar(':');
        printHex8(dev.slot);
        vga.putChar('.');
        vga.putChar('0' + dev.func);
        vga.write("    ");
        printHex16(dev.device_id);
        vga.write("  ");
        const name = deviceTypeName(dev.dev_type);
        vga.write(name);
        // Pad to 15 chars
        var pad = 15 -| name.len;
        while (pad > 0) {
            vga.putChar(' ');
            pad -= 1;
        }
        printHex32(dev.bar0);
        vga.write("   ");
        printDec(@as(usize, dev.irq));
        vga.putChar('\n');
    }
}

// ---- Helpers ----

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printHex16(val: u16) void {
    printHex8(@truncate(val >> 8));
    printHex8(@truncate(val));
}

fn printHex32(val: u32) void {
    printHex16(@truncate(val >> 16));
    printHex16(@truncate(val));
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
