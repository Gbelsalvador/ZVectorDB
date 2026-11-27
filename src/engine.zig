const std = @import("std");
const storage = @import("storage.zig");
const wal_mod = @import("wal.zig");
const InvertedIndex = @import("inverted_index.zig").InvertedIndex;
const SearchEngine = @import("search_engine.zig").SearchEngine;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const VectorIndex = @import("vector_index.zig").vectorindex;
const HNSW = @import("hnsw.zig").HNSW;
const query_engine = @import("query_engine.zig");
const SearchResult = @import("search_result.zig").SearchResult;
const VectorSearchResult = @import("vector_index.zig").SearchResult;
const vector_math = @import("vector.zig");
const RwLock = @import("concurrency.zig").RwLock;

const Wal = wal_mod.wal;
const Operation = wal_mod.Operation;
const Manifest = storage.Manifest;

const SnapshotPointer = struct {
    magic: [8]u8,
    slot: u8,
    reserved: [7]u8,
    manifest: Manifest,
};

pub const WalEngine = struct {
    allocator: std.mem.Allocator,
    manifest: Manifest,
    wal: Wal,
    vectors: std.ArrayList(f32),
    snapshot_slot: u8 = 0,

    var current_instance: ?*WalEngine = null;

    pub fn open(io: anytype, allocator: std.mem.Allocator, dir_path: []const u8) !WalEngine {
        _ = dir_path;

        var snapshot_slot: u8 = 0;
        const current = readSnapshotPointer(io) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const manifest = if (current) |pointer| blk: {
            if (pointer.slot > 1) return error.InvalidSnapshotPointer;
            snapshot_slot = pointer.slot;
            break :blk pointer.manifest;
        } else storage.readManifest(io, "vectors.manifest") catch |err| switch (err) {
            error.FileNotFound => Manifest{
                .magic = .{ 'Z', 'V', 'E', 'C', 'T', 'O', 'R' },
                .version = 1,
                .dimension = 3,
                .vector_count = 0,
                .last_sequence = 0,
                .metric = 0,
                .quantization = 0,
                .reserved = .{0} ** 6,
            },
            else => return err,
        };

        const journal_file = std.Io.Dir.cwd().openFile(io, "vectors.wal", .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(io, "vectors.wal", .{}),
            else => return err,
        };
        journal_file.close(io);
        // var create_f = try std.Io.Dir.cwd().createFile(io, "vectors.wal", .{ .exclusive = false });
        // create_f.close(io);
        const journal = try Wal.init(io, "vectors.wal");

        var engine = WalEngine{
            .allocator = allocator,
            .manifest = manifest,
            .wal = journal,
            .vectors = std.ArrayList(f32).empty,
            .snapshot_slot = snapshot_slot,
        };

        if (current != null) {
            try engine.loadSnapshotFrom(io, snapshotPath(snapshot_slot));
        } else engine.loadSnapshotFrom(io, "vectors.bin") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        try engine.recover(io);

        return engine;
    }

    pub fn close(self: *WalEngine, io: anytype) void {
        self.wal.deinit(io);
        self.vectors.deinit(self.allocator);
    }

    pub fn insert(self: *WalEngine, io: anytype, vector: []const f32) !void {
        if (vector.len != self.manifest.dimension) return error.InvalidDimension;

        const bytes = std.mem.sliceAsBytes(vector);
        const seq = try self.wal.append(io, .insert, bytes);

        try self.applyInsert(vector);

        self.manifest.last_sequence = seq;
        self.manifest.vector_count = self.vectors.items.len / self.manifest.dimension;
    }

    fn applyInsert(self: *WalEngine, vector: []const f32) !void {
        try self.vectors.appendSlice(self.allocator, vector);
    }

    pub fn contains(self: *WalEngine, vector: []const f32) bool {
        if (self.vectors.items.len == 0) return false;
        var i: usize = 0;
        while (i <= self.vectors.items.len - vector.len) : (i += vector.len) {
            if (std.mem.eql(f32, self.vectors.items[i .. i + vector.len], vector)) {
                return true;
            }
        }
        return false;
    }

    fn loadSnapshotFrom(self: *WalEngine, io: anytype, path: []const u8) !void {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var r = file.reader(io, read_buf[0..]);

        while (true) {
            var val: f32 = undefined;
            const amt = try r.interface.readSliceShort(std.mem.asBytes(&val));
            if (amt == 0) break;
            try self.vectors.append(self.allocator, val);
        }
    }

    pub fn recover(self: *WalEngine, io: anytype) !void {
        current_instance = self;
        defer current_instance = null;

        const greatest = try Wal.replayAfter(io, self.allocator, "vectors.wal", self.manifest.last_sequence, WalEngine.replayCallback);
        self.wal.next_sequence = @max(self.manifest.last_sequence, greatest) +| 1;
    }

    fn replayCallback(operation: Operation, payload: []const u8, sequence: u64) anyerror!void {
        const self = current_instance orelse return error.NoEngineContext;

        switch (operation) {
            .insert => {
                const float_count = payload.len / @sizeOf(f32);

                const temp_vector = try self.allocator.alloc(f32, float_count);
                defer self.allocator.free(temp_vector);

                @memcpy(std.mem.sliceAsBytes(temp_vector), payload);
                try self.applyInsert(temp_vector);
                self.manifest.last_sequence = sequence;
                self.manifest.vector_count = self.vectors.items.len / self.manifest.dimension;
            },
            else => {},
        }
    }

    /// Writes the inactive snapshot, then atomically switches CURRENT. Only
    /// after the switch is durable do we discard WAL entries covered by it.
    pub fn compact(self: *WalEngine, io: anytype) !void {
        const next_slot: u8 = 1 - self.snapshot_slot;
        const snapshot_path = snapshotPath(next_slot);
        var file = try std.Io.Dir.cwd().createFile(io, snapshot_path, .{});
        try storage.writeVectors(io, &file, self.vectors.items);
        try file.sync(io);
        file.close(io);

        const pointer = SnapshotPointer{
            .magic = .{ 'Z', 'V', 'C', 'U', 'R', 'R', 'E', 'N' },
            .slot = next_slot,
            .reserved = .{0} ** 7,
            .manifest = self.manifest,
        };
        var current_tmp = try std.Io.Dir.cwd().createFile(io, "CURRENT.tmp", .{});
        var current_buf: [256]u8 = undefined;
        var writer = current_tmp.writer(io, &current_buf);
        try writer.interface.writeAll(std.mem.asBytes(&pointer));
        try writer.flush();
        try current_tmp.sync(io);
        current_tmp.close(io);
        try std.Io.Dir.cwd().rename(io, "CURRENT.tmp", "CURRENT");

        self.snapshot_slot = next_slot;

        var truncate_wal = try std.Io.Dir.cwd().createFile(io, "vectors.wal", .{ .exclusive = false });
        try truncate_wal.sync(io);
        truncate_wal.close(io);
        self.wal.next_sequence = self.manifest.last_sequence +| 1;
    }

    pub fn checkpoint(self: *WalEngine, io: anytype) !void {
        return self.compact(io);
    }
};

