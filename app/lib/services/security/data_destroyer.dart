/// 敏感数据安全销毁（对齐「不可逆覆盖写入并删除」语义）。
///
/// 提供本机含账号凭据的敏感文件清单与不可逆擦除：
/// - 流媒体服务器凭据（`streaming_servers.json`，明文密码 / accessToken）
/// - 第三方账号会话（`netease_session.json`，网易云 cookies + 酷狗 token）
/// - 本地用户库（`user.db`，Subsonic 账号与收藏）
///
/// 擦除 = 随机数据多次覆盖写入（默认 3 遍）再删除，避免常规恢复手段
/// （数据恢复工具 / WAL 残留）取回凭据；SQLite 的 `-wal` / `-shm` 侧文件
/// 一并覆盖删除。
///
/// 销毁编排：优先走 Go 侧代理（[goShredFiles]，先关闭 userPool 连接再
/// 覆盖删除，并返回逐文件确认），代理不可用或单项失败时核心主动介入
/// （[shredFile] 本地覆盖删除兜底）。
///
/// 注意：仅处理文件层；「主动失效 token」（平台登出 API）与内存登录态
/// 清理由调用方（安全设置面板）编排，销毁流程见 settings/security_section.dart。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../stores/data_dir.dart';
import '../subsonic/subsonic_bindings.dart';

/// 覆盖写入遍数（越多越难恢复，3 遍已可对抗常规数据恢复工具）。
const int shredPasses = 3;

/// 单文件销毁结果。
class ShredResult {
  const ShredResult({
    required this.path,
    required this.existed,
    required this.shredded,
    this.bytes = 0,
  });

  final String path;
  final bool existed;

  /// 文件存在时是否完成覆盖 + 删除。
  final bool shredded;
  final int bytes;
}

/// 流媒体服务器凭据文件（明文 password / accessToken）。
String streamingServersPath() => '${resolveDataDir()}/streaming_servers.json';

/// 第三方账号会话文件（网易云 cookies + 酷狗 token，明文 JSON）。
String sessionStorePath() => '${resolveDataDir()}/netease_session.json';

/// 本地 Subsonic 用户库（与 Go 侧 DefaultUserDBPath 同目录推导）。
String userDbPath() => '${resolveDataDir()}/database/user.db';

/// 覆盖写入并删除单个文件（不存在时返回 existed=false，不报错）。
///
/// 覆盖用 [Random.secure] 随机字节分块写入，每遍 [flushSync] 落盘；
/// 文件被占用等导致删除失败时静默（尽力而为，不抛异常）。
ShredResult shredFile(String path, {int passes = shredPasses}) {
  final f = File(path);
  if (!f.existsSync()) {
    return ShredResult(path: path, existed: false, shredded: false);
  }
  final len = f.lengthSync();
  final rng = Random.secure();
  var deleted = false;
  try {
    final raf = f.openSync(mode: FileMode.write);
    try {
      // 覆盖后保持原长度（不 truncate），再整体覆盖一次防残留
      final buf = Uint8List(1 << 16);
      for (var i = 0; i < passes; i++) {
        raf.setPositionSync(0);
        var remaining = len;
        while (remaining > 0) {
          final n = remaining < buf.length ? remaining : buf.length;
          for (var j = 0; j < n; j++) {
            buf[j] = rng.nextInt(256);
          }
          raf.writeFromSync(buf, 0, n);
          remaining -= n;
        }
        raf.flushSync();
      }
    } finally {
      raf.closeSync();
    }
    try {
      f.deleteSync();
      deleted = true;
    } catch (_) {
      deleted = false;
    }
  } catch (_) {
    // 打开/写入失败：放弃覆盖（文件保持原样，调用方可感知 shredded=false）
  }
  return ShredResult(path: path, existed: true, shredded: deleted, bytes: len);
}

