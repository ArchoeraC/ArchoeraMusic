//! ASF 数据包 → WMA superframe 重组（最小 asfdec_f.c 移植：单音频流、无扩展）。
//!
//! 语义对齐 FFmpeg libavformat/asfdec_f.c：std-ecc 0x82 00 00 同步包；
//! 每个 segment 的 replicated header（packet_obj_size + timestamp）给出音频对象
//! 总长；frag_offset/frag_size 描述本段在该对象中的位置。对象完整后按序回调，
//! 输出为 block_align 大小 superframe 字节流（含解码器所见补零/填充）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const asf = @import("asf.zig");

const Reader = struct {
    b: []const u8,
    p: usize = 0,

    fn u8b(self: *Reader) Error!u8 {
        if (self.p >= self.b.len) return error.Corrupt;
        const v = self.b[self.p];
        self.p += 1;
        return v;
    }
    fn u16le(self: *Reader) Error!u16 {
        if (self.p + 2 > self.b.len) return error.Corrupt;
        const v = std.mem.readInt(u16, self.b[self.p..][0..2], .little);
        self.p += 2;
        return v;
    }
    fn u32le(self: *Reader) Error!u32 {
        if (self.p + 4 > self.b.len) return error.Corrupt;
        const v = std.mem.readInt(u32, self.b[self.p..][0..4], .little);
        self.p += 4;
        return v;
    }
    fn remaining(self: *Reader) usize {
        return self.b.len - self.p;
    }
    fn skip(self: *Reader, n: usize) Error!void {
        if (self.p + n > self.b.len) return error.Corrupt;
        self.p += n;
    }
};

fn do2bits(r: *Reader, bits: u8, defval: u32) Error!u32 {
    switch (bits & 3) {
        3 => return r.u32le(),
        2 => return @intCast(try r.u16le()),
        1 => return try r.u8b(),
        else => return defval,
    }
}

const ObjectSink = struct {
    out: []u8, // 容量
    count: usize = 0,
    cur: [4096]u8 = undefined,
    cur_len: usize = 0,
    cur_expect: usize = 0,

    fn begin(self: *ObjectSink, size: usize) Error!void {
        if (size > self.cur.len) return error.UnsupportedFormat;
        if (self.cur_len != 0) return error.Corrupt; // 上一个对象未完成
        self.cur_expect = size;
        self.cur_len = 0;
    }
    fn write(self: *ObjectSink, src: []const u8) Error!void {
        if (self.cur_len + src.len > self.cur_expect) return error.Corrupt;
        @memcpy(self.cur[self.cur_len .. self.cur_len + src.len], src);
        self.cur_len += src.len;
    }
    fn maybeFlush(self: *ObjectSink) Error!void {
        if (self.cur_len == self.cur_expect and self.cur_expect != 0) {
            if (self.count * self.cur_expect + self.cur_expect > self.out.len) return error.OutOfMemory;
            @memcpy(self.out[self.count * self.cur_expect ..][0..self.cur_expect], self.cur[0..self.cur_expect]);
            self.count += 1;
            self.cur_len = 0;
            self.cur_expect = 0;
        }
    }
};

