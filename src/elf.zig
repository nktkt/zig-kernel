// ELF32 ローダー — RAM FS から実行可能ファイルをロードして実行

const ramfs = @import("ramfs.zig");
const task = @import("task.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

// ELF32 ヘッダ
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

pub fn exec(name: []const u8) bool {
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

    // ELF32 チェック
    if (data[4] != 1) { // 32-bit
        vga.setColor(.light_red, .black);
        vga.write("Not ELF32\n");
        return false;
    }

    // エントリポイント取得 (offset 24, 4 bytes LE)
    const entry = readU32(data, 24);

    serial.write("[ELF] entry=0x");
    serial.writeHex(entry);
    serial.write("\n");

    // プログラムヘッダ解析・ロード
    const ph_off = readU32(data, 28); // e_phoff
    const ph_size = readU16(data, 42); // e_phentsize
    const ph_num = readU16(data, 44); // e_phnum

    var loaded = false;
    var i: u16 = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + @as(u32, i) * ph_size;
        if (off + ph_size > data.len) break;

        const p_type = readU32(data, off);
        if (p_type != 1) continue; // PT_LOAD のみ

        const p_offset = readU32(data, off + 4);
        const p_vaddr = readU32(data, off + 8);
        const p_filesz = readU32(data, off + 16);

        // データをロード先にコピー (identity mapping 前提)
        if (p_vaddr >= 0x100000 and p_vaddr + p_filesz < 0x8000000) {
            if (p_offset + p_filesz <= data.len) {
                const dst: [*]u8 = @ptrFromInt(p_vaddr);
                const src = data[p_offset .. p_offset + p_filesz];
                @memcpy(dst[0..p_filesz], src);
                loaded = true;
            }
        }
    }

    if (!loaded) {
        // PT_LOAD がない場合、エントリポイントが直接カーネル内関数の可能性
        // (組み込みプログラムとして扱う)
    }

    // ユーザータスクとして生成
    if (task.createUserTask(entry, name)) |pid| {
        vga.setColor(.light_green, .black);
        vga.write("Loaded '");
        vga.write(name);
        vga.write("' (pid=");
        pmm.printNum(pid);
        vga.write(")\n");
        task.enableScheduling();
        return true;
    } else {
        vga.setColor(.light_red, .black);
        vga.write("Failed to create task\n");
        return false;
    }
}

fn readU16(data: []const u8, off: u32) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readU32(data: []const u8, off: u32) u32 {
    return @as(u32, data[off]) | (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) | (@as(u32, data[off + 3]) << 24);
}
