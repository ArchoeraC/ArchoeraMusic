#pragma once

/// Archoera 刮削器 —— 目录扫描与标签读取器（header-only）
///
/// 直接扫描独立的刮削目录，使用 TagLib 读取音频文件现有标签，
/// 作为 MusicBrainz 查询的基础。
///
/// 这样刮削器不再依赖 DB tracks 表 —— 刮削目录可以不在扫描路径中。

#include "scraper.h"
#include <unordered_set>
#include <taglib/tag.h>
#include <taglib/fileref.h>
#include <taglib/audioproperties.h>
#include <taglib/mpegfile.h>
#include <taglib/id3v2tag.h>
#include <taglib/id3v2frame.h>
#include <taglib/textidentificationframe.h>
#include <taglib/flacfile.h>
#include <taglib/vorbisfile.h>
#include <taglib/opusfile.h>
#include <taglib/oggfile.h>
#include <taglib/xiphcomment.h>
#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4item.h>

#include <filesystem>
#include <algorithm>
#include <cctype>
#include <iostream>
#include <cstdlib>
#include <openssl/evp.h>
#include <cstdio>

namespace archoera::scraper {

/// 支持扫描的音频扩展名
inline static const std::vector<std::string> AUDIO_EXTENSIONS = {
    ".mp3", ".flac", ".ogg", ".oga", ".opus",
    ".m4a", ".aac", ".mp4", ".wav", ".ape",
    ".wv", ".dsf", ".dsd", ".dff", ".aiff", ".aif",
};

/// 判断文件是否为支持的音频格式（大小写不敏感）
inline bool isAudioFile(const std::string& filePath) {
    std::string ext = filePath;
    auto pos = ext.find_last_of('.');
    if (pos == std::string::npos) return false;
    ext = ext.substr(pos);
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    for (const auto& e : AUDIO_EXTENSIONS) {
        if (ext == e) return true;
    }
    return false;
}

/// 快速预检：判断文件是否值得用 TagLib 尝试打开
/// 跳过过大/过小/无法访问的文件
inline bool isFileProcessable(const std::string& filePath, int maxSizeMb) {
    std::error_code ec;
    auto sz = std::filesystem::file_size(filePath, ec);
    if (ec) return false;           // 无法访问
    if (sz == 0) return false;      // 空文件
    uint64_t maxBytes = static_cast<uint64_t>(maxSizeMb) * 1024ULL * 1024ULL;
    if (sz > maxBytes) return false; // 超过大小限制
    return true;
}

/// 文件扫描器：扫描目录并读取音频文件标签
class FileScanner {
public:
    explicit FileScanner(const ScraperConfig& cfg = ScraperConfig{}) : cfg_(cfg) {}

    /// 扫描多个目录，返回所有音频文件的 TrackInfo
    /// @param dirs 目录列表
    /// @param recursive 是否递归扫描子目录
    /// @return 文件列表（含现有标签信息）
    std::vector<TrackInfo> scanDirs(const std::vector<std::string>& dirs, bool recursive = true) {
        std::vector<TrackInfo> results;
        int scanned = 0;
        int skipped = 0;
        int errors = 0;
        int maxFiles = cfg_.maxScanFiles;
        int maxSizeMb = cfg_.maxFileSizeMb;
        int maxErrors = cfg_.maxScanErrors;
        // 去重集合：防止重叠目录将同一文件处理两次
        std::unordered_set<std::string> seenPaths;

        for (const auto& dir : dirs) {
            if (!std::filesystem::exists(dir)) {
                std::cerr << "[scanner] 目录不存在: " << dir << std::endl;
                continue;
            }
            if (!std::filesystem::is_directory(dir)) {
                std::cerr << "[scanner] 不是目录: " << dir << std::endl;
                continue;
            }

            std::cerr << "[scanner] 扫描目录: " << dir << std::endl;

            try {
                if (recursive) {
                    for (const auto& entry : std::filesystem::recursive_directory_iterator(
                             dir, std::filesystem::directory_options::skip_permission_denied)) {
                        if (scanned >= maxFiles) break;
                        if (errors >= maxErrors) break;
                        if (!entry.is_regular_file()) continue;
                        auto path = entry.path().string();
                        if (!isAudioFile(path)) continue;
                        if (!isFileProcessable(path, maxSizeMb)) { skipped++; continue; }
                        // 去重：跳过已在其他目录下处理过的文件
                        if (!seenPaths.insert(path).second) { skipped++; continue; }

                        auto track = readTags(path);
                        if (track) { results.push_back(*track); scanned++; errors = 0; }
                        else { skipped++; errors++; }
                    }
                } else {
                    for (const auto& entry : std::filesystem::directory_iterator(
                             dir, std::filesystem::directory_options::skip_permission_denied)) {
                        if (scanned >= maxFiles) break;
                        if (errors >= maxErrors) break;
                        if (!entry.is_regular_file()) continue;
                        auto path = entry.path().string();
                        if (!isAudioFile(path)) continue;
                        if (!isFileProcessable(path, maxSizeMb)) { skipped++; continue; }
                        // 去重：跳过已在其他目录下处理过的文件
                        if (!seenPaths.insert(path).second) { skipped++; continue; }

                        auto track = readTags(path);
                        if (track) { results.push_back(*track); scanned++; errors = 0; }
                        else { skipped++; errors++; }
                    }
                }
            } catch (const std::filesystem::filesystem_error& e) {
                std::cerr << "[scanner] 扫描失败 " << dir << ": " << e.what() << std::endl;
            } catch (const std::exception& e) {
                std::cerr << "[scanner] 扫描异常 " << dir << ": " << e.what() << std::endl;
            }
        }

        std::cerr << "[scanner] 扫描完成: " << scanned << " 个文件, "
                  << skipped << " 个跳过" << std::endl;
        return results;
    }

