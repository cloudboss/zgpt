const std = @import("std");
const zgpt = @import("root.zig");
const print = std.debug.print;

const usage =
    \\Usage: zgpt <command> [options]
    \\
    \\Commands:
    \\  list <device>                    List partitions on device
    \\  info <device> <partition_num>    Show partition information
    \\  resize <device> <partition_num> <size_mb>   Resize partition to specific size in MB
    \\  resize-max <device> <partition_num>         Resize partition to maximum available space
    \\
    \\Examples:
    \\  zgpt list /dev/sda
    \\  zgpt info /dev/sda 1
    \\  zgpt resize /dev/sda 1 10240      (resize to 10GB)
    \\  zgpt resize-max /dev/sda 1        (resize to max available space)
    \\
;

fn printUsage() void {
    print("{s}", .{usage});
}

fn formatBytes(bytes: u64, buffer: []u8) []const u8 {
    if (bytes >= 1024 * 1024 * 1024) {
        const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buffer, "{d:.2} GB", .{gb}) catch "? GB";
    } else if (bytes >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buffer, "{d:.2} MB", .{mb}) catch "? MB";
    } else if (bytes >= 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buffer, "{d:.2} KB", .{kb}) catch "? KB";
    } else {
        return std.fmt.bufPrint(buffer, "{} bytes", .{bytes}) catch "? bytes";
    }
}

fn listPartitions(allocator: std.mem.Allocator, device: []const u8) !void {
    var gpt = zgpt.ZGpt.init(allocator, device) catch |err| switch (err) {
        error.DeviceNotFound => {
            print("Error: Device '{s}' not found\n", .{device});
            return;
        },
        error.PermissionDenied => {
            print("Error: Permission denied accessing '{s}'. Try running as root.\n", .{device});
            return;
        },
        else => {
            print("Error: Failed to open device '{s}': {}\n", .{ device, err });
            return;
        },
    };
    defer gpt.deinit();

    gpt.load() catch |err| {
        print("Error: Failed to load GPT from device: {}\n", .{err});
        return;
    };

    const partitions = gpt.listPartitions() catch |err| {
        print("Error: Failed to list partitions: {}\n", .{err});
        return;
    };
    defer gpt.freePartitionList(partitions);

    if (partitions.len == 0) {
        print("No partitions found on device '{s}'\n", .{device});
        return;
    }

    print("Partitions on device '{s}':\n", .{device});
    print("{s:<4} {s:<12} {s:<12} {s:<10} {s}\n", .{ "Num", "Start", "End", "Size", "Name" });
    print("{s}\n", .{"-" ** 60});

    var size_buffer: [32]u8 = undefined;
    for (partitions) |partition| {
        const size_str = formatBytes(partition.size_bytes, &size_buffer);
        print("{:<4} {:<12} {:<12} {s:<10} {s}\n", .{
            partition.partition_number,
            partition.start_sector,
            partition.end_sector,
            size_str,
            partition.name,
        });
    }
}

fn showPartitionInfo(allocator: std.mem.Allocator, device: []const u8, partition_num: u32) !void {
    var gpt = zgpt.ZGpt.init(allocator, device) catch |err| switch (err) {
        error.DeviceNotFound => {
            print("Error: Device '{s}' not found\n", .{device});
            return;
        },
        error.PermissionDenied => {
            print("Error: Permission denied accessing '{s}'. Try running as root.\n", .{device});
            return;
        },
        else => {
            print("Error: Failed to open device '{s}': {}\n", .{ device, err });
            return;
        },
    };
    defer gpt.deinit();

    gpt.load() catch |err| {
        print("Error: Failed to load GPT from device: {}\n", .{err});
        return;
    };

    const partition_info = gpt.getPartitionInfo(partition_num) catch |err| {
        print("Error: Failed to get partition info: {}\n", .{err});
        return;
    };

    if (partition_info) |info| {
        defer {
            var mutable_info = info;
            mutable_info.deinit(allocator);
        }

        var size_buffer: [32]u8 = undefined;
        var guid_buffer: [64]u8 = undefined;

        const size_str = formatBytes(info.size_bytes, &size_buffer);
        const guid_str = info.type_guid.toString(&guid_buffer) catch "Invalid GUID";

        print("Partition {} information:\n", .{partition_num});
        print("  Name: {s}\n", .{info.name});
        print("  Start sector: {}\n", .{info.start_sector});
        print("  End sector: {}\n", .{info.end_sector});
        print("  Size (sectors): {}\n", .{info.size_sectors});
        print("  Size (bytes): {s}\n", .{size_str});
        print("  Type GUID: {s}\n", .{guid_str});
    } else {
        print("Partition {} not found or is empty\n", .{partition_num});
    }
}