fn snapshotPath(slot: u8) []const u8 {
    return if (slot == 0) "vectors.snapshot.0.bin" else "vectors.snapshot.1.bin";
}

fn readSnapshotPointer(io: anytype) !?SnapshotPointer {
    var file = try std.Io.Dir.cwd().openFile(io, "CURRENT", .{ .mode = .read_only });
    defer file.close(io);
    var pointer: SnapshotPointer = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(std.mem.asBytes(&pointer));
    if (!std.mem.eql(u8, &pointer.magic, "ZVCURREN")) return error.InvalidSnapshotPointer;
    return pointer;
}

pub const Document = struct {
    content: []u8,
};

pub const AddDocumentResult = struct {
    id: usize,
    term_count: usize,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Shared reads and exclusive mutations prevent readers from observing partial index updates.
    index_lock: RwLock = .{},
    index: InvertedIndex,
    vector_index: VectorIndex,
    hnsw: HNSW,
    documents: std.ArrayList(Document),
    restored: bool = false,
    database_file: []const u8 = "zvectordb.db",
    hnsw_file: []const u8 = "zvectordb.hnsw",
    owned_database_file: ?[]u8 = null,
    owned_hnsw_file: ?[]u8 = null,

    const hnsw_m = 16;
    const hnsw_ef_construction = 64;
    const hnsw_ef_search = 32;

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .index = InvertedIndex.init(allocator),
            .vector_index = VectorIndex.init(allocator, 3),
            .hnsw = HNSW.init(allocator, 3, hnsw_m, hnsw_ef_construction, hnsw_ef_search),
            .documents = .empty,
        };
    }

    pub fn open(self: *Engine, io: anytype) !void {
        errdefer self.deinit();
        if (storage.readDatabase(io, self.allocator, self.database_file)) |loaded_database| {
            var database = loaded_database;
            defer database.deinit(self.allocator);
            self.restored = true;
            self.vector_index.dimension = database.dimension;
            for (database.documents) |content| {
                const owned = try self.allocator.dupe(u8, content);
                errdefer self.allocator.free(owned);
                const id = self.documents.items.len;
                _ = try self.indexDocument(id, content);
                try self.documents.append(self.allocator, .{ .content = owned });
            }
            try self.vector_index.vectors.appendSlice(self.allocator, database.vectors);
            self.vector_index.count = database.vectors.len / database.dimension;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const loaded_hnsw = try loadOrBuildHnsw(io, self.allocator, &self.vector_index, self.hnsw_file);
        self.hnsw.deinit();
        self.hnsw = loaded_hnsw;
    }

    pub fn deinit(self: *Engine) void {
        self.hnsw.deinit();
        self.vector_index.deinit();
        self.index.deinit();
        for (self.documents.items) |document| self.allocator.free(document.content);
        self.documents.deinit(self.allocator);
        if (self.owned_database_file) |path| self.allocator.free(path);
        if (self.owned_hnsw_file) |path| self.allocator.free(path);
    }

    pub fn setStoragePaths(self: *Engine, database_file: []const u8, hnsw_file: []const u8) !void {
        const owned_database = try self.allocator.dupe(u8, database_file);
        errdefer self.allocator.free(owned_database);
        const owned_hnsw = try self.allocator.dupe(u8, hnsw_file);
        if (self.owned_database_file) |path| self.allocator.free(path);
        if (self.owned_hnsw_file) |path| self.allocator.free(path);
        self.owned_database_file = owned_database;
        self.owned_hnsw_file = owned_hnsw;
        self.database_file = owned_database;
        self.hnsw_file = owned_hnsw;
    }

    pub fn addDocument(self: *Engine, io: anytype, content: []const u8) !AddDocumentResult {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        const owned = try self.allocator.dupe(u8, content);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(owned);
        const id = self.documents.items.len;
        const term_count = try self.indexDocument(id, content);
        try self.documents.append(self.allocator, .{ .content = owned });
        transferred = true;
        try self.persistDatabase(io);
        return .{ .id = id, .term_count = term_count };
    }

    pub fn updateDocument(self: *Engine, io: anytype, id: usize, content: []const u8) !void {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        if (id >= self.documents.items.len) return error.DocumentNotFound;
        const owned = try self.allocator.dupe(u8, content);
        self.allocator.free(self.documents.items[id].content);
        self.documents.items[id].content = owned;
        try self.rebuildTextIndex();
        try self.persistDatabase(io);
    }

    pub fn deleteDocument(self: *Engine, io: anytype, id: usize) !void {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        if (id >= self.documents.items.len) return error.DocumentNotFound;

        // Document and vector IDs share the same positional namespace for
        // hybrid queries. Removing a document shifts every later document ID,
        // so remove the vector at the same position as well when one exists.
        // If there is no vector at this position, the remaining vectors still
        // form a prefix and their IDs remain aligned with the remaining docs.
        const removed_vector = id < self.vector_index.count;
        if (removed_vector) {
            const start = id * self.vector_index.dimension;
            const end = start + self.vector_index.dimension;
            const remaining = self.vector_index.vectors.items.len - self.vector_index.dimension;
            std.mem.copyForwards(
                f64,
                self.vector_index.vectors.items[start..remaining],
                self.vector_index.vectors.items[end..],
            );
            self.vector_index.vectors.items.len = remaining;
            self.vector_index.count -= 1;
            try self.rebuildHnsw();
        }

        const removed = self.documents.orderedRemove(id);
        self.allocator.free(removed.content);
        try self.rebuildTextIndex();
        if (removed_vector) {
            try self.persistVectorData(io);
        } else {
            try self.persistDatabase(io);
        }
    }

    pub fn setDimension(self: *Engine, io: anytype, dimension: usize) !void {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        if (dimension == 0) return error.InvalidDimension;
        if (self.vector_index.count != 0) return error.DimensionLocked;
        self.vector_index.dimension = dimension;
        self.hnsw.deinit();
        self.hnsw = HNSW.init(self.allocator, dimension, hnsw_m, hnsw_ef_construction, hnsw_ef_search);
        try self.hnsw.save(io, self.hnsw_file, self.vector_index.vectors.items);
    }

    pub fn addVector(self: *Engine, io: anytype, values: []const f64) !usize {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        const id = try self.vector_index.add(values);
        try self.insertHnswVector(values, id);
        try self.persistVectorData(io);
        return id;
    }

    pub fn updateVector(self: *Engine, io: anytype, id: usize, values: []const f64) !void {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        if (id >= self.vector_index.count) return error.VectorNotFound;
        if (values.len != self.vector_index.dimension) return error.InvalidDimension;
        const start = id * self.vector_index.dimension;
        @memcpy(self.vector_index.vectors.items[start .. start + self.vector_index.dimension], values);
        try self.rebuildHnsw();
        try self.persistVectorData(io);
    }

    pub fn deleteVector(self: *Engine, io: anytype, id: usize) !void {
        self.index_lock.lock();
        defer self.index_lock.unlock();
        if (id >= self.vector_index.count) return error.VectorNotFound;
        const start = id * self.vector_index.dimension;
        const end = start + self.vector_index.dimension;
        const remaining = self.vector_index.vectors.items.len - self.vector_index.dimension;
        std.mem.copyForwards(f64, self.vector_index.vectors.items[start..remaining], self.vector_index.vectors.items[end..]);
        self.vector_index.vectors.items.len = remaining;
        self.vector_index.count -= 1;
        try self.rebuildHnsw();
        try self.persistVectorData(io);
    }

    pub fn searchText(self: *Engine, query: []const u8) ![]SearchResult {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        var search = SearchEngine.init(self.allocator, &self.index);
        return search.search(query);
    }

    pub fn searchAnd(self: *Engine, left: []const u8, right: []const u8) ![]usize {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        return self.index.searchAnd(left, right);
    }

    pub fn searchExact(self: *Engine, query: []const f64, top_k: usize) ![]VectorSearchResult {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        return self.vector_index.search(query, self.allocator, top_k);
    }

    pub fn searchHnsw(
        self: *Engine,
        query: []const f64,
        top_k: usize,
        stats: *vector_math.DistanceStats,
    ) ![]@import("hnsw.zig").Candidate {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        if (query.len != self.vector_index.dimension) return error.InvalidDimension;
        const converted = try self.allocator.alloc(f32, query.len);
        defer self.allocator.free(converted);
        for (query, 0..) |value, i| converted[i] = @floatCast(value);
        return self.hnsw.search(converted, self.allocator, top_k, stats);
    }

    pub fn planQuery(self: *Engine, text_query: []const u8, has_vector_query: bool) query_engine.Plan {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        return query_engine.createPlan(text_query, has_vector_query, self.documents.items.len, self.vector_index.count);
    }

    /// Return owned bytes so a response cannot retain a pointer into a document
    /// that a concurrent update or delete frees.
    pub fn documentContentDup(self: *Engine, id: usize) !?[]u8 {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        if (id >= self.documents.items.len) return null;
        return try self.allocator.dupe(u8, self.documents.items[id].content);
    }

    pub fn executeQuery(
        self: *Engine,
        text_query: []const u8,
        vector_query: ?[]const f64,
        plan: query_engine.Plan,
    ) ![]query_engine.Result {
        if (!plan.aligned_ids) return error.UnalignedIdentifiers;
        if (plan.use_vector and vector_query == null) return error.MissingVectorQuery;
        var text_results: []SearchResult = &.{};
        if (plan.use_bm25) text_results = try self.searchText(text_query);
        defer if (plan.use_bm25) self.allocator.free(text_results);

        var vector_results: []@import("hnsw.zig").Candidate = &.{};
        if (plan.use_vector) {
            var stats = vector_math.DistanceStats{};
            vector_results = try self.searchHnsw(vector_query.?, plan.vector_candidates, &stats);
        }
        defer if (plan.use_vector) self.allocator.free(vector_results);
        const ranked = try query_engine.fuseAndRerank(self.allocator, text_results, vector_results, plan);
        defer self.allocator.free(ranked);
        const result_count = @min(query_engine.ResultLimit, ranked.len);
        const results = try self.allocator.alloc(query_engine.Result, result_count);
        @memcpy(results, ranked[0..result_count]);
        return results;
    }

    fn indexDocument(self: *Engine, id: usize, content: []const u8) !usize {
        const tokenizer = Tokenizer.init(self.allocator);
        const tokens = try tokenizer.tokenize(content);
        defer tokenizer.freeTokens(tokens);
        try self.index.addDocument(id, tokens.len);
        for (tokens) |token| try self.index.add(token, id);
        return tokens.len;
    }

    fn rebuildTextIndex(self: *Engine) !void {
        self.index.deinit();
        self.index = InvertedIndex.init(self.allocator);
        for (self.documents.items, 0..) |document, id| _ = try self.indexDocument(id, document.content);
    }

    fn persistDatabase(self: *Engine, io: anytype) !void {
        const contents = try self.allocator.alloc([]const u8, self.documents.items.len);
        defer self.allocator.free(contents);
        for (self.documents.items, 0..) |document, i| contents[i] = document.content;
        try storage.writeDatabase(io, self.database_file, contents, self.vector_index.vectors.items, self.vector_index.dimension);
    }

    fn persistVectorData(self: *Engine, io: anytype) !void {
        try self.persistDatabase(io);
        try self.hnsw.save(io, self.hnsw_file, self.vector_index.vectors.items);
    }

    fn rebuildHnsw(self: *Engine) !void {
        self.hnsw.deinit();
        self.hnsw = HNSW.init(self.allocator, self.vector_index.dimension, hnsw_m, hnsw_ef_construction, hnsw_ef_search);
        try self.populateHnsw();
    }

    fn populateHnsw(self: *Engine) !void {
        const converted = try self.allocator.alloc(f32, self.vector_index.dimension);
        defer self.allocator.free(converted);
        var random_state = std.Random.DefaultPrng.init(42);
        for (0..self.vector_index.count) |id| {
            const start = id * self.vector_index.dimension;
            const stored = self.vector_index.vectors.items[start .. start + self.vector_index.dimension];
            for (stored, 0..) |value, i| converted[i] = @floatCast(value);
            _ = try self.hnsw.insert(converted, random_state.random());
        }
    }

    fn insertHnswVector(self: *Engine, values: []const f64, id: usize) !void {
        const converted = try self.allocator.alloc(f32, values.len);
        defer self.allocator.free(converted);
        for (values, 0..) |value, i| converted[i] = @floatCast(value);
        var random_state = std.Random.DefaultPrng.init(@intCast(id + 42));
        _ = try self.hnsw.insert(converted, random_state.random());
    }
};

