const std = @import("std");

pub fn softmax(
    scores: []const f64,
    probabilities: []f64,
) void {
    std.debug.assert(
        scores.len == probabilities.len,
    );

    if (scores.len == 0) {
        return;
    }

    var max_score = scores[0];

    for (scores[1..]) |score| {
        if (score > max_score) {
            max_score = score;
        }
    }

    var sum: f64 = 0.0;

    for (scores, 0..) |score, i| {
        const exp_value = @exp(score - max_score);

        probabilities[i] = exp_value;

        sum += exp_value;
    }

    for (probabilities) |*probability| {
        probability.* /= sum;
    }
}
