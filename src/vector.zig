const std = @import("std");

pub const DistanceStats = struct {
    comparisons: usize = 0,
};

pub fn dotSIMD(
    a: []const f32,
    b: []const f32,
) f32 {
    std.debug.assert(
        a.len == b.len,
    );
    const width = 8;
    const vec = @Vector(width, f32);

    var sum: vec = @splat(0.0);
    var i: usize = 0;

    while (i + width <= a.len) : (i += width) {
        const va: vec = a[i .. i + width][0..width].*;

        const vb: vec = b[i .. i + width][0..width].*;

        sum += va * vb;
    }

    var result: f32 = 0;

    inline for (0..width) |j| {
        result += sum[j];
    }

    while (i < a.len) : (i += 1) {
        result += a[i] * b[i];
    }

    return result;
}

pub fn squaredNormSIMD(a: []const f32) f32 {
    const width = 8;
    const vec = @Vector(width, f32);
    var sum: vec = @splat(0.0);

    var i: usize = 0;

    while (i + width <= a.len) : (i += width) {
        const va: vec = a[i .. i + width][0..width].*;

        sum += va * va;
    }

    var result: f32 = 0;
    inline for (0..width) |j| {
        result += sum[j];
    }

    while (i < a.len) : (i += 1) {
        result += a[i] * a[i];
    }

    return result;
}

pub fn cosineSimilaritySMD(
    a: []const f32,
    b: []const f32,
) f32 {
    const dot_resultat = dotSIMD(a, b);
    const normA = squaredNormSIMD(a);
    const normB = squaredNormSIMD(b);

    if (normA == 0 or normB == 0) {
        return 0;
    }

    return dot_resultat / (@sqrt(normA) *
        @sqrt(normB));
}

pub fn cosineSimilaritySIMDFused(
    a: []const f32,
    b: []const f32,
) f32 {
    std.debug.assert(
        a.len == b.len,
    );

    const width = 8;

    const Vec =
        @Vector(width, f32);

    const dot_prod: Vec =
        @splat(0.0);

    var normA: Vec =
        @splat(0.0);

    var normB: Vec =
        @splat(0.0);

    var i: usize = 0;

    while (i + width <= a.len) : (i += width) {
        const va: Vec =
            a[i .. i + width][0..width].*;

        const vb: Vec =
            b[i .. i + width][0..width].*;

        dot += va * vb;
        normA += va * va;
        normB += vb * vb;
    }

    var dotScalar: f32 = 0;
    var normAScalar: f32 = 0;
    var normBScalar: f32 = 0;

    inline for (0..width) |j| {
        dotScalar += dot_prod[j];
        normAScalar += normA[j];
        normBScalar += normB[j];
    }

    while (i < a.len) : (i += 1) {
        dotScalar +=
            a[i] * b[i];

        normAScalar +=
            a[i] * a[i];

        normBScalar +=
            b[i] * b[i];
    }

    if (normAScalar == 0 or
        normBScalar == 0)
    {
        return 0;
    }

    return dotScalar /
        (@sqrt(normAScalar) *
            @sqrt(normBScalar));
}

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

pub fn cosineSimilarityCounted(
    a: []const f32,
    b: []const f32,
    stats: *DistanceStats,
) f32 {
    stats.comparisons += 1;
    std.debug.assert(
        a.len == b.len,
    );

    const dot_product = dot(a, b);

    const magnitude_a = magnitude(a);
    const magnitude_b = magnitude(b);

    if (magnitude_a == 0.0 or magnitude_b == 0.0) {
        return 0.0;
    }

    return dot_product / (magnitude_a * magnitude_b);
}
