const std = @import("std");
const gpt_types = @import("gpt.zig");
const Allocator = std.mem.Allocator;

pub const GptContext = struct {
    allocator: Allocator,
    device_file: std.fs.File,
    sector_size: u32,
    device_size: u64,
    primary_header: ?gpt_types.GptHeader,
    backup_header: ?gpt_types.GptHeader,
    partition_entries: ?[]gpt_types.GptEntry,

    const Self = @This();

    pub fn init(allocator: Allocator, device_path: []const u8) !Self {
        const file = try std.fs.openFileAbsolute(device_path, .{ .mode = .read_write });

        // Get device size
        const stat = try file.stat();
        const device_size = stat.size;

        return Self{
            .allocator = allocator,
            .device_file = file,
            .sector_size = 512, // Standard sector size
            .device_size = device_size,
            .primary_header = null,
            .backup_header = null,
            .partition_entries = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.partition_entries) |entries| {
            self.allocator.free(entries);
        }
        self.device_file.close();
    }

    fn seekToLba(self: *Self, lba: u64) !void {
        try self.device_file.seekTo(lba * self.sector_size);
    }

    fn readSector(self: *Self, lba: u64, buffer: []u8) !void {
        if (buffer.len != self.sector_size) {
            return error.InvalidBufferSize;
        }
        try self.seekToLba(lba);
        _ = try self.device_file.readAll(buffer);
    }

    fn writeSector(self: *Self, lba: u64, data: []const u8) !void {
        if (data.len != self.sector_size) {
            return error.InvalidBufferSize;
        }
        try self.seekToLba(lba);
        try self.device_file.writeAll(data);
    }

    fn calculateCrc32(data: []const u8) u32 {
        return std.hash.Crc32.hash(data);
    }

    fn validateHeaderCrc32(header: *gpt_types.GptHeader) !void {
        const original_crc = std.mem.littleToNative(u32, header.header_crc32);

        // Zero out CRC field for calculation
        header.header_crc32 = 0;
        const calculated_crc = calculateCrc32(std.mem.asBytes(header)[0..header.getHeaderSize()]);

        // Restore original CRC
        header.header_crc32 = std.mem.nativeToLittle(u32, original_crc);

        if (original_crc != calculated_crc) {
            return gpt_types.GptError.InvalidCrc32;
        }
    }

    fn updateHeaderCrc32(header: *gpt_types.GptHeader) void {
        header.header_crc32 = 0;
        const crc = calculateCrc32(std.mem.asBytes(header)[0..header.getHeaderSize()]);
        header.header_crc32 = std.mem.nativeToLittle(u32, crc);
    }

    fn validatePartitionArrayCrc32(header: *const gpt_types.GptHeader, entries: []const gpt_types.GptEntry) !void {
        const expected_crc = std.mem.littleToNative(u32, header.partition_entry_array_crc32);
        const entries_size = header.getNumPartitions() * header.getPartitionEntrySize();
        const calculated_crc = calculateCrc32(std.mem.sliceAsBytes(entries)[0..entries_size]);

        if (expected_crc != calculated_crc) {
            return gpt_types.GptError.InvalidCrc32;
        }
    }

    fn updatePartitionArrayCrc32(header: *gpt_types.GptHeader, entries: []const gpt_types.GptEntry) void {
        const entries_size = header.getNumPartitions() * header.getPartitionEntrySize();
        const crc = calculateCrc32(std.mem.sliceAsBytes(entries)[0..entries_size]);
        header.partition_entry_array_crc32 = std.mem.nativeToLittle(u32, crc);
    }

    pub fn readPrimaryHeader(self: *Self) !void {
        var sector_buffer: [512]u8 = undefined;
        try self.readSector(gpt_types.GPT_PRIMARY_PARTITION_TABLE_LBA, &sector_buffer);

        const header = std.mem.bytesToValue(gpt_types.GptHeader, &sector_buffer);

        if (!header.isValid()) {
            return gpt_types.GptError.InvalidSignature;
        }

        var header_copy = header;
        try validateHeaderCrc32(&header_copy);

        self.primary_header = header;
    }

    pub fn readBackupHeader(self: *Self) !void {
        if (self.primary_header == null) {
            try self.readPrimaryHeader();
        }

        const primary = self.primary_header.?;
        const backup_lba = primary.getAlternateLba();

        var sector_buffer: [512]u8 = undefined;
        try self.readSector(backup_lba, &sector_buffer);

        const header = std.mem.bytesToValue(gpt_types.GptHeader, &sector_buffer);

        if (!header.isValid()) {
            return gpt_types.GptError.InvalidSignature;
        }

        var header_copy = header;
        try validateHeaderCrc32(&header_copy);

        self.backup_header = header;
    }

    pub fn readPartitionEntries(self: *Self) !void {
        if (self.primary_header == null) {
            try self.readPrimaryHeader();
        }

        // If partition entries are already loaded, don't reload them
        if (self.partition_entries != null) {
            return;
        }

        const header = self.primary_header.?;
        const entries_lba = header.getPartitionLba();
        const num_entries = header.getNumPartitions();
        const entry_size = header.getPartitionEntrySize();

        if (entry_size != @sizeOf(gpt_types.GptEntry)) {
            return gpt_types.GptError.InvalidHeaderSize;
        }

        // Calculate how many sectors we need to read
        const entries_total_size = num_entries * entry_size;
        const sectors_needed = (entries_total_size + self.sector_size - 1) / self.sector_size;

        // Read all sectors containing partition entries
        const buffer = try self.allocator.alloc(u8, sectors_needed * self.sector_size);
        defer self.allocator.free(buffer);

        var sector: u32 = 0;
        while (sector < sectors_needed) : (sector += 1) {
            const offset = sector * self.sector_size;
            try self.readSector(entries_lba + sector, buffer[offset .. offset + self.sector_size]);
        }

        // Parse partition entries
        const entries = try self.allocator.alloc(gpt_types.GptEntry, num_entries);
        var i: u32 = 0;
        while (i < num_entries) : (i += 1) {
            const entry_offset = i * entry_size;
            entries[i] = std.mem.bytesToValue(gpt_types.GptEntry, buffer[entry_offset .. entry_offset + entry_size]);
        }

        // Validate partition array CRC
        try validatePartitionArrayCrc32(&header, entries);

        self.partition_entries = entries;
    }

    pub fn writePartitionEntries(self: *Self) !void {
        if (self.primary_header == null or self.partition_entries == null) {
            return error.InvalidState;
        }

        var header = self.primary_header.?;
        const entries = self.partition_entries.?;
        const entries_lba = header.getPartitionLba();
        const num_entries = header.getNumPartitions();
        const entry_size = header.getPartitionEntrySize();

        // Update partition array CRC in header
        updatePartitionArrayCrc32(&header, entries);
        self.primary_header = header;

        // Calculate sectors needed
        const entries_total_size = num_entries * entry_size;
        const sectors_needed = (entries_total_size + self.sector_size - 1) / self.sector_size;

        // Create buffer with partition entries
        const buffer = try self.allocator.alloc(u8, sectors_needed * self.sector_size);
        defer self.allocator.free(buffer);

        // Zero the buffer first
        @memset(buffer, 0);

        // Copy partition entries to buffer
        var i: u32 = 0;
        while (i < num_entries) : (i += 1) {
            const entry_offset = i * entry_size;
            const entry_bytes = std.mem.asBytes(&entries[i]);
            @memcpy(buffer[entry_offset .. entry_offset + entry_size], entry_bytes);
        }

        // Write all sectors
        var sector: u32 = 0;
        while (sector < sectors_needed) : (sector += 1) {
            const offset = sector * self.sector_size;
            try self.writeSector(entries_lba + sector, buffer[offset .. offset + self.sector_size]);
        }
    }

    pub fn writePrimaryHeader(self: *Self) !void {
        if (self.primary_header == null) {
            return error.InvalidState;
        }

        var header = self.primary_header.?;
        updateHeaderCrc32(&header);

        var sector_buffer: [512]u8 = undefined;
        @memset(&sector_buffer, 0);
        @memcpy(&sector_buffer, std.mem.asBytes(&header));

        try self.writeSector(gpt_types.GPT_PRIMARY_PARTITION_TABLE_LBA, &sector_buffer);

        self.primary_header = header;
    }

    pub fn writeBackupHeader(self: *Self) !void {
        if (self.primary_header == null) {
            return error.InvalidState;
        }

        var header = self.primary_header.?;
        const backup_lba = header.getAlternateLba();

        // Create backup header (swap my_lba and alternate_lba)
        var backup_header = header;
        backup_header.my_lba = std.mem.nativeToLittle(u64, backup_lba);
        backup_header.alternate_lba = std.mem.nativeToLittle(u64, gpt_types.GPT_PRIMARY_PARTITION_TABLE_LBA);

        updateHeaderCrc32(&backup_header);

        var sector_buffer: [512]u8 = undefined;
        @memset(&sector_buffer, 0);
        @memcpy(&sector_buffer, std.mem.asBytes(&backup_header));

        try self.writeSector(backup_lba, &sector_buffer);
    }

    pub fn load(self: *Self) !void {
        try self.readPrimaryHeader();
        try self.readPartitionEntries();
    }

    pub fn save(self: *Self) !void {
        try self.writePartitionEntries();
        try self.writePrimaryHeader();
        try self.writeBackupHeader();
        try self.device_file.sync();
    }

    pub fn getPartition(self: *Self, partition_num: u32) ?*gpt_types.GptEntry {
        if (self.partition_entries == null) return null;

        const entries = self.partition_entries.?;
        if (partition_num >= entries.len) return null;

        const entry = &entries[partition_num];
        return if (entry.isEmpty()) null else entry;
    }

    pub fn findPartitionByName(self: *Self, name: []const u8, allocator: Allocator) ?*gpt_types.GptEntry {
        if (self.partition_entries == null) return null;

        const entries = self.partition_entries.?;
        for (entries) |*entry| {
            if (entry.isEmpty()) continue;

            if (entry.getName(allocator)) |entry_name| {
                defer allocator.free(entry_name);
                if (std.mem.eql(u8, entry_name, name)) {
                    return entry;
                }
            } else |_| continue;
        }

        return null;
    }
};
