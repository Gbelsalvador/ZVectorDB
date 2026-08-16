const std = @import("std");

const Embedding = @import("embedding.zig").Embedding;

const softmax = @import("softmax.zig").softmax;

const crossEntropy = @import("loss.zig").crossEntropy;

pub const Word2vec = struct {
    allocator: std.mem.Allocator,

    vocab_size: usize,
    dimenson: usize,

    input: Embedding,
    output: Embedding,

    scores: []f64,
    probabilities: []f64,
};

pub fn init(
    allocator: std.mem.Allocator,
    vocab_size: usize,
    dimension: usize,
) !Word2vec {
    var input = try Embedding.init(allocator, vocab_size, dimension);

    errdefer input.deinit();

    var output = try Embedding.init(
        allocator,
        vocab_size,
        dimension,
    );

    errdefer output.deinit();
    const scores = try allocator.alloc(f64, vocab_size);

    errdefer allocator.free(scores);

    const probabilities = try allocator.alloc(
        f64,
        vocab_size,
    );

    return .{
        .allocator = allocator,
        .vocab_size = vocab_size,
        .dimenson = dimension,
        .input = input,
        .output = output,
        .scores = scores,
        .probabilities = probabilities,
    };
}
pub fn deinit(
    self: *Word2vec,
) void {
    self.input.deinit();
    self.output.deinit();

    self.allocator.free(
        self.scores,
    );

    self.allocator.free(
        self.probabilities,
    );
}

pub fn forward(
    self: *Word2vec,
    context_id: usize,
    target_id: usize,
) f64 {
    const context_vector =
        self.input.get(context_id);

    for (0..self.vocab_size) |word_id| {
        self.scores[word_id] =
            self.output.dotWith(
                word_id,
                context_vector,
            );
    }

    softmax(
        self.scores,
        self.probabilities,
    );

    return crossEntropy(
        self.probabilities,
        target_id,
    );
}

pub fn randomize(
    self: *Word2vec,
    random: std.Random,
) void {
    self.input.randomize(random);
    self.output.randomize(random);
}
