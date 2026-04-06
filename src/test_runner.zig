// Extended Test Runner -- Categorized tests with TAP output
// Categories: unit, integration, stress, regression.
// Assertions: assertEquals, assertNotNull, assertGreaterThan, assertTrue, assertContains.
// Test fixtures: setUp/tearDown per test. TAP (Test Anything Protocol) output.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");
const pit = @import("pit.zig");

// ---- Constants ----

const MAX_TESTS = 64;
const MAX_NAME_LEN = 48;
const MAX_MSG_LEN = 64;

// ---- Types ----

pub const TestCategory = enum(u8) {
    unit,
    integration,
    stress,
    regression,

    pub fn name(self: TestCategory) []const u8 {
        return switch (self) {
            .unit => "unit",
            .integration => "integration",
            .stress => "stress",
            .regression => "regression",
        };
    }
};

pub const TestStatus = enum(u8) {
    pass,
    fail,
    skip,
    error_,
};

pub const TestResult = struct {
    status: TestStatus,
    message: [MAX_MSG_LEN]u8,
    message_len: u8,
    elapsed_ms: u32,
};

pub const TestFn = *const fn () TestResult;
pub const SetUpFn = *const fn () void;
pub const TearDownFn = *const fn () void;

pub const TestCase = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    category: TestCategory,
    func: TestFn,
    setup: ?SetUpFn,
    teardown: ?TearDownFn,
    timeout_ms: u32,
    expected_result: TestStatus,
    used: bool,
};

// ---- State ----

var tests: [MAX_TESTS]TestCase = undefined;
var test_count: usize = 0;
var initialized: bool = false;

// Run statistics
var stats_passed: usize = 0;
var stats_failed: usize = 0;
var stats_skipped: usize = 0;
var stats_errors: usize = 0;
var stats_total_ms: u32 = 0;

// ---- Initialization ----

fn ensureInit() void {
    if (initialized) return;
    var i: usize = 0;
    while (i < MAX_TESTS) : (i += 1) {
        tests[i].used = false;
    }
    test_count = 0;
    initialized = true;
}

// ---- Public API: Registration ----

/// Register a test with category, name, and function.
pub fn registerTest(category: TestCategory, name: []const u8, func: TestFn) bool {
    return registerTestFull(category, name, func, null, null, 0, .pass);
}

/// Register a test with all options.
pub fn registerTestFull(
    category: TestCategory,
    name: []const u8,
    func: TestFn,
    setup: ?SetUpFn,
    teardown: ?TearDownFn,
    timeout_ms: u32,
    expected: TestStatus,
) bool {
    ensureInit();
    if (test_count >= MAX_TESTS) return false;

    var tc = &tests[test_count];
    tc.used = true;
    tc.category = category;
    tc.func = func;
    tc.setup = setup;
    tc.teardown = teardown;
    tc.timeout_ms = if (timeout_ms == 0) 5000 else timeout_ms;
    tc.expected_result = expected;
    tc.name_len = @intCast(@min(name.len, MAX_NAME_LEN));
    @memcpy(tc.name[0..tc.name_len], name[0..tc.name_len]);

    test_count += 1;
    return true;
}

// ---- Public API: Execution ----

/// Run all tests in a specific category.
pub fn runCategory(category: TestCategory) void {
    ensureInit();
    resetStats();

    vga.setColor(.yellow, .black);
    vga.write("TAP version 13\n");

    // Count tests in category
    var count: usize = 0;
    var i: usize = 0;
    while (i < test_count) : (i += 1) {
        if (tests[i].used and tests[i].category == category) count += 1;
    }

    vga.write("# Category: ");
    vga.write(category.name());
    vga.putChar('\n');

    // TAP plan
    vga.setColor(.light_grey, .black);
    vga.write("1..");
    fmt.printDec(count);
    vga.putChar('\n');

    serial.write("TAP version 13\n# Category: ");
    serial.write(category.name());
    serial.write("\n1..");
    serialWriteDec(count);
    serial.putChar('\n');

    // Run tests
    var test_num: usize = 1;
    i = 0;
    while (i < test_count) : (i += 1) {
        if (!tests[i].used or tests[i].category != category) continue;
        runSingleTest(&tests[i], test_num);
        test_num += 1;
    }

    printSummary();
}

