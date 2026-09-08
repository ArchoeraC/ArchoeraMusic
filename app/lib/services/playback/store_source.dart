// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data' show BytesBuilder;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'engine_bindings.dart';

/// M2.2 在线纯内存播放（不落盘）——Dart 整首拉流 → SegStore 内存源
/// （docs/audio-memory-source.md §2/§3/§4/§6.1/§6.2）。
///
/// 播放链路（playback_notifier_loading.load）在「引擎内存播放开且 source 为
/// http(s) 在线 URL」时，先用本模块把整首字节下载进进程内 SegStore，再经
/// `AudioEngineProcess.start(store:…)` → `createStore` 建立纯内存源会话。
///
/// 保守门禁：仅当整曲可完整驻留（≤ [kMemorySourceWholeTrackLimit]）才走纯内存；
/// 下载失败 / 超阈值 / store 建失败一律返回不可用（失败带结构化
/// [MemorySourceFailDetail]，弹窗按类别 l10n 渲染），由调用方决定回退旧 URL 路径
/// （引擎 FFmpeg 联网）或停止（§13 红色弹窗）。
///
/// 平台请求说明：用通用 `dart:io` HttpClient（不处理 qqmusic 等平台的专属
/// referer/UA——需要的源失败即回退 URL 路径，与改造前引擎自联网行为一致）。

/// “整首可驻留才走纯内存”的简化阈值（MiB→字节）。
///
/// 对齐 docs/audio-memory-source.md §6.1（minFloor ≈32 MB 会话基线）与 §6.2
/// （requiredCeiling = minFloor + requiredCache；超 ceiling−minFloor 的曲目
/// 不进入“播一段丢一段”状态）：这里简化为「内容长度 ≤ 64 MiB 视为可整首驻留、
/// 超过直接回退 URL 路径（不去顶预算）」。真实 requiredCeiling/ceiling 门禁
/// 由后续 M 的预算管理器细化（§6.2，自动 0.8 GiB 硬上限）。
const int kMemorySourceWholeTrackLimit = 64 << 20; // 64 MiB

/// minFloor 会话基线简化值（§6.1，≈32 MiB），用于 env 压低内存时从 ceiling 扣减。
const int kMemoryFloorBaselineBytes = 32 << 20;

/// auto ceiling 硬上限（§6.2/§3.3，0.8 GiB）。
const int kAutoCeilingBytes = 858993459;

/// M3 预算策略（§6.1/§6.2）：由当前可用内存（MB）给出“整首可驻留”缓存上限。
/// cache = max(0, min(avail×0.1, 0.8GiB) − floor)；avail 未知/不可得 → 回落
/// 默认 [kMemorySourceWholeTrackLimit]（测试/无引擎环境的保守常量）。
@visibleForTesting
int memoryPolicyCacheLimitBytes({required int availMb, int floorMb = 32}) {
  if (availMb <= 0) return kMemorySourceWholeTrackLimit;
  final floor = floorMb << 20;
  final ratioBytes = (availMb * 0.1 * (1 << 20)).round();
  var cache = ratioBytes - floor;
  final maxCache = kAutoCeilingBytes - floor;
  if (cache > maxCache) cache = maxCache;
  if (cache < 0) cache = 0;
  return cache;
}

int? _engineAvailMb() {
  try {
    final mb = EngineBindings.instance.memAvailableMb();
    return mb > 0 ? mb : null;
  } catch (_) {
    return null; // 无引擎 .so（单元/CI）或加载失败
  }
}

