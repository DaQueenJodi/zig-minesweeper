const std = @import("std");
const assert = std.debug.assert;
const clamp = std.math.clamp;
const c = @cImport({
    @cInclude("raylib.h");
});

const DEFAULT_WINDOW_WIDTH = 800;
const DEFAULT_WINDOW_HEIGHT = 600;

const GRID_WIDTH = 50;
const GRID_HEIGHT = 50;
const DEFAULT_CELL_SIZE = 16;

const BOMB_COUNT = 415;

const ATLAS_NUMS_OFFSET = 0;
const ATLAS_EMPTY = 9;
const ATLAS_FLAG = 10;
const ATLAS_WRONG_FLAG = 11;
const ATLAS_MINE = 12;
const ATLAS_REVEALED_MINE = 13;

const FACE_HAPPY = 0;
const FACE_PRESSED = 1;
const FACE_SURPRISED = 2;
const FACE_SUNGLASSES = 3;
const FACE_DEAD = 4;

const FACE_HEIGHT = 24;
const FACE_WIDTH = 24;
const UI_NUM_WIDTH = 13;
const UI_NUM_HEIGHT = 23;

const TOP_PADDING = FACE_HEIGHT * 3 / 2;
const UI_NUM_TOP_PADDING = (TOP_PADDING - UI_NUM_HEIGHT) / 2;
const FACE_TOP_PADDING = (TOP_PADDING - FACE_HEIGHT) / 2;

const SCROLL_SPEED = 300;

const Pos = struct { x: usize, y: usize };

const CellState = packed struct { is_bomb: bool = false, is_flagged: bool = false, is_revealed: bool = false };

const Cell = struct { state: CellState, n: usize };

fn contains(arr: anytype, e: std.meta.Child(@TypeOf(arr))) bool {
    for (arr) |a| if (std.meta.eql(a, e)) return true;
    return false;
}
fn indexOfScalar(arr: anytype, e: std.meta.Child(@TypeOf(arr))) ?usize {
    for (arr, 0..) |a, i| if (std.meta.eql(a, e)) return i;
    return null;
}

fn getNeighborPos(pos: Pos) [8]?Pos {
    var positions: [8]?Pos = undefined;
    var positions_len: usize = 0;
    const x_i: i32 = @intCast(pos.x);
    const y_i: i32 = @intCast(pos.y);
    const offsets = [_]i32{ -1, 0, 1 };
    for (offsets) |dy| {
        if (y_i + dy >= GRID_HEIGHT or y_i + dy < 0) continue;
        for (offsets) |dx| {
            if ((dx == 0 and dy == 0) or
                x_i + dx >= GRID_WIDTH or
                x_i + dx < 0) continue;

            const x: usize = @intCast(x_i + dx);
            const y: usize = @intCast(y_i + dy);
            positions[positions_len] = .{ .x = x, .y = y };
            positions_len += 1;
        }
    }
    for (positions[positions_len..]) |*p| p.* = null;
    return positions;
}

fn revealCell(grid: *[GRID_HEIGHT * GRID_WIDTH]Cell, pos: Pos) enum { changed, unchanged, splody } {
    var changed = false;
    const cell = &grid[pos.y * GRID_WIDTH + pos.x];
    switch (cell.state.is_revealed) {
        false => {
            if (!cell.state.is_flagged) {
                cell.state.is_revealed = true;
                if (cell.state.is_bomb) return .splody;
                changed = true;
            }
            if (cell.n == 0) {
                const neighbors = getNeighborPos(pos);
                for (neighbors) |n| {
                    if (n) |n0| {
                        if (!grid[n0.y * GRID_HEIGHT + n0.x].state.is_revealed) {
                            assert(revealCell(grid, n0) != .splody);
                        }
                    } else break;
                }
            }
        },
        true => {
            var splodied = false;
            const neighbors = getNeighborPos(pos);
            // check if there are enough flags
            var flag_count: usize = 0;
            for (neighbors) |n| {
                if (n) |n0| {
                    if (grid[n0.y * GRID_WIDTH + n0.x].state.is_flagged) {
                        flag_count += 1;
                    }
                }
            }
            // reveal surrounding areas
            if (flag_count == cell.n) {
                for (neighbors) |n| {
                    if (n) |n0| {
                        const cell0 = grid[n0.y * GRID_WIDTH + n0.x];
                        if (cell0.state.is_revealed or cell0.state.is_flagged) continue;
                        if (revealCell(grid, n0) == .splody) splodied = true;
                    } else break;
                }
            }
            if (splodied) return .splody;
        },
    }
    return if (changed) .changed else .unchanged;
}

