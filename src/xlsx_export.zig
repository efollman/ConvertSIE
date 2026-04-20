/// XLSX export — writes channels in the same side-by-side layout as CSV but in
/// Excel 2007+ (.xlsx) format.  Uses a minimal embedded ZIP writer (STORE method)
/// and generates the required Open XML Spreadsheet markup directly.
const std = @import("std");
const common = @import("common.zig");

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    var data = try common.readSieFile(allocator, input_path);
    defer data.deinit();

    const header_rows: u32 = 7;
    const excel_max_rows: u32 = 1_048_576;
    const max_data_per_sheet: u32 = excel_max_rows - header_rows;
    const raw_data_rows: u32 = @intCast(data.maxRows());
    const num_sheets: u32 = if (raw_data_rows <= max_data_per_sheet) 1 else (raw_data_rows + max_data_per_sheet - 1) / max_data_per_sheet;

    if (num_sheets > 1) {
        const stderr = std.fs.File.stderr();
        var stderr_buf: [4096]u8 = undefined;
        var w = stderr.writer(&stderr_buf);
        w.interface.print("Warning: Data has {d} rows, exceeding Excel's {d} row limit. Splitting across {d} sheets.\n", .{ raw_data_rows, excel_max_rows, num_sheets }) catch {};
    }

    // Generate sheet XML payloads
    var sheets: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (sheets.items) |*s| s.deinit(allocator);
        sheets.deinit(allocator);
    }

    for (0..num_sheets) |i| {
        const start: u32 = @intCast(i * max_data_per_sheet);
        const end: u32 = @min(start + max_data_per_sheet, raw_data_rows);
        var sheet_xml: std.ArrayList(u8) = .empty;
        try buildSheetXml(allocator, &sheet_xml, &data, start, end);
        try sheets.append(allocator, sheet_xml);
    }

    // Write the ZIP/XLSX package
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var zip = ZipWriter.init(file, allocator);
    defer zip.deinit();

    // Dynamic XML for multi-sheet support
    var ct_xml: std.ArrayList(u8) = .empty;
    defer ct_xml.deinit(allocator);
    try buildContentTypesXml(allocator, &ct_xml, num_sheets);

    var wb_xml: std.ArrayList(u8) = .empty;
    defer wb_xml.deinit(allocator);
    try buildWorkbookXml(allocator, &wb_xml, num_sheets);

    var wbr_xml: std.ArrayList(u8) = .empty;
    defer wbr_xml.deinit(allocator);
    try buildWorkbookRelsXml(allocator, &wbr_xml, num_sheets);

    try zip.addFile("[Content_Types].xml", ct_xml.items);
    try zip.addFile("_rels/.rels", rels_xml);
    try zip.addFile("xl/workbook.xml", wb_xml.items);
    try zip.addFile("xl/_rels/workbook.xml.rels", wbr_xml.items);
    try zip.addFile("xl/styles.xml", styles_xml);

    for (sheets.items, 0..) |sheet, i| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "xl/worksheets/sheet{d}.xml", .{i + 1}) catch unreachable;
        try zip.addFile(path, sheet.items);
    }

    try zip.finish();
}

// ===========================================================================
// Sheet XML generation
// ===========================================================================

