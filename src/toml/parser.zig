const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const fmt = std.fmt;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const StringArrayHashMap = std.StringArrayHashMap;

const AllocWhen = @import("scanner.zig").AllocWhen;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;

const nano_multiply = [_]u32{
    1000000000,
    100000000,
    10000000,
    1000000,
    100000,
    10000,
    1000,
    100,
    10,
    1,
};

/// Controls how the parser makes various decisions during the parsing.
pub const ParseOptions = struct {
    /// Passed to `toml.Scanner.nextAllocMax`. The default for `parseFromSlice`
    /// or `parseFromTokenSource` with a `*toml.Scanner` input is the length of
    /// the input slice, which means `error.ValueTooLong` will never be
    /// returned.
    max_value_len: ?usize = null,

    /// This determines whether strings should always be copied, or if
    /// a reference to the given buffer should be preferred if possible.
    /// The default for `parseFromSlice` or `parseFromTokenSource` with
    /// a `*toml.Scanner` input is `.alloc_if_needed`.
    allocate: ?AllocWhen = null,
};

/// TOML array value.
pub const Array = ArrayList(Value);

/// TOML table value.
pub const Table = StringArrayHashMap(Value);

/// Parsed value for a datetime in TOML.
pub const Datetime = struct {
    year: ?u16 = null,
    month: ?u8 = null,
    day: ?u8 = null,
    hour: ?u8 = null,
    minute: ?u8 = null,
    seconds: ?u8 = null,
    nano: ?u32 = null,
    offset_sign: ?enum(i2) { neg = -1, pos = 1 } = null,
    hour_offset: ?u8 = null,
    minute_offset: ?u8 = null,

    /// Parse an RFC 3339-formatted string into a `Datetime`.
    fn parse(slice: []const u8) !@This() {
        var buf: [64]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buf);
        const allocator = fba.allocator();

        var s = try allocator.dupe(u8, slice);

        // We just parse this with a few if statements. It's fast enough.
        var d = Datetime{};

        // Normal date first.
        if (s[4] == '-') {
            if (s[7] != '-' or s.len < 10) {
                return error.SyntaxError;
            }
            d.year = try fmt.parseUnsigned(u16, s[0..4], 10);
            d.month = try fmt.parseUnsigned(u8, s[5..7], 10);
            if (d.month.? == 0 or 13 <= d.month.?) {
                return error.SyntaxError;
            }
            d.day = try fmt.parseUnsigned(u8, s[8..10], 10);
            const leap_year = (d.year.? % 4 == 0 and (d.year.? % 100 != 0 or d.year.? % 400 == 0));
            switch (d.month.?) {
                1, 3, 5, 7, 8, 10, 12 => if (d.day.? > 31) {
                    return error.SyntaxError;
                },
                4, 6, 9, 11 => if (d.day.? > 30) {
                    return error.SyntaxError;
                },
                2 => if (leap_year) {
                    if (d.day.? > 29) {
                        return error.SyntaxError;
                    } else if (d.day.? > 28) {
                        return error.SyntaxError;
                    }
                },
                else => return error.SyntaxError,
            }

            if (s.len == 10) {
                return d;
            }

            if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') {
                return error.SyntaxError;
            }

            s = s[11..];
        }

        if (s.len < 8) {
            return error.SyntaxError;
        }

        if (s[2] != ':') {
            return error.SyntaxError;
        }

        d.hour = try fmt.parseUnsigned(u8, s[0..2], 10);
        if (d.hour.? > 23) {
            return error.SyntaxError;
        }
        d.minute = try fmt.parseUnsigned(u8, s[3..5], 10);
        if (d.minute.? > 59) {
            return error.SyntaxError;
        }
        d.seconds = try fmt.parseUnsigned(u8, s[6..8], 10);
        if (d.month) |m| {
            switch (m) {
                6 => if (d.day.? == 30) {
                    if (d.seconds.? > 60) {
                        return error.SyntaxError;
                    }
                } else if (d.seconds.? > 59) {
                    return error.SyntaxError;
                },
                12 => if (d.day.? == 31) {
                    if (d.seconds.? > 60) {
                        return error.SyntaxError;
                    }
                } else if (d.seconds.? > 59) {
                    return error.SyntaxError;
                },
                else => if (d.seconds.? > 59) {
                    return error.SyntaxError;
                },
            }
        } else if (d.seconds.? > 59) {
            return error.SyntaxError;
        }

        if (s.len == 8) {
            return d;
        }

        s = s[8..];

        if (s[0] == '.') {
            if (s.len < 2) {
                return error.SyntaxError;
            }
            s = s[1..];
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                switch (s[i]) {
                    '0'...'9' => continue,
                    else => break,
                }
            }
            d.nano = nano_multiply[i] * try fmt.parseUnsigned(u32, s[0..i], 10);

            if (s.len == i) {
                return d;
            }

            s = s[i..];
        }

        if (s.len == 1) {
            if (s[0] != 'Z' and s[0] != 'z') {
                return error.SyntaxError;
            }

            return d;
        }

        if (s.len != 6) {
            return error.SyntaxError;
        }

        switch (s[0]) {
            '+' => d.offset_sign = .pos,
            '-' => d.offset_sign = .neg,
            else => return error.SyntaxError,
        }

        d.hour_offset = try fmt.parseUnsigned(u8, s[1..3], 10);
        if (d.hour_offset.? > 23) {
            return error.SyntaxError;
        }

        if (s[3] != ':') {
            return error.SyntaxError;
        }

        d.minute_offset = try fmt.parseUnsigned(u8, s[4..6], 10);
        if (d.minute_offset.? > 59) {
            return error.SyntaxError;
        }

        return d;
    }
};