fn getMouseLocInGrid(scroll_x: f32, scroll_y: f32, cell_size: usize) ?Pos {
    const pos = c.GetMousePosition();
    if (pos.x < scroll_x or pos.y + scroll_y < TOP_PADDING) return null;
    const x: usize = @intFromFloat(@ceil(pos.x + scroll_x));
    const y: usize = @intFromFloat(@ceil(pos.y + scroll_y - TOP_PADDING));
    const grid_x = x / cell_size;
    const grid_y = y / cell_size;
    return .{ .x = grid_x, .y = grid_y };
}

fn getNthAtlasRect(n: usize) c.Rectangle {
    const row = @divFloor(n, 4);
    const col = @mod(n, 4);
    const TILE_SPRITE_SIZE = 16;
    return .{ .x = @floatFromInt(col * TILE_SPRITE_SIZE), .y = @floatFromInt(row * TILE_SPRITE_SIZE), .width = TILE_SPRITE_SIZE, .height = TILE_SPRITE_SIZE };
}

inline fn getUiNum(n: usize) c.Rectangle {
    return .{ .x = @floatFromInt(n * UI_NUM_WIDTH), .y = @floatFromInt(0), .width = UI_NUM_WIDTH, .height = UI_NUM_HEIGHT };
}

inline fn getFace(n: usize) c.Rectangle {
    return .{ .x = @floatFromInt(n * FACE_WIDTH), .y = @floatFromInt(0), .width = FACE_WIDTH, .height = FACE_HEIGHT };
}

fn getDuplicate(arr: anytype) ?usize {
    for (arr, 0..) |a, i| {
        for (arr, 0..) |b, j| {
            // don't count yourself
            if (i == j) continue;
            if (std.meta.eql(a, b)) return i;
        }
    }
    return null;
}

fn countBombNeighbors(pos: Pos, bombs: [BOMB_COUNT]Pos) usize {
    var count: usize = 0;

    const positions = getNeighborPos(pos);
    for (positions) |p| {
        for (bombs) |b| {
            if (std.meta.eql(p, b)) count += 1;
        }
    }
    return count;
}

const GameState = enum { playing, dead, win };

fn initBombs(bombs: *[BOMB_COUNT]Pos, rand: std.rand.Random) void {
    for (bombs) |*b| b.* = .{ .x = rand.uintLessThan(usize, GRID_WIDTH), .y = rand.uintLessThan(usize, GRID_HEIGHT) };
    while (getDuplicate(bombs)) |i| bombs[i] = .{ .x = rand.uintLessThan(usize, GRID_WIDTH), .y = rand.uintLessThan(usize, GRID_HEIGHT) };
}
fn initGrid(bombs: [BOMB_COUNT]Pos, grid: *[GRID_HEIGHT * GRID_WIDTH]Cell) void {
    for (0..GRID_HEIGHT) |y| {
        for (0..GRID_WIDTH) |x| {
            const pos = Pos{ .x = x, .y = y };
            const is_bomb = blk: {
                for (bombs) |b| {
                    if (std.meta.eql(pos, b)) break :blk true;
                }
                break :blk false;
            };
            const state = CellState{ .is_bomb = is_bomb, .is_revealed = false };
            grid[y * GRID_WIDTH + x] = Cell{ .n = countBombNeighbors(pos, bombs), .state = state };
        }
    }
}

