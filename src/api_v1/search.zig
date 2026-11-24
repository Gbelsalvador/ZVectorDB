const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const json = @import("json.zig");

pub fn execute(allocator: std.mem.Allocator, engine: *Engine, body: []const u8) !?[]u8 {
    var parsed = try json.parse(allocator, body);
    defer parsed.deinit();
    const query = json.stringField(parsed.value, "query") orelse return null;
    const results = try engine.searchText(query);
    defer allocator.free(results);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"results\":[");
    for (results, 0..) |result, index| {
        if (index != 0) try output.writer.writeAll(",");
        const maybe_content = try engine.documentContentDup(result.document_id);
        const content = maybe_content orelse "";
        defer if (maybe_content) |owned| allocator.free(owned);
        const encoded = try json.jsonString(allocator, content);
        defer allocator.free(encoded);
        try output.writer.print("{{\"id\":{d},\"score\":{d},\"content\":{s}}}", .{ result.document_id, result.score, encoded });
    }
    try output.writer.writeAll("]}");
    return try output.toOwnedSlice();
}
