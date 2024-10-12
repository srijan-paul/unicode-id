const std = @import("std");

const out_file = "./src/table.zig";

// A unicode code-point is a 21-bit unsigned integer (usually padded to 32 bits).
// Our job is to determine if for a given unicode code-point, it can be
// used as the start character for an identifier, or somewhere in the middle of one.
//
// We essentially want two sets:
//   1. A set of all unicode codepoints that are valid identifier starts.
//   2. A set of all unicode codepoints that are valid identifier continuations.
//
// To be efficient, a set can be modelled as a an array `[std.math.maxInt(u21)]bool`,
// where `set[x]` is `true` if `x` exists in the set.
//
// But such an array would be too large to be practical.
// Alternatively, we can use a dense bitset of type `[(std.math.maxInt(u21) / 6)]u64`, where
// `((set[(x / 64)] >> (x % 64)) & 0b1)` implies the codepoint `x` is present in the set.
// This way, we use one bit per codepoint.
// Even still, the size of this array ends up being ~262 KB - not a tragedy, but
// we can do better.
// TODO: explain

// download the the unicode codepoint dictionary from unicode.org
fn downloadUnicodeSpec(allocator: std.mem.Allocator, dst_path: []const u8) !void {
    if (std.fs.accessAbsolute(dst_path, .{})) {
        // file exists already. delete it.
        try std.fs.deleteFileAbsolute(dst_path);
    } else |_| {
        // if access failed, that's fine.
        // It means that (most likely) the file
        // doesn't already exist - which is exactly what we want anyway
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://www.unicode.org/Public/zipped/16.0.0/UCD.zip");

    var hd_buf: [1024]u8 = undefined;
    var req = try std.http.Client.open(&client, .GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .server_header_buffer = &hd_buf,
    });

    defer req.deinit();

    try req.send();
    try req.finish();

    try req.wait();

    const zip_file = try std.fs.createFileAbsolute(dst_path, .{});
    defer zip_file.close();

    const fwriter = zip_file.writer();
    const req_reader = req.reader();

    var buf = [_]u8{0} ** 1024;
    while (true) {
        const n_bytes = try req_reader.read(&buf);
        if (n_bytes == 0) break;
        std.debug.assert(try fwriter.write(buf[0..n_bytes]) == n_bytes);
    }

    std.log.info("downloaded unicode codepoint dictionary in {s}", .{dst_path});
}

fn unzipUcd(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dir_path = std.fs.path.dirname(path) orelse
        std.debug.panic("invalid ucd dict path.", .{});

    const extract_dir_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ dir_path, "ucd" },
    );

    // delete the extract dir if it exists.
    if (std.fs.accessAbsolute(extract_dir_path, .{})) {
        try std.fs.deleteTreeAbsolute(extract_dir_path);
    } else |err| {
        if (err != std.fs.Dir.AccessError.FileNotFound) {
            return err;
        }
    }

    try std.fs.makeDirAbsolute(extract_dir_path);
    var dir = try std.fs.openDirAbsolute(extract_dir_path, .{});
    defer dir.close();

    const fzip = try std.fs.openFileAbsolute(path, .{});
    defer fzip.close();
    const fstream = fzip.seekableStream();

    try std.zip.extract(dir, fstream, .{});
    std.log.info("Unzipped the archive at {s}", .{extract_dir_path});

    return extract_dir_path;
}

const IdPropertyKind = enum { start, continuation };
const ParsedLine = struct {
    start: u32,
    end: u32,
    kind: IdPropertyKind,
};

fn parseLine(text: []const u8, kind: IdPropertyKind) !?ParsedLine {
    if (std.mem.indexOf(u8, text, "..")) |i| {
        const r_start = text[0..i];
        const r_end = text[i + 2 ..];

        const start = try std.fmt.parseInt(u32, r_start, 16);
        const end = try std.fmt.parseInt(u32, r_end, 16);
        return .{ .start = start, .end = end + 1, .kind = kind };
    } else {
        const x = try std.fmt.parseInt(u32, text, 16);
        return .{ .start = x, .end = x + 1, .kind = kind };
    }
}

