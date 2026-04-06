// Red-Black Tree — 自己平衡二分探索木
// 固定サイズノードプール (64 ノード), ヒープ不要
// 性質: 1) ノードは赤か黒  2) ルートは黒  3) 赤の子は黒
//       4) 全パスの黒ノード数は等しい  5) nil ノードは黒

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const MAX_NODES = 64;
pub const NIL: u8 = 0xFF; // null ポインタ代わり

// ---- 色 ----

pub const Color = enum(u1) {
    red = 0,
    black = 1,
};

// ---- ノード ----

pub const Node = struct {
    key: u32 = 0,
    value: u32 = 0,
    color: Color = .black,
    left: u8 = NIL,
    right: u8 = NIL,
    parent: u8 = NIL,
    used: bool = false,
};

// ---- Red-Black Tree 本体 ----

pub const RBTree = struct {
    nodes: [MAX_NODES]Node = [_]Node{.{}} ** MAX_NODES,
    root: u8 = NIL,
    node_count: usize = 0,

    // ---- ノードプール管理 ----

    /// 空きノードを確保
    fn allocNode(self: *RBTree) ?u8 {
        for (0..MAX_NODES) |i| {
            if (!self.nodes[i].used) {
                self.nodes[i] = .{
                    .key = 0,
                    .value = 0,
                    .color = .red,
                    .left = NIL,
                    .right = NIL,
                    .parent = NIL,
                    .used = true,
                };
                return @truncate(i);
            }
        }
        return null;
    }

    /// ノードを解放
    fn freeNode(self: *RBTree, idx: u8) void {
        if (idx == NIL) return;
        self.nodes[idx].used = false;
        self.nodes[idx].left = NIL;
        self.nodes[idx].right = NIL;
        self.nodes[idx].parent = NIL;
    }

    // ---- ヘルパー ----

    fn getColor(self: *const RBTree, idx: u8) Color {
        if (idx == NIL) return .black;
        return self.nodes[idx].color;
    }

    fn setColor(self: *RBTree, idx: u8, c: Color) void {
        if (idx != NIL) {
            self.nodes[idx].color = c;
        }
    }

    fn parentOf(self: *const RBTree, idx: u8) u8 {
        if (idx == NIL) return NIL;
        return self.nodes[idx].parent;
    }

    fn grandparentOf(self: *const RBTree, idx: u8) u8 {
        const p = self.parentOf(idx);
        return self.parentOf(p);
    }

    fn siblingOf(self: *const RBTree, idx: u8) u8 {
        const p = self.parentOf(idx);
        if (p == NIL) return NIL;
        if (self.nodes[p].left == idx) return self.nodes[p].right;
        return self.nodes[p].left;
    }

    fn uncleOf(self: *const RBTree, idx: u8) u8 {
        const p = self.parentOf(idx);
        return self.siblingOf(p);
    }

    fn isLeftChild(self: *const RBTree, idx: u8) bool {
        const p = self.parentOf(idx);
        if (p == NIL) return false;
        return self.nodes[p].left == idx;
    }

    // ---- 回転 ----

    /// 左回転: idx を左に回転させる
    fn rotateLeft(self: *RBTree, idx: u8) void {
        if (idx == NIL) return;
        const r = self.nodes[idx].right;
        if (r == NIL) return;

        // idx の右の子を r の左の子にする
        self.nodes[idx].right = self.nodes[r].left;
        if (self.nodes[r].left != NIL) {
            self.nodes[self.nodes[r].left].parent = idx;
        }

        // r の親を idx の親にする
        self.nodes[r].parent = self.nodes[idx].parent;
        if (self.nodes[idx].parent == NIL) {
            self.root = r;
        } else if (self.nodes[self.nodes[idx].parent].left == idx) {
            self.nodes[self.nodes[idx].parent].left = r;
        } else {
            self.nodes[self.nodes[idx].parent].right = r;
        }

        // idx を r の左の子にする
        self.nodes[r].left = idx;
        self.nodes[idx].parent = r;
    }

    /// 右回転: idx を右に回転させる
    fn rotateRight(self: *RBTree, idx: u8) void {
        if (idx == NIL) return;
        const l = self.nodes[idx].left;
        if (l == NIL) return;

        self.nodes[idx].left = self.nodes[l].right;
        if (self.nodes[l].right != NIL) {
            self.nodes[self.nodes[l].right].parent = idx;
        }

        self.nodes[l].parent = self.nodes[idx].parent;
        if (self.nodes[idx].parent == NIL) {
            self.root = l;
        } else if (self.nodes[self.nodes[idx].parent].right == idx) {
            self.nodes[self.nodes[idx].parent].right = l;
        } else {
            self.nodes[self.nodes[idx].parent].left = l;
        }

        self.nodes[l].right = idx;
        self.nodes[idx].parent = l;
    }

    // ---- 挿入 ----

    /// キーと値を挿入。成功すれば true
    pub fn insert(self: *RBTree, key: u32, value: u32) bool {
        // 同一キーが存在するか確認
        if (self.findNode(key)) |existing| {
            self.nodes[existing].value = value; // 更新
            return true;
        }

        const new_idx = self.allocNode() orelse return false;
        self.nodes[new_idx].key = key;
        self.nodes[new_idx].value = value;
        self.nodes[new_idx].color = .red;

        // BST 挿入
        if (self.root == NIL) {
            self.root = new_idx;
            self.nodes[new_idx].color = .black;
            self.node_count += 1;
            return true;
        }

        var current: u8 = self.root;
        var parent_idx: u8 = NIL;

        while (current != NIL) {
            parent_idx = current;
            if (key < self.nodes[current].key) {
                current = self.nodes[current].left;
            } else {
                current = self.nodes[current].right;
            }
        }

        self.nodes[new_idx].parent = parent_idx;
        if (key < self.nodes[parent_idx].key) {
            self.nodes[parent_idx].left = new_idx;
        } else {
            self.nodes[parent_idx].right = new_idx;
        }

        self.node_count += 1;
        self.insertFixup(new_idx);
        return true;
    }

    /// 挿入後の修正 (赤-黒性質の回復)
    fn insertFixup(self: *RBTree, idx: u8) void {
        var z = idx;

        while (z != self.root and self.getColor(self.parentOf(z)) == .red) {
            const p = self.parentOf(z);
            const g = self.grandparentOf(z);
            if (g == NIL) break;

            if (self.isLeftChild(p)) {
                // 親が祖父の左の子
                const uncle = self.nodes[g].right;

                if (self.getColor(uncle) == .red) {
                    // Case 1: 叔父が赤 → 再色
                    self.setColor(p, .black);
                    self.setColor(uncle, .black);
                    self.setColor(g, .red);
                    z = g;
                } else {
                    if (!self.isLeftChild(z)) {
                        // Case 2: z が右の子 → 左回転で Case 3 へ
                        z = p;
                        self.rotateLeft(z);
                    }
                    // Case 3: z が左の子 → 右回転
                    const new_p = self.parentOf(z);
                    const new_g = self.grandparentOf(z);
                    self.setColor(new_p, .black);
                    self.setColor(new_g, .red);
                    if (new_g != NIL) {
                        self.rotateRight(new_g);
                    }
                }
            } else {
                // 親が祖父の右の子 (左右対称)
                const uncle = self.nodes[g].left;

                if (self.getColor(uncle) == .red) {
                    self.setColor(p, .black);
                    self.setColor(uncle, .black);
                    self.setColor(g, .red);
                    z = g;
                } else {
                    if (self.isLeftChild(z)) {
                        z = p;
                        self.rotateRight(z);
                    }
                    const new_p = self.parentOf(z);
                    const new_g = self.grandparentOf(z);
                    self.setColor(new_p, .black);
                    self.setColor(new_g, .red);
                    if (new_g != NIL) {
                        self.rotateLeft(new_g);
                    }
                }
            }
        }
        self.setColor(self.root, .black);
    }

    // ---- 検索 ----

    /// ノードインデックスを返す (内部用)
    fn findNode(self: *const RBTree, key: u32) ?u8 {
        var current = self.root;
        while (current != NIL) {
            if (key == self.nodes[current].key) return current;
            if (key < self.nodes[current].key) {
                current = self.nodes[current].left;
            } else {
                current = self.nodes[current].right;
            }
        }
        return null;
    }

    /// キーで値を検索
    pub fn find(self: *const RBTree, key: u32) ?u32 {
        const idx = self.findNode(key) orelse return null;
        return self.nodes[idx].value;
    }

    // ---- 削除 ----

    /// 部分木の最小ノードインデックスを返す
    fn treeMinimum(self: *const RBTree, idx: u8) u8 {
        var current = idx;
        while (current != NIL and self.nodes[current].left != NIL) {
            current = self.nodes[current].left;
        }
        return current;
    }

    /// 部分木の最大ノードインデックスを返す
    fn treeMaximum(self: *const RBTree, idx: u8) u8 {
        var current = idx;
        while (current != NIL and self.nodes[current].right != NIL) {
            current = self.nodes[current].right;
        }
        return current;
    }

    /// ノード u を v で置換 (親のリンクのみ更新)
    fn transplant(self: *RBTree, u: u8, v: u8) void {
        if (self.nodes[u].parent == NIL) {
            self.root = v;
        } else if (self.nodes[self.nodes[u].parent].left == u) {
            self.nodes[self.nodes[u].parent].left = v;
        } else {
            self.nodes[self.nodes[u].parent].right = v;
        }
        if (v != NIL) {
            self.nodes[v].parent = self.nodes[u].parent;
        }
    }

    /// キーでノードを削除
    pub fn remove(self: *RBTree, key: u32) bool {
        const z = self.findNode(key) orelse return false;

        var y = z;
        var y_original_color = self.nodes[y].color;
        var x: u8 = NIL;
        var x_parent: u8 = NIL;

        if (self.nodes[z].left == NIL) {
            x = self.nodes[z].right;
            x_parent = self.nodes[z].parent;
            self.transplant(z, self.nodes[z].right);
        } else if (self.nodes[z].right == NIL) {
            x = self.nodes[z].left;
            x_parent = self.nodes[z].parent;
            self.transplant(z, self.nodes[z].left);
        } else {
            // 後続ノード (右部分木の最小)
            y = self.treeMinimum(self.nodes[z].right);
            y_original_color = self.nodes[y].color;
            x = self.nodes[y].right;

            if (self.nodes[y].parent == z) {
                x_parent = y;
                if (x != NIL) {
                    self.nodes[x].parent = y;
                }
            } else {
                x_parent = self.nodes[y].parent;
                self.transplant(y, self.nodes[y].right);
                self.nodes[y].right = self.nodes[z].right;
                if (self.nodes[y].right != NIL) {
                    self.nodes[self.nodes[y].right].parent = y;
                }
            }

            self.transplant(z, y);
            self.nodes[y].left = self.nodes[z].left;
            if (self.nodes[y].left != NIL) {
                self.nodes[self.nodes[y].left].parent = y;
            }
            self.nodes[y].color = self.nodes[z].color;
        }

        self.freeNode(z);
        self.node_count -= 1;

        if (y_original_color == .black) {
            self.deleteFixup(x, x_parent);
        }

        return true;
    }

    /// 削除後の修正
    fn deleteFixup(self: *RBTree, x_in: u8, x_parent_in: u8) void {
        var x = x_in;
        var x_parent = x_parent_in;

        while (x != self.root and self.getColor(x) == .black) {
            if (x_parent == NIL) break;

            if (x == self.nodes[x_parent].left) {
                var w = self.nodes[x_parent].right;

                // Case 1: 兄弟が赤
                if (self.getColor(w) == .red) {
                    self.setColor(w, .black);
                    self.setColor(x_parent, .red);
                    self.rotateLeft(x_parent);
                    w = self.nodes[x_parent].right;
                }

                if (w == NIL) break;

                // Case 2: 兄弟の両方の子が黒
                if (self.getColor(self.nodes[w].left) == .black and
                    self.getColor(self.nodes[w].right) == .black)
                {
                    self.setColor(w, .red);
                    x = x_parent;
                    x_parent = self.parentOf(x);
                } else {
                    // Case 3: 兄弟の右の子が黒
                    if (self.getColor(self.nodes[w].right) == .black) {
                        self.setColor(self.nodes[w].left, .black);
                        self.setColor(w, .red);
                        self.rotateRight(w);
                        w = self.nodes[x_parent].right;
                    }
                    // Case 4: 兄弟の右の子が赤
                    if (w != NIL) {
                        self.setColor(w, self.getColor(x_parent));
                        self.setColor(x_parent, .black);
                        self.setColor(self.nodes[w].right, .black);
                    }
                    self.rotateLeft(x_parent);
                    x = self.root;
                    break;
                }
            } else {
                // 左右対称
                var w = self.nodes[x_parent].left;

                if (self.getColor(w) == .red) {
                    self.setColor(w, .black);
                    self.setColor(x_parent, .red);
                    self.rotateRight(x_parent);
                    w = self.nodes[x_parent].left;
                }

                if (w == NIL) break;

                if (self.getColor(self.nodes[w].right) == .black and
                    self.getColor(self.nodes[w].left) == .black)
                {
                    self.setColor(w, .red);
                    x = x_parent;
                    x_parent = self.parentOf(x);
                } else {
                    if (self.getColor(self.nodes[w].left) == .black) {
                        self.setColor(self.nodes[w].right, .black);
                        self.setColor(w, .red);
                        self.rotateLeft(w);
                        w = self.nodes[x_parent].left;
                    }
                    if (w != NIL) {
                        self.setColor(w, self.getColor(x_parent));
                        self.setColor(x_parent, .black);
                        self.setColor(self.nodes[w].left, .black);
                    }
                    self.rotateRight(x_parent);
                    x = self.root;
                    break;
                }
            }
        }
        self.setColor(x, .black);
    }

    // ---- 走査 ----

    /// 中順走査 (コールバック)
    pub fn inorderTraversal(self: *const RBTree, callback: *const fn (u32, u32) void) void {
        self.inorderHelper(self.root, callback);
    }

    fn inorderHelper(self: *const RBTree, idx: u8, callback: *const fn (u32, u32) void) void {
        if (idx == NIL) return;
        self.inorderHelper(self.nodes[idx].left, callback);
        callback(self.nodes[idx].key, self.nodes[idx].value);
        self.inorderHelper(self.nodes[idx].right, callback);
    }

    // ---- 最小値 / 最大値 ----

    /// 最小キーの値
    pub fn min(self: *const RBTree) ?u32 {
        if (self.root == NIL) return null;
        const idx = self.treeMinimum(self.root);
        return self.nodes[idx].value;
    }

    /// 最大キーの値
    pub fn max(self: *const RBTree) ?u32 {
        if (self.root == NIL) return null;
        const idx = self.treeMaximum(self.root);
        return self.nodes[idx].value;
    }

    /// 最小キー
    pub fn minKey(self: *const RBTree) ?u32 {
        if (self.root == NIL) return null;
        const idx = self.treeMinimum(self.root);
        return self.nodes[idx].key;
    }

    /// 最大キー
    pub fn maxKey(self: *const RBTree) ?u32 {
        if (self.root == NIL) return null;
        const idx = self.treeMaximum(self.root);
        return self.nodes[idx].key;
    }

    // ---- ユーティリティ ----

    /// ノード数
    pub fn count(self: *const RBTree) usize {
        return self.node_count;
    }

    /// ツリーをクリア
    pub fn clear(self: *RBTree) void {
        for (&self.nodes) |*n| {
            n.used = false;
            n.left = NIL;
            n.right = NIL;
            n.parent = NIL;
        }
        self.root = NIL;
        self.node_count = 0;
    }

    // ---- 検証 ----

    /// 赤黒木の性質を検証
    pub fn verify(self: *const RBTree) bool {
        if (self.root == NIL) return true;

        // 性質 2: ルートは黒
        if (self.nodes[self.root].color != .black) return false;

        // 性質の再帰的検証
        const result = self.verifyHelper(self.root);
        return result.valid;
    }

    const VerifyResult = struct {
        valid: bool,
        black_height: u32,
    };

    fn verifyHelper(self: *const RBTree, idx: u8) VerifyResult {
        if (idx == NIL) return .{ .valid = true, .black_height = 1 };

        const node = &self.nodes[idx];

        // 性質 3: 赤ノードの子は両方とも黒
        if (node.color == .red) {
            if (self.getColor(node.left) == .red) return .{ .valid = false, .black_height = 0 };
            if (self.getColor(node.right) == .red) return .{ .valid = false, .black_height = 0 };
        }

        // BST 性質: 左の子 < 親 < 右の子
        if (node.left != NIL and self.nodes[node.left].key >= node.key) {
            return .{ .valid = false, .black_height = 0 };
        }
        if (node.right != NIL and self.nodes[node.right].key <= node.key) {
            return .{ .valid = false, .black_height = 0 };
        }

        const left_result = self.verifyHelper(node.left);
        if (!left_result.valid) return .{ .valid = false, .black_height = 0 };

        const right_result = self.verifyHelper(node.right);
        if (!right_result.valid) return .{ .valid = false, .black_height = 0 };

        // 性質 4: 全パスの黒ノード数は等しい
        if (left_result.black_height != right_result.black_height) {
            return .{ .valid = false, .black_height = 0 };
        }

        const bh = left_result.black_height + @as(u32, if (node.color == .black) 1 else 0);
        return .{ .valid = true, .black_height = bh };
    }

    // ---- 表示 ----

    /// ツリーの視覚的表示
    pub fn printTree(self: *const RBTree) void {
        vga.setColor(.yellow, .black);
        vga.write("Red-Black Tree (");
        fmt.printDec(self.node_count);
        vga.write(" nodes):\n");
        vga.setColor(.light_grey, .black);

        if (self.root == NIL) {
            vga.write("  (empty)\n");
            return;
        }
        self.printHelper(self.root, 0, true);

        // 検証結果
        if (self.verify()) {
            vga.setColor(.light_green, .black);
            vga.write("  [VALID RB-Tree]\n");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("  [INVALID RB-Tree!]\n");
        }
        vga.setColor(.light_grey, .black);
    }

    fn printHelper(self: *const RBTree, idx: u8, depth: u32, is_right: bool) void {
        if (idx == NIL) return;

        // 右の子を先に表示 (上に表示されるように)
        self.printHelper(self.nodes[idx].right, depth + 1, true);

        // インデント
        var i: u32 = 0;
        while (i < depth) : (i += 1) {
            vga.write("    ");
        }

        // 接続線
        if (depth > 0) {
            if (is_right) {
                vga.write(" /--");
            } else {
                vga.write(" \\--");
            }
        }

        // ノード表示
        if (self.nodes[idx].color == .red) {
            vga.setColor(.light_red, .black);
        } else {
            vga.setColor(.white, .black);
        }
        vga.putChar('[');
        fmt.printDec(self.nodes[idx].key);
        vga.putChar(':');
        fmt.printDec(self.nodes[idx].value);
        vga.putChar(']');
        if (self.nodes[idx].color == .red) {
            vga.putChar('R');
        } else {
            vga.putChar('B');
        }
        vga.putChar('\n');
        vga.setColor(.light_grey, .black);

        // 左の子
        self.printHelper(self.nodes[idx].left, depth + 1, false);
    }

    /// ツリー高さを計算
    pub fn height(self: *const RBTree) u32 {
        return self.heightHelper(self.root);
    }

    fn heightHelper(self: *const RBTree, idx: u8) u32 {
        if (idx == NIL) return 0;
        const lh = self.heightHelper(self.nodes[idx].left);
        const rh = self.heightHelper(self.nodes[idx].right);
        return 1 + if (lh > rh) lh else rh;
    }
};

