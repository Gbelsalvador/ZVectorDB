const std = @import("std");

const Document = @import("document.zig").Document;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const InvertedIndex = @import("inverted_index.zig").InvertedIndex;
const SearchEngine = @import("search_engine.zig").SearchEngine;
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    //-----------------------------------------
    // Documents
    //-----------------------------------------

    const documents = [_]Document{
        Document.init(1, "machine learning avec python"),
        Document.init(2, "Deep learning avec pytorch"),
        Document.init(3, "machine learning et transformers"),
    };

    //----------------------------------------------
    // TOKENIZER & INDEX
    //-----------------------------------------------

    var tokenizer = Tokenizer.init(allocator);

    var index = InvertedIndex.init(allocator);
    defer index.deinit();

    //------------------------------
    // Indexation
    //-----------------------------

    for (documents) |document| {
        const tokens = try tokenizer.tokenize(document.content);
        defer tokenizer.freeTokens(tokens);
        try index.addDocument(
            document.id,
            tokens.len,
        );
        for (tokens) |token| {
            try index.add(token, document.id);
        }
    }

    //--------------------------------------
    // Affichage de l'Index
    //-------------------------------------

    std.debug.print("\n====== ZDEBUG INVERTED INDEX =============\n\n", .{});
    index.print();

    //--------------------------------
    // Recherche
    //---------------------------------

    std.debug.print("\n==== SEARCH BM25==========\n\n", .{});
    var engine = SearchEngine.init(
        allocator,
        &index,
    );
    const results = try engine.search(
        "machine learning",
    );

    defer allocator.free(results);

    for (results) |result| {
        std.debug.print(
            "document {d} --- score = {d:.4}\n",
            .{
                result.document_id,
                result.score,
            },
        );
    }
    // const query = "learning";

    // if (index.search(query)) |document_ids| {
    //     std.debug.print("Document contenant '{s}' : ", .{query});

    //     for (document_ids, 0..) |document_id, i| {
    //         if (i > 0) {
    //             std.debug.print(", ", .{});
    //         }

    //         std.debug.print("{d}", .{document_id});
    //     }

    //     std.debug.print("\n", .{});
    // } else {
    //     std.debug.print("aucun document trouvé\n", .{});
    // }

    // const results = try index.searchAnd(
    //     "machine",
    //     "learning",
    // );

    // defer allocator.free(results);

    // std.debug.print(
    //     "\nRecherche : machine AND learning\n",
    //     .{},
    // );

    // std.debug.print(
    //     "resultats: ",
    //     .{},
    // );

    // for (results, 0..) |document_id, i| {
    //     if (i > 0) {
    //         std.debug.print(", ", .{});
    //     }

    //     std.debug.print(
    //         "{d}",
    //         .{document_id},
    //     );
    // }

    // std.debug.print("\n", .{});

}
