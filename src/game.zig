// Text-based games -- number guessing and snake game
//
// Both games run in blocking mode (shell context).
// Keyboard input via key buffer (pushKey from keyboard IRQ).

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const pit = @import("pit.zig");
const keyboard = @import("keyboard.zig");

// ---- Key input buffer ----

const KEY_BUF_SIZE = 64;
var key_buf: [KEY_BUF_SIZE]u8 = undefined;
var key_read: usize = 0;
var key_write: usize = 0;
var game_active: bool = false;

pub fn pushKey(ch: u8) void {
    const next = (key_write + 1) % KEY_BUF_SIZE;
    if (next == key_read) return;
    key_buf[key_write] = ch;
    key_write = next;
}

fn popKey() ?u8 {
    if (key_read == key_write) return null;
    const ch = key_buf[key_read];
    key_read = (key_read + 1) % KEY_BUF_SIZE;
    return ch;
}

fn waitKey() u8 {
    while (true) {
        if (popKey()) |ch| return ch;
        asm volatile ("hlt");
    }
}

/// Non-blocking key poll
fn pollKey() ?u8 {
    return popKey();
}

pub fn isActive() bool {
    return game_active;
}

// ---- Pseudo-random number generator ----
// Simple LCG seeded from PIT ticks.

var rng_state: u32 = 0;

fn seedRng() void {
    rng_state = @truncate(pit.getTicks() ^ 0xDEADBEEF);
    // Mix in more entropy
    rng_state = rng_state *% 1103515245 +% 12345;
}

fn nextRandom() u32 {
    rng_state = rng_state *% 1103515245 +% 12345;
    return (rng_state >> 16) & 0x7FFF;
}

/// Random number in range [1, max] inclusive
fn randomRange(max: u32) u32 {
    if (max == 0) return 1;
    return (nextRandom() % max) + 1;
}

// ============================================================
// NUMBER GUESSING GAME
// ============================================================

const GUESS_BUF_SIZE = 8;

pub fn startGuessing() void {
    key_read = 0;
    key_write = 0;
    game_active = true;
    seedRng();

    const target = randomRange(100);
    var guesses: u32 = 0;
    var input_buf: [GUESS_BUF_SIZE]u8 = undefined;
    var input_len: usize = 0;

    vga.setColor(.light_cyan, .black);
    vga.write("========================================\n");
    vga.write("        NUMBER GUESSING GAME\n");
    vga.write("========================================\n");
    vga.setColor(.light_grey, .black);
    vga.write("I'm thinking of a number between 1-100.\n");
    vga.write("Type 'q' to quit.\n\n");
    printGuessPrompt();

    while (game_active) {
        const ch = waitKey();

        switch (ch) {
            '\n' => {
                vga.putChar('\n');
                if (input_len == 0) {
                    printGuessPrompt();
                    continue;
                }

                // Check for quit
                if (input_len == 1 and input_buf[0] == 'q') {
                    vga.setColor(.light_cyan, .black);
                    vga.write("The number was ");
                    fmt.printDec(@as(usize, target));
                    vga.write(". Goodbye!\n");
                    vga.setColor(.light_grey, .black);
                    game_active = false;
                    return;
                }

                // Parse number
                const guess = parseU32(input_buf[0..input_len]);
                input_len = 0;

                if (guess == null) {
                    vga.setColor(.light_red, .black);
                    vga.write("Please enter a number (1-100) or 'q'.\n");
                    vga.setColor(.light_grey, .black);
                    printGuessPrompt();
                    continue;
                }

                const g = guess.?;
                guesses += 1;

                if (g < 1 or g > 100) {
                    vga.setColor(.light_red, .black);
                    vga.write("Out of range! Enter 1-100.\n");
                    vga.setColor(.light_grey, .black);
                    printGuessPrompt();
                    continue;
                }

                if (g < target) {
                    vga.setColor(.yellow, .black);
                    vga.write("Too low!  ");
                    printHint(g, target);
                    vga.setColor(.light_grey, .black);
                    printGuessPrompt();
                } else if (g > target) {
                    vga.setColor(.yellow, .black);
                    vga.write("Too high! ");
                    printHint(g, target);
                    vga.setColor(.light_grey, .black);
                    printGuessPrompt();
                } else {
                    // Correct!
                    vga.setColor(.light_green, .black);
                    vga.write("*** CORRECT! ***  You got it in ");
                    fmt.printDec(@as(usize, guesses));
                    vga.write(" guess");
                    if (guesses != 1) vga.write("es");
                    vga.write("!\n");

                    // Rating
                    if (guesses <= 3) {
                        vga.write("Amazing! You're a mind reader!\n");
                    } else if (guesses <= 5) {
                        vga.write("Excellent work!\n");
                    } else if (guesses <= 7) {
                        vga.write("Good job!\n");
                    } else {
                        vga.write("You can do better next time!\n");
                    }
                    vga.setColor(.light_grey, .black);

                    // Play again?
                    vga.write("\nPlay again? (y/n) ");
                    const answer = waitKey();
                    vga.putChar(answer);
                    vga.putChar('\n');
                    if (answer == 'y' or answer == 'Y') {
                        startGuessing();
                    }
                    game_active = false;
                    return;
                }
            },
            8 => { // backspace
                if (input_len > 0) {
                    input_len -= 1;
                    vga.backspace();
                }
            },
            else => {
                if (ch >= 0x80) continue;
                if (input_len < GUESS_BUF_SIZE - 1) {
                    input_buf[input_len] = ch;
                    input_len += 1;
                    vga.putChar(ch);
                }
            },
        }
    }
}

