const std = @import("std");

pub const Manifest = struct {
    magic: [7]u4,
    version: u32,
    dimension: u32,
    vector_count: u64,
    metric: u8,
    quantization: u8,

    reserved: [6]u8,
};

pub fn writeManifest(
    allocator: std.mem.Allocator,
    path: []const u8,
    manifest: Manifest,
) !void {
    _ = allocator;
    var file = try std.fs.cwd().createFile(
        path,
        .{},
    );

    defer file.close();

    try file.writeAll(
        std.mem.asBytes(
            &manifest,
        ),
    );
}

pub fn readManifest(
    path: []const u8,
) !Manifest {
    var file = try std.fs.cwd().openFile(
        path,
        .{},
    );

    defer file.close();

    var manifest: Manifest = undefined;

    const bytes = std.mem.asBytes(
        &manifest,
    );

    const read = try file.readAll(
        bytes,
    );

    if (read != bytes.len) {
        return error.InvalidManifest;
    }

    if (!std.mem.eql(
        u8,
        &manifest.magic,
        "ZVECTOR",
    )) {
        return error.InvalidMagic;
    }

    return manifest;
}

test "manifest persistence" {
    const manifest = Manifest{
        .magic = .{
            'Z',
            'V',
            'E',
            'C',
            'T',
            'O',
            'R',
        },

        .version = 1,

        .dimension = 768,

        .vector_count = 10000,

        .metric = 0,

        .quantization = 1,

        .reserved = .{0} ** 6,
    };

    try writeManifest(
        std.testing.allocator,
        "test.manifest",
        manifest,
    );

    const loaded =
        try readManifest(
            "test.manifest",
        );

    try std.testing.expectEqual(
        manifest.dimension,
        loaded.dimension,
    );

    try std.testing.expectEqual(
        manifest.vector_count,
        loaded.vector_count,
    );
}

pub fn writeVectors(
    file: *std.fs.File,
    vectors: []const f32,
) !void {
    const bytes =
        std.mem.sliceAsBytes(
            vectors,
        );

    try file.writeAll(bytes);
}

pub fn readVectors(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    count: usize,
) ![]f32 {
    const vectors =
        try allocator.alloc(
            f32,
            count,
        );

    errdefer allocator.free(
        vectors,
    );

    const bytes =
        std.mem.sliceAsBytes(
            vectors,
        );

    const read =
        try file.readAll(bytes);

    if (read != bytes.len) {
        return error.UnexpectedEndOfFile;
    }

    return vectors;
}
