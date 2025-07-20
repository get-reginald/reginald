const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const unicode = std.unicode;

const native_os = builtin.target.os.tag;

pub const AllocWhen = enum { alloc_if_needed, alloc_always };

/// The parsing errors are divided into two categories:
///  * `SyntaxError` is for clearly malformed TOML documents, such as giving
///    an input document that isn't TOML at all.
///  * `UnexpectedEndOfInput` is for signaling that everything's been valid so
///    far, but the input appears to be truncated for some reason.
/// Note that a completely empty (or whitespace-only) input will give
/// `UnexpectedEndOfInput`.
pub const Error = error{ SyntaxError, UnexpectedEndOfInput };

pub const Diagnostics = struct {
    line_number: u64 = 1,
    line_start_cursor: usize = @as(usize, @bitCast(@as(isize, -1))), // Start just "before" the input buffer to get a 1-based column for line 1.
    total_bytes_before_current_input: u64 = 0,
    cursor_pointer: *const usize = undefined,

    /// Starts at 1.
    pub fn getLine(self: *const @This()) u64 {
        return self.line_number;
    }

    /// Starts at 1.
    pub fn getColumn(self: *const @This()) u64 {
        return self.cursor_pointer.* -% self.line_start_cursor;
    }

    /// Starts at 0. Measures the byte offset since the start of the input.
    pub fn getByteOffset(self: *const @This()) u64 {
        return self.total_bytes_before_current_input + self.cursor_pointer.*;
    }
};

/// Tokens emitted by `toml.Scanner` `next*()` functions.
pub const Token = union(enum) {
    key_begin,
    table_key_begin,
    array_table_key_begin,

    key: []const u8,
    partial_key: []const u8,
    partial_key_escaped_1: [1]u8,
    allocated_key: []const u8,

    table_begin,

    value_begin,

    string: []const u8,
    partial_string: []const u8,
    partial_string_escaped_1: [1]u8,
    allocated_string: []const u8,
    int: []const u8,
    allocated_int: []const u8,
    float: []const u8,
    allocated_float: []const u8,
    true,
    false,
    datetime: []const u8,
    allocated_datetime: []const u8,
    array_begin,
    array_end,
    inline_table_begin,
    inline_table_end,

    end_of_document,
};

pub const TokenType = enum {
    key_begin,
    table_key_begin,
    array_table_key_begin,

    key,

    table_begin,

    value_begin,

    string,
    int,
    float,
    true,
    false,
    datetime,
    array_begin,
    array_end,
    inline_table_begin,
    inline_table_end,

    end_of_document,
};

