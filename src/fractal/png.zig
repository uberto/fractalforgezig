//! Streaming opaque PNG output.
const std = @import("std");
const Size = @import("export_render.zig").Size;
const testing = std.testing;

const signature = "\x89PNG\r\n\x1a\n";

/// Writes 8-bit RGB PNG from RGBA rows in top-to-bottom order. The caller keeps
/// the writer alive until finish and owns the destination's close and cleanup.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    size: Size,
    rows: u32 = 0,
    state: enum { open, failed, finished } = .open,
    checksum: std.hash.Adler32 = .{},

    pub const Error = std.Io.Writer.Error || error{
        InvalidDimensions,
        InvalidRowLength,
        TooManyRows,
        MissingRows,
        EncoderFailed,
        AlreadyFinished,
    };

    pub fn init(writer: *std.Io.Writer, size: Size) Error!Encoder {
        try size.validate();
        try writer.writeAll(signature);
        var header = [_]u8{0} ** 13;
        std.mem.writeInt(u32, header[0..4], size.width, .big);
        std.mem.writeInt(u32, header[4..8], size.height, .big);
        header[8] = 8;
        header[9] = 2; // truecolor without alpha
        try writeChunk(writer, "IHDR", &header);
        try writeChunk(writer, "IDAT", std.compress.flate.Container.zlib.header());
        return .{ .writer = writer, .size = size };
    }

    pub fn writeRow(self: *Encoder, rgba: []const u8) Error!void {
        try self.requireOpen();
        if (self.rows == self.size.height) return error.TooManyRows;
        if (rgba.len != @as(usize, self.size.width) * 4) return error.InvalidRowLength;
        errdefer self.state = .failed;

        // Zig 0.15.2's full deflater has no implemented streaming drain. Use
        // RFC 1951 stored blocks with one unfiltered row per block and chunk.
        // A maximum-width row is 49,153 bytes, below the 65,535-byte block cap.
        var block: [5 + 1 + 3 * 16_384]u8 = undefined;
        const len: u16 = @intCast(1 + 3 * self.size.width);
        block[0] = @intFromBool(self.rows + 1 == self.size.height); // BFINAL, BTYPE=00
        std.mem.writeInt(u16, block[1..3], len, .little);
        std.mem.writeInt(u16, block[3..5], ~len, .little);
        const row = block[5..][0..len];
        row[0] = 0; // PNG filter None
        for (0..self.size.width) |x| {
            row[1 + 3 * x ..][0..3].* = rgba[4 * x ..][0..3].*;
        }
        self.checksum.update(row);
        try writeChunk(self.writer, "IDAT", block[0 .. 5 + len]);
        self.rows += 1;
    }

    /// Completes the PNG and flushes the borrowed writer. Row-count errors can
    /// be corrected. Any I/O error leaves the destination unusable as a PNG.
    pub fn finish(self: *Encoder) Error!void {
        try self.requireOpen();
        if (self.rows != self.size.height) return error.MissingRows;
        errdefer self.state = .failed;

        var footer: [4]u8 = undefined;
        std.mem.writeInt(u32, &footer, self.checksum.adler, .big);
        try writeChunk(self.writer, "IDAT", &footer);
        try writeChunk(self.writer, "IEND", &.{});
        try self.writer.flush();
        self.state = .finished;
    }

    fn requireOpen(self: Encoder) Error!void {
        switch (self.state) {
            .open => {},
            .failed => return error.EncoderFailed,
            .finished => return error.AlreadyFinished,
        }
    }
};

fn writeChunk(writer: *std.Io.Writer, kind: *const [4]u8, payload: []const u8) std.Io.Writer.Error!void {
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(payload);
    try writer.writeInt(u32, @intCast(payload.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(payload);
    try writer.writeInt(u32, crc.final(), .big);
}

test "a multi-chunk PNG decodes to the original opaque RGB samples" {
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var encoder = try Encoder.init(&writer, .{ .width = 2, .height = 2 });
    try encoder.writeRow(&.{ 10, 20, 30, 40, 50, 60, 70, 80 });
    try encoder.writeRow(&.{ 90, 100, 110, 120, 130, 140, 150, 160 });
    try encoder.finish();

    const encoded = writer.buffered();
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);
    var compressed: [128]u8 = undefined;
    var chunks = std.Io.Writer.fixed(&compressed);
    var idat_count: usize = 0;
    var next: usize = 8;
    while (next < encoded.len) {
        const len = std.mem.readInt(u32, encoded[next..][0..4], .big);
        const chunk = encoded[next + 4 ..][0 .. 4 + len];
        next += len + 8;
        try testing.expectEqual(std.hash.Crc32.hash(chunk), std.mem.readInt(u32, encoded[next..][0..4], .big));
        next += 4;
        if (std.mem.eql(u8, chunk[0..4], "IHDR")) {
            try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0 }, chunk[4..]);
        } else if (std.mem.eql(u8, chunk[0..4], "IDAT")) {
            try chunks.writeAll(chunk[4..]);
            idat_count += 1;
        }
    }
    try testing.expect(idat_count > 1);
    try testing.expectEqualSlices(u8, "IEND", encoded[encoded.len - 8 ..][0..4]);

    var stream = std.Io.Reader.fixed(chunks.buffered());
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater = std.compress.flate.Decompress.init(&stream, .zlib, &window);
    var rows: [14]u8 = undefined;
    try inflater.reader.readSliceAll(&rows);
    try testing.expectError(error.EndOfStream, inflater.reader.takeByte());
    try testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30, 50, 60, 70, 0, 90, 100, 110, 130, 140, 150 }, &rows);
}

