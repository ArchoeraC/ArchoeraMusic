// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音频容器嗅探。
///
/// Neko 音频是**直传原文件**（无音质档），且直链 `/api/music/file/{id}`
/// 无扩展名——只能按内容判断容器格式，与官方 PC 客户端
/// `musicdownloadmanager.cpp` 的 `extensionFromBuffer` 保持一致：
///
///   `fLaC` → flac；`RIFF....WAVE` → wav；`OggS` → ogg；`ID3` → mp3；
///   `0xFFEx`（MPEG 帧同步）→ mp3。
///
/// 无法判定返回 null（调用方回退 `fileFormat` / 默认 `mp3`）。
library;

/// 依据文件头字节嗅探音频扩展名；无法判定返回 null。
String? sniffAudioExtension(List<int> head) {
  if (head.length >= 4) {
    // fLaC
    if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
      return 'flac';
    }
    // OggS
    if (head[0] == 0x4F && head[1] == 0x67 && head[2] == 0x67 && head[3] == 0x53) {
      return 'ogg';
    }
    // ID3 (MP3 with tag)
    if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      return 'mp3';
    }
    // RIFF....WAVE
    if (head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head.length >= 12 &&
        head[8] == 0x57 &&
        head[9] == 0x41 &&
        head[10] == 0x56 &&
        head[11] == 0x45) {
      return 'wav';
    }
  }
  // MPEG 帧同步（0xFFEx）：无 ID3 的裸 MP3
  if (head.length >= 2 &&
      head[0] == 0xFF &&
      (head[1] & 0xE0) == 0xE0) {
    return 'mp3';
  }
  return null;
}
