// Lottery scheduler — ticket-based probabilistic scheduling
//
// Each task holds tickets; the scheduler draws a random ticket to select
// the next task to run. More tickets = higher probability of being scheduled.
// Supports ticket transfer between tasks, inflation/deflation, and
// probability display.

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const serial = @import("serial.zig");

// ---- Constants ----

pub const MAX_LOTTERY_TASKS = 16;
const DEFAULT_TICKETS = 100;
const MIN_TICKETS = 1;
const MAX_TICKETS_PER_TASK = 10000;

// ---- Task entry ----

pub const LotteryTask = struct {
    active: bool,
    pid: u32,
    tickets: u32,
    original_tickets: u32, // before inflation/deflation
    wins: u64, // times this task won the lottery
    total_ticks: u64, // total CPU ticks consumed
};

// ---- Statistics ----

pub const LotteryStats = struct {
    total_tasks: u32,
    total_tickets: u32,
    total_draws: u64,
    active_tasks: u32,
};

// ---- State ----

var tasks: [MAX_LOTTERY_TASKS]LotteryTask = undefined;
var task_count: u32 = 0;
var total_tickets: u32 = 0;
var total_draws: u64 = 0;
var rng_state: u32 = 0xDEADBEEF;
var initialized: bool = false;

// ---- Simple PRNG (Xorshift32 for ticket drawing) ----

fn xorshift() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn randomRange(max: u32) u32 {
    if (max == 0) return 0;
    return xorshift() % max;
}

// ---- Initialization ----

pub fn init() void {
    for (&tasks) |*t| {
        t.active = false;
        t.pid = 0;
        t.tickets = 0;
        t.original_tickets = 0;
        t.wins = 0;
        t.total_ticks = 0;
    }
    task_count = 0;
    total_tickets = 0;
    total_draws = 0;

    // Seed RNG from PIT ticks
    rng_state = @as(u32, @truncate(pit.getTicks())) ^ 0xCAFEBABE;
    if (rng_state == 0) rng_state = 1;

    initialized = true;
    serial.write("[lottery] Lottery scheduler initialized\n");
}

// ---- Task management ----

/// Add a task with the given number of tickets.
pub fn addTask(pid: u32, tickets: u32) bool {
    if (!initialized) return false;

    // Clamp tickets
    const t_count = if (tickets < MIN_TICKETS) MIN_TICKETS else if (tickets > MAX_TICKETS_PER_TASK) MAX_TICKETS_PER_TASK else tickets;

    // Check if already exists
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) return false;
    }

    // Find free slot
    var slot: ?usize = null;
    for (&tasks, 0..) |*t, i| {
        if (!t.active) {
            slot = i;
            break;
        }
    }
    const s = slot orelse return false;

    tasks[s] = .{
        .active = true,
        .pid = pid,
        .tickets = t_count,
        .original_tickets = t_count,
        .wins = 0,
        .total_ticks = 0,
    };

    task_count += 1;
    total_tickets += t_count;

    serial.write("[lottery] added pid=");
    serialDec(pid);
    serial.write(" tickets=");
    serialDec(t_count);
    serial.write(" total=");
    serialDec(total_tickets);
    serial.write("\n");

    return true;
}

/// Remove a task from the lottery.
pub fn removeTask(pid: u32) bool {
    if (!initialized) return false;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            total_tickets -= t.tickets;
            t.active = false;
            task_count -= 1;
            return true;
        }
    }
    return false;
}

// ---- Scheduling ----

/// Draw a random ticket and return the winning task's PID.
pub fn drawWinner() ?u32 {
    if (!initialized or total_tickets == 0 or task_count == 0) return null;

    total_draws += 1;

    // Draw a random ticket number in [0, total_tickets)
    const winning_ticket = randomRange(total_tickets);

    // Walk through tasks, accumulating tickets, to find the winner
    var counter: u32 = 0;
    for (&tasks) |*t| {
        if (!t.active) continue;
        counter += t.tickets;
        if (counter > winning_ticket) {
            t.wins += 1;
            t.total_ticks += 1;
            return t.pid;
        }
    }

    // Fallback: return first active task (shouldn't happen if tickets are correct)
    for (&tasks) |*t| {
        if (t.active) {
            t.wins += 1;
            t.total_ticks += 1;
            return t.pid;
        }
    }
    return null;
}

