/// Netease API 模块注册表——对齐 apis/netease/modules/index.ts。
///
/// 每新增一个 module，在对应分组 import 并加入 [modules] Map 即可。
/// 运行时通过 `nmCallNetease(name, params)` 按 key 路由。
library;

import '../core/types.dart';

// 登录 / 会话
import 'captcha_sent.dart';
import 'captcha_verify.dart';
import 'login.dart';
import 'login_cellphone.dart';
import 'login_qr_check.dart';
import 'login_qr_create.dart';
import 'login_qr_key.dart';
import 'login_refresh.dart';
import 'login_status.dart';
import 'logout.dart';
import 'register_anonimous.dart';

// 用户
import 'user_account.dart';
import 'user_cloud.dart';
import 'user_cloud_del.dart';
import 'cloud_upload_check.dart';
import 'cloud_nos_token.dart';
import 'cloud_upload_info.dart';
import 'cloud_pub.dart';
import 'cloud_upload_check_v2.dart';
import 'cloud_song_import.dart';
import 'user_detail.dart';
import 'user_detail_new.dart';
import 'user_followeds.dart';
import 'user_follows.dart';
import 'user_level.dart';
import 'user_playlist.dart';
import 'user_record.dart';
import 'user_subcount.dart';

// 评论
import 'comment_add.dart';
import 'comment_hot.dart';
import 'comment_music.dart';

// 搜索
import 'cloudsearch.dart';
import 'search.dart';
import 'search_default.dart';
import 'search_hot.dart';
import 'search_hot_detail.dart';
import 'search_match.dart';
import 'search_multimatch.dart';
import 'search_suggest.dart';
import 'search_suggest_pc.dart';

// 歌词
import 'lyric.dart';
import 'lyric_new.dart';
import 'cloud_lyric_get.dart';

// 播放
import 'song_detail.dart';
import 'song_url.dart';
import 'song_download_url.dart';
import 'playmode_intelligence.dart';
import 'personal_fm.dart';
import 'fm_trash.dart';
import 'scrobble.dart';
import 'scrobble_v1.dart';

// 每日推荐 / 发现
import 'recommend_songs.dart';
import 'personalized.dart';
import 'recommend_resource.dart';
import 'top_artists.dart';
import 'album_new.dart';

// 歌单 / 喜欢
import 'playlist_detail.dart';
import 'playlist_create.dart';
import 'playlist_delete.dart';
import 'playlist_tracks.dart';
import 'playlist_subscribe.dart';
import 'playlist_name_update.dart';
import 'playlist_desc_update.dart';
import 'playlist_order_update.dart';
import 'likelist.dart';
import 'like.dart';

// 专辑
import 'album.dart';
import 'album_sub.dart';

// 歌手
import 'artists.dart';
import 'artist_album.dart';
import 'artist_songs.dart';

// 用户收藏
import 'album_sublist.dart';
import 'artist_sub.dart';
import 'artist_sublist.dart';

/// 模块注册表：key 与 TS index.ts 完全一致
final Map<String, NeteaseModule> modules = {
  'captcha_sent': nmCaptchaSent,
  'captcha_verify': nmCaptchaVerify,
  'login': nmLogin,
  'login_cellphone': nmLoginCellphone,
  'login_qr_check': nmLoginQrCheck,
  'login_qr_create': nmLoginQrCreate,
  'login_qr_key': nmLoginQrKey,
  'login_refresh': nmLoginRefresh,
  'login_status': nmLoginStatus,
  'logout': nmLogout,
  'register_anonimous': nmRegisterAnonimous,

  'user_account': nmUserAccount,
  'user_cloud': nmUserCloud,
  'user_cloud_del': nmUserCloudDel,
  'cloud_upload_check': nmCloudUploadCheck,
  'cloud_nos_token': nmCloudNosToken,
  'cloud_upload_info': nmCloudUploadInfo,
  'cloud_pub': nmCloudPub,
  'cloud_upload_check_v2': nmCloudUploadCheckV2,
  'cloud_song_import': nmCloudSongImport,
  'user_detail': nmUserDetail,
  'user_detail_new': nmUserDetailNew,
  'user_followeds': nmUserFolloweds,
  'user_follows': nmUserFollows,
  'user_level': nmUserLevel,
  'user_playlist': nmUserPlaylist,
  'user_record': nmUserRecord,
  'user_subcount': nmUserSubcount,

  'cloudsearch': nmCloudsearch,
  'search': nmSearch,
  'search_default': nmSearchDefault,
  'search_hot': nmSearchHot,
  'search_hot_detail': nmSearchHotDetail,
  'search_match': nmSearchMatch,
  'search_multimatch': nmSearchMultimatch,
  'search_suggest': nmSearchSuggest,
  'search_suggest_pc': nmSearchSuggestPc,

  'lyric': nmLyric,
  'lyric_new': nmLyricNew,
  'cloud_lyric_get': nmCloudLyricGet,

  'song_detail': nmSongDetail,
  'song_url': nmSongUrl,
  'song_download_url': nmSongDownloadUrl,
  'playmode_intelligence': nmPlaymodeIntelligence,
  'personal_fm': nmPersonalFm,
  'fm_trash': nmFmTrash,
  'scrobble': nmScrobble,
  'scrobble_v1': nmScrobbleV1,

  'recommend_songs': nmRecommendSongs,
  'personalized': nmPersonalized,
  'recommend_resource': nmRecommendResource,
  'top_artists': nmTopArtists,
  'album_new': nmAlbumNew,

  'playlist_detail': nmPlaylistDetail,
  'playlist_create': nmPlaylistCreate,
  'playlist_delete': nmPlaylistDelete,
  'playlist_tracks': nmPlaylistTracks,
  'playlist_subscribe': nmPlaylistSubscribe,
  'playlist_name_update': nmPlaylistNameUpdate,
  'playlist_desc_update': nmPlaylistDescUpdate,
  'playlist_order_update': nmPlaylistOrderUpdate,
  'likelist': nmLikelist,
  'like': nmLike,

  'album': nmAlbum,
  'album_sub': nmAlbumSub,

  'artists': nmArtists,
  'artist_album': nmArtistAlbum,
  'artist_songs': nmArtistSongs,

  'album_sublist': nmAlbumSublist,
  'artist_sub': nmArtistSub,
  'artist_sublist': nmArtistSublist,

  'comment_hot': nmCommentHot,
  'comment_music': nmCommentMusic,
  'comment_add': nmCommentAdd,
};
