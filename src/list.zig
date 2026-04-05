// Intrusive Doubly Linked List — 侵入型双方向リンクリスト
// プロセス管理、スケジューラキュー、メモリブロック管理等に汎用的に利用

const vga = @import("vga.zig");
const pmm = @import("pmm.zig");

/// リストノード (対象構造体に埋め込んで使う)
pub const Node = struct {
    next: ?*Node = null,
    prev: ?*Node = null,

    /// このノードが所属するリストから自身を切り離す
    /// (リスト側の len は更新されないので、通常は List.remove() を使う)
    pub fn unlink(self: *Node) void {
        if (self.prev) |p| p.next = self.next;
        if (self.next) |n| n.prev = self.prev;
        self.next = null;
        self.prev = null;
    }

    /// 次のノードを返す
    pub fn getNext(self: *const Node) ?*Node {
        return self.next;
    }

    /// 前のノードを返す
    pub fn getPrev(self: *const Node) ?*Node {
        return self.prev;
    }
};

/// 双方向リンクリスト
pub const List = struct {
    head: ?*Node = null,
    tail: ?*Node = null,
    len: usize = 0,

    /// 新しい空のリストを作成
    pub fn init() List {
        return .{
            .head = null,
            .tail = null,
            .len = 0,
        };
    }

    /// リストの末尾にノードを追加
    pub fn append(self: *List, node: *Node) void {
        node.next = null;
        node.prev = self.tail;
        if (self.tail) |t| {
            t.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.len += 1;
    }

    /// リストの先頭にノードを追加
    pub fn prepend(self: *List, node: *Node) void {
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| {
            h.prev = node;
        } else {
            self.tail = node;
        }
        self.head = node;
        self.len += 1;
    }

    /// ノードをリストから削除
    pub fn remove(self: *List, node: *Node) void {
        if (node.prev) |p| {
            p.next = node.next;
        } else {
            self.head = node.next;
        }
        if (node.next) |n| {
            n.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        node.next = null;
        node.prev = null;
        if (self.len > 0) self.len -= 1;
    }

    /// 先頭ノードを取得して削除 (pop front)
    pub fn popFront(self: *List) ?*Node {
        const node = self.head orelse return null;
        self.remove(node);
        return node;
    }

    /// 末尾ノードを取得して削除 (pop back)
    pub fn popBack(self: *List) ?*Node {
        const node = self.tail orelse return null;
        self.remove(node);
        return node;
    }

    /// 先頭ノードを返す (削除しない)
    pub fn first(self: *const List) ?*Node {
        return self.head;
    }

    /// 末尾ノードを返す (削除しない)
    pub fn last(self: *const List) ?*Node {
        return self.tail;
    }

    /// リストが空かどうか
    pub fn isEmpty(self: *const List) bool {
        return self.head == null;
    }

    /// リストの長さ
    pub fn length(self: *const List) usize {
        return self.len;
    }

    /// target の後に node を挿入
    pub fn insertAfter(self: *List, target: *Node, node: *Node) void {
        node.prev = target;
        node.next = target.next;
        if (target.next) |n| {
            n.prev = node;
        } else {
            self.tail = node;
        }
        target.next = node;
        self.len += 1;
    }

    /// target の前に node を挿入
    pub fn insertBefore(self: *List, target: *Node, node: *Node) void {
        node.next = target;
        node.prev = target.prev;
        if (target.prev) |p| {
            p.next = node;
        } else {
            self.head = node;
        }
        target.prev = node;
        self.len += 1;
    }

    /// リスト内の全ノード数を走査してカウント (len の検証用)
    pub fn countNodes(self: *const List) usize {
        var count: usize = 0;
        var current = self.head;
        while (current) |node| {
            count += 1;
            current = node.next;
        }
        return count;
    }

    /// デバッグ: リストの情報を VGA に出力
    pub fn printInfo(self: *const List) void {
        vga.write("List: len=");
        pmm.printNum(self.len);
        vga.write(", head=");
        if (self.head != null) {
            vga.write("set");
        } else {
            vga.write("null");
        }
        vga.write(", tail=");
        if (self.tail != null) {
            vga.write("set");
        } else {
            vga.write("null");
        }
        vga.putChar('\n');
    }
};
