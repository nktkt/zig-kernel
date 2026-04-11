// 自動テスト — ブート時に全ライブラリモジュールを検証

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");
const pit = @import("pit.zig");
const ramfs = @import("ramfs.zig");
const pipe = @import("pipe.zig");
const string = @import("string.zig");
const math = @import("math.zig");
const crypto = @import("crypto.zig");
const base64 = @import("base64.zig");
const sort = @import("sort.zig");
const checksum_mod = @import("checksum.zig");
const bitops = @import("bitops.zig");
const color = @import("color.zig");
const fmt = @import("fmt.zig");
const ringbuf = @import("ringbuf.zig");
const compress = @import("compress.zig");
const sha256 = @import("sha256.zig");
const md5 = @import("md5.zig");
const hmac = @import("hmac.zig");
const path = @import("path.zig");
const permission = @import("permission.zig");
const errno = @import("errno.zig");

var passed: u32 = 0;
var failed: u32 = 0;

fn ok(name: []const u8) void {
    passed += 1;
    serial.write("  [PASS] ");
    serial.write(name);
    serial.write("\n");
}

fn fail(name: []const u8) void {
    failed += 1;
    serial.write("  [FAIL] ");
    serial.write(name);
    serial.write("\n");
    vga.setColor(.light_red, .black);
    vga.write("  FAIL: ");
    vga.write(name);
    vga.putChar('\n');
}

pub fn run() void {
    vga.setColor(.yellow, .black);
    vga.write("[TEST] Running automated tests...\n");
    serial.write("\n=== AUTOTEST START ===\n");
    passed = 0;
    failed = 0;

    testFmt();
    testPmm();
    testRamfs();
    testPipe();
    testMath();
    testBitops();
    testErrno();
    testString();
    testCrypto();
    testBase64();
    testSort();
    testChecksum();
    testRingbuf();
    testCompress();
    testPath();
    testPermission();
    testColor();
    testSha256();
    testMd5();
    testHmac();

    // 結果表示
    serial.write("=== AUTOTEST DONE: ");
    serialNum(passed);
    serial.write(" passed, ");
    serialNum(failed);
    serial.write(" failed ===\n");

    if (failed == 0) {
        vga.setColor(.light_green, .black);
        vga.write("[TEST] ALL ");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("[TEST] ");
    }
    printNum(passed);
    vga.write(" passed, ");
    printNum(failed);
    vga.write(" failed\n");
    vga.setColor(.light_grey, .black);
}

// ---- 個別テスト ----

fn testString() void {
    if (string.strlen("hello") == 5) ok("string.strlen") else fail("string.strlen");
    if (string.strcmp("abc", "abc") == 0) ok("string.strcmp eq") else fail("string.strcmp eq");
    if (string.strcmp("abc", "abd") < 0) ok("string.strcmp lt") else fail("string.strcmp lt");
    if (string.atoi("12345")) |v| {
        if (v == 12345) ok("string.atoi") else fail("string.atoi value");
    } else fail("string.atoi null");
    if (string.contains("hello world", "world")) ok("string.contains") else fail("string.contains");
    if (!string.contains("hello", "xyz")) ok("string.contains neg") else fail("string.contains neg");
}

fn testMath() void {
    if (math.abs(-5) == 5) ok("math.abs") else fail("math.abs");
    if (math.minI32(3, 7) == 3) ok("math.min") else fail("math.min");
    if (math.maxI32(3, 7) == 7) ok("math.max") else fail("math.max");
    if (math.gcd(12, 8) == 4) ok("math.gcd") else fail("math.gcd");
    if (math.lcm(4, 6) == 12) ok("math.lcm") else fail("math.lcm");
    if (math.isPrime(7)) ok("math.isPrime 7") else fail("math.isPrime 7");
    if (!math.isPrime(4)) ok("math.isPrime 4") else fail("math.isPrime 4");
    if (math.sqrt_int(144) == 12) ok("math.sqrt") else fail("math.sqrt");
    if (math.pow(2, 10) == 1024) ok("math.pow") else fail("math.pow");
}

fn testCrypto() void {
    const data = "hello";
    const crc = crypto.crc32(data);
    if (crc != 0) ok("crypto.crc32") else fail("crypto.crc32");
    const fnv = crypto.fnv1a(data);
    if (fnv != 0) ok("crypto.fnv1a") else fail("crypto.fnv1a");

    // XOR encrypt/decrypt roundtrip
    var encrypted: [5]u8 = undefined;
    var decrypted: [5]u8 = undefined;
    crypto.xorEncrypt(data, "key", &encrypted);
    crypto.xorDecrypt(&encrypted, "key", &decrypted);
    if (decrypted[0] == 'h' and decrypted[4] == 'o') ok("crypto.xor roundtrip") else fail("crypto.xor roundtrip");

    // PRNG
    crypto.seed(42);
    const r1 = crypto.rand();
    const r2 = crypto.rand();
    if (r1 != r2) ok("crypto.rand") else fail("crypto.rand");
}

