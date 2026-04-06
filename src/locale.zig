// Locale and internationalization -- Date/time/number formatting
// Supports locales: en_US, ja_JP, de_DE, fr_FR, en_GB.
// Date formats: ISO (YYYY-MM-DD), US (MM/DD/YYYY), EU (DD/MM/YYYY), JP (YYYY年MM月DD日).
// Time formats: 24h, 12h (AM/PM).
// Number formatting: decimal/thousands separators. Currency symbols.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");

// ---- Constants ----

const MAX_LOCALE_NAME = 8;
const MAX_FORMAT_BUF = 32;

// ---- Locale definitions ----

pub const DateFormat = enum(u8) {
    iso, // YYYY-MM-DD
    us, // MM/DD/YYYY
    eu, // DD/MM/YYYY
    jp, // YYYY/MM/DD
};

pub const TimeFormat = enum(u8) {
    h24, // 14:30:00
    h12, // 2:30:00 PM
};

pub const LocaleInfo = struct {
    name: [MAX_LOCALE_NAME]u8,
    name_len: u8,
    date_format: DateFormat,
    time_format: TimeFormat,
    decimal_sep: u8, // '.' or ','
    thousands_sep: u8, // ',' or '.'
    currency: [4]u8, // "$", "EUR", "JPY", etc.
    currency_len: u8,
    currency_before: bool, // true = "$100", false = "100 EUR"
};

// ---- Predefined locales ----

const LOCALE_EN_US = LocaleInfo{
    .name = "en_US\x00\x00\x00".*,
    .name_len = 5,
    .date_format = .us,
    .time_format = .h12,
    .decimal_sep = '.',
    .thousands_sep = ',',
    .currency = "$\x00\x00\x00".*,
    .currency_len = 1,
    .currency_before = true,
};

const LOCALE_EN_GB = LocaleInfo{
    .name = "en_GB\x00\x00\x00".*,
    .name_len = 5,
    .date_format = .eu,
    .time_format = .h24,
    .decimal_sep = '.',
    .thousands_sep = ',',
    .currency = "GBP\x00".*,
    .currency_len = 1, // just use pound sign area
    .currency_before = true,
};

const LOCALE_DE_DE = LocaleInfo{
    .name = "de_DE\x00\x00\x00".*,
    .name_len = 5,
    .date_format = .eu,
    .time_format = .h24,
    .decimal_sep = ',',
    .thousands_sep = '.',
    .currency = "EUR\x00".*,
    .currency_len = 3,
    .currency_before = false,
};

const LOCALE_FR_FR = LocaleInfo{
    .name = "fr_FR\x00\x00\x00".*,
    .name_len = 5,
    .date_format = .eu,
    .time_format = .h24,
    .decimal_sep = ',',
    .thousands_sep = ' ',
    .currency = "EUR\x00".*,
    .currency_len = 3,
    .currency_before = false,
};

const LOCALE_JA_JP = LocaleInfo{
    .name = "ja_JP\x00\x00\x00".*,
    .name_len = 5,
    .date_format = .jp,
    .time_format = .h24,
    .decimal_sep = '.',
    .thousands_sep = ',',
    .currency = "JPY\x00".*,
    .currency_len = 3,
    .currency_before = true,
};

// ---- State ----

var current_locale: LocaleInfo = LOCALE_EN_US;

// ---- Day/Month names (English) ----