fn buildSheetXml(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), data: *const common.ExportData, start_data_row: u32, end_data_row: u32) !void {
    const total_cols = data.totalColumns();
    const header_rows: u32 = 7;
    const data_row_count = end_data_row - start_data_row;
    const total_rows = header_rows + data_row_count;

    try appendStr(buf, allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    );

    if (total_cols > 0 and total_rows > 0) {
        var dim_col_buf: [3]u8 = undefined;
        const last_col = colName(&dim_col_buf, total_cols - 1);
        try appendStr(buf, allocator, "<dimension ref=\"A1:");
        try buf.appendSlice(allocator, last_col);
        try appendU32(buf, allocator, total_rows);
        try appendStr(buf, allocator, "\"/>\n");
    }

    try appendStr(buf, allocator, "<sheetData>\n");
    var row_num: u32 = 1;

    // Row 1: Test Name
    try appendStr(buf, allocator, "<row r=\"");
    try appendU32(buf, allocator, row_num);
    try appendStr(buf, allocator, "\">");
    try writeInlineCell(buf, allocator, 0, row_num, "Test Name", true);
    try writeInlineCell(buf, allocator, 1, row_num, data.test_name, false);
    try appendStr(buf, allocator, "</row>\n");
    row_num += 1;

    // Row 2: Start Time
    try appendStr(buf, allocator, "<row r=\"");
    try appendU32(buf, allocator, row_num);
    try appendStr(buf, allocator, "\">");
    try writeInlineCell(buf, allocator, 0, row_num, "Start Time", true);
    try writeInlineCell(buf, allocator, 1, row_num, data.start_time, false);
    try appendStr(buf, allocator, "</row>\n");
    row_num += 1;

    // Row 3: blank
    row_num += 1;

    // ── Grouped header rows 4-7 ───────────────────────────────────────────
    // Row 4: Channel names
    {
        try appendStr(buf, allocator, "<row r=\"");
        try appendU32(buf, allocator, row_num);
        try appendStr(buf, allocator, "\">");
        var col: usize = 0;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1; // blank sep
            if (grp.is_timeseries) {
                col += 1; // blank for shared time column
                for (grp.channel_indices.items) |ci| {
                    try writeInlineCell(buf, allocator, col, row_num, data.channels.items[ci].name, true);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeInlineCell(buf, allocator, col, row_num, ch.name, true);
                col += if (ch.is_raw_can) 2 else ch.dim_data.items.len;
            }
        }
        try appendStr(buf, allocator, "</row>\n");
        row_num += 1;
    }

    // Row 5: Units
    {
        try appendStr(buf, allocator, "<row r=\"");
        try appendU32(buf, allocator, row_num);
        try appendStr(buf, allocator, "\">");
        var col: usize = 0;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1;
            if (grp.is_timeseries) {
                col += 1; // blank for time column
                for (grp.channel_indices.items) |ci| {
                    try writeInlineCell(buf, allocator, col, row_num, data.channels.items[ci].units, false);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeInlineCell(buf, allocator, col, row_num, ch.units, false);
                col += if (ch.is_raw_can) 2 else ch.dim_data.items.len;
            }
        }
        try appendStr(buf, allocator, "</row>\n");
        row_num += 1;
    }

    // Row 6: Sample rate
    {
        try appendStr(buf, allocator, "<row r=\"");
        try appendU32(buf, allocator, row_num);
        try appendStr(buf, allocator, "\">");
        var col: usize = 0;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1;
            if (grp.is_timeseries) {
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    try writeInlineCell(buf, allocator, col, row_num, data.channels.items[ci].sample_rate, false);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeInlineCell(buf, allocator, col, row_num, ch.sample_rate, false);
                col += if (ch.is_raw_can) 2 else ch.dim_data.items.len;
            }
        }
        try appendStr(buf, allocator, "</row>\n");
        row_num += 1;
    }

    // Row 7: Dim labels (time label + value dim names)
    {
        try appendStr(buf, allocator, "<row r=\"");
        try appendU32(buf, allocator, row_num);
        try appendStr(buf, allocator, "\">");
        var col: usize = 0;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1;
            if (grp.is_timeseries) {
                const first_ch = &data.channels.items[grp.channel_indices.items[0]];
                try writeInlineCell(buf, allocator, col, row_num, first_ch.time_label, true);
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    const ch = &data.channels.items[ci];
                    const lbl = if (ch.dim_names.items.len > 1) ch.dim_names.items[1] else "";
                    try writeInlineCell(buf, allocator, col, row_num, lbl, true);
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                if (ch.is_raw_can) {
                    try writeInlineCell(buf, allocator, col, row_num, ch.time_label, true);
                    col += 1;
                    try writeInlineCell(buf, allocator, col, row_num, "Data", true);
                    col += 1;
                } else {
                    for (ch.dim_names.items) |dn| {
                        try writeInlineCell(buf, allocator, col, row_num, dn, true);
                        col += 1;
                    }
                }
            }
        }
        try appendStr(buf, allocator, "</row>\n");
        row_num += 1;
    }

    // ── Data rows ─────────────────────────────────────────────────────────
    for (start_data_row..end_data_row) |r| {
        try appendStr(buf, allocator, "<row r=\"");
        try appendU32(buf, allocator, row_num);
        try appendStr(buf, allocator, "\">");

        var col: usize = 0;
        for (data.groups.items, 0..) |*grp, gi| {
            if (gi > 0) col += 1; // blank sep

            if (grp.is_timeseries) {
                const first_ch = &data.channels.items[grp.channel_indices.items[0]];
                if (first_ch.dim_data.items.len > 0 and r < first_ch.dim_data.items[0].items.len) {
                    const t = first_ch.dim_data.items[0].items[r];
                    if (!std.math.isNan(t) and !std.math.isInf(t))
                        try writeNumberCell(buf, allocator, col, row_num, t);
                }
                col += 1;
                for (grp.channel_indices.items) |ci| {
                    const ch = &data.channels.items[ci];
                    if (ch.dim_data.items.len > 1 and r < ch.dim_data.items[1].items.len) {
                        const v = ch.dim_data.items[1].items[r];
                        if (!std.math.isNan(v) and !std.math.isInf(v))
                            try writeNumberCell(buf, allocator, col, row_num, v);
                    }
                    col += 1;
                }
            } else {
                const ch = &data.channels.items[grp.channel_indices.items[0]];
                if (ch.is_raw_can) {
                    if (ch.dim_data.items.len > 0 and r < ch.dim_data.items[0].items.len) {
                        const t = ch.dim_data.items[0].items[r];
                        if (!std.math.isNan(t) and !std.math.isInf(t))
                            try writeNumberCell(buf, allocator, col, row_num, t);
                    }
                    col += 1;
                    if (r < ch.raw_can_hex.items.len) {
                        try writeInlineCell(buf, allocator, col, row_num, ch.raw_can_hex.items[r], false);
                    }
                    col += 1;
                } else {
                    for (ch.dim_data.items) |dim| {
                        if (r < dim.items.len) {
                            const v = dim.items[r];
                            if (!std.math.isNan(v) and !std.math.isInf(v))
                                try writeNumberCell(buf, allocator, col, row_num, v);
                        }
                        col += 1;
                    }
                }
            }
        }
        try appendStr(buf, allocator, "</row>\n");
        row_num += 1;
    }

    try appendStr(buf, allocator, "</sheetData></worksheet>\n");
}

