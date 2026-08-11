package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/betastudio2/archoera-subsonic/config"
	"github.com/betastudio2/archoera-subsonic/crypto"
	"github.com/betastudio2/archoera-subsonic/model"
)

// 数据存储拆分（独立加密库）：
//   - mediaPool 媒体库（library.db）：tracks 曲目元数据，scanner 直写 / 服务端直读 / 前端读
//   - userPool  用户库（user.db）：subsonic_*（users/starred/playlists/shares），
//     敏感字段（密码）以 enc:v1 AES-256-GCM 字段级加密落盘
//
// 两个库均独立 WAL + 单连接，互不干扰；旧版 subsonic_* 数据经 MigrateUserDB 自动迁移。
var (
	mediaPool *sql.DB
	userPool  *sql.DB
)

func defaultDataDir() string {
	if dir := config.DataDir(); dir != "" {
		return dir
	}
	wd, err := os.Getwd()
	if err != nil {
		return filepath.Join(".", "data")
	}
	return filepath.Join(wd, "data")
}

// Open 打开媒体库（tracks）
//
// 使用 rw（读写）模式而非 ro（只读）：
// - ro 模式下无法设置 WAL journal mode，导致 TS 写进程阻塞 Go 读操作
// - rw 模式配合 busy_timeout，TS 写时 Go 读会等待而非挂死
func Open(dbPath string) error {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return fmt.Errorf("mkdir db dir: %w", err)
	}
	// mode=rwc（读写 + 缺文件时创建）：standalone/Docker 冷启动无库文件时自举。
	// ro 模式下无法设置 WAL journal mode，导致 TS 写进程阻塞 Go 读操作；
	// rw 模式配合 busy_timeout，TS 写时 Go 读会等待而非挂死。
	dsn := fmt.Sprintf("file:%s?mode=rwc&_journal_mode=WAL&_busy_timeout=10000", dbPath)
	var err error
	mediaPool, err = sql.Open("sqlite", dsn)
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	// 单连接避免 WAL 读写竞争
	mediaPool.SetMaxOpenConns(1)
	return mediaPool.Ping()
}

// DefaultUserDBPath 返回用户库默认路径（与媒体库同目录，独立加密库）
func DefaultUserDBPath() string {
	return filepath.Join(defaultDataDir(), "database", "user.db")
}

// OpenUserDB 打开用户库（subsonic_*：users/starred/playlists/shares）
//
// 与媒体库同样使用 rw + WAL + busy_timeout：桌面端 Dart（SubsonicAdmin）
// 与 Go 服务端会同时直读直写本库，WAL 保证读写互不阻塞。
func OpenUserDB(userDBPath string) error {
	if err := os.MkdirAll(filepath.Dir(userDBPath), 0o755); err != nil {
		return fmt.Errorf("mkdir user db dir: %w", err)
	}
	dsn := fmt.Sprintf("file:%s?mode=rwc&_journal_mode=WAL&_busy_timeout=10000", userDBPath)
	var err error
	userPool, err = sql.Open("sqlite", dsn)
	if err != nil {
		return fmt.Errorf("open user db: %w", err)
	}
	userPool.SetMaxOpenConns(1)
	return userPool.Ping()
}

// Close 关闭媒体库与用户库
func Close() {
	if mediaPool != nil {
		mediaPool.Close()
	}
	if userPool != nil {
		userPool.Close()
	}
}

// DefaultDBPath 返回默认媒体库路径
func DefaultDBPath() string {
	return filepath.Join(defaultDataDir(), "database", "library.db")
}

// EnsureTables 确保曲库与 Subsonic 表结构存在（与 Dart 侧 schema 对齐）。
// 曲库表建在媒体库（library.db）；subsonic_* 用户数据表建在独立用户库（user.db）。
// 桌面端由 Dart 建表；standalone/Docker 由服务端自建，保证两种模式自举。
func EnsureTables() error {
	mediaStmts := []string{
		`CREATE TABLE IF NOT EXISTS tracks (
			id TEXT PRIMARY KEY,
			path TEXT NOT NULL UNIQUE,
			title TEXT NOT NULL,
			track INTEGER,
			artists TEXT NOT NULL DEFAULT '[]',
			album TEXT,
			duration INTEGER NOT NULL,
			cover TEXT,
			codec TEXT,
			sample_rate INTEGER,
			bit_rate INTEGER,
			channels INTEGER,
			bits_per_sample INTEGER,
			file_size INTEGER NOT NULL,
			file_mtime INTEGER,
			file_ctime INTEGER,
			scanned_at INTEGER NOT NULL,
			lyrics TEXT,
			genre TEXT
		)`,
	}
	userStmts := []string{
		`CREATE TABLE IF NOT EXISTS subsonic_users (
			id TEXT PRIMARY KEY,
			username TEXT NOT NULL UNIQUE,
			password_cipher TEXT NOT NULL,
			is_admin INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS subsonic_starred (
			user_id TEXT NOT NULL,
			target_id TEXT NOT NULL,
			target_type TEXT NOT NULL,
			starred_at INTEGER NOT NULL,
			PRIMARY KEY (user_id, target_id, target_type)
		)`,
		`CREATE TABLE IF NOT EXISTS subsonic_playlists (
			id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL,
			name TEXT NOT NULL,
			comment TEXT,
			public INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS subsonic_playlist_entries (
			playlist_id TEXT NOT NULL,
			track_id TEXT NOT NULL,
			position INTEGER NOT NULL,
			PRIMARY KEY (playlist_id, position)
		)`,
		`CREATE TABLE IF NOT EXISTS subsonic_shares (
			id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL,
			name TEXT NOT NULL,
			description TEXT,
			url TEXT NOT NULL,
			expires_at INTEGER,
			created_at INTEGER NOT NULL,
			visit_count INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS subsonic_share_entries (
			share_id TEXT NOT NULL,
			track_id TEXT NOT NULL,
			PRIMARY KEY (share_id, track_id)
		)`,
	}
	for _, s := range mediaStmts {
		if _, err := mediaPool.Exec(s); err != nil {
			return fmt.Errorf("create media table: %w", err)
		}
	}
	for _, s := range userStmts {
		if _, err := userPool.Exec(s); err != nil {
			return fmt.Errorf("create user table: %w", err)
		}
	}
	return nil
}

