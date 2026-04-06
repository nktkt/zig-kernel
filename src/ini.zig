// INI file parser -- Full-featured INI document handling
// Sections, key-value pairs, comments, multi-line values (backslash continuation).
// Merge, validate, serialize.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- Constants ----

const MAX_SECTIONS = 16;
const MAX_KEYS_PER_SECTION = 16;
const MAX_SECTION_NAME = 32;
const MAX_KEY_LEN = 32;
const MAX_VALUE_LEN = 64;
const MAX_LINE_LEN = 128;

// ---- Data types ----

pub const ValueType = enum(u8) {
    string,
    integer,
    boolean,
    unknown,
};

pub const KeyValue = struct {
    key: [MAX_KEY_LEN]u8,
    key_len: u8,
    value: [MAX_VALUE_LEN]u8,
    value_len: u8,
    used: bool,
};

pub const Section = struct {
    name: [MAX_SECTION_NAME]u8,
    name_len: u8,
    entries: [MAX_KEYS_PER_SECTION]KeyValue,
    entry_count: usize,
    used: bool,
};

pub const IniDoc = struct {
    sections: [MAX_SECTIONS]Section,
    section_count: usize,
};

// ---- Parsing ----

/// Parse INI text into an IniDoc. Handles sections, key=value, comments, multi-line.
pub fn parse(text: []const u8) IniDoc {
    var doc: IniDoc = undefined;
    doc.section_count = 0;
    var i: usize = 0;
    while (i < MAX_SECTIONS) : (i += 1) {
        doc.sections[i].used = false;
        doc.sections[i].entry_count = 0;
        doc.sections[i].name_len = 0;
        var j: usize = 0;
        while (j < MAX_KEYS_PER_SECTION) : (j += 1) {
            doc.sections[i].entries[j].used = false;
            doc.sections[i].entries[j].key_len = 0;
            doc.sections[i].entries[j].value_len = 0;
        }
    }

    // Create a default global section (unnamed) at index 0
    doc.sections[0].used = true;
    doc.sections[0].name_len = 0;
    doc.sections[0].entry_count = 0;
    doc.section_count = 1;

    var current_section: usize = 0; // index into sections
    var pos: usize = 0;

    // Multi-line continuation state
    var continuation = false;
    var cont_sec: usize = 0;
    var cont_entry: usize = 0;

    while (pos < text.len) {
        // Extract line
        var line_end = pos;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

        var line = trimSlice(stripCR(text[pos..line_end]));
        pos = if (line_end < text.len) line_end + 1 else line_end;

        // Handle multi-line continuation
        if (continuation) {
            // Append to previous value
            const sec = &doc.sections[cont_sec];
            const entry = &sec.entries[cont_entry];
            const remain = MAX_VALUE_LEN - entry.value_len;
            if (remain > 0) {
                // Check if this line also has a continuation backslash
                var append_line = line;
                continuation = false;
                if (append_line.len > 0 and append_line[append_line.len - 1] == '\\') {
                    append_line = append_line[0 .. append_line.len - 1];
                    continuation = true;
                }
                const copy_len = @min(append_line.len, remain);
                @memcpy(entry.value[entry.value_len .. entry.value_len + copy_len], append_line[0..copy_len]);
                entry.value_len += @intCast(copy_len);
            } else {
                continuation = false;
            }
            continue;
        }

        if (line.len == 0) continue;

        // Comment
        if (line[0] == '#' or line[0] == ';') continue;

        // Section header: [name]
        if (line[0] == '[') {
            var bracket_end: usize = 1;
            while (bracket_end < line.len and line[bracket_end] != ']') : (bracket_end += 1) {}
            if (bracket_end > 1) {
                const sec_name = trimSlice(line[1..bracket_end]);
                current_section = findOrCreateSection(&doc, sec_name);
            }
            continue;
        }

        // Key=value
        var eq_pos: ?usize = null;
        for (line, 0..) |c, idx| {
            if (c == '=') {
                eq_pos = idx;
                break;
            }
        }
        if (eq_pos) |eq| {
            const key = trimSlice(line[0..eq]);
            var value = trimSlice(line[eq + 1 ..]);

            if (key.len == 0 or key.len > MAX_KEY_LEN) continue;

            // Check for backslash continuation
            continuation = false;
            if (value.len > 0 and value[value.len - 1] == '\\') {
                value = value[0 .. value.len - 1];
                continuation = true;
            }

            const entry_idx = addEntry(&doc, current_section, key, value);
            if (continuation) {
                cont_sec = current_section;
                cont_entry = entry_idx;
            }
        }
    }

    return doc;
}

