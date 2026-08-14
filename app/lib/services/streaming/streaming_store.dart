/// 流媒体服务器配置持久化（对齐 shared/types/streaming.ts StreamingApi）。
///
/// 配置文件 `streaming_servers.json` 只存**非敏感**字段（host/port/username 等）；
/// 凭据（password / accessToken）经凭据保险库（vault）加密存储，
/// 条目 uid = `streaming:<serverId>`。与 VaultSessionStore 同模式：
///   内存缓存即时可见（write-through），vault 持久化经串行队列异步执行。
///
/// 迁移：旧版本明文密码在首次 [load] 时发现 → 先入 vault（成功才覆写文件
/// 去密）；vault 不可用时降级——不静默丢弃凭据，[save] 回写含凭据旧形态
/// 并告警（等同迁移前状态，待 vault 可用后下次启动迁移）。
library;

import 'dart:convert';
import 'dart:io';

import '../../stores/data_dir.dart';
import '../security/vault_process.dart';
import 'streaming_types.dart';

/// 服务器配置存储。
class StreamingStore {
  StreamingStore._();

  /// 测试注入：非空时替代 [resolveDataDir]（凭据路径与 vault 查找同步生效）。
  static String dataDirOverride = '';

  /// 未初始化时的默认加密方案（与 [VaultSessionStore] 默认一致，crypto 推荐；
  /// 测试可注入 'vault' 验证 2-of-2 分支）。
  static String defaultScheme = 'crypto';

  static String _dir() =>
      dataDirOverride.isNotEmpty ? dataDirOverride : resolveDataDir();

  /// 存储文件路径：数据目录（`~/.local/share/ArchoeraMusic`）。
  static String get filePath => '${_dir()}/streaming_servers.json';

  /// vault 条目前缀：`streaming:<serverId>`。
  static const String _uidPrefix = 'streaming:';

  /// vault 持久化串行队列（防乱序覆盖；与 VaultSessionStore 同模式）。
  static Future<void> _queue = Future.value();

  /// 凭据内存缓存（按文件路径隔离，write-through）：serverId → {password, accessToken}。
  static final Map<String, Map<String, Map<String, String>>> _secretCache = {};

  /// vault 不可用告警只打一次（load/save 高频路径防刷屏）。
  static bool _warnedVaultDown = false;

  /// 设备变更/熵损坏（v3 有口令封装）：熵路径解锁失败 → 需恢复口令解锁。
  static bool _needsRecovery = false;

  /// v2 口令模式：本次会话的解锁口令（内存持有，仅用于 serve 握手；
  /// 绝不持久化/写盘；应用重启后需重新输入）。
  static String? _sessionPassword;

  /// v2 口令模式且本会话尚未解锁（[preloadSecrets] 检测到 password 模式、
  /// 无 [unlockWithPassword] 先行解锁时置位）——需用户输入口令解锁。
  static bool _needsPassword = false;

  /// 同 [VaultSessionStore.needsRecovery]（流媒体凭据侧，启动预取后查询）。
  static bool get needsRecovery => _needsRecovery;

  /// v2 口令模式本会话未解锁：需 [unlockWithPassword] 输入口令。
  static bool get needsPassword => _needsPassword;

  /// v2 口令解锁（每次会话启动后调用）：用口令解锁并重新预取全部流媒体
  /// 凭据。成功后 [needsPassword] 复位；口令仅内存持有（[_sessionPassword]）。
  static Future<bool> unlockWithPassword(String password) async {
    if (!VaultProcess.available) return false;
    _sessionPassword = password;
    try {
      await preloadSecrets();
      return !_needsPassword;
    } finally {
      if (_needsPassword) _sessionPassword = null; // 解锁失败：口令作废
    }
  }

  /// 三档切换条/设备绑定开关后的口令态同步：更新内存口令与 [needsPassword]，
  /// 避免与 vault 实际模式脱节（切换后同会话持久化按新模式带口令）。
  /// [password] 为新会话口令（v2 模式 / v3 关闭回落）；OS/多封装免密传 null。
  static void syncPasswordState(String? password) {
    _sessionPassword = password;
    _needsPassword = false;
  }

