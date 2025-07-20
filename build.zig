const std = @import("std");

const reginald_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "reginald",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);

    const env_prefix_opt = b.option(
        []const u8,
        "env-prefix",
        "Override the default prefix for environment variables used by Reginald. Default is \"REGINALD_\"",
    ) orelse "REGINALD_";
    exe_options.addOption([]const u8, "env_prefix", env_prefix_opt);

    const version_opt = b.option(
        []const u8,
        "version",
        "Override Reginald version string. Default is resolved from Git",
    );
    const version = resolveVersion(b, version_opt) catch {
        std.debug.print("error: resolving version failed\n", .{});
        std.process.exit(1);
    };
    exe_options.addOption([:0]const u8, "version", version);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    if (target.result.os.tag != .windows) {
        exe_unit_tests.linkLibC();
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const toml_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = b.createModule(.{
        .root_source_file = b.path("test/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    toml_mod.addImport("toml", toml_lib_mod);

    const toml = b.addExecutable(.{
        .name = "reginald-toml-test",
        .root_module = toml_mod,
    });

    const run_toml_test = b.addSystemCommand(&[_][]const u8{"toml-test"});
    run_toml_test.addFileArg(toml.getEmittedBin());

    const toml_test_step = b.step("toml-test", "Run toml-test for the TOML parser in Reginald");
    toml_test_step.dependOn(&run_toml_test.step);
}

fn resolveVersion(b: *std.Build, version_opt: ?[]const u8) ![:0]const u8 {
    const version_slice = if (version_opt) |v| v else v: {
        if (!std.process.can_spawn) {
            std.debug.print(
                "error: version cannot be resolved from Git. You must provide Reginald version using -Dversion\n",
                .{},
            );
            std.process.exit(1);
        }
        const version_string = b.fmt("{d}.{d}.{d}", .{
            reginald_version.major,
            reginald_version.minor,
            reginald_version.patch,
        });

        var code: u8 = undefined;
        const untrimmed = b.runAllowFail(&[_][]const u8{
            "git",
            "-C",
            b.build_root.path orelse ".",
            "--git-dir",
            ".git",
            "describe",
            "--match",
            "v*.*.*",
            "--tags",
            "--abbrev=9",
        }, &code, .Ignore) catch {
            // If the above command fails, there is probably no Git tags yet. In that case we need
            // to format a custom version based on the current time.
            const untrimmed = b.runAllowFail(&[_][]const u8{
                "git",
                "-C",
                b.build_root.path orelse ".",
                "--git-dir",
                ".git",
                "describe",
                "--always",
                "--abbrev=40",
                "--dirty",
            }, &code, .Ignore) catch {
                break :v version_string;
            };
            const commit = std.mem.trim(u8, untrimmed, " \n\r");

            if (!std.mem.endsWith(u8, commit, "-dirty")) {
                const untrimmed_date = b.runAllowFail(&[_][]const u8{
                    "git",
                    "-C",
                    b.build_root.path orelse ".",
                    "--git-dir",
                    ".git",
                    "show",
                    "-s",
                    "--date=format:'%Y%m%d%H%M%S'",
                    "--format=%cd",
                    std.mem.trimRight(u8, commit, "-dirty"),
                }, &code, .Ignore) catch {
                    break :v version_string;
                };
                const date = std.mem.trim(u8, untrimmed_date, " \n\r");
                break :v b.fmt("{s}-dev.{s}+{s}", .{
                    version_string,
                    date,
                    std.mem.trimRight(u8, commit, "-dirty"),
                });
            }

            const now = std.time.timestamp();

            // We assume that Reginald won't be built before epoch so the timestamp isn't negative.
            const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(now)) };
            const epoch_day = epoch_secs.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const year = year_day.year;
            const month_day = year_day.calculateMonthDay();
            const month = month_day.month.numeric();
            const day = month_day.day_index + 1;
            const day_secs = epoch_secs.getDaySeconds();
            const hour = day_secs.getHoursIntoDay();
            const minute = day_secs.getMinutesIntoHour();
            const second = day_secs.getSecondsIntoMinute();

            var buffer: [14]u8 = undefined;
            _ = try std.fmt.bufPrint(
                &buffer,
                "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}",
                .{ year, month, day, hour, minute, second },
            );

            break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, buffer, commit });
        };
        const git_describe = std.mem.trim(u8, untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                if (!std.mem.eql(u8, git_describe, version_string)) {
                    std.debug.print("Reginald version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                    std.process.exit(1);
                }

                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
                var it = std.mem.splitScalar(u8, git_describe, '-');
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                if (reginald_version.order(ancestor_ver) != .gt) {
                    std.debug.print("Reginald version '{}' must be greater than tagged ancestor '{}'\n", .{ reginald_version, ancestor_ver });
                    std.process.exit(1);
                }

                // Check that the commit hash is prefixed with a 'g' (a Git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                    break :v version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                break :v version_string;
            },
        }
    };
    const version = try b.allocator.dupeZ(u8, version_slice);

    return version;
}
