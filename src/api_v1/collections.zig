const std = @import("std");
const Manager = @import("collection_manager.zig").Manager;
const constants = @import("constants.zig");
const json = @import("json.zig");

pub const CollectionName = constants.CollectionName;

pub fn list(manager: *Manager) ![]u8 {
    return manager.listJson();
}

pub fn get(allocator: std.mem.Allocator, manager: *Manager, name: []const u8) !?[]u8 {
    if (manager.get(name) == null) return null;
    const encoded = try json.jsonString(allocator, name);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{{\"name\":{s}}}", .{encoded});
}

pub fn create(manager: *Manager, name: []const u8) !void {
    return manager.create(name);
}

pub fn delete(manager: *Manager, name: []const u8) !bool {
    return manager.delete(name);
}
