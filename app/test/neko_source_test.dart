// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 实验性音源 NekoMusic（`neko`）纯函数 / 模型单测：服务器地址归一化、
// Track 映射、用户会话往返、二维码图片解码与状态解析。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/lyric/format.dart' show kNekoV1LyricsFormat;
import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/services/lyrics/engine/lyric_source.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/lyrics/sources/neko_lyric_source.dart';
import 'package:archoera_music/services/neko/neko_api.dart';
import 'package:archoera_music/services/neko/neko_audio.dart';
import 'package:archoera_music/services/neko/neko_lyrics.dart';
import 'package:archoera_music/services/neko/neko_quality.dart';
import 'package:archoera_music/services/neko/neko_types.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/providers.dart';

void main() {
  group('normalizeNekoBaseUrl', () {
    test('空值 / 空白回退默认站点', () {
      expect(normalizeNekoBaseUrl(null), kDefaultNekoBaseUrl);
      expect(normalizeNekoBaseUrl('   '), kDefaultNekoBaseUrl);
    });

    test('补 scheme 并去除尾斜杠', () {
      expect(
        normalizeNekoBaseUrl('music.nekocore.cn/'),
        'https://music.nekocore.cn',
      );
      expect(
        normalizeNekoBaseUrl('http://127.0.0.1:65535//'),
        'http://127.0.0.1:65535',
      );
    });

    test('保留既有 scheme', () {
      expect(
        normalizeNekoBaseUrl('https://a.b/c'),
        'https://a.b/c',
      );
    });
  });

  group('nekoIsDegradedResponse（防爬降级判定）', () {
    test('GET 200 + SEO HTML / 空体 → 降级', () {
      expect(
        nekoIsDegradedResponse(
          status: 200,
          contentType: 'text/html;charset=UTF-8',
          body: '<!DOCTYPE html><html>...</html>',
        ),
        isTrue,
      );
      expect(
        nekoIsDegradedResponse(status: 200, body: '  <html>x</html>'),
        isTrue,
      );
    });

    test('正常 JSON 200 → 不降级', () {
      expect(
        nekoIsDegradedResponse(
          status: 200,
          contentType: 'application/json',
          body: '{"success":true,"data":{}}',
        ),
        isFalse,
      );
    });

    test('非 GET 403：空体 / HTML / 统一拒绝文案 → 降级；其它 403 不降级', () {
      expect(nekoIsDegradedResponse(status: 403, body: ''), isTrue);
      expect(
        nekoIsDegradedResponse(
          status: 403,
          contentType: 'application/json',
          body: '{"success":false,"message":"请求已拒绝"}',
        ),
        isTrue,
      );
      expect(
        nekoIsDegradedResponse(
          status: 403,
          contentType: 'application/json',
          body: '{"success":false,"message":"无权限"}',
        ),
        isFalse,
      );
    });

    test('其它状态（401 / 409 / 404）不判定为降级', () {
      for (final s in const [401, 404, 409, 429, 500]) {
        expect(
          nekoIsDegradedResponse(status: s, body: '{"success":false}'),
          isFalse,
          reason: '$s',
        );
      }
    });
  });

  group('NekoClient.resolveUrl', () {
    test('相对路径拼接为绝对地址；绝对地址原样返回', () {
      final c = NekoClient(baseUrl: 'https://x.y');
      expect(c.resolveUrl('/api/music/cover/1'), 'https://x.y/api/music/cover/1');
      expect(c.resolveUrl('http://a/b'), 'http://a/b');
    });
  });

  group('Track.fromNekoSong', () {
    test('字段映射 + 封面直链 + 秒转毫秒', () {
      final t = Track.fromNekoSong(
        {
          'id': 42,
          'title': '晴天',
          'artist': '周杰伦',
          'album': '叶惠美',
          'duration': 269,
          'lrc': true,
        },
        baseUrl: 'https://music.nekocore.cn',
      );
      expect(t.source, 'neko');
      expect(t.id, '42');
      expect(t.title, '晴天');
      expect(t.artistNames, '周杰伦');
      expect(t.album?.name, '叶惠美');
      expect(t.album?.cover, 'https://music.nekocore.cn/api/music/cover/42');
      expect(t.duration, 269000);
      expect(t.cover, 'https://music.nekocore.cn/api/music/cover/42');
    });

    test('多歌手分隔 / 无 baseUrl 不产生封面 / 缺字段安全默认', () {
      final t = Track.fromNekoSong({
        'id': 1,
        'title': 'x',
        'artist': 'A、B/C & D',
      });
      expect(t.artists.map((a) => a.name).toList(), ['A', 'B', 'C', 'D']);
      expect(t.cover, isNull);
      expect(t.album, isNull);
      expect(t.duration, 0);
    });
  });

  group('NekoUser 会话往返', () {
    test('toSessionMap → fromSessionMap 保持字段', () {
      const u = NekoUser(
        id: '7',
        nickname: '喵喵',
        email: 'a@b.c',
        isVip: true,
        vipExpiresAt: '2027-01-01T00:00:00',
      );
      final back = NekoUser.fromSessionMap(u.toSessionMap());
      expect(back.id, '7');
      expect(back.nickname, '喵喵');
      expect(back.email, 'a@b.c');
      expect(back.isVip, isTrue);
      expect(back.vipExpiresAt, '2027-01-01T00:00:00');
      expect(back.displayName, '喵喵');
    });

    test('非会员 / 无 vipExpiresAt 往返', () {
      const u = NekoUser(id: '1', nickname: '', email: 'x@y.z');
      final map = u.toSessionMap();
      expect(map.containsKey('vipExpiresAt'), isFalse);
      final back = NekoUser.fromSessionMap(map);
      expect(back.isVip, isFalse);
      expect(back.vipExpiresAt, isNull);
      // 昵称为空时回退邮箱
      expect(back.displayName, 'x@y.z');
    });

    test('fromJson 优先 nickname、兼容旧 username', () {
      expect(NekoUser.fromJson({'id': 1, 'nickname': '新'}).nickname, '新');
      expect(NekoUser.fromJson({'id': 1, 'username': '旧'}).nickname, '旧');
      expect(
        NekoUser.fromJson({'id': 1, 'nickname': '新', 'username': '旧'}).nickname,
        '新',
      );
    });

    test('fromSessionMap 兼容旧 username 键', () {
      expect(
        NekoUser.fromSessionMap({'userId': '1', 'username': '旧'}).nickname,
        '旧',
      );
      expect(
        NekoUser.fromSessionMap({'userId': '1', 'nickname': '新'}).nickname,
        '新',
      );
    });
  });

  group('NekoPlaylist creator 字段', () {
    test('优先 nickname、兼容旧 username、空串 → null', () {
      expect(
        NekoPlaylist.fromJson({
          'id': 1,
          'name': 'p',
          'creator': {'nickname': '甲'},
        }).creator,
        '甲',
      );
      expect(
        NekoPlaylist.fromJson({
          'id': 1,
          'name': 'p',
          'creator': {'username': '乙'},
        }).creator,
        '乙',
      );
      expect(
        NekoPlaylist.fromJson({
          'id': 1,
          'name': 'p',
          'creator': {'nickname': ''},
        }).creator,
        isNull,
      );
    });
  });

  group('sniffAudioExtension（直传文件头嗅探）', () {
    test('fLaC → flac', () {
      expect(sniffAudioExtension([0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 34]), 'flac');
    });

    test('RIFF....WAVE → wav', () {
      final head = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45];
      expect(sniffAudioExtension(head), 'wav');
    });

    test('OggS → ogg', () {
      expect(sniffAudioExtension([0x4F, 0x67, 0x67, 0x53, 0, 2]), 'ogg');
    });

    test('ID3 → mp3；MPEG 帧同步 0xFFEx → mp3', () {
      expect(sniffAudioExtension([0x49, 0x44, 0x33, 0x04]), 'mp3');
      expect(sniffAudioExtension([0xFF, 0xFB, 0x90, 0x00]), 'mp3');
    });

    test('....ftyp（ISO BMFF / m4a）→ m4a', () {
      final head = [
        0x00, 0x00, 0x00, 0x20, // box size
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x4D, 0x34, 0x41, 0x20, // 'M4A '
      ];
      expect(sniffAudioExtension(head), 'm4a');
    });

    test('RIFF 但非 WAVE / 未知 → null', () {
      expect(
        sniffAudioExtension([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x41, 0x56, 0x49, 0x20]),
        isNull,
      );
      expect(sniffAudioExtension([0x00, 0x01, 0x02, 0x03]), isNull);
      expect(sniffAudioExtension(const []), isNull);
    });
  });

  group('parseNekoLyrics（非标准 LRC 归一化）', () {
    test('正文带时间戳 + 下一行 {"译文"}：译文独立成行、同时间戳', () {
      final p = parseNekoLyrics(
        '[00:12.34]晴天\n'
        '{"Sunny day"}\n'
        '[00:15.00]故事的小黄花\n'
        "{'The little yellow flower of the story'}\n",
      );
      expect(p.content, '[00:12.34]晴天\n[00:15.00]故事的小黄花');
      expect(
        p.translation,
        '[00:12.34]Sunny day\n'
        '[00:15.00]The little yellow flower of the story',
      );
    });

    test('整行 [mm:ss.xx]{"译文"}（译文自带时间戳）也归一化', () {
      final p = parseNekoLyrics(
        '[00:01.00]原文一\n'
        '[00:01.00]{"译文一"}\n'
        '[00:02.00]原文二\n'
        '{"译文二"}\n',
      );
      expect(p.content, '[00:01.00]原文一\n[00:02.00]原文二');
      expect(p.translation, '[00:01.00]译文一\n[00:02.00]译文二');
    });

    test('一行多时间戳：正文保留原样，译文按全部时间戳展开', () {
      final p = parseNekoLyrics(
        '[00:01.00][00:05.00]副歌\n'
        '{"Chorus"}\n',
      );
      expect(p.content, '[00:01.00][00:05.00]副歌');
      expect(p.translation, '[00:01.00]Chorus\n[00:05.00]Chorus');
    });

    test('# 注释 / 元信息行被忽略；无译文时 translation 为 null', () {
      final p = parseNekoLyrics(
        '# 本歌词由 XX 提供\n'
        '[ar:某歌手]\n'
        '[00:01.00]只有正文\n',
      );
      expect(p.content, '[00:01.00]只有正文');
      expect(p.translation, isNull);
    });

    test('孤立 {"译文"}（前面无正文）不产生悬空译文', () {
      final p = parseNekoLyrics('{"没有归属"}\n[00:01.00]正文\n');
      expect(p.content, '[00:01.00]正文');
      expect(p.translation, isNull);
    });

    test('大括号但非引号包裹的正文行：视为译文（宽松兼容）', () {
      final p = parseNekoLyrics(
        '[00:01.00]正文\n'
        '{中文翻译}\n',
      );
      expect(p.translation, '[00:01.00]中文翻译');
    });
  });

  group('neko-v1 富歌词解析（逐字）', () {
    const rich = {
      'version': 1,
      'lines': [
        {
          'startMs': 1000,
          'endMs': 2200,
          'text': '晴天',
          'translation': 'Sunny day',
          'romanization': 'qing tian',
          'background': false,
          'words': [
            {'startMs': 1000, 'endMs': 1400, 'text': '晴'},
            {'startMs': 1400, 'endMs': 1800, 'text': '天'},
          ],
        },
        {
          'startMs': 2200,
          'endMs': 2600,
          'text': '和声',
          'background': true,
          'words': [
            {'startMs': 2200, 'text': '和'},
            {'startMs': 2400, 'text': '声'},
          ],
        },
      ],
    };

    test('行 / 逐字 / 翻译 / 音译 / 背景行 / endMs', () {
      final groups = parseLyricGroups(
        content: jsonEncode(rich),
        format: kNekoV1LyricsFormat,
      );
      expect(groups, hasLength(2));
      expect(groups[0].original.timeMs, 1000);
      expect(groups[0].original.text, '晴天');
      expect(groups[0].translation, 'Sunny day');
      expect(groups[0].romaji, 'qing tian');
      expect(groups[0].endMs, 2200);
      final frags = groups[0].fragments!;
      expect(frags.map((f) => f.text).join(), '晴天');
      expect(frags[0].startMs, 0);
      expect(frags[0].durationMs, 400);
      expect(frags[1].startMs, 400);
      expect(frags[1].durationMs, 400);
      expect(groups[1].isBG, isTrue);
      expect(groups[1].fragments!.first.startMs, 0);
      expect(groups[1].fragments!.first.durationMs, 200);
    });

    test('缺少 endMs / 字级 endMs 时按下一行 / 下一字兜底补齐', () {
      final groups = parseNekoV1Lyrics(jsonEncode({
        'lines': [
          {
            'startMs': 0,
            'text': '甲乙',
            'words': [
              {'startMs': 0, 'text': '甲'},
              {'startMs': 300, 'text': '乙'},
            ],
          },
          {'startMs': 1000, 'text': '下一行'},
        ],
      }));
      expect(groups, hasLength(2));
      expect(groups[0].endMs, 1000);
      expect(groups[0].fragments![0].startMs, 0);
      expect(groups[0].fragments![0].durationMs, 300);
      // 末字结束 = 行尾（下一行起点）。
      expect(groups[0].fragments![1].durationMs, 700);
    });

    test('非 JSON / 无有效行 → 空；format 标 neko-v1 时回退普通 LRC', () {
      expect(parseNekoV1Lyrics('not json'), isEmpty);
      expect(parseNekoV1Lyrics('{"version":1,"lines":[]}'), isEmpty);
      final fallback = parseLyricGroups(
        content: '[00:01.000]Hello\n',
        format: kNekoV1LyricsFormat,
      );
      expect(fallback.single.original.text, 'Hello');
    });

    test('服务端顺序错乱时按 startMs 稳定排序', () {
      final groups = parseNekoV1Lyrics(jsonEncode({
        'lines': [
          {'startMs': 2000, 'text': 'B'},
          {'startMs': 1000, 'text': 'A'},
        ],
      }));
      expect(groups.map((g) => g.original.text).toList(), ['A', 'B']);
    });
  });

  group('NekoLyricSource 富歌词优先', () {
    test('preferRich=true → neko-v1；false → 兼容 LRC', () async {
      final fake = _FakeNekoClient();
      final api = NekoApi(clientFactory: (baseUrl, token) => fake);
      final container = ProviderContainer(
        overrides: [nekoApiProvider.overrideWith((ref) => api)],
      );
      addTearDown(container.dispose);
      final sourceProvider = Provider<NekoLyricSource>(
        (ref) => NekoLyricSource(ref),
      );
      final source = container.read(sourceProvider);
      final track = Track.fromNekoSong({'id': 88, 'title': 'x'});

      final rich = await source.fetch(
        LyricRequest(track: track, preferRich: true),
      );
      expect(rich?.format, kNekoV1LyricsFormat);
      final groups = parseLyricGroups(
        content: rich!.content,
        format: rich.format,
      );
      expect(groups.first.original.text, '晴天');
      expect(groups.first.fragments, hasLength(2));

      final lrc = await source.fetch(
        LyricRequest(track: track, preferRich: false),
      );
      expect(lrc?.format, 'lrc');
      expect(lrc?.content, '[00:01.00]晴天');
    });

    test('富歌词整首为广告 → 丢弃该候选，preferRich 仍回退到 LRC', () async {
      final source = _buildNekoSource(
        NekoApi(clientFactory: (baseUrl, token) => _FakeNekoClient()),
      );
      final rich = await source.fetch(
        LyricRequest(
          track: Track.fromNekoSong({'id': 89, 'title': 'x'}),
          preferRich: true,
        ),
      );
      expect(rich?.format, 'lrc');
      expect(rich?.content, '[00:01.00]晴天');
    });

    test('无兼容 LRC 时，preferRich=false 也回退到富歌词', () async {
      final source = _buildNekoSource(
        NekoApi(clientFactory: (baseUrl, token) => _FakeNekoClient()),
      );
      final match = await source.fetch(
        LyricRequest(
          track: Track.fromNekoSong({'id': 90, 'title': 'x'}),
          preferRich: false,
        ),
      );
      expect(match?.format, kNekoV1LyricsFormat);
      final groups = parseLyricGroups(
        content: match!.content,
        format: match.format,
      );
      expect(groups.single.original.text, '晴天');
    });

    test('富歌词与 LRC 均不可用 → null（交给引擎换源）', () async {
      final source = _buildNekoSource(
        NekoApi(clientFactory: (baseUrl, token) => _FakeNekoClient()),
      );
      final match = await source.fetch(
        LyricRequest(
          track: Track.fromNekoSong({'id': 91, 'title': 'x'}),
          preferRich: true,
        ),
      );
      expect(match, isNull);
    });
  });

  group('NekoQrSession 二维码图片解码', () {
    test('解析服务端 qrImage data URL → PNG 字节', () {
      final png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A];
      final s = NekoQrSession(
        sessionId: 'sid',
        deliveryKey: 'dk',
        qrImage: 'data:image/png;base64,${base64Encode(png)}',
      );
      expect(s.sessionId, 'sid');
      expect(s.deliveryKey, 'dk');
      expect(s.qrImageBytes, png);
    });

    test('非图片 / 非法 base64 / 空值返回 null', () {
      expect(decodeQrImageDataUrl(null), isNull);
      expect(decodeQrImageDataUrl(''), isNull);
      expect(decodeQrImageDataUrl('https://x/y.png'), isNull);
      expect(decodeQrImageDataUrl('data:image/png,notbase64'), isNull);
      expect(decodeQrImageDataUrl('data:image/png;base64,@@@'), isNull);
    });
  });

  group('NekoQrStatus', () {
    test('状态帧不再携带 token（需 claim 领取）', () {
      final s = NekoQrStatus.fromJson({
        'status': 'confirmed',
        'token': 'ignored',
        'user': {'id': 1, 'nickname': 'n'},
      });
      expect(s.state, NekoQrState.confirmed);
      expect(s.message, isEmpty);
    });

    test('各状态映射 + 未知回退', () {
      expect(
        NekoQrStatus.fromJson({'status': 'pending'}).state,
        NekoQrState.pending,
      );
      expect(
        NekoQrStatus.fromJson({'status': 'scanned'}).state,
        NekoQrState.scanned,
      );
      expect(
        NekoQrStatus.fromJson({'status': 'canceled'}).state,
        NekoQrState.canceled,
      );
      expect(
        NekoQrStatus.fromJson({'status': 'expired'}).state,
        NekoQrState.expired,
      );
      expect(
        NekoQrStatus.fromJson({'status': '??? '}).state,
        NekoQrState.unknown,
      );
    });
  });

  group('NekoComment 解析', () {
    test('楼层 + 回复 + 被回复者 + 属地/可删', () {
      final c = NekoComment.fromJson({
        'id': 11,
        'content': '好听',
        'createdAt': '2026-09-22 10:30:00',
        'ipRegion': '浙江',
        'canDelete': true,
        'replyCount': 1,
        'user': {'id': 7, 'nickname': '喵'},
        'replies': [
          {
            'id': 12,
            'content': '同意',
            'createdAt': '2026-09-22T10:31:00',
            'user': {'id': 8, 'nickname': '汪'},
            'replyToUser': {'id': 7, 'nickname': '喵'},
          },
        ],
      });
      expect(c.id, '11');
      expect(c.userName, '喵');
      expect(c.userId, '7');
      expect(c.text, '好听');
      expect(c.location, '浙江');
      expect(c.canDelete, isTrue);
      expect(c.replyTotal, 1);
      expect(c.replies.single.userName, '汪');
      expect(c.replies.single.replyToName, '喵');
    });

    test('空 ipRegion → null；无 replies / user 安全', () {
      final c = NekoComment.fromJson({'id': 1, 'content': 'x', 'ipRegion': ''});
      expect(c.location, isNull);
      expect(c.userName, '');
      expect(c.userId, isNull);
      expect(c.replies, isEmpty);
      expect(c.replyTotal, 0);
      expect(c.canDelete, isFalse);
    });

    test('parseNekoWallClock：东八区墙钟 → 本地基准毫秒', () {
      final ms = parseNekoWallClock('2026-09-22 10:30:00');
      expect(ms, isNotNull);
      expect(
        DateTime.fromMillisecondsSinceEpoch(ms!, isUtc: true),
        DateTime.utc(2026, 9, 22, 2, 30, 0), // 10:30 +08:00 → 02:30 UTC
      );
      // 'T' 分隔同样解析
      expect(parseNekoWallClock('2026-09-22T10:30:00'), ms);
      expect(parseNekoWallClock(null), isNull);
      expect(parseNekoWallClock(''), isNull);
      expect(parseNekoWallClock('not-a-date'), isNull);
    });
  });

  group('NekoCommentPage.fromData', () {
    test('分页字段与 hasMore', () {
      final p = NekoCommentPage.fromData({
        'page': 2,
        'pageSize': 20,
        'total': 45,
        'hasMore': true,
        'comments': [
          {'id': 1, 'content': 'a', 'user': {'nickname': 'A'}},
          {'id': 2, 'content': 'b', 'user': {'nickname': 'B'}},
        ],
      });
      expect(p.list.length, 2);
      expect(p.list.first.userName, 'A');
      expect(p.page, 2);
      expect(p.pageSize, 20);
      expect(p.total, 45);
      expect(p.hasMore, isTrue);
    });

    test('缺字段安全默认', () {
      final p = NekoCommentPage.fromData(const {});
      expect(p.list, isEmpty);
      expect(p.total, 0);
      expect(p.hasMore, isFalse);
    });
  });

  group('Neko 音质档映射', () {
    test('统一档位 → 服务端 quality 参数', () {
      expect(nekoQualityParam('lq'), 'standard');
      expect(nekoQualityParam('sq'), 'hq');
      expect(nekoQualityParam('hq'), 'hq');
      expect(nekoQualityParam('lossless'), 'sq');
      expect(nekoQualityParam('hi-res'), 'hires');
      // 未知档回退服务端默认 hq
      expect(nekoQualityParam('???'), 'hq');
    });

    test('normalizeNekoQuality 归一化（含旧别名）', () {
      expect(normalizeNekoQuality('standard'), 'standard');
      expect(normalizeNekoQuality('lq'), 'standard');
      expect(normalizeNekoQuality('128'), 'standard');
      expect(normalizeNekoQuality('hq'), 'hq');
      expect(normalizeNekoQuality('mq'), 'hq');
      expect(normalizeNekoQuality('320'), 'hq');
      expect(normalizeNekoQuality('sq'), 'sq');
      expect(normalizeNekoQuality('lossless'), 'sq');
      expect(normalizeNekoQuality('无损'), 'sq');
      expect(normalizeNekoQuality('hires'), 'hires');
      expect(normalizeNekoQuality('hi-res'), 'hires');
      expect(normalizeNekoQuality(' Hi_Res '), 'hires');
      expect(normalizeNekoQuality(''), isNull);
      expect(normalizeNekoQuality(null), isNull);
      expect(normalizeNekoQuality('unknown'), isNull);
    });

    test('nekoQualityRank 排序（standard < hq < sq < hires；未知按 hq）', () {
      expect(nekoQualityRank('standard'), 0);
      expect(nekoQualityRank('hq'), 1);
      expect(nekoQualityRank('sq'), 2);
      expect(nekoQualityRank('hires'), 3);
      expect(nekoQualityRank('unknown'), 1);
      expect(nekoQualityRank(null), 1);
    });

    test('nekoQualityBadge 列表音质角标映射', () {
      expect(nekoQualityBadge(null), isNull);
      expect(nekoQualityBadge('???'), isNull);
      expect(nekoQualityBadge('standard'), (label: 'LQ', lossless: false));
      expect(nekoQualityBadge('hq'), (label: 'HQ', lossless: false));
      expect(nekoQualityBadge('sq'), (label: 'Lossless', lossless: true));
      expect(nekoQualityBadge('hires'), (label: 'Hi-Res', lossless: true));
      expect(nekoQualityBadge('无损'), (label: 'Lossless', lossless: true));
    });

    test('nekoLevelsForMaxQuality 按 maxQuality 裁剪可选档位', () {
      // 未知 / 未升级 → 全档位（服务端取流仍按原始最高封顶）
      expect(nekoLevelsForMaxQuality(null), ['lq', 'hq', 'lossless', 'hi-res']);
      expect(nekoLevelsForMaxQuality('???'), ['lq', 'hq', 'lossless', 'hi-res']);
      // standard（有损最低档）→ 仅 LQ
      expect(nekoLevelsForMaxQuality('standard'), ['lq']);
      // hq → 标准转码档封顶
      expect(nekoLevelsForMaxQuality('hq'), ['lq', 'hq']);
      // sq（无损）→ 到无损为止
      expect(nekoLevelsForMaxQuality('sq'), ['lq', 'hq', 'lossless']);
      // hires → 全档位
      expect(nekoLevelsForMaxQuality('hires'), ['lq', 'hq', 'lossless', 'hi-res']);
      // 别名同样识别
      expect(nekoLevelsForMaxQuality('无损'), ['lq', 'hq', 'lossless']);
    });
  });

  group('NekoApi.resolvePlayUrl / userAvatarUrl', () {
    test('音质解析：/api/music/file JSON → 媒体直链并缓存', () async {
      final fake = _FakeNekoClient();
      final api = NekoApi(clientFactory: (baseUrl, token) => fake);
      final t = Track.fromNekoSong({'id': 42, 'title': 'x'});

      final url = await api.resolvePlayUrl(t, quality: 'lossless');
      expect(fake.lastPath, '/api/music/file/42');
      expect(fake.lastQuery?['quality'], 'sq');
      expect(url, '$kDefaultNekoBaseUrl/media/music/42/sq.flac');

      // 二次调用命中进程内缓存，不再请求
      fake.calls = 0;
      expect(
        await api.resolvePlayUrl(t, quality: 'lossless'),
        contains('/media/'),
      );
      expect(fake.calls, 0);

      expect(await api.resolvePlayUrl(Track.fromNekoSong(const {})), isNull);
    });

    test('头像 URL 带缓存破坏版本；空 userId 返回 null', () {
      final api = NekoApi();
      final url = api.userAvatarUrl('7');
      expect(url, startsWith('$kDefaultNekoBaseUrl/api/user/avatar/7?v='));
      expect(api.userAvatarUrl('  '), isNull);
      expect(api.userAvatarUrl(null), isNull);
    });
  });

  group('NekoApi 音乐详情（歌词并入 info）', () {
    test('歌词从 /api/music/info 的 data.lyrics 取，且与最高音质共用缓存', () async {
      final fake = _FakeNekoClient();
      final api = NekoApi(clientFactory: (baseUrl, token) => fake);

      expect(await api.lyricText('42'), '[00:01.00]晴天');
      expect(fake.lastPath, '/api/music/info/42');
      expect(fake.calls, 1);

      // 同一曲目的最高音质复用同一份详情缓存，不再发第二次请求。
      expect(await api.fetchMaxQuality('42'), 'sq');
      expect(fake.calls, 1);
      expect(await api.lyricText('42'), '[00:01.00]晴天');
      expect(fake.calls, 1);
    });

    test('详情无歌词 → null；空 id 不发请求', () async {
      final fake = _FakeNekoClient();
      final api = NekoApi(clientFactory: (baseUrl, token) => fake);

      expect(await api.lyricText('7'), isNull);
      expect(fake.lastPath, '/api/music/info/7');
      fake.calls = 0;
      expect(await api.lyricText(''), isNull);
      expect(fake.calls, 0);
    });

    test('lyricsRich / lyricsFormat 解析为 neko-v1 载荷（共用详情缓存）', () async {
      final fake = _FakeNekoClient();
      final api = NekoApi(clientFactory: (baseUrl, token) => fake);

      final payload = await api.lyricPayload('88');
      expect(fake.lastPath, '/api/music/info/88');
      expect(payload?.format, kNekoV1LyricsFormat);
      expect(payload?.lrc, '[00:01.00]晴天');
      expect(payload?.rich?['lines'], isA<List>());

      // 同一曲目的 LRC 读取复用详情缓存，不再发请求。
      fake.calls = 0;
      expect(await api.lyricText('88'), '[00:01.00]晴天');
      expect(fake.calls, 0);
    });
  });

  group('withPicSize 查询参数保护', () {
    test('无查询追加 param；已有查询（如 Neko 头像 ?v=）不再追加', () {
      expect(
        withPicSize('https://x/y.jpg', 100),
        'https://x/y.jpg?param=100y100',
      );
      expect(
        withPicSize('https://x/y.jpg?param=50y50', 100),
        'https://x/y.jpg?param=50y50',
      );
      expect(
        withPicSize('https://music.nekocore.cn/api/user/avatar/7?v=123', 100),
        'https://music.nekocore.cn/api/user/avatar/7?v=123',
      );
      expect(withPicSize('', 100), '');
    });
  });
}

