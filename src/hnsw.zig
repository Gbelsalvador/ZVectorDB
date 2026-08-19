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
            embedding,
        );

        const level =
            RandomLevel(random);
        var levels =
            std.ArrayList(
                std.ArrayList(usize),
            ).empty;

        errdefer {
            for (levels.items) |*neighbors| {
                neighbors.deinit(self.allocator);
            }
            levels.deinit(self.allocator);
        }
        var i: usize = 0;

        while (i <= level) : (i += 1) {
            try levels.append(std.ArrayList(usize).empty);
        }
        try self.nodes.append(.{
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
    }

    fn pruneNeighbors(
        self: *HNSW,
        node_id: usize,
        level: usize,
    ) !void {
        const neighbors =
            self.nodes.items[
                node_id
            ].levels.items[
                level
            ].items;

        if (neighbors.len <= self.m) {
            return;
        }

        var Candidates = std.ArrayList(Candidate).empty;

        for (neighbors) |neighbor_id| {
            const score = vector.cosineSimilarity(
                self.getVector(node_id),
                self.getVector(neighbor_id),
            );

            try Candidates.appendAssumeCapacity(.{
                .id = neighbor_id,
                .score = score,
            });
        }

        std.sort.pdq(
            Candidate,
            Candidates.items,
            {},
            struct {
                fn lessthan(
                    _: void,
                    a: Candidate,
                    b: Candidate,
                ) bool {
                    return a.score > b.score;
                }
            }.lessThan,
        );
        while (Candidates.items.len > self.m) {
            _ = Candidates.pop();
        }
        var new_neighbors = std.ArrayList(usize).empty;
        for (Candidates.items) |candidate| {
            try new_neighbors.append(
                candidate.id,
            );
        }
        self.nodes.items[node_id].levels.items[level].deinit();
        self.nodes.items[node_id].levels.items[level] = new_neighbors;
    }

    fn connect(
        self: *HNSW,
        a: usize,
        b: usize,
        level: usize,
    ) !void {
        try self.nodes.items[a].levels.items[level].append(b);
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
        var current = entry;

        while (true) {
            const current_vector = self.getVector(current);

            const current_score = vector.cosineSimilarity(
                query,
                current_vector,
            );
            var best = current;

            var best_score = current_score;

            const node = &self.nodes.items[current];

            if (level >= node.levels.items.len) {
                return current;
            }
            for (node.levels.items[level].items) |neighbor_id| {
                const neighbor_vector = self.getVector(neighbor_id);

                const score = vector.cosineSimilarity(
                    query,
                    neighbor_vector,
                );

                if (score > best_score) {
                    best = neighbor_id;
                    best_score = score;
                }
            }

            if (best == current) {
                return current;
            }

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
    ) ![]Candidate {
        var candidates = CandidateQueue.init(allocator, {});

        defer candidates.deinit();

        var visited =
            std.AutoHashMap(
                usize,
                void,
            ).init(allocator);

        defer visited.deinit(self.allocator);

        var results =
            std.ArrayList(Candidate)
                .init(allocator);

        defer results.deinit(self.allocator);

        const entry =
            &self.nodes.items[
                entry_point
            ];

        const score =
            vector.cosineSimilarity(
                query,
                self.getVector(
                    entry_point,
                ),
            );

        const initial = Candidate{
            .id = entry_point,
            .score = score,
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

                const neighbor_score =
                    vector.cosineSimilarity(
                        query,
                        self.getVector(
                            neighbor_id,
                        ),
                    );

                try candidates.append(.{
                    .id = neighbor_id,
                    .score = neighbor_score,
                });

                try results.add(.{
                    .id = neighbor_id,
                    .score = neighbor_score,
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
    }

    fn selectNeighbors(
        self: *HNSW,
        query_id: usize,
        candidates: []const Candidate,
        max_neighbors: usize,
        allocator: std.mem.Allocator,
    ) ![]usize {
        var sorted = try allocator.dupe(
            Candidate,
            candidates,
        );

        defer allocator.free(sorted);

        std.mem.sort(Candidate, sorted, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.lessThan);

        var selected = std.ArrayList(usize).empty;
        defer selected.deinit(self.allocator);

        for (sorted) |candidate| {
            if (selected.items.len >= max_neighbors) {
                break;
            }

            var accept = true;

            const query = self.nodes.items[query_id].vector;
            const candidate_vector = self.nodes.items[candidate.id].vector;
            const candidate_score = vector.cosineSimilarity(
                query,
                candidate_vector,
            );

            for (selected.items) |selected_id| {
                const selected_vector =
                    self.nodes.items[
                        selected_id
                    ].vector;

                const similarity =
                    vector.cosineSimilarity(
                        candidate_vector,
                        selected_vector,
                    );

                if (similarity >
                    candidate_score)
                {
                    accept = false;
                    break;
                }
            }

            if (accept) {
                try selected.append(
                    candidate.id,
                );
            }
        }

        return try selected.toOwnedSlice();
    }
};
