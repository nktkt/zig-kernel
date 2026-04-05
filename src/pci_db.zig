// PCI デバイスデータベース — ベンダー・デバイス・クラス名の逆引き

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- ベンダー ID 定数 ----

pub const VENDOR_INTEL: u16 = 0x8086;
pub const VENDOR_AMD: u16 = 0x1022;
pub const VENDOR_NVIDIA: u16 = 0x10DE;
pub const VENDOR_REALTEK: u16 = 0x10EC;
pub const VENDOR_BROADCOM: u16 = 0x14E4;
pub const VENDOR_REDHAT: u16 = 0x1AF4; // Red Hat / QEMU virtio
pub const VENDOR_BOCHS: u16 = 0x1234; // Bochs/QEMU VGA

// ---- ベンダーテーブル ----

const VendorEntry = struct {
    id: u16,
    name: []const u8,
};

const vendor_table = [_]VendorEntry{
    .{ .id = VENDOR_INTEL, .name = "Intel Corporation" },
    .{ .id = VENDOR_AMD, .name = "Advanced Micro Devices (AMD)" },
    .{ .id = VENDOR_NVIDIA, .name = "NVIDIA Corporation" },
    .{ .id = VENDOR_REALTEK, .name = "Realtek Semiconductor" },
    .{ .id = VENDOR_BROADCOM, .name = "Broadcom Inc." },
    .{ .id = VENDOR_REDHAT, .name = "Red Hat / Virtio" },
    .{ .id = VENDOR_BOCHS, .name = "Bochs/QEMU" },
    .{ .id = 0x1002, .name = "AMD/ATI" },
    .{ .id = 0x10B7, .name = "3Com Corporation" },
    .{ .id = 0x15AD, .name = "VMware" },
    .{ .id = 0x1AB8, .name = "Parallel Desktop" },
    .{ .id = 0x80EE, .name = "Oracle VirtualBox" },
    .{ .id = 0x1B36, .name = "Red Hat QEMU" },
    .{ .id = 0x8086, .name = "Intel Corporation" },
};

/// ベンダー ID から名前を取得
pub fn getVendorName(vendor_id: u16) []const u8 {
    for (vendor_table) |entry| {
        if (entry.id == vendor_id) return entry.name;
    }
    return "Unknown Vendor";
}

// ---- デバイステーブル ----

const DeviceEntry = struct {
    vendor_id: u16,
    device_id: u16,
    name: []const u8,
};