    /// 读取单个音频文件的标签
    /// @param filePath 文件路径
    /// @return TrackInfo（含现有标签，缺失字段为空）
    std::optional<TrackInfo> readTags(const std::string& filePath) {
        try {
            // 预检：文件大小/可访问性
            if (!isFileProcessable(filePath, cfg_.maxFileSizeMb)) {
                lastError_ = "文件无法处理（过大/为空/不可访问）: " + filePath;
                return std::nullopt;
            }

            TagLib::FileRef f(filePath.c_str());
            if (f.isNull() || !f.file()) {
                lastError_ = "无法打开文件: " + filePath;
                return std::nullopt;
            }

            TagLib::Tag* tag = f.tag();
            if (!tag) {
                lastError_ = "文件不支持标签: " + filePath;
                return std::nullopt;
            }

            TrackInfo info;
            info.filePath = filePath;
            // 生成稳定 id（与 TS 层一致：md5(path)）
            info.id = generateId(filePath);

            // 读取基本标签
            info.title = tag->title().to8Bit(true);
            info.artist = tag->artist().to8Bit(true);
            info.album = tag->album().to8Bit(true);
            info.albumArtist = ""; // 标准 Tag 接口没有 albumArtist，需特定格式读取
            info.composer = "";    // 标准 Tag 接口没有 composer，需特定格式读取
            info.genre = tag->genre().to8Bit(true);
            info.trackNumber = tag->track();
            info.discNumber = 0;   // 标准 Tag 接口没有 discNumber，需特定格式读取
            info.year = tag->year() > 0 ? static_cast<int>(tag->year()) : 0;

            // 读取时长
            TagLib::AudioProperties* props = f.audioProperties();
            if (props) {
                info.durationMs = props->lengthInMilliseconds();
            }

            // 文件名优先策略：用文件名解析的 artist/title 作为搜索基础，
            // 标签值作为兜底（文件名无信息时才用标签）。
            // 原因：网络下载的音频文件标签常常损坏/错误/无意义，
            // 而文件名"歌手 - 标题"格式更接近用户原始意图，检索命中率更高。
            applyFilenameSearch(filePath, info);

            // 读取扩展标签（albumArtist/composer/discNumber）
            readExtendedTags(f.file(), info);

            return info;
        } catch (const std::exception& e) {
            lastError_ = std::string("读取标签异常: ") + e.what();
            return std::nullopt;
        }
    }

    /// 判断文件是否已刮削
    /// 判断依据（按可靠性排序）：
    ///   1. 有 MusicBrainz MBID（recording/album/artist 任一）→ 已刮削
    ///   2. 有 ISRC → 已刮削
    /// 仅靠 title/artist/album 不可靠：用户手动填写、损坏的元数据、
    /// 单曲/现场录音（无专辑）都可能误判。
    bool isAlreadyScraped(const std::string& filePath) {
        auto track = readTags(filePath);
        if (!track) return false;
        // 有 MBID 或 ISRC，认为已刮削
        if (!track->mbid.empty() || !track->isrc.empty() ||
            !track->albumMbid.empty() || !track->artistMbid.empty()) {
            return true;
        }
        return false;
    }

    /// 判断 TrackInfo 是否已刮削（避免重复读取文件）
    bool isAlreadyScraped(const TrackInfo& track) const {
        return !track.mbid.empty() || !track.isrc.empty() ||
               !track.albumMbid.empty() || !track.artistMbid.empty();
    }

