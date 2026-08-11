package endpoints

import (
	"net/http"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// GetPlaylists /rest/getPlaylists.view
func GetPlaylists(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)
	pls, err := db.ListPlaylists(user.ID)
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	list := make([]any, 0, len(pls))
	for _, p := range pls {
		var duration int64
		tracks, _ := db.GetTracksByIDs(p.TrackIDs)
		for _, t := range tracks {
			duration += t.Duration / 1000
		}
		entry := map[string]any{
			"id":        p.ID,
			"name":      p.Name,
			"songCount": len(p.TrackIDs),
			"duration":  duration,
			"public":    p.Public,
			"created":   util.TimestampISO(p.CreatedAt),
			"changed":   util.TimestampISO(p.UpdatedAt),
			"owner":     user.Username,
		}
		if p.Comment.Valid {
			entry["comment"] = p.Comment.String
		}
		list = append(list, entry)
	}
	xmlutil.Send(w, r, map[string]any{"playlists": map[string]any{"playlist": list}}, nil)
}

// GetPlaylist /rest/getPlaylist.view
func GetPlaylist(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)
	id := r.URL.Query().Get("id")
	pl, err := db.GetPlaylist(id, user.ID)
	if err != nil || pl == nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Playlist not found"})
		return
	}

	tracks, _ := db.GetTracksByIDs(pl.TrackIDs)
	var duration int64
	entries := make([]any, 0, len(tracks))
	for _, t := range tracks {
		duration += t.Duration / 1000
		entries = append(entries, util.TrackToChild(t, user.ID, true, isStarredHelper))
	}

	entry := map[string]any{
		"id":        pl.ID,
		"name":      pl.Name,
		"songCount": len(pl.TrackIDs),
		"duration":  duration,
		"public":    pl.Public,
		"created":   util.TimestampISO(pl.CreatedAt),
		"changed":   util.TimestampISO(pl.UpdatedAt),
		"owner":     user.Username,
		"entry":     entries,
	}
	if pl.Comment.Valid {
		entry["comment"] = pl.Comment.String
	}
	xmlutil.Send(w, r, map[string]any{"playlist": entry}, nil)
}
