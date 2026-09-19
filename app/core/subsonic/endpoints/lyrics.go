// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

package endpoints

import (
	"net/http"
	"strings"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/lyric"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// 歌词端点：只读取服务端曲库中扫描到的内嵌歌词。
//
// 服务端只负责「消费/传输」元数据：曲库没有内嵌歌词时返回空，由客户端
// （Subsonic 客户端）自行决定是否做在线歌词查询。服务端不回调宿主、
// 不做在线抓取，避免阻塞请求与跨进程同步等待。

// wantsArchExt 是否为 ArchoeraMusic 客户端（带扩展参数）。
// 仅在此时才在响应中附带非标准扩展字段，保证对标准 Subsonic 客户端零影响。
func wantsArchExt(r *http.Request) bool {
	return r.URL.Query().Get("archoeraExt") == "1"
}

// 扩展字段名（我方客户端识别）：曲库无内嵌歌词，提示客户端自行在线补全。
const archExtFetchOnline = "archoeraFetchOnline"

// GetLyrics /rest/getLyrics.view
func GetLyrics(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	// 优先按 id 查 track
	var trackID string
	var artistStr, titleStr string

	if q.Get("id") != "" {
		track, err := db.GetTrackByID(q.Get("id"))
		if err == nil && track != nil {
			trackID = track.ID
			artists := util.ParseArtists(track.ArtistsJSON)
			artistStr = util.FirstArtist(artists)
			titleStr = track.Title
		}
	}

	// 无 id 时用 artist + title 参数
	if trackID == "" {
		artistStr = q.Get("artist")
		titleStr = q.Get("title")
	}

	if trackID == "" && artistStr == "" && titleStr == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing id or artist/title"})
		return
	}

	// 只取内嵌歌词；无则返回空。
	var mainLyric string
	if trackID != "" {
		if embedded, err := db.GetTrackLyrics(trackID); err == nil && strings.TrimSpace(embedded) != "" {
			mainLyric = embedded
		}
	}

	if mainLyric == "" {
		// 无内嵌歌词：标准客户端得到空；我方客户端附带扩展标记，自行在线补全。
		resp := map[string]any{"lyrics": map[string]any{}}
		if wantsArchExt(r) {
			resp[archExtFetchOnline] = true
		}
		xmlutil.Send(w, r, resp, nil)
		return
	}

	prepared := lyric.Prepare(lyric.TrackLyricPayload{Main: mainLyric})

	xmlutil.Send(w, r, map[string]any{
		"lyrics": map[string]any{
			"artist": artistStr,
			"title":  titleStr,
			"synced": prepared.Synced,
			"value":  prepared.ClassicText,
		},
	}, nil)
}

// GetLyricsBySongId /rest/getLyricsBySongId.view
func GetLyricsBySongId(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing id"})
		return
	}

	track, err := db.GetTrackByID(id)
	if err != nil || track == nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Song not found"})
		return
	}

	// 只取内嵌歌词；无则返回空。
	embedded, err := db.GetTrackLyrics(id)
	if err != nil || strings.TrimSpace(embedded) == "" {
		resp := map[string]any{"lyricsList": map[string]any{}}
		if wantsArchExt(r) {
			resp[archExtFetchOnline] = true
		}
		xmlutil.Send(w, r, resp, nil)
		return
	}

	prepared := lyric.Prepare(lyric.TrackLyricPayload{Main: embedded})

	// 有行级时间轴 → synced；纯文本 → synced=false 的逐行歌词（无 start）。
	lines := make([]any, 0, len(prepared.StructuredLines))
	if len(prepared.StructuredLines) > 0 {
		for _, l := range prepared.StructuredLines {
			lines = append(lines, map[string]any{"start": l.Start, "value": l.Value})
		}
	} else {
		for _, raw := range strings.Split(prepared.ClassicText, "\n") {
			line := strings.TrimSpace(raw)
			if line == "" {
				continue
			}
			lines = append(lines, map[string]any{"value": line})
		}
	}
	if len(lines) == 0 {
		resp := map[string]any{"lyricsList": map[string]any{}}
		if wantsArchExt(r) {
			resp[archExtFetchOnline] = true
		}
		xmlutil.Send(w, r, resp, nil)
		return
	}

	artists := util.ParseArtists(track.ArtistsJSON)
	xmlutil.Send(w, r, map[string]any{
		"lyricsList": map[string]any{
			"structuredLyrics": []any{
				map[string]any{
					"lang":          "und",
					"displayArtist": util.FirstArtist(artists),
					"displayTitle":  track.Title,
					"synced":        prepared.Synced,
					"offset":        0,
					"line":          lines,
				},
			},
		},
	}, nil)
}