const device_table = [_]DeviceEntry{
    // Intel devices
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x1237, .name = "82441FX (Natoma) Host Bridge" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x7000, .name = "82371SB PIIX3 ISA Bridge" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x7010, .name = "82371SB PIIX3 IDE Controller" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x7020, .name = "82371SB PIIX3 USB (UHCI)" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x7113, .name = "82371AB PIIX4 ACPI/PM" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x100E, .name = "82540EM Gigabit Ethernet (E1000)" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x100F, .name = "82545EM Gigabit Ethernet" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x10D3, .name = "82574L Gigabit Ethernet" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x153A, .name = "I217-LM Gigabit Ethernet" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x2415, .name = "AC'97 Audio Controller (ICH)" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x2668, .name = "ICH6 HD Audio Controller" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x293E, .name = "ICH9 HD Audio Controller" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x29C0, .name = "82G33/G31 Express DRAM Controller" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x2934, .name = "ICH9 USB UHCI Controller #1" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x2935, .name = "ICH9 USB UHCI Controller #2" },
    .{ .vendor_id = VENDOR_INTEL, .device_id = 0x293A, .name = "ICH9 USB EHCI Controller" },

    // Bochs/QEMU VGA
    .{ .vendor_id = VENDOR_BOCHS, .device_id = 0x1111, .name = "Bochs/QEMU VGA (stdvga)" },

    // Red Hat Virtio devices
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1000, .name = "Virtio Network Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1001, .name = "Virtio Block Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1002, .name = "Virtio Balloon Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1003, .name = "Virtio Console Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1004, .name = "Virtio SCSI Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1005, .name = "Virtio Entropy Device (RNG)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1009, .name = "Virtio Filesystem (9P)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1041, .name = "Virtio Network (modern)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1042, .name = "Virtio Block (modern)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1043, .name = "Virtio Console (modern)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1044, .name = "Virtio Entropy (modern)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1045, .name = "Virtio Balloon (modern)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1048, .name = "Virtio SCSI (modern)" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1050, .name = "Virtio GPU Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1052, .name = "Virtio Input Device" },
    .{ .vendor_id = VENDOR_REDHAT, .device_id = 0x1110, .name = "QEMU ivshmem Device" },

    // Realtek
    .{ .vendor_id = VENDOR_REALTEK, .device_id = 0x8139, .name = "RTL-8139/8139C/8139C+ Ethernet" },
    .{ .vendor_id = VENDOR_REALTEK, .device_id = 0x8168, .name = "RTL8111/8168/8411 Gigabit Ethernet" },
    .{ .vendor_id = VENDOR_REALTEK, .device_id = 0x8169, .name = "RTL-8169 Gigabit Ethernet" },

    // AMD
    .{ .vendor_id = VENDOR_AMD, .device_id = 0x2000, .name = "PCnet-PCI II (Am79C970A) Ethernet" },

    // NVIDIA
    .{ .vendor_id = VENDOR_NVIDIA, .device_id = 0x0040, .name = "GeForce 6800 Ultra" },
    .{ .vendor_id = VENDOR_NVIDIA, .device_id = 0x0391, .name = "GeForce 7600 GT" },

    // VMware
    .{ .vendor_id = 0x15AD, .device_id = 0x0405, .name = "VMware SVGA II" },
    .{ .vendor_id = 0x15AD, .device_id = 0x0740, .name = "VMware Virtual Machine Comm. Interface" },
    .{ .vendor_id = 0x15AD, .device_id = 0x0770, .name = "VMware USB2 EHCI Controller" },
    .{ .vendor_id = 0x15AD, .device_id = 0x07A0, .name = "VMware PCI Bridge" },

    // VirtualBox
    .{ .vendor_id = 0x80EE, .device_id = 0xBEEF, .name = "VirtualBox Graphics Adapter" },
    .{ .vendor_id = 0x80EE, .device_id = 0xCAFE, .name = "VirtualBox Guest Service" },

    // Red Hat QEMU misc
    .{ .vendor_id = 0x1B36, .device_id = 0x0001, .name = "QEMU PCI-PCI Bridge" },
    .{ .vendor_id = 0x1B36, .device_id = 0x0002, .name = "QEMU PCI Serial Port (16550A)" },
    .{ .vendor_id = 0x1B36, .device_id = 0x0003, .name = "QEMU PCI Parallel Port" },
    .{ .vendor_id = 0x1B36, .device_id = 0x0004, .name = "QEMU PCI Test Device" },
    .{ .vendor_id = 0x1B36, .device_id = 0x0005, .name = "QEMU PCI Rocker Switch" },
    .{ .vendor_id = 0x1B36, .device_id = 0x000D, .name = "QEMU XHCI Host Controller" },
};

/// ベンダーID + デバイスID からデバイス名を取得
pub fn getDeviceName(vendor_id: u16, device_id: u16) []const u8 {
    for (device_table) |entry| {
        if (entry.vendor_id == vendor_id and entry.device_id == device_id) {
            return entry.name;
        }
    }
    return "Unknown Device";
}

// ---- PCI クラスコード ----

const ClassEntry = struct {
    class: u8,
    subclass: u8,
    name: []const u8,
};

