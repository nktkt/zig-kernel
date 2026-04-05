// Bitmap — 固定サイズビットマップ操作ユーティリティ
// PMM のページフレーム管理、ext2 のブロック/inode ビットマップ等に利用

/// 固定サイズビットマップ (comptime N: ビット数)
pub fn Bitmap(comptime N: usize) type {
    const WORDS = (N + 31) / 32;

    return struct {
        const Self = @This();
        const BitCount = N;

        data: [WORDS]u32,

        /// 全ビットを 0 (空き) で初期化
        pub fn initEmpty() Self {
            return .{ .data = [_]u32{0} ** WORDS };
        }

        /// 全ビットを 1 (使用中) で初期化
        pub fn initFull() Self {
            return .{ .data = [_]u32{0xFFFFFFFF} ** WORDS };
        }

        /// 指定ビットをセット (1 にする)
        pub fn set(self: *Self, bit: usize) void {
            if (bit >= N) return;
            self.data[bit / 32] |= @as(u32, 1) << @truncate(bit % 32);
        }

        /// 指定ビットをクリア (0 にする)
        pub fn clear(self: *Self, bit: usize) void {
            if (bit >= N) return;
            self.data[bit / 32] &= ~(@as(u32, 1) << @truncate(bit % 32));
        }

        /// 指定ビットがセットされているか
        pub fn isSet(self: *const Self, bit: usize) bool {
            if (bit >= N) return false;
            return (self.data[bit / 32] & (@as(u32, 1) << @truncate(bit % 32))) != 0;
        }

        /// 指定ビットをトグル (反転)
        pub fn toggle(self: *Self, bit: usize) void {
            if (bit >= N) return;
            self.data[bit / 32] ^= @as(u32, 1) << @truncate(bit % 32);
        }

        /// 最初の空きビット (0 のビット) を探す
        pub fn findFirstFree(self: *const Self) ?usize {
            for (self.data, 0..) |word, idx| {
                if (word != 0xFFFFFFFF) {
                    var bit: u5 = 0;
                    while (true) : (bit += 1) {
                        if (word & (@as(u32, 1) << bit) == 0) {
                            const result = idx * 32 + bit;
                            if (result >= N) return null;
                            return result;
                        }
                        if (bit == 31) break;
                    }
                }
            }
            return null;
        }

        /// 最初のセット済みビット (1 のビット) を探す
        pub fn findFirstSet(self: *const Self) ?usize {
            for (self.data, 0..) |word, idx| {
                if (word != 0) {
                    var bit: u5 = 0;
                    while (true) : (bit += 1) {
                        if (word & (@as(u32, 1) << bit) != 0) {
                            const result = idx * 32 + bit;
                            if (result >= N) return null;
                            return result;
                        }
                        if (bit == 31) break;
                    }
                }
            }
            return null;
        }

        /// count 個の連続した空きビットを探す
        pub fn findContiguous(self: *const Self, cnt: usize) ?usize {
            if (cnt == 0) return null;
            if (cnt > N) return null;

            var run_start: usize = 0;
            var run_len: usize = 0;

            var i: usize = 0;
            while (i < N) : (i += 1) {
                if (!self.isSet(i)) {
                    if (run_len == 0) run_start = i;
                    run_len += 1;
                    if (run_len >= cnt) return run_start;
                } else {
                    run_len = 0;
                }
            }
            return null;
        }

        /// セット済みビット数をカウント
        pub fn countSet(self: *const Self) usize {
            var total: usize = 0;
            for (self.data) |word| {
                total += popcount(word);
            }
            // 余剰ビットを除外 (N が 32 の倍数でない場合)
            const extra = WORDS * 32 - N;
            if (extra > 0) {
                // 最後のワードの上位ビットは無視
                const last = self.data[WORDS - 1];
                const mask = if (N % 32 == 0) @as(u32, 0xFFFFFFFF) else (@as(u32, 1) << @truncate(N % 32)) -% 1;
                const masked_count = popcount(last & mask);
                total = total - popcount(last) + masked_count;
            }
            return total;
        }

        /// 空きビット数をカウント
        pub fn countFree(self: *const Self) usize {
            return N - self.countSet();
        }

        /// 指定範囲をセット [start, start+cnt)
        pub fn setRange(self: *Self, start: usize, cnt: usize) void {
            var i: usize = 0;
            while (i < cnt) : (i += 1) {
                self.set(start + i);
            }
        }

        /// 指定範囲をクリア [start, start+cnt)
        pub fn clearRange(self: *Self, start: usize, cnt: usize) void {
            var i: usize = 0;
            while (i < cnt) : (i += 1) {
                self.clear(start + i);
            }
        }
    };
}

/// u32 のポピュレーションカウント (セットビット数)
fn popcount(x: u32) usize {
    // Brian Kernighan's algorithm
    var v = x;
    var count: usize = 0;
    while (v != 0) {
        v &= v - 1;
        count += 1;
    }
    return count;
}
