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

const GraphHeader = extern struct {
    magic: [8]u8,
    version: u32,
    dimension: u64,
    m: u64,
    ef_construction: u64,
    ef_search: u64,
    node_count: u64,
    entry_point: u64,
    max_level: u64,
    vector_fingerprint: u64,
};

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
    visit_marks: std.ArrayList(usize),
    visit_generation: usize,

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
            .visit_marks = std.ArrayList(usize).empty,
            .visit_generation = 0,
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
        self.visit_marks.deinit(self.allocator);
    }

    pub fn save(self: *const HNSW, io: anytype, path: []const u8, source_vectors: []const f64) !void {
        const header = GraphHeader{
            .magic = .{ 'Z', 'V', 'H', 'N', 'S', 'W', '0', '1' },
            .version = 1,
            .dimension = @intCast(self.dimension),
            .m = @intCast(self.m),
            .ef_construction = @intCast(self.ef_construction),
            .ef_search = @intCast(self.ef_search),
            .node_count = @intCast(self.nodes.items.len),
            .entry_point = if (self.entry_point) |id| @intCast(id) else std.math.maxInt(u64),
            .max_level = @intCast(self.max_level),
            .vector_fingerprint = fingerprintVectors(source_vectors, self.dimension),
        };
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        try writer.interface.writeAll(std.mem.asBytes(&header));
        for (self.nodes.items) |node| {
            const level_count: u64 = @intCast(node.levels.items.len);
            try writer.interface.writeAll(std.mem.asBytes(&level_count));
            for (node.levels.items) |neighbors| {
                const neighbor_count: u64 = @intCast(neighbors.items.len);
                try writer.interface.writeAll(std.mem.asBytes(&neighbor_count));
                for (neighbors.items) |neighbor_id| {
                    const id: u64 = @intCast(neighbor_id);
                    try writer.interface.writeAll(std.mem.asBytes(&id));
                }
            }
        }
        try writer.flush();
        try file.sync(io);
    }

    pub fn load(
        io: anytype,
        allocator: std.mem.Allocator,
        path: []const u8,
        dimension: usize,
        m: usize,
        ef_construction: usize,
        ef_search: usize,
        source_vectors: []const f64,
    ) !HNSW {
        if (dimension == 0 or source_vectors.len % dimension != 0) return error.InvalidGraph;
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        var header: GraphHeader = undefined;
        try reader.interface.readSliceAll(std.mem.asBytes(&header));
        if (!std.mem.eql(u8, &header.magic, "ZVHNSW01")) return error.InvalidGraph;
        if (header.version != 1) return error.UnsupportedGraphVersion;
        if (header.dimension != dimension or header.m != m or
            header.ef_construction != ef_construction or header.ef_search != ef_search)
        {
            return error.StaleGraph;
        }
        if (header.vector_fingerprint != fingerprintVectors(source_vectors, dimension) or
            header.node_count != source_vectors.len / dimension)
        {
            return error.StaleGraph;
        }
        if (header.node_count > std.math.maxInt(usize) or header.max_level > 63) return error.InvalidGraph;

        var graph = HNSW.init(allocator, dimension, m, ef_construction, ef_search);
        errdefer graph.deinit();
        const vector_count = std.math.mul(usize, source_vectors.len / dimension, dimension) catch return error.InvalidGraph;
        try graph.vectors.ensureTotalCapacity(allocator, vector_count);
        for (source_vectors) |value| graph.vectors.appendAssumeCapacity(@floatCast(value));

        const node_count: usize = @intCast(header.node_count);
        try graph.nodes.ensureTotalCapacity(allocator, node_count);
        try graph.visit_marks.ensureTotalCapacity(allocator, node_count);
        for (0..node_count) |id| {
            const levels = try readNodeLevels(&reader, allocator, node_count, m);
            graph.nodes.appendAssumeCapacity(.{
                .id = id,
                .vector_offset = id * dimension,
                .levels = levels,
            });
            graph.visit_marks.appendAssumeCapacity(0);
        }

        if (node_count == 0) {
            if (header.entry_point != std.math.maxInt(u64) or header.max_level != 0) return error.InvalidGraph;
            graph.entry_point = null;
        } else {
            if (header.entry_point >= header.node_count) return error.InvalidGraph;
            const entry_point: usize = @intCast(header.entry_point);
            const max_level: usize = @intCast(header.max_level);
            if (graph.nodes.items[entry_point].levels.items.len <= max_level) return error.InvalidGraph;
            for (graph.nodes.items, 0..) |node, node_id| {
                for (node.levels.items, 0..) |neighbors, level| {
                    for (neighbors.items) |neighbor_id| {
                        if (neighbor_id == node_id or
                            graph.nodes.items[neighbor_id].levels.items.len <= level)
                        {
                            return error.InvalidGraph;
                        }
                    }
                }
            }
            graph.entry_point = entry_point;
            graph.max_level = max_level;
        }
        return graph;
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

        try self.visit_marks.ensureTotalCapacity(self.allocator, id + 1);
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
        self.visit_marks.appendAssumeCapacity(0);

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

        self.visit_generation +%= 1;
        if (self.visit_generation == 0) {
            @memset(self.visit_marks.items, 0);
            self.visit_generation = 1;
        }
        const visit_generation = self.visit_generation;

        // var results =
        //     std.ArrayList(Candidate).empty;

        const initial_score = if (stats) |s| vector.cosineSimilarityCounted(query, self.getVector(entry_point), s) else vector.cosineSimilarity(query, self.getVector(entry_point));
        const initial = Candidate{
            .id = entry_point,
            .score = initial_score,
        };

        try candidates.push(self.allocator, initial);
        try resultsQ.push(self.allocator, initial);

        self.visit_marks.items[entry_point] = visit_generation;

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
                if (self.visit_marks.items[neighbor_id] == visit_generation) {
                    continue;
                }

                self.visit_marks.items[neighbor_id] = visit_generation;

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
                stats,
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

fn fingerprintVectors(vectors: []const f64, dimension: usize) u64 {
    var hash: u64 = 14695981039346656037;
    const dimension_u64: u64 = @intCast(dimension);
    for (std.mem.asBytes(&dimension_u64)) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    for (std.mem.sliceAsBytes(vectors)) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}

fn readNodeLevels(
    reader: anytype,
    allocator: std.mem.Allocator,
    node_count: usize,
    max_neighbors: usize,
) !std.ArrayList(std.ArrayList(usize)) {
    var level_count_raw: u64 = undefined;
    try reader.interface.readSliceAll(std.mem.asBytes(&level_count_raw));
    if (level_count_raw == 0 or level_count_raw > 64) return error.InvalidGraph;
    const level_count: usize = @intCast(level_count_raw);
    var levels = std.ArrayList(std.ArrayList(usize)).empty;
    errdefer {
        for (levels.items) |*neighbors| neighbors.deinit(allocator);
        levels.deinit(allocator);
    }
    try levels.ensureTotalCapacity(allocator, level_count);
    for (0..level_count) |_| {
        var neighbor_count_raw: u64 = undefined;
        try reader.interface.readSliceAll(std.mem.asBytes(&neighbor_count_raw));
        if (neighbor_count_raw > max_neighbors or neighbor_count_raw > node_count) return error.InvalidGraph;
        const neighbor_count: usize = @intCast(neighbor_count_raw);
        var neighbors = std.ArrayList(usize).empty;
        errdefer neighbors.deinit(allocator);
        try neighbors.ensureTotalCapacity(allocator, neighbor_count);
        for (0..neighbor_count) |_| {
            var neighbor_id_raw: u64 = undefined;
            try reader.interface.readSliceAll(std.mem.asBytes(&neighbor_id_raw));
            if (neighbor_id_raw >= node_count) return error.InvalidGraph;
            neighbors.appendAssumeCapacity(@intCast(neighbor_id_raw));
        }
        levels.appendAssumeCapacity(neighbors);
    }
    return levels;
}

test "HNSW graph persists and rejects stale vectors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test.hnsw";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const vectors = [_]f64{
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
        0.7, 0.7, 0,
    };
    var graph = HNSW.init(allocator, 3, 4, 8, 8);
    defer graph.deinit();
    var random_state = std.Random.DefaultPrng.init(42);
    var converted: [3]f32 = undefined;
    for (0..vectors.len / 3) |id| {
        for (0..3) |i| converted[i] = @floatCast(vectors[id * 3 + i]);
        _ = try graph.insert(&converted, random_state.random());
    }
    try graph.save(io, path, &vectors);

    var restored = try HNSW.load(io, allocator, path, 3, 4, 8, 8, &vectors);
    defer restored.deinit();
    try std.testing.expectEqual(graph.nodes.items.len, restored.nodes.items.len);
    try std.testing.expectEqual(graph.entry_point, restored.entry_point);

    const query = [_]f32{ 1, 0, 0 };
    var stats = vector.DistanceStats{};
    const results = try restored.search(&query, allocator, 2, &stats);
    defer allocator.free(results);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(usize, 0), results[0].id);
    try std.testing.expect(stats.comparisons > 0);

    var changed_vectors = vectors;
    changed_vectors[0] = 0.5;
    try std.testing.expectError(
        error.StaleGraph,
        HNSW.load(io, allocator, path, 3, 4, 8, 8, &changed_vectors),
    );
}
