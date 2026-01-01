const std = @import("std");
const testing = std.testing;
const zgpt = @import("zgpt");

test "integration: load, resize, save, reload" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_integration_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/complex_gpt.img", std.fs.cwd(), temp_path, .{});

    // First pass: load and resize
    {
        var gpt = try zgpt.ZGpt.init(allocator, temp_path);
        defer gpt.deinit();

        try gpt.load();

        // Get initial size of partition 2
        const initial_info = try gpt.getPartitionInfo(2);
        try testing.expect(initial_info != null);
        const initial_size = initial_info.?.size_sectors;
        var initial_info_copy = initial_info.?;
        initial_info_copy.deinit(allocator);

        // Resize partition 2 to 6MB (fits in available space)
        try gpt.resizePartitionByNumber(2, 6);

        // Save changes
        try gpt.save();

        // Verify resize happened
        const new_info = try gpt.getPartitionInfo(2);
        try testing.expect(new_info != null);
        try testing.expect(new_info.?.size_sectors != initial_size);

        var new_info_copy = new_info.?;
        new_info_copy.deinit(allocator);
    }

    // Second pass: reload and verify persistence
    {
        var gpt = try zgpt.ZGpt.init(allocator, temp_path);
        defer gpt.deinit();

        try gpt.load();

        const reloaded_info = try gpt.getPartitionInfo(2);
        try testing.expect(reloaded_info != null);

        // Size should be approximately 6MB (in sectors)
        const expected_sectors = (6 * 1024 * 1024) / 512;
        try testing.expect(@abs(@as(i64, @intCast(reloaded_info.?.size_sectors)) - @as(i64, @intCast(expected_sectors))) < 100);

        var reloaded_info_copy = reloaded_info.?;
        reloaded_info_copy.deinit(allocator);
    }
}

test "integration: multiple resize operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_multi_resize_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/complex_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Record initial sizes
    const initial_partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(initial_partitions);

    const initial_count = initial_partitions.len;
    try testing.expect(initial_count >= 2);

    // Resize multiple partitions
    try gpt.resizePartitionByNumber(2, 5); // Resize root to 5MB
    try gpt.resizePartitionToMax(4); // Resize home to max

    // Verify all partitions still exist
    const final_partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(final_partitions);

    try testing.expect(final_partitions.len == initial_count);

    // Save and verify persistence
    try gpt.save();
}

test "integration: edge case with minimal disk" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/valid/minimal_gpt.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 1);
    try testing.expectEqualStrings("Tiny", partitions[0].name);

    // Should be able to resize within minimal bounds
    // Copy for modification
    const temp_path = "tests/data/temp_minimal_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};
    try std.fs.cwd().copyFile("tests/data/valid/minimal_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt_temp = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt_temp.deinit();

    try gpt_temp.load();
    try gpt_temp.resizePartitionToMax(1);
}

test "integration: boundary partition handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/edge_cases/boundary_partitions.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 2);

    // Verify partitions are at boundaries
    try testing.expect(partitions[0].start_sector == 34); // First usable LBA

    // Verify names
    try testing.expectEqualStrings("Start boundary", partitions[0].name);
    try testing.expectEqualStrings("End boundary", partitions[1].name);
}

test "integration: error recovery" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with corrupted partition array
    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/invalid/corrupted_partition_array.img");
    defer gpt.deinit();

    try testing.expectError(error.InvalidCrc32, gpt.load());

    // GPT context should remain in safe state after error
    // We can't test much more without exposing internal state
}

test "integration: maximum partitions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/edge_cases/max_partitions.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 128); // Maximum standard GPT partitions

    // Verify all partitions have valid names
    for (partitions, 1..) |partition, i| {
        var expected_name_buf: [32]u8 = undefined;
        const expected_name = try std.fmt.bufPrint(&expected_name_buf, "Part{d}", .{i});
        try testing.expectEqualStrings(expected_name, partition.name);
    }
}
