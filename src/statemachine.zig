// State Machine — 有限状態機械フレームワーク
// 最大 16 状態, 32 遷移, イベント駆動
// enter/exit/update コールバック, ガード関数付き遷移

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const serial = @import("serial.zig");

// ---- 定数 ----

pub const MAX_STATES = 16;
pub const MAX_TRANSITIONS = 32;
pub const MAX_MACHINES = 4;
pub const NAME_LEN = 16;

// ---- イベント ----

pub const Event = enum(u8) {
    none = 0,
    start = 1,
    stop = 2,
    pause = 3,
    resume_event = 4,
    timeout = 5,
    error_event = 6,
    reset = 7,
    ack = 8,
    nack = 9,
    data_ready = 10,
    complete = 11,
    // ネットワーク関連
    syn = 12,
    syn_ack = 13,
    fin = 14,
    fin_ack = 15,
    // 信号機
    timer = 16,
    emergency = 17,
    // ユーザー定義
    user0 = 20,
    user1 = 21,
    user2 = 22,
    user3 = 23,
    _,
};

// ---- コールバック型 ----

pub const StateCallback = *const fn (sm_id: u8, state_id: u8) void;
pub const GuardFn = *const fn (sm_id: u8, event: Event) bool;

// ---- State 定義 ----

pub const State = struct {
    id: u8 = 0,
    name: [NAME_LEN]u8 = [_]u8{0} ** NAME_LEN,
    name_len: u8 = 0,
    enter_fn: ?StateCallback = null,
    exit_fn: ?StateCallback = null,
    update_fn: ?StateCallback = null,
    active: bool = false,
};

// ---- Transition 定義 ----

pub const Transition = struct {
    from_state: u8 = 0,
    to_state: u8 = 0,
    event: Event = .none,
    guard_fn: ?GuardFn = null,
    active: bool = false,
};

// ---- State Machine ----

