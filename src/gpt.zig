const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GptError = error{
    InvalidSignature,
    InvalidCrc32,
    InvalidHeaderSize,
    InvalidLbaRange,
    OutOfMemory,
    IoError,
    PartitionNotFound,
    PartitionTableFull,
    InvalidUuid,
    // File I/O errors
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    WouldBlock,
    Canceled,
    AccessDenied,
    ProcessNotFound,
    LockViolation,
    Unexpected,
    Unseekable,
    InvalidBufferSize,
    PermissionDenied,
    NoDevice,
    FileTooBig,
    NoSpaceLeft,
    DeviceBusy,
    DiskQuota,
    InvalidArgument,
    NotOpenForWriting,
    MessageTooBig,
    InvalidState,
};

pub const GPT_HEADER_SIGNATURE: u64 = 0x5452415020494645; // "EFI PART"
pub const GPT_HEADER_REVISION_V1_02: u32 = 0x00010200;
pub const GPT_HEADER_REVISION_V1_00: u32 = 0x00010000;
pub const GPT_HEADER_MINSZ: u32 = 92;
pub const GPT_PRIMARY_PARTITION_TABLE_LBA: u64 = 1;
pub const GPT_PART_NAME_LEN: usize = 36; // 72 bytes / 2
pub const GPT_NPARTITIONS_DEFAULT: u32 = 128;

pub const Guid = extern struct {
    time_low: u32,
    time_mid: u16,
    time_hi_and_version: u16,
    clock_seq_hi: u8,
    clock_seq_low: u8,
    node: [6]u8,

    pub fn isEmpty(self: *const Guid) bool {
        return self.time_low == 0 and
            self.time_mid == 0 and
            self.time_hi_and_version == 0 and
            self.clock_seq_hi == 0 and
            self.clock_seq_low == 0 and
            std.mem.eql(u8, &self.node, &[_]u8{0} ** 6);
    }

    pub fn fromString(str: []const u8) !Guid {
        // Parse UUID string format like "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        if (str.len != 36) return GptError.InvalidUuid;

        var guid: Guid = undefined;

        // Parse time_low (8 hex chars)
        guid.time_low = try std.fmt.parseInt(u32, str[0..8], 16);

        // Parse time_mid (4 hex chars)
        guid.time_mid = try std.fmt.parseInt(u16, str[9..13], 16);

        // Parse time_hi_and_version (4 hex chars)
        guid.time_hi_and_version = try std.fmt.parseInt(u16, str[14..18], 16);

        // Parse clock_seq_hi and clock_seq_low (2 hex chars each)
        guid.clock_seq_hi = try std.fmt.parseInt(u8, str[19..21], 16);
        guid.clock_seq_low = try std.fmt.parseInt(u8, str[21..23], 16);

        // Parse node (12 hex chars, 6 bytes)
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            guid.node[i] = try std.fmt.parseInt(u8, str[24 + i * 2 .. 24 + i * 2 + 2], 16);
        }

        return guid;
    }

    pub fn toString(self: *const Guid, buffer: []u8) ![]const u8 {
        if (buffer.len < 36) return error.BufferTooSmall;

        return std.fmt.bufPrint(buffer, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ self.time_low, self.time_mid, self.time_hi_and_version, self.clock_seq_hi, self.clock_seq_low, self.node[0], self.node[1], self.node[2], self.node[3], self.node[4], self.node[5] });
    }

    pub fn random() Guid {
        var rng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))));
        var node: [6]u8 = undefined;
        rng.random().bytes(&node);
        return Guid{
            .time_low = rng.random().int(u32),
            .time_mid = rng.random().int(u16),
            .time_hi_and_version = rng.random().int(u16),
            .clock_seq_hi = rng.random().int(u8),
            .clock_seq_low = rng.random().int(u8),
            .node = node,
        };
    }
};

