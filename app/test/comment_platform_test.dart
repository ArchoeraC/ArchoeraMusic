// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 评论「平台注册表」测试：各源能力声明 + 未注册源回退。
///
/// 评论弹窗是通用模板，行为完全由 [CommentPlatform] 的能力位驱动；这里锁定
/// 各平台的能力矩阵，避免以后改注册项时悄悄改变弹窗形态。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/dialogs/comment_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已注册平台：source 与适配器一一对应', () {
    for (final s in ['netease', 'kugou', 'qqmusic', 'neko']) {
      expect(commentPlatformFor(s).source, s, reason: '$s 未注册或错位');
    }
  });

  test('能力矩阵：热门 Tab / 发表 / 回复 / 删除', () {
    final nt = commentPlatformFor('netease');
    expect(nt.supportsHot, isTrue);
    expect(nt.supportsSend, isTrue);
    expect(nt.supportsReply, isFalse);
    expect(nt.supportsDelete, isFalse);

    final kg = commentPlatformFor('kugou');
    expect(kg.supportsHot, isFalse);
    expect(kg.supportsSend, isFalse);
    expect(kg.supportsReply, isFalse);
    expect(kg.supportsDelete, isFalse);

    final qq = commentPlatformFor('qqmusic');
    expect(qq.supportsHot, isTrue);
    expect(qq.supportsSend, isFalse);

    final nk = commentPlatformFor('neko');
    expect(nk.supportsHot, isFalse);
    expect(nk.supportsSend, isTrue);
    expect(nk.supportsReply, isTrue);
    expect(nk.supportsDelete, isTrue);
    expect(nk.expandsReplies, isTrue);
  });

  test('未注册源回退 NT（历史行为：异源走 NT 云搜索匹配）', () {
    expect(commentPlatformFor('streaming').source, 'netease');
    expect(commentPlatformFor('subsonic').source, 'netease');
  });
}
