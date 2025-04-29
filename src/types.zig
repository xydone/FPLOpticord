const std = @import("std");
pub const Solution = struct {
    gameweek: u16,
    lineup: []u8,
    bench: []u8,
    xPts: f64,
    move: []u8,
};

pub const SolverResponse = struct {
    up_to_date: ?bool,
    solutions: ?Solution,
    done: bool = false,

    pub const empty: SolverResponse = .{
        .up_to_date = null,
        .solutions = null,
    };
};
pub const ContentIterator = std.mem.TokenIterator(u8, .sequence);

/// Move list array which manages the memory of the `std.ArrayList` inside alongside the memory of the contents.
pub const ManagedString = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ManagedString {
        return ManagedString{ .allocator = allocator, .list = std.ArrayList([]const u8).init(allocator) };
    }

    pub fn append(self: *ManagedString, string: []const u8) !void {
        try self.list.append(string);
    }

    pub fn deinit(
        self: *ManagedString,
    ) void {
        for (self.list.items) |item| {
            self.allocator.free(item);
        }
        self.list.deinit();
    }
};
