// Sorting Algorithms -- for u32 arrays
// Provides bubble, insertion, shell, quick, merge, heap sorts
// Plus utility functions: binary search, unique, reverse, min, max, sum, average

const vga = @import("vga.zig");
const serial = @import("serial.zig");

// ---- Sorting Algorithms ----

/// Bubble sort - O(n^2) simple sort with early termination.
pub fn bubbleSort(arr: []u32) void {
    if (arr.len <= 1) return;
    var n = arr.len;
    while (n > 1) {
        var new_n: usize = 0;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (arr[i - 1] > arr[i]) {
                swap(arr, i - 1, i);
                new_n = i;
            }
        }
        n = new_n;
    }
}

/// Insertion sort - O(n^2) efficient for small or nearly-sorted arrays.
pub fn insertionSort(arr: []u32) void {
    if (arr.len <= 1) return;
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        const key = arr[i];
        var j: usize = i;
        while (j > 0 and arr[j - 1] > key) {
            arr[j] = arr[j - 1];
            j -= 1;
        }
        arr[j] = key;
    }
}

/// Shell sort - O(n^1.5) gap-based insertion sort.
/// Uses Knuth's gap sequence: 1, 4, 13, 40, 121, ...
pub fn shellSort(arr: []u32) void {
    if (arr.len <= 1) return;

    // Compute initial gap using Knuth sequence
    var gap: usize = 1;
    while (gap < arr.len / 3) {
        gap = gap * 3 + 1;
    }

    while (gap >= 1) {
        var i: usize = gap;
        while (i < arr.len) : (i += 1) {
            const key = arr[i];
            var j: usize = i;
            while (j >= gap and arr[j - gap] > key) {
                arr[j] = arr[j - gap];
                j -= gap;
            }
            arr[j] = key;
        }
        gap /= 3;
    }
}

/// Quick sort - O(n log n) average, in-place.
/// Uses median-of-three pivot selection.
pub fn quickSort(arr: []u32) void {
    if (arr.len <= 1) return;
    quickSortRange(arr, 0, arr.len - 1);
}

fn quickSortRange(arr: []u32, low_param: usize, high_param: usize) void {
    // Use a manual stack to avoid deep recursion
    var stack: [64]usize = undefined;
    var sp: usize = 0;

    stack[sp] = low_param;
    sp += 1;
    stack[sp] = high_param;
    sp += 1;

    while (sp >= 2) {
        sp -= 1;
        const high = stack[sp];
        sp -= 1;
        const low = stack[sp];

        if (low >= high) continue;

        // For small partitions, use insertion sort
        if (high - low < 10) {
            insertionSortRange(arr, low, high);
            continue;
        }

        const pivot_idx = partition(arr, low, high);

        // Push larger partition first (tail call optimization)
        if (pivot_idx > low) {
            if (pivot_idx >= 1) {
                if (sp + 2 <= stack.len) {
                    stack[sp] = low;
                    sp += 1;
                    stack[sp] = pivot_idx - 1;
                    sp += 1;
                }
            }
        }
        if (pivot_idx + 1 < high) {
            if (sp + 2 <= stack.len) {
                stack[sp] = pivot_idx + 1;
                sp += 1;
                stack[sp] = high;
                sp += 1;
            }
        }
    }
}

fn insertionSortRange(arr: []u32, low: usize, high: usize) void {
    var i: usize = low + 1;
    while (i <= high) : (i += 1) {
        const key = arr[i];
        var j: usize = i;
        while (j > low and arr[j - 1] > key) {
            arr[j] = arr[j - 1];
            j -= 1;
        }
        arr[j] = key;
    }
}

fn partition(arr: []u32, low: usize, high: usize) usize {
    // Median-of-three pivot
    const mid = low + (high - low) / 2;
    if (arr[mid] < arr[low]) swap(arr, low, mid);
    if (arr[high] < arr[low]) swap(arr, low, high);
    if (arr[mid] < arr[high]) swap(arr, mid, high);
    const pivot = arr[high];

    var i: usize = low;
    var j: usize = low;
    while (j < high) : (j += 1) {
        if (arr[j] <= pivot) {
            swap(arr, i, j);
            i += 1;
        }
    }
    swap(arr, i, high);
    return i;
}

/// Merge sort - O(n log n) stable, requires temporary buffer.
/// `tmp` must be at least as large as `arr`.
pub fn mergeSort(arr: []u32, tmp: []u32) void {
    if (arr.len <= 1) return;
    if (tmp.len < arr.len) return; // not enough temp space
    mergeSortRange(arr, tmp, 0, arr.len - 1);
}

fn mergeSortRange(arr: []u32, tmp: []u32, low: usize, high: usize) void {
    if (low >= high) return;

    const mid = low + (high - low) / 2;
    mergeSortRange(arr, tmp, low, mid);
    mergeSortRange(arr, tmp, mid + 1, high);
    mergeHalves(arr, tmp, low, mid, high);
}

