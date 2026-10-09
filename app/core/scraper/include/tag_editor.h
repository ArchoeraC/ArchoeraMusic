// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

/// Archoera 刮削器 —— 单文件标签读取 / 编辑（header-only）
///
/// 与 tag_writer.h 的区别：tag_writer 是「刮削结果写入器」（只写不删、跳过空值），
/// 本文件是「标签编辑器」——面向用户手动编辑单个文件：
///   - read()  读取原始标签（不套用 FileScanner 的文件名优先启发式），
///             供编辑界面回显；
///   - write() 对「受管字段」做完整覆盖：空串 / <=0 表示清除；
///             受管字段之外（MusicBrainz ID、自定义 TXXX 等）原样保留。
///
/// 支持格式：MP3 / FLAC / OGG / Opus / WAV / AIFF / M4A / MP4 等，
/// 未知格式回退到 TagLib::FileRef 通用接口。
///
/// 内部字符串一律 UTF-8；文件路径经 utf8ToPath 转换（Windows 安全）。

#include "scraper.h"
#include "scraper_log.h"

#include <taglib/tag.h>
#include <taglib/fileref.h>
#include <taglib/audioproperties.h>
#include <taglib/mpegfile.h>
#include <taglib/id3v2tag.h>
#include <taglib/id3v2frame.h>
#include <taglib/attachedpictureframe.h>
#include <taglib/textidentificationframe.h>
#include <taglib/unsynchronizedlyricsframe.h>
#include <taglib/flacfile.h>
#include <taglib/flacpicture.h>
#include <taglib/vorbisfile.h>
#include <taglib/opusfile.h>
#include <taglib/oggfile.h>
#include <taglib/xiphcomment.h>
#include <taglib/wavfile.h>
#include <taglib/aifffile.h>
#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4coverart.h>
#include <taglib/mp4item.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

namespace archoera::scraper {

/// 单文件可编辑标签集合。
/// 空字符串 / <=0 表示「清除该字段」（见 TagEditor::write）。
struct EditTags {
    std::string title;
    std::string artist;
    std::string album;
    std::string albumArtist;
    std::string composer;
    std::string genre;
    int trackNumber = 0;   ///< <=0 表示清除
    int discNumber = 0;    ///< <=0 表示清除
    int year = 0;          ///< <=0 表示清除
    std::string lyrics;                ///< 空表示清除
    std::vector<uint8_t> coverData;
    std::string coverMime;
    bool coverSet = false;             ///< 是否触碰封面（false 则完全保留原封面）
};

/// 单文件标签编辑器。
class TagEditor {
public:
    TagEditor() = default;
    ~TagEditor() = default;

    TagEditor(const TagEditor&) = delete;
    TagEditor& operator=(const TagEditor&) = delete;

    /// 读取文件原始标签（不套用文件名优先启发式）。
    /// @param filePath   音频文件路径（UTF-8）
    /// @param out        输出标签（失败时保持清空）
    /// @param durationMs 音频时长（毫秒；未知为 0）
    /// @param err        失败原因
    /// @return true 成功 / false 失败
    static bool read(const std::string& filePath, EditTags& out,
                     int& durationMs, std::string& err) {
        out = EditTags{};
        durationMs = 0;
        try {
            const auto fileP = utf8ToPath(filePath);
            TagLib::FileRef f(fileP.c_str());
            if (f.isNull() || !f.file()) {
                err = "无法打开文件: " + filePath;
                return false;
            }
            TagLib::Tag* tag = f.tag();
            if (!tag) {
                err = "文件不支持标签: " + filePath;
                return false;
            }

            // 基本字段
            out.title = tag->title().to8Bit(true);
            out.artist = tag->artist().to8Bit(true);
            out.album = tag->album().to8Bit(true);
            out.genre = tag->genre().to8Bit(true);
            out.trackNumber = static_cast<int>(tag->track());
            out.year = tag->year() > 0 ? static_cast<int>(tag->year()) : 0;

            // 时长
            if (TagLib::AudioProperties* props = f.audioProperties()) {
                durationMs = props->lengthInMilliseconds();
            }

            // 扩展字段（albumArtist / composer / discNumber / lyrics / cover）
            readExtended(f.file(), out);
            return true;
        } catch (const std::exception& e) {
            err = std::string("读取标签异常: ") + e.what();
            return false;
        }
    }

