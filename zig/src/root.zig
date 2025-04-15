const std = @import("std");
const testing = std.testing;

const UNITS = [_]u8{ 'K', 'M', 'G', 'T' };

const builtin = @import("builtin");
const PREFIX = if (builtin.target.os.tag == .macos) @import("build_options").HOME else "";

pub fn swapview(alloc: std.mem.Allocator) !void {
    var lst = init_list(alloc);
    defer deinit_list(lst);

    try get_swap_info_list(alloc, &lst);
    std.sort.block(SwapInfo, lst.items, {}, struct {
        fn lt(_: void, lhs: SwapInfo, rhs: SwapInfo) bool {
            return lhs.size < rhs.size;
        }
    }.lt);

    const stdout = std.io.getStdOut().writer();
    var total: u64 = 0;
    try stdout.print("{s:>7} {s:>9} {s}\n", .{ "PID", "SWAP", "COMMAND" });
    for (lst.items) |info| {
        const size_h = try filesize(alloc, info.size);
        defer alloc.free(size_h);

        try stdout.print("{d:>7} {s:>9} {s}\n", .{ info.pid, size_h, info.comm });
        total += info.size;
    }
    const total_h = try filesize(alloc, total);
    defer alloc.free(total_h);
    try stdout.print("Total: {s:>10}\n", .{total_h});
}

const SwapInfo = struct {
    alloc: std.mem.Allocator,
    pid: usize = 0,
    comm: []const u8 = &[_]u8{},
    size: u64 = 0,

    fn init(alloc: std.mem.Allocator) SwapInfo {
        return .{
            .alloc = alloc,
        };
    }

    fn deinit(self: *SwapInfo) void {
        if (self.comm.ptr != &[_]u8{} and self.comm.len > 0)
            self.alloc.free(self.comm);
    }
};

const SwapInfoList = std.ArrayList(SwapInfo);

fn get_swap_info_list(alloc: std.mem.Allocator, lst: *SwapInfoList) !void {
    const dir = try std.fs.cwd().openDir(PREFIX ++ "/proc", .{
        .iterate = true,
    });
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const pid = std.fmt.parseInt(usize, entry.name, 10) catch continue;
        const size = read_swap_size(alloc, pid) catch continue;
        if (size > 0) {
            var info = SwapInfo.init(alloc);
            const comm = read_comm(info.alloc, pid) catch continue;
            info.pid = pid;
            info.comm = comm;
            info.size = size;
            try lst.append(info);
        }
    }
}

fn init_list(alloc: std.mem.Allocator) SwapInfoList {
    return SwapInfoList.init(alloc);
}

fn deinit_list(lst: SwapInfoList) void {
    for (lst.items) |*v| {
        v.deinit();
    }
    lst.deinit();
}

test "get_list" {
    const alloc = testing.allocator;

    var lst = init_list(alloc);
    defer deinit_list(lst);

    try get_swap_info_list(alloc, &lst);

    var total: u64 = 0;
    for (lst.items) |v| {
        const size_h = try filesize(alloc, v.size);
        defer alloc.free(size_h);
        try testing.expect(size_h.len > 0);
        total += v.size;
    }

    try testing.expect(total > 0);
}

/// caller MUST free returned string
fn filesize(alloc: std.mem.Allocator, size: u64) ![]const u8 {
    var left: f64 = @as(f64, @floatFromInt(size));
    var unit: usize = 0;

    while (left > 1100 and unit < 4) {
        left /= 1024;
        unit += 1;
    }

    switch (unit) {
        0 => return try std.fmt.allocPrint(alloc, "{d}B", .{size}),
        else => return try std.fmt.allocPrint(alloc, "{d:.1}{c}iB", .{ left, UNITS[unit - 1] }),
    }
}

test "filesize" {
    const alloc = testing.allocator;

    const s1 = try filesize(alloc, 1000);
    defer alloc.free(s1);
    try testing.expectEqualStrings("1000B", s1);

    const s2 = try filesize(alloc, 1024);
    defer alloc.free(s2);
    try testing.expectEqualStrings("1024B", s2);

    const s3 = try filesize(alloc, 1_000_000);
    defer alloc.free(s3);
    try testing.expectEqualStrings("976.6KiB", s3);
}

/// caller MUST free returned string
fn read_comm(alloc: std.mem.Allocator, pid: usize) ![]const u8 {
    var path_buf: [40]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, PREFIX ++ "/proc/{d}/cmdline", .{pid});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const content = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    return sanitize_comm(content);
}

test "read_comm" {
    const alloc = testing.allocator;

    const cmd = try read_comm(alloc, 149392);
    defer alloc.free(cmd);
    try testing.expect(cmd.len > 0);
}

/// modifies `raw` in-place
fn sanitize_comm(raw: []u8) []const u8 {
    const z = [_]u8{0};
    const nulls = std.mem.count(u8, raw, &z);
    var i: usize = 0;
    var cnt: usize = 0;
    while (i < raw.len and cnt < nulls - 1) : (i += 1) {
        if (raw[i] == 0) {
            raw[i] = ' ';
            cnt += 1;
        }
    }
    return raw;
}

test "sanitize_comm" {
    const cmd = "myprogram\x00-o\x00output.txt\x00--verbose\x00some argument\x00";

    const alloc = std.testing.allocator;
    const cmd_slice = try alloc.alloc(u8, cmd.len);
    @memcpy(cmd_slice, cmd);
    defer alloc.free(cmd_slice);

    const res = sanitize_comm(cmd_slice);
    try std.testing.expectEqual(0, res[res.len - 1]);
}

/// return in Bytes
fn read_swap_size(alloc: std.mem.Allocator, pid: usize) !u64 {
    var total: u64 = 0;

    var path_buf: [40]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, PREFIX ++ "/proc/{d}/smaps", .{pid});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    var buf_rdr = std.io.bufferedReader(file.reader());
    const rdr = buf_rdr.reader();
    var line_buf = std.ArrayList(u8).init(alloc);
    defer line_buf.deinit();

    while (true) {
        rdr.streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        const line = line_buf.items;
        if (std.mem.startsWith(u8, line, "Swap:")) {
            const string = line[5..(line.len - 3)]; // -3 == " kB"
            const value = std.mem.trim(u8, string, " ");
            const size = try std.fmt.parseInt(u64, value, 10);
            total += size;
        }
        line_buf.clearRetainingCapacity();
    }

    return total * 1024;
}

test "read_swap_size" {
    const alloc = testing.allocator;

    const size = try read_swap_size(alloc, 149392);
    const s = try filesize(alloc, size);
    defer alloc.free(s);
    try testing.expect(size > 0 and s.len > 0);
}
