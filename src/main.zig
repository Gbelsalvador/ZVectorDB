const std = @import("std");
const builtin = @import("builtin");
const Engine = @import("engine.zig").Engine;
const Document = @import("engine.zig").Document;
const QueryEngine = @import("query_engine.zig");
const vector = @import("vector.zig");
const quantize = @import("quantifization.zig").quantize;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const TrainingDataset = @import("training_dataset.zig").TrainingDataset;
const NegativeSampler = @import("negative_sampler.zig").NegativeSampler;
const Word2vec = @import("word2vec.zig").Word2vec;
const ApiV1 = @import("api_v1/root.zig");

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

pub fn main(init: std.process.Init) !void {
    const original_code_pages = enableWindowsUtf8Console();
    defer restoreConsoleCodePages(original_code_pages);
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |id| printColored(ansi.cyan, "[{d}] {s}\n", .{ id, args.items[id].content });
    printColored(
        ansi.yellow,
        "le valeur de args : {d}\n",
        .{
            args.len,
        },
    );
    if (args.len > 1 and (std.mem.eql(u8, args[1], "server") or std.mem.eql(u8, args[1], "serve"))) {
        const port: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
        var manager = try ApiV1.CollectionManager.init(allocator, init.io);
        defer manager.deinit();
        try ApiV1.HttpServer.serve(init.io, allocator, &manager, port);
        return;
    }
    var engine = Engine.init(allocator);
    try engine.open(init.io);
    defer engine.deinit();
    if (engine.restored) {
        printColored(ansi.green, "Base restaurée: {d} documents, {d} vecteurs.\n", .{
            engine.documents.items.len,
            engine.vector_index.count,
        });
    }

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
                engine.index.total_documents,
                engine.index.total_terms,
                engine.index.averageDocumentLength(),
                engine.vector_index.count,
                engine.vector_index.dimension,
            });
        } else if (std.mem.eql(u8, command, "index")) {
            engine.index.print();
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
            const matches = try engine.searchAnd(left, right);
            defer allocator.free(matches);
            if (matches.len == 0) printColored(ansi.yellow, "Aucun document ne contient les deux termes.\n", .{});
            for (matches) |id| printColored(ansi.cyan, "[{d}] {s}\n", .{ id, engine.documents.items[id].content });
        } else if (std.mem.startsWith(u8, command, "dimension ")) {
            if (engine.vector_index.count != 0) {
                printColored(ansi.yellow, "Dimension verrouillée après la première insertion.\n", .{});
                continue;
            }
            const dimension = std.fmt.parseInt(usize, std.mem.trim(u8, command[9..], " \t"), 10) catch {
                printColored(ansi.red, "Usage: dimension <entier positif>\n", .{});
                continue;
            };
            if (dimension == 0) continue;
            try engine.setDimension(init.io, dimension);
            printColored(ansi.green, "Dimension vectorielle: {d}\n", .{dimension});
        } else if (std.mem.startsWith(u8, command, "vadd ")) {
            const values = parseVector(allocator, command[5..]) catch {
                printColored(ansi.red, "Vecteur CSV invalide; dimension attendue: {d}.\n", .{engine.vector_index.dimension});
                continue;
            };
            defer allocator.free(values);
            if (values.len != engine.vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ engine.vector_index.dimension, values.len });
                continue;
            }
            const id = try engine.addVector(init.io, values);
            printColored(ansi.green, "Vecteur {d} ajouté.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "vdelete ")) {
            const id = std.fmt.parseInt(usize, std.mem.trim(u8, command[8..], " \t"), 10) catch {
                printColored(ansi.red, "Usage: vdelete <id>\n", .{});
                continue;
            };
            if (id >= engine.vector_index.count) {
                printColored(ansi.yellow, "Vecteur {d} introuvable.\n", .{id});
                continue;
            }
            try engine.deleteVector(init.io, id);
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
            if (id >= engine.vector_index.count) {
                printColored(ansi.yellow, "Vecteur {d} introuvable.\n", .{id});
                continue;
            }
            const values = parseVector(allocator, std.mem.trim(u8, arguments[separator..], " \t")) catch {
                printColored(ansi.red, "Vecteur CSV invalide.\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != engine.vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ engine.vector_index.dimension, values.len });
                continue;
            }
            try engine.updateVector(init.io, id, values);
            printColored(ansi.green, "Vecteur {d} modifié.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "vsearch ")) {
            const values = parseVector(allocator, command[8..]) catch {
                printColored(ansi.red, "Usage: vsearch <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != engine.vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ engine.vector_index.dimension, values.len });
                continue;
            }
            const results = try engine.searchExact(values, 5);
            defer allocator.free(results);
            if (results.len == 0) printColored(ansi.yellow, "Index vectoriel vide.\n", .{});
            for (results) |result| printColored(ansi.cyan, "[{d}] similarité cosinus {d:.5}\n", .{ result.id, result.score });
        } else if (std.mem.startsWith(u8, command, "query ")) {
            const arguments = command[6..];
            const vector_marker = std.mem.indexOf(u8, arguments, "--vector");
            const text_query = if (vector_marker) |marker|
                std.mem.trim(u8, arguments[0..marker], " \t")
            else
                std.mem.trim(u8, arguments, " \t");
            var vector_values: ?[]f64 = null;
            defer {
                if (vector_values) |values| allocator.free(values);
            }
            if (vector_marker) |marker| {
                const vector_query_text = std.mem.trim(u8, arguments[marker + "--vector".len ..], " \t");
                if (vector_query_text.len == 0) {
                    printColored(ansi.red, "Usage: query <texte> [--vector <csv>]\n", .{});
                    continue;
                }
                vector_values = parseVector(allocator, vector_query_text) catch {
                    printColored(ansi.red, "Vecteur CSV invalide.\n", .{});
                    continue;
                };
            } else if (text_query.len == 0) {
                printColored(ansi.red, "Usage: query <texte> [--vector <csv>]\n", .{});
                continue;
            }
            if (vector_values) |values| {
                if (values.len != engine.vector_index.dimension) {
                    printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ engine.vector_index.dimension, values.len });
                    continue;
                }
            }

            const plan = engine.planQuery(
                text_query,
                vector_values != null,
            );
            printQueryPlan(plan);
            if (!plan.use_bm25 and !plan.use_vector) {
                printColored(ansi.yellow, "Aucune source de recherche disponible pour cette requête.\n", .{});
                continue;
            }
            if (!plan.aligned_ids) {
                printColored(ansi.yellow, "Exécution annulée: le nombre de documents et de vecteurs doit correspondre pour fusionner leurs identifiants.\n", .{});
                continue;
            }

            const results = try engine.executeQuery(text_query, vector_values, plan);
            defer allocator.free(results);
            if (results.len == 0) {
                printColored(ansi.yellow, "Aucun résultat pour cette requête.\n", .{});
            } else {
                for (results[0..@min(results.len, QueryEngine.ResultLimit)]) |result| {
                    if (result.id < engine.documents.items.len) {
                        printColored(ansi.cyan, "[{d}] score {d:.5} — {s}\n", .{
                            result.id,
                            result.score,
                            engine.documents.items[result.id].content,
                        });
                    } else {
                        printColored(ansi.cyan, "[{d}] score {d:.5} — vecteur sans document associé\n", .{ result.id, result.score });
                    }
                }
            }
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
            const values = parseVector(allocator, vector_query_text) catch {
                printColored(ansi.red, "Vecteur CSV invalide.\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != engine.vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ engine.vector_index.dimension, values.len });
                continue;
            }

            const plan = engine.planQuery(text_query, true);
            printQueryPlan(plan);
            if (!plan.use_bm25 or !plan.use_vector) {
                printColored(ansi.yellow, "La recherche hybride exige des documents et des vecteurs.\n", .{});
                continue;
            }
            if (!plan.aligned_ids) {
                printColored(ansi.yellow, "La recherche hybride exige un vecteur par document, dans le même ordre.\n", .{});
                continue;
            }
            const results = try engine.executeQuery(text_query, values, plan);
            defer allocator.free(results);
            if (results.len == 0) {
                printColored(ansi.yellow, "Aucun résultat hybride.\n", .{});
            } else {
                for (results[0..@min(results.len, QueryEngine.ResultLimit)]) |result| {
                    printColored(ansi.cyan, "[{d}] score {d:.5} — {s}\n", .{
                        result.id,
                        result.score,
                        engine.documents.items[result.id].content,
                    });
                }
            }
        } else if (std.mem.startsWith(u8, command, "hsearch ")) {
            const values = parseVector(allocator, command[8..]) catch {
                printColored(ansi.red, "Usage: hsearch <valeur1,valeur2,...>\n", .{});
                continue;
            };
            defer allocator.free(values);
            if (values.len != engine.vector_index.dimension) {
                printColored(ansi.red, "Dimension incorrecte: attendu {d}, reçu {d}.\n", .{ engine.vector_index.dimension, values.len });
                continue;
            }
            if (engine.vector_index.count == 0) {
                printColored(ansi.yellow, "Index vectoriel vide.\n", .{});
                continue;
            }
            var distance_stats = vector.DistanceStats{};
            const results = try engine.searchHnsw(values, 5, &distance_stats);
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
            if (engine.documents.items.len == 0) {
                printColored(ansi.yellow, "Ajoutez d'abord des documents avec 'add'.\n", .{});
                continue;
            }
            try trainAndShowSimilar(allocator, engine.documents.items, word, epochs);
        } else if (std.mem.eql(u8, command, "list")) {
            if (engine.documents.items.len == 0) printColored(ansi.yellow, "Aucun document. Ajoutez-en avec: add <texte>\n", .{});
            for (engine.documents.items, 0..) |doc, id| printColored(ansi.cyan, "[{d}] {s}\n", .{ id, doc.content });
        } else if (std.mem.startsWith(u8, command, "delete ")) {
            const id = std.fmt.parseInt(usize, std.mem.trim(u8, command[7..], " \t"), 10) catch {
                printColored(ansi.red, "Usage: delete <id>\n", .{});
                continue;
            };
            if (id >= engine.documents.items.len) {
                printColored(ansi.yellow, "Document {d} introuvable.\n", .{id});
                continue;
            }
            try engine.deleteDocument(init.io, id);
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
            if (id >= engine.documents.items.len or content.len == 0) {
                printColored(ansi.yellow, "Document introuvable ou texte vide.\n", .{});
                continue;
            }
            try engine.updateDocument(init.io, id, content);
            printColored(ansi.green, "Document {d} modifié.\n", .{id});
        } else if (std.mem.startsWith(u8, command, "add ")) {
            const content = std.mem.trim(u8, command[4..], " \t\r");
            if (content.len == 0) {
                printColored(ansi.red, "Usage: add <texte du document>\n", .{});
                continue;
            }
            const added = try engine.addDocument(init.io, content);
            printColored(ansi.green, "Document {d} ajouté ({d} termes).\n", .{ added.id, added.term_count });
        } else if (std.mem.startsWith(u8, command, "search ")) {
            const query = std.mem.trim(u8, command[7..], " \t\r");
            if (query.len == 0) {
                printColored(ansi.red, "Usage: search <requête>\n", .{});
                continue;
            }
            const results = try engine.searchText(query);
            defer allocator.free(results);
            if (results.len == 0) {
                printColored(ansi.yellow, "Aucun résultat pour « {s} ».\n", .{query});
            } else {
                for (results) |result| printColored(ansi.cyan, "[{d}] score {d:.4} — {s}\n", .{
                    result.document_id,
                    result.score,
                    engine.documents.items[result.document_id].content,
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
        \\  query <texte> [--vector <csv>] Planifier puis exécuter (top 10)
        \\  quantize <csv>  Quantifier un vecteur en INT8
        \\  train <mot> [n] Entraîner Word2Vec sur les documents et voir les voisins
        \\  help            Afficher cette aide
        \\  quit / exit     Quitter
        \\
    , .{});
}

fn printQueryPlan(plan: QueryEngine.Plan) void {
    printColored(ansi.yellow, "Plan du query engine:\n", .{});
    printColored(ansi.cyan, "  1. Filtres: aucun (pas de métadonnées indexées).\n", .{});
    printColored(ansi.cyan, "  2. Candidats BM25: {d} (maximum 50).\n", .{plan.bm25_candidates});
    printColored(ansi.cyan, "  3. Candidats HNSW: {d} (maximum 50).\n", .{plan.vector_candidates});
    printColored(ansi.cyan, "  4. Recherche vectorielle: {s}.\n", .{if (plan.use_vector) "oui" else "non"});
    printColored(ansi.cyan, "  5. Recherche BM25: {s}.\n", .{if (plan.use_bm25) "oui" else "non"});
    if (plan.usesBothSources() and plan.aligned_ids) {
        printColored(ansi.cyan, "  6. Fusion: RRF (k=60), puis reranking.\n", .{});
    } else if (plan.usesBothSources()) {
        printColored(ansi.cyan, "  6. Fusion: impossible tant que les identifiants document/vecteur ne sont pas alignés.\n", .{});
    } else {
        printColored(ansi.cyan, "  6. Fusion: aucune, une seule source active.\n", .{});
    }
    printColored(ansi.cyan, "  7. Reranking: scores min-max normalisés; poids 50/50 si les deux sources ont des résultats.\n", .{});
    printColored(ansi.cyan, "  8. Résultats: top {d}.\n", .{QueryEngine.ResultLimit});
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
