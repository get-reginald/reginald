//! Config is the configuration for the current run of Reginald.

const Config = @This();

const std = @import("std");

/// Path to the config file.
config: []const u8 = "",

/// The working directory. All of the relative paths are resolved relative to
/// this.
directory: []const u8 = ".",

/// If true, the program shows the help message and exits. When this is set to
/// true, the actual config instance should never be loaded.
show_help: bool = false,

/// If true, the program shows the version and exits. When this is set to true,
/// the actual config instance should never be loaded.
show_version: bool = false,

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
    show_help: OptionMetadata,
    show_version: OptionMetadata,
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
};
