package endpoints

// 转码器动态库加载与调用见 transcoder_unix.go / transcoder_windows.go
//（按平台封装 Go 层 API：openTranscoder / closeTranscoder / callTranscode）

import (
	"bytes"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/betastudio2/archoera-subsonic/config"
	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/model"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// transcoderBin 转码器动态库路径（config 注入，libarchoera_transcoder.so）
func transcoderBin() string {
	if p := config.Transcoder(); p != "" {
		return p
	}
	return ""
}

// estBitrateKbps 估算曲目比特率（kbps）
func estBitrateKbps(t *model.Track) int {
	if t.BitRate.Valid && t.BitRate.Int64 > 0 {
		return int(t.BitRate.Int64)
	}
	// 退回估算：file_size * 8 / duration_seconds
	if t.Duration > 0 && t.FileSize > 0 {
		return int(t.FileSize*8) / int(t.Duration/1000)
	}
	return 0
}

// shouldTranscode 判断是否需要转码
// 参数：
//   - srcSuffix: 源文件后缀（小写，无点）
//   - srcBitrate: 源比特率（kbps），0 表示未知
//   - maxBitRate: 客户端请求的最大比特率（kbps），0 表示不限
//   - targetFmt: 客户端请求的目标格式（"mp3"/"raw" 等），空表示不限
//
// 返回：(是否转码, 输出后缀, 输出 MIME)
func shouldTranscode(srcSuffix string, srcBitrate, maxBitRate int, targetFmt string) (bool, string, string) {
	targetFmt = strings.ToLower(strings.TrimSpace(targetFmt))

	// raw 表示客户端要求原始
	if targetFmt == "raw" {
		return false, srcSuffix, util.MimeOf("." + srcSuffix)
	}

	// 限定输出为 mp3（当前转码器仅支持 mp3 输出）
	outSuffix := "mp3"
	outMime := "audio/mpeg"

	// 客户端显式要求 mp3 且源不是 mp3 → 必转
	if targetFmt == "mp3" && srcSuffix != "mp3" {
		return true, outSuffix, outMime
	}

	// 客户端要求某种特定格式且源不匹配 → 转（仅当目标是 mp3 时支持，否则降级到 mp3）
	if targetFmt != "" && targetFmt != "mp3" && targetFmt != srcSuffix {
		// 无法满足，但音流通常接受 mp3 兜底
		return true, outSuffix, outMime
	}

	// 比特率限制
	if maxBitRate > 0 && srcBitrate > 0 && srcBitrate > maxBitRate {
		return true, outSuffix, outMime
	}

	// 源格式不在常见可直放列表（如 ape/wv/dsf/aiff）→ 主动转为 mp3
	switch srcSuffix {
	case "mp3", "flac", "ogg", "oga", "opus", "m4a", "aac", "wav", "mp4":
		return false, srcSuffix, util.MimeOf("." + srcSuffix)
	case "ape", "wv", "dsf", "aiff", "aif":
		return true, outSuffix, outMime
	}

	return false, srcSuffix, util.MimeOf("." + srcSuffix)
}

// ServeStream /rest/stream.view + /rest/download.view
func ServeStream(w http.ResponseWriter, r *http.Request, asDownload bool) {
	id := r.URL.Query().Get("id")
	track, err := db.GetTrackByID(id)
	if err != nil || track == nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Song not found"})
		return
	}

	if _, err := os.Stat(track.Path); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "File not found"})
		return
	}

	q := r.URL.Query()
	maxBitRate := middlewareAtoi(q.Get("maxBitRate"))
	format := q.Get("format")
	timeOffset := middlewareAtoi(q.Get("timeOffset"))

	srcSuffix := util.SuffixOf(track.Path)
	srcBitrate := estBitrateKbps(track)

	needTranscode, outSuffix, outMime := shouldTranscode(srcSuffix, srcBitrate, maxBitRate, format)

	// 下载模式且源可直放 → 走原始文件
	if asDownload && !needTranscode {
		serveDirectFile(w, r, track.Path, outMime, true)
		return
	}

	if !needTranscode {
		serveDirectFile(w, r, track.Path, outMime, false)
		return
	}

	// 转码参数
	bitrate := maxBitRate
	if bitrate <= 0 || bitrate > 320 {
		bitrate = 192
	}
	if bitrate < 32 {
		bitrate = 32
	}

	// 从查询参数提取可选转码参数
	var opts TranscodeOpts
	opts.Bitrate = bitrate
	if timeOffset > 0 {
		opts.SkipSeconds = timeOffset
	}
	if sr := q.Get("maxSampleRate"); sr != "" {
		opts.MaxSampleRate = middlewareAtoi(sr)
	}
	if ch := q.Get("channels"); ch != "" {
		c := middlewareAtoi(ch)
		if c == 1 || c == 2 {
			opts.Channels = c
		}
	}

	serveTranscoded(w, r, track.Path, outMime, outSuffix, asDownload, opts)
}