// ---- Ticket management ----

/// Set the ticket count for a task.
pub fn setTickets(pid: u32, tickets: u32) bool {
    if (!initialized) return false;
    const t_count = if (tickets < MIN_TICKETS) MIN_TICKETS else if (tickets > MAX_TICKETS_PER_TASK) MAX_TICKETS_PER_TASK else tickets;

    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            total_tickets = total_tickets - t.tickets + t_count;
            t.tickets = t_count;
            t.original_tickets = t_count;
            return true;
        }
    }
    return false;
}

/// Get the ticket count for a task.
pub fn getTickets(pid: u32) ?u32 {
    if (!initialized) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return t.tickets;
        }
    }
    return null;
}

/// Transfer tickets from one task to another.
pub fn transferTickets(from_pid: u32, to_pid: u32, count: u32) bool {
    if (!initialized) return false;

    var from_task: ?*LotteryTask = null;
    var to_task: ?*LotteryTask = null;

    for (&tasks) |*t| {
        if (t.active and t.pid == from_pid) from_task = t;
        if (t.active and t.pid == to_pid) to_task = t;
    }

    const ft = from_task orelse return false;
    const tt = to_task orelse return false;

    // Can't transfer more than we have (keep at least MIN_TICKETS)
    const max_transfer = if (ft.tickets > MIN_TICKETS) ft.tickets - MIN_TICKETS else 0;
    const actual = if (count > max_transfer) max_transfer else count;
    if (actual == 0) return false;

    ft.tickets -= actual;
    tt.tickets += actual;

    // Total tickets doesn't change in a transfer
    serial.write("[lottery] transfer ");
    serialDec(actual);
    serial.write(" tickets from pid=");
    serialDec(from_pid);
    serial.write(" to pid=");
    serialDec(to_pid);
    serial.write("\n");

    return true;
}

// ---- Currency operations (inflation/deflation) ----

/// Inflate all ticket counts by a factor (multiply by numerator/denominator).
/// Example: inflate(3, 2) multiplies all tickets by 1.5x.
pub fn inflate(numerator: u32, denominator: u32) void {
    if (!initialized or denominator == 0) return;

    total_tickets = 0;
    for (&tasks) |*t| {
        if (!t.active) continue;
        const new_tickets = (t.tickets * numerator) / denominator;
        t.tickets = if (new_tickets < MIN_TICKETS) MIN_TICKETS else if (new_tickets > MAX_TICKETS_PER_TASK) MAX_TICKETS_PER_TASK else new_tickets;
        total_tickets += t.tickets;
    }
}

/// Deflate all ticket counts (divide by factor).
pub fn deflate(numerator: u32, denominator: u32) void {
    if (!initialized or numerator == 0) return;

    total_tickets = 0;
    for (&tasks) |*t| {
        if (!t.active) continue;
        const new_tickets = (t.tickets * denominator) / numerator;
        t.tickets = if (new_tickets < MIN_TICKETS) MIN_TICKETS else new_tickets;
        total_tickets += t.tickets;
    }
}

/// Reset all tickets to their original values.
pub fn resetTickets() void {
    if (!initialized) return;
    total_tickets = 0;
    for (&tasks) |*t| {
        if (!t.active) continue;
        t.tickets = t.original_tickets;
        total_tickets += t.tickets;
    }
}

// ---- Queries ----

/// Get statistics.
pub fn getStats() LotteryStats {
    var active: u32 = 0;
    for (&tasks) |*t| {
        if (t.active) active += 1;
    }
    return .{
        .total_tasks = task_count,
        .total_tickets = total_tickets,
        .total_draws = total_draws,
        .active_tasks = active,
    };
}

/// Get win probability for a task (as percent * 100, i.e., 5000 = 50.00%).
pub fn getWinProbability(pid: u32) ?u32 {
    if (!initialized or total_tickets == 0) return null;
    for (&tasks) |*t| {
        if (t.active and t.pid == pid) {
            return (t.tickets * 10000) / total_tickets;
        }
    }
    return null;
}

/// Get total tickets.
pub fn getTotalTickets() u32 {
    return total_tickets;
}

/// Check if initialized.
pub fn isInitialized() bool {
    return initialized;
}

// ---- Display ----

