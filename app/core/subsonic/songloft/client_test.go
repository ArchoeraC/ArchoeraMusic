// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

package songloft

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func newSession(t *testing.T, srv *httptest.Server, cacheDir string) (*Session, *[]map[string]any) {
	t.Helper()
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(u.Port())
	s, err := Open(Config{
		ServerID:      "srv-1",
		Scheme:        u.Scheme,
		Host:          u.Hostname(),
		Port:          port,
		Username:      "alice",
		Password:      "secret",
		CoverCacheDir: cacheDir,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	events := make([]map[string]any, 0, 8)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case raw := <-s.Events():
			var ev map[string]any
			if err := json.Unmarshal(raw, &ev); err != nil {
				t.Fatalf("事件不是 JSON: %s", raw)
			}
			events = append(events, ev)
			if ev["type"] == "ready" || ev["type"] == "error" {
				return s, &events
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	t.Fatal("等待 ready / error 超时")
	return nil, nil
}

func waitResult(t *testing.T, s *Session, id string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case raw := <-s.Events():
			var ev map[string]any
			if err := json.Unmarshal(raw, &ev); err != nil {
				t.Fatalf("事件不是 JSON: %s", raw)
			}
			if ev["type"] == "result" && ev["id"] == id {
				return ev
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	t.Fatalf("等待 result %s 超时", id)
	return nil
}

func TestOpenLoginAndListSongs(t *testing.T) {
	var loginCalls atomic.Int32
	var sawToken atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/version":
			_, _ = w.Write([]byte(`{"version":"2.2.3","full":"2.2.3+1"}`))
		case "/api/v1/auth/login":
			loginCalls.Add(1)
			_, _ = w.Write([]byte(`{"access_token":"t1","refresh_token":"r1","expires_in":3600}`))
		case "/api/v1/songs":
			if r.Header.Get("Authorization") != "Bearer t1" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			sawToken.Store(true)
			q := r.URL.Query()
			if q.Get("limit") != "500" || q.Get("sort") != "added_at" {
				t.Errorf("分页/排序参数丢失: %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`{"songs":[{"id":7,"title":"晴天","artist":"周杰伦","album":"叶惠美","duration":269.5,"file_size":123,"format":"flac","bit_rate":900,"sample_rate":44100}],"total":1,"limit":500,"offset":0}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	s, events := newSession(t, srv, t.TempDir())
	if (*events)[len(*events)-1]["type"] != "ready" {
		t.Fatalf("未 ready: %v", *events)
	}
	for _, ev := range *events {
		if ev["type"] == "token" && (ev["accessToken"] != "t1" || ev["refreshToken"] != "r1") {
			t.Fatalf("token 事件错误: %v", ev)
		}
	}
	if loginCalls.Load() != 1 {
		t.Fatalf("login 次数 = %d, want 1", loginCalls.Load())
	}
	if err := s.Call("1", "listSongs", json.RawMessage(`{"limit":500,"sort":"added_at","order":"desc"}`)); err != nil {
		t.Fatal(err)
	}
	ev := waitResult(t, s, "1")
	if ev["ok"] != true {
		t.Fatalf("listSongs 失败: %v", ev)
	}
	data := ev["data"].(map[string]any)
	if data["total"].(float64) != 1 {
		t.Fatalf("total = %v", data["total"])
	}
	songs := data["songs"].([]any)
	first := songs[0].(map[string]any)
	if first["title"] != "晴天" || first["id"].(float64) != 7 {
		t.Fatalf("song = %v", first)
	}
	if !sawToken.Load() {
		t.Fatal("songs 未带 Bearer token")
	}
}

func TestRefreshOn401(t *testing.T) {
	var refreshCalls atomic.Int32
	var songsCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/version":
			_, _ = w.Write([]byte(`{"version":"2.2.3"}`))
		case "/api/v1/auth/login":
			_, _ = w.Write([]byte(`{"access_token":"old","refresh_token":"r1","expires_in":3600}`))
		case "/api/v1/auth/refresh":
			refreshCalls.Add(1)
			_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"r2","expires_in":3600}`))
		case "/api/v1/songs/facets":
			n := songsCalls.Add(1)
			if n == 1 {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if r.Header.Get("Authorization") != "Bearer new" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = w.Write([]byte(`{"field":"album","facets":[{"value":"叶惠美","count":3,"cover_url":"/api/v1/songs/9/cover"}],"total":1,"limit":500,"offset":0}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	s, _ := newSession(t, srv, t.TempDir())
	if err := s.Call("a", "listAlbums", json.RawMessage(`{"limit":500}`)); err != nil {
		t.Fatal(err)
	}
	ev := waitResult(t, s, "a")
	if ev["ok"] != true {
		t.Fatalf("listAlbums 失败: %v", ev)
	}
	if refreshCalls.Load() != 1 || songsCalls.Load() != 2 {
		t.Fatalf("refresh=%d calls=%d", refreshCalls.Load(), songsCalls.Load())
	}
	facet := ev["data"].(map[string]any)["facets"].([]any)[0].(map[string]any)
	if facet["coverSongId"].(float64) != 9 {
		t.Fatalf("coverSongId = %v", facet["coverSongId"])
	}
}

func TestLyrics404AndCoverCache(t *testing.T) {
	var coverHits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/version":
			_, _ = w.Write([]byte(`{"version":"2.2.3"}`))
		case "/api/v1/auth/login":
			_, _ = w.Write([]byte(`{"access_token":"t1","refresh_token":"r1","expires_in":3600}`))
		case "/api/v1/songs/1/lyric":
			w.WriteHeader(http.StatusNotFound)
		case "/api/v1/songs/1/cover":
			coverHits.Add(1)
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte("PNGDATA"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	cache := t.TempDir()
	s, _ := newSession(t, srv, cache)
	if err := s.Call("l", "getLyrics", json.RawMessage(`{"songId":1}`)); err != nil {
		t.Fatal(err)
	}
	ev := waitResult(t, s, "l")
	if ev["ok"] != true {
		t.Fatalf("歌词 404 应返回空结果: %v", ev)
	}

	if err := s.Call("c", "getCover", json.RawMessage(`{"kind":"song","id":1}`)); err != nil {
		t.Fatal(err)
	}
	cov := waitResult(t, s, "c")
	if cov["ok"] != true {
		t.Fatalf("getCover 失败: %v", cov)
	}
	path := cov["data"].(map[string]any)["path"].(string)
	if filepath.Dir(path) != filepath.Join(cache, "srv-1") {
		t.Fatalf("封面路径 = %s", path)
	}
	b, err := os.ReadFile(path)
	if err != nil || string(b) != "PNGDATA" {
		t.Fatalf("封面内容 = %q, err=%v", b, err)
	}
	// 第二次命中缓存，不再请求服务端。
	if err := s.Call("c2", "getCover", json.RawMessage(`{"kind":"song","id":1}`)); err != nil {
		t.Fatal(err)
	}
	if ev := waitResult(t, s, "c2"); ev["data"].(map[string]any)["cached"] != true {
		t.Fatalf("第二次未命中缓存: %v", ev)
	}
	if coverHits.Load() != 1 {
		t.Fatalf("cover 请求次数 = %d, want 1", coverHits.Load())
	}
}

func TestStreamURLQuality(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/version":
			_, _ = w.Write([]byte(`{"version":"2.2.3"}`))
		case "/api/v1/auth/login":
			_, _ = w.Write([]byte(`{"access_token":"tok","refresh_token":"r1","expires_in":3600}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	s, _ := newSession(t, srv, t.TempDir())
	if err := s.Call("u", "getStreamUrl", json.RawMessage(`{"songId":5,"quality":"high"}`)); err != nil {
		t.Fatal(err)
	}
	ev := waitResult(t, s, "u")
	if ev["ok"] != true {
		t.Fatalf("getStreamUrl 失败: %v", ev)
	}
	u := ev["data"].(map[string]any)["url"].(string)
	for _, want := range []string{"/api/v1/songs/5/play", "format=mp3", "quality=320", "access_token=tok"} {
		if !strings.Contains(u, want) {
			t.Fatalf("url %q 缺少 %q", u, want)
		}
	}
}
