// Extended ACPI Table Parsing
//
// Provides enumeration and basic parsing of ACPI tables beyond MADT/FADT:
//   DSDT, SSDT, HPET, MCFG, BGRT, SRAT, WAET, DMAR, ECDT, SBST, CPEP,
//   BERT, EINJ, ERST, MSCT, MPST, PMTT, NFIT, PCCT, SLIT, MCHI, UEFI,
//   WDAT, WDDT, WDRT, LPIT, IORT, STAO, XENV, IVRS, CSRT, DBG2, DBGP,
//   FPDT, GTDT, HEST, RASF, SPMI, TCPA, TPM2, WPBT, XSDT.
//
// Does NOT parse AML bytecode in DSDT/SSDT.
// Reference: ACPI Specification 6.4

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- ACPI SDT Header (common to all tables) ----

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

// ---- HPET Table ----

pub const HpetTable = extern struct {
    header: SdtHeader,
    hardware_rev_id: u8,
    comparator_count_and_flags: u8, // bits 4:0 = comparator count, bit 5 = counter size, bit 6 = legacy IRQ
    pci_vendor_id: u16,
    address_space_id: u8, // 0 = memory, 1 = I/O
    register_bit_width: u8,
    register_bit_offset: u8,
    reserved: u8,
    base_address: u64, // HPET base address
    hpet_number: u8,
    minimum_tick: u16,
    page_protection: u8,
};

// ---- MCFG Table (PCI Express Enhanced Configuration) ----

pub const McfgEntry = extern struct {
    base_address: u64,
    segment_group: u16,
    start_bus: u8,
    end_bus: u8,
    reserved: u32,
};

pub const McfgTable = extern struct {
    header: SdtHeader,
    reserved: u64,
    // Followed by McfgEntry array
};

// ---- BGRT Table (Boot Graphics Resource) ----

pub const BgrtTable = extern struct {
    header: SdtHeader,
    version: u16,
    status: u8, // Bit 0: displayed, Bit 1: orientation offset valid
    image_type: u8, // 0 = BMP
    image_address: u64,
    image_offset_x: u32,
    image_offset_y: u32,
};

// ---- SRAT Table (System Resource Affinity) ----

pub const SratHeader = extern struct {
    header: SdtHeader,
    reserved1: u32,
    reserved2: u64,
    // Followed by affinity structures
};

pub const SratProcessorAffinity = extern struct {
    entry_type: u8, // 0x00
    length: u8,
    proximity_domain_lo: u8,
    apic_id: u8,
    flags: u32,
    local_sapic_eid: u8,
    proximity_domain_hi: [3]u8,
    clock_domain: u32,
};

pub const SratMemoryAffinity = extern struct {
    entry_type: u8, // 0x01
    length: u8,
    proximity_domain: u32,
    reserved1: u16,
    base_addr_lo: u32,
    base_addr_hi: u32,
    length_lo: u32,
    length_hi: u32,
    reserved2: u32,
    flags: u32,
    reserved3: u64,
};

// ---- Known table signatures ----

pub const TableSignature = struct {
    sig: [4]u8,
    name: []const u8,
    description: []const u8,
};

