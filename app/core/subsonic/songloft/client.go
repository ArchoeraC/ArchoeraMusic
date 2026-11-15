// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package songloft 是 Songloft 服务端（/api/v1 + JWT）的纯 HTTP 客户端。
//
// 与 Subsonic 服务端代码完全隔离：不读写 library.db / user.db，不触碰
// config / credentials 包，只维护自己的会话（token、HTTP 连接池）。
// 由 lib_songloft.go 的 archoera_songloft_* FFI 导出供 Dart 调用。
package songloft

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Config 是 FFI open 传入的会话配置（与 Dart 侧 SongloftSessionConfig 对齐）。
type Config struct {
	ServerID         string `json:"serverId"`
	Scheme           string `json:"scheme"`
	Host             string `json:"host"`
	Port             int    `json:"port"`
	Username         string `json:"username"`
	Password         string `json:"password"`
	AccessToken      string `json:"accessToken"`
	RefreshToken     string `json:"refreshToken"`
	ExpiresAt        int64  `json:"expiresAt"`
	CoverCacheDir    string `json:"coverCacheDir"`
	RequestTimeoutMS int    `json:"requestTimeoutMs"`
}

// Error 是跨 FFI 的错误（code 供 Dart 映射 Streaming*Error）。
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

func newError(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// 错误码：auth / network / timeout / not-found / protocol / canceled。
const (
	CodeAuth     = "auth"
	CodeNetwork  = "network"
	CodeTimeout  = "timeout"
	CodeNotFound = "not-found"
	CodeProtocol = "protocol"
	CodeCanceled = "canceled"
)

// 事件（JSON）通过 Events 通道交给 FFI 层。
type event struct {
	Type         string `json:"type"`
	ID           string `json:"id,omitempty"`
	OK           bool   `json:"ok,omitempty"`
	Data         any    `json:"data,omitempty"`
	Error        *Error `json:"error,omitempty"`
	AccessToken  string `json:"accessToken,omitempty"`
	RefreshToken string `json:"refreshToken,omitempty"`
	ExpiresAt    int64  `json:"expiresAt,omitempty"`
	Version      string `json:"version,omitempty"`
	Message      string `json:"message,omitempty"`
}

// Session 是一次 Songloft 服务器连接（每个 serverId 一个）。
type Session struct {
	cfg  Config
	base string
	http *http.Client
	// events 缓冲：Dart 侧 20ms 轮询消费；满则丢弃并记错误（与 Subsonic 服务端一致）。
	events chan []byte

	mu        sync.Mutex
	access    string
	refresh   string
	expiresAt int64
	version   string
	ready     bool
	closed    bool
	closeOnce sync.Once
	done      chan struct{}
}

// Open 创建会话并异步完成 version + 登录，结果经事件 ready / error 回传。
func Open(cfg Config) (*Session, error) {
	scheme := strings.TrimSpace(cfg.Scheme)
	if scheme == "" {
		scheme = "http"
	}
	if scheme != "http" && scheme != "https" {
		return nil, newError(CodeProtocol, "不支持的协议 %q", cfg.Scheme)
	}
	host := strings.TrimSpace(cfg.Host)
	if host == "" {
		return nil, newError(CodeProtocol, "服务器地址为空")
	}
	port := cfg.Port
	if port <= 0 {
		port = 58091
	}
	timeout := time.Duration(cfg.RequestTimeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	s := &Session{
		cfg:       cfg,
		base:      fmt.Sprintf("%s://%s", scheme, net.JoinHostPort(host, strconv.Itoa(port))),
		events:    make(chan []byte, 256),
		access:    cfg.AccessToken,
		refresh:   cfg.RefreshToken,
		expiresAt: cfg.ExpiresAt,
		done:      make(chan struct{}),
	}
	s.http = &http.Client{Timeout: timeout}
	go s.start()
	return s, nil
}

// Events 返回事件通道（FFI take_event 消费）。
func (s *Session) Events() <-chan []byte { return s.events }

// Close 停止会话（幂等）；未完成请求由 Dart 侧按 id 失败。
func (s *Session) Close() {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.closed = true
		s.mu.Unlock()
		close(s.done)
		s.http.CloseIdleConnections()
	})
}

