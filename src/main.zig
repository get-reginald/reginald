const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const cli = @import("cli.zig");

pub const std_options: std.Options = .{
    // For now, we should set the log level always to debug so that messages don't get compiled out
    // and the level can be set during runtime.
    .log_level = .debug,
};

pub fn main() !void {
    // TODO: Add a custom crash report that guides the users to open an issue.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    assert(args.len > 0);

    var parsed_args = try cli.parseArgsAlloc(allocator, args, std.io.getStdErr().writer());
    defer parsed_args.deinit();

    const helpOpt = parsed_args.option("help").?;
    switch (helpOpt.value) {
        .bool => |b| {
            if (b) {
                try std.io.getStdOut().writer().print("Help message\n", .{});

                return;
            }
        },
        else => unreachable,
    }

    const versionOpt = parsed_args.option("version").?;
    switch (versionOpt.value) {
        .bool => |b| {
            if (b) {
                var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
                const w = bw.writer();
                try w.writeAll("reginald version " ++ build_options.version ++ "\n");
                try w.writeAll("Licensed under the Apache License, Version 2.0: <https://www.apache.org/licenses/LICENSE-2.0>\n");
                try bw.flush();

                return;
            }
        },
        else => unreachable,
    }
}

test {
    testing.refAllDecls(@This());
    _ = @import("path_util.zig");
}