pub const known_tables = [_]TableSignature{
    .{ .sig = "APIC".*, .name = "MADT", .description = "Multiple APIC Description Table" },
    .{ .sig = "FACP".*, .name = "FADT", .description = "Fixed ACPI Description Table" },
    .{ .sig = "DSDT".*, .name = "DSDT", .description = "Differentiated System Description Table" },
    .{ .sig = "SSDT".*, .name = "SSDT", .description = "Secondary System Description Table" },
    .{ .sig = "HPET".*, .name = "HPET", .description = "High Precision Event Timer" },
    .{ .sig = "MCFG".*, .name = "MCFG", .description = "PCI Express Memory Mapped Configuration" },
    .{ .sig = "BGRT".*, .name = "BGRT", .description = "Boot Graphics Resource Table" },
    .{ .sig = "SRAT".*, .name = "SRAT", .description = "System Resource Affinity Table" },
    .{ .sig = "SLIT".*, .name = "SLIT", .description = "System Locality Distance Information" },
    .{ .sig = "WAET".*, .name = "WAET", .description = "Windows ACPI Emulated Devices" },
    .{ .sig = "DMAR".*, .name = "DMAR", .description = "DMA Remapping Table" },
    .{ .sig = "ECDT".*, .name = "ECDT", .description = "Embedded Controller Boot Resources" },
    .{ .sig = "SBST".*, .name = "SBST", .description = "Smart Battery Specification Table" },
    .{ .sig = "CPEP".*, .name = "CPEP", .description = "Corrected Platform Error Polling" },
    .{ .sig = "BERT".*, .name = "BERT", .description = "Boot Error Record Table" },
    .{ .sig = "EINJ".*, .name = "EINJ", .description = "Error Injection Table" },
    .{ .sig = "ERST".*, .name = "ERST", .description = "Error Record Serialization Table" },
    .{ .sig = "MSCT".*, .name = "MSCT", .description = "Maximum System Characteristics Table" },
    .{ .sig = "MPST".*, .name = "MPST", .description = "Memory Power State Table" },
    .{ .sig = "PMTT".*, .name = "PMTT", .description = "Platform Memory Topology Table" },
    .{ .sig = "NFIT".*, .name = "NFIT", .description = "NVDIMM Firmware Interface Table" },
    .{ .sig = "PCCT".*, .name = "PCCT", .description = "Platform Communications Channel Table" },
    .{ .sig = "MCHI".*, .name = "MCHI", .description = "Management Controller Host Interface" },
    .{ .sig = "UEFI".*, .name = "UEFI", .description = "UEFI ACPI Data Table" },
    .{ .sig = "WDAT".*, .name = "WDAT", .description = "Watchdog Action Table" },
    .{ .sig = "WDDT".*, .name = "WDDT", .description = "Watchdog Description Table" },
    .{ .sig = "WDRT".*, .name = "WDRT", .description = "Watchdog Resource Table" },
    .{ .sig = "LPIT".*, .name = "LPIT", .description = "Low Power Idle Table" },
    .{ .sig = "IORT".*, .name = "IORT", .description = "I/O Remapping Table" },
    .{ .sig = "STAO".*, .name = "STAO", .description = "Status Override Table" },
    .{ .sig = "XENV".*, .name = "XENV", .description = "Xen Project Table" },
    .{ .sig = "IVRS".*, .name = "IVRS", .description = "I/O Virtualization Reporting Structure" },
    .{ .sig = "CSRT".*, .name = "CSRT", .description = "Core System Resource Table" },
    .{ .sig = "DBG2".*, .name = "DBG2", .description = "Debug Port Table 2" },
    .{ .sig = "DBGP".*, .name = "DBGP", .description = "Debug Port Table" },
    .{ .sig = "FPDT".*, .name = "FPDT", .description = "Firmware Performance Data Table" },
    .{ .sig = "GTDT".*, .name = "GTDT", .description = "Generic Timer Description Table" },
    .{ .sig = "HEST".*, .name = "HEST", .description = "Hardware Error Source Table" },
    .{ .sig = "RASF".*, .name = "RASF", .description = "RAS Feature Table" },
    .{ .sig = "SPMI".*, .name = "SPMI", .description = "Server Platform Management Interface" },
    .{ .sig = "TCPA".*, .name = "TCPA", .description = "Trusted Computing Platform Alliance" },
    .{ .sig = "TPM2".*, .name = "TPM2", .description = "TPM 2.0 Table" },
    .{ .sig = "WPBT".*, .name = "WPBT", .description = "Windows Platform Binary Table" },
    .{ .sig = "XSDT".*, .name = "XSDT", .description = "Extended System Description Table" },
};

// ---- Found table entries ----

pub const FoundTable = struct {
    signature: [4]u8,
    address: u32,
    length: u32,
    revision: u8,
    valid_checksum: bool,
};

const MAX_TABLES = 32;
var found_tables: [MAX_TABLES]FoundTable = @splat(FoundTable{
    .signature = @splat(0),
    .address = 0,
    .length = 0,
    .revision = 0,
    .valid_checksum = false,
});
var table_count: usize = 0;

