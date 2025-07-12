//! Path manipulation utilities.
//!
//! TODO: Think of better name for this.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

/// Expand environment variables in the given string. On Windows, Windows-style environment
/// variables are supported (`%VARIABLE%`) in addition to Unix-style variables (`${VARIABLE}` and
/// `$VARIABLE`). On other platforms, only Unix-style variables are supported.
///
/// Caller owns the result and should call `free` on it.
pub fn expandEnv(allocator: Allocator, s: []const u8, env_map: std.process.EnvMap) ![]const u8 {
    var out: []const u8 = s;
    var buf: [1024]u8 = undefined; // TODO: Is this enough?

    // The buffer goes out of scope, so no need to free the temporary allocations.
    var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
    const buf_allocator = fba.allocator();

    if (builtin.os.tag == .windows) {
        if (std.mem.count(u8, out, "%") >= 2) {
            const tmp = try expandWindowsEnv(buf_allocator, out, env_map);
            out = tmp;

            const unix = try expandEnvUnix(buf_allocator, out, env_map);
            out = unix;

            return try allocator.dupe(u8, out);
        }
    }

    const unix = try expandEnvUnix(buf_allocator, out, env_map);
    out = unix;

    return try allocator.dupe(u8, out);
}

fn expandEnvUnix(allocator: Allocator, s: []const u8, env_map: std.process.EnvMap) ![]const u8 {
    var buf: [512]u8 = undefined; // TODO: Is this enough?

    var l: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (j < s.len) : (j += 1) {
        if (s[j] == '$' and j + 1 < s.len) {
            // Add bytes up to '$'.
            for (s[i..j]) |c| {
                buf[l] = c;
                l += 1;
            }

            const t = s[j + 1 ..];
            const name, const w = blk: {
                if (t[0] == '{') {
                    if (t.len > 2 and isSpecialVar(t[1]) and t[2] == '}') {
                        break :blk .{ t[1..2], 3 };
                    }

                    var k: usize = 1;
                    while (k < t.len) : (k += 1) {
                        if (t[k] == '}') {
                            if (k == 1) {
                                break :blk .{ "", 2 };
                            }

                            break :blk .{ t[1..k], k + 1 };
                        }
                    }

                    break :blk .{ "", 1 };
                }

                if (isSpecialVar(t[0])) {
                    break :blk .{ t[0..1], 1 };
                }

                var k: usize = 0;
                while (k < t.len and isAlphaNum(t[k])) : (k += 1) {}

                break :blk .{ t[0..k], k };
            };

            if (std.mem.eql(u8, name, "") and w > 0) {
                // Invalid syntax, eat the characters.
            } else if (std.mem.eql(u8, name, "")) {
                // `$` is not followed by a name, so leave it in.
                buf[l] = s[j];
                l += 1;
            } else {
                // TODO: Right now, variables that do not exist are replaced with empty strings. Is
                // this what we want?
                const val = env_map.get(name) orelse "";
                for (val) |c| {
                    buf[l] = c;
                    l += 1;
                }
            }

            j += w;
            i = j + 1;
        }
    }

    if (l == 0) {
        return s;
    }

    return try std.mem.concat(allocator, u8, &[_][]const u8{ buf[0..l], s[i..] });
}

fn expandWindowsEnv(allocator: Allocator, s: []const u8, env_map: std.process.EnvMap) ![]const u8 {
    assert(builtin.os.tag == .windows);

    var buf: [512]u8 = undefined; // TODO: Is this enough?

    var l: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (j < s.len) : (j += 1) {
        if (s[j] == '%' and j + 1 < s.len) {
            // Add bytes up to '%'.
            for (s[i..j]) |c| {
                buf[l] = c;
                l += 1;
            }

            var k: usize = j + 1;
            while (k < s.len and isAlphaNum(s[k])) : (k += 1) {}

            if (k == j + 1) {
                // Because stand-alone '%' is not allowed, we do a quick check if there is a '%'
                // later in the string. That means that the variable name is invalid.
                if (k < s.len - 1) {
                    const percent = std.mem.indexOf(u8, s[k..], "%");
                    if (percent) |p| {
                        if (p == k) {
                            // On Windows, '%%' prints '%'.
                            buf[l] = '%';
                            l += 1;
                        } else {
                            return error.InvalidVar;
                        }
                    }
                }

                // If there is no more %s in the code, the byte is left as is.
                buf[l] = '%';
                l += 1;
            } else if (s[k] == '%') {
                const key = s[j + 1 .. k];
                // TODO: Right now, variables that do not exist are replaced with empty strings. Is
                // this what we want?
                const val = env_map.get(key) orelse "";
                for (val) |c| {
                    buf[l] = c;
                    l += 1;
                }
            } else {
                // Because stand-alone '%' is not allowed, we do a quick check if there is a '%'
                // later in the string. That means that the variable name is invalid.
                if (k < s.len - 1) {
                    for (s[k..]) |c| {
                        if (c == '%') {
                            return error.InvalidVar;
                        }
                    }
                }

                for (s[j .. k + 1]) |c| {
                    buf[l] = c;
                    l += 1;
                }
            }

            j = k + 1;
            i = j;
        }
    }

    if (l == 0) {
        return s;
    }

    return try std.mem.concat(allocator, u8, &[_][]const u8{ buf[0..l], s[i..] });
}

