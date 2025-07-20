//! Cli defines the main command-line interface of Reginald. It handles defining
//! the commands and command-line options for them and parsing the options from
//! the arguments the user has given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const testing = std.testing;

const Config = @import("Config.zig");

const ParseError = Allocator.Error || error{InvalidArgs};

pub const global_opts = generateOptionsFor(null);
pub const apply_opts = generateOptionsFor("apply");

/// What to do when the command-line parser finds an unknown argument.
pub const OnUnknown = enum {
    /// With `fail`, the parser fails immediately and returns an error.
    fail,

    /// With `collect`, the parser collects the unknown arguments as long as
    /// possible and returns what it was able to parse.
    collect,
};

/// Value of a command-line option.
const OptionValue = union(enum) {
    bool: bool,
    int: i32,
    string: []const u8,
};

/// Command-line option. Every option has a long option (e.g. `--verbose`) and
/// optionally a short, single-letter alternative (e.g. `-v`). Short options can
/// be combined, and values for the long options can be given in the next
/// argument or using `=`.
pub const Option = struct {
    allocator: ?Allocator = null, // set only when option holds a value that must be freed
    name: []const u8,
    short: ?u8 = null,
    description: []const u8,
    /// Contains the parsed value of the option. This field is used for setting
    /// the default value of the option. If the option is not set, the default
    /// value is naturally found here.
    value: OptionValue,
    changed: bool = false,

    fn hasValue(self: *const @This(), arg: []const u8) bool {
        const equals = std.mem.indexOf(u8, arg, "=");
        return switch (self.value) {
            .bool => false,
            .int, .string => equals == null,
        };
    }

    /// Parse an option from args by its long name. The argument to parse should
    /// be the first element in args. This returns the number of additional
    /// arguments used for parsing, which means that if the option takes a value
    /// and it wasn't given by using `=` within the same argument, the value is
    /// looked up from the next argument and this function returns 1.
    fn parseLong(self: *@This(), allocator: Allocator, args: []const []const u8, writer: anytype) !usize {
        assert(args.len > 0);

        const arg = args[0];
        const s = arg[2..];
        // Might be unnecessary to do this again but this is the simplest
        // solution.
        const name = if (std.mem.indexOf(u8, s, "=")) |j| s[0..j] else s;

        // TODO: If we implement count or list type options, this needs to
        // change.
        if (self.changed) {
            try writer.print("option `--{s}` can be specified only once\n", .{name});

            return error.InvalidArgs;
        }

        switch (self.value) {
            .bool => {
                // Having a value outside of giving it with a `=` is forbidden
                // for bools.
                if (std.mem.eql(u8, s, name)) {
                    try self.setValue(allocator, true);

                    return 0;
                }

                const b = parseBool(s[name.len + 1 ..]) catch {
                    try writer.print("invalid value for option `--{s}`: {s}\n", .{ name, s[name.len + 1 ..] });

                    return error.InvalidArgs;
                };

                try self.setValue(allocator, b);

                return 0;
            },
            .int => {
                if (!std.mem.eql(u8, s, name)) {
                    const v = s[name.len + 1 ..];

                    const n = std.fmt.parseInt(i32, v, 0) catch {
                        try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ name, v });

                        return error.InvalidArgs;
                    };

                    try self.setValue(allocator, n);

                    return 0;
                }

                if (args.len < 2) {
                    try writer.print("option `--{s}` requires a value", .{name});

                    return error.InvalidArgs;
                }

                const v = args[1];

                const n = std.fmt.parseInt(i32, v, 0) catch {
                    try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ name, v });

                    return error.InvalidArgs;
                };

                try self.setValue(allocator, n);

                return 1;
            },
            .string => {
                if (!std.mem.eql(u8, s, name)) {
                    var v = s[name.len + 1 ..];

                    // Allow wrapping the value in quotes.
                    if (std.mem.startsWith(u8, v, "\"") and std.mem.endsWith(u8, v, "\"")) {
                        v = v[1 .. v.len - 1];
                    }

                    try self.setValue(allocator, v);

                    return 0;
                }

                if (args.len < 2) {
                    try writer.print("option `--{s}` requires a value", .{name});

                    return error.InvalidArgs;
                }

                const v = args[1];

                try self.setValue(allocator, v);

                return 1;
            },
        }

        unreachable;
    }

    fn setValue(self: *@This(), allocator: Allocator, v: anytype) !void {
        if (self.allocator != null) {
            switch (self.value) {
                .string => |s| {
                    self.allocator.?.free(s);
                    self.allocator = null;
                },
                else => unreachable,
            }
        }

        switch (@TypeOf(v)) {
            bool => self.value = .{ .bool = v },
            i32 => self.value = .{ .int = v },
            []const u8 => {
                self.value = .{ .string = try allocator.dupe(u8, v) };
                self.allocator = allocator;
            },
            else => @compileError("Option.setValue accepts only bool, i32, and []const u8"),
        }

        self.changed = true;
    }
};

