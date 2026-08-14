const std = @import("std");

pub const InvertedIndex = struct {
    allocator: std.mem.Allocator,
    index: std.StringHashMap(std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator) InvertedIndex {
        return .{
            .allocator = allocator,
            .index = std.StringHashMap(std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *InvertedIndex) void {
        var iterator = self.index.iterator();

        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator); // En 0.16, ArrayList.deinit prend l'allocateur
        }
        self.index.deinit(); // StringHashMap.deinit ne prend pas d'argument
    }

    pub fn add(
        self: *InvertedIndex,
        token: []const u8,
        document_id: usize,
    ) !void {
        if (self.index.getPtr(token)) |document_ids| {
            if (!contains(document_ids.items, document_id)) {
                try document_ids.append(self.allocator, document_id);
            }
            return;
        }

        const owned_token = try self.allocator.dupe(u8, token);

        var document_ids = std.ArrayList(usize).empty;

        errdefer {
            self.allocator.free(owned_token);
            document_ids.deinit(self.allocator);
        }

        try document_ids.append(self.allocator, document_id);

        try self.index.put(
            owned_token,
            document_ids,
        );
    }

    pub fn search(
        self: *const InvertedIndex,
        token: []const u8,
    ) ?[]const usize {
        if (self.index.get(token)) |list| {
            return list.items;
        }
        return null;
    }

    fn contains(
        values: []const usize,
        value: usize,
    ) bool {
        for (values) |item| {
            if (item == value) {
                return true;
            }
        }
        return false;
    }

    pub fn intersect(self: *const InvertedIndex, left: []const usize, right: []const usize) ![]usize {
        var result = std.ArrayList(usize).empty;
        errdefer result.deinit(self.allocator);
        var i: usize = 0;
        var j: usize = 0;

        while (i < left.len and j < right.len) {
            if (left[i] == right[j]) {
                try result.append(self.allocator, left[i]);
                i += 1;
                j += 1;
            } else if (left[i] < right[j]) {
                i += 1;
            } else {
                j += 1;
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn searchAnd(
        self: *const InvertedIndex,
        left_token: []const u8,
        right_token: []const u8,
    ) ![]usize {
        const left = self.search(left_token) orelse {
            return self.allocator.alloc(usize, 0);
        };

        const right = self.search(right_token) orelse {
            return self.allocator.alloc(usize, 0);
        };

        return self.intersect(
            left,
            right,
        );
    }

    pub fn print(self: *InvertedIndex) void {
        var iterator = self.index.iterator();

        while (iterator.next()) |entry| {
            std.debug.print(
                "{s} -> ",
                .{entry.key_ptr.*},
            );
            for (entry.value_ptr.items, 0..) |document_id, i| {
                if (i > 0) {
                    std.debug.print(", ", .{});
                }

                std.debug.print(
                    "{d}",
                    .{document_id},
                );
            }
            std.debug.print("\n", .{});
        }
    }
};
