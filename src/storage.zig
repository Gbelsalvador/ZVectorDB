const std = @import("std");

pub const Manifest = struct {
    magic: [7]u8,
    version: u32,
    dimension: u32,
    vector_count: u64,
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

    // AJOUT CRUCIAL : Force l'écriture du tampon sur le disque avant la fermeture du fichier
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

    // AJOUT CRUCIAL : Force l'écriture des vecteurs restants dans le tampon
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
