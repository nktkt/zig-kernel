// ELF32 parser -- complete section, symbol, and relocation parsing
//
// Parses ELF32 headers, section headers, program headers, symbol tables,
// and string tables from raw byte data. Supports lookups by name and
// formatted display of all ELF structures. Designed for kernel-level
// introspection of loaded ELF images.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- ELF constants ----

pub const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };
pub const ELFCLASS32 = 1;
pub const ELFDATA2LSB = 1;
pub const ET_NONE = 0;
pub const ET_REL = 1;
pub const ET_EXEC = 2;
pub const ET_DYN = 3;
pub const ET_CORE = 4;
pub const EM_386 = 3;
pub const EV_CURRENT = 1;

// Section types
pub const SHT_NULL = 0;
pub const SHT_PROGBITS = 1;
pub const SHT_SYMTAB = 2;
pub const SHT_STRTAB = 3;
pub const SHT_RELA = 4;
pub const SHT_HASH = 5;
pub const SHT_DYNAMIC = 6;
pub const SHT_NOTE = 7;
pub const SHT_NOBITS = 8;
pub const SHT_REL = 9;
pub const SHT_DYNSYM = 11;

// Section flags
pub const SHF_WRITE = 0x1;
pub const SHF_ALLOC = 0x2;
pub const SHF_EXECINSTR = 0x4;

// Symbol binding
pub const STB_LOCAL = 0;
pub const STB_GLOBAL = 1;
pub const STB_WEAK = 2;

// Symbol type
pub const STT_NOTYPE = 0;
pub const STT_OBJECT = 1;
pub const STT_FUNC = 2;
pub const STT_SECTION = 3;
pub const STT_FILE = 4;

// Program header types
pub const PT_NULL = 0;
pub const PT_LOAD = 1;
pub const PT_DYNAMIC = 2;
pub const PT_INTERP = 3;
pub const PT_NOTE = 4;
pub const PT_SHLIB = 5;
pub const PT_PHDR = 6;

// Program header flags
pub const PF_X = 0x1;
pub const PF_W = 0x2;
pub const PF_R = 0x4;

// ---- Limits ----

pub const MAX_SECTIONS = 16;
pub const MAX_SYMBOLS = 32;
pub const MAX_PHDRS = 8;
pub const MAX_NAME_LEN = 32;

// ---- Types ----

pub const Section = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    sh_type: u32,
    flags: u32,
    addr: u32,
    offset: u32,
    size: u32,
    link: u32,
    info: u32,
    addralign: u32,
    entsize: u32,
};

pub const Symbol = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    value: u32,
    size: u32,
    info: u8, // binding (high 4) | type (low 4)
    other: u8,
    shndx: u16,

    pub fn binding(self: *const Symbol) u8 {
        return self.info >> 4;
    }

    pub fn symType(self: *const Symbol) u8 {
        return self.info & 0xF;
    }
};

pub const ProgramHeader = struct {
    ph_type: u32,
    offset: u32,
    vaddr: u32,
    paddr: u32,
    filesz: u32,
    memsz: u32,
    flags: u32,
    align_val: u32,
};

pub const ElfInfo = struct {
    // ELF header fields
    elf_class: u8,
    data_encoding: u8,
    elf_type: u16,
    machine: u16,
    version: u32,
    entry: u32,
    ph_offset: u32,
    sh_offset: u32,
    flags: u32,
    eh_size: u16,
    ph_entsize: u16,
    ph_num: u16,
    sh_entsize: u16,
    sh_num: u16,
    sh_strndx: u16,

    // Parsed sections
    sections: [MAX_SECTIONS]Section,
    section_count: u8,

    // Parsed symbols
    symbols: [MAX_SYMBOLS]Symbol,
    symbol_count: u8,

    // Parsed program headers
    program_headers: [MAX_PHDRS]ProgramHeader,
    phdr_count: u8,

    // Validity flag
    valid: bool,
};

// ---- Parsing ----

