const std = @import("std");

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tokenizer {
        return .{
            .allocator = allocator,
        };
    }

    pub fn tokenize(
        self: Tokenizer,
        text: []const u8,
    ) ![][]u8 {
        var tokens = std.ArrayList([]u8).empty;
        errdefer {
            for (tokens.items) |token| {
                self.allocator.free(token);
            }
            tokens.deinit(self.allocator);
        }

        var iterator = std.mem.tokenizeAny(
            u8,
            text,
            " \t\n\r.,!?;:\"'()[]{}",
        );

        while (iterator.next()) |word| {
            const token = try self.allocator.alloc(u8, word.len);
            errdefer self.allocator.free(token);

            for (word, 0..) |character, i| {
                token[i] = std.ascii.toLower(character);
            }

            try tokens.append(self.allocator, token);
        }

        return tokens.toOwnedSlice(self.allocator);
    }

    pub fn freeTokens(
        self: Tokenizer,
        tokens: [][]u8,
    ) void {
        for (tokens) |token| {
            self.allocator.free(token);
        }

        self.allocator.free(tokens);
    }
};