// TranscodeOpts 转码参数
type TranscodeOpts struct {
	Bitrate       int
	SkipSeconds   int
	MaxSampleRate int
	Channels      int
}

// dropPageCache 通知内核丢弃文件页面缓存，避免整首歌数据常驻内存。
// Linux 用 posix_fadvise(POSIX_FADV_DONTNEED)；其他平台为空操作
// （实现见 dropcache_linux.go / dropcache_other.go）。

// serveDirectFile 直接发送原始文件，支持 Range
// context-aware 流式拷贝：每 32KB 检查断连；结束后释放 OS 页面缓存
func serveDirectFile(w http.ResponseWriter, r *http.Request, path, mime string, asDownload bool) {
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer func() {
		dropPageCache(f)
		f.Close()
	}()

	info, err := f.Stat()
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	size := info.Size()

	w.Header().Set("Content-Type", mime)
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	if asDownload {
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filepath.Base(path)))
	}

	// 处理 Range 请求
	rangeHeader := r.Header.Get("Range")
	if rangeHeader != "" {
		serveRangeContent(w, r, f, size, mime, info.ModTime())
		return
	}

	// 完整传输：分块拷贝，每块之间检查 context 是否已取消（客户端断连）
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.WriteHeader(200)

	buf := make([]byte, 32*1024)
	remaining := size
	for remaining > 0 {
		select {
		case <-r.Context().Done():
			return // 客户端已断开，立即停止
		default:
		}
		readSize := int64(len(buf))
		if readSize > remaining {
			readSize = remaining
		}
		n, rerr := f.Read(buf[:readSize])
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			remaining -= int64(n)
		}
		if rerr != nil {
			break
		}
	}
}

// serveRangeContent 处理 Range 请求的分段传输
func serveRangeContent(w http.ResponseWriter, r *http.Request, f *os.File, size int64, mime string, modTime time.Time) {
	// 解析 Range header
	rangeStr := strings.TrimPrefix(r.Header.Get("Range"), "bytes=")
	parts := strings.SplitN(rangeStr, "-", 2)
	if len(parts) != 2 {
		http.Error(w, "invalid range", 416)
		return
	}

	start, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		start = 0
	}

	var end int64
	if parts[1] != "" {
		end, err = strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			end = size - 1
		}
	} else {
		end = size - 1
	}
	if end >= size {
		end = size - 1
	}

	contentLen := end - start + 1
	if start >= size || contentLen <= 0 {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", size))
		http.Error(w, "requested range not satisfiable", 416)
		return
	}

	f.Seek(start, io.SeekStart)

	w.Header().Set("Content-Type", mime)
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
	w.Header().Set("Content-Length", strconv.FormatInt(contentLen, 10))
	w.Header().Set("Last-Modified", modTime.UTC().Format(http.TimeFormat))
	w.WriteHeader(206)

	buf := make([]byte, 32*1024)
	remaining := contentLen
	for remaining > 0 {
		select {
		case <-r.Context().Done():
			return
		default:
		}
		readSize := int64(len(buf))
		if readSize > remaining {
			readSize = remaining
		}
		n, rerr := f.Read(buf[:readSize])
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			remaining -= int64(n)
		}
		if rerr != nil {
			break
		}
	}
}

