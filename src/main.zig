const tables = @import("table.zig");

const std = @import("std");
pub fn main() void {
    const size =
        (tables.is_id_start_leaf.len) * @sizeOf(u64) +
        (tables.is_id_continue_leaf.len) * @sizeOf(u64) +
        (tables.is_id_start_root.len) * @sizeOf(u8) +
        (tables.is_id_continue_root.len) * @sizeOf(u8);

    std.debug.print(
        "{d}kB (id-start-root len: {d}) (id-continue-root len: {d})\n",
        .{
            size / 1000,
            tables.is_id_start_root.len,
            tables.is_id_continue_root.len,
        },
    );
}
