const std = @import("std");
pub const NegativeSampling = struct {
    allocator: std.mem.Allocator,
    num_negative: usize,
};
pub fn sigmoid(x: f64) f64 {
    if (x >= 0.0) {
        const z = @exp(-x);
        return 1.0 / (1.0 + z);
    } else {
        const z = @exp(x);
        return z / (1.0 + z);
    }
}
pub fn positiveLoss(
    score: f64,
) f64 {
    const s = sigmoid(score);

    const epsilon = 1e-12;

    return -@log(
        @max(s, epsilon),
    );
}

pub fn negativeloss(
    score: f64,
) f64 {
    const s = sigmoid(score);
    const epsilon = 1e-12;
    return -@log(
        @max(
            1.0 - s,
            epsilon,
        ),
    );
}
