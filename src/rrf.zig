const std = @import("std");

pub const RankedDocument = struct {
    doc_id: u64,
    rank: usize,
};

pub const RRFEntry = struct {
    doc_id: u64,
    score: f32,
};

// Calcule le score RRF unitaire pour un rang donné
pub fn score(rank: usize, k: f32) f32 {
    return 1.0 / (k + @as(f32, @floatFromInt(rank)));
}

pub fn addRank(
    scores: *std.AutoHashMap(u64, f32),
    doc_id: u64,
    rank: usize,
    k: f32,
) !void {
    const contribution = score(rank, k);

    const entry = try scores.getOrPut(doc_id);
    if (!entry.found_existing) {
        entry.value_ptr.* = 0;
    }
    entry.value_ptr.* += contribution;
}

fn lessThanRRF(_: void, a: RRFEntry, b: RRFEntry) bool {
    return a.score > b.score;
}

pub fn computeRRF(
    allocator: std.mem.Allocator,
    scores_map: *std.AutoHashMap(u64, f32),
) ![]RRFEntry {
    const count = scores_map.count();
    const results = try allocator.alloc(RRFEntry, count);
    errdefer allocator.free(results);

    var it = scores_map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        results[i] = RRFEntry{
            .doc_id = entry.key_ptr.*,
            .score = entry.value_ptr.*,
        };
    }

    std.mem.sort(RRFEntry, results, {}, lessThanRRF);
    return results;
}

// --- ZONE DE TEST : VALIDATION DU RRF EN ZIG 0.16 ---

test "RRF fusion and ranking" {
    const allocator = std.testing.allocator;

    var scores = std.AutoHashMap(u64, f32).init(allocator);
    defer scores.deinit();

    const k: f32 = 60.0;

    try addRank(&scores, 100, 1, k);
    try addRank(&scores, 200, 2, k);

    try addRank(&scores, 200, 1, k);
    try addRank(&scores, 100, 3, k);

    const final_rankings = try computeRRF(allocator, &scores);
    defer allocator.free(final_rankings);

    try std.testing.expectEqual(@as(u64, 200), final_rankings[0].doc_id);
    try std.testing.expectEqual(@as(u64, 100), final_rankings[1].doc_id);
    try std.testing.expect(final_rankings[0].score > final_rankings[1].score);
}
