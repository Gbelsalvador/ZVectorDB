const std = @import("std");
const HNSW = @import("hnsw.zig").HNSW;
const vector = @import("vector.zig");
const vectorindex = @import("vector_index.zig").vectorindex;
const SearchResult = @import("vector_index.zig").SearchResult;

const DIMENSION = 128;
const DATASET_SIZE = 10_000;
const QUERY_COUNT = 100;
const K = 10;

fn recallAtK(
    exact: anytype,
    approx: anytype,
) f32 {
    if (exact.len == 0) return 0;

    var found: usize = 0;

    for (approx) |a| {
        for (exact) |e| {
            if (a.id == e.id) {
                found += 1;
                break;
            }
        }
    }

    return @as(f32, @floatFromInt(found)) / @as(f32, @floatFromInt(exact.len));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Allocation du dataset plat (DATASET_SIZE * DIMENSION)
    var dataset = try allocator.alloc(f32, DATASET_SIZE * DIMENSION);
    defer allocator.free(dataset);

    for (dataset) |*value| {
        value.* = random.float(f32) * 2.0 - 1.0;
    }

    var hnsw = HNSW.init(
        allocator,
        DIMENSION,
        16,
        100,
        100,
    );
    defer hnsw.deinit();

    var i: usize = 0;
    while (i < DATASET_SIZE) : (i += 1) {
        const start = i * DIMENSION;
        const embedding = dataset[start .. start + DIMENSION];

        _ = try hnsw.insert(
            embedding,
            random,
        );
    }

    const query = try allocator.alloc(f32, DIMENSION);
    defer allocator.free(query);

    for (query) |*value| {
        value.* = random.float(f32) * 2.0 - 1.0;
    }

    // Benchmark Flat via std.Io.Clock
    var flat_stats = vector.DistanceStats{};
    const flat_start = std.Io.Clock.awake.now(io);

    const flat_results = try vectorindex.searchFlat(
        dataset,
        DIMENSION,
        query,
        K,
        allocator,
        &flat_stats,
    );
    defer allocator.free(flat_results);

    const flat_elapsed = flat_start.untilNow(io, .awake);

    // Benchmark HNSW via std.Io.Clock
    var hnsw_stats = vector.DistanceStats{};
    const hnsw_start = std.Io.Clock.awake.now(io);

    const hnsw_results = try hnsw.search(
        query,
        allocator,
        K,
        &hnsw_stats,
    );
    defer allocator.free(hnsw_results);

    const hnsw_elapsed = hnsw_start.untilNow(io, .awake);
    const recall = recallAtK(flat_results, hnsw_results);

    std.debug.print(
        \\Flat:
        \\  time = {d} ns
        \\  distances = {d}
        \\
        \\HNSW:
        \\  time = {d} ns
        \\  distances = {d}
        \\  recall@10 = {d:.3}
        \\
    ,
        .{
            flat_elapsed.nanoseconds,
            flat_stats.comparisons,

            hnsw_elapsed.nanoseconds,
            hnsw_stats.comparisons,

            recall,
        },
    );
}
