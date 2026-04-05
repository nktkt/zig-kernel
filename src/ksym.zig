// Kernel symbol table -- address-to-name resolution for debugging
//
// Maintains a table of kernel symbols (functions, data, sections) that
// can be looked up by address or name. Supports nearest-match lookups
// for resolving return addresses in stack traces. Auto-registers key
// kernel entry points at initialization.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_SYMBOLS = 64;
pub const MAX_NAME_LEN = 32;
pub const MAX_RESOLVE_BUF = 48; // "symbol_name+0xOFFSET\0"

// ---- Symbol types ----

pub const SymbolType = enum(u8) {
    function = 0,
    data = 1,
    section = 2,
    unknown = 3,
};

// ---- Symbol entry ----

pub const Symbol = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    addr: u32,
    size: u32,
    sym_type: SymbolType,
    active: bool,
};

// ---- Symbol match (for nearest lookups) ----

pub const SymbolMatch = struct {
    symbol: *const Symbol,
    offset: u32, // offset from symbol start
};

// ---- State ----

var symbols: [MAX_SYMBOLS]Symbol = undefined;
var symbol_count: u32 = 0;
var initialized: bool = false;

// ---- Sorted index for binary search by address ----
var sorted_by_addr: [MAX_SYMBOLS]u8 = undefined;
var sorted_count: u8 = 0;

// ---- Initialization ----

pub fn init() void {
    for (&symbols) |*s| {
        s.active = false;
        s.addr = 0;
        s.size = 0;
        s.sym_type = .unknown;
        s.name_len = 0;
        for (&s.name) |*c| c.* = 0;
    }
    symbol_count = 0;
    sorted_count = 0;
    initialized = true;

    // Auto-register key kernel symbols using linker-provided addresses.
    // These are approximations -- in a real kernel we'd parse the ELF symtab.
    // We register a few well-known entry points so stack traces are useful.
    autoRegisterKernelSymbols();

    serial.write("[ksym] symbol table initialized, ");
    serialDec(symbol_count);
    serial.write(" symbols\n");
}

fn autoRegisterKernelSymbols() void {
    // Register symbols for key kernel functions.
    // Addresses are obtained via inline asm or known constants.
    // Size is estimated (these are just labels).

    // _start is at the entry point
    _ = registerSymbol("_start", 0x00100000, 64, .function);
    _ = registerSymbol("kmain", 0x00100040, 512, .function);
    _ = registerSymbol(".text", 0x00100000, 0x00080000, .section);
    _ = registerSymbol(".rodata", 0x00180000, 0x00020000, .section);
    _ = registerSymbol(".data", 0x001A0000, 0x00010000, .section);
    _ = registerSymbol(".bss", 0x001B0000, 0x00010000, .section);
    _ = registerSymbol("stack_bottom", 0x001C0000, 16384, .data);
    _ = registerSymbol("stack_top", 0x001C4000, 0, .data);
    _ = registerSymbol("gdt_init", 0x00100600, 128, .function);
    _ = registerSymbol("idt_init", 0x00100700, 256, .function);
    _ = registerSymbol("pmm_init", 0x00100900, 256, .function);
    _ = registerSymbol("pit_init", 0x00100A00, 64, .function);
    _ = registerSymbol("heap_init", 0x00100A40, 256, .function);
    _ = registerSymbol("timer_handler", 0x00100B40, 128, .function);
    _ = registerSymbol("keyboard_handler", 0x00100BC0, 128, .function);
    _ = registerSymbol("syscall_dispatch", 0x00100C40, 512, .function);
    _ = registerSymbol("page_fault_handler", 0x00100E40, 256, .function);
}

// ---- Registration ----

