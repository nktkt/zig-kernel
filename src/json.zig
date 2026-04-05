// JSON Parser (read-only) -- Tokenizer and value parser
// Supports: objects, arrays, strings, numbers(i32), booleans, null
// Max nesting depth: 8, max 32 key-value pairs per object

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_DEPTH = 8;
pub const MAX_PAIRS = 32;
pub const MAX_ARRAY_ELEMS = 32;
pub const MAX_STRING_LEN = 128;

// ---- Token Types ----

pub const TokenTag = enum(u8) {
    object_start, // {
    object_end, // }
    array_start, // [
    array_end, // ]
    string, // "..."
    number, // integer
    true_val, // true
    false_val, // false
    null_val, // null
    colon, // :
    comma, // ,
    eof, // end of input
    err, // parse error
};

pub const Token = struct {
    tag: TokenTag,
    // For string tokens: the slice of the source
    start: usize, // start position in input (after opening quote for strings)
    end: usize, // end position in input (before closing quote for strings)
    // For number tokens
    number_val: i32,
};

// ---- Tokenizer ----

pub const TokenIterator = struct {
    input: []const u8,
    pos: usize,

    pub fn next(self: *TokenIterator) Token {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return Token{ .tag = .eof, .start = self.pos, .end = self.pos, .number_val = 0 };
        }

        const ch = self.input[self.pos];

        switch (ch) {
            '{' => {
                self.pos += 1;
                return Token{ .tag = .object_start, .start = self.pos - 1, .end = self.pos, .number_val = 0 };
            },
            '}' => {
                self.pos += 1;
                return Token{ .tag = .object_end, .start = self.pos - 1, .end = self.pos, .number_val = 0 };
            },
            '[' => {
                self.pos += 1;
                return Token{ .tag = .array_start, .start = self.pos - 1, .end = self.pos, .number_val = 0 };
            },
            ']' => {
                self.pos += 1;
                return Token{ .tag = .array_end, .start = self.pos - 1, .end = self.pos, .number_val = 0 };
            },
            ':' => {
                self.pos += 1;
                return Token{ .tag = .colon, .start = self.pos - 1, .end = self.pos, .number_val = 0 };
            },
            ',' => {
                self.pos += 1;
                return Token{ .tag = .comma, .start = self.pos - 1, .end = self.pos, .number_val = 0 };
            },
            '"' => return self.readString(),
            '-', '0'...'9' => return self.readNumber(),
            't' => return self.readKeyword("true", .true_val),
            'f' => return self.readKeyword("false", .false_val),
            'n' => return self.readKeyword("null", .null_val),
            else => {
                return Token{ .tag = .err, .start = self.pos, .end = self.pos, .number_val = 0 };
            },
        }
    }

    fn skipWhitespace(self: *TokenIterator) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn readString(self: *TokenIterator) Token {
        self.pos += 1; // skip opening "
        const start = self.pos;

        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '\\') {
                self.pos += 2; // skip escape sequence
                continue;
            }
            if (self.input[self.pos] == '"') {
                const end = self.pos;
                self.pos += 1; // skip closing "
                return Token{ .tag = .string, .start = start, .end = end, .number_val = 0 };
            }
            self.pos += 1;
        }

        // Unterminated string
        return Token{ .tag = .err, .start = start, .end = self.pos, .number_val = 0 };
    }

    fn readNumber(self: *TokenIterator) Token {
        const start = self.pos;
        var negative = false;

        if (self.input[self.pos] == '-') {
            negative = true;
            self.pos += 1;
        }

        var val: i32 = 0;
        while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
            val = val * 10 + @as(i32, @intCast(self.input[self.pos] - '0'));
            self.pos += 1;
        }

        if (negative) val = -val;
        return Token{ .tag = .number, .start = start, .end = self.pos, .number_val = val };
    }

    fn readKeyword(self: *TokenIterator, keyword: []const u8, tag: TokenTag) Token {
        const start = self.pos;
        if (self.pos + keyword.len > self.input.len) {
            return Token{ .tag = .err, .start = start, .end = self.pos, .number_val = 0 };
        }
        for (keyword) |c| {
            if (self.input[self.pos] != c) {
                return Token{ .tag = .err, .start = start, .end = self.pos, .number_val = 0 };
            }
            self.pos += 1;
        }
        return Token{ .tag = tag, .start = start, .end = self.pos, .number_val = 0 };
    }
};

/// Create a token iterator from an input string.
pub fn tokenize(input: []const u8) TokenIterator {
    return TokenIterator{ .input = input, .pos = 0 };
}

// ---- JSON Value Types ----

