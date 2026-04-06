// Process hierarchy visualization — pstree-like process tree display
//
// Builds a tree from task ppid relationships, supports ancestry/descendant
// queries, formatted tree printing with indentation, and process state counts.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const task = @import("task.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_TREE_NODES = task.MAX_TASKS;
const MAX_CHILDREN = 8;
const MAX_DEPTH = 8;
const MAX_NAME = 16;

// ---- Tree node ----

pub const TreeNode = struct {
    pid: u32,
    ppid: u32,
    name: [MAX_NAME]u8,
    name_len: u8,
    state: task.TaskState,
    children: [MAX_CHILDREN]u32, // PIDs of children
    child_count: u8,
    depth: u8,
    valid: bool,
};

// ---- Process counts ----

pub const ProcessCounts = struct {
    total: u32,
    running: u32,
    ready: u32,
    waiting: u32,
    zombie: u32,
    terminated: u32,
};

// ---- Tree storage ----

var tree_nodes: [MAX_TREE_NODES]TreeNode = undefined;
var tree_node_count: u32 = 0;

// ---- Build tree ----

/// Scan task table and build a tree structure from ppid relationships.
pub fn buildTree() void {
    tree_node_count = 0;

    // First pass: create nodes for all active tasks
    var i: u32 = 0;
    while (i < task.MAX_TASKS) : (i += 1) {
        const t = task.getTask(i);
        // Also need to check pid == i for the kernel task (pid 0)
        // Use a raw scan approach instead
        _ = t;
    }

    // Direct scan of task table via getTask for each possible pid
    // We iterate by slot index, checking each task
    var pid_scan: u32 = 0;
    while (pid_scan < 256) : (pid_scan += 1) {
        if (getTaskInfo(pid_scan)) |info| {
            if (tree_node_count >= MAX_TREE_NODES) break;
            const idx = tree_node_count;
            tree_nodes[idx].pid = info.pid;
            tree_nodes[idx].ppid = info.ppid;
            tree_nodes[idx].name_len = info.name_len;
            @memcpy(tree_nodes[idx].name[0..info.name_len], info.name[0..info.name_len]);
            tree_nodes[idx].state = info.state;
            tree_nodes[idx].child_count = 0;
            tree_nodes[idx].depth = 0;
            tree_nodes[idx].valid = true;
            tree_node_count += 1;
        }
    }

    // Second pass: establish parent-child relationships
    var n: u32 = 0;
    while (n < tree_node_count) : (n += 1) {
        var m: u32 = 0;
        while (m < tree_node_count) : (m += 1) {
            if (n == m) {
                m += 1;
                continue;
            }
            // If node m's ppid matches node n's pid, m is a child of n
            if (tree_nodes[m].ppid == tree_nodes[n].pid and tree_nodes[n].valid and tree_nodes[m].valid) {
                if (tree_nodes[n].child_count < MAX_CHILDREN) {
                    tree_nodes[n].children[tree_nodes[n].child_count] = tree_nodes[m].pid;
                    tree_nodes[n].child_count += 1;
                }
            }
        }
    }

    // Third pass: compute depths
    computeDepths();
}

/// Helper to get task info by pid.
fn getTaskInfo(pid: u32) ?struct { pid: u32, ppid: u32, name: [MAX_NAME]u8, name_len: u8, state: task.TaskState } {
    if (task.getTask(pid)) |t| {
        return .{
            .pid = t.pid,
            .ppid = t.ppid,
            .name = t.name,
            .name_len = t.name_len,
            .state = t.state,
        };
    }
    return null;
}

/// Compute depth for each node (distance from root).
fn computeDepths() void {
    // Set root nodes (ppid == pid, i.e. kernel) to depth 0
    var n: u32 = 0;
    while (n < tree_node_count) : (n += 1) {
        tree_nodes[n].depth = computeNodeDepth(tree_nodes[n].pid, 0);
    }
}

