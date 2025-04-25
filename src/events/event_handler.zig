const std = @import("std");
const Discord = @import("discordzig");
const Cache = Discord.cache.TableTemplate{};
const Shard = Discord.Shard;

pub const Session = *Shard(Discord.cache.TableTemplate{});
// Individual handlers
const MessageHandler = @import("message_handler.zig").messageHandler;

var shared: *Shared = undefined;

//consider adding a mutex and a set(...) function
pub const Shared = struct {
    allocator: std.mem.Allocator,
    is_wsl: bool,
    config_folder_path: []const u8,
    solver_path: []const u8,

    /// Caller owns memory
    pub fn init(allocator: std.mem.Allocator, provided: Shared) void {
        shared = allocator.create(Shared) catch @panic("OOM");
        shared.* = provided;
    }
    pub fn deinit() void {
        shared.allocator.free(shared.config_folder_path);
        shared.allocator.free(shared.solver_path);
        shared.allocator.destroy(shared);
    }

    pub fn get() Shared {
        return shared.*;
    }

    pub fn isWSL(allocator: std.mem.Allocator) bool {
        var env_map = std.process.getEnvMap(allocator) catch unreachable;
        defer env_map.deinit();
        return if (env_map.get("WSL_DISTRO_NAME") != null) true else false;
    }
};

pub fn messageHandler(shard_ptr: *anyopaque, message: Discord.Message) !void {
    const session: *Shard(Cache) = @ptrCast(@alignCast(shard_ptr));

    try MessageHandler(session, message, Shared.get());
}

//TODO: make commands like get config work with reactions
pub fn reactionHandler(save: *anyopaque, log: Discord.MessageReactionAdd) anyerror!void {
    _ = save; // autofix
    _ = log; // autofix
}

pub fn ready(save: *anyopaque, data: Discord.Ready) !void {
    _ = save; // autofix
    std.debug.print("logged in as {s}\n", .{data.user.username});
}