const U32Set = std.AutoArrayHashMap(u32, void);

/// parse the unicode derived properties file and return a set of
/// id_starts and a set of id_continues.
fn parseFile(allocator: std.mem.Allocator, contents: []const u8) !struct { U32Set, U32Set } {
    var id_starts = U32Set.init(allocator);
    var id_contts = U32Set.init(allocator);

    var lines_iter = std.mem.splitScalar(u8, contents, '\n');

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) {
            continue;
        }

        const kind: IdPropertyKind = if (std.mem.indexOf(u8, line, "ID_Start")) |_|
            .start
        else if (std.mem.indexOf(u8, line, "ID_Continue")) |_|
            .continuation
        else
            continue;

        const space_index = std.mem.indexOfScalar(u8, line, ' ') orelse
            line.len;
        const to_parse = line[0..space_index];
        const parsed = try parseLine(to_parse, kind) orelse continue;

        if (kind == .start) {
            for (parsed.start..parsed.end) |x| {
                try id_starts.put(@intCast(x), {});
            }
        } else {
            for (parsed.start..parsed.end) |x| {
                try id_contts.put(@intCast(x), {});
            }
        }
    }

    return .{ id_starts, id_contts };
}

const Chunk = [16]u32; // One chunk = 512 bits
const default_chunk: Chunk = .{0} ** 16;

fn toTrie(allocator: std.mem.Allocator, set: *const U32Set) !struct { []u32, []u64 } {
    const chunk_size: usize = 64; // bytes
    const chunk_nbits = chunk_size * 8;
    const n_codepoints: usize = std.math.maxInt(u21) + 1;
    const n_chunks: usize = n_codepoints / chunk_nbits;

    // maps an index in the array of chunk indices (root of trie)
    // to the 512-bit chunk value it corresponds to.
    var chunk_at_index_root = std.AutoArrayHashMap(usize, Chunk).init(allocator);
    defer chunk_at_index_root.deinit();

    // maps a 512-bit chunk to its offset in the array of flat chunks
    // (a.k.a. leaf node of trie).
    var leaf_offset_of_chunk = std.AutoArrayHashMap(Chunk, usize).init(allocator);
    defer leaf_offset_of_chunk.deinit();

    for (0..n_chunks) |i_chunk| {
        // initialize the chunk with all zeros
        var chunk: Chunk = default_chunk;
        // iterate over every 32-bit piece of the chunk
        for (0.., &chunk) |i, *piece| {
            // for each bit in the piece, set it to 1
            // if the codepoint is in the set.
            for (0..32) |bit| {
                // each bit corresponds to a unique codepoint
                const cp: u32 = @intCast(i_chunk * chunk_nbits + i * 32 + bit);
                const is_set: u32 = if (set.contains(cp)) 1 else 0;
                // set the bit in the piece
                piece.* = piece.* | (is_set << @as(u5, @intCast(bit)));
            }
        }

        // store the chunk in the root map
        try chunk_at_index_root.put(i_chunk, chunk);
        const gop = try leaf_offset_of_chunk.getOrPut(chunk);
        if (!gop.found_existing) {
            // each chunk is 16 pieces.
            gop.value_ptr.* = (leaf_offset_of_chunk.count() - 1);
        }
    }

    var root = try allocator.alloc(u32, n_chunks);
    for (0..n_chunks) |i| {
        const chunk = chunk_at_index_root.get(i) orelse
            std.debug.panic("missing pattern for chunk #{d}\n", .{i});
        root[i] = @intCast(leaf_offset_of_chunk.get(chunk) orelse
            std.debug.panic("missing chunk {d}\n", .{i}));
    }

    var leaf = std.ArrayList(u64).init(allocator);
    defer leaf.deinit();

    for (leaf_offset_of_chunk.keys()) |*pieces| {
        for (pieces) |x| {
            try leaf.append(x);
        }
    }

    return .{ root, try leaf.toOwnedSlice() };
}