/// Parse an ELF32 file from raw data. Returns null if invalid.
pub fn parseElf(data: []const u8) ?ElfInfo {
    var info: ElfInfo = undefined;
    info.valid = false;
    info.section_count = 0;
    info.symbol_count = 0;
    info.phdr_count = 0;

    // Need at least ELF header (52 bytes)
    if (data.len < 52) return null;

    // Verify magic
    if (data[0] != ELF_MAGIC[0] or data[1] != ELF_MAGIC[1] or
        data[2] != ELF_MAGIC[2] or data[3] != ELF_MAGIC[3])
    {
        return null;
    }

    // Only ELF32 little-endian supported
    info.elf_class = data[4];
    if (info.elf_class != ELFCLASS32) return null;

    info.data_encoding = data[5];
    if (info.data_encoding != ELFDATA2LSB) return null;

    // ELF header fields
    info.elf_type = readU16(data, 16);
    info.machine = readU16(data, 18);
    info.version = readU32(data, 20);
    info.entry = readU32(data, 24);
    info.ph_offset = readU32(data, 28);
    info.sh_offset = readU32(data, 32);
    info.flags = readU32(data, 36);
    info.eh_size = readU16(data, 40);
    info.ph_entsize = readU16(data, 42);
    info.ph_num = readU16(data, 44);
    info.sh_entsize = readU16(data, 46);
    info.sh_num = readU16(data, 48);
    info.sh_strndx = readU16(data, 50);

    // Parse program headers
    parseProgramHeaders(data, &info);

    // Parse section headers
    parseSectionHeaders(data, &info);

    // Resolve section names from shstrtab
    resolveSectionNames(data, &info);

    // Parse symbol tables
    parseSymbolTables(data, &info);

    info.valid = true;
    return info;
}

fn parseProgramHeaders(data: []const u8, info: *ElfInfo) void {
    if (info.ph_offset == 0 or info.ph_num == 0) return;

    var i: u16 = 0;
    while (i < info.ph_num and info.phdr_count < MAX_PHDRS) : (i += 1) {
        const off: usize = info.ph_offset + @as(usize, i) * @as(usize, info.ph_entsize);
        if (off + 32 > data.len) break;

        const idx = info.phdr_count;
        info.program_headers[idx] = .{
            .ph_type = readU32(data, off),
            .offset = readU32(data, off + 4),
            .vaddr = readU32(data, off + 8),
            .paddr = readU32(data, off + 12),
            .filesz = readU32(data, off + 16),
            .memsz = readU32(data, off + 20),
            .flags = readU32(data, off + 24),
            .align_val = readU32(data, off + 28),
        };
        info.phdr_count += 1;
    }
}

fn parseSectionHeaders(data: []const u8, info: *ElfInfo) void {
    if (info.sh_offset == 0 or info.sh_num == 0) return;

    var i: u16 = 0;
    while (i < info.sh_num and info.section_count < MAX_SECTIONS) : (i += 1) {
        const off: usize = info.sh_offset + @as(usize, i) * @as(usize, info.sh_entsize);
        if (off + 40 > data.len) break;

        const idx = info.section_count;
        info.sections[idx] = .{
            .name = [_]u8{0} ** MAX_NAME_LEN,
            .name_len = 0,
            .sh_type = readU32(data, off + 4),
            .flags = readU32(data, off + 8),
            .addr = readU32(data, off + 12),
            .offset = readU32(data, off + 16),
            .size = readU32(data, off + 20),
            .link = readU32(data, off + 24),
            .info = readU32(data, off + 28),
            .addralign = readU32(data, off + 32),
            .entsize = readU32(data, off + 36),
        };
        // Store name index temporarily in name[0..4] (will resolve later)
        const name_idx = readU32(data, off);
        info.sections[idx].name[0] = @truncate(name_idx);
        info.sections[idx].name[1] = @truncate(name_idx >> 8);
        info.sections[idx].name[2] = @truncate(name_idx >> 16);
        info.sections[idx].name[3] = @truncate(name_idx >> 24);
        info.section_count += 1;
    }
}