/// 覆盖删除文件及其 SQLite 侧文件（`-wal` / `-shm`），返回主文件结果。
ShredResult shredSqlite(String dbPath) {
  shredFile('$dbPath-wal');
  shredFile('$dbPath-shm');
  return shredFile(dbPath);
}

/// SQLite 数据库涉及的全部文件路径（主库 + WAL + SHM 侧文件）。
List<String> sqliteFilePaths(String dbPath) => [
  dbPath,
  '$dbPath-wal',
  '$dbPath-shm',
];

// ── Go 侧销毁代理（先关连接再覆盖删除，返回确认）────────────────────

/// Go 代理对单个文件的销毁确认。
class GoShredFile {
  const GoShredFile({
    required this.path,
    required this.existed,
    required this.shredded,
    this.bytes = 0,
    this.error,
  });

  final String path;
  final bool existed;
  final bool shredded;
  final int bytes;
  final String? error;
}

/// Go 代理整体销毁确认。
class GoShredOutcome {
  const GoShredOutcome({
    required this.closedUserDb,
    required this.serverRunning,
    required this.files,
  });

  /// 是否已关闭 userPool 连接（销毁 user.db 的前置步骤）。
  final bool closedUserDb;

  /// 销毁时仍有运行中的服务实例；其 user.db 已失效，需重启实例重建。
  final bool serverRunning;
  final List<GoShredFile> files;
}

/// 调用 Go 侧销毁代理（`archoera_subsonic_shred_files`）。
///
/// 返回 `null` 表示代理不可用（库未加载 / 调用失败），由调用方
/// [destroySensitiveFiles] 核心主动介入销毁。
GoShredOutcome? goShredFiles(List<String> paths, {int passes = shredPasses}) {
  try {
    final b = SubsonicBindings.instance;
    final req = jsonEncode({'files': paths, 'passes': passes});
    final reqC = req.toNativeUtf8();
    final bufLen = 1 << 20;
    final buf = calloc.allocate<Uint8>(bufLen);
    try {
      final n = b.shredFiles(0, reqC, buf, bufLen);
      if (n < 0) return null;
      final map =
          jsonDecode(utf8.decode(buf.asTypedList(n))) as Map<String, dynamic>;
      return GoShredOutcome(
        closedUserDb: map['closedUserDb'] == true,
        serverRunning: map['serverRunning'] == true,
        files: [
          for (final f in (map['results'] as List? ?? const []))
            GoShredFile(
              path: (f as Map<String, dynamic>)['path'] as String? ?? '',
              existed: f['existed'] == true,
              shredded: f['shredded'] == true,
              bytes: (f['bytes'] as num?)?.toInt() ?? 0,
              error: f['error'] as String?,
            ),
        ],
      );
    } finally {
      calloc.free(buf);
      malloc.free(reqC);
    }
  } catch (_) {
    // 库未加载 / FFI 异常 → 视为代理不可用
    return null;
  }
}

/// 统一销毁入口：优先 Go 代理（先关连接 + 覆盖删除，返回确认）；
/// 代理不可用或单项销毁失败时，核心主动介入（本地覆盖删除兜底）。
///
/// 返回逐文件结果（与请求顺序一致）；`existed && !shredded` 表示彻底失败
/// （文件被占用等，需人工处理）。
List<ShredResult> destroySensitiveFiles(
  List<String> paths, {
  int passes = shredPasses,
}) {
  final go = goShredFiles(paths, passes: passes);
  if (go == null) {
    // Go 代理不可用：核心直接销毁全部
    return [for (final p in paths) shredFile(p, passes: passes)];
  }
  // Go 已确认：对 failed 项核心介入兜底，成功项采纳 Go 结果
  return [
    for (final gf in go.files)
      if (gf.existed && !gf.shredded)
        shredFile(gf.path, passes: passes)
      else
        ShredResult(
          path: gf.path,
          existed: gf.existed,
          shredded: gf.shredded,
          bytes: gf.bytes,
        ),
  ];
}
