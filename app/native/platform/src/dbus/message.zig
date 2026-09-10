//! D-Bus 线格式：编组（Writer/MessageBuilder）与解组（parseHeader/readBody）。
//!
//! 仅覆盖本桥接所需子面（bridge §4.1）：端序 'l'（LE）、协议版本 1、消息类型
//! 1-4、字段码 1-8、类型 s/u/x/d/b/y/o/g/v/a{sv}/as/结构体。不自研通用 D-Bus
//! 库——类型面收敛是正确性护栏（编组↔解组往返单测见文末）。
//!
//! 解组产生的字符串切片全部指向消息缓冲（零拷贝），随缓冲生命周期失效。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MSG_METHOD_CALL: u8 = 1;
pub const MSG_METHOD_RETURN: u8 = 2;
pub const MSG_ERROR: u8 = 3;
pub const MSG_SIGNAL: u8 = 4;

pub const FIELD_PATH: u8 = 1;
pub const FIELD_INTERFACE: u8 = 2;
pub const FIELD_MEMBER: u8 = 3;
pub const FIELD_ERROR_NAME: u8 = 4;
pub const FIELD_REPLY_SERIAL: u8 = 5;
pub const FIELD_DESTINATION: u8 = 6;
pub const FIELD_SENDER: u8 = 7;
pub const FIELD_SIGNATURE: u8 = 8;

pub const Error = error{
    Malformed,
    UnsupportedEndian,
    OutOfMemory,
};

// ── 编组 ──────────────────────────────────────────────────────────

/// 线格式写入器（LE；对齐：1/4/8 原生对齐，字符串 u32+len+NUL）。
pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    pub fn init(alloc: Allocator) Writer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.alloc);
    }

    pub fn slice(w: *const Writer) []const u8 {
        return w.buf.items;
    }

    pub fn alignTo(w: *Writer, n: usize) Error!void {
        const pad = (n - (w.buf.items.len % n)) % n;
        try w.buf.appendNTimes(w.alloc, 0, pad);
    }

    pub fn putByte(w: *Writer, v: u8) Error!void {
        try w.buf.append(w.alloc, v);
    }

    pub fn putU32(w: *Writer, v: u32) Error!void {
        try w.alignTo(4);
        try w.buf.appendSlice(w.alloc, &std.mem.toBytes(v));
    }

    pub fn putI32(w: *Writer, v: i32) Error!void {
        try w.alignTo(4);
        try w.buf.appendSlice(w.alloc, &std.mem.toBytes(v));
    }

    pub fn putI64(w: *Writer, v: i64) Error!void {
        try w.alignTo(8);
        try w.buf.appendSlice(w.alloc, &std.mem.toBytes(v));
    }

    pub fn putF64(w: *Writer, v: f64) Error!void {
        try w.alignTo(8);
        try w.buf.appendSlice(w.alloc, &std.mem.toBytes(v));
    }

    pub fn putBool(w: *Writer, v: bool) Error!void {
        try w.putU32(if (v) 1 else 0);
    }

    /// 's' / 'o'（对齐 4：u32 长度 + 字节 + NUL）。
    pub fn putString(w: *Writer, s: []const u8) Error!void {
        try w.putU32(@intCast(s.len));
        try w.buf.appendSlice(w.alloc, s);
        try w.buf.append(w.alloc, 0);
    }

    /// 'g'（对齐 1：u8 长度 + 字节 + NUL）。
    pub fn putSignature(w: *Writer, sig: []const u8) Error!void {
        try w.putByte(@intCast(sig.len));
        try w.buf.appendSlice(w.alloc, sig);
        try w.buf.append(w.alloc, 0);
    }

    /// 'v' 前半：只写签名，值由调用者紧随写入（值按自身对齐落位）。
    pub fn putVariantSig(w: *Writer, sig: []const u8) Error!void {
        try w.putSignature(sig);
    }

    /// 结构体/字典条目开头（对齐 8）。
    pub fn beginStruct(w: *Writer) Error!void {
        try w.alignTo(8);
    }

    /// 'a' 前半：u32 长度占位 + 元素对齐垫底；返回回填句柄。
    pub const ArrayMark = struct { len_pos: usize, content_start: usize };

    pub fn beginArray(w: *Writer, elem_align: usize) Error!ArrayMark {
        try w.alignTo(4);
        const len_pos = w.buf.items.len;
        try w.buf.appendSlice(w.alloc, &[_]u8{ 0, 0, 0, 0 });
        try w.alignTo(elem_align);
        return .{ .len_pos = len_pos, .content_start = w.buf.items.len };
    }

    /// 回填数组长度（长度 = 终点 − 内容起点；长度字段后的 padding 不计入）。
    pub fn endArray(w: *Writer, mark: ArrayMark) Error!void {
        const len: u32 = @intCast(w.buf.items.len - mark.content_start);
        std.mem.writeInt(u32, w.buf.items[mark.len_pos..][0..4], len, .little);
    }

    /// a{sv} 单条目：key + variant(sig, value 由调用者紧随写入)。
    pub fn putDictSvKey(w: *Writer, key: []const u8, val_sig: []const u8) Error!void {
        try w.beginStruct();
        try w.putString(key);
        try w.putVariantSig(val_sig);
    }
};

