//! Celeris-64 native standard library — networking primitives.
//!
//! ────────────────────────────────────────────────────────────────────────────
//! FIDELITY (docs/isa-encoding.md §8): this module is a SOFTWARE MODEL.
//!
//! There is NO network access in this module. It does not open sockets, resolve
//! names, or transmit anything, and it makes no claim to. What it implements is
//! the part of a network stack that is pure arithmetic and therefore testable
//! offline: byte-order conversion, IPv4 header parsing, checksum computation and
//! packet framing/deframing over a caller-supplied buffer.
//!
//! Nothing here has been exercised against a real peer, a real NIC, or a real
//! hardware offload path. Any parser built on it is a model parser.
//! ────────────────────────────────────────────────────────────────────────────
//!
//! Byte order: the Celeris-64 mandate is little-endian in memory (AGENTS.md
//! §2.2), while network headers are big-endian on the wire. The conversion
//! between them is explicit here rather than implicit, because silently
//! mis-ordering a length field is the classic parser bug.

const std = @import("std");

/// Wire (big-endian) helpers. Named after the wire, not the host, so a call site
/// reads as what it means.
pub fn wireU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

pub fn wireU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

pub fn putWireU16(out: []u8, value: u16) void {
    std.mem.writeInt(u16, out[0..2], value, .big);
}

pub fn putWireU32(out: []u8, value: u32) void {
    std.mem.writeInt(u32, out[0..4], value, .big);
}

/// An IPv4 address, stored in wire order (most significant octet first).
pub const Address = struct {
    octets: [4]u8,

    pub fn parse(text: []const u8) error{MalformedAddress}!Address {
        var result: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, text, '.');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i >= 4) return error.MalformedAddress;
            if (part.len == 0 or part.len > 3) return error.MalformedAddress;
            const value = std.fmt.parseInt(u8, part, 10) catch return error.MalformedAddress;
            result[i] = value;
        }
        if (i != 4) return error.MalformedAddress;
        return .{ .octets = result };
    }
};

/// The subset of an IPv4 header this model understands.
pub const Ipv4Header = struct {
    header_len_bytes: u8,
    total_len: u16,
    protocol: u8,
    source: Address,
    destination: Address,
};

pub const ParseError = error{
    /// The buffer is shorter than the header it claims to carry.
    Truncated,
    /// `version` was not 4.
    NotIpv4,
    /// The header length field was below the legal minimum of 5 words.
    HeaderTooShort,
    /// The declared total length exceeds what was actually supplied.
    LengthExceedsBuffer,
};

/// Parses an IPv4 header. Every length is validated before it is used, so a
/// truncated or lying packet is refused rather than read past the end.
pub fn parseIpv4(packet: []const u8) ParseError!Ipv4Header {
    if (packet.len < 20) return error.Truncated;

    const version = packet[0] >> 4;
    if (version != 4) return error.NotIpv4;

    const header_words = packet[0] & 0x0F;
    if (header_words < 5) return error.HeaderTooShort;
    const header_len: usize = @as(usize, header_words) * 4;
    if (packet.len < header_len) return error.Truncated;

    const total_len = wireU16(packet[2..4]);
    // The declared length must be self-consistent with the header, and must not
    // promise more bytes than were supplied.
    if (total_len < header_len) return error.LengthExceedsBuffer;
    if (@as(usize, total_len) > packet.len) return error.LengthExceedsBuffer;

    return .{
        .header_len_bytes = @intCast(header_len),
        .total_len = total_len,
        .protocol = packet[9],
        .source = .{ .octets = packet[12..16].* },
        .destination = .{ .octets = packet[16..20].* },
    };
}

