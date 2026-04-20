/// CSV export — writes channels in grouped tables: time-series channels that share
/// the same sample rate and row count are combined under a common time vector.
const std = @import("std");
const common = @import("common.zig");

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    var data = try common.readSieFile(allocator, input_path);
    defer data.deinit();

    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var write_buf: [8192]u8 = undefined;
    var w = out_file.writer(&write_buf);
    const wr = &w.interface;

    // ── File metadata ─────────────────────────────────────────────────────
    try wr.print("Test Name: {s}\n", .{data.test_name});
    try wr.print("Start Time: {s}\n", .{data.start_time});
    try wr.print("\n", .{});

    if (data.groups.items.len == 0) {
        try wr.flush();
        return;
    }

    // ── Channel name row ──────────────────────────────────────────────────
    try writeMetaRow(wr, &data, .name);
    // ── Units row ─────────────────────────────────────────────────────────
    try writeMetaRow(wr, &data, .units);
    // ── Sample rate row ───────────────────────────────────────────────────
    try writeMetaRow(wr, &data, .rate);
    // ── Column header row (time label + dim labels) ───────────────────────
    try writeDimRow(wr, &data);

    // ── Data rows ─────────────────────────────────────────────────────────
    const max_rows = data.maxRows();
    for (0..max_rows) |row| {
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) try wr.print(",", .{}); // blank separator column

            if (grp.is_timeseries) {
                // Shared time from first channel's dim 0
                const first_ch = &data.channels.items[grp.channel_indices.items[0]];
                if (first_ch.dim_data.items.len > 0 and row < first_ch.dim_data.items[0].items.len) {
                    try wr.print("{d}", .{first_ch.dim_data.items[0].items[row]});
                }
                // One value column per channel (dim 1)
                for (grp.channel_indices.items) |ci| {
                    const ch = &data.channels.items[ci];
                    try wr.print(",", .{});
                    if (ch.dim_data.items.len > 1 and row < ch.dim_data.items[1].items.len) {
                        try wr.print("{d}", .{ch.dim_data.items[1].items[row]});
                    }
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                if (ch.is_raw_can) {
                    // Time (dim 0) + raw hex string
                    if (ch.dim_data.items.len > 0 and row < ch.dim_data.items[0].items.len) {
                        try wr.print("{d}", .{ch.dim_data.items[0].items[row]});
                    }
                    try wr.print(",", .{});
                    if (row < ch.raw_can_hex.items.len) {
                        try wr.print("{s}", .{ch.raw_can_hex.items[row]});
                    }
                } else {
                    // All dims as separate columns
                    for (ch.dim_data.items, 0..) |dim, d| {
                        if (d > 0) try wr.print(",", .{});
                        if (row < dim.items.len) {
                            try wr.print("{d}", .{dim.items[row]});
                        }
                    }
                }
            }
        }
        try wr.print("\n", .{});
    }
    try wr.flush();
}

// ---------------------------------------------------------------------------
// Header row helpers
// ---------------------------------------------------------------------------

const MetaField = enum { name, units, rate };

fn writeMetaRow(wr: *std.Io.Writer, data: *const common.ExportData, field: MetaField) !void {
    for (data.groups.items, 0..) |*grp, gi| {
        if (gi > 0) try wr.print(",", .{}); // blank separator

        if (grp.is_timeseries) {
            try wr.print(",", .{}); // blank for shared time column
            for (grp.channel_indices.items, 0..) |ci, i| {
                if (i > 0) try wr.print(",", .{});
                const ch = &data.channels.items[ci];
                const val: []const u8 = switch (field) {
                    .name => ch.name,
                    .units => ch.units,
                    .rate => ch.sample_rate,
                };
                try wr.print("{s}", .{csvEscape(val)});
            }
        } else {
            const ch = &data.channels.items[grp.channel_indices.items[0]];
            const col_count: usize = if (ch.is_raw_can) 2 else ch.dim_data.items.len;
            const val: []const u8 = switch (field) {
                .name => ch.name,
                .units => ch.units,
                .rate => ch.sample_rate,
            };
            try wr.print("{s}", .{csvEscape(val)});
            // Pad remaining dim columns with empty
            for (1..@max(col_count, 1)) |_| try wr.print(",", .{});
        }
    }
    try wr.print("\n", .{});
}

fn writeDimRow(wr: *std.Io.Writer, data: *const common.ExportData) !void {
    for (data.groups.items, 0..) |*grp, gi| {
        if (gi > 0) try wr.print(",", .{});

        if (grp.is_timeseries) {
            const first_ch = &data.channels.items[grp.channel_indices.items[0]];
            try wr.print("{s}", .{csvEscape(first_ch.time_label)});
            for (grp.channel_indices.items) |ci| {
                try wr.print(",", .{});
                const ch = &data.channels.items[ci];
                // Value dim label: use dim_names[1] if set, else empty
                const lbl = if (ch.dim_names.items.len > 1) ch.dim_names.items[1] else "";
                try wr.print("{s}", .{csvEscape(lbl)});
            }
        } else {
            const ch = &data.channels.items[grp.channel_indices.items[0]];
            if (ch.is_raw_can) {
                try wr.print("{s},Data", .{csvEscape(ch.time_label)});
            } else {
                for (ch.dim_names.items, 0..) |dn, d| {
                    if (d > 0) try wr.print(",", .{});
                    try wr.print("{s}", .{csvEscape(dn)});
                }
            }
        }
    }
    try wr.print("\n", .{});
}

/// CSV "escape" — currently a no-op pass-through.
///
/// Proper RFC 4180 escaping (wrapping the value in double-quotes and doubling
/// any embedded double-quotes when the value contains `,`, `"`, `\n`, or `\r`)
/// would require an allocator-backed buffer. SIE metadata strings (channel
/// names, units, sample rates, dim labels) almost never contain these
/// characters, so we accept the limitation rather than thread an allocator
/// through every header writer. If a value with embedded commas appears in a
/// real-world file, this is the function to upgrade.
fn csvEscape(s: []const u8) []const u8 {
    return s;
}
