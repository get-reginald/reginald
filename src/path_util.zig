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

    if (comptime builtin.target.os.tag == .windows) {
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

/// Naively expand user's home directory, given as '~', in the given string. The function only
/// expands a valid formatting of a user directory that is in the beginning of the string. If the
/// home directory is for some other user than the current user (~other), it resolves the home
/// directory based on the home directory of the current user. The current user's home directory is
/// resolved from environment variables.
///
/// Caller owns the result and should call `free` on it.
pub fn expandUser(allocator: Allocator, s: []const u8) ![]const u8 {
    var buf: [1024]u8 = undefined; // TODO: Is this enough?

    // The buffer goes out of scope, so no need to free the temporary allocations.
    var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
    const buf_allocator = fba.allocator();

    const home = if (comptime builtin.target.os.tag == .windows)
        try std.process.getEnvVarOwned(buf_allocator, "USERPROFILE")
    else
        try std.process.getEnvVarOwned(buf_allocator, "HOME");

    if (std.mem.eql(u8, s, "~")) {
        return try allocator.dupe(u8, home);
    }

    if (std.mem.startsWith(u8, s, "~")) {
        if (s[1] == std.fs.path.sep) {
            return try std.fs.path.join(allocator, &[_][]const u8{ home, s[2..] });
        } else {
            // We naively assume that all of the user home directories follow the same pattern,
            // which is almost always correct.
            const i = std.mem.indexOf(u8, s, std.fs.path.sep_str);
            const user = if (i) |j| s[1..j] else s[1..];
            // TODO: We should really be checking this.
            const users = std.fs.path.dirname(home).?;

            if (i) |j| {
                return try std.fs.path.join(allocator, &[_][]const u8{ users, user, s[j + 1 ..] });
            } else {
                return try std.fs.path.join(allocator, &[_][]const u8{ users, user });
            }
        }
    }

    return try allocator.dupe(u8, s);
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
    assert(comptime builtin.target.os.tag == .windows);

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

            // Should we allow more characters than just alphanumerics and underscores? Technically
            // Windows might allow wild characters in variable names (if I'm not wrong), so should
            // those be allowed?
            var k: usize = j + 1;
            while (k < s.len and isAlphaNum(s[k])) : (k += 1) {}

            if (s[k] == '%') {
                if (k == j + 1) {
                    // On Windows, '%%' expands to '%'.
                    buf[l] = '%';
                    l += 1;
                } else {
                    // As k stops at the first character that is not valid in a variable name, the
                    // slice should now contain a valid variable name.
                    const key = s[j + 1 .. k];
                    // TODO: Right now, variables that do not exist are replaced with empty strings.
                    // Is this what we want?
                    const val = env_map.get(key) orelse "";
                    for (val) |c| {
                        buf[l] = c;
                        l += 1;
                    }
                }
            } else {
                // We found an invalid character; we should check if there is a '%' somewhere later
                // as that would construct an invalid variable name.
                for (s[k..]) |c| {
                    if (c == '%') {
                        return error.InvalidVar;
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
    if (builtin.target.os.tag == .windows) {
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

test expandUser {
    const c = @cImport({
        @cInclude("stdlib.h");
    });

    const is_win = builtin.target.os.tag == .windows;

    if (is_win) {
        // const key = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, "HOME");
        // defer testing.allocator.free(key);
        //
        // const value = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, "C:\\Users\\reginald");
        // defer testing.allocator.free(value);

        if (std.os.windows.kernel32.SetEnvironmentVariableW("HOME", "C:\\Users\\reginald") == 0) {
            unreachable;
        }
    } else {
        if (c.setenv("HOME", "/usr/home/reginald", 1) != 0) {
            unreachable;
        }
    }

    {
        const actual = try expandUser(testing.allocator, "~");
        defer testing.allocator.free(actual);

        if (is_win) {
            try testing.expectEqualStrings("C:\\Users\\reginald", actual);
        } else {
            try testing.expectEqualStrings("/usr/home/reginald", actual);
        }
    }

    {
        if (is_win) {
            const actual = try expandUser(testing.allocator, "~\\foo");
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings("C:\\Users\\reginald\\foo", actual);
        } else {
            const actual = try expandUser(testing.allocator, "~/foo");
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings("/usr/home/reginald/foo", actual);
        }
    }

    {
        const actual = try expandUser(testing.allocator, "/foo/bar");
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings("/foo/bar", actual);
    }

    {
        const actual = try expandUser(testing.allocator, "/foo/~/bar");
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings("/foo/~/bar", actual);
    }

    {
        const actual = try expandUser(testing.allocator, "~other");
        defer testing.allocator.free(actual);

        if (is_win) {
            try testing.expectEqualStrings("C:\\Users\\other", actual);
        } else {
            try testing.expectEqualStrings("/usr/home/other", actual);
        }
    }

    {
        if (is_win) {
            const actual = try expandUser(testing.allocator, "~other\\foo");
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings("C:\\Users\\other\\foo", actual);
        } else {
            const actual = try expandUser(testing.allocator, "~other/foo");
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings("/usr/home/other/foo", actual);
        }
    }
}
