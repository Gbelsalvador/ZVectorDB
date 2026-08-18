const std = @import("std");

pub const NegativeSampler = struct {
    allocator: std.mem.Allocator,
    probabilities: []f64,
    cumulative: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        frequencies: []const usize,
    ) !NegativeSampler {
        const size =
            frequencies.len;

        const probabilities =
            try allocator.alloc(
                f64,
                size,
            );

        errdefer allocator.free(
            probabilities,
        );

        const cumulative =
            try allocator.alloc(
                f64,
                size,
            );

        errdefer allocator.free(
            cumulative,
        );

        var total: f64 = 0.0;

        for (
            frequencies,
            0..,
        ) |frequency, i| {
            const f =
                @as(
                    f64,
                    @floatFromInt(
                        frequency,
                    ),
                );

            const weight =
                std.math.pow(
                    f64,
                    f,
                    0.75,
                );

            probabilities[i] =
                weight;

            total += weight;
        }

        if (total == 0.0) {
            @memset(
                probabilities,
                0.0,
            );

            @memset(
                cumulative,
                0.0,
            );

            return .{
                .allocator = allocator,
                .probabilities = probabilities,
                .cumulative = cumulative,
            };
        }

        for (
            probabilities,
            0..,
        ) |*probability, i| {
            probability.* /= total;

            if (i == 0) {
                cumulative[i] =
                    probability.*;
            } else {
                cumulative[i] =
                    cumulative[i - 1] +
                    probability.*;
            }
        }

        return .{
            .allocator = allocator,
            .probabilities = probabilities,
            .cumulative = cumulative,
        };
    }

    pub fn deinit(
        self: *NegativeSampler,
    ) void {
        self.allocator.free(
            self.probabilities,
        );

        self.allocator.free(
            self.cumulative,
        );
    }

    pub fn sample(
        self: *NegativeSampler,
        random: std.Random,
    ) usize {
        const value = random.float(f64);
        var left: usize = 0;
        var right: usize = self.cumulative.len;

        while (left < right) {
            const middle = left + (right - left) / 2;

            if (value <= self.cumulative[middle]) {
                right = middle;
            } else {
                left = middle + 1;
            }
        }
        if (left >= self.cumulative.len) {
            return self.cumulative.len - 1;
        }

        return left;
    }

    pub fn sampleExcluding(
        self: *NegativeSampler,
        random: std.Random,
        excluded_id: usize,
    ) usize {
        while (true) {
            const id = self.sample(random);

            if (id != excluded_id) {
                return id;
            }
        }
    }

    pub fn sampleExcludingTwo(
        self: *NegativeSampler,
        random: std.Random,
        excluded_a: usize,
        excluded_b: usize,
    ) usize {
        while (true) {
            const id = self.sample(random);

            if (id != excluded_a and id != excluded_b) {
                return id;
            }
        }
    }

    pub fn sampleNegatives(
        self: *NegativeSampler,
        random: std.Random,
        context_id: usize,
        target_id: usize,
        output: []usize,
    ) void {
        for (output) |*negative_id| {
            negative_id.* = self.sampleExcludingTwo(
                random,
                context_id,
                target_id,
            );
        }
    }
};
