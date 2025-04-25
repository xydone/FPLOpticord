const std = @import("std");
const types = @import("../types.zig");
const dotenv = @import("../util/dotenv.zig");
const Shared = @import("../events/event_handler.zig").Shared;

pub const Response = struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(Result),

    pub fn append(self: *Response, value: Result) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.list.append(value);
    }

    ///Caller must free result
    pub fn get(self: *Response, allocator: std.mem.Allocator) !std.ArrayList(Result) {
        _ = allocator; // autofix
        self.mutex.lock();
        const list = try self.list.clone();
        self.mutex.unlock();

        return list;
    }
    pub fn remove(self: *Response, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.list.orderedRemove(index);
    }
};

pub fn regular(response: *Response, allocator: std.mem.Allocator, config: []const u8) void {
    var env = dotenv.init(allocator, ".env") catch @panic("Can't get env");
    defer env.deinit();
    const shared = Shared.get();
    var env_map = std.process.getEnvMap(allocator) catch unreachable;
    defer env_map.deinit();
    const config_location = std.fmt.allocPrint(allocator, "--config={s}", .{config}) catch @panic("OOM");
    defer allocator.free(config_location);

    //NOTE: Calling python.exe will bypass the Python installation (if one exists) in WSL. To use the WSL version, use `python` instead.
    const python_executable = if (shared.is_wsl) "python.exe" else "python";
    const argv = &.{ python_executable, "-u", "solve_regular.py", config_location };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = shared.solver_path;
    child.expand_arg0 = .no_expand;
    child.progress_node = std.Progress.Node.none;
    env_map.put("PYTHONIOENCODING", "utf-8") catch |err| std.debug.panic("Failed to put PYTHONIOENCODING into env-map due to {}", .{err});
    if (shared.is_wsl) env_map.put("WSLENV", "PYTHONIOENCODING") catch |err| std.debug.panic("Failed to put WSLENV into env-map due to {}", .{err});

    child.env_map = &env_map;

    child.spawn() catch |err| {
        std.debug.print(
            "Failed to spawn solve_regular child process due to {}. Hint: Check if you are using the correct path for the python solver inside your .env\n",
            .{err},
        );
        return;
    };
    errdefer {
        _ = child.kill() catch {};
    }
    const stdout_reader = child.stdout.?.reader();
    const stderr_reader = child.stderr.?.reader();
    var buf: [1028]u8 = undefined;
    while (true) {
        const stdout_len = stdout_reader.read(&buf) catch |err| {
            std.debug.print("stdout reader failed with: {}\n", .{err});
            break;
        };
        if (stdout_len == 0) break;
        if (std.mem.eql(u8, buf[0..stdout_len], "\r\n")) continue;
        const process_state = parseOutput(buf[0..stdout_len], response, allocator);

        if (process_state.running == false) {
            _ = child.kill() catch std.debug.panic("Could not terminate process", .{});
            return;
        }
    }
    var stderr = std.ArrayList(u8).init(allocator);
    defer stderr.deinit();

    var stderr_buf: [1028]u8 = undefined;
    // read from stderr
    const stderr_len = stderr_reader.readAtLeast(&stderr_buf, 1024) catch |err| {
        std.debug.print("stderr reader failed with: {}\n", .{err});
        return;
    };

    // check if the solver ran into an error
    if (stderr.items.len != 0) {
        std.debug.print("caught error in solver!\n", .{});
        // const error_message = try std.mem.join(allocator, "", stderr.toOwnedSlice() catch @panic("OOM!"));
        response.append(.{ .solver_error = SolverError{ .message = stderr_buf[0..stderr_len] } }) catch @panic("Cannot append error");
        return;
    }

    _ = child.wait() catch unreachable;
    response.append(.{ .done = Done{} }) catch @panic("Cannot append");
}

const SolveProcessState = struct { running: bool };
fn parseOutput(
    message: []u8,
    response: *Response,
    allocator: std.mem.Allocator,
) SolveProcessState {
    var iterator = std.mem.tokenizeSequence(u8, message, "\r\n");
    while (iterator.next()) |str_a| {
        const str = std.fmt.allocPrint(allocator, "{s}", .{str_a}) catch @panic("OOM!");
        const state = State.fromString(str);
        const result = Result.fromString(str, allocator, state) catch |err| {
            std.debug.panic("Getting result failed with {}\nProvided message is: \"{s}\"", .{ err, message });
        };
        if (result == .incorrect_config) {
            response.append(.{ .incorrect_config = IncorrectConfig{} }) catch @panic("Cannot append");
            return .{ .running = false };
        }
        response.append(result) catch @panic("Cannot append");
    }
    return .{ .running = true };
}

const Outputs = enum {
    incorrect_config,
    up_to_date,
    result_summary,
    solution,
    gameweek_moves,
    unparsed,
    done,
    solver_error,

    const RawOutputs = enum {
        @"Your repository is up-to-date.",
        @"Result Summary",
    };
};

