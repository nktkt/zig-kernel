// 仮想メモリマネージャ — プロセスごとのページテーブル管理

const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

const PAGE_SIZE = 4096;
const ENTRIES = 1024;

// ページテーブルフラグ
pub const PF_PRESENT: u32 = 1 << 0;
pub const PF_WRITABLE: u32 = 1 << 1;
pub const PF_USER: u32 = 1 << 2;
pub const PF_PS: u32 = 1 << 7; // 4MB page (PSE)

// カーネルは 0-132MB を identity map (全プロセスで共有)
const KERNEL_PD_ENTRIES = 33; // 33 * 4MB = 132MB

/// 新しいページディレクトリを作成 (カーネルマッピングをコピー)
pub fn createAddressSpace() ?u32 {
    const pd_phys = pmm.alloc() orelse return null;
    const pd: [*]u32 = @ptrFromInt(pd_phys);

    // ゼロ初期化
    for (0..ENTRIES) |i| {
        pd[i] = 0;
    }

    // カーネル領域をコピー (0-132MB, PSE 4MB pages)
    // 最初の 4MB は 4KB ページテーブル経由 (VGA等のため)
    const current_pd = getCurrentPD();
    for (0..KERNEL_PD_ENTRIES) |i| {
        pd[i] = current_pd[i];
    }

    // 高位アドレス (MMIO等) もコピー
    for (KERNEL_PD_ENTRIES..ENTRIES) |i| {
        if (current_pd[i] & PF_PRESENT != 0) {
            pd[i] = current_pd[i];
        }
    }

    return pd_phys;
}

/// ユーザー空間にページをマップ
pub fn mapUserPage(pd_phys: u32, virt: u32, phys: u32) bool {
    const pd: [*]u32 = @ptrFromInt(pd_phys);
    const pd_idx = virt >> 22;
    const pt_idx = (virt >> 12) & 0x3FF;

    // ページテーブルがなければ作成
    if (pd[pd_idx] & PF_PRESENT == 0) {
        const pt_phys = pmm.alloc() orelse return false;
        const pt: [*]u32 = @ptrFromInt(pt_phys);
        for (0..ENTRIES) |i| {
            pt[i] = 0;
        }
        pd[pd_idx] = pt_phys | PF_PRESENT | PF_WRITABLE | PF_USER;
    }

    // PSE (4MB page) の場合はスキップ
    if (pd[pd_idx] & PF_PS != 0) return false;

    const pt: [*]u32 = @ptrFromInt(pd[pd_idx] & 0xFFFFF000);
    pt[pt_idx] = phys | PF_PRESENT | PF_WRITABLE | PF_USER;
    return true;
}

/// ユーザー空間のページをアンマップ
pub fn unmapUserPage(pd_phys: u32, virt: u32) void {
    const pd: [*]u32 = @ptrFromInt(pd_phys);
    const pd_idx = virt >> 22;
    if (pd[pd_idx] & PF_PRESENT == 0) return;
    if (pd[pd_idx] & PF_PS != 0) return;

    const pt: [*]u32 = @ptrFromInt(pd[pd_idx] & 0xFFFFF000);
    const pt_idx = (virt >> 12) & 0x3FF;
    pt[pt_idx] = 0;
}

/// ページディレクトリを複製 (fork用: ユーザー空間のみコピー)
pub fn cloneAddressSpace(src_pd_phys: u32) ?u32 {
    const new_pd_phys = createAddressSpace() orelse return null;
    const src_pd: [*]u32 = @ptrFromInt(src_pd_phys);
    const new_pd: [*]u32 = @ptrFromInt(new_pd_phys);

    // カーネル領域 (0-132MB) は既に createAddressSpace でコピー済み
    // ユーザー空間のページテーブルを複製
    for (KERNEL_PD_ENTRIES..ENTRIES) |i| {
        if (src_pd[i] & PF_PRESENT == 0) continue;
        if (src_pd[i] & PF_PS != 0) {
            // 4MB page はそのままコピー (MMIO等)
            new_pd[i] = src_pd[i];
            continue;
        }

        // 4KB ページテーブル: 新しい PT を割り当ててコピー
        const new_pt_phys = pmm.alloc() orelse {
            freeAddressSpace(new_pd_phys);
            return null;
        };
        const src_pt: [*]u32 = @ptrFromInt(src_pd[i] & 0xFFFFF000);
        const new_pt: [*]u32 = @ptrFromInt(new_pt_phys);

        for (0..ENTRIES) |j| {
            if (src_pt[j] & PF_PRESENT == 0) {
                new_pt[j] = 0;
                continue;
            }
            // ページデータをコピー
            const src_page = src_pt[j] & 0xFFFFF000;
            const dst_page = pmm.alloc() orelse {
                freeAddressSpace(new_pd_phys);
                return null;
            };
            copyPage(dst_page, src_page);
            new_pt[j] = dst_page | (src_pt[j] & 0xFFF); // フラグ保持
        }
        new_pd[i] = new_pt_phys | (src_pd[i] & 0xFFF);
    }

    return new_pd_phys;
}

/// アドレス空間を解放 (ユーザー空間のみ)
pub fn freeAddressSpace(pd_phys: u32) void {
    const pd: [*]u32 = @ptrFromInt(pd_phys);

    for (KERNEL_PD_ENTRIES..ENTRIES) |i| {
        if (pd[i] & PF_PRESENT == 0) continue;
        if (pd[i] & PF_PS != 0) continue; // 4MB pages (MMIO) は解放しない

        const pt: [*]u32 = @ptrFromInt(pd[i] & 0xFFFFF000);
        for (0..ENTRIES) |j| {
            if (pt[j] & PF_PRESENT != 0) {
                pmm.free(pt[j] & 0xFFFFF000);
            }
        }
        pmm.free(pd[i] & 0xFFFFF000); // ページテーブル自体を解放
    }
    pmm.free(pd_phys); // ページディレクトリを解放
}

/// CR3 を切り替え
pub fn switchTo(pd_phys: u32) void {
    asm volatile ("mov %[pd], %%cr3"
        :
        : [pd] "r" (pd_phys),
    );
}

/// 現在のページディレクトリの物理アドレスを取得
pub fn getCR3() u32 {
    return asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (-> u32),
    );
}

fn getCurrentPD() [*]u32 {
    return @ptrFromInt(getCR3());
}

fn copyPage(dst: u32, src: u32) void {
    const d: [*]u8 = @ptrFromInt(dst);
    const s: [*]const u8 = @ptrFromInt(src);
    @memcpy(d[0..PAGE_SIZE], s[0..PAGE_SIZE]);
}

/// ユーザー空間用のページを割り当ててマップ
pub fn allocAndMap(pd_phys: u32, virt: u32) ?u32 {
    const phys = pmm.alloc() orelse return null;
    // ゼロ初期化
    const ptr: [*]u8 = @ptrFromInt(phys);
    @memset(ptr[0..PAGE_SIZE], 0);
    if (!mapUserPage(pd_phys, virt, phys)) {
        pmm.free(phys);
        return null;
    }
    return phys;
}
