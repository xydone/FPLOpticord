const std = @import("std");
const Discord = @import("discordzig");
const dotenv = @import("util/dotenv.zig");
const Cache = Discord.cache.TableTemplate{};
const Shard = Discord.Shard(Cache);
const builtin = @import("builtin");

const DiscordHandler = @import("gateway/discord_handler.zig");
const EventHandler = @import("events/event_handler.zig");
const Shared = @import("events/event_handler.zig").Shared;
const wslpath = @import("util/util.zig").wslpath;

//GUILDS, GUILD_MESSAGES, MESSAGE_CONTENT = 33281
//GUILDS, GUILD_MESSAGES, MESSAGE_CONTENT, GUILD_MESSAGE_REACTIONS = 34305
const INTENTS = 34305;
pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const env = try dotenv.init(allocator, ".env");
    const env_token = env.get("token") orelse return error.NoToken;
    const token = try std.fmt.allocPrint(allocator, "Bot {s}", .{env_token});
    defer allocator.free(token);

    // discord.zig handler:
    // var discord_handler = Discord.init(allocator);
    // defer discord_handler.deinit();
    var discord_handler = DiscordHandler.init(allocator);
    defer discord_handler.deinit();

    const is_wsl = Shared.isWSL(allocator);

    const env_solver_path = env.get("optimization-tools-path") orelse @panic("No python solver path");
    const config_path = try std.fs.cwd().realpathAlloc(allocator, "./config");
    defer allocator.free(config_path);

    const solver_path = if (is_wsl) try wslpath(allocator, env_solver_path, .from_windows_to_wsl) else env_solver_path;
    defer allocator.free(solver_path);
    const config_folder_path = if (is_wsl) try wslpath(allocator, config_path, .from_wsl_to_windows) else config_path;
    defer allocator.free(config_folder_path);

    Shared.init(allocator, .{
        .allocator = allocator,
        .is_wsl = is_wsl,
        .solver_path = solver_path,
        .config_folder_path = config_folder_path,
    });
    defer Shared.deinit();

    try discord_handler.start(.{
        .intents = Discord.Intents.fromRaw(INTENTS),
        .token = token,
        .run = .{
            .message_create = &EventHandler.messageHandler,
            .ready = &EventHandler.ready,
            .message_reaction_add = &EventHandler.reactionHandler,
        },
        .options = .{
            .spawn_shard_delay = 6000,
            .total_shards = 5,
            .shard_start = 0,
            .shard_end = 5,
            .workers_per_shard = 5,
        },
        .cache = Cache,
        .log = Discord.Internal.Log.no,
    });
}

const copyFileAndBackup = @import("util/util.zig").copyFileAndBackup;
const Tests = @import("tests/environment.zig");

test "Setup tests:beforeAll" {
    const allocator = std.testing.allocator;

    try Tests.TestEnvironment.init();
    var test_env = Tests.test_env;

    const is_wsl = Shared.isWSL(allocator);

    const env_solver_path = test_env.env.get("optimization-tools-path") orelse @panic("No python solver path");
    const config_path = try std.fs.cwd().realpathAlloc(allocator, "./config");
    // defer allocator.free(config_path);

    const solver_path = if (is_wsl) try wslpath(allocator, env_solver_path, .from_windows_to_wsl) else env_solver_path;
    const config_folder_path = if (is_wsl) try wslpath(allocator, config_path, .from_wsl_to_windows) else config_path;

    Shared.init(allocator, .{
        .allocator = allocator,
        .is_wsl = is_wsl,
        .solver_path = solver_path,
        .config_folder_path = config_folder_path,
    });

    const player_data_path = try std.fs.cwd().realpathAlloc(allocator, "./config/player_data/");
    defer allocator.free(player_data_path);

    // Move the test player data to the correct directory
    try copyFileAndBackup(allocator, .{
        .path = player_data_path,
        .file_name = "TEST_PLAYER_DATA.csv",
    }, .{
        .path = solver_path,
        .file_name = "../data/fplreview.csv",
    }, .{ .append_custom_string = .{ .name = "fplreview", .string = "TEMPORARY", .extension = ".csv" } });

    // Move the test team data to the correct directory
    try copyFileAndBackup(allocator, .{
        .path = player_data_path,
        .file_name = "../team/TEST_TEAM.json",
    }, .{
        .path = solver_path,
        .file_name = "../data/team.json",
    }, .{ .append_custom_string = .{ .name = "../team/team", .string = "TEMPORARY", .extension = ".json" } });

    std.testing.refAllDecls(@This());
}

test "Teardown tests:afterAll" {
    var test_env = Tests.test_env;
    defer test_env.deinit();
    const shared = Shared.get();
    const env_solver_path = test_env.env.get("optimization-tools-path") orelse @panic("No python solver path");
    const solver_path = if (shared.is_wsl) try wslpath(test_env.allocator, env_solver_path, .from_windows_to_wsl) else env_solver_path;
    // We use the testing environment allocator here as this is ran after `std.testing.allocator.deinit(...)` is executed by the test runner.
    // Using a test allocator here would result in a General protection exception.
    // We opt out of memory leak detection for this part of the code, but it *shouldn't* be a issue.
    const player_data_path = try std.fs.cwd().realpathAlloc(test_env.allocator, "./config/player_data/");
    defer test_env.allocator.free(player_data_path);

    // Revert the files back to original state before tests
    try copyFileAndBackup(test_env.allocator, .{
        .path = player_data_path,
        .file_name = "fplreview_TEMPORARY.csv",
    }, .{
        .path = solver_path,
        .file_name = "../data/fplreview.csv",
    }, .false);
    try std.fs.cwd().deleteFile("./config/player_data/fplreview_TEMPORARY.csv");

    try copyFileAndBackup(test_env.allocator, .{
        .path = player_data_path,
        .file_name = "../team/team_TEMPORARY.json",
    }, .{
        .path = solver_path,
        .file_name = "../data/team.json",
    }, .false);
    try std.fs.cwd().deleteFile("./config/team/team_TEMPORARY.json");
}