fn appendU32(out: *std.ArrayList(u8), alloc: Allocator, v: u32) Allocator.Error!void {
    try out.appendSlice(alloc, &std.mem.toBytes(v));
}

/// 完整消息组装：header(16) + 字段条目（header 字段数组即 entries 本体，
/// 长度在固定头 offset 12）+ 8 对齐 + body。
pub const MessageBuilder = struct {
    fields: Writer,
    body: Writer,
    msg_type: u8,
    flags: u8 = 0,
    serial: u32,

    pub fn init(alloc: Allocator, msg_type: u8, serial: u32) MessageBuilder {
        return .{
            .fields = Writer.init(alloc),
            .body = Writer.init(alloc),
            .msg_type = msg_type,
            .serial = serial,
        };
    }

    pub fn deinit(b: *MessageBuilder) void {
        b.fields.deinit();
        b.body.deinit();
    }

    fn putFieldStr(b: *MessageBuilder, code: u8, sig: []const u8, s: []const u8) Error!void {
        try b.fields.beginStruct();
        try b.fields.putByte(code);
        try b.fields.putVariantSig(sig);
        try b.fields.putString(s);
    }

    pub fn fieldPath(b: *MessageBuilder, p: []const u8) Error!void {
        try b.putFieldStr(FIELD_PATH, "o", p);
    }

    pub fn fieldInterface(b: *MessageBuilder, s: []const u8) Error!void {
        try b.putFieldStr(FIELD_INTERFACE, "s", s);
    }

    pub fn fieldMember(b: *MessageBuilder, s: []const u8) Error!void {
        try b.putFieldStr(FIELD_MEMBER, "s", s);
    }

    pub fn fieldErrorName(b: *MessageBuilder, s: []const u8) Error!void {
        try b.putFieldStr(FIELD_ERROR_NAME, "s", s);
    }

    pub fn fieldDestination(b: *MessageBuilder, s: []const u8) Error!void {
        try b.putFieldStr(FIELD_DESTINATION, "s", s);
    }

    pub fn fieldReplySerial(b: *MessageBuilder, serial: u32) Error!void {
        try b.fields.beginStruct();
        try b.fields.putByte(FIELD_REPLY_SERIAL);
        try b.fields.putVariantSig("u");
        try b.fields.putU32(serial);
    }

    /// body 签名（必须与实际 body 写入一致；空 body 不写字段）。
    /// 值类型为 'g'（u8 长度 + 字节 + NUL），不能用 putString（u32 长度）。
    pub fn fieldSignature(b: *MessageBuilder, sig: []const u8) Error!void {
        try b.fields.beginStruct();
        try b.fields.putByte(FIELD_SIGNATURE);
        try b.fields.putVariantSig("g");
        try b.fields.putSignature(sig);
    }

    /// 组装完整消息（调用方负责 free 返回切片）。
    pub fn finish(b: *MessageBuilder, alloc: Allocator) (Allocator.Error || Error)![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.ensureTotalCapacity(alloc, 16 + b.fields.buf.items.len + b.body.buf.items.len + 8);
        try out.append(alloc, 'l'); // LE
        try out.append(alloc, b.msg_type);
        try out.append(alloc, b.flags);
        try out.append(alloc, 1); // 协议版本
        try appendU32(&out, alloc, @intCast(b.body.buf.items.len));
        try appendU32(&out, alloc, b.serial);
        try appendU32(&out, alloc, @intCast(b.fields.buf.items.len));
        try out.appendSlice(alloc, b.fields.buf.items);
        // body 从 8 对齐处开始
        const pad = (8 - (out.items.len % 8)) % 8;
        try out.appendNTimes(alloc, 0, pad);
        try out.appendSlice(alloc, b.body.buf.items);
        return out.toOwnedSlice(alloc);
    }
};