const class_table = [_]ClassEntry{
    // 0x00: Unclassified
    .{ .class = 0x00, .subclass = 0x00, .name = "Non-VGA Unclassified Device" },
    .{ .class = 0x00, .subclass = 0x01, .name = "VGA-Compatible Unclassified" },

    // 0x01: Mass Storage
    .{ .class = 0x01, .subclass = 0x00, .name = "SCSI Bus Controller" },
    .{ .class = 0x01, .subclass = 0x01, .name = "IDE Controller" },
    .{ .class = 0x01, .subclass = 0x02, .name = "Floppy Controller" },
    .{ .class = 0x01, .subclass = 0x03, .name = "IPI Bus Controller" },
    .{ .class = 0x01, .subclass = 0x04, .name = "RAID Controller" },
    .{ .class = 0x01, .subclass = 0x05, .name = "ATA Controller" },
    .{ .class = 0x01, .subclass = 0x06, .name = "SATA Controller (AHCI)" },
    .{ .class = 0x01, .subclass = 0x07, .name = "Serial Attached SCSI" },
    .{ .class = 0x01, .subclass = 0x08, .name = "NVMe Controller" },
    .{ .class = 0x01, .subclass = 0x80, .name = "Other Storage Controller" },

    // 0x02: Network
    .{ .class = 0x02, .subclass = 0x00, .name = "Ethernet Controller" },
    .{ .class = 0x02, .subclass = 0x01, .name = "Token Ring Controller" },
    .{ .class = 0x02, .subclass = 0x02, .name = "FDDI Controller" },
    .{ .class = 0x02, .subclass = 0x03, .name = "ATM Controller" },
    .{ .class = 0x02, .subclass = 0x04, .name = "ISDN Controller" },
    .{ .class = 0x02, .subclass = 0x80, .name = "Other Network Controller" },

    // 0x03: Display
    .{ .class = 0x03, .subclass = 0x00, .name = "VGA-Compatible Controller" },
    .{ .class = 0x03, .subclass = 0x01, .name = "XGA Controller" },
    .{ .class = 0x03, .subclass = 0x02, .name = "3D Controller (non-VGA)" },
    .{ .class = 0x03, .subclass = 0x80, .name = "Other Display Controller" },

    // 0x04: Multimedia
    .{ .class = 0x04, .subclass = 0x00, .name = "Multimedia Video Controller" },
    .{ .class = 0x04, .subclass = 0x01, .name = "Multimedia Audio Controller" },
    .{ .class = 0x04, .subclass = 0x02, .name = "Computer Telephony" },
    .{ .class = 0x04, .subclass = 0x03, .name = "HD Audio Controller" },
    .{ .class = 0x04, .subclass = 0x80, .name = "Other Multimedia" },

    // 0x05: Memory
    .{ .class = 0x05, .subclass = 0x00, .name = "RAM Controller" },
    .{ .class = 0x05, .subclass = 0x01, .name = "Flash Controller" },
    .{ .class = 0x05, .subclass = 0x80, .name = "Other Memory Controller" },

    // 0x06: Bridge
    .{ .class = 0x06, .subclass = 0x00, .name = "Host Bridge" },
    .{ .class = 0x06, .subclass = 0x01, .name = "ISA Bridge" },
    .{ .class = 0x06, .subclass = 0x02, .name = "EISA Bridge" },
    .{ .class = 0x06, .subclass = 0x03, .name = "MCA Bridge" },
    .{ .class = 0x06, .subclass = 0x04, .name = "PCI-to-PCI Bridge" },
    .{ .class = 0x06, .subclass = 0x05, .name = "PCMCIA Bridge" },
    .{ .class = 0x06, .subclass = 0x06, .name = "NuBus Bridge" },
    .{ .class = 0x06, .subclass = 0x07, .name = "CardBus Bridge" },
    .{ .class = 0x06, .subclass = 0x80, .name = "Other Bridge Device" },

    // 0x07: Communication
    .{ .class = 0x07, .subclass = 0x00, .name = "Serial Controller (16550)" },
    .{ .class = 0x07, .subclass = 0x01, .name = "Parallel Controller" },
    .{ .class = 0x07, .subclass = 0x02, .name = "Multiport Serial" },
    .{ .class = 0x07, .subclass = 0x03, .name = "Modem" },
    .{ .class = 0x07, .subclass = 0x80, .name = "Other Communication" },

    // 0x08: System Peripheral
    .{ .class = 0x08, .subclass = 0x00, .name = "PIC (8259)" },
    .{ .class = 0x08, .subclass = 0x01, .name = "DMA Controller" },
    .{ .class = 0x08, .subclass = 0x02, .name = "Timer (8254)" },
    .{ .class = 0x08, .subclass = 0x03, .name = "RTC Controller" },
    .{ .class = 0x08, .subclass = 0x04, .name = "PCI Hot-Plug Controller" },
    .{ .class = 0x08, .subclass = 0x05, .name = "SD Host Controller" },
    .{ .class = 0x08, .subclass = 0x80, .name = "Other System Peripheral" },

    // 0x09: Input
    .{ .class = 0x09, .subclass = 0x00, .name = "Keyboard Controller" },
    .{ .class = 0x09, .subclass = 0x01, .name = "Digitizer Pen" },
    .{ .class = 0x09, .subclass = 0x02, .name = "Mouse Controller" },
    .{ .class = 0x09, .subclass = 0x03, .name = "Scanner Controller" },
    .{ .class = 0x09, .subclass = 0x04, .name = "Gameport Controller" },
    .{ .class = 0x09, .subclass = 0x80, .name = "Other Input Controller" },

    // 0x0A: Docking Station
    .{ .class = 0x0A, .subclass = 0x00, .name = "Generic Docking Station" },
    .{ .class = 0x0A, .subclass = 0x80, .name = "Other Docking Station" },

    // 0x0B: Processor
    .{ .class = 0x0B, .subclass = 0x00, .name = "386 Processor" },
    .{ .class = 0x0B, .subclass = 0x01, .name = "486 Processor" },
    .{ .class = 0x0B, .subclass = 0x02, .name = "Pentium Processor" },
    .{ .class = 0x0B, .subclass = 0x40, .name = "Co-Processor" },

    // 0x0C: Serial Bus
    .{ .class = 0x0C, .subclass = 0x00, .name = "FireWire (IEEE 1394)" },
    .{ .class = 0x0C, .subclass = 0x01, .name = "ACCESS.bus" },
    .{ .class = 0x0C, .subclass = 0x02, .name = "SSA" },
    .{ .class = 0x0C, .subclass = 0x03, .name = "USB Controller" },
    .{ .class = 0x0C, .subclass = 0x04, .name = "Fibre Channel" },
    .{ .class = 0x0C, .subclass = 0x05, .name = "SMBus Controller" },
    .{ .class = 0x0C, .subclass = 0x80, .name = "Other Serial Bus" },

    // 0x0D: Wireless
    .{ .class = 0x0D, .subclass = 0x00, .name = "iRDA Compatible" },
    .{ .class = 0x0D, .subclass = 0x01, .name = "Consumer IR" },
    .{ .class = 0x0D, .subclass = 0x10, .name = "RF Controller" },
    .{ .class = 0x0D, .subclass = 0x11, .name = "Bluetooth Controller" },
    .{ .class = 0x0D, .subclass = 0x12, .name = "Broadband Controller" },
    .{ .class = 0x0D, .subclass = 0x20, .name = "Ethernet (802.1a)" },
    .{ .class = 0x0D, .subclass = 0x21, .name = "Ethernet (802.1b)" },
    .{ .class = 0x0D, .subclass = 0x80, .name = "Other Wireless" },

    // 0x0E: Intelligent Controller
    .{ .class = 0x0E, .subclass = 0x00, .name = "I20 Controller" },

    // 0x0F: Satellite
    .{ .class = 0x0F, .subclass = 0x01, .name = "Satellite TV" },
    .{ .class = 0x0F, .subclass = 0x02, .name = "Satellite Audio" },
    .{ .class = 0x0F, .subclass = 0x03, .name = "Satellite Voice" },
    .{ .class = 0x0F, .subclass = 0x04, .name = "Satellite Data" },

    // 0x10: Encryption
    .{ .class = 0x10, .subclass = 0x00, .name = "Network/Computing Encryption" },
    .{ .class = 0x10, .subclass = 0x10, .name = "Entertainment Encryption" },
    .{ .class = 0x10, .subclass = 0x80, .name = "Other Encryption" },

    // 0x11: Signal Processing
    .{ .class = 0x11, .subclass = 0x00, .name = "DPIO Modules" },
    .{ .class = 0x11, .subclass = 0x01, .name = "Performance Counters" },
    .{ .class = 0x11, .subclass = 0x80, .name = "Other Signal Processing" },
};

