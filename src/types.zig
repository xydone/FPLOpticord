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