/// 构造一个挂到测试容器上的 Neko 歌词来源（容器随测试结束释放）。
NekoLyricSource _buildNekoSource(NekoApi api) {
  final container = ProviderContainer(
    overrides: [nekoApiProvider.overrideWith((ref) => api)],
  );
  addTearDown(container.dispose);
  return container.read(Provider<NekoLyricSource>((ref) => NekoLyricSource(ref)));
}

/// 假 NekoClient：只覆盖 `getJson`，用于确定性验证音质解析后的媒体直链。
class _FakeNekoClient extends NekoClient {
  _FakeNekoClient() : super(baseUrl: kDefaultNekoBaseUrl);

  int calls = 0;
  String? lastPath;
  Map<String, String>? lastQuery;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    calls++;
    lastPath = path;
    lastQuery = query;
    if (path.startsWith('/api/music/info/')) {
      final id = path.substring('/api/music/info/'.length);
      if (id == '88') {
        return <String, dynamic>{
          'success': true,
          'data': const <String, dynamic>{
            'maxQuality': 'sq',
            'lyricsFormat': kNekoV1LyricsFormat,
            'lyrics': '[00:01.00]晴天',
            'lyricsRich': {
              'version': 1,
              'lines': [
                {
                  'startMs': 1000,
                  'endMs': 2000,
                  'text': '晴天',
                  'translation': 'Sunny day',
                  'romanization': 'qing tian',
                  'background': false,
                  'words': [
                    {'startMs': 1000, 'endMs': 1500, 'text': '晴'},
                    {'startMs': 1500, 'endMs': 2000, 'text': '天'},
                  ],
                },
              ],
            },
          },
        };
      }
      if (id == '89') {
        // 富歌词整首广告；兼容 LRC 可用。
        return <String, dynamic>{
          'success': true,
          'data': const <String, dynamic>{
            'lyricsFormat': kNekoV1LyricsFormat,
            'lyrics': '[00:01.00]晴天',
            'lyricsRich': {
              'version': 1,
              'lines': [
                {'startMs': 0, 'text': '资源来自Neko云音乐'},
              ],
            },
          },
        };
      }
      if (id == '90') {
        // 只有富歌词，没有兼容 LRC。
        return <String, dynamic>{
          'success': true,
          'data': const <String, dynamic>{
            'lyricsFormat': kNekoV1LyricsFormat,
            'lyrics': '',
            'lyricsRich': {
              'version': 1,
              'lines': [
                {'startMs': 1000, 'text': '晴天'},
              ],
            },
          },
        };
      }
      if (id == '91') {
        // 富歌词与 LRC 均为广告。
        return <String, dynamic>{
          'success': true,
          'data': const <String, dynamic>{
            'lyricsFormat': kNekoV1LyricsFormat,
            'lyrics': '[00:00.00]资源来自Neko云音乐',
            'lyricsRich': {
              'version': 1,
              'lines': [
                {'startMs': 0, 'text': '资源来自Neko云音乐'},
              ],
            },
          },
        };
      }
      return <String, dynamic>{
        'success': true,
        'data': id == '42'
            ? const <String, dynamic>{
                'maxQuality': 'sq',
                'lyrics': '[00:01.00]晴天',
                'favoriteCount': 3,
              }
            : const <String, dynamic>{},
      };
    }
    return <String, dynamic>{
      'success': true,
      'data': const <String, dynamic>{'url': '/media/music/42/sq.flac'},
    };
  }
}