fn loadOrBuildHnsw(io: anytype, allocator: std.mem.Allocator, vector_index: *const VectorIndex, path: []const u8) !HNSW {
    return HNSW.load(
        io,
        allocator,
        path,
        vector_index.dimension,
        Engine.hnsw_m,
        Engine.hnsw_ef_construction,
        Engine.hnsw_ef_search,
        vector_index.vectors.items,
    ) catch |err| switch (err) {
        error.FileNotFound, error.StaleGraph, error.InvalidGraph, error.UnsupportedGraphVersion, error.EndOfStream => {
            var graph = HNSW.init(allocator, vector_index.dimension, Engine.hnsw_m, Engine.hnsw_ef_construction, Engine.hnsw_ef_search);
            errdefer graph.deinit();
            const converted = try allocator.alloc(f32, vector_index.dimension);
            defer allocator.free(converted);
            var random_state = std.Random.DefaultPrng.init(42);
            for (0..vector_index.count) |id| {
                const start = id * vector_index.dimension;
                const stored = vector_index.vectors.items[start .. start + vector_index.dimension];
                for (stored, 0..) |value, i| converted[i] = @floatCast(value);
                _ = try graph.insert(converted, random_state.random());
            }
            try graph.save(io, path, vector_index.vectors.items);
            return graph;
        },
        else => return err,
    };
}

