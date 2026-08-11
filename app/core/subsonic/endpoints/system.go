package endpoints

import (
	"net/http"
	"strings"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// Ping /rest/ping.view
func Ping(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{}, nil)
}

// GetLicense /rest/getLicense.view
func GetLicense(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{
		"license": map[string]any{
			"valid":          true,
			"email":          "splayer@local",
			"licenseExpires": "2099-01-01",
		},
	}, nil)
}

// GetOpenSubsonicExtensions /rest/getOpenSubsonicExtensions.view
func GetOpenSubsonicExtensions(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{
		"openSubsonicExtensions": []any{
			map[string]any{"name": "formPost", "versions": []any{1}},
			map[string]any{"name": "songLyrics", "versions": []any{1, 2}},
		},
	}, nil)
}

// GetMusicFolders /rest/getMusicFolders.view
func GetMusicFolders(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{
		"musicFolders": map[string]any{
			"musicFolder": []any{
				map[string]any{"id": 0, "name": "Music"},
			},
		},
	}, nil)
}

// GetGenres /rest/getGenres.view
// 从 tracks.genre 聚合，返回流派列表及歌曲/专辑数
func GetGenres(w http.ResponseWriter, r *http.Request) {
	genres, err := db.GetGenres()
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	list := make([]any, 0, len(genres))
	for _, g := range genres {
		list = append(list, map[string]any{
			"#text":      g.Name,
			"songCount":  g.TrackCount,
			"albumCount": g.AlbumCount,
		})
	}
	xmlutil.Send(w, r, map[string]any{
		"genres": map[string]any{"genre": list},
	}, nil)
}

// GetNowPlaying /rest/getNowPlaying.view
func GetNowPlaying(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{"nowPlaying": map[string]any{}}, nil)
}

// GetTopSongs /rest/getTopSongs.view
func GetTopSongs(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{"topSongs": map[string]any{"song": []any{}}}, nil)
}

// GetSimilarArtists /rest/getSimilarArtists.view + getSimilarArtists2
func GetSimilarArtists(w http.ResponseWriter, r *http.Request, endpoint string) {
	key := "similarArtists"
	if endpoint == "getsimilarartists2" {
		key = "similarArtists2"
	}
	xmlutil.Send(w, r, map[string]any{
		key: map[string]any{"artist": []any{}},
	}, nil)
}

// GetSongsByGenre /rest/getSongsByGenre.view
func GetSongsByGenre(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	genre := strings.TrimSpace(q.Get("genre"))
	if genre == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 10, Message: "Missing genre"})
		return
	}
	count := middleware.ParseIntOr(q.Get("count"), 10)
	offset := middleware.ParseIntOr(q.Get("offset"), 0)
	tracks, err := db.GetTracksByGenre(genre, count, offset)
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	user := middleware.GetUser(r)
	songs := make([]any, 0, len(tracks))
	for _, t := range tracks {
		songs = append(songs, util.TrackToChild(t, user.ID, true, isStarredHelper))
	}
	xmlutil.Send(w, r, map[string]any{
		"songsByGenre": map[string]any{"song": songs},
	}, nil)
}

// Scrobble /rest/scrobble.view（简化：仅日志）
func Scrobble(w http.ResponseWriter, r *http.Request) {
	xmlutil.Send(w, r, map[string]any{}, nil)
}
