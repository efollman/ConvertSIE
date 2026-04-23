/// J1939 CAN error CSV exporter — extracts DM1 diagnostic trouble codes from
/// `message_can` channels in a SIE file and writes them as CSV.
///
/// Behavior mirrors `vector_asc_export.zig`:
/// - Only channels whose `data_type` (or `somat:data_format`) is `message_can`
///   are processed. Non-CAN channels are ignored.
/// - If the SIE file has zero CAN channels the output file is NOT created.
/// - Files with multiple CAN channels produce one combined CSV where each
///   channel's records are written under a header line naming the channel.
const std = @import("std");
const libsie = @import("libsie");
const can_err = @import("can_err.zig");

const SieFile = libsie.SieFile;
const Tag = libsie.Tag;

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    var sf = try SieFile.open(allocator, input_path);
    defer sf.deinit();

    // Per-channel extracted records (owned by caller).
    var channel_results: std.ArrayList(can_err.ChannelRecords) = .empty;
    defer {
        for (channel_results.items) |cr| {
            allocator.free(cr.name);
            allocator.free(cr.records);
        }
        channel_results.deinit(allocator);
    }

    const tests = sf.tests();
    for (tests) |*test_obj| {
        const channels = test_obj.channels();
        for (channels) |*ch| {
            if (!isCanChannel(ch.tags())) continue;

            // Stream the channel's (time, raw CAN frame) rows into two lists.
            var times: std.ArrayList(f64) = .empty;
            defer times.deinit(allocator);
            var raw_owned: std.ArrayList([]u8) = .empty;
            defer {
                for (raw_owned.items) |b| allocator.free(b);
                raw_owned.deinit(allocator);
            }

            var spig = sf.attachSpigot(ch) catch continue;
            defer spig.deinit();

            while (try spig.get()) |out| {
                for (0..out.num_rows) |row| {
                    const ts = out.float64(0, row) orelse continue;
                    const raw = out.raw(1, row) orelse continue;
                    const size: usize = @intCast(raw.size);
                    const copied = try allocator.dupe(u8, raw.ptr[0..size]);
                    try times.append(allocator, ts);
                    try raw_owned.append(allocator, copied);
                }
            }

            // Build a []const []const u8 view for canErrFindr.
            const raw_slices = try allocator.alloc([]const u8, raw_owned.items.len);
            defer allocator.free(raw_slices);
            for (raw_owned.items, 0..) |b, idx| raw_slices[idx] = b;

            const records = can_err.canErrFindr(allocator, times.items, raw_slices, null) catch continue;
            errdefer allocator.free(records);

            const name = try allocator.dupe(u8, ch.name);
            errdefer allocator.free(name);

            try channel_results.append(allocator, .{ .name = name, .records = records });
        }
    }

    if (channel_results.items.len == 0) return; // No CAN data → no file.

    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var write_buf: [16 * 1024]u8 = undefined;
    var fw = out_file.writer(&write_buf);
    const w = &fw.interface;

    if (channel_results.items.len == 1) {
        try can_err.writeCsv(channel_results.items[0].records, w);
    } else {
        try can_err.writeMultiChannelCsv(channel_results.items, w);
    }

    try w.flush();
}

fn isCanChannel(tags: []const Tag) bool {
    for (tags) |*tag| {
        const id = tag.key;
        if (std.mem.eql(u8, id, "data_type") or std.mem.eql(u8, id, "somat:data_format")) {
            const v = tag.string() orelse continue;
            if (std.mem.eql(u8, v, "message_can")) return true;
        }
    }
    return false;
}
