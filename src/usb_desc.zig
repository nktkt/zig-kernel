// USB Descriptor Parsing
//
// Parses standard USB descriptors from raw data:
//   - Device Descriptor (type 0x01)
//   - Configuration Descriptor (type 0x02)
//   - Interface Descriptor (type 0x04)
//   - Endpoint Descriptor (type 0x05)
//   - String Descriptor (type 0x03, limited UTF-16 -> ASCII)
//
// Reference: USB 2.0 Specification, Chapter 9.6

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Descriptor Type Constants ----

pub const DESC_DEVICE: u8 = 0x01;
pub const DESC_CONFIGURATION: u8 = 0x02;
pub const DESC_STRING: u8 = 0x03;
pub const DESC_INTERFACE: u8 = 0x04;
pub const DESC_ENDPOINT: u8 = 0x05;
pub const DESC_DEVICE_QUALIFIER: u8 = 0x06;
pub const DESC_OTHER_SPEED_CONFIG: u8 = 0x07;
pub const DESC_INTERFACE_POWER: u8 = 0x08;
pub const DESC_OTG: u8 = 0x09;
pub const DESC_DEBUG: u8 = 0x0A;
pub const DESC_INTERFACE_ASSOC: u8 = 0x0B;
pub const DESC_BOS: u8 = 0x0F;
pub const DESC_DEVICE_CAP: u8 = 0x10;
pub const DESC_HID: u8 = 0x21;
pub const DESC_HID_REPORT: u8 = 0x22;
pub const DESC_HID_PHYSICAL: u8 = 0x23;
pub const DESC_CS_INTERFACE: u8 = 0x24;
pub const DESC_CS_ENDPOINT: u8 = 0x25;
pub const DESC_HUB: u8 = 0x29;
pub const DESC_SUPERSPEED_HUB: u8 = 0x2A;
pub const DESC_SS_EP_COMPANION: u8 = 0x30;

// ---- USB Class Codes ----

pub const CLASS_AUDIO: u8 = 0x01;
pub const CLASS_CDC: u8 = 0x02; // Communications Device Class
pub const CLASS_HID: u8 = 0x03; // Human Interface Device
pub const CLASS_PHYSICAL: u8 = 0x05;
pub const CLASS_IMAGE: u8 = 0x06; // Still Imaging
pub const CLASS_PRINTER: u8 = 0x07;
pub const CLASS_MASS_STORAGE: u8 = 0x08;
pub const CLASS_HUB: u8 = 0x09;
pub const CLASS_CDC_DATA: u8 = 0x0A;
pub const CLASS_SMART_CARD: u8 = 0x0B;
pub const CLASS_CONTENT_SEC: u8 = 0x0D; // Content Security
pub const CLASS_VIDEO: u8 = 0x0E;
pub const CLASS_HEALTHCARE: u8 = 0x0F;
pub const CLASS_AV: u8 = 0x10; // Audio/Video
pub const CLASS_BILLBOARD: u8 = 0x11;
pub const CLASS_USB_C_BRIDGE: u8 = 0x12;
pub const CLASS_DIAGNOSTIC: u8 = 0xDC;
pub const CLASS_WIRELESS: u8 = 0xE0;
pub const CLASS_MISC: u8 = 0xEF;
pub const CLASS_APP_SPECIFIC: u8 = 0xFE;
pub const CLASS_VENDOR_SPEC: u8 = 0xFF;

// ---- Endpoint Transfer Types ----

pub const EP_TRANSFER_CONTROL: u8 = 0x00;
pub const EP_TRANSFER_ISOCHRONOUS: u8 = 0x01;
pub const EP_TRANSFER_BULK: u8 = 0x02;
pub const EP_TRANSFER_INTERRUPT: u8 = 0x03;

// ---- Descriptor Structures ----

pub const DeviceDesc = struct {
    bLength: u8,
    bDescriptorType: u8,
    bcdUSB: u16, // USB spec version (BCD, e.g., 0x0200 = USB 2.0)
    bDeviceClass: u8,
    bDeviceSubClass: u8,
    bDeviceProtocol: u8,
    bMaxPacketSize0: u8, // Max packet size for EP0 (8, 16, 32, or 64)
    idVendor: u16,
    idProduct: u16,
    bcdDevice: u16, // Device release number (BCD)
    iManufacturer: u8, // Index of manufacturer string
    iProduct: u8, // Index of product string
    iSerialNumber: u8, // Index of serial number string
    bNumConfigurations: u8,
};

