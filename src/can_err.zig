/// J1939 DM1 CAN error extraction — ported from
/// https://github.com/efollman/CanErrFindr-Zig (MIT-licensed, © Evan Follman).
///
/// Extracts DM1 diagnostic trouble codes from a stream of J1939 CAN frames:
/// handles both single-frame (PGN 0xFECA) and multi-frame BAM transport
/// (PGN 0xECFF → 0xEBFF, carrying PGN 0xFECA). Deduplicates on
/// (SPN, FMI, SA, OC), keeping the earliest timestamp for each unique record.
const std = @import("std");
const Allocator = std.mem.Allocator;

const HexSlice = struct {
    data: []const u8,

    pub fn format(self: HexSlice, writer: anytype) !void {
        for (self.data) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
    }
};

fn hexSlice(data: []const u8) HexSlice {
    return .{ .data = data };
}

/// Optional diagnostic sink. Warnings are counted and, if `messages` is
/// provided, each is also duplicated into the list via `msg_allocator`.
pub const Diagnostics = struct {
    warn_count: usize = 0,
    messages: ?*std.ArrayList([]const u8) = null,
    msg_allocator: ?Allocator = null,

    pub fn warn(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        self.warn_count += 1;
        if (self.messages) |msgs| {
            if (self.msg_allocator) |alloc| {
                var buf: [1024]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
                const duped = alloc.dupe(u8, msg) catch return;
                msgs.append(alloc, duped) catch {
                    alloc.free(duped);
                };
            }
        }
    }
};

pub const ErrRecord = struct {
    time: f64,
    pgn: u16,
    sa: u8,
    ls: u16,
    spn: u32,
    fmi: u8,
    oc: u8,
    warning: bool = false,
};

const Payload = struct {
    time: f64,
    can_id: u32,
    data: [6]u8,
};

/// Parse a SoMat raw CAN payload into (can_id, frame bytes). The first four
/// bytes are a big-endian 29-bit identifier (high bits masked off); the rest
/// are the CAN data bytes.
pub fn parseCan(raw_data: []const u8) ?struct { can_id: u32, frame: []const u8 } {
    if (raw_data.len < 4) return null;
    const can_id = std.mem.readInt(u32, raw_data[0..4], .big) & 0x1fffffff;
    return .{ .can_id = can_id, .frame = raw_data[4..] };
}

/// True for PGN 0xFECA (DM1) or the TP.CM/TP.DT PGNs used for its BAM transport.
pub fn isErrorPgn(can_id: u32) bool {
    const pgn_field = can_id & 0x00FFFF00;
    return pgn_field == 0x00FECA00 or pgn_field == 0x00ECFF00 or pgn_field == 0x00EBFF00;
}

