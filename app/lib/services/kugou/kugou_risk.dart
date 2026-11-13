// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG SSA 安全验证的协议模型与行为指纹生成。
///
/// 对齐 KuGouMusicApi `util/generate_simulate.js` 的协议模型：
///
/// - `ssa-code` 响应头 = 风控事件 id（eventid）；
/// - `/verifyservice/v3/get_verify_info` 返回 `v_type`
///   （23=腾讯 TCaptcha，32=短信）；
/// - 验证请求 `/v4/verify_user_info` 需要 `sid` + `edt`：
///   `edt` 是 AES-CBC 加密的行为指纹，`sid` 是 RSA-OAEP-SHA256 加密的
///   一次性 AES key。
///
/// 注意：`sid/edt` 不能替代人机验证本身；短信码/TCaptcha ticket 仍必须由
/// 用户提供。本文件只负责生成协议字段，不负责 UI。
library;

import 'dart:convert';
import 'dart:math';

import 'kugou_crypto.dart';

/// SSA 行为指纹固定 IV（ASCII 16 字节，与KG WASM 客户端一致）。
const _ssaEdtIv = 'kugousecurity123';

/// 一次 SSA 验证所需的 `sid` / `edt`。
class KgSidEdt {
  const KgSidEdt({required this.sid, required this.edt, required this.aesKey});

  /// RSA-OAEP-SHA256(AES key)，base64。
  final String sid;

  /// AES-128-CBC(行为指纹明文)，base64。
  final String edt;

  /// 本次 `edt` 使用的 AES key（仅测试/诊断用）。
  final String aesKey;
}

/// `get_verify_info` 解析结果。
class KgVerifyInfo {
  const KgVerifyInfo({
    required this.eventId,
    required this.vType,
    required this.txAppId,
    required this.raw,
  });

  /// 风控事件 id（来自 `ssa-code` 响应头）。
  final String eventId;

  /// 23=腾讯 TCaptcha；32=短信验证码。
  final int vType;

  /// 腾讯验证码 appid（v_type=23 时使用）。
  final String txAppId;

  /// 原始响应 data（诊断/兼容用）。
  final Map<String, dynamic> raw;

  bool get isSms => vType == 32;
  bool get isTencentCaptcha => vType == 23;
}

/// 应用内验证的处理结果。
enum KgRiskVerifyOutcome {
  /// 验证通过，可以重试原请求。
  verified,

  /// 用户取消。
  cancelled,

  /// 当前平台无法在应用内完成（例如腾讯 TCaptcha 需要 WebView）。
  unsupported,

  /// 提交验证失败。
  failed,
}

/// UI 层注入的验证处理器（[KugouApi.riskVerifyHandler]）。
typedef KgRiskVerifyHandler = Future<KgRiskVerifyOutcome> Function(
  KgVerifyInfo info,
);

/// 生成 SSA `sid` / `edt`。
///
/// [random] 仅测试传入固定种子；生产使用随机数生成鼠标轨迹。
KgSidEdt kgGenerateSidEdt({
  required String mid,
  required String userid,
  required String dfid,
  required String webgl,
  Random? random,
}) {
  final rng = random ?? Random.secure();
  // key = md5(16 位随机串) 前 16 字符（ASCII），与上游 CryptoJS 一致。
  final aesKey = kgMd5(kgRandomString(16)).substring(0, 16);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final webglValue = webgl.isNotEmpty ? webgl : _randomUint64(rng);
  final data = kgGenerateBehaviorData(random: rng);
  final plain =
      'mid=$mid;userid=$userid;dfid=$dfid;webgl=$webglValue;'
      'webdriver=0;ts=$ts;data=$data';
  final edt = kgAesEncryptBase64RawKeyIv(plain, aesKey, _ssaEdtIv);
  final sid = kgRsaOaepSha256Base64(utf8.encode(aesKey));
  return KgSidEdt(sid: sid, edt: edt, aesKey: aesKey);
}