// ===========================================================================
// Cell writers
// ===========================================================================

fn writeInlineCell(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, col: usize, row: u32, value: []const u8, bold: bool) !void {
    var col_buf: [3]u8 = undefined;
    const cn = colName(&col_buf, col);
    try appendStr(buf, allocator, "<c r=\"");
    try buf.appendSlice(allocator, cn);
    try appendU32(buf, allocator, row);
    if (bold) {
        try appendStr(buf, allocator, "\" t=\"inlineStr\" s=\"1\"><is><t>");
    } else {
        try appendStr(buf, allocator, "\" t=\"inlineStr\"><is><t>");
    }
    try appendXmlEscaped(buf, allocator, value);
    try appendStr(buf, allocator, "</t></is></c>");
}

fn writeNumberCell(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, col: usize, row: u32, value: f64) !void {
    var col_buf: [3]u8 = undefined;
    const cn = colName(&col_buf, col);
    try appendStr(buf, allocator, "<c r=\"");
    try buf.appendSlice(allocator, cn);
    try appendU32(buf, allocator, row);
    try appendStr(buf, allocator, "\"><v>");
    var num_buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch "0";
    try buf.appendSlice(allocator, s);
    try appendStr(buf, allocator, "</v></c>");
}

// ===========================================================================
// XML / string helpers
// ===========================================================================

