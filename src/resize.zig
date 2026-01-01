const std = @import("std");
const gpt_types = @import("gpt.zig");
const GptContext = @import("gpt_context.zig").GptContext;
const Allocator = std.mem.Allocator;

pub const ResizeOperation = struct {
    partition_number: u32,
    new_size_sectors: ?u64,
    new_end_sector: ?u64,
    
    pub fn bySectors(partition_number: u32, sectors: u64) ResizeOperation {
        return ResizeOperation{
            .partition_number = partition_number,
            .new_size_sectors = sectors,
            .new_end_sector = null,
        };
    }
    
    pub fn toEndSector(partition_number: u32, end_sector: u64) ResizeOperation {
        return ResizeOperation{
            .partition_number = partition_number,
            .new_size_sectors = null,
            .new_end_sector = end_sector,
        };
    }
    
    pub fn byMegabytes(partition_number: u32, megabytes: u64) ResizeOperation {
        const sectors = (megabytes * 1024 * 1024) / 512; // Assuming 512-byte sectors
        return bySectors(partition_number, sectors);
    }
    
    pub fn byGigabytes(partition_number: u32, gigabytes: u64) ResizeOperation {
        return byMegabytes(partition_number, gigabytes * 1024);
    }
};

pub const ResizeConstraints = struct {
    allow_shrinking: bool = false,
    allow_moving: bool = false,
    min_size_sectors: u64 = 1,
    alignment_sectors: u64 = 1,
};

pub const ResizeError = error{
    PartitionNotFound,
    InvalidSize,
    WouldShrink,
    NotEnoughSpace,
    OverlapDetected,
    AlignmentError,
} || gpt_types.GptError;

pub fn resizePartition(
    context: *GptContext, 
    operation: ResizeOperation,
    constraints: ResizeConstraints
) ResizeError!void {
    try context.load();
    
    const partition = context.getPartition(operation.partition_number) orelse
        return ResizeError.PartitionNotFound;
    
    const header = context.primary_header orelse return ResizeError.PartitionNotFound;
    
    // Calculate the new end sector
    const current_start = partition.getStartLba();
    _ = partition.getEndLba(); // current_end
    const current_size = partition.getSize();
    
    const new_end = if (operation.new_end_sector) |end| 
        end 
    else if (operation.new_size_sectors) |size| 
        current_start + size - 1 
    else 
        return ResizeError.InvalidSize;
    
    const new_size = new_end - current_start + 1;
    
    // Validate constraints
    if (new_size < constraints.min_size_sectors) {
        return ResizeError.InvalidSize;
    }
    
    if (!constraints.allow_shrinking and new_size < current_size) {
        return ResizeError.WouldShrink;
    }
    
    // Check alignment
    if ((new_end + 1) % constraints.alignment_sectors != 0) {
        return ResizeError.AlignmentError;
    }
    
    // Check if we're within usable LBA range
    const last_usable = header.getLastUsableLba();
    if (new_end > last_usable) {
        return ResizeError.NotEnoughSpace;
    }
    
    // Check for overlaps with other partitions
    try checkForOverlaps(context, operation.partition_number, current_start, new_end);
    
    // Perform the resize
    partition.setLbaRange(current_start, new_end);
    
    try context.save();
}

fn checkForOverlaps(
    context: *GptContext, 
    skip_partition: u32, 
    start: u64, 
    end: u64
) ResizeError!void {
    const entries = context.partition_entries orelse return ResizeError.PartitionNotFound;
    
    for (entries, 0..) |*entry, i| {
        if (i == skip_partition or entry.isEmpty()) continue;
        
        const entry_start = entry.getStartLba();
        const entry_end = entry.getEndLba();
        
        // Check for overlap
        if (!(end < entry_start or start > entry_end)) {
            return ResizeError.OverlapDetected;
        }
    }
}

