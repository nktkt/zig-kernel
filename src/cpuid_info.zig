// Comprehensive CPUID Information -- CPU identification and feature detection
//
// Queries CPUID leaves 0, 1, 2, 7, 0x80000000-0x80000004 to determine:
// vendor string, brand string, family/model/stepping, feature flags,
// cache descriptors, and extended features.

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- Feature flags enum ----

pub const Feature = enum(u8) {
    fpu = 0, // x87 FPU
    vme = 1, // Virtual 8086 Mode Extensions
    de = 2, // Debugging Extensions
    pse = 3, // Page Size Extension
    tsc = 4, // Time Stamp Counter
    msr = 5, // Model Specific Registers
    pae = 6, // Physical Address Extension
    mce = 7, // Machine Check Exception
    cx8 = 8, // CMPXCHG8B
    apic = 9, // APIC
    sep = 11, // SYSENTER/SYSEXIT
    mtrr = 12, // Memory Type Range Registers
    pge = 13, // Page Global Enable
    mca = 14, // Machine Check Architecture
    cmov = 15, // CMOV instructions
    pat = 16, // Page Attribute Table
    pse36 = 17, // 36-bit Page Size Extension
    psn = 18, // Processor Serial Number
    clfsh = 19, // CLFLUSH
    mmx = 23, // MMX
    fxsr = 24, // FXSAVE/FXRSTOR
    sse = 25, // SSE
    sse2 = 26, // SSE2
    ss = 27, // Self Snoop
    htt = 28, // Hyper-Threading
    tm = 29, // Thermal Monitor
    // ECX features (stored with offset 32)
    sse3 = 32, // SSE3
    pclmul = 33, // PCLMULQDQ
    dtes64 = 34, // 64-bit Debug Store
    monitor = 35, // MONITOR/MWAIT
    ssse3 = 41, // SSSE3
    fma = 44, // FMA
    cx16 = 45, // CMPXCHG16B
    sse41 = 51, // SSE4.1
    sse42 = 52, // SSE4.2
    movbe = 54, // MOVBE
    popcnt = 55, // POPCNT
    aesni = 57, // AES-NI
    xsave = 58, // XSAVE
    avx = 60, // AVX
    f16c = 61, // F16C
    rdrand = 62, // RDRAND
    // Extended (0x80000001 EDX)
    syscall_ext = 75, // SYSCALL/SYSRET
    nx = 84, // No-Execute bit
    lm = 93, // Long Mode (x86-64)
};

// ---- CPUID result ----

