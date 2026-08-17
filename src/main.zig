const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const trainingDataset = @import("training_dataset.zig").TrainingDataset;
const Word2vec = @import("word2vec.zig").Word2vec;

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

    // Note : Gardez les tokens ou assurez-vous que Vocabulary.add() fait une copie (dupe)
    for (sentences) |sentence| {
        const tokens = try tokenizer.tokenize(sentence);
        defer tokenizer.freeTokens(tokens);

        for (tokens) |token| {
            _ = try vocabulary.add(token);
        }
    }

    std.debug.print("\n==== VOCABULARY ====\n", .{});
    var id: usize = 0;
    while (id < vocabulary.size()) : (id += 1) {
        const word = vocabulary.getWord(id).?;
        std.debug.print("{d} -- {s}\n", .{ id, word });
    }

    var dataset = trainingDataset.init(allocator);
    defer dataset.deinit();

    for (sentences) |sentence| {
        const tokens = try tokenizer.tokenize(sentence);
        defer tokenizer.freeTokens(tokens);

        try dataset.buildFromTokens(&vocabulary, tokens, 1);
    }

    std.debug.print("\n=== TRAINING DATASET ===\n", .{});
    for (dataset.pairs.items) |pair| {
        const context = vocabulary.getWord(pair.context).?;
        const target = vocabulary.getWord(pair.target).?;
        std.debug.print("{s} --- {s}\n", .{ context, target });
    }

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var model = try Word2vec.init(
        allocator,
        vocabulary.size(),
        10,
    );
    defer model.deinit(); // Correction faute d'orthographe (denit -> deinit)

    model.randomize(random);

    // Correction : Utilisation de forward() à la place de loss()
    const loss_val = model.forward(1, 2);

    std.debug.print("loss = {d:.6}\n", .{loss_val});

    for (model.probabilities, 0..) |probability, word_id| {
        const word = vocabulary.getWord(word_id).?; // Utiliser getWord pour afficher le texte du token
        std.debug.print("{s} - {d:.4}\n", .{ word, probability });
    }
}