// ── 解组 ──────────────────────────────────────────────────────────

fn alignUp(v: usize, n: usize) usize {
    return (v + n - 1) & ~(n - 1);
}

fn readU32At(buf: []const u8, pos: usize) Error!u32 {
    if (pos + 4 > buf.len) return error.Malformed;
    return std.mem.readInt(u32, buf[pos..][0..4], .little);
}

pub const Header = struct {
    msg_type: u8,
    flags: u8,
    serial: u32,
    body_len: u32,
    fields_len: u32,
    body_off: usize,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

/// 完整消息长度（header + 字段数组 + 对齐 + body）。
pub fn messageTotalLen(msg: []const u8) Error!usize {
    if (msg.len < 16) return error.Malformed;
    const fields_len = try readU32At(msg, 12);
    const body_len = try readU32At(msg, 4);
    return alignUp(16 + fields_len, 8) + body_len;
}

/// 解析固定头 + 字段数组（字符串切片指向 msg 缓冲，零拷贝）。
pub fn parseHeader(msg: []const u8) Error!Header {
    if (msg.len < 16) return error.Malformed;
    if (msg[0] != 'l') return error.UnsupportedEndian;
    if (msg[3] != 1) return error.Malformed;
    const body_len = try readU32At(msg, 4);
    const serial = try readU32At(msg, 8);
    const fields_len = try readU32At(msg, 12);
    const fields_end = 16 + fields_len;
    if (msg.len < fields_end) return error.Malformed;

    var h = Header{
        .msg_type = msg[1],
        .flags = msg[2],
        .serial = serial,
        .body_len = body_len,
        .fields_len = fields_len,
        .body_off = alignUp(fields_end, 8),
    };

    var pos: usize = 16;
    while (pos < fields_end) {
        pos = alignUp(pos, 8);
        if (pos >= fields_end) break;
        const code = msg[pos];
        pos += 1;
        // variant：签名 g + 值
        if (pos >= fields_end) return error.Malformed;
        const sig_len: usize = msg[pos];
        pos += 1;
        if (pos + sig_len + 1 > fields_end) return error.Malformed;
        _ = &msg; // 字段值解析按 code 直接读（sig 已知为对应类型）
        pos += sig_len + 1; // 跳过 NUL
        switch (code) {
            FIELD_PATH, FIELD_INTERFACE, FIELD_MEMBER, FIELD_ERROR_NAME, FIELD_DESTINATION, FIELD_SENDER => {
                const v = try readStringish(msg, &pos);
                switch (code) {
                    FIELD_PATH => h.path = v,
                    FIELD_INTERFACE => h.interface = v,
                    FIELD_MEMBER => h.member = v,
                    FIELD_ERROR_NAME => h.error_name = v,
                    FIELD_DESTINATION => h.destination = v,
                    FIELD_SENDER => h.sender = v,
                    else => unreachable,
                }
            },
            FIELD_REPLY_SERIAL => {
                pos = alignUp(pos, 4);
                h.reply_serial = try readU32At(msg, pos);
                pos += 4;
            },
            FIELD_SIGNATURE => {
                if (pos >= msg.len) return error.Malformed;
                const slen: usize = msg[pos];
                pos += 1;
                if (pos + slen + 1 > msg.len) return error.Malformed;
                h.signature = msg[pos .. pos + slen];
                pos += slen + 1;
            },
            else => {},
        }
    }
    if (h.body_off > msg.len) return error.Malformed;
    return h;
}

fn readStringish(msg: []const u8, pos: *usize) Error![]const u8 {
    pos.* = alignUp(pos.*, 4);
    const len = try readU32At(msg, pos.*);
    pos.* += 4;
    if (pos.* + len + 1 > msg.len) return error.Malformed;
    const s = msg[pos.* .. pos.* + len];
    pos.* += len + 1; // 含 NUL
    return s;
}

// ── body 通用解组 ─────────────────────────────────────────────────

pub const Value = union(enum) {
    boolean: bool,
    u32_: u32,
    i64_: i64,
    f64_: f64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    array: []Value,
    struct_: []Value,
    /// 自引用类型禁止按值嵌套，键值经指针。
    dict_entry: struct { key: *Value, val: *Value },
    variant: *Value,
};

pub const DictSvEntry = struct { key: []const u8, val: Value };

/// 完整类型长度（'a' 递归 / 括号配对；基类型 1 字符）。
pub fn completeTypeLen(sig: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < sig.len) : (i += 1) {
        switch (sig[i]) {
            'a' => continue, // 元素类型在后续字符
            '(', '{' => depth += 1,
            ')', '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {
                if (depth == 0) return i + 1;
            },
        }
    }
    return sig.len;
}

