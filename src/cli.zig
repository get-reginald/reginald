//! Cli defines the main command-line interface of Reginald. It handles defining the commands and
//! command-line options for them and parsing the options from the arguments the user has given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const testing = std.testing;
const Config = @import("Config.zig");

const InvalidArgs = error.InvalidArgs;

/// Value of a command-line option.
const OptionValue = union(enum) {
    bool: bool,
    int: i32,
    string: []const u8,
};

/// Command-line option. Every option has a long option (e.g. `--verbose`) and optionally a short,
/// single-letter alternative (e.g. `-v`). Short options can be combined, and values for the long
/// options can be given in the next argument or using `=`.
const Option = struct {
    name: []const u8,
    short: ?u8 = null,
    description: []const u8,
    /// Contains the parsed value of the option. This field is used for setting the default value of
    /// the option. If the option is not set, the default value is naturally found here.
    value: OptionValue,
    changed: bool = false,

    /// Parse an option from args by its long name. The argument to parse should be the first
    /// element in args. This returns the number of additional arguments used for parsing, which
    /// means that if the option takes a value and it wasn't given by using `=` within the same
    /// argument, the value is looked up from the next argument and this function returns 1.
    fn parseLong(self: *@This(), args: []const []const u8, writer: anytype) !usize {
        assert(args.len > 0);

        const arg = args[0];
        const s = arg[2..];
        // Might be unnecessary to do this again but this is the simplest solution.
        const name = if (std.mem.indexOf(u8, s, "=")) |j| s[0..j] else s;

        // TODO: If we implement count or list type options, this needs to change.
        if (self.changed) {
            try writer.print("option `--{s}` can be specified only once\n", .{name});

            return InvalidArgs;
        }

        switch (self.value) {
            .bool => {
                // Having a value outside of giving it with a `=` is forbidden for bools.
                if (std.mem.eql(u8, s, name)) {
                    self.value = .{ .bool = true };
                    self.changed = true;

                    return 0;
                }

                const b = atob(s[name.len + 1 ..]) catch {
                    try writer.print("invalid value for option `--{s}`: {s}\n", .{ name, s[name.len + 1 ..] });

                    return InvalidArgs;
                };

                self.value = .{ .bool = b };
                self.changed = true;

                return 0;
            },
            .int => {
                if (!std.mem.eql(u8, s, name)) {
                    const v = s[name.len + 1 ..];

                    const n = std.fmt.parseInt(i32, v, 0) catch {
                        try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ name, v });

                        return InvalidArgs;
                    };

                    self.value = .{ .int = n };
                    self.changed = true;

                    return 0;
                }

                if (args.len < 2) {
                    try writer.print("option `--{s}` requires a value", .{name});

                    return InvalidArgs;
                }

                const v = args[1];

                const n = std.fmt.parseInt(i32, v, 0) catch {
                    try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ name, v });

                    return InvalidArgs;
                };

                self.value = .{ .int = n };
                self.changed = true;

                return 1;
            },
            .string => {
                if (!std.mem.eql(u8, s, name)) {
                    var v = s[name.len + 1 ..];

                    // Allow wrapping the value in quotes.
                    if (std.mem.startsWith(u8, v, "\"") and std.mem.endsWith(u8, v, "\"")) {
                        v = v[1 .. v.len - 1];
                    }

                    self.value = .{ .string = v };
                    self.changed = true;

                    return 0;
                }

                if (args.len < 2) {
                    try writer.print("option `--{s}` requires a value", .{name});

                    return InvalidArgs;
                }

                const v = args[1];

                self.value = .{ .string = v };
                self.changed = true;

                return 1;
            },
        }

        unreachable;
    }
};

/// Subcommands of Reginald.
const Command = union(enum) {
    const Apply = struct {
        allocator: Allocator,
        options: ArrayList(Option),

        fn init(allocator: Allocator) !@This() {
            var result = @This(){
                .allocator = allocator,
                .options = undefined,
            };
            var list = ArrayList(Option).init(allocator);
            errdefer list.deinit();

            try list.append(Option{
                .name = "jobs",
                .description = "maximum number of tasks to run concurrently",
                .value = .{ .int = -1 },
            });

            result.options = list;

            return result;
        }

        fn deinit(self: *@This()) void {
            self.options.deinit();
        }
    };

    apply: Apply,
};