fn resolveSectionNames(data: []const u8, info: *ElfInfo) void {
    if (info.sh_strndx == 0 or info.sh_strndx >= info.section_count) return;

    const strtab_sec = &info.sections[info.sh_strndx];
    const strtab_off: usize = strtab_sec.offset;
    const strtab_size: usize = strtab_sec.size;

    if (strtab_off + strtab_size > data.len) return;

    var i: u8 = 0;
    while (i < info.section_count) : (i += 1) {
        const sec = &info.sections[i];
        // Recover name index from temp storage
        const name_idx: usize = @as(usize, sec.name[0]) |
            (@as(usize, sec.name[1]) << 8) |
            (@as(usize, sec.name[2]) << 16) |
            (@as(usize, sec.name[3]) << 24);

        // Clear name buffer
        for (&sec.name) |*b| b.* = 0;
        sec.name_len = 0;

        if (name_idx < strtab_size) {
            var j: usize = 0;
            while (j < MAX_NAME_LEN - 1 and (name_idx + j) < strtab_size) : (j += 1) {
                const c = data[strtab_off + name_idx + j];
                if (c == 0) break;
                sec.name[j] = c;
                sec.name_len += 1;
            }
        }
    }
}

fn parseSymbolTables(data: []const u8, info: *ElfInfo) void {
    // Find SYMTAB or DYNSYM sections
    var i: u8 = 0;
    while (i < info.section_count) : (i += 1) {
        const sec = &info.sections[i];
        if (sec.sh_type != SHT_SYMTAB and sec.sh_type != SHT_DYNSYM) continue;
        if (sec.entsize == 0) continue;

        // The linked section is the string table for symbol names
        const strtab_idx: usize = sec.link;
        var str_off: usize = 0;
        var str_size: usize = 0;
        if (strtab_idx < info.section_count) {
            str_off = info.sections[strtab_idx].offset;
            str_size = info.sections[strtab_idx].size;
        }

        // Parse each symbol entry (16 bytes for ELF32)
        const sym_off: usize = sec.offset;
        const sym_count: usize = sec.size / sec.entsize;

        var j: usize = 0;
        while (j < sym_count and info.symbol_count < MAX_SYMBOLS) : (j += 1) {
            const soff = sym_off + j * sec.entsize;
            if (soff + 16 > data.len) break;

            const name_idx: usize = readU32(data, soff);
            const sym_value = readU32(data, soff + 4);
            const sym_size = readU32(data, soff + 8);
            const sym_info_byte = data[soff + 12];
            const sym_other = data[soff + 13];
            const sym_shndx = readU16(data, soff + 14);

            const idx = info.symbol_count;
            info.symbols[idx] = .{
                .name = [_]u8{0} ** MAX_NAME_LEN,
                .name_len = 0,
                .value = sym_value,
                .size = sym_size,
                .info = sym_info_byte,
                .other = sym_other,
                .shndx = sym_shndx,
            };

            // Resolve symbol name from string table
            if (name_idx > 0 and name_idx < str_size and str_off + str_size <= data.len) {
                var k: usize = 0;
                while (k < MAX_NAME_LEN - 1 and (name_idx + k) < str_size) : (k += 1) {
                    const c = data[str_off + name_idx + k];
                    if (c == 0) break;
                    info.symbols[idx].name[k] = c;
                    info.symbols[idx].name_len += 1;
                }
            }

            info.symbol_count += 1;
        }
    }
}

// ---- Lookup functions ----

/// Find a symbol by name. Returns pointer to symbol or null.
pub fn findSymbol(info: *const ElfInfo, name: []const u8) ?*const Symbol {
    var i: u8 = 0;
    while (i < info.symbol_count) : (i += 1) {
        const sym = &info.symbols[i];
        if (sym.name_len == 0) continue;
        if (sym.name_len != name.len) {
            i += 1 - 1; // just continue
            continue;
        }
        if (strEq(sym.name[0..sym.name_len], name)) {
            return sym;
        }
    }
    return null;
}

/// Find a section by name. Returns pointer to section or null.
pub fn getSectionByName(info: *const ElfInfo, name: []const u8) ?*const Section {
    var i: u8 = 0;
    while (i < info.section_count) : (i += 1) {
        const sec = &info.sections[i];
        if (sec.name_len == 0) continue;
        if (sec.name_len != name.len) continue;
        if (strEq(sec.name[0..sec.name_len], name)) {
            return sec;
        }
    }
    return null;
}

/// Get section by index.
pub fn getSectionByIndex(info: *const ElfInfo, idx: u8) ?*const Section {
    if (idx >= info.section_count) return null;
    return &info.sections[idx];
}

