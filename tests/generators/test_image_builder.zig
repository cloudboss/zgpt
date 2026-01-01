const std = @import("std");
const gpt_generator = @import("gpt_generator.zig");
const zgpt = @import("zgpt");

const LINUX_FILESYSTEM_GUID = zgpt.gpt.Guid{
    .time_low = 0x0FC63DAF,
    .time_mid = 0x8483,
    .time_hi_and_version = 0x4772,
    .clock_seq_hi = 0x8E,
    .clock_seq_low = 0x79,
    .node = [_]u8{ 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 },
};

const EFI_SYSTEM_GUID = zgpt.gpt.Guid{
    .time_low = 0xC12A7328,
    .time_mid = 0xF81F,
    .time_hi_and_version = 0x11D2,
    .clock_seq_hi = 0xBA,
    .clock_seq_low = 0x4B,
    .node = [_]u8{ 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B },
};

const SWAP_GUID = zgpt.gpt.Guid{
    .time_low = 0x0657FD6D,
    .time_mid = 0xA4AB,
    .time_hi_and_version = 0x43C4,
    .clock_seq_hi = 0x84,
    .clock_seq_low = 0xE5,
    .node = [_]u8{ 0x09, 0x33, 0xC8, 0x4B, 0x4F, 0x4F },
};

pub fn createBasicGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 10); // 10MB
    defer builder.deinit();

    // Add EFI system partition (512KB)
    try builder.addPartition(EFI_SYSTEM_GUID, 34, 1057, "EFI System");

    // Add main Linux filesystem partition
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 2048, 18431, "Linux filesystem");

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createComplexGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 50); // 50MB
    defer builder.deinit();

    // Add EFI system partition
    try builder.addPartition(EFI_SYSTEM_GUID, 34, 1057, "EFI System");

    // Add Linux filesystem partition with gap after
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 2048, 10239, "Root filesystem");

    // Gap from 10240 to 15359

    // Add swap partition
    try builder.addPartition(SWAP_GUID, 15360, 17407, "Linux swap");

    // Add another Linux partition
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 20480, 98303, "Home filesystem");

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createFullDiskGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 5); // 5MB
    defer builder.deinit();

    // Single partition using entire available space
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 34, 10206, "Full disk");

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createMinimalGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 1); // 1MB - minimal size
    defer builder.deinit();

    // Tiny partition
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 34, 100, "Tiny");

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createEmptyGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 5); // 5MB
    defer builder.deinit();

    // No partitions added

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createMaxPartitionsGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 100); // 100MB
    defer builder.deinit();

    // Create 128 small partitions (maximum for standard GPT)
    var i: u32 = 0;
    while (i < 128) {
        const start_lba = 34 + i * 100;
        const end_lba = start_lba + 99;

        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "Part{d}", .{i + 1});

        try builder.addPartition(LINUX_FILESYSTEM_GUID, start_lba, end_lba, name);
        i += 1;
    }

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createBoundaryPartitionsGpt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var builder = try gpt_generator.GptImageBuilder.init(allocator, 10); // 10MB
    defer builder.deinit();

    // Partition at start boundary
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 34, 1023, "Start boundary");

    // Partition at end boundary
    try builder.addPartition(LINUX_FILESYSTEM_GUID, 18432, 18465, "End boundary");

    var image = try builder.build();
    defer image.deinit();

    try image.writeToFile(output_path);
}

pub fn createCorruptedHeader(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const input_data = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(input_data);

    var output_data = try allocator.dupe(u8, input_data);
    defer allocator.free(output_data);

    // Corrupt the header CRC32 at offset 16 in the GPT header (sector 1)
    const header_offset = 512 + 16;
    output_data[header_offset] = ~output_data[header_offset];

    // Create parent directory if needed
    try ensureDirectoryExists(output_path);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output_data);
}

pub fn createCorruptedPartitionArray(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const input_data = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(input_data);

    var output_data = try allocator.dupe(u8, input_data);
    defer allocator.free(output_data);

    // Corrupt first partition entry at sector 2
    const partition_entry_offset = 2 * 512;
    output_data[partition_entry_offset] = ~output_data[partition_entry_offset];

    // Create parent directory if needed
    try ensureDirectoryExists(output_path);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output_data);
}

pub fn createInvalidSignature(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const input_data = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(input_data);

    var output_data = try allocator.dupe(u8, input_data);
    defer allocator.free(output_data);

    // Corrupt GPT signature at sector 1
    const signature_offset = 512;
    output_data[signature_offset] = 0x42; // Change "EFI PART" to "BFI PART"

    // Create parent directory if needed
    try ensureDirectoryExists(output_path);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output_data);
}

pub fn createTruncated(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const input_data = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(input_data);

    // Truncate to just past partition entries
    const truncated_size = 4 * 512; // Only first 4 sectors
    const output_data = input_data[0..truncated_size];

    // Create parent directory if needed
    try ensureDirectoryExists(output_path);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output_data);
}

fn ensureDirectoryExists(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }
}

pub fn buildAllTestImages(allocator: std.mem.Allocator) !void {
    std.debug.print("Building test images...\n", .{});

    // Valid test images
    try createBasicGpt(allocator, "tests/data/valid/basic_gpt.img");
    std.debug.print("Created tests/data/valid/basic_gpt.img\n", .{});

    try createComplexGpt(allocator, "tests/data/valid/complex_gpt.img");
    std.debug.print("Created tests/data/valid/complex_gpt.img\n", .{});

    try createFullDiskGpt(allocator, "tests/data/valid/full_disk.img");
    std.debug.print("Created tests/data/valid/full_disk.img\n", .{});

    try createMinimalGpt(allocator, "tests/data/valid/minimal_gpt.img");
    std.debug.print("Created tests/data/valid/minimal_gpt.img\n", .{});

    // Edge cases
    try createEmptyGpt(allocator, "tests/data/edge_cases/empty_table.img");
    std.debug.print("Created tests/data/edge_cases/empty_table.img\n", .{});

    try createMaxPartitionsGpt(allocator, "tests/data/edge_cases/max_partitions.img");
    std.debug.print("Created tests/data/edge_cases/max_partitions.img\n", .{});

    try createBoundaryPartitionsGpt(allocator, "tests/data/edge_cases/boundary_partitions.img");
    std.debug.print("Created tests/data/edge_cases/boundary_partitions.img\n", .{});

    // Invalid test images (based on basic GPT)
    try createCorruptedHeader(allocator, "tests/data/valid/basic_gpt.img", "tests/data/invalid/corrupted_header.img");
    std.debug.print("Created tests/data/invalid/corrupted_header.img\n", .{});

    try createCorruptedPartitionArray(allocator, "tests/data/valid/basic_gpt.img", "tests/data/invalid/corrupted_partition_array.img");
    std.debug.print("Created tests/data/invalid/corrupted_partition_array.img\n", .{});

    try createInvalidSignature(allocator, "tests/data/valid/basic_gpt.img", "tests/data/invalid/invalid_signature.img");
    std.debug.print("Created tests/data/invalid/invalid_signature.img\n", .{});

    try createTruncated(allocator, "tests/data/valid/basic_gpt.img", "tests/data/invalid/truncated.img");
    std.debug.print("Created tests/data/invalid/truncated.img\n", .{});

    std.debug.print("All test images created successfully!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try buildAllTestImages(allocator);
}
