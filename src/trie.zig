// Trie (Prefix Tree) — 文字列検索用データ構造
// ノードプール (256 ノード), a-z の 26 文字をサポート
// ヒープ不要, 固定サイズ

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const MAX_NODES = 256;
pub const ALPHABET_SIZE = 26;
pub const NIL: u16 = 0xFFFF;
pub const MAX_WORD_LEN = 32;

// ---- ノード ----

pub const TrieNode = struct {
    children: [ALPHABET_SIZE]u16 = [_]u16{NIL} ** ALPHABET_SIZE,
    is_end: bool = false,
    value: u32 = 0,
    used: bool = false,
    prefix_count: u32 = 0, // この接頭辞を通過する単語数
};

// ---- Trie 本体 ----

pub const Trie = struct {
    nodes: [MAX_NODES]TrieNode = [_]TrieNode{.{}} ** MAX_NODES,
    root: u16 = NIL,
    word_count: usize = 0,

    /// Trie を初期化 (ルートノードを確保)
    pub fn init(self: *Trie) void {
        for (&self.nodes) |*n| {
            n.* = .{};
        }
        self.word_count = 0;
        self.root = self.allocNode() orelse return;
    }

    // ---- ノードプール管理 ----

    fn allocNode(self: *Trie) ?u16 {
        for (0..MAX_NODES) |i| {
            if (!self.nodes[i].used) {
                self.nodes[i] = .{
                    .children = [_]u16{NIL} ** ALPHABET_SIZE,
                    .is_end = false,
                    .value = 0,
                    .used = true,
                    .prefix_count = 0,
                };
                return @truncate(i);
            }
        }
        return null;
    }

    fn freeNode(self: *Trie, idx: u16) void {
        if (idx == NIL) return;
        self.nodes[idx].used = false;
        self.nodes[idx].is_end = false;
        self.nodes[idx].prefix_count = 0;
        for (&self.nodes[idx].children) |*c| {
            c.* = NIL;
        }
    }

    // ---- ヘルパー ----

    /// 文字をインデックスに変換 (a=0, b=1, ..., z=25)
    fn charToIndex(c: u8) ?u8 {
        if (c >= 'a' and c <= 'z') return c - 'a';
        if (c >= 'A' and c <= 'Z') return c - 'A'; // 大文字も小文字として扱う
        return null;
    }

    fn indexToChar(idx: u8) u8 {
        return 'a' + idx;
    }

    // ---- 挿入 ----

    /// 単語と値を挿入
    pub fn insert(self: *Trie, word: []const u8, value: u32) bool {
        if (self.root == NIL) return false;
        if (word.len == 0) return false;

        var current = self.root;
        for (word) |c| {
            const ci = charToIndex(c) orelse return false;

            if (self.nodes[current].children[ci] == NIL) {
                const new_node = self.allocNode() orelse return false;
                self.nodes[current].children[ci] = new_node;
            }
            current = self.nodes[current].children[ci];
            self.nodes[current].prefix_count += 1;
        }

        if (!self.nodes[current].is_end) {
            self.word_count += 1;
        }
        self.nodes[current].is_end = true;
        self.nodes[current].value = value;
        return true;
    }

    // ---- 検索 ----

    /// 単語を検索して値を返す
    pub fn search(self: *const Trie, word: []const u8) ?u32 {
        const idx = self.findEndNode(word) orelse return null;
        if (!self.nodes[idx].is_end) return null;
        return self.nodes[idx].value;
    }

    /// 指定した接頭辞で始まる単語が存在するか
    pub fn startsWith(self: *const Trie, prefix: []const u8) bool {
        return self.findEndNode(prefix) != null;
    }

    /// 文字列のパスをたどり、最終ノードを返す
    fn findEndNode(self: *const Trie, word: []const u8) ?u16 {
        if (self.root == NIL) return null;
        var current = self.root;

        for (word) |c| {
            const ci = charToIndex(c) orelse return null;
            if (self.nodes[current].children[ci] == NIL) return null;
            current = self.nodes[current].children[ci];
        }
        return current;
    }

    // ---- 削除 ----

    /// 単語を削除。成功すれば true
    pub fn remove(self: *Trie, word: []const u8) bool {
        if (self.root == NIL) return false;
        if (word.len == 0) return false;

        // まず単語が存在するか確認
        const end_node = self.findEndNode(word) orelse return false;
        if (!self.nodes[end_node].is_end) return false;

        // パスを記録
        var path: [MAX_WORD_LEN + 1]u16 = undefined;
        var path_len: usize = 0;

        var current = self.root;
        path[path_len] = current;
        path_len += 1;

        for (word) |c| {
            const ci = charToIndex(c) orelse return false;
            current = self.nodes[current].children[ci];
            path[path_len] = current;
            path_len += 1;
        }

        // 終端マークを削除
        self.nodes[current].is_end = false;
        self.word_count -= 1;

        // prefix_count を減らし、不要ノードを削除
        var i = path_len;
        while (i > 1) {
            i -= 1;
            self.nodes[path[i]].prefix_count -= 1;

            // prefix_count が 0 で終端でもないノードは削除可能
            if (self.nodes[path[i]].prefix_count == 0 and !self.nodes[path[i]].is_end) {
                // 親から切り離す
                const ci = charToIndex(word[i - 1]) orelse break;
                self.nodes[path[i - 1]].children[ci] = NIL;
                self.freeNode(path[i]);
            }
        }

        return true;
    }

    // ---- オートコンプリート ----

    /// 接頭辞に一致する全単語を収集
    pub fn autoComplete(self: *const Trie, prefix: []const u8, results: []AutoCompleteResult, max_results: usize) usize {
        const start = self.findEndNode(prefix) orelse return 0;

        var ctx = CollectContext{
            .results = results,
            .max = if (max_results < results.len) max_results else results.len,
            .count = 0,
            .buf = undefined,
            .buf_len = 0,
        };

        // 接頭辞をバッファにコピー
        for (prefix, 0..) |c, i| {
            if (i >= MAX_WORD_LEN) break;
            ctx.buf[i] = c;
            ctx.buf_len = i + 1;
        }

        self.collectWords(start, &ctx);
        return ctx.count;
    }

    pub const AutoCompleteResult = struct {
        word: [MAX_WORD_LEN]u8 = undefined,
        word_len: usize = 0,
        value: u32 = 0,
    };

    const CollectContext = struct {
        results: []AutoCompleteResult,
        max: usize,
        count: usize,
        buf: [MAX_WORD_LEN]u8,
        buf_len: usize,
    };

    fn collectWords(self: *const Trie, idx: u16, ctx: *CollectContext) void {
        if (idx == NIL) return;
        if (ctx.count >= ctx.max) return;

        if (self.nodes[idx].is_end) {
            if (ctx.count < ctx.max) {
                var result = &ctx.results[ctx.count];
                for (0..ctx.buf_len) |i| {
                    result.word[i] = ctx.buf[i];
                }
                result.word_len = ctx.buf_len;
                result.value = self.nodes[idx].value;
                ctx.count += 1;
            }
        }

        for (0..ALPHABET_SIZE) |ci| {
            if (self.nodes[idx].children[ci] != NIL) {
                if (ctx.buf_len < MAX_WORD_LEN) {
                    ctx.buf[ctx.buf_len] = indexToChar(@truncate(ci));
                    ctx.buf_len += 1;
                    self.collectWords(self.nodes[idx].children[ci], ctx);
                    ctx.buf_len -= 1;
                }
            }
        }
    }

    // ---- 最長接頭辞 ----

    /// テキストの最長一致接頭辞の長さを返す
    pub fn longestPrefix(self: *const Trie, text: []const u8) usize {
        if (self.root == NIL) return 0;

        var current = self.root;
        var last_match: usize = 0;

        for (text, 0..) |c, i| {
            const ci = charToIndex(c) orelse break;
            if (self.nodes[current].children[ci] == NIL) break;
            current = self.nodes[current].children[ci];
            if (self.nodes[current].is_end) {
                last_match = i + 1;
            }
        }
        return last_match;
    }

    // ---- ユーティリティ ----

    /// 格納されている単語数
    pub fn countWords(self: *const Trie) usize {
        return self.word_count;
    }

    /// 全単語を表示
    pub fn printAll(self: *const Trie) void {
        vga.setColor(.yellow, .black);
        vga.write("Trie (");
        fmt.printDec(self.word_count);
        vga.write(" words):\n");
        vga.setColor(.light_grey, .black);

        if (self.root == NIL) {
            vga.write("  (empty)\n");
            return;
        }

        var buf: [MAX_WORD_LEN]u8 = undefined;
        self.printAllHelper(self.root, &buf, 0);
    }

    fn printAllHelper(self: *const Trie, idx: u16, buf: *[MAX_WORD_LEN]u8, depth: usize) void {
        if (idx == NIL) return;

        if (self.nodes[idx].is_end) {
            vga.write("  ");
            for (0..depth) |i| {
                vga.putChar(buf[i]);
            }
            vga.write(" -> ");
            fmt.printDec(self.nodes[idx].value);
            vga.putChar('\n');
        }

        for (0..ALPHABET_SIZE) |ci| {
            if (self.nodes[idx].children[ci] != NIL) {
                if (depth < MAX_WORD_LEN) {
                    buf[depth] = indexToChar(@truncate(ci));
                    self.printAllHelper(self.nodes[idx].children[ci], buf, depth + 1);
                }
            }
        }
    }
};

