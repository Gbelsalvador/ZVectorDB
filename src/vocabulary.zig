const std = @import("std");

pub const Vocabulary = struct {
    allocator: std.mem.Allocator,

    word_to_id: std.StringHashMap(usize),
    id_to_word: std.ArrayList([]u8),
    frequencies: std.ArrayList(usize),

    pub fn init(
        allocator: std.mem.Allocator,
    ) Vocabulary {
        return .{
            .allocator = allocator,

            .word_to_id = std.StringHashMap(usize).init(
                allocator,
            ),

            .id_to_word = std.ArrayList([]u8).empty,
            .frequencies = std.ArrayList(usize).empty,
        };
    }

    pub fn deinit(
        self: *Vocabulary,
    ) void {
        self.word_to_id.deinit();

        for (self.id_to_word.items) |word| {
            self.allocator.free(word);
        }

        self.id_to_word.deinit(self.allocator);
        self.frequencies.deinit();
    }

    pub fn add(
        self: *Vocabulary,
        word: []const u8,
    ) !usize {
        if (self.word_to_id.get(
            word,
        )) |id| {
            self.frequencies.items[id] += 1;
            return id;
        }

        const id =
            self.id_to_word.items.len;

        const owned_word =
            try self.allocator.dupe(
                u8,
                word,
            );

        errdefer {
            self.allocator.free(
                owned_word,
            );
        }

        try self.word_to_id.put(
            owned_word,
            id,
        );

        try self.id_to_word.append(
            self.allocator,
            owned_word,
        );

        try self.frequencies.append(self.allocator, 1);

        return id;
    }

    pub fn getId(
        self: *Vocabulary,
        word: []const u8,
    ) ?usize {
        return self.word_to_id.get(word);
    }

    pub fn getWord(
        self: *Vocabulary,
        id: usize,
    ) ?[]const u8 {
        if (id >= self.id_to_word.items.len) {
            return null;
        }

        return self.id_to_word.items[id];
    }

    pub fn size(
        self: *Vocabulary,
    ) usize {
        return self.id_to_word.items.len;
    }
};
