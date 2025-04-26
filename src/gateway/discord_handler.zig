const Discord = @import("discordzig");
const Cache = Discord.cache.TableTemplate{};
const Shard = @import("discordzig").Shard(Cache);
const std = @import("std");
const panic = @import("../util/util.zig").panic;

allocator: std.mem.Allocator,
sharder: Discord.Sharder(Cache),
token: []const u8,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .sharder = undefined,
        .token = undefined,
    };
}

pub fn deinit(self: *Self) void {
    self.sharder.deinit();
}

pub fn start(self: *Self, settings: struct {
    token: []const u8,
    intents: Discord.Intents,
    options: Options,
    run: Discord.Internal.GatewayDispatchEvent,
    log: Discord.Internal.Log,
    cache: Discord.cache.TableTemplate,
}) !void {
    self.token = settings.token;
    var req = Discord.FetchReq.init(self.allocator, settings.token);
    defer req.deinit();

    const res = try req.makeRequest(.GET, "/gateway/bot", null);
    const body = try req.body.toOwnedSlice();
    defer self.allocator.free(body);

    if (res.status != std.http.Status.ok) {
        panic(self.allocator, "Incorrect status\n", .{});
    }

    const parsed = try std.json.parseFromSlice(Discord.Internal.GatewayBotInfo, self.allocator, body, .{});
    defer parsed.deinit();

    self.sharder = try Discord.Sharder(Cache).init(self.allocator, .{
        .token = settings.token,
        .intents = settings.intents,
        .run = settings.run,
        .options = Discord.Sharder(Cache).SessionOptions{
            .info = parsed.value,
            .shard_start = settings.options.shard_start,
            .shard_end = @intCast(parsed.value.shards),
            .total_shards = @intCast(parsed.value.shards),
            .spawn_shard_delay = settings.options.spawn_shard_delay,
            //casting, kinda stinky code
            .resharding = if (settings.options.resharding == null) null else .{
                .interval = settings.options.resharding.?.interval,
                .percentage = settings.options.resharding.?.percentage,
            },
            .shard_lifespan = settings.options.shard_lifespan,
            .workers_per_shard = settings.options.workers_per_shard,
        },
        .log = settings.log,
        .cache = settings.cache,
    });

    try self.sharder.spawnShards();
}

pub const Options = struct {
    /// Delay in milliseconds to wait before spawning next shard. OPTIMAL IS ABOVE 5100. YOU DON'T WANT TO HIT THE RATE LIMIT!!!
    spawn_shard_delay: ?u64 = 5300,
    /// Total amount of shards your bot uses. Useful for zero-downtime updates or resharding.
    total_shards: usize = 1,
    shard_start: usize = 0,
    shard_end: usize = 1,
    /// The payload handlers for messages on the shard.
    resharding: ?struct { interval: u64, percentage: usize } = null,
    /// worker threads
    workers_per_shard: usize = 1,
    /// The shard lifespan in milliseconds. If a shard is not connected within this time, it will be closed.
    shard_lifespan: ?u64 = null,
};
