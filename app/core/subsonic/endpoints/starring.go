package endpoints

import (
	"net/http"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/model"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// Star /rest/star.view
func Star(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)

	ids := middleware.CollectIds(r, "id")
	albumIds := middleware.CollectIds(r, "albumId")
	artistIds := middleware.CollectIds(r, "artistId")

	for _, id := range ids {
		_ = db.Star(user.ID, id, model.StarTrack)
	}
	for _, id := range albumIds {
		_ = db.Star(user.ID, id, model.StarAlbum)
	}
	for _, id := range artistIds {
		_ = db.Star(user.ID, id, model.StarArtist)
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

// Unstar /rest/unstar.view
func Unstar(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)

	ids := middleware.CollectIds(r, "id")
	albumIds := middleware.CollectIds(r, "albumId")
	artistIds := middleware.CollectIds(r, "artistId")

	for _, id := range ids {
		_ = db.Unstar(user.ID, id, model.StarTrack)
	}
	for _, id := range albumIds {
		_ = db.Unstar(user.ID, id, model.StarAlbum)
	}
	for _, id := range artistIds {
		_ = db.Unstar(user.ID, id, model.StarArtist)
	}
	xmlutil.Send(w, r, map[string]any{}, nil)
}

// GetStarred /rest/getStarred.view + getStarred2
func GetStarred(w http.ResponseWriter, r *http.Request, endpoint string) {
	user := middleware.GetUser(r)
	starred, err := db.GetStarredIDs(user.ID)
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	// songs
	songTracks, _ := db.GetTracksByIDs(starred.Tracks)
	songs := make([]any, 0, len(songTracks))
	for _, t := range songTracks {
		songs = append(songs, util.TrackToChild(t, user.ID, true, isStarredHelper))
	}

	// albums
	albums := make([]any, 0)
	for _, id := range starred.Albums {
		name := findAlbumNameByID(id)
		if name == "" {
			continue
		}
		all, _ := db.GetAlbumList()
		for _, a := range all {
			if a.Name == name {
				albums = append(albums, albumSummaryToAlbum(a))
				break
			}
		}
	}

	// artists
	artists := make([]any, 0)
	for _, id := range starred.Artists {
		name := findArtistNameByID(id)
		if name == "" {
			continue
		}
		all, _ := db.GetArtistList()
		for _, a := range all {
			if a.Name == name {
				artists = append(artists, artistSummaryToArtist(a))
				break
			}
		}
	}

	key := "starred"
	if endpoint == "getstarred2" {
		key = "starred2"
	}
	xmlutil.Send(w, r, map[string]any{
		key: map[string]any{
			"song":   songs,
			"album":  albums,
			"artist": artists,
		},
	}, nil)
}
