/// 端到端在线播放验证：直连网易云取 URL → C 引擎转码 → WAV 落盘。
///
/// 复现 PlaybackNotifier 链路（不含 libmpv，避免 GUI 依赖）：
/// cloudsearch → song_url → AudioEngineProcess.start(URL) → done → 校验 stream.wav。
library;

import 'dart:io';

import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/audio_engine_process.dart';
import 'package:archoera_music/services/playback/pcm_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    '在线歌曲直连播放链路（取 URL → C 引擎完整转码 → WAV）',
    () async {
      // 1) 直连网易云：搜索 + 取可播 URL
      //    热门曲目多为 VIP 独占（匿名仅试听片段被 resolvePlayUrl 拒绝），
      //    因此遍历搜索命中取第一首可播曲目，避免样本抖动。
      final api = NeteaseApi(ApisNeteaseCaller());
      final result = await api.searchSongs('周杰伦', limit: 5);
      expect(result.items, isNotEmpty);
      String? url;
      Track? picked;
      for (final t in result.items) {
        final u = await api.resolvePlayUrl(t.id);
        if (u != null) {
          url = u;
          picked = t;
          break;
        }
      }
      expect(url, isNotNull, reason: '应在搜索命中中取到可播 URL');
      // ignore: avoid_print
      print('[e2e] ${picked!.title} -> $url');

      // 2) 直连 C 引擎转码（完整转码，等待 done）
      final engine = await AudioEngineProcess.start(source: url!);
      try {
        await engine.done.timeout(const Duration(seconds: 180));
        final wav = File(engine.wavFilePath);
        expect(wav.existsSync(), isTrue, reason: '转码完成后 WAV 应存在');
        final size = wav.lengthSync();
        expect(size, greaterThan(50 * 1024), reason: 'WAV 应有实际音频内容');
        final head = wav.openSync().readSync(4).toList();
        expect(head, [0x52, 0x49, 0x46, 0x46], reason: '应以 RIFF 魔数开头');
        // ignore: avoid_print
        print('[e2e] WAV 完整: ${size ~/ 1024}KB');

        // 3) PCM 块文件 + 按需 FFT（PcmAnalyzer 纯文件读取，拉模式）
        final pcmFile = File(engine.pcmFilePath);
        expect(pcmFile.existsSync(), isTrue, reason: 'PCM 块文件应存在');
        expect(pcmFile.lengthSync(), greaterThan(0), reason: 'PCM 应有内容');
        PcmAnalyzer? analyzer;
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (analyzer == null && DateTime.now().isBefore(deadline)) {
          analyzer = engine.pcm;
          if (analyzer == null) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(analyzer, isNotNull, reason: 'PCM 分析器应在 ready 事件后打开');
        // 歌曲 ~45s，取 15s 处一帧：应能二分到块并完成 FFT（128 bins）
        final frame = analyzer!.frameAt(15000);
        expect(frame, isNotNull, reason: '15s 处应有 PCM 帧');
        expect(frame!.ldata.length, 128, reason: 'FFT 输出 128 bins');
        expect(frame.rdata.length, 128);
        // ignore: avoid_print
        print('[e2e] PCM 块=${analyzer.blockCount} FFT 128 bins @15s');
      } finally {
        await engine.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 200)),
  );
}
