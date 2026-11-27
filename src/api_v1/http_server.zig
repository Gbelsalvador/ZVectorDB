const std = @import("std");
const Manager = @import("collection_manager.zig").Manager;
const router = @import("router.zig");
const Mutex = @import("../concurrency.zig").Mutex;

const max_header_bytes = 16 * 1024;
const max_body_bytes = 1024 * 1024;
pub const worker_count = 100;
const max_requests_per_minute = 1200;

const RateLimiter = struct {
    mutex: Mutex = .{},
    window_start: ?@TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined))) = null,
    count: usize = 0,

    fn allow(self: *RateLimiter, io: std.Io) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.window_start) |start| {
            const elapsed = start.untilNow(io, .awake).nanoseconds;
            if (elapsed >= 60_000_000_000) {
                self.window_start = std.Io.Clock.awake.now(io);
                self.count = 0;
            }
        } else {
            self.window_start = std.Io.Clock.awake.now(io);
        }
        if (self.count >= max_requests_per_minute) return false;
        self.count += 1;
        return true;
    }
};

pub const ConnectionCounters = struct { accepted: u64 = 0, active: u64 = 0, completed: u64 = 0, failed: u64 = 0 };
const Job = struct { stream: std.Io.net.Stream };

const ThreadPool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    manager: *Manager,
    rate_limiter: RateLimiter = .{},
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .empty,
    accepted: u64 = 0,
    active: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,

    fn start(self: *ThreadPool) !void {
        for (0..worker_count) |_| {
            const thread = try std.Thread.spawn(.{}, worker, .{self});
            thread.detach();
        }
    }

    fn enqueue(self: *ThreadPool, stream: std.Io.net.Stream) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.jobs.append(self.allocator, .{ .stream = stream });
        _ = @atomicRmw(u64, &self.accepted, .Add, 1, .monotonic);
        self.available.signal(self.io);
    }

    fn worker(self: *ThreadPool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.jobs.items.len == 0) self.available.waitUncancelable(self.io, &self.mutex);
            const job = self.jobs.orderedRemove(0);
            _ = @atomicRmw(u64, &self.active, .Add, 1, .monotonic);
            self.mutex.unlock(self.io);

            handleConnection(self.io, self.allocator, self.manager, &self.rate_limiter, job.stream) catch |err| {
                _ = @atomicRmw(u64, &self.failed, .Add, 1, .monotonic);
                std.log.warn("HTTP request ignored: {s}", .{@errorName(err)});
                _ = @atomicRmw(u64, &self.active, .Sub, 1, .monotonic);
                continue;
            };
            _ = @atomicRmw(u64, &self.completed, .Add, 1, .monotonic);
            _ = @atomicRmw(u64, &self.active, .Sub, 1, .monotonic);
        }
    }

    fn counters(self: *const ThreadPool) ConnectionCounters {
        return .{
            .accepted = @atomicLoad(u64, &self.accepted, .monotonic),
            .active = @atomicLoad(u64, &self.active, .monotonic),
            .completed = @atomicLoad(u64, &self.completed, .monotonic),
            .failed = @atomicLoad(u64, &self.failed, .monotonic),
        };
    }
};

var active_pool_address: usize = 0;

pub fn connectionCounters() ConnectionCounters {
    const address = @atomicLoad(usize, &active_pool_address, .acquire);
    if (address == 0) return .{};
    const pool: *ThreadPool = @ptrFromInt(address);
    return pool.counters();
}

pub fn serve(io: std.Io, allocator: std.mem.Allocator, manager: *Manager, port: u16) !void {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return error.InvalidAddress;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const pool = try allocator.create(ThreadPool);
    pool.* = .{ .io = io, .allocator = allocator, .manager = manager };
    try pool.start();
    @atomicStore(usize, &active_pool_address, @intFromPtr(pool), .release);
    std.debug.print("API v1 en écoute sur http://127.0.0.1:{d}/api/v1\n", .{port});
    while (true) {
        const stream = try server.accept(io);
        pool.enqueue(stream) catch |err| {
            stream.close(io);
            std.log.warn("HTTP request could not be queued: {s}", .{@errorName(err)});
            continue;
        };
    }
}

fn handleConnection(io: std.Io, allocator: std.mem.Allocator, manager: *Manager, limiter: *RateLimiter, stream: std.Io.net.Stream) !void {
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
    if (!limiter.allow(io)) {
        const too_many = try allocator.dupe(u8, "{\"error\":\"rate_limit_exceeded\"}");
        defer allocator.free(too_many);
        try writeResponse(io, allocator, stream, .{ .status = 429, .body = too_many });
        return;
    }
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
        429 => "Too Many Requests",
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