/// Get symbol by index.
pub fn getSymbolByIndex(info: *const ElfInfo, idx: u8) ?*const Symbol {
    if (idx >= info.symbol_count) return null;
    return &info.symbols[idx];
}

// ---- Display functions ----

/// Print ELF header information.
pub fn printHeaders(info: *const ElfInfo) void {
    if (!info.valid) {
        vga.write("Invalid ELF\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== ELF Header ===\n");
    vga.setColor(.light_grey, .black);

    vga.write("Class:       ");
    vga.write(if (info.elf_class == ELFCLASS32) "ELF32" else "unknown");
    vga.putChar('\n');

    vga.write("Data:        ");
    vga.write(if (info.data_encoding == ELFDATA2LSB) "Little Endian" else "unknown");
    vga.putChar('\n');

    vga.write("Type:        ");
    printElfType(info.elf_type);
    vga.putChar('\n');

    vga.write("Machine:     ");
    if (info.machine == EM_386) {
        vga.write("Intel 80386");
    } else {
        vga.write("0x");
        fmt.printHex16(info.machine);
    }
    vga.putChar('\n');

    vga.write("Entry point: 0x");
    fmt.printHex32(info.entry);
    vga.putChar('\n');

    vga.write("PH offset:   0x");
    fmt.printHex32(info.ph_offset);
    vga.write("  (");
    fmt.printDec(@as(usize, info.ph_num));
    vga.write(" entries)\n");

    vga.write("SH offset:   0x");
    fmt.printHex32(info.sh_offset);
    vga.write("  (");
    fmt.printDec(@as(usize, info.sh_num));
    vga.write(" entries)\n");

    vga.write("Flags:       0x");
    fmt.printHex32(info.flags);
    vga.putChar('\n');

    vga.write("SH strndx:   ");
    fmt.printDec(@as(usize, info.sh_strndx));
    vga.putChar('\n');
}

/// Print all sections.
pub fn printSections(info: *const ElfInfo) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Section Headers ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  #  Name             Type        Addr       Offset     Size       Flags\n");
    vga.setColor(.light_grey, .black);

    var i: u8 = 0;
    while (i < info.section_count) : (i += 1) {
        const sec = &info.sections[i];
        vga.write("  ");
        fmt.printDecPadded(@as(usize, i), 2);
        vga.write(" ");
        printNamePadded(&sec.name, sec.name_len, 16);
        vga.write(" ");
        printSectionType(sec.sh_type);
        vga.write(" 0x");
        fmt.printHex32(sec.addr);
        vga.write(" 0x");
        fmt.printHex32(sec.offset);
        vga.write(" 0x");
        fmt.printHex32(sec.size);
        vga.write(" ");
        printSectionFlags(sec.flags);
        vga.putChar('\n');
    }
}

/// Print all symbols.
pub fn printSymbols(info: *const ElfInfo) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Symbol Table ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  #  Value      Size  Bind   Type     Name\n");
    vga.setColor(.light_grey, .black);

    var i: u8 = 0;
    while (i < info.symbol_count) : (i += 1) {
        const sym = &info.symbols[i];
        vga.write("  ");
        fmt.printDecPadded(@as(usize, i), 2);
        vga.write(" 0x");
        fmt.printHex32(sym.value);
        vga.write(" ");
        fmt.printDecPadded(@as(usize, sym.size), 5);
        vga.write(" ");
        printSymbolBinding(sym.binding());
        vga.write(" ");
        printSymbolType(sym.symType());
        vga.write(" ");
        if (sym.name_len > 0) {
            vga.write(sym.name[0..sym.name_len]);
        } else {
            vga.write("(unnamed)");
        }
        vga.putChar('\n');
    }
}

/// Print program headers.
pub fn printProgramHeaders(info: *const ElfInfo) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== Program Headers ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  #  Type     Offset     VAddr      PAddr      FileSz     MemSz      Flags\n");
    vga.setColor(.light_grey, .black);

    var i: u8 = 0;
    while (i < info.phdr_count) : (i += 1) {
        const ph = &info.program_headers[i];
        vga.write("  ");
        fmt.printDecPadded(@as(usize, i), 2);
        vga.write(" ");
        printPhdrType(ph.ph_type);
        vga.write(" 0x");
        fmt.printHex32(ph.offset);
        vga.write(" 0x");
        fmt.printHex32(ph.vaddr);
        vga.write(" 0x");
        fmt.printHex32(ph.paddr);
        vga.write(" 0x");
        fmt.printHex32(ph.filesz);
        vga.write(" 0x");
        fmt.printHex32(ph.memsz);
        vga.write(" ");
        printPhdrFlags(ph.flags);
        vga.putChar('\n');
    }
}

