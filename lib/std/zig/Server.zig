in: std.fs.File,
out: std.fs.File,
receive_fifo: std.fifo.LinearFifo(u8, .Dynamic),

pub const Message = struct {
    pub const Header = extern struct {
        tag: Tag,
        /// Size of the body only; does not include this Header.
        bytes_len: u32,
    };

    pub const Tag = enum(u32) {
        /// Body is a UTF-8 string.
        zig_version,
        /// Body is an ErrorBundle.
        error_bundle,
        /// Body is a EmitDigest.
        emit_digest,
        /// Body is a TestMetadata
        test_metadata,
        /// Body is a TestResults
        test_results,
        /// Body is a series of strings, delimited by null bytes.
        /// Each string is a prefixed file path.
        /// The first byte indicates the file prefix path (see prefixes fields
        /// of Cache). This byte is sent over the wire incremented so that null
        /// bytes are not confused with string terminators.
        /// The remaining bytes is the file path relative to that prefix.
        /// The prefixes are hard-coded in Compilation.create (cwd, zig lib dir, local cache dir)
        file_system_inputs,
        /// Body is a u64le that indicates the file path within the cache used
        /// to store coverage information. The integer is a hash of the PCs
        /// stored within that file.
        coverage_id,
        /// Body is a u64le that indicates the function pointer virtual memory
        /// address of the fuzz unit test. This is used to provide a starting
        /// point to view coverage.
        fuzz_start_addr,

        _,
    };

    pub const PathPrefix = enum(u8) {
        cwd,
        zig_lib,
        local_cache,
        global_cache,
    };

    /// Trailing:
    /// * extra: [extra_len]u32,
    /// * string_bytes: [string_bytes_len]u8,
    /// See `std.zig.ErrorBundle`.
    pub const ErrorBundle = extern struct {
        extra_len: u32,
        string_bytes_len: u32,
    };

    /// Trailing:
    /// * name: [tests_len]u32
    ///   - null-terminated string_bytes index
    /// * expected_panic_msg: [tests_len]u32,
    ///   - null-terminated string_bytes index
    ///   - 0 means does not expect panic
    /// * string_bytes: [string_bytes_len]u8,
    pub const TestMetadata = extern struct {
        string_bytes_len: u32,
        tests_len: u32,
    };

    pub const TestResults = extern struct {
        index: u32,
        flags: Flags,

        pub const Flags = packed struct(u32) {
            fail: bool,
            skip: bool,
            leak: bool,
            fuzz: bool,
            log_err_count: u28 = 0,
        };
    };

    /// Trailing:
    /// * the hex digest of the cache directory within the /o/ subdirectory.
    pub const EmitDigest = extern struct {
        flags: Flags,

        pub const Flags = packed struct(u8) {
            cache_hit: bool,
            reserved: u7 = 0,
        };
    };
};

pub const Options = struct {
    gpa: Allocator,
    in: std.fs.File,
    out: std.fs.File,
    zig_version: []const u8,
};

pub fn init(options: Options) !Server {
    var s: Server = .{
        .in = options.in,
        .out = options.out,
        .receive_fifo = std.fifo.LinearFifo(u8, .Dynamic).init(options.gpa),
    };
    try s.serveStringMessage(.zig_version, options.zig_version);
    return s;
}

pub fn deinit(s: *Server) void {
    s.receive_fifo.deinit();
    s.* = undefined;
}

pub fn receiveMessage(s: *Server) !InMessage.Header {
    const Header = InMessage.Header;
    const fifo = &s.receive_fifo;
    var last_amt_zero = false;

    while (true) {
        const buf = fifo.readableSlice(0);
        assert(fifo.readableLength() == buf.len);
        if (buf.len >= @sizeOf(Header)) {
            // workaround for https://github.com/ziglang/zig/issues/14904
            const bytes_len = bswap_and_workaround_u32(buf[4..][0..4]);
            const tag = bswap_and_workaround_tag(buf[0..][0..4]);

            if (buf.len - @sizeOf(Header) >= bytes_len) {
                fifo.discard(@sizeOf(Header));
                return .{
                    .tag = tag,
                    .bytes_len = bytes_len,
                };
            } else {
                const needed = bytes_len - (buf.len - @sizeOf(Header));
                const write_buffer = try fifo.writableWithSize(needed);
                const amt = try s.in.read(write_buffer);
                fifo.update(amt);
                continue;
            }
        }

        const write_buffer = try fifo.writableWithSize(256);
        const amt = try s.in.read(write_buffer);
        fifo.update(amt);
        if (amt == 0) {
            if (last_amt_zero) return error.BrokenPipe;
            last_amt_zero = true;
        }
    }
}

pub fn receiveBody_u32(s: *Server) !u32 {
    const fifo = &s.receive_fifo;
    const buf = fifo.readableSlice(0);
    const result = @as(*align(1) const u32, @ptrCast(buf[0..4])).*;
    fifo.discard(4);
    return bswap(result);
}

pub fn serveStringMessage(s: *Server, tag: OutMessage.Tag, msg: []const u8) !void {
    return s.serveMessage(.{
        .tag = tag,
        .bytes_len = @as(u32, @intCast(msg.len)),
    }, &.{msg});
}

