const std = @import("std");

const Vocabulary =
    @import("vocabulary.zig").Vocabulary;

pub const TrainingPair = struct {
    context: usize,
    target: usize,
};

pub const TrainingDataset = struct {
    allocator: std.mem.Allocator,

    pairs: std.ArrayList(TrainingPair),

    pub fn init(
        allocator: std.mem.Allocator,
    ) TrainingDataset {
        return .{
            .allocator = allocator,

            .pairs = std.ArrayList(TrainingPair).empty,
        };
    }

    pub fn deinit(
        self: *TrainingDataset,
    ) void {
        self.pairs.deinit(self.allocator);
    }

    pub fn add(
        self: *TrainingDataset,
        context: usize,
        target: usize,
    ) !void {
        try self.pairs.append(self.allocator, .{
            .context = context,
            .target = target,
        });
    }

    pub fn len(
        self: *TrainingDataset,
    ) usize {
        return self.pairs.items.len;
    }
    pub fn buildFromTokens(
        self: *TrainingDataset,
        vocabulary: *Vocabulary,
        tokens: []const []const u8,
        window_size: usize,
    ) !void {
        for (tokens, 0..) |token, center_index| {
            const center_id =
                vocabulary.getId(token) orelse continue;

            const start =
                if (center_index > window_size)
                    center_index - window_size
                else
                    0;

            const end =
                @min(
                    tokens.len,
                    center_index + window_size + 1,
                );

            var context_index = start;

            while (context_index < end) : (context_index += 1) {
                if (context_index == center_index) {
                    continue;
                }

                const context_token =
                    tokens[context_index];

                const context_id =
                    vocabulary.getId(
                        context_token,
                    ) orelse continue;

                try self.add(
                    center_id,
                    context_id,
                );
            }
        }
    }

    pub fn shuffle(
        self: *TrainingDataset,
        random: std.Random,
    ) void {
        random.shuffle(
            TrainingPair,
            self.pairs.items,
        );
    }
};
