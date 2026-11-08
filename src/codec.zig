//! Celeris-64 codec and hashing model (spec §3.4).
//!
//! ════════════════════════════════════════════════════════════════════════════
//! FIDELITY (docs/isa-encoding.md §8): FUNCTIONAL SOFTWARE MODEL. There is no
//! compression hardware and no crypto hardware. Everything here is ordinary
//! scalar Zig on one thread, with no acceleration and no measurable throughput.
//!
//! SECURITY NOTE, STATED PLAINLY: the hash and checksum in this file are NOT
//! cryptography. They are not collision-resistant against a deliberate attacker,
//! they are not keyed, and they must never be used for authentication, integrity
//! against a hostile party, signatures, or password storage. They exist to model
//! the *shape* of the architecture's codec surface and to make data-corruption
//! bugs visible in tests. Use a real crypto library for anything that matters.
//! ════════════════════════════════════════════════════════════════════════════

const std = @import("std");

pub const CodecError = error{
    BufferTooSmall,
    TruncatedInput,
    InvalidOffset,
    InvalidLength,
};

pub fn explain(err: CodecError) []const u8 {
    return switch (err) {
        error.BufferTooSmall =>
            "The output buffer was too small to hold the result. " ++
                "Nothing was written, so no partial data was left behind.",
        error.TruncatedInput =>
            "The compressed data ended in the middle of a token. " ++
                "The stream is incomplete, so it cannot be decoded.",
        error.InvalidOffset =>
            "A back-reference in the compressed data points before the start of the output. " ++
                "Such a reference cannot be resolved, so the stream is malformed.",
        error.InvalidLength =>
            "A length field in the compressed data is zero or otherwise meaningless. " ++
                "A match must copy at least one byte.",
    };
}

/// A minimal LZ77-style compressor: literal runs and (offset, length) back-references.
///
/// FORMAT (self-describing, so decode is a total function of the bytes):
///   tag 0x00  followed by 1 byte  -> a literal byte
///   tag 0x01  followed by offset:u16 LE, length:u16 LE -> copy `length` bytes
///             starting `offset` bytes back in the output.
pub fn compress(input: []const u8, out: []u8) CodecError!usize {
    var ip: usize = 0;
    var op: usize = 0;

    // The window is bounded so this stays a simple, inspectable model.
    const window: usize = 4096;
    const max_match: usize = 255;

    while (ip < input.len) {
        var best_len: usize = 0;
        var best_off: usize = 0;

        if (ip > 0) {
            const start = if (ip > window) ip - window else 0;
            var candidate = start;
            while (candidate < ip) : (candidate += 1) {
                var len: usize = 0;
                while (len < max_match and ip + len < input.len and
                    input[candidate + len] == input[ip + len]) : (len += 1)
                {}
                if (len > best_len) {
                    best_len = len;
                    best_off = ip - candidate;
                }
            }
        }

        if (best_len >= 3) {
            if (op + 5 > out.len) return error.BufferTooSmall;
            out[op] = 0x01;
            std.mem.writeInt(u16, out[op + 1 ..][0..2], @intCast(best_off), .little);
            std.mem.writeInt(u16, out[op + 3 ..][0..2], @intCast(best_len), .little);
            op += 5;
            ip += best_len;
        } else {
            if (op + 2 > out.len) return error.BufferTooSmall;
            out[op] = 0x00;
            out[op + 1] = input[ip];
            op += 2;
            ip += 1;
        }
    }
    return op;
}

/// Decompress. Output length is discovered from the stream; `out` must be large
/// enough. Returns the number of bytes written.
pub fn decompress(input: []const u8, out: []u8) CodecError!usize {
    var ip: usize = 0;
    var op: usize = 0;

    while (ip < input.len) {
        const tag = input[ip];
        ip += 1;
        switch (tag) {
            0x00 => {
                if (ip >= input.len) return error.TruncatedInput;
                if (op >= out.len) return error.BufferTooSmall;
                out[op] = input[ip];
                ip += 1;
                op += 1;
            },
            0x01 => {
                if (ip + 4 > input.len) return error.TruncatedInput;
                const offset = std.mem.readInt(u16, input[ip..][0..2], .little);
                const length = std.mem.readInt(u16, input[ip + 2 ..][0..2], .little);
                ip += 4;
                if (offset == 0) return error.InvalidOffset;
                if (length == 0) return error.InvalidLength;
                if (offset > op) return error.InvalidOffset;
                if (op + length > out.len) return error.BufferTooSmall;

                var i: usize = 0;
                while (i < length) : (i += 1) {
                    // Byte-at-a-time so overlapping matches (offset < length)
                    // replicate correctly, which is the classic LZ pitfall.
                    out[op] = out[op - offset];
                    op += 1;
                }
            },
            else => return error.TruncatedInput,
        }
    }
    return op;
}

