const std = @import("std");
const zgpt = @import("zgpt");
const gpt_types = zgpt.gpt;

pub const TestGptImage = struct {
    data: []u8,
    size: u64,
    sector_size: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestGptImage) void {
        self.allocator.free(self.data);
    }

    pub fn writeToFile(self: *const TestGptImage, path: []const u8) !void {
        // Create parent directories if they don't exist
        if (std.fs.path.dirname(path)) |dir_path| {
            try std.fs.cwd().makePath(dir_path);
        }

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(self.data);
    }
};

pub fn createGptEntry(type_guid: gpt_types.Guid, start_lba: u64, end_lba: u64, name: []const u8) gpt_types.GptEntry {
    var entry = gpt_types.GptEntry{
        .type_guid = type_guid,
        .partition_guid = gpt_types.Guid.random(),
        .lba_start = std.mem.nativeToLittle(u64, start_lba),
        .lba_end = std.mem.nativeToLittle(u64, end_lba),
        .attrs = 0,
        .name = std.mem.zeroes([gpt_types.GPT_PART_NAME_LEN]u16),
    };

    // Convert UTF-8 name to UTF-16
    var i: usize = 0;
    while (i < name.len and i < gpt_types.GPT_PART_NAME_LEN - 1) {
        entry.name[i] = @as(u16, name[i]);
        i += 1;
    }

    return entry;
}

