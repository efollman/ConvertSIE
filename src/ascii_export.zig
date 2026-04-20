/// ASCII text export — writes SIE metadata and channel data to a plain text file.
const std = @import("std");
const libsie = @import("libsie");

const SieFile = libsie.sie_file.SieFile;
const Tag = libsie.tag.Tag;

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    var sf = try SieFile.open(allocator, input_path);
    defer sf.deinit();

    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var write_buf: [8192]u8 = undefined;
    var w = out_file.writer(&write_buf);

    // ── File summary ──────────────────────────────────────────────────────
    try w.interface.print("ExportSIE — SIE file export\n\n", .{});
    try w.interface.print("File: {s}\n\n", .{input_path});

    // ── File-level tags ───────────────────────────────────────────────────
    const file_tags = sf.getFileTags();
    if (file_tags.len > 0) {
        try w.interface.print("File tags:\n", .{});
        for (file_tags) |*tag| try writeTag(&w.interface, tag, "  ");
        try w.interface.print("\n", .{});
    }

    // ── Tests / channels / dimensions ─────────────────────────────────────
    const tests = sf.getTests();
    try w.interface.print("Tests: {d}\n", .{tests.len});

    for (tests) |*test_obj| {
        try w.interface.print("\n  Test id {d}: '{s}'\n", .{ test_obj.getId(), test_obj.getName() });

        const test_tags = test_obj.getTags();
        for (test_tags) |*tag| try writeTag(&w.interface, tag, "    ");

        const channels = test_obj.getChannels();
        try w.interface.print("    Channels: {d}\n", .{channels.len});

        for (channels) |*ch| {
            try w.interface.print("\n    Channel id {d}, '{s}':\n", .{ ch.getId(), ch.getName() });

            for (ch.getTags()) |*tag| try writeTag(&w.interface, tag, "      ");

            for (ch.getDimensions()) |*dim| {
                try w.interface.print("      Dimension {d}: '{s}'\n", .{ dim.getIndex(), dim.getName() });
                for (dim.getTags()) |*tag| try writeTag(&w.interface, tag, "        ");
            }
        }
    }

    // ── Channel data ──────────────────────────────────────────────────────
    try w.interface.print("\n--- Channel Data ---\n\n", .{});

    for (tests) |*test_obj| {
        const channels = test_obj.getChannels();
        for (channels) |*ch| {
            try w.interface.print("Channel {d} '{s}'\n", .{ ch.getId(), ch.getName() });

            var spig = sf.attachSpigot(ch) catch continue;
            defer spig.deinit();

            while (try spig.get()) |out| {
                for (0..out.num_rows) |row| {
                    for (0..out.num_dims) |dim| {
                        if (dim != 0) try w.interface.print("\t", .{});
                        if (out.getFloat64(dim, row)) |val| {
                            try w.interface.print("{d}", .{val});
                        } else if (out.getRaw(dim, row)) |raw| {
                            const size: usize = @intCast(raw.size);
                            try w.interface.print("0x", .{});
                            for (raw.ptr[0..size]) |byte| {
                                try w.interface.print("{x:0>2}", .{byte});
                            }
                        }
                    }
                    try w.interface.print("\n", .{});
                }
            }
            try w.interface.print("\n", .{});
        }
    }
    try w.interface.flush();
}

fn writeTag(iface: *std.Io.Writer, tag: *const Tag, prefix: []const u8) !void {
    const name = tag.getId();
    if (tag.isString()) {
        const value = tag.getString() orelse "";
        if (value.len > 80) {
            try iface.print("{s}'{s}': ({d} bytes)\n", .{ prefix, name, value.len });
        } else {
            try iface.print("{s}'{s}': '{s}'\n", .{ prefix, name, value });
        }
    } else {
        try iface.print("{s}'{s}': binary ({d} bytes)\n", .{ prefix, name, tag.getValueSize() });
    }
}
