package endpoints

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/betastudio2/archoera-subsonic/config"
	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/lyric"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

/** 在线歌词注入响应 */
type injectLyricResp struct {
	Main        string `json:"main,omitempty"`
	Translation string `json:"translation,omitempty"`
	Romaji      string `json:"romaji,omitempty"`
}

/** 请求宿主（Dart）获取在线歌词：发 lyric-request 事件并同步等待结果 */
func fetchOnlineLyrics(id, title, artist string) *injectLyricResp {
	res := config.RequestOnlineLyrics(id, title, artist)
	if res == "" {
		return nil
	}
	var result injectLyricResp
	if err := json.Unmarshal([]byte(res), &result); err != nil {
		return nil
	}
	if result.Main == "" {
		return nil
	}
	return &result
}

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

	// 1) 取内嵌歌词
	var mainLyric string
	if trackID != "" {
		if embedded, err := db.GetTrackLyrics(trackID); err == nil && strings.TrimSpace(embedded) != "" {
			mainLyric = embedded
		}
	}

	// 2) 内嵌歌词为空时，回调 TS 获取在线歌词
	if mainLyric == "" && titleStr != "" {
		if online := fetchOnlineLyrics(trackID, titleStr, artistStr); online != nil {
			mainLyric = online.Main
		}
	}

	if mainLyric == "" {
		xmlutil.Send(w, r, map[string]any{"lyrics": map[string]any{}}, nil)
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

	embedded, err := db.GetTrackLyrics(id)
	if err != nil || strings.TrimSpace(embedded) == "" {
		// 内嵌歌词为空时，回调 TS 获取在线歌词
		artists := util.ParseArtists(track.ArtistsJSON)
		artistStr := util.FirstArtist(artists)
		if online := fetchOnlineLyrics(id, track.Title, artistStr); online != nil {
			embedded = online.Main
		}
	}

	if embedded == "" || strings.TrimSpace(embedded) == "" {
		xmlutil.Send(w, r, map[string]any{"lyricsList": map[string]any{}}, nil)
		return
	}

	prepared := lyric.Prepare(lyric.TrackLyricPayload{Main: embedded})
	if len(prepared.StructuredLines) == 0 {
		xmlutil.Send(w, r, map[string]any{"lyricsList": map[string]any{}}, nil)
		return
	}

	artists := util.ParseArtists(track.ArtistsJSON)
	lines := make([]any, 0, len(prepared.StructuredLines))
	for _, l := range prepared.StructuredLines {
		lines = append(lines, map[string]any{"start": l.Start, "value": l.Value})
	}

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
