// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/log/log.dart';

void main() {
  test('scrub 掩码长敏感键 name=value', () {
    final out = Log.scrub('GET /x?access_token=SECRET123&foo=bar');
    expect(out.contains('SECRET123'), isFalse);
    expect(out.contains('foo=bar'), isTrue);
    expect(out.contains('access_token='), isTrue);
  });

  test('scrub 掩码 header 形式的 key: value 到行尾', () {
    final out = Log.scrub('Authorization: Bearer TOPSEKRIT');
    expect(out.contains('TOPSEKRIT'), isFalse);
    expect(out.contains('Bearer'), isFalse);
    expect(out.startsWith('Authorization: '), isTrue);
  });

  test('scrub 掩码 Subsonic 单字母查询键 t/s/p', () {
    final out = Log.scrub(
      'GET /rest/stream?u=alice&t=deadbeef&s=cafe&v=1.16.1',
    );
    expect(out.contains('deadbeef'), isFalse);
    expect(out.contains('cafe'), isFalse);
    expect(out.contains('u=alice'), isTrue);
    expect(out.contains('v=1.16.1'), isTrue);
    expect(out.contains('?u=alice&t='), isTrue);
  });

  test('scrub 掩码 ?p= 值', () {
    final out = Log.scrub('?p=hunter2');
    expect(out.contains('hunter2'), isFalse);
    expect(out.contains('p='), isTrue);
  });

  test('scrub 掩码 &s= 的 URL 编码值', () {
    final out = Log.scrub('x=1&s=A%2Bc');
    expect(out.contains('A%2Bc'), isFalse);
    expect(out.contains('x=1'), isTrue);
    expect(out.contains('&s='), isTrue);
  });

  test('scrub 不误伤普通文本中的单字母键', () {
    const prose = 'step=1 top=2 map=3 t=4';
    expect(Log.scrub(prose), prose);
  });

  test('scrub 保持左边界语义（mytoken 不掩码）', () {
    final out = Log.scrub('mytoken=keepme');
    expect(out.contains('keepme'), isTrue);
  });

  test('scrub 幂等', () {
    final once = Log.scrub('?p=hunter2&t=deadbeef');
    expect(Log.scrub(once), once);
  });

  // ── 对抗性用例（注入攻击：绕过尝试不得泄露）──
  group('short-key masking 对抗性', () {
    test('空格 / Tab 分隔绕过仍掩码', () {
      expect(Log.scrub('?t =pw123').contains('pw123'), isFalse);
      expect(Log.scrub('?t\t=pw123').contains('pw123'), isFalse);
    });

    test('大写键仍掩码', () {
      final out = Log.scrub('?T=ABCdef&S=salt42');
      expect(out.contains('ABCdef'), isFalse);
      expect(out.contains('salt42'), isFalse);
    });

    test('URL 中段（非行首）仍掩码', () {
      final out = Log.scrub('open https://h/rest?u=u&t=deadbeef&s=cafe ok');
      expect(out.contains('deadbeef'), isFalse);
      expect(out.contains('cafe'), isFalse);
    });

    test('双字母键 ts/ps 不匹配（非单字母不掩码）', () {
      expect(Log.scrub('x-ts=abc'), 'x-ts=abc');
    });

    test('普通文本不误伤', () {
      const prose = 'the t value is 1 and s value is 2';
      expect(Log.scrub(prose), prose);
    });
  });
}
