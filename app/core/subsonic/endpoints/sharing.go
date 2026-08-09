package endpoints

import (
	"net/http"

	"github.com/splayer/subsonic-go/db"
	"github.com/splayer/subsonic-go/middleware"
	"github.com/splayer/subsonic-go/util"
	"github.com/splayer/subsonic-go/xmlutil"
)

// GetShares /rest/getShares.view
func GetShares(w http.ResponseWriter, r *http.Request) {
	user := middleware.GetUser(r)
	shares, err := db.ListShares(user.ID)
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	list := make([]any, 0, len(shares))
	for _, s := range shares {
		entry := map[string]any{
			"id":         s.ID,
			"name":       s.Name,
			"url":        s.URL,
			"username":   user.Username,
			"created":    util.TimestampISO(s.CreatedAt),
			"visitCount": s.VisitCount,
		}
		if s.Description.Valid {
			entry["description"] = s.Description.String
		}
		if s.ExpiresAt.Valid {
			entry["expires"] = util.TimestampISO(s.ExpiresAt.Int64)
		}
		list = append(list, entry)
	}
	xmlutil.Send(w, r, map[string]any{"shares": map[string]any{"share": list}}, nil)
}