// ---- モジュールレベル関数 ----

/// グローバルインスタンス
var global_tree: RBTree = .{};

pub fn getTree() *RBTree {
    return &global_tree;
}

/// デモ: RB ツリーに値を挿入して検証
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Red-Black Tree Demo ===\n");
    vga.setColor(.light_grey, .black);

    var tree: RBTree = .{};

    // 連続値を挿入 (バランシングを発動)
    const keys = [_]u32{ 10, 20, 30, 15, 25, 5, 1, 8, 12, 18 };
    for (keys) |k| {
        const ok = tree.insert(k, k * 10);
        if (ok) {
            vga.write("  insert(");
            fmt.printDec(k);
            vga.write(") -> OK\n");
        }
    }

    tree.printTree();

    // 検索
    vga.write("\nfind(15) = ");
    if (tree.find(15)) |v| {
        fmt.printDec(v);
    } else {
        vga.write("not found");
    }
    vga.putChar('\n');

    vga.write("find(99) = ");
    if (tree.find(99)) |v| {
        fmt.printDec(v);
    } else {
        vga.write("not found");
    }
    vga.putChar('\n');

    // 最小・最大
    vga.write("min key = ");
    if (tree.minKey()) |k| fmt.printDec(k) else vga.write("none");
    vga.write(", max key = ");
    if (tree.maxKey()) |k| fmt.printDec(k) else vga.write("none");
    vga.putChar('\n');

    // 削除
    vga.write("\nRemove 20:\n");
    _ = tree.remove(20);
    tree.printTree();

    vga.write("Remove 10:\n");
    _ = tree.remove(10);
    tree.printTree();

    vga.write("Count: ");
    fmt.printDec(tree.count());
    vga.write(", Height: ");
    fmt.printDec(tree.height());
    vga.putChar('\n');

    // 検証
    vga.write("Valid: ");
    if (tree.verify()) vga.write("yes\n") else vga.write("NO!\n");
}

/// ツリー情報を表示
pub fn printInfo() void {
    global_tree.printTree();
}