/// The lowest-level parsing API for TOML. It emits tokens from full TOML input.
///
/// TODO: Think if we should support streaming tokens.
pub const Scanner = struct {
    state: State = .table,
    stack: ArrayList(Mode),
    value_start: usize = undefined,

    input: []const u8 = "",
    cursor: usize = 0,
    is_end_of_input: bool = false,
    diagnostics: ?*Diagnostics = null,

    const Mode = enum {
        /// Parsing table keys.
        key,
        /// Parsing a value.
        value,
        /// Parsing an array inside a value.
        array,
        /// Parsing an inline table inside a value.
        inline_table,
        /// A comma-terminator was found in an array or inline table.
        comma,
        /// A newline was found in an array or inline table.
        line_feed,
    };

    const State = enum {
        table,

        key_bare,
        key_string,
        key_literal_string,
        table_key_bare,
        table_key_string,
        table_key_literal_string,
        array_table_key_bare,
        array_table_key_string,
        array_table_key_literal_string,

        post_key,
        post_table_key,
        post_array_table_key,

        // String key parsing.
        key_string_backslash,
        key_string_backslash_u,
        key_string_backslash_upper_u,
        table_key_string_backslash,
        table_key_string_backslash_u,
        table_key_string_backslash_upper_u,
        array_table_key_string_backslash,
        array_table_key_string_backslash_u,
        array_table_key_string_backslash_upper_u,

        // Values.
        inline_table,
        value,

        string,
        string_backslash,
        string_backslash_u,
        string_backslash_upper_u,

        multiline_string,
        multiline_string_newline,
        multiline_string_backslash,
        multiline_string_backslash_u,
        multiline_string_backslash_upper_u,

        literal_string,

        multiline_literal_string,

        number, // state for parsing when the value can be any number

        literal_t,
        literal_tr,
        literal_tru,
        literal_f,
        literal_fa,
        literal_fal,
        literal_fals,

        post_value,

        // UTF-8 validation.
        // From https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
        key_string_utf8_state_a,
        key_string_utf8_state_b,
        key_string_utf8_state_c,
        key_string_utf8_state_d,
        key_string_utf8_state_e,
        key_string_utf8_state_f,
        key_string_utf8_state_g,

        key_literal_string_utf8_state_a,
        key_literal_string_utf8_state_b,
        key_literal_string_utf8_state_c,
        key_literal_string_utf8_state_d,
        key_literal_string_utf8_state_e,
        key_literal_string_utf8_state_f,
        key_literal_string_utf8_state_g,

        table_key_string_utf8_state_a,
        table_key_string_utf8_state_b,
        table_key_string_utf8_state_c,
        table_key_string_utf8_state_d,
        table_key_string_utf8_state_e,
        table_key_string_utf8_state_f,
        table_key_string_utf8_state_g,

        table_key_literal_string_utf8_state_a,
        table_key_literal_string_utf8_state_b,
        table_key_literal_string_utf8_state_c,
        table_key_literal_string_utf8_state_d,
        table_key_literal_string_utf8_state_e,
        table_key_literal_string_utf8_state_f,
        table_key_literal_string_utf8_state_g,

        array_table_key_string_utf8_state_a,
        array_table_key_string_utf8_state_b,
        array_table_key_string_utf8_state_c,
        array_table_key_string_utf8_state_d,
        array_table_key_string_utf8_state_e,
        array_table_key_string_utf8_state_f,
        array_table_key_string_utf8_state_g,

        array_table_key_literal_string_utf8_state_a,
        array_table_key_literal_string_utf8_state_b,
        array_table_key_literal_string_utf8_state_c,
        array_table_key_literal_string_utf8_state_d,
        array_table_key_literal_string_utf8_state_e,
        array_table_key_literal_string_utf8_state_f,
        array_table_key_literal_string_utf8_state_g,

        string_utf8_state_a,
        string_utf8_state_b,
        string_utf8_state_c,
        string_utf8_state_d,
        string_utf8_state_e,
        string_utf8_state_f,
        string_utf8_state_g,

        multiline_string_utf8_state_a,
        multiline_string_utf8_state_b,
        multiline_string_utf8_state_c,
        multiline_string_utf8_state_d,
        multiline_string_utf8_state_e,
        multiline_string_utf8_state_f,
        multiline_string_utf8_state_g,

        literal_string_utf8_state_a,
        literal_string_utf8_state_b,
        literal_string_utf8_state_c,
        literal_string_utf8_state_d,
        literal_string_utf8_state_e,
        literal_string_utf8_state_f,
        literal_string_utf8_state_g,

        multiline_literal_string_utf8_state_a,
        multiline_literal_string_utf8_state_b,
        multiline_literal_string_utf8_state_c,
        multiline_literal_string_utf8_state_d,
        multiline_literal_string_utf8_state_e,
        multiline_literal_string_utf8_state_f,
        multiline_literal_string_utf8_state_g,
    };

    /// Use this if your input is a single slice.
    pub fn initCompleteInput(allocator: Allocator, complete_input: []const u8) @This() {
        return .{
            .stack = ArrayList(Mode).init(allocator),
            .input = complete_input,
            .is_end_of_input = true,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.stack.deinit();
        self.* = undefined;
    }

    pub const NextError = Error || Allocator.Error || fmt.ParseIntError || error{
        BufferUnderrun,
        Utf8CannotEncodeSurrogateHalf,
        CodepointTooLarge,
    };
    pub const AllocError = Error || Allocator.Error || fmt.ParseIntError || error{
        ValueTooLong,
        Utf8CannotEncodeSurrogateHalf,
        CodepointTooLarge,
    };
    pub const PeekError = Error || error{BufferUnderrun};
    pub const AllocIntoArrayListError = AllocError || fmt.ParseIntError || error{
        BufferUnderrun,
        Utf8CannotEncodeSurrogateHalf,
        CodepointTooLarge,
    };

    pub fn nextAllocMax(
        self: *@This(),
        allocator: Allocator,
        when: AllocWhen,
        max_value_len: usize,
    ) AllocError!Token {
        assert(self.is_end_of_input);

        const token_type = self.peekNextTokenType() catch |e| switch (e) {
            error.BufferUnderrun => unreachable,
            else => |err| return err,
        };

        switch (token_type) {
            .key => {
                var value_list = ArrayList(u8).init(allocator);
                errdefer value_list.deinit();

                const slice = self.allocNextIntoArrayListMax(
                    &value_list,
                    when,
                    max_value_len,
                ) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };

                if (slice) |s| {
                    return .{ .key = s };
                } else {
                    return .{ .key = try value_list.toOwnedSlice() };
                }
            },

            .string => {
                var value_list = ArrayList(u8).init(allocator);
                errdefer value_list.deinit();

                const slice = self.allocNextIntoArrayListMax(
                    &value_list,
                    when,
                    max_value_len,
                ) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };

                if (slice) |s| {
                    return .{ .string = s };
                } else {
                    return .{ .string = try value_list.toOwnedSlice() };
                }
            },

            .int => {
                var value_list = ArrayList(u8).init(allocator);
                errdefer value_list.deinit();

                const slice = self.allocNextIntoArrayListMax(
                    &value_list,
                    when,
                    max_value_len,
                ) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };

                if (slice) |s| {
                    return .{ .int = s };
                } else {
                    return .{ .allocated_int = try value_list.toOwnedSlice() };
                }
            },

            .float => {
                var value_list = ArrayList(u8).init(allocator);
                errdefer value_list.deinit();

                const slice = self.allocNextIntoArrayListMax(
                    &value_list,
                    when,
                    max_value_len,
                ) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };

                if (slice) |s| {
                    return .{ .float = s };
                } else {
                    return .{ .allocated_float = try value_list.toOwnedSlice() };
                }
            },

            .datetime => {
                var value_list = ArrayList(u8).init(allocator);
                errdefer value_list.deinit();

                const slice = self.allocNextIntoArrayListMax(
                    &value_list,
                    when,
                    max_value_len,
                ) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };

                if (slice) |s| {
                    return .{ .datetime = s };
                } else {
                    return .{ .allocated_datetime = try value_list.toOwnedSlice() };
                }
            },

            // Simple tokens never alloc.
            .key_begin,
            .table_key_begin,
            .array_table_key_begin,
            .table_begin,
            .value_begin,
            .true,
            .false,
            .array_begin,
            .array_end,
            .inline_table_begin,
            .inline_table_end,
            .end_of_document,
            => return self.next() catch |e| switch (e) {
                error.BufferUnderrun => unreachable,
                else => |err| return err,
            },
        }
    }

    pub fn allocNextIntoArrayListMax(
        self: *@This(),
        value_list: *ArrayList(u8),
        when: AllocWhen,
        max_value_len: usize,
    ) AllocIntoArrayListError!?[]const u8 {
        while (true) {
            const token = try self.next();

            switch (token) {
                .partial_key => |slice| {
                    try appendSlice(value_list, slice, max_value_len);
                },
                .partial_key_escaped_1 => |buf| {
                    try appendSlice(value_list, buf[0..], max_value_len);
                },
                .key => |slice| {
                    if (when == .alloc_if_needed and value_list.items.len == 0) {
                        // No alloc necessary.
                        return slice;
                    }

                    try appendSlice(value_list, slice, max_value_len);

                    return null;
                },
                .partial_string => |slice| {
                    try appendSlice(value_list, slice, max_value_len);
                },
                .partial_string_escaped_1 => |buf| {
                    try appendSlice(value_list, buf[0..], max_value_len);
                },
                .string => |slice| {
                    if (when == .alloc_if_needed and value_list.items.len == 0) {
                        // No alloc necessary.
                        return slice;
                    }

                    try appendSlice(value_list, slice, max_value_len);

                    return null;
                },
                .int => |slice| {
                    if (when == .alloc_if_needed and value_list.items.len == 0) {
                        // No alloc necessary.
                        return slice;
                    }

                    try appendSlice(value_list, slice, max_value_len);

                    return null;
                },
                .float => |slice| {
                    if (when == .alloc_if_needed and value_list.items.len == 0) {
                        // No alloc necessary.
                        return slice;
                    }

                    try appendSlice(value_list, slice, max_value_len);

                    return null;
                },
                .datetime => |slice| {
                    if (when == .alloc_if_needed and value_list.items.len == 0) {
                        // No alloc necessary.
                        return slice;
                    }

                    try appendSlice(value_list, slice, max_value_len);

                    return null;
                },

                .true,
                .false,
                .array_begin,
                .array_end,
                .inline_table_begin,
                .inline_table_end,

                .key_begin,
                .table_key_begin,
                .array_table_key_begin,
                .table_begin,
                .value_begin,
                .end_of_document,
                => unreachable,

                .allocated_key,
                .allocated_string,
                .allocated_int,
                .allocated_float,
                .allocated_datetime,
                => unreachable,
            }
        }
    }

    /// The depth of current nesting used for checking if the ending position of
    /// the TOML document is valid.
    pub fn stackHeight(self: *const @This()) usize {
        return self.stack.items.len;
    }

    /// Peek the last value of the parsing mode stack.
    pub fn peekStack(self: *const @This()) ?Mode {
        if (self.stackHeight() < 1) {
            return null;
        }

        return self.stack.items[self.stackHeight() - 1];
    }

    /// Return the next raw token from the scanner. The typical flow involves
    /// looking up tokens with `next`, and when the parser expects a "real"
    /// value to come next, it calls the `nextAlloc*` functions for getting
    /// the value as `next` may return partial tokens. It should also be noted
    /// that `next` alone does not properly update the definition table and
    /// the `Scanner` should be used with the parsing functions (that use
    /// `nextAlloc*`) to make sure that the TOML document does not contain
    /// duplicate definitions.
    pub fn next(self: *@This()) NextError!Token {
        state_loop: while (true) {
            switch (self.state) {
                .table => {
                    if (try self.skipWsCrLnCheckEnd()) {
                        return .end_of_document;
                    }

                    switch (try self.skipWsCrLnExpectByte()) {
                        '#' => {
                            try self.skipComment();
                            continue;
                        },
                        '[' => {
                            self.cursor += 1;
                            if (self.cursor >= self.input.len) {
                                return error.UnexpectedEndOfInput;
                            }

                            // Special handling for arrays of tables as no
                            // whitespace is allowed between the two square
                            // brackets.
                            if (self.input[self.cursor] == '[') {
                                self.cursor += 1;
                                switch (try self.skipWsExpectByte()) {
                                    '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                                        try self.stack.append(.key);
                                        self.value_start = self.cursor;
                                        self.state = .array_table_key_bare;
                                        return .array_table_key_begin;
                                    },
                                    '"' => {
                                        try self.stack.append(.key);
                                        self.cursor += 1;
                                        self.value_start = self.cursor;
                                        self.state = .array_table_key_string;
                                        return .array_table_key_begin;
                                    },
                                    '\'' => {
                                        try self.stack.append(.key);
                                        self.cursor += 1;
                                        self.value_start = self.cursor;
                                        self.state = .array_table_key_literal_string;
                                        return .array_table_key_begin;
                                    },
                                    else => return error.SyntaxError,
                                }
                            }

                            // Do we open a table key or is this an array of
                            // tables.
                            switch (try self.skipWsExpectByte()) {
                                '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                                    try self.stack.append(.key);
                                    self.value_start = self.cursor;
                                    self.state = .table_key_bare;
                                    return .table_key_begin;
                                },
                                '"' => {
                                    try self.stack.append(.key);
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .table_key_string;
                                    return .table_key_begin;
                                },
                                '\'' => {
                                    try self.stack.append(.key);
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .table_key_literal_string;
                                    return .table_key_begin;
                                },
                                else => return error.SyntaxError,
                            }
                        },
                        '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                            try self.stack.append(.value);
                            self.value_start = self.cursor;
                            self.state = .key_bare;
                            return .key_begin;
                        },
                        '"' => {
                            try self.stack.append(.value);
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return .key_begin;
                        },
                        '\'' => {
                            try self.stack.append(.value);
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_literal_string;
                            return .key_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .key_bare => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            // Only ASCII numbers, letters, hyphens, and
                            // underscores are allowed in bare keys.
                            '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => continue,
                            // Keys end at whitespace.
                            ' ', '\t' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_key;
                                return result;
                            },
                            // No whitespace before next character, stop key but
                            // don't move past the next character.
                            '=', '.' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.state = .post_key;
                                return result;
                            },
                            else => return error.SyntaxError,
                        }
                    }
                },
                .key_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError, // bare control code
                            // Plain printable ASCII characters.
                            '\t', 0x20...('"' - 1), ('"' + 1)...('\\' - 1), ('\\' + 1)...0x7e => continue,
                            // Unescaped quote ends the string.
                            '"' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_key;
                                return result;
                            },
                            '\\' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.state = .key_string_backslash;

                                if (slice.len > 0) {
                                    return Token{ .partial_key = slice };
                                }

                                continue :state_loop;
                            },

                            // UTF-8 validation.
                            // See https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .key_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },
                .key_string_backslash => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        '"', '\\' => {
                            // Since these characters now represent themselves literally, we can
                            // simply begin the next plaintext slice here.
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .key_string;
                            continue :state_loop;
                        },
                        'b' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{0x08} };
                        },
                        't' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\t'} };
                        },
                        'n' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\n'} };
                        },
                        'f' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{0x0c} };
                        },
                        'r' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\r'} };
                        },
                        'u' => {
                            self.cursor += 1;
                            self.state = .key_string_backslash_u;
                            continue :state_loop;
                        },
                        'U' => {
                            self.cursor += 1;
                            self.state = .key_string_backslash_upper_u;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_backslash_u => {
                    if (self.cursor + 4 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 4];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 4;
                    self.state = .key_string;
                    return Token{ .partial_key = buf[0..n] };
                },
                .key_string_backslash_upper_u => {
                    if (self.cursor + 8 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 8];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 8;
                    self.state = .key_string;
                    return Token{ .partial_key = buf[0..n] };
                },
                .key_literal_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('\'' - 1), ('\'' + 1)...0x7e => continue,
                            '\'' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_key;
                                return result;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .key_literal_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },

                .post_key => {
                    switch (try self.skipWsExpectByte()) {
                        '.' => {
                            self.cursor += 1;

                            switch (try self.skipWsExpectByte()) {
                                '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                                    self.value_start = self.cursor;
                                    self.state = .key_bare;
                                    return .key_begin;
                                },
                                '"' => {
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .key_string;
                                    return .key_begin;
                                },
                                '\'' => {
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .key_literal_string;
                                    return .key_begin;
                                },
                                else => return error.SyntaxError,
                            }
                        },
                        '=' => {
                            self.cursor += 1;

                            if (try self.skipWsCheckEnd()) {
                                return error.UnexpectedEndOfInput;
                            }

                            self.value_start = self.cursor;
                            self.state = .value;
                            return .value_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .table_key_bare => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => continue,
                            ' ', '\t' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_table_key;
                                return result;
                            },
                            '.', ']' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.state = .post_table_key;
                                return result;
                            },
                            else => return error.SyntaxError,
                        }
                    }
                },
                .table_key_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('"' - 1), ('"' + 1)...('\\' - 1), ('\\' + 1)...0x7e => continue,
                            '"' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_table_key;
                                return result;
                            },
                            '\\' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.state = .table_key_string_backslash;

                                if (slice.len > 0) {
                                    return Token{ .partial_key = slice };
                                }

                                continue :state_loop;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .table_key_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },
                .table_key_string_backslash => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        '"', '\\' => {
                            // Since these characters now represent themselves literally, we can
                            // simply begin the next plaintext slice here.
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .table_key_string;
                            continue :state_loop;
                        },
                        'b' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{0x08} };
                        },
                        't' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\t'} };
                        },
                        'n' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\n'} };
                        },
                        'f' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{0x0c} };
                        },
                        'r' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\r'} };
                        },
                        'u' => {
                            self.cursor += 1;
                            self.state = .table_key_string_backslash_u;
                            continue :state_loop;
                        },
                        'U' => {
                            self.cursor += 1;
                            self.state = .table_key_string_backslash_upper_u;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_backslash_u => {
                    if (self.cursor + 4 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 4];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 4;
                    self.state = .table_key_string;
                    return Token{ .partial_key = buf[0..n] };
                },
                .table_key_string_backslash_upper_u => {
                    if (self.cursor + 8 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 8];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 8;
                    self.state = .table_key_string;
                    return Token{ .partial_key = buf[0..n] };
                },
                .table_key_literal_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('\'' - 1), ('\'' + 1)...0x7e => continue,
                            '\'' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_table_key;
                                return result;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .table_key_literal_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },

                .post_table_key => {
                    switch (try self.skipWsExpectByte()) {
                        '.' => {
                            self.cursor += 1;

                            switch (try self.skipWsExpectByte()) {
                                '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                                    self.value_start = self.cursor;
                                    self.state = .table_key_bare;
                                    return .table_key_begin;
                                },
                                '"' => {
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .table_key_string;
                                    return .table_key_begin;
                                },
                                '\'' => {
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .table_key_literal_string;
                                    return .table_key_begin;
                                },
                                else => return error.SyntaxError,
                            }
                        },
                        ']' => {
                            self.cursor += 1;

                            const pop = self.stack.pop();
                            if (pop == null or pop.? != .key) {
                                return error.SyntaxError;
                            }

                            if (try self.skipWsCrLnCheckEnd()) {
                                return .end_of_document;
                            }

                            self.state = .table;
                            return .table_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .array_table_key_bare => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => continue,
                            ' ', '\t' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_array_table_key;
                                return result;
                            },
                            '.', ']' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.state = .post_array_table_key;
                                return result;
                            },
                            else => return error.SyntaxError,
                        }
                    }
                },
                .array_table_key_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('"' - 1), ('"' + 1)...('\\' - 1), ('\\' + 1)...0x7e => continue,
                            '"' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_array_table_key;
                                return result;
                            },
                            '\\' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.state = .array_table_key_string_backslash;

                                if (slice.len > 0) {
                                    return Token{ .partial_key = slice };
                                }

                                continue :state_loop;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .array_table_key_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },
                .array_table_key_string_backslash => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        '"', '\\' => {
                            // Since these characters now represent themselves literally, we can
                            // simply begin the next plaintext slice here.
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .array_table_key_string;
                            continue :state_loop;
                        },
                        'b' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .array_table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{0x08} };
                        },
                        't' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .array_table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\t'} };
                        },
                        'n' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .array_table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\n'} };
                        },
                        'f' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .array_table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{0x0c} };
                        },
                        'r' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .array_table_key_string;
                            return Token{ .partial_key_escaped_1 = [_]u8{'\r'} };
                        },
                        'u' => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_backslash_u;
                            continue :state_loop;
                        },
                        'U' => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_backslash_upper_u;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_backslash_u => {
                    if (self.cursor + 4 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 4];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 4;
                    self.state = .array_table_key_string;
                    return Token{ .partial_key = buf[0..n] };
                },
                .array_table_key_string_backslash_upper_u => {
                    if (self.cursor + 8 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 8];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 8;
                    self.state = .array_table_key_string;
                    return Token{ .partial_key = buf[0..n] };
                },
                .array_table_key_literal_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('\'' - 1), ('\'' + 1)...0x7e => continue,
                            '\'' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_array_table_key;
                                return result;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .array_table_key_literal_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },
                .post_array_table_key => {
                    switch (try self.skipWsExpectByte()) {
                        '.' => {
                            self.cursor += 1;

                            switch (try self.skipWsExpectByte()) {
                                '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                                    self.value_start = self.cursor;
                                    self.state = .array_table_key_bare;
                                    return .array_table_key_begin;
                                },
                                '"' => {
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .array_table_key_string;
                                    return .array_table_key_begin;
                                },
                                '\'' => {
                                    self.cursor += 1;
                                    self.value_start = self.cursor;
                                    self.state = .array_table_key_literal_string;
                                    return .array_table_key_begin;
                                },
                                else => return error.SyntaxError,
                            }
                        },
                        ']' => {
                            self.cursor += 1;

                            if (self.cursor >= self.input.len) {
                                return error.SyntaxError;
                            }

                            if (self.input[self.cursor] != ']') {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;

                            const pop = self.stack.pop();
                            if (pop == null or pop.? != .key) {
                                return error.SyntaxError;
                            }

                            if (try self.skipWsCrLnCheckEnd()) {
                                return .end_of_document;
                            }

                            self.state = .table;
                            return .table_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .inline_table => {
                    switch (try self.skipWsExpectByte()) {
                        '-', '_', '0'...'9', 'A'...'Z', 'a'...'z' => {
                            try self.stack.append(.value);
                            self.value_start = self.cursor;
                            self.state = .key_bare;
                            return .key_begin;
                        },
                        '"' => {
                            try self.stack.append(.value);
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_string;
                            return .key_begin;
                        },
                        '\'' => {
                            try self.stack.append(.value);
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .key_literal_string;
                            return .key_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .value => {
                    switch (try self.skipWsExpectByte()) {
                        // TODO:
                        '"' => {
                            self.cursor += 1;

                            if (self.cursor >= self.input.len) {
                                return error.UnexpectedEndOfInput;
                            }

                            // Look ahead if this is a multiline string.
                            if (self.cursor + 2 < self.input.len and mem.eql(u8, self.input[self.cursor .. self.cursor + 2], "\"\"")) {
                                self.cursor += 2;

                                // Newline immediately following the quotes is
                                // trimmed.
                                if (self.input[self.cursor] == '\r') {
                                    self.cursor += 1;
                                }

                                if (self.cursor >= self.input.len) {
                                    return error.UnexpectedEndOfInput;
                                }

                                if (self.input[self.cursor] == '\n') {
                                    self.cursor += 1;
                                }

                                self.state = .multiline_string;
                            } else {
                                self.state = .string;
                            }

                            self.value_start = self.cursor;
                            continue;
                        },
                        '\'' => {
                            self.cursor += 1;

                            if (self.cursor >= self.input.len) {
                                return error.UnexpectedEndOfInput;
                            }

                            if (self.cursor + 2 < self.input.len and mem.eql(u8, self.input[self.cursor .. self.cursor + 2], "''")) {
                                self.cursor += 2;

                                if (self.input[self.cursor] == '\r') {
                                    self.cursor += 1;
                                }

                                if (self.cursor >= self.input.len) {
                                    return error.UnexpectedEndOfInput;
                                }

                                if (self.input[self.cursor] == '\n') {
                                    self.cursor += 1;
                                }

                                self.state = .multiline_literal_string;
                            } else {
                                self.state = .literal_string;
                            }

                            self.value_start = self.cursor;
                            continue;
                        },
                        '0'...'9', '+', '-' => {
                            self.value_start = self.cursor;

                            if (self.cursor + 3 < self.input.len) {
                                const inf_nan = mem.eql(
                                    u8,
                                    self.input[self.cursor + 1 .. self.cursor + 4],
                                    "inf",
                                ) or mem.eql(
                                    u8,
                                    self.input[self.cursor + 1 .. self.cursor + 4],
                                    "inf",
                                );
                                if (inf_nan) {
                                    self.cursor += 4;
                                    const slice = self.takeValueSlice();
                                    self.state = .post_value;
                                    return .{ .float = slice };
                                }
                            }

                            self.state = .number;
                            continue :state_loop;
                        },
                        'i', 'n' => {
                            self.value_start = self.cursor;
                            self.cursor += 3;
                            if (self.cursor >= self.input.len) {
                                return error.UnexpectedEndOfInput;
                            }

                            const slice = self.takeValueSlice();
                            if (!mem.eql(u8, slice, "inf") and !mem.eql(u8, slice, "nan")) {
                                return error.SyntaxError;
                            }

                            self.state = .post_value;
                            return .{ .float = slice };
                        },
                        't' => {
                            self.cursor += 1;
                            self.state = .literal_t;
                            continue;
                        },
                        'f' => {
                            self.cursor += 1;
                            self.state = .literal_f;
                            continue;
                        },
                        '[' => {
                            try self.stack.append(.array);
                            self.cursor += 1;
                            self.skipWsCrLn();
                            return .array_begin;
                        },
                        '{' => {
                            try self.stack.append(.inline_table);
                            self.cursor += 1;
                            self.skipWs();
                            self.state = .inline_table;
                            return .inline_table_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('"' - 1), ('"' + 1)...('\\' - 1), ('\\' + 1)...0x7e => continue,
                            '"' => {
                                const result = Token{ .string = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_value;
                                return result;
                            },
                            '\\' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.state = .string_backslash;

                                if (slice.len > 0) {
                                    return Token{ .partial_string = slice };
                                }

                                continue :state_loop;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },
                .string_backslash => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        '"', '\\' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .string;
                            continue :state_loop;
                        },
                        'b' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            return Token{ .partial_string_escaped_1 = [_]u8{0x08} };
                        },
                        't' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            return Token{ .partial_string_escaped_1 = [_]u8{'\t'} };
                        },
                        'n' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            return Token{ .partial_string_escaped_1 = [_]u8{'\n'} };
                        },
                        'f' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            return Token{ .partial_string_escaped_1 = [_]u8{0x0c} };
                        },
                        'r' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            return Token{ .partial_string_escaped_1 = [_]u8{'\r'} };
                        },
                        'u' => {
                            self.cursor += 1;
                            self.state = .string_backslash_u;
                            continue :state_loop;
                        },
                        'U' => {
                            self.cursor += 1;
                            self.state = .string_backslash_upper_u;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_backslash_u => {
                    if (self.cursor + 4 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 4];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 4;
                    self.state = .string;
                    return Token{ .partial_string = buf[0..n] };
                },
                .string_backslash_upper_u => {
                    if (self.cursor + 8 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 8];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 8;
                    self.state = .string;
                    return Token{ .partial_string = buf[0..n] };
                },

                .multiline_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 11...12, 14...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('"' - 1), ('"' + 1)...('\\' - 1), ('\\' + 1)...0x7e => continue,
                            // Newlines are normalized.
                            '\r' => {
                                if (self.cursor + 1 >= self.input.len) {
                                    return error.SyntaxError;
                                }

                                // \r must be escaped if it's not part of
                                // a newline.
                                if (self.input[self.cursor + 1] != '\n') {
                                    return error.SyntaxError;
                                }

                                const slice = self.takeValueSlice();
                                self.cursor += 2;
                                self.value_start = self.cursor;
                                self.state = .multiline_string_newline;

                                if (self.diagnostics) |diag| {
                                    diag.line_number += 1;
                                    diag.line_start_cursor = self.cursor;
                                }

                                if (slice.len > 0) {
                                    return Token{ .partial_string = slice };
                                }

                                continue :state_loop;
                            },
                            '\n' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.value_start = self.cursor;
                                self.state = .multiline_string_newline;

                                if (self.diagnostics) |diag| {
                                    diag.line_number += 1;
                                    diag.line_start_cursor = self.cursor;
                                }

                                if (slice.len > 0) {
                                    return Token{ .partial_string = slice };
                                }

                                continue :state_loop;
                            },
                            '"' => {
                                var count: usize = 1;
                                while (count < 3 and self.cursor + count < self.input.len and self.input[self.cursor + count] == '"') {
                                    count += 1;
                                }

                                if (count == 3) {
                                    const result = Token{ .string = self.takeValueSlice() };
                                    self.cursor += 3;
                                    self.state = .post_value;
                                    return result;
                                }

                                if (count < 3) {
                                    continue;
                                }

                                unreachable;
                            },
                            '\\' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.state = .multiline_string_backslash;

                                if (slice.len > 0) {
                                    return Token{ .partial_string = slice };
                                }

                                continue :state_loop;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .multiline_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },
                .multiline_string_newline => {
                    self.state = .multiline_string;

                    return Token{ .partial_string = switch (native_os) {
                        .windows => "\r\n",
                        else => "\n",
                    } };
                },
                .multiline_string_backslash => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        '\r', '\n' => {
                            if (self.cursor + 1 >= self.input.len) {
                                return error.SyntaxError;
                            }

                            if (self.input[self.cursor] == '\r') {
                                if (self.input[self.cursor + 1] != '\n') {
                                    return error.SyntaxError;
                                }
                            }

                            if (try self.skipWsCrLnCheckEnd()) {
                                return error.UnexpectedEndOfInput;
                            }

                            self.value_start = self.cursor;
                            self.state = .multiline_string;
                            continue :state_loop;
                        },
                        '"', '\\' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .multiline_string;
                            continue :state_loop;
                        },
                        'b' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .multiline_string;
                            return Token{ .partial_string_escaped_1 = [_]u8{0x08} };
                        },
                        't' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .multiline_string;
                            return Token{ .partial_string_escaped_1 = [_]u8{'\t'} };
                        },
                        'n' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .multiline_string;
                            return Token{ .partial_string_escaped_1 = [_]u8{'\n'} };
                        },
                        'f' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .multiline_string;
                            return Token{ .partial_string_escaped_1 = [_]u8{0x0c} };
                        },
                        'r' => {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .multiline_string;
                            return Token{ .partial_string_escaped_1 = [_]u8{'\r'} };
                        },
                        'u' => {
                            self.cursor += 1;
                            self.state = .multiline_string_backslash_u;
                            continue :state_loop;
                        },
                        'U' => {
                            self.cursor += 1;
                            self.state = .multiline_string_backslash_upper_u;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_backslash_u => {
                    if (self.cursor + 4 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 4];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 4;
                    self.state = .multiline_string;
                    return Token{ .partial_string = buf[0..n] };
                },
                .multiline_string_backslash_upper_u => {
                    if (self.cursor + 8 >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    const s = self.input[self.cursor .. self.cursor + 8];
                    const codepoint = try fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try unicode.utf8Encode(codepoint, &buf);
                    self.cursor += 8;
                    self.state = .multiline_string;
                    return Token{ .partial_string = buf[0..n] };
                },

                .literal_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 10...0x1f, 0x7f => return error.SyntaxError,
                            '\t', 0x20...('\'' - 1), ('\'' + 1)...0x7e => continue,
                            '\'' => {
                                const result = Token{ .key = self.takeValueSlice() };
                                self.cursor += 1;
                                self.state = .post_value;
                                return result;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .literal_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },

                .multiline_literal_string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            0...8, 11...12, 14...0x1f, 0x7f => return error.SyntaxError,
                            // According to specification, everything in
                            // multiline literal string is left as-is. However,
                            // control characters other than tab are not
                            // permitted, so if a newline is \r\n, we need to
                            // validate it as a lone \r is not allowed.
                            '\r' => {
                                if (self.cursor + 1 >= self.input.len) {
                                    return error.SyntaxError;
                                }

                                if (self.input[self.cursor] != '\n') {
                                    return error.SyntaxError;
                                }

                                continue;
                            },
                            '\t', '\n', 0x20...('\'' - 1), ('\'' + 1)...0x7e => continue,
                            '\'' => {
                                var count: usize = 1;
                                while (count < 3 and self.cursor + count < self.input.len and self.input[self.cursor + count] == '\'') {
                                    count += 1;
                                }

                                if (count == 3) {
                                    const result = Token{ .string = self.takeValueSlice() };
                                    self.cursor += 3;
                                    self.state = .post_value;
                                    return result;
                                }

                                if (count < 3) {
                                    continue;
                                }

                                unreachable;
                            },

                            // UTF-8 validation.
                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_a;
                                continue :state_loop;
                            },
                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_b;
                                continue :state_loop;
                            },
                            0xE0 => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_c;
                                continue :state_loop;
                            },
                            0xED => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_d;
                                continue :state_loop;
                            },
                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_e;
                                continue :state_loop;
                            },
                            0xF0 => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_f;
                                continue :state_loop;
                            },
                            0xF4 => {
                                self.cursor += 1;
                                self.state = .multiline_literal_string_utf8_state_g;
                                continue :state_loop;
                            },
                            0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        }
                    }
                },

                // Just simple parsing for the number tokens. The parser
                // receiving the token should be responsible for checking if
                // the value is valid.
                .number => {
                    var mode: enum {
                        none,
                        int,
                        float,
                        datetime,
                    } = .none;
                    var sign = false;

                    if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') {
                        sign = true;

                        self.cursor += 1;
                        if (self.cursor >= self.input.len) {
                            return error.UnexpectedEndOfInput;
                        }

                        switch (self.input[self.cursor]) {
                            'i' => {
                                if (self.cursor + 2 >= self.input.len) {
                                    return error.UnexpectedEndOfInput;
                                }

                                if (!mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "inf")) {
                                    return error.SyntaxError;
                                }

                                self.cursor += 3;
                                self.state = .post_value;
                                return Token{ .float = self.takeValueSlice() };
                            },
                            'n' => {
                                if (self.cursor + 2 >= self.input.len) {
                                    return error.UnexpectedEndOfInput;
                                }

                                if (!mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "nan")) {
                                    return error.SyntaxError;
                                }

                                self.cursor += 3;
                                self.state = .post_value;
                                return Token{ .float = self.takeValueSlice() };
                            },
                            else => {},
                        }
                    }

                    var leading_zero = false;
                    if (self.input[self.cursor] == '0') {
                        leading_zero = true;
                        self.cursor += 1;

                        if (self.input[self.cursor] == ' ') {
                            self.state = .post_value;
                            return Token{ .int = self.takeValueSlice() };
                        }

                        if (self.input[self.cursor] == '\r') {
                            self.state = .post_value;
                            const slice = self.takeValueSlice();
                            self.cursor += 1;

                            if (self.cursor >= self.input.len) {
                                return error.SyntaxError;
                            }

                            if (self.cursor != '\n') {
                                return error.SyntaxError;
                            }

                            return Token{ .int = slice };
                        }

                        if (self.input[self.cursor] == '\n') {
                            self.state = .post_value;
                            return Token{ .int = self.takeValueSlice() };
                        }

                        if (self.cursor >= self.input.len) {
                            return error.UnexpectedEndOfInput;
                        }

                        const c = self.input[self.cursor];
                        if (c == 'x' or c == 'o' or c == 'b') {
                            if (sign) {
                                return error.SyntaxError;
                            }
                            leading_zero = false;
                            mode = .int;
                            self.cursor += 1;
                        } else if (c == '.') {
                            leading_zero = false;
                            mode = .float;
                            self.cursor += 1;
                        }
                    }

                    var exp = false;
                    var delim_space = false;

                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '_' => switch (mode) {
                                .none, .int, .float => continue,
                                // This catches some syntax errors but
                                // ultimately the parser must recognize invalid
                                // datetimes.
                                .datetime => return error.SyntaxError,
                            },
                            '0'...'9' => continue,
                            'a'...'d', 'A'...'D', 'f', 'F' => switch (mode) {
                                // Mode is set to int only if there is a base
                                // prefix.
                                .int => continue,
                                else => return error.SyntaxError,
                            },
                            '.' => switch (mode) {
                                .none => mode = .float,
                                .int => return error.SyntaxError,
                                .float => return error.SyntaxError, // second dot
                                .datetime => continue,
                            },
                            'e', 'E' => switch (mode) {
                                .none => {
                                    mode = .float;
                                    exp = true;
                                },
                                .int => continue,
                                .float => {
                                    if (exp) {
                                        return error.SyntaxError;
                                    }

                                    exp = true;
                                    continue;
                                },
                                .datetime => return error.SyntaxError,
                            },
                            '-' => switch (mode) {
                                .none => mode = .datetime,
                                .int => return error.SyntaxError,
                                .float => {
                                    if (!exp) {
                                        return error.SyntaxError;
                                    }

                                    continue;
                                },
                                .datetime => continue,
                            },
                            '+' => switch (mode) {
                                .none => mode = .datetime,
                                .int => return error.SyntaxError,
                                .float => {
                                    if (!exp) {
                                        return error.SyntaxError;
                                    }

                                    continue;
                                },
                                .datetime => continue,
                            },
                            ':' => switch (mode) {
                                .none => mode = .datetime,
                                .datetime => continue,
                                else => return error.SyntaxError,
                            },
                            ' ' => switch (mode) {
                                .datetime => {
                                    if (delim_space) {
                                        break;
                                    }

                                    delim_space = true;
                                    continue;
                                },
                                else => break,
                            },
                            'T', 'Z' => switch (mode) {
                                .datetime => continue,
                                else => return error.SyntaxError,
                            },
                            '\r' => {
                                if (self.cursor + 1 >= self.input.len) {
                                    return error.SyntaxError;
                                }

                                if (self.input[self.cursor] != '\n') {
                                    return error.SyntaxError;
                                }

                                break;
                            },
                            '\n' => break,
                            // Numbers may end in commas inside arrays and
                            // inline tables.
                            ',' => {
                                if (self.stackHeight() < 2) {
                                    return error.SyntaxError;
                                }

                                if (self.peekStack().? != .array and self.peekStack().? != .inline_table) {
                                    if (self.peekStack().? == .value) {
                                        if (self.stack.items[self.stackHeight() - 2] != .inline_table) {
                                            return error.SyntaxError;
                                        }
                                    } else {
                                        return error.SyntaxError;
                                    }
                                }

                                break;
                            },
                            ']' => {
                                if (self.stackHeight() < 2) {
                                    return error.SyntaxError;
                                }

                                if (self.peekStack().? != .array) {
                                    return error.SyntaxError;
                                }

                                break;
                            },
                            '}' => {
                                if (self.stackHeight() < 2) {
                                    return error.SyntaxError;
                                }

                                if (self.peekStack().? != .inline_table) {
                                    return error.SyntaxError;
                                }

                                break;
                            },
                            else => return error.SyntaxError,
                        }
                    }

                    const slice = self.takeValueSlice();
                    self.state = .post_value;

                    return blk: switch (mode) {
                        .none, .int => {
                            if (leading_zero) {
                                break :blk error.SyntaxError;
                            }
                            break :blk Token{ .int = slice };
                        },
                        .float => {
                            if (leading_zero) {
                                break :blk error.SyntaxError;
                            }
                            break :blk Token{ .float = slice };
                        },
                        .datetime => Token{ .datetime = slice },
                    };
                },

                .literal_t => {
                    switch (try self.expectByte()) {
                        'r' => {
                            self.cursor += 1;
                            self.state = .literal_tr;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_tr => {
                    switch (try self.expectByte()) {
                        'u' => {
                            self.cursor += 1;
                            self.state = .literal_tru;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_tru => {
                    switch (try self.expectByte()) {
                        'e' => {
                            self.cursor += 1;
                            self.state = .post_value;
                            return .true;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_f => {
                    switch (try self.expectByte()) {
                        'a' => {
                            self.cursor += 1;
                            self.state = .literal_fa;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_fa => {
                    switch (try self.expectByte()) {
                        'l' => {
                            self.cursor += 1;
                            self.state = .literal_fal;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_fal => {
                    switch (try self.expectByte()) {
                        's' => {
                            self.cursor += 1;
                            self.state = .literal_fals;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_fals => {
                    switch (try self.expectByte()) {
                        'e' => {
                            self.cursor += 1;
                            self.state = .post_value;
                            return .false;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .post_value => {
                    switch (try self.skipWsCrExpectByte()) {
                        '#' => {
                            // There is no way to have a comment after a value
                            // in an inline table as that would require
                            // splitting it to multiple lines.
                            if (self.stackHeight() > 1 and self.peekStack().? == .inline_table) {
                                return error.SyntaxError;
                            }

                            try self.skipComment();
                            continue :state_loop;
                        },
                        '\n' => {
                            // Newline is only permitted after values in normal
                            // tables.
                            if (self.stackHeight() < 1) {
                                return error.SyntaxError;
                            }

                            if (self.peekStack().? == .inline_table) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;

                            if (self.diagnostics) |diag| {
                                diag.line_number += 1;
                                diag.line_start_cursor = self.cursor;
                            }

                            if (self.peekStack().? == .array) {
                                try self.stack.append(.line_feed);
                                continue;
                            }

                            const last = self.stack.pop().?;
                            if (last == .comma) {
                                continue;
                            }

                            if (last != .value) {
                                return error.SyntaxError;
                            }

                            self.state = .table;
                            continue;
                        },
                        ',' => {
                            if (self.stackHeight() < 2) {
                                return error.SyntaxError;
                            }

                            var last = self.peekStack().?;
                            if (last == .value) {
                                _ = self.stack.pop();
                                last = self.peekStack().?;
                                if (last != .inline_table) {
                                    return error.SyntaxError;
                                }
                            } else if (last != .array) {
                                return error.SyntaxError;
                            }

                            try self.stack.append(.comma);

                            self.cursor += 1;
                            continue;
                        },
                        ']' => {
                            if (self.stackHeight() < 2) {
                                return error.SyntaxError;
                            }

                            var last = self.stack.pop().?;
                            if (last != .array) {
                                if (last != .comma and last != .line_feed) {
                                    return error.SyntaxError;
                                }
                                last = self.stack.pop().?;
                            }
                            if (last != .array) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;
                            // self.state = .table;

                            // if (self.stackHeight() > 1) {
                            //     last = self.peekStack().?;
                            //     if (last == .array) {
                            //         self.state = .post_value;
                            //     }
                            // }

                            return .array_end;
                        },
                        '}' => {
                            if (self.stackHeight() < 3) {
                                return error.SyntaxError;
                            }

                            var last = self.stack.pop().?;
                            if (last == .comma) {
                                return error.SyntaxError;
                            }
                            if (last != .value) {
                                return error.SyntaxError;
                            }

                            last = self.stack.pop().?;
                            if (last != .inline_table) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;

                            return .inline_table_end;
                        },
                        else => {
                            if (try self.checkEnd()) {
                                return .end_of_document;
                            }

                            var last = self.peekStack() orelse {
                                return error.SyntaxError;
                            };
                            switch (last) {
                                .array => {
                                    self.state = .value;
                                    continue :state_loop;
                                },
                                .inline_table => {
                                    self.state = .inline_table;
                                    continue :state_loop;
                                },
                                .comma => {
                                    _ = self.stack.pop();
                                    last = self.peekStack() orelse {
                                        return error.SyntaxError;
                                    };

                                    switch (last) {
                                        .array => {
                                            self.state = .value;
                                            continue :state_loop;
                                        },
                                        .inline_table => {
                                            self.state = .inline_table;
                                            continue :state_loop;
                                        },
                                        else => return error.SyntaxError,
                                    }
                                },
                                .line_feed => {
                                    _ = self.stack.pop();
                                    last = self.peekStack() orelse {
                                        return error.SyntaxError;
                                    };
                                    if (last != .array) {
                                        return error.SyntaxError;
                                    }

                                    self.state = .value;
                                    continue :state_loop;
                                },
                                else => return error.SyntaxError,
                            }
                        },
                    }
                },

                // UTF-8 validation states.
                .key_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .key_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Literal string key UTF-8 validation.
                .key_literal_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .key_literal_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_literal_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_literal_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_literal_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_literal_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_literal_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .key_literal_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Table string key validation.
                .table_key_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .table_key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .table_key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Table literal string key UTF-8 validation.
                .table_key_literal_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_literal_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_literal_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_literal_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_literal_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_literal_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .table_key_literal_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .table_key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Array of tables string key validation.
                .array_table_key_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .array_table_key_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Table literal string key UTF-8 validation.
                .array_table_key_literal_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_literal_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_literal_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_literal_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_literal_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_literal_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .array_table_key_literal_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .array_table_key_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // String value UTF-8 validation.
                .string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Multiline string value UTF-8 validation.
                .multiline_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .multiline_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .multiline_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Literal string value UTF-8 validation.
                .literal_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .literal_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .literal_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                // Multiline literal string value UTF-8 validation.
                .multiline_literal_string_utf8_state_a => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_literal_string_utf8_state_b => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_literal_string_utf8_state_c => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_literal_string_utf8_state_d => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string_utf8_state_a;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_literal_string_utf8_state_e => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_literal_string_utf8_state_f => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .multiline_literal_string_utf8_state_g => {
                    if (self.cursor >= self.input.len) {
                        return self.endOfBufferInKeyString();
                    }

                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .multiline_literal_string_utf8_state_b;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
            }
        }

        unreachable;
    }

    /// Seeks ahead to until the first byte of the next token or end of the
    /// input and determines which kind of token comes next.
    pub fn peekNextTokenType(self: *@This()) PeekError!TokenType {
        const old_cursor = self.cursor;
        defer self.cursor = old_cursor; // TODO: Stupid hack.

        while (true) {
            switch (self.state) {
                .table => return try self.peekTableToken(),

                .key_bare,
                .key_string,
                .key_literal_string,
                .table_key_bare,
                .table_key_string,
                .table_key_literal_string,
                .array_table_key_bare,
                .array_table_key_string,
                .array_table_key_literal_string,
                .key_string_backslash,
                .key_string_backslash_u,
                .key_string_backslash_upper_u,
                .table_key_string_backslash,
                .table_key_string_backslash_u,
                .table_key_string_backslash_upper_u,
                .array_table_key_string_backslash,
                .array_table_key_string_backslash_u,
                .array_table_key_string_backslash_upper_u,
                => return .key,

                .post_key => {
                    switch (try self.skipWsExpectByte()) {
                        '.' => {
                            switch (try self.skipWsExpectByte()) {
                                '-',
                                '_',
                                '0'...'9',
                                'A'...'Z',
                                'a'...'z',
                                '"',
                                '\'',
                                => return .key_begin,
                                else => return error.SyntaxError,
                            }
                        },
                        '=' => {
                            if (try self.skipWsCheckEnd()) {
                                return error.UnexpectedEndOfInput;
                            }
                            return .value_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .post_table_key => {
                    switch (try self.skipWsExpectByte()) {
                        '.' => {
                            self.cursor += 1;
                            switch (try self.skipWsExpectByte()) {
                                '-',
                                '_',
                                '0'...'9',
                                'A'...'Z',
                                'a'...'z',
                                '"',
                                '\'',
                                => {
                                    return .table_key_begin;
                                },
                                else => return error.SyntaxError,
                            }
                        },
                        ']' => {
                            self.cursor += 1;

                            if (try self.skipWsCrLnCheckEnd()) {
                                return .end_of_document;
                            }

                            return .table_begin;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .post_array_table_key => unreachable,

                .inline_table => return .key_begin,
                .value => return try self.peekValueToken(),

                .post_value => {
                    switch (try self.skipWsCrExpectByte()) {
                        '#' => {
                            if (self.stackHeight() > 1 and self.peekStack().? == .inline_table) {
                                return error.SyntaxError;
                            }
                            try self.skipComment();
                            continue;
                        },
                        '\n' => {
                            if (self.stackHeight() < 1) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;

                            if (self.diagnostics) |diag| {
                                diag.line_number += 1;
                                diag.line_start_cursor = self.cursor;
                            }

                            const last = self.stack.items[self.stack.items.len - 1];
                            if (last == .inline_table) {
                                return error.SyntaxError;
                            }
                            if (last == .array) {
                                continue;
                            }

                            return self.peekTableToken();
                        },
                        ',' => {
                            if (self.stackHeight() < 2) {
                                return error.SyntaxError;
                            }

                            // TODO: Inline table.
                            const last = self.stack.items[self.stack.items.len - 1];
                            if (last != .array and last != .inline_table) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;
                            continue;
                        },
                        ']' => {
                            if (self.stackHeight() < 2) {
                                return error.SyntaxError;
                            }

                            const last = self.stack.items[self.stack.items.len - 1];
                            if (last != .array) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;
                            return .array_end;
                        },
                        '}' => {
                            if (self.stackHeight() < 2) {
                                return error.SyntaxError;
                            }

                            const last = self.stack.items[self.stack.items.len - 1];
                            if (last != .inline_table) {
                                return error.SyntaxError;
                            }

                            self.cursor += 1;
                            return .inline_table_end;
                        },
                        // TODO: Rest of the terminators.
                        else => {
                            if (try self.checkEnd()) {
                                return .end_of_document;
                            }

                            const last = self.stack.items[self.stack.items.len - 1];
                            if (last == .array) {
                                return try self.peekValueToken();
                            }

                            return error.SyntaxError;
                        },
                    }
                },

                else => unreachable,
            }
            unreachable;
        }
    }

    fn peekTableToken(self: *@This()) PeekError!TokenType {
        switch (try self.skipWsCrLnExpectByte()) {
            '#' => {
                try self.skipComment();
                return try self.peekTableToken();
            },
            '[' => {
                self.cursor += 1;
                if (self.cursor >= self.input.len) {
                    return error.UnexpectedEndOfInput;
                }

                if (self.input[self.cursor] == '[') {
                    return switch (try self.skipWsExpectByte()) {
                        '-',
                        '_',
                        '0'...'9',
                        'A'...'Z',
                        'a'...'z',
                        '"',
                        '\'',
                        => .array_table_key_begin,
                        else => error.SyntaxError,
                    };
                }

                return switch (try self.skipWsExpectByte()) {
                    '-',
                    '_',
                    '0'...'9',
                    'A'...'Z',
                    'a'...'z',
                    '"',
                    '\'',
                    => .table_key_begin,
                    else => error.SyntaxError,
                };
            },
            '-', '_', '0'...'9', 'A'...'Z', 'a'...'z', '"', '\'' => return .key_begin,
            else => return error.SyntaxError,
        }
    }

    fn peekValueToken(self: *@This()) !TokenType {
        switch (try self.skipWsExpectByte()) {
            '"', '\'' => return .string,
            '0'...'9', '+', '-' => {
                var sign = false;

                if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') {
                    sign = true;

                    self.cursor += 1;
                    if (self.cursor >= self.input.len) {
                        return error.UnexpectedEndOfInput;
                    }
                }

                if (self.input[self.cursor] == '0') {
                    self.cursor += 1;

                    if (self.input[self.cursor] == ' ') {
                        return .int;
                    }

                    if (self.input[self.cursor] == '\r') {
                        self.cursor += 1;

                        if (self.cursor >= self.input.len) {
                            return error.SyntaxError;
                        }

                        if (self.cursor != '\n') {
                            return error.SyntaxError;
                        }

                        return .int;
                    }

                    if (self.input[self.cursor] == '\n') {
                        return .int;
                    }

                    if (self.cursor >= self.input.len) {
                        return error.UnexpectedEndOfInput;
                    }

                    const c = self.input[self.cursor];
                    if (c == 'x' or c == 'o' or c == 'b') {
                        if (sign) {
                            return error.SyntaxError;
                        }
                        return .int;
                    } else if (c == '.') {
                        return .float;
                    }
                }

                while (self.cursor < self.input.len) : (self.cursor += 1) {
                    switch (self.input[self.cursor]) {
                        'i', 'n' => return .float,
                        '_', '0'...'9' => continue,
                        // Dot before a dash constitutes float.
                        '.' => return .float,
                        // Exponent contitutes float.
                        'e', 'E' => return .float,
                        // Datetime dash would always come before
                        // an exponent dash in floats.
                        '-' => return .datetime,
                        ':' => return .datetime,
                        // Everything else would have been caught by
                        // now so breaking space is reasonable.
                        ' ' => break,
                        '\r' => {
                            if (self.cursor + 1 >= self.input.len) {
                                return error.SyntaxError;
                            }

                            if (self.input[self.cursor] != '\n') {
                                return error.SyntaxError;
                            }

                            break;
                        },
                        '\n', ',', ']' => break,
                        else => return error.SyntaxError,
                    }
                }

                return .int;
            },
            'i', 'n' => return .float,
            't' => return .true,
            'f' => return .false,
            '[' => return .array_begin,
            '{' => return .inline_table_begin,
            else => return error.SyntaxError,
        }
    }

    fn checkEnd(self: *@This()) !bool {
        if (self.cursor >= self.input.len) {
            // End of buffer.
            if (self.is_end_of_input) {
                // End of everything.
                if (self.stackHeight() == 0) {
                    // We did it!
                    return true;
                }

                return error.UnexpectedEndOfInput;
            }

            return error.BufferUnderrun;
        }

        // if (self.stackHeight() == 0) {
        //     return error.SyntaxError;
        // }

        return false;
    }

    fn expectByte(self: *const @This()) !u8 {
        if (self.cursor < self.input.len) {
            return self.input[self.cursor];
        }

        // No byte.
        if (self.is_end_of_input) {
            return error.UnexpectedEndOfInput;
        }

        return error.BufferUnderrun;
    }

    fn skipComment(self: *@This()) !void {
        assert(self.cursor < self.input.len);

        if (self.input[self.cursor] != '#') {
            return;
        }

        self.cursor += 1;

        // Comments must be valid UTF-8.
        const CommentState = enum { start, a, b, c, d, e, f, g };
        var current_state: CommentState = .start;

        while (self.cursor < self.input.len) : (self.cursor += 1) {
            switch (current_state) {
                .start => {
                    switch (self.input[self.cursor]) {
                        '\n' => {
                            if (self.diagnostics) |diag| {
                                diag.line_number += 1;
                                diag.line_start_cursor = self.cursor;
                            }

                            return;
                        },
                        0...8, 0x0B...0x1F, 0x7F => return error.SyntaxError, // disallowed control characters
                        0x20...0x7e => continue, // ASCII

                        // UTF-8 validation.
                        0xC2...0xDF => {
                            current_state = .a;
                            continue;
                        },
                        0xE1...0xEC, 0xEE...0xEF => {
                            current_state = .b;
                            continue;
                        },
                        0xE0 => {
                            current_state = .c;
                            continue;
                        },
                        0xED => {
                            current_state = .d;
                            continue;
                        },
                        0xF1...0xF3 => {
                            current_state = .e;
                            continue;
                        },
                        0xF0 => {
                            current_state = .f;
                            continue;
                        },
                        0xF4 => {
                            current_state = .g;
                            continue;
                        },
                        0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return error.SyntaxError,
                        else => continue,
                    }
                },
                .a => {
                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            current_state = .start;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .b => {
                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            current_state = .a;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .c => {
                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            current_state = .a;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .d => {
                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            current_state = .a;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .e => {
                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            current_state = .b;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .f => {
                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            current_state = .b;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .g => {
                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            current_state = .b;
                            continue;
                        },
                        else => return error.SyntaxError,
                    }
                },
            }
        }
    }

    fn skipWs(self: *@This()) void {
        while (self.cursor < self.input.len) : (self.cursor += 1) {
            switch (self.input[self.cursor]) {
                ' ', '\t' => continue,
                else => return,
            }
        }
    }

    fn skipWsCr(self: *@This()) void {
        while (self.cursor < self.input.len) : (self.cursor += 1) {
            switch (self.input[self.cursor]) {
                ' ', '\t', '\r' => continue,
                else => return,
            }
        }
    }

    fn skipWsCrLn(self: *@This()) void {
        while (self.cursor < self.input.len) : (self.cursor += 1) {
            switch (self.input[self.cursor]) {
                ' ', '\t', '\r' => continue,
                '\n' => {
                    if (self.diagnostics) |diag| {
                        diag.line_number += 1;
                        // This will count the newline itself, which means
                        // a straight-forward subtraction will give a 1-based
                        // column number.
                        diag.line_start_cursor = self.cursor;
                    }
                    continue;
                },
                else => return,
            }
        }
    }

    fn skipWsExpectByte(self: *@This()) !u8 {
        self.skipWs();
        return self.expectByte();
    }

    fn skipWsCheckEnd(self: *@This()) !bool {
        self.skipWs();
        return self.checkEnd();
    }

    fn skipWsCrLnCheckEnd(self: *@This()) !bool {
        self.skipWsCrLn();
        return self.checkEnd();
    }

    fn skipWsCrExpectByte(self: *@This()) !u8 {
        self.skipWsCr();
        return self.expectByte();
    }

    fn skipWsCrLnExpectByte(self: *@This()) !u8 {
        self.skipWsCrLn();
        return self.expectByte();
    }

    fn takeValueSlice(self: *@This()) []const u8 {
        const slice = self.input[self.value_start..self.cursor];
        self.value_start = self.cursor;
        return slice;
    }

    fn takeValueSliceMinusTrailingOffset(self: *@This(), trailing_negative_offset: usize) []const u8 {
        // Check if the escape sequence started before the current input buffer.
        // (The algebra here is awkward to avoid unsigned underflow, but it's
        // just making sure the slice on the next line isn't UB.)
        if (self.cursor <= self.value_start + trailing_negative_offset) return "";
        const slice = self.input[self.value_start .. self.cursor - trailing_negative_offset];
        // When trailing_negative_offset is non-zero, setting self.value_start
        // doesn't matter, because we always set it again while emitting the
        // .partial_string_escaped_*.
        self.value_start = self.cursor;
        return slice;
    }

    fn endOfBufferInKeyString(self: *@This()) !Token {
        if (self.is_end_of_input) {
            return error.UnexpectedEndOfInput;
        }

        const slice = self.takeValueSliceMinusTrailingOffset(switch (self.state) {
            // Incomplete escape sequence is a syntax error.
            .key_string_backslash,
            .key_string_backslash_u,
            .key_string_backslash_upper_u,
            .table_key_string_backslash,
            .table_key_string_backslash_u,
            .table_key_string_backslash_upper_u,
            .array_table_key_string_backslash,
            .array_table_key_string_backslash_u,
            .array_table_key_string_backslash_upper_u,
            => return error.SyntaxError,

            // Include everything up to the cursor otherwise.
            .key_string,
            .key_string_utf8_state_a,
            .key_string_utf8_state_b,
            .key_string_utf8_state_c,
            .key_string_utf8_state_d,
            .key_string_utf8_state_f,
            .key_string_utf8_state_g,
            .key_literal_string,
            .key_literal_string_utf8_state_a,
            .key_literal_string_utf8_state_b,
            .key_literal_string_utf8_state_c,
            .key_literal_string_utf8_state_d,
            .key_literal_string_utf8_state_f,
            .key_literal_string_utf8_state_g,
            .table_key_string,
            .table_key_string_utf8_state_a,
            .table_key_string_utf8_state_b,
            .table_key_string_utf8_state_c,
            .table_key_string_utf8_state_d,
            .table_key_string_utf8_state_f,
            .table_key_string_utf8_state_g,
            .table_key_literal_string,
            .table_key_literal_string_utf8_state_a,
            .table_key_literal_string_utf8_state_b,
            .table_key_literal_string_utf8_state_c,
            .table_key_literal_string_utf8_state_d,
            .table_key_literal_string_utf8_state_f,
            .table_key_literal_string_utf8_state_g,
            .array_table_key_string,
            .array_table_key_string_utf8_state_a,
            .array_table_key_string_utf8_state_b,
            .array_table_key_string_utf8_state_c,
            .array_table_key_string_utf8_state_d,
            .array_table_key_string_utf8_state_f,
            .array_table_key_string_utf8_state_g,
            .array_table_key_literal_string,
            .array_table_key_literal_string_utf8_state_a,
            .array_table_key_literal_string_utf8_state_b,
            .array_table_key_literal_string_utf8_state_c,
            .array_table_key_literal_string_utf8_state_d,
            .array_table_key_literal_string_utf8_state_f,
            .array_table_key_literal_string_utf8_state_g,
            => 0,

            else => unreachable,
        });
        if (slice.len == 0) {
            return error.BufferUnderrun;
        }
        return Token{ .partial_key = slice };
    }
};

fn appendSlice(list: *ArrayList(u8), buf: []const u8, max_value_len: usize) !void {
    const new_len = math.add(usize, list.items.len, buf.len) catch return error.ValueTooLong;

    if (new_len > max_value_len) {
        return error.ValueTooLong;
    }

    try list.appendSlice(buf);
}
