// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词 v7 引擎「AMLL 对齐」新增能力的回归测试：
/// 播放时钟插值、逐字渲染几何、间奏三点、背景人声行、景深（缩放/失焦）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/engine/lyric_pipeline.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/curves.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/interlude_dots.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyric_clock.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_fragment_render.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_layout.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_word_anim.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/spring_policy.dart';

List<LyricGroup> buildGroups(int count) => [
  for (var i = 0; i < count; i++)
    LyricGroup(
      original: LyricLine(timeMs: i * 1000, text: '第 $i 行'),
      endMs: (i + 1) * 1000,
    ),
];

Widget buildWall(
  List<LyricGroup> groups,
  int pos, {
  bool playing = false,
  bool showRomanization = false,
  bool showTranslation = true,
  LyricsBlurQuality blurQuality = LyricsBlurQuality.auto,
  double width = 400,
  double height = 500,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: width,
      height: height,
      child: AmllPhysicsWall(
        groups: groups,
        positionMs: pos,
        playing: playing,
        showRomanization: showRomanization,
        showTranslation: showTranslation,
        blurQuality: blurQuality,
        onSeek: (_) {},
      ),
    ),
  ),
);

dynamic stateOf(WidgetTester tester) =>
    tester.state(find.byType(AmllPhysicsWall));

