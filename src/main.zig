const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const trainingDataset = @import("training_dataset.zig").TrainingDataset;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var tokenizer = Tokenizer.init(allocator);
    var vocabulary = Vocabulary.init(allocator);
    defer vocabulary.deinit();

    const sentences = [_][]const u8{
        "le chat mange",
        "le chien mange",
        "le chat dort",
    };

    for (sentences) |sentence| {
        const tokens = try tokenizer.tokenize(
            sentence,
        );

        defer tokenizer.freeTokens(
            tokens,
        );

        for (tokens) |token| {
            _ = try vocabulary.add(
                token,
            );
        }
    }

    std.debug.print(
        "\n==== VOCABULARY ====\n",
        .{},
    );

    var id: usize = 0;

    while (id < vocabulary.size()) : (id += 1) {
        const word = vocabulary.getWord(id).?;

        std.debug.print(
            "{d} -- {s}\n",
            .{ id, word },
        );
    }

    var dataset = trainingDataset.init(allocator);

    defer dataset.deinit();

    for (sentences) |sentence| {
        const tokens = try tokenizer.tokenize(
            sentence,
        );

        defer tokenizer.freeTokens(
            tokens,
        );

        try dataset.buildFromTokens(
            &vocabulary,
            tokens,
            1,
        );
    }

    std.debug.print(
        "\n=== TRAINING DATASET ===\n",
        .{},
    );

    for (dataset.pairs.items) |pair| {
        const context = vocabulary.getWord(
            pair.context,
        ).?;

        const target = vocabulary.getWord(
            pair.target,
        ).?;

        std.debug.print(
            "{s} --- {s}\n",
            .{
                context,
                target,
            },
        );
    }
}
