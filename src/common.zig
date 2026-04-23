/// Shared data structures and SIE reading utilities used by CSV and XLSX exporters.
const std = @import("std");
const libsie = @import("libsie");

const SieFile = libsie.SieFile;
const Tag = libsie.Tag;

/// All data extracted from a SIE file, ready for tabular export.
pub const ExportData = struct {
    allocator: std.mem.Allocator,
    test_name: []const u8,
    start_time: []const u8,
    /// File-level + test-level metadata, displayed as a key/value table at the
    /// top of CSV / XLSX exports. Each entry produces one row: column A = key,
    /// column B = value. Always includes "Test Name" and "Start Time" (when
    /// available) followed by all other file_tags and test_tags, deduplicated
    /// by key (first occurrence wins).
    meta_pairs: std.ArrayList(MetaPair),
    channels: std.ArrayList(Channel),
    groups: std.ArrayList(ChannelGroup),

    pub const MetaPair = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const Channel = struct {
        name: []const u8,
        units: []const u8,
        sample_rate: []const u8,
        description: []const u8,
        dim_names: std.ArrayList([]const u8),
        dim_data: std.ArrayList(std.ArrayList(f64)),
        /// Per-row hex strings for raw CAN dim (e.g. "0xaabb..."). Only populated
        /// when is_raw_can = true.
        raw_can_hex: std.ArrayList([]const u8),
        num_rows: usize,
        is_raw_can: bool,
        /// True for 2-dim time-series channels (DataMode starts with "timhis",
        /// or new-format dim 0 has core:units="Seconds"). Raw CAN channels may
        /// also have is_timeseries=true but are kept standalone (see buildGroups).
        is_timeseries: bool,
        /// Label for the time axis, e.g. "Time (S)".
        time_label: []const u8,
    };

    /// A group of channels that share a common time vector (is_timeseries=true,
    /// groupable), or a single standalone channel.
    pub const ChannelGroup = struct {
        channel_indices: std.ArrayList(usize),
        /// All channels in this group are 2-dim timeseries, sharing dim 0.
        is_timeseries: bool,
    };

    pub fn init(allocator: std.mem.Allocator) ExportData {
        return .{
            .allocator = allocator,
            .test_name = "",
            .start_time = "",
            .meta_pairs = .empty,
            .channels = .empty,
            .groups = .empty,
        };
    }

    pub fn deinit(self: *ExportData) void {
        const a = self.allocator;
        if (self.test_name.len > 0) a.free(self.test_name);
        if (self.start_time.len > 0) a.free(self.start_time);
        for (self.meta_pairs.items) |p| {
            a.free(p.key);
            a.free(p.value);
        }
        self.meta_pairs.deinit(a);
        for (self.channels.items) |*ch| {
            if (ch.name.len > 0) a.free(ch.name);
            if (ch.units.len > 0) a.free(ch.units);
            if (ch.sample_rate.len > 0) a.free(ch.sample_rate);
            if (ch.description.len > 0) a.free(ch.description);
            if (ch.time_label.len > 0) a.free(ch.time_label);
            for (ch.dim_names.items) |n| if (n.len > 0) a.free(n);
            ch.dim_names.deinit(a);
            for (ch.dim_data.items) |*d| d.deinit(a);
            ch.dim_data.deinit(a);
            for (ch.raw_can_hex.items) |s| if (s.len > 0) a.free(s);
            ch.raw_can_hex.deinit(a);
        }
        self.channels.deinit(a);
        for (self.groups.items) |*g| g.channel_indices.deinit(a);
        self.groups.deinit(a);
    }

    pub fn maxRows(self: *const ExportData) usize {
        var m: usize = 0;
        for (self.channels.items) |ch| m = @max(m, ch.num_rows);
        return m;
    }

    /// Total number of CSV/XLSX columns in grouped layout (with blank separators).
    /// Includes the leading row-label column (column A).
    pub fn totalColumns(self: *const ExportData) usize {
        var cols: usize = 1; // column A reserved for row labels (Channel/Units/...)
        for (self.groups.items, 0..) |*grp, gi| {
            if (gi > 0) cols += 1; // blank separator between groups
            if (grp.is_timeseries) {
                cols += 1; // shared time column
                cols += grp.channel_indices.items.len; // one value col per channel
            } else {
                const ci = grp.channel_indices.items[0];
                const ch = &self.channels.items[ci];
                if (ch.is_raw_can) {
                    cols += 2; // time col + raw hex col
                } else {
                    cols += ch.dim_data.items.len;
                }
            }
        }
        return cols;
    }

    /// Group channels: 2-dim timeseries channels with matching (sample_rate, num_rows)
    /// share a group. Everything else gets its own group.
    pub fn buildGroups(self: *ExportData) !void {
        const a = self.allocator;
        for (self.groups.items) |*g| g.channel_indices.deinit(a);
        self.groups.clearRetainingCapacity();

        var key_map = std.StringHashMap(usize).init(a);
        defer {
            var it = key_map.iterator();
            while (it.next()) |entry| a.free(entry.key_ptr.*);
            key_map.deinit();
        }

        for (self.channels.items, 0..) |*ch, ci| {
            // A channel is groupable only if it's a 2-dim time-series and not raw CAN
            const groupable = ch.is_timeseries and ch.dim_data.items.len == 2 and !ch.is_raw_can;
            const key = if (groupable)
                try std.fmt.allocPrint(a, "ts|{s}|{d}", .{ ch.sample_rate, ch.num_rows })
            else
                try std.fmt.allocPrint(a, "solo|{d}", .{ci});

            const gop = try key_map.getOrPut(key);
            if (gop.found_existing) {
                a.free(key);
                try self.groups.items[gop.value_ptr.*].channel_indices.append(a, ci);
            } else {
                gop.value_ptr.* = self.groups.items.len;
                var grp = ChannelGroup{ .channel_indices = .empty, .is_timeseries = groupable };
                try grp.channel_indices.append(a, ci);
                try self.groups.append(a, grp);
            }
        }
    }
};