func (s *Session) emit(ev event) {
	b, err := json.Marshal(ev)
	if err != nil {
		return
	}
	select {
	case s.events <- b:
	case <-s.done:
	default:
		// 宿主轮询不及时：丢弃事件，避免阻塞请求 goroutine。
	}
}

func (s *Session) start() {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	v, err := s.fetchVersion(ctx)
	if err != nil {
		s.emit(event{Type: "error", Message: err.Error()})
		return
	}
	s.mu.Lock()
	s.version = v
	s.mu.Unlock()
	if err := s.ensureToken(ctx); err != nil {
		s.emit(event{Type: "error", Message: err.Error()})
		return
	}
	s.mu.Lock()
	s.ready = true
	s.mu.Unlock()
	s.emit(event{Type: "ready", Version: v})
}

// Call 异步执行一个目录/播放请求；结果经 result 事件回传。
func (s *Session) Call(id, method string, params json.RawMessage) error {
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return newError(CodeCanceled, "会话已关闭")
	}
	go func() {
		data, err := s.dispatch(method, params)
		if err != nil {
			s.emit(event{Type: "result", ID: id, OK: false, Error: asError(err)})
			return
		}
		s.emit(event{Type: "result", ID: id, OK: true, Data: data})
	}()
	return nil
}

func asError(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return &Error{Code: CodeProtocol, Message: err.Error()}
}

func (s *Session) dispatch(method string, raw json.RawMessage) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), s.requestTimeout())
	defer cancel()
	switch method {
	case "version":
		v := s.cachedVersion()
		if v == "" {
			var err error
			if v, err = s.fetchVersion(ctx); err != nil {
				return nil, err
			}
			s.mu.Lock()
			s.version = v
			s.mu.Unlock()
		}
		return map[string]any{"version": v}, nil
	case "login":
		if err := s.login(ctx); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "listSongs":
		return s.listSongs(ctx, raw)
	case "listAlbums":
		return s.listFacets(ctx, "album", raw)
	case "listArtists":
		return s.listFacets(ctx, "artist", raw)
	case "listPlaylists":
		return s.listPlaylists(ctx, raw)
	case "getPlaylistSongs":
		return s.playlistSongs(ctx, raw)
	case "getStreamUrl":
		return s.streamURL(raw)
	case "getLyrics":
		return s.lyrics(ctx, raw)
	case "getCover":
		return s.cover(ctx, raw)
	default:
		return nil, newError(CodeProtocol, "不支持的方法 %q", method)
	}
}

func (s *Session) requestTimeout() time.Duration {
	if s.cfg.RequestTimeoutMS > 0 {
		return time.Duration(s.cfg.RequestTimeoutMS) * time.Millisecond
	}
	return 30 * time.Second
}

func (s *Session) cachedVersion() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.version
}

/* ------------------------------------------------------------------ */
/* 认证                                                                */
/* ------------------------------------------------------------------ */

type loginResp struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

func (s *Session) ensureToken(ctx context.Context) error {
	s.mu.Lock()
	access := s.access
	refresh := s.refresh
	expiresAt := s.expiresAt
	s.mu.Unlock()
	if access != "" && (expiresAt == 0 || time.Now().Unix() < expiresAt-60) {
		return nil
	}
	if refresh != "" {
		if err := s.refreshToken(ctx); err == nil {
			return nil
		}
	}
	return s.login(ctx)
}

func (s *Session) login(ctx context.Context) error {
	if s.cfg.Username == "" {
		return newError(CodeAuth, "缺少用户名")
	}
	body := map[string]string{"username": s.cfg.Username, "password": s.cfg.Password}
	res, err := s.doJSON(ctx, http.MethodPost, "/api/v1/auth/login", nil, body, nil, false)
	if err != nil {
		return err
	}
	var lr loginResp
	if err := json.Unmarshal(res, &lr); err != nil {
		return newError(CodeProtocol, "登录响应解析失败: %v", err)
	}
	if lr.AccessToken == "" {
		return newError(CodeAuth, "登录未返回 access_token")
	}
	s.setTokens(lr.AccessToken, lr.RefreshToken, lr.ExpiresIn)
	return nil
}

