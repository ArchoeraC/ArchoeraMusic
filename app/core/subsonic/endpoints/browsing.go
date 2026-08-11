package endpoints

import (
	"database/sql"
	"math/rand"
	"net/http"
	"sort"
	"strings"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/model"
	"github.com/betastudio2/archoera-subsonic/util"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// isStarredHelper 封装 db.IsStarred 适配 util.TrackToChild 签名
func isStarredHelper(userID, targetID, targetType string) bool {
	ok, _ := db.IsStarred(userID, targetID, model.StarTargetType(targetType))
	return ok
}

// GetIndexes /rest/getIndexes.view
func GetIndexes(w http.ResponseWriter, r *http.Request) {
	artists, err := db.GetArtistList()
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	groups := groupByIndex(artists)
	index := make([]any, 0, len(groups))
	for _, g := range groups {
		artistList := make([]any, 0, len(g.list))
		for _, a := range g.list {
			artistList = append(artistList, artistSummaryToArtist(a))
		}
		index = append(index, map[string]any{"name": g.name, "artist": artistList})
	}

	xmlutil.Send(w, r, map[string]any{
		"indexes": map[string]any{
			"ignoredArticles": "The El",
			"index":           index,
		},
	}, nil)
}

// GetArtists /rest/getArtists.view
func GetArtists(w http.ResponseWriter, r *http.Request) {
	artists, err := db.GetArtistList()
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	groups := groupByIndex(artists)
	index := make([]any, 0, len(groups))
	for _, g := range groups {
		artistList := make([]any, 0, len(g.list))
		for _, a := range g.list {
			artistList = append(artistList, artistSummaryToArtist(a))
		}
		index = append(index, map[string]any{"name": g.name, "artist": artistList})
	}

	xmlutil.Send(w, r, map[string]any{
		"artists": map[string]any{
			"ignoredArticles": "The El",
			"index":           index,
		},
	}, nil)
}

// GetArtist /rest/getArtist.view
func GetArtist(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	name := findArtistNameByID(id)
	if name == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Artist not found"})
		return
	}

	tracks, err := db.GetArtistTracks(name)
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	albumNames := make(map[string]bool)
	for _, t := range tracks {
		if t.AlbumJSON.Valid {
			if album := util.ParseAlbum(t.AlbumJSON.String); album != nil {
				albumNames[album.Name] = true
			}
		}
	}

	albums := make([]any, 0, len(albumNames))
	for an := range albumNames {
		at, _ := db.GetAlbumTracks(an)
		coverID := ""
		var duration int64
		for _, t := range at {
			if t.Cover.Valid && t.Cover.String != "" && coverID == "" {
				coverID = t.ID
			}
			duration += t.Duration / 1000
		}
		created := ""
		if len(at) > 0 && at[0].FileCtime.Valid {
			created = util.TimestampISO(at[0].FileCtime.Int64)
		}
		albums = append(albums, map[string]any{
			"id":        util.AlbumIDOf(an),
			"name":      an,
			"artist":    name,
			"artistId":  util.ArtistIDOf(name),
			"coverArt":  coverID,
			"songCount": len(at),
			"duration":  duration,
			"created":   created,
		})
	}

	coverArt := ""
	for _, t := range tracks {
		if t.Cover.Valid && t.Cover.String != "" {
			coverArt = util.ArtistIDOf(name)
			break
		}
	}

	xmlutil.Send(w, r, map[string]any{
		"artist": map[string]any{
			"id":         util.ArtistIDOf(name),
			"name":       name,
			"coverArt":   coverArt,
			"albumCount": len(albums),
			"album":      albums,
		},
	}, nil)
}

// GetAlbum /rest/getAlbum.view
func GetAlbum(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	name := findAlbumNameByID(id)
	if name == "" {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Album not found"})
		return
	}

	tracks, err := db.GetAlbumTracks(name)
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	user := middleware.GetUser(r)
	var duration int64
	coverID := ""
	songs := make([]any, 0, len(tracks))
	for _, t := range tracks {
		if t.Cover.Valid && t.Cover.String != "" && coverID == "" {
			coverID = t.ID
		}
		duration += t.Duration / 1000
		songs = append(songs, util.TrackToChild(t, user.ID, true, isStarredHelper))
	}

	artistName := ""
	artistID := ""
	var year int
	if len(tracks) > 0 {
		artists := util.ParseArtists(tracks[0].ArtistsJSON)
		artistName = util.FirstArtist(artists)
		artistID = util.FirstArtistID(artists)
		if tracks[0].AlbumJSON.Valid {
			if alb := util.ParseAlbum(tracks[0].AlbumJSON.String); alb != nil {
				year = alb.Year
			}
		}
	}

	created := ""
	if len(tracks) > 0 && tracks[0].FileCtime.Valid {
		created = util.TimestampISO(tracks[0].FileCtime.Int64)
	}

	albumMap := map[string]any{
		"id":        util.AlbumIDOf(name),
		"name":      name,
		"artist":    artistName,
		"artistId":  artistID,
		"coverArt":  coverID,
		"songCount": len(tracks),
		"duration":  duration,
		"created":   created,
		"song":      songs,
	}
	if year > 0 {
		albumMap["year"] = year
	}

	xmlutil.Send(w, r, map[string]any{
		"album": albumMap,
	}, nil)
}