test "invalid dimensions fail before writing" {
    var writer = std.Io.Writer.failing;
    for ([_]Size{
        .{ .width = 1, .height = 0 },
        .{ .width = 16_385, .height = 1 },
        .{ .width = 10_001, .height = 10_000 },
    }) |size| try testing.expectError(error.InvalidDimensions, Encoder.init(&writer, size));
}

test "malformed row length does not consume a row" {
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var encoder = try Encoder.init(&writer, .{ .width = 1, .height = 1 });
    try testing.expectError(error.InvalidRowLength, encoder.writeRow(&.{ 1, 2, 3 }));
    try encoder.writeRow(&.{ 1, 2, 3, 255 });
    try encoder.finish();
}

test "finish requires the exact row count" {
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var encoder = try Encoder.init(&writer, .{ .width = 1, .height = 1 });
    try testing.expectError(error.MissingRows, encoder.finish());
    try encoder.writeRow(&.{ 1, 2, 3, 255 });
    try testing.expectError(error.TooManyRows, encoder.writeRow(&.{ 1, 2, 3, 255 }));
    try encoder.finish();
    try testing.expectError(error.AlreadyFinished, encoder.finish());
}

test "I/O failure during a row poisons the encoder" {
    var output: [57]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var encoder = try Encoder.init(&writer, .{ .width = 1, .height = 1 });
    try testing.expectError(error.WriteFailed, encoder.writeRow(&.{ 1, 2, 3, 255 }));
    try testing.expectError(error.EncoderFailed, encoder.finish());
}

test "a tall image streams to a discarding writer" {
    var sink = std.Io.Writer.Discarding.init(&.{});
    var encoder = try Encoder.init(&sink.writer, .{ .width = 1, .height = 16_384 });
    for (0..16_384) |_| try encoder.writeRow(&.{ 10, 20, 30, 255 });
    try encoder.finish();
}

const ShortWriter = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    sink: std.Io.Writer,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ShortWriter = @fieldParentPtr("writer", writer);
        for (data[0 .. data.len - 1]) |part| {
            if (part.len == 0) continue;
            try self.sink.writeByte(part[0]);
            return 1;
        }
        const last = data[data.len - 1];
        if (last.len == 0 or splat == 0) return 0;
        try self.sink.writeByte(last[0]);
        return 1;
    }
};

test "partial writes deliver the complete PNG" {
    var output: [256]u8 = undefined;
    var short = ShortWriter{ .sink = .fixed(&output) };
    var expected: [256]u8 = undefined;
    var normal = std.Io.Writer.fixed(&expected);
    for ([_]*std.Io.Writer{ &short.writer, &normal }) |writer| {
        var encoder = try Encoder.init(writer, .{ .width = 1, .height = 1 });
        try encoder.writeRow(&.{ 10, 20, 30, 255 });
        try encoder.finish();
    }
    try testing.expectEqualSlices(u8, normal.buffered(), short.sink.buffered());
}

const BufferedWriter = struct {
    writer: std.Io.Writer,
    sink: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BufferedWriter = @fieldParentPtr("writer", writer);
        try self.sink.writeAll(writer.buffered());
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.sink.writeAll(part);
            written += part.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.sink.writeAll(last);
        _ = writer.consumeAll();
        return written + last.len * splat;
    }
};

test "finish drains the complete PNG to the sink" {
    var buffer: [256]u8 = undefined;
    var output: [256]u8 = undefined;
    var buffered = BufferedWriter{
        .writer = .{ .buffer = &buffer, .vtable = &BufferedWriter.vtable },
        .sink = .fixed(&output),
    };
    var expected: [256]u8 = undefined;
    var normal = std.Io.Writer.fixed(&expected);
    for ([_]*std.Io.Writer{ &buffered.writer, &normal }) |writer| {
        var encoder = try Encoder.init(writer, .{ .width = 1, .height = 1 });
        try encoder.writeRow(&.{ 10, 20, 30, 255 });
        try encoder.finish();
    }
    try testing.expectEqualSlices(u8, normal.buffered(), buffered.sink.buffered());
}

test "finish drain failure propagates and poisons the encoder" {
    var buffer: [256]u8 = undefined;
    var buffered = BufferedWriter{
        .writer = .{ .buffer = &buffer, .vtable = &BufferedWriter.vtable },
        .sink = .failing,
    };
    var encoder = try Encoder.init(&buffered.writer, .{ .width = 1, .height = 1 });
    try encoder.writeRow(&.{ 10, 20, 30, 255 });
    try testing.expectError(error.WriteFailed, encoder.finish());

    var recovered: [256]u8 = undefined;
    buffered.sink = .fixed(&recovered);
    try testing.expectError(error.EncoderFailed, encoder.finish());
}