/* ------------------------------------------------------------------ */
/* 旧库迁移（library.db → user.db）                                    */
/* ------------------------------------------------------------------ */

// MigrateUserDB 将旧版 library.db 中的 subsonic_* 用户数据迁移到独立用户库（user.db）。
// 幂等：
//   - 用户库已有数据（已迁移/全新安装）→ 跳过
//   - 媒体库无 subsonic_* 表（全新安装/已迁移）→ 跳过
//   - 媒体库存在旧 subsonic_* 数据 → 复制到用户库后删除旧表（避免双数据源）
//
// 需在 Open + OpenUserDB + EnsureTables 之后调用。
func MigrateUserDB() error {
	// 用户库已有数据 → 已迁移或全新，跳过
	var userCount int
	if err := userPool.QueryRow("SELECT COUNT(*) FROM subsonic_users").Scan(&userCount); err != nil {
		return fmt.Errorf("check user db: %w", err)
	}
	if userCount > 0 {
		return nil
	}
	// 媒体库无 subsonic 表 → 无需迁移
	var legacyTables int
	if err := mediaPool.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE 'subsonic_%'`,
	).Scan(&legacyTables); err != nil {
		return fmt.Errorf("check library subsonic tables: %w", err)
	}
	if legacyTables == 0 {
		return nil
	}
	if err := copyLegacyUsers(); err != nil {
		return err
	}
	if err := copyLegacyStarred(); err != nil {
		return err
	}
	if err := copyLegacyPlaylists(); err != nil {
		return err
	}
	if err := copyLegacyPlaylistEntries(); err != nil {
		return err
	}
	if err := copyLegacyShares(); err != nil {
		return err
	}
	if err := copyLegacyShareEntries(); err != nil {
		return err
	}
	// 迁移成功后删除媒体库中的旧表
	for _, t := range []string{
		"subsonic_users", "subsonic_starred", "subsonic_playlists",
		"subsonic_playlist_entries", "subsonic_shares", "subsonic_share_entries",
	} {
		if _, err := mediaPool.Exec("DROP TABLE IF EXISTS " + t); err != nil {
			return fmt.Errorf("drop legacy table %s: %w", t, err)
		}
	}
	return nil
}

func copyLegacyUsers() error {
	rows, err := mediaPool.Query(
		"SELECT id, username, password_cipher, is_admin, created_at FROM subsonic_users")
	if err != nil {
		return fmt.Errorf("read legacy users: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, username, cipher string
		var isAdmin int
		var createdAt int64
		if err := rows.Scan(&id, &username, &cipher, &isAdmin, &createdAt); err != nil {
			return fmt.Errorf("scan legacy user: %w", err)
		}
		if _, err := userPool.Exec(
			"INSERT INTO subsonic_users (id, username, password_cipher, is_admin, created_at) VALUES (?, ?, ?, ?, ?)",
			id, username, cipher, isAdmin, createdAt,
		); err != nil {
			return fmt.Errorf("copy legacy user: %w", err)
		}
	}
	return rows.Err()
}

func copyLegacyStarred() error {
	rows, err := mediaPool.Query(
		"SELECT user_id, target_id, target_type, starred_at FROM subsonic_starred")
	if err != nil {
		return fmt.Errorf("read legacy starred: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var userID, targetID, targetType string
		var starredAt int64
		if err := rows.Scan(&userID, &targetID, &targetType, &starredAt); err != nil {
			return fmt.Errorf("scan legacy starred: %w", err)
		}
		if _, err := userPool.Exec(
			"INSERT INTO subsonic_starred (user_id, target_id, target_type, starred_at) VALUES (?, ?, ?, ?)",
			userID, targetID, targetType, starredAt,
		); err != nil {
			return fmt.Errorf("copy legacy starred: %w", err)
		}
	}
	return rows.Err()
}

func copyLegacyPlaylists() error {
	rows, err := mediaPool.Query(
		"SELECT id, user_id, name, comment, public, created_at, updated_at FROM subsonic_playlists")
	if err != nil {
		return fmt.Errorf("read legacy playlists: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, userID, name string
		var comment sql.NullString
		var isPublic int
		var createdAt, updatedAt int64
		if err := rows.Scan(&id, &userID, &name, &comment, &isPublic, &createdAt, &updatedAt); err != nil {
			return fmt.Errorf("scan legacy playlist: %w", err)
		}
		if _, err := userPool.Exec(
			"INSERT INTO subsonic_playlists (id, user_id, name, comment, public, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
			id, userID, name, comment, isPublic, createdAt, updatedAt,
		); err != nil {
			return fmt.Errorf("copy legacy playlist: %w", err)
		}
	}
	return rows.Err()
}

func copyLegacyPlaylistEntries() error {
	rows, err := mediaPool.Query(
		"SELECT playlist_id, track_id, position FROM subsonic_playlist_entries")
	if err != nil {
		return fmt.Errorf("read legacy playlist entries: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var playlistID, trackID string
		var position int
		if err := rows.Scan(&playlistID, &trackID, &position); err != nil {
			return fmt.Errorf("scan legacy playlist entry: %w", err)
		}
		if _, err := userPool.Exec(
			"INSERT INTO subsonic_playlist_entries (playlist_id, track_id, position) VALUES (?, ?, ?)",
			playlistID, trackID, position,
		); err != nil {
			return fmt.Errorf("copy legacy playlist entry: %w", err)
		}
	}
	return rows.Err()
}

func copyLegacyShares() error {
	rows, err := mediaPool.Query(
		"SELECT id, user_id, name, description, url, expires_at, created_at, visit_count FROM subsonic_shares")
	if err != nil {
		return fmt.Errorf("read legacy shares: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, userID, name, url string
		var description sql.NullString
		var expiresAt sql.NullInt64
		var createdAt, visitCount int64
		if err := rows.Scan(&id, &userID, &name, &description, &url, &expiresAt, &createdAt, &visitCount); err != nil {
			return fmt.Errorf("scan legacy share: %w", err)
		}
		if _, err := userPool.Exec(
			"INSERT INTO subsonic_shares (id, user_id, name, description, url, expires_at, created_at, visit_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
			id, userID, name, description, url, expiresAt, createdAt, visitCount,
		); err != nil {
			return fmt.Errorf("copy legacy share: %w", err)
		}
	}
	return rows.Err()
}

func copyLegacyShareEntries() error {
	rows, err := mediaPool.Query(
		"SELECT share_id, track_id FROM subsonic_share_entries")
	if err != nil {
		return fmt.Errorf("read legacy share entries: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var shareID, trackID string
		if err := rows.Scan(&shareID, &trackID); err != nil {
			return fmt.Errorf("scan legacy share entry: %w", err)
		}
		if _, err := userPool.Exec(
			"INSERT INTO subsonic_share_entries (share_id, track_id) VALUES (?, ?)",
			shareID, trackID,
		); err != nil {
			return fmt.Errorf("copy legacy share entry: %w", err)
		}
	}
	return rows.Err()
}

// CoverCacheDir 返回封面缓存目录
func CoverCacheDir() string {
	return filepath.Join(defaultDataDir(), "cache", "covers")
}

// MusicDir 返回音乐根目录
func MusicDir() string {
	if d := config.MusicDir(); d != "" {
		return d
	}
	return filepath.Join(defaultDataDir(), "music")
}

/* ------------------------------------------------------------------ */
/* 用户（user.db）                                                     */
/* ------------------------------------------------------------------ */

// GetUserByUsername 按用户名查找（含密码解密）
func GetUserByUsername(username string) (*model.SubsonicUser, error) {
	var u model.SubsonicUser
	var passwordCipher string
	var isAdmin int
	err := userPool.QueryRow(
		"SELECT id, username, password_cipher, is_admin, created_at FROM subsonic_users WHERE username = ?",
		username,
	).Scan(&u.ID, &u.Username, &passwordCipher, &isAdmin, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	u.IsAdmin = isAdmin == 1
	plain, err := crypto.DecryptString(passwordCipher)
	if err != nil {
		return nil, fmt.Errorf("decrypt password: %w", err)
	}
	u.Password = plain
	return &u, nil
}

// CreateUser 创建用户（密码加密落盘）；同名用户已存在时返回错误。
// 供 standalone/Docker 入口引导管理员使用（桌面端由 Dart 侧 SubsonicAdmin 创建）。
func CreateUser(id, username, password string, isAdmin bool) error {
	existing, err := GetUserByUsername(username)
	if err == nil && existing != nil {
		return fmt.Errorf("username already exists: %s", username)
	}
	cipher, err := crypto.EncryptString(password)
	if err != nil {
		return fmt.Errorf("encrypt password: %w", err)
	}
	admin := 0
	if isAdmin {
		admin = 1
	}
	_, err = userPool.Exec(
		"INSERT INTO subsonic_users (id, username, password_cipher, is_admin, created_at) VALUES (?, ?, ?, ?, ?)",
		id, username, cipher, admin, nowMs(),
	)
	return err
}

// ListUsers 列出全部用户
func ListUsers() ([]model.SubsonicUser, error) {
	rows, err := userPool.Query("SELECT id, username, password_cipher, is_admin, created_at FROM subsonic_users ORDER BY created_at")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []model.SubsonicUser
	for rows.Next() {
		var u model.SubsonicUser
		var passwordCipher string
		var isAdmin int
		if err := rows.Scan(&u.ID, &u.Username, &passwordCipher, &isAdmin, &u.CreatedAt); err != nil {
			return nil, err
		}
		u.IsAdmin = isAdmin == 1
		plain, err := crypto.DecryptString(passwordCipher)
		if err == nil {
			u.Password = plain
		}
		users = append(users, u)
	}
	return users, nil
}

/* ------------------------------------------------------------------ */
/* 曲目查询（library.db）                                              */
/* ------------------------------------------------------------------ */

// scanSQLiteFloat64 兼容 SQLite 动态类型：float64 → int64
// SQLite 可能将整数存为 float64（例如大时间戳），Go sql.NullInt64 无法直接 Scan。
func scanSQLiteFloat64(val any) int64 {
	switch v := val.(type) {
	case int64:
		return v
	case float64:
		return int64(v)
	case nil:
		return 0
	}
	return 0
}

func scanTrack(row interface{ Scan(...any) error }) (model.Track, error) {
	var t model.Track
	var rawFileMtime, rawFileCtime any
	var rawSampleRate, rawBitRate, rawChannels, rawBitsPerSample any
	err := row.Scan(
		&t.ID, &t.Path, &t.Title, &t.TrackNo, &t.ArtistsJSON, &t.AlbumJSON,
		&t.Duration, &t.Cover, &t.Codec, &rawSampleRate, &rawBitRate,
		&rawChannels, &rawBitsPerSample, &t.FileSize, &rawFileMtime, &rawFileCtime,
		&t.ScannedAt, &t.Lyrics, &t.Genre,
	)
	if err != nil {
		return t, err
	}
	if rawSampleRate != nil {
		t.SampleRate = sql.NullInt64{Int64: scanSQLiteFloat64(rawSampleRate), Valid: true}
	}
	if rawBitRate != nil {
		t.BitRate = sql.NullInt64{Int64: scanSQLiteFloat64(rawBitRate), Valid: true}
	}
	if rawChannels != nil {
		t.Channels = sql.NullInt64{Int64: scanSQLiteFloat64(rawChannels), Valid: true}
	}
	if rawBitsPerSample != nil {
		t.BitsPerSample = sql.NullInt64{Int64: scanSQLiteFloat64(rawBitsPerSample), Valid: true}
	}
	if rawFileMtime != nil {
		t.FileMtime = sql.NullInt64{Int64: scanSQLiteFloat64(rawFileMtime), Valid: true}
	}
	if rawFileCtime != nil {
		t.FileCtime = sql.NullInt64{Int64: scanSQLiteFloat64(rawFileCtime), Valid: true}
	}
	return t, nil
}

const trackColumns = `id, path, title, track, artists, album, duration, cover,
	codec, sample_rate, bit_rate, channels, bits_per_sample,
	file_size, file_mtime, file_ctime, scanned_at, lyrics, genre`

// GetAllTracks 获取全部曲目
func GetAllTracks() ([]model.Track, error) {
	rows, err := mediaPool.Query("SELECT " + trackColumns + " FROM tracks")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// GetTracksPaginated 分页获取曲目（LIMIT + OFFSET）
func GetTracksPaginated(limit, offset int) ([]model.Track, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := mediaPool.Query("SELECT "+trackColumns+" FROM tracks ORDER BY id LIMIT ? OFFSET ?", limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// GetTrackCount 返回曲目总数
func GetTrackCount() (int, error) {
	var count int
	err := mediaPool.QueryRow("SELECT COUNT(*) FROM tracks").Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}

// RemoveDuplicatePaths 移除 path 列的重复行，保留 rowid 最小的那条
// 源于 C# 扫描器直接写入与 Node.js watcher HTTP 写入共用同一 SQLite 时，
// 可能因蓝图时序产生同 path 不同 id 的行。
func RemoveDuplicatePaths() (int, error) {
	// 先统计
	var dupCount int
	err := mediaPool.QueryRow(`
		SELECT COUNT(*) - COUNT(DISTINCT path) FROM tracks
	`).Scan(&dupCount)
	if err != nil {
		return 0, err
	}
	if dupCount == 0 {
		return 0, nil
	}
	// 删除 path 重复的行，保留 rowid 最小的
	res, err := mediaPool.Exec(`
		DELETE FROM tracks WHERE rowid NOT IN (
			SELECT MIN(rowid) FROM tracks GROUP BY path
		)
	`)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// GetTrackByID 按 ID 获取单曲
func GetTrackByID(id string) (*model.Track, error) {
	row := mediaPool.QueryRow("SELECT "+trackColumns+" FROM tracks WHERE id = ?", id)
	t, err := scanTrack(row)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// GetTracksByIDs 批量按 ID 获取
func GetTracksByIDs(ids []string) ([]model.Track, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	placeholders := ""
	args := make([]any, len(ids))
	for i, id := range ids {
		if i > 0 {
			placeholders += ","
		}
		placeholders += "?"
		args[i] = id
	}
	rows, err := mediaPool.Query("SELECT "+trackColumns+" FROM tracks WHERE id IN ("+placeholders+")", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// GetRandomTracks 随机取 N 首
func GetRandomTracks(limit int) ([]model.Track, error) {
	if limit <= 0 {
		return nil, nil
	}
	if limit > 500 {
		limit = 500
	}
	rows, err := mediaPool.Query("SELECT "+trackColumns+" FROM tracks ORDER BY RANDOM() LIMIT ?", limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// SearchTracks 模糊搜索
//
// artists/album 列为 JSON，INSTR 做字节级搜索兼容多字节 UTF-8。
func SearchTracks(query string) ([]model.Track, error) {
	pattern := "%" + query + "%"
	rows, err := mediaPool.Query(
		`SELECT `+trackColumns+` FROM tracks
		 WHERE title LIKE ? ESCAPE '\'
		    OR INSTR(album, ?) > 0
		    OR INSTR(artists, ?) > 0`,
		pattern, query, query,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// GetTrackLyrics 取内嵌歌词
func GetTrackLyrics(id string) (string, error) {
	var lyrics sql.NullString
	err := mediaPool.QueryRow("SELECT lyrics FROM tracks WHERE id = ?", id).Scan(&lyrics)
	if err != nil {
		return "", err
	}
	if lyrics.Valid {
		return lyrics.String, nil
	}
	return "", nil
}

/* ------------------------------------------------------------------ */
/* 流派                                                                */
/* ------------------------------------------------------------------ */

// GenreSummary 流派摘要
type GenreSummary struct {
	Name       string
	TrackCount int
	AlbumCount int
}

// GetGenres 聚合 tracks.genre 列，返回非空流派及其歌曲/专辑数
// genre 列可能存储单个流派或以 ; / , / / 分隔的多个流派，做拆分处理
func GetGenres() ([]GenreSummary, error) {
	rows, err := mediaPool.Query(`
		SELECT genre, COUNT(*) AS track_count,
		       COUNT(DISTINCT json_extract(album, '$.name')) AS album_count
		FROM tracks
		WHERE genre IS NOT NULL AND TRIM(genre) != ''
		GROUP BY genre`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// 由于 genre 列可能含多个流派，先聚合原始值再拆分
	rawMap := make(map[string]*GenreSummary)
	for rows.Next() {
		var g string
		var tc, ac int
		if err := rows.Scan(&g, &tc, &ac); err != nil {
			return nil, err
		}
		for _, name := range splitGenres(g) {
			name = strings.TrimSpace(name)
			if name == "" {
				continue
			}
			if s, ok := rawMap[name]; ok {
				s.TrackCount += tc
				s.AlbumCount += ac
			} else {
				rawMap[name] = &GenreSummary{Name: name, TrackCount: tc, AlbumCount: ac}
			}
		}
	}

	list := make([]GenreSummary, 0, len(rawMap))
	for _, s := range rawMap {
		list = append(list, *s)
	}
	// 按歌曲数降序
	sort.Slice(list, func(i, j int) bool {
		return list[i].TrackCount > list[j].TrackCount
	})
	return list, nil
}

// splitGenres 拆分流派字符串（支持 ; , / 作为分隔符）
func splitGenres(s string) []string {
	out := []string{}
	s = strings.ReplaceAll(s, ";", "|")
	s = strings.ReplaceAll(s, ",", "|")
	s = strings.ReplaceAll(s, "/", "|")
	for _, p := range strings.Split(s, "|") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// GetTracksByGenre 按 genre 模糊匹配获取曲目（支持分页）
func GetTracksByGenre(genre string, limit, offset int) ([]model.Track, error) {
	if limit <= 0 {
		limit = 10
	}
	if limit > 500 {
		limit = 500
	}
	if offset < 0 {
		offset = 0
	}
	pattern := "%" + genre + "%"
	rows, err := mediaPool.Query(
		"SELECT "+trackColumns+" FROM tracks WHERE genre LIKE ? ORDER BY id LIMIT ? OFFSET ?",
		pattern, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

/* ------------------------------------------------------------------ */
/* 专辑/歌手聚合查询                                                    */
/* ------------------------------------------------------------------ */

// AlbumSummary 专辑摘要
type AlbumSummary struct {
	Name       string
	Cover      sql.NullString
	Artists    string
	TrackCount int
}

// ArtistSummary 歌手摘要
type ArtistSummary struct {
	Name       string
	TrackCount int
	Cover      sql.NullString
}

// GetAlbumList 获取专辑列表
func GetAlbumList() ([]AlbumSummary, error) {
	rows, err := mediaPool.Query(`
		SELECT
			json_extract(album, '$.name') AS name,
			MAX(CASE WHEN cover IS NOT NULL THEN cover END) AS cover,
			MAX(artists) AS artists,
			COUNT(*) AS trackCount
		FROM tracks
		WHERE album IS NOT NULL AND json_extract(album, '$.name') IS NOT NULL
		GROUP BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []AlbumSummary
	for rows.Next() {
		var a AlbumSummary
		if err := rows.Scan(&a.Name, &a.Cover, &a.Artists, &a.TrackCount); err != nil {
			return nil, err
		}
		list = append(list, a)
	}
	return list, nil
}