// HPET parsed data
var hpet_base_addr: u64 = 0;
var hpet_comparators: u8 = 0;
var hpet_min_tick: u16 = 0;
var hpet_found: bool = false;

// MCFG parsed data
var mcfg_base_addr: u64 = 0;
var mcfg_segment: u16 = 0;
var mcfg_start_bus: u8 = 0;
var mcfg_end_bus: u8 = 0;
var mcfg_found: bool = false;

// DSDT info
var dsdt_addr: u32 = 0;
var dsdt_length: u32 = 0;
var dsdt_found: bool = false;

// SSDT count
var ssdt_count: u8 = 0;

// ---- Initialization ----

/// Parse ACPI tables from the RSDT at the given address.
pub fn initFromRsdt(rsdt_addr: u32) void {
    table_count = 0;
    hpet_found = false;
    mcfg_found = false;
    dsdt_found = false;
    ssdt_count = 0;

    if (rsdt_addr == 0 or rsdt_addr >= 0x8000000) return;

    const hdr: *const SdtHeader = @ptrFromInt(rsdt_addr);
    if (hdr.length < @sizeOf(SdtHeader) or hdr.length > 0x10000) return;

    // Verify RSDT signature
    if (!eql4(&hdr.signature, "RSDT")) return;

    const entries_len = (hdr.length - @sizeOf(SdtHeader)) / 4;
    const entries: [*]const u32 = @ptrFromInt(rsdt_addr + @sizeOf(SdtHeader));

    var i: u32 = 0;
    while (i < entries_len and i < 64) : (i += 1) {
        const taddr = entries[i];
        if (taddr == 0 or taddr >= 0x8000000) continue;

        const table_hdr: *const SdtHeader = @ptrFromInt(taddr);
        if (table_hdr.length < @sizeOf(SdtHeader) or table_hdr.length > 0x100000) continue;

        // Record this table
        if (table_count < MAX_TABLES) {
            found_tables[table_count] = .{
                .signature = table_hdr.signature,
                .address = taddr,
                .length = table_hdr.length,
                .revision = table_hdr.revision,
                .valid_checksum = validateChecksum(taddr, table_hdr.length),
            };
            table_count += 1;
        }

        // Parse specific tables
        if (eql4(&table_hdr.signature, "HPET")) {
            parseHpet(taddr);
        } else if (eql4(&table_hdr.signature, "MCFG")) {
            parseMcfg(taddr);
        } else if (eql4(&table_hdr.signature, "SSDT")) {
            ssdt_count += 1;
        }
    }

    // Look for DSDT in FADT
    for (found_tables[0..table_count]) |*t| {
        if (eql4(&t.signature, "FACP")) {
            parseFadtForDsdt(t.address);
            break;
        }
    }

    serial.write("[ACPI-EXT] ");
    serialDec(@truncate(table_count));
    serial.write(" tables found\n");
}

/// Initialize without RSDT (no-op for compatibility).
pub fn init() void {
    table_count = 0;
    hpet_found = false;
    mcfg_found = false;
    dsdt_found = false;
    ssdt_count = 0;
}

// ---- Table-specific parsers ----

fn parseHpet(addr: u32) void {
    if (addr >= 0x8000000) return;
    const hdr: *const SdtHeader = @ptrFromInt(addr);
    if (hdr.length < @sizeOf(HpetTable)) return;

    const hpet: *const HpetTable = @ptrFromInt(addr);
    hpet_base_addr = hpet.base_address;
    hpet_comparators = (hpet.comparator_count_and_flags & 0x1F) + 1;
    hpet_min_tick = hpet.minimum_tick;
    hpet_found = true;

    serial.write("[ACPI-EXT] HPET base=0x");
    serialHex32(@truncate(hpet_base_addr));
    serial.write(" comparators=");
    serialDec(hpet_comparators);
    serial.write("\n");
}