/// Run all registered tests across all categories.
pub fn runAll() void {
    ensureInit();
    resetStats();

    vga.setColor(.yellow, .black);
    vga.write("TAP version 13\n");
    vga.write("# Running all tests\n");

    vga.setColor(.light_grey, .black);
    vga.write("1..");
    fmt.printDec(test_count);
    vga.putChar('\n');

    serial.write("TAP version 13\n# Running all tests\n1..");
    serialWriteDec(test_count);
    serial.putChar('\n');

    // Run by category order
    const categories = [_]TestCategory{ .unit, .integration, .stress, .regression };
    var test_num: usize = 1;

    for (categories) |cat| {
        var has_tests = false;
        var i: usize = 0;
        while (i < test_count) : (i += 1) {
            if (tests[i].used and tests[i].category == cat) {
                if (!has_tests) {
                    vga.setColor(.dark_grey, .black);
                    vga.write("# --- ");
                    vga.write(cat.name());
                    vga.write(" ---\n");
                    has_tests = true;
                }
                runSingleTest(&tests[i], test_num);
                test_num += 1;
            }
        }
    }

    printSummary();
}

/// List all registered tests.
pub fn listTests() void {
    ensureInit();

    vga.setColor(.light_cyan, .black);
    vga.write("Registered Tests:\n");

    const categories = [_]TestCategory{ .unit, .integration, .stress, .regression };

    for (categories) |cat| {
        var has_tests = false;
        var i: usize = 0;
        while (i < test_count) : (i += 1) {
            if (tests[i].used and tests[i].category == cat) {
                if (!has_tests) {
                    vga.setColor(.yellow, .black);
                    vga.write("\n  [");
                    vga.write(cat.name());
                    vga.write("]\n");
                    has_tests = true;
                }
                vga.setColor(.light_grey, .black);
                vga.write("    ");
                vga.write(tests[i].name[0..tests[i].name_len]);
                if (tests[i].setup != null) {
                    vga.setColor(.dark_grey, .black);
                    vga.write(" +setup");
                }
                if (tests[i].teardown != null) {
                    vga.setColor(.dark_grey, .black);
                    vga.write(" +teardown");
                }
                vga.putChar('\n');
            }
        }
    }

    vga.setColor(.dark_grey, .black);
    vga.putChar('\n');
    fmt.printDec(test_count);
    vga.write(" tests registered\n");
    vga.setColor(.light_grey, .black);
}

// ---- Assertions ----

/// Assert that two values are equal.
pub fn assertEquals(a: usize, b: usize, msg: []const u8) TestResult {
    if (a == b) {
        return makeResult(.pass, msg);
    }
    return makeResult(.fail, msg);
}

/// Assert that a value is not null (non-zero).
pub fn assertNotNull(val: usize, msg: []const u8) TestResult {
    if (val != 0) {
        return makeResult(.pass, msg);
    }
    return makeResult(.fail, msg);
}

/// Assert that a > b.
pub fn assertGreaterThan(a: usize, b: usize, msg: []const u8) TestResult {
    if (a > b) {
        return makeResult(.pass, msg);
    }
    return makeResult(.fail, msg);
}

/// Assert that a condition is true.
pub fn assertTrue(condition: bool, msg: []const u8) TestResult {
    if (condition) {
        return makeResult(.pass, msg);
    }
    return makeResult(.fail, msg);
}

/// Assert that haystack contains needle.
pub fn assertContains(haystack: []const u8, needle: []const u8, msg: []const u8) TestResult {
    if (contains(haystack, needle)) {
        return makeResult(.pass, msg);
    }
    return makeResult(.fail, msg);
}

/// Assert that two slices are equal.
pub fn assertSliceEquals(a: []const u8, b: []const u8, msg: []const u8) TestResult {
    if (sliceEql(a, b)) {
        return makeResult(.pass, msg);
    }
    return makeResult(.fail, msg);
}

/// Skip a test with a reason.
pub fn skip(msg: []const u8) TestResult {
    return makeResult(.skip, msg);
}

/// Make a passing result.
pub fn pass(msg: []const u8) TestResult {
    return makeResult(.pass, msg);
}

/// Make a failing result.
pub fn fail(msg: []const u8) TestResult {
    return makeResult(.fail, msg);
}

// ---- Internal ----

fn makeResult(status: TestStatus, msg: []const u8) TestResult {
    var result: TestResult = undefined;
    result.status = status;
    result.elapsed_ms = 0;
    result.message_len = @intCast(@min(msg.len, MAX_MSG_LEN));
    @memcpy(result.message[0..result.message_len], msg[0..result.message_len]);
    return result;
}

