// Simple Regex Engine -- NFA-based backtracking matcher
// Supports: literals, . * + ? ^ $ [abc] [^abc] \d \w \s

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Types ----

pub const MAX_INSTRUCTIONS = 64;
pub const MAX_CLASS_CHARS = 16;

pub const InstrTag = enum(u8) {
    literal, // match a specific byte
    dot, // match any byte (except \n)
    char_class, // match one of a set of bytes
    neg_class, // match any byte NOT in the set
    anchor_start, // ^ (match start of text)
    anchor_end, // $ (match end of text)
    digit, // \d [0-9]
    word, // \w [a-zA-Z0-9_]
    space, // \s [ \t\n\r]
    // Quantifiers are combined with the preceding instruction
};

pub const QuantifierKind = enum(u8) {
    one, // exactly one (default)
    star, // zero or more
    plus, // one or more
    optional, // zero or one
};

pub const Instruction = struct {
    tag: InstrTag,
    quantifier: QuantifierKind,
    // For literal
    ch: u8,
    // For char_class / neg_class
    class_chars: [MAX_CLASS_CHARS]u8,
    class_len: u8,
};

pub const Regex = struct {
    instrs: [MAX_INSTRUCTIONS]Instruction,
    len: usize,
    anchored_start: bool,
    anchored_end: bool,
};

pub const Match = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Match, text: []const u8) []const u8 {
        if (self.start >= text.len) return text[0..0];
        const e = if (self.end > text.len) text.len else self.end;
        return text[self.start..e];
    }
};

// ---- Compiler ----

/// Compile a regex pattern string into a Regex instruction array.
/// Returns null if the pattern is invalid or too long.
pub fn compile(pattern: []const u8) ?Regex {
    var regex = Regex{
        .instrs = undefined,
        .len = 0,
        .anchored_start = false,
        .anchored_end = false,
    };

    var i: usize = 0;

    // Check for leading ^
    if (i < pattern.len and pattern[i] == '^') {
        regex.anchored_start = true;
        i += 1;
    }

    while (i < pattern.len) {
        if (regex.len >= MAX_INSTRUCTIONS) return null; // pattern too long

        var instr = Instruction{
            .tag = .literal,
            .quantifier = .one,
            .ch = 0,
            .class_chars = [_]u8{0} ** MAX_CLASS_CHARS,
            .class_len = 0,
        };

        const ch = pattern[i];

        if (ch == '$' and i + 1 == pattern.len) {
            // Trailing $ means anchor end
            regex.anchored_end = true;
            i += 1;
            continue;
        } else if (ch == '.') {
            instr.tag = .dot;
            i += 1;
        } else if (ch == '\\') {
            // Escape sequence
            i += 1;
            if (i >= pattern.len) return null; // trailing backslash
            const esc = pattern[i];
            switch (esc) {
                'd' => {
                    instr.tag = .digit;
                },
                'w' => {
                    instr.tag = .word;
                },
                's' => {
                    instr.tag = .space;
                },
                else => {
                    // Literal escaped character (e.g. \. \\ \* etc.)
                    instr.tag = .literal;
                    instr.ch = esc;
                },
            }
            i += 1;
        } else if (ch == '[') {
            // Character class
            i += 1;
            if (i >= pattern.len) return null;

            var negated = false;
            if (pattern[i] == '^') {
                negated = true;
                i += 1;
            }

            instr.tag = if (negated) .neg_class else .char_class;
            instr.class_len = 0;

            while (i < pattern.len and pattern[i] != ']') {
                if (instr.class_len >= MAX_CLASS_CHARS) return null;
                // Handle range: a-z
                if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                    const range_start = pattern[i];
                    const range_end = pattern[i + 2];
                    if (range_start > range_end) return null;
                    var c = range_start;
                    while (c <= range_end) {
                        if (instr.class_len >= MAX_CLASS_CHARS) return null;
                        instr.class_chars[instr.class_len] = c;
                        instr.class_len += 1;
                        if (c == 255) break;
                        c += 1;
                    }
                    i += 3;
                } else {
                    instr.class_chars[instr.class_len] = pattern[i];
                    instr.class_len += 1;
                    i += 1;
                }
            }
            if (i >= pattern.len) return null; // unterminated [
            i += 1; // skip ']'
        } else if (ch == '*' or ch == '+' or ch == '?') {
            // Quantifier without preceding atom
            return null;
        } else {
            // Literal character
            instr.tag = .literal;
            instr.ch = ch;
            i += 1;
        }

        // Check for quantifier
        if (i < pattern.len) {
            switch (pattern[i]) {
                '*' => {
                    instr.quantifier = .star;
                    i += 1;
                },
                '+' => {
                    instr.quantifier = .plus;
                    i += 1;
                },
                '?' => {
                    instr.quantifier = .optional;
                    i += 1;
                },
                else => {},
            }
        }

        regex.instrs[regex.len] = instr;
        regex.len += 1;
    }

    return regex;
}