/// Represents TOML value, including the root table. It can contain other TOML
/// values. All TOML documents are first parsed into `Value`s to avoid dealing
/// with the more dynamic nature of TOML compared to something like JSON.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    datetime: Datetime,
    array: Array,
    table: Table,
};

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

/// TOML types for tracking the definitions.
const TomlType = enum {
    string,
    int,
    float,
    bool,
    datetime,
    array,
    table,
    implicit_table, // super tables in when defining subtables in table headers
    array_table,
};

const ParseError = error{
    BufferUnderrun,
    CodepointTooLarge,
    DuplicateKey,
    InvalidCharacter,
    OutOfMemory,
    Overflow,
    SyntaxError,
    UnexpectedEndOfInput,
    UnexpectedToken,
    Utf8CannotEncodeSurrogateHalf,
    ValueTooLong,
};

/// Parse the TOML document from `s` and return the resulting `Value` packaged
/// in `toml.Parsed`. You must call `deinit` of the returned object to clean up
/// the allocated resources.
pub fn parseFromSlice(allocator: Allocator, s: []const u8, options: ParseOptions) !Parsed(Value) {
    var scanner = Scanner.initCompleteInput(allocator, s);
    defer scanner.deinit();

    return parseFromTokenSource(allocator, &scanner, options);
}