/// Extract DM1 error records from a time-aligned sequence of raw CAN frames.
/// Caller owns the returned slice.
pub fn canErrFindr(
    allocator: Allocator,
    times: []const f64,
    raw_frames: []const []const u8,
    diag: ?*Diagnostics,
) ![]ErrRecord {
    // Step 1: Parse and filter for error-related CAN IDs
    var filtered_times: std.ArrayList(f64) = .empty;
    defer filtered_times.deinit(allocator);
    var filtered_ids: std.ArrayList(u32) = .empty;
    defer filtered_ids.deinit(allocator);
    var filtered_frames: std.ArrayList([]const u8) = .empty;
    defer filtered_frames.deinit(allocator);

    for (times, raw_frames) |t, raw| {
        const parsed = parseCan(raw) orelse continue;
        if (isErrorPgn(parsed.can_id)) {
            try filtered_times.append(allocator, t);
            try filtered_ids.append(allocator, parsed.can_id);
            try filtered_frames.append(allocator, parsed.frame);
        }
    }

    // Step 2: Extract payloads (single-frame and multi-frame BAM)
    var payloads: std.ArrayList(Payload) = .empty;
    defer payloads.deinit(allocator);

    const f_times = filtered_times.items;
    const f_ids = filtered_ids.items;
    const f_frames = filtered_frames.items;

    var i: usize = 0;
    while (i < f_ids.len) : (i += 1) {
        const pgn_field = f_ids[i] & 0x00FFFF00;

        if (pgn_field == 0x00FECA00) {
            // Single-frame DM1
            if (f_frames[i].len >= 6) {
                try payloads.append(allocator, .{
                    .time = f_times[i],
                    .can_id = f_ids[i],
                    .data = f_frames[i][0..6].*,
                });
            }
        } else if (pgn_field == 0x00ECFF00) {
            // TP.CM - check if it's transporting DM1 (PGN 0xFECA)
            if (f_frames[i].len >= 7) {
                const transported_pgn = std.mem.readInt(u16, f_frames[i][5..7], .little);
                if (transported_pgn == 0xFECA) {
                    if (f_frames[i][0] != 0x20) {
                        if (diag) |d| d.warn("Not a BAM control message (byte: 0x{x:0>2}, time: {d:.3})", .{ f_frames[i][0], f_times[i] });
                        continue;
                    }
                    const total_size: usize = @intCast(f_frames[i][1]);
                    const num_frames_expected: u8 = f_frames[i][3];

                    var curr_frame: u8 = 1;
                    var ex_frame_data: std.ArrayList(u8) = .empty;
                    defer ex_frame_data.deinit(allocator);
                    var ls_bytes: [2]u8 = .{ 0, 0 };

                    var bam_complete = false;
                    var j = i + 1;
                    while (j < f_ids.len) : (j += 1) {
                        // Check for unexpected new multiframe start
                        if (f_ids[j] == f_ids[i]) {
                            if (diag) |d| {
                                d.warn("Unexpected new multiframe before last finished: time: {d:.3} id: 0x{x} frame: 0x{f} next index expected: {d} length expected: {d}", .{
                                    f_times[j],
                                    f_ids[j],
                                    hexSlice(f_frames[j]),
                                    curr_frame,
                                    num_frames_expected,
                                });
                            }
                            break;
                        }

                        // Check if this is the matching TP.DT
                        // Convert EC to EB: (original & 0x00ffffff) - 0x00010000
                        const expected_dt_addr = (f_ids[i] & 0x00ffffff) -% 0x00010000;
                        if ((f_ids[j] & 0x00ffffff) == expected_dt_addr) {
                            if (f_frames[j].len > 0 and f_frames[j][0] == curr_frame) {
                                curr_frame +%= 1;

                                var start: usize = undefined;
                                if (f_frames[j][0] == 1) {
                                    // First data frame carries LS bytes
                                    if (f_frames[j].len >= 3) {
                                        ls_bytes = f_frames[j][1..3].*;
                                    }
                                    start = 3;
                                } else {
                                    start = 1;
                                }

                                if (start < f_frames[j].len) {
                                    try ex_frame_data.appendSlice(allocator, f_frames[j][start..]);
                                }

                                if (f_frames[j][0] == num_frames_expected) {
                                    // All frames received - trim to declared size minus LS (2 bytes)
                                    const trim_len = if (total_size >= 2) total_size - 2 else 0;
                                    const actual_trim = @min(ex_frame_data.items.len, trim_len);
                                    ex_frame_data.shrinkRetainingCapacity(actual_trim);
                                    bam_complete = true;
                                    break;
                                }
                            } else {
                                if (diag) |d| d.warn("Multiframe index desync (time: {d:.3}, expected frame {d}, got {d})", .{ f_times[j], curr_frame, f_frames[j][0] });
                                break;
                            }
                        }
                    }

                    if (!bam_complete and j >= f_ids.len) {
                        if (diag) |d| d.warn("End of file before multiframe assembled (time: {d:.3})", .{f_times[i]});
                    }

                    // Split reassembled data into 4-byte DTC chunks
                    const data = ex_frame_data.items;
                    if (data.len >= 4) {
                        const num_dtcs = data.len / 4;
                        for (0..num_dtcs) |b| {
                            try payloads.append(allocator, .{
                                .time = f_times[i],
                                .can_id = f_ids[i],
                                .data = .{
                                    ls_bytes[0],
                                    ls_bytes[1],
                                    data[b * 4],
                                    data[b * 4 + 1],
                                    data[b * 4 + 2],
                                    data[b * 4 + 3],
                                },
                            });
                        }
                    }

                    ex_frame_data.clearRetainingCapacity();
                }
            }
        }
    }

    // Step 3: Interpret payloads into error records
    var records: std.ArrayList(ErrRecord) = .empty;
    errdefer records.deinit(allocator);

    for (payloads.items) |pl| {
        const spn: u32 = @as(u32, pl.data[2]) |
            (@as(u32, pl.data[3]) << 8) |
            (@as(u32, (pl.data[4] & 0xE0) >> 5) << 16);

        if (spn == 0) continue;

        const cm_bit = pl.data[5] & 0x80;
        if (cm_bit != 0) {
            if (diag) |d| d.warn("CM bit = 1, older SPN encoding version? SPN: {d}, Time: {d:.3}, Payload: 0x{f}", .{
                spn,
                pl.time,
                hexSlice(&pl.data),
            });
        }

        try records.append(allocator, .{
            .time = pl.time,
            .pgn = @intCast((pl.can_id & 0xFFFF00) >> 8),
            .sa = @intCast(pl.can_id & 0xFF),
            .ls = std.mem.readInt(u16, pl.data[0..2], .little),
            .spn = spn,
            .fmi = pl.data[4] & 0x1F,
            .oc = pl.data[5] & 0x7F,
            .warning = cm_bit != 0,
        });
    }

    // Step 4: Remove duplicates by (SPN, FMI, SA, OC), keep earliest time
    std.sort.block(ErrRecord, records.items, {}, lessThanByTime);

    var idx: usize = records.items.len;
    while (idx > 0) {
        idx -= 1;
        var j_idx: usize = idx;
        while (j_idx > 0) {
            j_idx -= 1;
            if (records.items[j_idx].spn == records.items[idx].spn and
                records.items[j_idx].fmi == records.items[idx].fmi and
                records.items[j_idx].sa == records.items[idx].sa and
                records.items[j_idx].oc == records.items[idx].oc)
            {
                records.items[idx].time = @min(records.items[j_idx].time, records.items[idx].time);
                _ = records.orderedRemove(j_idx);
                idx -= 1;
            }
        }
    }

    std.sort.block(ErrRecord, records.items, {}, lessThanByTime);

    return records.toOwnedSlice(allocator);
}

fn lessThanByTime(_: void, a: ErrRecord, b: ErrRecord) bool {
    return a.time < b.time;
}

pub fn writeCsv(records: []const ErrRecord, writer: anytype) !void {
    try writer.writeAll("Time,PGN,SA,LS,SPN,FMI,OC\n");
    for (records) |r| {
        try writer.print("{d},{x},0x{x},0x{x},{d},{d},{d}\n", .{
            r.time,
            r.pgn,
            r.sa,
            r.ls,
            r.spn,
            r.fmi,
            r.oc,
        });
    }
}

pub const ChannelRecords = struct {
    name: []const u8,
    records: []const ErrRecord,
};

pub fn writeMultiChannelCsv(channels: []const ChannelRecords, writer: anytype) !void {
    for (channels, 0..) |ch, i| {
        if (i > 0) try writer.writeByte('\n');
        try writer.print("{s}\n", .{ch.name});
        try writeCsv(ch.records, writer);
    }
}
