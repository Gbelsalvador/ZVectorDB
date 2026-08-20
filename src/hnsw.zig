const std = @import("std");
const vector = @import("vector.zig");

pub const Node = struct {
    id: usize,
    vector_offset: usize,
    levels: std.ArrayList(std.ArrayList(usize)),
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

pub fn resultLessThan(
    _: void,
    a: Candidate,
    b: Candidate,
) std.math.Order {
    return std.math.order(
        a.score,
        b.score,
    );
}

pub const CandidateQueue = std.PriorityQueue(Candidate, void, CandidateLessThan);
pub const ResultQueue = std.PriorityQueue(
    Candidate,
    void,
    resultLessThan,
);
pub const HNSW = struct {
    allocator: std.mem.Allocator,
    dimension: usize,
    m: usize,
    ef_construction: usize,
    ef_search: usize,
    nodes: std.ArrayList(Node),
    entry_point: ?usize,
    max_level: usize,
    vectors: std.ArrayList(f32),

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
            .vectors = std.ArrayList(f32).empty,
        };
    }

    pub fn deinit(
        self: *HNSW,
    ) void {
        for (self.nodes.items) |*node| {
            for (node.levels.items) |*Neighbors| {
                Neighbors.deinit(self.allocator);
            }

            node.levels.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.vectors.deinit(self.allocator);
    }

    fn getVector(
        self: *HNSW,
        id: usize,
    ) []const f32 {
        const node =
            &self.nodes.items[id];

        return self.vectors.items[node.vector_offset .. node.vector_offset +
            self.dimension];
    }

    pub fn insert(
        self: *HNSW,
        embedding: []const f32,
        random: std.Random,
    ) !usize {
        if (embedding.len !=
            self.dimension)
        {
            return error.InvalidDimension;
        }

        const id =
            self.nodes.items.len;

        const vector_offset =
            self.vectors.items.len;

        try self.vectors.appendSlice(
            self.allocator,
            embedding,
        );

        const level =
            RandomLevel(random);
        var levels =
            std.ArrayList(
                std.ArrayList(usize),
            ).empty;

        // errdefer {
        //     for (levels.items) |*neighbors| {
        //         neighbors.deinit(self.allocator);
        //     }
        //     levels.deinit(self.allocator);
        // }
        var i: usize = 0;

        while (i <= level) : (i += 1) {
            try levels.append(self.allocator, std.ArrayList(usize).empty);
        }
        try self.nodes.append(self.allocator, .{
            .id = id,
            .vector_offset = vector_offset,
            .levels = levels,
        });

        if (self.entry_point == null) {
            self.entry_point = id;
            self.max_level = level;

            return id;
        }

        var current =
            self.entry_point.?;

        var current_level = self.max_level;

        while (current_level > level) : (current_level -= 1) {
            current = self.greedySearch(embedding, current, current_level, null);
            if (current_level == 0) break;
        }

        // connexion aux niveau pertinents
        while (true) : (current_level -= 1) {
            const layer_candidates = try self.searchLayer(
                embedding,
                current,
                current_level,
                self.ef_construction,
                self.allocator,
                null,
            );
            defer self.allocator.free(layer_candidates);

            const selected = try self.selectNeighbors(
                layer_candidates,
                self.m,
                self.allocator,
            );

            defer self.allocator.free(
                selected,
            );

            for (selected) |neighbor_id| {
                try self.connect(id, neighbor_id, current_level);
                try self.connect(neighbor_id, id, current_level);
                try self.pruneNeighbors(neighbor_id, current_level);
            }

            if (selected.len > 0) current = selected[0];
            if (current_level == 0) break;
        }

        if (level > self.max_level) {
            self.max_level = level;
            self.entry_point = id;
        }

        return id;
    }

    fn pruneNeighbors(
        self: *HNSW,
        node_id: usize,
        level: usize,
    ) !void {
        if (level >= self.nodes.items[node_id].levels.items.len) return;
        const neighbors = &self.nodes.items[node_id].levels.items[level];

        if (neighbors.items.len <= self.m) {
            return;
        }

        var Candidates = std.ArrayList(Candidate).empty;
        defer Candidates.deinit(self.allocator);
        for (neighbors.items) |neighbor_id| {
            const score = vector.cosineSimilarity(
                self.getVector(node_id),
                self.getVector(neighbor_id),
            );

            try Candidates.append(self.allocator, .{
                .id = neighbor_id,
                .score = score,
            });
        }

        std.sort.pdq(
            Candidate,
            Candidates.items,
            {},
            struct {
                pub fn lessThan(
                    _: void,
                    a: Candidate,
                    b: Candidate,
                ) bool {
                    return a.score > b.score;
                }
            }.lessThan,
        );

        neighbors.clearRetainingCapacity();

        for (Candidates.items[0..self.m]) |c| {
            try neighbors.append(self.allocator, c.id);
        }
    }

    fn connect(
        self: *HNSW,
        a: usize,
        b: usize,
        level: usize,
    ) !void {
        if (level < self.nodes.items[a].levels.items.len) {
            try self.nodes.items[a].levels.items[level].append(self.allocator, b);
        }
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
        stats: ?*vector.DistanceStats,
    ) usize {
        var current = entry;

        while (true) {
            // const current_vector = self.getVector(current);

            // const current_score = vector.cosineSimilarity(
            //     query,
            //     current_vector,
            // );
            var best = current;

            var best_score = if (stats) |s| vector.cosineSimilarityCounted(query, self.getVector(current), s) else vector.cosineSimilarity(query, self.getVector(current));

            const node = &self.nodes.items[current];

            if (level >= node.levels.items.len) {
                return current;
            }
            for (node.levels.items[level].items) |neighbor_id| {
                //const neighbor_vector = self.getVector(neighbor_id);

                const score = if (stats) |s| vector.cosineSimilarityCounted(
                    query,
                    self.getVector(neighbor_id),
                    s,
                ) else vector.cosineSimilarity(query, self.getVector(neighbor_id));

                if (score > best_score) {
                    best = neighbor_id;
                    best_score = score;
                }
            }

            if (best == current) return current;
            current = best;
        }
    }

    fn searchLayer(
        self: *HNSW,
        query: []const f32,
        entry_point: usize,
        level: usize,
        ef: usize,
        allocator: std.mem.Allocator,
        stats: ?*vector.DistanceStats,
    ) ![]Candidate {
        var candidates = CandidateQueue{
            .items = &.{},
            .cap = 0,
            .context = {},
        };

        defer candidates.deinit(self.allocator);

        var resultsQ = ResultQueue{
            .items = &.{},
            .cap = 0,
            .context = {},
        };

        defer resultsQ.deinit(self.allocator);

        var visited =
            std.AutoHashMap(
                usize,
                void,
            ).init(allocator);

        defer visited.deinit();

        // var results =
        //     std.ArrayList(Candidate).empty;

        const initial_score = if (stats) |s| vector.cosineSimilarityCounted(query, self.getVector(entry_point), s) else vector.cosineSimilarity(query, self.getVector(entry_point));
        const initial = Candidate{
            .id = entry_point,
            .score = initial_score,
        };

        try candidates.push(self.allocator, initial);
        try resultsQ.push(self.allocator, initial);

        try visited.put(
            entry_point,
            {},
        );

        while (candidates.count() > 0) {
            const best =
                candidates.peek().?;

            if (resultsQ.count() >= ef) {
                const worst = resultsQ.peek().?;

                if (best.score < worst.score) {
                    break;
                }
            }
            const current = candidates.pop().?;
            const node_id = current.id;
            const node = self.nodes.items[node_id];

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

                const neighbor_score = if (stats) |s|
                    vector.cosineSimilarityCounted(
                        query,
                        self.getVector(
                            neighbor_id,
                        ),
                        s,
                    )
                else
                    vector.cosineSimilarity(query, self.getVector(neighbor_id));

                if (resultsQ.count() < ef or neighbor_score > resultsQ.peek().?.score) {
                    const c = Candidate{ .id = neighbor_id, .score = neighbor_score };

                    try candidates.push(self.allocator, c);
                    try resultsQ.push(self.allocator, c);

                    if (resultsQ.count() > ef) {
                        _ = resultsQ.pop();
                    }
                }
            }
        }

        var output = try allocator.alloc(
            Candidate,
            resultsQ.count(),
        );
        var i: usize = 0;

        while (resultsQ.count() > 0) {
            output[i] = resultsQ.pop().?;
            i += 1;
        }

        std.sort.pdq(
            Candidate,
            output,
            {},
            struct {
                fn lessThan(
                    _: void,
                    a: Candidate,
                    b: Candidate,
                ) bool {
                    return a.score > b.score;
                }
            }.lessThan,
        );

        return output;
    }
    fn selectNeighbors(
        self: *HNSW,
        candidates: []const Candidate,
        max_neighbors: usize,
        allocator: std.mem.Allocator,
    ) ![]usize {
        const sorted = try allocator.dupe(
            Candidate,
            candidates,
        );

        defer allocator.free(sorted);

        std.sort.pdq(Candidate, sorted, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.lessThan);

        var selected = std.ArrayList(usize).empty;

        for (sorted) |cand| {
            if (selected.items.len >= max_neighbors) {
                break;
            }
            var accept = true;
            const cand_vec = self.getVector(cand.id);
            // const query = self.nodes.items[query_id].vector;
            // const candidate_vector = self.nodes.items[candidate.id].vector;
            // const candidate_score = vector.cosineSimilarity(
            //     query,
            //     candidate_vector,
            // );

            for (selected.items) |selected_id| {
                const selected_vector = self.getVector(selected_id);

                if (vector.cosineSimilarity(cand_vec, selected_vector) >
                    cand.score)
                {
                    accept = false;
                    break;
                }
            }

            if (accept) {
                try selected.append(
                    self.allocator,
                    cand.id,
                );
            }
        }

        return try selected.toOwnedSlice(self.allocator);
    }

    pub fn search(
        self: *HNSW,
        query: []const f32,
        allocator: std.mem.Allocator,
        top_k: usize,
        stats: *vector.DistanceStats,
    ) ![]Candidate {
        if (self.entry_point == null) {
            return error.EmptyIndex;
        }

        var current =
            self.entry_point.?;

        var level =
            self.max_level;

        while (level > 0) : (level -= 1) {
            current = self.greedySearch(query, current, level, stats);
        }
        const candidates =
            try self.searchLayer(
                query,
                current,
                0,
                self.ef_search,
                allocator,
                null,
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

    fn shouldSelect(
        self: *HNSW,
        query_id: usize,
        Candidate_id: usize,
        selected: []const usize,
    ) bool {
        const query = self.nodes.items[query_id].vector;

        const candidate = self.nodes.items[Candidate_id].vector;

        const candidate_score = vector.cosineSimilarity(
            query,
            candidate,
        );

        for (selected) |selected_id| {
            const selected_vector = self.nodes.items[selected_id].vector;
            const similarity = vector.cosineSimilarity(
                candidate,
                selected_vector,
            );
            if (similarity > candidate_score) {
                return false;
            }
        }

        return true;
    }
};
