// Graph — グラフデータ構造とアルゴリズム
// 隣接リスト表現, 最大 32 ノード, 128 エッジ
// BFS, DFS, Dijkstra, トポロジカルソート, サイクル検出

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const MAX_NODES = 32;
pub const MAX_EDGES = 128;
pub const INF: u32 = 0xFFFFFFFF;

// ---- エッジ ----

pub const Edge = struct {
    src: u8 = 0,
    dst: u8 = 0,
    weight: u32 = 1,
    used: bool = false,
    next: u8 = 0xFF, // 同じ src からの次のエッジインデックス
};

// ---- ノード ----

pub const GraphNode = struct {
    id: u8 = 0,
    active: bool = false,
    first_edge: u8 = 0xFF, // 最初のエッジインデックス
    in_degree: u32 = 0,
    out_degree: u32 = 0,
};

// ---- Graph 本体 ----

pub const Graph = struct {
    nodes: [MAX_NODES]GraphNode = [_]GraphNode{.{}} ** MAX_NODES,
    edges: [MAX_EDGES]Edge = [_]Edge{.{}} ** MAX_EDGES,
    node_count_val: usize = 0,
    edge_count_val: usize = 0,
    directed: bool = true,

    /// 有向グラフとして初期化
    pub fn initDirected() Graph {
        return .{ .directed = true };
    }

    /// 無向グラフとして初期化
    pub fn initUndirected() Graph {
        return .{ .directed = false };
    }

    // ---- エッジプール ----

    fn allocEdge(self: *Graph) ?u8 {
        for (0..MAX_EDGES) |i| {
            if (!self.edges[i].used) {
                self.edges[i] = .{ .used = true, .next = 0xFF };
                return @truncate(i);
            }
        }
        return null;
    }

    fn freeEdge(self: *Graph, idx: u8) void {
        if (idx == 0xFF) return;
        self.edges[idx].used = false;
        self.edges[idx].next = 0xFF;
    }

    // ---- ノード操作 ----

    /// ノードを追加
    pub fn addNode(self: *Graph, id: u8) bool {
        if (id >= MAX_NODES) return false;
        if (self.nodes[id].active) return true; // 既に存在
        self.nodes[id].active = true;
        self.nodes[id].id = id;
        self.nodes[id].first_edge = 0xFF;
        self.nodes[id].in_degree = 0;
        self.nodes[id].out_degree = 0;
        self.node_count_val += 1;
        return true;
    }

    // ---- エッジ操作 ----

    /// エッジを追加
    pub fn addEdge(self: *Graph, src: u8, dst: u8, weight: u32) bool {
        if (src >= MAX_NODES or dst >= MAX_NODES) return false;
        if (!self.nodes[src].active or !self.nodes[dst].active) return false;

        // 重複チェック
        if (self.hasEdge(src, dst)) return true;

        const edge_idx = self.allocEdge() orelse return false;
        self.edges[edge_idx].src = src;
        self.edges[edge_idx].dst = dst;
        self.edges[edge_idx].weight = weight;

        // 隣接リストの先頭に挿入
        self.edges[edge_idx].next = self.nodes[src].first_edge;
        self.nodes[src].first_edge = edge_idx;
        self.nodes[src].out_degree += 1;
        self.nodes[dst].in_degree += 1;
        self.edge_count_val += 1;

        // 無向グラフの場合、逆方向も追加
        if (!self.directed) {
            const rev_idx = self.allocEdge() orelse return false;
            self.edges[rev_idx].src = dst;
            self.edges[rev_idx].dst = src;
            self.edges[rev_idx].weight = weight;
            self.edges[rev_idx].next = self.nodes[dst].first_edge;
            self.nodes[dst].first_edge = rev_idx;
            self.nodes[dst].out_degree += 1;
            self.nodes[src].in_degree += 1;
            self.edge_count_val += 1;
        }

        return true;
    }

    /// エッジが存在するか
    fn hasEdge(self: *const Graph, src: u8, dst: u8) bool {
        var eidx = self.nodes[src].first_edge;
        while (eidx != 0xFF) {
            if (self.edges[eidx].dst == dst) return true;
            eidx = self.edges[eidx].next;
        }
        return false;
    }

    /// エッジを削除
    pub fn removeEdge(self: *Graph, src: u8, dst: u8) bool {
        if (src >= MAX_NODES or dst >= MAX_NODES) return false;
        if (!self.nodes[src].active) return false;

        var prev: u8 = 0xFF;
        var eidx = self.nodes[src].first_edge;

        while (eidx != 0xFF) {
            if (self.edges[eidx].dst == dst) {
                // リストから削除
                if (prev == 0xFF) {
                    self.nodes[src].first_edge = self.edges[eidx].next;
                } else {
                    self.edges[prev].next = self.edges[eidx].next;
                }
                self.freeEdge(eidx);
                self.nodes[src].out_degree -= 1;
                self.nodes[dst].in_degree -= 1;
                self.edge_count_val -= 1;

                // 無向グラフの場合、逆方向も削除
                if (!self.directed) {
                    _ = self.removeDirectedEdge(dst, src);
                }
                return true;
            }
            prev = eidx;
            eidx = self.edges[eidx].next;
        }
        return false;
    }

    fn removeDirectedEdge(self: *Graph, src: u8, dst: u8) bool {
        var prev: u8 = 0xFF;
        var eidx = self.nodes[src].first_edge;

        while (eidx != 0xFF) {
            if (self.edges[eidx].dst == dst) {
                if (prev == 0xFF) {
                    self.nodes[src].first_edge = self.edges[eidx].next;
                } else {
                    self.edges[prev].next = self.edges[eidx].next;
                }
                self.freeEdge(eidx);
                self.nodes[src].out_degree -= 1;
                self.nodes[dst].in_degree -= 1;
                self.edge_count_val -= 1;
                return true;
            }
            prev = eidx;
            eidx = self.edges[eidx].next;
        }
        return false;
    }

    // ---- BFS ----

    /// 幅優先探索
    pub fn bfs(self: *const Graph, start: u8, callback: *const fn (u8) void) void {
        if (start >= MAX_NODES or !self.nodes[start].active) return;

        var visited: [MAX_NODES]bool = @splat(false);
        var queue: [MAX_NODES]u8 = undefined;
        var head: usize = 0;
        var tail: usize = 0;

        visited[start] = true;
        queue[tail] = start;
        tail += 1;

        while (head < tail) {
            const current = queue[head];
            head += 1;
            callback(current);

            var eidx = self.nodes[current].first_edge;
            while (eidx != 0xFF) {
                const dst = self.edges[eidx].dst;
                if (!visited[dst]) {
                    visited[dst] = true;
                    queue[tail] = dst;
                    tail += 1;
                }
                eidx = self.edges[eidx].next;
            }
        }
    }

    // ---- DFS ----

    /// 深さ優先探索
    pub fn dfs(self: *const Graph, start: u8, callback: *const fn (u8) void) void {
        if (start >= MAX_NODES or !self.nodes[start].active) return;

        var visited: [MAX_NODES]bool = @splat(false);
        self.dfsHelper(start, &visited, callback);
    }

    fn dfsHelper(self: *const Graph, node: u8, visited: *[MAX_NODES]bool, callback: *const fn (u8) void) void {
        if (visited[node]) return;
        visited[node] = true;
        callback(node);

        var eidx = self.nodes[node].first_edge;
        while (eidx != 0xFF) {
            const dst = self.edges[eidx].dst;
            if (!visited[dst]) {
                self.dfsHelper(dst, visited, callback);
            }
            eidx = self.edges[eidx].next;
        }
    }

    // ---- Dijkstra ----

    /// 最短パスの重み (Dijkstra)
    pub fn shortestPath(self: *const Graph, src: u8, dst: u8) ?u32 {
        if (src >= MAX_NODES or dst >= MAX_NODES) return null;
        if (!self.nodes[src].active or !self.nodes[dst].active) return null;

        var dist: [MAX_NODES]u32 = @splat(INF);
        var visited: [MAX_NODES]bool = @splat(false);

        dist[src] = 0;

        // 全ノード分繰り返す
        var iter: usize = 0;
        while (iter < MAX_NODES) : (iter += 1) {
            // 未訪問で最小距離のノードを選ぶ
            var min_dist: u32 = INF;
            var min_node: u8 = 0xFF;

            for (0..MAX_NODES) |i| {
                const ni: u8 = @truncate(i);
                if (self.nodes[ni].active and !visited[ni] and dist[ni] < min_dist) {
                    min_dist = dist[ni];
                    min_node = ni;
                }
            }

            if (min_node == 0xFF) break; // 到達不能
            if (min_node == dst) return dist[dst];

            visited[min_node] = true;

            // 隣接ノードの距離を更新
            var eidx = self.nodes[min_node].first_edge;
            while (eidx != 0xFF) {
                const edge = &self.edges[eidx];
                const new_dist = dist[min_node] +| edge.weight;
                if (new_dist < dist[edge.dst]) {
                    dist[edge.dst] = new_dist;
                }
                eidx = edge.next;
            }
        }

        if (dist[dst] == INF) return null;
        return dist[dst];
    }

    // ---- 連結性 ----

    /// 2 ノード間の接続性
    pub fn isConnected(self: *const Graph, a: u8, b: u8) bool {
        if (a >= MAX_NODES or b >= MAX_NODES) return false;
        if (!self.nodes[a].active or !self.nodes[b].active) return false;

        var visited: [MAX_NODES]bool = @splat(false);
        return self.dfsReach(a, b, &visited);
    }

    fn dfsReach(self: *const Graph, current: u8, target: u8, visited: *[MAX_NODES]bool) bool {
        if (current == target) return true;
        visited[current] = true;

        var eidx = self.nodes[current].first_edge;
        while (eidx != 0xFF) {
            const dst = self.edges[eidx].dst;
            if (!visited[dst]) {
                if (self.dfsReach(dst, target, visited)) return true;
            }
            eidx = self.edges[eidx].next;
        }
        return false;
    }

    // ---- トポロジカルソート ----

    /// DAG のトポロジカルソート。サイクルがあれば null
    pub fn topologicalSort(self: *const Graph, result: []u8) ?usize {
        // Kahn's algorithm
        var in_deg: [MAX_NODES]u32 = undefined;
        for (0..MAX_NODES) |i| {
            in_deg[i] = self.nodes[i].in_degree;
        }

        var queue: [MAX_NODES]u8 = undefined;
        var head: usize = 0;
        var tail: usize = 0;

        // 入次数 0 のノードをキューに入れる
        for (0..MAX_NODES) |i| {
            const ni: u8 = @truncate(i);
            if (self.nodes[ni].active and in_deg[ni] == 0) {
                queue[tail] = ni;
                tail += 1;
            }
        }

        var count_val: usize = 0;

        while (head < tail) {
            const node = queue[head];
            head += 1;

            if (count_val < result.len) {
                result[count_val] = node;
            }
            count_val += 1;

            var eidx = self.nodes[node].first_edge;
            while (eidx != 0xFF) {
                const dst = self.edges[eidx].dst;
                in_deg[dst] -= 1;
                if (in_deg[dst] == 0) {
                    queue[tail] = dst;
                    tail += 1;
                }
                eidx = self.edges[eidx].next;
            }
        }

        if (count_val != self.node_count_val) return null; // サイクル検出
        return count_val;
    }

    // ---- サイクル検出 ----

    /// サイクルが存在するか (有向グラフ用)
    pub fn hasCycle(self: *const Graph) bool {
        // 白 (0) = 未訪問, 灰 (1) = 処理中, 黒 (2) = 完了
        var color: [MAX_NODES]u8 = @splat(0);

        for (0..MAX_NODES) |i| {
            const ni: u8 = @truncate(i);
            if (self.nodes[ni].active and color[ni] == 0) {
                if (self.hasCycleDfs(ni, &color)) return true;
            }
        }
        return false;
    }

    fn hasCycleDfs(self: *const Graph, node: u8, color: *[MAX_NODES]u8) bool {
        color[node] = 1; // 灰色 (処理中)

        var eidx = self.nodes[node].first_edge;
        while (eidx != 0xFF) {
            const dst = self.edges[eidx].dst;
            if (color[dst] == 1) return true; // バックエッジ = サイクル
            if (color[dst] == 0) {
                if (self.hasCycleDfs(dst, color)) return true;
            }
            eidx = self.edges[eidx].next;
        }

        color[node] = 2; // 黒 (完了)
        return false;
    }

    // ---- 統計 ----

    pub fn nodeCount(self: *const Graph) usize {
        return self.node_count_val;
    }

    pub fn edgeCount(self: *const Graph) usize {
        return self.edge_count_val;
    }

    // ---- 表示 ----

    pub fn printGraph(self: *const Graph) void {
        vga.setColor(.yellow, .black);
        vga.write("Graph (");
        fmt.printDec(self.node_count_val);
        vga.write(" nodes, ");
        fmt.printDec(self.edge_count_val);
        vga.write(" edges, ");
        if (self.directed) vga.write("directed") else vga.write("undirected");
        vga.write("):\n");
        vga.setColor(.light_grey, .black);

        for (0..MAX_NODES) |i| {
            const ni: u8 = @truncate(i);
            if (!self.nodes[ni].active) continue;

            vga.write("  [");
            fmt.printDec(ni);
            vga.write("] -> ");

            var eidx = self.nodes[ni].first_edge;
            var first = true;
            while (eidx != 0xFF) {
                if (!first) vga.write(", ");
                first = false;
                fmt.printDec(self.edges[eidx].dst);
                vga.putChar('(');
                fmt.printDec(self.edges[eidx].weight);
                vga.putChar(')');
                eidx = self.edges[eidx].next;
            }
            if (first) vga.write("(none)");
            vga.putChar('\n');
        }
    }

    /// グラフをクリア
    pub fn clear(self: *Graph) void {
        for (&self.nodes) |*n| {
            n.active = false;
            n.first_edge = 0xFF;
        }
        for (&self.edges) |*e| {
            e.used = false;
            e.next = 0xFF;
        }
        self.node_count_val = 0;
        self.edge_count_val = 0;
    }
};

