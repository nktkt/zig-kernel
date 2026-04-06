// CSV parser -- RFC 4180 compliant with quoted fields and escaped quotes
// Supports parsing, serialization, formatted display, row addition, and sorting.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- Constants ----

const MAX_ROWS = 32;
const MAX_COLS = 16;
const MAX_CELL_LEN = 64;

// ---- Data types ----

pub const Cell = struct {
    data: [MAX_CELL_LEN]u8,
    len: u8,
    used: bool,
};

pub const CsvTable = struct {
    cells: [MAX_ROWS][MAX_COLS]Cell,
    col_count: [MAX_ROWS]usize, // columns per row
    row_count: usize,
};

// ---- Parsing ----

/// Parse CSV text into a CsvTable.
/// Handles: commas, quoted fields, escaped quotes (""), newlines within quotes.
pub fn parse(text: []const u8) CsvTable {
    var table: CsvTable = undefined;
    table.row_count = 0;
    var i: usize = 0;
    while (i < MAX_ROWS) : (i += 1) {
        table.col_count[i] = 0;
        var j: usize = 0;
        while (j < MAX_COLS) : (j += 1) {
            table.cells[i][j].used = false;
            table.cells[i][j].len = 0;
        }
    }

    var pos: usize = 0;
    var row: usize = 0;
    var col: usize = 0;

    while (pos < text.len and row < MAX_ROWS) {
        const result = parseField(text, pos);
        if (col < MAX_COLS) {
            setCell(&table.cells[row][col], result.value);
            col += 1;
        }

        if (result.next_pos >= text.len) {
            // End of input
            table.col_count[row] = col;
            if (col > 0) row += 1;
            break;
        }

        if (text[result.next_pos] == ',') {
            pos = result.next_pos + 1;
        } else if (text[result.next_pos] == '\n') {
            table.col_count[row] = col;
            row += 1;
            col = 0;
            pos = result.next_pos + 1;
        } else if (result.next_pos + 1 < text.len and text[result.next_pos] == '\r' and text[result.next_pos + 1] == '\n') {
            table.col_count[row] = col;
            row += 1;
            col = 0;
            pos = result.next_pos + 2;
        } else {
            pos = result.next_pos + 1;
        }
    }

    // Handle case where last line has no trailing newline and wasn't counted
    if (col > 0 and row < MAX_ROWS) {
        table.col_count[row] = col;
        row += 1;
    }

    table.row_count = row;
    return table;
}

const FieldResult = struct {
    value: []const u8,
    next_pos: usize,
};

fn parseField(text: []const u8, start: usize) FieldResult {
    if (start >= text.len) {
        return FieldResult{ .value = text[0..0], .next_pos = text.len };
    }

    if (text[start] == '"') {
        // Quoted field
        return parseQuotedField(text, start);
    } else {
        // Unquoted field
        var end = start;
        while (end < text.len and text[end] != ',' and text[end] != '\n' and text[end] != '\r') : (end += 1) {}
        return FieldResult{ .value = text[start..end], .next_pos = end };
    }
}

fn parseQuotedField(text: []const u8, start: usize) FieldResult {
    // Skip opening quote
    var pos = start + 1;
    const content_start = pos;

    // Find the closing quote (handle escaped quotes "")
    while (pos < text.len) {
        if (text[pos] == '"') {
            if (pos + 1 < text.len and text[pos + 1] == '"') {
                // Escaped quote, skip both
                pos += 2;
                continue;
            }
            // Closing quote
            const value = text[content_start..pos];
            pos += 1; // skip closing quote
            return FieldResult{ .value = value, .next_pos = pos };
        }
        pos += 1;
    }

    // No closing quote found, return what we have
    return FieldResult{ .value = text[content_start..pos], .next_pos = pos };
}

fn setCell(cell: *Cell, value: []const u8) void {
    // For quoted fields, we need to unescape ""
    var dst: usize = 0;
    var src: usize = 0;
    while (src < value.len and dst < MAX_CELL_LEN) {
        if (src + 1 < value.len and value[src] == '"' and value[src + 1] == '"') {
            cell.data[dst] = '"';
            dst += 1;
            src += 2;
        } else {
            cell.data[dst] = value[src];
            dst += 1;
            src += 1;
        }
    }
    cell.len = @intCast(dst);
    cell.used = true;
}

