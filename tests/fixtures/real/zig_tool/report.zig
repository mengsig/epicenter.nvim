//! A tiny reporting pipeline, in the language navgraph itself is written in.
//! Its point in this fixture is indented method bodies: every statement below
//! sits inside a function, which is where a cursor actually spends its time.
const std = @import("std");

pub const Row = struct {
    id: u32,
    label: []const u8,
    weight: u32,
};

pub const Report = struct {
    rows: std.ArrayList(Row),

    pub fn init(allocator: std.mem.Allocator) Report {
        return .{ .rows = std.ArrayList(Row).init(allocator) };
    }

    pub fn deinit(self: *Report) void {
        self.rows.deinit();
    }

    pub fn add(self: *Report, row: Row) !void {
        try self.rows.append(row);
    }

    /// Sum of every row's weight - the body a blast-from-inside case aims at.
    pub fn total(self: *const Report) u32 {
        var sum: u32 = 0;
        for (self.rows.items) |row| {
            sum += row.weight;
        }
        return sum;
    }

    pub fn heaviest(self: *const Report) ?Row {
        var best: ?Row = null;
        for (self.rows.items) |row| {
            if (best == null or row.weight > best.?.weight) {
                best = row;
            }
        }
        return best;
    }
};

pub fn summarize(report: *const Report) u32 {
    const sum = report.total();
    const top = report.heaviest();
    if (top) |row| {
        return sum + row.weight;
    }
    return sum;
}