/// 观测/压测用：内存上限（§6.1/§6.2 门禁）。
///
/// - `ARCHOERA_MEMORY_CEIL_MB`：总 ceiling（MB）；低于它（减 floor 后）不足以整首
///   驻留 → 直接判定不可用（日志见决策、调用方回退 URL 路径，可故意压内存观察动作）。
/// - `ARCHOERA_MEMORY_FLOOR_MB`：覆盖 minFloor（默认 [kMemoryFloorBaselineBytes]）。
/// - 两者均不设置（[env] == null，真实运行）：auto——询问引擎可用内存按
///   [memoryPolicyCacheLimitBytes] 计算；无引擎（测试传入非空 env 或不含 .so）回落
///   默认 [kMemorySourceWholeTrackLimit]。
@visibleForTesting
int memoryWholeTrackLimitBytes({Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final ceilMb = int.tryParse(e['ARCHOERA_MEMORY_CEIL_MB'] ?? '');
  final floorMb = int.tryParse(e['ARCHOERA_MEMORY_FLOOR_MB'] ?? '');
  final baseFloor = (floorMb != null && floorMb > 0)
      ? floorMb
      : kMemoryFloorBaselineBytes >> 20;
  if (ceilMb != null && ceilMb > 0) {
    final cache = (ceilMb << 20) - (baseFloor << 20);
    return cache > 0 ? cache : 0; // ≤0 → 任何在线曲目都不可整首驻留
  }
  if (env == null) {
    final avail = _engineAvailMb();
    if (avail != null) {
      return memoryPolicyCacheLimitBytes(availMb: avail, floorMb: baseFloor);
    }
  }
  return kMemorySourceWholeTrackLimit;
}

/// 门禁判定说明（供日志/测试观测“故意压低内存”的决策结果）。
@visibleForTesting
String memoryGateExplain(int contentLength, {Map<String, String>? env}) {
  final limit = memoryWholeTrackLimitBytes(env: env);
  if (contentLength <= limit) {
    return '整首可驻留（内容 $contentLength ≤ 上限 $limit）';
  }
  return '内容 $contentLength > 纯内存整首驻留上限 $limit（§6.1/§6.2，回退 URL 路径）';
}

/// 连接/请求超时（下载整首；超过按失败回退 URL 路径）。
const Duration _downloadTimeout = Duration(seconds: 30);

/// 通用 UA（多数在线直链无鉴权；个别平台校验 UA 的源失败即回退，见文件头）。
const String _userAgent = 'ArchoeraMusic/0.9';

/// 内存源失败的结构化类别（供弹窗 l10n 渲染；`.error` raw 串仅供日志/测试）。
enum MemorySourceFailKind {
  /// 非 http(s) 源（不尝试拉流）。
  notHttpSource,

  /// 内存源 worker isolate 启动失败。
  isolateSpawn,

  /// HTTP 状态非 200（code/status 见详情）。
  httpStatus,

  /// Content-Length 已知且超整首驻留上限（content=实际内容，limit=上限）。
  overWholeCeiling,

  /// 下载中途累计超过上限（got=已下载，limit=上限）。
  grewOverCeiling,

  /// 内容为空（0 字节）。
  emptyContent,

  /// segstore_new 分配失败（OOM）。
  segstoreNewOom,

  /// segstore_fill 返回错误。
  segstoreFillError,

  /// store 填充异常（error=异常文本）。
  segstoreFillException,

  /// 网络/下载失败（error=异常文本）。
  downloadFailed,
}

/// 结构化失败详情（纯数据；供弹窗把失败原因本地化渲染）。
class MemorySourceFailDetail {
  const MemorySourceFailDetail(
    this.kind, {
    this.httpCode,
    this.httpStatus,
    this.content,
    this.limit,
    this.got,
    this.error,
  });

  final MemorySourceFailKind kind;

  /// [kind] == httpStatus 时的状态码。
  final int? httpCode;

  /// [kind] == httpStatus 时的原因短语。
  final String? httpStatus;

  /// 内容/期望字节（overWholeCeiling / grewOverCeiling 用）。
  final int? content;

  /// 整首驻留上限字节（overWholeCeiling / grewOverCeiling 用）。
  final int? limit;

  /// 已下载字节（grewOverCeiling 用）。
  final int? got;

  /// 底层异常文本（isolateSpawn / segstoreFillException / downloadFailed 用）。
  final String? error;
}

/// 整首下载 → SegStore 准备结果。
class WholeTrackPrepareResult {
  WholeTrackPrepareResult.ok({required this.store, required this.bytes})
    : error = null,
      cancelled = false,
      fail = null;

  WholeTrackPrepareResult.fail(String this.error, {this.fail})
    : store = 0,
      bytes = 0,
      cancelled = false;

  /// 会话被取代而主动取消（无 fallback/弹窗语义，调用方按“放弃本次”处理）。
  WholeTrackPrepareResult.cancelled()
    : store = 0,
      bytes = 0,
      error = null,
      cancelled = true,
      fail = null;

  /// SegStore 句柄（非 0 即成功；成功调用方接管所有权，负责最终 destroy）。
  final SegStoreHandle store;

  /// 实际下载/填充的字节数（成功时有效）。
  final int bytes;

  /// 失败原因 raw 串（供日志/测试；弹窗渲染用 [fail] 结构化详情本地化）。
  final String? error;

  /// 结构化失败详情（成功/取消时 null；弹窗按类别本地化渲染）。
  final MemorySourceFailDetail? fail;

  /// 是否因会话被取代而被调用方主动取消。
  final bool cancelled;

  bool get ok => store != 0;
}

/// 可取消的在途整首下载（会话被取代时中止拉流，避免浪费）。
class WholeTrackFetch {
  WholeTrackFetch._(this._cancelFn, this._done);

  final void Function()? _cancelFn;
  final Future<WholeTrackPrepareResult> _done;

  /// 完成结果（成功/fail/cancelled）。
  Future<WholeTrackPrepareResult> get done => _done;

  /// 请求中止当前下载（幂等；worker 收到后在最近分块边界返回 cancelled）。
  void cancel() => _cancelFn?.call();
}

class _DownloadReq {
  _DownloadReq(this.url, this.gateEnv, this.reply);
  final String url;
  final Map<String, String>? gateEnv;
  final SendPort reply;
}

/// worker 入口：收到控制消息（'cancel'）→ 置取消标志；下载/填充完成后结果回主 isolate。
void _downloadEntry(_DownloadReq req) async {
  final ctrl = ReceivePort();
  req.reply.send(ctrl.sendPort);
  var cancelled = false;
  ctrl.listen((msg) {
    if (msg == 'cancel') cancelled = true;
  });
  final client = HttpClient()..connectionTimeout = _downloadTimeout;
  try {
    final result =
        await _downloadIntoStore(client, req.url, req.gateEnv, () => cancelled);
    req.reply.send(result);
  } finally {
    client.close(force: true);
    ctrl.close();
  }
}

/// 下载整首并填充到新 SegStore（在后台 isolate 执行，UI 不阻塞；可取消）。
///
/// 每个调用新建独立 store，下载/填充串行于同一 isolate——不存在两个调用
/// 并发写同一句柄；若会话在下载期间被取代，调用方 [WholeTrackFetch.cancel]
/// 中止拉流，结果将以 cancelled 返回（不触发 fallback/弹窗）。
///
/// [gateEnv]：内存门禁 env（测试/观测用，缺省读进程 env；§6.1/§6.2）。
WholeTrackFetch prepareWholeTrackStore(
  String url, {
  Map<String, String>? gateEnv,
}) {
  final reply = ReceivePort();
  final completer = Completer<WholeTrackPrepareResult>();
  SendPort? ctrl;
  reply.listen((msg) {
    if (msg is SendPort) {
      ctrl = msg;
    } else if (msg is WholeTrackPrepareResult) {
      if (!completer.isCompleted) completer.complete(msg);
      reply.close();
    }
  });
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    completer.complete(
      WholeTrackPrepareResult.fail(
        '非 http(s) 源',
        fail: const MemorySourceFailDetail(MemorySourceFailKind.notHttpSource),
      ),
    );
    reply.close();
  } else {
    // Isolate.spawn 为异步：失败以 fail 收尾（不悬挂）。
    Isolate.spawn(
      _downloadEntry,
      _DownloadReq(url, gateEnv, reply.sendPort),
    ).then(
      (_) {},
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.complete(
            WholeTrackPrepareResult.fail(
              '内存源 isolate 启动失败: $e',
              fail: MemorySourceFailDetail(
                MemorySourceFailKind.isolateSpawn,
                error: '$e',
              ),
            ),
          );
        }
      },
    );
  }
  return WholeTrackFetch._(
    () => ctrl?.send('cancel'),
    completer.future,
  );
}

