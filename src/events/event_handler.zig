const std = @import("std");
const Discord = @import("discordzig");
const Cache = Discord.cache.TableTemplate{};
const Shard = Discord.Shard;

pub const Session = *Shard(Discord.cache.TableTemplate{});
// Individual handlers
const MessageHandler = @import("message_handler.zig").messageHandler;
const dotenv = @import("../util/dotenv.zig");
const wslpath = @import("../util/util.zig").wslpath;
const panic = @import("../util/util.zig").panic;

var shared: *Shared = undefined;

//consider adding a mutex and a set(...) function
pub const Shared = struct {
    allocator: std.mem.Allocator,
    is_wsl: bool,
    config_folder_path: []const u8,
    prefix: []const u8,
    solver_path: []const u8,

    /// Caller owns memory
    pub fn init(allocator: std.mem.Allocator) !void {
        shared = allocator.create(Shared) catch @panic("OOM");
        const env = try dotenv.init(allocator, ".env");
        const is_wsl = isWSL(allocator);

        const env_solver_path = env.get("optimization-tools-path") orelse panic(allocator, "No python solver path!", .{});
        const prefix = env.get("prefix") orelse panic(allocator, "No prefix provided!", .{});
        const config_path = try std.fs.cwd().realpathAlloc(allocator, "./config");
        const solver_path = if (is_wsl) try wslpath(allocator, env_solver_path, .from_windows_to_wsl) else env_solver_path;
        const config_folder_path = if (is_wsl) try wslpath(allocator, config_path, .from_wsl_to_windows) else config_path;

        shared.* = .{
            .allocator = allocator,
            .is_wsl = is_wsl,
            .prefix = prefix,
            .solver_path = solver_path,
            .config_folder_path = config_folder_path,
        };
    }
    pub fn deinit() void {
        shared.allocator.free(shared.config_folder_path);
        shared.allocator.free(shared.prefix);
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

    try MessageHandler(session, message, shared.*);
}

//TODO: make commands like get config work with reactions
pub fn reactionHandler(save: *anyopaque, log: Discord.MessageReactionAdd) anyerror!void {
    _ = save; // autofix
    _ = log; // autofix
}

const getDatetimeString = @import("../util/util.zig").getDatetimeString;

pub fn ready(save: *anyopaque, data: Discord.Ready) !void {
    _ = save; // autofix
    const datetime = try getDatetimeString(shared.allocator, .now);
    std.debug.print("{s} Logged in as \"{s}\" with prefix \"{s}\"\n", .{ datetime, data.user.username, shared.prefix });
}