/// Parsed command-line arguments.
pub const ParsedArgs = struct {
    /// Allocator the CLI instance uses.
    allocator: Allocator,

    /// Defined command-line options. There won't be that many options so we have no need for a map.
    /// However, having an ArrayList simplifies our code a lot without too much additional overhead.
    options: ArrayList(Option),

    /// Subcommand that the user invoked. Must be cleaned by during the cleanup for the full struct.
    command: ?Command,

    /// Free the memory used by ParsedArgs.
    pub fn deinit(self: *@This()) void {
        self.options.deinit();

        if (self.command) |*cmd| {
            switch (cmd.*) {
                .apply => |*v| v.deinit(),
            }
        }
    }

    /// Get command-line option for the given name.
    pub fn option(self: *@This(), name: []const u8) ?*Option {
        for (self.options.items) |*opt| {
            if (std.mem.eql(u8, opt.name, name)) {
                return opt;
            }
        }

        return null;
    }

    /// Get command-line option for the given one-letter short option.
    fn optionForShort(self: *@This(), short: u8) ?*Option {
        for (self.options.items) |*opt| {
            if (opt.short != null and opt.short == short) {
                return opt;
            }
        }

        return null;
    }
};

/// Parse command-line arguments from iter and return the parsed arguments. The writer is used for
/// printing more detailed error messages if the user has given invalid arguments.
///
/// The caller must call `deinit` on the returned result.
pub fn parseArgsAlloc(allocator: Allocator, args: []const []const u8, writer: anytype) !ParsedArgs {
    var result: ParsedArgs = .{
        .allocator = allocator,
        .options = try initGlobalOptions(allocator),
        .command = null,
    };
    errdefer result.deinit();

    if (args.len <= 1) {
        return result;
    }

    var i: usize = 1;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];

        assert(arg.len > 0);

        // Start with the simple case of arg starting with `--` as there is no ambiguity in the
        // meaning, e.g. there is no multiple options combined.
        if (std.mem.startsWith(u8, arg, "--")) {
            // Stop parsing at "--".
            if (arg.len == 2) {
                break;
            }

            const s = arg[2..];
            const name = if (std.mem.indexOf(u8, s, "=")) |j| s[0..j] else s;

            var opt = result.option(name) orelse {
                try writer.print("invalid command-line option `--{s}`\n", .{name});
                return InvalidArgs;
            };

            const used = try opt.parseLong(args[i..], writer);
            if (used > 0) {
                i += used;
            }

            continue;
        }

        if (arg[0] == '-' and arg.len > 1) {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];

                var opt = result.optionForShort(c) orelse {
                    try writer.print("invalid command-line option `-{c}` in `{s}`\n", .{ c, arg });
                    return InvalidArgs;
                };

                // TODO: If we implement count or list type options, this needs to change.
                if (opt.changed) {
                    try writer.print("option `--{s}` can be specified only once\n", .{opt.name});

                    return InvalidArgs;
                }

                // Inline this parsing so we can check all of the options in the same argument at
                // once.
                switch (opt.value) {
                    .bool => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const v = arg[j + 2 ..];
                            const b = atob(v) catch {
                                try writer.print("invalid value for option `-{c}` in `{s}`: {s}\n", .{ c, arg, v });

                                return InvalidArgs;
                            };

                            opt.value = .{ .bool = b };
                            opt.changed = true;

                            // Current argument should end here.
                            continue :outer;
                        }

                        opt.value = .{ .bool = true };
                        opt.changed = true;
                    },
                    .int => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const v = arg[j + 2 ..];

                            const n = std.fmt.parseInt(i32, v, 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, v });

                                return InvalidArgs;
                            };

                            opt.value = .{ .int = n };
                            opt.changed = true;

                            // Current argument should end here.
                            continue :outer;
                        }

                        if (arg.len > j + 1) {
                            const v = arg[j + 1 ..];

                            const n = std.fmt.parseInt(i32, v, 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, v });

                                return InvalidArgs;
                            };

                            opt.value = .{ .int = n };
                            opt.changed = true;

                            continue :outer;
                        }

                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});

                            return InvalidArgs;
                        }

                        i += 1;

                        const v = args[i];

                        const n = std.fmt.parseInt(i32, v, 0) catch {
                            try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, v });

                            return InvalidArgs;
                        };

                        opt.value = .{ .int = n };
                        opt.changed = true;
                    },
                    .string => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            var v = arg[j + 2 ..];

                            // Allow wrapping the value in quotes.
                            if (std.mem.startsWith(u8, v, "\"") and std.mem.endsWith(u8, v, "\"")) {
                                v = v[1 .. v.len - 1];
                            }

                            opt.value = .{ .string = v };
                            opt.changed = true;

                            // Current argument should end here.
                            continue :outer;
                        }

                        // As string flags require a value, we assume that the bytes after the
                        // option are the value.
                        if (arg.len > j + 1) {
                            var v = arg[j + 1 ..];

                            // Allow wrapping the value in quotes.
                            if (std.mem.startsWith(u8, v, "\"") and std.mem.endsWith(u8, v, "\"")) {
                                v = v[1 .. v.len - 1];
                            }

                            opt.value = .{ .string = v };
                            opt.changed = true;

                            continue :outer;
                        }

                        // Otherwise the value must be in the next argument.
                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});

                            return InvalidArgs;
                        }

                        i += 1;

                        const v = args[i];

                        opt.value = .{ .string = v };
                        opt.changed = true;
                    },
                }
            }

            continue;
        }

        // Otherwise the argument must match a command.
        if (std.mem.eql(u8, arg, "apply")) {
            var c = try Command.Apply.init(allocator);
            errdefer c.deinit();

            result.command = .{ .apply = c };
            try result.options.appendSlice(c.options.items);
        } else {
            try writer.print("invalid argument: {s}\n", .{arg});

            return InvalidArgs;
        }
    }

    return result;
}