/// 下载并在 C 侧 SegStore 落地（隔离线程执行体；引擎侧内存源解码，
/// store 段内存归引擎侧 C 所有，Dart 仅 fill 拷贝，见 §4/§12）。
Future<WholeTrackPrepareResult> _downloadIntoStore(
  HttpClient client,
  String url, [
  Map<String, String>? gateEnv,
  bool Function()? isCancelled,
]) async {
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(_downloadTimeout);
    // 通用请求：不注入平台专属 referer/UA（qqmusic 个别源失败即回退 URL 路径）。
    req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    final resp = await req.close().timeout(_downloadTimeout);
    if (resp.statusCode != HttpStatus.ok) {
      return WholeTrackPrepareResult.fail(
        'HTTP ${resp.statusCode} ${resp.reasonPhrase}',
        fail: MemorySourceFailDetail(
          MemorySourceFailKind.httpStatus,
          httpCode: resp.statusCode,
          httpStatus: resp.reasonPhrase,
        ),
      );
    }
    // Content-Length 已知：用（可被 env 压低的）整首驻留上限判定，不下载（§6.2）。
    final limit = memoryWholeTrackLimitBytes(env: gateEnv);
    final known = resp.contentLength;
    if (known > limit) {
      return WholeTrackPrepareResult.fail(
        memoryGateExplain(known, env: gateEnv),
        fail: MemorySourceFailDetail(
          MemorySourceFailKind.overWholeCeiling,
          content: known,
          limit: limit,
        ),
      );
    }
    final b = BytesBuilder(copy: false);
    var got = 0;
    await for (final chunk in resp) {
      if (isCancelled?.call() ?? false) {
        return WholeTrackPrepareResult.cancelled();
      }
      got += chunk.length;
      if (got > limit) {
        return WholeTrackPrepareResult.fail(
          '下载超过纯内存整首驻留上限（$got > $limit），中止（回退 URL 路径）',
          fail: MemorySourceFailDetail(
            MemorySourceFailKind.grewOverCeiling,
            got: got,
            limit: limit,
          ),
        );
      }
      b.add(chunk);
    }
    final bytes = b.takeBytes();
    if (bytes.isEmpty) {
      return WholeTrackPrepareResult.fail(
        '空内容（0 字节）',
        fail: const MemorySourceFailDetail(
          MemorySourceFailKind.emptyContent,
        ),
      );
    }
    final bindings = EngineBindings.instance;
    final store = bindings.segstoreNew(totalHint: bytes.length);
    if (store == 0) {
      return WholeTrackPrepareResult.fail(
        'segstore_new 分配失败（OOM）',
        fail: const MemorySourceFailDetail(
          MemorySourceFailKind.segstoreNewOom,
        ),
      );
    }
    try {
      bindings.segstoreSetTotal(store, bytes.length);
      final ptr = calloc<Uint8>(bytes.length);
      try {
        ptr.asTypedList(bytes.length).setAll(0, bytes);
        if (bindings.segstoreFill(store, 0, ptr, bytes.length) != 0) {
          bindings.segstoreDestroy(store);
          return WholeTrackPrepareResult.fail(
            'segstore_fill 返回错误',
            fail: const MemorySourceFailDetail(
              MemorySourceFailKind.segstoreFillError,
            ),
          );
        }
      } finally {
        calloc.free(ptr);
      }
      return WholeTrackPrepareResult.ok(store: store, bytes: bytes.length);
    } catch (e) {
      bindings.segstoreDestroy(store);
      return WholeTrackPrepareResult.fail(
        'store 填充异常: $e',
        fail: MemorySourceFailDetail(
          MemorySourceFailKind.segstoreFillException,
          error: '$e',
        ),
      );
    }
  } catch (e) {
    return WholeTrackPrepareResult.fail(
      '下载失败: $e',
      fail: MemorySourceFailDetail(
        MemorySourceFailKind.downloadFailed,
        error: '$e',
      ),
    );
  }
}
