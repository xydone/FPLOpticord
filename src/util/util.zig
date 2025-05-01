const std = @import("std");
pub fn fetchFileFromAPI(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const log = std.log.scoped(.fetchFile);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var body = std.ArrayList(u8).init(allocator);
    const res = try client.fetch(.{ .location = .{
        .url = url,
    }, .response_storage = .{ .dynamic = &body } });
    const response_body = try body.toOwnedSlice();
    if (res.status != .ok) {
        log.err("fetchFile failed with status {}\nresponse body: {s}", .{ res.status, response_body });
        return error.FailedFetching;
    }
    return response_body;
}

pub fn isBufJson(allocator: std.mem.Allocator, buf: []u8) bool {
    _ = std.json.parseFromSlice(std.json.Value, allocator, buf, .{}) catch return false;
    return true;
}

pub fn writeFile(sub_path: []const u8, file_flags: std.fs.File.CreateFlags, content: []u8) !void {
    const file = try std.fs.cwd().createFile(sub_path, file_flags);
    defer file.close();

    try file.writeAll(content);
}

/// Currently only verifies .json files, will verify .csv later too
pub fn saveFileFromAPI(allocator: std.mem.Allocator, url: []const u8, output_file_path: []const u8, file_flags: std.fs.File.CreateFlags) !void {
    const content = try fetchFileFromAPI(allocator, url);
    if (std.mem.endsWith(u8, output_file_path, ".json")) {
        const is_json = isBufJson(allocator, content);
        if (is_json == false) return error.FileNotJson;
        try writeFile(output_file_path, file_flags, content);
    }
}

pub const WSLPathOptions = enum {
    /// force result to absolute path format
    force,
    /// translate from a Windows path to a WSL path
    from_windows_to_wsl,
    /// translate from a WSL path to a Windows path
    from_wsl_to_windows,
    /// translate from a WSL path to a Windows path, with '/' instead of '\'
    from_wsl_to_windows_slashes,

    pub fn toString(self: WSLPathOptions) []const u8 {
        switch (self) {
            .force => return "-a",
            .from_windows_to_wsl => return "-u",
            .from_wsl_to_windows => return "-w",
            .from_wsl_to_windows_slashes => return "-m",
        }
    }
};

pub const BackupStrategy = enum {
    /// Do not backup the file
    false,
    /// Append `std.fs.File.Stat.atime` to the file name
    append_atime,
    /// Append `std.fs.File.Stat.mtime` to the file name
    append_mtime,
    /// Append `std.fs.File.Stat.ctime` to the file name
    append_ctime,
    /// Append a custom string to the file name
    append_custom_string,
};

pub fn copyFileAndBackup(
    allocator: std.mem.Allocator,
    from: struct {
        path: []const u8,
        file_name: []const u8,
    },
    to: struct {
        path: []const u8,
        file_name: []const u8,
    },
    backup: union(BackupStrategy) {
        false,
        append_atime: struct { name: []const u8, extension: []const u8 },
        append_mtime: struct { name: []const u8, extension: []const u8 },
        append_ctime: struct { name: []const u8, extension: []const u8 },
        append_custom_string: struct { name: []const u8, string: []const u8, extension: []const u8 },

        // Caller owns memory.
        pub fn getFileName(self: @This(), alloc: std.mem.Allocator, stat: std.fs.File.Stat) ![]const u8 {
            return switch (self) {
                .append_atime => |v| {
                    const atime = try std.fmt.allocPrint(alloc, "_{d}", .{stat.atime});
                    defer alloc.free(atime);
                    return try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ v.name, atime, v.extension });
                },
                .append_mtime => |v| {
                    const mtime = try std.fmt.allocPrint(alloc, "_{d}", .{stat.mtime});
                    defer alloc.free(mtime);
                    return try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ v.name, mtime, v.extension });
                },
                .append_ctime => |v| {
                    const ctime = try std.fmt.allocPrint(alloc, "_{d}", .{stat.ctime});
                    defer alloc.free(ctime);
                    return try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ v.name, ctime, v.extension });
                },
                .append_custom_string => |v| {
                    const string = try std.fmt.allocPrint(alloc, "_{s}", .{v.string});
                    defer alloc.free(string);
                    return try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ v.name, string, v.extension });
                },
                .false => return error.NoBackupStrategy,
            };
        }
    },
) !void {
    const to_dir = try std.fs.openDirAbsolute(to.path, .{});
    // Check if player data file exists already
    const file_exists = to_dir.statFile(to.file_name) != error.FileNotFound;
    // The file exists. Move it to the correct path
    if (file_exists) {
        // Backup the file only if backup strategy is not false
        switch (backup) {
            .false => {},
            else => {
                const to_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ to.path, to.file_name });
                defer allocator.free(to_file_path);
                const stat = try to_dir.statFile(to.file_name);
                const backup_file_name = try backup.getFileName(allocator, stat);
                defer allocator.free(backup_file_name);
                const copied_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from.path, backup_file_name });
                defer allocator.free(copied_file_path);

                // Copy the file over to the path
                try std.fs.copyFileAbsolute(to_file_path, copied_file_path, .{});
            },
        }
        // Delete the one in the "to" folder
        try to_dir.deleteFile(to.file_name);
    }
    // Copy the file from "from" to "to" (lol)
    const from_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from.path, from.file_name });
    defer allocator.free(from_file_path);
    const to_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ to.path, to.file_name });
    defer allocator.free(to_file_path);
    try std.fs.copyFileAbsolute(from_file_path, to_file_path, .{});
}

/// Caller must free memory
pub fn wslpath(
    allocator: std.mem.Allocator,
    path: []const u8,
    option: WSLPathOptions,
) ![]u8 {
    const argv = &.{ "wslpath", option.toString(), path };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = try std.process.getCwdAlloc(allocator);
    child.expand_arg0 = .no_expand;
    child.progress_node = std.Progress.Node.none;

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr.deinit(allocator);

    child.spawn() catch |err| {
        panic(
            allocator,
            "Failed to spawn wslpath child process due to {}.\n",
            .{err},
        );
    };
    errdefer {
        _ = child.kill() catch {};
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024);
    return try std.mem.replaceOwned(u8, allocator, try stdout.toOwnedSlice(allocator), "\n", "");
}

const zdt = @import("zdt");
pub const DatetimeOptions = enum {
    now,
    /// Uses custom datetime object
    use_datetime,
};

/// Caller owns memory
pub fn getDatetimeString(allocator: std.mem.Allocator, datetime_options: union(DatetimeOptions) {
    now,
    use_datetime: struct { datetime: zdt.Datetime },
}) ![]u8 {
    var locale = try zdt.Timezone.tzLocal(allocator);
    defer locale.deinit();
    const datetime = switch (datetime_options) {
        .now => try zdt.Datetime.now(.{ .tz = &locale }),
        .use_datetime => |use_datetime| use_datetime.datetime,
    };
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    // https://github.com/FObersteiner/zdt/wiki/String-parsing-and-formatting-directives
    try datetime.toString("[%Y-%m-%d %H:%M:%S]", buf.writer());
    return try buf.toOwnedSlice();
}

/// Custom panic handler with timestamp
pub fn panic(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) noreturn {
    const datetime = getDatetimeString(allocator, .now) catch {
        // If we cannot allocate memory to print the datetime, something has gone seriously wrong.
        std.debug.print("[???] ", .{});
        std.debug.panic(format, args);
    };
    std.debug.print("{s} ", .{datetime});
    std.debug.panic(format, args);
}
