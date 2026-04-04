// SMP 検出 & スピンロックプリミティブ

const acpi = @import("acpi.zig");
const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- スピンロック ----

pub const SpinLock = struct {
    locked: u32 = 0,

    pub fn acquire(self: *SpinLock) void {
        while (true) {
            // lock xchg で atomically に 1 を書き込み、前の値を取得
            const prev = asm volatile ("lock xchgl %[val], (%[ptr])"
                : [val] "=r" (-> u32),
                : [val] "0" (@as(u32, 1)),
                  [ptr] "r" (&self.locked),
                : .{ .memory = true }
            );
            if (prev == 0) return; // ロック取得成功
            // スピンウェイト
            asm volatile ("pause");
        }
    }

    pub fn release(self: *SpinLock) void {
        asm volatile ("" ::: .{ .memory = true }); // コンパイラバリア
        self.locked = 0;
    }

    pub fn tryAcquire(self: *SpinLock) bool {
        const prev = asm volatile ("lock xchgl %[val], (%[ptr])"
            : [val] "=r" (-> u32),
            : [val] "0" (@as(u32, 1)),
              [ptr] "r" (&self.locked),
            : .{ .memory = true }
        );
        return prev == 0;
    }
};

// ---- SMP 情報 ----

var bsp_id: u32 = 0;
var cpu_count_cached: u32 = 0;

pub fn init() void {
    // BSP の APIC ID を取得 (CPUID leaf 1, EBX[31:24])
    var ebx: u32 = undefined;
    asm volatile ("cpuid"
        : [b] "={ebx}" (ebx),
        : [eax] "{eax}" (@as(u32, 1)),
        : .{ .eax = true, .ecx = true, .edx = true }
    );
    bsp_id = ebx >> 24;
    cpu_count_cached = acpi.getCpuCount();

    serial.write("[SMP] BSP APIC ID=");
    serial.writeHex(bsp_id);
    serial.write(" CPUs=");
    serial.writeHex(cpu_count_cached);
    serial.write("\n");
}

pub fn getCpuCount() u32 {
    if (cpu_count_cached == 0) return 1;
    return cpu_count_cached;
}

pub fn getBspId() u32 {
    return bsp_id;
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("SMP Info:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  BSP APIC ID: ");
    printDec(bsp_id);
    vga.putChar('\n');
    vga.write("  CPU count:   ");
    printDec(getCpuCount());
    vga.putChar('\n');
    vga.write("  SpinLock:    available (lock xchg)\n");
}

fn printDec(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
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