pub const ValueTag = enum(u8) {
    string_val,
    number_val,
    bool_val,
    null_val,
    object_val,
    array_val,
};

pub const KeyValue = struct {
    key_start: usize,
    key_end: usize,
    value: JsonValueRef,
};

pub const JsonValue = struct {
    tag: ValueTag,
    // For string
    str_start: usize,
    str_end: usize,
    // For number
    num: i32,
    // For boolean
    boolean: bool,
    // For object
    pairs: [MAX_PAIRS]KeyValue,
    pair_count: usize,
    // For array
    elements: [MAX_ARRAY_ELEMS]JsonValueRef,
    elem_count: usize,
    // Source reference
    source: []const u8,
};

/// A lightweight reference to avoid deeply nested large structs.
/// Stores the essential fields only.
pub const JsonValueRef = struct {
    tag: ValueTag,
    str_start: usize,
    str_end: usize,
    num: i32,
    boolean: bool,
};

fn toRef(v: JsonValue) JsonValueRef {
    return JsonValueRef{
        .tag = v.tag,
        .str_start = v.str_start,
        .str_end = v.str_end,
        .num = v.num,
        .boolean = v.boolean,
    };
}

// ---- Parser ----

const ParseState = struct {
    iter: TokenIterator,
    depth: usize,
    source: []const u8,
};

/// Parse a JSON string into a JsonValue.
/// Returns null on parse error.
pub fn parse(input: []const u8) ?JsonValue {
    var state = ParseState{
        .iter = tokenize(input),
        .depth = 0,
        .source = input,
    };
    return parseValue(&state);
}

fn parseValue(state: *ParseState) ?JsonValue {
    if (state.depth >= MAX_DEPTH) return null;

    const tok = state.iter.next();

    switch (tok.tag) {
        .string => {
            return JsonValue{
                .tag = .string_val,
                .str_start = tok.start,
                .str_end = tok.end,
                .num = 0,
                .boolean = false,
                .pairs = undefined,
                .pair_count = 0,
                .elements = undefined,
                .elem_count = 0,
                .source = state.source,
            };
        },
        .number => {
            return JsonValue{
                .tag = .number_val,
                .str_start = 0,
                .str_end = 0,
                .num = tok.number_val,
                .boolean = false,
                .pairs = undefined,
                .pair_count = 0,
                .elements = undefined,
                .elem_count = 0,
                .source = state.source,
            };
        },
        .true_val => {
            return JsonValue{
                .tag = .bool_val,
                .str_start = 0,
                .str_end = 0,
                .num = 0,
                .boolean = true,
                .pairs = undefined,
                .pair_count = 0,
                .elements = undefined,
                .elem_count = 0,
                .source = state.source,
            };
        },
        .false_val => {
            return JsonValue{
                .tag = .bool_val,
                .str_start = 0,
                .str_end = 0,
                .num = 0,
                .boolean = false,
                .pairs = undefined,
                .pair_count = 0,
                .elements = undefined,
                .elem_count = 0,
                .source = state.source,
            };
        },
        .null_val => {
            return JsonValue{
                .tag = .null_val,
                .str_start = 0,
                .str_end = 0,
                .num = 0,
                .boolean = false,
                .pairs = undefined,
                .pair_count = 0,
                .elements = undefined,
                .elem_count = 0,
                .source = state.source,
            };
        },
        .object_start => return parseObject(state),
        .array_start => return parseArray(state),
        else => return null,
    }
}

fn parseObject(state: *ParseState) ?JsonValue {
    state.depth += 1;

    var obj = JsonValue{
        .tag = .object_val,
        .str_start = 0,
        .str_end = 0,
        .num = 0,
        .boolean = false,
        .pairs = undefined,
        .pair_count = 0,
        .elements = undefined,
        .elem_count = 0,
        .source = state.source,
    };

    // Check for empty object
    const first = state.iter.next();
    if (first.tag == .object_end) {
        state.depth -= 1;
        return obj;
    }

    // First key
    if (first.tag != .string) return null;

    // Parse first pair
    var colon = state.iter.next();
    if (colon.tag != .colon) return null;
    var val = parseValue(state) orelse return null;
    obj.pairs[0] = KeyValue{
        .key_start = first.start,
        .key_end = first.end,
        .value = toRef(val),
    };
    obj.pair_count = 1;

    // Parse remaining pairs
    while (true) {
        const sep = state.iter.next();
        if (sep.tag == .object_end) break;
        if (sep.tag != .comma) return null;

        if (obj.pair_count >= MAX_PAIRS) return null;

        const key_tok = state.iter.next();
        if (key_tok.tag != .string) return null;

        colon = state.iter.next();
        if (colon.tag != .colon) return null;

        val = parseValue(state) orelse return null;
        obj.pairs[obj.pair_count] = KeyValue{
            .key_start = key_tok.start,
            .key_end = key_tok.end,
            .value = toRef(val),
        };
        obj.pair_count += 1;
    }

    state.depth -= 1;
    return obj;
}

