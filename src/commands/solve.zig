const std = @import("std");
const Solver = @import("../wrapper/run_solve.zig");
const Discord = @import("discordzig");
const Cache = Discord.cache.TableTemplate{};
const Shard = Discord.Shard(Cache);
const types = @import("../types.zig");
const Shared = @import("../events/event_handler.zig").Shared;

/// Move list array which manages the memory of the `std.ArrayList` inside alongside the memory of the contents.
pub const MoveList = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) MoveList {
        return MoveList{ .allocator = allocator, .list = std.ArrayList([]const u8).init(allocator) };
    }

    pub fn append(self: *MoveList, string: []const u8) !void {
        try self.list.append(string);
    }

    pub fn deinit(
        self: *MoveList,
    ) void {
        for (self.list.items) |item| {
            self.allocator.free(item);
        }
        self.list.deinit();
    }
};

pub fn regular(session: *Shard, message: Discord.Message, content_it: *types.ContentIterator, shared: Shared) !void {
    const allocator = std.heap.smp_allocator;
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

    var move_list = MoveList.init(allocator);
    defer move_list.deinit();

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
                .solution => |solution| {
                    const prefix = switch (solution.number) {
                        1 => "🏆 ",
                        2 => "🥈 ",
                        3 => "🥉 ",
                        else => "",
                    };
                    const solution_string = try std.fmt.allocPrint(allocator, "{s}Solution {d}:", .{ prefix, solution.number });

                    try move_list.append(solution_string);
                },
                .gameweek_moves => |gameweek_moves| {
                    const move = try std.fmt.allocPrint(allocator, "GW{d}: {s}", .{ gameweek_moves.gameweek, gameweek_moves.moves });

                    try move_list.append(move);
                },
                .done => {
                    const move_string = try std.mem.join(allocator, "\n", move_list.list.items);
                    defer allocator.free(move_string);

                    const content = try std.fmt.allocPrint(allocator, "Solve complete!\n{s}", .{move_string});
                    defer allocator.free(content);

                    const edit_msg_content = Discord.Partial(Discord.CreateMessage){
                        .content = content,
                    };

                    const edited_msg = try session.editMessage(message.channel_id, m.id, edit_msg_content);
                    defer edited_msg.deinit();
                    break :outer;
                },
                .solver_error => |solver_error| {
                    std.debug.print("Solver error caught: {s}\n", .{solver_error.message});
                    const msg = Discord.Partial(Discord.CreateMessage){
                        .content = "The solver ran into an error!",
                    };

                    const edited_msg = try session.editMessage(message.channel_id, m.id, msg);
                    defer edited_msg.deinit();
                },
                else => {
                    // std.debug.print("item: {}\n", .{item});
                },
            }
            response.remove(0);
        }
    }
}