pub const GptImageBuilder = struct {
    allocator: std.mem.Allocator,
    sector_size: u32,
    total_sectors: u64,
    partitions: [128]?gpt_types.GptEntry,
    partition_count: u32,
    disk_guid: gpt_types.Guid,

    pub fn init(allocator: std.mem.Allocator, size_mb: u64) !GptImageBuilder {
        const sector_size = 512;
        const total_sectors = (size_mb * 1024 * 1024) / sector_size;

        return GptImageBuilder{
            .allocator = allocator,
            .sector_size = sector_size,
            .total_sectors = total_sectors,
            .partitions = [_]?gpt_types.GptEntry{null} ** 128,
            .partition_count = 0,
            .disk_guid = gpt_types.Guid.random(),
        };
    }

    pub fn deinit(self: *GptImageBuilder) void {
        _ = self;
    }

    pub fn addPartition(self: *GptImageBuilder, type_guid: gpt_types.Guid, start_lba: u64, end_lba: u64, name: []const u8) !void {
        if (self.partition_count >= 128) return error.TooManyPartitions;
        const entry = createGptEntry(type_guid, start_lba, end_lba, name);
        self.partitions[self.partition_count] = entry;
        self.partition_count += 1;
    }

    pub fn build(self: *GptImageBuilder) !TestGptImage {
        const total_size = self.total_sectors * self.sector_size;
        const data = try self.allocator.alloc(u8, total_size);
        @memset(data, 0);

        // Create protective MBR at sector 0
        try self.createProtectiveMbr(data[0..self.sector_size]);

        // Create primary GPT header at sector 1
        const primary_header_offset = self.sector_size;
        try self.createGptHeader(data[primary_header_offset .. primary_header_offset + self.sector_size], true);

        // Create partition entries starting at sector 2
        const entries_start_sector: u64 = 2;
        const entries_offset = entries_start_sector * self.sector_size;
        const entries_size = gpt_types.GPT_NPARTITIONS_DEFAULT * @sizeOf(gpt_types.GptEntry);
        try self.createPartitionEntries(data[entries_offset .. entries_offset + entries_size]);

        // Create backup partition entries
        const backup_entries_sectors = (entries_size + self.sector_size - 1) / self.sector_size;
        const backup_entries_start = self.total_sectors - backup_entries_sectors - 1;
        const backup_entries_offset = backup_entries_start * self.sector_size;
        try self.createPartitionEntries(data[backup_entries_offset .. backup_entries_offset + entries_size]);

        // Create backup GPT header at last sector
        const backup_header_offset = (self.total_sectors - 1) * self.sector_size;
        try self.createGptHeader(data[backup_header_offset .. backup_header_offset + self.sector_size], false);

        return TestGptImage{
            .data = data,
            .size = total_size,
            .sector_size = self.sector_size,
            .allocator = self.allocator,
        };
    }

    fn createProtectiveMbr(self: *GptImageBuilder, sector: []u8) !void {
        @memset(sector, 0);

        // MBR signature
        sector[510] = 0x55;
        sector[511] = 0xAA;

        // Single protective partition entry
        const partition_entry_offset = 446;
        sector[partition_entry_offset] = 0x00; // Non-bootable
        sector[partition_entry_offset + 1] = 0x00; // Start head
        sector[partition_entry_offset + 2] = 0x02; // Start sector
        sector[partition_entry_offset + 3] = 0x00; // Start cylinder
        sector[partition_entry_offset + 4] = 0xEE; // GPT protective type
        sector[partition_entry_offset + 5] = 0xFF; // End head
        sector[partition_entry_offset + 6] = 0xFF; // End sector
        sector[partition_entry_offset + 7] = 0xFF; // End cylinder

        // Start LBA (little endian)
        std.mem.writeInt(u32, sector[partition_entry_offset + 8 .. partition_entry_offset + 12], 1, .little);

        // Size in sectors (little endian)
        const max_mbr_sectors = if (self.total_sectors > 0xFFFFFFFF) 0xFFFFFFFF else @as(u32, @truncate(self.total_sectors - 1));
        std.mem.writeInt(u32, sector[partition_entry_offset + 12 .. partition_entry_offset + 16], max_mbr_sectors, .little);
    }

    fn createGptHeader(self: *GptImageBuilder, sector: []u8, is_primary: bool) !void {
        @memset(sector, 0);

        var header: *gpt_types.GptHeader = @ptrCast(@alignCast(sector.ptr));

        header.signature = std.mem.nativeToLittle(u64, gpt_types.GPT_HEADER_SIGNATURE);
        header.revision = std.mem.nativeToLittle(u32, gpt_types.GPT_HEADER_REVISION_V1_00);
        header.header_size = std.mem.nativeToLittle(u32, gpt_types.GPT_HEADER_MINSZ);
        header.header_crc32 = 0; // Will be calculated later

        if (is_primary) {
            header.my_lba = std.mem.nativeToLittle(u64, 1);
            header.alternate_lba = std.mem.nativeToLittle(u64, self.total_sectors - 1);
            header.partition_entry_lba = std.mem.nativeToLittle(u64, 2);
        } else {
            header.my_lba = std.mem.nativeToLittle(u64, self.total_sectors - 1);
            header.alternate_lba = std.mem.nativeToLittle(u64, 1);
            const backup_entries_sectors = ((gpt_types.GPT_NPARTITIONS_DEFAULT * @sizeOf(gpt_types.GptEntry)) + self.sector_size - 1) / self.sector_size;
            header.partition_entry_lba = std.mem.nativeToLittle(u64, self.total_sectors - backup_entries_sectors - 1);
        }

        header.first_usable_lba = std.mem.nativeToLittle(u64, 34); // After GPT data
        header.last_usable_lba = std.mem.nativeToLittle(u64, self.total_sectors - 34); // Before backup GPT
        header.disk_guid = self.disk_guid;
        header.num_partition_entries = std.mem.nativeToLittle(u32, gpt_types.GPT_NPARTITIONS_DEFAULT);
        header.sizeof_partition_entry = std.mem.nativeToLittle(u32, @sizeOf(gpt_types.GptEntry));

        // Calculate partition array CRC32
        const entries_size = gpt_types.GPT_NPARTITIONS_DEFAULT * @sizeOf(gpt_types.GptEntry);
        const entries_data = try self.allocator.alloc(u8, entries_size);
        defer self.allocator.free(entries_data);
        @memset(entries_data, 0);

        // Create temporary partition entries for CRC calculation
        for (0..self.partition_count) |i| {
            const partition_entry = self.partitions[i].?;
            const entry_offset = i * @sizeOf(gpt_types.GptEntry);
            const entry: *gpt_types.GptEntry = @ptrCast(@alignCast(entries_data[entry_offset .. entry_offset + @sizeOf(gpt_types.GptEntry)].ptr));
            entry.* = partition_entry;
        }

        const partition_crc = std.hash.Crc32.hash(entries_data);
        header.partition_entry_array_crc32 = std.mem.nativeToLittle(u32, partition_crc);

        // Calculate header CRC32 (header_crc32 field must be zero during calculation)
        header.header_crc32 = 0;
        const header_crc = std.hash.Crc32.hash(sector[0..gpt_types.GPT_HEADER_MINSZ]);
        header.header_crc32 = std.mem.nativeToLittle(u32, header_crc);
    }

    fn createPartitionEntries(self: *GptImageBuilder, entries_data: []u8) !void {
        @memset(entries_data, 0);

        for (0..self.partition_count) |i| {
            const partition_entry = self.partitions[i].?;
            const entry_offset = i * @sizeOf(gpt_types.GptEntry);
            const entry: *gpt_types.GptEntry = @ptrCast(@alignCast(entries_data[entry_offset .. entry_offset + @sizeOf(gpt_types.GptEntry)].ptr));
            entry.* = partition_entry;
        }
    }
};