// GetAlbumList /rest/getAlbumList.view + getAlbumList2
func GetAlbumList(w http.ResponseWriter, r *http.Request, endpoint string) {
	q := r.URL.Query()
	listType := q.Get("type")
	if listType == "" {
		listType = "newest"
	}
	size := middleware.ParseIntOr(q.Get("size"), 10)
	if size > 500 {
		size = 500
	}
	offset := middleware.ParseIntOr(q.Get("offset"), 0)
	if offset < 0 {
		offset = 0
	}
	genre := strings.TrimSpace(q.Get("genre"))
	fromYear := middleware.ParseIntOr(q.Get("fromYear"), 0)
	toYear := middleware.ParseIntOr(q.Get("toYear"), 0)

	all, err := db.GetAlbumList()
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	// 按 genre 过滤：查询该 genre 下的专辑名集合
	if genre != "" {
		tracks, err := db.GetTracksByGenre(genre, 99999, 0)
		if err == nil {
			matched := make(map[string]bool, len(tracks))
			for _, t := range tracks {
				if t.AlbumJSON.Valid {
					if alb := util.ParseAlbum(t.AlbumJSON.String); alb != nil && alb.Name != "" {
						matched[alb.Name] = true
					}
				}
			}
			filtered := make([]db.AlbumSummary, 0, len(matched))
			for _, a := range all {
				if matched[a.Name] {
					filtered = append(filtered, a)
				}
			}
			all = filtered
		}
	}

	// 按年份范围过滤
	if fromYear > 0 || toYear > 0 {
		filtered := make([]db.AlbumSummary, 0, len(all))
		for _, a := range all {
			tracks, err := db.GetAlbumTracks(a.Name)
			if err != nil || len(tracks) == 0 {
				continue
			}
			// 取第一首曲目的专辑年份
			alb := util.ParseAlbum(tracks[0].AlbumJSON.String)
			if alb == nil {
				continue
			}
			if fromYear > 0 && alb.Year < fromYear {
				continue
			}
			if toYear > 0 && alb.Year > toYear {
				continue
			}
			filtered = append(filtered, a)
		}
		all = filtered
	}

	list := sortAlbums(all, listType)
	if offset >= len(list) {
		list = nil
	} else {
		end := offset + size
		if end > len(list) {
			end = len(list)
		}
		list = list[offset:end]
	}

	albums := make([]any, 0, len(list))
	for _, row := range list {
		albums = append(albums, albumSummaryToAlbum(row))
	}

	key := "albumList"
	if endpoint == "getalbumlist2" {
		key = "albumList2"
	}
	xmlutil.Send(w, r, map[string]any{
		key: map[string]any{"album": albums},
	}, nil)
}

// GetSong /rest/getSong.view
func GetSong(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	track, err := db.GetTrackByID(id)
	if err != nil || track == nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 70, Message: "Song not found"})
		return
	}
	user := middleware.GetUser(r)
	xmlutil.Send(w, r, map[string]any{
		"song": util.TrackToChild(*track, user.ID, true, isStarredHelper),
	}, nil)
}

// GetRandomSongs /rest/getRandomSongs.view
func GetRandomSongs(w http.ResponseWriter, r *http.Request) {
	size := middleware.ParseIntOr(r.URL.Query().Get("size"), 10)
	tracks, err := db.GetRandomTracks(size)
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
		"randomSongs": map[string]any{"song": songs},
	}, nil)
}

