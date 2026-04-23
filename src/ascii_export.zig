/// ASCII text export — writes SIE metadata and channel data to a plain text file.
const std = @import("std");
const libsie = @import("libsie");

const SieFile = libsie.SieFile;
const Tag = libsie.Tag;

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    var sf = try SieFile.open(allocator, input_path);
    defer sf.deinit();

    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var write_buf: [8192]u8 = undefined;
    var w = out_file.writer(&write_buf);

    // ── File summary ──────────────────────────────────────────────────────
    try w.interface.print("ConvertSIE — SIE file export\n\n", .{});
    try w.interface.print("File: {s}\n\n", .{input_path});

    // ── File-level tags ───────────────────────────────────────────────────
    const file_tags = sf.fileTags();
    if (file_tags.len > 0) {
        try w.interface.print("File tags:\n", .{});
        for (file_tags) |*tag| try writeTag(&w.interface, tag, "  ");
        try w.interface.print("\n", .{});
    }

    // ── Tests / channels / dimensions ─────────────────────────────────────
    const tests = sf.tests();
    try w.interface.print("Tests: {d}\n", .{tests.len});

    for (tests) |*test_obj| {
        try w.interface.print("\n  Test id {d}: '{s}'\n", .{ test_obj.id, test_obj.name });

        const test_tags = test_obj.tags();
        for (test_tags) |*tag| try writeTag(&w.interface, tag, "    ");

        const channels = test_obj.channels();
        try w.interface.print("    Channels: {d}\n", .{channels.len});

        for (channels) |*ch| {
            try w.interface.print("\n    Channel id {d}, '{s}':\n", .{ ch.id, ch.name });

            for (ch.tags()) |*tag| try writeTag(&w.interface, tag, "      ");

            for (ch.dimensions()) |*dim| {
                try w.interface.print("      Dimension {d}: '{s}'\n", .{ dim.index, dim.name });
                for (dim.tags()) |*tag| try writeTag(&w.interface, tag, "        ");
            }
        }
    }

    // ── Channel data ──────────────────────────────────────────────────────
    try w.interface.print("\n--- Channel Data ---\n\n", .{});

    for (tests) |*test_obj| {
        const channels = test_obj.channels();
        for (channels) |*ch| {
            try w.interface.print("Channel {d} '{s}'\n", .{ ch.id, ch.name });

            var spig = sf.attachSpigot(ch) catch continue;
            defer spig.deinit();

            while (try spig.get()) |out| {
                for (0..out.num_rows) |row| {
                    for (0..out.num_dims) |dim| {
                        if (dim != 0) try w.interface.print("\t", .{});
                        if (out.float64(dim, row)) |val| {
                            // SIE samples typically originate as f32; print at f32
                            // precision so shortest-round-trip strips spurious f64
                            // noise digits like "0.019999999552965164" → "0.02".
                            const f32_val: f32 = @floatCast(val);
                            try w.interface.print("{d}", .{f32_val});
                        } else if (out.raw(dim, row)) |raw| {
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
    const name = tag.key;
    if (tag.isString()) {
        const value = tag.string() orelse "";
        if (value.len > 80) {
            try iface.print("{s}'{s}': ({d} bytes)\n", .{ prefix, name, value.len });
        } else {
            try iface.print("{s}'{s}': '{s}'\n", .{ prefix, name, value });
        }
    } else {
        try iface.print("{s}'{s}': binary ({d} bytes)\n", .{ prefix, name, tag.valueSize() });
    }
}