    /// 写入受管字段（空串 / <=0 清除）；未列出的字段（MBID、自定义 TXXX 等）保留。
    /// 封面仅在 tags.coverSet=true 时处理（先清空全部封面，再按需写入 FrontCover）。
    /// @param filePath 音频文件路径（UTF-8）
    /// @param tags     要写入的标签
    /// @param err      失败原因
    /// @return true 成功 / false 失败
    bool write(const std::string& filePath, const EditTags& tags, std::string& err) {
        lastError_.clear();
        try {
            const std::string ext = extOf(filePath);

            bool ok = false;
            if (ext == "mp3") {
                ok = writeMp3(filePath, tags);
            } else if (ext == "flac") {
                ok = writeFlac(filePath, tags);
            } else if (ext == "ogg" || ext == "oga" || ext == "opus") {
                ok = writeOgg(filePath, tags, ext == "opus");
            } else if (ext == "wav") {
                ok = writeWav(filePath, tags);
            } else if (ext == "aiff" || ext == "aif") {
                ok = writeAiff(filePath, tags);
            } else if (ext == "m4a" || ext == "aac" || ext == "mp4") {
                ok = writeMp4(filePath, tags);
            } else {
                ok = writeGeneric(filePath, tags);
            }

            if (!ok) {
                err = lastError_;
                return false;
            }
            return true;
        } catch (const std::exception& e) {
            lastError_ = std::string("标签写入异常: ") + e.what();
            err = lastError_;
            return false;
        }
    }

    const std::string& lastError() const { return lastError_; }

private:
    // ───────────────────────────── 工具函数 ─────────────────────────────

    /// TagLib UTF-8 字符串。
    static TagLib::String ts(const std::string& s) {
        return TagLib::String(s, TagLib::String::UTF8);
    }