fn appendStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u32) !void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "0";
    try buf.appendSlice(allocator, s);
}

fn appendXmlEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, c),
        }
    }
}

/// Convert a 0-based column index to an Excel column letter (A, B, …, Z, AA, AB, …).
fn colName(buf: *[3]u8, col_idx: usize) []const u8 {
    var n = col_idx;
    if (n < 26) {
        buf[0] = @intCast('A' + n);
        return buf[0..1];
    }
    n -= 26;
    if (n < 26 * 26) {
        buf[0] = @intCast('A' + n / 26);
        buf[1] = @intCast('A' + n % 26);
        return buf[0..2];
    }
    n -= 26 * 26;
    buf[0] = @intCast('A' + n / (26 * 26));
    buf[1] = @intCast('A' + (n / 26) % 26);
    buf[2] = @intCast('A' + n % 26);
    return buf[0..3];
}

// ===========================================================================
// Minimal ZIP writer (STORE method — std.compress.flate is unfinished in
// Zig 0.15.2 so Deflate is not available; STORE produces valid XLSX files)
// ===========================================================================

const ZipWriter = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    offset: u64,
    entries: std.ArrayList(Entry),

    const Entry = struct {
        name: []const u8,
        local_offset: u64,
        crc32: u32,
        size: u32,
    };

    fn init(file: std.fs.File, allocator: std.mem.Allocator) ZipWriter {
        return .{
            .file = file,
            .allocator = allocator,
            .offset = 0,
            .entries = .empty,
        };
    }

    fn deinit(self: *ZipWriter) void {
        for (self.entries.items) |e| self.allocator.free(e.name);
        self.entries.deinit(self.allocator);
    }

    fn addFile(self: *ZipWriter, name: []const u8, data: []const u8) !void {
        const crc = std.hash.Crc32.hash(data);
        const size: u32 = @intCast(data.len);
        const local_offset = self.offset;

        // Local file header
        // TODO: Use Deflate compression (method=8) here once std.compress.flate is fully implemented
        // in Zig. As of Zig 0.15.2, std.compress.flate.Compress.drain() has @panic("TODO") and
        // returns 0 for small inputs (causing an infinite loop in end()), and BlockWriter references
        // fields that don't exist yet. When compression is available, compress `data` to a heap
        // buffer, update `compressed_size`, set method=8, and write the compressed bytes instead.
        try self.write32(0x04034b50); // signature
        try self.write16(20); // version needed
        try self.write16(0); // flags
        try self.write16(0); // compression = STORE (switch to 8 for Deflate when available)
        try self.write16(0); // mod time
        try self.write16(0); // mod date
        try self.write32(crc);
        try self.write32(size); // compressed = uncompressed for STORE
        try self.write32(size);
        try self.write16(@intCast(name.len));
        try self.write16(0); // extra field length
        try self.writeBytes(name);
        try self.writeBytes(data);

        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .local_offset = local_offset,
            .crc32 = crc,
            .size = size,
        });
    }

    fn finish(self: *ZipWriter) !void {
        const cd_offset = self.offset;

        for (self.entries.items) |e| {
            try self.write32(0x02014b50); // central dir signature
            try self.write16(20); // version made by
            try self.write16(20); // version needed
            try self.write16(0); // flags
            try self.write16(0); // compression = STORE
            try self.write16(0); // mod time
            try self.write16(0); // mod date
            try self.write32(e.crc32);
            try self.write32(e.size);
            try self.write32(e.size);
            try self.write16(@intCast(e.name.len));
            try self.write16(0); // extra
            try self.write16(0); // comment
            try self.write16(0); // disk start
            try self.write16(0); // internal attr
            try self.write32(0); // external attr
            try self.write32(@intCast(e.local_offset));
            try self.writeBytes(e.name);
        }

        const cd_size: u32 = @intCast(self.offset - cd_offset);
        const num_entries: u16 = @intCast(self.entries.items.len);

        // End of central directory
        try self.write32(0x06054b50);
        try self.write16(0); // disk number
        try self.write16(0); // disk of CD
        try self.write16(num_entries);
        try self.write16(num_entries);
        try self.write32(cd_size);
        try self.write32(@intCast(cd_offset));
        try self.write16(0); // comment length
    }

    fn writeBytes(self: *ZipWriter, data: []const u8) !void {
        try self.file.writeAll(data);
        self.offset += data.len;
    }

    fn write16(self: *ZipWriter, val: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, val, .little);
        try self.writeBytes(&buf);
    }

    fn write32(self: *ZipWriter, val: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, val, .little);
        try self.writeBytes(&buf);
    }
};