// Search2 /rest/search2.view
// Search3 /rest/search3.view
func Search(w http.ResponseWriter, r *http.Request, endpoint string) {
	q := r.URL.Query()
	query := q.Get("query")
	artistCount := clampNonNeg(middleware.ParseIntOr(q.Get("artistCount"), 10))
	albumCount := clampNonNeg(middleware.ParseIntOr(q.Get("albumCount"), 10))
	songCount := clampNonNeg(middleware.ParseIntOr(q.Get("songCount"), 10))
	// offset 只保非负，不能截断上限——否则超出 500 后每页都返回同一批，客户端无限追加重复曲目
	artistOffset := clampOffset(middleware.ParseIntOr(q.Get("artistOffset"), 0))
	albumOffset := clampOffset(middleware.ParseIntOr(q.Get("albumOffset"), 0))
	songOffset := clampOffset(middleware.ParseIntOr(q.Get("songOffset"), 0))

	var tracks []model.Track
	var err error
	matchedArtists := make(map[string]db.ArtistSummary)
	matchedAlbums := make(map[string]db.AlbumSummary)
	user := middleware.GetUser(r)

	if query != "" {
		tracks, err = db.SearchTracks(query)
	} else if artistCount == 0 && albumCount == 0 {
		// 纯分页：仅拉取歌曲，跳过艺术家/专辑构建
		tracks, err = db.GetTracksPaginated(songCount, songOffset)
		if err == nil {
			// 获取歌曲总数量用于分页判断
			totalCount, countErr := db.GetTrackCount()
			if countErr == nil && songOffset+songCount < totalCount {
				// 还有更多歌曲——前端会根据 songOffset 自动翻页
			}
			songList := make([]any, 0, len(tracks))
			for _, t := range tracks {
				songList = append(songList, util.TrackToChild(t, user.ID, true, isStarredHelper))
			}
			key := "searchResult2"
			if endpoint == "search3" {
				key = "searchResult3"
			}
			xmlutil.Send(w, r, map[string]any{
				key: map[string]any{
					"artist": []any{},
					"album":  []any{},
					"song":   songList,
				},
			}, nil)
			return
		}
	} else {
		tracks, err = db.GetAllTracks()
	}
	if err != nil {
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{Code: 0, Message: err.Error()})
		return
	}

	if query != "" || artistCount > 0 || albumCount > 0 {
		for _, t := range tracks {
			artists := util.ParseArtists(t.ArtistsJSON)
			for _, a := range artists {
				if _, ok := matchedArtists[a.Name]; !ok {
					at, _ := db.GetArtistTracks(a.Name)
					cover := ""
					for _, x := range at {
						if x.Cover.Valid && x.Cover.String != "" {
							cover = x.Cover.String
							break
						}
					}
					matchedArtists[a.Name] = db.ArtistSummary{Name: a.Name, TrackCount: len(at), Cover: nullableString(cover)}
				}
			}
			if t.AlbumJSON.Valid {
				album := util.ParseAlbum(t.AlbumJSON.String)
				if album != nil && album.Name != "" {
					if _, ok := matchedAlbums[album.Name]; !ok {
						at, _ := db.GetAlbumTracks(album.Name)
						cover := ""
						artistName := ""
						if len(at) > 0 {
							artistName = util.FirstArtist(util.ParseArtists(at[0].ArtistsJSON))
						}
						for _, x := range at {
							if x.Cover.Valid && x.Cover.String != "" {
								cover = x.Cover.String
								break
							}
						}
						matchedAlbums[album.Name] = db.AlbumSummary{Name: album.Name, Cover: nullableString(cover), Artists: artistName, TrackCount: len(at)}
					}
				}
			}
		}
	}

	artistList := sliceMapArtists(matchedArtists, artistOffset, artistCount)
	albumList := sliceMapAlbums(matchedAlbums, albumOffset, albumCount)
	songList := make([]any, 0)
	if songOffset < len(tracks) {
		end := songOffset + songCount
		if end > len(tracks) {
			end = len(tracks)
		}
		for _, t := range tracks[songOffset:end] {
			songList = append(songList, util.TrackToChild(t, user.ID, true, isStarredHelper))
		}
	}

	key := "searchResult2"
	if endpoint == "search3" {
		key = "searchResult3"
	}
	xmlutil.Send(w, r, map[string]any{
		key: map[string]any{
			"artist": artistList,
			"album":  albumList,
			"song":   songList,
		},
	}, nil)
}

/* ------------------------------------------------------------------ */
/* 辅助函数                                                            */
/* ------------------------------------------------------------------ */

type indexGroup struct {
	name string
	list []db.ArtistSummary
}

func groupByIndex(artists []db.ArtistSummary) []indexGroup {
	groups := make(map[string][]db.ArtistSummary)
	var order []string
	for _, a := range artists {
		idx := "#"
		if len(a.Name) > 0 && ((a.Name[0] >= 'a' && a.Name[0] <= 'z') || (a.Name[0] >= 'A' && a.Name[0] <= 'Z')) {
			idx = strings.ToUpper(a.Name[:1])
		}
		if _, ok := groups[idx]; !ok {
			order = append(order, idx)
		}
		groups[idx] = append(groups[idx], a)
	}
	sort.Strings(order)
	result := make([]indexGroup, 0, len(order))
	for _, name := range order {
		result = append(result, indexGroup{name: name, list: groups[name]})
	}
	return result
}

