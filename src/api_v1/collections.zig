const std = @import("std");

pub const CollectionName = "default";

pub fn list(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"collections\":[{{\"name\":\"{s}\"}}]}}", .{CollectionName});
}

pub fn get(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (!std.mem.eql(u8, name, CollectionName)) return null;
    return std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{CollectionName});
}