func (s *Session) refreshToken(ctx context.Context) error {
	s.mu.Lock()
	refresh := s.refresh
	s.mu.Unlock()
	if refresh == "" {
		return newError(CodeAuth, "缺少 refresh_token")
	}
	body := map[string]string{"refresh_token": refresh}
	res, err := s.doJSON(ctx, http.MethodPost, "/api/v1/auth/refresh", nil, body, nil, false)
	if err != nil {
		return err
	}
	var lr loginResp
	if err := json.Unmarshal(res, &lr); err != nil {
		return newError(CodeProtocol, "刷新响应解析失败: %v", err)
	}
	if lr.AccessToken == "" {
		return newError(CodeAuth, "刷新未返回 access_token")
	}
	s.setTokens(lr.AccessToken, lr.RefreshToken, lr.ExpiresIn)
	return nil
}

// reauthenticate 先尝试 refresh_token，失败后回退用户名/密码登录。
func (s *Session) reauthenticate(ctx context.Context) error {
	if err := s.refreshToken(ctx); err == nil {
		return nil
	}
	return s.login(ctx)
}

func (s *Session) setTokens(access, refresh string, expiresIn int64) {
	s.mu.Lock()
	s.access = access
	if refresh != "" {
		s.refresh = refresh
	}
	expiresAt := int64(0)
	if expiresIn > 0 {
		expiresAt = time.Now().Unix() + expiresIn
	}
	s.expiresAt = expiresAt
	rt := s.refresh
	s.mu.Unlock()
	s.emit(event{
		Type:         "token",
		AccessToken:  access,
		RefreshToken: rt,
		ExpiresAt:    expiresAt,
	})
}

func (s *Session) token() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.access
}

/* ------------------------------------------------------------------ */
/* HTTP                                                                */
/* ------------------------------------------------------------------ */

// doJSON 执行请求并返回响应体；retryAuth=true 时 401 自动刷新并重放一次。
func (s *Session) doJSON(
	ctx context.Context,
	method, path string,
	q url.Values,
	body any,
	target any,
	retryAuth bool,
) ([]byte, error) {
	raw, status, err := s.do(ctx, method, path, q, body)
	if err != nil {
		return nil, err
	}
	if status == http.StatusUnauthorized && retryAuth {
		// 先 refresh；refresh token 失效/缺失时回退账号密码登录一次。
		if err := s.reauthenticate(ctx); err != nil {
			return nil, err
		}
		raw, status, err = s.do(ctx, method, path, q, body)
		if err != nil {
			return nil, err
		}
	}
	if status < 200 || status >= 300 {
		return nil, statusError(status, raw)
	}
	if target != nil {
		if err := json.Unmarshal(raw, target); err != nil {
			return nil, newError(CodeProtocol, "响应解析失败: %v", err)
		}
	}
	return raw, nil
}

