// https://github.com/zigster64/dotenv.zig/
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Self = @This();

map: std.process.EnvMap = undefined,

pub fn init(allocator: Allocator, filename: ?[]const u8) !Self {
    var map = try std.process.getEnvMap(allocator);

    if (filename) |f| {
        var file = std.fs.cwd().openFile(f, .{}) catch {
            return .{ .map = map };
        };

        defer file.close();
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        var buf: [1024]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            // ignore commented out lines
            if (line.len > 0 and line[0] == '#') {
                continue;
            }
            // split into KEY and Value
            if (std.mem.indexOf(u8, line, "=")) |index| {
                const key = line[0..index];
                const value = line[index + 1 ..];
                try map.put(key, value);
            }
        }
    }
    return .{
        .map = map,
    };
}

pub fn deinit(self: *Self) void {
    self.map.deinit();
}

pub fn get(self: Self, key: []const u8) ?[]const u8 {
    return self.map.get(key);
}

pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
    return self.map.put(key, value);
}