pub const ConfigDesc = struct {
    bLength: u8,
    bDescriptorType: u8,
    wTotalLength: u16, // Total length of configuration data
    bNumInterfaces: u8,
    bConfigurationValue: u8,
    iConfiguration: u8, // Index of string descriptor
    bmAttributes: u8, // D7: reserved (1), D6: self-powered, D5: remote wakeup
    bMaxPower: u8, // Max power in 2mA units
};

pub const InterfaceDesc = struct {
    bLength: u8,
    bDescriptorType: u8,
    bInterfaceNumber: u8,
    bAlternateSetting: u8,
    bNumEndpoints: u8,
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    iInterface: u8,
};

pub const EndpointDesc = struct {
    bLength: u8,
    bDescriptorType: u8,
    bEndpointAddress: u8, // Bit 7: direction (0=OUT, 1=IN), bits 3:0: endpoint number
    bmAttributes: u8, // Bits 1:0: transfer type
    wMaxPacketSize: u16,
    bInterval: u8, // Polling interval
};

pub const StringDesc = struct {
    bLength: u8,
    bDescriptorType: u8,
    data: [126]u8, // UTF-16LE characters (max 126 bytes = 63 chars)
    data_len: u8,
};

// ---- Parsed configuration tree ----

pub const ParsedConfig = struct {
    device: DeviceDesc,
    configs: [4]ConfigDesc,
    config_count: u8,
    interfaces: [8]InterfaceDesc,
    interface_count: u8,
    endpoints: [16]EndpointDesc,
    endpoint_count: u8,
};

// ---- Parsing functions ----

/// Parse a device descriptor from raw bytes. Expects at least 18 bytes.
pub fn parseDevice(data: []const u8) ?DeviceDesc {
    if (data.len < 18) return null;
    if (data[1] != DESC_DEVICE) return null;

    return .{
        .bLength = data[0],
        .bDescriptorType = data[1],
        .bcdUSB = readU16(data, 2),
        .bDeviceClass = data[4],
        .bDeviceSubClass = data[5],
        .bDeviceProtocol = data[6],
        .bMaxPacketSize0 = data[7],
        .idVendor = readU16(data, 8),
        .idProduct = readU16(data, 10),
        .bcdDevice = readU16(data, 12),
        .iManufacturer = data[14],
        .iProduct = data[15],
        .iSerialNumber = data[16],
        .bNumConfigurations = data[17],
    };
}

/// Parse a configuration descriptor from raw bytes. Expects at least 9 bytes.
pub fn parseConfig(data: []const u8) ?ConfigDesc {
    if (data.len < 9) return null;
    if (data[1] != DESC_CONFIGURATION) return null;

    return .{
        .bLength = data[0],
        .bDescriptorType = data[1],
        .wTotalLength = readU16(data, 2),
        .bNumInterfaces = data[4],
        .bConfigurationValue = data[5],
        .iConfiguration = data[6],
        .bmAttributes = data[7],
        .bMaxPower = data[8],
    };
}

/// Parse an interface descriptor from raw bytes. Expects at least 9 bytes.
pub fn parseInterface(data: []const u8) ?InterfaceDesc {
    if (data.len < 9) return null;
    if (data[1] != DESC_INTERFACE) return null;

    return .{
        .bLength = data[0],
        .bDescriptorType = data[1],
        .bInterfaceNumber = data[2],
        .bAlternateSetting = data[3],
        .bNumEndpoints = data[4],
        .bInterfaceClass = data[5],
        .bInterfaceSubClass = data[6],
        .bInterfaceProtocol = data[7],
        .iInterface = data[8],
    };
}

/// Parse an endpoint descriptor from raw bytes. Expects at least 7 bytes.
pub fn parseEndpoint(data: []const u8) ?EndpointDesc {
    if (data.len < 7) return null;
    if (data[1] != DESC_ENDPOINT) return null;

    return .{
        .bLength = data[0],
        .bDescriptorType = data[1],
        .bEndpointAddress = data[2],
        .bmAttributes = data[3],
        .wMaxPacketSize = readU16(data, 4),
        .bInterval = data[6],
    };
}