/// Register a symbol in the table. Returns true on success.
pub fn registerSymbol(name: []const u8, addr: u32, size: u32, sym_type: SymbolType) bool {
    if (!initialized and symbol_count > 0) return false; // not yet init and already has data? odd

    // Check for duplicate address
    for (&symbols) |*s| {
        if (s.active and s.addr == addr) {
            // Update existing
            copyName(&s.name, &s.name_len, name);
            s.size = size;
            s.sym_type = sym_type;
            rebuildSorted();
            return true;
        }
    }

    if (symbol_count >= MAX_SYMBOLS) return false;

    // Find free slot
    for (&symbols) |*s| {
        if (!s.active) {
            s.active = true;
            s.addr = addr;
            s.size = size;
            s.sym_type = sym_type;
            copyName(&s.name, &s.name_len, name);
            symbol_count += 1;
            rebuildSorted();
            return true;
        }
    }
    return false;
}

/// Remove a symbol by name.
pub fn removeSymbol(name: []const u8) bool {
    for (&symbols) |*s| {
        if (s.active and nameEq(&s.name, s.name_len, name)) {
            s.active = false;
            symbol_count -= 1;
            rebuildSorted();
            return true;
        }
    }
    return false;
}

// ---- Sorted index maintenance ----

fn rebuildSorted() void {
    sorted_count = 0;
    for (0..MAX_SYMBOLS) |i| {
        if (symbols[i].active) {
            sorted_by_addr[sorted_count] = @truncate(i);
            sorted_count += 1;
        }
    }

    // Insertion sort by address ascending
    if (sorted_count <= 1) return;
    var i: u8 = 1;
    while (i < sorted_count) : (i += 1) {
        const key = sorted_by_addr[i];
        const key_addr = symbols[key].addr;
        var j: u8 = i;
        while (j > 0 and symbols[sorted_by_addr[j - 1]].addr > key_addr) {
            sorted_by_addr[j] = sorted_by_addr[j - 1];
            j -= 1;
        }
        sorted_by_addr[j] = key;
    }
}

// ---- Lookups ----

/// Find a symbol that contains the given address.
/// Returns pointer to symbol if addr falls within [sym.addr, sym.addr + sym.size).
pub fn lookupByAddr(addr: u32) ?*const Symbol {
    for (&symbols) |*s| {
        if (!s.active) continue;
        if (addr >= s.addr and (s.size == 0 or addr < s.addr + s.size)) {
            // Prefer functions over sections
            if (s.sym_type == .function) return s;
        }
    }
    // Fallback: any containing symbol
    for (&symbols) |*s| {
        if (!s.active) continue;
        if (addr >= s.addr and (s.size == 0 or addr < s.addr + s.size)) {
            return s;
        }
    }
    return null;
}

/// Find a symbol by exact name match.
pub fn lookupByName(name: []const u8) ?*const Symbol {
    for (&symbols) |*s| {
        if (s.active and nameEq(&s.name, s.name_len, name)) {
            return s;
        }
    }
    return null;
}

/// Find the nearest symbol at or before the given address.
/// Returns the symbol and the offset from its start.
pub fn nearestSymbol(addr: u32) ?SymbolMatch {
    if (sorted_count == 0) return null;

    // Linear scan through sorted list to find the last symbol with addr <= target
    var best: ?u8 = null;
    var i: u8 = 0;
    while (i < sorted_count) : (i += 1) {
        const sym_idx = sorted_by_addr[i];
        const sym = &symbols[sym_idx];
        if (sym.addr <= addr) {
            // Prefer functions
            if (best == null or sym.sym_type == .function or
                (symbols[sorted_by_addr[best.?]].sym_type != .function and
                sym.addr >= symbols[sorted_by_addr[best.?]].addr))
            {
                best = i;
            }
        }
    }

    if (best) |b| {
        const sym = &symbols[sorted_by_addr[b]];
        return .{
            .symbol = sym,
            .offset = addr - sym.addr,
        };
    }
    return null;
}