fn mergeHalves(arr: []u32, tmp: []u32, low: usize, mid: usize, high: usize) void {
    // Copy to temp
    var k: usize = low;
    while (k <= high) : (k += 1) {
        tmp[k] = arr[k];
    }

    var i: usize = low;
    var j: usize = mid + 1;
    k = low;
    while (i <= mid and j <= high) {
        if (tmp[i] <= tmp[j]) {
            arr[k] = tmp[i];
            i += 1;
        } else {
            arr[k] = tmp[j];
            j += 1;
        }
        k += 1;
    }
    while (i <= mid) {
        arr[k] = tmp[i];
        i += 1;
        k += 1;
    }
    while (j <= high) {
        arr[k] = tmp[j];
        j += 1;
        k += 1;
    }
}

/// Heap sort - O(n log n) in-place, not stable.
pub fn heapSort(arr: []u32) void {
    if (arr.len <= 1) return;
    const n = arr.len;

    // Build max heap
    if (n >= 2) {
        var i: usize = n / 2;
        while (i > 0) {
            i -= 1;
            siftDown(arr, i, n);
        }
    }

    // Extract elements from heap
    var end: usize = n - 1;
    while (end > 0) {
        swap(arr, 0, end);
        siftDown(arr, 0, end);
        end -= 1;
    }
}

fn siftDown(arr: []u32, start: usize, len: usize) void {
    var root = start;
    while (true) {
        const left = 2 * root + 1;
        if (left >= len) break;

        var largest = root;
        if (arr[left] > arr[largest]) {
            largest = left;
        }
        const right = left + 1;
        if (right < len and arr[right] > arr[largest]) {
            largest = right;
        }

        if (largest == root) break;
        swap(arr, root, largest);
        root = largest;
    }
}

// ---- Utility Functions ----

/// Check if array is sorted in ascending order.
pub fn isSorted(arr: []const u32) bool {
    if (arr.len <= 1) return true;
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        if (arr[i] < arr[i - 1]) return false;
    }
    return true;
}

/// Reverse an array in place.
pub fn reverse(arr: []u32) void {
    if (arr.len <= 1) return;
    var left: usize = 0;
    var right: usize = arr.len - 1;
    while (left < right) {
        swap(arr, left, right);
        left += 1;
        right -= 1;
    }
}

/// Binary search in a sorted array. Returns the index of `val`, or null if not found.
pub fn binarySearch(arr: []const u32, val: u32) ?usize {
    if (arr.len == 0) return null;
    var low: usize = 0;
    var high: usize = arr.len - 1;

    while (low <= high) {
        const mid = low + (high - low) / 2;
        if (arr[mid] == val) return mid;
        if (arr[mid] < val) {
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    return null;
}

/// Remove duplicates from a sorted array in-place.
/// Returns the new logical length.
pub fn unique(arr: []u32) usize {
    if (arr.len <= 1) return arr.len;
    var write_pos: usize = 1;
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        if (arr[i] != arr[write_pos - 1]) {
            arr[write_pos] = arr[i];
            write_pos += 1;
        }
    }
    return write_pos;
}

/// Find the minimum value in an array.
pub fn min(arr: []const u32) u32 {
    if (arr.len == 0) return 0;
    var result = arr[0];
    for (arr[1..]) |v| {
        if (v < result) result = v;
    }
    return result;
}

/// Find the maximum value in an array.
pub fn max(arr: []const u32) u32 {
    if (arr.len == 0) return 0;
    var result = arr[0];
    for (arr[1..]) |v| {
        if (v > result) result = v;
    }
    return result;
}

/// Compute the sum of all elements (u64 to avoid overflow).
pub fn sum(arr: []const u32) u64 {
    var total: u64 = 0;
    for (arr) |v| {
        total += v;
    }
    return total;
}

/// Compute the average of all elements.
pub fn average(arr: []const u32) u32 {
    if (arr.len == 0) return 0;
    return @truncate(sum(arr) / arr.len);
}

// ---- Helpers ----

fn swap(arr: []u32, a: usize, b: usize) void {
    const tmp = arr[a];
    arr[a] = arr[b];
    arr[b] = tmp;
}

// ---- Display ----

/// Print the first n elements of an array (max 20 for readability).
pub fn printArray(arr: []const u32) void {
    const limit = if (arr.len > 20) @as(usize, 20) else arr.len;
    vga.putChar('[');
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (i > 0) vga.write(", ");
        printDec(arr[i]);
    }
    if (arr.len > 20) vga.write(", ...");
    vga.putChar(']');
}

/// Print sorting statistics.
pub fn printStats(arr: []const u32) void {
    vga.write("Array: len=");
    printDecUsize(arr.len);
    vga.write(" min=");
    printDec(min(arr));
    vga.write(" max=");
    printDec(max(arr));
    vga.write(" avg=");
    printDec(average(arr));
    vga.write(" sorted=");
    if (isSorted(arr)) vga.write("yes") else vga.write("no");
    vga.putChar('\n');
}

fn printDec(n: u32) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDecUsize(n: usize) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + val % 10);
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}
