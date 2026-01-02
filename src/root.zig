//
// Copyright (C) 2026 Joseph Wright <joseph@cloudboss.co>
//

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const gpt = @import("gpt.zig");
pub const GptContext = @import("gpt_context.zig").GptContext;
pub const resize = @import("resize.zig");

pub const ZGptError = error{
    InvalidDevice,
    PermissionDenied,
    DeviceNotFound,
} || gpt.GptError || resize.ResizeError;

pub const ZGpt = struct {
    allocator: Allocator,
    context: GptContext,

    const Self = @This();

    pub fn init(allocator: Allocator, device_path: []const u8) ZGptError!Self {
        const context = GptContext.init(allocator, device_path) catch |err| switch (err) {
            error.FileNotFound => return ZGptError.DeviceNotFound,
            error.AccessDenied => return ZGptError.PermissionDenied,
            else => return ZGptError.InvalidDevice,
        };

        return Self{
            .allocator = allocator,
            .context = context,
        };
    }

    pub fn deinit(self: *Self) void {
        self.context.deinit();
    }

    pub fn load(self: *Self) ZGptError!void {
        try self.context.load();
    }

    pub fn save(self: *Self) ZGptError!void {
        try self.context.save();
    }

    pub fn resizePartitionByNumber(self: *Self, partition_number: u32, new_size_mb: u64) ZGptError!void {
        const operation = resize.ResizeOperation.byMegabytes(partition_number, new_size_mb);
        try resize.resizePartition(&self.context, operation, resize.ResizeConstraints{});
    }

    pub fn resizePartitionToMax(self: *Self, partition_number: u32) ZGptError!void {
        try resize.resizeToMaxSize(&self.context, partition_number, resize.ResizeConstraints{});
    }

    pub fn listPartitions(self: *Self) ZGptError![]resize.PartitionInfo {
        return resize.listPartitions(&self.context, self.allocator);
    }

    pub fn getPartitionInfo(self: *Self, partition_number: u32) ZGptError!?resize.PartitionInfo {
        return resize.getPartitionInfo(&self.context, partition_number, self.allocator);
    }

    pub fn freePartitionList(self: *Self, partitions: []resize.PartitionInfo) void {
        for (partitions) |*partition| {
            partition.deinit(self.allocator);
        }
        self.allocator.free(partitions);
    }
};

test "GUID parsing and formatting" {
    const testing = std.testing;

    const guid_str = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";
    const guid = try gpt.Guid.fromString(guid_str);

    var buffer: [64]u8 = undefined;
    const result = try guid.toString(&buffer);

    // Convert result to uppercase for comparison
    var upper_result: [36]u8 = undefined;
    for (result, 0..) |c, i| {
        upper_result[i] = std.ascii.toUpper(c);
    }

    try testing.expect(std.mem.eql(u8, &upper_result, guid_str));
}

test "GPT header validation" {
    const testing = std.testing;

    var header = gpt.GptHeader.init();
    try testing.expect(header.isValid());
    try testing.expectEqual(@as(u32, gpt.GPT_NPARTITIONS_DEFAULT), header.getNumPartitions());
    try testing.expectEqual(@as(u32, @sizeOf(gpt.GptEntry)), header.getPartitionEntrySize());
}

test "partition entry operations" {
    const testing = std.testing;

    var entry: gpt.GptEntry = std.mem.zeroes(gpt.GptEntry);
    try testing.expect(entry.isEmpty());

    entry.setSize(2048, 1000000); // Start at sector 2048, size 1M sectors
    try testing.expectEqual(@as(u64, 2048), entry.getStartLba());
    try testing.expectEqual(@as(u64, 1000000), entry.getSize());
    try testing.expectEqual(@as(u64, 2048 + 1000000 - 1), entry.getEndLba());
}
