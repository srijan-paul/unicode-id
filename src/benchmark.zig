const unicode_id = @import("./root.zig");
const std = @import("std");

pub fn main() void {
    const start = std.time.nanoTimestamp();
    for (0..std.math.maxInt(u21)) |ch| {
        _ = unicode_id.canStartId(@truncate(ch));
        _ = unicode_id.canContinueId(@truncate(ch));
    }
    const end = std.time.nanoTimestamp();
    const elapsed = end - start;
    const average = @divTrunc(elapsed, @as(i128, std.math.maxInt(u21)));

    std.debug.print("Average time per codepoint: {} ns\n", .{average});
}