/// Resolve an address to "symbol_name+0xOFFSET" format.
/// Writes into the provided buffer and returns the written slice.
pub fn resolveAddress(addr: u32, buf: []u8) []u8 {
    if (buf.len < 12) return buf[0..0];

    const match = nearestSymbol(addr) orelse {
        // Just write the hex address
        return writeHexAddr(addr, buf);
    };

    var pos: usize = 0;

    // Copy symbol name
    const name_len = @as(usize, match.symbol.name_len);
    const copy_len = if (name_len > buf.len - 12) buf.len - 12 else name_len;
    for (0..copy_len) |i| {
        buf[pos] = match.symbol.name[i];
        pos += 1;
    }

    if (match.offset > 0) {
        // Add "+0x" prefix
        if (pos + 11 <= buf.len) {
            buf[pos] = '+';
            pos += 1;
            buf[pos] = '0';
            pos += 1;
            buf[pos] = 'x';
            pos += 1;
            // Write hex offset
            pos = writeHexU32(match.offset, buf, pos);
        }
    }

    return buf[0..pos];
}

fn writeHexAddr(addr: u32, buf: []u8) []u8 {
    if (buf.len < 10) return buf[0..0];
    buf[0] = '0';
    buf[1] = 'x';
    var pos: usize = 2;
    pos = writeHexU32(addr, buf, pos);
    return buf[0..pos];
}

fn writeHexU32(val: u32, buf: []u8, start: usize) usize {
    const hex = "0123456789ABCDEF";
    var v = val;
    var digits: [8]u8 = undefined;
    var dlen: usize = 0;

    if (v == 0) {
        if (start < buf.len) {
            buf[start] = '0';
            return start + 1;
        }
        return start;
    }

    while (v > 0 and dlen < 8) {
        digits[dlen] = hex[v & 0xF];
        v >>= 4;
        dlen += 1;
    }

    var pos = start;
    while (dlen > 0 and pos < buf.len) {
        dlen -= 1;
        buf[pos] = digits[dlen];
        pos += 1;
    }
    return pos;
}

// ---- Stack trace resolution ----

/// Walk the stack and print resolved symbol names for each frame.
/// ebp: starting frame pointer, depth: max frames to walk.
pub fn resolveStackTrace(ebp_val: u32, depth: usize) void {
    vga.setColor(.yellow, .black);
    vga.write("=== Resolved Stack Trace ===\n");
    vga.setColor(.light_grey, .black);

    var ebp = ebp_val;
    var frame: usize = 0;

    while (frame < depth) : (frame += 1) {
        if (ebp == 0 or ebp < 0x1000) break;

        // Return address is at [ebp + 4]
        const ret_addr_ptr: *const u32 = @ptrFromInt(ebp + 4);
        const ret_addr = ret_addr_ptr.*;

        if (ret_addr == 0) break;

        // Resolve the address
        var buf: [MAX_RESOLVE_BUF]u8 = undefined;
        const resolved = resolveAddress(ret_addr, &buf);

        vga.write("  #");
        fmt.printDec(frame);
        vga.write("  0x");
        fmt.printHex32(ret_addr);
        vga.write("  ");
        if (resolved.len > 0) {
            vga.setColor(.light_green, .black);
            vga.write(resolved);
            vga.setColor(.light_grey, .black);
        } else {
            vga.write("???");
        }
        vga.putChar('\n');

        // Also to serial
        serial.write("  #");
        serialDec(frame);
        serial.write("  ");
        if (resolved.len > 0) {
            serial.write(resolved);
        } else {
            serial.write("0x");
            serialHex32(ret_addr);
        }
        serial.write("\n");

        // Next frame
        const next_ebp_ptr: *const u32 = @ptrFromInt(ebp);
        ebp = next_ebp_ptr.*;
    }

    if (frame == 0) {
        vga.write("  (no frames)\n");
    }
}

/// Print the symbol at the current location (using caller's EBP).
pub fn resolveCurrentTrace(depth: usize) void {
    const ebp = asm volatile ("" : [ebp] "={ebp}" (-> u32));
    resolveStackTrace(ebp, depth);
}

// ---- Display ----