fn testBase64() void {
    var enc_buf: [32]u8 = undefined;
    var dec_buf: [32]u8 = undefined;
    const input = "Hello";
    const enc_len = base64.encode(input, &enc_buf);
    if (enc_len > 0) {
        const dec_len = base64.decode(enc_buf[0..enc_len], &dec_buf);
        if (dec_len) |dl| {
            if (dl == 5 and dec_buf[0] == 'H' and dec_buf[4] == 'o') {
                ok("base64 roundtrip");
            } else fail("base64 roundtrip value");
        } else fail("base64 decode null");
    } else fail("base64 encode");
}

fn testSort() void {
    var data = [_]u32{ 5, 3, 1, 4, 2 };
    sort.quickSort(&data);
    if (sort.isSorted(&data)) ok("sort.quickSort") else fail("sort.quickSort");
    if (sort.binarySearch(&data, 3)) |idx| {
        if (idx == 2) ok("sort.binarySearch") else fail("sort.binarySearch idx");
    } else fail("sort.binarySearch null");
    if (sort.min(&data) == 1) ok("sort.min") else fail("sort.min");
    if (sort.max(&data) == 5) ok("sort.max") else fail("sort.max");
}

fn testChecksum() void {
    const data = "test data";
    const a32 = checksum_mod.adler32(data);
    if (a32 != 0) ok("checksum.adler32") else fail("checksum.adler32");
    const fl16 = checksum_mod.fletcher16(data);
    if (fl16 != 0) ok("checksum.fletcher16") else fail("checksum.fletcher16");
    const xor = checksum_mod.xorChecksum(data);
    _ = xor;
    ok("checksum.xor");
}

fn testBitops() void {
    if (bitops.popcount(0xFF) == 8) ok("bitops.popcount") else fail("bitops.popcount");
    if (bitops.isPowerOf2(256)) ok("bitops.isPow2") else fail("bitops.isPow2");
    if (!bitops.isPowerOf2(255)) ok("bitops.isPow2 neg") else fail("bitops.isPow2 neg");
    if (bitops.nextPowerOf2(5) == 8) ok("bitops.nextPow2") else fail("bitops.nextPow2");
}

fn testRingbuf() void {
    var rb = ringbuf.RingBuffer(u8, 8){};
    rb.push('A');
    rb.push('B');
    rb.push('C');
    if (rb.count() == 3) ok("ringbuf.count") else fail("ringbuf.count");
    if (rb.pop()) |v| {
        if (v == 'A') ok("ringbuf.pop") else fail("ringbuf.pop value");
    } else fail("ringbuf.pop null");
    if (rb.count() == 2) ok("ringbuf.count after pop") else fail("ringbuf.count after pop");
}

fn testCompress() void {
    const input = "AAAAABBBCC";
    var compressed: [64]u8 = undefined;
    var decompressed: [64]u8 = undefined;
    const comp_len = compress.rleEncode(input, &compressed);
    if (comp_len > 0) {
        const decomp_len = compress.rleDecode(compressed[0..comp_len], &decompressed);
        if (decomp_len == input.len) ok("compress.rle roundtrip") else fail("compress.rle roundtrip len");
    } else fail("compress.rle encode");
}

fn testSha256() void {
    const hash = sha256.hash("abc");
    // SHA-256("abc") = ba7816bf...
    if (hash[0] == 0xba and hash[1] == 0x78) ok("sha256.hash abc") else fail("sha256.hash abc");

    // Empty string
    const empty_hash = sha256.hash("");
    // SHA-256("") = e3b0c44298fc...
    if (empty_hash[0] == 0xe3 and empty_hash[1] == 0xb0) ok("sha256.hash empty") else fail("sha256.hash empty");
}

fn testMd5() void {
    const hash = md5.hash("abc");
    // MD5("abc") = 900150983cd24fb0d6963f7d28e17f72
    if (hash[0] == 0x90 and hash[1] == 0x01) ok("md5.hash abc") else fail("md5.hash abc");
}

fn testHmac() void {
    const mac = hmac.hmacSha256("key", "message");
    if (mac[0] != 0 or mac[1] != 0) ok("hmac.sha256") else fail("hmac.sha256");
    if (hmac.verify("key", "message", mac)) ok("hmac.verify") else fail("hmac.verify");
}

