// Kernel Object System — 参照カウント付きカーネルオブジェクト管理
//
// Linux の kobject に着想を得た軽量オブジェクトシステム。
// 参照カウント、親子関係、型固有操作の vtable を提供する。
// プロセス、ファイル、デバイス、ソケット等を統一的に管理。

const vga = @import("vga.zig");
const serial = @import("serial.zig");
const fmt = @import("fmt.zig");

// ---- 定数 ----

const MAX_OBJECTS: usize = 64;
const MAX_NAME_LEN: usize = 24;
const MAX_CHILDREN: usize = 8;

// ---- オブジェクトタイプ ----

pub const ObjectType = enum(u8) {
    none,
    process,
    file,
    device,
    socket,
    pipe,
    mutex,
    semaphore,
    timer,
    module,
    directory,
};

/// オブジェクトタイプの名前を返す
fn typeName(t: ObjectType) []const u8 {
    return switch (t) {
        .none => "none",
        .process => "process",
        .file => "file",
        .device => "device",
        .socket => "socket",
        .pipe => "pipe",
        .mutex => "mutex",
        .semaphore => "semaphore",
        .timer => "timer",
        .module => "module",
        .directory => "directory",
    };
}

// ---- Operations vtable ----

pub const KObjectOps = struct {
    /// オブジェクト解放時に呼ばれるコールバック
    release: ?*const fn (*KObject) void = null,
    /// 表示用の追加情報
    show: ?*const fn (*const KObject) void = null,
    /// オブジェクト固有のコマンド
    ioctl: ?*const fn (*KObject, u32, u32) i32 = null,
};

const default_ops = KObjectOps{};

// ---- KObject 構造体 ----

pub const KObject = struct {
    obj_type: ObjectType,
    ref_count: u32,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    active: bool,
    parent_id: u16, // 親オブジェクトの ID (0=なし)
    id: u16, // このオブジェクトの ID
    ops: KObjectOps,
    children: [MAX_CHILDREN]u16, // 子オブジェクト ID
    child_count: u8,
    create_tick: u64, // 作成時刻
    user_data: u32, // 型固有のデータ (ポインタ等)
};

fn initKObject() KObject {
    return .{
        .obj_type = .none,
        .ref_count = 0,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .active = false,
        .parent_id = 0,
        .id = 0,
        .ops = default_ops,
        .children = [_]u16{0} ** MAX_CHILDREN,
        .child_count = 0,
        .create_tick = 0,
        .user_data = 0,
    };
}

// ---- グローバル状態 ----

var objects: [MAX_OBJECTS]KObject = initAllObjects();
var next_id: u16 = 1;

// 統計
var total_created: u64 = 0;
var total_destroyed: u64 = 0;
var peak_active: usize = 0;

fn initAllObjects() [MAX_OBJECTS]KObject {
    var objs: [MAX_OBJECTS]KObject = undefined;
    for (&objs) |*o| {
        o.* = initKObject();
    }
    return objs;
}

fn activeCount() usize {
    var count: usize = 0;
    for (&objects) |*o| {
        if (o.active) count += 1;
    }
    return count;
}

// ---- ヘルパー ----

fn copyName(dst: *[MAX_NAME_LEN]u8, src: []const u8) u8 {
    const len: u8 = @truncate(@min(src.len, MAX_NAME_LEN));
    for (0..len) |i| {
        dst[i] = src[i];
    }
    return len;
}