const State = struct {
    state: Outputs,
    value: []const u8,

    pub fn fromString(buf: []u8) State {
        var solution_it = std.mem.tokenizeSequence(u8, buf, "Solution ");
        if (solution_it.next()) |solution| {
            if (!std.mem.eql(u8, buf, solution)) {
                if (solution_it.next()) |after_solution| {
                    return State{ .state = .solution, .value = after_solution };
                }
                return State{ .state = .solution, .value = solution };
            }
        }
        var gameweek_it = std.mem.tokenizeSequence(u8, buf, "\tGW");
        if (gameweek_it.peek()) |gw| {
            if (!std.mem.eql(u8, buf, gw)) {
                return State{ .state = .gameweek_moves, .value = gw };
            }
        }
        if (std.mem.startsWith(u8, buf, "Warning: Configuration file")) {
            return State{ .state = .incorrect_config, .value = buf };
        }
        return .{ .state = .unparsed, .value = buf };
    }
};

pub const Result = union(Outputs) {
    incorrect_config: IncorrectConfig,
    up_to_date: UpToDate,
    result_summary: ResultSummary,
    solution: Solution,
    gameweek_moves: GameweekMoves,
    unparsed: Unparsed,
    done: Done,
    solver_error: SolverError,

    // Depending on the result type, caller might own memory. `.deinit(...)` should be called
    pub fn fromString(str: []u8, allocator: std.mem.Allocator, state: State) !Result {
        const enums = std.meta.stringToEnum(Outputs.RawOutputs, str) orelse {
            switch (state.state) {
                Outputs.solution => {
                    return .{ .solution = Solution{ .number = try std.fmt.parseInt(u16, state.value, 10), .buf = str } };
                },
                Outputs.gameweek_moves => {
                    var gw_moves_it = std.mem.tokenizeSequence(u8, state.value, ": ");
                    const gameweek = gw_moves_it.next().?;
                    const moves = gw_moves_it.next().?;
                    return .{ .gameweek_moves = GameweekMoves{ .gameweek = try std.fmt.parseInt(u6, gameweek, 10), .moves = moves, .buf = str } };
                },
                Outputs.incorrect_config => {
                    allocator.free(str);
                    return .{ .incorrect_config = IncorrectConfig{} };
                },
                else => {
                    allocator.free(str);
                    return .{ .unparsed = Unparsed{} };
                },
            }
        };
        allocator.free(str);
        //Meant for lines which can be matched with the whole text
        return switch (enums) {
            .@"Your repository is up-to-date." => .{ .up_to_date = UpToDate{} },
            .@"Result Summary" => .{ .result_summary = ResultSummary{} },
        };
    }

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .gameweek_moves => |inner| {
                allocator.free(inner.buf);
            },
            .solution => |inner| {
                allocator.free(inner.buf);
            },
            else => {},
        }
    }
};

const IncorrectConfig = struct {};
const UpToDate = struct {};
const ResultSummary = struct {};
const Solution = struct {
    number: u32,
    buf: []const u8,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; // autofix
        _ = options; // autofix
        try writer.writeAll("Solution{ ");
        try writer.print(".number = {d}, .buf = \"{s}\"", .{
            self.number, self.buf,
        });
        try writer.writeAll(" }");
    }
};
const GameweekMoves = struct {
    gameweek: u8,
    moves: []const u8,
    buf: []const u8,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; // autofix
        _ = options; // autofix
        try writer.writeAll("GameweekMoves{ ");
        try writer.print(".gameweek = {d}, .moves = \"{s}\"", .{
            self.gameweek, self.moves,
        });
        try writer.writeAll(" }");
    }
};
const Unparsed = struct {};
const Done = struct {};
const SolverError = struct {
    message: []const u8,
};

// The FPL Optimization Tools python solver (https://github.com/sertalpbilal/FPL-Optimization-Tools) pulls player name data from the FPL API instead of the `.csv`.
// Relevant code: https://github.com/sertalpbilal/FPL-Optimization-Tools/blob/a46d4fcac4b37be88715daed0ce54dbbf1ae4135/src/multi_period_dev.py#L1228
// Because of that, I cannot guarantee the consistency of tests and they are likely (almost certainly) going to fail when a season ends and a new one begins.
// There are two ways to deal with this
//  1. Maintain a fork. This will break an already established workflow for many and will be a big barrier of entry.
//  2. Rewrite the test whenever the data gets changed. As this test does not intend to E2E test the solver itself, we only care about the output and the way FPLOpticord parses it. This is the current solution
// Alternatively, we can also maintain a fork specifically used for testing purposes. Sounds promising, but as of right now, I'm going to resort to option 2.
// - xydone
test "regular solve" {
    const allocator = std.testing.allocator;
    var response = Response{
        .list = .init(allocator),
        .mutex = std.Thread.Mutex{},
    };
    defer response.list.deinit();
    const shared = Shared.get();

    const config_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shared.config_folder_path, "TEST_CONFIG.json" });
    defer allocator.free(config_path);

    regular(&response, allocator, config_path);

    const duped_response = try response.get(allocator);
    defer duped_response.deinit();

    const VALID_RESPONSES = [_][]const u8{ "M.Salah -> Fábio Vieira", "Isak -> Adu-Adjei", "M.Salah, Isak -> Fábio Vieira, Adu-Adjei" };

    for (duped_response.items, 0..) |result, i| {
        switch (result) {
            .solution => |solution| {
                const next = duped_response.items[i + 1];
                try std.testing.expectEqual(34, next.gameweek_moves.gameweek);
                try std.testing.expectEqualStrings(VALID_RESPONSES[solution.number - 1], next.gameweek_moves.moves);
            },
            else => {},
        }
        result.deinit(allocator);
    }
}