const day_names_short = [7][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const day_names_full = [7][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

const month_names_short = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const month_names_full = [12][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

// ---- DateTime struct ----

pub const DateTime = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8, // 0-59
    second: u8, // 0-59
    day_of_week: u8, // 0=Monday, 6=Sunday
};

// ---- Public API: Locale management ----

/// Set the active locale by name. Returns true on success.
pub fn setLocale(locale_name: []const u8) bool {
    if (sliceEql(locale_name, "en_US")) {
        current_locale = LOCALE_EN_US;
        return true;
    }
    if (sliceEql(locale_name, "en_GB")) {
        current_locale = LOCALE_EN_GB;
        return true;
    }
    if (sliceEql(locale_name, "de_DE")) {
        current_locale = LOCALE_DE_DE;
        return true;
    }
    if (sliceEql(locale_name, "fr_FR")) {
        current_locale = LOCALE_FR_FR;
        return true;
    }
    if (sliceEql(locale_name, "ja_JP")) {
        current_locale = LOCALE_JA_JP;
        return true;
    }
    return false;
}

/// Get the current locale name.
pub fn getLocaleName() []const u8 {
    return current_locale.name[0..current_locale.name_len];
}

/// Get the current locale info.
pub fn getLocale() *const LocaleInfo {
    return &current_locale;
}

// ---- Public API: Date formatting ----

/// Format a date according to the current locale. Returns the slice of buf used.
pub fn formatDate(dt: *const DateTime, buf: []u8) []const u8 {
    if (buf.len < 12) return buf[0..0];
    var pos: usize = 0;

    switch (current_locale.date_format) {
        .iso => {
            // YYYY-MM-DD
            pos += writeDecPadded(buf[pos..], dt.year, 4);
            buf[pos] = '-';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.month, 2);
            buf[pos] = '-';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.day, 2);
        },
        .us => {
            // MM/DD/YYYY
            pos += writeDecPadded(buf[pos..], dt.month, 2);
            buf[pos] = '/';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.day, 2);
            buf[pos] = '/';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.year, 4);
        },
        .eu => {
            // DD/MM/YYYY
            pos += writeDecPadded(buf[pos..], dt.day, 2);
            buf[pos] = '/';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.month, 2);
            buf[pos] = '/';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.year, 4);
        },
        .jp => {
            // YYYY/MM/DD
            pos += writeDecPadded(buf[pos..], dt.year, 4);
            buf[pos] = '/';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.month, 2);
            buf[pos] = '/';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.day, 2);
        },
    }

    return buf[0..pos];
}

/// Format time according to the current locale.
pub fn formatTime(dt: *const DateTime, buf: []u8) []const u8 {
    if (buf.len < 12) return buf[0..0];
    var pos: usize = 0;

    switch (current_locale.time_format) {
        .h24 => {
            pos += writeDecPadded(buf[pos..], dt.hour, 2);
            buf[pos] = ':';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.minute, 2);
            buf[pos] = ':';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.second, 2);
        },
        .h12 => {
            var h = dt.hour;
            const pm = h >= 12;
            if (h == 0) h = 12 else if (h > 12) h -= 12;

            pos += writeDecPadded(buf[pos..], h, 2);
            buf[pos] = ':';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.minute, 2);
            buf[pos] = ':';
            pos += 1;
            pos += writeDecPadded(buf[pos..], dt.second, 2);
            buf[pos] = ' ';
            pos += 1;
            if (pm) {
                buf[pos] = 'P';
            } else {
                buf[pos] = 'A';
            }
            pos += 1;
            buf[pos] = 'M';
            pos += 1;
        },
    }

    return buf[0..pos];
}

/// Format a number with locale-appropriate separators.
pub fn formatNumber(n: u32, buf: []u8) []const u8 {
    if (buf.len < 14) return buf[0..0];

    // First, convert to decimal string (reversed)
    var digits: [12]u8 = undefined;
    var digit_count: usize = 0;
    var val = n;
    if (val == 0) {
        digits[0] = '0';
        digit_count = 1;
    } else {
        while (val > 0) {
            digits[digit_count] = @truncate('0' + val % 10);
            digit_count += 1;
            val /= 10;
        }
    }

    // Now write to buf with thousands separators
    var pos: usize = 0;
    var i: usize = digit_count;
    while (i > 0) {
        i -= 1;
        buf[pos] = digits[i];
        pos += 1;
        // Add thousands separator every 3 digits from the right
        if (i > 0 and i % 3 == 0 and current_locale.thousands_sep != 0) {
            buf[pos] = current_locale.thousands_sep;
            pos += 1;
        }
    }

    return buf[0..pos];
}

