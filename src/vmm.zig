// 仮想メモリマネージャ — 64-bit プロセスごとのページテーブル管理

const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

const PAGE_SIZE = 4096;
const ENTRIES = 512;

// ページテーブルフラグ
pub const PF_PRESENT: u64 = 1 << 0;
pub const PF_WRITABLE: u64 = 1 << 1;
pub const PF_USER: u64 = 1 << 2;
pub const PF_PS: u64 = 1 << 7; // 2MB page

// カーネルは 0-4GB を identity map (全プロセスで共有)
const KERNEL_PDPT_ENTRIES = 4; // 4 * 1GB = 4GB

/// 新しいPML4を作成 (カーネルマッピングをコピー)
pub fn createAddressSpace() ?u64 {
    const pml4_phys = pmm.alloc() orelse return null;
    const pml4: [*]u64 = @ptrFromInt(pml4_phys);

    // ゼロ初期化
    for (0..ENTRIES) |i| {
        pml4[i] = 0;
    }

    // カーネル領域をコピー (PML4[0] etc from current)
    const current_pml4 = getCurrentPD();
    for (0..ENTRIES) |i| {
        if (current_pml4[i] & PF_PRESENT != 0) {
            pml4[i] = current_pml4[i];
        }
    }

    return @intCast(pml4_phys);
}

/// ユーザー空間にページをマップ (simplified for now)
pub fn mapUserPage(pd_phys: u64, virt: u64, phys: u64) bool {
    _ = pd_phys;
    _ = virt;
    _ = phys;
    // TODO: implement 4-level page walk for user space
    return false;
}

/// ユーザー空間のページをアンマップ
pub fn unmapUserPage(pd_phys: u64, virt: u64) void {
    _ = pd_phys;
    _ = virt;
    // TODO: implement 4-level page walk for user space
}

/// ページディレクトリを複製 (fork用)
pub fn cloneAddressSpace(src_pd_phys: u64) ?u64 {
    _ = src_pd_phys;
    // For now, just create a new address space sharing kernel mappings
    return createAddressSpace() orelse return null;
}

/// アドレス空間を解放
pub fn freeAddressSpace(pd_phys: u64) void {
    pmm.free(@intCast(pd_phys));
}

/// CR3 を切り替え
pub fn switchTo(pd_phys: u64) void {
    asm volatile ("mov %[pd], %%cr3"
        :
        : [pd] "r" (pd_phys),
    );
}

/// 現在のPML4の物理アドレスを取得
pub fn getCR3() u64 {
    return asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (-> u64),
    );
}

fn getCurrentPD() [*]u64 {
    return @ptrFromInt(@as(usize, @truncate(getCR3())));
}

fn copyPage(dst: u64, src: u64) void {
    const d: [*]u8 = @ptrFromInt(@as(usize, @truncate(dst)));
    const s: [*]const u8 = @ptrFromInt(@as(usize, @truncate(src)));
    @memcpy(d[0..PAGE_SIZE], s[0..PAGE_SIZE]);
}

/// ユーザー空間用のページを割り当ててマップ
pub fn allocAndMap(pd_phys: u64, virt: u64) ?u64 {
    const phys = pmm.alloc() orelse return null;
    // ゼロ初期化
    const ptr: [*]u8 = @ptrFromInt(phys);
    @memset(ptr[0..PAGE_SIZE], 0);
    if (!mapUserPage(pd_phys, virt, @intCast(phys))) {
        pmm.free(phys);
        return null;
    }
    return @intCast(phys);
}