pub fn findNextPartitionStart(context: *GptContext, after_partition: u32) !?u64 {
    const entries = context.partition_entries orelse return null;
    
    const target_partition = context.getPartition(after_partition) orelse return null;
    const target_end = target_partition.getEndLba();
    
    var next_start: ?u64 = null;
    
    for (entries, 0..) |*entry, i| {
        if (i == after_partition or entry.isEmpty()) continue;
        
        const entry_start = entry.getStartLba();
        if (entry_start > target_end) {
            if (next_start == null or entry_start < next_start.?) {
                next_start = entry_start;
            }
        }
    }
    
    return next_start;
}

pub fn calculateMaxResizeSize(context: *GptContext, partition_number: u32) !u64 {
    const partition = context.getPartition(partition_number) orelse return 0;
    const header = context.primary_header orelse return 0;
    
    const current_start = partition.getStartLba();
    _ = partition.getEndLba(); // Use the value to avoid unused variable warning
    
    // Find the next partition start or use the last usable LBA
    const next_start = (try findNextPartitionStart(context, partition_number)) orelse 
        header.getLastUsableLba() + 1;
    
    const max_end = next_start - 1;
    
    if (max_end <= current_start) {
        return 0;
    }
    
    return max_end - current_start + 1;
}

pub fn resizeToMaxSize(
    context: *GptContext,
    partition_number: u32,
    constraints: ResizeConstraints
) ResizeError!void {
    const max_size = try calculateMaxResizeSize(context, partition_number);
    if (max_size == 0) return ResizeError.NotEnoughSpace;
    
    const operation = ResizeOperation.bySectors(partition_number, max_size);
    try resizePartition(context, operation, constraints);
}

pub fn shrinkPartition(
    context: *GptContext,
    partition_number: u32,
    new_size_sectors: u64
) ResizeError!void {
    var constraints = ResizeConstraints{};
    constraints.allow_shrinking = true;
    
    const operation = ResizeOperation.bySectors(partition_number, new_size_sectors);
    try resizePartition(context, operation, constraints);
}

pub fn growPartition(
    context: *GptContext,
    partition_number: u32,
    additional_sectors: u64
) ResizeError!void {
    const partition = context.getPartition(partition_number) orelse 
        return ResizeError.PartitionNotFound;
    
    const current_size = partition.getSize();
    const new_size = current_size + additional_sectors;
    
    const operation = ResizeOperation.bySectors(partition_number, new_size);
    try resizePartition(context, operation, ResizeConstraints{});
}

pub const PartitionInfo = struct {
    partition_number: u32,
    start_sector: u64,
    end_sector: u64,
    size_sectors: u64,
    size_bytes: u64,
    type_guid: gpt_types.Guid,
    name: []const u8,
    
    pub fn deinit(self: *PartitionInfo, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub fn getPartitionInfo(
    context: *GptContext,
    partition_number: u32,
    allocator: Allocator
) !?PartitionInfo {
    const partition = context.getPartition(partition_number) orelse return null;
    
    const name = try partition.getName(allocator);
    
    return PartitionInfo{
        .partition_number = partition_number,
        .start_sector = partition.getStartLba(),
        .end_sector = partition.getEndLba(),
        .size_sectors = partition.getSize(),
        .size_bytes = partition.getSize() * 512, // Assuming 512-byte sectors
        .type_guid = partition.type_guid,
        .name = name,
    };
}

pub fn listPartitions(context: *GptContext, allocator: Allocator) ![]PartitionInfo {
    try context.load();
    
    const entries = context.partition_entries orelse return &[_]PartitionInfo{};
    
    // Count non-empty partitions first
    var count: usize = 0;
    for (entries) |*entry| {
        if (!entry.isEmpty()) count += 1;
    }
    
    var partitions = try allocator.alloc(PartitionInfo, count);
    errdefer allocator.free(partitions);
    var index: usize = 0;
    
    for (entries, 0..) |*entry, i| {
        if (entry.isEmpty()) continue;
        
        if (try getPartitionInfo(context, @as(u32, @intCast(i)), allocator)) |info| {
            partitions[index] = info;
            index += 1;
        }
    }
    
    return partitions[0..index];
}