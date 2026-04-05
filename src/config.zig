// System configuration -- key-value INI-like config store with ramfs persistence
//
// Supports sections, key=value pairs, and comments.
// INI format:
//   [section]
//   key=value
//   # comment

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");

// ---- Constants ----

const MAX_ENTRIES = 32;
const MAX_SECTION = 8;
const MAX_KEY = 16;
const MAX_VALUE = 32;

// ---- Entry type ----

const Entry = struct {
    section: [MAX_SECTION]u8,
    section_len: u8,
    key: [MAX_KEY]u8,
    key_len: u8,
    value: [MAX_VALUE]u8,
    value_len: u8,
    used: bool,
};

// ---- State ----

var entries: [MAX_ENTRIES]Entry = undefined;
var initialized: bool = false;

// ---- Public API ----

/// Initialize config with default values.
pub fn init() void {
    for (&entries) |*e| {
        e.used = false;
        e.section_len = 0;
        e.key_len = 0;
        e.value_len = 0;
    }
    initialized = true;

    // Default [system] entries
    _ = set("system", "hostname", "zig-os");
    _ = set("system", "version", "0.3.4");
    _ = set("system", "arch", "x86");
    _ = set("system", "ticks_hz", "1000");

    // Default [network] entries
    _ = set("network", "ip", "10.0.2.16");
    _ = set("network", "netmask", "255.255.255.0");
    _ = set("network", "gateway", "10.0.2.1");
    _ = set("network", "dns", "10.0.2.3");

    // Default [display] entries
    _ = set("display", "colors", "16");
    _ = set("display", "width", "80");
    _ = set("display", "height", "25");
    _ = set("display", "mode", "text");
}

/// Get a value by section and key.
/// Returns the value slice, or null if not found.
pub fn get(section: []const u8, key: []const u8) ?[]const u8 {
    for (&entries) |*e| {
        if (!e.used) continue;
        if (e.section_len == section.len and e.key_len == key.len) {
            if (sliceEql(e.section[0..e.section_len], section) and
                sliceEql(e.key[0..e.key_len], key))
            {
                return e.value[0..e.value_len];
            }
        }
    }
    return null;
}

/// Set a value. Returns true on success.
/// If the key already exists in the section, updates it.
/// Otherwise, adds a new entry.
pub fn set(section: []const u8, key: []const u8, value: []const u8) bool {
    if (section.len > MAX_SECTION or key.len > MAX_KEY or value.len > MAX_VALUE) {
        return false;
    }

    // Try to find existing entry
    for (&entries) |*e| {
        if (!e.used) continue;
        if (e.section_len == section.len and e.key_len == key.len) {
            if (sliceEql(e.section[0..e.section_len], section) and
                sliceEql(e.key[0..e.key_len], key))
            {
                // Update value
                e.value_len = @intCast(value.len);
                @memcpy(e.value[0..e.value_len], value[0..value.len]);
                return true;
            }
        }
    }

    // Find a free slot
    for (&entries) |*e| {
        if (!e.used) {
            e.used = true;
            e.section_len = @intCast(section.len);
            @memcpy(e.section[0..e.section_len], section[0..section.len]);
            e.key_len = @intCast(key.len);
            @memcpy(e.key[0..e.key_len], key[0..key.len]);
            e.value_len = @intCast(value.len);
            @memcpy(e.value[0..e.value_len], value[0..value.len]);
            return true;
        }
    }

    return false; // No free slots
}

/// Remove an entry by section and key.
pub fn remove(section: []const u8, key: []const u8) bool {
    for (&entries) |*e| {
        if (!e.used) continue;
        if (e.section_len == section.len and e.key_len == key.len) {
            if (sliceEql(e.section[0..e.section_len], section) and
                sliceEql(e.key[0..e.key_len], key))
            {
                e.used = false;
                return true;
            }
        }
    }
    return false;
}

/// Load config from an INI file in ramfs.
/// Replaces all current entries.
pub fn loadFromFile(filename: []const u8) bool {
    const idx = ramfs.findByName(filename) orelse return false;
    var buf: [ramfs.MAX_DATA]u8 = undefined;
    const size = ramfs.readFile(idx, &buf);
    if (size == 0) return false;

    // Clear existing entries
    for (&entries) |*e| {
        e.used = false;
    }

    // Parse INI
    var current_section: [MAX_SECTION]u8 = undefined;
    var current_section_len: u8 = 0;

    var pos: usize = 0;
    while (pos < size) {
        // Find end of line
        var line_end = pos;
        while (line_end < size and buf[line_end] != '\n') : (line_end += 1) {}

        const line = trimSlice(buf[pos..line_end]);
        pos = line_end;
        if (pos < size) pos += 1; // skip '\n'

        if (line.len == 0) continue;

        // Comment
        if (line[0] == '#' or line[0] == ';') continue;

        // Section header: [name]
        if (line[0] == '[') {
            // Find closing bracket
            var bracket_end: usize = 1;
            while (bracket_end < line.len and line[bracket_end] != ']') : (bracket_end += 1) {}
            if (bracket_end > 1) {
                const sec_name = line[1..bracket_end];
                current_section_len = @intCast(@min(sec_name.len, MAX_SECTION));
                @memcpy(current_section[0..current_section_len], sec_name[0..current_section_len]);
            }
            continue;
        }

        // Key=value
        var eq_pos: ?usize = null;
        for (line, 0..) |c, i| {
            if (c == '=') {
                eq_pos = i;
                break;
            }
        }
        if (eq_pos) |eq| {
            if (current_section_len == 0) continue;
            const k = trimSlice(line[0..eq]);
            const v = trimSlice(line[eq + 1 ..]);
            if (k.len > 0 and k.len <= MAX_KEY and v.len <= MAX_VALUE) {
                _ = set(current_section[0..current_section_len], k, v);
            }
        }
    }

    return true;
}