/// Open a SIE file and read all metadata + channel data into memory.
pub fn readSieFile(allocator: std.mem.Allocator, input_path: [:0]const u8) !ExportData {
    var sf = try SieFile.open(allocator, input_path);
    defer sf.deinit();

    var data = ExportData.init(allocator);
    errdefer data.deinit();

    // --- File / test level metadata ---
    const file_tags = sf.fileTags();
    const name_keys = [_][]const u8{ "SIE:TCE_SetupName", "name", "Name", "TestName" };
    if (findTag(file_tags, &name_keys)) |name| {
        data.test_name = try allocator.dupe(u8, name);
    }
    const time_keys = [_][]const u8{ "start_time", "SIE:start_time", "datetime", "StartTime", "Date", "core:start_time" };
    if (findTag(file_tags, &time_keys)) |t| {
        data.start_time = try allocator.dupe(u8, t);
    }

    const tests = sf.tests();
    if (data.test_name.len == 0 and tests.len > 0) {
        const tn = tests[0].name;
        if (tn.len > 0) data.test_name = try allocator.dupe(u8, tn);
    }
    if (data.start_time.len == 0 and tests.len > 0) {
        if (findTag(tests[0].tags(), &time_keys)) |t| {
            data.start_time = try allocator.dupe(u8, t);
        }
    }

    // Build meta_pairs: Test Name + Start Time + all file/test tags (deduped by key).
    if (data.test_name.len > 0) {
        try appendMetaPair(allocator, &data.meta_pairs, "Test Name", data.test_name);
    }
    if (data.start_time.len > 0) {
        try appendMetaPair(allocator, &data.meta_pairs, "Start Time", data.start_time);
    }
    for (file_tags) |*tag| {
        const v = tag.string() orelse continue;
        if (tag.key.len == 0 or v.len == 0) continue;
        try appendMetaPair(allocator, &data.meta_pairs, tag.key, v);
    }
    if (tests.len > 0) {
        for (tests[0].tags()) |*tag| {
            const v = tag.string() orelse continue;
            if (tag.key.len == 0 or v.len == 0) continue;
            try appendMetaPair(allocator, &data.meta_pairs, tag.key, v);
        }
    }

    // --- Read all channels across all tests ---
    for (tests) |*test_obj| {
        const channels = test_obj.channels();
        for (channels) |*ch| {
            var channel = ExportData.Channel{
                .name = "",
                .units = "",
                .sample_rate = "",
                .description = "",
                .dim_names = .empty,
                .dim_data = .empty,
                .raw_can_hex = .empty,
                .num_rows = 0,
                .is_raw_can = false,
                .is_timeseries = false,
                .time_label = "",
            };

            // Channel name
            const cn = ch.name;
            if (cn.len > 0) channel.name = try allocator.dupe(u8, cn);

            const ch_tags = ch.tags();

            // Sample rate (new format: core:sample_rate; old format: absent)
            const rate_keys = [_][]const u8{ "core:sample_rate", "sample_rate", "SampleRate", "rate", "Rate", "SIE:sample_rate" };
            if (findTag(ch_tags, &rate_keys)) |r| {
                channel.sample_rate = try allocator.dupe(u8, r);
            }

            // Description
            const desc_keys = [_][]const u8{ "Description", "core:description", "description" };
            if (findTag(ch_tags, &desc_keys)) |d| {
                if (d.len > 0) channel.description = try allocator.dupe(u8, d);
            }

            // Detect raw CAN: somat:data_format or data_type = "message_can"
            for ([_][]const u8{ "somat:data_format", "data_type" }) |key| {
                if (findTag(ch_tags, &[_][]const u8{key})) |v| {
                    if (std.mem.eql(u8, v, "message_can")) {
                        channel.is_raw_can = true;
                        break;
                    }
                }
            }

            // Dimensions: names, units, data arrays
            const dims = ch.dimensions();
            for (dims) |*dim| {
                // Prefer getName(), fall back to core:label tag
                const dn = dim.name;
                const label_keys = [_][]const u8{"core:label"};
                const name_str = if (dn.len > 0) dn else (findTag(dim.tags(), &label_keys) orelse "");
                try channel.dim_names.append(allocator, try allocator.dupe(u8, name_str));
                try channel.dim_data.append(allocator, .empty);
            }

            // Units from value dimension (index 1 if exists, else 0)
            if (dims.len > 0) {
                const unit_idx: usize = if (dims.len > 1) 1 else 0;
                const unit_keys = [_][]const u8{ "core:units", "SIE:units", "units", "Units", "eng_units" };
                if (findTag(dims[unit_idx].tags(), &unit_keys)) |u| {
                    channel.units = try allocator.dupe(u8, u);
                }
            }

            // Detect timeseries from DataMode tag (old format: timhis, timhis_8, timhis_16, ...)
            if (findTag(ch_tags, &[_][]const u8{"DataMode"})) |v| {
                if (v.len >= 6 and std.ascii.eqlIgnoreCase(v[0..6], "timhis")) {
                    channel.is_timeseries = true;
                }
            }
            // Detect timeseries from dim 0 tags (new format: core:units=Seconds or core:label=Time)
            if (!channel.is_timeseries and dims.len >= 2) {
                const d0_units = findTag(dims[0].tags(), &[_][]const u8{"core:units"}) orelse "";
                const d0_label = findTag(dims[0].tags(), &[_][]const u8{"core:label"}) orelse "";
                if (std.ascii.eqlIgnoreCase(d0_units, "seconds") or
                    std.ascii.eqlIgnoreCase(d0_units, "s") or
                    std.ascii.eqlIgnoreCase(d0_label, "time"))
                {
                    channel.is_timeseries = true;
                }
            }

            // Build time_label: "{label} ({units_abbrev})", fallback "Time (S)"
            {
                const lbl = if (dims.len > 0)
                    (findTag(dims[0].tags(), &[_][]const u8{"core:label"}) orelse "Time")
                else
                    "Time";
                const u_raw = if (dims.len > 0)
                    (findTag(dims[0].tags(), &[_][]const u8{"core:units"}) orelse "S")
                else
                    "S";
                // Abbreviate "Seconds" -> "S"
                const u_abbrev = if (std.ascii.eqlIgnoreCase(u_raw, "seconds")) "S" else u_raw;
                channel.time_label = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ lbl, u_abbrev });
            }

            // Stream channel data
            var spig = sf.attachSpigot(ch) catch continue;
            defer spig.deinit();

            while (try spig.get()) |out| {
                for (0..out.num_rows) |row| {
                    for (0..out.num_dims) |d| {
                        if (channel.is_raw_can and d == 1) {
                            // Raw CAN dim: store as hex string
                            if (out.raw(d, row)) |raw| {
                                const size: usize = @intCast(raw.size);
                                const hex_str = try fmtHex(allocator, raw.ptr[0..size]);
                                try channel.raw_can_hex.append(allocator, hex_str);
                            } else {
                                try channel.raw_can_hex.append(allocator, try allocator.dupe(u8, ""));
                            }
                        } else {
                            if (d < channel.dim_data.items.len) {
                                if (out.float64(d, row)) |val| {
                                    try channel.dim_data.items[d].append(allocator, val);
                                }
                            }
                        }
                    }
                }
            }

            // Compute row count
            var max_r: usize = 0;
            for (channel.dim_data.items) |d| max_r = @max(max_r, d.items.len);
            max_r = @max(max_r, channel.raw_can_hex.items.len);
            channel.num_rows = max_r;

            try data.channels.append(allocator, channel);
        }
    }

    try data.buildGroups();
    return data;
}

/// Format raw bytes as "0x" + lowercase hex (e.g. "0xaabbcc").
fn fmtHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[2 + i * 2] = hex_chars[byte >> 4];
        out[2 + i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return out;
}

/// Append a (key, value) pair to the meta_pairs list, but only if `key` isn't
/// already present (case-sensitive). Both strings are duplicated into the
/// allocator and freed by ExportData.deinit().
fn appendMetaPair(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(ExportData.MetaPair),
    key: []const u8,
    value: []const u8,
) !void {
    for (list.items) |p| {
        if (std.mem.eql(u8, p.key, key)) return;
    }
    try list.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
}

/// Search a tag slice for the first tag whose id matches any of the given keys.
pub fn findTag(tags: []const Tag, keys: []const []const u8) ?[]const u8 {
    for (tags) |*tag| {
        const id = tag.key;
        for (keys) |key| {
            if (std.mem.eql(u8, id, key)) {
                return tag.string();
            }
        }
    }
    return null;
}