/// ASF 数据包 → WMA Pro packet 流（变长对象）。每个完整音频对象 = 一个 WMA
/// packet（wmapro 解码器 feed 单元，通常 block_align 字节，末个可更短）。
/// 输出写 flat（容量 ≥ 各对象累计长），sizes 记录每个对象长。返回对象数。
pub fn demuxObjects(
    buf: []const u8,
    hdr: *const asf.Header,
    flat: []u8,
    sizes: []usize,
) Error!usize {
    const pkt_size: usize = hdr.packet_size;
    var r = Reader{ .b = buf };
    const start = try asf.dataPacketsOffset(buf, hdr.data_offset);
    r.p = start;

    var out: usize = 0; // 已写对象数
    var written: usize = 0; // 已写字节
    var cur_base: usize = 0;
    var cur_expect: usize = 0;
    var cur_len: usize = 0;

    while (r.remaining() >= 3) {
        const packet_start = r.p;
        if (r.b[r.p] != 0x82 or r.b[r.p + 1] != 0 or r.b[r.p + 2] != 0) {
            var found = false;
            while (r.p + 3 <= r.b.len) : (r.p += 1) {
                if (r.b[r.p] == 0x82 and r.b[r.p + 1] == 0 and r.b[r.p + 2] == 0) {
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
        r.p += 3;
        const flags = try r.u8b();
        const prop = try r.u8b();
        var packet_length: u32 = @intCast(pkt_size);
        packet_length = do2bits(&r, flags >> 5, packet_length) catch return error.Corrupt;
        _ = do2bits(&r, flags >> 1, @as(u32, 0)) catch return error.Corrupt;
        const pad: u32 = do2bits(&r, flags >> 3, @as(u32, 0)) catch return error.Corrupt;
        if (packet_length == 0 or packet_length >= (1 << 29)) return error.Corrupt;
        if (pad >= packet_length) return error.Corrupt;
        _ = try r.u32le();
        _ = try r.u16le();

        var nsegs: usize = 1;
        var segsizetype: u8 = 0x80;
        if (flags & 0x01 != 0) {
            segsizetype = try r.u8b();
            nsegs = segsizetype & 0x3f;
        }
        const payload_end: usize = @min(r.b.len, packet_start + @as(usize, @intCast(packet_length)) - pad);

        var seg: usize = 0;
        while (seg < nsegs) : (seg += 1) {
            if (r.p >= payload_end) break;
            const num = try r.u8b();
            const stream_id = num & 0x7f;
            if (stream_id != 1) return error.UnsupportedFormat;
            _ = do2bits(&r, prop >> 4, @as(u32, 0)) catch return error.Corrupt;
            const frag_offset: u32 = do2bits(&r, prop >> 2, @as(u32, 0)) catch return error.Corrupt;
            const replic: u32 = do2bits(&r, prop, @as(u32, 0)) catch return error.Corrupt;
            if (replic >= 8) {
                const obj_size = try r.u32le();
                _ = try r.u32le();
                if (replic > 8) try r.skip(replic - 8);
                if (frag_offset == 0) {
                    // 对象结束（若有未完成）
                    if (cur_expect != 0 and cur_len != cur_expect) return error.Corrupt;
                    if (out >= sizes.len) return error.OutOfMemory;
                    cur_expect = obj_size;
                    cur_base = written;
                    cur_len = 0;
                }
            } else if (replic == 1) {
                return error.UnsupportedFormat;
            } else if (replic != 0) {
                return error.Corrupt;
            }
            var frag_size: usize = 0;
            if (flags & 0x01 != 0) {
                frag_size = do2bits(&r, segsizetype >> 6, @as(u32, 0)) catch return error.Corrupt;
            } else {
                frag_size = payload_end - r.p;
            }
            if (frag_size > payload_end - r.p) return error.Corrupt;
            // 写片段到对象位置（positional，片段按序到达）
            if (cur_expect == 0) {
                // 无当前对象（跳过多余负载）
                r.p += frag_size;
                continue;
            }
            const fo: usize = frag_offset;
            if (fo + frag_size > cur_expect) return error.Corrupt;
            if (cur_base + fo + frag_size > flat.len) return error.OutOfMemory;
            if (r.p + frag_size <= payload_end) {
                @memcpy(flat[cur_base + fo ..][0..frag_size], r.b[r.p .. r.p + frag_size]);
                r.p += frag_size;
            } else {
                return error.Corrupt;
            }
            cur_len = @max(cur_len, fo + frag_size);
            if (cur_len == cur_expect) {
                sizes[out] = cur_expect;
                out += 1;
                written += cur_expect;
                cur_expect = 0;
                cur_len = 0;
            }
        }
        const next = packet_start + @as(usize, @intCast(packet_length));
        if (next <= r.b.len) {
            r.p = next;
        } else {
            r.p = r.b.len;
        }
    }
    // 尾部：Data Object 截止处的未完成对象按实际长度返回（对齐 asfdec EOF 语义：
    // 最后一个 WMA packet 常短于 block_align，decode_packet 会判 too-small 丢弃）
    if (cur_expect != 0 and cur_len != 0 and cur_len <= cur_expect) {
        if (out >= sizes.len) return error.OutOfMemory;
        sizes[out] = cur_len;
        out += 1;
    } else if (cur_expect != 0 and cur_len != cur_expect) {
        return error.Corrupt;
    }
    return out;
}

/// 把 Data Object 中全部音频对象（每个 = block_align 字节 superframe）写入 objs。
pub fn demuxSuperframes(
    buf: []const u8,
    hdr: *const asf.Header,
    objs: []u8,
) Error!usize {
    const pkt_size: usize = hdr.packet_size;
    var r = Reader{ .b = buf };
    const start = try asf.dataPacketsOffset(buf, hdr.data_offset);
    r.p = start;

    var sink = ObjectSink{ .out = objs };

    while (r.remaining() >= 3) {
        const packet_start = r.p;
        // std-ecc 同步：0x82 00 00
        if (r.b[r.p] != 0x82 or r.b[r.p + 1] != 0 or r.b[r.p + 2] != 0) {
            // 尝试逐字节搜同步（对齐损坏防护）
            var found = false;
            while (r.p + 3 <= r.b.len) : (r.p += 1) {
                if (r.b[r.p] == 0x82 and r.b[r.p + 1] == 0 and r.b[r.p + 2] == 0) {
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
        r.p += 3;
        const flags = try r.u8b();
        const prop = try r.u8b();
        var packet_length: u32 = @intCast(pkt_size);
        packet_length = do2bits(&r, flags >> 5, packet_length) catch return error.Corrupt;
        _ = do2bits(&r, flags >> 1, @as(u32, 0)) catch return error.Corrupt; // sequence
        const pad: u32 = do2bits(&r, flags >> 3, @as(u32, 0)) catch return error.Corrupt;
        if (packet_length == 0 or packet_length >= (1 << 29)) return error.Corrupt;
        if (pad >= packet_length) return error.Corrupt;
        _ = try r.u32le(); // timestamp
        _ = try r.u16le(); // duration

        var nsegs: usize = 1;
        var segsizetype: u8 = 0x80;
        if (flags & 0x01 != 0) {
            segsizetype = try r.u8b();
            nsegs = segsizetype & 0x3f;
        }
        const payload_end: usize = @min(r.b.len, packet_start + @as(usize, @intCast(packet_length)) - pad);

        var seg: usize = 0;
        while (seg < nsegs) : (seg += 1) {
            if (r.p >= payload_end) break;
            const num = try r.u8b();
            const stream_id = num & 0x7f;
            if (stream_id != 1) return error.UnsupportedFormat;
            _ = do2bits(&r, prop >> 4, @as(u32, 0)) catch return error.Corrupt; // seq
            const frag_offset: u32 = do2bits(&r, prop >> 2, @as(u32, 0)) catch return error.Corrupt;
            const replic: u32 = do2bits(&r, prop, @as(u32, 0)) catch return error.Corrupt;
            if (replic >= 8) {
                const obj_size = try r.u32le();
                _ = try r.u32le(); // obj timestamp
                if (replic > 8) try r.skip(replic - 8);
                if (frag_offset == 0) try sink.begin(obj_size);
            } else if (replic == 1) {
                return error.UnsupportedFormat;
            } else if (replic != 0) {
                return error.Corrupt;
            }

            var frag_size: usize = 0;
            if (flags & 0x01 != 0) {
                frag_size = do2bits(&r, segsizetype >> 6, @as(u32, 0)) catch return error.Corrupt;
            } else {
                frag_size = payload_end - r.p;
            }
            if (frag_size > payload_end - r.p) return error.Corrupt;
            // 读负载
            if (r.p + frag_size <= payload_end) {
                try sink.write(r.b[r.p .. r.p + frag_size]);
                r.p += frag_size;
            } else {
                return error.Corrupt;
            }
            try sink.maybeFlush();
        }
        // 跳到本包末尾（含 pad），保持同步
        const next = packet_start + @as(usize, @intCast(packet_length));
        if (next <= r.b.len) {
            r.p = next;
        } else {
            r.p = r.b.len;
        }
    }
    return sink.count;
}
