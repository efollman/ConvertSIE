/// XLSX export — writes channels in the same side-by-side layout as CSV but in
/// Excel 2007+ (.xlsx) format, using the libxlsxwriter C library so the
/// resulting file is guaranteed to satisfy Excel's strict OOXML reader (no
/// "Repaired Records" warning on open).
const std = @import("std");
const common = @import("common.zig");

// ---------------------------------------------------------------------------
// libxlsxwriter extern declarations
//
// Only the subset we actually use. Mirrors the public API in
// `include/xlsxwriter.h`. Types are kept opaque — we never inspect their
// fields, only pass the pointers back to the library.
// ---------------------------------------------------------------------------

const lxw_workbook = opaque {};
const lxw_worksheet = opaque {};
const lxw_format = opaque {};

const lxw_row_t = u32;
const lxw_col_t = u16;

extern fn workbook_new(filename: [*:0]const u8) ?*lxw_workbook;
extern fn workbook_add_worksheet(wb: *lxw_workbook, sheetname: ?[*:0]const u8) ?*lxw_worksheet;
extern fn workbook_add_format(wb: *lxw_workbook) ?*lxw_format;
extern fn workbook_close(wb: *lxw_workbook) u8;
extern fn format_set_bold(fmt: *lxw_format) void;
extern fn worksheet_write_string(
    ws: *lxw_worksheet,
    row: lxw_row_t,
    col: lxw_col_t,
    str: [*:0]const u8,
    fmt: ?*lxw_format,
) u8;
extern fn worksheet_write_number(
    ws: *lxw_worksheet,
    row: lxw_row_t,
    col: lxw_col_t,
    num: f64,
    fmt: ?*lxw_format,
) u8;
extern fn worksheet_write_blank(
    ws: *lxw_worksheet,
    row: lxw_row_t,
    col: lxw_col_t,
    fmt: ?*lxw_format,
) u8;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    var data = try common.readSieFile(allocator, input_path);
    defer data.deinit();

    const header_rows: u32 = 7;
    const excel_max_rows: u32 = 1_048_576;
    const max_data_per_sheet: u32 = excel_max_rows - header_rows;
    const raw_data_rows: u32 = @intCast(data.maxRows());
    const num_sheets: u32 = if (raw_data_rows <= max_data_per_sheet)
        1
    else
        (raw_data_rows + max_data_per_sheet - 1) / max_data_per_sheet;

    if (num_sheets > 1) {
        const stderr = std.fs.File.stderr();
        var stderr_buf: [4096]u8 = undefined;
        var w = stderr.writer(&stderr_buf);
        w.interface.print(
            "Warning: Data has {d} rows, exceeding Excel's {d} row limit. Splitting across {d} sheets.\n",
            .{ raw_data_rows, excel_max_rows, num_sheets },
        ) catch {};
    }

    const wb = workbook_new(output_path.ptr) orelse return error.XlsxWorkbookCreateFailed;
    // From here on, on error we still must close the workbook to release the
    // temp files libxlsxwriter accumulates while building the package.
    errdefer _ = workbook_close(wb);

    const bold = workbook_add_format(wb) orelse return error.XlsxFormatCreateFailed;
    format_set_bold(bold);

    var name_buf: [32]u8 = undefined;
    for (0..num_sheets) |i| {
        const sheet_name: [:0]const u8 = if (num_sheets == 1)
            try std.fmt.bufPrintZ(&name_buf, "Data", .{})
        else
            try std.fmt.bufPrintZ(&name_buf, "Data {d}", .{i + 1});

        const ws = workbook_add_worksheet(wb, sheet_name.ptr) orelse
            return error.XlsxWorksheetCreateFailed;

        const start: u32 = @intCast(i * max_data_per_sheet);
        const end: u32 = @min(start + max_data_per_sheet, raw_data_rows);
        try writeSheet(allocator, ws, bold, &data, start, end);
    }

    const close_err = workbook_close(wb);
    if (close_err != 0) return error.XlsxWorkbookCloseFailed;
}

// ---------------------------------------------------------------------------
// Per-sheet population
//
// Layout matches the previous implementation (and CSV export):
//   metadata pairs (key, value) → blank row → 4 grouped header rows →
//   data rows. Group separator columns are left blank.
// ---------------------------------------------------------------------------

