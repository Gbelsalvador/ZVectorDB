const std = @import("std");

pub const Embedding = struct {
    allocator: std.mem.Allocator,

    vocab_size: usize,
    dimension: usize,

    weights: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        vocab_size: usize,
        dimension: usize,
    ) !Embedding {
        const size = vocab_size * dimension;
        const weights = try allocator.alloc(f64, size);

        return .{
            .allocator = allocator,
            .vocab_size = vocab_size,
            .dimension = dimension,
            .weights = weights,
        };
    }

    pub fn deinit(
        self: *Embedding,
    ) void {
        self.allocator.free(
            self.weights,
        );
    }

    pub fn randomize(
        self: *Embedding,
        random: std.Random,
    ) void {
        const scale = 1.0 / @sqrt(
            @as(
                f64,
                @floatFromInt(
                    self.dimension,
                ),
            ),
        );

        for (self.weights) |*weight| {
            weight.* = (random.float(f64) * 2.0 - 1.0) * scale;
        }
    }

    pub fn get(
        self: *Embedding,
        word_id: usize,
    ) []f64 {
        std.debug.assert(
            word_id < self.vocab_size,
        );

        const start = word_id * self.dimension;

        return self.weights[start .. start + self.dimension];
    }

    pub fn dotWith(
        self: *Embedding,
        word_id: usize,
        vector: []const f64,
    ) f64 {
        const embedding = self.get(word_id);

        std.debug.assert(
            embedding.len == vector.len,
        );

        var result: f64 = 0.0;

        for (embedding, vector) |a, b| {
            result += a * b;
        }

        return result;
    }
};