// ---- Matching ----

/// Test if the entire text matches the regex.
pub fn match(regex: *const Regex, text: []const u8) bool {
    if (regex.anchored_start) {
        const end = matchAt(regex, text, 0, 0) orelse return false;
        if (regex.anchored_end) {
            return end == text.len;
        }
        return true;
    }

    // Try matching at every position
    var pos: usize = 0;
    while (pos <= text.len) : (pos += 1) {
        if (matchAt(regex, text, pos, 0)) |end| {
            if (regex.anchored_end) {
                if (end == text.len) return true;
            } else {
                return true;
            }
        }
    }
    return false;
}

/// Find the first match in text.
pub fn search(regex: *const Regex, text: []const u8) ?Match {
    const start_limit: usize = if (regex.anchored_start) 1 else text.len + 1;

    var pos: usize = 0;
    while (pos < start_limit) : (pos += 1) {
        if (matchAt(regex, text, pos, 0)) |end| {
            if (regex.anchored_end and end != text.len) {
                continue;
            }
            return Match{ .start = pos, .end = end };
        }
    }
    return null;
}

/// Internal: try matching starting at text[pos] with instruction ip.
/// Returns the end position if successful, null otherwise.
fn matchAt(regex: *const Regex, text: []const u8, pos: usize, ip: usize) ?usize {
    var cur_pos = pos;
    var cur_ip = ip;

    while (cur_ip < regex.len) {
        const instr = &regex.instrs[cur_ip];

        switch (instr.quantifier) {
            .one => {
                if (!matchOne(instr, text, cur_pos)) return null;
                cur_pos += 1;
                cur_ip += 1;
            },
            .star => {
                // Greedy: try matching as many as possible, then backtrack
                const saved_pos = cur_pos;
                var count: usize = 0;
                while (matchOne(instr, text, cur_pos)) {
                    cur_pos += 1;
                    count += 1;
                }
                // Try to match the rest from furthest position, backtracking
                while (true) {
                    if (matchAt(regex, text, cur_pos, cur_ip + 1)) |end| {
                        return end;
                    }
                    if (count == 0) return null;
                    count -= 1;
                    cur_pos -= 1;
                }
                _ = saved_pos;
            },
            .plus => {
                // Must match at least one
                if (!matchOne(instr, text, cur_pos)) return null;
                cur_pos += 1;
                var count: usize = 1;
                while (matchOne(instr, text, cur_pos)) {
                    cur_pos += 1;
                    count += 1;
                }
                // Backtrack
                while (true) {
                    if (matchAt(regex, text, cur_pos, cur_ip + 1)) |end| {
                        return end;
                    }
                    if (count <= 1) return null;
                    count -= 1;
                    cur_pos -= 1;
                }
            },
            .optional => {
                // Try matching one, then zero
                if (matchOne(instr, text, cur_pos)) {
                    if (matchAt(regex, text, cur_pos + 1, cur_ip + 1)) |end| {
                        return end;
                    }
                }
                // Try matching zero
                cur_ip += 1;
            },
        }
    }

    return cur_pos;
}