fn parseMcfg(addr: u32) void {
    if (addr >= 0x8000000) return;
    const hdr: *const SdtHeader = @ptrFromInt(addr);
    if (hdr.length < @sizeOf(McfgTable) + @sizeOf(McfgEntry)) return;

    // First entry starts after McfgTable header
    const entry_addr = addr + @sizeOf(McfgTable);
    if (entry_addr >= 0x8000000) return;

    const entry: *const McfgEntry = @ptrFromInt(entry_addr);
    mcfg_base_addr = entry.base_address;
    mcfg_segment = entry.segment_group;
    mcfg_start_bus = entry.start_bus;
    mcfg_end_bus = entry.end_bus;
    mcfg_found = true;

    serial.write("[ACPI-EXT] MCFG base=0x");
    serialHex32(@truncate(mcfg_base_addr));
    serial.write(" bus=");
    serialDec(mcfg_start_bus);
    serial.write("-");
    serialDec(mcfg_end_bus);
    serial.write("\n");
}

fn parseFadtForDsdt(fadt_addr: u32) void {
    if (fadt_addr >= 0x8000000) return;
    const hdr: *const SdtHeader = @ptrFromInt(fadt_addr);
    if (hdr.length < 44) return;

    // DSDT address is at offset 40 in FADT
    const dsdt_ptr: *const u32 align(1) = @ptrFromInt(fadt_addr + 40);
    const addr = dsdt_ptr.*;

    if (addr == 0 or addr >= 0x8000000) return;

    const dsdt_hdr: *const SdtHeader = @ptrFromInt(addr);
    if (!eql4(&dsdt_hdr.signature, "DSDT")) return;
    if (dsdt_hdr.length < @sizeOf(SdtHeader) or dsdt_hdr.length > 0x100000) return;

    dsdt_addr = addr;
    dsdt_length = dsdt_hdr.length;
    dsdt_found = true;

    // Record DSDT in table list
    if (table_count < MAX_TABLES) {
        found_tables[table_count] = .{
            .signature = "DSDT".*,
            .address = addr,
            .length = dsdt_hdr.length,
            .revision = dsdt_hdr.revision,
            .valid_checksum = validateChecksum(addr, dsdt_hdr.length),
        };
        table_count += 1;
    }
}

// ---- Query functions ----

/// Find a table by its 4-character signature. Returns the physical address or null.
pub fn findTable(signature: *const [4]u8) ?u32 {
    for (found_tables[0..table_count]) |*t| {
        if (eql4(&t.signature, signature)) return t.address;
    }
    return null;
}

/// Get the number of found ACPI tables.
pub fn getTableCount() usize {
    return table_count;
}

/// Get a found table entry by index.
pub fn getTable(idx: usize) ?*const FoundTable {
    if (idx >= table_count) return null;
    return &found_tables[idx];
}

/// Get HPET base address. Returns 0 if HPET not found.
pub fn getHpetBase() u64 {
    return hpet_base_addr;
}

/// Get HPET comparator count.
pub fn getHpetComparators() u8 {
    return hpet_comparators;
}

/// Get HPET minimum tick.
pub fn getHpetMinTick() u16 {
    return hpet_min_tick;
}

/// Check if HPET was found.
pub fn isHpetPresent() bool {
    return hpet_found;
}

/// Get MCFG (PCIe) base address. Returns 0 if not found.
pub fn getMcfgBase() u64 {
    return mcfg_base_addr;
}

/// Check if MCFG was found.
pub fn isMcfgPresent() bool {
    return mcfg_found;
}

/// Get DSDT address. Returns 0 if not found.
pub fn getDsdtAddr() u32 {
    return dsdt_addr;
}

/// Check if DSDT was found.
pub fn isDsdtPresent() bool {
    return dsdt_found;
}

/// Get number of SSDTs found.
pub fn getSsdtCount() u8 {
    return ssdt_count;
}

/// Look up a table signature in the known table database.
pub fn lookupSignature(sig: *const [4]u8) ?*const TableSignature {
    for (&known_tables) |*ts| {
        if (eql4(sig, &ts.sig)) return ts;
    }
    return null;
}

// ---- Checksum validation ----

fn validateChecksum(addr: u32, length: u32) bool {
    if (addr >= 0x8000000 or length == 0 or length > 0x100000) return false;
    const bytes: [*]const u8 = @ptrFromInt(addr);
    var sum: u8 = 0;
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        sum +%= bytes[i];
    }
    return sum == 0;
}

