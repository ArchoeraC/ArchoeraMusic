package util

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"strings"
	"time"

	"github.com/betastudio2/archoera-subsonic/model"
)

// AlbumIDOf 计算 album 稳定 ID（md5 hex）
func AlbumIDOf(name string) string {
	h := md5.Sum([]byte(name))
	return hex.EncodeToString(h[:])
}

// ArtistIDOf 计算 artist 稳定 ID（md5 hex）
func ArtistIDOf(name string) string {
	return AlbumIDOf(name) // 同算法
}

// ParseArtists 解析 artists JSON
func ParseArtists(jsonStr string) []model.Artist {
	var artists []model.Artist
	_ = json.Unmarshal([]byte(jsonStr), &artists)
	if artists == nil {
		artists = []model.Artist{{Name: "未知歌手"}}
	}
	return artists
}

// ParseAlbum 解析 album JSON
func ParseAlbum(jsonStr string) *model.Album {
	if jsonStr == "" {
		return nil
	}
	var album model.Album
	if err := json.Unmarshal([]byte(jsonStr), &album); err != nil {
		return nil
	}
	return &album
}

// FirstArtist 取第一个歌手名（多歌手用 / 连接）
func FirstArtist(artists []model.Artist) string {
	names := make([]string, len(artists))
	for i, a := range artists {
		names[i] = a.Name
	}
	return strings.Join(names, " / ")
}

// FirstArtistID 取第一个歌手 ID
func FirstArtistID(artists []model.Artist) string {
	if len(artists) > 0 {
		return ArtistIDOf(artists[0].Name)
	}
	return ""
}

var audioMime = map[string]string{
	"mp3": "audio/mpeg", "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/ogg",
	"oga": "audio/ogg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav",
	"ape": "audio/x-ape", "wv": "audio/x-wavpack", "dsf": "audio/x-dsf", "mp4": "audio/mp4",
	"aiff": "audio/aiff", "aif": "audio/aiff",
}

// SuffixOf 取文件扩展名（小写，无点）
func SuffixOf(filePath string) string {
	return strings.TrimPrefix(strings.ToLower(filepath.Ext(filePath)), ".")
}

// MimeOf 取音频 MIME 类型
func MimeOf(filePath string) string {
	suf := SuffixOf(filePath)
	if m, ok := audioMime[suf]; ok {
		return m
	}
	return "application/octet-stream"
}

// TrackToChild 将 Track 转换为 Subsonic child/song 对象
func TrackToChild(t model.Track, userID string, includeStarred bool, isStarredFn func(string, string, string) bool) map[string]any {
	artists := ParseArtists(t.ArtistsJSON)
	album := ParseAlbum("")
	if t.AlbumJSON.Valid {
		album = ParseAlbum(t.AlbumJSON.String)
	}
	albumName := ""
	albumYear := 0
	if album != nil {
		albumName = album.Name
		albumYear = album.Year
	}

	child := map[string]any{
		"id":          t.ID,
		"isDir":       false,
		"title":       t.Title,
		"album":       albumName,
		"artist":      FirstArtist(artists),
		"coverArt":    t.ID,
		"size":        t.FileSize,
		"contentType": MimeOf(t.Path),
		"suffix":      SuffixOf(t.Path),
		"duration":    t.Duration / 1000,
		"bitRate":     0,
		"path":        filepath.Base(t.Path),
		"discNumber":  1,
		"type":        "music",
		"artistId":    FirstArtistID(artists),
		"year":        albumYear,
	}
	if albumName != "" {
		child["albumId"] = AlbumIDOf(albumName)
		child["parent"] = AlbumIDOf(albumName)
	}
	if t.TrackNo.Valid {
		child["track"] = t.TrackNo.Int64
	}
	if t.BitRate.Valid {
		child["bitRate"] = t.BitRate.Int64
	}
	if t.Genre.Valid && t.Genre.String != "" {
		child["genre"] = t.Genre.String
	}
	if t.FileCtime.Valid {
		child["created"] = TimestampISO(t.FileCtime.Int64)
	}
	if includeStarred && isStarredFn != nil && isStarredFn(userID, t.ID, "track") {
		child["starred"] = time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	}
	return child
}

// TimestampISO 毫秒时间戳 → ISO 8601
func TimestampISO(ms int64) string {
	return time.UnixMilli(ms).UTC().Format("2006-01-02T15:04:05.000Z")
}