fn resizePartition(allocator: std.mem.Allocator, device: []const u8, partition_num: u32, size_mb: u64) !void {
    print("Resizing partition {} on device '{s}' to {} MB...\n", .{ partition_num, device, size_mb });

    var gpt = zgpt.ZGpt.init(allocator, device) catch |err| switch (err) {
        error.DeviceNotFound => {
            print("Error: Device '{s}' not found\n", .{device});
            return;
        },
        error.PermissionDenied => {
            print("Error: Permission denied accessing '{s}'. Try running as root.\n", .{device});
            return;
        },
        else => {
            print("Error: Failed to open device '{s}': {}\n", .{ device, err });
            return;
        },
    };
    defer gpt.deinit();

    gpt.resizePartitionByNumber(partition_num, size_mb) catch |err| switch (err) {
        error.PartitionNotFound => {
            print("Error: Partition {} not found\n", .{partition_num});
            return;
        },
        error.NotEnoughSpace => {
            print("Error: Not enough space to resize partition to {} MB\n", .{size_mb});
            return;
        },
        error.WouldShrink => {
            print("Error: This operation would shrink the partition. Use explicit shrink command if intended.\n", .{});
            return;
        },
        else => {
            print("Error: Failed to resize partition: {}\n", .{err});
            return;
        },
    };

    print("Partition {} successfully resized to {} MB\n", .{ partition_num, size_mb });
}

fn resizeToMax(allocator: std.mem.Allocator, device: []const u8, partition_num: u32) !void {
    print("Resizing partition {} on device '{s}' to maximum available space...\n", .{ partition_num, device });

    var gpt = zgpt.ZGpt.init(allocator, device) catch |err| switch (err) {
        error.DeviceNotFound => {
            print("Error: Device '{s}' not found\n", .{device});
            return;
        },
        error.PermissionDenied => {
            print("Error: Permission denied accessing '{s}'. Try running as root.\n", .{device});
            return;
        },
        else => {
            print("Error: Failed to open device '{s}': {}\n", .{ device, err });
            return;
        },
    };
    defer gpt.deinit();

    gpt.resizePartitionToMax(partition_num) catch |err| switch (err) {
        error.PartitionNotFound => {
            print("Error: Partition {} not found\n", .{partition_num});
            return;
        },
        error.NotEnoughSpace => {
            print("Error: No additional space available for partition {}\n", .{partition_num});
            return;
        },
        else => {
            print("Error: Failed to resize partition: {}\n", .{err});
            return;
        },
    };

    print("Partition {} successfully resized to maximum available space\n", .{partition_num});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];
    const device = args[2];

    if (std.mem.eql(u8, command, "list")) {
        try listPartitions(allocator, device);
    } else if (std.mem.eql(u8, command, "info")) {
        if (args.len < 4) {
            print("Error: partition number required for 'info' command\n", .{});
            printUsage();
            std.process.exit(1);
        }

        const partition_num = std.fmt.parseInt(u32, args[3], 10) catch {
            print("Error: Invalid partition number '{s}'\n", .{args[3]});
            std.process.exit(1);
        };

        try showPartitionInfo(allocator, device, partition_num);
    } else if (std.mem.eql(u8, command, "resize")) {
        if (args.len < 5) {
            print("Error: partition number and size required for 'resize' command\n", .{});
            printUsage();
            std.process.exit(1);
        }

        const partition_num = std.fmt.parseInt(u32, args[3], 10) catch {
            print("Error: Invalid partition number '{s}'\n", .{args[3]});
            std.process.exit(1);
        };

        const size_mb = std.fmt.parseInt(u64, args[4], 10) catch {
            print("Error: Invalid size '{s}'\n", .{args[4]});
            std.process.exit(1);
        };

        try resizePartition(allocator, device, partition_num, size_mb);
    } else if (std.mem.eql(u8, command, "resize-max")) {
        if (args.len < 4) {
            print("Error: partition number required for 'resize-max' command\n", .{});
            printUsage();
            std.process.exit(1);
        }

        const partition_num = std.fmt.parseInt(u32, args[3], 10) catch {
            print("Error: Invalid partition number '{s}'\n", .{args[3]});
            std.process.exit(1);
        };

        try resizeToMax(allocator, device, partition_num);
    } else {
        print("Error: Unknown command '{s}'\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

test "simple test" {
    const testing = std.testing;

    // Test GUID operations
    const guid_str = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";
    const guid = try zgpt.gpt.Guid.fromString(guid_str);

    try testing.expect(!guid.isEmpty());

    var buffer: [64]u8 = undefined;
    const result = try guid.toString(&buffer);

    // Convert to uppercase for comparison
    var upper_result: [36]u8 = undefined;
    for (result, 0..) |c, i| {
        upper_result[i] = std.ascii.toUpper(c);
    }

    try testing.expect(std.mem.eql(u8, &upper_result, guid_str));
}
