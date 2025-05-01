const std = @import("std");
const types = @import("../types.zig");
const dotenv = @import("../util/dotenv.zig");
const Shared = @import("../events/event_handler.zig").Shared;
const panic = @import("../util/util.zig").panic;

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
    var env = dotenv.init(allocator, ".env") catch panic(allocator, "Can't get env", .{});
    defer env.deinit();
    const shared = Shared.get();
    var env_map = std.process.getEnvMap(allocator) catch unreachable;
    defer env_map.deinit();
    const config_location = std.fmt.allocPrint(allocator, "--config={s}", .{config}) catch @panic("OOM");
    defer allocator.free(config_location);

    //NOTE: Calling python.exe will bypass the Python installation (if one exists) in WSL. To use the WSL version, use `python` instead.
    const python_executable = if (shared.is_wsl) "python.exe" else "python";
    //using -W ignore::FutureWarning due to Pandas' .replace(...) downcast deprecation warning
    const argv = &.{ python_executable, "-W", "ignore::FutureWarning", "-u", "solve_regular.py", config_location };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = shared.solver_path;
    child.expand_arg0 = .no_expand;
    child.progress_node = std.Progress.Node.none;
    env_map.put("PYTHONIOENCODING", "utf-8") catch |err| panic(allocator, "Failed to put PYTHONIOENCODING into env-map due to {}", .{err});
    if (shared.is_wsl) env_map.put("WSLENV", "PYTHONIOENCODING") catch |err| panic(allocator, "Failed to put WSLENV into env-map due to {}", .{err});

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
    var buf: [2056]u8 = undefined;
    while (true) {
        const stdout_len = stdout_reader.read(&buf) catch |err| {
            std.debug.print("stdout reader failed with: {}\n", .{err});
            break;
        };
        if (stdout_len == 0) break;
        if (std.mem.eql(u8, buf[0..stdout_len], "\r\n")) continue;
        const process_state = parseOutput(buf[0..stdout_len], response, allocator);

        if (process_state.running == false) {
            _ = child.kill() catch panic(allocator, "Could not terminate process", .{});
            return;
        }
    }

    var stderr_buf: [2056]u8 = undefined;
    // read from stderr
    const stderr_len = stderr_reader.read(&stderr_buf) catch |err| {
        std.debug.print("stderr reader failed with: {}\n", .{err});
        return;
    };

    // check if the solver ran into an error
    if (stderr_len != 0) {
        response.append(.{ .solver_error = SolverError{ .message = stderr_buf[0..stderr_len] } }) catch panic(allocator, "Cannot append", .{});
        return;
    }

    _ = child.wait() catch unreachable;
    response.append(.{ .done = Done{} }) catch panic(allocator, "Cannot append", .{});
}

const SolveProcessState = struct { running: bool };
fn parseOutput(
    message: []u8,
    response: *Response,
    allocator: std.mem.Allocator,
) SolveProcessState {
    const states = Result.fromString(allocator, message) catch std.debug.panic("State parsing failed!", .{});
    defer states.deinit();

    for (states.items) |state| {
        if (state == .incorrect_config) {
            response.append(.{ .incorrect_config = IncorrectConfig{} }) catch panic(allocator, "Cannot append", .{});
            return .{ .running = false };
        }
        response.append(state) catch panic(allocator, "Cannot append", .{});
    }
    return .{ .running = true };
}

const Outputs = enum {
    incorrect_config,
    up_to_date,
    result_summary,
    solution_start,
    solution_end,
    unparsed,
    done,
    solver_error,
    gameweek,

    const RawOutputs = enum {
        @"Your repository is up-to-date.",
        @"Result Summary",
    };
};

