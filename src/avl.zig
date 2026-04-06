// AVL Tree — 自己平衡二分探索木 (高さバランス)
// 固定サイズノードプール (64 ノード), ヒープ不要
// 全ノードのバランスファクター (左高さ - 右高さ) は -1, 0, +1 のいずれか

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const MAX_NODES = 64;
pub const NIL: u8 = 0xFF;

// ---- ノード ----

pub const Node = struct {
    key: u32 = 0,
    value: u32 = 0,
    left: u8 = NIL,
    right: u8 = NIL,
    parent: u8 = NIL,
    node_height: u32 = 1, // ノード高さ (葉 = 1)
    used: bool = false,
};

// ---- AVL Tree 本体 ----

pub const AVLTree = struct {
    nodes: [MAX_NODES]Node = [_]Node{.{}} ** MAX_NODES,
    root: u8 = NIL,
    node_count: usize = 0,

    // ---- ノードプール管理 ----

    fn allocNode(self: *AVLTree) ?u8 {
        for (0..MAX_NODES) |i| {
            if (!self.nodes[i].used) {
                self.nodes[i] = .{
                    .key = 0,
                    .value = 0,
                    .left = NIL,
                    .right = NIL,
                    .parent = NIL,
                    .node_height = 1,
                    .used = true,
                };
                return @truncate(i);
            }
        }
        return null;
    }

    fn freeNode(self: *AVLTree, idx: u8) void {
        if (idx == NIL) return;
        self.nodes[idx].used = false;
        self.nodes[idx].left = NIL;
        self.nodes[idx].right = NIL;
        self.nodes[idx].parent = NIL;
    }

    // ---- ヘルパー ----

    fn getHeight(self: *const AVLTree, idx: u8) u32 {
        if (idx == NIL) return 0;
        return self.nodes[idx].node_height;
    }

    fn updateHeight(self: *AVLTree, idx: u8) void {
        if (idx == NIL) return;
        const lh = self.getHeight(self.nodes[idx].left);
        const rh = self.getHeight(self.nodes[idx].right);
        self.nodes[idx].node_height = 1 + if (lh > rh) lh else rh;
    }

    /// バランスファクター: 左高さ - 右高さ
    fn balanceFactor(self: *const AVLTree, idx: u8) i32 {
        if (idx == NIL) return 0;
        const lh: i32 = @intCast(self.getHeight(self.nodes[idx].left));
        const rh: i32 = @intCast(self.getHeight(self.nodes[idx].right));
        return lh - rh;
    }

    fn setParent(self: *AVLTree, child: u8, parent: u8) void {
        if (child != NIL) {
            self.nodes[child].parent = parent;
        }
    }

    fn replaceChild(self: *AVLTree, parent: u8, old_child: u8, new_child: u8) void {
        if (parent == NIL) {
            self.root = new_child;
        } else if (self.nodes[parent].left == old_child) {
            self.nodes[parent].left = new_child;
        } else {
            self.nodes[parent].right = new_child;
        }
        self.setParent(new_child, parent);
    }

    // ---- 回転 ----

    /// 右回転 (LL ケース)
    fn rotateRight(self: *AVLTree, y: u8) u8 {
        if (y == NIL) return NIL;
        const x = self.nodes[y].left;
        if (x == NIL) return y;

        const p = self.nodes[y].parent;
        const t2 = self.nodes[x].right;

        // x の右の子を y にする
        self.nodes[x].right = y;
        self.nodes[y].parent = x;

        // t2 を y の左の子にする
        self.nodes[y].left = t2;
        self.setParent(t2, y);

        // 親の更新
        self.replaceChild(p, y, x);

        self.updateHeight(y);
        self.updateHeight(x);
        return x;
    }

    /// 左回転 (RR ケース)
    fn rotateLeft(self: *AVLTree, x: u8) u8 {
        if (x == NIL) return NIL;
        const y = self.nodes[x].right;
        if (y == NIL) return x;

        const p = self.nodes[x].parent;
        const t2 = self.nodes[y].left;

        self.nodes[y].left = x;
        self.nodes[x].parent = y;

        self.nodes[x].right = t2;
        self.setParent(t2, x);

        self.replaceChild(p, x, y);

        self.updateHeight(x);
        self.updateHeight(y);
        return y;
    }

    /// ノードのバランスを回復
    fn rebalance(self: *AVLTree, idx: u8) u8 {
        if (idx == NIL) return NIL;

        self.updateHeight(idx);
        const bf = self.balanceFactor(idx);

        // 左に偏りすぎ (LL or LR)
        if (bf > 1) {
            const left = self.nodes[idx].left;
            if (left != NIL and self.balanceFactor(left) < 0) {
                // LR ケース: 左の子を左回転してから右回転
                self.nodes[idx].left = self.rotateLeft(left);
                self.setParent(self.nodes[idx].left, idx);
            }
            return self.rotateRight(idx);
        }

        // 右に偏りすぎ (RR or RL)
        if (bf < -1) {
            const right = self.nodes[idx].right;
            if (right != NIL and self.balanceFactor(right) > 0) {
                // RL ケース: 右の子を右回転してから左回転
                self.nodes[idx].right = self.rotateRight(right);
                self.setParent(self.nodes[idx].right, idx);
            }
            return self.rotateLeft(idx);
        }

        return idx;
    }

    // ---- 挿入 ----

    /// キーと値を挿入
    pub fn insert(self: *AVLTree, key: u32, value: u32) bool {
        if (self.findNode(key)) |existing| {
            self.nodes[existing].value = value;
            return true;
        }

        const new_idx = self.allocNode() orelse return false;
        self.nodes[new_idx].key = key;
        self.nodes[new_idx].value = value;

        if (self.root == NIL) {
            self.root = new_idx;
            self.node_count += 1;
            return true;
        }

        // BST 挿入
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

        // 挿入後、親を遡ってバランス回復
        self.fixupAncestors(parent_idx);
        return true;
    }

    /// 祖先ノードのバランスを回復
    fn fixupAncestors(self: *AVLTree, start: u8) void {
        var idx = start;
        while (idx != NIL) {
            const parent = self.nodes[idx].parent;
            const new_idx = self.rebalance(idx);
            _ = new_idx;
            idx = parent;
        }
    }

    // ---- 検索 ----

    fn findNode(self: *const AVLTree, key: u32) ?u8 {
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
    pub fn find(self: *const AVLTree, key: u32) ?u32 {
        const idx = self.findNode(key) orelse return null;
        return self.nodes[idx].value;
    }

    // ---- 削除 ----

    fn treeMinimum(self: *const AVLTree, idx: u8) u8 {
        var current = idx;
        while (current != NIL and self.nodes[current].left != NIL) {
            current = self.nodes[current].left;
        }
        return current;
    }

    fn treeMaximum(self: *const AVLTree, idx: u8) u8 {
        var current = idx;
        while (current != NIL and self.nodes[current].right != NIL) {
            current = self.nodes[current].right;
        }
        return current;
    }

    /// キーでノードを削除
    pub fn remove(self: *AVLTree, key: u32) bool {
        const z = self.findNode(key) orelse return false;

        var fix_start: u8 = NIL;

        if (self.nodes[z].left == NIL or self.nodes[z].right == NIL) {
            // 子が 0 または 1 個
            const child = if (self.nodes[z].left != NIL) self.nodes[z].left else self.nodes[z].right;
            fix_start = self.nodes[z].parent;

            self.replaceChild(self.nodes[z].parent, z, child);
            self.freeNode(z);
        } else {
            // 子が 2 個: 後続ノードの値をコピーして後続を削除
            const succ = self.treeMinimum(self.nodes[z].right);
            self.nodes[z].key = self.nodes[succ].key;
            self.nodes[z].value = self.nodes[succ].value;

            const succ_child = self.nodes[succ].right;
            fix_start = self.nodes[succ].parent;
            if (fix_start == z) fix_start = z; // z 自体が succ の親

            self.replaceChild(self.nodes[succ].parent, succ, succ_child);
            self.freeNode(succ);
        }

        self.node_count -= 1;
        self.fixupAncestors(fix_start);
        return true;
    }

    // ---- 走査 ----

    /// 中順走査 (昇順)
    pub fn inorder(self: *const AVLTree, callback: *const fn (u32, u32) void) void {
        self.inorderHelper(self.root, callback);
    }

    fn inorderHelper(self: *const AVLTree, idx: u8, callback: *const fn (u32, u32) void) void {
        if (idx == NIL) return;
        self.inorderHelper(self.nodes[idx].left, callback);
        callback(self.nodes[idx].key, self.nodes[idx].value);
        self.inorderHelper(self.nodes[idx].right, callback);
    }

    /// 前順走査
    pub fn preorder(self: *const AVLTree, callback: *const fn (u32, u32) void) void {
        self.preorderHelper(self.root, callback);
    }

    fn preorderHelper(self: *const AVLTree, idx: u8, callback: *const fn (u32, u32) void) void {
        if (idx == NIL) return;
        callback(self.nodes[idx].key, self.nodes[idx].value);
        self.preorderHelper(self.nodes[idx].left, callback);
        self.preorderHelper(self.nodes[idx].right, callback);
    }

    /// 後順走査
    pub fn postorder(self: *const AVLTree, callback: *const fn (u32, u32) void) void {
        self.postorderHelper(self.root, callback);
    }

    fn postorderHelper(self: *const AVLTree, idx: u8, callback: *const fn (u32, u32) void) void {
        if (idx == NIL) return;
        self.postorderHelper(self.nodes[idx].left, callback);
        self.postorderHelper(self.nodes[idx].right, callback);
        callback(self.nodes[idx].key, self.nodes[idx].value);
    }

    // ---- クエリ ----

    /// ツリー全体の高さ
    pub fn height(self: *const AVLTree) u32 {
        return self.getHeight(self.root);
    }

    /// バランス検証
    pub fn isBalanced(self: *const AVLTree) bool {
        return self.isBalancedHelper(self.root);
    }

    fn isBalancedHelper(self: *const AVLTree, idx: u8) bool {
        if (idx == NIL) return true;
        const bf = self.balanceFactor(idx);
        if (bf < -1 or bf > 1) return false;
        return self.isBalancedHelper(self.nodes[idx].left) and
            self.isBalancedHelper(self.nodes[idx].right);
    }

    /// 後続 (次に大きいキー)
    pub fn successor(self: *const AVLTree, key: u32) ?u32 {
        var current = self.root;
        var succ: ?u32 = null;

        while (current != NIL) {
            if (self.nodes[current].key > key) {
                succ = self.nodes[current].key;
                current = self.nodes[current].left;
            } else {
                current = self.nodes[current].right;
            }
        }
        return succ;
    }

    /// 前任 (次に小さいキー)
    pub fn predecessor(self: *const AVLTree, key: u32) ?u32 {
        var current = self.root;
        var pred: ?u32 = null;

        while (current != NIL) {
            if (self.nodes[current].key < key) {
                pred = self.nodes[current].key;
                current = self.nodes[current].right;
            } else {
                current = self.nodes[current].left;
            }
        }
        return pred;
    }

    /// 範囲検索: [lo, hi] のキーを results に格納
    pub fn rangeSearch(self: *const AVLTree, lo: u32, hi: u32, results: []u32) usize {
        var count_val: usize = 0;
        self.rangeHelper(self.root, lo, hi, results, &count_val);
        return count_val;
    }

    fn rangeHelper(self: *const AVLTree, idx: u8, lo: u32, hi: u32, results: []u32, count_val: *usize) void {
        if (idx == NIL) return;
        if (count_val.* >= results.len) return;

        // 左部分木に lo 以上のキーがあるかもしれない
        if (self.nodes[idx].key > lo) {
            self.rangeHelper(self.nodes[idx].left, lo, hi, results, count_val);
        }

        // 現在のノードが範囲内か
        if (self.nodes[idx].key >= lo and self.nodes[idx].key <= hi) {
            if (count_val.* < results.len) {
                results[count_val.*] = self.nodes[idx].key;
                count_val.* += 1;
            }
        }

        // 右部分木に hi 以下のキーがあるかもしれない
        if (self.nodes[idx].key < hi) {
            self.rangeHelper(self.nodes[idx].right, lo, hi, results, count_val);
        }
    }

    // ---- 表示 ----

    /// ツリーの視覚的表示
    pub fn printTree(self: *const AVLTree) void {
        vga.setColor(.yellow, .black);
        vga.write("AVL Tree (");
        fmt.printDec(self.node_count);
        vga.write(" nodes, height=");
        fmt.printDec(self.height());
        vga.write("):\n");
        vga.setColor(.light_grey, .black);

        if (self.root == NIL) {
            vga.write("  (empty)\n");
            return;
        }
        self.printHelper(self.root, 0);

        if (self.isBalanced()) {
            vga.setColor(.light_green, .black);
            vga.write("  [BALANCED]\n");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("  [UNBALANCED!]\n");
        }
        vga.setColor(.light_grey, .black);
    }

    fn printHelper(self: *const AVLTree, idx: u8, depth: u32) void {
        if (idx == NIL) return;

        self.printHelper(self.nodes[idx].right, depth + 1);

        var i: u32 = 0;
        while (i < depth) : (i += 1) {
            vga.write("    ");
        }

        vga.putChar('[');
        fmt.printDec(self.nodes[idx].key);
        vga.putChar(':');
        fmt.printDec(self.nodes[idx].value);
        vga.write("] bf=");
        fmt.printDecSigned(self.balanceFactor(idx));
        vga.putChar('\n');

        self.printHelper(self.nodes[idx].left, depth + 1);
    }

    /// ノード数
    pub fn count(self: *const AVLTree) usize {
        return self.node_count;
    }

    /// クリア
    pub fn clear(self: *AVLTree) void {
        for (&self.nodes) |*n| {
            n.used = false;
            n.left = NIL;
            n.right = NIL;
            n.parent = NIL;
        }
        self.root = NIL;
        self.node_count = 0;
    }
};

// ---- モジュールレベル関数 ----

var global_tree: AVLTree = .{};

pub fn getTree() *AVLTree {
    return &global_tree;
}

/// デモ: AVL ツリーに値を挿入してバランスを確認
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== AVL Tree Demo ===\n");
    vga.setColor(.light_grey, .black);

    var tree: AVLTree = .{};

    // 昇順挿入 (最悪ケース — 平衡されるはず)
    const keys = [_]u32{ 10, 20, 30, 40, 50, 25, 35, 5, 15, 28 };
    for (keys) |k| {
        const ok = tree.insert(k, k * 100);
        if (ok) {
            vga.write("  insert(");
            fmt.printDec(k);
            vga.write(") height=");
            fmt.printDec(tree.height());
            vga.write(" balanced=");
            if (tree.isBalanced()) vga.write("yes") else vga.write("no");
            vga.putChar('\n');
        }
    }

    tree.printTree();

    // 検索
    vga.write("\nfind(30) = ");
    if (tree.find(30)) |v| fmt.printDec(v) else vga.write("not found");
    vga.putChar('\n');

    // 後続 / 前任
    vga.write("successor(25) = ");
    if (tree.successor(25)) |k| fmt.printDec(k) else vga.write("none");
    vga.putChar('\n');

    vga.write("predecessor(30) = ");
    if (tree.predecessor(30)) |k| fmt.printDec(k) else vga.write("none");
    vga.putChar('\n');

    // 範囲検索
    var range_buf: [16]u32 = undefined;
    const range_count = tree.rangeSearch(15, 35, &range_buf);
    vga.write("range[15..35] = ");
    for (0..range_count) |i| {
        if (i > 0) vga.write(", ");
        fmt.printDec(range_buf[i]);
    }
    vga.putChar('\n');

    // 削除
    vga.write("\nRemove 30:\n");
    _ = tree.remove(30);
    tree.printTree();

    vga.write("Count: ");
    fmt.printDec(tree.count());
    vga.write(", Height: ");
    fmt.printDec(tree.height());
    vga.putChar('\n');
}

pub fn printInfo() void {
    global_tree.printTree();
}
