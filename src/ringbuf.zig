// Generic Ring Buffer — 固定サイズ循環バッファ (型安全・コンパイル時サイズ決定)

/// 固定容量の循環バッファ。キーボード入力、パイプ、ログ等に汎用的に利用可能。
/// comptime T: 要素の型, comptime N: 最大要素数
pub fn RingBuffer(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();
        const Capacity = N;

        buf: [N]T = undefined,
        head: usize = 0, // 次に読む位置
        tail: usize = 0, // 次に書く位置
        len: usize = 0,

        /// 要素を末尾に追加する。バッファが満杯なら最も古い要素を上書きする。
        pub fn push(self: *Self, item: T) void {
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % N;
            if (self.len == N) {
                // 満杯 → head を進めて最古の要素を捨てる
                self.head = (self.head + 1) % N;
            } else {
                self.len += 1;
            }
        }

        /// 要素を末尾に追加する。バッファが満杯なら false を返し追加しない。
        pub fn tryPush(self: *Self, item: T) bool {
            if (self.len == N) return false;
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % N;
            self.len += 1;
            return true;
        }

        /// 先頭から要素を取り出す。空なら null を返す。
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % N;
            self.len -= 1;
            return item;
        }

        /// 先頭の要素を参照する (取り出さない)。空なら null。
        pub fn peek(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.buf[self.head];
        }

        /// バッファが満杯かどうか
        pub fn isFull(self: *const Self) bool {
            return self.len == N;
        }

        /// バッファが空かどうか
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// 現在の要素数
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// バッファの残り容量
        pub fn remaining(self: *const Self) usize {
            return N - self.len;
        }

        /// バッファをクリアする (要素数を 0 にリセット)
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }

        /// バッファの内容をスライスとしてコピーする (最大 out.len 要素)
        /// 返り値: 実際にコピーした要素数
        pub fn copyTo(self: *const Self, out: []T) usize {
            const to_copy = if (out.len < self.len) out.len else self.len;
            var i: usize = 0;
            while (i < to_copy) : (i += 1) {
                out[i] = self.buf[(self.head + i) % N];
            }
            return to_copy;
        }

        /// capacity (コンパイル時定数)
        pub fn capacity(_: *const Self) usize {
            return N;
        }
    };
}