fn printGuessPrompt() void {
    vga.setColor(.light_green, .black);
    vga.write("Guess> ");
    vga.setColor(.white, .black);
}

fn printHint(guess: u32, target: u32) void {
    const diff = if (guess > target) guess - target else target - guess;
    if (diff <= 3) {
        vga.write("(very close!)\n");
    } else if (diff <= 10) {
        vga.write("(getting warm)\n");
    } else if (diff <= 25) {
        vga.write("(not bad)\n");
    } else {
        vga.write("(way off)\n");
    }
}

// ============================================================
// SNAKE GAME
// ============================================================

const FIELD_W = 40;
const FIELD_H = 20;
const MAX_SNAKE_LEN = 200;

const CHAR_SNAKE_HEAD = '@';
const CHAR_SNAKE_BODY = 'o';
const CHAR_FOOD = '*';
const CHAR_WALL = '#';
const CHAR_EMPTY = ' ';

const Direction = enum(u8) { up, down, left, right };

// Snake segments stored as x,y pairs
var snake_x: [MAX_SNAKE_LEN]u8 = undefined;
var snake_y: [MAX_SNAKE_LEN]u8 = undefined;
var snake_len: usize = 0;
var snake_dir: Direction = .right;

var food_x: u8 = 0;
var food_y: u8 = 0;
var score: u32 = 0;
var game_over: bool = false;

// VGA offset for the play field (row, col) of top-left corner
const FIELD_ROW = 2;
const FIELD_COL = 0;

pub fn startSnake() void {
    key_read = 0;
    key_write = 0;
    game_active = true;
    game_over = false;
    seedRng();

    // Initialize snake in the middle
    snake_len = 3;
    const mid_x: u8 = FIELD_W / 2;
    const mid_y: u8 = FIELD_H / 2;
    snake_x[0] = mid_x;
    snake_y[0] = mid_y;
    snake_x[1] = mid_x - 1;
    snake_y[1] = mid_y;
    snake_x[2] = mid_x - 2;
    snake_y[2] = mid_y;
    snake_dir = .right;
    score = 0;

    placeFood();
    drawField();
    drawSnake();
    drawFoodChar();
    drawScore();

    // Game loop - tick based
    var last_tick = pit.getTicks();
    const tick_interval: u64 = 100; // 100ms per step

    while (!game_over and game_active) {
        // Process all available keys (non-blocking)
        while (pollKey()) |ch| {
            switch (ch) {
                'q' => {
                    game_active = false;
                    restoreScreen();
                    return;
                },
                'w', keyboard.KEY_UP => {
                    if (snake_dir != .down) snake_dir = .up;
                },
                's', keyboard.KEY_DOWN => {
                    if (snake_dir != .up) snake_dir = .down;
                },
                'a', keyboard.KEY_LEFT => {
                    if (snake_dir != .right) snake_dir = .left;
                },
                'd', keyboard.KEY_RIGHT => {
                    if (snake_dir != .left) snake_dir = .right;
                },
                else => {},
            }
        }

        // Tick-based movement
        const now = pit.getTicks();
        if (now - last_tick >= tick_interval) {
            last_tick = now;
            updateSnake();
            if (!game_over) {
                drawSnake();
                drawFoodChar();
                drawScore();
            }
        }

        asm volatile ("hlt");
    }

    // Game over screen
    if (game_over) {
        drawGameOver();
        // Wait for any key
        _ = waitKey();
    }

    game_active = false;
    restoreScreen();
}

fn placeFood() void {
    // Try random positions until we find an empty one
    var attempts: u32 = 0;
    while (attempts < 500) : (attempts += 1) {
        food_x = @truncate(randomRange(FIELD_W - 2));
        food_y = @truncate(randomRange(FIELD_H - 2));
        if (food_x == 0) food_x = 1;
        if (food_y == 0) food_y = 1;

        // Check not on snake
        var on_snake = false;
        var i: usize = 0;
        while (i < snake_len) : (i += 1) {
            if (snake_x[i] == food_x and snake_y[i] == food_y) {
                on_snake = true;
                break;
            }
        }
        if (!on_snake) return;
    }
    // Fallback: just place at 1,1
    food_x = 1;
    food_y = 1;
}