pub fn main() !void {
    var seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&seed));
    var pcg = std.rand.Pcg.init(seed);
    const rand = pcg.random();

    var bombs: [BOMB_COUNT]Pos = undefined;
    initBombs(&bombs, rand);

    var game_state: GameState = .playing;

    var grid: [GRID_WIDTH * GRID_HEIGHT]Cell = undefined;
    for (&grid) |*e| e.* = .{ .n = 0, .state = .{} };

    c.SetTraceLogLevel(c.LOG_FATAL | c.LOG_WARNING | c.LOG_ERROR);
    c.SetTargetFPS(60);
    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT, "minesweeper");

    var window_width: usize = @intCast(c.GetScreenWidth());
    var window_height: usize = @intCast(c.GetScreenHeight());
    var cell_size: usize = DEFAULT_CELL_SIZE;

    // sprites
    const texture_atlas = c.LoadTexture("resources/atlas.png");
    defer c.UnloadTexture(texture_atlas);

    const ui_nums_atlas = c.LoadTexture("resources/ui_numbers.png");
    defer c.UnloadTexture(ui_nums_atlas);

    const face_atlas = c.LoadTexture("resources/faces.png");
    defer c.UnloadTexture(face_atlas);
    
    // sounds
    c.InitAudioDevice();
    defer c.CloseAudioDevice();
    const tick_sound = c.LoadSound("resources/tick.wav");
    defer c.UnloadSound(tick_sound);
    const lose_sound = c.LoadSound("resources/lose.wav");
    defer c.UnloadSound(lose_sound);
    const win_sound = c.LoadSound("resources/win.wav");
    defer c.UnloadSound(win_sound);

    var scroll_x: f32 = 0;
    var scroll_y: f32 = 0;

    var flags_left: usize = BOMB_COUNT;

    var first_click = true;
    var time_started: ?std.time.Instant = null;
    var time_elapsed: ?u64 = null;

    while (!c.WindowShouldClose()) {
        const top_width = GRID_WIDTH * cell_size;
        const face_dst: c.Rectangle = .{ .x = @floatFromInt(top_width / 2), .y = @floatFromInt(FACE_TOP_PADDING), .height = FACE_HEIGHT, .width = FACE_WIDTH };
        {
            c.BeginDrawing();
            defer c.EndDrawing();

            c.ClearBackground(c.BLACK);
            // draw grid
            for (0..GRID_HEIGHT) |y| {
                for (0..GRID_WIDTH) |x| {
                    const cell = grid[y * GRID_WIDTH + x];
                    const atlas_index: usize = blk: {
                        if (cell.state.is_revealed) {
                            if (cell.state.is_bomb) break :blk ATLAS_REVEALED_MINE;
                            break :blk ATLAS_NUMS_OFFSET + cell.n;
                        } else if (cell.state.is_flagged) {
                            if (game_state == .dead and !cell.state.is_bomb) break :blk ATLAS_WRONG_FLAG;
                            break :blk ATLAS_FLAG;
                        } else if (game_state == .dead and cell.state.is_bomb) {
                            break :blk ATLAS_MINE;
                        }
                        break :blk ATLAS_EMPTY;
                    };
                    const src = getNthAtlasRect(atlas_index);
                    const pixel_x: f32 = @floatFromInt(x * cell_size);
                    const pixel_y: f32 = @floatFromInt(y * cell_size);
                    c.DrawTexturePro(texture_atlas, src, .{ .x = pixel_x - scroll_x, .y = pixel_y - scroll_y + TOP_PADDING, .width = @floatFromInt(cell_size), .height = @floatFromInt(cell_size) }, .{}, 0, c.WHITE);
                }
            }
            // draw top ui
            c.DrawRectangle(0, 0, @intCast(top_width), TOP_PADDING, c.GRAY);
            // draw face
            const face: usize = if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT) and c.CheckCollisionPointRec(.{ .x = @floatFromInt(c.GetMouseX()), .y = @floatFromInt(c.GetMouseY()) }, face_dst)) FACE_PRESSED else switch (game_state) {
                .dead => FACE_DEAD,
                .win => FACE_SUNGLASSES,
                .playing => if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT) and getMouseLocInGrid(scroll_x, scroll_y, cell_size) != null) FACE_SURPRISED else FACE_HAPPY,
            };
            c.DrawTexturePro(face_atlas, getFace(face), face_dst, .{}, 0, c.WHITE);
            // flags left
            var digits: [10]usize = undefined;
            var digits_count: usize = 0;
            {
                var n = flags_left;
                while (n > 0) : ({
                    n /= 10;
                    digits_count += 1;
                }) {
                    digits[digits_count] = n % 10;
                }
            }
            // this gets digits in the wrong order, so we draw them in reverse
            {
                var i: usize = digits_count;
                while (i > 0) : (i -= 1) {
                    const src = getUiNum(digits[i - 1]);
                    const place = digits_count - i;
                    const pixel_x: f32 = @floatFromInt(place * UI_NUM_WIDTH);
                    c.DrawTexturePro(ui_nums_atlas, src, .{ .x = pixel_x, .y = UI_NUM_TOP_PADDING, .width = UI_NUM_WIDTH, .height = UI_NUM_HEIGHT }, .{}, 0.0, c.WHITE);
                }
            }
            // time
            const time: u64 = if (time_elapsed) |_| @divFloor(time_elapsed.?, std.time.ns_per_s) else 0;
            if (time == 0) {
                const src = comptime getUiNum(0);
                const pixel_x: f32 = @floatFromInt(top_width - UI_NUM_WIDTH);
                c.DrawTexturePro(ui_nums_atlas, src, .{ .x = pixel_x, .y = UI_NUM_TOP_PADDING, .width = UI_NUM_WIDTH, .height = UI_NUM_HEIGHT }, .{}, 0.0, c.WHITE);
            } else {
                digits_count = 0;
                {
                    var n = time;
                    while (n > 0) : ({
                        n /= 10;
                        digits_count += 1;
                    }) {
                        digits[digits_count] = n % 10;
                    }
                }
                {
                    var i: usize = 0;
                    while (i < digits_count) : (i += 1) {
                        const src = getUiNum(digits[i]);
                        const place = i + 1;
                        const pixel_x: f32 = @floatFromInt(top_width - place * UI_NUM_WIDTH);
                        c.DrawTexturePro(ui_nums_atlas, src, .{ .x = pixel_x, .y = UI_NUM_TOP_PADDING, .width = UI_NUM_WIDTH, .height = UI_NUM_HEIGHT }, .{}, 0.0, c.WHITE);
                    }
                }
            }
        }
        var bell = false;
        switch (game_state) {
            .playing => {

                // update elapsed time
                if (time_started) |_| {
                    time_elapsed = (try std.time.Instant.now()).since(time_started.?);
                }
                if (c.IsMouseButtonReleased(c.MOUSE_BUTTON_RIGHT) or
                    ((c.IsMouseButtonReleased(c.MOUSE_BUTTON_LEFT) and c.IsMouseButtonDown(c.KEY_LEFT_SHIFT))))
                {
                    const pos = getMouseLocInGrid(scroll_x, scroll_y, cell_size);
                    if (pos) |pos0| {
                        const cell = &grid[pos0.y * GRID_WIDTH + pos0.x];
                        if (!cell.state.is_revealed) {
                            switch (cell.state.is_flagged) {
                                true => {
                                    cell.state.is_flagged = false;
                                    flags_left += 1;
                                },
                                false => {
                                    cell.state.is_flagged = true;
                                    if (flags_left > 0) {
                                        flags_left -= 1;
                                    } else {
                                        bell = true;
                                    }
                                },
                            }
                        }
                    }
                } else if (c.IsMouseButtonReleased(c.MOUSE_BUTTON_LEFT)) {
                    const pos = getMouseLocInGrid(scroll_x, scroll_y, cell_size);
                    if (pos) |pos0| {

                        //c.PlaySound(tick_sound);


                        if (first_click) {
                            first_click = false;
                            if (indexOfScalar(bombs, pos0)) |bombs_i| {
                                var new_bomb_pos = Pos{ .x = 0, .y = 0 };
                                while (contains(bombs, new_bomb_pos)) {
                                    if (new_bomb_pos.x == GRID_WIDTH) {
                                        new_bomb_pos.x = 0;
                                        new_bomb_pos.y += 1;
                                    } else new_bomb_pos.x += 1;
                                }
                                bombs[bombs_i] = new_bomb_pos;
                            }
                            initGrid(bombs, &grid);
                            time_started = try std.time.Instant.now();
                            time_elapsed = null;
                        }
                        const res = revealCell(&grid, pos0);
                        switch (res) {
                            .splody => {
                                game_state = .dead;
                                c.PlaySound(lose_sound);
                            },
                            .unchanged => bell = true,
                            .changed => {},
                        }
                        if (res != .splody) {
                            var win = true;
                            for (0..GRID_WIDTH * GRID_HEIGHT) |i| {
                                if (!grid[i].state.is_revealed and !grid[i].state.is_bomb) {
                                    win = false;
                                    break;
                                }
                            }
                            if (win) {
                                game_state = .win;
                                c.PlaySound(win_sound);
                            }
                        }
                    }
                }
            },
            .win, .dead => {},
        }
        // srolling
        const max_scroll_x: f32 = if (GRID_WIDTH * cell_size > window_width)
            @floatFromInt(GRID_WIDTH * cell_size - window_width)
        else
            0.0;
        const max_scroll_y: f32 = if (GRID_WIDTH * cell_size > window_height + TOP_PADDING)
            @floatFromInt(GRID_WIDTH * cell_size - window_height - TOP_PADDING)
        else
            0.0;
        if (c.IsKeyDown(c.KEY_RIGHT)) scroll_x = clamp(scroll_x + SCROLL_SPEED * c.GetFrameTime(), 0.0, max_scroll_x);
        if (c.IsKeyDown(c.KEY_LEFT)) scroll_x = clamp(scroll_x - SCROLL_SPEED * c.GetFrameTime(), 0.0, max_scroll_x);
        if (c.IsKeyDown(c.KEY_DOWN)) scroll_y = clamp(scroll_y + SCROLL_SPEED * c.GetFrameTime(), 0.0, max_scroll_y);
        if (c.IsKeyDown(c.KEY_UP)) scroll_y = clamp(scroll_y - SCROLL_SPEED * c.GetFrameTime(), 0.0, max_scroll_y);
        // zooming
        if (c.IsKeyPressed(c.KEY_EQUAL)) cell_size += 1;
        if (c.IsKeyPressed(c.KEY_MINUS)) cell_size = if (cell_size == 0) 0 else cell_size - 1;
        if (c.IsMouseButtonReleased(c.MOUSE_BUTTON_LEFT) and c.CheckCollisionPointRec(.{ .x = @floatFromInt(c.GetMouseX()), .y = @floatFromInt(c.GetMouseY()) }, face_dst)) {
            initBombs(&bombs, rand);
            for (&grid) |*e| e.* = .{ .n = 0, .state = .{} };
            game_state = .playing;
            first_click = true;
            time_started = null;
            time_elapsed = null;
        }
        // TODO: add audio bell
        //if (bell) c.PlaySound(bell_sound);
    }
    c.CloseWindow();
}