fn writeSheet(
    allocator: std.mem.Allocator,
    ws: *lxw_worksheet,
    bold: *lxw_format,
    data: *const common.ExportData,
    start_data_row: u32,
    end_data_row: u32,
) !void {
    var row: lxw_row_t = 0;

    // ── File / test metadata: column A = key, column B = value ────────────
    for (data.meta_pairs.items) |p| {
        try writeStringCell(allocator, ws, row, 0, p.key, bold);
        try writeStringCell(allocator, ws, row, 1, p.value, null);
        row += 1;
    }

    // Blank separator row
    row += 1;

    // ── Channel name row ──────────────────────────────────────────────────
    try writeStringCell(allocator, ws, row, 0, "Channel", bold);
    {
        var col: lxw_col_t = 1;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1; // blank separator
            if (grp.is_timeseries) {
                col += 1; // shared time column placeholder
                for (grp.channel_indices.items) |ci| {
                    try writeStringCell(allocator, ws, row, col, data.channels.items[ci].name, bold);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeStringCell(allocator, ws, row, col, ch.name, bold);
                col += @intCast(if (ch.is_raw_can) 2 else ch.dim_data.items.len);
            }
        }
    }
    row += 1;

    // ── Units row ─────────────────────────────────────────────────────────
    try writeStringCell(allocator, ws, row, 0, "Units", bold);
    {
        var col: lxw_col_t = 1;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1;
            if (grp.is_timeseries) {
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    try writeStringCell(allocator, ws, row, col, data.channels.items[ci].units, null);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeStringCell(allocator, ws, row, col, ch.units, null);
                col += @intCast(if (ch.is_raw_can) 2 else ch.dim_data.items.len);
            }
        }
    }
    row += 1;

    // ── Sample-rate row ───────────────────────────────────────────────────
    try writeStringCell(allocator, ws, row, 0, "Sample Rate", bold);
    {
        var col: lxw_col_t = 1;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1;
            if (grp.is_timeseries) {
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    try writeStringCell(allocator, ws, row, col, data.channels.items[ci].sample_rate, null);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeStringCell(allocator, ws, row, col, ch.sample_rate, null);
                col += @intCast(if (ch.is_raw_can) 2 else ch.dim_data.items.len);
            }
        }
    }
    row += 1;

    // ── Dimension labels row (time label + value-dim names) ───────────────
    try writeStringCell(allocator, ws, row, 0, "Dimension", bold);
    {
        var col: lxw_col_t = 1;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1;
            if (grp.is_timeseries) {
                const first_ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeStringCell(allocator, ws, row, col, first_ch.time_label, bold);
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    const ch = &data.channels.items[ci];
                    const lbl = if (ch.dim_names.items.len > 1) ch.dim_names.items[1] else "";
                    try writeStringCell(allocator, ws, row, col, lbl, bold);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                if (ch.is_raw_can) {
                    try writeStringCell(allocator, ws, row, col, ch.time_label, bold);
                    col += 1;
                    try writeStringCell(allocator, ws, row, col, "Data", bold);
                    col += 1;
                } else {
                    for (ch.dim_names.items) |dn| {
                        try writeStringCell(allocator, ws, row, col, dn, bold);
                        col += 1;
                    }
                }
            }
        }
    }
    row += 1;

    // ── Data rows ─────────────────────────────────────────────────────────
    for (start_data_row..end_data_row) |r| {
        // Column 0 is the row-label column; data rows leave it blank.
        var col: lxw_col_t = 1;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1; // blank separator

            if (grp.is_timeseries) {
                const first_ch = &data.channels.items[grp.channel_indices.items[0]];
                if (first_ch.dim_data.items.len > 0 and r < first_ch.dim_data.items[0].items.len) {
                    const t = first_ch.dim_data.items[0].items[r];
                    if (!std.math.isNan(t) and !std.math.isInf(t))
                        _ = worksheet_write_number(ws, row, col, t, null);
                }
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    const ch = &data.channels.items[ci];
                    if (ch.dim_data.items.len > 1 and r < ch.dim_data.items[1].items.len) {
                        const v = ch.dim_data.items[1].items[r];
                        if (!std.math.isNan(v) and !std.math.isInf(v))
                            _ = worksheet_write_number(ws, row, col, v, null);
                    }
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                if (ch.is_raw_can) {
                    if (ch.dim_data.items.len > 0 and r < ch.dim_data.items[0].items.len) {
                        const t = ch.dim_data.items[0].items[r];
                        if (!std.math.isNan(t) and !std.math.isInf(t))
                            _ = worksheet_write_number(ws, row, col, t, null);
                    }
                    col += 1;
                    if (r < ch.raw_can_hex.items.len) {
                        try writeStringCell(allocator, ws, row, col, ch.raw_can_hex.items[r], null);
                    }
                    col += 1;
                } else {
                    for (ch.dim_data.items) |dim| {
                        if (r < dim.items.len) {
                            const v = dim.items[r];
                            if (!std.math.isNan(v) and !std.math.isInf(v))
                                _ = worksheet_write_number(ws, row, col, v, null);
                        }
                        col += 1;
                    }
                }
            }
        }
        row += 1;
    }
}

// ---------------------------------------------------------------------------
// String-cell helper
//
// libxlsxwriter requires NUL-terminated strings. Cell text must also be
// sanitised: characters < 0x20 are illegal in XML 1.0 and embedded
// newlines/tabs render poorly inside a single cell. We allocate a small
// scratch copy per call to do both.
// ---------------------------------------------------------------------------

fn writeStringCell(
    allocator: std.mem.Allocator,
    ws: *lxw_worksheet,
    row: lxw_row_t,
    col: lxw_col_t,
    value: []const u8,
    fmt: ?*lxw_format,
) !void {
    if (value.len == 0) return;

    const buf = try allocator.allocSentinel(u8, value.len, 0);
    defer allocator.free(buf);

    var w: usize = 0;
    for (value) |c| {
        switch (c) {
            '\n', '\r', '\t' => {
                buf[w] = ' ';
                w += 1;
            },
            else => {
                if (c < 0x20) continue;
                buf[w] = c;
                w += 1;
            },
        }
    }
    // Re-assert the sentinel at the actual end of written content. The
    // allocator placed one at index value.len, but `w` may be smaller after
    // stripping control bytes.
    buf[w] = 0;

    if (w == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(buf.ptr);
    _ = worksheet_write_string(ws, row, col, cstr, fmt);
}