// serveTranscoded 通过 FFI（dlopen Rust cdylib）转码为 MP3 文件后发送
// 转码完成后文件可 seek，走 http.ServeContent（支持 Range、Content-Length）
func serveTranscoded(w http.ResponseWriter, r *http.Request, srcPath string, mime, suffix string, asDownload bool, opts TranscodeOpts) {
	libPath := transcoderBin()
	if libPath == "" {
		log.Printf("[subsonic] 未配置转码器库路径")
		http.Error(w, "transcode unavailable", 500)
		return
	}

	handle := openTranscoder(libPath)
	if handle == nil {
		log.Printf("[subsonic] 加载转码器失败: %s", libPath)
		http.Error(w, "transcode unavailable", 500)
		return
	}
	defer closeTranscoder(handle)

	// 转码输出到临时文件（Rust 端全量转码）
	tmp, err := os.CreateTemp("", "archoera-transcode-*."+suffix)
	if err != nil {
		log.Printf("[subsonic] 创建临时文件失败: %v", err)
		http.Error(w, "transcode failed", 500)
		return
	}
	tmpName := tmp.Name()
	_ = tmp.Close()
	defer os.Remove(tmpName)

	rc := callTranscode(handle, srcPath, tmpName,
		opts.Bitrate, opts.MaxSampleRate, opts.Channels, opts.SkipSeconds)
	if rc != 0 {
		log.Printf("[subsonic] 转码失败: rc=%d", rc)
		http.Error(w, "transcode failed", 500)
		return
	}

	f, err := os.Open(tmpName)
	if err != nil {
		log.Printf("[subsonic] 打开转码结果失败: %v", err)
		http.Error(w, "transcode failed", 500)
		return
	}
	defer func() {
		dropPageCache(f)
		f.Close()
	}()

	st, _ := f.Stat()
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	if asDownload {
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="transcoded.%s"`, suffix))
	}
	http.ServeContent(w, r, "transcoded."+suffix, st.ModTime(), f)
}

// middlewareAtoi 安全转换字符串为 int（避免与 middleware 包循环引用，复制一份最小实现）
func middlewareAtoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}

// ServeCoverArt /rest/getCoverArt.view
func ServeCoverArt(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	sizeStr := r.URL.Query().Get("size")
	size := 0
	if sizeStr != "" {
		size, _ = strconv.Atoi(sizeStr)
	}

	coverPath := filepath.Join(db.CoverCacheDir(), id+".img")

	// 若不是 track，找对应 album/artist 下第一个有封面的 track
	if _, err := os.Stat(coverPath); os.IsNotExist(err) {
		var track *model.Track
		if name := findAlbumNameByID(id); name != "" {
			tracks, _ := db.GetAlbumTracks(name)
			for _, t := range tracks {
				if t.Cover.Valid && t.Cover.String != "" {
					track = &t
					break
				}
			}
		}
		if track == nil {
			if name := findArtistNameByID(id); name != "" {
				tracks, _ := db.GetArtistTracks(name)
				for _, t := range tracks {
					if t.Cover.Valid && t.Cover.String != "" {
						track = &t
						break
					}
				}
			}
		}
		if track != nil {
			coverPath = filepath.Join(db.CoverCacheDir(), track.ID+".img")
		}
	}

	f, err := os.Open(coverPath)
	if err != nil {
		http.Error(w, "cover not found", 404)
		return
	}
	defer f.Close()

	// 读取前 512 字节探测图片类型
	head := make([]byte, 512)
	n, _ := f.Read(head)
	f.Seek(0, io.SeekStart)
	mime := http.DetectContentType(head[:n])

	// size > 0 时按比例缩放到 size×size 框内，统一输出 JPEG
	if size > 0 {
		serveResizedCover(w, r, f, size)
		return
	}

	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "public, max-age=86400")
	stat, _ := f.Stat()
	http.ServeContent(w, r, stat.Name(), stat.ModTime(), f)
}

// serveResizedCover 解码原图、缩放到 size×size（保持比例，最长边=size），输出 JPEG
func serveResizedCover(w http.ResponseWriter, r *http.Request, src *os.File, size int) {
	img, _, err := image.Decode(src)
	if err != nil {
		log.Printf("[subsonic] 封面解码失败，回退原图: %v", err)
		_, _ = src.Seek(0, io.SeekStart)
		fi, _ := src.Stat()
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		http.ServeContent(w, r, "cover.jpg", fi.ModTime(), src)
		return
	}

	bounds := img.Bounds()
	w0 := bounds.Dx()
	h0 := bounds.Dy()
	if w0 <= 0 || h0 <= 0 {
		http.Error(w, "invalid cover", 500)
		return
	}

	// 等比缩放：最长边 = size
	targetW, targetH := w0, h0
	if w0 > h0 {
		targetW = size
		targetH = max(1, h0*size/w0)
	} else {
		targetH = size
		targetW = max(1, w0*size/h0)
	}

	dst := image.NewRGBA(image.Rect(0, 0, targetW, targetH))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, bounds, draw.Over, nil)

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 85}); err != nil {
		http.Error(w, "encode cover failed", 500)
		return
	}

	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Header().Set("Content-Length", strconv.Itoa(buf.Len()))
	_, _ = w.Write(buf.Bytes())
	_ = r
}
