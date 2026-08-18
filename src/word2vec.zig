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

    grad_input: []f64,
    grad_output: []f64,
    grad_scores: []f64,

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

        const grad_input = try allocator.alloc(
            f64,
            vocab_size * dimension,
        );

        errdefer allocator.free(grad_input);

        const grad_output = try allocator.alloc(
            f64,
            vocab_size * dimension,
        );
        errdefer allocator.free(grad_output);

        const grad_scores = try allocator.alloc(
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
            .grad_input = grad_input,
            .grad_output = grad_output,
            .grad_scores = grad_scores,
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

        self.allocator.free(
            self.grad_input,
        );

        self.allocator.free(
            self.grad_output,
        );

        self.allocator.free(
            self.grad_scores,
        );
    }
    // fonction pour remettre le gradient à zeros
    fn zeroGradients(
        self: *Word2vec,
    ) void {
        @memset(
            self.grad_input,
            0.0,
        );

        @memset(
            self.grad_output,
            0.0,
        );

        @memset(
            self.grad_scores,
            0.0,
        );
    }

    // fonction pour le calcule du gradient des scores

    fn computeScoreGradients(
        self: *Word2vec,
        target_id: usize,
    ) void {
        for (
            self.probabilities,
            0..,
        ) |probability, i| {
            self.grad_scores[i] = probability;

            if (i == target_id) {
                self.grad_scores[i] -= 1.0;
            }
        }
    }

    fn computeOutputGradients(
        self: *Word2vec,
        context_id: usize,
    ) void {
        const context_vector = self.input.get(context_id);
        for (0..self.vocab_size) |word_id| {
            const gradient_score = self.grad_scores[word_id];
            const start = word_id * self.dimenson;

            for (0..self.dimenson) |d| {
                self.grad_output[
                    start + d
                ] += gradient_score * context_vector[d];
            }
        }
    }

    fn computeInputGradient(
        self: *Word2vec,
        context_id: usize,
    ) void {
        const start = context_id * self.dimenson;

        for (0..self.vocab_size) |word_id| {
            const gradient_score = self.grad_scores[word_id];
            const output_vector = self.output.get(word_id);

            for (0..self.dimenson) |d| {
                self.grad_input[start + d] += gradient_score * output_vector[d];
            }
        }
    }

    fn updateOuput(
        self: *Word2vec,
        learning_rate: f64,
    ) void {
        for (
            self.output.weights,
            self.grad_output,
        ) |*weight, gradient| {
            weight.* -= learning_rate * gradient;
        }
    }

    fn updateInput(
        self: *Word2vec,
        learning_rate: f64,
    ) void {
        for (
            self.input.weights,
            self.grad_input,
        ) |*weight, gradient| {
            weight.* -= learning_rate * gradient;
        }
    }

    pub fn update(
        self: *Word2vec,
        learning_rate: f64,
    ) void {
        self.updateInput(
            learning_rate,
        );
        self.updateOuput(
            learning_rate,
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

    pub fn backward(
        self: *Word2vec,
        context_id: usize,
        target_id: usize,
    ) void {
        self.zeroGradients();

        self.computeScoreGradients(
            target_id,
        );
        self.computeOutputGradients(
            context_id,
        );
        self.computeInputGradient(
            context_id,
        );
    }
};
