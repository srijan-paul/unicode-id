const std = @import("std");
const table = @import("./table.zig");

const n_pieces_in_chunk = 16;
const n_bits_in_piece = 32;

/// Checks if a unicode code point is the valid identifier start
pub fn canStartId(ch: u32) bool {
    if (ch < 128) {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or ch == '$' or ch == '_';
    }

    const chunk_number = ch / 512;
    // offset of the first u32 in the chunk in the leaf table.
    const chunk_offset = table.is_id_start_root[chunk_number];

    // now codepoint is between [0, 512).
    const c = ch - (chunk_number * 512);
    // Find the 32-bit piece inside the chunk that contains the codepoint's flag.
    // offset of the 32-bit piece in the leaf array.
    const piece_offset = chunk_offset + (c / 32);
    // bit-position of the codepoint inside the 32-bit piece.
    const bitpos_in_piece: u5 = @truncate(c % 32);

    // find the u32 piece that ch belongs to.
    const piece = table.is_id_start_leaf[piece_offset];

    // find the bit in that u32 that corresponds to this codepoint
    // and check if its set.
    return (piece >> bitpos_in_piece) & 1 == 1;
}

/// Checks if a unicode code point is the valid identifier continuation
pub fn canContinueId(ch: u32) bool {
    if (ch < 128) {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            ch == '_' or
            (ch >= '0' and ch <= '9');
    }

    const chunk_number = ch / 512;
    // offset of the first u32 in the chunk in the leaf table.
    const chunk_offset = table.is_id_continue_root[chunk_number];

    // now codepoint is between [0, 512).
    const c = ch - (chunk_number * 512);
    // Find the 32-bit piece inside the chunk that contains the codepoint's flag.
    // offset of the 32-bit piece in the leaf array.
    const piece_offset = chunk_offset + (c / 32);
    // bit-position of the codepoint inside the 32-bit piece.
    const bitpos_in_piece: u5 = @truncate(c % 32);

    // find the u32 piece that ch belongs to.
    const piece = table.is_id_continue_leaf[piece_offset];

    // find the bit in that u32 that corresponds to this codepoint
    // and check if its set.
    return (piece >> bitpos_in_piece) & 1 == 1;
}

const t = std.testing;
const g = @import("./tools/generate.zig");

test {
    var id_starts, var id_contts = try g.downloadAndParseProperties(t.allocator);
    defer id_starts.deinit();
    defer id_contts.deinit();

    for (0..std.math.maxInt(u21)) |ch| {
        const expected = id_starts.contains(@intCast(ch)) or ch == '_' or ch == '$';
        if (t.expectEqual(expected, canStartId(@intCast(ch)))) {} else |err| {
            std.debug.print("ID Start failed for codepoint:  ({d})\n", .{ch});
            return err;
        }
    }

    for (0..std.math.maxInt(u21)) |ch| {
        const expected = id_contts.contains(@intCast(ch));
        if (t.expectEqual(expected, canContinueId(@intCast(ch)))) {} else |err| {
            std.debug.print("ID Continue failed for codepoint:  ({d})\n", .{ch});
            return err;
        }
    }
}
