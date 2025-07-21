const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const json = std.json;
const mem = std.mem;
const process = std.process;

const toml = @import("toml");

const native_os = builtin.target.os.tag;

const DatetimeType = enum { datetime, datetime_local, date_local, time_local };

const Error = Allocator.Error || fmt.BufPrintError || error{ InvalidDatetime, InvalidTomlValue };

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

fn jsonValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    var obj_map = json.ObjectMap.init(allocator);
    var toml_table: toml.Table = undefined;

    switch (toml_value) {
        .table => |t| toml_table = t,
        else => return error.InvalidTomlValue,
    }

    for (toml_table.keys()) |key| {
        const val = toml_table.get(key) orelse return error.InvalidTomlValue;
        try obj_map.put(try allocator.dupe(u8, key), try objectFromValue(allocator, val));
    }

    return .{ .object = obj_map };
}

fn objectFromValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    switch (toml_value) {
        .string => |s| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "string" });
            try obj.put("value", json.Value{ .string = try allocator.dupe(u8, s) });
            return .{ .object = obj };
        },
        .int => |i| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "integer" });
            var buf: [1024]u8 = undefined;
            try obj.put("value", json.Value{ .string = try fmt.bufPrint(&buf, "{d}", .{i}) });
            return .{ .object = obj };
        },
        .float => |f| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "float" });
            var buf: [1024]u8 = undefined;
            try obj.put("value", json.Value{ .string = try fmt.bufPrint(&buf, "{d}", .{f}) });
            return .{ .object = obj };
        },
        .bool => |b| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "bool" });
            try obj.put("value", json.Value{ .string = if (b) "true" else "false" });
            return .{ .object = obj };
        },
        .datetime => |datetime| {
            var obj = json.ObjectMap.init(allocator);
            var dtt: DatetimeType = .datetime;
            var value: ?[]const u8 = null;

            if (datetime.year) |year| {
                value = try fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2}", .{ year, datetime.month.?, datetime.day.? });
                dtt = .date_local;
            }

            if (datetime.hour) |hour| {
                var time = try fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, datetime.minute.?, datetime.seconds.? });
                if (datetime.nano) |nano| {
                    time = try fmt.allocPrint(allocator, "{s}.{d:0>9}", .{ time, nano });
                }

                if (value) |v| {
                    value = try mem.join(allocator, "T", &[_][]const u8{ v, time });
                    dtt = .datetime_local;
                } else {
                    value = time;
                    dtt = .time_local;
                }
            }

            if (value == null) {
                return error.InvalidDatetime;
            }

            if (datetime.hour_offset) |h_offset| {
                if (dtt == .date_local or dtt == .time_local) {
                    return error.InvalidDatetime;
                }

                var offset: []const u8 = undefined;
                if (h_offset == 0 and datetime.minute_offset.? == 0) {
                    offset = "Z";
                } else {
                    offset = try fmt.allocPrint(allocator, "{s}{d:0>2}:{d:0>2}", .{ switch (datetime.offset_sign.?) {
                        .neg => "-",
                        .pos => "+",
                    }, h_offset, datetime.minute_offset.? });
                }

                value = try mem.concat(allocator, u8, &[_][]const u8{ value.?, offset });
                dtt = .datetime;
            }

            try obj.put("type", json.Value{ .string = switch (dtt) {
                .datetime => "datetime",
                .datetime_local => "datetime-local",
                .date_local => "date-local",
                .time_local => "time-local",
            } });
            try obj.put("value", json.Value{ .string = value.? });
            return .{ .object = obj };
        },
        .array => |arr| {
            var array = json.Array.init(allocator);
            for (arr.items) |item| {
                const json_value = try objectFromValue(allocator, item);
                try array.append(json_value);
            }
            return .{ .array = array };
        },
        .table => {
            return try jsonValue(allocator, toml_value);
        },
    }
}
