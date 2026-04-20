/// HDF5 export — converts SIE files to HDF5 format using a two-pass pipeline.
const std = @import("std");
const libsie = @import("libsie");
const hdf5 = @import("hdf5.zig");
const common = @import("common.zig");

const SieFile = libsie.sie_file.SieFile;
const Tag = libsie.tag.Tag;

// ---------------------------------------------------------------------------
// Per-channel dataset tracking (maps structure pass → data pass)
// ---------------------------------------------------------------------------
const ChannelEntry = struct {
    dim_datasets: std.ArrayList(hdf5.ChunkedDataset),
    /// For raw CAN channels: flat uint8 dataset (all frames concatenated,
    /// padded to CAN_FRAME_SIZE bytes each).
    raw_bytes_ds: ?hdf5.ByteDataset = null,
    /// For raw CAN channels: uint8 dataset storing actual DLC per frame.
    raw_dlc_ds: ?hdf5.ByteDataset = null,
    is_raw_can: bool = false,

    fn deinit(self: *ChannelEntry, allocator: std.mem.Allocator) void {
        for (self.dim_datasets.items) |ds| ds.close();
        self.dim_datasets.deinit(allocator);
        if (self.raw_bytes_ds) |ds| ds.close();
        if (self.raw_dlc_ds) |ds| ds.close();
    }
};

/// Maximum CAN frame payload size (standard CAN = 8, CAN FD = 64).
const CAN_FRAME_SIZE: usize = 8;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Process-wide mutex serializing HDF5 calls.
/// The vendored HDF5 C library is built without --enable-threadsafe, so its
/// global state (VOL connectors, error stacks, free lists) is corrupted when
/// multiple threads call into it concurrently. We serialize the entire export
/// at the convert() boundary so the GUI can still run other format exports
/// (CSV/XLSX/ASCII) in parallel — only HDF5 jobs queue behind each other.
var hdf5_mutex: std.Thread.Mutex = .{};

