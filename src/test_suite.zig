// In-Kernel Test Framework — カーネルモジュールの自動テスト
// 各サブシステムのユニットテストを実行し、結果をカラー表示

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const ramfs = @import("ramfs.zig");
const pipe = @import("pipe.zig");
const string = @import("string.zig");
const ringbuf = @import("ringbuf.zig");
const bitmap_mod = @import("bitmap.zig");
const serial = @import("serial.zig");

// ---- テスト結果 ----

pub const TestStatus = enum(u8) {
    pass,
    fail,
    skip,
};

pub const TestResult = struct {
    status: TestStatus,
    name: []const u8,
    message: []const u8,
};

// ---- テストケース ----

pub const TestFn = *const fn () TestResult;

pub const TestCase = struct {
    name: []const u8,
    func: TestFn,
};

// ---- アサーション ----

/// テストアサーション: 条件が false ならテスト失敗
pub fn assert(condition: bool, msg: []const u8) TestResult {
    if (condition) {
        return TestResult{ .status = .pass, .name = "", .message = msg };
    } else {
        return TestResult{ .status = .fail, .name = "", .message = msg };
    }
}

/// 等値アサーション: a != b ならテスト失敗
pub fn assertEqual(a: usize, b: usize, msg: []const u8) TestResult {
    if (a == b) {
        return TestResult{ .status = .pass, .name = "", .message = msg };
    } else {
        return TestResult{ .status = .fail, .name = "", .message = msg };
    }
}

// ---- テスト登録テーブル ----

const all_tests = [_]TestCase{
    .{ .name = "pmm_alloc_free", .func = test_pmm },
    .{ .name = "heap_alloc_free", .func = test_heap },
    .{ .name = "ramfs_create_rw_del", .func = test_ramfs },
    .{ .name = "pipe_write_read", .func = test_pipe },
    .{ .name = "string_functions", .func = test_string },
    .{ .name = "ringbuf_operations", .func = test_ringbuf },
    .{ .name = "bitmap_operations", .func = test_bitmap },
    .{ .name = "fmt_functions", .func = test_fmt },
};

// ---- テスト実行 ----

/// 全テストを実行し、結果を表示する
pub fn runAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Kernel Test Suite ===\n\n");

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    for (all_tests) |tc| {
        vga.setColor(.light_grey, .black);
        vga.write("  [");
        const result = tc.func();

        switch (result.status) {
            .pass => {
                vga.setColor(.light_green, .black);
                vga.write("PASS");
                passed += 1;
            },
            .fail => {
                vga.setColor(.light_red, .black);
                vga.write("FAIL");
                failed += 1;
            },
            .skip => {
                vga.setColor(.yellow, .black);
                vga.write("SKIP");
                skipped += 1;
            },
        }
        vga.setColor(.light_grey, .black);
        vga.write("] ");
        vga.write(tc.name);

        if (result.message.len > 0) {
            vga.write(" - ");
            if (result.status == .fail) {
                vga.setColor(.light_red, .black);
            }
            vga.write(result.message);
            vga.setColor(.light_grey, .black);
        }
        vga.putChar('\n');

        // シリアルにも出力
        serial.write("  [");
        switch (result.status) {
            .pass => serial.write("PASS"),
            .fail => serial.write("FAIL"),
            .skip => serial.write("SKIP"),
        }
        serial.write("] ");
        serial.write(tc.name);
        serial.putChar('\n');
    }

    // サマリー
    vga.putChar('\n');
    vga.setColor(.white, .black);
    vga.write("Results: ");
    vga.setColor(.light_green, .black);
    fmt.printDec(passed);
    vga.write(" passed");
    vga.setColor(.light_grey, .black);
    vga.write(", ");
    if (failed > 0) {
        vga.setColor(.light_red, .black);
    }
    fmt.printDec(failed);
    vga.write(" failed");
    vga.setColor(.light_grey, .black);
    vga.write(", ");
    vga.setColor(.yellow, .black);
    fmt.printDec(skipped);
    vga.write(" skipped");
    vga.setColor(.light_grey, .black);
    vga.write(" (");
    fmt.printDec(all_tests.len);
    vga.write(" total)\n");

    if (failed == 0) {
        vga.setColor(.light_green, .black);
        vga.write("All tests passed!\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Some tests failed.\n");
    }
    vga.setColor(.light_grey, .black);
}

// ---- テスト実装 ----

/// PMM テスト: ページの割り当てと解放
fn test_pmm() TestResult {
    const free_before = pmm.freeCount();

    // ページ割り当て
    const page = pmm.alloc();
    if (page == null) {
        return TestResult{ .status = .fail, .name = "pmm_alloc_free", .message = "alloc returned null" };
    }

    // 割り当て後は空きページが 1 減る
    const free_after_alloc = pmm.freeCount();
    if (free_after_alloc >= free_before) {
        pmm.free(page.?);
        return TestResult{ .status = .fail, .name = "pmm_alloc_free", .message = "free count did not decrease" };
    }

    // 解放
    pmm.free(page.?);

    // 解放後は元に戻る
    const free_after_free = pmm.freeCount();
    if (free_after_free != free_before) {
        return TestResult{ .status = .fail, .name = "pmm_alloc_free", .message = "free count mismatch after free" };
    }

    return TestResult{ .status = .pass, .name = "pmm_alloc_free", .message = "alloc/free pages OK" };
}