    /// 小写扩展名（无点；识别不到返回空串）。
    static std::string extOf(const std::string& filePath) {
        const size_t dot = filePath.find_last_of('.');
        if (dot == std::string::npos) return "";
        std::string ext = filePath.substr(dot + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return ext;
    }

    /// MIME 归一化：image/jpg → image/jpeg，其余小写。
    static std::string normalizedMime(const std::string& mime) {
        std::string n = mime;
        std::transform(n.begin(), n.end(), n.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (n == "image/jpg") return "image/jpeg";
        return n;
    }

    /// 解析 "1" 或 "1/2" 形式编号，取斜杠前整数；非法返回 0。
    static int parseNumber(const std::string& s) {
        const size_t slash = s.find('/');
        const std::string head = (slash == std::string::npos) ? s : s.substr(0, slash);
        return std::atoi(head.c_str());
    }

    /// ByteVector → std::vector<uint8_t>。
    static std::vector<uint8_t> toVector(const TagLib::ByteVector& bv) {
        const auto* p = reinterpret_cast<const uint8_t*>(bv.data());
        return std::vector<uint8_t>(p, p + bv.size());
    }

    /// std::vector<uint8_t> → ByteVector。
    static TagLib::ByteVector toByteVector(const std::vector<uint8_t>& v) {
        return TagLib::ByteVector(reinterpret_cast<const char*>(v.data()), v.size());
    }

    // ───────────────────────────── 读取：扩展字段 ─────────────────────────────

    /// 按文件实际类型读取扩展字段。
    static void readExtended(TagLib::File* file, EditTags& out) {
        if (auto* mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
            readId3Extended(mpeg->ID3v2Tag(false), out);
            return;
        }
        if (auto* wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
            readId3Extended(wav->ID3v2Tag(), out);
            return;
        }
        if (auto* aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
            readId3Extended(aiff->tag(), out);
            return;
        }
        if (auto* flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
            if (auto* vc = flac->xiphComment(false)) readXiphFields(vc, out);
            readFlacCover(flac, out);
            return;
        }
        if (auto* vorbis = dynamic_cast<TagLib::Ogg::Vorbis::File*>(file)) {
            readOggCover(vorbis->tag(), out);
            return;
        }
        if (auto* opus = dynamic_cast<TagLib::Ogg::Opus::File*>(file)) {
            readOggCover(opus->tag(), out);
            return;
        }
        if (auto* mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
            readMp4Extended(mp4->tag(), out);
            return;
        }
    }

    /// ID3v2 扩展字段（MP3/WAV/AIFF）。
    static void readId3Extended(TagLib::ID3v2::Tag* id3, EditTags& out) {
        if (!id3) return;

        auto tpe2 = id3->frameList("TPE2");
        if (!tpe2.isEmpty()) out.albumArtist = tpe2.front()->toString().to8Bit(true);

        auto tcom = id3->frameList("TCOM");
        if (!tcom.isEmpty()) out.composer = tcom.front()->toString().to8Bit(true);

        auto tpos = id3->frameList("TPOS");
        if (!tpos.isEmpty()) out.discNumber = parseNumber(tpos.front()->toString().to8Bit(true));

        auto uslt = id3->frameList("USLT");
        if (!uslt.isEmpty()) {
            if (auto* lyr = dynamic_cast<TagLib::ID3v2::UnsynchronizedLyricsFrame*>(uslt.front())) {
                out.lyrics = lyr->text().to8Bit(true);
            }
        }

        auto apic = id3->frameList("APIC");
        if (!apic.isEmpty()) {
            if (auto* pic = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame*>(apic.front())) {
                out.coverMime = normalizedMime(pic->mimeType().to8Bit(true));
                out.coverData = toVector(pic->picture());
            }
        }
    }

    /// Xiph Comment 字段（FLAC/OGG/Opus）。
    static void readXiphFields(TagLib::Ogg::XiphComment* vc, EditTags& out) {
        if (!vc) return;
        const auto& flm = vc->fieldListMap();

        auto albumArtist = flm["ALBUMARTIST"];
        if (!albumArtist.isEmpty()) out.albumArtist = albumArtist.front().to8Bit(true);

        auto composer = flm["COMPOSER"];
        if (!composer.isEmpty()) out.composer = composer.front().to8Bit(true);

        auto disc = flm["DISCNUMBER"];
        if (!disc.isEmpty()) out.discNumber = parseNumber(disc.front().to8Bit(true));

        auto lyrics = flm["LYRICS"];
        if (!lyrics.isEmpty()) out.lyrics = lyrics.front().to8Bit(true);
    }

    /// FLAC 封面（首个 Picture 块）。
    static void readFlacCover(TagLib::FLAC::File* f, EditTags& out) {
        auto pics = f->pictureList();
        if (pics.isEmpty() || !pics.front()) return;
        out.coverMime = normalizedMime(pics.front()->mimeType().to8Bit(true));
        out.coverData = toVector(pics.front()->data());
    }

    /// OGG/Opus 封面（首个 Xiph Picture）。
    static void readOggCover(TagLib::Ogg::XiphComment* vc, EditTags& out) {
        if (!vc) return;
        readXiphFields(vc, out);

        auto pics = vc->pictureList();
        if (pics.isEmpty() || !pics.front()) return;
        out.coverMime = normalizedMime(pics.front()->mimeType().to8Bit(true));
        out.coverData = toVector(pics.front()->data());
    }

    /// MP4 扩展字段（M4A/AAC/MP4）。
    static void readMp4Extended(TagLib::MP4::Tag* tag, EditTags& out) {
        if (!tag) return;

        auto aart = tag->item("aART");
        if (aart.isValid()) out.albumArtist = aart.toStringList().toString().to8Bit(true);

        auto wrt = tag->item("\251wrt");
        if (wrt.isValid()) out.composer = wrt.toStringList().toString().to8Bit(true);

        auto disk = tag->item("disk");
        if (disk.isValid()) {
            const auto pair = disk.toIntPair();
            if (pair.first > 0) {
                out.discNumber = pair.first;
            } else {
                const int v = disk.toInt();
                if (v > 0) out.discNumber = v;
            }
        }

        auto lyr = tag->item("\251lyr");
        if (lyr.isValid()) out.lyrics = lyr.toStringList().toString().to8Bit(true);

        auto covr = tag->item("covr");
        if (covr.isValid()) {
            const auto list = covr.toCoverArtList();
            if (!list.isEmpty()) {
                const auto& art = list.front();
                switch (art.format()) {
                    case TagLib::MP4::CoverArt::JPEG: out.coverMime = "image/jpeg"; break;
                    case TagLib::MP4::CoverArt::PNG:  out.coverMime = "image/png";  break;
                    default: return;  // 不支持的封面格式 → 不输出
                }
                out.coverData = toVector(art.data());
            }
        }
    }

    // ───────────────────────────── 写入：各格式 ─────────────────────────────

    /// 基本字段（Tag 通用接口；空串 / 0 即清除）。
    static void applyBasic(TagLib::Tag* tag, const EditTags& t) {
        if (!tag) return;
        tag->setTitle(ts(t.title));
        tag->setArtist(ts(t.artist));
        tag->setAlbum(ts(t.album));
        tag->setGenre(ts(t.genre));
        tag->setYear(t.year > 0 ? static_cast<unsigned int>(t.year) : 0u);
        tag->setTrack(t.trackNumber > 0 ? static_cast<unsigned int>(t.trackNumber) : 0u);
    }

    bool writeMp3(const std::string& filePath, const EditTags& t) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::MPEG::File f(fileP.c_str());
        if (!f.isValid()) {
            lastError_ = "无法打开 MP3 文件: " + filePath;
            return false;
        }
        TagLib::ID3v2::Tag* id3 = f.ID3v2Tag(true);
        applyBasic(f.tag(), t);
        applyId3Extended(id3, t);
        if (t.coverSet) applyId3Cover(id3, t);
        if (!f.save()) {
            lastError_ = "保存 MP3 标签失败";
            return false;
        }
        return true;
    }

    bool writeFlac(const std::string& filePath, const EditTags& t) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::FLAC::File f(fileP.c_str());
        if (!f.isValid()) {
            lastError_ = "无法打开 FLAC 文件: " + filePath;
            return false;
        }
        TagLib::Ogg::XiphComment* vc = f.xiphComment(true);
        applyBasic(vc, t);
        applyXiphExtended(vc, t);
        if (t.coverSet) applyFlacCover(&f, t);
        if (!f.save()) {
            lastError_ = "保存 FLAC 标签失败";
            return false;
        }
        return true;
    }

