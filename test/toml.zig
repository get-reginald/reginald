const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const io = std.io;
const json = std.json;
const process = std.process;

const toml = @import("toml");

const native_os = builtin.target.os.tag;
var debug_allocator: heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const stdin = io.getStdIn().reader();
    const toml_bytes = try stdin.readAllAlloc(gpa, 1024 * 1024); // Adjust size as needed
    defer gpa.free(toml_bytes);

    var parsed = toml.parseFromSlice(gpa, toml_bytes, .{}) catch {
        process.exit(1);
    };
    defer parsed.deinit();

    const json_value = try jsonValue(gpa, parsed.value);
    try json.stringify(json_value, .{}, io.getStdOut().writer());
}

fn jsonValue(allocator: Allocator, toml_value: toml.Value) !json.Value {
    _ = toml_value;
    const obj_map = json.ObjectMap.init(allocator);

    return .{ .object = obj_map };
}