func artistSummaryToArtist(row db.ArtistSummary) map[string]any {
	coverArt := ""
	if row.Cover.Valid && row.Cover.String != "" {
		coverArt = util.ArtistIDOf(row.Name)
	}
	tracks, _ := db.GetArtistTracks(row.Name)
	albumSet := make(map[string]bool)
	for _, t := range tracks {
		if t.AlbumJSON.Valid {
			if album := util.ParseAlbum(t.AlbumJSON.String); album != nil {
				albumSet[album.Name] = true
			}
		}
	}
	return map[string]any{
		"id":         util.ArtistIDOf(row.Name),
		"name":       row.Name,
		"coverArt":   coverArt,
		"albumCount": len(albumSet),
	}
}

func albumSummaryToAlbum(row db.AlbumSummary) map[string]any {
	tracks, _ := db.GetAlbumTracks(row.Name)
	var duration int64
	coverID := ""
	var year int
	for _, t := range tracks {
		if t.Cover.Valid && t.Cover.String != "" && coverID == "" {
			coverID = t.ID
		}
		duration += t.Duration / 1000
		if year == 0 && t.AlbumJSON.Valid {
			if alb := util.ParseAlbum(t.AlbumJSON.String); alb != nil {
				year = alb.Year
			}
		}
	}
	created := ""
	if len(tracks) > 0 && tracks[0].FileCtime.Valid {
		created = util.TimestampISO(tracks[0].FileCtime.Int64)
	}
	artistName := row.Artists
	if artistName != "" {
		artists := util.ParseArtists(artistName)
		artistName = util.FirstArtist(artists)
	}
	coverArt := coverID
	if coverArt == "" {
		coverArt = util.AlbumIDOf(row.Name)
	}
	m := map[string]any{
		"id":        util.AlbumIDOf(row.Name),
		"name":      row.Name,
		"artist":    artistName,
		"artistId":  util.ArtistIDOf(artistName),
		"coverArt":  coverArt,
		"songCount": row.TrackCount,
		"duration":  duration,
		"created":   created,
	}
	if year > 0 {
		m["year"] = year
	}
	return m
}

func findArtistNameByID(id string) string {
	artists, _ := db.GetArtistList()
	for _, a := range artists {
		if util.ArtistIDOf(a.Name) == id {
			return a.Name
		}
	}
	return ""
}

func findAlbumNameByID(id string) string {
	albums, _ := db.GetAlbumList()
	for _, a := range albums {
		if util.AlbumIDOf(a.Name) == id {
			return a.Name
		}
	}
	return ""
}

func sortAlbums(all []db.AlbumSummary, listType string) []db.AlbumSummary {
	list := make([]db.AlbumSummary, len(all))
	copy(list, all)
	switch listType {
	case "newest", "recent":
		sort.Slice(list, func(i, j int) bool {
			at, _ := db.GetAlbumTracks(list[i].Name)
			bt, _ := db.GetAlbumTracks(list[j].Name)
			var aTime, bTime int64
			if len(at) > 0 && at[0].FileCtime.Valid {
				aTime = at[0].FileCtime.Int64
			}
			if len(bt) > 0 && bt[0].FileCtime.Valid {
				bTime = bt[0].FileCtime.Int64
			}
			return aTime > bTime
		})
	case "frequent":
		sort.Slice(list, func(i, j int) bool { return list[i].TrackCount > list[j].TrackCount })
	case "random":
		rand.Shuffle(len(list), func(i, j int) { list[i], list[j] = list[j], list[i] })
	case "alphabeticalByName":
		sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	case "alphabeticalByArtist":
		sort.Slice(list, func(i, j int) bool { return list[i].Artists < list[j].Artists })
	default:
		sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	}
	return list
}

func clampNonNeg(n int) int {
	if n < 0 {
		return 0
	}
	if n > 500 {
		return 500
	}
	return n
}

// clampOffset 仅保证 offset 非负，不设上限——分页偏移截断会导致重复返回同一页数据
func clampOffset(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

func nullableString(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}

func sliceMapArtists(m map[string]db.ArtistSummary, offset, count int) []any {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	result := make([]any, 0)
	if offset >= len(keys) {
		return result
	}
	end := offset + count
	if end > len(keys) {
		end = len(keys)
	}
	for _, k := range keys[offset:end] {
		result = append(result, artistSummaryToArtist(m[k]))
	}
	return result
}

func sliceMapAlbums(m map[string]db.AlbumSummary, offset, count int) []any {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	result := make([]any, 0)
	if offset >= len(keys) {
		return result
	}
	end := offset + count
	if end > len(keys) {
		end = len(keys)
	}
	for _, k := range keys[offset:end] {
		result = append(result, albumSummaryToAlbum(m[k]))
	}
	return result
}