/// Create the global command-line options. These options are available for every subcommand. The
/// caller must call `deinit` on the result.
fn initGlobalOptions(allocator: Allocator) !ArrayList(Option) {
    var list = ArrayList(Option).init(allocator);

    try list.append(Option{
        .name = "version",
        .description = "print the version information and exit",
        .value = .{ .bool = false },
    });
    try list.append(Option{
        .name = "help",
        .short = 'h',
        .description = "show the help message and exit",
        .value = .{ .bool = false },
    });
    try list.append(Option{
        .name = "config",
        .short = 'c',
        .description = "use config file from `<path>`",
        .value = .{ .string = try Config.defaultConfigFile() },
    });
    try list.append(Option{
        .name = "directory",
        .short = 'C',
        .description = "run Reginald as if it was started from `<path>`",
        .value = .{ .string = try Config.defaultDir() },
    });
    try list.append(Option{
        .name = "verbose",
        .short = 'v',
        .description = "print more verbose output",
        .value = .{ .bool = false },
    });
    try list.append(Option{
        .name = "quiet",
        .short = 'q',
        .description = "silence all output expect errors",
        .value = .{ .bool = false },
    });

    return list;
}

/// Convert an ASCII string to a bool.
fn atob(a: []const u8) !bool {
    var buf: [64]u8 = undefined;
    const v = std.ascii.lowerString(&buf, a);

    if (std.mem.eql(u8, v, "true")) {
        return true;
    } else if (std.mem.eql(u8, v, "t")) {
        return true;
    } else if (std.mem.eql(u8, v, "1")) {
        return true;
    } else if (std.mem.eql(u8, v, "false")) {
        return false;
    } else if (std.mem.eql(u8, v, "f")) {
        return false;
    } else if (std.mem.eql(u8, v, "0")) {
        return false;
    }

    return error.@"string is not a bool";
}

test "no options" {
    const args = [_][:0]const u8{"reginald"};
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
}

test "stop parsing at `--`" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "--", "--quiet" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
}

test "bool option" {
    const args = [_][:0]const u8{ "reginald", "--verbose" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
}

test "bool option value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=true" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
}

test "bool option invalid value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=something" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);

    try testing.expectError(InvalidArgs, parsed);
}

test "bool option empty value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);

    try testing.expectError(InvalidArgs, parsed);
}

