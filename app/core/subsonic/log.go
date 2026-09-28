// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

// 统一日志助手（见 docs/unified-logging.md §4）：tag 提供模块标签，由统一
// sink 渲染为 `[HH:mm:ss LEVEL] [subsonic] …`。禁止直接使用标准库 log.*。
import "github.com/betastudio2/archoera-subsonic/logging"

func logDebug(tag, format string, args ...any) { logging.Debug(tag, format, args...) }
func logInfo(tag, format string, args ...any)  { logging.Info(tag, format, args...) }
func logWarn(tag, format string, args ...any)  { logging.Warn(tag, format, args...) }
func logError(tag, format string, args ...any) { logging.Error(tag, format, args...) }
