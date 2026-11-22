const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const json = @import("json.zig");

pub fn list(allocator: std.mem.Allocator, engine: *const Engine) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"documents\":[");
    for (engine.documents.items, 0..) |document, id| {
        if (id != 0) try output.writer.writeAll(",");
        const encoded = try json.jsonString(allocator, document.content);
        defer allocator.free(encoded);
        try output.writer.print("{{\"id\":{d},\"content\":{s}}}", .{ id, encoded });
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn get(allocator: std.mem.Allocator, engine: *const Engine, id: usize) !?[]u8 {
    if (id >= engine.documents.items.len) return null;
    const encoded = try json.jsonString(allocator, engine.documents.items[id].content);
    defer allocator.free(encoded);
    return try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"content\":{s}}}", .{ id, encoded });
}

pub fn create(allocator: std.mem.Allocator, engine: *Engine, io: std.Io, content: []const u8) ![]u8 {
    const added = try engine.addDocument(io, content);
    const encoded = try json.jsonString(allocator, content);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"content\":{s}}}", .{ added.id, encoded });
}

pub fn update(allocator: std.mem.Allocator, engine: *Engine, io: std.Io, id: usize, content: []const u8) !?[]u8 {
    if (id >= engine.documents.items.len) return null;
    try engine.updateDocument(io, id, content);
    return get(allocator, engine, id);
}

pub fn delete(engine: *Engine, io: std.Io, id: usize) !bool {
    if (id >= engine.documents.items.len) return false;
    try engine.deleteDocument(io, id);
    return true;
}
