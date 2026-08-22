const std = @import("std");

pub const VectorStorage = struct {
    data: []const f32,
    dimension: usize,
    count: usize,
    raw_mapping: []align(std.mem.page_size) u8,

    pub fn get(
        self: *const VectorStorage,
        id: usize,
    ) []const f32 {
        const start = id * self.dimension;
        return self.data[start .. start + self.dimension];
    }

    pub fn close(self: *VectorStorage) void {
        if (self.raw_mapping.len > 0) {
            std.posix.munmap(self.raw_mapping);
            self.raw_mapping = &.{};
            self.data = &.{};
        }
    }
};

pub fn openRam(
    data: []const f32,
    dimension: usize,
) VectorStorage {
    return .{
        .data = data,
        .dimension = dimension,
        .count = data.len / dimension,
        .raw_mapping = &.{},
    };
}

pub const VectorFileHeader = struct {
    magic: [4]u8,
    version: u32,
    dimension: u32,
    count: u64,
    element_size: u32,
};

pub fn openMapped(
    io: anytype,
    path: []const u8,
    dimension: usize,
) !VectorStorage {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const stats = try file.stat(io);
    if (stats.size < @sizeOf(VectorFileHeader)) return error.InvalidFileLength;

    const raw_bytes = try std.posix.mmap(
        null,
        stats.size,
        std.posix.PROT.READ,
        std.posix.MAP.SHARED,
        file.handle,
        0,
    );
    errdefer std.posix.munmap(raw_bytes);

    const header = std.mem.bytesAsValue(VectorFileHeader, raw_bytes[0..@sizeOf(VectorFileHeader)]);
    if (!std.mem.eql(u8, &header.magic, "ZBIN")) return error.InvalidMagic;
    if (header.dimension != dimension) return error.DimensionMismatch;

    const vector_bytes = raw_bytes[@sizeOf(VectorFileHeader)..];

    const float_data = std.mem.bytesAsSlice(f32, vector_bytes);

    return VectorStorage{
        .data = float_data,
        .dimension = dimension,
        .count = float_data.len / dimension,
        .raw_mapping = raw_bytes,
    };
}
