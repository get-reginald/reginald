//! Config is the configuration for the current run of Reginald.

const Config = @This();

const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const process = std.process;

const cli = @import("cli.zig");
const filepath = @import("filepath.zig");

/// Path to the config file.
config: []const u8 = "",

/// The working directory. All of the relative paths are resolved relative to
/// this.
directory: []const u8 = ".",

/// The maximum number of concurrent jobs to allow. If this is less than 1,
/// unlimited concurrent jobs are allowed.
max_jobs: i32 = -1,

/// Whether quiet output is enabled.
quiet: bool = false,

/// If true, the program shows the help message and exits. When this is set to
/// true, the actual config instance should never be loaded.
show_help: bool = false,

/// If true, the program shows the version and exits. When this is set to true,
/// the actual config instance should never be loaded.
show_version: bool = false,

/// Whether verbose output is enabled.
verbose: bool = false,

const native_os = builtin.target.os.tag;

/// Basename of the default config files without the file extension.
const default_filename = "reginald";

/// Default config file extensions to look for.
const default_extensions = [_][]const u8{".toml"};

/// Helper constant that contains the different files that should be checked for
/// config files when trying to find it from "~/.config" or similar.
const unix_config_lookup = [_][]const u8{
    default_filename ++ std.fs.path.sep_str ++ default_filename,
    default_filename ++ std.fs.path.sep_str ++ "config",
    default_filename,
};

pub const OptionMetadata = struct {
    /// Name of the long command-line option. If not set but the command-line
    /// option is not disable, the name of the field will be used.
    long: ?[]const u8 = null,

    /// The one-letter command-line option.
    short: ?u8 = null,

    /// Short description of the option on the command-line help output.
    description: ?[]const u8 = null,

    /// If not null and set to true, no command-line option is generated for
    /// this option.
    disable_option: ?bool = null,

    /// If not null and set to true, value for this config option is not checked
    /// from an environment variable.
    disable_env: ?bool = null,

    /// Subcommands for which the command-line option for this config option
    /// should be created for instead of creating it as a global command-line
    /// option.
    subcommands: ?[]const []const u8 = null,
};

pub const Metadata = struct {
    config: OptionMetadata,
    directory: OptionMetadata,
    max_jobs: OptionMetadata,
    quiet: OptionMetadata,
    show_help: OptionMetadata,
    show_version: OptionMetadata,
    verbose: OptionMetadata,
};

/// The metadata of the config.
pub const metadata = Metadata{
    .config = .{
        .short = 'c',
        .description = "use config file from `<path>`",
    },
    .directory = .{
        .short = 'C',
        .description = "run Reginald as if it was started from `<path>`",
    },
    .max_jobs = .{
        .long = "jobs",
        .short = 'j',
        .description = "maximum number of jobs to run concurrently",
        .subcommands = &[_][]const u8{"apply"},
    },
    .quiet = .{
        .short = 'q',
        .description = "silence all output expect errors",
    },
    .show_help = .{
        .long = "help",
        .short = 'h',
        .description = "show the help message and exit",
        .disable_env = true,
    },
    .show_version = .{
        .long = "version",
        .description = "print the version information and exit",
        .disable_env = true,
    },
    .verbose = .{
        .short = 'v',
        .description = "print more verbose output",
    },
};