func (s *Session) do(
	ctx context.Context,
	method, path string,
	q url.Values,
	body any,
) ([]byte, int, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, 0, newError(CodeProtocol, "请求编码失败: %v", err)
		}
		reader = bytes.NewReader(b)
	}
	u := s.base + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, reader)
	if err != nil {
		return nil, 0, newError(CodeProtocol, "请求构造失败: %v", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ArchoeraMusic")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if tok := s.token(); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := s.http.Do(req)
	if err != nil {
		return nil, 0, transportError(err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if err != nil {
		return nil, 0, transportError(err)
	}
	return raw, res.StatusCode, nil
}

func transportError(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return newError(CodeTimeout, "请求超时")
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return newError(CodeTimeout, "请求超时: %v", err)
	}
	var ue *url.Error
	if errors.As(err, &ue) && ue.Timeout() {
		return newError(CodeTimeout, "请求超时: %v", err)
	}
	return newError(CodeNetwork, "网络请求失败: %v", err)
}

func statusError(status int, body []byte) error {
	msg := strings.TrimSpace(string(body))
	var e struct {
		Error   string `json:"error"`
		Detail  string `json:"detail"`
		Message string `json:"message"`
	}
	if json.Unmarshal(body, &e) == nil {
		switch {
		case e.Error != "" && e.Detail != "":
			msg = e.Error + ": " + e.Detail
		case e.Error != "":
			msg = e.Error
		case e.Message != "":
			msg = e.Message
		}
	}
	switch status {
	case http.StatusUnauthorized, http.StatusForbidden:
		return newError(CodeAuth, "鉴权失败 (HTTP %d)", status)
	case http.StatusNotFound:
		return newError(CodeNotFound, "资源不存在 (HTTP 404)")
	}
	if msg == "" {
		msg = fmt.Sprintf("HTTP %d", status)
	}
	return newError(CodeProtocol, "%s", msg)
}

/* ------------------------------------------------------------------ */
/* 目录 / 播放 / 歌词                                                   */
/* ------------------------------------------------------------------ */

func (s *Session) fetchVersion(ctx context.Context) (string, error) {
	var v struct {
		Version string `json:"version"`
		Full    string `json:"full"`
	}
	_, err := s.doJSON(ctx, http.MethodGet, "/api/v1/version", nil, nil, &v, false)
	if err != nil {
		return "", err
	}
	if v.Version == "" {
		return v.Full, nil
	}
	return v.Version, nil
}

type listParams struct {
	Offset  int    `json:"offset"`
	Limit   int    `json:"limit"`
	Sort    string `json:"sort"`
	Order   string `json:"order"`
	Keyword string `json:"keyword"`
	Album   string `json:"album"`
	Artist  string `json:"artist"`
	Genre   string `json:"genre"`
}

type song struct {
	ID         int64   `json:"id"`
	Title      string  `json:"title"`
	Artist     string  `json:"artist"`
	Album      string  `json:"album"`
	Year       int     `json:"year"`
	Genre      string  `json:"genre"`
	Duration   float64 `json:"duration"`
	FileSize   int64   `json:"file_size"`
	Format     string  `json:"format"`
	BitRate    int     `json:"bit_rate"`
	SampleRate int     `json:"sample_rate"`
	CoverURL   string  `json:"cover_url"`
}

type songPage struct {
	Songs  []song `json:"songs"`
	Total  int64  `json:"total"`
	Limit  int    `json:"limit"`
	Offset int    `json:"offset"`
}

func (s *Session) listSongs(ctx context.Context, raw json.RawMessage) (any, error) {
	var p listParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, newError(CodeProtocol, "参数解析失败: %v", err)
		}
	}
	q := url.Values{}
	if p.Limit > 0 {
		q.Set("limit", strconv.Itoa(p.Limit))
	}
	if p.Offset > 0 {
		q.Set("offset", strconv.Itoa(p.Offset))
	}
	if p.Sort != "" {
		q.Set("sort", p.Sort)
	}
	if p.Order != "" {
		q.Set("order", p.Order)
	}
	if p.Keyword != "" {
		q.Set("keyword", p.Keyword)
	}
	if p.Album != "" {
		q.Set("album", p.Album)
	}
	if p.Artist != "" {
		q.Set("artist", p.Artist)
	}
	if p.Genre != "" {
		q.Set("genre", p.Genre)
	}
	var page songPage
	if _, err := s.doJSON(ctx, http.MethodGet, "/api/v1/songs", q, nil, &page, true); err != nil {
		return nil, err
	}
	return map[string]any{"total": page.Total, "limit": page.Limit, "offset": page.Offset, "songs": page.Songs}, nil
}

type facet struct {
	Value    string `json:"value"`
	Count    int64  `json:"count"`
	CoverURL string `json:"cover_url"`
	CoverID  int64  `json:"-"`
}

type facetPage struct {
	Field  string  `json:"field"`
	Facets []facet `json:"facets"`
	Total  int64   `json:"total"`
	Limit  int     `json:"limit"`
	Offset int     `json:"offset"`
}

