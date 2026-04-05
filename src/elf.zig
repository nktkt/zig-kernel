// ELF32 ローダー — RAM FS から実行可能ファイルをロードして実行
// argc/argv をユーザースタックに構築

const ramfs = @import("ramfs.zig");
const task = @import("task.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

pub fn exec(name: []const u8) bool {
    return execWithArgs(name, &.{});
}

pub fn execWithArgs(name: []const u8, args: []const []const u8) bool {
    const idx = ramfs.findByName(name) orelse {
        vga.setColor(.light_red, .black);
        vga.write("File not found: ");
        vga.write(name);
        vga.putChar('\n');
        return false;
    };
    const file = ramfs.getFile(idx) orelse return false;
    const data = file.data[0..file.size];

    if (data.len < 52) {
        vga.setColor(.light_red, .black);
        vga.write("File too small for ELF\n");
        return false;
    }

    // ELF マジック検証
    if (data[0] != 0x7F or data[1] != 'E' or data[2] != 'L' or data[3] != 'F') {
        vga.setColor(.light_red, .black);
        vga.write("Not an ELF file\n");
        return false;
    }

    if (data[4] != 1) {
        vga.setColor(.light_red, .black);
        vga.write("Not ELF32\n");
        return false;
    }

    const entry = readU32(data, 24);
    serial.write("[ELF] entry=0x");
    serial.writeHex(entry);
    serial.write("\n");

    // プログラムヘッダ解析・ロード
    const ph_off = readU32(data, 28);
    const ph_size = readU16(data, 42);
    const ph_num = readU16(data, 44);

    var loaded = false;
    var i: u16 = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + @as(u32, i) * ph_size;
        if (off + ph_size > data.len) break;

        const p_type = readU32(data, off);
        if (p_type != 1) continue;

        const p_offset = readU32(data, off + 4);
        const p_vaddr = readU32(data, off + 8);
        const p_filesz = readU32(data, off + 16);

        if (p_vaddr >= 0x100000 and p_vaddr + p_filesz < 0x8000000) {
            if (p_offset + p_filesz <= data.len) {
                const dst: [*]u8 = @ptrFromInt(p_vaddr);
                const src = data[p_offset .. p_offset + p_filesz];
                @memcpy(dst[0..p_filesz], src);
                loaded = true;
            }
        }
    }
    // ユーザータスクを作成
    const pid = task.createUserTask(entry, name) orelse {
        vga.setColor(.light_red, .black);
        vga.write("Failed to create task\n");
        return false;
    };

    // argc/argv をユーザースタックに構築
    if (task.getTask(pid)) |t| {
        buildArgv(t, name, args);
    }

    vga.setColor(.light_green, .black);
    vga.write("Loaded '");
    vga.write(name);
    vga.write("' (pid=");
    pmm.printNum(pid);
    vga.write(")\n");
    task.enableScheduling();
    return true;
}

/// ユーザースタックに argc, argv を構築
/// スタックレイアウト (上→下):
///   argv[0] 文字列データ
///   argv[1] 文字列データ
///   ...
///   argv[0] ポインタ
///   argv[1] ポインタ
///   NULL
///   argv ポインタ (argv 配列の先頭アドレス)
///   argc
fn buildArgv(t: *task.Task, name: []const u8, args: []const []const u8) void {
    const stack_base: [*]u8 = @ptrFromInt(t.user_stack);
    var sp: usize = 4096; // スタックトップからのオフセット (下に伸びる)

    // 文字列データをスタックに書き込む (argv[0] = name, argv[1..] = args)
    const argc: u32 = 1 + @as(u32, @truncate(args.len));
    var argv_ptrs: [16]u32 = undefined;
    var arg_idx: usize = 0;

    // argv[0] = プログラム名
    sp -= name.len + 1;
    @memcpy(stack_base[sp .. sp + name.len], name);
    stack_base[sp + name.len] = 0; // null terminator
    argv_ptrs[0] = @truncate(t.user_stack + sp);
    arg_idx = 1;

    // argv[1..] = 追加引数
    for (args) |arg| {
        if (arg_idx >= 16) break;
        sp -= arg.len + 1;
        @memcpy(stack_base[sp .. sp + arg.len], arg);
        stack_base[sp + arg.len] = 0;
        argv_ptrs[arg_idx] = @truncate(t.user_stack + sp);
        arg_idx += 1;
    }

    // 4バイトアライン
    sp &= ~@as(usize, 3);

    // NULL terminator
    sp -= 4;
    const null_ptr: *u32 = @ptrFromInt(t.user_stack + sp);
    null_ptr.* = 0;

    // argv ポインタ配列 (逆順で積む)
    var j: usize = argc;
    while (j > 0) {
        j -= 1;
        sp -= 4;
        const ptr: *u32 = @ptrFromInt(t.user_stack + sp);
        ptr.* = argv_ptrs[j];
    }
    const argv_addr: u32 = @truncate(t.user_stack + sp);

    // argv ポインタ
    sp -= 4;
    const argv_p: *u32 = @ptrFromInt(t.user_stack + sp);
    argv_p.* = argv_addr;

    // argc
    sp -= 4;
    const argc_p: *u32 = @ptrFromInt(t.user_stack + sp);
    argc_p.* = argc;

    // IRET フレームの User ESP を更新
    const kstack: [*]u32 = @ptrFromInt(t.kernel_esp);
    kstack[11] = @truncate(t.user_stack + sp); // User ESP

    serial.write("[ELF] argc=");
    serial.writeHex(argc);
    serial.write(" sp=0x");
    serial.writeHex(@truncate(t.user_stack + sp));
    serial.write("\n");
}

fn readU16(data: []const u8, off: u32) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readU32(data: []const u8, off: u32) u32 {
    return @as(u32, data[off]) | (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) | (@as(u32, data[off + 3]) << 24);
}