  /// 恢复解锁（设备变更/熵损坏）：用恢复口令解锁并重新预取全部流媒体凭据。
  /// 成功后 [needsRecovery] 复位；可经 [VaultProcess.rebind] 重绑定本机免密。
  static Future<bool> recover(String recoveryPassword) async {
    if (!VaultProcess.available) return false;
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        final cache = _secretCache.putIfAbsent(filePath, () => {});
        final json = jsonDecode(file.readAsStringSync());
        if (json is Map && json['servers'] is List) {
          for (final e in (json['servers'] as List).whereType<Map>()) {
            final m = e.cast<String, dynamic>();
            final id = m['id']?.toString();
            if (id == null || id.isEmpty || cache.containsKey(id)) continue;
            final raw = await VaultProcess.get(_dir(), _uidFor(id),
                password: recoveryPassword);
            if (raw == null || raw == 'null') continue;
            final sec = _decodeSecret(raw);
            if (sec != null) cache[id] = sec;
          }
        }
      }
      _needsRecovery = false;
      return true;
    } catch (e) {
      stderr.writeln('[vault] 流媒体恢复口令解锁失败：$e');
      return false;
    }
  }

  /// 重置静态状态（测试隔离用；生产不调用）。
  static void resetForTest() {
    dataDirOverride = '';
    defaultScheme = 'crypto';
    _secretCache.clear();
    _queue = Future.value();
    _warnedVaultDown = false;
    _needsRecovery = false;
    _needsPassword = false;
    _sessionPassword = null;
  }

  /// 等待持久化队列排空（登出/退出前落盘确认；测试断言用）。
  static Future<void> flush() => _queue;

  static void _enqueue(Future<bool> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object e) {
      stderr.writeln('[vault] 流媒体凭据持久化失败：$e');
      return false;
    });
  }

  static void _warnVaultDown() {
    if (_warnedVaultDown) return;
    _warnedVaultDown = true;
    stderr.writeln('[vault] 凭据保险库不可用：流媒体服务器凭据无法加密存储');
  }

  static String _uidFor(String serverId) => '$_uidPrefix$serverId';

  static Map<String, String>? _decodeSecret(String raw) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return null;
  }

  /// 启动预取：将全部流媒体服务器凭据从 vault 解密进内存缓存
  /// （[load] 同步接口的凭据来源；vault 会话 I/O 为异步，故在 main 启动时
  /// await 完成后 runApp，保证首帧读取即已就绪）。
  /// vault 不可用 / 未初始化时惰性 init；异常静默降级（load 返回空凭据）。
  /// v2 口令模式：未 [unlockWithPassword] 前仅置 [needsPassword]（不告警
  /// vault down——区别对待「需口令解锁」与「vault 不可用」）。
  static Future<void> preloadSecrets() async {
    try {
      if (!VaultProcess.available) return;
      if (!await VaultProcess.isInitialized(_dir())) {
        // 惰性初始化：默认 crypto（LEGACY 单因子推荐）；defaultScheme='vault'
        // 时走 2-of-2（实验性）；'file' 走文件密钥模式（LEGACY 兼容，
        // 免 OS 钥匙串）——设置页选择后冷切重启生效。
        if (defaultScheme == 'vault') {
          await VaultProcess.init(_dir());
        } else if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dir());
        } else {
          await VaultProcess.initCrypto(_dir());
        }
      }
      if (await VaultProcess.mode(_dir()) == 'password' &&
          _sessionPassword == null) {
        _needsPassword = true;
        return;
      }
      _needsPassword = false;
      final file = File(filePath);
      if (!file.existsSync()) return;
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map && json['servers'] is List) {
        final cache = _secretCache.putIfAbsent(filePath, () => {});
        for (final e in (json['servers'] as List).whereType<Map>()) {
          final m = e.cast<String, dynamic>();
          final id = m['id']?.toString();
          if (id == null || id.isEmpty || cache.containsKey(id)) continue;
          final raw = await VaultProcess.get(_dir(), _uidFor(id),
              password: _sessionPassword);
          if (raw == null || raw == 'null') continue;
          final sec = _decodeSecret(raw);
          if (sec != null) cache[id] = sec;
        }
      }
    } on VaultNeedRecoveryException catch (e) {
      // 设备变更/熵损坏（v3 有口令封装）：可恢复状态，UI 应弹恢复流而非静默降级
      _needsRecovery = true;
      stderr.writeln('[vault] 流媒体凭据需恢复口令解锁：$e');
    } catch (e) {
      // v2 口令模式：口令错误/锁定（GCM 认证拒绝、退避拒绝）→ 保持
      // needsPassword 待重试（unlockWithPassword 据此返回 false，不误报成功）；
      // 其余不可用（二进制缺失等）→ 告警降级。
      if (await _passwordModeLocked()) {
        _needsPassword = true;
      } else {
        _warnVaultDown();
      }
      stderr.writeln('[vault] 流媒体凭据预取失败：$e');
    }
  }

  /// 当前 vault 是否为 v2 口令模式（解锁失败时区分「口令错误待重试」
  /// 与「vault 不可用」）。读取失败视为非口令模式（走告警降级）。
  static Future<bool> _passwordModeLocked() async {
    try {
      return await VaultProcess.mode(_dir()) == 'password';
    } catch (_) {
      return false;
    }
  }

  /// 读取服务器列表 + 当前激活服务器 id（凭据从 vault 解密填充；
  /// 发现旧明文自动迁移：先入 vault，成功才覆写文件去密）。
  static ({List<StreamingServerConfig> servers, String? activeServerId}) load() {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    var pendingMigration = false;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return (servers: const [], activeServerId: null);
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map) {
        final raw = json['servers'];
        final activeServerId = json['activeServerId']?.toString();
        if (raw is List) {
          final servers = <StreamingServerConfig>[];
          for (final e in raw.whereType<Map>()) {
            final m = e.cast<String, dynamic>();
            final cfg = StreamingServerConfig.fromJson(m);
            final legacyPassword = m['password']?.toString();
            final legacyToken = m['accessToken']?.toString();
            final hasLegacy = (legacyPassword?.isNotEmpty ?? false) ||
                (legacyToken?.isNotEmpty ?? false);
            if (hasLegacy) {
              // 旧明文（vault 未接管前）：内存采用并标记迁移
              cache[cfg.id] = {
                if (legacyPassword != null && legacyPassword.isNotEmpty)
                  'password': legacyPassword,
                if (legacyToken != null && legacyToken.isNotEmpty)
                  'accessToken': legacyToken,
              };
              servers.add(cfg.copyWith(
                password: legacyPassword ?? '',
                accessToken: legacyToken,
              ));
              pendingMigration = true;
            } else {
              // 已迁移：凭据来自内存缓存（启动 preloadSecrets 已从 vault 解密填充）
              final sec = cache[cfg.id];
              servers.add(cfg.copyWith(
                password: sec?['password'] ?? '',
                accessToken: sec?['accessToken'],
              ));
            }
          }
          if (pendingMigration) {
            final ids = servers.map((s) => s.id).toSet();
            _enqueue(() => _migrate(servers, activeServerId, ids));
          }
          return (servers: servers, activeServerId: activeServerId);
        }
      }
    } catch (_) {
      // 损坏的存储文件：回退空列表
    }
    return (servers: const [], activeServerId: null);
  }

  /// 保存服务器列表 + 当前激活服务器 id。
  ///
  /// 凭据写穿内存缓存后异步入 vault；配置文件立即剥离凭据落盘。
  /// vault 完全不可用（二进制缺失）时回写含凭据旧形态并告警——
  /// 不静默丢弃凭据（用户重填成本 > 迁移前明文暴露，且该状态等同迁移前）。
  static void save(List<StreamingServerConfig> servers, String? activeServerId) {
    final cache = _secretCache.putIfAbsent(filePath, () => {});
    final ids = servers.map((s) => s.id).toSet();
    // 写穿缓存（含已删除服务器的 uid，供持久化删除）
    for (final s in servers) {
      cache[s.id] = {
        if (s.password.isNotEmpty) 'password': s.password,
        if (s.accessToken?.isNotEmpty ?? false) 'accessToken': s.accessToken!,
      };
    }
    final removedIds = cache.keys.where((id) => !ids.contains(id)).toList();
    for (final id in removedIds) {
      cache.remove(id);
    }
    if (!VaultProcess.available) {
      _writeFile(servers, activeServerId, includeSecrets: true);
      _warnVaultDown();
      return;
    }
    _writeFile(servers, activeServerId, includeSecrets: false);
    _enqueue(() => _persistSecrets(servers, {...ids, ...removedIds}));
  }

  static void _writeFile(
    List<StreamingServerConfig> servers,
    String? activeServerId, {
    required bool includeSecrets,
  }) {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'servers': [
          for (final s in servers)
            if (includeSecrets) s.toJson() else _withoutSecrets(s),
        ],
        'activeServerId': activeServerId,
      }));
    } catch (_) {
      // 持久化失败不阻塞（自用项目，配置丢失可接受）
    }
  }

  static Map<String, dynamic> _withoutSecrets(StreamingServerConfig s) {
    final json = s.toJson()
      ..remove('password')
      ..remove('accessToken');
    return json;
  }

  /// 凭据全部入 vault；任一步失败返回 false（调用方回滚/保留明文）。
  /// v2 口令模式：须本会话已解锁（[unlockWithPassword] 后 [_sessionPassword]
  /// 非空）；未解锁时落库失败（_persistSecrets 返回 false，文件保持原样）。
  static Future<bool> _persistSecrets(
    List<StreamingServerConfig> servers,
    Set<String> ids,
  ) async {
    try {
      if (!VaultProcess.available) return false;
      if (!await VaultProcess.isInitialized(_dir())) {
        // 惰性重建（销毁后自动重建）：按默认方案初始化
        if (defaultScheme == 'vault') {
          await VaultProcess.init(_dir());
        } else if (defaultScheme == 'file') {
          await VaultProcess.initFile(_dir());
        } else {
          await VaultProcess.initCrypto(_dir());
        }
      }
      final cache = _secretCache[filePath] ?? const {};
      // 现有 + 已删除（已删除条目缓存已剔除 → sec 为 null → 走 delete）
      final all = {...ids, ...cache.keys};
      for (final id in all) {
        final sec = cache[id];
        if (sec == null || sec.isEmpty) {
          await VaultProcess.delete(_dir(), _uidFor(id),
              password: _sessionPassword);
        } else {
          await VaultProcess.set(_dir(), _uidFor(id), jsonEncode(sec),
              password: _sessionPassword);
        }
      }
      return true;
    } on VaultNeedRecoveryException catch (e) {
      // 设备变更/熵损坏：可恢复状态，标记待恢复（UI 弹恢复流）
      _needsRecovery = true;
      stderr.writeln('[vault] 流媒体凭据需恢复口令解锁：$e');
      return false;
    } catch (e) {
      _warnVaultDown();
      stderr.writeln('[vault] 流媒体凭据落库失败：$e');
      return false;
    }
  }

  /// 旧明文迁移：凭据入 vault 成功后才覆写文件为无凭据形态；
  /// 失败保留原文件（下次启动重试），防止凭据丢失。
  static Future<bool> _migrate(
    List<StreamingServerConfig> servers,
    String? activeServerId,
    Set<String> ids,
  ) async {
    final ok = await _persistSecrets(servers, ids);
    if (!ok) return false;
    _writeFile(servers, activeServerId, includeSecrets: false);
    return true;
  }
}
