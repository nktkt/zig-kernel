// Simple XML parser -- Tokenizer and DOM tree builder
// Supports: elements, attributes, text content, self-closing tags, entities.
// Max nesting depth: 8, max children: 8, max attributes: 4.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- Constants ----

const MAX_DEPTH = 8;
const MAX_CHILDREN = 8;
const MAX_ATTRIBUTES = 4;
const MAX_NAME_LEN = 32;
const MAX_VALUE_LEN = 64;
const MAX_TEXT_LEN = 128;
const MAX_NODES = 64;

// ---- Data types ----

pub const Attribute = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    value: [MAX_VALUE_LEN]u8,
    value_len: u8,
    used: bool,
};

pub const XmlNode = struct {
    tag_name: [MAX_NAME_LEN]u8,
    tag_name_len: u8,
    attributes: [MAX_ATTRIBUTES]Attribute,
    attr_count: usize,
    children: [MAX_CHILDREN]u8, // indices into node pool
    child_count: usize,
    text_content: [MAX_TEXT_LEN]u8,
    text_len: usize,
    is_text_node: bool, // true if this is a pure text node
    used: bool,
};

// Global node pool (no allocator available)
var node_pool: [MAX_NODES]XmlNode = undefined;
var node_pool_count: usize = 0;

fn resetPool() void {
    node_pool_count = 0;
    var i: usize = 0;
    while (i < MAX_NODES) : (i += 1) {
        node_pool[i].used = false;
        node_pool[i].tag_name_len = 0;
        node_pool[i].attr_count = 0;
        node_pool[i].child_count = 0;
        node_pool[i].text_len = 0;
        node_pool[i].is_text_node = false;
        var j: usize = 0;
        while (j < MAX_ATTRIBUTES) : (j += 1) {
            node_pool[i].attributes[j].used = false;
        }
    }
}

fn allocNode() ?u8 {
    if (node_pool_count >= MAX_NODES) return null;
    const idx: u8 = @truncate(node_pool_count);
    node_pool[node_pool_count].used = true;
    node_pool[node_pool_count].tag_name_len = 0;
    node_pool[node_pool_count].attr_count = 0;
    node_pool[node_pool_count].child_count = 0;
    node_pool[node_pool_count].text_len = 0;
    node_pool[node_pool_count].is_text_node = false;
    var j: usize = 0;
    while (j < MAX_ATTRIBUTES) : (j += 1) {
        node_pool[node_pool_count].attributes[j].used = false;
    }
    node_pool_count += 1;
    return idx;
}

pub fn getNode(idx: u8) *XmlNode {
    return &node_pool[idx];
}

// ---- Parser state ----

const ParseState = struct {
    input: []const u8,
    pos: usize,

    fn peek(self: *ParseState) ?u8 {
        if (self.pos < self.input.len) return self.input[self.pos];
        return null;
    }

    fn advance(self: *ParseState) void {
        if (self.pos < self.input.len) self.pos += 1;
    }

    fn skipWhitespace(self: *ParseState) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.pos += 1;
        }
    }

    fn startsWith(self: *ParseState, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        var i: usize = 0;
        while (i < prefix.len) : (i += 1) {
            if (self.input[self.pos + i] != prefix[i]) return false;
        }
        return true;
    }

    fn remaining(self: *ParseState) []const u8 {
        if (self.pos >= self.input.len) return self.input[0..0];
        return self.input[self.pos..];
    }
};

// ---- Public API ----

/// Parse XML text into a DOM tree. Returns the root node index, or null on error.
pub fn parse(text: []const u8) ?*XmlNode {
    resetPool();

    var state = ParseState{ .input = text, .pos = 0 };
    state.skipWhitespace();

    // Skip XML declaration <?xml ... ?>
    if (state.startsWith("<?")) {
        while (state.pos + 1 < state.input.len) {
            if (state.input[state.pos] == '?' and state.input[state.pos + 1] == '>') {
                state.pos += 2;
                break;
            }
            state.pos += 1;
        }
        state.skipWhitespace();
    }

    // Skip DOCTYPE
    if (state.startsWith("<!DOCTYPE") or state.startsWith("<!doctype")) {
        while (state.pos < state.input.len and state.input[state.pos] != '>') : (state.pos += 1) {}
        if (state.pos < state.input.len) state.pos += 1;
        state.skipWhitespace();
    }

    const root_idx = parseElement(&state, 0) orelse return null;
    return &node_pool[root_idx];
}

