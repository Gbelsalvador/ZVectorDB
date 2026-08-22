const std = @import("std");

const Operation =
    enum(u8) {
        insert = 1,
        delete = 2,
        update = 3,
    };

const WalEntryHeader = struct {
    magic: [4]u8,
    version: u8,
    operation: Operation,
    payload_len: u32,
    sequence: u64,
    checksum: u32,
};
const crc32 = std.hash.Crc32;
fn checksum(
    data: []const u8,
) u32 {
    return crc32.hash(data);
}
pub const wal = struct {
    file: std.Io.File,
    next_sequence: u64,

    pub fn init(
        io: anytype,
        path: []const u8,
    ) !wal {
        const file = try std.Io.Dir.cwd().openFile(
            io,
            path,
            .{
                .mode = .read_write,
            },
        );

        return .{
            .file = file,
            .next_sequence = 1,
        };
    }

    pub fn denit(
        self: *wal,
        io: anytype,
    ) void {
        self.file.close(io);
    }

    pub fn append(
        self: *wal,
        io: anytype,
        operation: Operation,
        payload: []const u8,
    ) !u64 {
        const sequence = self.next_sequence;

        self.next_sequence += 1;

        const header = WalEntryHeader{
            .magic = .{ 'Z', 'W', 'A', 'L' },
            .version = 1,
            .operation = operation,
            .payload_len = @intCast(
                payload.len,
            ),
            .sequence = sequence,
            .checksum = checksum(payload),
        };

        var write_buf: [4096]u8 = undefined;
        var w = self.file.writer(io, &write_buf);

        try w.seekTo(.end, 0);
        try w.interface.writeAll(std.mem.asBytes(&header));
        try w.interface.writeAll(payload);
        //vide le tampon de l'application vers le systeme d'exploitation
        try w.flush();
        // pour forcer le systeme d'exploitation à ecrire physiquement
        // les données sur le disque
        try self.file.sync(io);
        return sequence;
    }

    fn readheader(
        file: *std.Io.File,
        io: anytype,
    ) !?WalEntryHeader {
        var header: WalEntryHeader = undefined;

        const bytes = std.mem.asBytes(&header);
        var read_buf: [256]u8 = undefined;
        var r = file.reader(io, &read_buf);
        const reader = &r.interface;
        const amt = try reader.readSliceShort(bytes);

        // si on a lu 0 octet des le depart on arrete le fichier
        if (amt == 0) {
            return null;
        }
        // si on a lu un morceau mais pas la structure entiere ce que le fichier est tronqué
        if (amt < bytes.len) {
            return error.TruncateWal;
        }
        // verification magique
        if (!std.mem.eql(u8, &header.magic, "ZWAL")) {
            return error.InvalidMagic;
        }

        return header;
    }

    pub const ReplayFn = *const fn (
        operation: Operation,
        payload: []const u8,
    ) anyerror!void;

    pub fn replay(
        io: anytype,
        allocator: std.mem.Allocator,
        path: []const u8,
        callback: ReplayFn,
    ) !void {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var payload_buf: [4096]u8 = undefined;
        var r = file.reader(io, &payload_buf);

        while (try readheader(&file, io)) |header| {
            const payload = try allocator.alloc(u8, header.payload_len);
            defer allocator.free(payload);

            try r.interface.readSliceAll(payload);

            if (checksum(payload) != header.checksum) {
                return error.CorruptedWal;
            }

            try callback(header.operation, payload);
        }
    }

    // Structure pour accumuler les données lues lors du replay (pour vérification)
    const ReplayTracker = struct {
        count: usize = 0,
        allocator: std.mem.Allocator,

        // Notre fonction de rappel (callback) qui correspond à wal.ReplayFn
        pub fn callback(operation: Operation, payload: []const u8) anyerror!void {
            // Dans un vrai système, vous appliqueriez ici la modification à votre base de données
            switch (operation) {
                .insert => {
                    try std.testing.expectEqualSlices(u8, "Hello Zig 0.16", payload);
                },
                .update => {
                    try std.testing.expectEqualSlices(u8, "WAL is working", payload);
                },
                .delete => return error.UnexpectedOperation,
            }
        }
    };

    test "WAL complete cycle: append and replay" {
        // 1. Récupération des outils de test standards de Zig 0.16
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        const path = "test_run.wal";

        // Sécurité : Supprime le fichier s'il existait déjà d'un test précédent
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        // Nettoyage automatique du fichier à la fin du test
        defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

        // 2. PHASE D'ÉCRITURE
        {
            // Création initiale du fichier WAL via l'API standard pour que wal.init puisse l'ouvrir
            var create_file = try std.Io.Dir.cwd().createFile(io, path, .{});
            create_file.close(io);

            // Initialisation de notre structure WAL
            var my_wal = try wal.init(io, path);
            defer my_wal.deinit(io);

            // Écriture de la première entrée
            const seq1 = try my_wal.append(io, .insert, "Hello Zig 0.16");
            try std.testing.expectEqual(@as(u64, 1), seq1);

            // Écriture de la deuxième entrée
            const seq2 = try my_wal.append(io, .update, "WAL is working");
            try std.testing.expectEqual(@as(u64, 2), seq2);
        }

        // 3. PHASE DE LECTURE / REPLAY
        // Appel de la méthode replay qui va ouvrir le fichier, parser les structures et exécuter notre logique
        try wal.replay(io, allocator, path, ReplayTracker.callback);
    }
};
