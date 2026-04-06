// Simple template engine -- Variable substitution and control flow
// Syntax: {{variable}}, {%if condition%}...{%endif%}, {%for item in list%}...{%endfor%}
// Variables from a key-value store. Built-in vars: $date, $hostname, $version.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const ramfs = @import("ramfs.zig");

// ---- Constants ----

const MAX_VARS = 16;
const MAX_VAR_NAME = 32;
const MAX_VAR_VALUE = 64;
const MAX_OUTPUT = 2048;
const MAX_FOR_ITERATIONS = 8;
const MAX_LIST_ITEMS = 8;
const MAX_NESTING = 4;

// ---- Variable store ----

const Variable = struct {
    name: [MAX_VAR_NAME]u8,
    name_len: u8,
    value: [MAX_VAR_VALUE]u8,
    value_len: u8,
    used: bool,
};

var variables: [MAX_VARS]Variable = undefined;
var vars_initialized: bool = false;

fn ensureInit() void {
    if (vars_initialized) return;
    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        variables[i].used = false;
        variables[i].name_len = 0;
        variables[i].value_len = 0;
    }
    vars_initialized = true;
}

// ---- Public API: Variable management ----

/// Set a variable in the store.
pub fn setVar(name: []const u8, value: []const u8) void {
    ensureInit();
    if (name.len > MAX_VAR_NAME or value.len > MAX_VAR_VALUE) return;

    // Try to update existing
    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        if (variables[i].used and variables[i].name_len == name.len and
            sliceEql(variables[i].name[0..variables[i].name_len], name))
        {
            variables[i].value_len = @intCast(value.len);
            @memcpy(variables[i].value[0..variables[i].value_len], value[0..value.len]);
            return;
        }
    }

    // Find free slot
    i = 0;
    while (i < MAX_VARS) : (i += 1) {
        if (!variables[i].used) {
            variables[i].used = true;
            variables[i].name_len = @intCast(name.len);
            @memcpy(variables[i].name[0..variables[i].name_len], name[0..name.len]);
            variables[i].value_len = @intCast(value.len);
            @memcpy(variables[i].value[0..variables[i].value_len], value[0..value.len]);
            return;
        }
    }
}

/// Get a variable from the store.
pub fn getVar(name: []const u8) ?[]const u8 {
    ensureInit();

    // Built-in variables
    if (sliceEql(name, "$date")) return "2026-04-04";
    if (sliceEql(name, "$hostname")) return "zig-os";
    if (sliceEql(name, "$version")) return "1.0.0";
    if (sliceEql(name, "$arch")) return "x86";
    if (sliceEql(name, "$kernel")) return "Zig Kernel";

    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        if (variables[i].used and variables[i].name_len == name.len and
            sliceEql(variables[i].name[0..variables[i].name_len], name))
        {
            return variables[i].value[0..variables[i].value_len];
        }
    }
    return null;
}

/// Remove a variable from the store.
pub fn removeVar(name: []const u8) bool {
    ensureInit();
    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        if (variables[i].used and variables[i].name_len == name.len and
            sliceEql(variables[i].name[0..variables[i].name_len], name))
        {
            variables[i].used = false;
            return true;
        }
    }
    return false;
}

/// Clear all variables.
pub fn clearVars() void {
    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        variables[i].used = false;
    }
    vars_initialized = true;
}

/// Count active variables.
pub fn varCount() usize {
    ensureInit();
    var count: usize = 0;
    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        if (variables[i].used) count += 1;
    }
    return count;
}

// ---- Public API: Rendering ----

/// Render a template string with variable substitution and control flow.
/// Returns the number of bytes written to output.
pub fn render(template: []const u8, output: []u8) usize {
    ensureInit();
    var ctx = RenderContext{
        .template = template,
        .pos = 0,
        .output = output,
        .out_pos = 0,
        .depth = 0,
    };

    renderBlock(&ctx, null);
    return ctx.out_pos;
}