fn parseElement(state: *ParseState, depth: usize) ?u8 {
    if (depth >= MAX_DEPTH) return null;
    state.skipWhitespace();
    if (state.peek() == null) return null;

    if (state.peek() != '<') {
        // This is text content
        return parseTextNode(state);
    }

    // Skip comments <!-- ... -->
    if (state.startsWith("<!--")) {
        while (state.pos + 2 < state.input.len) {
            if (state.input[state.pos] == '-' and state.input[state.pos + 1] == '-' and state.input[state.pos + 2] == '>') {
                state.pos += 3;
                state.skipWhitespace();
                return parseElement(state, depth);
            }
            state.pos += 1;
        }
        return null;
    }

    // Skip CDATA sections
    if (state.startsWith("<![CDATA[")) {
        state.pos += 9;
        const node_idx = allocNode() orelse return null;
        const node = &node_pool[node_idx];
        node.is_text_node = true;
        while (state.pos + 2 < state.input.len) {
            if (state.input[state.pos] == ']' and state.input[state.pos + 1] == ']' and state.input[state.pos + 2] == '>') {
                state.pos += 3;
                break;
            }
            if (node.text_len < MAX_TEXT_LEN) {
                node.text_content[node.text_len] = state.input[state.pos];
                node.text_len += 1;
            }
            state.pos += 1;
        }
        return node_idx;
    }

    // Opening tag
    state.advance(); // skip '<'

    // Check for closing tag
    if (state.peek() == '/') return null; // unexpected closing tag

    // Parse tag name
    const node_idx = allocNode() orelse return null;
    const node = &node_pool[node_idx];
    parseTagName(state, &node.tag_name, &node.tag_name_len);

    // Parse attributes
    parseAttributes(state, node);

    state.skipWhitespace();

    // Self-closing tag?
    if (state.peek() == '/') {
        state.advance(); // skip '/'
        if (state.peek() == '>') state.advance(); // skip '>'
        return node_idx;
    }

    // Close of opening tag
    if (state.peek() == '>') {
        state.advance();
    } else {
        return null; // malformed
    }

    // Parse children (elements and text)
    while (state.pos < state.input.len) {
        state.skipWhitespace();
        if (state.peek() == null) break;

        // Check for closing tag
        if (state.startsWith("</")) {
            state.pos += 2; // skip '</'
            // Skip tag name
            while (state.pos < state.input.len and state.input[state.pos] != '>') : (state.pos += 1) {}
            if (state.pos < state.input.len) state.pos += 1; // skip '>'
            break;
        }

        // Check for comment
        if (state.startsWith("<!--")) {
            while (state.pos + 2 < state.input.len) {
                if (state.input[state.pos] == '-' and state.input[state.pos + 1] == '-' and state.input[state.pos + 2] == '>') {
                    state.pos += 3;
                    break;
                }
                state.pos += 1;
            }
            continue;
        }

        // Try to parse child element or text
        if (state.peek() == '<') {
            if (node.child_count < MAX_CHILDREN) {
                const child_idx = parseElement(state, depth + 1) orelse break;
                node.children[node.child_count] = child_idx;
                node.child_count += 1;
            } else {
                break;
            }
        } else {
            // Text content until '<'
            const text_start = state.pos;
            while (state.pos < state.input.len and state.input[state.pos] != '<') : (state.pos += 1) {}
            const raw_text = state.input[text_start..state.pos];
            const trimmed = trimSlice(raw_text);
            if (trimmed.len > 0) {
                // Store as text content on this node, or as a text child node
                if (node.text_len == 0) {
                    const copy_len = @min(trimmed.len, MAX_TEXT_LEN);
                    decodeEntities(trimmed[0..copy_len], &node.text_content, &node.text_len);
                } else if (node.child_count < MAX_CHILDREN) {
                    const text_node_idx = allocNode() orelse break;
                    const text_node = &node_pool[text_node_idx];
                    text_node.is_text_node = true;
                    decodeEntities(trimmed, &text_node.text_content, &text_node.text_len);
                    node.children[node.child_count] = text_node_idx;
                    node.child_count += 1;
                }
            }
        }
    }

    return node_idx;
}

fn parseTextNode(state: *ParseState) ?u8 {
    const start = state.pos;
    while (state.pos < state.input.len and state.input[state.pos] != '<') : (state.pos += 1) {}
    const raw_text = trimSlice(state.input[start..state.pos]);
    if (raw_text.len == 0) return null;

    const node_idx = allocNode() orelse return null;
    const node = &node_pool[node_idx];
    node.is_text_node = true;
    decodeEntities(raw_text, &node.text_content, &node.text_len);
    return node_idx;
}