/// Get a value from the document by section name and key.
pub fn get(doc: *const IniDoc, section: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        const sec = &doc.sections[i];
        if (!sec.used) continue;
        if (!sliceEql(sec.name[0..sec.name_len], section)) continue;

        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            const entry = &sec.entries[j];
            if (!entry.used) continue;
            if (sliceEql(entry.key[0..entry.key_len], key)) {
                return entry.value[0..entry.value_len];
            }
        }
    }
    return null;
}

/// Set a value in the document (creates section/key if needed).
pub fn set(doc: *IniDoc, section: []const u8, key: []const u8, value: []const u8) bool {
    if (key.len > MAX_KEY_LEN or value.len > MAX_VALUE_LEN) return false;

    const sec_idx = findOrCreateSection(doc, section);
    if (sec_idx >= MAX_SECTIONS) return false;

    const sec = &doc.sections[sec_idx];

    // Try to find existing key
    var j: usize = 0;
    while (j < sec.entry_count) : (j += 1) {
        const entry = &sec.entries[j];
        if (!entry.used) continue;
        if (sliceEql(entry.key[0..entry.key_len], key)) {
            // Update value
            entry.value_len = @intCast(value.len);
            @memcpy(entry.value[0..entry.value_len], value[0..value.len]);
            return true;
        }
    }

    // Add new entry
    _ = addEntry(doc, sec_idx, key, value);
    return true;
}

/// Serialize the document back to INI text in the buffer.
/// Returns the number of bytes written.
pub fn serialize(doc: *const IniDoc, buf: []u8) usize {
    var pos: usize = 0;

    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        const sec = &doc.sections[i];
        if (!sec.used) continue;
        if (sec.entry_count == 0) continue;

        // Blank line between sections
        if (pos > 0 and pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }

        // Write section header (skip for global section with empty name)
        if (sec.name_len > 0) {
            if (pos + sec.name_len + 3 > buf.len) break;
            buf[pos] = '[';
            pos += 1;
            @memcpy(buf[pos .. pos + sec.name_len], sec.name[0..sec.name_len]);
            pos += sec.name_len;
            buf[pos] = ']';
            pos += 1;
            buf[pos] = '\n';
            pos += 1;
        }

        // Write entries
        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            const entry = &sec.entries[j];
            if (!entry.used) continue;

            const needed = @as(usize, entry.key_len) + 1 + @as(usize, entry.value_len) + 1;
            if (pos + needed > buf.len) break;

            @memcpy(buf[pos .. pos + entry.key_len], entry.key[0..entry.key_len]);
            pos += entry.key_len;
            buf[pos] = '=';
            pos += 1;
            @memcpy(buf[pos .. pos + entry.value_len], entry.value[0..entry.value_len]);
            pos += entry.value_len;
            buf[pos] = '\n';
            pos += 1;
        }
    }

    return pos;
}

/// Merge two IniDoc: overlay values override base values.
pub fn merge(base: *const IniDoc, overlay: *const IniDoc) IniDoc {
    // Start with a copy of base
    var result: IniDoc = base.*;

    // Apply overlay entries
    var i: usize = 0;
    while (i < overlay.section_count) : (i += 1) {
        const sec = &overlay.sections[i];
        if (!sec.used) continue;

        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            const entry = &sec.entries[j];
            if (!entry.used) continue;
            _ = set(&result, sec.name[0..sec.name_len], entry.key[0..entry.key_len], entry.value[0..entry.value_len]);
        }
    }

    return result;
}