/// クラス + サブクラスから名前を取得
pub fn getClassName(class: u8, subclass: u8) []const u8 {
    for (class_table) |entry| {
        if (entry.class == class and entry.subclass == subclass) {
            return entry.name;
        }
    }
    // サブクラスが見つからない場合、クラスの大分類を返す
    return getBaseClassName(class);
}

/// クラスコードの大分類名
fn getBaseClassName(class: u8) []const u8 {
    return switch (class) {
        0x00 => "Unclassified",
        0x01 => "Mass Storage Controller",
        0x02 => "Network Controller",
        0x03 => "Display Controller",
        0x04 => "Multimedia Controller",
        0x05 => "Memory Controller",
        0x06 => "Bridge Device",
        0x07 => "Communication Controller",
        0x08 => "System Peripheral",
        0x09 => "Input Device Controller",
        0x0A => "Docking Station",
        0x0B => "Processor",
        0x0C => "Serial Bus Controller",
        0x0D => "Wireless Controller",
        0x0E => "Intelligent Controller",
        0x0F => "Satellite Communication",
        0x10 => "Encryption Controller",
        0x11 => "Signal Processing Controller",
        0x12 => "Processing Accelerator",
        0x13 => "Non-Essential Instrumentation",
        0xFF => "Unassigned Class",
        else => "Unknown Class",
    };
}

