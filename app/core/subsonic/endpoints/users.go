package endpoints

import (
	"net/http"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/model"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// GetUsers /rest/getUsers.view
func GetUsers(w http.ResponseWriter, r *http.Request) {
	users, err := db.ListUsers()
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}
	list := make([]any, 0, len(users))
	for _, u := range users {
		list = append(list, userToMap(u))
	}
	xmlutil.Send(w, r, map[string]any{"users": map[string]any{"user": list}}, nil)
}

// GetUser /rest/getUser.view
func GetUser(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)
	targetUsername := r.URL.Query().Get("username")
	if targetUsername != "" {
		users, _ := db.ListUsers()
		for _, u := range users {
			if u.Username == targetUsername {
				xmlutil.Send(w, r, map[string]any{"user": userToMap(u)}, nil)
				return
			}
		}
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "User not found"})
		return
	}
	xmlutil.Send(w, r, map[string]any{"user": userToMap(*user)}, nil)
}

func userToMap(u model.SubsonicUser) map[string]any {
	return map[string]any{
		"username":     u.Username,
		"adminRole":    u.IsAdmin,
		"settingsRole": u.IsAdmin,
		"downloadRole": true,
		"uploadRole":   false,
		"playlistRole": true,
		"coverArtRole": false,
		"commentRole":  true,
		"podcastRole":  false,
		"streamRole":   true,
		"jukeboxRole":  false,
		"shareRole":    true,
	}
}
