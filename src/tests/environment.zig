const std = @import("std");
const dotenv = @import("../util/dotenv.zig");

pub var test_env: TestEnvironment = undefined;

/// The allocator inside is only meant to be used for resources meant to outlive the test allocator. It does not offer memory leak detection. Use with care!
pub const TestEnvironment = struct {
    /// This allocator is only meant to be used for resources meant to outlive the test allocator. It does not offer memory leak detection. Use with care!
    allocator: std.mem.Allocator,
    env: dotenv,

    pub fn init() !void {
        const alloc = std.heap.smp_allocator;
        // Could possibly use a specific testing environment variable file, however as of right now, there is no need.
        const env = try dotenv.init(alloc, ".env");

        test_env = TestEnvironment{
            .allocator = alloc,
            .env = env,
        };
    }
    pub fn deinit(self: *TestEnvironment) void {
        self.env.deinit();
    }
};
