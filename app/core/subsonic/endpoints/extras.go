package endpoints

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/betastudio2/archoera-subsonic/config"
	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// GetMusicDirectory /rest/getMusicDirectory.view
// 兼容旧客户端：按 id 返回目录结构
// - id 为 album id → 返回该专辑下的曲目（作为子项）
// - id 为 artist id → 返回该歌手的专辑列表（作为子项）
// - id 为 0 / musicfolder → 返回顶层歌手列表
func GetMusicDirectory(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" || id == "0" {
		// 顶层：返回全部歌手（视为目录的子项）
		artists, err := db.GetArtistList()
		if err != nil {
			xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
			return
		}
		children := make([]any, 0, len(artists))
		for _, a := range artists {
			children = append(children, artistSummaryToDirChild(a))
		}
		xmlutil.Send(w, r, map[string]any{
			"directory": map[string]any{
				"id":       "0",
				"name":     "Music",
				"children": children,
			},
		}, nil)
		return
	}

	// 尝试作为专辑
	if name := findAlbumNameByID(id); name != "" {
		tracks, err := db.GetAlbumTracks(name)
		if err != nil {
			xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
			return
		}
		user := middleware.GetUser(r)
		children := make([]any, 0, len(tracks))
		for _, t := range tracks {
			children = append(children, util.TrackToChild(t, user.ID, true, isStarredHelper))
		}
		xmlutil.Send(w, r, map[string]any{
			"directory": map[string]any{
				"id":       id,
				"name":     name,
				"children": children,
			},
		}, nil)
		return
	}

	// 尝试作为歌手
	if name := findArtistNameByID(id); name != "" {
		tracks, err := db.GetArtistTracks(name)
		if err != nil {
			xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
			return
		}
		// 聚合该歌手的专辑
		albumSet := make(map[string]bool)
		for _, t := range tracks {
			if t.AlbumJSON.Valid {
				if album := util.ParseAlbum(t.AlbumJSON.String); album != nil {
					albumSet[album.Name] = true
				}
			}
		}
		children := make([]any, 0, len(albumSet))
		for an := range albumSet {
			children = append(children, map[string]any{
				"id":       util.AlbumIDOf(an),
				"parent":   id,
				"isDir":    true,
				"title":    an,
				"name":     an,
				"artist":   name,
				"artistId": util.ArtistIDOf(name),
				"type":     "album",
			})
		}
		xmlutil.Send(w, r, map[string]any{
			"directory": map[string]any{
				"id":       id,
				"name":     name,
				"children": children,
			},
		}, nil)
		return
	}

	xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Directory not found"})
}

func artistSummaryToDirChild(a db.ArtistSummary) map[string]any {
	coverArt := ""
	if a.Cover.Valid && a.Cover.String != "" {
		coverArt = util.ArtistIDOf(a.Name)
	}
	return map[string]any{
		"id":       util.ArtistIDOf(a.Name),
		"isDir":    true,
		"title":    a.Name,
		"name":     a.Name,
		"coverArt": coverArt,
		"type":     "artist",
	}
}

/* ------------------------------------------------------------------ */
/* 播放列表 CRUD                                                        */
/* ------------------------------------------------------------------ */

// CreatePlaylist /rest/createPlaylist.view
// 参数：name, playlistId（可选，更新模式）, songId（可多个）, public, comment
func CreatePlaylist(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)
	q := r.URL.Query()

	name := q.Get("name")
	playlistID := q.Get("playlistId")
	songIDs := middleware.CollectIds(r, "songId")

	// playlistId 提供时表示更新现有播放列表
	if playlistID != "" {
		comment := nullableStr(q.Get("comment"))
		pub := parseBoolPtr(q.Get("public"))
		if err := db.UpdatePlaylist(playlistID, name, comment, pub, songIDs, nil); err != nil {
			xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
			return
		}
		xmlutil.Send(w, r, map[string]any{}, nil)
		return
	}

	if name == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing name"})
		return
	}

	newID := uuid.NewString()
	comment := nullableStr(q.Get("comment"))
	pub := parseBool(q.Get("public"), true)

	if err := db.CreatePlaylist(newID, user.ID, name, comment, pub, songIDs); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

// UpdatePlaylist /rest/updatePlaylist.view
// 参数：playlistId, name, comment, public, songIdToAdd, songIndexToRemove
func UpdatePlaylist(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id := q.Get("playlistId")
	if id == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing playlistId"})
		return
	}

	name := q.Get("name")
	comment := nullableStr(q.Get("comment"))
	var pub *bool
	if v := q.Get("public"); v != "" {
		b := parseBool(v, true)
		pub = &b
	}
	addIDs := middleware.CollectIds(r, "songIdToAdd")
	removeIdxStrs := q["songIndexToRemove"]
	var removeIdx []int
	for _, s := range removeIdxStrs {
		if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
			removeIdx = append(removeIdx, n)
		}
	}

	if err := db.UpdatePlaylist(id, name, comment, pub, addIDs, removeIdx); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

// DeletePlaylist /rest/deletePlaylist.view
func DeletePlaylist(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing id"})
		return
	}
	if err := db.DeletePlaylist(id); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

/* ------------------------------------------------------------------ */
/* 分享 CRUD                                                            */
/* ------------------------------------------------------------------ */