/// The internet checksum (RFC 1071): one's-complement sum of 16-bit big-endian
/// words, with an odd trailing byte treated as the high half of a final word.
pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += wireU16(data[i..][0..2]);
    }
    if (i < data.len) {
        // Odd byte: it is the high octet of the last word.
        sum += @as(u32, data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

/// Frames a payload by prefixing its length. The result is written into `out`.
pub fn frame(payload: []const u8, out: []u8) error{ BufferTooSmall, PayloadTooLarge }![]u8 {
    if (payload.len > std.math.maxInt(u16)) return error.PayloadTooLarge;
    if (out.len < payload.len + 2) return error.BufferTooSmall;
    putWireU16(out[0..2], @intCast(payload.len));
    @memcpy(out[2..][0..payload.len], payload);
    return out[0 .. payload.len + 2];
}

/// Splits one frame off the front of `stream`, returning the payload and the
/// number of bytes consumed.
///
/// A frame that claims more bytes than are present is an error, not a short
/// read: a parser that returns partial data here is how truncation attacks work.
pub fn deframe(stream: []const u8) error{ Truncated, IncompleteFrame }!struct { payload: []const u8, consumed: usize } {
    if (stream.len < 2) return error.Truncated;
    const len = wireU16(stream[0..2]);
    if (stream.len < @as(usize, len) + 2) return error.IncompleteFrame;
    return .{ .payload = stream[2..][0..len], .consumed = @as(usize, len) + 2 };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "wire order is big-endian regardless of host order" {
    const bytes = [_]u8{ 0x12, 0x34 };
    try testing.expectEqual(@as(u16, 0x1234), wireU16(&bytes));
    var out: [2]u8 = undefined;
    putWireU16(&out, 0x1234);
    try testing.expectEqualSlices(u8, &bytes, &out);
}

test "addresses parse and reject malformed text" {
    const a = try Address.parse("192.168.0.1");
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 0, 1 }, &a.octets);
    try testing.expectError(error.MalformedAddress, Address.parse("192.168.0"));
    try testing.expectError(error.MalformedAddress, Address.parse("192.168.0.1.5"));
    try testing.expectError(error.MalformedAddress, Address.parse("192.168.0."));
    try testing.expectError(error.MalformedAddress, Address.parse("192.168.0.999"));
}

test "a packed IPv4 header parses field by field" {
    var header: [20]u8 = @splat(0);
    header[0] = 0x45; // version 4, 5 words
    putWireU16(header[2..4], 20);
    header[9] = 6; // TCP
    @memcpy(header[12..16], &[_]u8{ 10, 0, 0, 1 });
    @memcpy(header[16..20], &[_]u8{ 10, 0, 0, 2 });

    const h = try parseIpv4(&header);
    try testing.expectEqual(@as(u8, 20), h.header_len_bytes);
    try testing.expectEqual(@as(u16, 20), h.total_len);
    try testing.expectEqual(@as(u8, 6), h.protocol);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &h.source.octets);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 2 }, &h.destination.octets);
}

test "a truncated header is refused, never read past the end" {
    var header: [20]u8 = @splat(0);
    header[0] = 0x45;
    putWireU16(header[2..4], 20);

    try testing.expectError(error.Truncated, parseIpv4(header[0..19]));
    try testing.expectError(error.Truncated, parseIpv4(&[_]u8{ 0x45, 0 }));
}

test "a header that promises more bytes than supplied is refused" {
    var header: [20]u8 = @splat(0);
    header[0] = 0x45;
    putWireU16(header[2..4], 6000); // claims a 6000-byte packet
    try testing.expectError(error.LengthExceedsBuffer, parseIpv4(&header));
}

test "a non-IPv4 version and a short header length are both refused" {
    var header: [20]u8 = @splat(0);
    header[0] = 0x65; // version 6
    try testing.expectError(error.NotIpv4, parseIpv4(&header));

    header[0] = 0x44; // version 4, only 4 words
    try testing.expectError(error.HeaderTooShort, parseIpv4(&header));
}

test "the checksum of a valid header field verifies to zero" {
    // Build a header, compute its checksum, insert it, and confirm that
    // re-summing the whole header (checksum field included) yields zero, which
    // is the defining property of a correct internet checksum.
    var header: [20]u8 = @splat(0);
    header[0] = 0x45;
    putWireU16(header[2..4], 20);
    header[8] = 64; // TTL
    header[9] = 6;
    @memcpy(header[12..16], &[_]u8{ 10, 0, 0, 1 });
    @memcpy(header[16..20], &[_]u8{ 10, 0, 0, 2 });

    const sum = checksum(&header);
    putWireU16(header[10..12], sum);
    try testing.expectEqual(@as(u16, 0), checksum(&header));
}

test "the checksum handles an odd trailing byte" {
    // Three bytes: one full word plus a padded half word.
    const odd = [_]u8{ 0x01, 0x02, 0x03 };
    const expected = blk: {
        var sum: u32 = 0x0102 + (@as(u32, 0x03) << 8);
        while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        break :blk @as(u16, @truncate(~sum));
    };
    try testing.expectEqual(expected, checksum(&odd));
}

test "framing then deframing returns the original payload" {
    const payload = "celeris";
    var buf: [32]u8 = undefined;
    const framed = try frame(payload, &buf);

    const result = try deframe(framed);
    try testing.expectEqualStrings(payload, result.payload);
    try testing.expectEqual(payload.len + 2, result.consumed);
}

test "a frame promising more bytes than present is refused, not short-read" {
    var buf: [16]u8 = undefined;
    putWireU16(buf[0..2], 500); // claims 500 bytes
    @memcpy(buf[2..5], "abc");
    try testing.expectError(error.IncompleteFrame, deframe(&buf));
}

test "a stream too short to hold a length prefix is refused" {
    try testing.expectError(error.Truncated, deframe(&[_]u8{0x00}));
}

test "framing refuses a buffer that cannot hold the result" {
    var small: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, frame("abcdefgh", &small));
}

test "multiple frames can be consumed in sequence" {
    var buf: [32]u8 = undefined;
    const a = try frame("one", &buf);
    var rest: [32]u8 = undefined;
    const b = try frame("two", &rest);

    var stream: [32]u8 = undefined;
    @memcpy(stream[0..a.len], a);
    @memcpy(stream[a.len..][0..b.len], b);

    const first = try deframe(stream[0 .. a.len + b.len]);
    try testing.expectEqualStrings("one", first.payload);
    const second = try deframe(stream[first.consumed..][0..b.len]);
    try testing.expectEqualStrings("two", second.payload);
}
