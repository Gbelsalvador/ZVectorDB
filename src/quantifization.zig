const std = @import("std");

pub const QuantizedVector = struct {
    values: []i8,
    scale: f32,
};

pub fn quantize(
    allocator: std.mem.Allocator,
    input: []const f32,
) !QuantizedVector {
    var max_abs: f32 = 0;

    for (input) |x| {
        const abs_x = @abs(x);

        if (abs_x > max_abs) {
            max_abs = abs_x;
        }
    }

    if (max_abs == 0) {
        max_abs = 1;
    }

    const scale = 127.0 / max_abs;

    const values = try allocator.alloc(
        i8,
        input.len,
    );

    for (
        input,
        values,
    ) |x, *q| {
        const scaled = x * scale;

        const rounded = @round(scaled);

        q.* = @intFromFloat(
            std.math.clamp(
                rounded,
                -127,
                127.0,
            ),
        );
    }

    return .{
        .values = values,
        .scale = scale,
    };
}
