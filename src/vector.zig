const std = @import("std");

pub fn dot(
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
    vector: []const f64,
) f64 {
    var sum: f64 = 0.0;

    for (vector) |value| {
        sum += value * value;
    }

    return @sqrt(sum);
}

pub fn cosineSimilarity(
    a: []const f64,
    b: []const f64,
) f64 {
    std.debug.assert(a.len == b.len);

    const dot_product = dot(a, b);

    const magnitude_a = magnitude(a);
    const magnitude_b = magnitude(b);

    if (magnitude_a == 0.0 or magnitude_b == 0.0) {
        return 0.0;
    }

    return dot_product / (magnitude_a * magnitude_b);
}
