const std = @import("std");
pub const Posting = struct { document_id: usize, frequency: usize };

pub const InvertedIndex = struct {
    allocator: std.mem.Allocator,
    index: std.StringHashMap(std.ArrayList(Posting)),
    document_lengts: std.AutoHashMap(usize, usize),
    total_documents: usize,
    total_terms: usize,

    pub fn init(allocator: std.mem.Allocator) InvertedIndex {
        return .{
            .allocator = allocator,
            .index = std.StringHashMap(std.ArrayList(Posting)).init(allocator),
            .document_lengts = std.AutoHashMap(usize, usize).init(allocator),
            .total_documents = 0,
            .total_terms = 0,
        };
    }

    pub fn deinit(self: *InvertedIndex) void {
        var iterator = self.index.iterator();

        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator); // En 0.16, ArrayList.deinit prend l'allocateur
        }
        self.index.deinit(); // StringHashMap.deinit ne prend pas d'argument
        self.document_lengts.deinit();
    }

    pub fn add(
        self: *InvertedIndex,
        token: []const u8,
        document_id: usize,
    ) !void {
        if (self.index.getPtr(token)) |postings_list| {
            for (postings_list.items) |*posting| {
                if (posting.document_id == document_id) {
                    posting.frequency += 1;
                    return;
                }
            }
            try postings_list.append(self.allocator, .{
                .document_id = document_id,
                .frequency = 1,
            });

            return;
        }

        const owned_token = try self.allocator.dupe(u8, token);

        var postings_list = std.ArrayList(Posting).empty;

        errdefer {
            self.allocator.free(owned_token);
            postings_list.deinit(self.allocator);
        }

        try postings_list.append(self.allocator, .{
            .document_id = document_id,
            .frequency = 1,
        });

        try self.index.put(
            owned_token,
            postings_list,
        );
    }

    pub fn addDocument(
        self: *InvertedIndex,
        document_id: usize,
        total_terms: usize,
    ) !void {
        try self.document_lengts.put(
            document_id,
            total_terms,
        );

        self.total_documents += 1;
        self.total_terms += total_terms;
    }

    pub fn documentFrequency(
        self: *InvertedIndex,
        token: []const u8,
    ) usize {
        if (self.index.get(token)) |postings| {
            return postings.items.len;
        }

        return 0;
    }

    pub fn documentLength(
        self: *InvertedIndex,
        document_id: usize,
    ) usize {
        return self.document_lengts.get(
            document_id,
        ) orelse 0;
    }

    pub fn averageDocumentLength(
        self: *InvertedIndex,
    ) f64 {
        if (self.total_documents == 0) {
            return 0.0;
        }

        return @as(
            f64,
            @floatFromInt(self.total_terms),
        ) / @as(
            f64,
            @floatFromInt(self.total_documents),
        );
    }

    pub fn search(
        self: *const InvertedIndex,
        token: []const u8,
    ) ?[]const Posting {
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

    pub fn intersect(self: *const InvertedIndex, left: []const Posting, right: []const Posting) ![]usize {
        var result = std.ArrayList(usize).empty;
        errdefer result.deinit(self.allocator);
        var i: usize = 0;
        var j: usize = 0;

        while (i < left.len and j < right.len) {
            const left_doc = left[i].document_id;
            const right_doc = right[j].document_id;
            if (left_doc == right_doc) {
                try result.append(self.allocator, left_doc);
                i += 1;
                j += 1;
            } else if (left_doc < right_doc) {
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

        // pltutot que d'allouer une tranche vide on retourne une tranche
        //constante pour plus de perfomance et eviter de fuite de memoire

        const empty_postings: []const Posting = &.{};

        const left = self.search(left_token) orelse empty_postings;
        const right = self.search(right_token) orelse empty_postings;

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
            for (entry.value_ptr.items, 0..) |posting, i| {
                if (i > 0) {
                    std.debug.print(", ", .{});
                }

                std.debug.print(
                    "Doc:{d}(Freq:{d})",
                    .{ posting.document_id, posting.frequency },
                );
            }
            std.debug.print("\n", .{});
        }
    }
};