// ---- モジュールレベル関数 ----

var global_trie: Trie = .{};
var global_initialized: bool = false;

pub fn getTrie() *Trie {
    if (!global_initialized) {
        global_trie.init();
        global_initialized = true;
    }
    return &global_trie;
}

/// デモ: Trie に単語を挿入して検索
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Trie Demo ===\n");
    vga.setColor(.light_grey, .black);

    var trie: Trie = .{};
    trie.init();

    // 単語を挿入
    const words = [_][]const u8{ "hello", "help", "heap", "heavy", "hero", "her", "he" };
    const values = [_]u32{ 1, 2, 3, 4, 5, 6, 7 };

    for (words, values) |w, v| {
        if (trie.insert(w, v)) {
            vga.write("  insert('");
            vga.write(w);
            vga.write("', ");
            fmt.printDec(v);
            vga.write(") OK\n");
        }
    }

    trie.printAll();

    // 検索
    vga.write("\nsearch('hello') = ");
    if (trie.search("hello")) |v| fmt.printDec(v) else vga.write("not found");
    vga.putChar('\n');

    vga.write("search('world') = ");
    if (trie.search("world")) |v| fmt.printDec(v) else vga.write("not found");
    vga.putChar('\n');

    // 接頭辞チェック
    vga.write("startsWith('hel') = ");
    if (trie.startsWith("hel")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    vga.write("startsWith('xyz') = ");
    if (trie.startsWith("xyz")) vga.write("true") else vga.write("false");
    vga.putChar('\n');

    // オートコンプリート
    var results: [8]Trie.AutoCompleteResult = undefined;
    const ac_count = trie.autoComplete("he", &results, 8);
    vga.write("\nautoComplete('he'): ");
    fmt.printDec(ac_count);
    vga.write(" results\n");
    for (0..ac_count) |i| {
        vga.write("  '");
        for (0..results[i].word_len) |j| {
            vga.putChar(results[i].word[j]);
        }
        vga.write("' = ");
        fmt.printDec(results[i].value);
        vga.putChar('\n');
    }

    // 最長接頭辞
    vga.write("longestPrefix('helping') = ");
    const lp = trie.longestPrefix("helping");
    fmt.printDec(lp);
    vga.putChar('\n');

    // 削除
    vga.write("\nRemove 'help': ");
    if (trie.remove("help")) vga.write("OK\n") else vga.write("FAIL\n");
    vga.write("Word count: ");
    fmt.printDec(trie.countWords());
    vga.putChar('\n');
}

pub fn printInfo() void {
    const trie = getTrie();
    trie.printAll();
}