// ---- Public API ----

/// Get cell content at (row, col). Returns null if out of bounds or empty.
pub fn getCell(table: *const CsvTable, row: usize, col: usize) ?[]const u8 {
    if (row >= table.row_count) return null;
    if (col >= table.col_count[row]) return null;
    const cell = &table.cells[row][col];
    if (!cell.used) return null;
    return cell.data[0..cell.len];
}

/// Get the number of rows.
pub fn getRowCount(table: *const CsvTable) usize {
    return table.row_count;
}

/// Get the number of columns in a specific row.
pub fn getColCount(table: *const CsvTable, row: usize) usize {
    if (row >= table.row_count) return 0;
    return table.col_count[row];
}

/// Get the maximum number of columns across all rows.
pub fn getMaxColCount(table: *const CsvTable) usize {
    var max: usize = 0;
    var i: usize = 0;
    while (i < table.row_count) : (i += 1) {
        if (table.col_count[i] > max) max = table.col_count[i];
    }
    return max;
}

/// Print the table in a formatted display with borders.
pub fn printTable(table: *const CsvTable) void {
    if (table.row_count == 0) {
        vga.write("(empty table)\n");
        return;
    }

    const max_cols = getMaxColCount(table);
    if (max_cols == 0) return;

    // Calculate column widths
    var col_widths: [MAX_COLS]usize = undefined;
    var c: usize = 0;
    while (c < max_cols) : (c += 1) {
        col_widths[c] = 3; // minimum width
        var r: usize = 0;
        while (r < table.row_count) : (r += 1) {
            if (c < table.col_count[r]) {
                const cell = &table.cells[r][c];
                if (cell.used and cell.len > col_widths[c]) {
                    col_widths[c] = cell.len;
                }
            }
        }
        if (col_widths[c] > 20) col_widths[c] = 20; // cap at 20
    }

    // Print top border
    printBorder(col_widths[0..max_cols], '+', '-');

    // Print rows
    var r: usize = 0;
    while (r < table.row_count) : (r += 1) {
        vga.putChar('|');
        c = 0;
        while (c < max_cols) : (c += 1) {
            vga.putChar(' ');
            if (c < table.col_count[r]) {
                const cell = &table.cells[r][c];
                if (cell.used) {
                    const display_len = @min(@as(usize, cell.len), col_widths[c]);
                    if (r == 0) {
                        vga.setColor(.yellow, .black);
                    } else {
                        vga.setColor(.light_grey, .black);
                    }
                    vga.write(cell.data[0..display_len]);
                    var pad = col_widths[c] -| display_len;
                    while (pad > 0) : (pad -= 1) vga.putChar(' ');
                } else {
                    var pad = col_widths[c];
                    while (pad > 0) : (pad -= 1) vga.putChar(' ');
                }
            } else {
                var pad = col_widths[c];
                while (pad > 0) : (pad -= 1) vga.putChar(' ');
            }
            vga.setColor(.light_grey, .black);
            vga.write(" |");
        }
        vga.putChar('\n');

        // Separator after header
        if (r == 0) {
            printBorder(col_widths[0..max_cols], '+', '=');
        }
    }

    // Bottom border
    printBorder(col_widths[0..max_cols], '+', '-');

    vga.setColor(.dark_grey, .black);
    fmt.printDec(table.row_count);
    vga.write(" rows, ");
    fmt.printDec(max_cols);
    vga.write(" columns\n");
    vga.setColor(.light_grey, .black);
}

fn printBorder(widths: []const usize, corner: u8, fill: u8) void {
    vga.putChar(corner);
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            vga.putChar(fill);
        }
        vga.putChar(corner);
    }
    vga.putChar('\n');
}

