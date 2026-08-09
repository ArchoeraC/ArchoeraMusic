package model

import "database/sql"

// Track 对应 SQLite tracks 表的行
type Track struct {
	ID             string
	Path           string
	Title          string
	TrackNo        sql.NullInt64
	ArtistsJSON    string // JSON array of {name}
	AlbumJSON      sql.NullString
	Duration       int64
	Cover          sql.NullString
	Codec          sql.NullString
	SampleRate     sql.NullInt64
	BitRate        sql.NullInt64
	Channels       sql.NullInt64
	BitsPerSample  sql.NullInt64
	FileSize       int64
	FileMtime      sql.NullInt64
	FileCtime      sql.NullInt64
	ScannedAt      int64
	Lyrics         sql.NullString
	Genre          sql.NullString
}

// Artist 简化歌手
type Artist struct {
	Name string `json:"name"`
}

// Album 简化专辑
type Album struct {
	Name   string `json:"name"`
	Year   int    `json:"year,omitempty"`
	Artist string `json:"artist,omitempty"`
}

// SubsonicUser 对应 subsonic_users 表
type SubsonicUser struct {
	ID           string
	Username     string
	Password     string // 解密后明文
	IsAdmin      bool
	CreatedAt    int64
}

// StarTargetType 收藏目标类型
type StarTargetType string

const (
	StarTrack  StarTargetType = "track"
	StarAlbum  StarTargetType = "album"
	StarArtist StarTargetType = "artist"
)

// Playlist 对应 subsonic_playlists + entries
type Playlist struct {
	ID        string
	UserID    string
	Name      string
	Comment   sql.NullString
	Public    bool
	CreatedAt int64
	UpdatedAt int64
	TrackIDs  []string
}

// Share 对应 subsonic_shares + entries
type Share struct {
	ID          string
	UserID      string
	Name        string
	Description sql.NullString
	URL         string
	ExpiresAt   sql.NullInt64
	CreatedAt   int64
	VisitCount  int64
	TrackIDs    []string
}
