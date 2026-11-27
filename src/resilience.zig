const std = @import("std");
const Engine = @import("engine.zig").Engine;
const Wal = @import("wal.zig").wal;

const database_path = "zv_resilience.db";
const graph_path = "zv_resilience.hnsw";
const document_count = 250;
var failures: usize = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    defer clean(io);
    std.debug.print("ZvectorDB RAG resilience run\n", .{});

    try scenarioRestart(io, allocator);
    try scenarioWalRecovery(io, allocator);
    try scenarioCorruptGraph(io, allocator);
    try scenarioCorruptDatabase(io, allocator);
    try scenarioInvalidRequest(io, allocator);
    try scenarioLoad(io, allocator);
    try scenarioConcurrentWrites(io, allocator);

    report("Power loss during write", .not_simulated, "requires a VM or block-device fault injector");
    report("Process kill mid-write", .not_simulated, "this runner does not spawn and terminate a child process");
    report("Disk full", .not_simulated, "requires a quota-limited filesystem");
    report("Memory exhaustion", .not_simulated, "allocator exhaustion is not equivalent to system-wide OOM");
    std.debug.print("\nSimulate power loss, process kill and disk full in an isolated VM before production use.\n", .{});
    if (failures != 0) return error.ResilienceFailures;
}

const Status = enum { pass, fail, not_simulated };

fn report(name: []const u8, status: Status, detail: []const u8) void {
    if (status == .fail) failures += 1;
    const label = switch (status) { .pass => "PASS", .fail => "FAIL", .not_simulated => "NOT SIMULATED" };
    std.debug.print("[{s}] {s}: {s}\n", .{ label, name, detail });
}

fn clean(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, database_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, graph_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.wal") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.recover.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.snapshot.0.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.snapshot.1.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.snapshot.0.recover.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.snapshot.1.recover.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.CURRENT") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.CURRENT.tmp") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.snapshot.0") catch {};
    std.Io.Dir.cwd().deleteFile(io, "zv_resilience.db.snapshot.1") catch {};
}

fn newEngine(io: std.Io, allocator: std.mem.Allocator) !Engine {
    var engine = Engine.init(allocator);
    try engine.setStoragePaths(database_path, graph_path);
    try engine.open(io);
    return engine;
}

fn scenarioRestart(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    {
        var engine = try newEngine(io, allocator);
        defer engine.deinit();
        for (0..16) |i| {
            const text = try std.fmt.allocPrint(allocator, "durable restart record {d}", .{i});
            defer allocator.free(text);
            _ = try engine.addDocument(io, text);
        }
    }
    var recovered = try newEngine(io, allocator);
    defer recovered.deinit();
    if (recovered.documents.items.len != 16) {
    report("Restart persistence", .fail, "document count changed after reopen");
        return;
    }
    report("Restart persistence", .pass, "all 16 acknowledged documents survived a clean process restart");
}

fn scenarioCorruptDatabase(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    {
        var engine = try newEngine(io, allocator);
        defer engine.deinit();
        _ = try engine.addDocument(io, "database corruption detection marker");
    }
    var corrupt = try std.Io.Dir.cwd().createFile(io, "zv_resilience.db.snapshot.0", .{});
    var buffer: [32]u8 = undefined;
    var writer = corrupt.writer(io, &buffer);
    try writer.interface.writeAll("not a ZvectorDB database");
    try writer.flush();
    corrupt.close(io);

    var engine = Engine.init(allocator);
    try engine.setStoragePaths(database_path, graph_path);
    engine.open(io) catch |err| {
        report("Corrupted database", .pass, @errorName(err));
        return;
    };
    defer engine.deinit();
    report("Corrupted database", .fail, "corrupt primary database opened without an error");
}

fn scenarioCorruptGraph(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    {
        var engine = try newEngine(io, allocator);
        defer engine.deinit();
        _ = try engine.addVector(io, &.{ 1, 0, 0 });
    }
    var corrupt = try std.Io.Dir.cwd().createFile(io, graph_path, .{});
    var buffer: [32]u8 = undefined;
    var writer = corrupt.writer(io, &buffer);
    try writer.interface.writeAll("deliberately corrupted graph");
    try writer.flush();
    corrupt.close(io);

    var recovered = try newEngine(io, allocator);
    defer recovered.deinit();
    if (recovered.vector_index.count != 1) {
        report("Corrupted index file", .fail, "vector data was not recovered from the database");
        return;
    }
    report("Corrupted index file", .pass, "corrupt HNSW graph was rebuilt from the vector database");
}