// ---- Name helpers ----

fn printElfType(t: u16) void {
    switch (t) {
        ET_NONE => vga.write("NONE"),
        ET_REL => vga.write("REL (Relocatable)"),
        ET_EXEC => vga.write("EXEC (Executable)"),
        ET_DYN => vga.write("DYN (Shared object)"),
        ET_CORE => vga.write("CORE (Core file)"),
        else => {
            vga.write("0x");
            fmt.printHex16(t);
        },
    }
}

fn printSectionType(t: u32) void {
    switch (t) {
        SHT_NULL => vga.write("NULL      "),
        SHT_PROGBITS => vga.write("PROGBITS  "),
        SHT_SYMTAB => vga.write("SYMTAB    "),
        SHT_STRTAB => vga.write("STRTAB    "),
        SHT_RELA => vga.write("RELA      "),
        SHT_HASH => vga.write("HASH      "),
        SHT_DYNAMIC => vga.write("DYNAMIC   "),
        SHT_NOTE => vga.write("NOTE      "),
        SHT_NOBITS => vga.write("NOBITS    "),
        SHT_REL => vga.write("REL       "),
        SHT_DYNSYM => vga.write("DYNSYM    "),
        else => {
            vga.write("0x");
            fmt.printHex32(t);
            vga.write("  ");
        },
    }
}

fn printSectionFlags(f: u32) void {
    if (f & SHF_WRITE != 0) vga.putChar('W');
    if (f & SHF_ALLOC != 0) vga.putChar('A');
    if (f & SHF_EXECINSTR != 0) vga.putChar('X');
    if (f == 0) vga.write("---");
}

fn printSymbolBinding(b: u8) void {
    switch (b) {
        STB_LOCAL => vga.write("LOCAL "),
        STB_GLOBAL => vga.write("GLOBAL"),
        STB_WEAK => vga.write("WEAK  "),
        else => vga.write("???   "),
    }
}

fn printSymbolType(t: u8) void {
    switch (t) {
        STT_NOTYPE => vga.write("NOTYPE "),
        STT_OBJECT => vga.write("OBJECT "),
        STT_FUNC => vga.write("FUNC   "),
        STT_SECTION => vga.write("SECTION"),
        STT_FILE => vga.write("FILE   "),
        else => vga.write("???    "),
    }
}

fn printPhdrType(t: u32) void {
    switch (t) {
        PT_NULL => vga.write("NULL   "),
        PT_LOAD => vga.write("LOAD   "),
        PT_DYNAMIC => vga.write("DYNAMIC"),
        PT_INTERP => vga.write("INTERP "),
        PT_NOTE => vga.write("NOTE   "),
        PT_SHLIB => vga.write("SHLIB  "),
        PT_PHDR => vga.write("PHDR   "),
        else => {
            vga.write("0x");
            fmt.printHex32(t);
        },
    }
}

fn printPhdrFlags(f: u32) void {
    if (f & PF_R != 0) vga.putChar('R') else vga.putChar('-');
    if (f & PF_W != 0) vga.putChar('W') else vga.putChar('-');
    if (f & PF_X != 0) vga.putChar('X') else vga.putChar('-');
}

fn printNamePadded(name: []const u8, name_len: u8, width: usize) void {
    var printed: usize = 0;
    if (name_len > 0) {
        const len = @as(usize, name_len);
        const to_print = if (len > width) width else len;
        vga.write(name[0..to_print]);
        printed = to_print;
    }
    while (printed < width) : (printed += 1) {
        vga.putChar(' ');
    }
}

// ---- Byte reading helpers (little-endian) ----

fn readU16(data: []const u8, off: usize) u16 {
    if (off + 2 > data.len) return 0;
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readU32(data: []const u8, off: usize) u32 {
    if (off + 4 > data.len) return 0;
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
