# Instructions for Copilot

## Project overview

This project is ZGPT, a Zig library for reading and manipulating GPT (GUID Partition Table) partition tables. It's ported from util-linux libfdisk GPT implementation.

## Architecture

**Core modules structure:**
- `gpt.zig`: Core GPT data structures (Guid, GptHeader, GptEntry), constants, and error types
- `gpt_context.zig`: Device I/O operations, sector-level access, CRC validation, header/partition loading
- `resize.zig`: Partition resizing logic with constraints (allow_shrinking, allow_moving, alignment)
- `root.zig`: Public API facade that wraps context operations and provides ZGpt struct
- `main.zig`: CLI interface with commands: list, info, resize, resize-max

**Key patterns:**
- Error handling: Custom error unions (ZGptError, GptError, ResizeError) with specific error mapping
- Resource management: All structures follow init/deinit pattern with explicit allocator management
- Sector-based I/O: All operations work at 512-byte sector level with LBA addressing
- CRC32 validation: Headers and partition arrays must have valid CRCs before/after modifications

**Data flow:**
1. ZGpt.init() → GptContext.init() opens device file and detects size
2. ZGpt.load() → reads primary/backup headers, validates CRCs, loads partition entries
3. Operations modify in-memory structures
4. ZGpt.save() → writes back headers and partition table with CRC updates

## Build system

Use `zig build` for compilation. Key build targets:
- `zig build` - builds library and CLI executable
- `zig build test` - runs unit and integration tests
- `zig build gen-test-images` - generates test disk images via test_image_builder.zig

**Testing approach:**
- Unit tests in tests/unit/ for individual module testing
- Integration tests use temporary disk images copied from tests/data/valid/
- Test generators in tests/generators/ create GPT disk images for testing

## LLM response language

Do not act friendly. Do not give praise. Do not use exclamation marks. Keep your commentary technical and to the point.

## Code style

Do not write comments indicating what you have changed. For example, if I ask you to remove some code, DO NOT put a comment as a placeholder for the deleted code. It is intended to be gone and forgotten. Old code lives in git history, not code comments.

Do not write comments for obvious things like imports or variables. For example, if you are calling a function called run_dhcp(), there is no need for a comment above it to say "// Run DHCP". Make the code speak for itself as much as possible. Comments may be used when there is nuance that may not be obvious from reading the code itself. When comments are used, explain the why, not the what.

**Zig-specific conventions:**
- Use explicit error handling with try/catch, avoid error unions without handling
- All structures should have init/deinit methods taking allocator as first parameter
- Use defer for cleanup immediately after resource allocation
- Prefer compile-time known sizes, use allocator only when necessary
- Use extern struct for binary data layouts (GPT headers/entries)

## Critical workflows

**Adding new resize constraints:**
1. Modify ResizeConstraints struct in resize.zig
2. Update validation logic in resize.resizePartition()
3. Add corresponding unit tests in tests/unit/resize_test.zig

**Modifying GPT structures:**
1. Update extern struct definitions in gpt.zig
2. Verify binary layout matches GPT specification
3. Update CRC calculation logic in gpt_context.zig if header changes
4. Test with existing disk images to ensure compatibility

**Adding CLI commands:**
1. Add command parsing to main.zig
2. Add corresponding ZGpt method to root.zig
3. Update usage string and add example usage
