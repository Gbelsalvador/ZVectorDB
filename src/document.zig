const std = @import("std");

pub const Document = struct{
    id: usize,
    content: []const u8,

    pub fn init(id: usize, content: []const u8) Document {
        return .{
            .id = id,
            .content = content,
        };
    }
};