/// Print all tasks with ticket counts and probabilities.
pub fn printLottery() void {
    if (!initialized) {
        vga.write("Lottery scheduler not initialized.\n");
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("=== Lottery Scheduler ===\n");
    vga.setColor(.yellow, .black);
    vga.write("  PID  TICKETS  PROB%    WINS       TICKS      ORIGINAL\n");
    vga.setColor(.light_grey, .black);

    var any = false;
    for (&tasks) |*t| {
        if (!t.active) continue;
        any = true;

        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.pid), 4);
        vga.write("  ");
        fmt.printDecPadded(@as(usize, t.tickets), 7);
        vga.write("  ");

        // Probability
        if (total_tickets > 0) {
            const prob = (t.tickets * 10000) / total_tickets;
            printPercent(prob);
        } else {
            vga.write("  0.00%");
        }
        vga.write("  ");

        // Wins
        printDec64Padded(t.wins, 9);
        vga.write("  ");

        // Ticks
        printDec64Padded(t.total_ticks, 9);
        vga.write("  ");

        // Original tickets
        fmt.printDecPadded(@as(usize, t.original_tickets), 8);

        vga.putChar('\n');
    }

    if (!any) {
        vga.setColor(.dark_grey, .black);
        vga.write("  (no tasks registered)\n");
    }

    // Summary
    vga.setColor(.light_cyan, .black);
    vga.write("\nTotal tickets: ");
    vga.setColor(.white, .black);
    fmt.printDec(@as(usize, total_tickets));
    vga.setColor(.light_grey, .black);
    vga.write("  Total draws: ");
    printDec64(total_draws);
    vga.write("  Tasks: ");
    fmt.printDec(@as(usize, task_count));
    vga.putChar('\n');

    // Visual ticket distribution
    if (task_count > 0 and total_tickets > 0) {
        vga.setColor(.light_cyan, .black);
        vga.write("\nTicket distribution:\n");

        for (&tasks) |*t| {
            if (!t.active) continue;
            vga.setColor(.dark_grey, .black);
            vga.write("  PID ");
            fmt.printDecPadded(@as(usize, t.pid), 3);
            vga.write(": ");
            vga.setColor(.light_green, .black);
            fmt.printBar(@as(usize, t.tickets), @as(usize, total_tickets), 40);
            vga.setColor(.light_grey, .black);
            vga.write(" ");
            fmt.printDec(@as(usize, t.tickets));
            vga.putChar('\n');
        }
    }
}

/// Print compact task list.
pub fn printCompact() void {
    if (!initialized) return;

    vga.setColor(.light_grey, .black);
    for (&tasks) |*t| {
        if (!t.active) continue;
        vga.write("PID ");
        fmt.printDec(@as(usize, t.pid));
        vga.write(": ");
        fmt.printDec(@as(usize, t.tickets));
        vga.write(" tickets (");
        if (total_tickets > 0) {
            const prob = (t.tickets * 100) / total_tickets;
            fmt.printDec(@as(usize, prob));
        } else {
            vga.write("0");
        }
        vga.write("%)\n");
    }
}

// ---- Helpers ----

/// Print percent from fixed-point value (10000 = 100.00%).
fn printPercent(val: u32) void {
    const integer = val / 100;
    const frac = val % 100;
    fmt.printDecPadded(@as(usize, integer), 3);
    vga.putChar('.');
    if (frac < 10) vga.putChar('0');
    fmt.printDec(@as(usize, frac));
    vga.putChar('%');
}

fn printDec64(n: u64) void {
    if (n == 0) {
        vga.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        vga.putChar(buf[len]);
    }
}

fn printDec64Padded(n: u64, width: usize) void {
    var digits: usize = 0;
    var tmp = n;
    if (tmp == 0) {
        digits = 1;
    } else {
        while (tmp > 0) {
            digits += 1;
            tmp /= 10;
        }
    }
    if (digits < width) {
        var pad = width - digits;
        while (pad > 0) : (pad -= 1) vga.putChar(' ');
    }
    printDec64(n);
}

fn serialDec(n: u32) void {
    if (n == 0) {
        serial.putChar('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var val = n;
    while (val > 0) {
        buf[len] = @truncate('0' + @as(u8, @truncate(val % 10)));
        len += 1;
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        serial.putChar(buf[len]);
    }
}
