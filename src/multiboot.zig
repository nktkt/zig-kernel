// Multiboot 1 Information Structure Parser
//
// Parses the Multiboot info structure passed by the bootloader.
// Provides access to memory map, modules, command line, boot device, etc.
// Reference: Multiboot Specification version 0.6.96

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- Multiboot header flags (info->flags bits) ----

pub const FLAG_MEM: u32 = 1 << 0; // mem_lower, mem_upper valid
pub const FLAG_BOOT_DEV: u32 = 1 << 1; // boot_device valid
pub const FLAG_CMDLINE: u32 = 1 << 2; // cmdline valid
pub const FLAG_MODS: u32 = 1 << 3; // mods_count, mods_addr valid
pub const FLAG_AOUT_SYMS: u32 = 1 << 4; // a.out symbol table valid
pub const FLAG_ELF_SHDR: u32 = 1 << 5; // ELF section header table valid
pub const FLAG_MMAP: u32 = 1 << 6; // mmap_length, mmap_addr valid
pub const FLAG_DRIVES: u32 = 1 << 7; // drives_length, drives_addr valid
pub const FLAG_CONFIG: u32 = 1 << 8; // config_table valid
pub const FLAG_LOADER: u32 = 1 << 9; // boot_loader_name valid
pub const FLAG_APM: u32 = 1 << 10; // apm_table valid
pub const FLAG_VBE: u32 = 1 << 11; // VBE info valid
pub const FLAG_FRAMEBUF: u32 = 1 << 12; // framebuffer info valid

// ---- Multiboot info structure ----

pub const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32, // KB of lower memory (starting at 0)
    mem_upper: u32, // KB of upper memory (starting at 1MB)
    boot_device: u32,
    cmdline: u32, // physical address of C string
    mods_count: u32,
    mods_addr: u32, // physical address of module list
    // Union: either a.out or ELF symbols (12 bytes)
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,
    drives_length: u32,
    drives_addr: u32,
    config_table: u32,
    boot_loader_name: u32,
    apm_table: u32,
    // VBE fields
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
    // Framebuffer fields
    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,
};

// ---- Memory map entry ----

pub const MmapEntry = extern struct {
    size: u32, // size of this entry (not including 'size' field itself)
    base_addr_low: u32,
    base_addr_high: u32,
    length_low: u32,
    length_high: u32,
    mem_type: u32,
};

// ---- Memory map types ----

pub const MemType = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    acpi_nvs = 4,
    bad_memory = 5,
    _,
};

pub fn memTypeName(t: u32) []const u8 {
    return switch (t) {
        1 => "Available",
        2 => "Reserved",
        3 => "ACPI Reclaimable",
        4 => "ACPI NVS",
        5 => "Bad Memory",
        else => "Unknown",
    };
}

// ---- Module entry ----

pub const ModuleEntry = extern struct {
    mod_start: u32,
    mod_end: u32,
    cmdline: u32, // physical address of module command line
    padding: u32,
};

// ---- Memory map iterator ----

pub const MmapIterator = struct {
    addr: u32,
    remaining: u32,

    pub fn next(self: *MmapIterator) ?*const MmapEntry {
        if (self.remaining == 0) return null;

        const entry: *const MmapEntry = @ptrFromInt(self.addr);
        const entry_size = entry.size + 4; // +4 for the size field itself

        if (entry_size > self.remaining) {
            self.remaining = 0;
            return null;
        }

        self.addr += entry_size;
        self.remaining -= entry_size;
        return entry;
    }
};

/// Create an iterator over the BIOS memory map.
pub fn iterMemoryMap(info: *const MultibootInfo) ?MmapIterator {
    if (info.flags & FLAG_MMAP == 0) return null;
    if (info.mmap_addr == 0 or info.mmap_length == 0) return null;

    return MmapIterator{
        .addr = info.mmap_addr,
        .remaining = info.mmap_length,
    };
}

