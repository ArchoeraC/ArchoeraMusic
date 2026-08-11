import 'dart:io';

/// 音频引擎（app/core/audio-engine，C archoera-audio-engine）路径解析。
///
/// 解析优先级：
///  1. 环境变量 `ARCHOERACAR_AUDIO_ENGINE`（打包/部署阶段显式指定引擎根目录）；
///  2. 从可执行文件（[Platform.resolvedExecutable]）沿父目录向上查找含
///     `audio-engine` 的目录 —— 覆盖 `flutter run` 的 debug bundle 与安装包
///     布局，不依赖进程 cwd；
///  3. dev 兜底：`flutter run` 的 cwd 为 `app/`，引擎位于 `app/core/audio-engine`。
class EnginePaths {
  EnginePaths._();

  /// 引擎根目录（含 build/、src/、include/）。
  static String resolveEngineDir() {
    final override = Platform.environment['ARCHOERACAR_AUDIO_ENGINE'];
    if (override != null && override.isNotEmpty) return override;

    // 从可执行文件所在目录向上查找包含 audio-engine 的祖先目录
    final exe = Platform.resolvedExecutable;
    var dir = File(exe).parent;
    while (dir.path != dir.parent.path) {
      final cand = Directory('${dir.path}/audio-engine');
      if (cand.existsSync()) return cand.absolute.path;
      dir = dir.parent;
    }

    // dev 兜底：cwd = app/ 时，引擎在 app/core/audio-engine
    final cwd = Directory.current;
    final fromCwd = Directory('${cwd.path}/core/audio-engine');
    if (fromCwd.existsSync()) return fromCwd.absolute.path;

    throw StateError(
        '无法定位 audio-engine：请设置 ARCHOERACAR_AUDIO_ENGINE 环境变量');
  }

  /// 独立 FFT 分析库（fft.c 编译的共享库，Flutter FFI 复用 C 引擎分析器）。
  static String libfftPath() {
    final name = Platform.isWindows ? 'fft.dll' : (Platform.isMacOS ? 'libfft.dylib' : 'libfft.so');
    return '${resolveEngineDir()}/build/$name';
  }
}
