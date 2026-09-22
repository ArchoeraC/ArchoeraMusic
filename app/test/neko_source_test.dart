// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 实验性音源 NekoMusic（`neko`）纯函数 / 模型单测：服务器地址归一化、
// Track 映射、用户会话往返、二维码状态解析。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/services/neko/neko_audio.dart';
import 'package:archoera_music/services/neko/neko_lyrics.dart';
import 'package:archoera_music/services/neko/neko_types.dart';
import 'package:archoera_music/services/netease/track.dart';

void main() {
  group('normalizeNekoBaseUrl', () {
    test('空值 / 空白回退默认站点', () {
      expect(normalizeNekoBaseUrl(null), kDefaultNekoBaseUrl);
      expect(normalizeNekoBaseUrl('   '), kDefaultNekoBaseUrl);
    });

    test('补 scheme 并去除尾斜杠', () {
      expect(
        normalizeNekoBaseUrl('music.cnmsb.xin/'),
        'https://music.cnmsb.xin',
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
        baseUrl: 'https://music.cnmsb.xin',
      );
      expect(t.source, 'neko');
      expect(t.id, '42');
      expect(t.title, '晴天');
      expect(t.artistNames, '周杰伦');
      expect(t.album?.name, '叶惠美');
      expect(t.album?.cover, 'https://music.cnmsb.xin/api/music/cover/42');
      expect(t.duration, 269000);
      expect(t.cover, 'https://music.cnmsb.xin/api/music/cover/42');
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

  group('NekoQrStatus', () {
    test('confirmed 带 token 与用户', () {
      final s = NekoQrStatus.fromJson({
        'status': 'confirmed',
        'token': 'abc123',
        'user': {'id': 1, 'nickname': 'n'},
      });
      expect(s.state, NekoQrState.confirmed);
      expect(s.token, 'abc123');
      expect(s.user?.nickname, 'n');
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
}
