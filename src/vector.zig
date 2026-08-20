const std = @import("std");

pub fn dot(
    a: []const f32,
    b: []const f32,
) f32 {
    std.debug.assert(a.len == b.len);
    var result: f32 = 0.0;

    for (a, b) |x, y| {
        result += x * y;
    }

    return result;
}

pub fn dot64(
    a: []const f64,
    b: []const f64,
) f64 {
    std.debug.assert(a.len == b.len);
    var result: f64 = 0.0;

    for (a, b) |x, y| {
        result += x * y;
    }

    return result;
}

pub fn magnitude(
    vector: []const f32,
) f32 {
    var sum: f32 = 0.0;

    for (vector) |value| {
        sum += value * value;
    }

    return @sqrt(sum);
}

pub fn cosineSimilarity(
    a: []const f32,
    b: []const f32,
) f32 {
    std.debug.assert(a.len == b.len);

    const dot_product = dot(a, b);

    const magnitude_a = magnitude(a);
    const magnitude_b = magnitude(b);

    if (magnitude_a == 0.0 or magnitude_b == 0.0) {
        return 0.0;
    }

    return dot_product / (magnitude_a * magnitude_b);
}

pub fn cosineSimilarityF64(a: []const f64, b: []const f64) f64 {
    var dot_prod: f64 = 0.0;
    var norm_a: f64 = 0.0;
    var norm_b: f64 = 0.0;
    for (a, 0..) |val, i| {
        dot_prod += val * b[i];
        norm_a += val * val;
        norm_b += b[i] * b[i];
    }
    if (norm_a == 0.0 or norm_b == 0.0) return 0.0;
    return dot_prod / (@sqrt(norm_a) * @sqrt(norm_b));
}