fn parseTagName(state: *ParseState, name: *[MAX_NAME_LEN]u8, name_len: *u8) void {
    name_len.* = 0;
    while (state.pos < state.input.len) {
        const c = state.input[state.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
        if (name_len.* < MAX_NAME_LEN) {
            name[name_len.*] = c;
            name_len.* += 1;
        }
        state.pos += 1;
    }
}

fn parseAttributes(state: *ParseState, node: *XmlNode) void {
    while (state.pos < state.input.len) {
        state.skipWhitespace();
        const c = state.peek() orelse break;
        if (c == '>' or c == '/') break;

        if (node.attr_count >= MAX_ATTRIBUTES) {
            // Skip remaining attributes
            while (state.pos < state.input.len and state.input[state.pos] != '>' and state.input[state.pos] != '/') : (state.pos += 1) {}
            break;
        }

        var attr = &node.attributes[node.attr_count];
        attr.used = true;

        // Parse attribute name
        attr.name_len = 0;
        while (state.pos < state.input.len) {
            const ch = state.input[state.pos];
            if (ch == '=' or ch == ' ' or ch == '>' or ch == '/') break;
            if (attr.name_len < MAX_NAME_LEN) {
                attr.name[attr.name_len] = ch;
                attr.name_len += 1;
            }
            state.pos += 1;
        }

        state.skipWhitespace();

        // Expect '='
        if (state.peek() == '=') {
            state.advance();
        } else {
            // Boolean attribute (no value)
            attr.value_len = 0;
            node.attr_count += 1;
            continue;
        }

        state.skipWhitespace();

        // Parse value (quoted)
        attr.value_len = 0;
        const quote = state.peek();
        if (quote == '"' or quote == '\'') {
            state.advance(); // skip opening quote
            while (state.pos < state.input.len and state.input[state.pos] != quote.?) {
                if (attr.value_len < MAX_VALUE_LEN) {
                    attr.value[attr.value_len] = state.input[state.pos];
                    attr.value_len += 1;
                }
                state.pos += 1;
            }
            if (state.pos < state.input.len) state.advance(); // skip closing quote
        } else {
            // Unquoted value
            while (state.pos < state.input.len) {
                const ch = state.input[state.pos];
                if (ch == ' ' or ch == '>' or ch == '/') break;
                if (attr.value_len < MAX_VALUE_LEN) {
                    attr.value[attr.value_len] = ch;
                    attr.value_len += 1;
                }
                state.pos += 1;
            }
        }

        node.attr_count += 1;
    }
}

// ---- Entity decoding ----

fn decodeEntities(src: []const u8, dst: *[MAX_TEXT_LEN]u8, dst_len: *usize) void {
    var si: usize = 0;
    var di: usize = dst_len.*;
    while (si < src.len and di < MAX_TEXT_LEN) {
        if (src[si] == '&') {
            if (matchEntity(src, si, "&amp;")) {
                dst[di] = '&';
                di += 1;
                si += 5;
            } else if (matchEntity(src, si, "&lt;")) {
                dst[di] = '<';
                di += 1;
                si += 4;
            } else if (matchEntity(src, si, "&gt;")) {
                dst[di] = '>';
                di += 1;
                si += 4;
            } else if (matchEntity(src, si, "&quot;")) {
                dst[di] = '"';
                di += 1;
                si += 6;
            } else if (matchEntity(src, si, "&apos;")) {
                dst[di] = '\'';
                di += 1;
                si += 6;
            } else {
                // Unknown entity, copy as-is
                dst[di] = src[si];
                di += 1;
                si += 1;
            }
        } else {
            dst[di] = src[si];
            di += 1;
            si += 1;
        }
    }
    dst_len.* = di;
}

fn matchEntity(src: []const u8, pos: usize, entity: []const u8) bool {
    if (pos + entity.len > src.len) return false;
    var i: usize = 0;
    while (i < entity.len) : (i += 1) {
        if (src[pos + i] != entity[i]) return false;
    }
    return true;
}

// ---- Query API ----

/// Find first child element by tag name (recursive).
pub fn findByTag(root: *const XmlNode, tag: []const u8) ?*XmlNode {
    // Check root itself
    if (!root.is_text_node and root.tag_name_len == tag.len and
        sliceEql(root.tag_name[0..root.tag_name_len], tag))
    {
        // Return mutable pointer by finding it in pool
        var i: usize = 0;
        while (i < node_pool_count) : (i += 1) {
            if (&node_pool[i] == root) return &node_pool[i];
        }
    }

    // Search children
    var c: usize = 0;
    while (c < root.child_count) : (c += 1) {
        const child = &node_pool[root.children[c]];
        if (!child.is_text_node and child.tag_name_len == tag.len and
            sliceEql(child.tag_name[0..child.tag_name_len], tag))
        {
            return child;
        }
        // Recurse
        if (findByTag(child, tag)) |found| return found;
    }
    return null;
}

/// Get an attribute value by name.
pub fn getAttribute(node: *const XmlNode, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < node.attr_count) : (i += 1) {
        const attr = &node.attributes[i];
        if (attr.used and attr.name_len == name.len and
            sliceEql(attr.name[0..attr.name_len], name))
        {
            return attr.value[0..attr.value_len];
        }
    }
    return null;
}