pub fn serveMessage(
    s: *const Server,
    header: OutMessage.Header,
    bufs: []const []const u8,
) !void {
    var iovecs: [10]std.posix.iovec_const = undefined;
    const header_le = bswap(header);
    iovecs[0] = .{
        .base = @as([*]const u8, @ptrCast(&header_le)),
        .len = @sizeOf(OutMessage.Header),
    };
    for (bufs, iovecs[1 .. bufs.len + 1]) |buf, *iovec| {
        iovec.* = .{
            .base = buf.ptr,
            .len = buf.len,
        };
    }
    try s.out.writevAll(iovecs[0 .. bufs.len + 1]);
}

pub fn serveU64Message(s: *Server, tag: OutMessage.Tag, int: u64) !void {
    const msg_le = bswap(int);
    return s.serveMessage(.{
        .tag = tag,
        .bytes_len = @sizeOf(u64),
    }, &.{std.mem.asBytes(&msg_le)});
}

pub fn serveEmitDigest(
    s: *Server,
    digest: *const [Cache.bin_digest_len]u8,
    header: OutMessage.EmitDigest,
) !void {
    try s.serveMessage(.{
        .tag = .emit_digest,
        .bytes_len = @intCast(digest.len + @sizeOf(OutMessage.EmitDigest)),
    }, &.{
        std.mem.asBytes(&header),
        digest,
    });
}

pub fn serveTestResults(
    s: *Server,
    msg: OutMessage.TestResults,
) !void {
    const msg_le = bswap(msg);
    try s.serveMessage(.{
        .tag = .test_results,
        .bytes_len = @intCast(@sizeOf(OutMessage.TestResults)),
    }, &.{
        std.mem.asBytes(&msg_le),
    });
}

pub fn serveErrorBundle(s: *Server, error_bundle: std.zig.ErrorBundle) !void {
    const eb_hdr: OutMessage.ErrorBundle = .{
        .extra_len = @intCast(error_bundle.extra.len),
        .string_bytes_len = @intCast(error_bundle.string_bytes.len),
    };
    const bytes_len = @sizeOf(OutMessage.ErrorBundle) +
        4 * error_bundle.extra.len + error_bundle.string_bytes.len;
    try s.serveMessage(.{
        .tag = .error_bundle,
        .bytes_len = @intCast(bytes_len),
    }, &.{
        std.mem.asBytes(&eb_hdr),
        // TODO: implement @ptrCast between slices changing the length
        std.mem.sliceAsBytes(error_bundle.extra),
        error_bundle.string_bytes,
    });
}

pub const TestMetadata = struct {
    names: []u32,
    expected_panic_msgs: []u32,
    string_bytes: []const u8,
};

pub fn serveTestMetadata(s: *Server, test_metadata: TestMetadata) !void {
    const header: OutMessage.TestMetadata = .{
        .tests_len = bswap(@as(u32, @intCast(test_metadata.names.len))),
        .string_bytes_len = bswap(@as(u32, @intCast(test_metadata.string_bytes.len))),
    };
    const trailing = 2;
    const bytes_len = @sizeOf(OutMessage.TestMetadata) +
        trailing * @sizeOf(u32) * test_metadata.names.len + test_metadata.string_bytes.len;

    if (need_bswap) {
        bswap_u32_array(test_metadata.names);
        bswap_u32_array(test_metadata.expected_panic_msgs);
    }
    defer if (need_bswap) {
        bswap_u32_array(test_metadata.names);
        bswap_u32_array(test_metadata.expected_panic_msgs);
    };

    return s.serveMessage(.{
        .tag = .test_metadata,
        .bytes_len = @intCast(bytes_len),
    }, &.{
        std.mem.asBytes(&header),
        // TODO: implement @ptrCast between slices changing the length
        std.mem.sliceAsBytes(test_metadata.names),
        std.mem.sliceAsBytes(test_metadata.expected_panic_msgs),
        test_metadata.string_bytes,
    });
}

fn bswap(x: anytype) @TypeOf(x) {
    if (!need_bswap) return x;

    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .@"enum" => return @as(T, @enumFromInt(@byteSwap(@intFromEnum(x)))),
        .int => return @byteSwap(x),
        .@"struct" => |info| switch (info.layout) {
            .@"extern" => {
                var result: T = undefined;
                inline for (info.fields) |field| {
                    @field(result, field.name) = bswap(@field(x, field.name));
                }
                return result;
            },
            .@"packed" => {
                const I = info.backing_integer.?;
                return @as(T, @bitCast(@byteSwap(@as(I, @bitCast(x)))));
            },
            .auto => @compileError("auto layout struct"),
        },
        else => @compileError("bswap on type " ++ @typeName(T)),
    }
}

fn bswap_u32_array(slice: []u32) void {
    comptime assert(need_bswap);
    for (slice) |*elem| elem.* = @byteSwap(elem.*);
}

/// workaround for https://github.com/ziglang/zig/issues/14904
fn bswap_and_workaround_u32(bytes_ptr: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes_ptr, .little);
}

/// workaround for https://github.com/ziglang/zig/issues/14904
fn bswap_and_workaround_tag(bytes_ptr: *const [4]u8) InMessage.Tag {
    const int = std.mem.readInt(u32, bytes_ptr, .little);
    return @as(InMessage.Tag, @enumFromInt(int));
}

const OutMessage = std.zig.Server.Message;
const InMessage = std.zig.Client.Message;

const Server = @This();
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const native_endian = builtin.target.cpu.arch.endian();
const need_bswap = native_endian != .little;
const Cache = std.Build.Cache;
