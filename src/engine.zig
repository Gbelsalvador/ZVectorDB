const std = @import("std");
const storage = @import("storage.zig");
const wal_mod = @import("wal.zig");

const Wal = wal_mod.wal;
const Operation = wal_mod.Operation;
const Manifest = storage.Manifest;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    manifest: Manifest,
    wal: Wal,
    vectors: std.ArrayList(f32),

    var current_instance: ?*Engine = null;

    pub fn open(io: anytype, allocator: std.mem.Allocator, dir_path: []const u8) !Engine {
        _ = dir_path;

        const manifest = storage.readManifest(io, "vectors.manifest") catch |err| switch (err) {
            error.FileNotFound => Manifest{
                .magic = .{ 'Z', 'V', 'E', 'C', 'T', 'O', 'R' },
                .version = 1,
                .dimension = 3,
                .vector_count = 0,
                .last_sequence = 0,
                .metric = 0,
                .quantization = 0,
                .reserved = .{0} ** 6,
            },
            else => return err,
        };

        const journal_file = std.Io.Dir.cwd().openFile(io, "vectors.wal", .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(io, "vectors.wal", .{}),
            else => return err,
        };
        journal_file.close(io);
        // var create_f = try std.Io.Dir.cwd().createFile(io, "vectors.wal", .{ .exclusive = false });
        // create_f.close(io);
        const journal = try Wal.init(io, "vectors.wal");

        var engine = Engine{
            .allocator = allocator,
            .manifest = manifest,
            .wal = journal,
            .vectors = std.ArrayList(f32).empty,
        };

        engine.loadSnapshot(io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        try engine.recover(io);

        return engine;
    }

    pub fn close(self: *Engine, io: anytype) void {
        self.wal.deinit(io);
        self.vectors.deinit(self.allocator);
    }

    pub fn insert(self: *Engine, io: anytype, vector: []const f32) !void {
        if (vector.len != self.manifest.dimension) return error.InvalidDimension;

        const bytes = std.mem.sliceAsBytes(vector);
        const seq = try self.wal.append(io, .insert, bytes);

        try self.applyInsert(vector);

        self.manifest.last_sequence = seq;
        self.manifest.vector_count = self.vectors.items.len / self.manifest.dimension;
    }

    fn applyInsert(self: *Engine, vector: []const f32) !void {
        try self.vectors.appendSlice(self.allocator, vector);
    }

    pub fn contains(self: *Engine, vector: []const f32) bool {
        if (self.vectors.items.len == 0) return false;
        var i: usize = 0;
        while (i <= self.vectors.items.len - vector.len) : (i += vector.len) {
            if (std.mem.eql(f32, self.vectors.items[i .. i + vector.len], vector)) {
                return true;
            }
        }
        return false;
    }

    fn loadSnapshot(self: *Engine, io: anytype) !void {
        var file = try std.Io.Dir.cwd().openFile(io, "vectors.bin", .{ .mode = .read_only });
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var r = file.reader(io, read_buf[0..]);

        while (true) {
            var val: f32 = undefined;
            const amt = try r.interface.readSliceShort(std.mem.asBytes(&val));
            if (amt == 0) break;
            try self.vectors.append(self.allocator, val);
        }
    }

    pub fn recover(self: *Engine, io: anytype) !void {
        current_instance = self;
        defer current_instance = null;

        try Wal.replay(io, self.allocator, "vectors.wal", Engine.replayCallback);
    }

    fn replayCallback(operation: Operation, payload: []const u8) anyerror!void {
        const self = current_instance orelse return error.NoEngineContext;

        switch (operation) {
            .insert => {
                const float_count = payload.len / @sizeOf(f32);

                const temp_vector = try self.allocator.alloc(f32, float_count);
                defer self.allocator.free(temp_vector);

                @memcpy(std.mem.sliceAsBytes(temp_vector), payload);
                try self.applyInsert(temp_vector);
            },
            else => {},
        }
    }

    pub fn checkpoint(self: *Engine, io: anytype) !void {
        //
        var file = try std.Io.Dir.cwd().createFile(io, "vectors.bin.tmp", .{});
        defer file.close(io);

        try storage.writeVectors(io, &file, self.vectors.items);
        try file.sync(io);

        try std.Io.Dir.cwd().rename(io, "vectors.bin.tmp", "vectors.bin");

        try storage.writeManifest(io, "vectors.manifest", self.manifest);

        self.wal.next_sequence = 1;
        var truncate_wal = try std.Io.Dir.cwd().createFile(io, "vectors.wal", .{ .exclusive = false });
        truncate_wal.close(io);
    }
};

// --- ZONE DE TEST : VALIDATION DU RECOVERY APRÈS UN CRASH COMPATIBLE ZIG 0.16 ---

test "engine recovery after crash" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // Nettoyage de sécurité avant l'exécution du test
    std.Io.Dir.cwd().deleteFile(io, "vectors.manifest") catch {};
    std.Io.Dir.cwd().deleteFile(io, "vectors.wal") catch {};
    std.Io.Dir.cwd().deleteFile(io, "vectors.bin") catch {};
    defer {
        std.Io.Dir.cwd().deleteFile(io, "vectors.manifest") catch {};
        std.Io.Dir.cwd().deleteFile(io, "vectors.wal") catch {};
        std.Io.Dir.cwd().deleteFile(io, "vectors.bin") catch {};
    }

    const vector1 = [_]f32{ 1.1, 2.2, 3.3 };
    const vector2 = [_]f32{ 4.4, 5.5, 6.6 };

    // ÉTAPE 1 : Session active d'insertions
    {
        var engine = try Engine.open(io, allocator, "test_db");
        defer engine.close(io);

        try engine.insert(io, &vector1);
        try engine.insert(io, &vector2);
    }

    // ÉTAPE 2 : Session de récupération mécanique
    {
        var recovered = try Engine.open(io, allocator, "test_db");
        defer recovered.close(io);

        try std.testing.expect(recovered.contains(&vector1));
        try std.testing.expect(recovered.contains(&vector2));
    }
}
