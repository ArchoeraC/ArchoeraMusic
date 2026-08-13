import 'dart:io';

/// FFI 动态库模块标识与文件名/查找路径约定。
///
/// 收敛 engine/scanner/scraper/subsonic/downloader 各模块原先独立的
/// ancestors 查找 + dev 兜底逻辑（见 [NativeLibPaths]），统一承载：
/// 平台文件名、环境变量名、候选相对路径。
enum NativeModule {
  /// 音频引擎主库（libarchoera_mediaengine.{so,dylib} / archoera_mediaengine.dll）。
  mediaEngine(
    'archoera_mediaengine',
    envName: 'ARCHOERA_AUDIO_ENGINE',
    envIsRootDir: true,
    candidates: ['native', 'audio-engine/build', 'core/audio-engine/build'],
  ),

  /// FFT 分析库（libfft.{so,dylib} / fft.dll），位于 audio-engine 产物目录。
  fft('fft', candidates: ['native', 'audio-engine/build', 'core/audio-engine/build']),

  /// 扫描库（scanner-ffi.{so,dylib,dll}，无 lib 前缀）。
  scanner(
    'scanner-ffi',
    libPrefix: false,
    envName: 'ARCHOERA_SCANNER_FFI',
    candidates: ['native', 'scanner/build', 'core/scanner/build'],
  ),

  /// SQLite 原生库（libe_sqlite3.{so,dylib} / e_sqlite3.dll），与 scanner 同目录。
  sqlite('e_sqlite3', candidates: ['native', 'scanner/build', 'core/scanner/build']),

  /// 刮削库（libarchoera_scraper.{so,dylib} / archoera_scraper.dll）。
  scraper(
    'archoera_scraper',
    candidates: ['native', 'scraper/build', 'core/scraper/build'],
  ),

  /// Subsonic 服务端库（libarchoera_subsonic.{so,dylib} / archoera_subsonic.dll）。
  subsonic(
    'archoera_subsonic',
    candidates: ['native', 'subsonic/build', 'core/subsonic/build'],
  ),

  /// 转码器库（libarchoera_transcoder.{so,dylib} / archoera_transcoder.dll），
  /// 与 subsonic 同目录（Go 侧 dlopen 或 Dart 注入绝对路径）。
  transcoder(
    'archoera_transcoder',
    candidates: ['native', 'subsonic/build', 'core/subsonic/build'],
  ),

  /// 下载库（libarchoera_downloader.{so,dylib} / archoera_downloader.dll，
  /// Cargo target 目录；release 优先、debug 兜底）。
  downloader(
    'archoera_downloader',
    envName: 'ARCHOERA_DOWNLOADER_SO',
    candidates: [
      'native',
      'core/downloader/target/release',
      'core/downloader/target/debug',
    ],
  );

  const NativeModule(
    this.fileBase, {
    this.envName,
    this.envIsRootDir = false,
    this.libPrefix = true,
    required this.candidates,
  });

  /// 文件名基（无 lib 前缀/扩展名）。
  final String fileBase;

  /// 各模块既有环境变量名（向后兼容覆盖）；null = 无。
  final String? envName;

  /// 环境变量语义为「模块根目录」（mediaEngine：根含 build/ 子目录），
  /// 而非「库文件路径或含库文件的目录」。
  final bool envIsRootDir;

  /// 非 Windows 平台是否加 `lib` 前缀（scanner-ffi 不加）。
  final bool libPrefix;

  /// 相对某根目录（exe 祖先链 / cwd）的候选查找路径，按优先级排列。
  final List<String> candidates;

  /// 当前平台库文件名，如 `libarchoera_mediaengine.so` / `archoera_mediaengine.dll`。
  String get fileName {
    final ext = Platform.isWindows
        ? 'dll'
        : (Platform.isMacOS ? 'dylib' : 'so');
    if (!Platform.isWindows && libPrefix) return 'lib$fileBase.$ext';
    return '$fileBase.$ext';
  }
}

/// FFI 动态库统一路径解析。
///
/// 解析优先级：
///  1. 统一目录变量 `ARCHOERA_NATIVE_DIR`（指向包含全部 FFI 库的目录）；
///  2. 各模块既有环境变量（[NativeModule.envName]，向后兼容）；
///  3. bundle：沿 [Platform.resolvedExecutable] 祖先链查找各候选路径；
///  4. dev 兜底：`flutter run` 的 cwd 为 `app/` 时查 `app/<candidate>`。
///
/// 各模块产物**构建目录保持现状**（`core/<module>/build/`、Cargo `target/`），
/// 这里只统一「安装进 bundle 后的查找」；切 `bundle/native/` 平铺布局时
/// 只需调整 [NativeModule.candidates] 或设置 `ARCHOERA_NATIVE_DIR`。
class NativeLibPaths {
  NativeLibPaths._();

  /// 统一目录环境变量：优先于各模块既有变量。
  static const String nativeDirEnv = 'ARCHOERA_NATIVE_DIR';

  /// 解析库绝对路径；未命中返回 null。
  ///
  /// [extraCandidates] 可在运行时追加候选相对路径（排在模块默认候选前）。
  static String? resolve(NativeModule m, {List<String>? extraCandidates}) {
    // 1) 统一目录变量
    final nativeDir = Platform.environment[nativeDirEnv];
    if (nativeDir != null && nativeDir.isNotEmpty) {
      final hit = _asFileOrDir(nativeDir, m.fileName);
      if (hit != null) return hit;
    }

    // 2) 各模块既有变量
    final env = m.envName;
    if (env != null) {
      final raw = Platform.environment[env];
      if (raw != null && raw.isNotEmpty) {
        if (m.envIsRootDir) {
          final fromRoot = File('$raw/build/${m.fileName}');
          if (fromRoot.existsSync()) return fromRoot.absolute.path;
        } else {
          final hit = _asFileOrDir(raw, m.fileName);
          if (hit != null) return hit;
        }
      }
    }

    // 3) bundle：exe 祖先链逐级查找
    final candidates = <String>[
      ...?extraCandidates,
      ...m.candidates,
    ];
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      for (final rel in candidates) {
        final cand = File('${dir.path}/$rel/${m.fileName}');
        if (cand.existsSync()) return cand.absolute.path;
      }
      dir = dir.parent;
    }

    // 4) dev 兜底：cwd（flutter run 时为 app/）
    for (final rel in candidates) {
      final cand = File('${Directory.current.path}/$rel/${m.fileName}');
      if (cand.existsSync()) return cand.absolute.path;
    }

    return null;
  }

  /// 解析库绝对路径；未命中抛 [StateError]（附搜索提示）。
  static String resolveRequired(NativeModule m, {String hint = ''}) {
    final path = resolve(m);
    if (path != null) return path;
    final suffix = hint.isEmpty ? '' : '（$hint）';
    throw StateError('未找到 ${m.fileName}$suffix');
  }

  /// 环境变量值视为「库文件路径」或「含库文件的目录」。
  static String? _asFileOrDir(String raw, String fileName) {
    if (File(raw).existsSync()) return File(raw).absolute.path;
    final asDir = File('$raw/$fileName');
    if (asDir.existsSync()) return asDir.absolute.path;
    return null;
  }
}