/// ヒープテスト: malloc/free
fn test_heap() TestResult {
    // 64 バイト確保
    const ptr = heap.alloc(64);
    if (ptr == null) {
        return TestResult{ .status = .fail, .name = "heap_alloc_free", .message = "alloc returned null" };
    }

    // メモリに書き込みテスト
    const p = ptr.?;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        p[i] = @truncate(i & 0xFF);
    }

    // 読み戻し検証
    i = 0;
    while (i < 64) : (i += 1) {
        if (p[i] != @as(u8, @truncate(i & 0xFF))) {
            heap.free(p);
            return TestResult{ .status = .fail, .name = "heap_alloc_free", .message = "data verification failed" };
        }
    }

    heap.free(p);
    return TestResult{ .status = .pass, .name = "heap_alloc_free", .message = "alloc/write/read/free OK" };
}

/// RAMFS テスト: ファイル作成・書き込み・読み取り・削除
fn test_ramfs() TestResult {
    // テストファイル作成
    const name = "__test_file__";
    const idx = ramfs.create(name);
    if (idx == null) {
        return TestResult{ .status = .fail, .name = "ramfs_create_rw_del", .message = "create failed" };
    }

    // 書き込み
    const data = "Hello, test!";
    const written = ramfs.writeFile(idx.?, data);
    if (written != data.len) {
        ramfs.remove(idx.?);
        return TestResult{ .status = .fail, .name = "ramfs_create_rw_del", .message = "write size mismatch" };
    }

    // 読み取り
    var buf: [64]u8 = undefined;
    const read_len = ramfs.readFile(idx.?, &buf);
    if (read_len != data.len) {
        ramfs.remove(idx.?);
        return TestResult{ .status = .fail, .name = "ramfs_create_rw_del", .message = "read size mismatch" };
    }

    // データ検証
    if (!eql(buf[0..read_len], data)) {
        ramfs.remove(idx.?);
        return TestResult{ .status = .fail, .name = "ramfs_create_rw_del", .message = "data content mismatch" };
    }

    // 削除
    ramfs.remove(idx.?);

    // 削除後にファイルが見つからないことを確認
    if (ramfs.findByName(name) != null) {
        return TestResult{ .status = .fail, .name = "ramfs_create_rw_del", .message = "file still exists after remove" };
    }

    return TestResult{ .status = .pass, .name = "ramfs_create_rw_del", .message = "create/write/read/delete OK" };
}

/// パイプテスト: 書き込みと読み取り
fn test_pipe() TestResult {
    const p = pipe.create();
    if (p == null) {
        return TestResult{ .status = .fail, .name = "pipe_write_read", .message = "create failed" };
    }
    const idx = p.?;

    // 書き込み
    const data = "pipe test data";
    const written = pipe.writePipe(idx, data);
    if (written != data.len) {
        pipe.destroy(idx);
        return TestResult{ .status = .fail, .name = "pipe_write_read", .message = "write size mismatch" };
    }

    // available チェック
    const avail = pipe.available(idx);
    if (avail != data.len) {
        pipe.destroy(idx);
        return TestResult{ .status = .fail, .name = "pipe_write_read", .message = "available count wrong" };
    }

    // 読み取り
    var buf: [64]u8 = undefined;
    const read_len = pipe.readPipe(idx, &buf);
    if (read_len != data.len) {
        pipe.destroy(idx);
        return TestResult{ .status = .fail, .name = "pipe_write_read", .message = "read size mismatch" };
    }

    if (!eql(buf[0..read_len], data)) {
        pipe.destroy(idx);
        return TestResult{ .status = .fail, .name = "pipe_write_read", .message = "data content mismatch" };
    }

    // 読み取り後の available は 0
    if (pipe.available(idx) != 0) {
        pipe.destroy(idx);
        return TestResult{ .status = .fail, .name = "pipe_write_read", .message = "buffer not empty after read" };
    }

    pipe.destroy(idx);
    return TestResult{ .status = .pass, .name = "pipe_write_read", .message = "write/read/verify OK" };
}

