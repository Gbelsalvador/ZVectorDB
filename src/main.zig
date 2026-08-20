const std = @import("std");
const vector = @import("vector.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const trainingDataset = @import("training_dataset.zig").TrainingDataset;
const Word2vec = @import("word2vec.zig").Word2vec;
const NegtaiveSampler = @import("negative_sampler.zig").NegativeSampler;
const vectorindex = @import("vector_index.zig").vectorindex;
const HNSW = @import("hnsw.zig").HNSW;
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var tokenizer = Tokenizer.init(allocator);
    var vocabulary = Vocabulary.init(allocator);
    defer vocabulary.deinit();

    const sentences = [_][]const u8{
        // --- Groupe 1 : Chats, Chiens & Animaux de compagnie ---
        "le chat mange",
        "le chien mange",
        "le chat dort",
        "le chien dort",
        "le chat court",
        "le chien court",
        "le chat saute",
        "le chien saute",
        "le chat joue",
        "le chien joue",
        "le chat regarde",
        "le chien regarde",
        "le chat écoute",
        "le chien écoute",
        "le chat marche",
        "le chien marche",
        "le chat chasse",
        "le chien chasse",
        "le chat ronronne",
        "le chien aboie",
        "le chat griffe",
        "le chien mord",
        "le chat s amuse",
        "le chien s amuse",
        "le chat est rapide",
        "le chien est rapide",
        "le chat est petit",
        "le chien est grand",
        "le chat mange la viande",
        "le chien mange la viande",
        "le chat mange du poisson",
        "le chien mange du poisson",
        "le chat dort sur le lit",
        "le chien dort sur le lit",
        "le chat dort sous la table",
        "le chien dort sous la table",
        "le chat court dans le jardin",
        "le chien court dans le jardin",
        "le chat chasse une souris",
        "le chien chasse un chat",
        "le chat regarde l oiseau",
        "le chien regarde la voiture",
        "le chat saute sur le mur",
        "le chien saute sur le mur",
        "le chat boit du lait",
        "le chien boit de l eau",
        "le petit chat mange",
        "le grand chien mange",
        "un chat noir dort",
        "un chien blanc court",

        // --- Groupe 2 : Oiseaux, Poissons & Animaux sauvages ---
        "l oiseau vole",
        "l oiseau chante",
        "l oiseau mange",
        "l oiseau dort",
        "l oiseau saute",
        "le poisson nage",
        "le poisson mange",
        "le poisson dort",
        "le lion chasse",
        "le lion mange",
        "le lion dort",
        "le lion rugit",
        "le tigre chasse",
        "le tigre mange",
        "le tigre court",
        "le loup chasse",
        "le loup aboie",
        "le loup court",
        "l oiseau vole dans le ciel",
        "l oiseau chante une chanson",
        "le poisson nage dans l eau",
        "le poisson nage dans la riviere",
        "le lion chasse une gazelle",
        "le tigre dort dans la forêt",
        "le loup court dans la montagne",
        "un petit oiseau chante",
        "un grand poisson nage",
        "le lion est fort",
        "le tigre est rapide",
        "le loup est sauvage",

        // --- Groupe 3 : Humains & Actions du quotidien ---
        "l homme mange",
        "la femme mange",
        "l enfant mange",
        "l homme dort",
        "la femme dort",
        "l enfant dort",
        "l homme marche",
        "la femme marche",
        "l enfant marche",
        "l homme court",
        "la femme court",
        "l enfant court",
        "l homme regarde",
        "la femme regarde",
        "l enfant regarde",
        "l homme lit un livre",
        "la femme lit un livre",
        "l enfant lit un livre",
        "l homme ecrit une lettre",
        "la femme ecrit une lettre",
        "l homme parle",
        "la femme parle",
        "l enfant parle",
        "l homme ecoute",
        "la femme ecoute",
        "l enfant ecoute",
        "l homme travaille",
        "la femme travaille",
        "l homme conduit une voiture",
        "la femme conduit une voiture",
        "l enfant joue au ballon",
        "l homme mange de la viande",
        "la femme mange du poisson",
        "l enfant boit du lait",
        "l homme dort dans la chambre",
        "la femme dort dans la chambre",
        "l enfant dort sur le lit",
        "l homme marche dans la rue",
        "la femme marche dans la rue",
        "l enfant court dans le parc",
        "l homme regarde la television",
        "la femme regarde le jardin",
        "l enfant ecoute la musique",
        "l homme habite dans la maison",
        "la femme habite dans la maison",
        "un homme fort travaille",
        "une femme intelligente lit",
        "un petit enfant joue",
        "l homme est grand",
        "la femme est grande",

        // --- Groupe 4 : Objets, Nature & Lieux ---
        "la voiture roule",
        "la voiture s arrete",
        "le bus roule",
        "le train arrive",
        "le train part",
        "la maison est grande",
        "la maison est belle",
        "le jardin est grand",
        "le jardin est beau",
        "la table est grande",
        "la chaise est petite",
        "le livre est intéressant",
        "l eau est froide",
        "le soleil brille",
        "la pluie tombe",
        "le vent souffle",
        "la nuit tombe",
        "le jour se leve",
        "la voiture roule vite",
        "le train roule vite",
        "la voiture est rouge",
        "le bus est bleu",
        "le soleil brille dans le ciel",
        "la pluie tombe sur la maison",
        "l eau coule dans la riviere",
        "le livre est sur la table",
        "le chat est sur la chaise",
        "le chien est sous la table",
        "la voiture est devant la maison",
        "le jardin est derriere la maison",

        // --- Groupe 5 : Phraséologie combinée & Sémantique poussée ---
        "le chat mange le poisson",
        "le chien mange la viande",
        "l oiseau mange le poisson",
        "le lion mange le chien",
        "l homme mange le poisson",
        "la femme mange le poisson",
        "l enfant mange le pain",
        "le chat et le chien jouent",
        "l homme et la femme parlent",
        "l enfant et le chien courent",
        "l oiseau et le poisson vivent",
        "le chat dort et le chien joue",
        "l homme travaille et la femme lit",
        "la voiture et le bus roulent",
        "le train et la voiture arrivent",
        "le petit chat chasse la souris",
        "le grand chien garde la maison",
        "l oiseau chante dans le jardin",
        "le poisson nage dans la mer",
        "le lion dort dans la savane",
        "l homme marche vers la maison",
        "la femme court vers la voiture",
        "l enfant joue avec le chat",
        "l homme joue avec le chien",
        "le chat saute sur la table",
        "le chien saute sur la chaise",
        "l oiseau vole au dessus du jardin",
        "la voiture passe dans la rue",
        "la pluie tombe sur le jardin",
        "le soleil illumine la maison",
        "un chat noir mange du poisson",
        "un chien blanc dort dans le jardin",
        "un grand lion chasse dans la forêt",
        "un petit oiseau vole dans le ciel",
        "un homme fort conduit la voiture",
        "une belle femme lit un grand livre",
        "un petit enfant boit du bon lait",
        "la maison bleue a un grand jardin",
        "le train rouge arrive dans la gare",
        "la voiture noire roule dans la rue",
    };

    // Note : Gardez les tokens ou assurez-vous que Vocabulary.add() fait une copie (dupe)
    for (sentences) |sentence| {
        const tokens = try tokenizer.tokenize(sentence);
        defer tokenizer.freeTokens(tokens);

        for (tokens) |token| {
            _ = try vocabulary.add(token);
        }
    }

    var sampler = try NegtaiveSampler.init(allocator, vocabulary.frequencies.items);
    defer sampler.deinit();

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
    const vector_dim: usize = 10;
    var model = try Word2vec.init(
        allocator,
        vocabulary.size(),
        vector_dim,
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

    const batch_size: usize = 32;
    const epochs = 1000;
    const learning_rate = 0.025;
    const num_negative = 5;

    var epoch: usize = 0;

    while (epoch < epochs) : (epoch += 1) {
        dataset.shuffle(random);
        var total_loss: f64 = 0.0;
        var total_examples: usize = 0;
        var start: usize = 0;

        while (start < dataset.len()) {
            const end = @min(
                start + batch_size,
                dataset.len(),
            );

            const current_batch_size = end - start;

            model.zeroGradients();

            var i = start;

            while (i < end) : (i += 1) {
                const pair = dataset.pairs.items[i];

                total_loss += model.trainPair(
                    random,
                    &sampler,
                    pair.context,
                    pair.target,
                    num_negative,
                );

                total_examples += 1;
            }

            model.updataBatch(learning_rate, current_batch_size);

            start = end;
        }

        if (epoch % 100 == 0) {
            const average_loss =
                total_loss /
                @as(
                    f64,
                    @floatFromInt(
                        dataset.len(),
                    ),
                );

            std.debug.print(
                "Epoch {d} | Loss = {d:.6}\n",
                .{
                    epoch,
                    average_loss,
                },
            );
        }
    }

    //==================================================
    // INITIALISATION ET POPULATION DE L'INDEX HNSW
    //==================================================
    std.debug.print("\n======== DEBUT DE l'INDEXATION HNSW===========\n", .{});
    //parametre HNSW : dimension = 10, m=16, ef_construction=64, efçsearch=32
    var hnsw_index = HNSW.init(allocator, vector_dim, 16, 64, 32);
    defer hnsw_index.deinit();
    // tampon pour convertir la representation f64 du modele en f32
    const buffer_f32 = try allocator.alloc(f32, vector_dim);
    defer allocator.free(buffer_f32);
    var word_id: usize = 0;
    // insertion desvecteurs de chaque mot du vocabulaire dans l'index
    while (word_id < vocabulary.size()) : (word_id += 1) {
        const raw_vector = model.input.get(word_id);
        //copy/cast de f64 vers f32
        for (raw_vector, 0..) |val, i| {
            buffer_f32[i] = @floatCast(val);
        }
        _ = try hnsw_index.insert(buffer_f32, random);
    }

    std.debug.print("indexation de {d} mots terminée avec succes! \n", .{vocabulary.size()});

    //=====================================================
    // RECHERCHE DE VOISIN VIA HNSW
    //=====================================================
    const chat_id = vocabulary.getId("chat").?;
    const chien_id = vocabulary.getId("chien").?;
    const mange_id = vocabulary.getId("mange").?;
    const chat_vector = model.input.get(chat_id);
    const mange_vector = model.input.get(mange_id);
    const chien_vector = model.input.get(chien_id);

    for (chat_vector, 0..) |val, i| {
        buffer_f32[i] = @floatCast(val);
    }
    const top_k: usize = 5;
    const search_results = try hnsw_index.search(buffer_f32, allocator, top_k);
    defer allocator.free(search_results);

    std.debug.print("\n======== PLUS PROCHES VOISINS DE 'chat' (VIA HNSW) ======\n", .{});
    for (search_results) |cand| {
        const word = vocabulary.getWord(cand.id).?;
        std.debug.print("{s} (id: {d}) ------ score cosine: {d:.4}\n", .{
            word,
            cand.id,
            cand.score,
        });
    }

    const similar = try model.mostSimilar(
        chat_id,
        allocator,
        5,
    );

    defer allocator.free(similar);
    for (similar) |item| {
        const word = vocabulary.getWord(item.id).?;

        std.debug.print(
            "{s} --- {d:.4}\n",
            .{
                word,
                item.score,
            },
        );
    }
    std.debug.print(
        "\n=======SIMILARITIES ========\n",
        .{},
    );

    std.debug.print(
        "chat -- chien = {d:.4}\n",
        .{
            vector.cosineSimilarityF64(chat_vector, chien_vector),
        },
    );

    std.debug.print(
        "chat --- mange = {d:.4}\n",
        .{
            vector.cosineSimilarityF64(chat_vector, mange_vector),
        },
    );
}
