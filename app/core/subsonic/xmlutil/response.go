package xmlutil

import (
	"encoding/xml"
	"fmt"
	"net/http"
	"strings"
)

// Subsonic 响应常量
const (
	Version       = "1.16.1"
	ServerName    = "splayer"
	ServerVersion = "1.0.0"
)

// SubError 错误
type SubError struct {
	Code    int    `xml:"code,attr"`
	Message string `xml:"message,attr"`
}

// Response subsonic-response 根
type Response struct {
	XMLName       xml.Name `xml:"subsonic-response"`
	Status        string   `xml:"status,attr"`
	Version       string   `xml:"version,attr"`
	Type          string   `xml:"type,attr"`
	ServerVersion string   `xml:"serverVersion,attr"`
	OpenSubsonic  bool     `xml:"openSubsonic,attr"`
	// 动态字段通过 payload 传递
	Children []byte    `xml:",innerxml"`
	Error    *SubError `xml:"error,omitempty"`
}

// Send 按 f 参数选 JSON/XML 格式发送响应
func Send(w http.ResponseWriter, r *http.Request, payload map[string]any, subErr *SubError) {
	format := r.URL.Query().Get("f")
	if format == "" {
		format = "xml"
	}

	status := "ok"
	if subErr != nil {
		status = "failed"
	}

	body := map[string]any{
		"status":        status,
		"version":       Version,
		"type":          ServerName,
		"serverVersion": ServerVersion,
		"openSubsonic":  true,
	}
	for k, v := range payload {
		body[k] = v
	}
	if subErr != nil {
		body["error"] = map[string]any{"code": subErr.Code, "message": subErr.Message}
	}

	if format == "json" {
		// JSON: {"subsonic-response": {...}}
		w.Header().Set("Content-Type", "application/json")
		wrapped := map[string]any{"subsonic-response": body}
		writeJSON(w, wrapped)
		return
	}

	// XML
	w.Header().Set("Content-Type", "text/xml; charset=utf-8")
	xmlStr := ToXML(body)
	fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?>`+"\n%s", xmlStr)
}

// writeJSON 写 JSON（手动序列化以保持字段顺序兼容）
func writeJSON(w http.ResponseWriter, v any) {
	// 使用标准 json 包，字段顺序由 map 决定（Go 1.22+ 保持插入顺序 for json.Marshal 已不保证）
	// 为兼容性，直接用 encoding/json
	w.Header().Set("Content-Type", "application/json")
	data := mustJSON(v)
	w.Write(data)
}

// 特殊键名：值为元素的文本内容（不渲染为属性）
const TextContentKey = "#text"

// ToXML 把 map 序列化为 Subsonic XML
// 规则：数组用单数子元素名（如 artists → artist），基本类型走属性，复杂对象走子元素
//
//	map 中含 "#text" 键时，其值作为元素的文本内容
func ToXML(body map[string]any) string {
	var sb strings.Builder
	writeElement(&sb, "subsonic-response", body, 0)
	return sb.String()
}

var singularMap = map[string]string{
	"artists":       "artist",
	"albums":        "album",
	"songs":         "song",
	"entries":       "entry",
	"playlists":     "playlist",
	"shares":        "share",
	"genres":        "genre",
	"indexes":       "index",
	"children":      "child",
	"musicFolders":  "musicFolder",
	"similarSongs":  "similarSong",
	"similarSongs2": "similarSong",
	"searchResult2": "searchResult2",
	"searchResult3": "searchResult3",
	"artistsRoot":   "artists",
	"versions":      "versions",
}

func singularOf(key string) string {
	if s, ok := singularMap[key]; ok {
		return s
	}
	if strings.HasSuffix(key, "s") {
		return key[:len(key)-1]
	}
	return key
}

func escapeXML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	return s
}

func isPrimitive(v any) bool {
	switch v.(type) {
	case string, int, int64, float64, bool:
		return true
	}
	return false
}

func writeElement(sb *strings.Builder, name string, obj any, indent int) {
	if obj == nil {
		return
	}
	pad := strings.Repeat("  ", indent)

	if isPrimitive(obj) {
		sb.WriteString(pad)
		sb.WriteString("<")
		sb.WriteString(name)
		sb.WriteString(">")
		sb.WriteString(escapeXML(fmt.Sprintf("%v", obj)))
		sb.WriteString("</")
		sb.WriteString(name)
		sb.WriteString(">\n")
		return
	}

	switch v := obj.(type) {
	case []any:
		child := singularOf(name)
		for _, item := range v {
			writeElement(sb, child, item, indent)
		}
		return
	case map[string]any:
		// lyrics/line/cue 元素带 value 字段 → chardata
		if val, hasVal := v["value"]; hasVal && (name == "lyrics" || name == "line" || name == "cue") {
			var attrs []string
			var children []string
			for k, vv := range v {
				if k == "value" || vv == nil {
					continue
				}
				if isPrimitive(vv) {
					attrs = append(attrs, fmt.Sprintf(`%s="%s"`, k, escapeXML(fmt.Sprintf("%v", vv))))
				} else {
					var c strings.Builder
					writeElement(&c, k, vv, indent+1)
					children = append(children, c.String())
				}
			}
			attrStr := ""
			if len(attrs) > 0 {
				attrStr = " " + strings.Join(attrs, " ")
			}
			text := escapeXML(fmt.Sprintf("%v", val))
			sb.WriteString(pad)
			sb.WriteString("<")
			sb.WriteString(name)
			sb.WriteString(attrStr)
			sb.WriteString(">")
			sb.WriteString(text)
			if len(children) == 0 {
				sb.WriteString("</")
				sb.WriteString(name)
				sb.WriteString(">\n")
			} else {
				sb.WriteString("\n")
				for _, c := range children {
					sb.WriteString(c)
				}
				sb.WriteString(pad)
				sb.WriteString("</")
				sb.WriteString(name)
				sb.WriteString(">\n")
			}
			return
		}

		// 普通对象：属性 + 可选文本内容 + 子元素
		var attrs []string
		var children []string
		var textContent string
		var hasText bool
		for k, vv := range v {
			if vv == nil {
				continue
			}
			if k == TextContentKey {
				textContent = escapeXML(fmt.Sprintf("%v", vv))
				hasText = true
				continue
			}
			if isPrimitive(vv) {
				attrs = append(attrs, fmt.Sprintf(`%s="%s"`, k, escapeXML(fmt.Sprintf("%v", vv))))
			} else {
				var c strings.Builder
				writeElement(&c, k, vv, indent+1)
				children = append(children, c.String())
			}
		}
		attrStr := ""
		if len(attrs) > 0 {
			attrStr = " " + strings.Join(attrs, " ")
		}
		sb.WriteString(pad)
		sb.WriteString("<")
		sb.WriteString(name)
		sb.WriteString(attrStr)
		if hasText {
			sb.WriteString(">")
			sb.WriteString(textContent)
			if len(children) == 0 {
				sb.WriteString("</")
				sb.WriteString(name)
				sb.WriteString(">\n")
			} else {
				sb.WriteString("\n")
				for _, c := range children {
					sb.WriteString(c)
				}
				sb.WriteString(pad)
				sb.WriteString("</")
				sb.WriteString(name)
				sb.WriteString(">\n")
			}
		} else if len(children) == 0 {
			sb.WriteString("/>\n")
		} else {
			sb.WriteString(">\n")
			for _, c := range children {
				sb.WriteString(c)
			}
			sb.WriteString(pad)
			sb.WriteString("</")
			sb.WriteString(name)
			sb.WriteString(">\n")
		}
	}
}