fn isAlphaNum(c: u8) bool {
    return c == '_' or ('0' <= c and c <= '9') or ('a' <= c and c <= 'z') or ('A' <= c and c <= 'Z');
}

fn isSpecialVar(c: u8) bool {
    switch (c) {
        '*', '#', '$', '@', '!', '?', '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
            return true;
        },
        else => return false,
    }
}

test expandEnv {
    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("SOMETHING", "hello");

        const path = "/tmp";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("SOMETHING", "hello");

        const path = "/tmp/$SOMETHING";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/hello", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("SOMETHING", "hello");

        const path = "/tmp/$SOMETHING/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/hello/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("SOMETHING", "hello");

        const path = "/tmp/${SOMETHING}";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/hello", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("SOMETHING", "hello");

        const path = "/tmp/${SOMETHING}/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/hello/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("SOMETHING", "hello");

        const path = "/tmp/$SOMETHIN/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp//something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("$", "PID");

        const path = "/tmp/$$/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/PID/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("1", "ARG1");

        const path = "/tmp/$1/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/ARG1/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("1", "ARG1");

        const path = "/tmp/${1}/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/ARG1/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("*", "all args");

        const path = "/tmp/$*/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/all args/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("*", "all args");

        const path = "/tmp/${*}/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/tmp/all args/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("HOME", "/usr/reginald");
        try env.put("H", "(here is H)");

        const path = "${HOME}/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/usr/reginald/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("HOME", "/usr/reginald");
        try env.put("H", "(here is H)");

        const path = "${H}OME/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("(here is H)OME/something_else", actual);
    }

    {
        var env = std.process.EnvMap.init(testing.allocator);
        defer env.deinit();

        try env.put("HOME", "/usr/reginald");
        try env.put("H", "(here is H)");

        const path = "$HOME/something_else";
        const actual = try expandEnv(testing.allocator, path, env);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings("/usr/reginald/something_else", actual);
    }
}

test "expandEnv Windows" {
    if (builtin.os.tag == .windows) {
        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp/%SOMETHING%";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/hello", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp/%SOMETHING%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/hello/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp/%SoMEtHInG%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/hello/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp/%SOMETHIN%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp//something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            const path = "/tmp/%%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/%/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("$", "PID");

            const path = "/tmp/%$%/something_else";
            const actual = expandEnv(testing.allocator, path, env);
            try testing.expectError(error.InvalidVar, actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("1", "ARG1");

            const path = "/tmp/%1%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/ARG1/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("HOME", "/usr/reginald");
            try env.put("H", "(here is H)");

            const path = "%HOME%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/usr/reginald/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("HOME", "/usr/reginald");
            try env.put("H", "(here is H)");

            const path = "%H%OME/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("(here is H)OME/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp/$SOMETHING/dir/%SOMETHING%";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/hello/dir/hello", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            try env.put("SOMETHING", "hello");

            const path = "/tmp/${SOMETHING}/dir/%SOMETHING%";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/hello/dir/hello", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            const path = "/tmp/%/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/%/something_else", actual);
        }

        {
            var env = std.process.EnvMap.init(testing.allocator);
            defer env.deinit();

            const path = "/tmp/%hello&/something_else";
            const actual = try expandEnv(testing.allocator, path, env);
            defer testing.allocator.free(actual);

            try testing.expectEqualStrings("/tmp/%hello&/something_else", actual);
        }
    }
}
