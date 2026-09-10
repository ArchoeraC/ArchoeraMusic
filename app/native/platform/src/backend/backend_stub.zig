// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! P0 通用 stub 后端：能力位图恒 0，一切调用返回 UNSUPPORTED。
//!
//! P1–P5 逐平台落地后（见 docs/platform-native-bridge.md §7），各平台后端
//! 覆盖对应函数；本文件仅兜底未知目标平台与编译期无后端的场景。

const core = @import("../core.zig");

pub const Backend = struct {
    pub fn caps() u32 {
        return 0;
    }
    pub fn init() i32 {
        return core.OK;
    }
    pub fn shutdown() i32 {
        return core.OK;
    }
    pub fn powerSetSleepInhibit(on: i32) i32 {
        _ = on;
        return core.ERR_UNSUPPORTED;
    }
    pub fn powerSetScreenEvents(on: i32) i32 {
        _ = on;
        return core.ERR_UNSUPPORTED;
    }
    pub fn windowSetEvents(on: i32) i32 {
        _ = on;
        return core.ERR_UNSUPPORTED;
    }
    pub fn mediaSetTrack(meta: ?*const core.TrackMeta) i32 {
        _ = meta;
        return core.ERR_UNSUPPORTED;
    }
    pub fn mediaSetPlayback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) i32 {
        _ = .{ state, position_ms, speed, volume, loop, shuffle };
        return core.ERR_UNSUPPORTED;
    }
    pub fn mediaSetWindow(win: i64) i32 {
        _ = win;
        return core.OK;
    }
    pub fn appInstanceAcquire() i32 {
        return 1;
    }
    pub fn notify(title: []const u8, body: []const u8) i32 {
        _ = .{ title, body };
        return core.OK;
    }
    pub fn systemAccent() ?[3]u8 {
        return null;
    }
    pub fn systemAccentSetEvents(on: i32) i32 {
        _ = on;
        return core.ERR_UNSUPPORTED;
    }
};

pub fn appInstanceAcquire() i32 {
    return 1; // 无平台：不阻断
}


pub fn notify(title: []const u8, body: []const u8) i32 {
    _ = title; _ = body;
    return core.OK;
}

pub fn systemAccent() ?[3]u8 {
    return null;
}
