const std = @import("std");
const vector = @import("vector.zig");

pub const SearchResult = struct {
    id: usize,
    score: f64,
};
pub const vectorindex = struct {
    allocator: std.mem.Allocator,

    dimension: usize,
    vectors: std.ArrayList(f64),

    count: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        dimension: usize,
    ) vectorindex {
        return .{
            .allocator = allocator,
            .dimension = dimension,
            .vectors = std.ArrayList(f64).empty,
            .count = 0,
        };
    }

    pub fn deinit(
        self: *vectorindex,
    ) void {
        self.vectors.deinit(self.allocator);
    }

    pub fn add(
        self: *vectorindex,
        embedding: []const f64,
    ) !usize {
        if (embedding.len != self.dimension) {
            return error.InvalidDimension;
        }

        try self.vectors.appendSlice(
            self.allocator,
            embedding,
        );

        const id = self.count;

        self.count += 1;

        return id;
    }

    pub fn get(
        self: *vectorindex,
        id: usize,
    ) []const f64 {
        const start = id * self.dimension;

        return self.vectors.items[start .. start + self.dimension];
    }

    pub fn search(
        self: *vectorindex,
        query: []const f64,
        allocator: std.mem.Allocator,
        top_k: usize,
    ) ![]SearchResult {
        if (query.len != self.dimension) {
            return error.InvalidDimension;
        }

        var results = try allocator.alloc(SearchResult, self.count);

        for (0..self.count) |id| {
            const candidate = self.get(id);

            results[id] = .{
                .id = id,
                .score = vector.cosineSimilarity(
                    query,
                    candidate,
                ),
            };
        }

        std.sort.pdq(
            SearchResult,
            results,
            {},
            struct {
                fn lessthan(
                    _: void,
                    a: SearchResult,
                    b: SearchResult,
                ) bool {
                    return a.score > b.score;
                }
            }.lessThan,
        );

        const result_count = @min(
            top_k,
            results.len,
        );

        const output = try allocator.alloc(
            SearchResult,
            result_count,
        );

        @memcpy(
            output,
            results[0..result_count],
        );

        allocator.free(results);

        return output;
    }
};
