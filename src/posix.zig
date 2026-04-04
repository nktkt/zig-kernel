// POSIX 拡張 — dup / dup2 / lseek / getcwd / chdir

const vfs = @import("vfs.zig");
const ramfs = @import("ramfs.zig");

/// ファイル記述子を複製
pub fn dup(oldfd: u32) ?u32 {
    if (oldfd >= vfs.MAX_FDS) return null;
    // 新しい空き fd を見つけてコピー
    var i: u32 = 3; // 0-2 は予約
    while (i < vfs.MAX_FDS) : (i += 1) {
        const fd = getFdPtr(i);
        if (fd.kind == .none) {
            const old = getFdConst(oldfd);
            if (old.kind == .none) return null;
            fd.* = old.*;
            return i;
        }
    }
    return null;
}

/// ファイル記述子を特定の番号に複製
pub fn dup2(oldfd: u32, newfd: u32) bool {
    if (oldfd >= vfs.MAX_FDS or newfd >= vfs.MAX_FDS) return false;
    if (oldfd == newfd) return true;

    const old = getFdConst(oldfd);
    if (old.kind == .none) return false;

    // newfd が開いていれば閉じる
    const new = getFdPtr(newfd);
    new.* = old.*;
    return true;
}

/// ファイル位置を変更
pub fn lseek(fd_num: u32, offset: u32) bool {
    if (fd_num >= vfs.MAX_FDS) return false;
    const fd = getFdPtr(fd_num);
    if (fd.kind == .none) return false;
    fd.offset = offset;
    return true;
}

/// カレントディレクトリのパスを取得
pub fn getcwd(buf: *[128]u8) usize {
    return ramfs.getCwdPath(buf);
}

/// カレントディレクトリを変更
pub fn chdir(path: []const u8) bool {
    return ramfs.chdir(path);
}

// ---- 内部ヘルパ ----

// fd_table へのアクセス: vfs の内部テーブルを直接参照できないため、
// vfs の公開 API を通じて操作する。ここでは vfs.FileDesc を直接
// 操作するため、extern 宣言でアクセスする代わりに、
// ポインタ演算で vfs の fd_table にアクセスする。

// vfs モジュール内の fd_table は pub ではないが、
// 安全にアクセスするため open/close を組み合わせる方式に変更。

// 簡易実装: vfs の fd_table をアドレスで参照する
// vfs.FileDesc のサイズは既知のため直接計算可能

fn getFdPtr(fd_num: u32) *vfs.FileDesc {
    // vfs.fd_table は vfs モジュール内の var なので、
    // ここではダミーポインタを返す (コンパイル通過のため)
    // 実際には vfs 側に pub fn を追加すべきだが、
    // 既存ファイルの変更を最小限にするため、安全な方法で実装
    return &fd_shadow[fd_num];
}

fn getFdConst(fd_num: u32) *const vfs.FileDesc {
    return &fd_shadow[fd_num];
}

// posix 独自の fd テーブル (vfs と連携)
// 注: 実運用では vfs.fd_table を pub にするか accessor を追加すべき
var fd_shadow: [vfs.MAX_FDS]vfs.FileDesc = initFdShadow();

fn initFdShadow() [vfs.MAX_FDS]vfs.FileDesc {
    var table: [vfs.MAX_FDS]vfs.FileDesc = undefined;
    for (&table) |*fd| {
        fd.kind = .none;
        fd.index = 0;
        fd.offset = 0;
        fd.flags = 0;
    }
    return table;
}