Future<void> settle(WidgetTester tester, {int frames = 90}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('LyricClock', () {
    test('非播放态严格等于锚点位置', () {
      final c = LyricClock()..reset(1000, playing: false);
      c.tick(0.5);
      expect(c.valueMs, 1000);
      expect(c.isRunning, isFalse);
    });

    test('播放态按 tick 外推并受上限钳制', () {
      final c = LyricClock()..reset(1000, playing: true);
      c.tick(0.05);
      expect(c.valueMs, 1050);
      // 一次超大 tick 最多外推 kMaxExtrapolateMs。
      c.tick(5.0);
      expect(c.valueMs, 1000 + kMaxExtrapolateMs);
    });

    test('锚点位置变化重置外推', () {
      final c = LyricClock()..reset(1000, playing: true);
      c.tick(0.1);
      expect(c.valueMs, greaterThan(1000));
      c.anchor(2000, playing: true);
      expect(c.valueMs, 2000);
    });

    test('同一位置重复上报不清空外推（事件停更时停在上限）', () {
      final c = LyricClock()..reset(1000, playing: true);
      c.tick(0.1);
      final v = c.valueMs;
      c.anchor(1000, playing: true);
      expect(c.valueMs, v);
    });

    test('播放状态变化重置外推', () {
      final c = LyricClock()..reset(1000, playing: true);
      c.tick(0.1);
      expect(c.valueMs, greaterThan(1000));
      c.anchor(1000, playing: false);
      expect(c.valueMs, 1000);
      expect(c.isRunning, isFalse);
    });
  });

  group('缓动曲线', () {
    test('cubicBezier 端点与单调性', () {
      expect(cubicBezier(0, 0.2, 0.4, 0.58, 1), 0);
      expect(cubicBezier(1, 0.2, 0.4, 0.58, 1), 1);
      var last = -1.0;
      for (var i = 0; i <= 20; i++) {
        final v = cubicBezier(i / 20, 0.2, 0.4, 0.58, 1);
        expect(v, greaterThanOrEqualTo(last));
        last = v;
      }
    });

    test('empathEasing 为 0→1→0 的脉冲（中点为峰值）', () {
      expect(empathEasing(0), 0);
      expect(empathEasing(1), closeTo(0, 1e-9));
      expect(empathEasing(0.5), closeTo(1, 1e-6));
      // 前半段单调升、后半段单调降。
      var last = -1.0;
      for (var i = 0; i <= 10; i++) {
        final v = empathEasing(i / 20);
        expect(v, greaterThanOrEqualTo(last - 1e-9));
        last = v;
      }
      last = 2.0;
      for (var i = 10; i <= 20; i++) {
        final v = empathEasing(i / 20);
        expect(v, lessThanOrEqualTo(last + 1e-9));
        last = v;
      }
    });
  });

  group('逐词动画', () {
    test('短音只有上浮、无辉光', () {
      final a = resolveWordAnim(
        text: 'a',
        index: 0,
        count: 1,
        relStartMs: 0,
        durationMs: 300,
        lineRelMs: 300,
        fontSize: 20,
      );
      expect(a.glowAlpha, 0);
      expect(a.scale, 1.0);
      // 上浮 0.05em × 20px × easeOut(0.3) ≈ 0.66px。
      expect(a.dy, lessThan(0));
      expect(a.dy, greaterThan(-1.0));
    });

    test('CJK 长音触发辉光脉冲（中点为峰值、首尾归零）', () {
      WordAnim at(int ms) => resolveWordAnim(
        text: '字',
        index: 0,
        count: 1,
        relStartMs: 0,
        durationMs: 1500,
        lineRelMs: ms,
        fontSize: 20,
      );
      expect(at(0).glowAlpha, closeTo(0, 1e-6));
      final mid = at(900); // du=1800（末词 ×1.2）→ 峰值
      expect(mid.glowAlpha, greaterThan(0));
      expect(mid.glowBlur, greaterThan(0));
      expect(mid.scale, greaterThan(1.0));
    });

    test('拉丁长词按字数门槛判定（2~7 触发、超长不触发）', () {
      WordAnim anim(String text) => resolveWordAnim(
        text: text,
        index: 0,
        count: 1,
        relStartMs: 0,
        durationMs: 1500,
        lineRelMs: 750,
        fontSize: 20,
      );
      expect(anim('hello').glowAlpha, greaterThan(0));
      expect(anim('a').glowAlpha, 0); // 单字符不触发
      expect(anim('abcdefghij').glowAlpha, 0); // >7 字符不触发
    });

    test('末词强调更强', () {
      final first = resolveWordAnim(
        text: '字',
        index: 0,
        count: 2,
        relStartMs: 0,
        durationMs: 1500,
        lineRelMs: 750,
        fontSize: 20,
      );
      final last = resolveWordAnim(
        text: '字',
        index: 1,
        count: 2,
        relStartMs: 0,
        durationMs: 1500,
        lineRelMs: 900,
        fontSize: 20,
      );
      expect(last.glowAlpha, greaterThan(first.glowAlpha));
      expect(last.scale, greaterThan(first.scale));
    });

    test('背景人声上浮幅度翻倍', () {
      WordAnim anim({required bool bg}) => resolveWordAnim(
        text: 'a',
        index: 0,
        count: 1,
        relStartMs: 0,
        durationMs: 400,
        lineRelMs: 400,
        fontSize: 20,
        isBG: bg,
      );
      expect(anim(bg: true).dy, closeTo(anim(bg: false).dy * 2, 1e-9));
    });

    test('未开始（负相对时间）时上浮为 0', () {
      final a = resolveWordAnim(
        text: 'a',
        index: 0,
        count: 1,
        relStartMs: 1000,
        durationMs: 500,
        lineRelMs: 0,
        fontSize: 20,
      );
      expect(a.dy, 0);
      expect(a.glowAlpha, 0);
    });
  });

  group('间奏识别', () {
    test('逐字行真实结束时间与下一行之间 >= 7s → 识别为间奏', () {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 0, text: '第一句'),
          endMs: 2000,
          fragments: const [
            LyricFragment(text: '第', startMs: 0, durationMs: 500),
            LyricFragment(text: '一', startMs: 500, durationMs: 500),
            LyricFragment(text: '句', startMs: 1000, durationMs: 500),
          ],
        ),
        LyricGroup(original: const LyricLine(timeMs: 12000, text: '第二句')),
      ];
      final it = computeInterludes(groups);
      expect(it, hasLength(1));
      expect(it.single.startMs, 2000);
      expect(it.single.endMs, 12000);
      expect(it.single.anchorIndex, 0);
    });

    test('普通 LRC（endMs 即下一行起始）不产生间奏（对齐 AMLL）', () {
      final groups = buildGroups(3);
      expect(computeInterludes(groups), isEmpty);
    });

    test('间隔不足 7s 不产生间奏', () {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 0, text: 'A'),
          endMs: 1000,
          fragments: const [LyricFragment(text: 'A', startMs: 0, durationMs: 500)],
        ),
        LyricGroup(original: const LyricLine(timeMs: 6000, text: 'B')),
      ];
      expect(computeInterludes(groups), isEmpty);
    });
  });

  group('间奏三点动画', () {
    test('空隙过短 → 不显示', () {
      // 总空隙 < 7s：不产生间奏。
      expect(
        resolveInterludeDots(startMs: 0, endMs: 5000, nowMs: 1000).visible,
        isFalse,
      );
      // 恰好 7s：身体段足够，可见。
      expect(
        resolveInterludeDots(startMs: 0, endMs: 7000, nowMs: 1200).visible,
        isTrue,
      );
    });

    test('中途可见、三点依次点亮且第 3 点最晚', () {
      const start = 0;
      const end = 20000;
      final early = resolveInterludeDots(
        startMs: start,
        endMs: end,
        nowMs: 1500,
      );
      expect(early.visible, isTrue);
      expect(early.opacity, greaterThan(0));
      expect(early.dots[0], greaterThan(early.dots[1]));
      expect(early.dots[1], greaterThanOrEqualTo(early.dots[2]));

      final late = resolveInterludeDots(
        startMs: start,
        endMs: end,
        nowMs: 16000,
      );
      expect(late.visible, isTrue);
      expect(late.dots[2], greaterThan(early.dots[2]));
      // 亮度落在 [0.2, 0.9]。
      for (final d in late.dots) {
        expect(d, greaterThanOrEqualTo(0.0));
        expect(d, lessThanOrEqualTo(1.0));
      }
    });

    test('退场段淡出到接近 0 并缩放收小', () {
      final st = resolveInterludeDots(startMs: 0, endMs: 20000, nowMs: 19990);
      expect(st.visible, isTrue);
      expect(st.opacity, lessThan(0.35));
      expect(st.scale, lessThan(1.0));
    });

    test('区间外不可见', () {
      expect(
        resolveInterludeDots(startMs: 0, endMs: 20000, nowMs: 20001).visible,
        isFalse,
      );
      expect(
        resolveInterludeDots(startMs: 0, endMs: 20000, nowMs: -1).visible,
        isFalse,
      );
    });
  });

  group('背景人声行解析', () {
    test('整行圆括号 → isBG 且剥掉括号', () {
      final groups = parseLyricGroups(
        content: '[00:00.000]主句\n[00:02.000]（和声句）\n',
        format: 'lrc',
      );
      expect(groups, hasLength(2));
      expect(groups[0].isBG, isFalse);
      expect(groups[0].original.text, '主句');
      expect(groups[1].isBG, isTrue);
      expect(groups[1].original.text, '和声句');
      // 背景人声行不挂翻译。
      expect(groups[1].translation, isNull);
    });

    test('半角圆括号同样识别', () {
      final groups = parseLyricGroups(
        content: '[00:00.000](backing)\n',
        format: 'lrc',
      );
      expect(groups.single.isBG, isTrue);
      expect(groups.single.original.text, 'backing');
    });

    test('逐字行剥掉括号并保留片段时间', () {
      final groups = parseLyricGroups(
        content: '[00:00.000]<0,200>（<200,300>和<500,300>声<800,200>）\n',
        format: 'yrc',
      );
      expect(groups.single.isBG, isTrue);
      expect(groups.single.original.text, '和声');
      final frags = groups.single.fragments!;
      expect(frags.map((f) => f.text).join(), '和声');
      expect(frags.first.startMs, 200);
    });

    test('普通括号内文本（非整行包裹）不算背景人声', () {
      final groups = parseLyricGroups(
        content: '[00:00.000]这是（插注）一句话\n',
        format: 'lrc',
      );
      expect(groups.single.isBG, isFalse);
      expect(groups.single.original.text, '这是（插注）一句话');
    });
  });

  group('逐字渲染几何', () {
    test('逐字盒按整行居中布局、按文本顺序递增', () {
      final r = buildLyricsFragmentRender(
        fragments: const [
          LyricFragment(text: '逐', startMs: 0, durationMs: 1000),
          LyricFragment(text: '字', startMs: 1000, durationMs: 1000),
          LyricFragment(text: '高', startMs: 2000, durationMs: 1000),
          LyricFragment(text: '亮', startMs: 3000, durationMs: 1000),
        ],
        lineText: '逐字高亮',
        fontFamily: null,
        fontSize: 18,
        weight: FontWeight.w600,
        maxWidth: 376,
        played: const Color(0xFFFFFFFF),
        unsungAlpha: 0.4,
        litAlpha: 1.0,
      );
      expect(r, isNotNull);
      expect(r!.length, 4);
      for (var i = 1; i < r.length; i++) {
        expect(r.boxes[i].left, greaterThanOrEqualTo(r.boxes[i - 1].left));
      }
      expect(r.width, closeTo(376, 0.01));
      expect(r.height, greaterThan(0));
    });

    test('整行文本与片段拼接不一致 → 返回 null（回退整行绘制）', () {
      final r = buildLyricsFragmentRender(
        fragments: const [LyricFragment(text: '逐', startMs: 0)],
        lineText: '完全不同的文本',
        fontFamily: null,
        fontSize: 18,
        weight: FontWeight.w600,
        maxWidth: 376,
        played: const Color(0xFFFFFFFF),
        unsungAlpha: 0.4,
        litAlpha: 1.0,
      );
      expect(r, isNull);
    });

    test('空片段列表 → null', () {
      final r = buildLyricsFragmentRender(
        fragments: const [],
        lineText: '',
        fontFamily: null,
        fontSize: 18,
        weight: FontWeight.w600,
        maxWidth: 376,
        played: const Color(0xFFFFFFFF),
        unsungAlpha: 0.4,
        litAlpha: 1.0,
      );
      expect(r, isNull);
    });
  });

  group('行纵向弹簧策略（AMLL getPosYSpringPolicy）', () {
    double zeta(double stiffness, double damping, double mass) =>
        damping / (2 * math.sqrt(stiffness * mass));

    test('Seek / 间奏 / 无间隔 → 慢速；歌末 → 中速', () {
      for (final p in [
        resolvePosYSpringPolicy(seeking: true),
        resolvePosYSpringPolicy(interludeActive: true),
        resolvePosYSpringPolicy(intervalMs: null),
      ]) {
        expect(p.stiffness, kSlowSpringStiffness);
        expect(p.damping, kSlowSpringDamping);
      }
      final end = resolvePosYSpringPolicy(intervalMs: 300, endOfSong: true);
      expect(end.stiffness, kMediumSpringStiffness);
      expect(end.damping, kMediumSpringDamping);
      // Seek/间奏优先于歌末判断。
      final both = resolvePosYSpringPolicy(
        seeking: true,
        intervalMs: 300,
        endOfSong: true,
      );
      expect(both.stiffness, kSlowSpringStiffness);
    });

    test('正常播放按间隔自适应：间隔越短刚度越高', () {
      final fast = resolvePosYSpringPolicy(intervalMs: 100);
      final mid = resolvePosYSpringPolicy(intervalMs: 400);
      final slow = resolvePosYSpringPolicy(intervalMs: 800);
      expect(fast.stiffness, closeTo(kSpringMaxStiffness, 0.01));
      expect(slow.stiffness, closeTo(kSpringMinStiffness, 0.01));
      expect(mid.stiffness, greaterThan(slow.stiffness));
      expect(mid.stiffness, lessThan(fast.stiffness));
      // 超出范围被钳制。
      expect(
        resolvePosYSpringPolicy(intervalMs: 20).stiffness,
        fast.stiffness,
      );
      expect(
        resolvePosYSpringPolicy(intervalMs: 5000).stiffness,
        slow.stiffness,
      );
    });

    test('阻尼 = √刚度 × 2.2，阻尼比 ≈ 1.1（略过阻尼、不过冲）', () {
      for (final interval in [100, 250, 400, 600, 800]) {
        final p = resolvePosYSpringPolicy(intervalMs: interval);
        expect(
          p.damping,
          closeTo(math.sqrt(p.stiffness) * kSpringDampingMultiplier, 1e-9),
        );
        final z = zeta(p.stiffness, p.damping, p.mass);
        expect(z, greaterThan(1.0), reason: 'interval=$interval ζ=$z 应过阻尼');
        expect(z, lessThan(1.3));
      }
    });
  });

  group('歌词间距（对齐 AMLL CSS 度量）', () {
    test('间距/行高常量与 AMLL 一致', () {
      expect(kLyricLineHeightEm, 1.2);
      expect(kLyricLineGapEm, 0.8);
      expect(kLyricTranslationGapEm, 0.3);
      expect(kLyricTranslationFontScale, 0.5);
      expect(kLyricTranslationLineHeightEm, 1.5);
      expect(lyricTranslationFontSize(14), 10); // 下限 10px
      expect(lyricTranslationFontSize(38), 19);
    });

    test('相邻两行中心距 = 行高 + 0.8em 间距', () {
      const fs = 20.0;
      const h = <double>[fs * kLyricLineHeightEm, fs * kLyricLineHeightEm];
      final centers = computeCenters(h, gapPx: fs * kLyricLineGapEm);
      expect(centers[1] - centers[0], closeTo(h[0] + fs * kLyricLineGapEm, 1e-9));
    });

    test('音译行计入行高（主行 + 音译 + 译文，顺序与绘制一致）', () {
      const fs = 20.0;
      final groups = [
        const LyricGroup(
          original: LyricLine(timeMs: 0, text: '主行'),
          translation: 'translation',
          romaji: 'romaji line',
        ),
      ];
      final mainH = fs * kLyricLineHeightEm;
      final subH =
          lyricTranslationFontSize(fs) * kLyricTranslationLineHeightEm;
      final noSub = computeLineHeights(groups, fontSize: fs, maxWidth: 400);
      expect(noSub.single, closeTo(mainH + fs * kLyricTranslationGapEm + subH, 0.01));

      final withRoma = computeLineHeights(
        groups,
        fontSize: fs,
        maxWidth: 400,
        showRomanization: true,
      );
      expect(
        withRoma.single,
        closeTo(
          mainH + 2 * (fs * kLyricTranslationGapEm + subH),
          0.01,
        ),
      );

      // 关闭音译/翻译后只剩主行。
      final bare = computeLineHeights(
        groups,
        fontSize: fs,
        maxWidth: 400,
        showTranslation: false,
        showRomanization: false,
      );
      expect(bare.single, closeTo(mainH, 0.01));
    });
  });

  group('罗马音 + 背景人声共存', () {
    test('解析：翻译/音译按时间挂到主行，背景人声行不挂', () {
      final groups = parseLyricGroups(
        content: '[00:00.000]主句\n[00:02.000]（和声）\n',
        format: 'lrc',
        translation: '[00:00.000]trans\n[00:02.000]bg trans\n',
        romaji: '[00:00.000]roma\n[00:02.000]bg roma\n',
      );
      expect(groups, hasLength(2));
      expect(groups[0].translation, 'trans');
      expect(groups[0].romaji, 'roma');
      expect(groups[0].isBG, isFalse);
      expect(groups[1].isBG, isTrue);
      expect(groups[1].translation, isNull);
      expect(groups[1].romaji, isNull);
    });

    test('脏话还原重建 LyricGroup 时保留 romaji 与 isBG', () {
      final groups = [
        const LyricGroup(
          original: LyricLine(timeMs: 0, text: 'f**k'),
          translation: 'f**k tr',
          romaji: 'f**k ro',
          endMs: 1000,
          isBG: true,
        ),
      ];
      final out = const LyricPipeline([
        UncensorLyricProcessor(),
      ]).process(groups, const LyricProcessContext(uncensor: true));
      expect(out, hasLength(1));
      expect(out.single.isBG, isTrue, reason: 'isBG 必须保留');
      expect(out.single.romaji, 'f**k ro', reason: 'romaji 必须保留');
      expect(out.single.endMs, 1000);
    });
  });

  group('歌词墙（AMLL 引擎）', () {
    testWidgets('playing 时时钟按 vsync 插值推进', (tester) async {
      final groups = buildGroups(50);
      await tester.pumpWidget(buildWall(groups, 5000, playing: true));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final s = stateOf(tester);
      final ms = s.debugClockMs() as int;
      expect(ms, greaterThanOrEqualTo(5000));
      expect(ms, lessThanOrEqualTo(5000 + kMaxExtrapolateMs));
    });

    testWidgets('暂停时时钟等于权威位置', (tester) async {
      final groups = buildGroups(50);
      await tester.pumpWidget(buildWall(groups, 5000));
      await settle(tester);
      expect(stateOf(tester).debugClockMs(), 5000);
    });

    testWidgets('激活行淡入到 1、其余为 0', (tester) async {
      final groups = buildGroups(30);
      await tester.pumpWidget(buildWall(groups, 5000));
      await settle(tester);
      final fade = (stateOf(tester) as dynamic).debugFade() as List<double>;
      expect(fade[5], closeTo(1.0, 0.05));
      expect(fade[4], lessThan(0.05));
      expect(fade[6], lessThan(0.05));
    });

    testWidgets('非激活行缩放 0.97、激活行 1.0', (tester) async {
      final groups = buildGroups(30);
      await tester.pumpWidget(buildWall(groups, 5000));
      await settle(tester);
      dynamic s = stateOf(tester);
      final scale = s.debugScale() as List<double>;
      expect(scale[5], closeTo(1.0, 1e-3));
      expect(scale[4], closeTo(0.97, 1e-3));
      expect(scale[8], closeTo(0.97, 1e-3));

      // 关闭缩放后全部为 1。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 500,
              child: AmllPhysicsWall(
                groups: groups,
                positionMs: 5000,
                enableScale: false,
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      s = stateOf(tester);
      expect((s.debugScale() as List<double>)[4], closeTo(1.0, 1e-3));
    });

    testWidgets('除高亮行外所有行都失焦（半径 1+距离，上限 5px）', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(buildWall(groups, 20000));
      await settle(tester);
      dynamic s = stateOf(tester);
      final blur = s.debugBlur() as List<double>;
      final ws = s.debugWindowStart() as int;
      final we = s.debugWindowEnd() as int;
      expect(we - ws, greaterThan(6), reason: '窗口应覆盖视口附近若干行');
      // 窗口内：只有高亮行不模糊，其余按 AMLL `resolveBlurLevel = min(5, 1+距离)`。
      // 窗口外的行不参与渲染（停驻），不在此断言范围。
      for (var i = ws; i < we; i++) {
        final d = (i - 20).abs();
        final expected = d == 0 ? 0.0 : math.min(5.0, 1.0 + d);
        expect(blur[i], closeTo(expected, 0.1), reason: '第 $i 行（距高亮 $d 行）');
      }
    });

    testWidgets('间奏期间不高亮任何行且显示三点', (tester) async {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 0, text: '第一句'),
          endMs: 2000,
          fragments: const [
            LyricFragment(text: '第', startMs: 0, durationMs: 500),
            LyricFragment(text: '一', startMs: 500, durationMs: 500),
            LyricFragment(text: '句', startMs: 1000, durationMs: 500),
          ],
        ),
        LyricGroup(
          original: const LyricLine(timeMs: 12000, text: '第二句'),
          endMs: 14000,
        ),
      ];
      // 间奏中段
      await tester.pumpWidget(buildWall(groups, 6000));
      await settle(tester);
      dynamic s = stateOf(tester);
      expect(s.debugActive(), -1);
      expect(s.debugDotsVisible(), isTrue);
      // 锚点停在间奏前一行（三点画在它下方）。
      expect(s.debugAnchor(), 0);

      // 回到第一行
      await tester.pumpWidget(buildWall(groups, 500));
      await settle(tester);
      s = stateOf(tester);
      expect(s.debugActive(), 0);
      expect(s.debugDotsVisible(), isFalse);
    });

    testWidgets('超长前奏（首行之前）间奏锚点为 0', (tester) async {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 20000, text: '第一句'),
          endMs: 21000,
        ),
      ];
      await tester.pumpWidget(buildWall(groups, 9000));
      await settle(tester);
      dynamic s = stateOf(tester);
      expect(s.debugActive(), -1);
      expect(s.debugDotsVisible(), isTrue);
      expect(s.debugAnchor(), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('逐字扫亮路径不抛异常且逐字缓存有界', (tester) async {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 0, text: '逐字高亮'),
          endMs: 5000,
          fragments: const [
            LyricFragment(text: '逐', startMs: 0, durationMs: 1000),
            LyricFragment(text: '字', startMs: 1000, durationMs: 1000),
            LyricFragment(text: '高', startMs: 2000, durationMs: 1000),
            LyricFragment(text: '亮', startMs: 3000, durationMs: 1000),
          ],
        ),
        LyricGroup(
          original: const LyricLine(timeMs: 5000, text: '下一行'),
          endMs: 9000,
        ),
      ];
      await tester.pumpWidget(buildWall(groups, 500, playing: true));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      dynamic s = stateOf(tester);
      expect(s.debugFragCacheEntries() as int, greaterThan(0));
      expect(s.debugFragCacheEntries() as int, lessThan(8));
      expect(tester.takeException(), isNull);
    });

    testWidgets('羽化扫亮：已唱部分明显亮于未唱部分', (tester) async {
      tester.view.physicalSize = const Size(420, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const key = ValueKey('sweep');
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: Container(
              color: const Color(0xFF101018),
              child: SizedBox(
                width: 420,
                height: 200,
                child: AmllPhysicsWall(
                  groups: [
                    LyricGroup(
                      original: const LyricLine(timeMs: 0, text: 'AABB'),
                      endMs: 4000,
                      fragments: const [
                        LyricFragment(text: 'A', startMs: 0, durationMs: 1000),
                        LyricFragment(text: 'A', startMs: 1000, durationMs: 1000),
                        LyricFragment(text: 'B', startMs: 2000, durationMs: 1000),
                        LyricFragment(text: 'B', startMs: 3000, durationMs: 1000),
                      ],
                    ),
                  ],
                  positionMs: 2500,
                  fontSize: 22,
                  blurQuality: LyricsBlurQuality.off,
                  enableScale: false,
                  alignFraction: 0.5,
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      var left = 0;
      var right = 0;
      await tester.runAsync(() async {
        final img = await boundary.toImage(pixelRatio: 1);
        final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final b = raw!.buffer.asUint8List();
        int lum(int x, int y) => b[(y * img.width + x) * 4];
        for (var y = 90; y <= 110; y++) {
          for (var x = 174; x <= 186; x++) {
            if (lum(x, y) > left) left = lum(x, y);
          }
          for (var x = 234; x <= 246; x++) {
            if (lum(x, y) > right) right = lum(x, y);
          }
        }
      });
      // 已唱部分 ≈ 播放色全亮；未唱部分 ≈ 播放色 × 0.4。
      expect(left, greaterThan(150), reason: '已唱部分应明亮 ($left)');
      expect(right, lessThan(130), reason: '未唱部分应压暗 ($right)');
      expect(left - right, greaterThan(60));
    });

    testWidgets('音译行计入行高并正常渲染（含译文，来自 main 的罗马音能力）', (tester) async {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 0, text: '主行'),
          translation: 'translation line',
          romaji: 'romaji line here',
          endMs: 3000,
        ),
        LyricGroup(
          original: const LyricLine(timeMs: 3000, text: '下一行'),
          endMs: 6000,
        ),
      ];
      await tester.pumpWidget(
        buildWall(groups, 0, showRomanization: true),
      );
      await settle(tester);
      dynamic s = stateOf(tester);
      final withSub = s.debugHeights() as List<double>;
      // 两条附属小字（音译 + 译文）显著抬高该行。
      expect(withSub[0], greaterThan(withSub[1] * 1.5));
      expect(tester.takeException(), isNull);

      // 关闭音译后该行变矮。
      await tester.pumpWidget(
        buildWall(groups, 0, showRomanization: false),
      );
      await settle(tester);
      s = stateOf(tester);
      final withoutRoma = s.debugHeights() as List<double>;
      expect(withoutRoma[0], lessThan(withSub[0]));
      expect(tester.takeException(), isNull);
    });

    testWidgets('视口窗口：只动画可见窗口内的行，窗口外停驻且不全量测量', (tester) async {
      final groups = buildGroups(600);
      await tester.pumpWidget(buildWall(groups, 300 * 1000));
      await settle(tester);
      dynamic s = stateOf(tester);
      final ws = s.debugWindowStart() as int;
      final we = s.debugWindowEnd() as int;
      expect(ws, greaterThan(0), reason: '长歌应只圈出视口附近，而不是从头开始');
      expect(we - ws, lessThan(80), reason: '窗口只覆盖视口 ± 余量，不随歌长增长');
      // 按需测量：只为窗口附近的行排版，不整首排版
      expect(s.debugMeasuredCount() as int, lessThan(80));
      // 窗口外的行精确停驻在目标位置（不参与每帧弹簧求解）
      final y = s.debugY() as List<double>;
      final centers = s.debugCenters() as List<double>;
      final anchor = s.debugAnchor() as int;
      double target(int i) => centers[i] - (centers[anchor] - 500 * 0.5);
      for (final i in <int>[0, 1, ws - 1, we, 300, 599]) {
        if (i < 0 || i >= groups.length || (i >= ws && i < we)) continue;
        expect(y[i], closeTo(target(i), 0.01), reason: '窗口外第 $i 行应停驻在目标');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('行窗口随视口高度自适应（窗口越大圈越多行）', (tester) async {
      final groups = buildGroups(600);
      int windowSize(dynamic s) =>
          (s.debugWindowEnd() as int) - (s.debugWindowStart() as int);
      await tester.pumpWidget(
        buildWall(groups, 300 * 1000, height: 260),
      );
      await settle(tester);
      final small = windowSize(stateOf(tester));
      await tester.pumpWidget(
        buildWall(groups, 300 * 1000, height: 1200),
      );
      await settle(tester);
      final big = windowSize(stateOf(tester));
      expect(
        big,
        greaterThan(small),
        reason: '余量随视口高度放大：$small → $big',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('屏幕内的行（含只露出一半的长行）必须都在动画窗口内', (tester) async {
      // 长短行混排：长行换行后会很高，用来验证"按行本体判定"。
      final groups = <LyricGroup>[
        for (var i = 0; i < 200; i++)
          LyricGroup(
            original: LyricLine(
              timeMs: i * 1000,
              text: i % 5 == 0
                  ? '这是一行很长的歌词内容它会在可用宽度内自动换行成好几行从而显著变高$i'
                  : '短行 $i',
            ),
            endMs: (i + 1) * 1000,
          ),
      ];
      await tester.pumpWidget(buildWall(groups, 60 * 1000));
      await settle(tester);
      dynamic s = stateOf(tester);
      final ws = s.debugWindowStart() as int;
      final we = s.debugWindowEnd() as int;
      final y = s.debugY() as List<double>;
      final heights = s.debugHeights() as List<double>;
      const viewH = 500.0;
      var visibleCount = 0;
      for (var i = 0; i < groups.length; i++) {
        final cy = y[i];
        final half = heights[i] / 2;
        final visible = cy + half >= 0 && cy - half <= viewH;
        if (!visible) continue;
        visibleCount++;
        expect(
          i >= ws && i < we,
          isTrue,
          reason: '可见行 $i（center=$cy, h=${heights[i]}）必须在窗口 [$ws,$we) 内',
        );
      }
      expect(visibleCount, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('高速换行（单步 + 间隔很短）直接吸附，不再等弹簧', (tester) async {
      // 间隔 200ms 的密集歌词
      final fast = <LyricGroup>[
        for (var i = 0; i < 60; i++)
          LyricGroup(
            original: LyricLine(timeMs: i * 200, text: '第 $i 行'),
            endMs: (i + 1) * 200,
          ),
      ];
      await tester.pumpWidget(buildWall(fast, 20 * 200));
      await settle(tester);
      dynamic s = stateOf(tester);
      final anchor0 = s.debugAnchor() as int;
      // 只推进一行（+200ms，远低于 2000ms 的 seek 阈值）
      await tester.pumpWidget(buildWall(fast, (anchor0 + 1) * 200));
      await tester.pump(const Duration(milliseconds: 16));
      s = stateOf(tester);
      final anchor = s.debugAnchor() as int;
      final y = s.debugY() as List<double>;
      final centers = s.debugCenters() as List<double>;
      double target(int i) => centers[i] - (centers[anchor] - 500 * 0.5);
      expect(anchor, anchor0 + 1);
      expect(
        y[anchor],
        closeTo(target(anchor), 0.01),
        reason: '高速换行应直接吸附到目标（不走弹簧）',
      );
    });

    testWidgets('正常速度换行仍走弹簧（只有高速才吸附）', (tester) async {
      final slow = buildGroups(60); // 每行 1000ms
      await tester.pumpWidget(buildWall(slow, 20 * 1000));
      await settle(tester);
      dynamic s = stateOf(tester);
      final anchor0 = s.debugAnchor() as int;
      await tester.pumpWidget(buildWall(slow, (anchor0 + 1) * 1000));
      await tester.pump(const Duration(milliseconds: 16));
      s = stateOf(tester);
      final anchor = s.debugAnchor() as int;
      final y = s.debugY() as List<double>;
      final centers = s.debugCenters() as List<double>;
      double target(int i) => centers[i] - (centers[anchor] - 500 * 0.5);
      expect(anchor, anchor0 + 1);
      expect(
        (y[anchor] - target(anchor)).abs(),
        greaterThan(0.5),
        reason: '正常间隔的换行应仍在弹簧途中，不能被吸附吞掉',
      );
    });

    testWidgets('鼠标悬停时取消失焦（对齐 AMLL :hover filter: unset）', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(buildWall(groups, 20000));
      await settle(tester);
      dynamic s = stateOf(tester);
      final before = s.debugBlur() as List<double>;
      expect(before[19], closeTo(2.0, 0.1), reason: '未悬停时相邻行有失焦');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(AmllPhysicsWall)));
      await tester.pump();
      await settle(tester, frames: 20);
      s = stateOf(tester);
      final hovered = s.debugBlur() as List<double>;
      expect(hovered[19], 0, reason: '悬停时失焦应被取消');
      expect(hovered[18], 0);

      // 移出后恢复失焦。
      await mouse.moveTo(const Offset(-50, -50));
      await tester.pump();
      await settle(tester, frames: 20);
      s = stateOf(tester);
      final after = s.debugBlur() as List<double>;
      expect(after[19], closeTo(2.0, 0.1), reason: '移出后应恢复失焦');
      expect(tester.takeException(), isNull);
    });

    testWidgets('整层失焦为默认档：强度收敛到 1，绘制不抛异常', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(buildWall(groups, 20000));
      await settle(tester);
      final dynamic s = stateOf(tester);
      expect(s.debugBlurMode(), LyricsBlurMode.panel, reason: '默认走整层档');
      expect(s.debugPanelBlur(), closeTo(1.0, 0.05), reason: '整层强度应平滑到 ~1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('整层档：悬停把强度压到 0，移出后恢复', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(buildWall(groups, 20000));
      await settle(tester);
      expect((stateOf(tester) as dynamic).debugPanelBlur(), closeTo(1.0, 0.05));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(AmllPhysicsWall)));
      await tester.pump();
      await settle(tester, frames: 30);
      expect((stateOf(tester) as dynamic).debugPanelBlur(), closeTo(0.0, 0.02),
          reason: '悬停时整层失焦应归零（对齐 :hover filter: unset）');

      await mouse.moveTo(const Offset(-50, -50));
      await tester.pump();
      await settle(tester, frames: 30);
      expect((stateOf(tester) as dynamic).debugPanelBlur(), closeTo(1.0, 0.05));
      expect(tester.takeException(), isNull);
    });

    testWidgets('逐行档可强制启用：按距离失焦且绘制不抛异常', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(buildWall(groups, 20000));
      await settle(tester);
      (stateOf(tester) as dynamic).debugForceBlurMode(LyricsBlurMode.perLine);
      await settle(tester, frames: 40);
      final dynamic s = stateOf(tester);
      expect(s.debugBlurMode(), LyricsBlurMode.perLine);
      expect(s.debugPanelBlur(), closeTo(0.0, 0.05), reason: '逐行档不用整层强度');
      final blur = s.debugBlur() as List<double>;
      expect(blur[20], closeTo(0.0, 0.05));
      expect(blur[19], closeTo(2.0, 0.1));
      expect(blur[16], closeTo(5.0, 0.1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置里选「关闭」：整层强度恒为 0', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(
        buildWall(groups, 20000, blurQuality: LyricsBlurQuality.off),
      );
      await settle(tester);
      final dynamic s = stateOf(tester);
      expect(s.debugBlurMode(), LyricsBlurMode.off);
      expect(s.debugPanelBlur(), closeTo(0.0, 0.02));
      expect(tester.takeException(), isNull);
    });

    testWidgets('连续光栅掉帧 → 自动降级关闭失焦（且只降不升）', (tester) async {
      final groups = buildGroups(40);
      // playing=true 让 ticker 常驻（降级只统计歌词墙在动的帧）。
      await tester.pumpWidget(buildWall(groups, 20000, playing: true));
      await settle(tester, frames: 10);
      final dynamic s = stateOf(tester);
      expect(s.debugBlurMode(), LyricsBlurMode.panel);

      for (var i = 0; i < 60; i++) {
        s.debugNoteFrame(rasterMs: 30.0, uiMs: 3.0);
      }
      await tester.pump(const Duration(milliseconds: 16));
      final dynamic after = stateOf(tester);
      expect(after.debugBlurDegraded(), isTrue, reason: '持续光栅超预算应降级');
      expect(after.debugBlurMode(), LyricsBlurMode.off);
      await settle(tester, frames: 30);
      expect((stateOf(tester) as dynamic).debugPanelBlur(), closeTo(0.0, 0.05),
          reason: '降级后整层强度归零');

      // 后续就算帧时间正常也不会自己升回来（避免画质抖动）。
      for (var i = 0; i < 60; i++) {
        after.debugNoteFrame(rasterMs: 6.0, uiMs: 3.0);
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect((stateOf(tester) as dynamic).debugBlurMode(), LyricsBlurMode.off);
      expect(tester.takeException(), isNull);
    });

    testWidgets('UI 线程卡顿不触发失焦降级（不是失焦的锅）', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(buildWall(groups, 20000, playing: true));
      await settle(tester, frames: 10);
      final dynamic s = stateOf(tester);
      for (var i = 0; i < 60; i++) {
        s.debugNoteFrame(rasterMs: 30.0, uiMs: 20.0);
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect((stateOf(tester) as dynamic).debugBlurDegraded(), isFalse);
      expect((stateOf(tester) as dynamic).debugBlurMode(), LyricsBlurMode.panel);
    });

    testWidgets('设置「画质」档：固定逐行，显式选择不吃自动降级', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(
        buildWall(
          groups,
          20000,
          playing: true,
          blurQuality: LyricsBlurQuality.quality,
        ),
      );
      await settle(tester, frames: 10);
      final dynamic s = stateOf(tester);
      expect(s.debugBlurMode(), LyricsBlurMode.perLine);
      for (var i = 0; i < 60; i++) {
        s.debugNoteFrame(rasterMs: 30.0, uiMs: 3.0);
      }
      await tester.pump(const Duration(milliseconds: 16));
      final dynamic after = stateOf(tester);
      expect(after.debugBlurDegraded(), isFalse, reason: '显式档位不自动降级');
      expect(after.debugBlurMode(), LyricsBlurMode.perLine);
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置「流畅」档：固定整层档，显式选择不吃自动降级', (tester) async {
      final groups = buildGroups(40);
      await tester.pumpWidget(
        buildWall(
          groups,
          20000,
          playing: true,
          blurQuality: LyricsBlurQuality.fast,
        ),
      );
      await settle(tester, frames: 10);
      final dynamic s = stateOf(tester);
      expect(s.debugBlurMode(), LyricsBlurMode.panel);
      for (var i = 0; i < 60; i++) {
        s.debugNoteFrame(rasterMs: 30.0, uiMs: 3.0);
      }
      await tester.pump(const Duration(milliseconds: 16));
      final dynamic after = stateOf(tester);
      expect(after.debugBlurDegraded(), isFalse);
      expect(after.debugBlurMode(), LyricsBlurMode.panel);
      expect(after.debugPanelBlur(), greaterThan(0.5), reason: '整层仍生效');
      expect(tester.takeException(), isNull);
    });

    testWidgets('位置连续跳变（拖动进度条）时高亮跟随、整墙平滑滑动', (tester) async {
      final groups = buildGroups(200); // 每行 1000ms
      await tester.pumpWidget(buildWall(groups, 20 * 1000));
      await settle(tester);
      dynamic s = stateOf(tester);
      // 模拟拖动：位置一次跳 5s（典型拖动步进），并保持暂停（拖动中不推进时钟）
      await tester.pumpWidget(buildWall(groups, 120 * 1000));
      await tester.pump(const Duration(milliseconds: 16));
      s = stateOf(tester);
      // 高亮立刻跟到新位置（不等动画）
      expect(s.debugActive(), 120);
      // 但整墙是"滑"过去的：锚点行一帧后还没到目标位（弹簧途中）
      final y = s.debugY() as List<double>;
      final centers = s.debugCenters() as List<double>;
      final anchor = s.debugAnchor() as int;
      double target(int i) => centers[i] - (centers[anchor] - 500 * 0.5);
      expect(anchor, 120);
      expect(
        (y[anchor] - target(anchor)).abs(),
        greaterThan(1.0),
        reason: '拖动时应平滑滑动到目标，而不是瞬移',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('背景人声行不占独立纵向槽位（与主行间距小于主行间距）', (tester) async {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 0, text: '主句'),
          endMs: 3000,
        ),
        LyricGroup(
          original: const LyricLine(timeMs: 1000, text: '和声'),
          endMs: 4000,
          isBG: true,
        ),
        LyricGroup(
          original: const LyricLine(timeMs: 4000, text: '下一主句'),
          endMs: 7000,
        ),
      ];
      await tester.pumpWidget(buildWall(groups, 0));
      await settle(tester);
      dynamic s = stateOf(tester);
      final centers = s.debugCenters() as List<double>;
      final mainGap = centers[2] - centers[0];
      final bgGap = centers[1] - centers[0];
      // 背景行挂在主行下方（间距明显小于两个主行之间的距离）。
      expect(centers[1], greaterThan(centers[0]));
      expect(bgGap, lessThan(mainGap));
      expect(tester.takeException(), isNull);
    });
  });
}
