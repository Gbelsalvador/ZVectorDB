const std = @import("std");

pub const Operation = enum(u8) {
    insert = 1,
    delete = 2,
    update = 3,
};

const WalEntryHeader = struct {
    magic: [4]u8,
    version: u8,
    operation: Operation,
    payload_len: u32,
    sequence: u64,
    checksum: u32,
};

const crc32 = std.hash.Crc32;

fn checksum(data: []const u8) u32 {
    return crc32.hash(data);
}

pub const wal = struct {
    file: std.Io.File,
    next_sequence: u64,

    pub fn init(
        io: anytype,
        path: []const u8,
    ) !wal {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{
            .mode = .read_write,
        });

        return .{
            .file = file,
            .next_sequence = 1,
        };
    }

    pub fn deinit(
        self: *wal,
        io: anytype,
    ) void {
        self.file.close(io);
    }

    pub fn append(
        self: *wal,
        io: anytype,
        operation: Operation,
        payload: []const u8,
    ) !u64 {
        const sequence = self.next_sequence;
        self.next_sequence += 1;

        const header = WalEntryHeader{
            .magic = .{ 'Z', 'W', 'A', 'L' },
            .version = 1,
            .operation = operation,
            .payload_len = @intCast(payload.len),
            .sequence = sequence,
            .checksum = checksum(payload),
        };

        const stats = try self.file.stat(io);

        var write_buf: [4096]u8 = undefined;
        var w = self.file.writer(io, &write_buf);

        try w.seekTo(stats.size);
        try w.interface.writeAll(std.mem.asBytes(&header));
        try w.interface.writeAll(payload);

        try w.flush();
        try self.file.sync(io);
        return sequence;
    }

    pub const ReplayFn = *const fn (
        operation: Operation,
        payload: []const u8,
    ) anyerror!void;

    pub fn replay(
        io: anytype,
        allocator: std.mem.Allocator,
        path: []const u8,
        callback: ReplayFn,
    ) !void {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var payload_buf: [4096]u8 = undefined;
        var r = file.reader(io, &payload_buf);

        try r.seekTo(0);

        while (true) {
            var header: WalEntryHeader = undefined;
            const header_bytes = std.mem.asBytes(&header);

            const amt = try r.interface.readSliceShort(header_bytes);
            if (amt == 0) break;
            if (amt < header_bytes.len) return error.TruncatedWal;
            if (!std.mem.eql(u8, &header.magic, "ZWAL")) return error.InvalidMagic;

            const payload = try allocator.alloc(u8, header.payload_len);
            defer allocator.free(payload);

            try r.interface.readSliceAll(payload);

            if (checksum(payload) != header.checksum) {
                return error.CorruptedWal;
            }

            try callback(header.operation, payload);
        }
    }
};
// pour le test

const ReplayTracker = struct {
    pub fn callback(operation: Operation, payload: []const u8) anyerror!void {
        switch (operation) {
            .insert => {
                try std.testing.expectEqualSlices(u8, "Hello Zig 0.16", payload);
            },
            .update => {
                try std.testing.expectEqualSlices(u8, "WAL is working", payload);
            },
            .delete => return error.UnexpectedOperation,
        }
    }
};

test "WAL complete cycle: append and replay" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "test_run.wal";

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        // Création initiale
        var create_file = try std.Io.Dir.cwd().createFile(io, path, .{});
        create_file.close(io);

        var my_wal = try wal.init(io, path);
        defer my_wal.deinit(io);

        const seq1 = try my_wal.append(io, .insert, "Hello Zig 0.16");
        try std.testing.expectEqual(@as(u64, 1), seq1);

        const seq2 = try my_wal.append(io, .update, "WAL is working");
        try std.testing.expectEqual(@as(u64, 2), seq2);
    }

    // Phase de replay
    try wal.replay(io, allocator, path, ReplayTracker.callback);
}
