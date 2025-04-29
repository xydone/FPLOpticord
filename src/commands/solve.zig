const std = @import("std");
const Solver = @import("../wrapper/run_solve.zig");
const Discord = @import("discordzig");
const Cache = Discord.cache.TableTemplate{};
const Shard = Discord.Shard(Cache);
const types = @import("../types.zig");
const ManagedString = @import("../types.zig").ManagedString;
const Shared = @import("../events/event_handler.zig").Shared;

pub fn regular(session: *Shard, message: Discord.Message, content_it: *types.ContentIterator, shared: Shared) !void {
    const allocator = shared.allocator;
    var result = try session.sendMessage(message.channel_id, .{
        .content = "Starting regular run...",
    });
    defer result.deinit();
    const m = result.value.unwrap();

    var response = Solver.Response{
        .list = .init(allocator),
        .mutex = std.Thread.Mutex{},
    };
    defer response.list.deinit();

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    const config = content_it.next() orelse {
        const edit_msg_content = Discord.Partial(Discord.CreateMessage){
            .content = "⚠️ Config not provided! Stopping run...",
        };

        const edited_msg = try session.editMessage(message.channel_id, m.id, edit_msg_content);
        defer edited_msg.deinit();
        return;
    };
    const config_file = try std.fmt.allocPrint(allocator, "{s}_{s}.json", .{ message.author.id, config });
    defer allocator.free(config_file);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shared.config_folder_path, config_file });
    defer allocator.free(config_path);

    try pool.spawn(Solver.regular, .{ &response, allocator, config_path });

    var move_list = ManagedString.init(allocator);
    defer move_list.deinit();

    var gameweek_moves = ManagedString.init(allocator);
    defer gameweek_moves.deinit();

    var fields = std.ArrayList(Discord.EmbedField).init(allocator);
    defer fields.deinit();

    var solution_index: u8 = 0;

    outer: while (true) {
        const list = try response.get(allocator);
        defer list.deinit();
        for (list.items) |item| {
            switch (item) {
                .incorrect_config => {
                    const edit_msg_content = Discord.Partial(Discord.CreateMessage){
                        .content = "⚠️ Config file not found! Stopping run...",
                    };

                    const edited_msg = try session.editMessage(message.channel_id, m.id, edit_msg_content);
                    defer edited_msg.deinit();
                    break :outer;
                },
                .up_to_date => {
                    const content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ m.content.?, "Solver is up-to-date! ✅" });
                    defer allocator.free(content);

                    const edit_msg_content = Discord.Partial(Discord.CreateMessage){
                        .content = content,
                    };
                    const edited_msg = try session.editMessage(message.channel_id, m.id, edit_msg_content);
                    defer edited_msg.deinit();
                },
                .gameweek => |gw| {
                    const chip_active = if (gw.chip_active != null) try std.fmt.allocPrint(allocator, "{s} ACTIVE! 🔥", .{gw.chip_active.?}) else "";

                    var buy_transfers_list = ManagedString.init(allocator);
                    defer buy_transfers_list.deinit();

                    var sell_transfers_list = ManagedString.init(allocator);
                    defer sell_transfers_list.deinit();

                    for (gw.transfers) |transfer| {
                        switch (transfer.action) {
                            .buy => {
                                try buy_transfers_list.append(transfer.player);
                            },
                            .sell => {
                                try sell_transfers_list.append(transfer.player);
                            },
                        }
                    }

                    const buy_transfers = try std.mem.join(allocator, ",", try buy_transfers_list.list.toOwnedSlice());
                    defer allocator.free(buy_transfers);

                    const sell_transfers = try std.mem.join(allocator, ",", try sell_transfers_list.list.toOwnedSlice());
                    defer allocator.free(sell_transfers);

                    const gw_string = try std.fmt.allocPrint(allocator, "GW{d}:{s}{s}{s}{s}", .{
                        gw.gameweek,
                        chip_active,
                        buy_transfers,
                        if (buy_transfers.len != 0) " > " else "",
                        sell_transfers,
                    });
                    try gameweek_moves.append(gw_string);
                },
                .solution_start => {
                    solution_index += 1;
                },
                .solution_end => {
                    //TODO: fix memory leak (defer allocator.free(...) doesn't work due to global scope of fields)
                    const gameweeks = try std.mem.join(allocator, "\n", try gameweek_moves.list.toOwnedSlice());

                    //TODO: fix memory leak (defer allocator.free(...) doesn't work due to global scope of fields)
                    const solution_name = try std.fmt.allocPrint(allocator, "Solution {}", .{solution_index});
                    try fields.append(.{ .name = solution_name, .value = gameweeks });
                    const embed = Discord.Embed{
                        .title = try std.fmt.allocPrint(allocator, "Regular solve \"{s}\"", .{"example solve name"}),
                        // .description = "description",
                        .color = 0x804440,
                        .fields = fields.items,
                    };

                    defer allocator.free(embed.title.?);
                    var embeds = [_]Discord.Embed{embed};
                    const msg = try session.editMessage(message.channel_id, m.id, Discord.Partial(Discord.CreateMessage){
                        .embeds = &embeds,
                    });
                    defer msg.deinit();
                },
                .solver_error => |solver_error| {
                    std.debug.print("Solver error caught: {s}\n", .{solver_error.message});
                    const msg = Discord.Partial(Discord.CreateMessage){
                        .content = "The solver ran into an error!",
                    };

                    const edited_msg = try session.editMessage(message.channel_id, m.id, msg);
                    defer edited_msg.deinit();
                },
                .done => {
                    break :outer;
                },
                else => {
                    // std.debug.print("item: {}\n", .{item});
                },
            }
            response.remove(0);
        }
    }
}
