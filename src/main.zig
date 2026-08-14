const std = @import("std");

const Document = @import("document.zig").Document;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const InvertedIndex = @import("inverted_index.zig").InvertedIndex;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    //-----------------------------------------
    // Documents
    //-----------------------------------------

    const documents = [_]Document{
        Document.init(
            1,
            "machine learning avec python",
        ),
        Document.init(
            2,
            "Deep learinig avec pytorch",
        ),
        Document.init(
            1,
            "machine learning et transformers",
        ),
    };

    //----------------------------------------------
    //TOKENIZER
    //-----------------------------------------------

    var tokenizer = Tokenizer.init(allocator);

    //---------------------------------------------
    // INVERTED INDEC
    //----------------------------------------------
    var index = InvertedIndex.init(allocator);
    defer index.deinit();

    //------------------------------
    //indexatio,
    //-----------------------------

    for (documents) |document| {
        const tokens = try tokenizer.tokenize(
            document.content,
        );
        defer tokenizer.freeTokens(tokens);

        for (tokens) |token| {
            try index.add(
                token,
                document.id,
            );
        }
    }

    //--------------------------------------
    //AFFICHAGE DE l'INDEX
    //-------------------------------------

    std.debug.print(
        "\n====== ZDEBUG INVERTED INDEX =============\n\n",
        .{},
    );

    index.print();

    //--------------------------------
    //RECHERCHE
    //---------------------------------

    std.debug.print(
        "\n==== SEARCH ==========\n\n",
        .{},
    );

    const query = "learning";

    if (index.search(query)) |document_ids| {
        std.debug.print(
            "Document contenant '{s}' :",
            .{query},
        );

        for (document_ids, 0..) |document_id, i| {
            if (i > 0) {
                std.debug.print(",", .{});
            }

            std.debug.print(
                "{d}",
                .{document_id},
            );
        }

        std.debug.print("\n", .{});
    } else {
        std.debug.print(
            "aucun document troubé\n",
            .{},
        );
    }
}