/// Load template from ramfs and render.
/// Returns the number of bytes written to output.
pub fn renderFile(filename: []const u8, output: []u8) usize {
    const idx = ramfs.findByName(filename) orelse return 0;
    var buf: [ramfs.MAX_DATA]u8 = undefined;
    const size = ramfs.readFile(idx, &buf);
    if (size == 0) return 0;
    return render(buf[0..size], output);
}

/// Print all defined variables.
pub fn printVars() void {
    ensureInit();
    vga.setColor(.light_cyan, .black);
    vga.write("Template Variables:\n");

    // Built-in vars
    vga.setColor(.dark_grey, .black);
    vga.write("  (built-in)\n");
    printOneVar("$date", "2026-04-04");
    printOneVar("$hostname", "zig-os");
    printOneVar("$version", "1.0.0");
    printOneVar("$arch", "x86");
    printOneVar("$kernel", "Zig Kernel");

    // User vars
    var count: usize = 0;
    var i: usize = 0;
    while (i < MAX_VARS) : (i += 1) {
        if (variables[i].used) {
            if (count == 0) {
                vga.setColor(.dark_grey, .black);
                vga.write("  (user)\n");
            }
            printOneVar(variables[i].name[0..variables[i].name_len], variables[i].value[0..variables[i].value_len]);
            count += 1;
        }
    }

    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no user variables)\n");
    }

    vga.setColor(.dark_grey, .black);
    fmt.printDec(count + 5);
    vga.write(" total variables\n");
    vga.setColor(.light_grey, .black);
}

fn printOneVar(name: []const u8, value: []const u8) void {
    vga.setColor(.light_grey, .black);
    vga.write("    ");
    vga.setColor(.yellow, .black);
    vga.write(name);
    vga.setColor(.light_grey, .black);
    vga.write(" = ");
    vga.setColor(.white, .black);
    vga.write(value);
    vga.putChar('\n');
}

// ---- Render engine ----

const RenderContext = struct {
    template: []const u8,
    pos: usize,
    output: []u8,
    out_pos: usize,
    depth: usize,

    fn emit(self: *RenderContext, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len and self.out_pos < self.output.len) {
            self.output[self.out_pos] = data[i];
            self.out_pos += 1;
            i += 1;
        }
    }

    fn emitChar(self: *RenderContext, c: u8) void {
        if (self.out_pos < self.output.len) {
            self.output[self.out_pos] = c;
            self.out_pos += 1;
        }
    }

    fn peek2(self: *RenderContext) ?[2]u8 {
        if (self.pos + 1 < self.template.len) {
            return [2]u8{ self.template[self.pos], self.template[self.pos + 1] };
        }
        return null;
    }

    fn remaining(self: *RenderContext) []const u8 {
        if (self.pos >= self.template.len) return "";
        return self.template[self.pos..];
    }

    fn startsWith(self: *RenderContext, prefix: []const u8) bool {
        const rem = self.remaining();
        if (rem.len < prefix.len) return false;
        var i: usize = 0;
        while (i < prefix.len) : (i += 1) {
            if (rem[i] != prefix[i]) return false;
        }
        return true;
    }
};

fn renderBlock(ctx: *RenderContext, end_tag: ?[]const u8) void {
    while (ctx.pos < ctx.template.len) {
        // Check for end tag
        if (end_tag) |tag| {
            if (ctx.startsWith(tag)) {
                ctx.pos += tag.len;
                // Skip to closing %}
                skipToBlockClose(ctx);
                return;
            }
        }

        const p2 = ctx.peek2() orelse {
            // Single character left
            ctx.emitChar(ctx.template[ctx.pos]);
            ctx.pos += 1;
            break;
        };

        // Variable substitution: {{var}}
        if (p2[0] == '{' and p2[1] == '{') {
            ctx.pos += 2;
            handleVariable(ctx);
            continue;
        }

        // Block tag: {%...%}
        if (p2[0] == '{' and p2[1] == '%') {
            ctx.pos += 2;
            skipWS(ctx);

            if (ctx.startsWith("if ") or ctx.startsWith("if\t")) {
                ctx.pos += 3;
                handleIf(ctx);
            } else if (ctx.startsWith("for ") or ctx.startsWith("for\t")) {
                ctx.pos += 4;
                handleFor(ctx);
            } else if (ctx.startsWith("endif") or ctx.startsWith("endfor") or
                ctx.startsWith("else"))
            {
                // Unexpected end block - return to caller
                // Rewind so caller can see it
                ctx.pos -= 2;
                return;
            } else {
                // Unknown block tag, skip
                skipToBlockClose(ctx);
            }
            continue;
        }

        // Regular character
        ctx.emitChar(ctx.template[ctx.pos]);
        ctx.pos += 1;
    }
}

