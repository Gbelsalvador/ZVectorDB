const std = @import("std");

pub fn crossEntropy(
    probabilities: []const f64,
    target: usize,
) f64 {
    std.debug.assert(
        target < probabilities.len,
    );

    const epsilon = 1e-12;
    const probability = @max(
        probabilities[target],
        epsilon,
    );

    return -@log(probability);
}
