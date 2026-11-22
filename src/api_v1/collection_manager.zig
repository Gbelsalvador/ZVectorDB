const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const constants = @import("constants.zig");
const json = @import("json.zig");

const registry_path = "zvectordb.collections";
const registry_temp_path = "zvectordb.collections.tmp";
const Entry = struct { engine: *Engine };

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Manager {
        var manager = Manager{ .allocator = allocator, .io = io, .entries = std.StringHashMap(Entry).init(allocator) };
        errdefer manager.deinit();

        const registry = std.Io.Dir.cwd().readFileAlloc(io, registry_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (registry) |bytes| {
            defer allocator.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |raw| {
                const name = std.mem.trim(u8, raw, " \r\t");
                if (name.len == 0) continue;
                if (manager.entries.contains(name)) return error.DuplicateCollectionInRegistry;
                try manager.openEntry(name);
            }
        } else {
            try manager.openEntry(constants.CollectionName);
            try manager.persistRegistry();
        }
        return manager;
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.engine.deinit();
            self.allocator.destroy(entry.value_ptr.engine);
        }
        self.entries.deinit();
    }

    pub fn get(self: *Manager, name: []const u8) ?*Engine {
        const entry = self.entries.get(name) orelse return null;
        return entry.engine;
    }

    pub fn create(self: *Manager, name: []const u8) !void {
        if (!isValidName(name)) return error.InvalidCollectionName;
        if (self.entries.contains(name)) return error.CollectionAlreadyExists;
        try self.openEntry(name);
        self.persistRegistry() catch |err| {
            const removed = self.entries.fetchRemove(name).?;
            self.destroyEntry(removed.key, removed.value);
            deleteCollectionFiles(self.io, self.allocator, name);
            return err;
        };
    }

    pub fn delete(self: *Manager, name: []const u8) !bool {
        if (!isValidName(name)) return false;
        const paths = try storagePaths(self.allocator, name);
        defer self.allocator.free(paths.database);
        defer self.allocator.free(paths.hnsw);
        const removed = self.entries.fetchRemove(name) orelse return false;
        self.persistRegistry() catch |err| {
            try self.entries.put(removed.key, removed.value);
            return err;
        };
        self.destroyEntry(removed.key, removed.value);
        std.Io.Dir.cwd().deleteFile(self.io, paths.database) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        std.Io.Dir.cwd().deleteFile(self.io, paths.hnsw) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return true;
    }

    pub fn listJson(self: *Manager) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"collections\":[");
        var iterator = self.entries.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try output.writer.writeAll(",");
            first = false;
            const encoded = try json.jsonString(self.allocator, entry.key_ptr.*);
            defer self.allocator.free(encoded);
            try output.writer.print("{{\"name\":{s}}}", .{encoded});
        }
        try output.writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    fn openEntry(self: *Manager, name: []const u8) !void {
        if (!isValidName(name)) return error.InvalidCollectionName;
        const paths = try storagePaths(self.allocator, name);
        defer self.allocator.free(paths.database);
        defer self.allocator.free(paths.hnsw);
        const engine = try self.allocator.create(Engine);
        engine.* = Engine.init(self.allocator);
        engine.setStoragePaths(paths.database, paths.hnsw) catch |err| {
            engine.deinit();
            self.allocator.destroy(engine);
            return err;
        };
        engine.open(self.io) catch |err| {
            // Engine.open deinitializes its owned resources on failure.
            self.allocator.destroy(engine);
            return err;
        };
        var transferred = false;
        errdefer if (!transferred) {
            engine.deinit();
            self.allocator.destroy(engine);
        };
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.entries.put(key, .{ .engine = engine });
        transferred = true;
    }

    fn destroyEntry(self: *Manager, name: []const u8, entry: Entry) void {
        self.allocator.free(name);
        entry.engine.deinit();
        self.allocator.destroy(entry.engine);
    }

    fn persistRegistry(self: *Manager) !void {
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, registry_temp_path, .{});
            defer file.close(self.io);
            var buffer: [1024]u8 = undefined;
            var writer = file.writer(self.io, &buffer);
            var iterator = self.entries.iterator();
            while (iterator.next()) |entry| {
                try writer.interface.writeAll(entry.key_ptr.*);
                try writer.interface.writeAll("\n");
            }
            try writer.interface.flush();
            try file.sync(self.io);
        }
        try std.Io.Dir.cwd().rename(registry_temp_path, self.io, std.Io.Dir.cwd(), registry_path);
    }
};

const Paths = struct { database: []u8, hnsw: []u8 };

fn storagePaths(allocator: std.mem.Allocator, name: []const u8) !Paths {
    if (std.mem.eql(u8, name, constants.CollectionName)) {
        const database = try allocator.dupe(u8, "zvectordb.db");
        errdefer allocator.free(database);
        const hnsw = try allocator.dupe(u8, "zvectordb.hnsw");
        return .{ .database = database, .hnsw = hnsw };
    }
    const database = try std.fmt.allocPrint(allocator, "zvectordb.collection.{s}.db", .{name});
    errdefer allocator.free(database);
    const hnsw = try std.fmt.allocPrint(allocator, "zvectordb.collection.{s}.hnsw", .{name});
    return .{ .database = database, .hnsw = hnsw };
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }
    return true;
}

fn deleteCollectionFiles(io: std.Io, allocator: std.mem.Allocator, name: []const u8) void {
    const paths = storagePaths(allocator, name) catch return;
    defer allocator.free(paths.database);
    defer allocator.free(paths.hnsw);
    std.Io.Dir.cwd().deleteFile(io, paths.database) catch {};
    std.Io.Dir.cwd().deleteFile(io, paths.hnsw) catch {};
}