pub const StateMachine = struct {
    name: [NAME_LEN]u8 = [_]u8{0} ** NAME_LEN,
    name_len: u8 = 0,
    states: [MAX_STATES]State = [_]State{.{}} ** MAX_STATES,
    transitions: [MAX_TRANSITIONS]Transition = [_]Transition{.{}} ** MAX_TRANSITIONS,
    state_count: u8 = 0,
    transition_count: u8 = 0,
    current_state: u8 = 0,
    active: bool = false,
    total_transitions: u32 = 0, // 統計
    history: [16]u8 = @splat(0xFF), // 状態遷移履歴
    history_len: u8 = 0,

    /// 状態を追加
    pub fn addState(
        self: *StateMachine,
        id: u8,
        name: []const u8,
        enter: ?StateCallback,
        exit_cb: ?StateCallback,
        update_cb: ?StateCallback,
    ) bool {
        if (id >= MAX_STATES) return false;
        if (self.states[id].active) return false;

        self.states[id].id = id;
        self.states[id].active = true;
        self.states[id].enter_fn = enter;
        self.states[id].exit_fn = exit_cb;
        self.states[id].update_fn = update_cb;

        const len = if (name.len > NAME_LEN) NAME_LEN else name.len;
        for (0..len) |i| {
            self.states[id].name[i] = name[i];
        }
        self.states[id].name_len = @truncate(len);
        self.state_count += 1;
        return true;
    }

    /// 遷移を追加
    pub fn addTransition(
        self: *StateMachine,
        from: u8,
        to: u8,
        event: Event,
        guard: ?GuardFn,
    ) bool {
        if (self.transition_count >= MAX_TRANSITIONS) return false;
        if (!self.states[from].active or !self.states[to].active) return false;

        const idx = self.transition_count;
        self.transitions[idx] = .{
            .from_state = from,
            .to_state = to,
            .event = event,
            .guard_fn = guard,
            .active = true,
        };
        self.transition_count += 1;
        return true;
    }

    /// イベントを処理
    pub fn processEvent(self: *StateMachine, sm_id: u8, event: Event) bool {
        // 一致する遷移を検索
        for (0..self.transition_count) |i| {
            const t = &self.transitions[i];
            if (!t.active) continue;
            if (t.from_state != self.current_state) continue;
            if (t.event != event) continue;

            // ガード関数チェック
            if (t.guard_fn) |guard| {
                if (!guard(sm_id, event)) continue;
            }

            // 遷移実行
            const old_state = self.current_state;
            const new_state = t.to_state;

            // exit コールバック
            if (self.states[old_state].exit_fn) |exit_fn| {
                exit_fn(sm_id, old_state);
            }

            // 状態変更
            self.current_state = new_state;

            // 履歴記録
            if (self.history_len < 16) {
                self.history[self.history_len] = new_state;
                self.history_len += 1;
            }
            self.total_transitions += 1;

            // enter コールバック
            if (self.states[new_state].enter_fn) |enter_fn| {
                enter_fn(sm_id, new_state);
            }

            return true;
        }
        return false; // 遷移なし
    }

    /// 現在の状態 ID
    pub fn getCurrentState(self: *const StateMachine) u8 {
        return self.current_state;
    }

    /// 現在の状態名
    pub fn getCurrentStateName(self: *const StateMachine) []const u8 {
        const s = &self.states[self.current_state];
        return s.name[0..s.name_len];
    }

    /// update コールバックを呼び出す
    pub fn update(self: *StateMachine, sm_id: u8) void {
        if (self.states[self.current_state].update_fn) |update_fn| {
            update_fn(sm_id, self.current_state);
        }
    }

    /// 状態機械を表示
    pub fn printStateMachine(self: *const StateMachine) void {
        vga.setColor(.yellow, .black);
        vga.write("StateMachine '");
        vga.write(self.name[0..self.name_len]);
        vga.write("' (");
        fmt.printDec(self.state_count);
        vga.write(" states, ");
        fmt.printDec(self.transition_count);
        vga.write(" transitions):\n");
        vga.setColor(.light_grey, .black);

        // 現在の状態
        vga.write("  Current: ");
        vga.setColor(.light_green, .black);
        vga.write(self.states[self.current_state].name[0..self.states[self.current_state].name_len]);
        vga.setColor(.light_grey, .black);
        vga.write(" (id=");
        fmt.printDec(self.current_state);
        vga.write(")\n");

        // 状態一覧
        vga.write("  States:\n");
        for (0..MAX_STATES) |i| {
            if (!self.states[i].active) continue;
            vga.write("    [");
            fmt.printDec(i);
            vga.write("] ");
            vga.write(self.states[i].name[0..self.states[i].name_len]);
            if (i == self.current_state) {
                vga.setColor(.light_green, .black);
                vga.write(" <-- current");
                vga.setColor(.light_grey, .black);
            }
            vga.putChar('\n');
        }

        // 遷移一覧
        vga.write("  Transitions:\n");
        for (0..self.transition_count) |i| {
            const t = &self.transitions[i];
            if (!t.active) continue;
            vga.write("    ");
            vga.write(self.states[t.from_state].name[0..self.states[t.from_state].name_len]);
            vga.write(" --[");
            printEventName(t.event);
            vga.write("]--> ");
            vga.write(self.states[t.to_state].name[0..self.states[t.to_state].name_len]);
            if (t.guard_fn != null) vga.write(" (guarded)");
            vga.putChar('\n');
        }

        // 統計
        vga.write("  Total transitions: ");
        fmt.printDec(self.total_transitions);
        vga.putChar('\n');

        // 履歴
        if (self.history_len > 0) {
            vga.write("  History: ");
            for (0..self.history_len) |i| {
                if (i > 0) vga.write(" -> ");
                const sid = self.history[i];
                if (sid < MAX_STATES and self.states[sid].active) {
                    vga.write(self.states[sid].name[0..self.states[sid].name_len]);
                }
            }
            vga.putChar('\n');
        }
    }
};

// ---- イベント名表示 ----