func (s *Session) listFacets(ctx context.Context, field string, raw json.RawMessage) (any, error) {
	var p listParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, newError(CodeProtocol, "参数解析失败: %v", err)
		}
	}
	q := url.Values{"field": {field}}
	if p.Limit > 0 {
		q.Set("limit", strconv.Itoa(p.Limit))
	}
	if p.Offset > 0 {
		q.Set("offset", strconv.Itoa(p.Offset))
	}
	if p.Sort != "" {
		q.Set("sort", p.Sort)
	}
	if p.Order != "" {
		q.Set("order", p.Order)
	}
	if p.Keyword != "" {
		q.Set("keyword", p.Keyword)
	}
	var page facetPage
	if _, err := s.doJSON(ctx, http.MethodGet, "/api/v1/songs/facets", q, nil, &page, true); err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(page.Facets))
	for _, f := range page.Facets {
		out = append(out, map[string]any{
			"value":       f.Value,
			"count":       f.Count,
			"coverSongId": coverSongID(f.CoverURL),
		})
	}
	return map[string]any{"total": page.Total, "limit": page.Limit, "offset": page.Offset, "facets": out}, nil
}

// coverSongID 从 `/api/v1/songs/{id}/cover` 提取 id；非该形态返回 0。
func coverSongID(raw string) int64 {
	const prefix = "/api/v1/songs/"
	const suffix = "/cover"
	if !strings.HasPrefix(raw, prefix) || !strings.HasSuffix(raw, suffix) {
		return 0
	}
	id, err := strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(raw, prefix), suffix), 10, 64)
	if err != nil {
		return 0
	}
	return id
}

type playlist struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	CoverURL    string `json:"cover_url"`
	SongCount   int    `json:"song_count"`
}

type playlistPage struct {
	Playlists []playlist `json:"playlists"`
	Total     int64      `json:"total"`
}

func (s *Session) listPlaylists(ctx context.Context, raw json.RawMessage) (any, error) {
	var p listParams
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &p)
	}
	q := url.Values{}
	if p.Limit > 0 {
		q.Set("limit", strconv.Itoa(p.Limit))
	}
	if p.Offset > 0 {
		q.Set("offset", strconv.Itoa(p.Offset))
	}
	var page playlistPage
	if _, err := s.doJSON(ctx, http.MethodGet, "/api/v1/playlists", q, nil, &page, true); err != nil {
		return nil, err
	}
	return map[string]any{"total": page.Total, "playlists": page.Playlists}, nil
}

func (s *Session) playlistSongs(ctx context.Context, raw json.RawMessage) (any, error) {
	var p struct {
		PlaylistID int64  `json:"playlistId"`
		Offset     int    `json:"offset"`
		Limit      int    `json:"limit"`
		Sort       string `json:"sort"`
		Order      string `json:"order"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, newError(CodeProtocol, "参数解析失败: %v", err)
		}
	}
	if p.PlaylistID <= 0 {
		return nil, newError(CodeProtocol, "缺少 playlistId")
	}
	q := url.Values{}
	if p.Limit > 0 {
		q.Set("limit", strconv.Itoa(p.Limit))
	}
	if p.Offset > 0 {
		q.Set("offset", strconv.Itoa(p.Offset))
	}
	if p.Sort != "" {
		q.Set("sort", p.Sort)
	}
	if p.Order != "" {
		q.Set("order", p.Order)
	}
	var page songPage
	path := fmt.Sprintf("/api/v1/playlists/%d/songs", p.PlaylistID)
	if _, err := s.doJSON(ctx, http.MethodGet, path, q, nil, &page, true); err != nil {
		return nil, err
	}
	return map[string]any{"total": page.Total, "songs": page.Songs}, nil
}

func (s *Session) streamURL(raw json.RawMessage) (any, error) {
	var p struct {
		SongID  int64  `json:"songId"`
		Quality string `json:"quality"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, newError(CodeProtocol, "参数解析失败: %v", err)
		}
	}
	if p.SongID <= 0 {
		return nil, newError(CodeProtocol, "缺少 songId")
	}
	q := url.Values{}
	switch p.Quality {
	case "high":
		q.Set("format", "mp3")
		q.Set("quality", "320")
	case "medium":
		q.Set("format", "mp3")
		q.Set("quality", "192")
	case "low":
		q.Set("format", "mp3")
		q.Set("quality", "128")
	}
	q.Set("access_token", s.token())
	return map[string]any{"url": s.base + fmt.Sprintf("/api/v1/songs/%d/play?%s", p.SongID, q.Encode())}, nil
}