fn parseArray(state: *ParseState) ?JsonValue {
    state.depth += 1;

    var arr = JsonValue{
        .tag = .array_val,
        .str_start = 0,
        .str_end = 0,
        .num = 0,
        .boolean = false,
        .pairs = undefined,
        .pair_count = 0,
        .elements = undefined,
        .elem_count = 0,
        .source = state.source,
    };

    // Peek at next token to check for empty array
    // We need to check without consuming; since our tokenizer doesn't support peek,
    // save position and restore if needed.
    const saved_pos = state.iter.pos;
    const peek = state.iter.next();
    if (peek.tag == .array_end) {
        state.depth -= 1;
        return arr;
    }
    // Restore position to re-parse the element
    state.iter.pos = saved_pos;

    // Parse first element
    const first_val = parseValue(state) orelse return null;
    arr.elements[0] = valueToRef(first_val);
    arr.elem_count = 1;

    // Parse remaining elements
    while (true) {
        const sep = state.iter.next();
        if (sep.tag == .array_end) break;
        if (sep.tag != .comma) return null;
        if (arr.elem_count >= MAX_ARRAY_ELEMS) return null;

        const elem = parseValue(state) orelse return null;
        arr.elements[arr.elem_count] = valueToRef(elem);
        arr.elem_count += 1;
    }

    state.depth -= 1;
    return arr;
}

fn valueToRef(val: JsonValue) JsonValueRef {
    return JsonValueRef{
        .tag = val.tag,
        .str_start = val.str_start,
        .str_end = val.str_end,
        .num = val.num,
        .boolean = val.boolean,
    };
}

// ---- Accessors ----

/// Get a string value from an object by key.
pub fn getString(val: *const JsonValue, key: []const u8) ?[]const u8 {
    if (val.tag != .object_val) return null;
    var i: usize = 0;
    while (i < val.pair_count) : (i += 1) {
        const kv = &val.pairs[i];
        const kstr = val.source[kv.key_start..kv.key_end];
        if (eql(kstr, key)) {
            if (kv.value.tag == .string_val) {
                return val.source[kv.value.str_start..kv.value.str_end];
            }
            return null;
        }
    }
    return null;
}

/// Get a number (i32) from an object by key.
pub fn getNumber(val: *const JsonValue, key: []const u8) ?i32 {
    if (val.tag != .object_val) return null;
    var i: usize = 0;
    while (i < val.pair_count) : (i += 1) {
        const kv = &val.pairs[i];
        const kstr = val.source[kv.key_start..kv.key_end];
        if (eql(kstr, key)) {
            if (kv.value.tag == .number_val) {
                return kv.value.num;
            }
            return null;
        }
    }
    return null;
}

/// Get a boolean from an object by key.
pub fn getBool(val: *const JsonValue, key: []const u8) ?bool {
    if (val.tag != .object_val) return null;
    var i: usize = 0;
    while (i < val.pair_count) : (i += 1) {
        const kv = &val.pairs[i];
        const kstr = val.source[kv.key_start..kv.key_end];
        if (eql(kstr, key)) {
            if (kv.value.tag == .bool_val) {
                return kv.value.boolean;
            }
            return null;
        }
    }
    return null;
}

/// Get a value from an object by key.
pub fn getValue(val: *const JsonValue, key: []const u8) ?*const JsonValue {
    if (val.tag != .object_val) return null;
    var i: usize = 0;
    while (i < val.pair_count) : (i += 1) {
        const kv = &val.pairs[i];
        const kstr = val.source[kv.key_start..kv.key_end];
        if (eql(kstr, key)) {
            return &kv.value;
        }
    }
    return null;
}

/// Get the number of key-value pairs in an object.
pub fn objectLen(val: *const JsonValue) usize {
    if (val.tag != .object_val) return 0;
    return val.pair_count;
}

/// Get the number of elements in an array.
pub fn arrayLen(val: *const JsonValue) usize {
    if (val.tag != .array_val) return 0;
    return val.elem_count;
}

// ---- Pretty-Print ----

/// Pretty-print a JSON value to VGA.
pub fn printValue(val: *const JsonValue) void {
    printValueIndent(val, 0);
    vga.putChar('\n');
}

