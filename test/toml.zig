const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const io = std.io;
const json = std.json;
const process = std.process;

const toml = @import("toml");

const native_os = builtin.target.os.tag;

pub fn main() !void {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdin = io.getStdIn().reader();
    const toml_bytes = try stdin.readAllAlloc(allocator, 1024 * 1024); // Adjust size as needed
    defer allocator.free(toml_bytes);

    var parsed = toml.parseFromSlice(allocator, toml_bytes, .{}) catch {
        process.exit(1);
    };
    defer parsed.deinit();

    const json_value = try jsonValue(allocator, parsed.value);
    try json.stringify(json_value, .{}, io.getStdOut().writer());
}

fn jsonValue(allocator: Allocator, toml_value: toml.Value) !json.Value {
    _ = toml_value;
    const obj_map = json.ObjectMap.init(allocator);

    return .{ .object = obj_map };
}