/// Detect the type of a value string.
pub fn detectType(value: []const u8) ValueType {
    if (value.len == 0) return .string;

    // Boolean check
    if (sliceEqlI(value, "true") or sliceEqlI(value, "false") or
        sliceEqlI(value, "yes") or sliceEqlI(value, "no") or
        sliceEqlI(value, "on") or sliceEqlI(value, "off"))
    {
        return .boolean;
    }

    // Integer check
    var start: usize = 0;
    if (value[0] == '-' or value[0] == '+') start = 1;
    if (start >= value.len) return .string;

    var all_digits = true;
    var idx: usize = start;
    while (idx < value.len) : (idx += 1) {
        if (value[idx] < '0' or value[idx] > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) return .integer;

    return .string;
}

/// Parse value as boolean. Returns null if not a boolean.
pub fn parseBool(value: []const u8) ?bool {
    if (sliceEqlI(value, "true") or sliceEqlI(value, "yes") or sliceEqlI(value, "on") or sliceEqlI(value, "1")) {
        return true;
    }
    if (sliceEqlI(value, "false") or sliceEqlI(value, "no") or sliceEqlI(value, "off") or sliceEqlI(value, "0")) {
        return false;
    }
    return null;
}

/// Parse value as integer. Returns null if not a valid integer.
pub fn parseInt(value: []const u8) ?i32 {
    if (value.len == 0) return null;
    var negative = false;
    var start: usize = 0;
    if (value[0] == '-') {
        negative = true;
        start = 1;
    } else if (value[0] == '+') {
        start = 1;
    }
    if (start >= value.len) return null;

    var result: i32 = 0;
    var idx: usize = start;
    while (idx < value.len) : (idx += 1) {
        if (value[idx] < '0' or value[idx] > '9') return null;
        result = result * 10 + @as(i32, value[idx] - '0');
    }
    return if (negative) -result else result;
}

/// Check for duplicate keys in a section. Returns count of duplicates.
pub fn checkDuplicates(doc: *const IniDoc, section: []const u8) usize {
    var dups: usize = 0;
    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        const sec = &doc.sections[i];
        if (!sec.used) continue;
        if (!sliceEql(sec.name[0..sec.name_len], section)) continue;

        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            const e1 = &sec.entries[j];
            if (!e1.used) continue;
            var k: usize = j + 1;
            while (k < sec.entry_count) : (k += 1) {
                const e2 = &sec.entries[k];
                if (!e2.used) continue;
                if (e1.key_len == e2.key_len and sliceEql(e1.key[0..e1.key_len], e2.key[0..e2.key_len])) {
                    dups += 1;
                }
            }
        }
    }
    return dups;
}

/// Print the entire document to VGA.
pub fn printDoc(doc: *const IniDoc) void {
    vga.setColor(.light_cyan, .black);
    vga.write("=== INI Document ===\n");

    var total_entries: usize = 0;
    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        const sec = &doc.sections[i];
        if (!sec.used) continue;

        if (sec.name_len > 0) {
            vga.setColor(.yellow, .black);
            vga.write("[");
            vga.write(sec.name[0..sec.name_len]);
            vga.write("]\n");
        } else {
            vga.setColor(.dark_grey, .black);
            vga.write("[global]\n");
        }

        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            const entry = &sec.entries[j];
            if (!entry.used) continue;

            vga.setColor(.light_grey, .black);
            vga.write("  ");
            vga.setColor(.white, .black);
            vga.write(entry.key[0..entry.key_len]);
            vga.setColor(.light_grey, .black);
            vga.write(" = ");
            vga.setColor(.light_green, .black);
            vga.write(entry.value[0..entry.value_len]);

            // Show detected type
            const vtype = detectType(entry.value[0..entry.value_len]);
            vga.setColor(.dark_grey, .black);
            switch (vtype) {
                .integer => vga.write(" [int]"),
                .boolean => vga.write(" [bool]"),
                .string => vga.write(" [str]"),
                .unknown => vga.write(" [?]"),
            }
            vga.putChar('\n');
            total_entries += 1;
        }
    }

    vga.setColor(.dark_grey, .black);
    fmt.printDec(total_entries);
    vga.write(" entries in ");
    fmt.printDec(doc.section_count);
    vga.write(" sections\n");
    vga.setColor(.light_grey, .black);
}