fn printEventName(event: Event) void {
    switch (event) {
        .none => vga.write("none"),
        .start => vga.write("start"),
        .stop => vga.write("stop"),
        .pause => vga.write("pause"),
        .resume_event => vga.write("resume"),
        .timeout => vga.write("timeout"),
        .error_event => vga.write("error"),
        .reset => vga.write("reset"),
        .ack => vga.write("ack"),
        .nack => vga.write("nack"),
        .data_ready => vga.write("data_ready"),
        .complete => vga.write("complete"),
        .syn => vga.write("SYN"),
        .syn_ack => vga.write("SYN_ACK"),
        .fin => vga.write("FIN"),
        .fin_ack => vga.write("FIN_ACK"),
        .timer => vga.write("timer"),
        .emergency => vga.write("emergency"),
        .user0 => vga.write("user0"),
        .user1 => vga.write("user1"),
        .user2 => vga.write("user2"),
        .user3 => vga.write("user3"),
        _ => vga.write("unknown"),
    }
}

// ---- グローバルマシン管理 ----

var machines: [MAX_MACHINES]StateMachine = [_]StateMachine{.{}} ** MAX_MACHINES;

/// 新しい状態機械を作成
pub fn create(name: []const u8) ?u8 {
    for (0..MAX_MACHINES) |i| {
        if (!machines[i].active) {
            machines[i].active = true;
            machines[i].state_count = 0;
            machines[i].transition_count = 0;
            machines[i].current_state = 0;
            machines[i].total_transitions = 0;
            machines[i].history_len = 0;

            const len = if (name.len > NAME_LEN) NAME_LEN else name.len;
            for (0..len) |j| {
                machines[i].name[j] = name[j];
            }
            machines[i].name_len = @truncate(len);
            return @truncate(i);
        }
    }
    return null;
}

/// 状態機械を取得
pub fn getMachine(id: u8) ?*StateMachine {
    if (id >= MAX_MACHINES) return null;
    if (!machines[id].active) return null;
    return &machines[id];
}

// ---- 組み込みサンプル: TCP 状態機械 ----

pub fn createTcpStateMachine() ?u8 {
    const sm_id = create("TCP") orelse return null;
    const sm = &machines[sm_id];

    // TCP 状態
    _ = sm.addState(0, "CLOSED", &tcpEnter, null, null);
    _ = sm.addState(1, "LISTEN", &tcpEnter, null, null);
    _ = sm.addState(2, "SYN_SENT", &tcpEnter, null, null);
    _ = sm.addState(3, "SYN_RCVD", &tcpEnter, null, null);
    _ = sm.addState(4, "ESTABLISHED", &tcpEnter, null, null);
    _ = sm.addState(5, "FIN_WAIT", &tcpEnter, null, null);
    _ = sm.addState(6, "CLOSE_WAIT", &tcpEnter, null, null);
    _ = sm.addState(7, "TIME_WAIT", &tcpEnter, null, null);

    // TCP 遷移
    _ = sm.addTransition(0, 1, .start, null); // CLOSED -> LISTEN (passive open)
    _ = sm.addTransition(0, 2, .syn, null); // CLOSED -> SYN_SENT (active open)
    _ = sm.addTransition(1, 3, .syn, null); // LISTEN -> SYN_RCVD
    _ = sm.addTransition(2, 4, .syn_ack, null); // SYN_SENT -> ESTABLISHED
    _ = sm.addTransition(3, 4, .ack, null); // SYN_RCVD -> ESTABLISHED
    _ = sm.addTransition(4, 5, .fin, null); // ESTABLISHED -> FIN_WAIT
    _ = sm.addTransition(4, 6, .fin_ack, null); // ESTABLISHED -> CLOSE_WAIT
    _ = sm.addTransition(5, 7, .fin_ack, null); // FIN_WAIT -> TIME_WAIT
    _ = sm.addTransition(6, 0, .fin, null); // CLOSE_WAIT -> CLOSED
    _ = sm.addTransition(7, 0, .timeout, null); // TIME_WAIT -> CLOSED

    return sm_id;
}

fn tcpEnter(sm_id: u8, state_id: u8) void {
    _ = sm_id;
    _ = state_id;
    // TCP 状態遷移ログ (実装時にはシリアル出力)
}

// ---- 組み込みサンプル: 信号機 ----