/// Parse the TOML document represented by the `scanner` token source and return
/// the resulting `Value` packaged in `toml.Parsed`. You must call `deinit` of
/// the returned object to clean up the allocated resources.
pub fn parseFromTokenSource(
    allocator: Allocator,
    scanner: *Scanner,
    options: ParseOptions,
) !Parsed(Value) {
    var parsed = Parsed(Value){
        .arena = try allocator.create(ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    parsed.value = try parseFromTokenSourceLeaky(parsed.arena.allocator(), scanner, options);

    return parsed;
}

/// Parse the TOML document from the `scanner` token source. Allocations made
/// during this operation are not carefully tracked and may not be possible to
/// individually clean up. It is recommended to use a `std.heap.ArenaAllocator`
/// or similar.
pub fn parseFromTokenSourceLeaky(
    allocator: Allocator,
    scanner: *Scanner,
    options: ParseOptions,
) !Value {
    assert(scanner.is_end_of_input);

    var resolved_options = options;

    if (resolved_options.max_value_len == null) {
        resolved_options.max_value_len = scanner.input.len;
    }

    if (resolved_options.allocate == null) {
        resolved_options.allocate = .alloc_if_needed;
    }

    const value = parseRootTable(allocator, scanner, resolved_options);

    assert(try scanner.next() == .end_of_document);

    return value;
}

fn parseRootTable(allocator: Allocator, source: *Scanner, options: ParseOptions) !Value {
    var r = Value{ .table = .init(allocator) };
    var defined = StringArrayHashMap(TomlType).init(allocator);
    defer defined.deinit();

    const root_table: *Table = &r.table;
    try parseTable(allocator, root_table, null, &defined, source, options);

    return r;
}

fn parseTable(
    allocator: Allocator,
    table: *Table,
    parent_key: ?[]const u8,
    defined: *StringArrayHashMap(TomlType),
    source: *Scanner,
    options: ParseOptions,
) ParseError!void {
    while (true) {
        const token = try source.next();

        // Parsing should always start with a beginning of a key.
        switch (token) {
            .end_of_document => break,
            .key_begin => {
                var key_parts = ArrayList([]const u8).init(allocator);
                defer key_parts.deinit();

                while (true) {
                    const key_token = try source.nextAllocMax(
                        allocator,
                        .alloc_if_needed,
                        options.max_value_len.?,
                    );
                    switch (key_token) {
                        .key, .allocated_key => |s| try key_parts.append(s),
                        else => return error.SyntaxError,
                    }

                    switch (try source.next()) {
                        .key_begin => continue,
                        .value_begin => break,
                        else => return error.UnexpectedToken,
                    }
                }

                var current_table: *Table = table;
                var def_key = try mem.join(allocator, ".", key_parts.items);
                if (parent_key) |parent| {
                    def_key = try mem.join(allocator, ".", &[_][]const u8{ parent, def_key });
                }
                // defer allocator.free(full_key);

                if (defined.contains(def_key)) {
                    return error.DuplicateKey;
                }

                var i: usize = 0;
                while (i < key_parts.items.len - 1) : (i += 1) {
                    const k = key_parts.items[i];
                    if (current_table.contains(k)) {
                        var v = current_table.get(k).?;
                        switch (v) {
                            .table => |*t| current_table = t,
                            else => unreachable,
                        }
                    } else {
                        const full = try mem.join(allocator, ".", key_parts.items[0 .. i + 1]);
                        var def = try allocator.dupe(u8, full);
                        if (parent_key) |parent| {
                            def = try mem.join(allocator, ".", &[_][]const u8{ parent, full });
                        }

                        if (defined.contains(def) and defined.get(def).? != .implicit_table) {
                            return error.DuplicateKey;
                        }

                        try current_table.put(k, .{ .table = .init(allocator) });
                        var v = current_table.get(k).?;
                        switch (v) {
                            .table => |*t| current_table = t,
                            else => unreachable,
                        }
                        try defined.put(def, .implicit_table);
                    }
                }

                const v = try parseValue(allocator, def_key, defined, source, options);
                if (v == null) {
                    return error.UnexpectedToken;
                }

                try current_table.put(key_parts.items[key_parts.items.len - 1], v.?);
                const tt: TomlType = switch (v.?) {
                    .string => .string,
                    .int => .int,
                    .float => .float,
                    .bool => .bool,
                    .datetime => .datetime,
                    .array => .array,
                    .table => .table,
                };
                try defined.put(def_key, tt);
            },

            .table_key_begin => {
                var key_parts = ArrayList([]const u8).init(allocator);
                defer key_parts.deinit();

                while (true) {
                    const key_token = try source.nextAllocMax(
                        allocator,
                        .alloc_if_needed,
                        options.max_value_len.?,
                    );
                    switch (key_token) {
                        .key, .allocated_key => |s| try key_parts.append(s),
                        else => return error.SyntaxError,
                    }

                    switch (try source.next()) {
                        .table_key_begin => continue,
                        .table_begin => break,
                        else => return error.UnexpectedToken,
                    }
                }

                var current_table: *Table = table;
                const def_key = try mem.join(allocator, ".", key_parts.items);
                // defer allocator.free(full_key);

                if (defined.contains(def_key) and defined.get(def_key).? != .implicit_table) {
                    return error.DuplicateKey;
                }

                var i: usize = 0;
                while (i < key_parts.items.len - 1) : (i += 1) {
                    const k = key_parts.items[i];
                    if (current_table.contains(k)) {
                        var v = current_table.get(k).?;
                        switch (v) {
                            .table => |*t| current_table = t,
                            else => unreachable,
                        }
                    } else {
                        const full = try mem.join(allocator, ".", key_parts.items[0 .. i + 1]);
                        const def = try allocator.dupe(u8, full);

                        if (defined.contains(def) and defined.get(def).? != .implicit_table) {
                            return error.DuplicateKey;
                        }

                        try current_table.put(k, .{ .table = .init(allocator) });
                        var v = current_table.get(k).?;
                        switch (v) {
                            .table => |*t| current_table = t,
                            else => unreachable,
                        }
                        try defined.put(def, .implicit_table);
                    }
                }

                try parseTable(allocator, current_table, def_key, defined, source, options);

                if (parent_key != null) {
                    return;
                }
            },
            .array_table_key_begin => {
                var key_parts = ArrayList([]const u8).init(allocator);
                defer key_parts.deinit();

                while (true) {
                    const key_token = try source.nextAllocMax(
                        allocator,
                        .alloc_if_needed,
                        options.max_value_len.?,
                    );
                    switch (key_token) {
                        .key, .allocated_key => |s| try key_parts.append(s),
                        else => return error.SyntaxError,
                    }

                    switch (try source.next()) {
                        .array_table_key_begin => continue,
                        .table_begin => break,
                        else => return error.UnexpectedToken,
                    }
                }

                var current_table: *Table = table;
                const def_key = try mem.join(allocator, ".", key_parts.items);
                // defer allocator.free(full_key);

                if (defined.contains(def_key) and defined.get(def_key).? != .array_table) {
                    return error.DuplicateKey;
                }

                var i: usize = 0;
                while (i < key_parts.items.len - 1) : (i += 1) {
                    const k = key_parts.items[i];
                    if (current_table.contains(k)) {
                        var v = current_table.get(k).?;
                        switch (v) {
                            .table => |*t| current_table = t,
                            else => unreachable,
                        }
                    } else {
                        const full = try mem.join(allocator, ".", key_parts.items[0 .. i + 1]);
                        const def = try allocator.dupe(u8, full);

                        const got = defined.get(def);
                        if (defined.contains(def) and got.? != .table and got.? != .implicit_table) {
                            return error.DuplicateKey;
                        }

                        try current_table.put(k, .{ .table = .init(allocator) });
                        var v = current_table.get(k).?;
                        switch (v) {
                            .table => |*t| current_table = t,
                            else => unreachable,
                        }
                        try defined.put(def, .implicit_table);
                    }
                }

                var value_table = Table.init(allocator);
                var table_defs = StringArrayHashMap(TomlType).init(allocator);
                defer table_defs.deinit();

                try parseTable(allocator, &value_table, null, &table_defs, source, options);

                const key = key_parts.items[key_parts.items.len - 1];
                var array = Array.init(allocator);
                if (current_table.get(key)) |value| {
                    switch (value) {
                        .array => |a| {
                            try array.appendSlice(a.items);
                            a.deinit();
                        },
                        else => return error.UnexpectedToken,
                    }
                }
                try array.append(.{ .table = value_table });
                try current_table.put(key, .{ .array = array });

                try defined.put(def_key, .array_table);
            },

            // Checking this here is the simplest way to make a clean exit from
            // the parsing. The scanner does not make up this token and it comes
            // instead of a key.
            .inline_table_end => return,

            else => return error.UnexpectedToken,
        }
    }
}

fn parseValue(
    allocator: Allocator,
    parent_key: ?[]const u8,
    defined: *StringArrayHashMap(TomlType),
    source: *Scanner,
    options: ParseOptions,
) ParseError!?Value {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    defer freeAllocated(allocator, token);

    switch (token) {
        .string, .allocated_string => |slice| {
            return .{ .string = slice };
        },
        .int, .allocated_int => |slice| {
            return .{ .int = try fmt.parseInt(i64, slice, 0) };
        },
        .float, .allocated_float => |slice| {
            if (mem.eql(u8, slice, "inf")) {
                return .{ .float = math.inf(f64) };
            } else if (mem.eql(u8, slice, "-inf")) {
                return .{ .float = -math.inf(f64) };
            } else if (mem.eql(u8, slice, "+inf")) {
                return .{ .float = math.inf(f64) };
            } else if (mem.eql(u8, slice, "nan")) {
                return .{ .float = math.nan(f64) };
            } else if (mem.eql(u8, slice, "-nan")) {
                return .{ .float = -math.nan(f64) };
            } else if (mem.eql(u8, slice, "+nan")) {
                return .{ .float = math.nan(f64) };
            }

            return .{ .float = try fmt.parseFloat(f64, slice) };
        },
        .true => {
            return .{ .bool = true };
        },
        .false => {
            return .{ .bool = false };
        },
        .datetime, .allocated_datetime => |slice| {
            return .{ .datetime = try Datetime.parse(slice) };
        },
        .array_begin => {
            var array = Array.init(allocator);
            while (true) {
                var array_defined = StringArrayHashMap(TomlType).init(allocator);
                defer array_defined.deinit();
                const value = try parseValue(allocator, null, &array_defined, source, options);
                if (value) |v| {
                    try array.append(v);
                } else {
                    break;
                }
            }

            return .{ .array = array };
        },
        .inline_table_begin => {
            var t = Table.init(allocator);
            try parseTable(allocator, &t, parent_key, defined, source, options);
            return .{ .table = t };
        },
        .array_end, .inline_table_end => return null,
        else => return error.UnexpectedToken,
    }
}

fn freeAllocated(allocator: Allocator, token: Token) void {
    switch (token) {
        .allocated_key => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}