/// Get the text content of a node (direct text or first text child).
pub fn getText(node: *const XmlNode) ?[]const u8 {
    if (node.text_len > 0) return node.text_content[0..node.text_len];

    // Check first text child
    var c: usize = 0;
    while (c < node.child_count) : (c += 1) {
        const child = &node_pool[node.children[c]];
        if (child.is_text_node and child.text_len > 0) {
            return child.text_content[0..child.text_len];
        }
    }
    return null;
}

/// Get the number of child elements (non-text nodes).
pub fn getChildElementCount(node: *const XmlNode) usize {
    var count: usize = 0;
    var c: usize = 0;
    while (c < node.child_count) : (c += 1) {
        if (!node_pool[node.children[c]].is_text_node) count += 1;
    }
    return count;
}

/// Get child element by index (skipping text nodes).
pub fn getChildElement(node: *const XmlNode, index: usize) ?*XmlNode {
    var found: usize = 0;
    var c: usize = 0;
    while (c < node.child_count) : (c += 1) {
        const child = &node_pool[node.children[c]];
        if (!child.is_text_node) {
            if (found == index) return child;
            found += 1;
        }
    }
    return null;
}

// ---- Display ----

/// Print the XML tree to VGA with indentation.
pub fn printTree(node: *const XmlNode, depth: usize) void {
    if (depth >= MAX_DEPTH) return;

    if (node.is_text_node) {
        printIndent(depth);
        vga.setColor(.light_grey, .black);
        vga.write(node.text_content[0..node.text_len]);
        vga.putChar('\n');
        return;
    }

    // Opening tag
    printIndent(depth);
    vga.setColor(.light_cyan, .black);
    vga.putChar('<');
    vga.setColor(.yellow, .black);
    vga.write(node.tag_name[0..node.tag_name_len]);

    // Attributes
    var i: usize = 0;
    while (i < node.attr_count) : (i += 1) {
        const attr = &node.attributes[i];
        if (!attr.used) continue;
        vga.setColor(.light_grey, .black);
        vga.putChar(' ');
        vga.setColor(.light_green, .black);
        vga.write(attr.name[0..attr.name_len]);
        vga.setColor(.light_grey, .black);
        vga.write("=\"");
        vga.setColor(.light_magenta, .black);
        vga.write(attr.value[0..attr.value_len]);
        vga.setColor(.light_grey, .black);
        vga.putChar('"');
    }

    if (node.child_count == 0 and node.text_len == 0) {
        vga.setColor(.light_cyan, .black);
        vga.write("/>\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.putChar('>');

    // Inline text content
    if (node.child_count == 0 and node.text_len > 0) {
        vga.setColor(.white, .black);
        vga.write(node.text_content[0..node.text_len]);
        vga.setColor(.light_cyan, .black);
        vga.write("</");
        vga.setColor(.yellow, .black);
        vga.write(node.tag_name[0..node.tag_name_len]);
        vga.setColor(.light_cyan, .black);
        vga.write(">\n");
        return;
    }

    vga.putChar('\n');

    // Print text content as child
    if (node.text_len > 0) {
        printIndent(depth + 1);
        vga.setColor(.white, .black);
        vga.write(node.text_content[0..node.text_len]);
        vga.putChar('\n');
    }

    // Children
    var c: usize = 0;
    while (c < node.child_count) : (c += 1) {
        printTree(&node_pool[node.children[c]], depth + 1);
    }

    // Closing tag
    printIndent(depth);
    vga.setColor(.light_cyan, .black);
    vga.write("</");
    vga.setColor(.yellow, .black);
    vga.write(node.tag_name[0..node.tag_name_len]);
    vga.setColor(.light_cyan, .black);
    vga.write(">\n");
    vga.setColor(.light_grey, .black);
}

fn printIndent(depth: usize) void {
    var i: usize = 0;
    while (i < depth * 2) : (i += 1) {
        vga.putChar(' ');
    }
}

/// Count total nodes in the tree (recursive).
pub fn countNodes(node: *const XmlNode) usize {
    var count: usize = 1;
    var c: usize = 0;
    while (c < node.child_count) : (c += 1) {
        count += countNodes(&node_pool[node.children[c]]);
    }
    return count;
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
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}