const ApplyCommand = struct {};

const CommandTag = enum {
    apply,
};

/// Subcommands of Reginald.
const Command = union(CommandTag) {
    apply: ApplyCommand,
};

/// Parsed command-line arguments.
pub const ParsedArgs = struct {
    /// Allocator the CLI instance uses.
    allocator: Allocator,

    /// Subcommand that the user invoked. Must be cleaned by during the cleanup
    /// for the full struct.
    command: ?Command,

    /// Current set of command-line options.
    options: ArrayList(Option),

    /// Unknown arguments found.
    unknown: ?ArrayList(UnknownArgument),

    /// Free the memory used by ParsedArgs.
    pub fn deinit(self: *@This()) void {
        for (self.options.items) |*o| {
            if (o.allocator) |a| {
                switch (o.value) {
                    .string => |s| {
                        a.free(s);
                        o.allocator = null;
                    },
                    else => unreachable,
                }
            }
        }

        self.options.deinit();

        if (self.unknown) |unknown| {
            unknown.deinit();
        }

        // if (self.command) |*cmd| {
        //     switch (cmd.*) {
        //         .apply => |*v| v.deinit(),
        //     }
        // }
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

const UnknownOptionName = union(enum) {
    long: []const u8,
    short: u8,
};

/// Unknown command-line argument that was encountered during the parsing.
const UnknownArgument = struct {
    /// Index of the argument.
    pos: usize,

    /// Argument that was or contains the unknown argument.
    arg: []const u8,

    /// If the unknown argument was a command-line option, this is the name of
    /// it as found in the command-line arguments. Especially useful if
    /// an unknown option was found in an argument that contains multiple short
    /// options.
    option_name: ?UnknownOptionName,
};

/// Parse command-line arguments from iter and return the parsed arguments.
/// The writer is used for printing more detailed error messages if the user has
/// given invalid arguments.
///
/// The caller must call `deinit` on the returned result.
///
/// TODO: Add a second pass that checks for the plugin arguments.
pub fn parseArgs(
    allocator: Allocator,
    args: []const []const u8,
    writer: anytype,
    on_unknown: OnUnknown,
) (ParseError || @TypeOf(writer).Error)!ParsedArgs {
    var result: ParsedArgs = .{
        .allocator = allocator,
        .command = null,
        .options = .init(allocator),
        .unknown = switch (on_unknown) {
            .collect => .init(allocator),
            .fail => null,
        },
    };
    try result.options.appendSlice(&global_opts);
    errdefer result.deinit();

    if (args.len <= 1) {
        return result;
    }

    var i: usize = 1;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];

        assert(arg.len > 0);

        // Start with the simple case of arg starting with `--` as there is no
        // ambiguity in the meaning, e.g. there is no multiple options combined.
        if (std.mem.startsWith(u8, arg, "--")) {
            // Stop parsing at "--".
            if (arg.len == 2) {
                break;
            }

            const s = arg[2..];
            const name = if (std.mem.indexOf(u8, s, "=")) |j| s[0..j] else s;

            var opt = result.option(name) orelse switch (on_unknown) {
                .collect => {
                    try result.unknown.?.append(.{
                        .pos = i,
                        .arg = arg,
                        .option_name = .{ .long = name },
                    });
                    continue;
                },
                .fail => {
                    try writer.print("invalid command-line option `--{s}`\n", .{name});
                    return error.InvalidArgs;
                },
            };

            const used = try opt.parseLong(allocator, args[i..], writer);
            if (used > 0) {
                i += used;
            }

            continue;
        }

        if (arg[0] == '-' and arg.len > 1) {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];

                var opt = result.optionForShort(c) orelse switch (on_unknown) {
                    .collect => {
                        try result.unknown.?.append(.{
                            .pos = i,
                            .arg = arg,
                            .option_name = .{ .short = c },
                        });
                        continue;
                    },
                    .fail => {
                        try writer.print("invalid command-line option `-{c}` in `{s}`\n", .{ c, arg });
                        return error.InvalidArgs;
                    },
                };

                // TODO: If we implement count or list type options, this needs
                // to change.
                if (opt.changed) {
                    try writer.print("option `--{s}` can be specified only once\n", .{opt.name});

                    return error.InvalidArgs;
                }

                // Inline this parsing so we can check all of the options in
                // the same argument at once.
                switch (opt.value) {
                    .bool => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const v = arg[j + 2 ..];
                            const b = parseBool(v) catch {
                                try writer.print("invalid value for option `-{c}` in `{s}`: {s}\n", .{ c, arg, v });

                                return error.InvalidArgs;
                            };

                            try opt.setValue(allocator, b);

                            // Current argument should end here.
                            continue :outer;
                        }

                        try opt.setValue(allocator, true);
                    },
                    .int => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const v = arg[j + 2 ..];

                            const n = std.fmt.parseInt(i32, v, 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, v });

                                return error.InvalidArgs;
                            };

                            try opt.setValue(allocator, n);

                            // Current argument should end here.
                            continue :outer;
                        }

                        if (arg.len > j + 1) {
                            const v = arg[j + 1 ..];

                            const n = std.fmt.parseInt(i32, v, 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, v });

                                return error.InvalidArgs;
                            };

                            try opt.setValue(allocator, n);

                            continue :outer;
                        }

                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});

                            return error.InvalidArgs;
                        }

                        i += 1;

                        const v = args[i];

                        const n = std.fmt.parseInt(i32, v, 0) catch {
                            try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, v });

                            return error.InvalidArgs;
                        };

                        try opt.setValue(allocator, n);
                    },
                    .string => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            var v = arg[j + 2 ..];

                            // Allow wrapping the value in quotes.
                            if (std.mem.startsWith(u8, v, "\"") and std.mem.endsWith(u8, v, "\"")) {
                                v = v[1 .. v.len - 1];
                            }

                            try opt.setValue(allocator, v);

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

                            try opt.setValue(allocator, v);

                            continue :outer;
                        }

                        // Otherwise the value must be in the next argument.
                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});

                            return error.InvalidArgs;
                        }

                        i += 1;

                        const v = args[i];

                        try opt.setValue(allocator, v);
                    },
                }
            }

            continue;
        }

        if (std.meta.stringToEnum(CommandTag, arg)) |tag| {
            switch (tag) {
                .apply => {
                    result.command = .{ .apply = .{} };
                    try result.options.appendSlice(&apply_opts);
                },
            }
        } else switch (on_unknown) {
            .collect => {
                try result.unknown.?.append(.{
                    .pos = i,
                    .arg = arg,
                    .option_name = null,
                });
                continue;
            },
            .fail => {
                try writer.print("invalid argument: {s}\n", .{arg});
                return error.InvalidArgs;
            },
        }
    }

    return result;
}

