const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const collections = @import("collections.zig");
const documents = @import("documents.zig");
const search = @import("search.zig");
const json = @import("json.zig");

pub const Request = struct { method: []const u8, path: []const u8, body: []const u8 = "" };
pub const Response = struct { status: u16, body: []u8 };

pub fn route(allocator: std.mem.Allocator, engine: *Engine, io: std.Io, request: Request) !Response {
    if (std.mem.eql(u8, request.path, "/api/v1/collections")) {
        if (!std.mem.eql(u8, request.method, "GET")) return response(allocator, 405, "{\"error\":\"method_not_allowed\"}");
        return .{ .status = 200, .body = try collections.list(allocator) };
    }

    const prefix = "/api/v1/collections/";
    if (!std.mem.startsWith(u8, request.path, prefix)) return response(allocator, 404, "{\"error\":\"not_found\"}");
    const tail = request.path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const collection_name = tail[0..slash];
    const collection = try collections.get(allocator, collection_name) orelse return response(allocator, 404, "{\"error\":\"collection_not_found\"}");
    allocator.free(collection);
    if (slash == tail.len) {
        if (!std.mem.eql(u8, request.method, "GET")) return response(allocator, 405, "{\"error\":\"method_not_allowed\"}");
        return .{ .status = 200, .body = try collections.get(allocator, collection_name) orelse unreachable };
    }

    const resource = tail[slash + 1 ..];
    if (std.mem.eql(u8, resource, "documents")) {
        if (std.mem.eql(u8, request.method, "GET")) return .{ .status = 200, .body = try documents.list(allocator, engine) };
        if (std.mem.eql(u8, request.method, "POST")) {
            var parsed = json.parse(allocator, request.body) catch return response(allocator, 400, "{\"error\":\"invalid_json\"}");
            defer parsed.deinit();
            const content = json.stringField(parsed.value, "content") orelse return response(allocator, 400, "{\"error\":\"content_required\"}");
            return .{ .status = 201, .body = try documents.create(allocator, engine, io, content) };
        }
    }
    if (std.mem.eql(u8, resource, "search") and std.mem.eql(u8, request.method, "POST")) {
        const result = search.execute(allocator, engine, request.body) catch return response(allocator, 400, "{\"error\":\"invalid_search_request\"}");
        return .{ .status = if (result == null) 400 else 200, .body = result orelse try allocator.dupe(u8, "{\"error\":\"query_required\"}") };
    }

    if (std.mem.startsWith(u8, resource, "documents/")) {
        const raw_id = resource["documents/".len..];
        const id = std.fmt.parseInt(usize, raw_id, 10) catch return response(allocator, 400, "{\"error\":\"invalid_document_id\"}");
        if (std.mem.eql(u8, request.method, "GET")) {
            const result = try documents.get(allocator, engine, id);
            return .{ .status = if (result == null) 404 else 200, .body = result orelse try allocator.dupe(u8, "{\"error\":\"document_not_found\"}") };
        }
        if (std.mem.eql(u8, request.method, "PUT")) {
            var parsed = json.parse(allocator, request.body) catch return response(allocator, 400, "{\"error\":\"invalid_json\"}");
            defer parsed.deinit();
            const content = json.stringField(parsed.value, "content") orelse return response(allocator, 400, "{\"error\":\"content_required\"}");
            const result = try documents.update(allocator, engine, io, id, content);
            return .{ .status = if (result == null) 404 else 200, .body = result orelse try allocator.dupe(u8, "{\"error\":\"document_not_found\"}") };
        }
        if (std.mem.eql(u8, request.method, "DELETE")) {
            const deleted = try documents.delete(engine, io, id);
            return response(allocator, if (deleted) 200 else 404, if (deleted) "{\"deleted\":true}" else "{\"error\":\"document_not_found\"}");
        }
    }
    return response(allocator, 405, "{\"error\":\"method_not_allowed\"}");
}

fn response(allocator: std.mem.Allocator, status: u16, body: []const u8) !Response {
    return .{ .status = status, .body = try allocator.dupe(u8, body) };
}