fn writeTrie(
    allocator: std.mem.Allocator,
    codepoint_set: *const U32Set,
    f: std.fs.File,
    name: []const u8,
) !void {
    _ = try f.write("\npub const ");
    _ = try f.write(name);
    _ = try f.write("_root = [_]u8 {");

    const root, const leaf = try toTrie(allocator, codepoint_set);
    defer allocator.free(root);
    defer allocator.free(leaf);

    var buf: [1024]u8 = undefined;
    for (0.., root) |i, x| {
        if (i % 16 == 0) {
            _ = try f.write("\n\t");
        }

        std.debug.assert(i < root.len);

        const line = try (if (i != root.len - 1)
            std.fmt.bufPrint(&buf, "0x{x:0>2}, ", .{x})
        else
            std.fmt.bufPrint(&buf, "0x{x:0>2} ", .{x}));

        _ = try f.write(line);
    }

    _ = try f.write("};\n");

    _ = try f.write("\npub const ");
    _ = try f.write(name);
    _ = try f.write("_leaf = [_]u64 {");

    for (0.., leaf) |i, x| {
        if (i % 8 == 0) {
            _ = try f.write("\n\t");
        }

        const line = try (if (i != leaf.len - 1)
            std.fmt.bufPrint(&buf, "0x{x:0>2}, ", .{x})
        else
            std.fmt.bufPrint(&buf, "0x{x:0>2} ", .{x}));

        _ = try f.write(line);
    }

    _ = try f.write("\n};\n");
}

/// Generate the `table.zig` file that contains
/// the tables for id_start and id_continue codepoints.
fn writeFile(allocator: std.mem.Allocator, id_starts: *const U32Set, id_contt: *const U32Set) !void {
    const cwd = std.fs.cwd();
    const f = try cwd.createFile(out_file, .{});
    defer f.close();

    _ = try f.write(
        "// This is a generated file.\n" ++
            "// See: ./src/tools/generate.zig\n" ++
            "pub const chunk_size = 64;\n",
    );

    try writeTrie(allocator, id_starts, f, "is_id_start");
    try writeTrie(allocator, id_contt, f, "is_id_continue");

    std.log.info("Wrote tries to table.zig", .{});
}

fn readAndParseFile(allocator: std.mem.Allocator, filepath: []const u8) !struct { U32Set, U32Set } {
    const f = try std.fs.openFileAbsolute(filepath, .{});
    const contents = try f.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(contents);

    return try parseFile(allocator, contents);
}

const extracted_path = "/tmp/ucd";

fn exists(filepath: []const u8) bool {
    if (std.fs.accessAbsolute(filepath, .{})) {
        return true;
    } else |_| {
        return false;
    }
}

// Download the unicode codepoint database,
// parse the DerivedCoreProperties.txt file,
// and return two sets: one that contains all valid ID_Starts and
// another that contains all valid ID_Continues.
pub fn downloadAndParseProperties(allocator: std.mem.Allocator) !struct { U32Set, U32Set } {
    if (!exists(extracted_path)) {
        const zip_path = "/tmp/ucd.zip";
        try downloadUnicodeSpec(allocator, zip_path);

        const outfile = try unzipUcd(allocator, zip_path);
        allocator.free(outfile);
    }

    const derived_properties_filepath = try std.fs.path.join(
        allocator,
        &[_][]const u8{
            extracted_path,
            "DerivedCoreProperties.txt",
        },
    );

    defer allocator.free(derived_properties_filepath);
    return try readAndParseFile(allocator, derived_properties_filepath);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    if (!exists(extracted_path)) {
        const zip_path = "/tmp/ucd.zip";
        try downloadUnicodeSpec(allocator, zip_path);
        const s = try unzipUcd(allocator, zip_path);
        defer allocator.free(s);
    }

    const derived_properties_filepath = try std.fs.path.join(
        allocator,
        &[_][]const u8{
            extracted_path,
            "DerivedCoreProperties.txt",
        },
    );
    defer allocator.free(derived_properties_filepath);

    var id_starts, var id_contts =
        try readAndParseFile(allocator, derived_properties_filepath);

    defer id_starts.deinit();
    defer id_contts.deinit();

    try writeFile(allocator, &id_starts, &id_contts);
}