/// Check whether the given config option metadata belongs to the given
/// subcommand.
fn belongsTo(comptime name: ?[:0]const u8, comptime metadata: Config.OptionMetadata) bool {
    const disabled = metadata.disable_option orelse false;
    if (disabled) {
        return false;
    }

    if (name == null and metadata.subcommands == null) {
        return true;
    }

    if (name) |n| {
        if (metadata.subcommands) |sub| {
            inline for (sub) |s| {
                if (comptime std.mem.eql(u8, n, s)) {
                    return true;
                }
            }
        }
    }

    return false;
}

/// Resolve the number of command-line options for the given command or
/// the number of global options in name is null.
fn numOptions(comptime name: ?[:0]const u8) usize {
    var i: usize = 0;

    inline for (std.meta.fields(Config)) |field| {
        const m = @field(Config.metadata, field.name);
        if (comptime belongsTo(name, m)) {
            i += 1;
        }
    }

    return i;
}

/// Generate the array of command-line options for the given subcommand or
/// generate the global options by giving a null name.
fn generateOptionsFor(comptime name: ?[:0]const u8) [numOptions(name)]Option {
    var result: [numOptions(name)]Option = undefined;

    var i: usize = 0;
    for (std.meta.fields(Config)) |field| {
        const m = @field(Config.metadata, field.name);
        if (comptime !belongsTo(name, m)) {
            continue;
        }

        const long = m.long orelse field.name;
        const short = m.short;
        const description = m.description orelse "DESCRIPTION MISSING"; // make it visible
        const value = switch (field.type) {
            bool => OptionValue{ .bool = field.defaultValue() orelse false },
            i32 => OptionValue{ .int = field.defaultValue() orelse 0 },
            []const u8 => OptionValue{ .string = field.defaultValue() orelse "" },
            else => |t| @compileError("config option with invalid type " ++ @typeName(t)),
        };

        result[i] = .{
            .name = long,
            .short = short,
            .description = description,
            .value = value,
        };

        i += 1;
    }

    return result;
}

