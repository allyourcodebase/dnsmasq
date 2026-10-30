const std = @import("std");

const Io = std.Io;

/// Copies a source file, inserting lines next to others: it is how the OpenTelemetry hooks get into upstream's code.
///
/// ```
/// patch <input> <output> (--before | --after) <line> <text>...
/// ```
///
/// Inserts `<text>` before or after the one line whose content, whitespace aside, is `<line>`.
/// Fails if there is none or more than one: upstream changed, and the patch must follow.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 3 or (args.len - 3) % 3 != 0) return error.Usage;

    const cwd = Io.Dir.cwd();
    const source = try cwd.readFileAlloc(io, args[1], alloc, .limited(16 * 1024 * 1024));

    // For each line, what to insert before it and after it
    var lines: std.ArrayList([]const u8) = .empty;
    var lines_iterator = std.mem.splitScalar(u8, source, '\n');
    while (lines_iterator.next()) |line| try lines.append(alloc, line);
    const before = try alloc.alloc(std.ArrayList([]const u8), lines.items.len);
    const after = try alloc.alloc(std.ArrayList([]const u8), lines.items.len);
    @memset(before, .empty);
    @memset(after, .empty);

    var edits = std.mem.window([]const u8, args[3..], 3, 3);
    while (edits.next()) |edit| {
        const anchor = std.mem.trim(u8, edit[1], " \t");
        var found: ?usize = null;
        for (lines.items, 0..) |line, i| {
            if (!std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), anchor)) continue;
            if (found != null) {
                std.log.err("{s}: the line \"{s}\" is there more than once", .{ args[1], anchor });
                return error.AmbiguousAnchor;
            }
            found = i;
        }
        const index = found orelse {
            std.log.err("{s}: the line \"{s}\" is not there", .{ args[1], anchor });
            return error.AnchorNotFound;
        };
        if (std.mem.eql(u8, edit[0], "--before")) {
            try before[index].append(alloc, edit[2]);
        } else if (std.mem.eql(u8, edit[0], "--after")) {
            try after[index].append(alloc, edit[2]);
        } else return error.Usage;
    }

    var output: std.ArrayList(u8) = .empty;
    for (lines.items, before, after, 0..) |line, inserted_before, inserted_after, i| {
        for (inserted_before.items) |text| try output.print(alloc, "{s}\n", .{text});
        try output.appendSlice(alloc, line);
        if (i + 1 < lines.items.len) try output.append(alloc, '\n');
        for (inserted_after.items) |text| try output.print(alloc, "{s}\n", .{text});
    }

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = output.items });
}
