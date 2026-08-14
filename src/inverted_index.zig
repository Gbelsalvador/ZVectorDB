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
            entry.value_ptr.deinit(self.allocator);
        }
        self.index.deinit();
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

    pub fn print(self: *InvertedIndex) void {
        var iterator = self.index.iterator();

        while (iterator.next()) |entry| {
            std.debug.print(
                "{s} ->",
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
