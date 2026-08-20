const std = @import("std");
const vector = @import("vector.zig");
pub const QuantizedVector = struct {
    values: []i8,
    scale: f32,

    pub fn deinit(
        self: *QuantizedVector,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.values);
    }

    pub fn dotInt8(
        a: []const i8,
        b: []const i8,
    ) i32 {
        std.debug.assert(
            a.len == b.len,
        );

        var sum: i32 = 0;

        for (a, b) |x, y| {
            sum +=
                @as(i32, x) *
                @as(i32, y);
        }

        return sum;
    }

    pub fn dotInt8SIMD(
        a: []const i8,
        b: []const i8,
    ) i32 {
        std.debug.assert(
            a.len == b.len,
        );

        const Width = 8;

        const Vec =
            @Vector(Width, i16);

        var sum: Vec =
            @splat(0);

        var i: usize = 0;

        while (i + Width <= a.len) : (i += Width) {
            var va: Vec = undefined;
            var vb: Vec = undefined;

            inline for (0..Width) |j| {
                va[j] =
                    @as(i16, a[i + j]);

                vb[j] =
                    @as(i16, b[i + j]);
            }

            sum += va * vb;
        }

        var result: i32 = 0;

        inline for (0..Width) |j| {
            result +=
                @as(i32, sum[j]);
        }

        while (i < a.len) : (i += 1) {
            result +=
                @as(i32, a[i]) *
                @as(i32, b[i]);
        }

        return result;
    }

    pub fn squaredNormInt8(
        a: []const i8,
    ) i64 {
        var sum: i64 = 0;

        for (a) |x| {
            const v =
                @as(i64, x);

            sum += v * v;
        }

        return sum;
    }

    pub fn cosineInt8(
        a: []const i8,
        b: []const i8,
    ) f32 {
        const dot =
            dotInt8(a, b);

        const normA =
            squaredNormInt8(a);

        const normB =
            squaredNormInt8(b);

        if (normA == 0 or
            normB == 0)
        {
            return 0;
        }

        return @as(f32, @floatFromInt(dot)) /
            (@sqrt(@as(f32, @floatFromInt(normA))) *
                @sqrt(@as(f32, @floatFromInt(normB))));
    }

    test "INT8 cosine accuracy" {
        const allocator =
            std.testing.allocator;

        const a = [_]f32{
            0.1,
            0.2,
            0.3,
            0.4,
            0.5,
            0.6,
            0.7,
            0.8,
        };

        const b = [_]f32{
            0.2,
            0.1,
            0.4,
            0.3,
            0.6,
            0.5,
            0.8,
            0.7,
        };

        const qa =
            try quantize(
                allocator,
                &a,
            );

        defer qa.deinit(
            allocator,
        );

        const qb =
            try quantize(
                allocator,
                &b,
            );

        defer qb.deinit(
            allocator,
        );

        const exact =
            vector.cosineSimilarity(
                &a,
                &b,
            );

        const approximate =
            cosineInt8(
                qa.values,
                qb.values,
            );

        const error_value =
            @abs(
                exact -
                    approximate,
            );

        std.debug.print(
            "f32 = {d}\n",
            .{exact},
        );

        std.debug.print(
            "int8 = {d}\n",
            .{approximate},
        );

        std.debug.print(
            "error = {d}\n",
            .{error_value},
        );
    }
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

test "INT8 quantization" {
    const allocator =
        std.testing.allocator;

    const original = [_]f32{
        -0.92,
        -0.41,
        0.03,
        0.72,
        0.98,
    };

    const quantized =
        try quantize(
            allocator,
            &original,
        );

    defer allocator.free(
        quantized.values,
    );

    const restored =
        try dequantize(
            allocator,
            quantized,
        );

    defer allocator.free(
        restored,
    );

    for (
        original,
        restored,
    ) |a, b| {
        std.debug.print(
            "{d} -> {d}\n",
            .{ a, b },
        );
    }
}
pub fn dequantize(
    allocator: std.mem.Allocator,
    input: QuantizedVector,
) ![]f32 {
    const output = try allocator.alloc(
        f32,
        input.values.len,
    );
    for (
        input.values,
        output,
    ) |q, *x| {
        x.* = @as(f32, @floatFromInt(q)) / input.scale;
    }
    return output;
}