/// Print all symbols sorted by address.
pub fn printTable() void {
    if (!initialized) {
        vga.write("Symbol table not initialized.\n");
        return;
    }

    rebuildSorted();

    vga.setColor(.light_cyan, .black);
    vga.write("=== Kernel Symbol Table ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  Address    Size       Type     Name\n");
    vga.setColor(.light_grey, .black);

    var i: u8 = 0;
    while (i < sorted_count) : (i += 1) {
        const sym = &symbols[sorted_by_addr[i]];
        vga.write("  0x");
        fmt.printHex32(sym.addr);
        vga.write(" ");
        fmt.printDecPadded(@as(usize, sym.size), 9);
        vga.write("  ");
        printSymType(sym.sym_type);
        vga.write("  ");
        if (sym.name_len > 0) {
            vga.write(sym.name[0..sym.name_len]);
        }
        vga.putChar('\n');
    }

    vga.setColor(.light_grey, .black);
    vga.write("Total: ");
    fmt.printDec(@as(usize, symbol_count));
    vga.write(" symbols\n");
}

/// Print symbols near a given address (3 before, the match, 3 after).
pub fn printNearby(addr: u32) void {
    rebuildSorted();

    vga.setColor(.light_cyan, .black);
    vga.write("=== Symbols near 0x");
    fmt.printHex32(addr);
    vga.write(" ===\n");
    vga.setColor(.light_grey, .black);

    // Find the closest symbol index in sorted list
    var closest_idx: u8 = 0;
    var closest_dist: u64 = 0xFFFFFFFF;
    var i: u8 = 0;
    while (i < sorted_count) : (i += 1) {
        const sym = &symbols[sorted_by_addr[i]];
        const dist: u64 = if (addr >= sym.addr)
            @as(u64, addr - sym.addr)
        else
            @as(u64, sym.addr - addr);
        if (dist < closest_dist) {
            closest_dist = dist;
            closest_idx = i;
        }
    }

    // Print a window around the closest symbol
    const window: u8 = 3;
    const start: u8 = if (closest_idx > window) closest_idx - window else 0;
    const end: u8 = if (closest_idx + window + 1 < sorted_count) closest_idx + window + 1 else sorted_count;

    i = start;
    while (i < end) : (i += 1) {
        const sym = &symbols[sorted_by_addr[i]];
        if (i == closest_idx) {
            vga.setColor(.light_green, .black);
            vga.write("> ");
        } else {
            vga.setColor(.light_grey, .black);
            vga.write("  ");
        }
        vga.write("0x");
        fmt.printHex32(sym.addr);
        vga.write("  ");
        printSymType(sym.sym_type);
        vga.write("  ");
        if (sym.name_len > 0) {
            vga.write(sym.name[0..sym.name_len]);
        }
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
}

fn printSymType(t: SymbolType) void {
    switch (t) {
        .function => vga.write("FUNC  "),
        .data => vga.write("DATA  "),
        .section => vga.write("SECT  "),
        .unknown => vga.write("???   "),
    }
}

/// Get symbol count.
pub fn getSymbolCount() u32 {
    return symbol_count;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Helpers ----

fn copyName(dest: *[MAX_NAME_LEN]u8, dest_len: *u8, src: []const u8) void {
    const copy_len = if (src.len > MAX_NAME_LEN) MAX_NAME_LEN else src.len;
    for (0..copy_len) |i| {
        dest[i] = src[i];
    }
    var i: usize = copy_len;
    while (i < MAX_NAME_LEN) : (i += 1) {
        dest[i] = 0;
    }
    dest_len.* = @truncate(copy_len);
}

fn nameEq(stored: *const [MAX_NAME_LEN]u8, stored_len: u8, name: []const u8) bool {
    if (@as(usize, stored_len) != name.len) return false;
    for (0..name.len) |i| {
        if (stored[i] != name[i]) return false;
    }
    return true;
}

fn serialDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}

fn serialHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    var v = val;
    var i: usize = 8;
    var buf: [8]u8 = undefined;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    for (buf) |c| serial.putChar(c);
}