fn nameMatch(obj_name: []const u8, search: []const u8) bool {
    if (obj_name.len != search.len) return false;
    for (obj_name, search) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn findById(id: u16) ?*KObject {
    if (id == 0) return null;
    for (&objects) |*o| {
        if (o.active and o.id == id) return o;
    }
    return null;
}

// ---- 公開 API ----

/// 新しいカーネルオブジェクトを作成
pub fn create(obj_type: ObjectType, name: []const u8) ?*KObject {
    // 空きスロットを探す
    for (&objects) |*o| {
        if (!o.active) {
            const id = next_id;
            next_id +%= 1;
            if (next_id == 0) next_id = 1;

            o.* = initKObject();
            o.obj_type = obj_type;
            o.ref_count = 1;
            o.name_len = copyName(&o.name, name);
            o.active = true;
            o.id = id;
            o.create_tick = 0; // PIT import は直接使わず、呼び出し元が設定可能

            total_created += 1;
            const current = activeCount();
            if (current > peak_active) {
                peak_active = current;
            }

            serial.write("[kobject] created id=");
            serial.writeHex(id);
            serial.write(" type=");
            serial.write(typeName(obj_type));
            serial.write(" name=");
            serial.write(name);
            serial.write("\n");

            return o;
        }
    }
    serial.write("[kobject] pool exhausted\n");
    return null;
}

/// オブジェクトを作成して操作テーブルを設定
pub fn createWithOps(obj_type: ObjectType, name: []const u8, ops: KObjectOps) ?*KObject {
    const obj = create(obj_type, name) orelse return null;
    obj.ops = ops;
    return obj;
}

/// 参照カウントをインクリメント
pub fn retain(obj: *KObject) void {
    if (!obj.active) return;
    obj.ref_count += 1;
}

/// 参照カウントをデクリメント (0 になったら解放)
pub fn release(obj: *KObject) void {
    if (!obj.active) return;
    if (obj.ref_count == 0) return;

    obj.ref_count -= 1;

    if (obj.ref_count == 0) {
        // release コールバック
        if (obj.ops.release) |release_fn| {
            release_fn(obj);
        }

        // 親から子リストを削除
        if (obj.parent_id != 0) {
            if (findById(obj.parent_id)) |parent| {
                removeChild(parent, obj.id);
            }
        }

        // 子オブジェクトの親参照をクリア
        for (0..obj.child_count) |i| {
            if (findById(obj.children[i])) |child| {
                child.parent_id = 0;
            }
        }

        serial.write("[kobject] destroyed id=");
        serial.writeHex(obj.id);
        serial.write("\n");

        obj.active = false;
        total_destroyed += 1;
    }
}

/// 参照カウントを取得
pub fn getRefCount(obj: *const KObject) u32 {
    return obj.ref_count;
}

/// 親子関係を設定
pub fn setParent(child: *KObject, parent: *KObject) bool {
    if (!child.active or !parent.active) return false;

    // 既存の親から削除
    if (child.parent_id != 0) {
        if (findById(child.parent_id)) |old_parent| {
            removeChild(old_parent, child.id);
        }
    }

    child.parent_id = parent.id;
    return addChild(parent, child.id);
}

fn addChild(parent: *KObject, child_id: u16) bool {
    if (parent.child_count >= MAX_CHILDREN) return false;
    parent.children[parent.child_count] = child_id;
    parent.child_count += 1;
    return true;
}

fn removeChild(parent: *KObject, child_id: u16) void {
    for (0..parent.child_count) |i| {
        if (parent.children[i] == child_id) {
            // 末尾で上書き
            parent.child_count -= 1;
            if (i < parent.child_count) {
                parent.children[i] = parent.children[parent.child_count];
            }
            return;
        }
    }
}

/// 名前でオブジェクトを検索
pub fn findByName(name: []const u8) ?*KObject {
    for (&objects) |*o| {
        if (o.active and nameMatch(o.name[0..o.name_len], name)) {
            return o;
        }
    }
    return null;
}

/// タイプで最初のオブジェクトを検索
pub fn findByType(obj_type: ObjectType) ?*KObject {
    for (&objects) |*o| {
        if (o.active and o.obj_type == obj_type) {
            return o;
        }
    }
    return null;
}

/// タイプに一致するオブジェクト数を返す
pub fn countByType(obj_type: ObjectType) usize {
    var count: usize = 0;
    for (&objects) |*o| {
        if (o.active and o.obj_type == obj_type) count += 1;
    }
    return count;
}

/// ユーザーデータを設定
pub fn setUserData(obj: *KObject, data: u32) void {
    obj.user_data = data;
}

/// ユーザーデータを取得
pub fn getUserData(obj: *const KObject) u32 {
    return obj.user_data;
}

/// ioctl 呼び出し
pub fn ioctl(obj: *KObject, cmd: u32, arg: u32) i32 {
    if (obj.ops.ioctl) |ioctl_fn| {
        return ioctl_fn(obj, cmd, arg);
    }
    return -1;
}

// ---- 表示 ----

/// 単一オブジェクトの情報を表示
pub fn printObject(obj: *const KObject) void {
    vga.setColor(.light_cyan, .black);
    vga.write("  KObject #");
    fmt.printDec(obj.id);
    vga.setColor(.light_grey, .black);
    vga.write(": ");
    vga.write(obj.name[0..obj.name_len]);
    vga.write(" type=");
    vga.write(typeName(obj.obj_type));
    vga.write(" ref=");
    fmt.printDec(obj.ref_count);
    if (obj.parent_id != 0) {
        vga.write(" parent=#");
        fmt.printDec(obj.parent_id);
    }
    if (obj.child_count > 0) {
        vga.write(" children=");
        fmt.printDec(obj.child_count);
    }
    if (obj.user_data != 0) {
        vga.write(" data=0x");
        fmt.printHex32(obj.user_data);
    }
    vga.putChar('\n');

    // show コールバック
    if (obj.ops.show) |show_fn| {
        show_fn(obj);
    }
}

/// 全オブジェクトを表示
pub fn printAll() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Kernel Objects ===\n");
    vga.setColor(.light_grey, .black);

    var count: usize = 0;
    for (&objects) |*o| {
        if (o.active) {
            printObject(o);
            count += 1;
        }
    }

    if (count == 0) {
        vga.write("  No active objects.\n");
    }

    vga.write("\n  Total active: ");
    fmt.printDec(count);
    vga.write("  Created: ");
    printU64(total_created);
    vga.write("  Destroyed: ");
    printU64(total_destroyed);
    vga.write("  Peak: ");
    fmt.printDec(peak_active);
    vga.putChar('\n');

    // タイプ別サマリー
    vga.write("\n  Type summary:\n");
    const types = [_]ObjectType{
        .process, .file, .device, .socket, .pipe,
        .mutex,   .semaphore, .timer, .module, .directory,
    };
    for (types) |t| {
        const c = countByType(t);
        if (c > 0) {
            vga.write("    ");
            vga.write(typeName(t));
            vga.write(": ");
            fmt.printDec(c);
            vga.putChar('\n');
        }
    }
}

/// 階層構造をツリー表示
pub fn printTree() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Object Tree ===\n");
    vga.setColor(.light_grey, .black);

    // ルートオブジェクト (parent_id == 0) から開始
    for (&objects) |*o| {
        if (o.active and o.parent_id == 0) {
            printTreeNode(o, 0);
        }
    }
}

fn printTreeNode(obj: *const KObject, depth: usize) void {
    // インデント
    for (0..depth) |_| {
        vga.write("  ");
    }
    if (depth > 0) {
        vga.write("|- ");
    }

    vga.write(obj.name[0..obj.name_len]);
    vga.write(" (");
    vga.write(typeName(obj.obj_type));
    vga.write(" ref=");
    fmt.printDec(obj.ref_count);
    vga.write(")\n");

    // 子を再帰表示
    for (0..obj.child_count) |i| {
        if (findById(obj.children[i])) |child| {
            printTreeNode(child, depth + 1);
        }
    }
}

fn printU64(val: u64) void {
    fmt.printDec(@truncate(val));
}

// ---- リセット (テスト用) ----

pub fn reset() void {
    for (&objects) |*o| {
        o.* = initKObject();
    }
    next_id = 1;
    total_created = 0;
    total_destroyed = 0;
    peak_active = 0;
}
