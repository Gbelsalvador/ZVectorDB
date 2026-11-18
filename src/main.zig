const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage.zig");
const InvertedIndex = @import("inverted_index.zig").InvertedIndex;
const SearchEngine = @import("search_engine.zig").SearchEngine;
const VectorIndex = @import("vector_index.zig").vectorindex;
const HNSW = @import("hnsw.zig").HNSW;
const rrf = @import("rrf.zig");
const quantize = @import("quantifization.zig").quantize;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const TrainingDataset = @import("training_dataset.zig").TrainingDataset;
const NegativeSampler = @import("negative_sampler.zig").NegativeSampler;
const Word2vec = @import("word2vec.zig").Word2vec;
const hnsw_m = 16;
const hnsw_ef_construction = 64;
const hnsw_ef_search = 32;
const hnsw_path = "zvectordb.hnsw";

extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn GetStdHandle(handle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(handle: ?*anyopaque, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(handle: ?*anyopaque, mode: u32) callconv(.winapi) i32;

const ConsoleCodePages = struct {
    input: u32,
    output: u32,
    stderr_handle: ?*anyopaque,
    stderr_mode: ?u32,
};

const ansi = struct {
    const reset = "\x1b[0m";
    const cyan_bold = "\x1b[1;36m";
    const cyan = "\x1b[36m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
};

const std_error_handle: u32 = 0xfffffff4;
const enable_virtual_terminal_processing: u32 = 0x0004;
var colors_enabled = true;

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

    if (storage.readDatabase(init.io, allocator, "zvectordb.db")) |loaded_database| {
        var database = loaded_database;
        defer database.deinit(allocator);
        vector_index.dimension = database.dimension;
        for (database.documents) |content| {
            const owned = try allocator.dupe(u8, content);
            errdefer allocator.free(owned);
            const id = documents.items.len;
            const tokens = try search_engine.tokenizer.tokenize(content);
            defer search_engine.tokenizer.freeTokens(tokens);
            try index.addDocument(id, tokens.len);
            for (tokens) |token| try index.add(token, id);
            try documents.append(allocator, .{ .content = owned });
        }
        try vector_index.vectors.appendSlice(allocator, database.vectors);
        vector_index.count = database.vectors.len / database.dimension;
        printColored(ansi.green, "Base restaurée: {d} documents, {d} vecteurs.\n", .{ documents.items.len, vector_index.count });
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var hnsw = try loadOrBuildHnsw(init.io, allocator, &vector_index);
    defer hnsw.deinit();

    printBanner();
    var input_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buffer);
    while (true) {
        printColored(ansi.cyan_bold, "zvectordb>", .{});
        std.debug.print(" ", .{});
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
            printColored(ansi.cyan, "Documents: {d} | termes indexés: {d} | longueur moyenne: {d:.2} | vecteurs: {d} x {d}\n", .{
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
                printColored(ansi.red, "Usage: search-and <mot1> <mot2>\n", .{});
                continue;
            };
            const right = terms.next() orelse {
                printColored(ansi.red, "Usage: search-and <mot1> <mot2>\n", .{});
                continue;
            };
            const matches = try index.searchAnd(left, right);
            defer allocator.free(matches);
            if (matches.len == 0) printColored(ansi.yellow, "Aucun document ne contient les deux termes.\n", .{});
            for (matches) |id| printColored(ansi.cyan, "[{d}] {s}\n", .{ id, documents.items[id].content });
        } else if (std.mem.startsWith(u8, command, "dimension ")) {
            if (vector_index.count != 0) {
                printColored(ansi.yellow, "Dimension verrouillée après la première insertion.\n", .{});
                continue;
            }
            const dimension = std.fmt.parseInt(usize, std.mem.trim(u8, command[9..], " \t"), 10) catch {
                printColored(ansi.red, "Usage: dimension <entier positif>\n", .{});
                continue;
            };
            if (dimension == 0) continue;
            vector_index.dimension = dimension;
            hnsw.deinit();
            hnsw = HNSW.init(allocator, dimension, hnsw_m, hnsw_ef_construction, hnsw_ef_search);
            try hnsw.save(init.io, hnsw_path, vector_index.vectors.items);
            printColored(ansi.green, "Dimension vectorielle: {d}\n", .{dimension});
        } else if (std.mem.startsWith(u8, command, "vadd ")) {
            const values = parseVector(allocator, command[5..]) catch {
                printColored(ansi.red, "Vecteur CSV invalide; dimension attendue: {d}.\n", .{vector_index.dimension});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            const id = try vector_index.add(values);
            try insertHnswVector(allocator, &hnsw, values, id);
            try persistVectorData(init.io, allocator, documents.items, &vector_index, &hnsw);
            printColored(ansi.green, "Vecteur {d} ajouté.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "vdelete ")) {
            const id = std.fmt.parseInt(usize, std.mem.trim(u8, command[8..], " \t"), 10) catch {
                printColored(ansi.red, "Usage: vdelete <id>\n", .{});
                continue;
            };
            if (id >= vector_index.count) {
                printColored(ansi.yellow, "Vecteur {d} introuvable.\n", .{id});
                continue;
            }
            const start = id * vector_index.dimension;
            const end = start + vector_index.dimension;
            const remaining = vector_index.vectors.items.len - vector_index.dimension;
            std.mem.copyForwards(f64, vector_index.vectors.items[start..remaining], vector_index.vectors.items[end..]);
            vector_index.vectors.items.len = remaining;
            vector_index.count -= 1;
            try rebuildHnsw(allocator, &hnsw, &vector_index);
            try persistVectorData(init.io, allocator, documents.items, &vector_index, &hnsw);
            printColored(ansi.green, "Vecteur {d} supprimé.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "vupdate ")) {
            const arguments = command[8..];
            const separator = std.mem.indexOfAny(u8, arguments, " \t") orelse {
                printColored(ansi.red, "Usage: vupdate <id> <valeur1,valeur2,...>\n", .{});
                continue;
            };
            const id = std.fmt.parseInt(usize, std.mem.trim(u8, arguments[0..separator], " \t"), 10) catch {
                printColored(ansi.red, "Usage: vupdate <id> <valeur1,valeur2,...>\n", .{});
                continue;
            };
            if (id >= vector_index.count) {
                printColored(ansi.yellow, "Vecteur {d} introuvable.\n", .{id});
                continue;
            }
            const values = parseVector(allocator, std.mem.trim(u8, arguments[separator..], " \t")) catch {
                printColored(ansi.red, "Vecteur CSV invalide.\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            const start = id * vector_index.dimension;
            @memcpy(vector_index.vectors.items[start .. start + vector_index.dimension], values);
            try rebuildHnsw(allocator, &hnsw, &vector_index);
            try persistVectorData(init.io, allocator, documents.items, &vector_index, &hnsw);
            printColored(ansi.green, "Vecteur {d} modifié.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "vsearch ")) {
            const values = parseVector(allocator, command[8..]) catch {
                printColored(ansi.red, "Usage: vsearch <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            const results = try vector_index.search(values, allocator, 5);
            defer allocator.free(results);
            if (results.len == 0) printColored(ansi.yellow, "Index vectoriel vide.\n", .{});
            for (results) |result| printColored(ansi.cyan, "[{d}] similarité cosinus {d:.5}\n", .{ result.id, result.score });
        } else if (std.mem.startsWith(u8, command, "hybrid ")) {
            const arguments = command[7..];
            const vector_marker = std.mem.indexOf(u8, arguments, "--vector") orelse {
                printColored(ansi.red, "Usage: hybrid <requête texte> --vector <valeur1,valeur2,...>\n", .{});
                continue;
            };
            const text_query = std.mem.trim(u8, arguments[0..vector_marker], " \t");
            const vector_query_text = std.mem.trim(u8, arguments[vector_marker + "--vector".len ..], " \t");
            if (text_query.len == 0 or vector_query_text.len == 0) {
                printColored(ansi.red, "Usage: hybrid <requête texte> --vector <valeur1,valeur2,...>\n", .{});
                continue;
            }
            if (documents.items.len == 0 or vector_index.count == 0) {
                printColored(ansi.yellow, "La recherche hybride exige des documents et des vecteurs.\n", .{});
                continue;
            }
            if (documents.items.len != vector_index.count) {
                printColored(ansi.yellow, "La recherche hybride exige un vecteur par document, dans le même ordre.\n", .{});
                continue;
            }
            const values = parseVector(allocator, vector_query_text) catch {
                printColored(ansi.red, "Vecteur CSV invalide.\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }

            const text_results = try search_engine.search(text_query);
            defer allocator.free(text_results);
            const converted = try allocator.alloc(f32, vector_index.dimension);
            defer allocator.free(converted);
            for (values, 0..) |value, i| converted[i] = @floatCast(value);
            var distance_stats = @import("vector.zig").DistanceStats{};
            const vector_results = try hnsw.search(converted, allocator, 5, &distance_stats);
            defer allocator.free(vector_results);

            var scores = std.AutoHashMap(u64, f32).init(allocator);
            defer scores.deinit();
            const text_count = @min(text_results.len, 5);
            for (text_results[0..text_count], 0..) |result, rank| {
                try rrf.addRank(&scores, @intCast(result.document_id), rank + 1, 60);
            }
            for (vector_results, 0..) |result, rank| {
                try rrf.addRank(&scores, @intCast(result.id), rank + 1, 60);
            }

            const results = try rrf.computeRRF(allocator, &scores);
            defer allocator.free(results);
            if (results.len == 0) {
                printColored(ansi.yellow, "Aucun résultat hybride.\n", .{});
            } else {
                for (results[0..@min(results.len, 5)]) |result| {
                    const id: usize = @intCast(result.doc_id);
                    printColored(ansi.cyan, "[{d}] score RRF {d:.5} — {s}\n", .{
                        id,
                        result.score,
                        documents.items[id].content,
                    });
                }
            }
        } else if (std.mem.startsWith(u8, command, "hsearch ")) {
            const values = parseVector(allocator, command[8..]) catch {
                printColored(ansi.red, "Usage: hsearch <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ vector_index.dimension, values.len });
                continue;
            }
            if (vector_index.count == 0) {
                printColored(ansi.yellow, "Index vectoriel vide.\n", .{});
                continue;
            }
            const converted = try allocator.alloc(f32, vector_index.dimension);
            defer allocator.free(converted);
            for (values, 0..) |value, i| converted[i] = @floatCast(value);
            var distance_stats = @import("vector.zig").DistanceStats{};
            const results = try hnsw.search(converted, allocator, 5, &distance_stats);
            defer allocator.free(results);
            for (results) |result| printColored(ansi.cyan, "[{d}] similarité cosinus {d:.5}\n", .{ result.id, result.score });
            printColored(ansi.yellow, "Comparaisons: {d}; graphe HNSW persistant.\n", .{distance_stats.comparisons});
        } else if (std.mem.startsWith(u8, command, "quantize ")) {
            const values = parseVector(allocator, command[9..]) catch {
                printColored(ansi.red, "Usage: quantize <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            const f32_values = try allocator.alloc(f32, values.len);
            defer allocator.free(f32_values);
            for (values, 0..) |value, i| f32_values[i] = @floatCast(value);
            const quantized = try quantize(allocator, f32_values);
            defer allocator.free(quantized.values);
            printColored(ansi.cyan, "INT8 scale={d:.6}: ", .{quantized.scale});
            for (quantized.values, 0..) |value, i| std.debug.print("{s}{d}", .{ if (i == 0) "" else ",", value });
            std.debug.print("\n", .{});
        } else if (std.mem.startsWith(u8, command, "train ")) {
            var arguments = std.mem.tokenizeAny(u8, command[6..], " \t");
            const word = arguments.next() orelse {
                printColored(ansi.red, "Usage: train <mot> [epochs]\n", .{});
                continue;
            };
            const epochs = if (arguments.next()) |raw|
                (std.fmt.parseInt(usize, raw, 10) catch 100)
            else
                100;
            if (documents.items.len == 0) {
                printColored(ansi.yellow, "Ajoutez d'abord des documents avec 'add'.\n", .{});
                continue;
            }
            try trainAndShowSimilar(allocator, documents.items, word, epochs);
        } else if (std.mem.eql(u8, command, "list")) {
            if (documents.items.len == 0) printColored(ansi.yellow, "Aucun document. Ajoutez-en avec: add <texte>\n", .{});
            for (documents.items, 0..) |doc, id| printColored(ansi.cyan, "[{d}] {s}\n", .{ id, doc.content });
        } else if (std.mem.startsWith(u8, command, "delete ")) {
            const id = std.fmt.parseInt(usize, std.mem.trim(u8, command[7..], " \t"), 10) catch {
                printColored(ansi.red, "Usage: delete <id>\n", .{});
                continue;
            };
            if (id >= documents.items.len) {
                printColored(ansi.yellow, "Document {d} introuvable.\n", .{id});
                continue;
            }
            const removed = documents.orderedRemove(id);
            allocator.free(removed.content);
            try rebuildTextIndex(allocator, &index, &search_engine, documents.items);
            try persistDatabase(init.io, allocator, documents.items, &vector_index);
            printColored(ansi.green, "Document {d} supprimé.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "update ")) {
            const arguments = command[7..];
            const separator = std.mem.indexOfAny(u8, arguments, " \t") orelse {
                printColored(ansi.red, "Usage: update <id> <nouveau texte>\n", .{});
                continue;
            };
            const id = std.fmt.parseInt(usize, std.mem.trim(u8, arguments[0..separator], " \t"), 10) catch {
                printColored(ansi.red, "Usage: update <id> <nouveau texte>\n", .{});
                continue;
            };
            const content = std.mem.trim(u8, arguments[separator..], " \t");
            if (id >= documents.items.len or content.len == 0) {
                printColored(ansi.yellow, "Document introuvable ou texte vide.\n", .{});
                continue;
            }
            const owned = try allocator.dupe(u8, content);
            allocator.free(documents.items[id].content);
            documents.items[id].content = owned;
            try rebuildTextIndex(allocator, &index, &search_engine, documents.items);
            try persistDatabase(init.io, allocator, documents.items, &vector_index);
            printColored(ansi.green, "Document {d} modifié.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "add ")) {
            const content = std.mem.trim(u8, command[4..], " \t\r");
            if (content.len == 0) {
                printColored(ansi.red, "Usage: add <texte du document>\n", .{});
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
            try persistDatabase(init.io, allocator, documents.items, &vector_index);
            printColored(ansi.green, "Document {d} ajouté ({d} termes).\n", .{ id, tokens.len });
        } else if (std.mem.startsWith(u8, command, "search ")) {
            const query = std.mem.trim(u8, command[7..], " \t\r");
            if (query.len == 0) {
                printColored(ansi.red, "Usage: search <requête>\n", .{});
                continue;
            }
            const results = try search_engine.search(query);
            defer allocator.free(results);
            if (results.len == 0) {
                printColored(ansi.yellow, "Aucun résultat pour « {s} ».\n", .{query});
            } else {
                for (results) |result| printColored(ansi.cyan, "[{d}] score {d:.4} — {s}\n", .{
                    result.document_id,
                    result.score,
                    documents.items[result.document_id].content,
                });
            }
        } else {
            printColored(ansi.red, "Commande inconnue. Tapez 'help'.\n", .{});
        }
    }
    printColored(ansi.green, "À bientôt.\n", .{});
}

fn enableWindowsUtf8Console() ConsoleCodePages {
    if (comptime builtin.os.tag == .windows) {
        // Le CLI émet et lit de l'UTF-8. Sans code page 65001, la console
        // Windows interprète ces octets dans la page OEM active (souvent 437).
        const original = ConsoleCodePages{
            .input = GetConsoleCP(),
            .output = GetConsoleOutputCP(),
            .stderr_handle = null,
            .stderr_mode = null,
        };
        _ = SetConsoleOutputCP(65001);
        _ = SetConsoleCP(65001);
        colors_enabled = false;
        if (GetStdHandle(std_error_handle)) |handle| {
            var mode: u32 = 0;
            if (GetConsoleMode(handle, &mode) != 0 and
                SetConsoleMode(handle, mode | enable_virtual_terminal_processing) != 0)
            {
                colors_enabled = true;
                return .{
                    .input = original.input,
                    .output = original.output,
                    .stderr_handle = handle,
                    .stderr_mode = mode,
                };
            }
        }
        return original;
    }
    return .{ .input = 0, .output = 0, .stderr_handle = null, .stderr_mode = null };
}

fn printBanner() void {
    printColored(ansi.cyan_bold,
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
        if (original.stderr_handle) |handle| {
            if (original.stderr_mode) |mode| _ = SetConsoleMode(handle, mode);
        }
        if (original.output != 0) _ = SetConsoleOutputCP(original.output);
        if (original.input != 0) _ = SetConsoleCP(original.input);
    }
}

fn printHelp() void {
    printColored(ansi.cyan,
        \\Commandes disponibles:
        \\  add <texte>     Indexer un document en mémoire
        \\  search <texte>  Chercher avec le classement BM25
        \\  search-and <a> <b> Intersection de deux termes
        \\  index           Afficher l'index lexical et ses postings
        \\  list            Afficher les documents
        \\  update <id> <texte> Modifier un document
        \\  delete <id>     Supprimer un document
        \\  stats           Afficher les statistiques de l'index
        \\  dimension <n>   Définir la dimension avant ajout de vecteurs
        \\  vadd <csv>      Ajouter un vecteur, ex: vadd 1,0,0
        \\  vupdate <id> <csv> Modifier un vecteur
        \\  vdelete <id>    Supprimer un vecteur
        \\  vsearch <csv>   Recherche exacte top 5 par cosinus
        \\  hsearch <csv>   Recherche top 5 dans le graphe HNSW persistant
        \\  hybrid <texte> --vector <csv> Fusion BM25/HNSW, un vecteur par document
        \\  quantize <csv>  Quantifier un vecteur en INT8
        \\  train <mot> [n] Entraîner Word2Vec sur les documents et voir les voisins
        \\  help            Afficher cette aide
        \\  quit / exit     Quitter
        \\
    , .{});
}

fn printColored(color: []const u8, comptime format: []const u8, args: anytype) void {
    if (colors_enabled) std.debug.print("{s}", .{color});
    std.debug.print(format, args);
    if (colors_enabled) std.debug.print("{s}", .{ansi.reset});
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

fn persistDatabase(
    io: anytype,
    allocator: std.mem.Allocator,
    documents: []const Document,
    vector_index: *const VectorIndex,
) !void {
    const contents = try allocator.alloc([]const u8, documents.len);
    defer allocator.free(contents);
    for (documents, 0..) |document, i| contents[i] = document.content;
    try storage.writeDatabase(io, "zvectordb.db", contents, vector_index.vectors.items, vector_index.dimension);
}

fn loadOrBuildHnsw(io: anytype, allocator: std.mem.Allocator, vector_index: *const VectorIndex) !HNSW {
    return HNSW.load(
        io,
        allocator,
        hnsw_path,
        vector_index.dimension,
        hnsw_m,
        hnsw_ef_construction,
        hnsw_ef_search,
        vector_index.vectors.items,
    ) catch |err| switch (err) {
        error.FileNotFound, error.StaleGraph, error.InvalidGraph, error.UnsupportedGraphVersion, error.EndOfStream => {
            var graph = HNSW.init(allocator, vector_index.dimension, hnsw_m, hnsw_ef_construction, hnsw_ef_search);
            errdefer graph.deinit();
            try populateHnsw(allocator, &graph, vector_index);
            try graph.save(io, hnsw_path, vector_index.vectors.items);
            return graph;
        },
        else => return err,
    };
}

fn rebuildHnsw(allocator: std.mem.Allocator, graph: *HNSW, vector_index: *const VectorIndex) !void {
    graph.deinit();
    graph.* = HNSW.init(allocator, vector_index.dimension, hnsw_m, hnsw_ef_construction, hnsw_ef_search);
    try populateHnsw(allocator, graph, vector_index);
}

fn populateHnsw(allocator: std.mem.Allocator, graph: *HNSW, vector_index: *const VectorIndex) !void {
    const converted = try allocator.alloc(f32, vector_index.dimension);
    defer allocator.free(converted);
    var random_state = std.Random.DefaultPrng.init(42);
    for (0..vector_index.count) |id| {
        const start = id * vector_index.dimension;
        const stored = vector_index.vectors.items[start .. start + vector_index.dimension];
        for (stored, 0..) |value, i| converted[i] = @floatCast(value);
        _ = try graph.insert(converted, random_state.random());
    }
}

fn insertHnswVector(allocator: std.mem.Allocator, graph: *HNSW, values: []const f64, id: usize) !void {
    const converted = try allocator.alloc(f32, values.len);
    defer allocator.free(converted);
    for (values, 0..) |value, i| converted[i] = @floatCast(value);
    var random_state = std.Random.DefaultPrng.init(@intCast(id + 42));
    _ = try graph.insert(converted, random_state.random());
}

fn persistVectorData(
    io: anytype,
    allocator: std.mem.Allocator,
    documents: []const Document,
    vector_index: *const VectorIndex,
    graph: *const HNSW,
) !void {
    try persistDatabase(io, allocator, documents, vector_index);
    try graph.save(io, hnsw_path, vector_index.vectors.items);
}

fn rebuildTextIndex(
    allocator: std.mem.Allocator,
    index: *InvertedIndex,
    search_engine: *SearchEngine,
    documents: []const Document,
) !void {
    index.deinit();
    index.* = InvertedIndex.init(allocator);
    for (documents, 0..) |document, id| {
        const tokens = try search_engine.tokenizer.tokenize(document.content);
        defer search_engine.tokenizer.freeTokens(tokens);
        try index.addDocument(id, tokens.len);
        for (tokens) |token| try index.add(token, id);
    }
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
        printColored(ansi.yellow, "Word2Vec exige au moins deux mots distincts.\n", .{});
        return;
    }
    const query_id = vocabulary.getId(query_word) orelse {
        printColored(ansi.yellow, "Mot absent du vocabulaire: {s}\n", .{query_word});
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
        printColored(ansi.yellow, "Corpus trop court pour construire des paires de contexte.\n", .{});
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
    printColored(ansi.cyan, "Voisins Word2Vec de '{s}' après {d} époques:\n", .{ query_word, passes });
    for (similar) |item| printColored(ansi.cyan, "  {s}: {d:.5}\n", .{ vocabulary.getWord(item.id).?, item.score });
}