/// Find the first matching config file and load its contents. The caller owns
/// the returned contents and should call `free` on them.
pub fn loadFile(allocator: Allocator, file_opt: *cli.Option, wd_path: ?[]const u8) ![]const u8 {
    var env_path: ?[]const u8 = null;
    if (process.getEnvVarOwned(allocator, build_options.env_prefix ++ "CONFIG")) |s| {
        env_path = s;
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    var opt_path: ?[]const u8 = null;
    if (file_opt.changed) {
        switch (file_opt.value) {
            .string => |s| opt_path = s,
            else => unreachable,
        }
    }

    var path: ?[]const u8 = null;

    if (opt_path) |s| {
        if (env_path) |p| {
            allocator.free(p);
        }

        path = try allocator.dupe(u8, s);
    } else if (env_path) |s| {
        path = s; // We already own s.
    }

    if (path) |p| {
        defer allocator.free(p);

        const f = try filepath.expand(allocator, p);
        defer allocator.free(f);

        var wd = fs.cwd();
        if (wd_path) |s| {
            wd = try wd.openDir(s, .{});
        }
        defer if (wd_path != null) {
            wd.close();
        };

        return try loadOne(allocator, f, &wd);
    }

    // If the user uses an option or environment variable to set the config
    // file, the lookup should fail if that file is not present. Otherwise, we
    // should continue and check the default file locations.
    var wd = fs.cwd();
    if (wd_path) |s| {
        wd = try wd.openDir(s, .{});
    }
    defer if (wd_path != null) {
        wd.close();
    };

    // Current working directory first as that's the most natural place.
    inline for (default_extensions) |e| {
        if (loadOne(allocator, default_filename ++ e, &wd)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound, error.IsDir => {},
                else => return err,
            }
        }
    }

    if (process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);

        // I think this is the encouraged way to handle the lookups.
        var dir = try wd.openDir(xdg, .{});
        defer dir.close();

        if (tryPaths(allocator, unix_config_lookup, &dir)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    if (native_os == .windows or native_os == .uefi) {
        // TODO: Are these the correct paths for Windows? I don't know it that
        // well.
        const dirname = try filepath.expand(allocator, "%APPDATA%");
        defer allocator.free(dirname);

        var dir = try wd.openDir(dirname, .{});
        defer dir.close();

        if (tryPaths(allocator, [_][]const u8{ default_filename, "config" }, &dir)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    } else if (native_os.isDarwin()) {
        const app_support_j = try fs.path.join(
            allocator,
            &[_][]const u8{ "~", "Library", "Application Support", default_filename },
        );
        defer allocator.free(app_support_j);

        const app_support_name = try filepath.expand(allocator, app_support_j);
        defer allocator.free(app_support_name);

        var app_support = try wd.openDir(app_support_name, .{});
        defer app_support.close();

        if (tryPaths(allocator, [_][]const u8{ default_filename, "config" }, &app_support)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    }

    if (native_os != .windows and native_os != .uefi) {
        const home_cfg_j = try fs.path.join(allocator, &[_][]const u8{ "~", ".config" });
        defer allocator.free(home_cfg_j);

        const home_cfg_name = try filepath.expand(allocator, home_cfg_j);
        defer allocator.free(home_cfg_name);

        var home_cfg = try wd.openDir(home_cfg_name, .{});
        defer home_cfg.close();

        if (tryPaths(allocator, unix_config_lookup, &home_cfg)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        const home_j = try fs.path.join(allocator, &[_][]const u8{ "~", default_filename });
        defer allocator.free(home_j);

        const home_name = try filepath.expand(allocator, home_j);
        defer allocator.free(home_name);

        var home = try wd.openDir(home_name, .{});
        defer home.close();

        if (tryPaths(allocator, [_][]const u8{ default_filename, "." ++ default_filename }, &home)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    }

    return error.FileNotFound;
}

/// Try to load a config file. Caller owns the result and should call `free` on
/// it.
fn loadOne(allocator: Allocator, f: []const u8, dir: *std.fs.Dir) ![]const u8 {
    const stat = try dir.statFile(f);
    const size = stat.size;
    const max_size = 1 << 20;

    if (size > max_size) {
        const w = std.io.getStdErr().writer();
        try w.print(
            "config files over 1MB are not currently allowed, current size is {d} bytes\n",
            .{size},
        );
        try w.print(
            "this is only temporary safeguard during development and will be removed in the future\n",
            .{},
        );

        return error.FileTooBig;
    }

    // TODO: Is one MB enough?
    return try dir.readFileAlloc(allocator, f, 1 << 20);
}

fn tryPaths(allocator: Allocator, comptime paths: anytype, dir: *std.fs.Dir) ![]const u8 {
    inline for (paths) |f| {
        inline for (default_extensions) |e| {
            if (loadOne(allocator, f ++ e, dir)) |result| {
                return result;
            } else |err| {
                switch (err) {
                    error.FileNotFound, error.IsDir => {},
                    else => return err,
                }
            }
        }
    }

    return error.FileNotFound;
}