fn printValueIndent(val: *const JsonValue, depth: usize) void {
    switch (val.tag) {
        .string_val => {
            vga.putChar('"');
            vga.write(val.source[val.str_start..val.str_end]);
            vga.putChar('"');
        },
        .number_val => {
            printDecSigned(val.num);
        },
        .bool_val => {
            if (val.boolean) vga.write("true") else vga.write("false");
        },
        .null_val => {
            vga.write("null");
        },
        .object_val => {
            vga.write("{\n");
            var i: usize = 0;
            while (i < val.pair_count) : (i += 1) {
                printIndent(depth + 1);
                vga.putChar('"');
                vga.write(val.source[val.pairs[i].key_start..val.pairs[i].key_end]);
                vga.write("\": ");
                printValueIndent(&val.pairs[i].value, depth + 1);
                if (i + 1 < val.pair_count) vga.putChar(',');
                vga.putChar('\n');
            }
            printIndent(depth);
            vga.putChar('}');
        },
        .array_val => {
            vga.write("[\n");
            var i: usize = 0;
            while (i < val.elem_count) : (i += 1) {
                printIndent(depth + 1);
                // Print ref values directly
                const ref = &val.elements[i];
                printRef(ref, val.source);
                if (i + 1 < val.elem_count) vga.putChar(',');
                vga.putChar('\n');
            }
            printIndent(depth);
            vga.putChar(']');
        },
    }
}

fn printRef(ref: *const JsonValueRef, source: []const u8) void {
    switch (ref.tag) {
        .string_val => {
            vga.putChar('"');
            vga.write(source[ref.str_start..ref.str_end]);
            vga.putChar('"');
        },
        .number_val => {
            printDecSigned(ref.num);
        },
        .bool_val => {
            if (ref.boolean) vga.write("true") else vga.write("false");
        },
        .null_val => {
            vga.write("null");
        },
        .object_val => vga.write("{...}"),
        .array_val => vga.write("[...]"),
    }
}

fn printIndent(depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        vga.write("  ");
    }
}

// ---- Self-test ----

/// Run parser self-test.
pub fn selfTest() void {
    vga.setColor(.yellow, .black);
    vga.write("JSON self-test:\n");
    vga.setColor(.light_grey, .black);

    var passed: usize = 0;
    var failed: usize = 0;

    // Test 1: simple object
    {
        const input = "{\"name\": \"Zig\", \"version\": 15, \"cool\": true}";
        if (parse(input)) |val| {
            if (getString(&val, "name")) |name| {
                if (eql(name, "Zig")) {
                    passed += 1;
                } else {
                    failed += 1;
                    vga.write("  FAIL: getString name\n");
                }
            } else {
                failed += 1;
                vga.write("  FAIL: getString null\n");
            }

            if (getNumber(&val, "version")) |ver| {
                if (ver == 15) {
                    passed += 1;
                } else {
                    failed += 1;
                    vga.write("  FAIL: getNumber version\n");
                }
            } else {
                failed += 1;
                vga.write("  FAIL: getNumber null\n");
            }

            if (getBool(&val, "cool")) |cool| {
                if (cool) {
                    passed += 1;
                } else {
                    failed += 1;
                    vga.write("  FAIL: getBool cool\n");
                }
            } else {
                failed += 1;
                vga.write("  FAIL: getBool null\n");
            }
        } else {
            failed += 3;
            vga.write("  FAIL: parse object\n");
        }
    }

    // Test 2: number
    {
        const input = "42";
        if (parse(input)) |val| {
            if (val.tag == .number_val and val.num == 42) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: parse number\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: parse number null\n");
        }
    }

    // Test 3: empty object
    {
        const input = "{}";
        if (parse(input)) |val| {
            if (val.tag == .object_val and val.pair_count == 0) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: empty object\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: parse empty object\n");
        }
    }

    // Test 4: null
    {
        const input = "null";
        if (parse(input)) |val| {
            if (val.tag == .null_val) {
                passed += 1;
            } else {
                failed += 1;
                vga.write("  FAIL: null type\n");
            }
        } else {
            failed += 1;
            vga.write("  FAIL: parse null\n");
        }
    }

    vga.setColor(.light_green, .black);
    vga.write("  Passed: ");
    printDec(passed);
    vga.setColor(.light_red, .black);
    vga.write("  Failed: ");
    printDec(failed);
    vga.putChar('\n');
    vga.setColor(.light_grey, .black);
}

// ---- Helpers ----

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
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

fn printDecSigned(n: i32) void {
    if (n < 0) {
        vga.putChar('-');
        printDec(@intCast(-n));
    } else {
        printDec(@intCast(n));
    }
}