/// Count the number of memory map entries.
pub fn countMmapEntries(info: *const MultibootInfo) u32 {
    var iter = iterMemoryMap(info) orelse return 0;
    var count: u32 = 0;
    while (iter.next() != null) : (count += 1) {}
    return count;
}

/// Get total available memory in KB from memory map.
pub fn getTotalAvailableKB(info: *const MultibootInfo) u64 {
    var iter = iterMemoryMap(info) orelse {
        // Fallback to mem_lower + mem_upper
        if (info.flags & FLAG_MEM != 0) {
            return @as(u64, info.mem_lower) + info.mem_upper;
        }
        return 0;
    };

    var total: u64 = 0;
    while (iter.next()) |entry| {
        if (entry.mem_type == 1) { // Available
            const length = @as(u64, entry.length_high) << 32 | entry.length_low;
            total += length / 1024;
        }
    }
    return total;
}

// ---- Command line access ----

/// Get the boot command line as a pointer to a null-terminated string.
pub fn getCmdline(info: *const MultibootInfo) ?[*]const u8 {
    if (info.flags & FLAG_CMDLINE == 0) return null;
    if (info.cmdline == 0) return null;
    return @ptrFromInt(info.cmdline);
}

/// Get command line as a bounded slice (max_len chars).
pub fn getCmdlineSlice(info: *const MultibootInfo, max_len: usize) ?[]const u8 {
    const ptr = getCmdline(info) orelse return null;
    var len: usize = 0;
    while (len < max_len and ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

// ---- Boot loader name ----

pub fn getBootLoaderName(info: *const MultibootInfo) ?[*]const u8 {
    if (info.flags & FLAG_LOADER == 0) return null;
    if (info.boot_loader_name == 0) return null;
    return @ptrFromInt(info.boot_loader_name);
}

pub fn getBootLoaderNameSlice(info: *const MultibootInfo, max_len: usize) ?[]const u8 {
    const ptr = getBootLoaderName(info) orelse return null;
    var len: usize = 0;
    while (len < max_len and ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

// ---- Modules ----

/// Get the module list.
pub fn getModules(info: *const MultibootInfo) ?[]const ModuleEntry {
    if (info.flags & FLAG_MODS == 0) return null;
    if (info.mods_count == 0 or info.mods_addr == 0) return null;

    const ptr: [*]const ModuleEntry = @ptrFromInt(info.mods_addr);
    return ptr[0..info.mods_count];
}

// ---- Boot device parsing ----

pub const BootDevice = struct {
    drive: u8,
    partition1: u8,
    partition2: u8,
    partition3: u8,
};

pub fn getBootDevice(info: *const MultibootInfo) ?BootDevice {
    if (info.flags & FLAG_BOOT_DEV == 0) return null;
    return .{
        .drive = @truncate(info.boot_device >> 24),
        .partition1 = @truncate(info.boot_device >> 16),
        .partition2 = @truncate(info.boot_device >> 8),
        .partition3 = @truncate(info.boot_device),
    };
}

// ---- Print all info ----

pub fn printInfo(mb_addr: u32) void {
    if (mb_addr == 0) {
        vga.write("  No Multiboot info available\n");
        return;
    }

    const info: *const MultibootInfo = @ptrFromInt(mb_addr);

    vga.setColor(.yellow, .black);
    vga.write("Multiboot Information\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Flags: 0x");
    fmt.printHex32(info.flags);
    vga.putChar('\n');

    // Memory info
    if (info.flags & FLAG_MEM != 0) {
        vga.write("  Lower memory: ");
        fmt.printDec(info.mem_lower);
        vga.write(" KB\n");
        vga.write("  Upper memory: ");
        fmt.printDec(info.mem_upper);
        vga.write(" KB (");
        fmt.printDec(info.mem_upper / 1024);
        vga.write(" MB)\n");
    }

    // Boot device
    if (info.flags & FLAG_BOOT_DEV != 0) {
        vga.write("  Boot device: 0x");
        fmt.printHex32(info.boot_device);
        if (getBootDevice(info)) |bd| {
            vga.write(" (drive=0x");
            fmt.printHex8(bd.drive);
            vga.write(" part=");
            fmt.printDec(bd.partition1);
            vga.write(")\n");
        } else {
            vga.putChar('\n');
        }
    }

    // Command line
    if (info.flags & FLAG_CMDLINE != 0) {
        vga.write("  Command line: ");
        if (getCmdlineSlice(info, 60)) |cmd| {
            vga.write(cmd);
        } else {
            vga.write("(none)");
        }
        vga.putChar('\n');
    }

    // Boot loader name
    if (info.flags & FLAG_LOADER != 0) {
        vga.write("  Boot loader: ");
        if (getBootLoaderNameSlice(info, 40)) |name| {
            vga.write(name);
        } else {
            vga.write("(unknown)");
        }
        vga.putChar('\n');
    }

    // Modules
    if (info.flags & FLAG_MODS != 0) {
        vga.write("  Modules: ");
        fmt.printDec(info.mods_count);
        vga.putChar('\n');

        if (getModules(info)) |mods| {
            for (mods, 0..) |mod, i| {
                vga.write("    [");
                fmt.printDec(i);
                vga.write("] 0x");
                fmt.printHex32(mod.mod_start);
                vga.write(" - 0x");
                fmt.printHex32(mod.mod_end);
                vga.write(" (");
                fmt.printDec(mod.mod_end - mod.mod_start);
                vga.write(" bytes)\n");
            }
        }
    }

    // Memory map
    if (info.flags & FLAG_MMAP != 0) {
        vga.write("  Memory map (");
        fmt.printDec(info.mmap_length);
        vga.write(" bytes, ");
        fmt.printDec(countMmapEntries(info));
        vga.write(" entries):\n");

        printMemoryMap(info);
    }

    // Framebuffer
    if (info.flags & FLAG_FRAMEBUF != 0) {
        vga.write("  Framebuffer: ");
        fmt.printDec(info.framebuffer_width);
        vga.putChar('x');
        fmt.printDec(info.framebuffer_height);
        vga.write(" @ ");
        fmt.printDec(info.framebuffer_bpp);
        vga.write("bpp, addr=0x");
        fmt.printHex32(@truncate(info.framebuffer_addr));
        vga.putChar('\n');
    }

    // Total available memory
    const total_kb = getTotalAvailableKB(info);
    if (total_kb > 0) {
        vga.setColor(.light_green, .black);
        vga.write("  Total available: ");
        fmt.printDec(@truncate(total_kb));
        vga.write(" KB (");
        fmt.printDec(@truncate(total_kb / 1024));
        vga.write(" MB)\n");
        vga.setColor(.light_grey, .black);
    }
}

/// Print the BIOS memory map in detail.
pub fn printMemoryMap(info: *const MultibootInfo) void {
    var iter = iterMemoryMap(info) orelse return;
    var idx: u32 = 0;

    while (iter.next()) |entry| {
        const base: u64 = @as(u64, entry.base_addr_high) << 32 | entry.base_addr_low;
        const length: u64 = @as(u64, entry.length_high) << 32 | entry.length_low;
        const end = base + length;

        vga.write("    ");
        fmt.printDec(idx);
        vga.write(": 0x");
        fmt.printHex32(@truncate(base));
        vga.write(" - 0x");
        fmt.printHex32(@truncate(end));
        vga.write(" ");

        // Size
        const kb = length / 1024;
        if (kb >= 1024) {
            fmt.printDec(@truncate(kb / 1024));
            vga.write(" MB  ");
        } else {
            fmt.printDec(@truncate(kb));
            vga.write(" KB  ");
        }

        // Type
        const type_name = memTypeName(entry.mem_type);
        if (entry.mem_type == 1) {
            vga.setColor(.light_green, .black);
        } else {
            vga.setColor(.light_red, .black);
        }
        vga.write(type_name);
        vga.setColor(.light_grey, .black);
        vga.putChar('\n');

        idx += 1;
    }
}