/// Parse a string descriptor and convert limited UTF-16LE to ASCII.
pub fn parseString(data: []const u8) ?StringDesc {
    if (data.len < 2) return null;
    if (data[1] != DESC_STRING) return null;

    var desc = StringDesc{
        .bLength = data[0],
        .bDescriptorType = data[1],
        .data = @splat(0),
        .data_len = 0,
    };

    // String data starts at offset 2, UTF-16LE encoded
    const str_bytes = data[0] -| 2;
    var i: usize = 0;
    var out_idx: usize = 0;
    while (i < str_bytes and i + 2 + 1 < data.len and out_idx < 126) : (i += 2) {
        const lo = data[2 + i];
        const hi = data[2 + i + 1];
        // Simple UTF-16 to ASCII: only convert BMP codepoints <= 0x7F
        if (hi == 0 and lo >= 0x20 and lo < 0x7F) {
            desc.data[out_idx] = lo;
        } else {
            desc.data[out_idx] = '?'; // Non-ASCII placeholder
        }
        out_idx += 1;
    }
    desc.data_len = @truncate(out_idx);

    return desc;
}

/// Walk a configuration descriptor block and parse all contained descriptors.
pub fn parseFullConfig(data: []const u8) ParsedConfig {
    var result = ParsedConfig{
        .device = .{
            .bLength = 0,
            .bDescriptorType = 0,
            .bcdUSB = 0,
            .bDeviceClass = 0,
            .bDeviceSubClass = 0,
            .bDeviceProtocol = 0,
            .bMaxPacketSize0 = 0,
            .idVendor = 0,
            .idProduct = 0,
            .bcdDevice = 0,
            .iManufacturer = 0,
            .iProduct = 0,
            .iSerialNumber = 0,
            .bNumConfigurations = 0,
        },
        .configs = undefined,
        .config_count = 0,
        .interfaces = undefined,
        .interface_count = 0,
        .endpoints = undefined,
        .endpoint_count = 0,
    };

    var offset: usize = 0;
    while (offset + 2 <= data.len) {
        const blen = data[offset];
        if (blen < 2 or offset + blen > data.len) break;

        const btype = data[offset + 1];

        switch (btype) {
            DESC_DEVICE => {
                if (parseDevice(data[offset..])) |dev| {
                    result.device = dev;
                }
            },
            DESC_CONFIGURATION => {
                if (result.config_count < 4) {
                    if (parseConfig(data[offset..])) |cfg| {
                        result.configs[result.config_count] = cfg;
                        result.config_count += 1;
                    }
                }
            },
            DESC_INTERFACE => {
                if (result.interface_count < 8) {
                    if (parseInterface(data[offset..])) |iface| {
                        result.interfaces[result.interface_count] = iface;
                        result.interface_count += 1;
                    }
                }
            },
            DESC_ENDPOINT => {
                if (result.endpoint_count < 16) {
                    if (parseEndpoint(data[offset..])) |ep| {
                        result.endpoints[result.endpoint_count] = ep;
                        result.endpoint_count += 1;
                    }
                }
            },
            else => {},
        }

        offset += blen;
    }

    return result;
}

// ---- USB class name lookup ----

/// Get a human-readable name for a USB class code.
pub fn getClassName(class: u8) []const u8 {
    return switch (class) {
        0x00 => "Device",
        CLASS_AUDIO => "Audio",
        CLASS_CDC => "CDC (Comm)",
        CLASS_HID => "HID",
        CLASS_PHYSICAL => "Physical",
        CLASS_IMAGE => "Image",
        CLASS_PRINTER => "Printer",
        CLASS_MASS_STORAGE => "Mass Storage",
        CLASS_HUB => "Hub",
        CLASS_CDC_DATA => "CDC Data",
        CLASS_SMART_CARD => "Smart Card",
        CLASS_CONTENT_SEC => "Content Security",
        CLASS_VIDEO => "Video",
        CLASS_HEALTHCARE => "Healthcare",
        CLASS_AV => "Audio/Video",
        CLASS_BILLBOARD => "Billboard",
        CLASS_USB_C_BRIDGE => "USB-C Bridge",
        CLASS_DIAGNOSTIC => "Diagnostic",
        CLASS_WIRELESS => "Wireless",
        CLASS_MISC => "Miscellaneous",
        CLASS_APP_SPECIFIC => "Application Specific",
        CLASS_VENDOR_SPEC => "Vendor Specific",
        else => "Unknown",
    };
}

/// Get the transfer type name for an endpoint.
pub fn getTransferTypeName(bmAttributes: u8) []const u8 {
    return switch (bmAttributes & 0x03) {
        EP_TRANSFER_CONTROL => "Control",
        EP_TRANSFER_ISOCHRONOUS => "Isochronous",
        EP_TRANSFER_BULK => "Bulk",
        EP_TRANSFER_INTERRUPT => "Interrupt",
        else => "Unknown",
    };
}

