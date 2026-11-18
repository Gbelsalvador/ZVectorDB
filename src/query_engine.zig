const std = @import("std");
const SearchResult = @import("search_result.zig").SearchResult;

pub const CandidateLimit = 50;
pub const ResultLimit = 10;

pub const Plan = struct {
    use_bm25: bool,
    use_vector: bool,
    bm25_candidates: usize,
    vector_candidates: usize,
    aligned_ids: bool,

    pub fn usesBothSources(self: Plan) bool {
        return self.use_bm25 and self.use_vector;
    }
};

pub const Result = struct {
    id: usize,
    score: f64,
    rrf_score: f64,
};

pub const VectorCandidate = struct {
    id: usize,
    score: f32,
};

const FusionCandidate = struct {
    id: usize,
    bm25_score: f64 = 0,
    vector_score: f64 = 0,
    rrf_score: f64 = 0,
    has_bm25: bool = false,
    has_vector: bool = false,
};

pub fn createPlan(
    text_query: []const u8,
    has_vector_query: bool,
    document_count: usize,
    vector_count: usize,
) Plan {
    const use_bm25 = text_query.len != 0 and document_count != 0;
    const use_vector = has_vector_query and vector_count != 0;
    return .{
        .use_bm25 = use_bm25,
        .use_vector = use_vector,
        .bm25_candidates = if (use_bm25) @min(CandidateLimit, document_count) else 0,
        .vector_candidates = if (use_vector) @min(CandidateLimit, vector_count) else 0,
        .aligned_ids = !use_bm25 or !use_vector or document_count == vector_count,
    };
}

pub fn fuseAndRerank(
    allocator: std.mem.Allocator,
    bm25_results: []const SearchResult,
    vector_results: anytype,
    plan: Plan,
) ![]Result {
    if (!plan.aligned_ids) return error.UnalignedIdentifiers;

    var candidates = std.AutoHashMap(usize, FusionCandidate).init(allocator);
    defer candidates.deinit();

    if (plan.use_bm25) {
        for (bm25_results[0..@min(bm25_results.len, plan.bm25_candidates)], 0..) |result, rank| {
            const entry = try candidates.getOrPut(result.document_id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .id = result.document_id };
            entry.value_ptr.bm25_score = result.score;
            entry.value_ptr.has_bm25 = true;
            if (plan.usesBothSources()) entry.value_ptr.rrf_score += reciprocalRankScore(rank + 1);
        }
    }
    if (plan.use_vector) {
        for (vector_results[0..@min(vector_results.len, plan.vector_candidates)], 0..) |result, rank| {
            const entry = try candidates.getOrPut(result.id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .id = result.id };
            entry.value_ptr.vector_score = result.score;
            entry.value_ptr.has_vector = true;
            if (plan.usesBothSources()) entry.value_ptr.rrf_score += reciprocalRankScore(rank + 1);
        }
    }

    var min_bm25 = std.math.inf(f64);
    var max_bm25 = -std.math.inf(f64);
    var min_vector = std.math.inf(f64);
    var max_vector = -std.math.inf(f64);
    var has_bm25_scores = false;
    var has_vector_scores = false;
    var iterator = candidates.iterator();
    while (iterator.next()) |entry| {
        const candidate = entry.value_ptr;
        if (candidate.has_bm25) {
            min_bm25 = @min(min_bm25, candidate.bm25_score);
            max_bm25 = @max(max_bm25, candidate.bm25_score);
            has_bm25_scores = true;
        }
        if (candidate.has_vector) {
            min_vector = @min(min_vector, candidate.vector_score);
            max_vector = @max(max_vector, candidate.vector_score);
            has_vector_scores = true;
        }
    }

    const use_bm25_score = plan.use_bm25 and has_bm25_scores;
    const use_vector_score = plan.use_vector and has_vector_scores;
    const both_scores = use_bm25_score and use_vector_score;
    const results = try allocator.alloc(Result, candidates.count());
    errdefer allocator.free(results);

    iterator = candidates.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const candidate = entry.value_ptr.*;
        const bm25_score = if (candidate.has_bm25)
            normalize(candidate.bm25_score, min_bm25, max_bm25)
        else
            0;
        const vector_score = if (candidate.has_vector)
            normalize(candidate.vector_score, min_vector, max_vector)
        else
            0;
        const final_score: f64 = if (both_scores)
            0.5 * bm25_score + 0.5 * vector_score
        else if (use_bm25_score)
            bm25_score
        else if (use_vector_score)
            vector_score
        else
            0;
        results[index] = .{
            .id = candidate.id,
            .score = final_score,
            .rrf_score = candidate.rrf_score,
        };
    }

    std.mem.sort(Result, results, {}, lessThanResult);
    return results;
}

fn reciprocalRankScore(rank: usize) f64 {
    return 1.0 / (60.0 + @as(f64, @floatFromInt(rank)));
}

fn normalize(value: f64, min_value: f64, max_value: f64) f64 {
    if (max_value == min_value) return 1;
    return (value - min_value) / (max_value - min_value);
}

fn lessThanResult(_: void, a: Result, b: Result) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.rrf_score != b.rrf_score) return a.rrf_score > b.rrf_score;
    return a.id < b.id;
}

test "query plan selects sources and caps candidate counts" {
    const plan = createPlan("search text", true, 120, 25);
    try std.testing.expect(plan.use_bm25);
    try std.testing.expect(plan.use_vector);
    try std.testing.expectEqual(CandidateLimit, plan.bm25_candidates);
    try std.testing.expectEqual(@as(usize, 25), plan.vector_candidates);
    try std.testing.expect(plan.aligned_ids == false);
    const empty_bm25 = [_]SearchResult{};
    const empty_vectors = [_]VectorCandidate{};
    try std.testing.expectError(
        error.UnalignedIdentifiers,
        fuseAndRerank(std.testing.allocator, &empty_bm25, &empty_vectors, plan),
    );

    const text_only = createPlan("search text", false, 4, 25);
    try std.testing.expect(text_only.use_bm25);
    try std.testing.expect(!text_only.use_vector);
    try std.testing.expectEqual(@as(usize, 4), text_only.bm25_candidates);
}

test "query fusion reranks normalized scores and returns deterministic order" {
    const allocator = std.testing.allocator;
    const bm25_results = [_]SearchResult{
        .{ .document_id = 1, .score = 10 },
        .{ .document_id = 0, .score = 5 },
    };
    const vector_results = [_]VectorCandidate{
        .{ .id = 1, .score = 0.9 },
        .{ .id = 0, .score = 0.2 },
        .{ .id = 2, .score = 0.1 },
    };
    const plan = createPlan("text", true, 3, 3);
    const results = try fuseAndRerank(allocator, &bm25_results, &vector_results, plan);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(@as(usize, 1), results[0].id);
    try std.testing.expectEqual(@as(usize, 0), results[1].id);
    try std.testing.expectEqual(@as(usize, 2), results[2].id);
}