// ===========================================================================
// Dynamic XLSX XML builders (multi-sheet support)
// ===========================================================================

fn buildContentTypesXml(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), num_sheets: u32) !void {
    try appendStr(buf, allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" ++
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" ++
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>");
    for (0..num_sheets) |i| {
        try appendStr(buf, allocator, "<Override PartName=\"/xl/worksheets/sheet");
        try appendU32(buf, allocator, @intCast(i + 1));
        try appendStr(buf, allocator, ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>");
    }
    try appendStr(buf, allocator, "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" ++
        "</Types>");
}

fn buildWorkbookXml(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), num_sheets: u32) !void {
    try appendStr(buf, allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" ++
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" ++
        "<sheets>");
    for (0..num_sheets) |i| {
        try appendStr(buf, allocator, "<sheet name=\"");
        if (num_sheets == 1) {
            try appendStr(buf, allocator, "Data");
        } else {
            try appendStr(buf, allocator, "Data ");
            try appendU32(buf, allocator, @intCast(i + 1));
        }
        try appendStr(buf, allocator, "\" sheetId=\"");
        try appendU32(buf, allocator, @intCast(i + 1));
        try appendStr(buf, allocator, "\" r:id=\"rId");
        try appendU32(buf, allocator, @intCast(i + 1));
        try appendStr(buf, allocator, "\"/>");
    }
    try appendStr(buf, allocator, "</sheets></workbook>");
}

fn buildWorkbookRelsXml(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), num_sheets: u32) !void {
    try appendStr(buf, allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" ++
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
    for (0..num_sheets) |i| {
        try appendStr(buf, allocator, "<Relationship Id=\"rId");
        try appendU32(buf, allocator, @intCast(i + 1));
        try appendStr(buf, allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet");
        try appendU32(buf, allocator, @intCast(i + 1));
        try appendStr(buf, allocator, ".xml\"/>");
    }
    // styles relationship — use rId after the sheet IDs
    try appendStr(buf, allocator, "<Relationship Id=\"rId");
    try appendU32(buf, allocator, num_sheets + 1);
    try appendStr(buf, allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" ++
        "</Relationships>");
}

// ===========================================================================
// Static XLSX XML templates
// ===========================================================================

const rels_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    \\</Relationships>
;

const styles_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    \\<fonts count="2">
    \\<font><sz val="11"/><name val="Calibri"/></font>
    \\<font><b/><sz val="11"/><name val="Calibri"/></font>
    \\</fonts>
    \\<fills count="2">
    \\<fill><patternFill patternType="none"/></fill>
    \\<fill><patternFill patternType="gray125"/></fill>
    \\</fills>
    \\<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    \\<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    \\<cellXfs count="2">
    \\<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    \\<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    \\</cellXfs>
    \\</styleSheet>
;