fn elemAlign(elem_sig: []const u8) usize {
    return switch (elem_sig[0]) {
        'x', 'd' => 8,
        '(' , '{', 'a' => 8,
        's', 'o' => 4,
        'y', 'g', 'v' => 1,
        else => 4, // b/u/i/n/q
    };
}

const BodyReader = struct {
    buf: []const u8,
    pos: usize = 0,
    alloc: Allocator,

    fn alignTo(r: *BodyReader, n: usize) Error!void {
        const pad = (n - (r.pos % n)) % n;
        if (r.pos + pad > r.buf.len) return error.Malformed;
        r.pos += pad;
    }

    fn take(r: *BodyReader, n: usize) Error![]const u8 {
        if (r.pos + n > r.buf.len) return error.Malformed;
        const s = r.buf[r.pos .. r.pos + n];
        r.pos += n;
        return s;
    }

    fn u32v(r: *BodyReader) Error!u32 {
        try r.alignTo(4);
        const b = try r.take(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn strv(r: *BodyReader) Error![]const u8 {
        const len = try r.u32v();
        const b = try r.take(len + 1); // 含 NUL
        if (b[len] != 0) return error.Malformed;
        return b[0..len];
    }
};

/// 解析 body（sig 为完整 body 签名；返回值切片指向 msg 缓冲，零拷贝）。
pub fn readBody(alloc: Allocator, sig: []const u8, body: []const u8) Error![]Value {
    var r = BodyReader{ .buf = body, .alloc = alloc };
    var values: std.ArrayList(Value) = .empty;
    errdefer values.deinit(alloc);
    var it = SigIterator{ .sig = sig };
    while (it.next()) |one| {
        const v = try parseValue(&r, one);
        try values.append(alloc, v);
    }
    return values.toOwnedSlice(alloc);
}

pub const SigIterator = struct {
    sig: []const u8,
    pos: usize = 0,

    pub fn next(it: *SigIterator) ?[]const u8 {
        if (it.pos >= it.sig.len) return null;
        const n = completeTypeLen(it.sig[it.pos..]);
        const one = it.sig[it.pos .. it.pos + n];
        it.pos += n;
        return one;
    }
};

/// 递归释放 [readBody] 产生的 Value 树（数组/结构体/字典/变体均深释放）。
pub fn freeValues(alloc: Allocator, values: []Value) void {
    for (values) |v| freeValue(alloc, v);
    alloc.free(values);
}

fn freeValue(alloc: Allocator, v: Value) void {
    switch (v) {
        .array => |a| {
            for (a) |e| freeValue(alloc, e);
            alloc.free(a);
        },
        .struct_ => |s| {
            for (s) |e| freeValue(alloc, e);
            alloc.free(s);
        },
        .dict_entry => |d| {
            freeValue(alloc, d.key.*);
            alloc.destroy(d.key);
            freeValue(alloc, d.val.*);
            alloc.destroy(d.val);
        },
        .variant => |p| {
            freeValue(alloc, p.*);
            alloc.destroy(p);
        },
        else => {},
    }
}

fn parseValue(r: *BodyReader, sig: []const u8) Error!Value {
    switch (sig[0]) {
        'y' => return Value{ .u32_ = (try r.take(1))[0] },
        'b' => return Value{ .boolean = (try r.u32v()) != 0 },
        'u' => return Value{ .u32_ = try r.u32v() },
        'x' => {
            try r.alignTo(8);
            const b = try r.take(8);
            return Value{ .i64_ = std.mem.readInt(i64, b[0..8], .little) };
        },
        'd' => {
            try r.alignTo(8);
            const b = try r.take(8);
            return Value{ .f64_ = @bitCast(std.mem.readInt(u64, b[0..8], .little)) };
        },
        's' => return Value{ .string = try r.strv() },
        'o' => return Value{ .object_path = try r.strv() },
        'g' => {
            const len = (try r.take(1))[0];
            const b = try r.take(@as(usize, len) + 1);
            if (b[len] != 0) return error.Malformed;
            return Value{ .signature = b[0..len] };
        },
        'v' => {
            const len = (try r.take(1))[0];
            const sb = try r.take(@as(usize, len) + 1);
            if (sb[len] != 0) return error.Malformed;
            const inner_sig = sb[0..len];
            const inner = try r.alloc.create(Value);
            inner.* = try parseValue(r, inner_sig);
            return Value{ .variant = inner };
        },
        'a' => {
            const elem_sig = sig[1..];
            const total = try r.u32v();
            try r.alignTo(elemAlign(elem_sig));
            const content_start = r.pos;
            if (content_start + total > r.buf.len) return error.Malformed;
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(r.alloc);
            while (r.pos < content_start + total) {
                try items.append(r.alloc, try parseValue(r, elem_sig));
            }
            if (r.pos != content_start + total) return error.Malformed;
            return Value{ .array = try items.toOwnedSlice(r.alloc) };
        },
        '(' => {
            const inner = sig[1 .. sig.len - 1];
            try r.alignTo(8);
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(r.alloc);
            var it = SigIterator{ .sig = inner };
            while (it.next()) |one| {
                try items.append(r.alloc, try parseValue(r, one));
            }
            return Value{ .struct_ = try items.toOwnedSlice(r.alloc) };
        },
        '{' => {
            const inner = sig[1 .. sig.len - 1];
            try r.alignTo(8);
            var it = SigIterator{ .sig = inner };
            const key_sig = it.next() orelse return error.Malformed;
            const key = try r.alloc.create(Value);
            key.* = try parseValue(r, key_sig);
            const val_sig = it.next() orelse return error.Malformed;
            const val = try r.alloc.create(Value);
            val.* = try parseValue(r, val_sig);
            return Value{ .dict_entry = .{ .key = key, .val = val } };
        },
        else => return error.Malformed,
    }
}

// ── 单测（编组↔解组往返 + 布局护栏）───────────────────────────────

const t = std.testing;

// readBody 产生的 Value 树含指针（variant/dict_entry）；测试内用
// page_allocator（parser 分配与消息缓冲同生命周期，无跨用例状态可泄漏）。
fn bodyValues(sig: []const u8, body: []const u8) ![]Value {
    return readBody(std.heap.page_allocator, sig, body);
}

fn expectStr(v: Value, want: []const u8) !void {
    try t.expectEqualStrings(want, v.string);
}

test "hello: header only round trip" {
    var b = MessageBuilder.init(t.allocator, MSG_METHOD_CALL, 1);
    defer b.deinit();
    try b.fieldDestination("org.freedesktop.DBus");
    try b.fieldPath("/org/freedesktop/DBus");
    try b.fieldInterface("org.freedesktop.DBus");
    try b.fieldMember("Hello");

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);

    const h = try parseHeader(msg);
    try t.expectEqual(MSG_METHOD_CALL, h.msg_type);
    try t.expectEqual(@as(u32, 1), h.serial);
    try t.expectEqualStrings("org.freedesktop.DBus", h.destination.?);
    try t.expectEqualStrings("/org/freedesktop/DBus", h.path.?);
    try t.expectEqualStrings("org.freedesktop.DBus", h.interface.?);
    try t.expectEqualStrings("Hello", h.member.?);
    try t.expect(h.signature == null);
    try t.expectEqual(@as(u32, 0), h.body_len);
    try t.expectEqual(@as(usize, msg.len), h.body_off);
    try t.expectEqual(@as(usize, msg.len), try messageTotalLen(msg));
}

test "inhibit: ss body round trip" {
    var b = MessageBuilder.init(t.allocator, MSG_METHOD_CALL, 7);
    defer b.deinit();
    try b.fieldDestination("org.freedesktop.ScreenSaver");
    try b.fieldPath("/org/freedesktop/ScreenSaver");
    try b.fieldInterface("org.freedesktop.ScreenSaver");
    try b.fieldMember("Inhibit");
    try b.fieldSignature("ss");
    try b.body.putString("ArchoeraMusic");
    try b.body.putString("playback");

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);

    const h = try parseHeader(msg);
    try t.expectEqualStrings("ss", h.signature.?);
    const vals = try bodyValues("ss", msg[h.body_off..]);
    try t.expectEqual(@as(usize, 2), vals.len);
    try expectStr(vals[0], "ArchoeraMusic");
    try expectStr(vals[1], "playback");
}

