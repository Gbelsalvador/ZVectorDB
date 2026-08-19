const std = @import("std");
const vector = @import("vector.zig");

pub const Node = struct {
    id: usize,

    vector: []const f32,
    neighbors: std.ArrayList(usize),
    levels: std.ArrayList(std.ArrayList(usize)),
    level: usize,
};

pub const Candidate = struct {
    id: usize,
    score: f32,
};

pub fn CandidateLessThan(
    _: void,
    a: Candidate,
    b: Candidate,
) std.math.Order {
    return std.math.order(b.score, a.score);
}

pub const CandidateQueue = std.PriorityQueue(Candidate, void, CandidateLessThan);

pub const HNSW = struct {
    allocator: std.mem.Allocator,
    dimension: usize,
    m: usize,
    ef_construtcion: usize,
    ef_search: usize,
    nodes: std.ArrayList(Node),
    entry_point: ?usize,
    max_level: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        dimension: usize,
        m: usize,
        ef_construction: usize,
        ef_search: usize,
    ) HNSW {
        return .{
            .allocator = allocator,
            .dimension = dimension,
            .m = m,

            .ef_construction = ef_construction,
            .ef_search = ef_search,
            .nodes = std.ArrayList(Node).empty,
            .entry_point = null,
            .max_level = 0,
        };
    }

    fn RandomLevel(
        random: std.Random,
    ) usize {
        var level: usize = 0;

        while (random.float(f64) < 0.5) {
            level += 1;
        }

        return level;
    }

    fn greedySearch(
        self: *HNSW,
        query: []const f32,
        entry: usize,
        level: usize,
    ) usize {
        _ = level;
        var current = entry;

        while (true) {
            var changed = false;

            const current_node = &self.nodes.items[current];

            const current_score = vector.cosineSimilarity(
                query,
                current_node.vector,
            );
            for (current_node.neighbors.items) |neighbor_id| {
                const neighbor = &self.nodes.items[neighbor_id];

                const score = vector.cosineSimilarity(
                    query,
                    neighbor.vector,
                );

                if (score > current_score) {
                    current = neighbor_id;
                    changed = true;
                    break;
                }
            }

            if (!changed) {
                break;
            }
        }
        return current;
    }

    fn searchLayer(
        self: *HNSW,
        query: []const f32,
        entry_point: usize,
        level: usize,
        ef: usize,
        allocator: std.mem.Allocator,
    ) ![]Candidate {
        var candidates = CandidateQueue.init(allocator, {});

        defer candidates.deinit(self.allocator);

        var results =
            std.ArrayList(Candidate)
                .init(allocator);

        defer results.deinit(self.allocator);

        var visited =
            std.AutoHashMap(
                usize,
                void,
            ).init(allocator);

        defer visited.deinit(self.allocator);

        const entry =
            &self.nodes.items[
                entry_point
            ];

        const entry_score =
            vector.cosineSimilarity(
                query,
                entry.vector,
            );

        const initial = Candidate{
            .id = entry_point,
            .score = entry_score,
        };

        try candidates.add(initial);
        try results.append(initial);

        try visited.put(
            entry_point,
            {},
        );

        while (candidates.count() > 0) {
            const current =
                candidates.remove();

            const node =
                &self.nodes.items[
                    current.id
                ];

            if (level >=
                node.levels.items.len)
            {
                continue;
            }

            for (node.levels.items[level].items) |neighbor_id| {
                if (visited.contains(
                    neighbor_id,
                )) {
                    continue;
                }

                try visited.put(
                    neighbor_id,
                    {},
                );

                const neighbor =
                    &self.nodes.items[
                        neighbor_id
                    ];

                const score =
                    vector.cosineSimilarity(
                        query,
                        neighbor.vector,
                    );

                try results.append(.{
                    .id = neighbor_id,
                    .score = score,
                });

                try candidates.add(.{
                    .id = neighbor_id,
                    .score = score,
                });

                std.mem.sort(Candidate, results.items, {}, struct {
                    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                        return a.score > b.score;
                    }
                }.lessThan);

                while (results.items.len > ef) {
                    _ = results.pop();
                }
            }
        }

        return try results.toOwnedSlice();
    }
    pub fn search(
        self: *HNSW,
        query: []const f32,
        allocator: std.mem.Allocator,
        top_k: usize,
    ) ![]Candidate {
        if (self.entry_point == null) {
            return error.EmptyIndex;
        }

        var current =
            self.entry_point.?;

        var level =
            self.max_level;

        while (level > 0) : (level -= 1) {
            const candidates =
                try self.searchLayer(
                    query,
                    current,
                    level,
                    1,
                    allocator,
                );

            defer allocator.free(
                candidates,
            );

            if (candidates.len > 0) {
                current =
                    candidates[0].id;
            }
        }

        const candidates =
            try self.searchLayer(
                query,
                current,
                0,
                self.ef_search,
                allocator,
            );

        if (candidates.len > top_k) {
            const output =
                try allocator.alloc(
                    Candidate,
                    top_k,
                );

            @memcpy(
                output,
                candidates[0..top_k],
            );

            allocator.free(
                candidates,
            );

            return output;
        }

        return candidates;
    }
};