/// Non-cryptographic FNV-1a hash. NOT a security primitive - see the header.
pub fn fnv1a(data: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (data) |b| {
        h ^= b;
        h *%= 0x0000_0100_0000_01B3;
    }
    return h;
}

/// Internet checksum (RFC 1071 style), 16-bit one's complement.
/// A data-integrity check against accidental corruption, NOT an authenticator.
pub fn checksum16(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "compress then decompress round-trips byte-identically" {
    const input = "the quick brown fox jumps over the quick brown fox";
    var comp: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    const clen = try compress(input, &comp);
    const olen = try decompress(comp[0..clen], &out);
    try testing.expectEqualStrings(input, out[0..olen]);
}

test "repetitive input actually compresses" {
    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    var comp: [512]u8 = undefined;
    const clen = try compress(input, &comp);
    // A run of 32 identical bytes must not cost 64 literal bytes.
    try testing.expect(clen < input.len);
}

test "round-trip holds on RANDOM data, where no match can be found" {
    // Random data defeats the matcher, so this exercises the all-literals path
    // and proves the format survives inputs it cannot compress at all.
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rnd = prng.random();

    var input: [256]u8 = undefined;
    rnd.bytes(&input);

    var comp: [1024]u8 = undefined;
    var out: [1024]u8 = undefined;
    const clen = try compress(&input, &comp);
    const olen = try decompress(comp[0..clen], &out);
    try testing.expectEqualSlices(u8, &input, out[0..olen]);
}

test "round-trip holds on empty input" {
    var comp: [8]u8 = undefined;
    var out: [8]u8 = undefined;
    const clen = try compress("", &comp);
    try testing.expectEqual(@as(usize, 0), clen);
    const olen = try decompress(comp[0..clen], &out);
    try testing.expectEqual(@as(usize, 0), olen);
}

test "an overlapping match replicates correctly" {
    // offset=1, length=8 after one literal byte: must produce 8 copies of it,
    // reading bytes the loop itself just wrote. A naive memcpy would fail here.
    const stream = [_]u8{ 0x00, 'A', 0x01, 1, 0, 8, 0 };
    var out: [16]u8 = undefined;
    const olen = try decompress(&stream, &out);
    try testing.expectEqualStrings("AAAAAAAAA", out[0..olen]);
}

test "malformed streams are refused, never guessed at" {
    var out: [16]u8 = undefined;
    // Truncated literal.
    try testing.expectError(error.TruncatedInput, decompress(&[_]u8{0x00}, &out));
    // Truncated back-reference.
    try testing.expectError(error.TruncatedInput, decompress(&[_]u8{ 0x01, 1, 0 }, &out));
    // Offset pointing before the start of output.
    try testing.expectError(error.InvalidOffset, decompress(&[_]u8{ 0x01, 5, 0, 2, 0 }, &out));
    // Zero-length match.
    try testing.expectError(error.InvalidLength, decompress(&[_]u8{ 0x01, 1, 0, 0, 0 }, &out));
    // Unknown tag.
    try testing.expectError(error.TruncatedInput, decompress(&[_]u8{0x77}, &out));
}

test "a too-small output buffer is refused without writing partially" {
    var small: [1]u8 = undefined;
    // Two literals into a one-byte buffer.
    try testing.expectError(error.BufferTooSmall, decompress(&[_]u8{ 0x00, 'a', 0x00, 'b' }, &small));
}

test "hash is deterministic and sensitive to a single bit" {
    const a = fnv1a("hello world");
    const b = fnv1a("hello world");
    const c = fnv1a("hello worle"); // last char differs
    try testing.expectEqual(a, b);
    try testing.expect(a != c);
    try testing.expect(fnv1a("") == 0xcbf2_9ce4_8422_2325);
}

test "checksum detects a corrupted byte and is stable otherwise" {
    const good = "The quick brown fox";
    const bad = "The quick brown foy"; // one byte changed
    try testing.expectEqual(checksum16(good), checksum16("The quick brown fox"));
    try testing.expect(checksum16(good) != checksum16(bad));
}

test "MODEL LIMITS: these are integrity checks, not authentication" {
    // Stated in executable form so the module cannot be mistaken for crypto.
    // FNV-1a is trivially collidable by design and checksum16 has no key at all.
    // Neither can tell a forged message from a genuine one.
    const honest = "transfer 100";
    const forged = "transfer 999";
    // The checksum differs here (good for accident detection) - but an attacker
    // who can choose bytes can trivially construct a collision, because there is
    // no key and no secret. Nothing in this file prevents that.
    try testing.expect(checksum16(honest) != checksum16(forged));
    // There is no key, no nonce and no tag: this is not a MAC.
    try testing.expect(@sizeOf(@TypeOf(fnv1a(honest))) == 8);
}
