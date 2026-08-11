package main

import (
	"log"
	"net/http"
	"strings"

	"github.com/betastudio2/archoera-subsonic/endpoints"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

// dispatch 统一端点分发（与 TS 版 switch 逻辑一致）
// 服务器生命周期由 lib_subsonic.go 的 runServer 管理
func dispatch(w http.ResponseWriter, r *http.Request) {
	endpoint := middleware.ParseEndpoint(r.URL.Path)

	// 去掉 /rest 前缀后的端点名
	// 例如 /rest/ping.view → ping, /rest/rest/getCoverArt → getcoverart
	ep := strings.ToLower(endpoint)

	switch ep {
	/* ---- 基础 ---- */
	case "ping":
		endpoints.Ping(w, r)
	case "getlicense":
		endpoints.GetLicense(w, r)
	case "getopensubsonicextensions":
		endpoints.GetOpenSubsonicExtensions(w, r)
	case "getmusicfolders":
		endpoints.GetMusicFolders(w, r)

	/* ---- 浏览 ---- */
	case "getindexes":
		endpoints.GetIndexes(w, r)
	case "getartists":
		endpoints.GetArtists(w, r)
	case "getartist":
		endpoints.GetArtist(w, r)
	case "getalbum":
		endpoints.GetAlbum(w, r)
	case "getalbumlist", "getalbumlist2":
		endpoints.GetAlbumList(w, r, ep)
	case "getsong":
		endpoints.GetSong(w, r)
	case "getrandomsongs":
		endpoints.GetRandomSongs(w, r)
	case "getmusicdirectory":
		endpoints.GetMusicDirectory(w, r)

	/* ---- 媒体 ---- */
	case "getcoverart":
		endpoints.ServeCoverArt(w, r)
	case "stream", "download":
		endpoints.ServeStream(w, r, ep == "download")

	/* ---- 搜索 ---- */
	case "search2", "search3":
		endpoints.Search(w, r, ep)

	/* ---- 收藏 ---- */
	case "star":
		endpoints.Star(w, r)
	case "unstar":
		endpoints.Unstar(w, r)
	case "getstarred", "getstarred2":
		endpoints.GetStarred(w, r, ep)

	/* ---- 歌词 ---- */
	case "getlyrics":
		endpoints.GetLyrics(w, r)
	case "getlyricsbysongid":
		endpoints.GetLyricsBySongId(w, r)

	/* ---- 播放列表 ---- */
	case "getplaylists":
		endpoints.GetPlaylists(w, r)
	case "getplaylist":
		endpoints.GetPlaylist(w, r)
	case "createplaylist":
		endpoints.CreatePlaylist(w, r)
	case "updateplaylist":
		endpoints.UpdatePlaylist(w, r)
	case "deleteplaylist":
		endpoints.DeletePlaylist(w, r)

	/* ---- 分享 ---- */
	case "getshares":
		endpoints.GetShares(w, r)
	case "createshare":
		endpoints.CreateShare(w, r)
	case "updateshare":
		endpoints.UpdateShare(w, r)
	case "deleteshare":
		endpoints.DeleteShare(w, r)

	/* ---- 用户 ---- */
	case "getusers":
		endpoints.GetUsers(w, r)
	case "getuser":
		endpoints.GetUser(w, r)

	/* ---- 扫描 ---- */
	case "getscanstatus":
		endpoints.GetScanStatus(w, r)
	case "startscan":
		endpoints.StartScan(w, r)

	/* ---- 元信息 ---- */
	case "getartistinfo", "getartistinfo2":
		endpoints.GetArtistInfo(w, r, ep)
	case "getalbuminfo", "getalbuminfo2":
		endpoints.GetAlbumInfo(w, r, ep)

	/* ---- 其他（简化实现） ---- */
	case "getgenres":
		endpoints.GetGenres(w, r)
	case "getnowplaying":
		endpoints.GetNowPlaying(w, r)
	case "gettopsongs":
		endpoints.GetTopSongs(w, r)
	case "getsimilarartists", "getsimilarartists2":
		endpoints.GetSimilarArtists(w, r, ep)
	case "getsongsbygenre":
		endpoints.GetSongsByGenre(w, r)
	case "scrobble":
		endpoints.Scrobble(w, r)

	default:
		log.Printf("[subsonic] 未实现的端点: %s", ep)
		xmlutil.Send(w, r, map[string]any{}, &xmlutil.SubError{
			Code:    0,
			Message: "Endpoint " + ep + " not implemented",
		})
	}
}