test "scalars: suxbv round trip" {
    var b = MessageBuilder.init(t.allocator, MSG_METHOD_CALL, 2);
    defer b.deinit();
    try b.fieldSignature("suxbv");
    try b.body.putString("hi");
    try b.body.putU32(42);
    try b.body.putI64(-1_000_000_000_123);
    try b.body.putBool(true);
    try b.body.putVariantSig("u");
    try b.body.putU32(9);

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);
    const h = try parseHeader(msg);
    const vals = try bodyValues("suxbv", msg[h.body_off..]);

    try expectStr(vals[0], "hi");
    try t.expectEqual(@as(u32, 42), vals[1].u32_);
    try t.expectEqual(@as(i64, -1_000_000_000_123), vals[2].i64_);
    try t.expect(vals[3].boolean);
    try t.expectEqual(@as(u32, 9), vals[4].variant.u32_);
}

test "a{sv} metadata round trip" {
    var b = MessageBuilder.init(t.allocator, MSG_METHOD_CALL, 3);
    defer b.deinit();
    try b.fieldSignature("a{sv}");
    const mark = try b.body.beginArray(8); // dict entry = struct
    try b.body.putDictSvKey("xesam:title", "s");
    try b.body.putString("Song A");
    try b.body.putDictSvKey("mpris:length", "x");
    try b.body.putI64(240_000_000);
    try b.body.endArray(mark);

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);
    const h = try parseHeader(msg);
    const vals = try bodyValues("a{sv}", msg[h.body_off..]);

    try t.expectEqual(@as(usize, 1), vals.len);
    const entries = vals[0].array;
    try t.expectEqual(@as(usize, 2), entries.len);
    try t.expectEqualStrings("xesam:title", entries[0].dict_entry.key.string);
    try t.expectEqualStrings("Song A", entries[0].dict_entry.val.variant.string);
    try t.expectEqualStrings("mpris:length", entries[1].dict_entry.key.string);
    try t.expectEqual(@as(i64, 240_000_000), entries[1].dict_entry.val.variant.i64_);
}