/// Get the descriptor type name.
pub fn getDescTypeName(desc_type: u8) []const u8 {
    return switch (desc_type) {
        DESC_DEVICE => "Device",
        DESC_CONFIGURATION => "Configuration",
        DESC_STRING => "String",
        DESC_INTERFACE => "Interface",
        DESC_ENDPOINT => "Endpoint",
        DESC_DEVICE_QUALIFIER => "Device Qualifier",
        DESC_OTHER_SPEED_CONFIG => "Other Speed Config",
        DESC_INTERFACE_POWER => "Interface Power",
        DESC_OTG => "OTG",
        DESC_DEBUG => "Debug",
        DESC_INTERFACE_ASSOC => "Interface Assoc",
        DESC_BOS => "BOS",
        DESC_DEVICE_CAP => "Device Capability",
        DESC_HID => "HID",
        DESC_HID_REPORT => "HID Report",
        DESC_HID_PHYSICAL => "HID Physical",
        DESC_CS_INTERFACE => "CS Interface",
        DESC_CS_ENDPOINT => "CS Endpoint",
        DESC_HUB => "Hub",
        DESC_SUPERSPEED_HUB => "SS Hub",
        DESC_SS_EP_COMPANION => "SS EP Companion",
        else => "Unknown",
    };
}

// ---- Display functions ----

/// Print a device descriptor.
pub fn printDeviceDesc(dev: *const DeviceDesc) void {
    vga.write("  USB ");
    printBCD(dev.bcdUSB);
    vga.write(" Device\n");

    vga.write("    VID:PID   ");
    printHex16(dev.idVendor);
    vga.putChar(':');
    printHex16(dev.idProduct);
    vga.putChar('\n');

    vga.write("    Class:    ");
    printHex8(dev.bDeviceClass);
    vga.write(" (");
    vga.write(getClassName(dev.bDeviceClass));
    vga.write(")\n");

    vga.write("    SubClass: ");
    printHex8(dev.bDeviceSubClass);
    vga.write("  Protocol: ");
    printHex8(dev.bDeviceProtocol);
    vga.putChar('\n');

    vga.write("    MaxPkt0:  ");
    printDecU8(dev.bMaxPacketSize0);
    vga.putChar('\n');

    vga.write("    Configs:  ");
    printDecU8(dev.bNumConfigurations);
    vga.putChar('\n');

    vga.write("    Release:  ");
    printBCD(dev.bcdDevice);
    vga.putChar('\n');

    vga.write("    Strings:  Mfg=");
    printDecU8(dev.iManufacturer);
    vga.write(" Prod=");
    printDecU8(dev.iProduct);
    vga.write(" Ser=");
    printDecU8(dev.iSerialNumber);
    vga.putChar('\n');
}

/// Print a configuration descriptor.
pub fn printConfigDesc(cfg: *const ConfigDesc) void {
    vga.write("    Config #");
    printDecU8(cfg.bConfigurationValue);
    vga.putChar('\n');

    vga.write("      Interfaces:  ");
    printDecU8(cfg.bNumInterfaces);
    vga.putChar('\n');

    vga.write("      TotalLen:    ");
    printDec16(cfg.wTotalLength);
    vga.putChar('\n');

    vga.write("      Attributes:  0x");
    printHex8(cfg.bmAttributes);
    if (cfg.bmAttributes & 0x40 != 0) vga.write(" SelfPowered");
    if (cfg.bmAttributes & 0x20 != 0) vga.write(" RemoteWakeup");
    vga.putChar('\n');

    vga.write("      MaxPower:    ");
    printDec16(@as(u16, cfg.bMaxPower) * 2);
    vga.write(" mA\n");
}

/// Print an interface descriptor.
pub fn printInterfaceDesc(iface: *const InterfaceDesc) void {
    vga.write("      Interface #");
    printDecU8(iface.bInterfaceNumber);
    vga.write(" Alt ");
    printDecU8(iface.bAlternateSetting);
    vga.putChar('\n');

    vga.write("        Class:     ");
    printHex8(iface.bInterfaceClass);
    vga.write(" (");
    vga.write(getClassName(iface.bInterfaceClass));
    vga.write(")\n");

    vga.write("        SubClass:  ");
    printHex8(iface.bInterfaceSubClass);
    vga.write("  Protocol: ");
    printHex8(iface.bInterfaceProtocol);
    vga.putChar('\n');

    vga.write("        Endpoints: ");
    printDecU8(iface.bNumEndpoints);
    vga.putChar('\n');
}

