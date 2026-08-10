/// QM 模块注册表——对齐 apis/qqmusic/modules/index.ts。
library;

import '../core/types.dart';

import 'hot_search.dart';
import 'leaderboard.dart';
import 'lyric.dart';
import 'match.dart';
import 'search.dart';
import 'song_info.dart';
import 'song_list.dart';

/// 模块注册表：key 与 TS index.ts 完全一致
final Map<String, QmModule> qmModules = {
  'hot_search': qmHotSearch,
  'leaderboard': qmLeaderboard,
  'lyric': qmLyric,
  'match': qmMatch,
  'search': qmSearch,
  'song_info': qmSongInfo,
  'song_list': qmSongList,
};