/// Serialize the table back to CSV text.
/// Returns the number of bytes written.
pub fn serialize(table: *const CsvTable, buf: []u8) usize {
    var pos: usize = 0;

    var r: usize = 0;
    while (r < table.row_count) : (r += 1) {
        var c: usize = 0;
        while (c < table.col_count[r]) : (c += 1) {
            if (c > 0 and pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }

            const cell = &table.cells[r][c];
            if (cell.used) {
                // Check if quoting is needed
                const needs_quote = cellNeedsQuoting(cell.data[0..cell.len]);
                if (needs_quote) {
                    if (pos < buf.len) {
                        buf[pos] = '"';
                        pos += 1;
                    }
                    // Write with escaped quotes
                    var i: usize = 0;
                    while (i < cell.len) : (i += 1) {
                        if (cell.data[i] == '"') {
                            if (pos + 2 <= buf.len) {
                                buf[pos] = '"';
                                buf[pos + 1] = '"';
                                pos += 2;
                            }
                        } else {
                            if (pos < buf.len) {
                                buf[pos] = cell.data[i];
                                pos += 1;
                            }
                        }
                    }
                    if (pos < buf.len) {
                        buf[pos] = '"';
                        pos += 1;
                    }
                } else {
                    const copy_len = @min(@as(usize, cell.len), buf.len - pos);
                    @memcpy(buf[pos .. pos + copy_len], cell.data[0..copy_len]);
                    pos += copy_len;
                }
            }
        }
        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    return pos;
}

fn cellNeedsQuoting(data: []const u8) bool {
    for (data) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') return true;
    }
    return false;
}

/// Add a row to the table. Values is a slice of slices.
/// Returns true on success.
pub fn addRow(table: *CsvTable, values: []const []const u8) bool {
    if (table.row_count >= MAX_ROWS) return false;

    const r = table.row_count;
    const num_cols = @min(values.len, MAX_COLS);

    var c: usize = 0;
    while (c < num_cols) : (c += 1) {
        const cell = &table.cells[r][c];
        cell.len = @intCast(@min(values[c].len, MAX_CELL_LEN));
        @memcpy(cell.data[0..cell.len], values[c][0..cell.len]);
        cell.used = true;
    }
    table.col_count[r] = num_cols;
    table.row_count += 1;
    return true;
}

/// Sort the table by a specific column (ascending, lexicographic).
/// Skips row 0 (assumed to be header).
pub fn sortByColumn(table: *CsvTable, col: usize) void {
    if (table.row_count <= 2) return; // nothing to sort with 0-1 data rows

    // Simple bubble sort on rows 1..row_count-1
    var swapped = true;
    while (swapped) {
        swapped = false;
        var r: usize = 1;
        while (r + 1 < table.row_count) : (r += 1) {
            const a = getCellForSort(table, r, col);
            const b = getCellForSort(table, r + 1, col);
            if (compareSlices(a, b) > 0) {
                // Swap rows
                swapRows(table, r, r + 1);
                swapped = true;
            }
        }
    }
}

fn getCellForSort(table: *const CsvTable, row: usize, col: usize) []const u8 {
    if (col >= table.col_count[row]) return "";
    const cell = &table.cells[row][col];
    if (!cell.used) return "";
    return cell.data[0..cell.len];
}

fn compareSlices(a: []const u8, b: []const u8) i32 {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn swapRows(table: *CsvTable, a: usize, b: usize) void {
    // Swap col_count
    const tmp_cols = table.col_count[a];
    table.col_count[a] = table.col_count[b];
    table.col_count[b] = tmp_cols;

    // Swap cells
    var c: usize = 0;
    while (c < MAX_COLS) : (c += 1) {
        const tmp = table.cells[a][c];
        table.cells[a][c] = table.cells[b][c];
        table.cells[b][c] = tmp;
    }
}

/// Search for a value in the table. Returns row index or null.
pub fn findValue(table: *const CsvTable, value: []const u8) ?usize {
    var r: usize = 0;
    while (r < table.row_count) : (r += 1) {
        var c: usize = 0;
        while (c < table.col_count[r]) : (c += 1) {
            const cell = &table.cells[r][c];
            if (cell.used and cell.len == value.len and sliceEql(cell.data[0..cell.len], value)) {
                return r;
            }
        }
    }
    return null;
}

/// Count non-empty cells in the table.
pub fn countCells(table: *const CsvTable) usize {
    var count: usize = 0;
    var r: usize = 0;
    while (r < table.row_count) : (r += 1) {
        var c: usize = 0;
        while (c < table.col_count[r]) : (c += 1) {
            if (table.cells[r][c].used and table.cells[r][c].len > 0) count += 1;
        }
    }
    return count;
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
