const std = @import("std");
const Manager = @import("collection_manager.zig").Manager;
const router = @import("router.zig");

const max_header_bytes = 16 * 1024;
const max_body_bytes = 1024 * 1024;

pub fn serve(io: std.Io, allocator: std.mem.Allocator, manager: *Manager, port: u16) !void {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return error.InvalidAddress;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("API v1 en écoute sur http://127.0.0.1:{d}/api/v1\n", .{port});
    while (true) {
        const stream = try server.accept(io);
        handleConnection(io, allocator, manager, stream) catch |err| std.log.warn("HTTP request ignored: {s}", .{@errorName(err)});
    }
}

fn handleConnection(io: std.Io, allocator: std.mem.Allocator, manager: *Manager, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var headers: std.Io.Writer.Allocating = .init(allocator);
    defer headers.deinit();
    var header_bytes: usize = 0;
    var content_length: usize = 0;
    var first_line = true;
    while (true) {
        // takeDelimiterExclusive leaves the newline unread; consume it here
        // so the next iteration advances to the next header.
        const maybe_line = try reader.interface.takeDelimiter('\n');
        const line = maybe_line orelse return error.InvalidRequest;
        header_bytes += line.len + 1;
        if (header_bytes > max_header_bytes) return error.HeadersTooLarge;
        if (first_line) {
            try headers.writer.writeAll(line);
            first_line = false;
        } else if (line.len == 0 or std.mem.eql(u8, line, "\r")) {
            break;
        } else if (line.len >= "Content-Length:".len and std.ascii.eqlIgnoreCase(line[0.."Content-Length:".len], "Content-Length:")) {
            const raw = std.mem.trim(u8, line["Content-Length:".len..], " \r\t");
            content_length = try std.fmt.parseInt(usize, raw, 10);
        }
        try headers.writer.writeAll("\n");
    }
    if (content_length > max_body_bytes) return error.BodyTooLarge;
    const request_line = headers.written();
    const line_end = std.mem.indexOfScalar(u8, request_line, '\n') orelse return error.InvalidRequest;
    var parts = std.mem.tokenizeScalar(u8, request_line[0..line_end], ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    const body = try allocator.alloc(u8, content_length);
    defer allocator.free(body);
    if (content_length != 0) try reader.interface.readSliceAll(body);
    const result = try router.route(allocator, manager, io, .{ .method = method, .path = path, .body = body });
    defer allocator.free(result.body);
    try writeResponse(io, allocator, stream, result);
}

fn writeResponse(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, result: router.Response) !void {
    const reason: []const u8 = switch (result.status) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        else => "Internal Server Error",
    };
    const header = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ result.status, reason, result.body.len });
    defer allocator.free(header);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(header);
    try writer.interface.writeAll(result.body);
    try writer.interface.flush();
}