/// Test if a single instruction matches at the given position.
fn matchOne(instr: *const Instruction, text: []const u8, pos: usize) bool {
    if (pos >= text.len) return false;
    const ch = text[pos];

    return switch (instr.tag) {
        .literal => ch == instr.ch,
        .dot => ch != '\n',
        .digit => ch >= '0' and ch <= '9',
        .word => (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_',
        .space => ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r',
        .char_class => classContains(instr, ch),
        .neg_class => !classContains(instr, ch),
        .anchor_start, .anchor_end => false, // these are handled at a higher level
    };
}

/// Check if a character is in the character class.
fn classContains(instr: *const Instruction, ch: u8) bool {
    var i: usize = 0;
    while (i < instr.class_len) : (i += 1) {
        if (instr.class_chars[i] == ch) return true;
    }
    return false;
}

// ---- Display ----

/// Print a compiled regex summary.
pub fn printRegex(regex: *const Regex) void {
    vga.write("Regex: ");
    printDec(regex.len);
    vga.write(" instructions");
    if (regex.anchored_start) vga.write(" [^]");
    if (regex.anchored_end) vga.write(" [$]");
    vga.putChar('\n');

    var i: usize = 0;
    while (i < regex.len) : (i += 1) {
        vga.write("  [");
        printDec(i);
        vga.write("] ");
        const instr = &regex.instrs[i];
        switch (instr.tag) {
            .literal => {
                vga.write("LIT '");
                vga.putChar(instr.ch);
                vga.putChar('\'');
            },
            .dot => vga.write("DOT"),
            .digit => vga.write("\\d"),
            .word => vga.write("\\w"),
            .space => vga.write("\\s"),
            .char_class => {
                vga.write("CLASS[");
                var j: usize = 0;
                while (j < instr.class_len) : (j += 1) {
                    vga.putChar(instr.class_chars[j]);
                }
                vga.putChar(']');
            },
            .neg_class => {
                vga.write("NCLASS[^");
                var j: usize = 0;
                while (j < instr.class_len) : (j += 1) {
                    vga.putChar(instr.class_chars[j]);
                }
                vga.putChar(']');
            },
            .anchor_start => vga.write("^"),
            .anchor_end => vga.write("$"),
        }
        switch (instr.quantifier) {
            .one => {},
            .star => vga.write(" *"),
            .plus => vga.write(" +"),
            .optional => vga.write(" ?"),
        }
        vga.putChar('\n');
    }
}

/// Print match result.
pub fn printMatch(m: Match) void {
    vga.write("Match(");
    printDec(m.start);
    vga.write("..");
    printDec(m.end);
    vga.putChar(')');
}

// ---- Quick helpers ----

/// Quick test: compile and match in one call.
pub fn quickMatch(pattern: []const u8, text: []const u8) bool {
    const r = compile(pattern) orelse return false;
    return match(&r, text);
}

/// Quick search: compile and search in one call.
pub fn quickSearch(pattern: []const u8, text: []const u8) ?Match {
    const r = compile(pattern) orelse return null;
    return search(&r, text);
}

/// Count all non-overlapping matches.
pub fn countMatches(regex: *const Regex, text: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos <= text.len) {
        // Create a sub-regex for search from pos
        const sub_text = text[pos..];
        if (searchInSlice(regex, sub_text)) |m| {
            count += 1;
            // Advance past this match (at least 1 to avoid infinite loop)
            const advance = if (m.end > m.start) m.end else m.start + 1;
            pos += advance;
        } else {
            break;
        }
    }
    return count;
}

fn searchInSlice(regex: *const Regex, text: []const u8) ?Match {
    const start_limit: usize = if (regex.anchored_start) 1 else text.len + 1;
    var pos: usize = 0;
    while (pos < start_limit) : (pos += 1) {
        if (matchAt(regex, text, pos, 0)) |end| {
            if (regex.anchored_end and end != text.len) continue;
            return Match{ .start = pos, .end = end };
        }
    }
    return null;
}

// ---- Self-test ----

/// Run a quick self-test of the regex engine and print results.
pub fn selfTest() void {
    vga.setColor(.yellow, .black);
    vga.write("Regex self-test:\n");
    vga.setColor(.light_grey, .black);

    var passed: usize = 0;
    var failed: usize = 0;

    // Test literal matching
    if (quickMatch("hello", "hello")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: literal 'hello'\n");
    }

    // Test dot
    if (quickMatch("h.llo", "hello")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: dot 'h.llo'\n");
    }

    // Test star
    if (quickMatch("he*llo", "hllo")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: star 'he*llo' vs 'hllo'\n");
    }

    // Test plus
    if (quickMatch("he+llo", "hello")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: plus 'he+llo' vs 'hello'\n");
    }

    // Test plus must match at least one
    if (!quickMatch("he+llo", "hllo")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: plus 'he+llo' vs 'hllo' should fail\n");
    }

    // Test optional
    if (quickMatch("colou?r", "color")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: optional 'colou?r' vs 'color'\n");
    }

    if (quickMatch("colou?r", "colour")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: optional 'colou?r' vs 'colour'\n");
    }

    // Test digit
    if (quickMatch("\\d+", "12345")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: digit '\\d+' vs '12345'\n");
    }

    // Test char class
    if (quickMatch("[abc]", "b")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: class '[abc]' vs 'b'\n");
    }

    // Test negated class
    if (!quickMatch("^[^abc]$", "a")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: neg_class '^[^abc]$' vs 'a' should fail\n");
    }

    // Test search
    if (quickSearch("\\d+", "abc123def")) |m| {
        if (m.start == 3 and m.end == 6) {
            passed += 1;
        } else {
            failed += 1;
            vga.write("  FAIL: search position wrong\n");
        }
    } else {
        failed += 1;
        vga.write("  FAIL: search '\\d+' in 'abc123def'\n");
    }

    // Test anchor start
    if (!quickMatch("^world", "hello world")) {
        passed += 1;
    } else {
        failed += 1;
        vga.write("  FAIL: ^world should not match 'hello world'\n");
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
