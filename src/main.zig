const std = @import("std");
const builtin = @import("builtin");
const InvertedIndex = @import("inverted_index.zig").InvertedIndex;
const SearchEngine = @import("search_engine.zig").SearchEngine;
const VectorIndex = @import("vector_index.zig").vectorindex;
const HNSW = @import("hnsw.zig").HNSW;
const quantize = @import("quantifization.zig").quantize;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const TrainingDataset = @import("training_dataset.zig").TrainingDataset;
const NegativeSampler = @import("negative_sampler.zig").NegativeSampler;
const Word2vec = @import("word2vec.zig").Word2vec;

extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;

const ConsoleCodePages = struct { input: u32, output: u32 };

const Document = struct {
    content: []u8,
};

pub fn main(init: std.process.Init) !void {
    const original_code_pages = enableWindowsUtf8Console();
    defer restoreConsoleCodePages(original_code_pages);
    const allocator = init.gpa;
    var index = InvertedIndex.init(allocator);
    defer index.deinit();
    var search_engine = SearchEngine.init(allocator, &index);
    var vector_index = VectorIndex.init(allocator, 3);
    defer vector_index.deinit();
    var documents = std.ArrayList(Document).empty;
    defer {
        for (documents.items) |doc| allocator.free(doc.content);
        documents.deinit(allocator);
    }

    printBanner();
    var input_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buffer);
    while (true) {
        std.debug.print("zvectordb> ", .{});
        // takeDelimiter consomme aussi le '\n', contrairement à
        // takeDelimiterExclusive, et retourne null à la fin de l'entrée.
        const maybe_line = try reader.interface.takeDelimiter('\n');
        const line = maybe_line orelse break;
        const command = std.mem.trim(u8, line, " \t\r");
        if (command.len == 0) continue;
        if (std.mem.eql(u8, command, "quit") or std.mem.eql(u8, command, "exit")) break;
        if (std.mem.eql(u8, command, "help")) {
            printHelp();
        } else if (std.mem.eql(u8, command, "stats")) {
            std.debug.print("Documents: {d} | termes indexés: {d} | longueur moyenne: {d:.2} | vecteurs: {d} x {d}\n", .{
                index.total_documents,
                index.total_terms,
                index.averageDocumentLength(),
                vector_index.count,
                vector_index.dimension,
            });
        } else if (std.mem.eql(u8, command, "index")) {
            index.print();
        } else if (std.mem.startsWith(u8, command, "search-and ")) {
            var terms = std.mem.tokenizeAny(u8, command[11..], " \t");
            const left = terms.next() orelse {
                std.debug.print("Usage: search-and <mot1> <mot2>\n", .{});
                continue;
            };
            const right = terms.next() orelse {
                std.debug.print("Usage: search-and <mot1> <mot2>\n", .{});
                continue;
            };
            const matches = try index.searchAnd(left, right);
            defer allocator.free(matches);
            if (matches.len == 0) std.debug.print("Aucun document ne contient les deux termes.\n", .{});
            for (matches) |id| std.debug.print("[{d}] {s}\n", .{ id, documents.items[id].content });
        } else if (std.mem.startsWith(u8, command, "dimension ")) {
            if (vector_index.count != 0) {
                std.debug.print("Dimension verrouillée après la première insertion.\n", .{});
                continue;
            }
            const dimension = std.fmt.parseInt(usize, std.mem.trim(u8, command[9..], " \t"), 10) catch {
                std.debug.print("Usage: dimension <entier positif>\n", .{});
                continue;
            };
            if (dimension == 0) continue;
            vector_index.dimension = dimension;
            std.debug.print("Dimension vectorielle: {d}\n", .{dimension});
        } else if (std.mem.startsWith(u8, command, "vadd ")) {
            const values = parseVector(allocator, command[5..]) catch {
                std.debug.print("Vecteur CSV invalide; dimension attendue: {d}.\n", .{vector_index.dimension});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                std.debug.print("Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            const id = try vector_index.add(values);
            std.debug.print("Vecteur {d} ajouté.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "vsearch ")) {
            const values = parseVector(allocator, command[8..]) catch {
                std.debug.print("Usage: vsearch <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                std.debug.print("Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            const results = try vector_index.search(values, allocator, 5);
            defer allocator.free(results);
            if (results.len == 0) std.debug.print("Index vectoriel vide.\n", .{});
            for (results) |result| std.debug.print("[{d}] similarité cosinus {d:.5}\n", .{ result.id, result.score });
        } else if (std.mem.startsWith(u8, command, "hsearch ")) {
            const values = parseVector(allocator, command[8..]) catch {
                std.debug.print("Usage: hsearch <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                std.debug.print("Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            if (vector_index.count == 0) {
                std.debug.print("Index vectoriel vide.\n", .{});
                continue;
            }
            var random_state = std.Random.DefaultPrng.init(42);
            var hnsw = HNSW.init(allocator, vector_index.dimension, 16, 64, 32);
            defer hnsw.deinit();
            const converted = try allocator.alloc(f32, vector_index.dimension);
            defer allocator.free(converted);
            for (0..vector_index.count) |id| {
                for (vector_index.get(id), 0..) |value, i| converted[i] = @floatCast(value);
                _ = try hnsw.insert(converted, random_state.random());
            }
            for (values, 0..) |value, i| converted[i] = @floatCast(value);
            var distance_stats = @import("vector.zig").DistanceStats{};
            const results = try hnsw.search(converted, allocator, 5, &distance_stats);
            defer allocator.free(results);
            for (results) |result| std.debug.print("[{d}] similarité cosinus {d:.5}\n", .{ result.id, result.score });
            std.debug.print("Comparaisons: {d}; HNSW est reconstruit à chaque requête.\n", .{distance_stats.comparisons});
        } else if (std.mem.startsWith(u8, command, "quantize ")) {
            const values = parseVector(allocator, command[9..]) catch {
                std.debug.print("Usage: quantize <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            const f32_values = try allocator.alloc(f32, values.len);
            defer allocator.free(f32_values);
            for (values, 0..) |value, i| f32_values[i] = @floatCast(value);
            const quantized = try quantize(allocator, f32_values);
            defer allocator.free(quantized.values);
            std.debug.print("INT8 scale={d:.6}: ", .{quantized.scale});
            for (quantized.values, 0..) |value, i| std.debug.print("{s}{d}", .{ if (i == 0) "" else ",", value });
            std.debug.print("\n", .{});
        } else if (std.mem.startsWith(u8, command, "train ")) {
            var arguments = std.mem.tokenizeAny(u8, command[6..], " \t");
            const word = arguments.next() orelse {
                std.debug.print("Usage: train <mot> [epochs]\n", .{});
                continue;
            };
            const epochs = if (arguments.next()) |raw|
                (std.fmt.parseInt(usize, raw, 10) catch 100)
            else
                100;
            if (documents.items.len == 0) {
                std.debug.print("Ajoutez d'abord des documents avec 'add'.\n", .{});
                continue;
            }
            try trainAndShowSimilar(allocator, documents.items, word, epochs);
        } else if (std.mem.eql(u8, command, "list")) {
            if (documents.items.len == 0) std.debug.print("Aucun document. Ajoutez-en avec: add <texte>\n", .{});
            for (documents.items, 0..) |doc, id| std.debug.print("[{d}] {s}\n", .{ id, doc.content });
        } else if (std.mem.startsWith(u8, command, "add ")) {
            const content = std.mem.trim(u8, command[4..], " \t\r");
            if (content.len == 0) {
                std.debug.print("Usage: add <texte du document>\n", .{});
                continue;
            }
            const owned = try allocator.dupe(u8, content);
            errdefer allocator.free(owned);
            const id = documents.items.len;
            const tokens = try search_engine.tokenizer.tokenize(content);
            defer search_engine.tokenizer.freeTokens(tokens);
            try index.addDocument(id, tokens.len);
            for (tokens) |token| try index.add(token, id);
            try documents.append(allocator, .{ .content = owned });
            std.debug.print("Document {d} ajouté ({d} termes).\n", .{ id, tokens.len });
        } else if (std.mem.startsWith(u8, command, "search ")) {
            const query = std.mem.trim(u8, command[7..], " \t\r");
            if (query.len == 0) {
                std.debug.print("Usage: search <requête>\n", .{});
                continue;
            }
            const results = try search_engine.search(query);
            defer allocator.free(results);
            if (results.len == 0) {
                std.debug.print("Aucun résultat pour « {s} ».\n", .{query});
            } else {
                for (results) |result| std.debug.print("[{d}] score {d:.4} — {s}\n", .{
                    result.document_id,
                    result.score,
                    documents.items[result.document_id].content,
                });
            }
        } else {
            std.debug.print("Commande inconnue. Tapez 'help'.\n", .{});
        }
    }
    std.debug.print("À bientôt.\n", .{});
}

fn enableWindowsUtf8Console() ConsoleCodePages {
    if (comptime builtin.os.tag == .windows) {
        // Le CLI émet et lit de l'UTF-8. Sans code page 65001, la console
        // Windows interprète ces octets dans la page OEM active (souvent 437).
        const original = ConsoleCodePages{
            .input = GetConsoleCP(),
            .output = GetConsoleOutputCP(),
        };
        _ = SetConsoleOutputCP(65001);
        _ = SetConsoleCP(65001);
        return original;
    }
    return .{ .input = 0, .output = 0 };
}

fn printBanner() void {
    std.debug.print(
        \\
        \\ ZZZZZZ  V     V EEEEE CCCCC TTTTT OOOOO RRRR  DDDD  BBBB
        \\     ZZ  V     V E     C       T   O   O R   R D   D B   B
        \\   ZZ    V     V EEEE  C       T   O   O RRRR  D   D BBBB
        \\ ZZ       V   V  E     C       T   O   O R R   D   D B   B
        \\ ZZZZZZ    V V   EEEEE CCCCC   T   OOOOO R  RR DDDD  BBBB
        \\
        \\              BASE DE DONNEES VECTORIELLE
        \\                 BM25 | HNSW | WORD2VEC | INT8
        \\
        \\ Tapez 'help' pour les commandes. 'quit' pour quitter.
        \\
    , .{});
}

fn restoreConsoleCodePages(original: ConsoleCodePages) void {
    if (comptime builtin.os.tag == .windows) {
        if (original.output != 0) _ = SetConsoleOutputCP(original.output);
        if (original.input != 0) _ = SetConsoleCP(original.input);
    }
}

fn printHelp() void {
    std.debug.print(
        \\Commandes disponibles:
        \\  add <texte>     Indexer un document en mémoire
        \\  search <texte>  Chercher avec le classement BM25
        \\  search-and <a> <b> Intersection de deux termes
        \\  index           Afficher l'index lexical et ses postings
        \\  list            Afficher les documents
        \\  stats           Afficher les statistiques de l'index
        \\  dimension <n>   Définir la dimension avant ajout de vecteurs
        \\  vadd <csv>      Ajouter un vecteur, ex: vadd 1,0,0
        \\  vsearch <csv>   Recherche exacte top 5 par cosinus
        \\  hsearch <csv>   Recherche top 5 HNSW (reconstruit par requête)
        \\  quantize <csv>  Quantifier un vecteur en INT8
        \\  train <mot> [n] Entraîner Word2Vec sur les documents et voir les voisins
        \\  help            Afficher cette aide
        \\  quit / exit     Quitter
        \\
    , .{});
}

fn parseVector(allocator: std.mem.Allocator, text: []const u8) ![]f64 {
    var values = std.ArrayList(f64).empty;
    errdefer values.deinit(allocator);
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |part| {
        const value = try std.fmt.parseFloat(f64, std.mem.trim(u8, part, " \t"));
        try values.append(allocator, value);
    }
    if (values.items.len == 0) return error.EmptyVector;
    return values.toOwnedSlice(allocator);
}

fn trainAndShowSimilar(
    allocator: std.mem.Allocator,
    documents: []const Document,
    query_word: []const u8,
    epochs: usize,
) !void {
    const tokenizer = @import("tokenizer.zig").Tokenizer.init(allocator);
    var vocabulary = Vocabulary.init(allocator);
    defer vocabulary.deinit();
    for (documents) |doc| {
        const tokens = try tokenizer.tokenize(doc.content);
        defer tokenizer.freeTokens(tokens);
        for (tokens) |token| _ = try vocabulary.add(token);
    }
    if (vocabulary.size() < 2) {
        std.debug.print("Word2Vec exige au moins deux mots distincts.\n", .{});
        return;
    }
    const query_id = vocabulary.getId(query_word) orelse {
        std.debug.print("Mot absent du vocabulaire: {s}\n", .{query_word});
        return;
    };
    var dataset = TrainingDataset.init(allocator);
    defer dataset.deinit();
    for (documents) |doc| {
        const tokens = try tokenizer.tokenize(doc.content);
        defer tokenizer.freeTokens(tokens);
        try dataset.buildFromTokens(&vocabulary, tokens, 2);
    }
    if (dataset.len() == 0) {
        std.debug.print("Corpus trop court pour construire des paires de contexte.\n", .{});
        return;
    }
    var sampler = try NegativeSampler.init(allocator, vocabulary.frequencies.items);
    defer sampler.deinit();
    var model = try Word2vec.init(allocator, vocabulary.size(), 32);
    defer model.deinit();
    var random_state = std.Random.DefaultPrng.init(42);
    const random = random_state.random();
    model.randomize(random);
    const passes = @max(epochs, 1);
    for (0..passes) |_| {
        dataset.shuffle(random);
        for (dataset.pairs.items) |pair| {
            model.zeroGradients();
            _ = model.trainPair(random, &sampler, pair.context, pair.target, 5);
            model.updataBatch(0.025, 1);
        }
    }
    const similar = try model.mostSimilar(query_id, allocator, 5);
    defer allocator.free(similar);
    std.debug.print("Voisins Word2Vec de '{s}' après {d} époques:\n", .{ query_word, passes });
    for (similar) |item| std.debug.print("  {s}: {d:.5}\n", .{ vocabulary.getWord(item.id).?, item.score });
}