// ---- モジュールレベル関数 ----

var global_graph: Graph = .{};

pub fn getGraph() *Graph {
    return &global_graph;
}

/// デモ: グラフアルゴリズムを実行
pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Graph Demo ===\n");
    vga.setColor(.light_grey, .black);

    // 有向グラフを構築
    var g = Graph.initDirected();
    var i: u8 = 0;
    while (i < 6) : (i += 1) {
        _ = g.addNode(i);
    }

    _ = g.addEdge(0, 1, 4);
    _ = g.addEdge(0, 2, 2);
    _ = g.addEdge(1, 3, 5);
    _ = g.addEdge(2, 1, 1);
    _ = g.addEdge(2, 3, 8);
    _ = g.addEdge(3, 4, 2);
    _ = g.addEdge(4, 5, 6);
    _ = g.addEdge(2, 4, 10);

    g.printGraph();

    // BFS
    vga.write("\nBFS from 0: ");
    g.bfs(0, &bfsCallback);
    vga.putChar('\n');

    // DFS
    vga.write("DFS from 0: ");
    g.dfs(0, &dfsCallback);
    vga.putChar('\n');

    // Dijkstra
    vga.write("Shortest 0->4: ");
    if (g.shortestPath(0, 4)) |d| {
        fmt.printDec(d);
    } else {
        vga.write("unreachable");
    }
    vga.putChar('\n');

    vga.write("Shortest 0->5: ");
    if (g.shortestPath(0, 5)) |d| {
        fmt.printDec(d);
    } else {
        vga.write("unreachable");
    }
    vga.putChar('\n');

    // 接続性
    vga.write("Connected(0,5): ");
    if (g.isConnected(0, 5)) vga.write("yes") else vga.write("no");
    vga.putChar('\n');

    // サイクル検出
    vga.write("Has cycle: ");
    if (g.hasCycle()) vga.write("yes") else vga.write("no");
    vga.putChar('\n');

    // トポロジカルソート
    var topo: [MAX_NODES]u8 = undefined;
    if (g.topologicalSort(&topo)) |cnt| {
        vga.write("Topological order: ");
        for (0..cnt) |idx| {
            if (idx > 0) vga.write(", ");
            fmt.printDec(topo[idx]);
        }
        vga.putChar('\n');
    } else {
        vga.write("Topological sort: CYCLE detected\n");
    }
}

fn bfsCallback(node: u8) void {
    fmt.printDec(node);
    vga.putChar(' ');
}

fn dfsCallback(node: u8) void {
    fmt.printDec(node);
    vga.putChar(' ');
}

pub fn printInfo() void {
    global_graph.printGraph();
}