fn updateSnake() void {
    // Calculate new head position
    var new_x: i16 = @as(i16, snake_x[0]);
    var new_y: i16 = @as(i16, snake_y[0]);

    switch (snake_dir) {
        .up => new_y -= 1,
        .down => new_y += 1,
        .left => new_x -= 1,
        .right => new_x += 1,
    }

    // Wall collision
    if (new_x <= 0 or new_x >= FIELD_W - 1 or new_y <= 0 or new_y >= FIELD_H - 1) {
        game_over = true;
        return;
    }

    const nx: u8 = @intCast(new_x);
    const ny: u8 = @intCast(new_y);

    // Self collision
    var i: usize = 0;
    while (i < snake_len) : (i += 1) {
        if (snake_x[i] == nx and snake_y[i] == ny) {
            game_over = true;
            return;
        }
    }

    // Check food
    const ate_food = (nx == food_x and ny == food_y);

    // Clear tail from screen before moving
    if (!ate_food) {
        clearCell(snake_x[snake_len - 1], snake_y[snake_len - 1]);
    }

    // Move body segments backwards
    if (!ate_food) {
        // Shift body
        var j: usize = snake_len - 1;
        while (j > 0) : (j -= 1) {
            snake_x[j] = snake_x[j - 1];
            snake_y[j] = snake_y[j - 1];
        }
    } else {
        // Grow: shift everything and add head
        if (snake_len < MAX_SNAKE_LEN) {
            var j: usize = snake_len;
            while (j > 0) : (j -= 1) {
                snake_x[j] = snake_x[j - 1];
                snake_y[j] = snake_y[j - 1];
            }
            snake_len += 1;
        }
        score += 10;
        placeFood();
    }

    // Set new head
    snake_x[0] = nx;
    snake_y[0] = ny;
}

// ---- Drawing ----

fn drawField() void {
    vga.clear();
    vga.setColor(.light_cyan, .black);
    vga.setCursor(0, 0);
    vga.write("  SNAKE GAME  |  WASD/Arrows: move  |  Q: quit");

    // Draw border
    vga.setColor(.dark_grey, .black);
    var y: usize = 0;
    while (y < FIELD_H) : (y += 1) {
        var x: usize = 0;
        while (x < FIELD_W) : (x += 1) {
            if (x == 0 or x == FIELD_W - 1 or y == 0 or y == FIELD_H - 1) {
                putAt(@truncate(x), @truncate(y), CHAR_WALL, .dark_grey);
            }
        }
    }
}

fn drawSnake() void {
    // Draw head
    putAt(snake_x[0], snake_y[0], CHAR_SNAKE_HEAD, .light_green);

    // Draw body
    var i: usize = 1;
    while (i < snake_len) : (i += 1) {
        putAt(snake_x[i], snake_y[i], CHAR_SNAKE_BODY, .green);
    }
}

fn drawFoodChar() void {
    putAt(food_x, food_y, CHAR_FOOD, .light_red);
}

fn clearCell(x: u8, y: u8) void {
    putAt(x, y, CHAR_EMPTY, .black);
}

fn putAt(x: u8, y: u8, ch: u8, color: vga.Color) void {
    // Write directly to VGA buffer for speed
    const vga_x: usize = @as(usize, x) + FIELD_COL;
    const vga_y: usize = @as(usize, y) + FIELD_ROW;
    if (vga_x >= 80 or vga_y >= 25) return;
    const buf: [*]volatile u16 = @ptrFromInt(0xB8000);
    const attr: u16 = @as(u16, @intFromEnum(color)) | (@as(u16, @intFromEnum(vga.Color.black)) << 4);
    buf[vga_y * 80 + vga_x] = @as(u16, ch) | (attr << 8);
}

fn drawScore() void {
    vga.setCursor(1, 0);
    vga.setColor(.yellow, .black);
    vga.write("  Score: ");
    fmt.printDec(@as(usize, score));
    vga.write("   Length: ");
    fmt.printDec(snake_len);
    vga.write("     ");
}

fn drawGameOver() void {
    // Draw game over message in the middle of the field
    const msg_row = FIELD_ROW + FIELD_H / 2;
    const msg_col = FIELD_COL + (FIELD_W / 2) - 8;
    vga.setCursor(msg_row, msg_col);
    vga.setColor(.light_red, .black);
    vga.write("  GAME OVER!  ");

    vga.setCursor(msg_row + 1, msg_col);
    vga.setColor(.yellow, .black);
    vga.write(" Score: ");
    fmt.printDec(@as(usize, score));
    vga.write("    ");

    vga.setCursor(msg_row + 2, msg_col);
    vga.setColor(.dark_grey, .black);
    vga.write(" Press any key ");
}

fn restoreScreen() void {
    vga.clear();
    vga.setCursor(0, 0);
    vga.setColor(.light_grey, .black);
}

// ---- Utility ----

fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const new = @mulWithOverflow(val, 10);
        if (new[1] != 0) return null;
        const add = @addWithOverflow(new[0], c - '0');
        if (add[1] != 0) return null;
        val = add[0];
    }
    return val;
}
