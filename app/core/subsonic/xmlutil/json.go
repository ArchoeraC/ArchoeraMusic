package xmlutil

import "encoding/json"

// mustJSON 序列化 JSON（失败返回 null）
func mustJSON(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		return []byte("null")
	}
	return data
}
