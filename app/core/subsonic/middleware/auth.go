package middleware

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"

	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/model"
	"github.com/betastudio2/archoera-subsonic/xmlutil"
)

type contextKey string

const UserKey contextKey = "subsonicUser"

// SubError 用于鉴权失败
type SubError = xmlutil.SubError

// Authenticate 鉴权中间件：解析 u/p/t/s，挂到 context
func Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := r.URL.Query().Get("u")
		p := r.URL.Query().Get("p")
		t := r.URL.Query().Get("t")
		s := r.URL.Query().Get("s")

		// POST 表单支持
		if u == "" && r.Method == http.MethodPost {
			if err := r.ParseForm(); err == nil {
				u = r.FormValue("u")
				p = r.FormValue("p")
				t = r.FormValue("t")
				s = r.FormValue("s")
			}
		}

		user, subErr := authenticate(u, p, t, s)
		if subErr != nil {
			xmlutil.Send(w, r, map[string]any{}, subErr)
			return
		}

		ctx := context.WithValue(r.Context(), UserKey, user)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func authenticate(u, p, t, s string) (*model.SubsonicUser, *SubError) {
	if u == "" {
		return nil, &SubError{Code: 10, Message: "Missing required parameter u"}
	}
	user, err := db.GetUserByUsername(u)
	if err != nil || user == nil {
		return nil, &SubError{Code: 40, Message: "Wrong username or password"}
	}

	// token + salt 模式
	if t != "" && s != "" {
		expected := md5hex(user.Password + s)
		if expected != t {
			return nil, &SubError{Code: 40, Message: "Wrong username or password"}
		}
		return user, nil
	}

	// 明文密码模式（可能带 enc:hex: 前缀）
	if p != "" {
		plain := p
		if strings.HasPrefix(plain, "enc:hex:") {
			decoded, err := hex.DecodeString(plain[8:])
			if err == nil {
				plain = string(decoded)
			}
		}
		if plain != user.Password {
			return nil, &SubError{Code: 40, Message: "Wrong username or password"}
		}
		return user, nil
	}

	return nil, &SubError{Code: 10, Message: "Missing authentication"}
}

func md5hex(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

// GetUser 从 context 取已鉴权用户
func GetUser(r *http.Request) *model.SubsonicUser {
	if v, ok := r.Context().Value(UserKey).(*model.SubsonicUser); ok {
		return v
	}
	return nil
}

// ParseEndpoint 从 URL 路径解析端点名（去掉 .view 后缀）
func ParseEndpoint(path string) string {
	// 兼容 /rest/rest/<endpoint> 双重前缀
	// 取最后一段
	idx := strings.LastIndex(path, "/")
	if idx < 0 {
		return strings.ToLower(path)
	}
	endpoint := path[idx+1:]
	// 去掉 .view 后缀
	endpoint = strings.TrimSuffix(endpoint, ".view")
	return strings.ToLower(endpoint)
}

// CollectIds 收集可能多值的 query 参数（逗号分隔或重复参数）
func CollectIds(r *http.Request, key string) []string {
	values := r.URL.Query()[key]
	var ids []string
	for _, v := range values {
		for _, part := range strings.Split(v, ",") {
			part = strings.TrimSpace(part)
			if part != "" {
				ids = append(ids, part)
			}
		}
	}
	return ids
}

// ParseIntOr 解析整数，失败返回 fallback
func ParseIntOr(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return fallback
	}
	return n
}
