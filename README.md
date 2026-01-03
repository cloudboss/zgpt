# ZGPT - Zig GPT Partition Library

A Zig library for reading and manipulating GPT (GUID Partition Table) partition tables.

## Features

- **GPT Parsing**: Read and validate GPT headers and partition entries
- **Partition Resizing**: Resize partitions to specific sizes or maximum available space
- **Safety Checks**: Comprehensive validation and error handling
- **Command Line Interface**: Easy-to-use CLI for common operations

## Installation

```bash
zig build
```

## API Usage

### Basic Usage

```zig
const std = @import("std");
const zgpt = @import("zgpt");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open a GPT device
    var gpt = try zgpt.ZGpt.init(allocator, "/dev/nvme0n1");
    defer gpt.deinit();

    // Load the partition table
    try gpt.load();

    // List all partitions
    const partitions = try gpt.listPartitions();
    defer gpt.freePartitionList(partitions);

    for (partitions) |partition| {
        std.debug.print("Partition {}: {s}\\n", .{ partition.partition_number, partition.name });
    }

    // Resize partition 1 to maximum available space
    try gpt.resizePartitionToMax(1);
}
```

### Advanced Usage

```zig
const zgpt = @import("zgpt");

// Resize with specific constraints
var constraints = zgpt.resize.ResizeConstraints{
    .allow_shrinking = false,
    .allow_moving = false,
    .min_size_sectors = 2048,
    .alignment_sectors = 8, // 4KB alignment
};

const operation = zgpt.resize.ResizeOperation.byGigabytes(1, 20); // 20GB
try zgpt.resize.resizePartition(&context, operation, constraints);
```

## Command Line Interface

### List Partitions
```bash
./zig-out/bin/zgpt list /dev/nvme0n1
```

### Show Partition Information
```bash
./zig-out/bin/zgpt info /dev/nvme0n1 1
```

### Resize Partition
```bash
# Resize to specific size (in MB)
./zig-out/bin/zgpt resize /dev/nvme0n1 1 10240

# Resize to maximum available space
./zig-out/bin/zgpt resize-max /dev/nvme0n1 1
```

## Library Structure

### Core Modules

- **`gpt.zig`**: Core GPT data structures (Guid, GptHeader, GptEntry)
- **`GptContext.zig`**: GPT device context and I/O operations
- **`resize.zig`**: Partition resizing functionality
- **`root.zig`**: Main library interface

### Key Types

#### `Guid`
```zig
pub const Guid = extern struct {
    // GUID structure for partition types and identifiers
    pub fn fromString(str: []const u8) !Guid
    pub fn toString(self: *const Guid, buffer: []u8) ![]const u8
    pub fn isEmpty(self: *const Guid) bool
}
```

#### `GptHeader`
```zig
pub const GptHeader = extern struct {
    // GPT header structure
    pub fn init() GptHeader
    pub fn isValid(self: *const GptHeader) bool
    pub fn getNumPartitions(self: *const GptHeader) u32
}
```

#### `GptEntry`
```zig
pub const GptEntry = extern struct {
    // GPT partition entry
    pub fn isEmpty(self: *const GptEntry) bool
    pub fn getStartLba(self: *const GptEntry) u64
    pub fn getEndLba(self: *const GptEntry) u64
    pub fn getSize(self: *const GptEntry) u64
    pub fn setSize(self: *GptEntry, start: u64, size: u64) void
}
```

## EC2 Usage Example

Typical usage for resizing the root partition on an EC2 instance after volume expansion:

```bash
# After expanding the EBS volume in AWS console
sudo ./zig-out/bin/zgpt resize-max /dev/nvme0n1 1
sudo resize2fs /dev/nvme0n1p1  # For ext4 filesystems
```

## Safety and Validation

The library includes comprehensive safety checks:

- **CRC32 validation** of GPT headers and partition arrays
- **Signature verification** of GPT headers
- **Overlap detection** when resizing partitions
- **Boundary checking** against usable LBA ranges
- **Backup header synchronization**

## Error Handling

The library uses Zig's error union types for comprehensive error handling:

```zig
pub const GptError = error{
    InvalidSignature,
    InvalidCrc32,
    InvalidHeaderSize,
    InvalidLbaRange,
    PartitionNotFound,
    NotEnoughSpace,
    // ... and many more I/O errors
};
```

## Testing

```bash
zig build test
```

The test suite includes:
- GUID parsing and formatting tests
- GPT header validation tests
- Partition entry manipulation tests

## Requirements

- Zig 0.15.2 or later
- Root privileges for accessing block devices
- Compatible with GPT partition tables (UEFI/EFI systems)

## Limitations

- Currently supports 512-byte sector sizes only
- Designed primarily for Linux block devices
- Does not support MBR partition tables
- UTF-16 partition names are simplified to ASCII

## Contributing

This library was ported from the util-linux libfdisk GPT implementation. Contributions welcome for:

- Support for non-512-byte sectors
- Better UTF-16 name handling
- Additional partition type definitions
- Performance optimizations

## License

See the source files for individual license information. The GPT implementation is based on util-linux which is licensed under various licenses including GPL.
