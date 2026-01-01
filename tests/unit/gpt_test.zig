const std = @import("std");
const testing = std.testing;
const zgpt = @import("zgpt");

test "load basic GPT image" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/valid/basic_gpt.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 2);
    try testing.expectEqualStrings("EFI System", partitions[0].name);
    try testing.expectEqualStrings("Linux filesystem", partitions[1].name);
}

test "load complex GPT image" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/valid/complex_gpt.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 4);
    try testing.expectEqualStrings("EFI System", partitions[0].name);
    try testing.expectEqualStrings("Root filesystem", partitions[1].name);
    try testing.expectEqualStrings("Linux swap", partitions[2].name);
    try testing.expectEqualStrings("Home filesystem", partitions[3].name);

    // Check for gaps between partitions
    try testing.expect(partitions[1].end_sector < partitions[2].start_sector - 1);
}

test "load empty GPT table" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/edge_cases/empty_table.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 0);
}

test "load full disk GPT" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/valid/full_disk.img");
    defer gpt.deinit();

    try gpt.load();

    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    try testing.expect(partitions.len == 1);
    try testing.expectEqualStrings("Full disk", partitions[0].name);
}

test "load corrupted header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/invalid/corrupted_header.img");
    defer gpt.deinit();

    try testing.expectError(error.InvalidCrc32, gpt.load());
}

test "load invalid signature" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/invalid/invalid_signature.img");
    defer gpt.deinit();

    try testing.expectError(error.InvalidSignature, gpt.load());
}

test "load truncated image" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/invalid/truncated.img");
    defer gpt.deinit();

    try testing.expectError(error.InputOutput, gpt.load());
}

test "partition info retrieval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gpt = try zgpt.ZGpt.init(allocator, "tests/data/valid/basic_gpt.img");
    defer gpt.deinit();

    try gpt.load();

    const partition_info = try gpt.getPartitionInfo(1);
    try testing.expect(partition_info != null);

    if (partition_info) |info| {
        try testing.expectEqualStrings("EFI System", info.name);
        try testing.expect(info.start_sector == 34);
        try testing.expect(info.size_sectors > 0);
        try testing.expect(info.size_bytes > 0);

        var info_copy = info;
        info_copy.deinit(allocator);
    }

    const nonexistent_partition = try gpt.getPartitionInfo(99);
    try testing.expect(nonexistent_partition == null);
}
