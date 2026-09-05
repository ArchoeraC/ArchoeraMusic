/// QM 模块注册表——对齐 apis/qqmusic/modules/index.ts。
library;

import '../core/types.dart';

import 'album.dart';
import 'artist.dart';
import 'comment.dart';
import 'favorite.dart';
import 'hot_search.dart';
import 'leaderboard.dart';
import 'login_qr.dart';
import 'lyric.dart';
import 'match.dart';
import 'search.dart';
import 'song_info.dart';
import 'song_list.dart';
import 'song_url.dart';
import 'user_detail.dart';

/// 模块注册表：key 与 TS index.ts 完全一致
final Map<String, QmModule> qmModules = {
  'hot_search': qmHotSearch,
  'leaderboard': qmLeaderboard,
  'lyric': qmLyric,
  'match': qmMatch,
  'search': qmSearch,
  'album': qmAlbum,
  'artist': qmArtist,
  'song_info': qmSongInfo,
  'song_list': qmSongList,
  'user_detail': qmUserDetail,
  'song_url': qmSongUrl,
  'comment': qmComment,
  'login_qr_key': qmLoginQrKey,
  'login_qr_check': qmLoginQrCheck,
  // 实验性「我喜欢」（dirid=201，社区逆向，见 favorite.dart 调研说明）
  'favorite_list': qmFavoriteList,
  'favorite_add': qmFavoriteAdd,
  'favorite_remove': qmFavoriteRemove,
};

