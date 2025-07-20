const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const cli = @import("cli.zig");
const Config = @import("Config.zig");
const filepath = @import("filepath.zig");

const native_os = builtin.target.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    // TODO: It could be ok to remove these safety checks.
    comptime {
        if (std.meta.fields(Config).len != std.meta.fields(Config.Metadata).len) {
            @compileError("number of fields in config metadata does not match the config");
        }

        for (std.meta.fields(Config)) |field| {
            if (!@hasField(Config.Metadata, field.name)) {
                @compileError("config field " ++ field.name ++ " not present in metadata");
            }
        }

        for (std.meta.fields(Config.Metadata)) |field| {
            if (!@hasField(Config, field.name)) {
                @compileError("metadata field " ++ field.name ++ " not present in config");
            }
        }
    }

    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    assert(args.len > 0);

    // Errors from parsing are ignored for now and the errors are checked after
    // loading plugins.
    var parsed_args = try cli.parseArgs(gpa, args, std.io.getStdErr().writer(), .collect);
    defer parsed_args.deinit();

    const help_opt = parsed_args.option("help").?;
    switch (help_opt.value) {
        .bool => |b| {
            if (b) {
                try std.io.getStdOut().writer().print("Help message\n", .{});

                return;
            }
        },
        else => unreachable,
    }

    const version_opt = parsed_args.option("version").?;
    switch (version_opt.value) {
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

    const wd_path = try workingDirPath(gpa, parsed_args.option("directory").?);
    defer if (wd_path) |s| {
        gpa.free(s);
    };

    const cfg_file = Config.loadFile(gpa, parsed_args.option("config").?, wd_path) catch |err| {
        switch (err) {
            error.FileNotFound, error.IsDir => {
                try std.io.getStdErr().writer().print("config file not found\n", .{});

                return err;
            },
            else => return err,
        }
    };
    defer gpa.free(cfg_file);
}

/// Resolve the working directory of the current run. Caller owns the return
/// value and should call `free` on it if it is not null. A null return value
/// means that the current working directory should be used.
pub fn workingDirPath(allocator: Allocator, wd_opt: *cli.Option) !?[]const u8 {
    if (wd_opt.changed) {
        switch (wd_opt.value) {
            .string => |s| {
                return try filepath.expand(allocator, s);
            },
            else => unreachable,
        }
    }

    if (std.process.getEnvVarOwned(allocator, build_options.env_prefix ++ "DIRECTORY")) |s| {
        defer allocator.free(s);
        return try filepath.expand(allocator, s);
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    return null;
}

test {
    testing.refAllDecls(@This());
}