// GetArtistList 获取歌手列表
func GetArtistList() ([]ArtistSummary, error) {
	rows, err := mediaPool.Query(`
		SELECT
			json_extract(a.value, '$.name') AS name,
			COUNT(DISTINCT t.id) AS trackCount,
			MAX(CASE WHEN t.cover IS NOT NULL THEN t.cover END) AS cover
		FROM tracks t, json_each(t.artists) a
		WHERE json_extract(a.value, '$.name') IS NOT NULL
			AND TRIM(json_extract(a.value, '$.name')) != ''
		GROUP BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []ArtistSummary
	for rows.Next() {
		var a ArtistSummary
		if err := rows.Scan(&a.Name, &a.TrackCount, &a.Cover); err != nil {
			return nil, err
		}
		list = append(list, a)
	}
	return list, nil
}

// GetAlbumTracks 按专辑名获取全部曲目
func GetAlbumTracks(albumName string) ([]model.Track, error) {
	rows, err := mediaPool.Query("SELECT "+trackColumns+" FROM tracks WHERE json_extract(album, '$.name') = ?", albumName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// GetArtistTracks 按歌手名获取全部曲目
func GetArtistTracks(artistName string) ([]model.Track, error) {
	rows, err := mediaPool.Query(`
		SELECT DISTINCT t.id, t.path, t.title, t.track, t.artists, t.album,
			t.duration, t.cover, t.codec, t.sample_rate, t.bit_rate,
			t.channels, t.bits_per_sample, t.file_size, t.file_mtime, t.file_ctime,
			t.scanned_at, t.lyrics, t.genre
		FROM tracks t, json_each(t.artists) a
		WHERE LOWER(json_extract(a.value, '$.name')) = LOWER(?)`, artistName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tracks []model.Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

/* ------------------------------------------------------------------ */
/* 收藏（starred，user.db）                                            */
/* ------------------------------------------------------------------ */

// Star 收藏
func Star(userID, targetID string, targetType model.StarTargetType) error {
	_, err := userPool.Exec(
		"INSERT OR IGNORE INTO subsonic_starred (user_id, target_id, target_type, starred_at) VALUES (?, ?, ?, ?)",
		userID, targetID, string(targetType), 0,
	)
	return err
}

// Unstar 取消收藏
func Unstar(userID, targetID string, targetType model.StarTargetType) error {
	_, err := userPool.Exec(
		"DELETE FROM subsonic_starred WHERE user_id = ? AND target_id = ? AND target_type = ?",
		userID, targetID, string(targetType),
	)
	return err
}

// IsStarred 是否已收藏
func IsStarred(userID, targetID string, targetType model.StarTargetType) (bool, error) {
	var one int
	err := userPool.QueryRow(
		"SELECT 1 FROM subsonic_starred WHERE user_id = ? AND target_id = ? AND target_type = ?",
		userID, targetID, string(targetType),
	).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	return err == nil, err
}

// StarredIDs 用户全部收藏 ID
type StarredIDs struct {
	Tracks  []string
	Albums  []string
	Artists []string
}

func GetStarredIDs(userID string) (*StarredIDs, error) {
	rows, err := userPool.Query(
		"SELECT target_id, target_type FROM subsonic_starred WHERE user_id = ?",
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := &StarredIDs{}
	for rows.Next() {
		var targetID, targetType string
		if err := rows.Scan(&targetID, &targetType); err != nil {
			return nil, err
		}
		switch model.StarTargetType(targetType) {
		case model.StarTrack:
			result.Tracks = append(result.Tracks, targetID)
		case model.StarAlbum:
			result.Albums = append(result.Albums, targetID)
		case model.StarArtist:
			result.Artists = append(result.Artists, targetID)
		}
	}
	return result, nil
}

/* ------------------------------------------------------------------ */
/* 播放列表（user.db）                                                 */
/* ------------------------------------------------------------------ */

func ListPlaylists(userID string) ([]model.Playlist, error) {
	rows, err := userPool.Query(
		"SELECT id, user_id, name, comment, public, created_at, updated_at FROM subsonic_playlists WHERE user_id = ? OR public = 1 ORDER BY updated_at DESC",
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []model.Playlist
	for rows.Next() {
		var p model.Playlist
		var isPublic int
		if err := rows.Scan(&p.ID, &p.UserID, &p.Name, &p.Comment, &isPublic, &p.CreatedAt, &p.UpdatedAt); err != nil {
			return nil, err
		}
		p.Public = isPublic == 1
		// 加载 entries
		entryRows, err := userPool.Query(
			"SELECT track_id FROM subsonic_playlist_entries WHERE playlist_id = ? ORDER BY position",
			p.ID,
		)
		if err != nil {
			return nil, err
		}
		for entryRows.Next() {
			var tid string
			entryRows.Scan(&tid)
			p.TrackIDs = append(p.TrackIDs, tid)
		}
		entryRows.Close()
		list = append(list, p)
	}
	return list, nil
}

func GetPlaylist(id, userID string) (*model.Playlist, error) {
	var p model.Playlist
	var isPublic int
	err := userPool.QueryRow(
		"SELECT id, user_id, name, comment, public, created_at, updated_at FROM subsonic_playlists WHERE id = ? AND (user_id = ? OR public = 1)",
		id, userID,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.Comment, &isPublic, &p.CreatedAt, &p.UpdatedAt)
	if err != nil {
		return nil, err
	}
	p.Public = isPublic == 1
	rows, err := userPool.Query(
		"SELECT track_id FROM subsonic_playlist_entries WHERE playlist_id = ? ORDER BY position",
		id,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var tid string
		rows.Scan(&tid)
		p.TrackIDs = append(p.TrackIDs, tid)
	}
	return &p, nil
}

/* ------------------------------------------------------------------ */
/* 分享（user.db）                                                     */
/* ------------------------------------------------------------------ */

func ListShares(userID string) ([]model.Share, error) {
	rows, err := userPool.Query(
		"SELECT id, user_id, name, description, url, expires_at, created_at, visit_count FROM subsonic_shares WHERE user_id = ? ORDER BY created_at DESC",
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []model.Share
	for rows.Next() {
		var s model.Share
		if err := rows.Scan(&s.ID, &s.UserID, &s.Name, &s.Description, &s.URL, &s.ExpiresAt, &s.CreatedAt, &s.VisitCount); err != nil {
			return nil, err
		}
		entryRows, err := userPool.Query("SELECT track_id FROM subsonic_share_entries WHERE share_id = ?", s.ID)
		if err != nil {
			return nil, err
		}
		for entryRows.Next() {
			var tid string
			entryRows.Scan(&tid)
			s.TrackIDs = append(s.TrackIDs, tid)
		}
		entryRows.Close()
		list = append(list, s)
	}
	return list, nil
}

// CreatePlaylist 创建播放列表，返回新 ID
// playlistID 由调用方传入（通常为 uuid），便于事务一致性
func CreatePlaylist(playlistID, userID, name string, comment sql.NullString, public bool, trackIDs []string) error {
	now := nowMs()
	isPublic := 0
	if public {
		isPublic = 1
	}
	tx, err := userPool.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(
		"INSERT INTO subsonic_playlists (id, user_id, name, comment, public, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
		playlistID, userID, name, comment, isPublic, now, now,
	); err != nil {
		return err
	}

	for i, tid := range trackIDs {
		if _, err := tx.Exec(
			"INSERT INTO subsonic_playlist_entries (playlist_id, track_id, position) VALUES (?, ?, ?)",
			playlistID, tid, i,
		); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// UpdatePlaylist 更新播放列表（任意字段为空/nil 表示不更新）
// trackIDsToAdd 追加到末尾；trackIndexesToRemove 删除指定位置（0-based）的条目
func UpdatePlaylist(id, name string, comment sql.NullString, public *bool, trackIDsToAdd []string, trackIndexesToRemove []int) error {
	tx, err := userPool.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if name != "" {
		if _, err := tx.Exec("UPDATE subsonic_playlists SET name = ?, updated_at = ? WHERE id = ?", name, nowMs(), id); err != nil {
			return err
		}
	}
	if comment.Valid {
		if _, err := tx.Exec("UPDATE subsonic_playlists SET comment = ?, updated_at = ? WHERE id = ?", comment.String, nowMs(), id); err != nil {
			return err
		}
	}
	if public != nil {
		isPublic := 0
		if *public {
			isPublic = 1
		}
		if _, err := tx.Exec("UPDATE subsonic_playlists SET public = ?, updated_at = ? WHERE id = ?", isPublic, nowMs(), id); err != nil {
			return err
		}
	}

	// 删除指定位置条目（倒序删除避免索引漂移）
	if len(trackIndexesToRemove) > 0 {
		// 收集现有位置
		rows, err := tx.Query("SELECT rowid FROM subsonic_playlist_entries WHERE playlist_id = ? ORDER BY position", id)
		if err != nil {
			return err
		}
		var rowids []int64
		for rows.Next() {
			var rid int64
			rows.Scan(&rid)
			rowids = append(rowids, rid)
		}
		rows.Close()
		// 倒序删除
		sorted := append([]int(nil), trackIndexesToRemove...)
		sort.Sort(sort.Reverse(sort.IntSlice(sorted)))
		for _, idx := range sorted {
			if idx >= 0 && idx < len(rowids) {
				if _, err := tx.Exec("DELETE FROM subsonic_playlist_entries WHERE rowid = ?", rowids[idx]); err != nil {
					return err
				}
			}
		}
		// 重新编号 position
		if _, err := tx.Exec(`
			UPDATE subsonic_playlist_entries
			SET position = (
				SELECT COUNT(*) FROM subsonic_playlist_entries AS t2
				WHERE t2.playlist_id = subsonic_playlist_entries.playlist_id
				  AND t2.rowid < subsonic_playlist_entries.rowid
			)
			WHERE playlist_id = ?
		`, id); err != nil {
			return err
		}
	}

	// 追加新条目
	if len(trackIDsToAdd) > 0 {
		var maxPos sql.NullInt64
		_ = tx.QueryRow("SELECT MAX(position) FROM subsonic_playlist_entries WHERE playlist_id = ?", id).Scan(&maxPos)
		startPos := 0
		if maxPos.Valid {
			startPos = int(maxPos.Int64) + 1
		}
		for i, tid := range trackIDsToAdd {
			if _, err := tx.Exec(
				"INSERT INTO subsonic_playlist_entries (playlist_id, track_id, position) VALUES (?, ?, ?)",
				id, tid, startPos+i,
			); err != nil {
				return err
			}
		}
		if _, err := tx.Exec("UPDATE subsonic_playlists SET updated_at = ? WHERE id = ?", nowMs(), id); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// DeletePlaylist 删除播放列表及其条目
func DeletePlaylist(id string) error {
	tx, err := userPool.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec("DELETE FROM subsonic_playlist_entries WHERE playlist_id = ?", id); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM subsonic_playlists WHERE id = ?", id); err != nil {
		return err
	}
	return tx.Commit()
}

/* ------------------------------------------------------------------ */
/* 分享 CRUD（user.db）                                                */
/* ------------------------------------------------------------------ */

// CreateShare 创建分享，返回新 ID（由调用方传入）
func CreateShare(shareID, userID, name string, description sql.NullString, url string, expiresAt sql.NullInt64, trackIDs []string) error {
	now := nowMs()
	tx, err := userPool.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(
		"INSERT INTO subsonic_shares (id, user_id, name, description, url, expires_at, created_at, visit_count) VALUES (?, ?, ?, ?, ?, ?, ?, 0)",
		shareID, userID, name, description, url, expiresAt, now,
	); err != nil {
		return err
	}

	for i, tid := range trackIDs {
		if _, err := tx.Exec(
			"INSERT INTO subsonic_share_entries (share_id, track_id, position) VALUES (?, ?, ?)",
			shareID, tid, i,
		); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// UpdateShare 更新分享（空值不更新）
func UpdateShare(id, name string, description sql.NullString, expiresAt sql.NullInt64) error {
	tx, err := userPool.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if name != "" {
		if _, err := tx.Exec("UPDATE subsonic_shares SET name = ? WHERE id = ?", name, id); err != nil {
			return err
		}
	}
	if description.Valid {
		if _, err := tx.Exec("UPDATE subsonic_shares SET description = ? WHERE id = ?", description.String, id); err != nil {
			return err
		}
	}
	if expiresAt.Valid {
		if _, err := tx.Exec("UPDATE subsonic_shares SET expires_at = ? WHERE id = ?", expiresAt.Int64, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// DeleteShare 删除分享及其条目
func DeleteShare(id string) error {
	tx, err := userPool.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec("DELETE FROM subsonic_share_entries WHERE share_id = ?", id); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM subsonic_shares WHERE id = ?", id); err != nil {
		return err
	}
	return tx.Commit()
}

/* ------------------------------------------------------------------ */
/* 扫描状态（library.db）                                              */
/* ------------------------------------------------------------------ */

// GetLastScanTime 返回 tracks 表中最大的 scanned_at（毫秒），0 表示无数据
func GetLastScanTime() (int64, error) {
	var t sql.NullInt64
	err := mediaPool.QueryRow("SELECT MAX(scanned_at) FROM tracks").Scan(&t)
	if err != nil {
		return 0, err
	}
	if !t.Valid {
		return 0, nil
	}
	return t.Int64, nil
}

// nowMs 当前毫秒时间戳
func nowMs() int64 {
	return time.Now().UnixMilli()
}
