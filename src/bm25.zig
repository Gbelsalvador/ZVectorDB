const std = @import("std");

pub const BM25 = struct {
    k1: f64,
    b: f64,

    pub fn init(k1: f64, b: f64) BM25 {
        return .{
            .k1 = k1,
            .b = b,
        };
    }
    // BM25(t,D) = IDF(t) * (f(t,D)(k1 + 1)/f(t,D) + k1(1 -b + (b* (|D|/avgdl))))
    pub fn score(
        self: *const BM25,
        frequency: usize,
        document_length: usize,
        average_document_length: f64,
        total_documents: usize,
        document_frequency: usize,
    ) f64 {
        if (frequency == 0 or document_frequency == 0 or total_documents == 0) {
            return 0.0;
        }

        const idf = @log(
            1.0 + (@as(f64, @floatFromInt(total_documents)) / @as(f64, @floatFromInt(document_frequency))),
        );

        const tf = @as(
            f64,
            @floatFromInt(frequency),
        );

        const dl = @as(
            f64,
            @floatFromInt(document_length),
        );

        const normalization = 1.0 - self.b + self.b * (dl / average_document_length);

        const numerator = tf * (self.k1 + 1.0);
        const denominator = tf + self.k1 * normalization;

        return idf * (numerator / denominator);
    }
};
