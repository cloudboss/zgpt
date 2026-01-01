const std = @import("std");
const testing = std.testing;
const zgpt = @import("zgpt");

test "resize partition to larger size" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_resize_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/complex_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Get initial partition info
    const initial_info = try gpt.getPartitionInfo(2);
    try testing.expect(initial_info != null);
    const initial_size = initial_info.?.size_sectors;
    var initial_info_copy = initial_info.?;
    initial_info_copy.deinit(allocator);

    // Resize partition 2 to 6MB (fits in available space)
    try gpt.resizePartitionByNumber(2, 6);

    // Verify the resize
    const new_info = try gpt.getPartitionInfo(2);
    try testing.expect(new_info != null);
    try testing.expect(new_info.?.size_sectors > initial_size);

    var new_info_copy = new_info.?;
    new_info_copy.deinit(allocator);
}

test "resize partition to maximum size" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_resize_max_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/complex_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Get initial partition info for the last partition
    const initial_info = try gpt.getPartitionInfo(4);
    try testing.expect(initial_info != null);
    const initial_size = initial_info.?.size_sectors;
    var initial_info_copy = initial_info.?;
    initial_info_copy.deinit(allocator);

    // Resize to maximum available space
    try gpt.resizePartitionToMax(4);

    // Verify the resize
    const new_info = try gpt.getPartitionInfo(4);
    try testing.expect(new_info != null);
    try testing.expect(new_info.?.size_sectors >= initial_size);

    var new_info_copy = new_info.?;
    new_info_copy.deinit(allocator);
}

test "resize partition beyond available space" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_resize_overflow_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/complex_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Try to resize partition 2 to an impossibly large size (1TB)
    try testing.expectError(error.NotEnoughSpace, gpt.resizePartitionByNumber(2, 1024 * 1024));
}

test "resize nonexistent partition" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_resize_nonexistent_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/basic_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Try to resize a partition that doesn't exist
    try testing.expectError(error.PartitionNotFound, gpt.resizePartitionByNumber(99, 100));
}

test "resize single partition disk" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_resize_single_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/full_disk.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Get initial partition info
    const initial_info = try gpt.getPartitionInfo(1);
    try testing.expect(initial_info != null);
    const initial_size = initial_info.?.size_sectors;
    var initial_info_copy = initial_info.?;
    initial_info_copy.deinit(allocator);

    // Resize to maximum should work
    try gpt.resizePartitionToMax(1);

    // Verify the resize
    const new_info = try gpt.getPartitionInfo(1);
    try testing.expect(new_info != null);
    try testing.expect(new_info.?.size_sectors >= initial_size);

    var new_info_copy = new_info.?;
    new_info_copy.deinit(allocator);
}

test "resize with invalid size" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Copy test image to temporary location for modification
    const temp_path = "tests/data/temp_resize_invalid_test.img";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try std.fs.cwd().copyFile("tests/data/valid/basic_gpt.img", std.fs.cwd(), temp_path, .{});

    var gpt = try zgpt.ZGpt.init(allocator, temp_path);
    defer gpt.deinit();

    try gpt.load();

    // Try to resize to 0 MB (invalid)
    try testing.expectError(error.InvalidSize, gpt.resizePartitionByNumber(1, 0));
}