    const std::string& lastError() const { return lastError_; }

private:
    static std::string trim(std::string s) {
        auto notSpace = [](unsigned char c) { return !std::isspace(c); };
        s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
        s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
        return s;
    }

    static bool looksLikeTrackPrefix(const std::string& s) {
        if (s.empty()) return false;
        size_t i = 0;
        while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) i++;
        if (i == 0) return false;
        while (i < s.size() && (s[i] == '.' || s[i] == '-' || s[i] == '_' || std::isspace(static_cast<unsigned char>(s[i])))) i++;
        return i == s.size();
    }

    /// 判断字符串是否为无意义的占位符（如 "unknown"、"track 01"、"未知歌手" 等）
    /// 这些值无法用于有效检索，应视为缺失
    static bool isPlaceholderValue(const std::string& s) {
        std::string lower = s;
        std::transform(lower.begin(), lower.end(), lower.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        lower = trim(lower);
        if (lower.empty()) return true;
        if (looksLikeTrackPrefix(lower)) return true;
        static const std::vector<std::string> placeholders = {
            "unknown", "unknown artist", "unknown title", "unknown track",
            "untitled", "no title", "no artist",
            "track", "track01", "audio", "music",
            "未知", "未知歌手", "未知艺术家", "未知标题", "未知专辑",
            "佚名", "无", "未分类",
        };
        for (const auto& p : placeholders) {
            if (lower == p) return true;
        }
        return false;
    }

    /// 从艺术家字符串中剥离 feat./&/× 等多艺术家分隔符，
    /// 只保留主艺术家，避免"歌手A feat. 歌手B"被当作整体去搜索。
    ///
    /// 支持的格式（按优先级）：
    ///   "A feat. B" / "A ft. B" / "A featuring B" / "A Feat B"
    ///   "A & B" / "A × B" / "A x B"
    ///   "A vs. B" / "A pres. B"
    ///   "A, B" / "A、B"
    static std::string stripFeaturedArtist(const std::string& artist) {
        if (artist.empty()) return artist;
        std::string lower = artist;
        std::transform(lower.begin(), lower.end(), lower.begin(),
                       [](unsigned char c) { return std::tolower(c); });

        // feat. 系列（最优先，因为最常见）
        static const std::vector<std::string> featMarkers = {
            " feat. ", " ft. ", " featuring ", " feat ", " ft ",
            "feat.", "ft.", "featuring",
        };
        for (const auto& marker : featMarkers) {
            size_t pos = lower.find(marker);
            if (pos != std::string::npos) {
                return trim(artist.substr(0, pos));
            }
        }

        // 分隔符系列（需要判断是否有空格上下文避免误判）
        // "A & B" → A
        // 但 "A&B"（无空格）可能是乐队名的一部分，不处理
        size_t ampPos = lower.find(" & ");
        if (ampPos != std::string::npos) {
            return trim(artist.substr(0, ampPos));
        }

        // "A × B" / "A x B"
        for (const auto& marker : {" × ", " x "}) {
            size_t pos = lower.find(marker);
            if (pos != std::string::npos) {
                return trim(artist.substr(0, pos));
            }
        }

        // "A vs. B" / "A pres. B"
        for (const auto& marker : {" vs. ", " vs ", " pres. ", " presents "}) {
            size_t pos = lower.find(marker);
            if (pos != std::string::npos) {
                return trim(artist.substr(0, pos));
            }
        }

        // 逗号/顿号分隔（仅在字符串较长时处理，避免 "A, B" 本身是名字）
        // "A, B" → A（仅当 A 部分 >= 3 字符且 B 部分 >= 2 字符时）
        size_t commaPos = lower.find(", ");
        if (commaPos != std::string::npos && commaPos >= 3 &&
            artist.length() - commaPos - 2 >= 2) {
            return trim(artist.substr(0, commaPos));
        }

        return artist;
    }

    /// 文件名优先策略：用文件名解析的 artist/title 作为搜索基础，
    /// 标签值仅在文件名无法解析时使用。
    ///
    /// 解析规则（按文件名常见命名习惯）：
    ///   "artist - title.ext"  → artist + title（最常见）
    ///   "01 - title.ext"      → title（left 是 track 前缀，忽略）
    ///   "title.ext"           → title（无 artist）
    ///
    /// 覆盖规则：
    ///   - 文件名解析出 title  → 覆盖标签 title（即使标签存在）
    ///   - 文件名解析出 artist → 覆盖标签 artist（即使标签存在）
    ///   - 文件名无法解析     → 保留标签值（兜底）
    ///   - 标签为占位符（unknown/未知等）→ 始终用文件名（即使文件名信息不全）
    ///
    /// 原因：网络下载的音频文件标签常常损坏/错误/无意义，
    /// 而文件名"歌手 - 标题"格式更接近用户原始意图，检索命中率更高。
    static void applyFilenameSearch(const std::string& filePath, TrackInfo& info) {
        std::string stem = std::filesystem::path(filePath).stem().string();
        stem = trim(stem);
        if (stem.empty()) return;

        std::string normalized = stem;
        std::replace(normalized.begin(), normalized.end(), '_', ' ');

        size_t sep = std::string::npos;
        size_t sepLen = 0;
        for (const auto& marker : {std::string(" - "), std::string(" – "), std::string(" — ")}) {
            sep = normalized.find(marker);
            if (sep != std::string::npos) {
                sepLen = marker.size();
                break;
            }
        }

        std::string left = sep == std::string::npos ? "" : trim(normalized.substr(0, sep));
        std::string right = sep == std::string::npos ? normalized : trim(normalized.substr(sep + sepLen));

        if (!left.empty() && looksLikeTrackPrefix(left)) {
            left.clear();
        }

        std::string fileTitle = !right.empty() ? right : "";
        std::string fileArtist = !left.empty() ? left : "";

        bool tagTitlePlaceholder = isPlaceholderValue(info.title);

        // title 决策：文件名有 → 用文件名；否则保留标签
        if (!fileTitle.empty()) {
            info.title = fileTitle;
        } else if (tagTitlePlaceholder) {
            // 标签是占位符且文件名解析不出 → 用文件名 stem 作为最后兜底
            info.title = normalized;
        }

        // artist 决策：文件名有 → 剥离 feat./& 等多艺术家后写入，否则保留标签
        if (!fileArtist.empty()) {
            info.artist = stripFeaturedArtist(fileArtist);
        }
    }

    /// 生成稳定 id（md5(path)）
    /// 与 C# 端 MD5.HashData(Encoding.UTF8.GetBytes(path)) 保持一致，
    /// 确保同一文件在不同工具中产生相同的 track ID。
    std::string generateId(const std::string& path) {
        unsigned char digest[16];
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        if (!ctx) return path; // 降级
        EVP_DigestInit_ex(ctx, EVP_md5(), nullptr);
        EVP_DigestUpdate(ctx, path.data(), path.size());
        EVP_DigestFinal_ex(ctx, digest, nullptr);
        EVP_MD_CTX_free(ctx);

        char hex[33];
        for (int i = 0; i < 16; ++i)
            std::snprintf(hex + i * 2, 3, "%02x", digest[i]);
        return std::string(hex, 32);
    }

    /// 读取扩展标签（albumArtist/composer/discNumber/MBID/ISRC 等）
    void readExtendedTags(TagLib::File* file, TrackInfo& info) {
        // 尝试读取 ID3v2 扩展标签（MP3）
        auto* mpegFile = dynamic_cast<TagLib::MPEG::File*>(file);
        if (mpegFile) {
            TagLib::ID3v2::Tag* id3v2 = mpegFile->ID3v2Tag(false);
            if (id3v2) {
                // TPE2 = 专辑艺术家
                auto tpe2 = id3v2->frameList("TPE2");
                if (!tpe2.isEmpty()) {
                    info.albumArtist = tpe2.front()->toString().to8Bit(true);
                }
                // TCOM = 作曲家
                auto tcom = id3v2->frameList("TCOM");
                if (!tcom.isEmpty()) {
                    info.composer = tcom.front()->toString().to8Bit(true);
                }
                // TPOS = 碟片编号
                auto tpos = id3v2->frameList("TPOS");
                if (!tpos.isEmpty()) {
                    std::string discStr = tpos.front()->toString().to8Bit(true);
                    auto slash = discStr.find('/');
                    if (slash != std::string::npos) {
                        info.discNumber = std::atoi(discStr.substr(0, slash).c_str());
                    } else {
                        info.discNumber = std::atoi(discStr.c_str());
                    }
                }
                // TSRC = ISRC
                auto tsrc = id3v2->frameList("TSRC");
                if (!tsrc.isEmpty()) {
                    info.isrc = tsrc.front()->toString().to8Bit(true);
                }
                // TXXX = MusicBrainz 标识符
                auto txxxList = id3v2->frameList("TXXX");
                for (auto* f : txxxList) {
                    auto* txxx = dynamic_cast<TagLib::ID3v2::UserTextIdentificationFrame*>(f);
                    if (!txxx) continue;
                    std::string desc = txxx->description().to8Bit(true);
                    auto values = txxx->fieldList();
                    if (values.isEmpty()) continue;
                    std::string val = values.front().to8Bit(true);
                    if (desc == "MusicBrainz Recording Id") {
                        info.mbid = val;
                    } else if (desc == "MusicBrainz Album Id") {
                        info.albumMbid = val;
                    } else if (desc == "MusicBrainz Artist Id") {
                        info.artistMbid = val;
                    }
                }
            }
            return;
        }

        // 尝试读取 FLAC/OGG Vorbis Comments
        auto* flacFile = dynamic_cast<TagLib::FLAC::File*>(file);
        if (flacFile) {
            TagLib::Ogg::XiphComment* vc = flacFile->xiphComment(false);
            if (vc) {
                readXiphFields(vc, info);
            }
            return;
        }

        auto* vorbisFile = dynamic_cast<TagLib::Ogg::Vorbis::File*>(file);
        if (vorbisFile) {
            TagLib::Ogg::XiphComment* vc = vorbisFile->tag();
            if (vc) {
                readXiphFields(vc, info);
            }
            return;
        }

        // 尝试读取 Opus 标签
        auto* opusFile = dynamic_cast<TagLib::Ogg::Opus::File*>(file);
        if (opusFile) {
            TagLib::Ogg::XiphComment* vc = opusFile->tag();
            if (vc) {
                readXiphFields(vc, info);
            }
            return;
        }

        // 尝试读取 MP4 标签
        auto* mp4File = dynamic_cast<TagLib::MP4::File*>(file);
        if (mp4File) {
            TagLib::MP4::Tag* mp4Tag = mp4File->tag();
            if (mp4Tag) {
                auto albumArtistItem = mp4Tag->item("aART");
                if (albumArtistItem.isValid()) {
                    info.albumArtist = albumArtistItem.toStringList().toString().to8Bit(true);
                }
                auto composerItem = mp4Tag->item("\251wrt");
                if (composerItem.isValid()) {
                    info.composer = composerItem.toStringList().toString().to8Bit(true);
                }
                auto discItem = mp4Tag->item("disk");
                if (discItem.isValid()) {
                    auto discInt = discItem.toInt();
                    if (discInt > 0) info.discNumber = discInt;
                }
                // freeform 标签：----com.apple.iTunes:xxx
                auto mbidItem = mp4Tag->item("----com.apple.iTunes:MusicBrainz Track Id");
                if (mbidItem.isValid()) {
                    info.mbid = mbidItem.toStringList().toString().to8Bit(true);
                }
                auto isrcItem = mp4Tag->item("----com.apple.iTunes:ISRC");
                if (isrcItem.isValid()) {
                    info.isrc = isrcItem.toStringList().toString().to8Bit(true);
                }
            }
            return;
        }
    }

    /// 读取 Xiph Comment 字段（FLAC/OGG）
    void readXiphFields(TagLib::Ogg::XiphComment* vc, TrackInfo& info) {
        auto& flm = vc->fieldListMap();
        auto albumArtist = flm["ALBUMARTIST"];
        if (!albumArtist.isEmpty()) {
            info.albumArtist = albumArtist.front().to8Bit(true);
        }
        auto composer = flm["COMPOSER"];
        if (!composer.isEmpty()) {
            info.composer = composer.front().to8Bit(true);
        }
        auto disc = flm["DISCNUMBER"];
        if (!disc.isEmpty()) {
            std::string discStr = disc.front().to8Bit(true);
            auto slash = discStr.find('/');
            if (slash != std::string::npos) {
                info.discNumber = std::atoi(discStr.substr(0, slash).c_str());
            } else {
                info.discNumber = std::atoi(discStr.c_str());
            }
        }
        // ISRC
        auto isrc = flm["ISRC"];
        if (!isrc.isEmpty()) {
            info.isrc = isrc.front().to8Bit(true);
        }
        // MusicBrainz 标识符（支持多种命名约定）
        auto mbid = flm["MUSICBRAINZ_RECORDINGID"];
        if (mbid.isEmpty()) mbid = flm["MUSICBRAINZ_TRACKID"];
        if (!mbid.isEmpty()) {
            info.mbid = mbid.front().to8Bit(true);
        }
        auto albumMbid = flm["MUSICBRAINZ_ALBUMID"];
        if (!albumMbid.isEmpty()) {
            info.albumMbid = albumMbid.front().to8Bit(true);
        }
        auto artistMbid = flm["MUSICBRAINZ_ARTISTID"];
        if (!artistMbid.isEmpty()) {
            info.artistMbid = artistMbid.front().to8Bit(true);
        }
    }

    std::string lastError_;
    ScraperConfig cfg_;
};

} // namespace archoera::scraper