fn computeNodeDepth(pid: u32, recursion: u8) u8 {
    if (recursion >= MAX_DEPTH) return MAX_DEPTH;

    // Find this node
    var n: u32 = 0;
    while (n < tree_node_count) : (n += 1) {
        if (tree_nodes[n].pid == pid and tree_nodes[n].valid) {
            // Root: ppid == own pid (kernel task pid=0, ppid=0)
            if (tree_nodes[n].ppid == tree_nodes[n].pid) return 0;
            // Otherwise recurse on parent
            return computeNodeDepth(tree_nodes[n].ppid, recursion + 1) + 1;
        }
    }
    return 0;
}

// ---- Tree node lookup ----

fn findNode(pid: u32) ?*TreeNode {
    var n: u32 = 0;
    while (n < tree_node_count) : (n += 1) {
        if (tree_nodes[n].pid == pid and tree_nodes[n].valid) {
            return &tree_nodes[n];
        }
    }
    return null;
}

// ---- Ancestry queries ----

/// Find all ancestors of a given PID (parent, grandparent, ...).
/// Returns count of ancestors found, stores PIDs in result buffer.
pub fn findAncestors(pid: u32, result: *[MAX_DEPTH]u32) u32 {
    buildTree();
    var count: u32 = 0;
    var current_pid = pid;
    var depth: u32 = 0;

    while (depth < MAX_DEPTH) : (depth += 1) {
        if (findNode(current_pid)) |node| {
            if (node.ppid == node.pid) break; // reached root
            result[count] = node.ppid;
            count += 1;
            current_pid = node.ppid;
        } else break;
    }
    return count;
}

/// Find all descendants of a given PID (children, grandchildren, ...).
/// Returns count found, stores PIDs in result buffer.
pub fn findDescendants(pid: u32, result: *[MAX_TREE_NODES]u32) u32 {
    buildTree();
    var count: u32 = 0;
    collectDescendants(pid, result, &count);
    return count;
}

fn collectDescendants(pid: u32, result: *[MAX_TREE_NODES]u32, count: *u32) void {
    if (findNode(pid)) |node| {
        var i: u8 = 0;
        while (i < node.child_count) : (i += 1) {
            if (count.* < MAX_TREE_NODES) {
                result[count.*] = node.children[i];
                count.* += 1;
                collectDescendants(node.children[i], result, count);
            }
        }
    }
}

/// Get depth of a process in the tree.
pub fn getDepth(pid: u32) u32 {
    buildTree();
    if (findNode(pid)) |node| {
        return @as(u32, node.depth);
    }
    return 0;
}

// ---- Process counting ----

/// Count processes by state.
pub fn getCounts() ProcessCounts {
    buildTree();
    var counts = ProcessCounts{
        .total = 0,
        .running = 0,
        .ready = 0,
        .waiting = 0,
        .zombie = 0,
        .terminated = 0,
    };

    var n: u32 = 0;
    while (n < tree_node_count) : (n += 1) {
        if (!tree_nodes[n].valid) continue;
        counts.total += 1;
        switch (tree_nodes[n].state) {
            .running => counts.running += 1,
            .ready => counts.ready += 1,
            .waiting => counts.waiting += 1,
            .zombie => counts.zombie += 1,
            .terminated => counts.terminated += 1,
            .unused => {},
        }
    }
    return counts;
}

// ---- Display ----

/// Print the process tree with indentation (pstree-style).
pub fn printTree() void {
    buildTree();

    vga.setColor(.light_cyan, .black);
    vga.write("=== Process Tree ===\n");

    if (tree_node_count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no processes)\n");
        return;
    }

    // Print starting from root nodes (depth == 0)
    var n: u32 = 0;
    while (n < tree_node_count) : (n += 1) {
        if (tree_nodes[n].valid and tree_nodes[n].depth == 0) {
            printNodeRecursive(tree_nodes[n].pid, 0, false);
        }
    }
}

