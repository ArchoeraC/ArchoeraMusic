// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// B 站播放音轨解析：AAC / FLAC / 杜比的选择与回退。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/bilibili/modules/playurl.dart';

Map<String, dynamic> _row(
  int id,
  int bandwidth,
  String codecs,
  String url, {
  List<String> backups = const [],
}) => {
  'id': id,
  'bandwidth': bandwidth,
  'codecs': codecs,
  'baseUrl': url,
  if (backups.isNotEmpty) 'backupUrl': backups,
  'size': 1234,
};

String _url(int id) =>
    'https://upos-sz-test.bilivideo.com/audio-$id.m4s?deadline=1700000000';

void main() {
  group('Bilibili 音轨选择', () {
    final aacOnly = {
      'audio': [
        _row(30216, 65_000, 'mp4a.40.2', _url(30216)),
        _row(30232, 100_000, 'mp4a.40.2', _url(30232)),
        _row(30280, 192_000, 'mp4a.40.2', _url(30280)),
      ],
      'flac': null,
      'dolby': {'type': 0, 'audio': null},
    };

    test('LQ / HQ 选对应 AAC 档', () {
      final lq = selectBilibiliAudioFromDash(aacOnly, quality: 'lq')!;
      expect(lq.qualityId, 30216);
      expect(lq.codec, 'aac');
      expect(lq.isLossless, isFalse);

      final hq = selectBilibiliAudioFromDash(aacOnly, quality: 'hq')!;
      expect(hq.qualityId, 30280);
      expect(hq.deadline, 1700000000);
      expect(hq.fileSize, 1234);
    });

    test('无无损音轨时 Lossless / Hi-Res 回退到最高 AAC', () {
      for (final quality in ['lossless', 'hi-res']) {
        final picked = selectBilibiliAudioFromDash(aacOnly, quality: quality)!;
        expect(picked.qualityId, 30280, reason: quality);
        expect(picked.isLossless, isFalse, reason: quality);
      }
    });

    test('FLAC（对象形式）优先于杜比与 AAC', () {
      final dash = {
        'audio': [_row(30280, 192_000, 'mp4a.40.2', _url(30280))],
        'flac': {
          'display': true,
          'audio': _row(30251, 1_400_000, 'fLaC', _url(30251)),
        },
        'dolby': {
          'type': 2,
          'audio': [_row(30250, 448_000, 'ec-3', _url(30250))],
        },
      };
      final picked = selectBilibiliAudioFromDash(dash, quality: 'lossless')!;
      expect(picked.qualityId, 30251);
      expect(picked.codec, 'flac');
      expect(picked.isLossless, isTrue);

      // 普通档不受无损音轨影响。
      final hq = selectBilibiliAudioFromDash(dash, quality: 'hq')!;
      expect(hq.qualityId, 30280);
    });

    test('无 FLAC 时用杜比作为高音质回退', () {
      final dash = {
        'audio': [_row(30280, 192_000, 'mp4a.40.2', _url(30280))],
        'flac': null,
        'dolby': {
          'type': 2,
          'audio': [_row(30250, 448_000, 'ec-3', _url(30250))],
        },
      };
      final picked = selectBilibiliAudioFromDash(dash, quality: 'hi-res')!;
      expect(picked.qualityId, 30250);
      expect(picked.codec, 'eac3');
      expect(picked.isLossless, isFalse);
    });

    test('优先 upos 直连 CDN，备份顺序保留', () {
      const mcdn = 'https://xy1x2x3x4.mcdn.bilivideo.com/audio.m4s';
      final dash = {
        'audio': [
          _row(30280, 192_000, 'mp4a.40.2', mcdn, backups: [_url(30280)]),
        ],
        'flac': null,
        'dolby': null,
      };
      final picked = selectBilibiliAudioFromDash(dash, quality: 'hq')!;
      expect(picked.url, _url(30280));
      expect(picked.backups, [mcdn]);
    });

    test('只使用音频字段：dash.video 一律忽略', () {
      final dash = {
        'video': [_row(30280, 192_000, 'mp4a.40.2', _url(30280))],
        'audio': null,
        'flac': null,
        'dolby': null,
      };
      expect(selectBilibiliAudioFromDash(dash, quality: 'hq'), isNull);
      expect(selectBilibiliAudioFromDash(dash, quality: 'lossless'), isNull);
    });

    test('无可用音轨 / 非 DASH 响应返回 null', () {
      expect(selectBilibiliAudioFromDash(null, quality: 'hq'), isNull);
      expect(selectBilibiliAudioFromDash(const {}, quality: 'hq'), isNull);
      expect(
        selectBilibiliAudioFromDash({
          'audio': [_row(30280, 1, 'avc1.640032', _url(30280))],
        }, quality: 'hq'),
        isNull,
      );
    });
  });
}