/// Count total entries across all sections.
pub fn countEntries(doc: *const IniDoc) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        const sec = &doc.sections[i];
        if (!sec.used) continue;
        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            if (sec.entries[j].used) total += 1;
        }
    }
    return total;
}

/// Remove a key from a section. Returns true if found and removed.
pub fn removeKey(doc: *IniDoc, section: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        const sec = &doc.sections[i];
        if (!sec.used) continue;
        if (!sliceEql(sec.name[0..sec.name_len], section)) continue;

        var j: usize = 0;
        while (j < sec.entry_count) : (j += 1) {
            const entry = &sec.entries[j];
            if (!entry.used) continue;
            if (sliceEql(entry.key[0..entry.key_len], key)) {
                entry.used = false;
                return true;
            }
        }
    }
    return false;
}

// ---- Internal helpers ----

fn findOrCreateSection(doc: *IniDoc, name: []const u8) usize {
    // Search existing sections
    var i: usize = 0;
    while (i < doc.section_count) : (i += 1) {
        if (doc.sections[i].used and
            doc.sections[i].name_len == name.len and
            sliceEql(doc.sections[i].name[0..doc.sections[i].name_len], name))
        {
            return i;
        }
    }
    // Create new section
    if (doc.section_count < MAX_SECTIONS) {
        const idx = doc.section_count;
        doc.sections[idx].used = true;
        doc.sections[idx].name_len = @intCast(@min(name.len, MAX_SECTION_NAME));
        @memcpy(doc.sections[idx].name[0..doc.sections[idx].name_len], name[0..doc.sections[idx].name_len]);
        doc.sections[idx].entry_count = 0;
        var j: usize = 0;
        while (j < MAX_KEYS_PER_SECTION) : (j += 1) {
            doc.sections[idx].entries[j].used = false;
        }
        doc.section_count += 1;
        return idx;
    }
    return 0; // fallback to global
}

fn addEntry(doc: *IniDoc, sec_idx: usize, key: []const u8, value: []const u8) usize {
    if (sec_idx >= MAX_SECTIONS) return 0;
    const sec = &doc.sections[sec_idx];

    // Check for existing key (update)
    var j: usize = 0;
    while (j < sec.entry_count) : (j += 1) {
        const entry = &sec.entries[j];
        if (entry.used and entry.key_len == key.len and sliceEql(entry.key[0..entry.key_len], key)) {
            entry.value_len = @intCast(@min(value.len, MAX_VALUE_LEN));
            @memcpy(entry.value[0..entry.value_len], value[0..entry.value_len]);
            return j;
        }
    }

    // Add new entry
    if (sec.entry_count < MAX_KEYS_PER_SECTION) {
        const idx = sec.entry_count;
        sec.entries[idx].used = true;
        sec.entries[idx].key_len = @intCast(@min(key.len, MAX_KEY_LEN));
        @memcpy(sec.entries[idx].key[0..sec.entries[idx].key_len], key[0..sec.entries[idx].key_len]);
        sec.entries[idx].value_len = @intCast(@min(value.len, MAX_VALUE_LEN));
        @memcpy(sec.entries[idx].value[0..sec.entries[idx].value_len], value[0..sec.entries[idx].value_len]);
        sec.entry_count += 1;
        return idx;
    }
    return 0;
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn sliceEqlI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn trimSlice(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

fn stripCR(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}