/// Save config to an INI file in ramfs.
pub fn saveToFile(filename: []const u8) bool {
    var buf: [ramfs.MAX_DATA]u8 = undefined;
    var pos: usize = 0;

    // Collect unique sections
    var sections: [MAX_ENTRIES][MAX_SECTION]u8 = undefined;
    var section_lens: [MAX_ENTRIES]u8 = undefined;
    var section_count: usize = 0;

    for (&entries) |*e| {
        if (!e.used) continue;
        // Check if section is already in list
        var found = false;
        var s: usize = 0;
        while (s < section_count) : (s += 1) {
            if (section_lens[s] == e.section_len and
                sliceEql(sections[s][0..section_lens[s]], e.section[0..e.section_len]))
            {
                found = true;
                break;
            }
        }
        if (!found and section_count < MAX_ENTRIES) {
            section_lens[section_count] = e.section_len;
            @memcpy(sections[section_count][0..e.section_len], e.section[0..e.section_len]);
            section_count += 1;
        }
    }

    // Write each section
    var si: usize = 0;
    while (si < section_count) : (si += 1) {
        const sec = sections[si][0..section_lens[si]];

        // Write section header
        if (pos + sec.len + 4 > ramfs.MAX_DATA) break;
        if (si > 0) {
            buf[pos] = '\n';
            pos += 1;
        }
        buf[pos] = '[';
        pos += 1;
        @memcpy(buf[pos .. pos + sec.len], sec);
        pos += sec.len;
        buf[pos] = ']';
        pos += 1;
        buf[pos] = '\n';
        pos += 1;

        // Write entries for this section
        for (&entries) |*e| {
            if (!e.used) continue;
            if (e.section_len != sec.len) continue;
            if (!sliceEql(e.section[0..e.section_len], sec)) continue;

            const k = e.key[0..e.key_len];
            const v = e.value[0..e.value_len];

            if (pos + k.len + 1 + v.len + 1 > ramfs.MAX_DATA) break;
            @memcpy(buf[pos .. pos + k.len], k);
            pos += k.len;
            buf[pos] = '=';
            pos += 1;
            @memcpy(buf[pos .. pos + v.len], v);
            pos += v.len;
            buf[pos] = '\n';
            pos += 1;
        }
    }

    // Write to file
    const idx = ramfs.findByName(filename) orelse (ramfs.create(filename) orelse return false);
    const written = ramfs.writeFile(idx, buf[0..pos]);
    return written > 0;
}

/// Print all config entries grouped by section.
pub fn printAll() void {
    // Collect unique sections
    var sections: [MAX_ENTRIES][MAX_SECTION]u8 = undefined;
    var section_lens: [MAX_ENTRIES]u8 = undefined;
    var section_count: usize = 0;

    for (&entries) |*e| {
        if (!e.used) continue;
        var found = false;
        var s: usize = 0;
        while (s < section_count) : (s += 1) {
            if (section_lens[s] == e.section_len and
                sliceEql(sections[s][0..section_lens[s]], e.section[0..e.section_len]))
            {
                found = true;
                break;
            }
        }
        if (!found and section_count < MAX_ENTRIES) {
            section_lens[section_count] = e.section_len;
            @memcpy(sections[section_count][0..e.section_len], e.section[0..e.section_len]);
            section_count += 1;
        }
    }

    if (section_count == 0) {
        vga.write("(no configuration entries)\n");
        return;
    }

    var total: usize = 0;
    var si: usize = 0;
    while (si < section_count) : (si += 1) {
        const sec = sections[si][0..section_lens[si]];

        vga.setColor(.light_cyan, .black);
        vga.write("[");
        vga.write(sec);
        vga.write("]\n");

        for (&entries) |*e| {
            if (!e.used) continue;
            if (e.section_len != sec.len) continue;
            if (!sliceEql(e.section[0..e.section_len], sec)) continue;

            vga.setColor(.light_grey, .black);
            vga.write("  ");
            vga.setColor(.yellow, .black);
            vga.write(e.key[0..e.key_len]);
            vga.setColor(.light_grey, .black);
            vga.write(" = ");
            vga.setColor(.white, .black);
            vga.write(e.value[0..e.value_len]);
            vga.putChar('\n');
            total += 1;
        }
    }
    vga.setColor(.dark_grey, .black);
    fmt.printDec(total);
    vga.write(" entries in ");
    fmt.printDec(section_count);
    vga.write(" sections\n");
    vga.setColor(.light_grey, .black);
}

/// Count the number of active entries.
pub fn count() usize {
    var c: usize = 0;
    for (&entries) |*e| {
        if (e.used) c += 1;
    }
    return c;
}

// ---- Utility ----

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trimSlice(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}
