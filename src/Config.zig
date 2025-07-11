//! Config is the configuration for the current run of Reginald.

const std = @import("std");

/// Resolve the default config file.
pub fn defaultConfigFile() ![]const u8 {
    return "";
}

// Resolve the default working directory for the run.
pub fn defaultDir() ![]const u8 {
    // No need to have a Dir object so we just get the string. Let's hope the buffer size is enough.
    var buf: [512]u8 = undefined;
    return try std.process.getCwd(&buf);
}
