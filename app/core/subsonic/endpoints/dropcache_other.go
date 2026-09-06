// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//go:build !linux

package endpoints

import "os"

// dropPageCache 非 Linux 平台为空操作（macOS/Windows 无 FADV_DONTNEED 语义）。
func dropPageCache(_ *os.File) {}
