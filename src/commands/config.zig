const std = @import("std");
const Discord = @import("discordzig");
const Cache = Discord.cache.TableTemplate{};
const Shard = Discord.Shard(Cache);
const types = @import("../types.zig");
const util = @import("../util/util.zig");
const json = @import("../util/json.zig");
const Shared = @import("../events/event_handler.zig").Shared;

pub fn create(session: *Shard, message: Discord.Message, content_it: *std.mem.TokenIterator(u8, .sequence), shared: Shared) !void {
    _ = shared; // autofix
    //TODO: use one singular allocator
    const allocator = std.heap.smp_allocator;
    if (!std.mem.endsWith(u8, message.attachments[0].filename, ".json")) {
        const msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
            .content = "⚠️ The attachment is not `.json`",
        });
        defer msg.deinit();
        return;
    }

    //Expected arguments
    // 1. file name
    // 2. override status (optional)
    const EXPECTED_ARGUMENTS = 2;
    //This could probably be slightly better if we instead do a prefilled with nulls variable, however for future consistency sake I think this makes sense
    var args = try std.ArrayList([]const u8).initCapacity(allocator, EXPECTED_ARGUMENTS);
    defer args.deinit();
    var i: u8 = 0;
    while (content_it.next()) |arg| : (i += 1) {
        if (i == EXPECTED_ARGUMENTS) break;
        try args.append(arg);
    }

    const file_name = args.items[0];
    const maybe_override = if (args.items.len == EXPECTED_ARGUMENTS) args.items[1] else null;
    const exclusive = if (maybe_override) |override| !std.mem.eql(u8, override, "override") else true;

    const output_file_path = try std.fmt.allocPrint(allocator, "config/{s}_{s}.json", .{
        message.author.id,
        file_name,
    });
    defer allocator.free(output_file_path);

    _ = util.saveFileFromAPI(allocator, message.attachments[0].url, output_file_path, .{ .exclusive = exclusive }) catch |err| switch (err) {
        error.FileNotJson => {
            const invalid_json_msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
                .content = "⚠️ The attachment is not valid `.json`",
            });
            defer invalid_json_msg.deinit();
            return;
        },
        error.PathAlreadyExists => {
            const config_exists_msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
                .content = "⚠️ Config with that name exists. If you want to override it, add `override` at the end of the command!",
            });
            defer config_exists_msg.deinit();
            return;
        },
        else => {
            return err;
        },
    };
    const success_msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
        .content = "✅ Success!",
    });
    defer success_msg.deinit();
}

pub fn get(session: *Shard, message: Discord.Message, content_it: *std.mem.TokenIterator(u8, .sequence), shared: Shared) !void {
    _ = shared; // autofix
    //TODO: use one singular allocator
    const allocator = std.heap.smp_allocator;
    //Expected arguments
    // 1. config name
    // 2. config page (defaults to 1)
    const config_name = content_it.next() orelse return error.ConfigNameNotProvided;
    const config_page = try std.fmt.parseInt(u8, content_it.next() orelse "1", 10);

    const LINES_PER_PAGE = 24;
    const STARTING_INDEX = (config_page - 1) * LINES_PER_PAGE;

    const file_path = try std.fmt.allocPrint(allocator, "config/{s}_{s}.json", .{
        message.author.id,
        config_name,
    });
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var fields = std.ArrayList(Discord.EmbedField).init(allocator);
    defer fields.deinit();
    const config = try parseConfig(allocator, file);
    var it = config.value.object.iterator();
    var i: usize = STARTING_INDEX;

    //skip to the starting index
    for (0..STARTING_INDEX) |_| {
        const skip = it.next();
        if (skip == null) {
            const msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
                .content = "Page out of bounds!",
            });
            defer msg.deinit();
            return;
        }
    }

    while (it.next()) |entry| {
        if (i == STARTING_INDEX + LINES_PER_PAGE) break;
        i += 1;
        const string = try formatJsonValue(allocator, entry);
        // defer allocator.free(string); // breaks output
        try fields.append(.{ .name = entry.key_ptr.*, .value = string, .@"inline" = true });
    }

    const embed = Discord.Embed{
        .title = try std.fmt.allocPrint(allocator, "Config \"{s}\"", .{config_name}),
        // .description = "description",
        .color = 0x804440,
        .fields = try fields.toOwnedSlice(),
        .footer = Discord.EmbedFooter{
            .text = try std.fmt.allocPrint(allocator, "Page {}/{}", .{ config_page, try std.math.divCeil(u32, it.len, LINES_PER_PAGE) }),
        },
    };
    defer allocator.free(embed.title.?);
    defer allocator.free(embed.footer.?.text);

    var embeds = [_]Discord.Embed{embed};

    const msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
        .embeds = &embeds,
    });
    defer msg.deinit();
}

pub fn edit(session: *Shard, message: Discord.Message, content_it: *std.mem.TokenIterator(u8, .sequence), shared: Shared) !void {
    _ = shared; // autofix
    //TODO: use one singular allocator
    const allocator = std.heap.smp_allocator;
    //Expected arguments
    // 1. config name
    // 2. field to edit
    // 3. new value for field
    const config_name = content_it.next() orelse return error.ConfigNameNotProvided;
    const config_field = content_it.next() orelse return error.ConfigFieldNotProvided;
    const config_value = content_it.next() orelse return error.ConfigValueNotProvided;

    const file_path = try std.fmt.allocPrint(allocator, "config/{s}_{s}.json", .{
        message.author.id,
        config_name,
    });
    const file = try std.fs.cwd().openFile(file_path, std.fs.File.OpenFlags{ .mode = .read_write });
    defer file.close();

    var config = try parseConfig(allocator, file);

    const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, config_value, .{ .parse_numbers = false });

    try config.value.object.put(config_field, parsed_value.value);

    const write_file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer write_file.close();

    const new_config = try json.jsonStringify(allocator, config.value, .{});
    defer allocator.free(new_config);

    _ = write_file.write(new_config) catch {
        const msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
            .content = "⚠️ Config edit failed!",
        });
        defer msg.deinit();
    };
    const msg = try session.sendMessage(message.channel_id, Discord.Partial(Discord.CreateMessage){
        .content = "Success!",
    });
    defer msg.deinit();
}

fn parseConfig(allocator: std.mem.Allocator, file: std.fs.File) !std.json.Parsed(std.json.Value) {
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var r = std.json.reader(allocator, reader);
    const parsed = try std.json.parseFromTokenSource(std.json.Value, allocator, &r, .{ .parse_numbers = false });
    return parsed;
}

/// Caller owns returned memory
fn formatJsonValue(allocator: std.mem.Allocator, entry: std.ArrayHashMap([]const u8, std.json.Value, std.array_hash_map.StringContext, true).Entry) ![]u8 {
    return switch (entry.value_ptr.*) {
        .null => {
            return try std.fmt.allocPrint(allocator, "null", .{});
        },
        .object => |object| {
            var object_string = std.ArrayList([]u8).init(allocator);
            var object_it = object.iterator();
            while (object_it.next()) |inner_entry| {
                try object_string.append(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ inner_entry.key_ptr.*, try formatJsonValue(allocator, inner_entry) }));
            }
            if (object_string.items.len == 0) return try std.fmt.allocPrint(allocator, "empty", .{});
            return try std.mem.join(allocator, "\n", try object_string.toOwnedSlice());
        },

        else => {
            return try json.jsonStringify(allocator, entry.value_ptr.*, .{});
        },
    };
}
