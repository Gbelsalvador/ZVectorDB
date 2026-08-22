const std = @import("std");

pub const Metadata = struct {
    country: []const u8,
    language: []const u8,
    year: u16,
};

pub const Bitmap = struct {
    bits: []u64,
    length: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        length: usize,
    ) !Bitmap {
        const words = (length + 63) / 64;

        const bits = try allocator.alloc(u64, words);
        @memset(bits, 0);

        return .{
            .bits = bits,
            .length = length,
        };
    }

    pub fn deinit(self: *Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn set(
        self: *Bitmap,
        id: usize,
    ) void {
        const word = id / 64;
        const bit = id % 64;

        self.bits[word] |= (@as(u64, 1) << @intCast(bit));
    }

    pub fn andInPlace(
        self: *Bitmap,
        other: *const Bitmap,
    ) void {
        std.debug.assert(self.bits.len == other.bits.len);

        for (self.bits, other.bits) |*a, b| {
            a.* &= b;
        }
    }

    pub fn orInPlace(
        self: *Bitmap,
        other: *const Bitmap,
    ) void {
        std.debug.assert(self.bits.len == other.bits.len);

        for (self.bits, other.bits) |*a, b| {
            a.* |= b;
        }
    }

    pub fn notInPlace(
        self: *Bitmap,
    ) void {
        for (self.bits) |*word| {
            word.* = ~word.*;
        }
    }
};

// --- ZONE DE TEST : VALIDATION DU BITMAP  ---

test "Bitmap basic operations and memory management" {
    const allocator = std.testing.allocator;

    var b1 = try Bitmap.init(allocator, 100);
    defer b1.deinit(allocator);

    var b2 = try Bitmap.init(allocator, 100);
    defer b2.deinit(allocator);

    b1.set(10);
    b1.set(50);

    b2.set(50);
    b2.set(90);

    b1.andInPlace(&b2);

    const expected_word: u64 = @as(u64, 1) << 50;
    try std.testing.expectEqual(expected_word, b1.bits[0]);
    try std.testing.expectEqual(@as(u64, 0), b1.bits[1]); // Mot index 1 doit être vide
}
