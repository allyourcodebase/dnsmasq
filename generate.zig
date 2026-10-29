const std = @import("std");

const Io = std.Io;
const File = Io.File;

/// Reads upstream's Makefile on stdin, and writes the list of C sources of dnsmasq: its `objs` variable, with `.o` swapped for `.c`
///
/// ```make
/// objs = cache.o rfc1035.o util.o \
///        option.o forward.o
/// ```
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var stdin_file_reader: File.Reader = File.stdin().reader(init.io, try alloc.alloc(u8, 2048));
    var stdout_file_writer: File.Writer = File.stdout().writer(init.io, try alloc.alloc(u8, 2048));
    var input: *Io.Reader = &stdin_file_reader.interface;
    var output: *Io.Writer = &stdout_file_writer.interface;
    defer output.flush() catch unreachable;

    var sources: std.ArrayList([]const u8) = .empty;
    var inside_objs = false;
    while (try input.takeDelimiter('\n')) |line| {
        var rest: []const u8 = line;
        if (!inside_objs) {
            var halves = std.mem.splitScalar(u8, line, '=');
            if (!std.mem.eql(u8, std.mem.trim(u8, halves.first(), " \t"), "objs")) continue;
            inside_objs = true;
            rest = halves.rest();
        }

        var objects = std.mem.tokenizeAny(u8, rest, " \t\\");
        while (objects.next()) |object| {
            const name = std.mem.cutSuffix(u8, object, ".o") orelse return error.NotAnObjectFile;
            try sources.append(alloc, try std.fmt.allocPrint(alloc, "{s}.c", .{name}));
        }

        // A trailing backslash continues the list on the next line
        if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, rest, " \t"), "\\")) break;
    }
    if (sources.items.len == 0) return error.ObjsNotFound;

    try output.writeAll("pub const sources = .{\n");
    for (sources.items) |source| {
        try output.print("    \"{s}\",\n", .{source});
    }
    try output.writeAll("};\n");
}