/// string.zig テスト
fn test_string() TestResult {
    // strlen
    const s: [*]const u8 = "hello\x00world";
    if (string.strlen(s) != 5) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "strlen failed" };
    }

    // strcmp
    if (string.strcmp("abc", "abc") != 0) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "strcmp equal failed" };
    }
    if (string.strcmp("abc", "abd") >= 0) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "strcmp less-than failed" };
    }
    if (string.strcmp("abd", "abc") <= 0) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "strcmp greater-than failed" };
    }

    // eql
    if (!string.eql("test", "test")) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "eql failed" };
    }
    if (string.eql("test", "tess")) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "eql false positive" };
    }

    // strchr
    if (string.strchr("hello", 'l') != 2) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "strchr failed" };
    }

    // contains
    if (!string.contains("hello world", "world")) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "contains failed" };
    }

    // atoi
    if (string.atoi("123") != 123) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "atoi failed" };
    }
    if (string.atoi("-42") != -42) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "atoi negative failed" };
    }

    // isDigit / isAlpha
    if (!string.isDigit('5')) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "isDigit failed" };
    }
    if (!string.isAlpha('A')) {
        return TestResult{ .status = .fail, .name = "string_functions", .message = "isAlpha failed" };
    }

    return TestResult{ .status = .pass, .name = "string_functions", .message = "all string tests OK" };
}

/// RingBuffer テスト
fn test_ringbuf() TestResult {
    var rb = ringbuf.RingBuffer(u8, 8){};

    // 空チェック
    if (!rb.isEmpty()) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "new buffer not empty" };
    }

    // push/pop
    rb.push(42);
    rb.push(99);
    if (rb.count() != 2) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "count wrong after push" };
    }

    const v1 = rb.pop();
    if (v1 != 42) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "pop returned wrong value" };
    }

    const v2 = rb.pop();
    if (v2 != 99) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "second pop wrong" };
    }

    if (!rb.isEmpty()) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "not empty after pop all" };
    }

    // オーバーフロー: push 9 elements into size-8 buffer
    var i: u8 = 0;
    while (i < 9) : (i += 1) {
        rb.push(i);
    }
    // バッファは満杯で最古の要素 (0) が消えている
    if (!rb.isFull()) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "should be full" };
    }
    const oldest = rb.pop();
    if (oldest != 1) { // 0 は上書きされたので 1 が先頭
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "overflow wrap incorrect" };
    }

    // tryPush テスト
    rb.clear();
    i = 0;
    while (i < 8) : (i += 1) {
        _ = rb.tryPush(i);
    }
    if (rb.tryPush(255)) {
        return TestResult{ .status = .fail, .name = "ringbuf_operations", .message = "tryPush should fail when full" };
    }

    return TestResult{ .status = .pass, .name = "ringbuf_operations", .message = "push/pop/overflow/tryPush OK" };
}

/// Bitmap テスト
fn test_bitmap() TestResult {
    var bm = bitmap_mod.Bitmap(64).initEmpty();

    // 初期状態: 全ビットクリア
    if (bm.countSet() != 0) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "initEmpty not empty" };
    }

    // set / isSet
    bm.set(0);
    bm.set(31);
    bm.set(63);
    if (!bm.isSet(0) or !bm.isSet(31) or !bm.isSet(63)) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "set/isSet failed" };
    }
    if (bm.countSet() != 3) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "countSet wrong" };
    }

    // clear
    bm.clear(31);
    if (bm.isSet(31)) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "clear failed" };
    }

    // findFirstFree
    var full = bitmap_mod.Bitmap(64).initFull();
    full.clear(42);
    if (full.findFirstFree() != 42) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "findFirstFree wrong" };
    }

    // findContiguous
    var bm2 = bitmap_mod.Bitmap(64).initFull();
    bm2.clearRange(10, 5); // ビット 10-14 をクリア
    if (bm2.findContiguous(5) != 10) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "findContiguous failed" };
    }

    // toggle
    var bm3 = bitmap_mod.Bitmap(32).initEmpty();
    bm3.toggle(5);
    if (!bm3.isSet(5)) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "toggle set failed" };
    }
    bm3.toggle(5);
    if (bm3.isSet(5)) {
        return TestResult{ .status = .fail, .name = "bitmap_operations", .message = "toggle clear failed" };
    }

    return TestResult{ .status = .pass, .name = "bitmap_operations", .message = "set/clear/find/toggle OK" };
}

/// fmt.zig テスト (パーサー)
fn test_fmt() TestResult {
    // parseU32
    const v1 = fmt.parseU32("12345");
    if (v1 == null or v1.? != 12345) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "parseU32(12345) failed" };
    }

    const v2 = fmt.parseU32("0");
    if (v2 == null or v2.? != 0) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "parseU32(0) failed" };
    }

    const v3 = fmt.parseU32("abc");
    if (v3 != null) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "parseU32(abc) should be null" };
    }

    const v4 = fmt.parseU32("");
    if (v4 != null) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "parseU32('') should be null" };
    }

    // eql
    if (!fmt.eql("hello", "hello")) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "eql failed" };
    }

    // trim
    const trimmed = fmt.trim("  hello  ");
    if (!eql(trimmed, "hello")) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "trim failed" };
    }

    // startsWith
    if (!fmt.startsWith("hello world", "hello")) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "startsWith failed" };
    }

    // indexOf
    if (fmt.indexOf("abcdef", 'd') != 3) {
        return TestResult{ .status = .fail, .name = "fmt_functions", .message = "indexOf failed" };
    }

    return TestResult{ .status = .pass, .name = "fmt_functions", .message = "parseU32/eql/trim/startsWith OK" };
}

// ---- ヘルパー ----

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