/// Format a decimal number (integer part + fractional part).
pub fn formatDecimal(integer_part: u32, decimal_part: u32, decimal_digits: u8, buf: []u8) []const u8 {
    if (buf.len < 20) return buf[0..0];
    var pos: usize = 0;

    // Write integer part
    const int_str = formatNumber(integer_part, buf[pos..]);
    pos += int_str.len;

    // Decimal separator
    buf[pos] = current_locale.decimal_sep;
    pos += 1;

    // Decimal part (zero-padded)
    pos += writeDecPadded(buf[pos..], decimal_part, decimal_digits);

    return buf[0..pos];
}

/// Format a currency value.
pub fn formatCurrency(amount: u32, cents: u32, buf: []u8) []const u8 {
    if (buf.len < 24) return buf[0..0];
    var pos: usize = 0;

    if (current_locale.currency_before) {
        // "$100.50"
        @memcpy(buf[pos .. pos + current_locale.currency_len], current_locale.currency[0..current_locale.currency_len]);
        pos += current_locale.currency_len;
    }

    const dec_str = formatDecimal(amount, cents, 2, buf[pos..]);
    pos += dec_str.len;

    if (!current_locale.currency_before) {
        // "100.50 EUR"
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos .. pos + current_locale.currency_len], current_locale.currency[0..current_locale.currency_len]);
        pos += current_locale.currency_len;
    }

    return buf[0..pos];
}

// ---- Public API: Names ----

/// Get abbreviated day name (0=Monday, 6=Sunday).
pub fn getDayNameShort(day_of_week: u8) []const u8 {
    if (day_of_week > 6) return "???";
    return day_names_short[day_of_week];
}

/// Get full day name.
pub fn getDayNameFull(day_of_week: u8) []const u8 {
    if (day_of_week > 6) return "???";
    return day_names_full[day_of_week];
}

/// Get abbreviated month name (1-12).
pub fn getMonthNameShort(month: u8) []const u8 {
    if (month < 1 or month > 12) return "???";
    return month_names_short[month - 1];
}

/// Get full month name.
pub fn getMonthNameFull(month: u8) []const u8 {
    if (month < 1 or month > 12) return "???";
    return month_names_full[month - 1];
}

/// Calculate day of week (Zeller's congruence). 0=Monday, 6=Sunday.
pub fn dayOfWeek(year: u16, month: u8, day: u8) u8 {
    var y: i32 = year;
    var m: i32 = month;
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const q: i32 = day;
    const k: i32 = @rem(y, 100);
    const j: i32 = @divTrunc(y, 100);
    var h: i32 = @rem(q + @divTrunc(13 * (m + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) - 2 * j, 7);
    if (h < 0) h += 7;
    // Convert from Zeller (0=Sat) to our convention (0=Mon)
    // Zeller: 0=Sat, 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri
    const conversion = [7]u8{ 5, 6, 0, 1, 2, 3, 4 };
    return conversion[@intCast(h)];
}

/// Check if a year is a leap year.
pub fn isLeapYear(year: u16) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    if (year % 4 == 0) return true;
    return false;
}

/// Get number of days in a month.
pub fn daysInMonth(year: u16, month: u8) u8 {
    const days = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 or month > 12) return 0;
    if (month == 2 and isLeapYear(year)) return 29;
    return days[month - 1];
}

// ---- Public API: Display ----

