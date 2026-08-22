const std = @import("std");
const wal_mod = @import("wal.zig");
const Wal = wal_mod.wal;
const Operation = wal_mod.Operation;
pub const Manifest = struct {
    magic: [7]u8,
    version: u32,
    dimension: u32,
    vector_count: u64,
    last_sequence: u64,
    metric: u8,
    quantization: u8,
    reserved: [6]u8,
};

pub fn writeManifest(
    io: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
    manifest: Manifest,
) !void {
    _ = allocator;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [256]u8 = undefined;
    var w = file.writer(io, &write_buf);

    try w.interface.writeAll(std.mem.asBytes(&manifest));

    // Force l'écriture du tampon sur le disque avant la fermeture du fichier
    try w.flush();
}

pub fn readManifest(
    io: anytype,
    path: []const u8,
) !Manifest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var manifest: Manifest = undefined;
    const bytes = std.mem.asBytes(&manifest);

    var read_buf: [256]u8 = undefined;
    var r = file.reader(io, &read_buf);

    try r.interface.readSliceAll(bytes);

    if (!std.mem.eql(u8, &manifest.magic, "ZVECTOR")) {
        return error.InvalidMagic;
    }

    return manifest;
}

pub const Engine = struct {
    allocator: std.mem.Allocator,
    manifest: Manifest,
    wal: Wal,
    vectors: std.ArrayList(f32),

    var current_engine_instance: ?*Engine = null;
    pub fn open(io: anytype, allocator: std.mem.Allocator, dir_path: []const u8) !Engine {
        _ = dir_path;
        const manifest = readManifest(io, "Vectors.manifest") catch |err| switch (err) {
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

        var f = std.Io.Dir.cwd().createFile(io, "vectors.wal", .{}) catch |err| switch (err) {
            error.PathAlreadyExists => try std.Io.Dir.cwd().openFile(io, "vectors.wal", .{ .mode = .read_write }),
            else => return err,
        };
        f.close(io);

        const journal = try Wal.init(io, "vectors.wal");

        var engine = Engine{
            .allocator = allocator,
            .manifest = manifest,
            .wal = journal,
            .vectors = std.ArrayList(f32).empty,
        };

        engine.loadSnapshot(io) catch |err| if (err != error.FileNotFound) return err;
        try engine.recover(io);

        return engine;
    }

    pub fn close(self: *Engine, io: anytype) void {
        self.wal.denit(io);
        self.vectors.deinit(self.allocator);
    }

    pub fn insert(self: *Engine, io: anytype, vector: []const f32) !void {
        const bytes = std.mem.sliceAsBytes(vector);
        const seq = try self.wal.append(io, .insert, bytes);
        try self.applyInsert(vector);
        self.manifest.last_sequence = seq;
        self.manifest.vector_count = self.vectors.items.len / 3;
    }

    pub fn applyInsert(self: *Engine, vector: []const f32) !void {
        try self.vectors.appendSlice(self.allocator, vector);
    }

    pub fn contains(self: *Engine, vector: []const f32) bool {
        if (self.vectors.items.len == 0) return false;
        var i: usize = 0;
        while (i <= self.vectors.items.len - vector.len) : (i += vector.len) {
            if (std.mem.eql(f32, self.vectors.items[i .. i + vector.len], vector)) return true;
        }
        return false;
    }
    fn loadSnapshot(self: *Engine, io: anytype) !void {
        var file = try std.Io.Dir.cwd().openFile(io, "vectors.bin", .{ .mode = .read_only });
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var r = file.reader(io, &read_buf);

        while (true) {
            var val: f32 = undefined;
            const amt = try r.interface.readSliceShort(std.mem.asBytes(&val));
            if (amt == 0) break;
            try self.vectors.append(self.allocator, val);
        }
    }
    pub fn recover(self: *Engine, io: anytype) !void {
        current_engine_instance = self;
        defer current_engine_instance = null;

        try Wal.replay(io, self.allocator, "vectors.wal", Engine.replayCallback);
    }
    fn replayCallback(operation: Operation, payload: []const u8) anyerror!void {
        const self = current_engine_instance orelse return error.NoEngineContext;

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
        var file = try std.Io.Dir.cwd().createFile(io, "vectors.bin.tmp", .{});
        defer file.close(io);

        var write_buf: [4096]u8 = undefined;
        var w = file.writer(io, &write_buf);
        try w.interface.writeAll(std.mem.sliceAsBytes(self.vectors.items));
        try w.flush();
        try file.sync(io);

        try std.Io.Dir.cwd().rename(io, "vectors.bin.tmp", "vectors.bin");

        try writeManifest(io, "vectors.manifest", self.manifest);
    }
};

pub fn writeVectors(
    io: anytype,
    file: *std.Io.File,
    vectors: []const f32,
) !void {
    const bytes = std.mem.sliceAsBytes(vectors);

    var write_buf: [4096]u8 = undefined;
    var w = file.writer(io, &write_buf);

    try w.interface.writeAll(bytes);

    // Force l'écriture du tampon sur le disque avant la fermeture du fichier
    try w.flush();
}

pub fn readVectors(
    io: anytype,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    count: usize,
) ![]f32 {
    const vectors = try allocator.alloc(f32, count);
    errdefer allocator.free(vectors);

    const bytes = std.mem.sliceAsBytes(vectors);

    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);

    try r.interface.readSliceAll(bytes);

    return vectors;
}

test "recovery after crash" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // Nettoyage initial des fichiers de test
    defer {
        std.Io.Dir.cwd().deleteFile(io, "vectors.manifest") catch {};
        std.Io.Dir.cwd().deleteFile(io, "vectors.wal") catch {};
        std.Io.Dir.cwd().deleteFile(io, "vectors.bin") catch {};
    }

    const v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 4.0, 5.0, 6.0 };

    {
        // 1. Première session : On insère des données puis on "crash" (close sans checkpoint)
        var engine = try Engine.open(io, allocator, "test_db");
        defer engine.close(io);

        try engine.insert(io, &v1);
        try engine.insert(io, &v2);
    }
    {
        // 2. Deuxième session : On relance un moteur tout neuf sur les mêmes fichiers
        var recovered = try Engine.open(io, allocator, "test_db");
        defer recovered.close(io);

        // L'Engine doit lire le WAL et restaurer v1 et v2 magiquement en mémoire !
        try std.testing.expect(recovered.contains(&v1));
        try std.testing.expect(recovered.contains(&v2));
    }
}
test "manifest persistence" {
    const io = std.testing.io;
    const file_path = "test.manifest";

    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    const manifest = Manifest{
        .magic = .{ 'Z', 'V', 'E', 'C', 'T', 'O', 'R' },
        .version = 1,
        .dimension = 768,
        .vector_count = 10000,
        .metric = 0,
        .quantization = 1,
        .reserved = .{0} ** 6,
    };

    try writeManifest(
        io,
        std.testing.allocator,
        file_path,
        manifest,
    );

    const loaded = try readManifest(
        io,
        file_path,
    );

    try std.testing.expectEqual(manifest.dimension, loaded.dimension);
    try std.testing.expectEqual(manifest.vector_count, loaded.vector_count);
}