const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn cpuid(leaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [ecx_in] "{ecx}" (@as(u32, 0)),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn cpuidSub(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [ecx_in] "{ecx}" (subleaf),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

// ---- State ----

var max_leaf: u32 = 0;
var max_ext_leaf: u32 = 0;

var vendor_buf: [12]u8 = undefined;
var vendor_len: u8 = 12;

var brand_buf: [48]u8 = undefined;
var brand_len: u8 = 0;

var family: u8 = 0;
var model: u8 = 0;
var stepping: u8 = 0;
var ext_family: u8 = 0;
var ext_model: u8 = 0;
var logical_processors: u8 = 0;
var apic_id: u8 = 0;
var clflush_size: u8 = 0;

// Feature bits: two u32s for leaf1 EDX and ECX
var feat_edx: u32 = 0;
var feat_ecx: u32 = 0;
var ext_feat_edx: u32 = 0; // 0x80000001 EDX

// Leaf 7 sub-0 features (EBX)
var leaf7_ebx: u32 = 0;

var cpu_initialized: bool = false;

// ---- Init ----

pub fn init() void {
    // Leaf 0: max standard leaf + vendor string
    const l0 = cpuid(0);
    max_leaf = l0.eax;

    // Vendor string is EBX + EDX + ECX (12 chars)
    const vb = @as([4]u8, @bitCast(l0.ebx));
    const vd = @as([4]u8, @bitCast(l0.edx));
    const vc = @as([4]u8, @bitCast(l0.ecx));
    vendor_buf[0] = vb[0];
    vendor_buf[1] = vb[1];
    vendor_buf[2] = vb[2];
    vendor_buf[3] = vb[3];
    vendor_buf[4] = vd[0];
    vendor_buf[5] = vd[1];
    vendor_buf[6] = vd[2];
    vendor_buf[7] = vd[3];
    vendor_buf[8] = vc[0];
    vendor_buf[9] = vc[1];
    vendor_buf[10] = vc[2];
    vendor_buf[11] = vc[3];

    // Leaf 1: family/model/stepping, features
    if (max_leaf >= 1) {
        const l1 = cpuid(1);

        stepping = @truncate(l1.eax & 0x0F);
        model = @truncate((l1.eax >> 4) & 0x0F);
        family = @truncate((l1.eax >> 8) & 0x0F);
        ext_model = @truncate((l1.eax >> 16) & 0x0F);
        ext_family = @truncate((l1.eax >> 20) & 0xFF);

        // Compute effective family/model
        if (family == 0x0F) {
            family += ext_family;
        }
        if (family == 0x06 or family == 0x0F) {
            model += @as(u8, ext_model) << 4;
        }

        logical_processors = @truncate((l1.ebx >> 16) & 0xFF);
        apic_id = @truncate((l1.ebx >> 24) & 0xFF);
        clflush_size = @truncate(((l1.ebx >> 8) & 0xFF) * 8);

        feat_edx = l1.edx;
        feat_ecx = l1.ecx;
    }

    // Leaf 7 sub-0: extended features
    if (max_leaf >= 7) {
        const l7 = cpuidSub(7, 0);
        leaf7_ebx = l7.ebx;
    }

    // Extended leaves
    const ext0 = cpuid(0x80000000);
    max_ext_leaf = ext0.eax;

    // 0x80000001: extended features
    if (max_ext_leaf >= 0x80000001) {
        const ext1 = cpuid(0x80000001);
        ext_feat_edx = ext1.edx;
    }

    // 0x80000002-0x80000004: brand string (48 chars)
    brand_len = 0;
    if (max_ext_leaf >= 0x80000004) {
        var leaf: u32 = 0x80000002;
        while (leaf <= 0x80000004) : (leaf += 1) {
            const r = cpuid(leaf);
            storeBrandChunk(r.eax);
            storeBrandChunk(r.ebx);
            storeBrandChunk(r.ecx);
            storeBrandChunk(r.edx);
        }
        // Trim trailing spaces
        while (brand_len > 0 and brand_buf[brand_len - 1] == ' ') {
            brand_len -= 1;
        }
    }

    cpu_initialized = true;
}

fn storeBrandChunk(val: u32) void {
    const bytes = @as([4]u8, @bitCast(val));
    for (bytes) |b| {
        if (brand_len < 48) {
            brand_buf[brand_len] = b;
            brand_len += 1;
        }
    }
}

// ---- Public accessors ----

pub fn getVendor() []const u8 {
    return vendor_buf[0..vendor_len];
}

pub fn getBrand() []const u8 {
    if (brand_len == 0) return "(unknown)";
    // Skip leading spaces
    var start: u8 = 0;
    while (start < brand_len and brand_buf[start] == ' ') start += 1;
    return brand_buf[start..brand_len];
}

pub fn getFamily() u8 {
    return family;
}

pub fn getModel() u8 {
    return model;
}

pub fn getStepping() u8 {
    return stepping;
}

pub fn getApicId() u8 {
    return apic_id;
}

pub fn getLogicalProcessors() u8 {
    return logical_processors;
}

/// Check if a specific CPU feature is supported.
pub fn hasFeature(feat: Feature) bool {
    const idx = @intFromEnum(feat);

    if (idx < 32) {
        // EDX features
        return (feat_edx & (@as(u32, 1) << @as(u5, @truncate(idx)))) != 0;
    } else if (idx < 64) {
        // ECX features
        return (feat_ecx & (@as(u32, 1) << @as(u5, @truncate(idx - 32)))) != 0;
    } else if (idx < 96) {
        // Extended EDX features
        return (ext_feat_edx & (@as(u32, 1) << @as(u5, @truncate(idx - 64)))) != 0;
    }
    return false;
}

/// Check leaf 7 features.
pub fn hasLeaf7Feature(bit: u5) bool {
    return (leaf7_ebx & (@as(u32, 1) << bit)) != 0;
}

// ---- Friendly feature names ----

const FeatureEntry = struct {
    feat: Feature,
    name: []const u8,
};

const feature_list = [_]FeatureEntry{
    .{ .feat = .fpu, .name = "FPU" },
    .{ .feat = .vme, .name = "VME" },
    .{ .feat = .de, .name = "DE" },
    .{ .feat = .pse, .name = "PSE" },
    .{ .feat = .tsc, .name = "TSC" },
    .{ .feat = .msr, .name = "MSR" },
    .{ .feat = .pae, .name = "PAE" },
    .{ .feat = .mce, .name = "MCE" },
    .{ .feat = .cx8, .name = "CX8" },
    .{ .feat = .apic, .name = "APIC" },
    .{ .feat = .sep, .name = "SEP" },
    .{ .feat = .mtrr, .name = "MTRR" },
    .{ .feat = .pge, .name = "PGE" },
    .{ .feat = .cmov, .name = "CMOV" },
    .{ .feat = .pat, .name = "PAT" },
    .{ .feat = .pse36, .name = "PSE36" },
    .{ .feat = .clfsh, .name = "CLFLUSH" },
    .{ .feat = .mmx, .name = "MMX" },
    .{ .feat = .fxsr, .name = "FXSR" },
    .{ .feat = .sse, .name = "SSE" },
    .{ .feat = .sse2, .name = "SSE2" },
    .{ .feat = .ss, .name = "SS" },
    .{ .feat = .htt, .name = "HTT" },
    .{ .feat = .sse3, .name = "SSE3" },
    .{ .feat = .pclmul, .name = "PCLMUL" },
    .{ .feat = .ssse3, .name = "SSSE3" },
    .{ .feat = .fma, .name = "FMA" },
    .{ .feat = .cx16, .name = "CX16" },
    .{ .feat = .sse41, .name = "SSE4.1" },
    .{ .feat = .sse42, .name = "SSE4.2" },
    .{ .feat = .popcnt, .name = "POPCNT" },
    .{ .feat = .aesni, .name = "AES-NI" },
    .{ .feat = .xsave, .name = "XSAVE" },
    .{ .feat = .avx, .name = "AVX" },
    .{ .feat = .f16c, .name = "F16C" },
    .{ .feat = .rdrand, .name = "RDRAND" },
    .{ .feat = .nx, .name = "NX" },
    .{ .feat = .lm, .name = "LM" },
};

// ---- Print all ----

pub fn printAll() void {
    if (!cpu_initialized) {
        vga.write("CPUID: not initialized\n");
        return;
    }

    vga.setColor(.yellow, .black);
    vga.write("CPU Information (CPUID)\n");
    vga.setColor(.light_grey, .black);

    // Vendor
    vga.write("  Vendor: ");
    vga.write(getVendor());
    vga.putChar('\n');

    // Brand
    vga.write("  Brand:  ");
    vga.write(getBrand());
    vga.putChar('\n');

    // Family/Model/Stepping
    vga.write("  Family: ");
    fmt.printDec(family);
    vga.write("  Model: ");
    fmt.printDec(model);
    vga.write("  Stepping: ");
    fmt.printDec(stepping);
    vga.putChar('\n');

    // APIC / logical CPUs
    vga.write("  APIC ID: ");
    fmt.printDec(apic_id);
    vga.write("  Logical CPUs: ");
    fmt.printDec(logical_processors);
    vga.putChar('\n');

    // CLFLUSH line size
    vga.write("  CLFLUSH line: ");
    fmt.printDec(clflush_size);
    vga.write(" bytes\n");

    // Max CPUID leaves
    vga.write("  Max leaf: 0x");
    fmt.printHex32(max_leaf);
    vga.write("  Max ext leaf: 0x");
    fmt.printHex32(max_ext_leaf);
    vga.putChar('\n');

    // Feature flags
    vga.write("  Features: ");
    var count: u32 = 0;
    for (feature_list) |entry| {
        if (hasFeature(entry.feat)) {
            if (count > 0) vga.write(" ");
            vga.setColor(.light_green, .black);
            vga.write(entry.name);
            vga.setColor(.light_grey, .black);
            count += 1;
        }
    }
    vga.putChar('\n');

    // Raw feature bits
    vga.write("  EDX: 0x");
    fmt.printHex32(feat_edx);
    vga.write("  ECX: 0x");
    fmt.printHex32(feat_ecx);
    vga.putChar('\n');

    if (ext_feat_edx != 0) {
        vga.write("  Ext EDX: 0x");
        fmt.printHex32(ext_feat_edx);
        vga.putChar('\n');
    }
}

/// Print a compact one-line summary.
pub fn printSummary() void {
    vga.write(getVendor());
    vga.write(" ");
    vga.write(getBrand());
    vga.write(" (fam=");
    fmt.printDec(family);
    vga.write(" mod=");
    fmt.printDec(model);
    vga.write(" step=");
    fmt.printDec(stepping);
    vga.write(")\n");
}