// CreateShare /rest/createShare.view
// 参数：id（曲目 id，可多个）, description, expires, name
func CreateShare(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)
	q := r.URL.Query()
	trackIDs := middleware.CollectIds(r, "id")
	if len(trackIDs) == 0 {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing id"})
		return
	}

	name := q.Get("name")
	if name == "" {
		// 默认用第一首曲目名
		if t, err := db.GetTrackByID(trackIDs[0]); err == nil && t != nil {
			name = t.Title
		} else {
			name = "Share " + time.Now().Format("2006-01-02")
		}
	}

	desc := nullableStr(q.Get("description"))
	var expiresAt sql.NullInt64
	if exp := q.Get("expires"); exp != "" {
		if n, err := strconv.ParseInt(exp, 10, 64); err == nil && n > 0 {
			expiresAt = sql.NullInt64{Int64: n, Valid: true}
		}
	}

	newID := uuid.NewString()
	// 简化：分享 URL 指向 TS 服务的 share 页面
	shareURL := fmt.Sprintf("/share/%s", newID)

	if err := db.CreateShare(newID, user.ID, name, desc, shareURL, expiresAt, trackIDs); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	// 返回新创建的 share
	xmlutil.Send(w, r, map[string]any{
		"shares": map[string]any{
			"share": []any{
				map[string]any{
					"id":       newID,
					"name":     name,
					"url":      shareURL,
					"username": user.Username,
					"created":  util.TimestampISO(time.Now().UnixMilli()),
				},
			},
		},
	}, nil)
}

// UpdateShare /rest/updateShare.view
// 参数：id, description, expires
func UpdateShare(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id := q.Get("id")
	if id == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing id"})
		return
	}

	name := q.Get("name")
	desc := nullableStr(q.Get("description"))
	var expiresAt sql.NullInt64
	if exp := q.Get("expires"); exp != "" {
		if n, err := strconv.ParseInt(exp, 10, 64); err == nil && n > 0 {
			expiresAt = sql.NullInt64{Int64: n, Valid: true}
		}
	}

	if err := db.UpdateShare(id, name, desc, expiresAt); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

// DeleteShare /rest/deleteShare.view
func DeleteShare(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing id"})
		return
	}
	if err := db.DeleteShare(id); err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

/* ------------------------------------------------------------------ */
/* 扫描状态                                                             */
/* ------------------------------------------------------------------ */

// GetScanStatus /rest/getScanStatus.view
// 从数据库读取最后扫描时间（扫描由宿主 Dart 经 C# scanner FFI 执行）
func GetScanStatus(w http.ResponseWriter, r *http.Request) {
	lastScan, err := db.GetLastScanTime()
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	xmlutil.Send(w, r, map[string]any{
		"scanStatus": map[string]any{
			"scanning":    false,
			"lastScanned": util.TimestampISO(lastScan),
			"count":       0,
		},
	}, nil)
}

// StartScan /rest/startScan.view
// 发 scan-request 事件通知宿主（Dart）执行扫描（扫描由 C# scanner FFI 执行），立即返回
func StartScan(w http.ResponseWriter, r *http.Request) {
	config.EmitEvent(`{"type":"scan-request"}`)
	log.Printf("[subsonic] 已请求宿主执行扫描")
	xmlutil.Send(w, r, map[string]any{
		"scanStatus": map[string]any{
			"scanning": true,
			"count":    0,
		},
	}, nil)
}

/* ------------------------------------------------------------------ */
/* 元信息端点                                                           */
/* ------------------------------------------------------------------ */

// GetArtistInfo /rest/getArtistInfo.view + getArtistInfo2
// 简化实现：返回空的相关艺术家和简介
func GetArtistInfo(w http.ResponseWriter, r *http.Request, endpoint string) {
	id := r.URL.Query().Get("id")
	name := findArtistNameByID(id)
	if name == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Artist not found"})
		return
	}

	key := "artistInfo"
	if endpoint == "getartistinfo2" {
		key = "artistInfo2"
	}

	xmlutil.Send(w, r, map[string]any{
		key: map[string]any{
			"biography":      "",
			"musicBrainzId":  "",
			"smallImageUrl":  "",
			"mediumImageUrl": "",
			"largeImageUrl":  "",
			"similarArtist":  []any{},
		},
	}, nil)
}

// GetAlbumInfo /rest/getAlbumInfo.view + getAlbumInfo2
func GetAlbumInfo(w http.ResponseWriter, r *http.Request, endpoint string) {
	id := r.URL.Query().Get("id")
	name := findAlbumNameByID(id)
	if name == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Album not found"})
		return
	}

	key := "albumInfo"
	if endpoint == "getalbuminfo2" {
		key = "albumInfo2"
	}

	xmlutil.Send(w, r, map[string]any{
		key: map[string]any{
			"notes":          "",
			"musicBrainzId":  "",
			"smallImageUrl":  "",
			"mediumImageUrl": "",
			"largeImageUrl":  "",
		},
	}, nil)
}

/* ------------------------------------------------------------------ */
/* 辅助                                                                */
/* ------------------------------------------------------------------ */

func nullableStr(s string) sql.NullString {
	s = strings.TrimSpace(s)
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}

func parseBool(s string, def bool) bool {
	s = strings.ToLower(strings.TrimSpace(s))
	switch s {
	case "true", "1", "yes", "on":
		return true
	case "false", "0", "no", "off":
		return false
	}
	return def
}

func parseBoolPtr(s string) *bool {
	if s == "" {
		return nil
	}
	b := parseBool(s, true)
	return &b
}