fn scenarioWalRecovery(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    {
        var engine = try newEngine(io, allocator);
        defer engine.deinit();
        _ = try engine.addDocument(io, "WAL crash recovery marker");
    }
    const snapshot = try readWholeFile(io, allocator, "zv_resilience.db.snapshot.0");
    defer allocator.free(snapshot);
    var journal = try Wal.init(io, "zv_resilience.db.wal");
    _ = try journal.append(io, .update, snapshot);
    journal.deinit(io);

    var damaged = try std.Io.Dir.cwd().createFile(io, "zv_resilience.db.snapshot.0", .{});
    damaged.close(io);
    var recovered = try newEngine(io, allocator);
    defer recovered.deinit();
    if (recovered.documents.items.len != 1 or
        !std.mem.eql(u8, recovered.documents.items[0].content, "WAL crash recovery marker"))
    {
        report("WAL recovery", .fail, "latest checksummed WAL snapshot was not restored");
        return;
    }
    var compacted_wal = try std.Io.Dir.cwd().openFile(io, "zv_resilience.db.wal", .{ .mode = .read_only });
    defer compacted_wal.close(io);
    if ((try compacted_wal.stat(io)).size != 0) {
        report("WAL recovery", .fail, "recovered snapshot was not compacted from the journal");
        return;
    }
    report("WAL recovery", .pass, "checksummed WAL snapshot restored the database after its file was damaged");
}

fn readWholeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stats = try file.stat(io);
    const bytes = try allocator.alloc(u8, @intCast(stats.size));
    errdefer allocator.free(bytes);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

fn scenarioInvalidRequest(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    var engine = try newEngine(io, allocator);
    defer engine.deinit();
    if (engine.addVector(io, &.{ 1, 2 })) |_| {
        report("Invalid request", .fail, "accepted a vector with the wrong dimension");
        return;
    } else |err| {
        if (err != error.InvalidDimension) return err;
    }
    if (engine.vector_index.count != 0) {
        report("Invalid request", .fail, "invalid vector mutated the live index");
        return;
    }
    report("Invalid request", .pass, "wrong-dimension vector rejected without mutating state");
}

fn scenarioLoad(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    var engine = try newEngine(io, allocator);
    defer engine.deinit();
    for (0..document_count) |i| {
        const text = try std.fmt.allocPrint(allocator, "load corpus document {d} retrieval database", .{i});
        defer allocator.free(text);
        _ = try engine.addDocument(io, text);
    }
    if (engine.documents.items.len != document_count) {
        report("Heavy load", .fail, "in-memory document count differs from accepted writes");
        return;
    }
    report("Heavy load", .pass, "250 sequential document writes completed");
}

const Race = struct { engine: *Engine, io: std.Io, worker_id: usize, failed: *u8 };

fn raceWriter(race: Race) void {
    for (0..20) |i| {
        const text = std.fmt.allocPrint(race.engine.allocator, "parallel writer {d} record {d}", .{ race.worker_id, i }) catch {
            @atomicStore(u8, race.failed, 1, .monotonic);
            return;
        };
        defer race.engine.allocator.free(text);
        _ = race.engine.addDocument(race.io, text) catch {
            @atomicStore(u8, race.failed, 1, .monotonic);
            return;
        };
    }
}

fn scenarioConcurrentWrites(io: std.Io, allocator: std.mem.Allocator) !void {
    clean(io);
    var engine = try newEngine(io, allocator);
    defer engine.deinit();
    var failed: u8 = 0;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, raceWriter, .{Race{
        .engine = &engine,
        .io = io,
        .worker_id = i,
        .failed = &failed,
    }});
    for (threads) |thread| thread.join();
    if (@atomicLoad(u8, &failed, .monotonic) != 0 or engine.documents.items.len != 80) {
        report("Race condition", .fail, "concurrent writes failed or lost acknowledged records");
        return;
    }
    report("Race condition", .pass, "4 writers completed 80 serialized, persisted writes");
}