    bool writeOgg(const std::string& filePath, const EditTags& t, bool isOpus) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::File* file = isOpus
            ? static_cast<TagLib::File*>(new TagLib::Ogg::Opus::File(fileP.c_str()))
            : static_cast<TagLib::File*>(new TagLib::Ogg::Vorbis::File(fileP.c_str()));

        if (!file->isValid()) {
            delete file;
            lastError_ = "无法打开 OGG/Opus 文件: " + filePath;
            return false;
        }
        auto* vc = dynamic_cast<TagLib::Ogg::XiphComment*>(file->tag());
        applyBasic(vc, t);
        applyXiphExtended(vc, t);
        if (t.coverSet) applyXiphCover(vc, t);

        if (!file->save()) {
            delete file;
            lastError_ = "保存 OGG/Opus 标签失败";
            return false;
        }
        delete file;
        return true;
    }

    bool writeWav(const std::string& filePath, const EditTags& t) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::RIFF::WAV::File f(fileP.c_str());
        if (!f.isValid()) {
            lastError_ = "无法打开 WAV 文件: " + filePath;
            return false;
        }
        TagLib::ID3v2::Tag* id3 = f.ID3v2Tag();
        applyBasic(f.tag(), t);
        applyId3Extended(id3, t);
        if (t.coverSet) applyId3Cover(id3, t);
        if (!f.save()) {
            lastError_ = "保存 WAV 标签失败";
            return false;
        }
        return true;
    }

    bool writeAiff(const std::string& filePath, const EditTags& t) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::RIFF::AIFF::File f(fileP.c_str());
        if (!f.isValid()) {
            lastError_ = "无法打开 AIFF 文件: " + filePath;
            return false;
        }
        TagLib::ID3v2::Tag* id3 = f.tag();
        applyBasic(id3, t);
        applyId3Extended(id3, t);
        if (t.coverSet) applyId3Cover(id3, t);
        if (!f.save()) {
            lastError_ = "保存 AIFF 标签失败";
            return false;
        }
        return true;
    }

    bool writeMp4(const std::string& filePath, const EditTags& t) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::MP4::File f(fileP.c_str());
        if (!f.isValid()) {
            lastError_ = "无法打开 MP4/M4A 文件: " + filePath;
            return false;
        }
        TagLib::MP4::Tag* tag = f.tag();
        applyBasic(tag, t);
        applyMp4Extended(tag, t);
        if (t.coverSet) applyMp4Cover(tag, t);
        if (!f.save()) {
            lastError_ = "保存 MP4/M4A 标签失败";
            return false;
        }
        return true;
    }

    bool writeGeneric(const std::string& filePath, const EditTags& t) {
        const auto fileP = utf8ToPath(filePath);
        TagLib::FileRef f(fileP.c_str());
        if (f.isNull() || !f.file()) {
            lastError_ = "无法打开文件: " + filePath;
            return false;
        }
        TagLib::Tag* tag = f.tag();
        if (!tag) {
            lastError_ = "文件不支持标签写入";
            return false;
        }
        applyBasic(tag, t);
        applyExtendedGeneric(f.file(), t);
        if (t.coverSet) applyCoverGeneric(f.file(), t);
        if (!f.save()) {
            lastError_ = "保存标签失败";
            return false;
        }
        return true;
    }

    // ───────────────────────────── 写入：扩展字段 ─────────────────────────────

    /// ID3v2 扩展字段（先移除受管帧，再按非空写回；其余帧保留）。
    static void applyId3Extended(TagLib::ID3v2::Tag* id3, const EditTags& t) {
        if (!id3) return;

        id3->removeFrames("TPE2");
        if (!t.albumArtist.empty()) {
            auto* frame = new TagLib::ID3v2::TextIdentificationFrame("TPE2", TagLib::String::UTF8);
            frame->setText(ts(t.albumArtist));
            id3->addFrame(frame);
        }

        id3->removeFrames("TCOM");
        if (!t.composer.empty()) {
            auto* frame = new TagLib::ID3v2::TextIdentificationFrame("TCOM", TagLib::String::UTF8);
            frame->setText(ts(t.composer));
            id3->addFrame(frame);
        }

        id3->removeFrames("TPOS");
        if (t.discNumber > 0) {
            auto* frame = new TagLib::ID3v2::TextIdentificationFrame("TPOS", TagLib::String::UTF8);
            frame->setText(ts(std::to_string(t.discNumber)));
            id3->addFrame(frame);
        }

        id3->removeFrames("USLT");
        if (!t.lyrics.empty()) {
            auto* uslt = new TagLib::ID3v2::UnsynchronizedLyricsFrame();
            uslt->setLanguage(TagLib::ByteVector("XXX", 3));
            uslt->setText(ts(t.lyrics));
            id3->addFrame(uslt);
        }
    }

    /// ID3v2 封面：先移除全部 APIC，再按需写入 FrontCover。
    static void applyId3Cover(TagLib::ID3v2::Tag* id3, const EditTags& t) {
        if (!id3) return;
        id3->removeFrames("APIC");
        if (t.coverData.empty()) return;

        auto* pic = new TagLib::ID3v2::AttachedPictureFrame();
        pic->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
        pic->setMimeType(TagLib::String(normalizedMime(t.coverMime), TagLib::String::Latin1));
        pic->setDescription(ts("Front Cover"));
        pic->setPicture(toByteVector(t.coverData));
        id3->addFrame(pic);
    }

    /// Xiph Comment 扩展字段（先移除受管键，再按非空写回；其余键保留）。
    static void applyXiphExtended(TagLib::Ogg::XiphComment* vc, const EditTags& t) {
        if (!vc) return;

        auto setField = [vc](const char* key, const std::string& value) {
            vc->removeFields(TagLib::String(key, TagLib::String::Latin1));
            if (!value.empty()) vc->addField(key, ts(value), true);
        };

        setField("ALBUMARTIST", t.albumArtist);
        setField("COMPOSER", t.composer);
        setField("DISCNUMBER", t.discNumber > 0 ? std::to_string(t.discNumber) : std::string());
        setField("LYRICS", t.lyrics);
    }

    /// Xiph 封面：先移除全部 Picture，再按需写入 FrontCover。
    static void applyXiphCover(TagLib::Ogg::XiphComment* vc, const EditTags& t) {
        if (!vc) return;
        auto existing = vc->pictureList();
        for (auto* pic : existing) {
            vc->removePicture(pic, true);
        }
        if (t.coverData.empty()) return;

        auto* picture = new TagLib::FLAC::Picture();
        picture->setType(TagLib::FLAC::Picture::FrontCover);
        picture->setMimeType(TagLib::String(normalizedMime(t.coverMime), TagLib::String::Latin1));
        picture->setDescription(ts("Front Cover"));
        applyImageMetadata(picture, t.coverData, t.coverMime);
        picture->setData(toByteVector(t.coverData));
        vc->addPicture(picture);
    }

    /// FLAC 封面：先移除全部 Picture 块，再按需写入 FrontCover。
    static void applyFlacCover(TagLib::FLAC::File* f, const EditTags& t) {
        if (!f) return;
        f->removePictures();
        if (t.coverData.empty()) return;

        auto* picture = new TagLib::FLAC::Picture();
        picture->setType(TagLib::FLAC::Picture::FrontCover);
        picture->setMimeType(TagLib::String(normalizedMime(t.coverMime), TagLib::String::Latin1));
        picture->setDescription(ts("Front Cover"));
        applyImageMetadata(picture, t.coverData, t.coverMime);
        picture->setData(toByteVector(t.coverData));
        f->addPicture(picture);
    }

    /// MP4 扩展字段（先移除受管项，再按非空写回）。
    static void applyMp4Extended(TagLib::MP4::Tag* tag, const EditTags& t) {
        if (!tag) return;

        auto setText = [tag](const char* key, const std::string& value) {
            const TagLib::String k(key, TagLib::String::Latin1);
            tag->removeItem(k);
            if (!value.empty()) {
                tag->setItem(k, TagLib::MP4::Item(TagLib::StringList(ts(value))));
            }
        };

        setText("aART", t.albumArtist);
        setText("\251wrt", t.composer);
        setText("\251lyr", t.lyrics);

        tag->removeItem(TagLib::String("disk", TagLib::String::Latin1));
        if (t.discNumber > 0) {
            tag->setItem(TagLib::String("disk", TagLib::String::Latin1),
                         TagLib::MP4::Item(t.discNumber, 0));
        }
    }

    /// MP4 封面：先移除 covr，再按需写入（仅 JPEG/PNG 支持）。
    static void applyMp4Cover(TagLib::MP4::Tag* tag, const EditTags& t) {
        if (!tag) return;
        tag->removeItem(TagLib::String("covr", TagLib::String::Latin1));
        if (t.coverData.empty()) return;

        const std::string mime = normalizedMime(t.coverMime);
        TagLib::MP4::CoverArt::Format format;
        if (mime == "image/png") {
            format = TagLib::MP4::CoverArt::PNG;
        } else if (mime == "image/jpeg") {
            format = TagLib::MP4::CoverArt::JPEG;
        } else {
            SCRAPER_LOGW(NULL, "[tag_editor] MP4 不支持 %s 封面，跳过（仅 JPEG/PNG）",
                         t.coverMime.c_str());
            return;
        }

        TagLib::MP4::CoverArtList list;
        list.append(TagLib::MP4::CoverArt(format, toByteVector(t.coverData)));
        tag->setItem(TagLib::String("covr", TagLib::String::Latin1), list);
    }

    /// 通用（未知格式）扩展字段：按实际类型动态分发。
    static void applyExtendedGeneric(TagLib::File* file, const EditTags& t) {
        if (auto* mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
            applyId3Extended(mpeg->ID3v2Tag(true), t);
            return;
        }
        if (auto* wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
            applyId3Extended(wav->ID3v2Tag(), t);
            return;
        }
        if (auto* aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
            applyId3Extended(aiff->tag(), t);
            return;
        }
        if (auto* flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
            applyXiphExtended(flac->xiphComment(true), t);
            return;
        }
        if (auto* ogg = dynamic_cast<TagLib::Ogg::File*>(file)) {
            applyXiphExtended(dynamic_cast<TagLib::Ogg::XiphComment*>(ogg->tag()), t);
            return;
        }
        if (auto* mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
            applyMp4Extended(mp4->tag(), t);
            return;
        }
    }

    /// 通用（未知格式）封面：按实际类型动态分发。
    static void applyCoverGeneric(TagLib::File* file, const EditTags& t) {
        if (auto* mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
            applyId3Cover(mpeg->ID3v2Tag(true), t);
            return;
        }
        if (auto* wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
            applyId3Cover(wav->ID3v2Tag(), t);
            return;
        }
        if (auto* aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
            applyId3Cover(aiff->tag(), t);
            return;
        }
        if (auto* flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
            applyFlacCover(flac, t);
            return;
        }
        if (auto* ogg = dynamic_cast<TagLib::Ogg::File*>(file)) {
            applyXiphCover(dynamic_cast<TagLib::Ogg::XiphComment*>(ogg->tag()), t);
            return;
        }
        if (auto* mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
            applyMp4Cover(mp4->tag(), t);
            return;
        }
    }

    // ──────────────── 图像元数据解析（自 tag_writer.h，本项目自有实现）───────────────

    struct ImageInfo {
        int width = 0;
        int height = 0;
        int depth = 0;
        int colors = 0;
    };

    static uint16_t readBe16(const uint8_t* p) {
        return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
    }

    static uint32_t readBe32(const uint8_t* p) {
        return (static_cast<uint32_t>(p[0]) << 24) |
               (static_cast<uint32_t>(p[1]) << 16) |
               (static_cast<uint32_t>(p[2]) << 8) |
               static_cast<uint32_t>(p[3]);
    }

    static uint32_t readLe16(const uint8_t* p) {
        return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8);
    }

    static uint32_t readLe24(const uint8_t* p) {
        return static_cast<uint32_t>(p[0]) |
               (static_cast<uint32_t>(p[1]) << 8) |
               (static_cast<uint32_t>(p[2]) << 16);
    }

    static uint32_t readLe32(const uint8_t* p) {
        return static_cast<uint32_t>(p[0]) |
               (static_cast<uint32_t>(p[1]) << 8) |
               (static_cast<uint32_t>(p[2]) << 16) |
               (static_cast<uint32_t>(p[3]) << 24);
    }

    static std::optional<ImageInfo> parseImageInfo(const std::vector<uint8_t>& data,
                                                   const std::string& mime) {
        const auto normalized = normalizedMime(mime);
        if (normalized == "image/png") {
            if (data.size() < 29) return std::nullopt;
            static constexpr uint8_t kPngSig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
            if (!std::equal(std::begin(kPngSig), std::end(kPngSig), data.begin())) return std::nullopt;
            if (!(data[12] == 'I' && data[13] == 'H' && data[14] == 'D' && data[15] == 'R')) return std::nullopt;
            ImageInfo info;
            info.width = static_cast<int>(readBe32(data.data() + 16));
            info.height = static_cast<int>(readBe32(data.data() + 20));
            info.depth = static_cast<int>(data[24]);
            if (data[25] == 2) info.depth *= 3;
            else if (data[25] == 4) info.depth *= 2;
            else if (data[25] == 6) info.depth *= 4;
            return info;
        }

        if (normalized == "image/gif") {
            if (data.size() < 11) return std::nullopt;
            if (!(data[0] == 'G' && data[1] == 'I' && data[2] == 'F' && data[3] == '8' &&
                  (data[4] == '7' || data[4] == '9') && data[5] == 'a')) {
                return std::nullopt;
            }
            ImageInfo info;
            info.width = static_cast<int>(readLe16(data.data() + 6));
            info.height = static_cast<int>(readLe16(data.data() + 8));
            const uint8_t packed = data[10];
            info.depth = (packed & 0x07) + 1;
            info.colors = (packed & 0x80) ? (1 << info.depth) : 0;
            return info;
        }

        if (normalized == "image/webp") {
            if (data.size() < 30) return std::nullopt;
            if (!(data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F' &&
                  data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P')) {
                return std::nullopt;
            }
            ImageInfo info;
            if (data[12] == 'V' && data[13] == 'P' && data[14] == '8' && data[15] == 'X' && data.size() >= 30) {
                info.width = static_cast<int>(1 + readLe24(data.data() + 24));
                info.height = static_cast<int>(1 + readLe24(data.data() + 27));
                return info;
            }
            if (data[12] == 'V' && data[13] == 'P' && data[14] == '8' && data[15] == ' ' && data.size() >= 30) {
                info.width = static_cast<int>(readLe16(data.data() + 26) & 0x3FFF);
                info.height = static_cast<int>(readLe16(data.data() + 28) & 0x3FFF);
                return info;
            }
            if (data[12] == 'V' && data[13] == 'P' && data[14] == '8' && data[15] == 'L' && data.size() >= 25) {
                const uint32_t bits = readLe32(data.data() + 21);
                info.width = static_cast<int>((bits & 0x3FFF) + 1);
                info.height = static_cast<int>(((bits >> 14) & 0x3FFF) + 1);
                return info;
            }
            return std::nullopt;
        }

        if (normalized == "image/jpeg") {
            if (data.size() < 4 || data[0] != 0xFF || data[1] != 0xD8) return std::nullopt;
            size_t i = 2;
            while (i + 8 < data.size()) {
                if (data[i] != 0xFF) {
                    ++i;
                    continue;
                }
                while (i < data.size() && data[i] == 0xFF) ++i;
                if (i >= data.size()) break;
                const uint8_t marker = data[i++];
                if (marker == 0xD8 || marker == 0xD9) continue;
                if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
                if (i + 2 > data.size()) break;
                const auto segmentLength = readBe16(data.data() + i);
                if (segmentLength < 2 || i + segmentLength > data.size()) break;
                if ((marker >= 0xC0 && marker <= 0xC3) ||
                    (marker >= 0xC5 && marker <= 0xC7) ||
                    (marker >= 0xC9 && marker <= 0xCB) ||
                    (marker >= 0xCD && marker <= 0xCF)) {
                    ImageInfo info;
                    info.depth = static_cast<int>(data[i + 2]);
                    info.height = static_cast<int>(readBe16(data.data() + i + 3));
                    info.width = static_cast<int>(readBe16(data.data() + i + 5));
                    const int channels = static_cast<int>(data[i + 7]);
                    if (channels > 0) info.depth *= channels;
                    return info;
                }
                i += segmentLength;
            }
        }

        return std::nullopt;
    }

    static void applyImageMetadata(TagLib::FLAC::Picture* picture,
                                   const std::vector<uint8_t>& data,
                                   const std::string& mime) {
        if (!picture) return;
        const auto info = parseImageInfo(data, mime);
        if (!info) return;
        picture->setWidth(info->width);
        picture->setHeight(info->height);
        picture->setColorDepth(info->depth);
        picture->setNumColors(info->colors);
    }

    std::string lastError_;
};

} // namespace archoera::scraper