fn handleVariable(ctx: *RenderContext) void {
    skipWS(ctx);
    // Read variable name until }}
    var name_buf: [MAX_VAR_NAME]u8 = undefined;
    var name_len: usize = 0;

    while (ctx.pos < ctx.template.len) {
        if (ctx.pos + 1 < ctx.template.len and
            ctx.template[ctx.pos] == '}' and ctx.template[ctx.pos + 1] == '}')
        {
            ctx.pos += 2;
            break;
        }
        if (ctx.template[ctx.pos] != ' ' and ctx.template[ctx.pos] != '\t') {
            if (name_len < MAX_VAR_NAME) {
                name_buf[name_len] = ctx.template[ctx.pos];
                name_len += 1;
            }
        }
        ctx.pos += 1;
    }

    if (name_len > 0) {
        const name = name_buf[0..name_len];
        if (getVar(name)) |value| {
            ctx.emit(value);
        } else {
            // Unknown variable: output placeholder
            ctx.emit("{{");
            ctx.emit(name);
            ctx.emit("}}");
        }
    }
}

fn handleIf(ctx: *RenderContext) void {
    skipWS(ctx);

    // Read condition (variable name or "not variable")
    var negate = false;
    if (ctx.startsWith("not ")) {
        negate = true;
        ctx.pos += 4;
        skipWS(ctx);
    }

    var cond_buf: [MAX_VAR_NAME]u8 = undefined;
    var cond_len: usize = 0;
    while (ctx.pos < ctx.template.len and ctx.template[ctx.pos] != '%' and
        ctx.template[ctx.pos] != ' ' and ctx.template[ctx.pos] != '\t')
    {
        if (cond_len < MAX_VAR_NAME) {
            cond_buf[cond_len] = ctx.template[ctx.pos];
            cond_len += 1;
        }
        ctx.pos += 1;
    }

    // Skip to %}
    skipToBlockClose(ctx);

    // Evaluate condition: variable exists and is not empty/"false"/"0"
    var condition = false;
    if (cond_len > 0) {
        if (getVar(cond_buf[0..cond_len])) |val| {
            condition = val.len > 0 and !sliceEql(val, "false") and !sliceEql(val, "0");
        }
    }
    if (negate) condition = !condition;

    if (condition) {
        // Render the if-block body
        renderBlock(ctx, "{%endif");
        // Check if there's an else block we need to skip
        // (already consumed by renderBlock returning at {%else or {%endif)
    } else {
        // Skip to else or endif
        skipToTag(ctx, "endif", "else");
        if (ctx.pos >= 2 and ctx.template[ctx.pos - 1] == '%' and ctx.template[ctx.pos - 2] == '{') {
            // We found else, render else block
            renderBlock(ctx, "{%endif");
        }
    }
}