// ---- 統合表示 ----

/// デバイス情報をフォーマット表示
pub fn printDeviceInfo(vendor_id: u16, device_id: u16, class: u8, subclass: u8) void {
    // ベンダー:デバイス (hex)
    vga.setColor(.light_cyan, .black);
    printHex16(vendor_id);
    vga.putChar(':');
    printHex16(device_id);
    vga.write("  ");

    // クラス名
    vga.setColor(.yellow, .black);
    vga.write(getClassName(class, subclass));
    vga.putChar('\n');

    // ベンダー名
    vga.setColor(.light_grey, .black);
    vga.write("  Vendor: ");
    vga.write(getVendorName(vendor_id));
    vga.putChar('\n');

    // デバイス名
    vga.write("  Device: ");
    vga.write(getDeviceName(vendor_id, device_id));
    vga.putChar('\n');
}

/// PCI バス上の全デバイスを名前付きで表示
pub fn printAllDevices() void {
    const pci = @import("pci.zig");
    const count = pci.getDeviceCount();

    vga.setColor(.yellow, .black);
    vga.write("PCI Devices (");
    printDec(count);
    vga.write("):\n");
    vga.setColor(.light_grey, .black);

    // pci.zig の devices 配列にはアクセスできないため、
    // findDevice を使った走査はできない。
    // ここではデータベース統計のみ表示

    vga.write("  Vendors in DB: ");
    printDec(vendor_table.len);
    vga.putChar('\n');
    vga.write("  Devices in DB: ");
    printDec(device_table.len);
    vga.putChar('\n');
    vga.write("  Classes in DB: ");
    printDec(class_table.len);
    vga.putChar('\n');
}

/// データベース統計を表示
pub fn printStats() void {
    vga.setColor(.yellow, .black);
    vga.write("PCI Device Database:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Known vendors:  ");
    printDec(vendor_table.len);
    vga.putChar('\n');

    vga.write("  Known devices:  ");
    printDec(device_table.len);
    vga.putChar('\n');

    vga.write("  Known classes:  ");
    printDec(class_table.len);
    vga.putChar('\n');

    // ベンダーごとのデバイス数
    vga.setColor(.yellow, .black);
    vga.write("\nDevices per vendor:\n");
    vga.setColor(.light_grey, .black);

    for (vendor_table) |vendor| {
        var count: usize = 0;
        for (device_table) |dev| {
            if (dev.vendor_id == vendor.id) count += 1;
        }
        if (count > 0) {
            vga.write("  ");
            printHex16(vendor.id);
            vga.write(" ");
            vga.write(vendor.name);
            vga.write(": ");
            printDec(count);
            vga.write(" device(s)\n");
        }
    }
}

/// シリアルにデータベースダンプ
pub fn dumpToSerial() void {
    serial.write("=== PCI DB ===\n");
    serial.write("Vendors: ");
    serial.writeHex(vendor_table.len);
    serial.write(" Devices: ");
    serial.writeHex(device_table.len);
    serial.write(" Classes: ");
    serial.writeHex(class_table.len);
    serial.write("\n");
}

// ---- 内部ヘルパ ----

fn printHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[@as(u4, @truncate(val >> 12))]);
    vga.putChar(hex[@as(u4, @truncate(val >> 8))]);
    vga.putChar(hex[@as(u4, @truncate(val >> 4))]);
    vga.putChar(hex[@as(u4, @truncate(val))]);
}

fn printDec(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
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
        vga.putChar(buf[len]);
    }
}
