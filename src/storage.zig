const std = @import("std");

const DatabaseHeader = extern struct {
    magic: [8]u8,
    version: u32,
    reserved: u32,
    dimension: u64,
    document_count: u64,
    vector_count: u64,
};

pub const Database = struct {
    dimension: usize,
    documents: [][]u8,
    vectors: []f64,

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        for (self.documents) |document| allocator.free(document);
        allocator.free(self.documents);
        allocator.free(self.vectors);
    }
};

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

pub fn writeDatabase(
    io: anytype,
    path: []const u8,
    documents: []const []const u8,
    vectors: []const f64,
    dimension: usize,
) !void {
    if (dimension == 0 or vectors.len % dimension != 0) return error.InvalidDatabase;

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var w = file.writer(io, &write_buf);
    const header = DatabaseHeader{
        .magic = .{ 'Z', 'V', 'D', 'B', 'D', 'A', 'T', 'A' },
        .version = 1,
        .reserved = 0,
        .dimension = @intCast(dimension),
        .document_count = @intCast(documents.len),
        .vector_count = @intCast(vectors.len / dimension),
    };
    try w.interface.writeAll(std.mem.asBytes(&header));

    for (documents) |document| {
        const document_len: u64 = @intCast(document.len);
        try w.interface.writeAll(std.mem.asBytes(&document_len));
        try w.interface.writeAll(document);
    }
    try w.interface.writeAll(std.mem.sliceAsBytes(vectors));
    try w.flush();
    try file.sync(io);
}

pub fn readDatabase(
    io: anytype,
    allocator: std.mem.Allocator,
    path: []const u8,
) !Database {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    var header: DatabaseHeader = undefined;
    try r.interface.readSliceAll(std.mem.asBytes(&header));
    if (!std.mem.eql(u8, &header.magic, "ZVDBDATA")) return error.InvalidMagic;
    if (header.version != 1) return error.UnsupportedVersion;
    if (header.dimension == 0 or header.dimension > std.math.maxInt(usize) or
        header.document_count > std.math.maxInt(usize) or header.vector_count > std.math.maxInt(usize))
    {
        return error.InvalidDatabase;
    }

    const dimension: usize = @intCast(header.dimension);
    const document_count: usize = @intCast(header.document_count);
    const vector_count: usize = @intCast(header.vector_count);
    const scalar_count = std.math.mul(usize, vector_count, dimension) catch return error.InvalidDatabase;

    var documents = std.ArrayList([]u8).empty;
    errdefer {
        for (documents.items) |document| allocator.free(document);
        documents.deinit(allocator);
    }
    for (0..document_count) |_| {
        var document_len: u64 = undefined;
        try r.interface.readSliceAll(std.mem.asBytes(&document_len));
        if (document_len > std.math.maxInt(usize)) return error.InvalidDatabase;
        const document = try allocator.alloc(u8, @intCast(document_len));
        r.interface.readSliceAll(document) catch |err| {
            allocator.free(document);
            return err;
        };
        documents.append(allocator, document) catch |err| {
            allocator.free(document);
            return err;
        };
    }

    const vectors = try allocator.alloc(f64, scalar_count);
    errdefer allocator.free(vectors);
    try r.interface.readSliceAll(std.mem.sliceAsBytes(vectors));

    return .{
        .dimension = dimension,
        .documents = try documents.toOwnedSlice(allocator),
        .vectors = vectors,
    };
}

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

test "manifest persistence" {
    const io = std.testing.io;
    const file_path = "test.manifest";

    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    const manifest = Manifest{
        .magic = .{ 'Z', 'V', 'E', 'C', 'T', 'O', 'R' },
        .version = 1,
        .dimension = 768,
        .vector_count = 10000,
        .last_sequence = 0,
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

test "database persistence" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const file_path = "test.database";
    const documents = [_][]const u8{ "Zig vector database", "second document" };
    const vectors = [_]f64{ 1, 0, 0, 0.5, 0.5, 0 };

    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    try writeDatabase(io, file_path, &documents, &vectors, 3);
    var loaded = try readDatabase(io, allocator, file_path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), loaded.dimension);
    try std.testing.expectEqual(@as(usize, 2), loaded.documents.len);
    try std.testing.expectEqualSlices(u8, documents[0], loaded.documents[0]);
    try std.testing.expectEqualSlices(u8, documents[1], loaded.documents[1]);
    try std.testing.expectEqualSlices(f64, &vectors, loaded.vectors);
}