fn handleFor(ctx: *RenderContext) void {
    skipWS(ctx);

    // Parse: "item in listvar"
    var item_buf: [MAX_VAR_NAME]u8 = undefined;
    var item_len: usize = 0;
    while (ctx.pos < ctx.template.len and ctx.template[ctx.pos] != ' ' and ctx.template[ctx.pos] != '\t') {
        if (item_len < MAX_VAR_NAME) {
            item_buf[item_len] = ctx.template[ctx.pos];
            item_len += 1;
        }
        ctx.pos += 1;
    }
    skipWS(ctx);

    // Expect "in"
    if (ctx.startsWith("in ") or ctx.startsWith("in\t")) {
        ctx.pos += 3;
    }
    skipWS(ctx);

    var list_buf: [MAX_VAR_NAME]u8 = undefined;
    var list_len: usize = 0;
    while (ctx.pos < ctx.template.len and ctx.template[ctx.pos] != '%' and
        ctx.template[ctx.pos] != ' ' and ctx.template[ctx.pos] != '\t')
    {
        if (list_len < MAX_VAR_NAME) {
            list_buf[list_len] = ctx.template[ctx.pos];
            list_len += 1;
        }
        ctx.pos += 1;
    }

    // Skip to %}
    skipToBlockClose(ctx);

    // Save loop body start position
    const body_start = ctx.pos;

    // Get list value (comma-separated)
    var items: [MAX_LIST_ITEMS][MAX_VAR_VALUE]u8 = undefined;
    var item_lens: [MAX_LIST_ITEMS]usize = undefined;
    var item_count: usize = 0;

    if (list_len > 0) {
        if (getVar(list_buf[0..list_len])) |list_val| {
            // Split by comma
            var start: usize = 0;
            var idx: usize = 0;
            while (idx <= list_val.len and item_count < MAX_LIST_ITEMS) {
                if (idx == list_val.len or list_val[idx] == ',') {
                    const item_val = trimSlice(list_val[start..idx]);
                    if (item_val.len > 0) {
                        const copy_len = @min(item_val.len, MAX_VAR_VALUE);
                        @memcpy(items[item_count][0..copy_len], item_val[0..copy_len]);
                        item_lens[item_count] = copy_len;
                        item_count += 1;
                    }
                    start = idx + 1;
                }
                idx += 1;
            }
        }
    }

    // Limit iterations
    if (item_count > MAX_FOR_ITERATIONS) item_count = MAX_FOR_ITERATIONS;

    // Execute loop body for each item
    if (item_count > 0 and item_len > 0) {
        var iter: usize = 0;
        while (iter < item_count) : (iter += 1) {
            // Set the loop variable
            setVar(item_buf[0..item_len], items[iter][0..item_lens[iter]]);

            // Also set $index
            var idx_buf: [4]u8 = undefined;
            idx_buf[0] = @truncate('0' + iter);
            setVar("$index", idx_buf[0..1]);

            // Render body
            ctx.pos = body_start;
            renderBlock(ctx, "{%endfor");
        }
        // Clean up loop variable
        _ = removeVar(item_buf[0..item_len]);
    } else {
        // No items, skip to endfor
        skipToTag(ctx, "endfor", null);
    }
}

fn skipWS(ctx: *RenderContext) void {
    while (ctx.pos < ctx.template.len and (ctx.template[ctx.pos] == ' ' or ctx.template[ctx.pos] == '\t')) : (ctx.pos += 1) {}
}

fn skipToBlockClose(ctx: *RenderContext) void {
    while (ctx.pos + 1 < ctx.template.len) {
        if (ctx.template[ctx.pos] == '%' and ctx.template[ctx.pos + 1] == '}') {
            ctx.pos += 2;
            return;
        }
        ctx.pos += 1;
    }
}

fn skipToTag(ctx: *RenderContext, tag1: []const u8, tag2: ?[]const u8) void {
    var nesting: usize = 0;
    while (ctx.pos + 1 < ctx.template.len) {
        if (ctx.template[ctx.pos] == '{' and ctx.template[ctx.pos + 1] == '%') {
            ctx.pos += 2;
            skipWS(ctx);

            // Check for nested if/for
            if (ctx.startsWith("if ") or ctx.startsWith("for ")) {
                nesting += 1;
                skipToBlockClose(ctx);
                continue;
            }

            if (nesting > 0) {
                if (ctx.startsWith("endif") or ctx.startsWith("endfor")) {
                    nesting -= 1;
                    skipToBlockClose(ctx);
                    continue;
                }
            } else {
                if (ctx.startsWith(tag1)) {
                    ctx.pos += tag1.len;
                    skipToBlockClose(ctx);
                    return;
                }
                if (tag2) |t2| {
                    if (ctx.startsWith(t2)) {
                        ctx.pos += t2.len;
                        skipToBlockClose(ctx);
                        return;
                    }
                }
            }
            skipToBlockClose(ctx);
        } else {
            ctx.pos += 1;
        }
    }
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
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}
