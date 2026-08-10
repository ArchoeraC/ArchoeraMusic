//go:build linux

package endpoints

import (
	"os"

	"golang.org/x/sys/unix"
)

// dropPageCache 通知内核丢弃文件页面缓存（Linux：FADV_DONTNEED）。
func dropPageCache(f *os.File) {
	_ = unix.Fadvise(int(f.Fd()), 0, 0, unix.FADV_DONTNEED)
}
