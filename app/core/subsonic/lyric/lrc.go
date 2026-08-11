package lyric

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// LrcLine LRC 歌词行
type LrcLine struct {
	Start int64  `json:"start"`
	Value string `json:"value"`
}

var lrcRe = regexp.MustCompile(`\[(?:(\d{1,2}):)?(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]`)

// lrcTimeToMs [mm:ss.xx] → 毫秒
func lrcTimeToMs(hh, mm, ss, xx string) int64 {
	hours := 0
	if hh != "" {
		hours, _ = strconv.Atoi(hh)
	}
	minutes, _ := strconv.Atoi(mm)
	seconds, _ := strconv.Atoi(ss)
	frac := 0
	if xx != "" {
		f, _ := strconv.ParseFloat("0."+xx, 64)
		frac = int(f * 1000)
	}
	return int64(hours)*3600000 + int64(minutes)*60000 + int64(seconds)*1000 + int64(frac)
}

// ParseLrc 解析 LRC 文本为带时间戳的行（过滤元数据标签）
func ParseLrc(text string) []LrcLine {
	var lines []LrcLine
	for _, raw := range strings.Split(text, "\n") {
		raw = strings.TrimRight(raw, "\r")
		matches := lrcRe.FindAllStringSubmatch(raw, -1)
		if len(matches) == 0 {
			continue
		}
		var stamps []int64
		for _, m := range matches {
			stamps = append(stamps, lrcTimeToMs(m[1], m[2], m[3], m[4]))
		}
		value := strings.TrimSpace(lrcRe.ReplaceAllString(raw, ""))
		for _, start := range stamps {
			lines = append(lines, LrcLine{Start: start, Value: value})
		}
	}
	sort.Slice(lines, func(i, j int) bool { return lines[i].Start < lines[j].Start })
	return lines
}

const alignToleranceMs = 300

// AlignAuxiliaryLines 将辅助歌词行（翻译/罗马音）对齐到主歌词行
func AlignAuxiliaryLines(mainLines, extraLines []LrcLine) []*string {
	aligned := make([]*string, len(mainLines))
	if len(mainLines) == 0 || len(extraLines) == 0 {
		return aligned
	}
	cursor := 0
	for i, main := range mainLines {
		for cursor < len(extraLines) && extraLines[cursor].Start < main.Start-alignToleranceMs {
			cursor++
		}
		bestIndex := -1
		bestDiff := int64(alignToleranceMs + 1)
		for j := cursor; j < len(extraLines); j++ {
			diff := extraLines[j].Start - main.Start
			if diff > int64(alignToleranceMs) {
				break
			}
			absDiff := diff
			if absDiff < 0 {
				absDiff = -absDiff
			}
			if absDiff < bestDiff {
				bestDiff = absDiff
				bestIndex = j
			}
		}
		if bestIndex >= 0 {
			val := extraLines[bestIndex].Value
			aligned[i] = &val
			cursor = bestIndex + 1
		}
	}
	return aligned
}

// FormatLrcTimestamp 毫秒 → [mm:ss.xx] 格式
func FormatLrcTimestamp(ms int64) string {
	if ms < 0 {
		ms = 0
	}
	mm := ms / 60000
	ss := (ms % 60000) / 1000
	xx := (ms % 1000) / 10
	return "[" + padTwo(int(mm)) + ":" + padTwo(int(ss)) + "." + padTwo(int(xx)) + "]"
}

func padTwo(n int) string {
	if n < 10 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

// PreparedLyric 准备好的歌词数据
type PreparedLyric struct {
	Synced           bool
	ClassicText      string
	StructuredLines  []LrcLine
}

// TrackLyricPayload 原始歌词文本
type TrackLyricPayload struct {
	Main        string
	Translation string
	Romaji      string
}

// Prepare 组合主歌词 + 翻译 + 罗马音为 Subsonic 结构化歌词
func Prepare(lyric TrackLyricPayload) PreparedLyric {
	mainLines := ParseLrc(lyric.Main)
	if len(mainLines) == 0 {
		return PreparedLyric{
			Synced:          false,
			ClassicText:     lyric.Main,
			StructuredLines: nil,
		}
	}

	var translationLines, romajiLines []LrcLine
	if lyric.Translation != "" {
		translationLines = ParseLrc(lyric.Translation)
	}
	if lyric.Romaji != "" {
		romajiLines = ParseLrc(lyric.Romaji)
	}

	alignedTranslation := AlignAuxiliaryLines(mainLines, translationLines)
	alignedRomaji := AlignAuxiliaryLines(mainLines, romajiLines)

	var structured []LrcLine
	for i, main := range mainLines {
		structured = append(structured, main)
		if alignedTranslation[i] != nil {
			structured = append(structured, LrcLine{Start: main.Start, Value: *alignedTranslation[i]})
		}
		if alignedRomaji[i] != nil {
			structured = append(structured, LrcLine{Start: main.Start, Value: *alignedRomaji[i]})
		}
	}

	var classicText strings.Builder
	for _, line := range structured {
		classicText.WriteString(FormatLrcTimestamp(line.Start))
		classicText.WriteString(line.Value)
		classicText.WriteString("\n")
	}

	return PreparedLyric{
		Synced:          true,
		ClassicText:     strings.TrimRight(classicText.String(), "\n"),
		StructuredLines: structured,
	}
}