// --- ZONE DE TEST : VALIDATION DU RECOVERY APRÈS UN CRASH COMPATIBLE ZIG 0.16 ---

test "engine recovery after crash" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // Nettoyage de sécurité avant l'exécution du test
    std.Io.Dir.cwd().deleteFile(io, "vectors.manifest") catch {};
    std.Io.Dir.cwd().deleteFile(io, "vectors.wal") catch {};
    std.Io.Dir.cwd().deleteFile(io, "vectors.bin") catch {};
    defer {
        std.Io.Dir.cwd().deleteFile(io, "vectors.manifest") catch {};
        std.Io.Dir.cwd().deleteFile(io, "vectors.wal") catch {};
        std.Io.Dir.cwd().deleteFile(io, "vectors.bin") catch {};
    }

    const vector1 = [_]f32{ 1.1, 2.2, 3.3 };
    const vector2 = [_]f32{ 4.4, 5.5, 6.6 };

    // ÉTAPE 1 : Session active d'insertions
    {
        var engine = try WalEngine.open(io, allocator, "test_db");
        defer engine.close(io);

        try engine.insert(io, &vector1);
        try engine.insert(io, &vector2);
    }

    // ÉTAPE 2 : Session de récupération mécanique
    {
        var recovered = try WalEngine.open(io, allocator, "test_db");
        defer recovered.close(io);

        try std.testing.expect(recovered.contains(&vector1));
        try std.testing.expect(recovered.contains(&vector2));
    }
}

test "application engine orchestrates BM25 and HNSW queries" {
    const allocator = std.testing.allocator;
    var engine = Engine.init(allocator);
    defer engine.deinit();

    const documents = [_][]const u8{
        "Zig vector search",
        "database indexing",
    };
    for (documents, 0..) |content, id| {
        const owned = try allocator.dupe(u8, content);
        errdefer allocator.free(owned);
        _ = try engine.indexDocument(id, content);
        try engine.documents.append(allocator, .{ .content = owned });
    }

    const vectors = [_][]const f64{
        &.{ 1, 0, 0 },
        &.{ 0, 1, 0 },
    };
    for (vectors, 0..) |embedding, id| {
        _ = try engine.vector_index.add(embedding);
        try engine.insertHnswVector(embedding, id);
    }

    const plan = engine.planQuery("zig search", true);
    try std.testing.expect(plan.usesBothSources());
    const query = [_]f64{ 1, 0, 0 };
    const results = try engine.executeQuery("zig search", &query, plan);
    defer allocator.free(results);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(usize, 0), results[0].id);
}