/// Print an endpoint descriptor.
pub fn printEndpointDesc(ep: *const EndpointDesc) void {
    const ep_num = ep.bEndpointAddress & 0x0F;
    const ep_dir = if (ep.bEndpointAddress & 0x80 != 0) "IN " else "OUT";

    vga.write("        EP ");
    printDecU8(ep_num);
    vga.write(" ");
    vga.write(ep_dir);
    vga.write("  ");
    vga.write(getTransferTypeName(ep.bmAttributes));
    vga.write("  MaxPkt=");
    printDec16(ep.wMaxPacketSize & 0x07FF);
    vga.write("  Interval=");
    printDecU8(ep.bInterval);
    vga.putChar('\n');
}

/// Print all descriptors from a raw data buffer.
pub fn printDescriptors(data: []const u8) void {
    vga.setColor(.yellow, .black);
    vga.write("USB Descriptors:\n");
    vga.setColor(.light_grey, .black);

    if (data.len < 2) {
        vga.write("  No data\n");
        return;
    }

    const parsed = parseFullConfig(data);

    // Device descriptor
    if (parsed.device.bDescriptorType == DESC_DEVICE) {
        printDeviceDesc(&parsed.device);
    }

    // Configurations
    var ci: u8 = 0;
    while (ci < parsed.config_count) : (ci += 1) {
        printConfigDesc(&parsed.configs[ci]);
    }

    // Interfaces
    var ii: u8 = 0;
    while (ii < parsed.interface_count) : (ii += 1) {
        printInterfaceDesc(&parsed.interfaces[ii]);
    }

    // Endpoints
    var ei: u8 = 0;
    while (ei < parsed.endpoint_count) : (ei += 1) {
        printEndpointDesc(&parsed.endpoints[ei]);
    }
}

/// Print a raw descriptor dump (hex bytes with type annotations).
pub fn printRawDescriptors(data: []const u8) void {
    vga.setColor(.yellow, .black);
    vga.write("Raw USB Descriptor Dump:\n");
    vga.setColor(.light_grey, .black);

    var offset: usize = 0;
    var desc_num: u8 = 0;

    while (offset + 2 <= data.len) {
        const blen = data[offset];
        if (blen < 2 or offset + blen > data.len) break;

        desc_num += 1;
        vga.write("  [");
        printDecU8(desc_num);
        vga.write("] Type=0x");
        printHex8(data[offset + 1]);
        vga.write(" (");
        vga.write(getDescTypeName(data[offset + 1]));
        vga.write(") Len=");
        printDecU8(blen);
        vga.putChar('\n');

        // Print hex bytes
        vga.write("      ");
        var i: usize = 0;
        while (i < blen and offset + i < data.len) : (i += 1) {
            printHex8(data[offset + i]);
            vga.putChar(' ');
            if (i > 0 and i % 16 == 15) {
                vga.write("\n      ");
            }
        }
        vga.putChar('\n');

        offset += blen;
    }
}

// ---- Utility functions ----

/// Check if endpoint is IN direction.
pub fn isEndpointIn(ep: *const EndpointDesc) bool {
    return (ep.bEndpointAddress & 0x80) != 0;
}

/// Get endpoint number (0-15).
pub fn getEndpointNumber(ep: *const EndpointDesc) u4 {
    return @truncate(ep.bEndpointAddress & 0x0F);
}

/// Get endpoint transfer type.
pub fn getTransferType(ep: *const EndpointDesc) u2 {
    return @truncate(ep.bmAttributes & 0x03);
}

/// Check if configuration is self-powered.
pub fn isSelfPowered(cfg: *const ConfigDesc) bool {
    return (cfg.bmAttributes & 0x40) != 0;
}

/// Check if configuration supports remote wakeup.
pub fn supportsRemoteWakeup(cfg: *const ConfigDesc) bool {
    return (cfg.bmAttributes & 0x20) != 0;
}

/// Get max power in milliamps.
pub fn getMaxPowerMa(cfg: *const ConfigDesc) u16 {
    return @as(u16, cfg.bMaxPower) * 2;
}

// ---- Internal helpers ----

fn readU16(data: []const u8, offset: usize) u16 {
    if (offset + 1 >= data.len) return 0;
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn printBCD(val: u16) void {
    // BCD format: 0x0210 -> "2.10"
    const major = (val >> 8) & 0xFF;
    const minor = val & 0xFF;

    printDecU8(@truncate(major));
    vga.putChar('.');
    // Minor always 2 digits
    printHex8(@truncate(minor));
}

fn printHex16(val: u16) void {
    const hex = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;
    var v = val;
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xF];
        v >>= 4;
    }
    vga.write(&buf);
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    vga.putChar(hex[val >> 4]);
    vga.putChar(hex[val & 0xF]);
}

fn printDecU8(val: u8) void {
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