pub fn convert(allocator: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    hdf5_mutex.lock();
    defer hdf5_mutex.unlock();

    // Open SIE file
    var sf = try SieFile.open(allocator, input_path);
    defer sf.deinit();

    // Create HDF5 output
    const h5 = try hdf5.File.create(output_path);
    defer h5.close();

    // Collect per-channel datasets for the data pass
    var entries: std.ArrayList(ChannelEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    // ====================== Structure Pass =================================
    // File-level tags → root attributes
    try writeTags(allocator, h5.id, sf.getFileTags());

    const tests = sf.getTests();
    for (tests) |*test_obj| {
        // --- Test group ---
        const tname = try groupName(allocator, test_obj.getName(), test_obj.getId(), "test");
        defer allocator.free(tname);

        const test_grp = try h5.createGroup(tname);
        defer test_grp.close();

        try writeTags(allocator, test_grp.id, test_obj.getTags());

        // --- Channels in this test ---
        const channels = test_obj.getChannels();
        for (channels) |*ch| {
            const cname = try groupName(allocator, ch.getName(), ch.getId(), "ch");
            defer allocator.free(cname);

            const ch_grp = try test_grp.createGroup(cname);
            defer ch_grp.close();

            try writeTags(allocator, ch_grp.id, ch.getTags());

            // --- Dimensions → chunked datasets ---
            var entry = ChannelEntry{ .dim_datasets = .empty };

            const ch_tags = ch.getTags();
            const raw_can_keys_fmt = [_][]const u8{ "somat:data_format", "data_type" };
            for (raw_can_keys_fmt) |key| {
                if (common.findTag(ch_tags, &[_][]const u8{key})) |v| {
                    if (std.mem.eql(u8, v, "message_can")) {
                        entry.is_raw_can = true;
                        break;
                    }
                }
            }

            const dims = ch.getDimensions();
            for (dims, 0..) |*dim, di| {
                // For raw CAN, only create a float64 dataset for dim 0 (time);
                // dim 1 (raw bytes) gets dedicated byte datasets created below.
                if (entry.is_raw_can and di >= 1) break;
                var buf: [64]u8 = undefined;
                const dset_name = std.fmt.bufPrintZ(&buf, "dim{d}", .{di}) catch "dim";
                const ds = try hdf5.ChunkedDataset.create(ch_grp.id, dset_name, hdf5.CHUNK_ROWS);
                const dim_name_z = try allocator.dupeZ(u8, dim.getName());
                defer allocator.free(dim_name_z);
                hdf5.writeStringAttr(ds.id, "name", dim_name_z) catch {};
                try writeTags(allocator, ds.id, dim.getTags());
                try entry.dim_datasets.append(allocator, ds);
            }

            if (entry.is_raw_can) {
                // Tag channel group as raw CAN
                const true_z: [:0]const u8 = "true";
                hdf5.writeStringAttr(ch_grp.id, "raw_can", true_z) catch {};
                hdf5.writeStringAttr(ch_grp.id, "raw_can_encoding", @as([:0]const u8, "padded_uint8_dlc")) catch {};
                entry.raw_bytes_ds = try hdf5.ByteDataset.create(ch_grp.id, "raw_bytes", hdf5.CHUNK_ROWS * CAN_FRAME_SIZE);
                entry.raw_dlc_ds = try hdf5.ByteDataset.create(ch_grp.id, "raw_dlc", hdf5.CHUNK_ROWS);
            }

            try entries.append(allocator, entry);
        }
    }

    // ====================== Data Pass ======================================
    var ch_idx: usize = 0;
    const tests2 = sf.getTests();
    for (tests2) |*test_obj| {
        const channels = test_obj.getChannels();
        for (channels) |*ch| {
            defer ch_idx += 1;
            if (ch_idx >= entries.items.len) continue;
            const entry = &entries.items[ch_idx];

            var spig = sf.attachSpigot(ch) catch continue;
            defer spig.deinit();

            while (try spig.get()) |out| {
                if (entry.is_raw_can) {
                    // Write time (dim 0) as float64
                    if (out.dimensions[0].dim_type == .Float64) {
                        if (out.dimensions[0].float64_data) |fdata| {
                            if (out.num_rows <= fdata.len)
                                try entry.dim_datasets.items[0].appendRows(fdata[0..out.num_rows]);
                        }
                    }
                    // Write raw CAN bytes (dim 1) into padded byte datasets
                    if (entry.raw_bytes_ds != null) {
                        var pad: [CAN_FRAME_SIZE]u8 = [_]u8{0} ** CAN_FRAME_SIZE;
                        for (0..out.num_rows) |row| {
                            if (out.getRaw(1, row)) |raw| {
                                const size: usize = @intCast(raw.size);
                                const copy_len = @min(size, CAN_FRAME_SIZE);
                                @memcpy(pad[0..copy_len], raw.ptr[0..copy_len]);
                                @memset(pad[copy_len..CAN_FRAME_SIZE], 0);
                                try entry.raw_bytes_ds.?.appendRows(&pad);
                                const dlc: u8 = @intCast(@min(size, 255));
                                try entry.raw_dlc_ds.?.appendRows(&[_]u8{dlc});
                            } else {
                                @memset(&pad, 0);
                                try entry.raw_bytes_ds.?.appendRows(&pad);
                                try entry.raw_dlc_ds.?.appendRows(&[_]u8{0});
                            }
                        }
                    }
                } else {
                    for (0..out.num_dims) |d| {
                        if (d >= entry.dim_datasets.items.len) continue;
                        if (out.dimensions[d].dim_type == .Float64) {
                            if (out.dimensions[d].float64_data) |fdata| {
                                if (out.num_rows <= fdata.len) {
                                    try entry.dim_datasets.items[d].appendRows(fdata[0..out.num_rows]);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn groupName(allocator: std.mem.Allocator, name: []const u8, id: u32, prefix: []const u8) ![:0]u8 {
    if (name.len > 0) {
        return sanitize(allocator, name);
    }
    var buf: [80]u8 = undefined;
    const fallback = std.fmt.bufPrint(&buf, "{s}_{d}", .{ prefix, id }) catch prefix;
    return allocator.dupeZ(u8, fallback);
}

fn sanitize(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, s.len, 0);
    for (out[0..s.len], s) |*o, c| {
        o.* = if (c == '/' or c == 0) '_' else c;
    }
    return out;
}

fn writeTags(allocator: std.mem.Allocator, loc_id: hdf5.hid_t, tags: []const Tag) !void {
    for (tags) |*t| {
        writeOneTag(allocator, loc_id, t) catch continue;
    }
}

fn writeOneTag(allocator: std.mem.Allocator, loc_id: hdf5.hid_t, t: *const Tag) !void {
    const key = t.getId();
    if (key.len == 0) return;

    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);

    if (t.isString()) {
        const val = t.getString() orelse "";
        const val_z = try allocator.dupeZ(u8, val);
        defer allocator.free(val_z);
        try hdf5.writeStringAttr(loc_id, key_z, val_z);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "convert min timhis SIE to HDF5" {
    const allocator = std.testing.allocator;
    const out_path = "test_output.h5";

    convert(allocator, "test/data/sie_min_timhis_a_19EFAA61.sie", out_path) catch |err| {
        std.debug.print("convert failed: {}\n", .{err});
        return err;
    };
    defer std.fs.cwd().deleteFile(out_path) catch {};

    const stat = try std.fs.cwd().statFile(out_path);
    try std.testing.expect(stat.size > 0);
}