test "as + empty array round trip" {
    var b = MessageBuilder.init(t.allocator, MSG_SIGNAL, 5);
    defer b.deinit();
    try b.fieldSignature("asu");
    const mark = try b.body.beginArray(4);
    try b.body.putString("a");
    try b.body.putString("bb");
    try b.body.endArray(mark);
    try b.body.putU32(3);

    const empty_b = MessageBuilder.init(t.allocator, MSG_SIGNAL, 6);
    _ = empty_b;

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);
    const h = try parseHeader(msg);
    const vals = try bodyValues("asu", msg[h.body_off..]);

    const arr = vals[0].array;
    try t.expectEqual(@as(usize, 2), arr.len);
    try expectStr(arr[0], "a");
    try expectStr(arr[1], "bb");
    try t.expectEqual(@as(u32, 3), vals[1].u32_);
}

test "empty array" {
    var b = MessageBuilder.init(t.allocator, MSG_METHOD_CALL, 8);
    defer b.deinit();
    try b.fieldSignature("a{sv}");
    const mark = try b.body.beginArray(8);
    try b.body.endArray(mark);

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);
    const h = try parseHeader(msg);
    const vals = try bodyValues("a{sv}", msg[h.body_off..]);
    try t.expectEqual(@as(usize, 0), vals[0].array.len);
}