pub const Result = union(Outputs) {
    incorrect_config: IncorrectConfig,
    up_to_date: UpToDate,
    result_summary: ResultSummary,
    solution_start: SolutionStart,
    solution_end: SolutionEnd,
    unparsed: Unparsed,
    done: Done,
    solver_error: SolverError,
    gameweek: Gameweek,

    /// Caller owns memory
    pub fn fromString(allocator: std.mem.Allocator, buf: []u8) !std.ArrayList(Result) {
        // std.debug.print("=== buf start: ===\n{s}\n=== buf end ==\n", .{buf});
        var state_list = std.ArrayList(Result).init(allocator);
        if (try Gameweek.parse(buf, allocator, &state_list)) return state_list;
        if (state_list.items.len == 0) {
            const unparsed = Result{ .unparsed = Unparsed{} };
            try state_list.append(unparsed);
            return state_list;
        }
        unreachable;
    }

    pub fn deinitSlice(slice: []Result, allocator: std.mem.Allocator) void {
        for (slice) |result| {
            result.deinitAny(allocator);
        }
    }

    pub fn deinitAny(result: Result, allocator: std.mem.Allocator) void {
        switch (result) {
            inline else => |any| {
                if (std.meta.hasFn(@TypeOf(any), "deinit")) {
                    any.deinit(allocator);
                }
            },
        }
    }
};

const IncorrectConfig = struct {};
const UpToDate = struct {};
const ResultSummary = struct {};
const SolutionStart = struct {};
const SolutionEnd = struct {};