pub const GptEntry = extern struct {
    type_guid: Guid,
    partition_guid: Guid,
    lba_start: u64,
    lba_end: u64,
    attrs: u64,
    name: [GPT_PART_NAME_LEN]u16,

    pub fn isEmpty(self: *const GptEntry) bool {
        return self.type_guid.isEmpty();
    }

    pub fn getStartLba(self: *const GptEntry) u64 {
        return std.mem.littleToNative(u64, self.lba_start);
    }

    pub fn getEndLba(self: *const GptEntry) u64 {
        return std.mem.littleToNative(u64, self.lba_end);
    }

    pub fn getSize(self: *const GptEntry) u64 {
        const start = self.getStartLba();
        const end = self.getEndLba();
        if (end >= start) {
            return end - start + 1;
        }
        return 0;
    }

    pub fn setLbaRange(self: *GptEntry, start: u64, end: u64) void {
        self.lba_start = std.mem.nativeToLittle(u64, start);
        self.lba_end = std.mem.nativeToLittle(u64, end);
    }

    pub fn setSize(self: *GptEntry, start: u64, size: u64) void {
        if (size > 0) {
            self.setLbaRange(start, start + size - 1);
        }
    }

    pub fn getName(self: *const GptEntry, allocator: Allocator) ![]const u8 {
        // Simple conversion from UTF-16 to UTF-8
        // Find null terminator
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) : (len += 1) {}

        // Allocate buffer for name
        var result = try allocator.alloc(u8, len);
        for (self.name[0..len], 0..) |char, i| {
            // Simple ASCII conversion (assuming most partition names are ASCII)
            result[i] = @truncate(char);
        }
        return result;
    }

    pub fn setName(self: *GptEntry, name: []const u8) !void {
        // Convert UTF-8 to UTF-16
        const utf16_len = try std.unicode.utf8ToUtf16Le(&self.name, name);
        if (utf16_len < self.name.len) {
            self.name[utf16_len] = 0; // Null terminate
        }
    }
};

pub const GptHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved1: u32,
    my_lba: u64,
    alternate_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: Guid,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    sizeof_partition_entry: u32,
    partition_entry_array_crc32: u32,
    reserved2: [420]u8, // 512 - 92 = 420

    pub fn init() GptHeader {
        return GptHeader{
            .signature = std.mem.nativeToLittle(u64, GPT_HEADER_SIGNATURE),
            .revision = std.mem.nativeToLittle(u32, GPT_HEADER_REVISION_V1_00),
            .header_size = std.mem.nativeToLittle(u32, GPT_HEADER_MINSZ),
            .header_crc32 = 0,
            .reserved1 = 0,
            .my_lba = 0,
            .alternate_lba = 0,
            .first_usable_lba = 0,
            .last_usable_lba = 0,
            .disk_guid = std.mem.zeroes(Guid),
            .partition_entry_lba = 0,
            .num_partition_entries = std.mem.nativeToLittle(u32, GPT_NPARTITIONS_DEFAULT),
            .sizeof_partition_entry = std.mem.nativeToLittle(u32, @sizeOf(GptEntry)),
            .partition_entry_array_crc32 = 0,
            .reserved2 = std.mem.zeroes([420]u8),
        };
    }

    pub fn isValid(self: *const GptHeader) bool {
        const signature = std.mem.littleToNative(u64, self.signature);
        return signature == GPT_HEADER_SIGNATURE;
    }

    pub fn getRevision(self: *const GptHeader) u32 {
        return std.mem.littleToNative(u32, self.revision);
    }

    pub fn getHeaderSize(self: *const GptHeader) u32 {
        return std.mem.littleToNative(u32, self.header_size);
    }

    pub fn getNumPartitions(self: *const GptHeader) u32 {
        return std.mem.littleToNative(u32, self.num_partition_entries);
    }

    pub fn getPartitionEntrySize(self: *const GptHeader) u32 {
        return std.mem.littleToNative(u32, self.sizeof_partition_entry);
    }

    pub fn getPartitionLba(self: *const GptHeader) u64 {
        return std.mem.littleToNative(u64, self.partition_entry_lba);
    }

    pub fn getFirstUsableLba(self: *const GptHeader) u64 {
        return std.mem.littleToNative(u64, self.first_usable_lba);
    }

    pub fn getLastUsableLba(self: *const GptHeader) u64 {
        return std.mem.littleToNative(u64, self.last_usable_lba);
    }

    pub fn getMyLba(self: *const GptHeader) u64 {
        return std.mem.littleToNative(u64, self.my_lba);
    }

    pub fn getAlternateLba(self: *const GptHeader) u64 {
        return std.mem.littleToNative(u64, self.alternate_lba);
    }
};

pub const PartitionType = enum {
    linux_filesystem,
    linux_swap,
    linux_home,
    efi_system,
    linux_raid,
    linux_lvm,

    pub fn toGuid(self: PartitionType) !Guid {
        const guid_str = switch (self) {
            .linux_filesystem => "0FC63DAF-8483-4772-8E79-3D69D8477DE4",
            .linux_swap => "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F",
            .linux_home => "933AC7E1-2EB4-4F13-B844-0E14E2AEF915",
            .efi_system => "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
            .linux_raid => "A19D880F-05FC-4D3B-A006-743F0F84911E",
            .linux_lvm => "E6D6D379-F507-44C2-A23C-238F2A3DF928",
        };
        return Guid.fromString(guid_str);
    }
};

comptime {
    std.debug.assert(@sizeOf(GptEntry) == 128);
    std.debug.assert(@sizeOf(GptHeader) == 512);
    std.debug.assert(@sizeOf(Guid) == 16);
}
