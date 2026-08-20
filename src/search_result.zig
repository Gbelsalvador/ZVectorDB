const std = @import("std");
pub const SearchResult = struct {
    document_id: usize,
    score: f64,
};

pub const SearchResult2 = struct { id: usize, score: f32 };

pub fn topK(
    allocator: std.mem.Allocator,
    Candidates: []const SearchResult2,
    k: usize,
) ![]SearchResult2 {
    var results = try allocator.dupe(
        SearchResult2,
        Candidates,
    );

    std.sort.pdq(
        SearchResult2,
        results,
        {},
        struct {
            fn lessThan(
                _: void,
                a: SearchResult2,
                b: SearchResult2,
            ) bool {
                return a.score > b.score;
            }
        }.lessThan,
    );

    const count = @min(k, results.len);
    const output = try allocator.alloc(
        SearchResult2,
        count,
    );

    @memcpy(
        output,
        results[0..count],
    );

    allocator.free(results);

    return output;
}