pub const Transfers = struct {
    action: TransferAction,
    player: []const u8,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; // autofix
        _ = options; // autofix

        try writer.writeAll("Transfers{");
        try writer.print(" .action = {any}", .{self.action});
        try writer.print(" .player = \"{s}\"", .{self.player});
        try writer.writeAll(" }");
    }

    /// Only necessary if player was allocated, such as what happens during the solve process.
    pub fn deinitSlice(slice: []Transfers, allocator: std.mem.Allocator) void {
        for (slice) |transfer| {
            allocator.free(transfer.player);
        }
    }

    pub const TransferAction = enum { buy, sell };
};
const Gameweek = struct {
    gameweek: u8,
    chip_active: ?[]const u8,
    free_transfers: u32,
    paid_transfers: u8,
    net_transfers: u8,
    transfers: []Transfers,
    /// meant to be freed after usage
    buf: []const u8,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; // autofix
        _ = options; // autofix
        const chip_quotes = if (self.chip_active != null) "\"" else "";
        try writer.writeAll("Gameweek{");
        try writer.print(" .gameweek = {d}", .{self.gameweek});
        try writer.print(" .chip_active: {s}{?s}{s},", .{ chip_quotes, self.chip_active, chip_quotes });
        try writer.print(" .free_transfers = {d}", .{self.free_transfers});
        try writer.print(" .paid_transfers = {d}", .{self.paid_transfers});
        try writer.print(" .net_transfers = {d}", .{self.net_transfers});
        try writer.print(" .transfers = {any}", .{self.transfers});
        try writer.writeAll(" }");
    }

    pub fn deinit(self: Gameweek, allocator: std.mem.Allocator) void {
        Transfers.deinitSlice(self.transfers, allocator);
        allocator.free(self.transfers);
    }

    pub fn parse(buf: []u8, allocator: std.mem.Allocator, list: *std.ArrayList(Result)) !bool {
        // neat workaround as only the relevant lines are printed as "GW " ("GW" with space char) and the other ones that involve the string "GW" do not have the space char.
        var gameweek_it = std.mem.tokenizeSequence(u8, buf, "GW ");
        if (gameweek_it.next()) |gw| {
            // delimeter not found
            if (std.mem.eql(u8, buf, gw)) return false;
            //this means we do have an actual solution
            try list.append(.{ .solution_start = SolutionStart{} });
            defer list.append(.{ .solution_end = SolutionEnd{} }) catch @panic("Cannot append!");
            while (gameweek_it.next()) |solution| {
                var lines = std.mem.tokenizeSequence(u8, solution, "\r\n");
                var chip: ?[]const u8 = null;
                //Lines template:
                //GW: <number>
                //ITB=<number> ...
                //CHIP <CHIP>
                //Buy/Sell <ID> ...

                // handle gameweek number
                const gameweek_line = lines.next().?;
                var colon_it = std.mem.tokenizeSequence(u8, gameweek_line, ":");
                const gameweek_number = std.fmt.parseInt(u8, colon_it.next().?, 10) catch |err| std.debug.panic("Parsing gameweek number failed with {}", .{err});
                var itb: ?[]const u8 = undefined;
                var ft: ?u8 = undefined;
                var pt: ?u8 = undefined;
                var nt: ?u8 = undefined;
                var transfers = std.ArrayList(Transfers).init(allocator);
                defer transfers.deinit();

                line_loop: while (lines.next()) |line| {
                    // parsing transfer values
                    if (std.mem.startsWith(u8, line, "ITB")) {
                        const replaced = try std.mem.replaceOwned(u8, allocator, line, ", ", "=");
                        defer allocator.free(replaced);
                        var it = std.mem.tokenizeSequence(u8, replaced, "=");
                        _ = it.next();
                        itb = it.next().?;
                        _ = it.next();
                        ft = try std.fmt.parseInt(u8, it.next().?, 10);
                        _ = it.next();
                        pt = try std.fmt.parseInt(u8, it.next().?, 10);
                        _ = it.next();
                        nt = try std.fmt.parseInt(u8, it.next().?, 10);

                        continue :line_loop;
                    }
                    // parsing transfers
                    // true - it is a buy line
                    // false - it is a sell line
                    // null - it is neither
                    var transfer_action: ?Transfers.TransferAction = null;
                    buy_or_sell: {
                        if (std.mem.startsWith(u8, line, "Buy")) {
                            transfer_action = .buy;
                            break :buy_or_sell;
                        }
                        if (std.mem.startsWith(u8, line, "Sell")) {
                            transfer_action = .sell;
                            break :buy_or_sell;
                        }
                    }
                    if (transfer_action != null) {
                        var player_it = std.mem.tokenizeSequence(u8, line, " - ");
                        _ = player_it.next();
                        const player = try allocator.dupe(u8, player_it.next().?);
                        try transfers.append(Transfers{
                            .action = transfer_action.?,
                            .player = player,
                        });
                        continue :line_loop;
                    }
                    // is chip active?
                    if (std.mem.startsWith(u8, line, "CHIP")) {
                        var chip_line = std.mem.tokenizeSequence(u8, line, " ");
                        _ = chip_line.next();
                        chip = chip_line.next().?;
                        continue :line_loop;
                    }
                    // is it the separator line?
                    if (std.mem.startsWith(u8, line, "---")) {
                        continue :line_loop;
                    }
                }

                try list.append(Result{ .gameweek = .{
                    .gameweek = gameweek_number,
                    .chip_active = chip,
                    .free_transfers = ft orelse std.debug.panic("Not defined!", .{}),
                    .paid_transfers = pt orelse std.debug.panic("Not defined!", .{}),
                    .net_transfers = nt orelse std.debug.panic("Not defined!", .{}),
                    .transfers = try transfers.toOwnedSlice(),
                    .buf = buf,
                } });
            }
        }
        return true;
    }
};
const Unparsed = struct {};
const Done = struct {};
const SolverError = struct {
    message: []const u8,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; // autofix
        _ = options; // autofix
        try writer.writeAll("SolverError{");
        try writer.print(" .message = {s}", .{self.message});
        try writer.writeAll(" }");
    }
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
    defer Result.deinitSlice(response.list.items, allocator);

    const shared = Shared.get();

    const config_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shared.config_folder_path, "TEST_CONFIG.json" });
    defer allocator.free(config_path);

    regular(&response, allocator, config_path);

    // const duped_response = try response.get(allocator);
    // defer duped_response.deinit();

    var first_iteration = [_]Transfers{
        Transfers{ .action = .buy, .player = "Fábio Vieira" },
        Transfers{ .action = .sell, .player = "M.Salah" },
    };
    var second_iteration = [_]Transfers{
        Transfers{ .action = .buy, .player = "Adu-Adjei" },
        Transfers{ .action = .sell, .player = "Isak" },
    };
    var third_iteration = [_]Transfers{
        Transfers{ .action = .buy, .player = "Fábio Vieira" },
        Transfers{ .action = .buy, .player = "Adu-Adjei" },
        Transfers{ .action = .sell, .player = "Isak" },
        Transfers{ .action = .sell, .player = "M.Salah" },
    };
    const iterations = [_][]Transfers{ &first_iteration, &second_iteration, &third_iteration };

    var iteration: u8 = 0;

    for (response.list.items) |result| {
        switch (result) {
            .solution_end => iteration += 1,
            .gameweek => |gw| {
                for (gw.transfers, 0..) |transfers, i| {
                    try std.testing.expectEqual(iterations[iteration][i].action, transfers.action);
                    try std.testing.expectEqualStrings(iterations[iteration][i].player, transfers.player);
                }
            },
            else => {},
        }
    }
}