/// 生成 `edt` 的 data 字段（鼠标轨迹 + 滚动 + 窗口事件）。
///
/// 该值只用于模拟官方客户端的交互序列；测试可传 [random] 固定轨迹。
String kgGenerateBehaviorData({Random? random}) {
  final rng = random ?? Random.secure();
  // 哨兵值：接近 0xFFFFFFFF，每次生成随机偏移，增加指纹差异。
  final sentinel = 0xffffffff - rng.nextInt(20);
  final entries = <String>[];
  var ts = 0;
  var eventIndex = 0;

  // 启动时的两个 type-5 零事件（含哨兵）。
  entries.add(_f5(0, 0));
  entries.add(_fs5(sentinel, 0));
  entries.add(_f5(0, 0));
  entries.add(_fs5(sentinel, 0));

  // 窗口事件：模拟移动端页面 750x500。
  ts += _ri(rng, 5, 20);
  entries.add(_f6(ts, eventIndex, 750, 500));
  entries.add(_fs6(sentinel, eventIndex, 750, 500));
  eventIndex++;

  // 三次滚动，间隔不均匀。
  for (var i = 0; i < 3; i++) {
    ts += _ri(rng, 80, 600);
    entries.add(_f5(ts, eventIndex));
    entries.add(_fs5(sentinel, eventIndex));
    eventIndex++;
  }

  // 鼠标贝塞尔轨迹。
  final points = _ri(rng, 30, 60);
  final startX = _ri(rng, 200, 600);
  final startY = _ri(rng, 200, 500);
  final endX = _ri(rng, 500, 700);
  final endY = _ri(rng, 80, 150);
  final path = _bezierPath(rng, startX, startY, endX, endY, points);

  var subIndex = 0;
  for (var i = 0; i < path.length; i++) {
    final x = path[i].x.round();
    final y = path[i].y.round();
    ts += _ri(rng, 8, 50);
    entries.add(_f3(ts, subIndex, x, y));
    entries.add(_fs3(sentinel, subIndex, x, y));

    // 每 12 帧插入一次滚动，模拟边移动边滚动。
    if (i > 0 && i % 12 == 0) {
      ts += _ri(rng, 20, 60);
      entries.add(_f5(ts, eventIndex));
      entries.add(_fs5(sentinel, eventIndex));
      eventIndex++;
    }
    subIndex = (subIndex + 1) % 2;
  }

  // 结束事件：终点附近微调后点击。
  ts += _ri(rng, 5, 30);
  entries.add(
    _f3(
      ts,
      1,
      (endX + _ri(rng, -5, 5)).round(),
      (endY + _ri(rng, -5, 5)).round(),
    ),
  );
  entries.add(_fs3(sentinel, 1, endX, endY));

  return entries.join(':');
}

class _Point {
  const _Point(this.x, this.y);
  final double x;
  final double y;
}

/// 三阶贝塞尔曲线 + 手抖抖动（对齐上游 `bezierPath`）。
List<_Point> _bezierPath(Random rng, int sx, int sy, int ex, int ey, int n) {
  final c1x = sx + (ex - sx) * 0.3 + _ri(rng, -80, 80);
  final c1y = sy + (ey - sy) * 0.2 + _ri(rng, -60, 60);
  final c2x = sx + (ex - sx) * 0.7 + _ri(rng, -60, 60);
  final c2y = sy + (ey - sy) * 0.8 + _ri(rng, -40, 40);

  final points = <_Point>[];
  for (var i = 0; i <= n; i++) {
    final t = i / n;
    final u = 1 - t;
    final x =
        u * u * u * sx +
        3 * u * u * t * c1x +
        3 * u * t * t * c2x +
        t * t * t * ex;
    final y =
        u * u * u * sy +
        3 * u * u * t * c1y +
        3 * u * t * t * c2y +
        t * t * t * ey;
    // 起步抖动大（约 3px），移动后收敛到 0.5px。
    final jitter = max(0.5, 3 - t * 2.5);
    points.add(
      _Point(
        x + (rng.nextDouble() - 0.5) * jitter,
        y + (rng.nextDouble() - 0.5) * jitter,
      ),
    );
  }
  return points;
}

String _f3(int t, int i, int x, int y) => '3,$t,$i,$x,$y';

String _f5(int t, int i) => '5,$t,$i';

String _f6(int t, int i, int x, int y) => '6,$t,$i,$x,$y';

String _fs3(int sentinel, int i, int x, int y) => '3,$sentinel,$i,$x,$y';

String _fs5(int sentinel, int i) => '5,$sentinel,$i';

String _fs6(int sentinel, int i, int x, int y) => '6,$sentinel,$i,$x,$y';

int _ri(Random rng, int min, int max) => min + rng.nextInt(max - min + 1);

String _randomUint64(Random rng) {
  final hi = (rng.nextInt(1 << 30) << 2) | rng.nextInt(4);
  final lo = (rng.nextInt(1 << 30) << 2) | rng.nextInt(4);
  return ((BigInt.from(hi) << 32) | BigInt.from(lo)).toString();
}