fn printNodeRecursive(pid: u32, indent: u32, is_last: bool) void {
    if (findNode(pid)) |node| {
        // Indent
        var i: u32 = 0;
        while (i < indent) : (i += 1) {
            if (i + 1 == indent) {
                if (is_last) {
                    vga.write("  `-- ");
                } else {
                    vga.write("  |-- ");
                }
            } else {
                vga.write("  |   ");
            }
        }

        if (indent == 0) {
            vga.write("  ");
        }

        // PID and name
        printStateColor(node.state);
        vga.write(node.name[0..node.name_len]);
        vga.setColor(.dark_grey, .black);
        vga.write("(");
        fmt.printDec(@as(usize, node.pid));
        vga.write(")");

        // State indicator
        vga.write(" [");
        printStateName(node.state);
        vga.write("]");
        vga.putChar('\n');

        // Print children
        var c: u8 = 0;
        while (c < node.child_count) : (c += 1) {
            const child_is_last = (c + 1 == node.child_count);
            printNodeRecursive(node.children[c], indent + 1, child_is_last);
        }
    }
}

fn printStateColor(state: task.TaskState) void {
    switch (state) {
        .running => vga.setColor(.light_green, .black),
        .ready => vga.setColor(.light_cyan, .black),
        .waiting => vga.setColor(.yellow, .black),
        .zombie => vga.setColor(.light_red, .black),
        .terminated => vga.setColor(.dark_grey, .black),
        .unused => vga.setColor(.dark_grey, .black),
    }
}

fn printStateName(state: task.TaskState) void {
    switch (state) {
        .running => vga.write("R"),
        .ready => vga.write("S"),
        .waiting => vga.write("W"),
        .zombie => vga.write("Z"),
        .terminated => vga.write("T"),
        .unused => vga.write("-"),
    }
}

/// Print all process trees (forest view).
pub fn printForest() void {
    buildTree();

    vga.setColor(.light_cyan, .black);
    vga.write("=== Process Forest ===\n");

    // Print summary
    const counts = getCounts();
    vga.setColor(.light_grey, .black);
    vga.write("Total: ");
    fmt.printDec(@as(usize, counts.total));
    vga.write("  Running: ");
    fmt.printDec(@as(usize, counts.running));
    vga.write("  Ready: ");
    fmt.printDec(@as(usize, counts.ready));
    vga.write("  Waiting: ");
    fmt.printDec(@as(usize, counts.waiting));
    vga.write("  Zombie: ");
    fmt.printDec(@as(usize, counts.zombie));
    vga.putChar('\n');
    vga.putChar('\n');

    // Print all trees
    printTree();
}

/// Print ancestors of a process.
pub fn printAncestors(pid: u32) void {
    var ancestors: [MAX_DEPTH]u32 = undefined;
    const count = findAncestors(pid, &ancestors);

    vga.setColor(.light_cyan, .black);
    vga.write("Ancestors of PID ");
    fmt.printDec(@as(usize, pid));
    vga.write(": ");

    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("(root)\n");
        return;
    }

    vga.setColor(.light_grey, .black);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i > 0) vga.write(" -> ");
        fmt.printDec(@as(usize, ancestors[i]));
    }
    vga.putChar('\n');
}

/// Print descendants of a process.
pub fn printDescendants(pid: u32) void {
    var descendants: [MAX_TREE_NODES]u32 = undefined;
    const count = findDescendants(pid, &descendants);

    vga.setColor(.light_cyan, .black);
    vga.write("Descendants of PID ");
    fmt.printDec(@as(usize, pid));
    vga.write(": ");

    if (count == 0) {
        vga.setColor(.dark_grey, .black);
        vga.write("(none)\n");
        return;
    }

    vga.setColor(.light_grey, .black);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i > 0) vga.write(", ");
        fmt.printDec(@as(usize, descendants[i]));
    }
    vga.putChar('\n');
}