fn testPath() void {
    const b = path.basename("/dir/file.txt");
    if (b.len == 8 and b[0] == 'f') ok("path.basename") else fail("path.basename");
    const d = path.dirname("/dir/file.txt");
    if (d.len == 4 and d[0] == '/') ok("path.dirname") else fail("path.dirname");
    const e = path.extension("file.txt");
    if (e.len == 3 and e[0] == 't') ok("path.extension") else fail("path.extension");
    if (path.isAbsolute("/foo")) ok("path.isAbsolute") else fail("path.isAbsolute");
    if (!path.isAbsolute("foo")) ok("path.isRelative") else fail("path.isRelative");
}

fn testPermission() void {
    const p = permission.fromOctal(0o755);
    var buf: [10]u8 = undefined;
    _ = permission.toString(p, &buf);
    if (buf[0] == 'r' and buf[1] == 'w' and buf[2] == 'x') ok("permission.toString") else fail("permission.toString");
    if (permission.check(p, 0, 0, 0, 0, .READ)) ok("permission.check owner r") else fail("permission.check owner r");
}

fn testErrno() void {
    const s = errno.strerror(.ENOENT);
    if (s.len > 0) ok("errno.strerror") else fail("errno.strerror");
    errno.setErrno(.SUCCESS);
    if (errno.getErrno() == .SUCCESS) ok("errno.get/set") else fail("errno.get/set");
}

fn testFmt() void {
    if (fmt.eql("hello", "hello")) ok("fmt.eql") else fail("fmt.eql");
    if (!fmt.eql("hello", "world")) ok("fmt.eql neg") else fail("fmt.eql neg");
    if (fmt.startsWith("hello world", "hello")) ok("fmt.startsWith") else fail("fmt.startsWith");
    const trimmed = fmt.trim("  hi  ");
    if (trimmed.len == 2 and trimmed[0] == 'h') ok("fmt.trim") else fail("fmt.trim");
    if (fmt.parseU32("42")) |v| {
        if (v == 42) ok("fmt.parseU32") else fail("fmt.parseU32 val");
    } else fail("fmt.parseU32 null");
}

fn testColor() void {
    const c = color.RGB{ .r = 255, .g = 128, .b = 0 };
    const idx = color.rgbTo256(c);
    _ = idx;
    ok("color.rgbTo256");
    const blended = color.blend(
        color.RGB{ .r = 255, .g = 0, .b = 0 },
        color.RGB{ .r = 0, .g = 0, .b = 255 },
        128,
    );
    if (blended.r > 100 and blended.b > 100) ok("color.blend") else fail("color.blend");
}

fn testRamfs() void {
    // ファイル作成・書き込み・読み取り・削除
    if (ramfs.create("_test_.txt")) |idx| {
        const data = "autotest data";
        _ = ramfs.writeFile(idx, data);
        var buf: [64]u8 = undefined;
        const n = ramfs.readFile(idx, &buf);
        if (n == data.len and buf[0] == 'a') ok("ramfs read/write") else fail("ramfs read/write");
        ramfs.remove(idx);
        if (ramfs.findByName("_test_.txt") == null) ok("ramfs remove") else fail("ramfs remove");
    } else fail("ramfs create");

    // ディレクトリ
    if (ramfs.mkdir("_testdir_")) {
        ok("ramfs mkdir");
        if (ramfs.chdir("_testdir_")) {
            ok("ramfs chdir");
            _ = ramfs.chdir("..");
        } else fail("ramfs chdir");
    } else fail("ramfs mkdir");
}

fn testPipe() void {
    if (pipe.create()) |idx| {
        const msg = "pipe test";
        const written = pipe.writePipe(idx, msg);
        if (written == msg.len) {
            var buf: [32]u8 = undefined;
            const read = pipe.readPipe(idx, &buf);
            if (read == msg.len and buf[0] == 'p') ok("pipe read/write") else fail("pipe read/write data");
        } else fail("pipe write");
        pipe.destroy(idx);
        ok("pipe destroy");
    } else fail("pipe create");
}

fn testPmm() void {
    const before = pmm.freeCount();
    if (pmm.alloc()) |addr| {
        const after = pmm.freeCount();
        if (after == before - 1) ok("pmm alloc count") else fail("pmm alloc count");
        pmm.free(addr);
        if (pmm.freeCount() == before) ok("pmm free count") else fail("pmm free count");
    } else fail("pmm alloc");
}

// ---- ユーティリティ ----

fn printNum(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn serialNum(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @truncate('0' + v % 10);
        len += 1;
        v /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
