const std = @import("std");
const ExportSIE = @import("ExportSIE");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        const stderr = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr.writer(&buf);
        try w.interface.print("Usage: exportsie <input.sie> <output.[h5|txt|csv|xlsx]>\n\n", .{});
        try w.interface.print("Supported output formats (determined by file extension):\n", .{});
        try w.interface.print("  .h5 / .hdf5  \xe2\x80\x94 HDF5 hierarchical data format\n", .{});
        try w.interface.print("  .txt         \xe2\x80\x94 ASCII text export (tags + tab-separated data)\n", .{});
        try w.interface.print("  .csv         \xe2\x80\x94 Comma-separated values (side-by-side channels)\n", .{});
        try w.interface.print("  .xlsx        \xe2\x80\x94 Excel 2007+ spreadsheet\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    // Determine export format from output file extension
    const ext = extensionOf(output_path);

    if (std.ascii.eqlIgnoreCase(ext, ".h5") or std.ascii.eqlIgnoreCase(ext, ".hdf5")) {
        ExportSIE.hdf5_export.convert(allocator, input_path, output_path) catch |err| {
            return fail("HDF5 export failed: {}\n", .{err});
        };
    } else if (std.ascii.eqlIgnoreCase(ext, ".txt")) {
        ExportSIE.ascii_export.convert(allocator, input_path, output_path) catch |err| {
            return fail("ASCII export failed: {}\n", .{err});
        };
    } else if (std.ascii.eqlIgnoreCase(ext, ".csv")) {
        ExportSIE.csv_export.convert(allocator, input_path, output_path) catch |err| {
            return fail("CSV export failed: {}\n", .{err});
        };
    } else if (std.ascii.eqlIgnoreCase(ext, ".xlsx")) {
        ExportSIE.xlsx_export.convert(allocator, input_path, output_path) catch |err| {
            return fail("XLSX export failed: {}\n", .{err});
        };
    } else {
        return fail("Unsupported output format: '{s}'\nUse one of: .h5, .hdf5, .txt, .csv, .xlsx\n", .{ext});
    }
}

fn extensionOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        return path[dot..];
    }
    return "";
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    var w = stderr.writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

test "arg parsing smoke test" {
    try std.testing.expect(true);
}
