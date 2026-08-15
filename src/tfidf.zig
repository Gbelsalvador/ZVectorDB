const std = @import("std");

pub fn termFrequency(
    frequency: usize,
    total_terms: usize,
) f64 {
    if (total_terms == 0) {
        return 0.0;
    }
    // TF(f,t) = nombre d'occurences de t / nombre total de termes du documents
    return @as(f64, @floatFromInt(frequency)) / @as(f64, @floatFromInt(total_terms));
}

pub fn inverseDocumentFrequency(
    total_documents: usize,
    document_frequency: usize,
) f64 {
    if (document_frequency == 0) {
        return 0.0;
    }
    // IDF(t) = log(nombre total de document / nombre de documents contenant le terme)
    return @log(
        @as(f64, @floatFromInt(total_documents)) /
            @as(f64, @floatFromInt(document_frequency)),
    );
}

pub fn tfidf(
    tf: f64,
    idf: f64,
) f64 {
    return tf * idf;
}
