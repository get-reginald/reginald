const std = @import("std");
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

    std.log.info("Hello Reginald", .{});

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    assert(args.len > 0);

    var parsed_args = try cli.parseArgsAlloc(allocator, args, std.io.getStdErr().writer());
    defer parsed_args.deinit();

    if (parsed_args.command) |cmd| {
        switch (cmd) {
            .apply => std.debug.print("Apply\n", .{}),
        }
    }
}

test {
    testing.refAllDecls(@This());
}