/// Convert an ASCII string to a bool.
fn parseBool(a: []const u8) !bool {
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
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expectEqual(parsed.unknown, null);
}

test "stop parsing at `--`" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "--", "--quiet" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "bool option" {
    const args = [_][:0]const u8{ "reginald", "--verbose" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "bool option value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=true" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "bool option invalid value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=something" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);

    try testing.expectError(error.InvalidArgs, parsed);
}

test "bool option empty value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);

    try testing.expectError(error.InvalidArgs, parsed);
}

test "duplicate bool" {
    const args = [_][:0]const u8{ "reginald", "--quiet", "--quiet" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "string option" {
    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "multiple string options" {
    const args = [_][:0]const u8{
        "reginald",
        "--config",
        "/tmp/config.toml",
        "--directory",
        "/tmp",
    };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expect(std.mem.eql(u8, parsed.option("directory").?.value.string, "/tmp"));
    try testing.expectEqual(parsed.unknown, null);
}

test "string option equals sign" {
    const args = [_][:0]const u8{ "reginald", "--config=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "string option equals sign quoted" {
    const args = [_][:0]const u8{ "reginald", "--config=\"/tmp/config.toml\"" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "string option no value" {
    const args = [_][:0]const u8{ "reginald", "--config" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "bool and string option" {
    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml", "--verbose" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "string option mixed" {
    const args = [_][:0]const u8{ "reginald", "--directory=/tmp", "--config", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expect(std.mem.eql(u8, parsed.option("directory").?.value.string, "/tmp"));
    try testing.expectEqual(parsed.unknown, null);
}

test "invalid string order" {
    const args = [_][:0]const u8{ "reginald", "--config", "--verbose" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "--verbose"));
    try testing.expectEqual(parsed.unknown, null);
}

test "invalid long option" {
    const args = [_][:0]const u8{ "reginald", "--cfg" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);

    try testing.expectError(error.InvalidArgs, parsed);
}

test "short bool option" {
    const args = [_][:0]const u8{ "reginald", "-v" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "short bool option value" {
    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=true" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "short bool option combined" {
    const args = [_][:0]const u8{ "reginald", "-qv" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "short bool option combined last value" {
    const args = [_][:0]const u8{ "reginald", "-qv=false" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.option("quiet").?.value.bool);
    try testing.expectEqual(parsed.unknown, null);
}

test "short bool option invalid value" {
    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=something" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);

    try testing.expectError(error.InvalidArgs, parsed);
}

test "short bool option empty value" {
    const args = [_][:0]const u8{ "reginald", "-v=" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);

    try testing.expectError(error.InvalidArgs, parsed);
}

test "short string option" {
    const args = [_][:0]const u8{ "reginald", "-c", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short string option value" {
    const args = [_][:0]const u8{ "reginald", "-c=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short string option value merged" {
    const args = [_][:0]const u8{ "reginald", "-c/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short string option empty quoted value" {
    const args = [_][:0]const u8{ "reginald", "-c=\"\"" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(!parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, ""));
    try testing.expectEqual(parsed.unknown, null);
}

test "short option combined" {
    const args = [_][:0]const u8{ "reginald", "-vc", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short option combined value" {
    const args = [_][:0]const u8{ "reginald", "-vc=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short option combined value merged" {
    const args = [_][:0]const u8{ "reginald", "-vc/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short option combined value merged quoted" {
    const args = [_][:0]const u8{ "reginald", "-vc\"/tmp/config.toml\"" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, "/tmp/config.toml"));
    try testing.expectEqual(parsed.unknown, null);
}

test "short option combined value merged empty quoted" {
    const args = [_][:0]const u8{ "reginald", "-vc\"\"" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.option("config").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(std.mem.eql(u8, parsed.option("config").?.value.string, ""));
    try testing.expectEqual(parsed.unknown, null);
}

test "short option combined no value" {
    const args = [_][:0]const u8{ "reginald", "-vc" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "invalid empty short" {
    const args = [_][:0]const u8{ "reginald", "-" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "subcommand apply" {
    const args = [_][:0]const u8{ "reginald", "apply" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }
}

test "subcommand int option" {
    const args = [_][:0]const u8{ "reginald", "apply", "--jobs", "20" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }

    try testing.expectEqual(parsed.option("jobs").?.changed, true);
    try testing.expectEqual(parsed.option("jobs").?.value.int, 20);
    try testing.expectEqual(parsed.unknown, null);
}

test "subcommand global option before" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "apply", "--jobs", "20" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
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
    try testing.expectEqual(parsed.unknown, null);
}

test "subcommand global option after" {
    const args = [_][:0]const u8{ "reginald", "apply", "--verbose", "--jobs", "20" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
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
    try testing.expectEqual(parsed.unknown, null);
}

test "subcommand global option both" {
    const args = [_][:0]const u8{ "reginald", "--quiet", "apply", "--verbose", "--jobs", "20" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
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
    try testing.expectEqual(parsed.unknown, null);
}

test "subcommand option before" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "--jobs", "20", "apply" };
    const parsed = parseArgs(testing.allocator, &args, std.io.null_writer, .fail);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "no unknown" {
    const args = [_][:0]const u8{ "reginald", "apply", "--verbose", "--jobs", "40" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .collect);
    defer parsed.deinit();

    try testing.expect(parsed.command != null);

    // TODO: This definitely makes more sense when there are more commands.
    switch (parsed.command.?) {
        .apply => try testing.expect(true),
    }

    try testing.expectEqual(parsed.option("verbose").?.changed, true);
    try testing.expectEqual(parsed.option("jobs").?.changed, true);
    try testing.expectEqual(parsed.option("verbose").?.value.bool, true);
    try testing.expectEqual(parsed.option("jobs").?.value.int, 40);
    try testing.expect(parsed.unknown != null);
    try testing.expectEqual(parsed.unknown.?.items.len, 0);
}

test "unknown long option" {
    const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .collect);
    defer parsed.deinit();

    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("help").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.unknown != null);
    try testing.expectEqual(parsed.unknown.?.items.len, 1);
    const u = parsed.unknown.?.items[0];
    try testing.expectEqual(u.pos, 1);
    try testing.expectEqual(u.arg, "--not-real");
    try testing.expectEqualSlices(u8, u.option_name.?.long, "not-real");
}

test "unknown short option" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "-ah" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .collect);
    defer parsed.deinit();

    try testing.expect(parsed.option("help").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("help").?.value.bool);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.unknown != null);
    try testing.expectEqual(parsed.unknown.?.items.len, 1);
    const u = parsed.unknown.?.items[0];
    try testing.expectEqual(u.pos, 2);
    try testing.expectEqual(u.arg, "-ah");
    try testing.expectEqual(u.option_name.?.short, 'a');
}

test "unknown arg" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "-h", "not-real" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .collect);
    defer parsed.deinit();

    try testing.expect(parsed.option("help").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("help").?.value.bool);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.unknown != null);
    try testing.expectEqual(parsed.unknown.?.items.len, 1);
    const u = parsed.unknown.?.items[0];
    try testing.expectEqual(u.pos, 3);
    try testing.expectEqual(u.arg, "not-real");
    try testing.expectEqual(u.option_name, null);
}

test "multiple unknown" {
    const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose", "-ah", "unreal", "-b" };
    var parsed = try parseArgs(testing.allocator, &args, std.io.null_writer, .collect);
    defer parsed.deinit();

    try testing.expect(parsed.option("help").?.changed);
    try testing.expect(parsed.option("verbose").?.changed);
    try testing.expect(!parsed.option("version").?.changed);
    try testing.expect(!parsed.option("config").?.changed);
    try testing.expect(!parsed.option("directory").?.changed);
    try testing.expect(!parsed.option("quiet").?.changed);
    try testing.expect(parsed.option("help").?.value.bool);
    try testing.expect(parsed.option("verbose").?.value.bool);
    try testing.expect(parsed.unknown != null);
    try testing.expectEqual(parsed.unknown.?.items.len, 4);
    var u = parsed.unknown.?.items[0];
    try testing.expectEqual(u.pos, 1);
    try testing.expectEqual(u.arg, "--not-real");
    try testing.expectEqualSlices(u8, u.option_name.?.long, "not-real");
    u = parsed.unknown.?.items[1];
    try testing.expectEqual(u.pos, 3);
    try testing.expectEqual(u.arg, "-ah");
    try testing.expectEqual(u.option_name.?.short, 'a');
    u = parsed.unknown.?.items[2];
    try testing.expectEqual(u.pos, 4);
    try testing.expectEqual(u.arg, "unreal");
    try testing.expectEqual(u.option_name, null);
    u = parsed.unknown.?.items[3];
    try testing.expectEqual(u.pos, 5);
    try testing.expectEqual(u.arg, "-b");
    try testing.expectEqual(u.option_name.?.short, 'b');
}
