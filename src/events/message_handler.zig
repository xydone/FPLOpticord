const Discord = @import("discordzig");
const Shard = Discord.Shard;
const std = @import("std");
const Solve = @import("../commands/solve.zig");
const Config = @import("../commands/config.zig");
const types = @import("../types.zig");
const Session = @import("event_handler.zig").Session;
const Shared = @import("event_handler.zig").Shared;

pub fn messageHandler(session: Session, message: Discord.Message, shared: Shared) !void {
    const allocator = std.heap.smp_allocator;
    try handleCommand(Solve.regular, allocator, .{
        .name = "solveregular",
    }, session, message, shared);
    try handleCommand(Config.create, allocator, .{
        .name = "createconfig",
        .requirements = Requirements{ .attachment = true },
    }, session, message, shared);
    try handleCommand(Config.get, allocator, .{
        .name = "getconfig",
    }, session, message, shared);
    try handleCommand(Config.edit, allocator, .{
        .name = "editconfig",
    }, session, message, shared);
}

fn handleCommand(
    callback: *const fn (Session, Discord.Message, *types.ContentIterator, Shared) anyerror!void,
    allocator: std.mem.Allocator,
    options: CommandOptions,
    session: Session,
    message: Discord.Message,
    shared: Shared,
) !void {
    var content_it = std.mem.tokenizeSequence(u8, message.content.?, " ");
    _ = content_it.next();
    const command = try std.fmt.allocPrint(allocator, "{s}{s}", .{ shared.prefix, options.name });
    defer allocator.free(command);
    if (std.ascii.startsWithIgnoreCase(message.content.?, command)) {
        var timer = try std.time.Timer.start();
        var time_requirements: u64 = 0;
        var time_callback: u64 = 0;
        const logger = try MessageHandlerLogger.init(allocator, message.content.?, .{
            .requirements = &time_requirements,
            .callback = &time_callback,
        });
        defer logger.deinit();
        try logger.printReceived();
        defer logger.print() catch {};

        if (options.requirements) |requirements| {
            const success = try requirements.handle(message, session);
            time_requirements = timer.lap();
            if (!success) return;
        }
        try callback(session, message, &content_it, shared);
        time_callback = timer.lap();
    }
}

const CommandOptions = struct {
    name: []const u8,
    requirements: ?Requirements = null,
};

const Requirements = struct {
    attachment: bool = false,

    /// Returns if the command matches the requirements
    pub fn handle(self: *const Requirements, message: Discord.Message, session: Session) !bool {
        if (self.attachment == true) {
            if (message.attachments.len == 0) {
                const msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
                    .content = "Attachments missing!",
                });
                defer msg.deinit();

                return false;
            }
        }
        return true;
    }
};

const getDatetimeString = @import("../util/util.zig").getDatetimeString;

pub const MessageHandlerLogger = struct {
    id: []const u8,
    allocator: std.mem.Allocator,
    command: []const u8,
    times: Times,

    pub fn init(allocator: std.mem.Allocator, command: []const u8, times: Times) !MessageHandlerLogger {
        const command_no_space = try std.mem.replaceOwned(u8, allocator, command, " ", "");
        defer allocator.free(command_no_space);
        var prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        const random_number = prng.random().int(u8);
        const id = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ command_no_space, random_number });
        return MessageHandlerLogger{
            .id = id,
            .allocator = allocator,
            .command = command,
            .times = times,
        };
    }

    pub fn deinit(self: MessageHandlerLogger) void {
        self.allocator.free(self.id);
    }

    pub const Times = struct {
        requirements: *u64,
        callback: *u64,
    };

    /// Caller owns memory
    fn _printReceived(self: MessageHandlerLogger) ![]u8 {
        const datetime = try getDatetimeString(self.allocator, .now);
        defer self.allocator.free(datetime);

        return try std.fmt.allocPrint(self.allocator, "{s} \"{s}\" received! (id: {s})\n", .{
            datetime,
            self.command,
            self.id,
        });
    }

    /// Caller owns memory
    fn _print(self: MessageHandlerLogger) ![]u8 {
        const datetime = try getDatetimeString(self.allocator, .now);
        defer self.allocator.free(datetime);

        const total_time = self.times.requirements.* + self.times.callback.*;

        return try std.fmt.allocPrint(self.allocator, "{s} \"{s}\" in {s}{d:.2}ms\x1b[0m (requirements: {d:.2}ms, callback: {d:.2}ms) (id: {s})\n", .{
            datetime,
            self.command,
            //arbitrary 2s
            switch (total_time < 2 * std.time.ns_per_s) {
                //ansi coloring (https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797)
                //green
                true => "\x1b[32m",
                //red
                false => "\x1b[31m",
            },
            @as(f64, @floatFromInt(total_time)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(self.times.requirements.*)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(self.times.callback.*)) / std.time.ns_per_ms,
            self.id,
        });
    }
    /// Coloring depends on execution time, rather than execution status.
    ///
    /// TODO: make it depend on execution status
    pub fn print(self: MessageHandlerLogger) !void {
        const string = try self._print();
        defer self.allocator.free(string);
        std.debug.print("{s}", .{string});
    }
    pub fn printReceived(self: MessageHandlerLogger) !void {
        const string = try self._printReceived();
        defer self.allocator.free(string);
        std.debug.print("{s}", .{string});
    }
};

test "MessageHandlerLogger" {
    const allocator = std.testing.allocator;

    var time_requirements: u64 = 0;
    var time_callback: u64 = 5000;
    const logger = try MessageHandlerLogger.init(allocator, "!testcommand", .{
        .requirements = &time_requirements,
        .callback = &time_callback,
    });
    defer logger.deinit();
    const printReceived = try logger._printReceived();
    defer allocator.free(printReceived);
    const print = try logger._print();
    defer allocator.free(print);

    const expected_print_received = try std.fmt.allocPrint(allocator, "\"{s}\" received! (id: {s})\n", .{ logger.command, logger.id });
    defer allocator.free(expected_print_received);
    const expected_print = try std.fmt.allocPrint(allocator, "\"{s}\" in \x1b[32m0.01ms\x1b[0m (requirements: 0.00ms, callback: 0.01ms) (id: {s})\n", .{ logger.command, logger.id });
    defer allocator.free(expected_print);

    try std.testing.expectStringEndsWith(printReceived, expected_print_received);
    try std.testing.expectStringEndsWith(print, expected_print);
}