// ---- Display functions ----

/// Print all found ACPI tables.
pub fn printAllTables() void {
    vga.setColor(.yellow, .black);
    vga.write("ACPI Tables (");
    printDec(table_count);
    vga.write(" found):\n");
    vga.setColor(.light_grey, .black);

    if (table_count == 0) {
        vga.write("  No tables found\n");
        return;
    }

    vga.write("  SIG   ADDRESS     LENGTH  REV  CHKSUM  DESCRIPTION\n");
    vga.write("  ----------------------------------------------------\n");

    for (found_tables[0..table_count]) |*t| {
        vga.write("  ");
        // Signature
        for (t.signature) |c| {
            if (c >= 0x20 and c < 0x7F) {
                vga.putChar(c);
            } else {
                vga.putChar('?');
            }
        }
        vga.write("  0x");
        printHex32(t.address);
        vga.write("  ");
        printDecPad(t.length, 6);
        vga.write("  ");
        printDecPad(@as(u32, t.revision), 3);
        vga.write("  ");
        if (t.valid_checksum) {
            vga.setColor(.light_green, .black);
            vga.write("OK    ");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("FAIL  ");
        }
        vga.setColor(.light_grey, .black);

        // Look up description
        if (lookupSignature(&t.signature)) |info| {
            vga.write(info.description);
        } else {
            vga.write("Unknown");
        }
        vga.putChar('\n');
    }

    // Summary
    vga.putChar('\n');
    if (hpet_found) {
        vga.write("  HPET: base=0x");
        printHex32(@truncate(hpet_base_addr));
        vga.write(" comparators=");
        printDec8(hpet_comparators);
        vga.write(" min_tick=");
        printDec16(hpet_min_tick);
        vga.putChar('\n');
    }

    if (mcfg_found) {
        vga.write("  MCFG: base=0x");
        printHex32(@truncate(mcfg_base_addr));
        vga.write(" segment=");
        printDec16(mcfg_segment);
        vga.write(" bus=");
        printDec8(mcfg_start_bus);
        vga.write("-");
        printDec8(mcfg_end_bus);
        vga.putChar('\n');
    }

    if (dsdt_found) {
        vga.write("  DSDT: addr=0x");
        printHex32(dsdt_addr);
        vga.write(" length=");
        printDec32(dsdt_length);
        vga.write(" (AML not parsed)\n");
    }

    if (ssdt_count > 0) {
        vga.write("  SSDTs: ");
        printDec8(ssdt_count);
        vga.write(" found\n");
    }
}

/// Print known ACPI table signature database.
pub fn printSignatureDB() void {
    vga.setColor(.yellow, .black);
    vga.write("Known ACPI Table Signatures (");
    printDec(known_tables.len);
    vga.write("):\n");
    vga.setColor(.light_grey, .black);

    for (&known_tables) |*ts| {
        vga.write("  ");
        for (ts.sig) |c| {
            vga.putChar(c);
        }
        vga.write("  ");
        vga.write(ts.name);
        // Pad name to 6 chars
        var pad = 6 -| ts.name.len;
        while (pad > 0) : (pad -= 1) {
            vga.putChar(' ');
        }
        vga.write(ts.description);
        vga.putChar('\n');
    }
}

// ---- Internal helpers ----

fn eql4(a: *const [4]u8, b: *const [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
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
        vga.putChar(buf[len]);
    }
}

fn printDec8(val: u8) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [3]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = '0' + v % 10;
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDec16(val: u16) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [5]u8 = undefined;
    var len: usize = 0;
    var v = val;
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

fn printDec32(val: u32) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = val;
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

fn printDecPad(val: u32, width: usize) void {
    var digits: usize = 0;
    var tmp = val;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    var p = width -| digits;
    while (p > 0) : (p -= 1) {
        vga.putChar(' ');
    }
    printDec32(val);
}

fn serialDec(val: u8) void {
    if (val == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [3]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) {
        buf[len] = '0' + v % 10;
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var v = val;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| serial.putChar(c);
}