pub fn createTrafficLightStateMachine() ?u8 {
    const sm_id = create("TrafficLight") orelse return null;
    const sm = &machines[sm_id];

    _ = sm.addState(0, "RED", &trafficEnter, &trafficExit, null);
    _ = sm.addState(1, "GREEN", &trafficEnter, &trafficExit, null);
    _ = sm.addState(2, "YELLOW", &trafficEnter, &trafficExit, null);
    _ = sm.addState(3, "EMERGENCY", &trafficEnter, &trafficExit, null);

    _ = sm.addTransition(0, 1, .timer, null); // RED -> GREEN
    _ = sm.addTransition(1, 2, .timer, null); // GREEN -> YELLOW
    _ = sm.addTransition(2, 0, .timer, null); // YELLOW -> RED
    _ = sm.addTransition(0, 3, .emergency, null); // RED -> EMERGENCY
    _ = sm.addTransition(1, 3, .emergency, null); // GREEN -> EMERGENCY
    _ = sm.addTransition(2, 3, .emergency, null); // YELLOW -> EMERGENCY
    _ = sm.addTransition(3, 0, .reset, null); // EMERGENCY -> RED

    return sm_id;
}

fn trafficEnter(sm_id: u8, state_id: u8) void {
    _ = sm_id;
    _ = state_id;
}

fn trafficExit(sm_id: u8, state_id: u8) void {
    _ = sm_id;
    _ = state_id;
}

// ---- デモ ----

pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== State Machine Demo ===\n");
    vga.setColor(.light_grey, .black);

    // TCP 状態機械
    if (createTcpStateMachine()) |tcp_id| {
        const tcp = &machines[tcp_id];

        vga.write("\n--- TCP State Machine ---\n");
        tcp.printStateMachine();

        // 接続シミュレーション
        vga.write("\nSimulating TCP connection:\n");
        _ = tcp.processEvent(tcp_id, .syn); // CLOSED -> SYN_SENT
        vga.write("  After SYN: ");
        vga.write(tcp.getCurrentStateName());
        vga.putChar('\n');

        _ = tcp.processEvent(tcp_id, .syn_ack); // SYN_SENT -> ESTABLISHED
        vga.write("  After SYN_ACK: ");
        vga.write(tcp.getCurrentStateName());
        vga.putChar('\n');

        _ = tcp.processEvent(tcp_id, .fin); // ESTABLISHED -> FIN_WAIT
        vga.write("  After FIN: ");
        vga.write(tcp.getCurrentStateName());
        vga.putChar('\n');
    }

    // 信号機
    if (createTrafficLightStateMachine()) |tl_id| {
        const tl = &machines[tl_id];

        vga.write("\n--- Traffic Light ---\n");

        // 通常サイクル
        vga.write("Normal cycle: ");
        vga.write(tl.getCurrentStateName());
        _ = tl.processEvent(tl_id, .timer);
        vga.write(" -> ");
        vga.write(tl.getCurrentStateName());
        _ = tl.processEvent(tl_id, .timer);
        vga.write(" -> ");
        vga.write(tl.getCurrentStateName());
        _ = tl.processEvent(tl_id, .timer);
        vga.write(" -> ");
        vga.write(tl.getCurrentStateName());
        vga.putChar('\n');

        // 緊急割り込み
        vga.write("Emergency: ");
        _ = tl.processEvent(tl_id, .emergency);
        vga.write(tl.getCurrentStateName());
        vga.putChar('\n');

        _ = tl.processEvent(tl_id, .reset);
        vga.write("After reset: ");
        vga.write(tl.getCurrentStateName());
        vga.putChar('\n');

        tl.printStateMachine();
    }
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("State Machines:\n");
    vga.setColor(.light_grey, .black);

    var found = false;
    for (0..MAX_MACHINES) |i| {
        if (machines[i].active) {
            found = true;
            vga.write("  [");
            fmt.printDec(i);
            vga.write("] ");
            vga.write(machines[i].name[0..machines[i].name_len]);
            vga.write(" state=");
            vga.write(machines[i].getCurrentStateName());
            vga.putChar('\n');
        }
    }
    if (!found) {
        vga.write("  (no active state machines)\n");
    }
}