test "signal ActiveChanged(b) round trip" {
    var b = MessageBuilder.init(t.allocator, MSG_SIGNAL, 11);
    defer b.deinit();
    try b.fieldPath("/org/freedesktop/ScreenSaver");
    try b.fieldInterface("org.freedesktop.ScreenSaver");
    try b.fieldMember("ActiveChanged");
    try b.fieldSignature("b");
    try b.body.putBool(false);

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);
    const h = try parseHeader(msg);
    try t.expectEqual(MSG_SIGNAL, h.msg_type);
    try t.expectEqualStrings("ActiveChanged", h.member.?);
    const vals = try bodyValues("b", msg[h.body_off..]);
    try t.expect(!vals[0].boolean);
}

test "method return with reply serial" {
    var b = MessageBuilder.init(t.allocator, MSG_METHOD_RETURN, 20);
    defer b.deinit();
    try b.fieldReplySerial(19);
    try b.fieldSignature("u");
    try b.body.putU32(777);

    const msg = try b.finish(t.allocator);
    defer t.allocator.free(msg);
    const h = try parseHeader(msg);
    try t.expectEqual(@as(u32, 19), h.reply_serial.?);
    const vals = try bodyValues("u", msg[h.body_off..]);
    try t.expectEqual(@as(u32, 777), vals[0].u32_);
}

test "completeTypeLen" {
    try t.expectEqual(@as(usize, 1), completeTypeLen("s"));
    try t.expectEqual(@as(usize, 2), completeTypeLen("as"));
    try t.expectEqual(@as(usize, 3), completeTypeLen("aas"));
    try t.expectEqual(@as(usize, 5), completeTypeLen("a{sv}"));
    try t.expectEqual(@as(usize, 4), completeTypeLen("(ii)"));
    try t.expectEqual(@as(usize, 5), completeTypeLen("a{sv}u"));
    try t.expectEqual(@as(usize, 5), completeTypeLen("a{sv}a{sv}"));
}