type lyricPayload struct {
	Lyric   string `json:"lyric"`
	Tlyric  string `json:"tlyric"`
	Rlyric  string `json:"rlyric"`
	Lxlyric string `json:"lxlyric"`
}

func (s *Session) lyrics(ctx context.Context, raw json.RawMessage) (any, error) {
	var p struct {
		SongID int64 `json:"songId"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, newError(CodeProtocol, "参数解析失败: %v", err)
		}
	}
	if p.SongID <= 0 {
		return nil, newError(CodeProtocol, "缺少 songId")
	}
	var lp lyricPayload
	_, err := s.doJSON(ctx, http.MethodGet,
		fmt.Sprintf("/api/v1/songs/%d/lyric", p.SongID), nil, nil, &lp, true)
	if err != nil {
		var e *Error
		if errors.As(err, &e) && e.Code == CodeNotFound {
			return map[string]any{}, nil
		}
		return nil, err
	}
	return lp, nil
}

/* ------------------------------------------------------------------ */
/* 封面                                                                */
/* ------------------------------------------------------------------ */

// cover 拉取封面并写入封面缓存，返回文件路径（已存在则直接返回）。
func (s *Session) cover(ctx context.Context, raw json.RawMessage) (any, error) {
	var p struct {
		Kind string `json:"kind"`
		ID   int64  `json:"id"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, newError(CodeProtocol, "参数解析失败: %v", err)
		}
	}
	if p.ID <= 0 {
		return nil, newError(CodeProtocol, "缺少封面 id")
	}
	var path string
	switch p.Kind {
	case "song":
		path = fmt.Sprintf("/api/v1/songs/%d/cover", p.ID)
	case "playlist":
		path = fmt.Sprintf("/api/v1/playlists/%d/cover", p.ID)
	default:
		return nil, newError(CodeProtocol, "不支持的封面类型 %q", p.Kind)
	}

	dir := filepath.Join(s.cfg.CoverCacheDir, s.cfg.ServerID)
	target := filepath.Join(dir, fmt.Sprintf("%s-%d.img", p.Kind, p.ID))
	if st, err := os.Stat(target); err == nil && st.Size() > 0 {
		return map[string]any{"path": target, "cached": true}, nil
	}

	data, ct, err := s.fetchBinary(ctx, path)
	if err != nil {
		var e *Error
		if errors.As(err, &e) && e.Code == CodeAuth {
			if rerr := s.reauthenticate(ctx); rerr == nil {
				data, ct, err = s.fetchBinary(ctx, path)
			}
		}
		if err != nil {
			return nil, err
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, newError(CodeProtocol, "创建封面缓存目录失败: %v", err)
	}
	tmp, err := os.CreateTemp(dir, ".cover-*")
	if err != nil {
		return nil, newError(CodeProtocol, "创建封面缓存文件失败: %v", err)
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return nil, newError(CodeProtocol, "写入封面缓存失败: %v", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return nil, newError(CodeProtocol, "关闭封面缓存失败: %v", err)
	}
	if err := os.Rename(tmpName, target); err != nil {
		_ = os.Remove(tmpName)
		return nil, newError(CodeProtocol, "提交封面缓存失败: %v", err)
	}
	return map[string]any{"path": target, "contentType": ct, "bytes": len(data), "cached": false}, nil
}

func (s *Session) fetchBinary(ctx context.Context, path string) ([]byte, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.base+path, nil)
	if err != nil {
		return nil, "", newError(CodeProtocol, "请求构造失败: %v", err)
	}
	req.Header.Set("User-Agent", "ArchoeraMusic")
	if tok := s.token(); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := s.http.Do(req)
	if err != nil {
		return nil, "", transportError(err)
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		return nil, "", statusError(res.StatusCode, raw)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, 8<<20))
	if err != nil {
		return nil, "", transportError(err)
	}
	return data, res.Header.Get("Content-Type"), nil
}