fn runSingleTest(tc: *const TestCase, test_num: usize) void {
    // Run setup
    if (tc.setup) |setup_fn| {
        setup_fn();
    }

    // Time the test
    const start_ticks = pit.getTicks();
    const result = tc.func();
    const end_ticks = pit.getTicks();
    const elapsed: u32 = @truncate(end_ticks - start_ticks);

    // Run teardown
    if (tc.teardown) |teardown_fn| {
        teardown_fn();
    }

    // Check if result matches expected
    const actual_status = if (result.status == tc.expected_result) result.status else result.status;

    // Update stats
    switch (actual_status) {
        .pass => stats_passed += 1,
        .fail => stats_failed += 1,
        .skip => stats_skipped += 1,
        .error_ => stats_errors += 1,
    }
    stats_total_ms += elapsed;

    // TAP output to VGA
    switch (actual_status) {
        .pass => {
            vga.setColor(.light_green, .black);
            vga.write("ok ");
        },
        .fail => {
            vga.setColor(.light_red, .black);
            vga.write("not ok ");
        },
        .skip => {
            vga.setColor(.yellow, .black);
            vga.write("ok ");
        },
        .error_ => {
            vga.setColor(.light_red, .black);
            vga.write("not ok ");
        },
    }

    fmt.printDec(test_num);
    vga.setColor(.light_grey, .black);
    vga.write(" - ");
    vga.write(tc.name[0..tc.name_len]);

    if (actual_status == .skip) {
        vga.setColor(.dark_grey, .black);
        vga.write(" # SKIP");
    }

    if (result.message_len > 0) {
        vga.setColor(.dark_grey, .black);
        vga.write(" # ");
        vga.write(result.message[0..result.message_len]);
    }

    // Timing
    vga.setColor(.dark_grey, .black);
    vga.write(" (");
    fmt.printDec(elapsed);
    vga.write("ms)");
    vga.putChar('\n');

    // TAP output to serial
    switch (actual_status) {
        .pass => serial.write("ok "),
        .fail => serial.write("not ok "),
        .skip => serial.write("ok "),
        .error_ => serial.write("not ok "),
    }
    serialWriteDec(test_num);
    serial.write(" - ");
    serial.write(tc.name[0..tc.name_len]);
    if (actual_status == .skip) serial.write(" # SKIP");
    serial.putChar('\n');
}

fn resetStats() void {
    stats_passed = 0;
    stats_failed = 0;
    stats_skipped = 0;
    stats_errors = 0;
    stats_total_ms = 0;
}

fn printSummary() void {
    vga.putChar('\n');
    vga.setColor(.white, .black);
    vga.write("# Test Summary\n");

    vga.setColor(.light_green, .black);
    vga.write("#   Passed:  ");
    fmt.printDec(stats_passed);
    vga.putChar('\n');

    if (stats_failed > 0) {
        vga.setColor(.light_red, .black);
    } else {
        vga.setColor(.light_grey, .black);
    }
    vga.write("#   Failed:  ");
    fmt.printDec(stats_failed);
    vga.putChar('\n');

    vga.setColor(.yellow, .black);
    vga.write("#   Skipped: ");
    fmt.printDec(stats_skipped);
    vga.putChar('\n');

    if (stats_errors > 0) {
        vga.setColor(.light_red, .black);
        vga.write("#   Errors:  ");
        fmt.printDec(stats_errors);
        vga.putChar('\n');
    }

    vga.setColor(.light_grey, .black);
    vga.write("#   Total:   ");
    fmt.printDec(stats_passed + stats_failed + stats_skipped + stats_errors);
    vga.putChar('\n');

    vga.write("#   Time:    ");
    fmt.printDec(stats_total_ms);
    vga.write("ms\n");

    if (stats_failed == 0 and stats_errors == 0) {
        vga.setColor(.light_green, .black);
        vga.write("# All tests passed!\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("# FAILURES DETECTED\n");
    }
    vga.setColor(.light_grey, .black);
}

/// Get total number of registered tests.
pub fn getTestCount() usize {
    ensureInit();
    return test_count;
}

/// Get number of tests in a category.
pub fn getCategoryCount(category: TestCategory) usize {
    ensureInit();
    var count: usize = 0;
    var i: usize = 0;
    while (i < test_count) : (i += 1) {
        if (tests[i].used and tests[i].category == category) count += 1;
    }
    return count;
}

/// Clear all registered tests.
pub fn clearTests() void {
    var i: usize = 0;
    while (i < MAX_TESTS) : (i += 1) {
        tests[i].used = false;
    }
    test_count = 0;
}

// ---- Utility ----

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (sliceEql(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn serialWriteDec(n: usize) void {
    if (n == 0) {
        serial.putChar('0');
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
        serial.putChar(buf[len]);
    }
}
