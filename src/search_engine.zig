const std = @import("std");

const Tokenizer = @import("tokenizer.zig").Tokenizer;

const InvertedIndex = @import("inverted_index.zig").InvertedIndex;

const BM25 = @import("bm25.zig").BM25;

const SearchResult = @import("search_result.zig").SearchResult;

pub const SearchEngine = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    index: *InvertedIndex,
    bm25: BM25,

    pub fn init(
        allocator: std.mem.Allocator,
        index: *InvertedIndex,
    ) SearchEngine {
        return .{
            .allocator = allocator,
            .tokenizer = Tokenizer.init(allocator),
            .index = index,
            .bm25 = BM25.init(1.5, 0.75),
        };
    }

    pub fn search(
        self: *SearchEngine,
        query: []const u8,
    ) ![]SearchResult {
        const tokens = try self.tokenizer.tokenize(query);
        defer self.tokenizer.freeTokens(tokens);

        var results = std.AutoHashMap(usize, f64).init(self.allocator);

        defer results.deinit();

        const avgdl = self.index.averageDocumentLength();

        for (tokens) |token| {
            const postings = self.index.search(token) orelse continue;

            const df = postings.len;

            for (postings) |posting| {
                const dl = self.index.documentLength(
                    posting.document_id,
                );

                const score = self.bm25.score(
                    posting.frequency,
                    dl,
                    avgdl,
                    self.index.total_documents,
                    df,
                );

                const current = results.get(
                    posting.document_id,
                ) orelse 0.0;

                try results.put(
                    posting.document_id,
                    current + score,
                );
            }
        }

        var output = std.ArrayList(SearchResult).empty;
        var iterator = results.iterator();

        while (iterator.next()) |entry| {
            try output.append(self.allocator, .{
                .document_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
            });
        }

        std.mem.sort(
            SearchResult,
            output.items,
            {},
            compareResults,
        );

        return output.toOwnedSlice(self.allocator);
    }

    fn compareResults(
        _: void,
        a: SearchResult,
        b: SearchResult,
    ) bool {
        return a.score > b.score;
    }
};