test "duplicate bool" {
    const args = [_][:0]const u8{ "reginald", "--quiet", "--quiet" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    try testing.expectError(InvalidArgs, parsed);
}

test "string option" {
    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "multiple string options" {
    const args = [_][:0]const u8{
        "reginald",
        "--config",
        "/tmp/config.toml",
        "--directory",
        "/tmp",
    };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expect(std.mem.eql(u8, parsed.option("directory").?.value.string, "/tmp"));
}

test "string option equals sign" {
    const args = [_][:0]const u8{ "reginald", "--config=/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "string option equals sign quoted" {
    const args = [_][:0]const u8{ "reginald", "--config=\"/tmp/config.toml\"" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "string option no value" {
    const args = [_][:0]const u8{ "reginald", "--config" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    try testing.expectError(InvalidArgs, parsed);
}

test "bool and string option" {
    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml", "--verbose" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expect(parsed.option("verbose").?.value.bool);
}

test "string option mixed" {
    const args = [_][:0]const u8{ "reginald", "--directory=/tmp", "--config", "/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expect(std.mem.eql(u8, parsed.option("directory").?.value.string, "/tmp"));
}

test "invalid string order" {
    const args = [_][:0]const u8{ "reginald", "--config", "--verbose" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "--verbose"));
}

test "invalid long option" {
    const args = [_][:0]const u8{ "reginald", "--cfg" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);

    try testing.expectError(InvalidArgs, parsed);
}

test "short bool option" {
    const args = [_][:0]const u8{ "reginald", "-v" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
}

test "short bool option value" {
    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=true" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
}

test "short bool option combined" {
    const args = [_][:0]const u8{ "reginald", "-qv" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
}

test "short bool option combined last value" {
    const args = [_][:0]const u8{ "reginald", "-qv=false" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
}

test "short bool option invalid value" {
    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=something" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);

    try testing.expectError(InvalidArgs, parsed);
}

test "short bool option empty value" {
    const args = [_][:0]const u8{ "reginald", "-v=" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);

    try testing.expectError(InvalidArgs, parsed);
}

test "short string option" {
    const args = [_][:0]const u8{ "reginald", "-c", "/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short string option value" {
    const args = [_][:0]const u8{ "reginald", "-c=/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short string option value merged" {
    const args = [_][:0]const u8{ "reginald", "-c/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short string option empty quoted value" {
    const args = [_][:0]const u8{ "reginald", "-c=\"\"" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, ""));
}

test "short option combined" {
    const args = [_][:0]const u8{ "reginald", "-vc", "/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short option combined value" {
    const args = [_][:0]const u8{ "reginald", "-vc=/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short option combined value merged" {
    const args = [_][:0]const u8{ "reginald", "-vc/tmp/config.toml" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short option combined value merged quoted" {
    const args = [_][:0]const u8{ "reginald", "-vc\"/tmp/config.toml\"" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
}

test "short option combined value merged empty quoted" {
    const args = [_][:0]const u8{ "reginald", "-vc\"\"" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, ""));
}

test "short option combined no value" {
    const args = [_][:0]const u8{ "reginald", "-vc" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    try testing.expectError(InvalidArgs, parsed);
}

test "invalid empty short" {
    const args = [_][:0]const u8{ "reginald", "-" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    try testing.expectError(InvalidArgs, parsed);
}

test "subcommand apply" {
    const args = [_][:0]const u8{ "reginald", "apply" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }
}

test "subcommand int option" {
    const args = [_][:0]const u8{ "reginald", "apply", "--jobs", "20" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }

    try testing.expectEqual(parsed.option("jobs").?.changed, true);
    try testing.expectEqual(parsed.option("jobs").?.value.int, 20);
}

test "subcommand global option before" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "apply", "--jobs", "20" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }

    try testing.expectEqual(parsed.option("verbose").?.changed, true);
    try testing.expectEqual(parsed.option("jobs").?.changed, true);
    try testing.expectEqual(parsed.option("verbose").?.value.bool, true);
    try testing.expectEqual(parsed.option("jobs").?.value.int, 20);
}

test "subcommand global option after" {
    const args = [_][:0]const u8{ "reginald", "apply", "--verbose", "--jobs", "20" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }

    try testing.expectEqual(parsed.option("verbose").?.changed, true);
    try testing.expectEqual(parsed.option("jobs").?.changed, true);
    try testing.expectEqual(parsed.option("verbose").?.value.bool, true);
    try testing.expectEqual(parsed.option("jobs").?.value.int, 20);
}

test "subcommand global option both" {
    const args = [_][:0]const u8{ "reginald", "--quiet", "apply", "--verbose", "--jobs", "20" };
    var parsed = try parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }

    try testing.expectEqual(parsed.option("verbose").?.changed, true);
    try testing.expectEqual(parsed.option("quiet").?.changed, true);
    try testing.expectEqual(parsed.option("jobs").?.changed, true);
    try testing.expectEqual(parsed.option("verbose").?.value.bool, true);
    try testing.expectEqual(parsed.option("quiet").?.value.bool, true);
    try testing.expectEqual(parsed.option("jobs").?.value.int, 20);
}

test "subcommand option before" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "--jobs", "20", "apply" };
    const parsed = parseArgsAlloc(testing.allocator, &args, std.io.null_writer);
    try testing.expectError(InvalidArgs, parsed);
}
