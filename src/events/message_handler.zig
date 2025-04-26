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
        const logger = MessageHandlerLogger.init(allocator, message.content.?, .{
            .requirements = &time_requirements,
            .callback = &time_callback,
        });
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
    allocator: std.mem.Allocator,
    command: []const u8,
    times: Times,

    pub fn init(allocator: std.mem.Allocator, command: []const u8, times: Times) MessageHandlerLogger {
        return MessageHandlerLogger{
            .allocator = allocator,
            .command = command,
            .times = times,
        };
    }

    pub const Times = struct {
        requirements: *u64,
        callback: *u64,
    };

    /// Coloring depends on execution time, rather than execution status.
    ///
    /// TODO: make it depend on execution status
    pub fn print(self: MessageHandlerLogger) !void {
        const datetime = try getDatetimeString(self.allocator, .now);

        const total_time = self.times.requirements.* + self.times.callback.*;

        std.debug.print("{s} \"{s}\" in {s}{d:.2}ms\x1b[0m (requirements: {d:.2}ms, callback: {d:.2}ms)\n", .{
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
        });
    }
};