/// Print comprehensive locale info to VGA.
pub fn printLocaleInfo() void {
    vga.setColor(.light_cyan, .black);
    vga.write("Locale Information:\n");
    vga.setColor(.light_grey, .black);

    vga.write("  Locale:     ");
    vga.setColor(.white, .black);
    vga.write(current_locale.name[0..current_locale.name_len]);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("  Date fmt:   ");
    vga.setColor(.white, .black);
    switch (current_locale.date_format) {
        .iso => vga.write("YYYY-MM-DD (ISO 8601)\n"),
        .us => vga.write("MM/DD/YYYY (US)\n"),
        .eu => vga.write("DD/MM/YYYY (European)\n"),
        .jp => vga.write("YYYY/MM/DD (Japanese)\n"),
    }

    vga.setColor(.light_grey, .black);
    vga.write("  Time fmt:   ");
    vga.setColor(.white, .black);
    switch (current_locale.time_format) {
        .h24 => vga.write("24-hour\n"),
        .h12 => vga.write("12-hour (AM/PM)\n"),
    }

    vga.setColor(.light_grey, .black);
    vga.write("  Decimal:    '");
    vga.putChar(current_locale.decimal_sep);
    vga.write("'\n");

    vga.write("  Thousands:  '");
    if (current_locale.thousands_sep == ' ') {
        vga.write("(space)");
    } else {
        vga.putChar(current_locale.thousands_sep);
    }
    vga.write("'\n");

    vga.write("  Currency:   ");
    vga.setColor(.yellow, .black);
    vga.write(current_locale.currency[0..current_locale.currency_len]);
    vga.setColor(.light_grey, .black);
    if (current_locale.currency_before) {
        vga.write(" (prefix)\n");
    } else {
        vga.write(" (suffix)\n");
    }

    // Show example formatting
    vga.setColor(.light_cyan, .black);
    vga.write("\n  Examples:\n");

    const sample_dt = DateTime{
        .year = 2026,
        .month = 4,
        .day = 4,
        .hour = 14,
        .minute = 30,
        .second = 45,
        .day_of_week = 5, // Saturday
    };

    var date_buf: [32]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    var num_buf: [32]u8 = undefined;

    const date_str = formatDate(&sample_dt, &date_buf);
    const time_str = formatTime(&sample_dt, &time_buf);
    const num_str = formatNumber(1234567, &num_buf);

    vga.setColor(.light_grey, .black);
    vga.write("    Date:     ");
    vga.setColor(.white, .black);
    vga.write(date_str);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("    Time:     ");
    vga.setColor(.white, .black);
    vga.write(time_str);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
    vga.write("    Number:   ");
    vga.setColor(.white, .black);
    vga.write(num_str);
    vga.putChar('\n');

    vga.setColor(.light_grey, .black);
}

/// List all available locales.
pub fn listLocales() void {
    vga.setColor(.light_cyan, .black);
    vga.write("Available Locales:\n");

    const locales = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "en_US", .desc = "English (United States)" },
        .{ .name = "en_GB", .desc = "English (United Kingdom)" },
        .{ .name = "de_DE", .desc = "German (Germany)" },
        .{ .name = "fr_FR", .desc = "French (France)" },
        .{ .name = "ja_JP", .desc = "Japanese (Japan)" },
    };

    for (locales) |loc| {
        vga.setColor(.light_grey, .black);
        vga.write("  ");
        if (sliceEql(loc.name, current_locale.name[0..current_locale.name_len])) {
            vga.setColor(.light_green, .black);
            vga.write("* ");
        } else {
            vga.write("  ");
        }
        vga.setColor(.yellow, .black);
        vga.write(loc.name);
        vga.setColor(.light_grey, .black);
        vga.write("  ");
        vga.write(loc.desc);
        vga.putChar('\n');
    }
    vga.setColor(.light_grey, .black);
}

// ---- Internal helpers ----

fn writeDecPadded(buf: []u8, val: anytype, width: usize) usize {
    const v: u32 = @intCast(val);
    var digits: [10]u8 = undefined;
    var digit_count: usize = 0;
    var tmp = v;
    if (tmp == 0) {
        digits[0] = '0';
        digit_count = 1;
    } else {
        while (tmp > 0) {
            digits[digit_count] = @truncate('0' + tmp % 10);
            digit_count += 1;
            tmp /= 10;
        }
    }

    var pos: usize = 0;
    // Leading zeros
    if (digit_count < width) {
        var pad = width - digit_count;
        while (pad > 0 and pos < buf.len) : (pad -= 1) {
            buf[pos] = '0';
            pos += 1;
        }
    }
    // Digits (reversed)
    var i = digit_count;
    while (i > 0 and pos < buf.len) {
        i -= 1;
        buf[pos] = digits[i];
        pos += 1;
    }
    return pos;
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
