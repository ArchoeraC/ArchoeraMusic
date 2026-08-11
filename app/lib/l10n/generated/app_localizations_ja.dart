// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get menuTrackDetail => 'メディア詳細';

  @override
  String get trackDetailDuration => '再生時間';

  @override
  String get trackDetailArtist => 'アーティスト';

  @override
  String get trackDetailAlbum => 'アルバム';

  @override
  String get trackDetailSource => 'ソース';

  @override
  String get trackDetailPath => 'パス';

  @override
  String get trackDetailFileSize => 'ファイルサイズ';

  @override
  String get trackDetailCodec => 'コーデック';

  @override
  String get trackDetailSampleRate => 'サンプルレート';

  @override
  String get trackDetailBitDepth => 'ビット深度';

  @override
  String get trackDetailBitrate => 'ビットレート';

  @override
  String get trackDetailChannels => 'チャンネル';

  @override
  String get trackSourceLocal => 'ローカルファイル';

  @override
  String get trackSourceStreaming => 'ストリーミング';

  @override
  String get trackDetailQuality => '音質';

  @override
  String get batchSelectAll => 'すべて選択';

  @override
  String get batchInvert => '選択を反転';

  @override
  String get batchPlay => '選択を再生';

  @override
  String get batchAddQueue => 'キューに追加';

  @override
  String get batchDownload => '一括ダウンロード';

  @override
  String get batchExit => '複数選択を終了';

  @override
  String get batchSelectHint => '複数選択';

  @override
  String toastBatchAddedToQueue(Object count) {
    return 'キューに $count 曲追加しました';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return 'ダウンロードキューに $count 曲追加しました';
  }

  @override
  String get settingsBarEnhancedLyrics => 'バー拡張歌詞';

  @override
  String get settingsBarEnhancedLyricsOn => 'ワードタイム歌詞がある場合カラオケハイライトを表示';

  @override
  String get settingsBarEnhancedLyricsOff => 'バーに通常の歌詞を常に表示';

  @override
  String get settingsSectionClose => 'アプリを閉じる';

  @override
  String get settingsSectionPower => '省電力';

  @override
  String get settingsPowerSaver => '省電力モード';

  @override
  String get settingsPowerSaverOn =>
      'バックグラウンドで描画を抑止（最小化時 5 FPS、非フォーカス/画面オフ時 1 FPS）';

  @override
  String get settingsPowerSaverOff => '常にフルレートで描画';

  @override
  String get settingsSuppressSleep => 'システムのスリープを無効化';

  @override
  String get settingsSuppressSleepOn => '再生中はシステムを起動状態に保ち、バックグラウンド再生の中断を防ぐ';

  @override
  String get settingsSuppressSleepOff => 'システムはアイドル時にスリープする可能性があります';

  @override
  String get settingsPowerSaverNote =>
      '省電力モードはウィンドウ状態イベントを監視して描画レートを下げます（ポーリングなし）。ウィンドウ非表示やディスプレイオフ時はエンジン自体が描画を停止します。「スリープ無効化」は再生中のみ有効です。';

  @override
  String get settingsCloseBehavior => 'アプリを閉じるとき';

  @override
  String get settingsCloseBehaviorAsk => '毎回確認';

  @override
  String get settingsCloseBehaviorBackground => 'バックグラウンド再生';

  @override
  String get settingsCloseBehaviorQuit => 'すぐに終了';

  @override
  String get commonCloseConfirmTitle => 'アプリを終了';

  @override
  String get commonCloseConfirmMessage => 'メインウィンドウを閉じた後';

  @override
  String get commonCloseConfirmRemember => '選択を記憶して次回から確認しない';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => 'Netease Music';

  @override
  String get brandKugou => 'Kugou Music';

  @override
  String get commonBack => '戻る';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonClose => '閉じる';

  @override
  String get commonDefault => 'デフォルト';

  @override
  String get commonGoLogin => 'ログイン';

  @override
  String get commonLike => 'いいね';

  @override
  String get commonLoading => '読み込み中';

  @override
  String get commonLossless => 'ロスレス';

  @override
  String get commonOriginal => '原曲';

  @override
  String get commonMore => 'もっと見る';

  @override
  String get commonNext => '次の曲';

  @override
  String get commonNoMore => 'これ以上ありません';

  @override
  String get commonPrevious => '前の曲';

  @override
  String get commonSettings => '設定';

  @override
  String get commonUnknownAlbum => '不明なアルバム';

  @override
  String get commonUnknownArtist => '不明なアーティスト';

  @override
  String get commonUnlike => 'いいねを外す';

  @override
  String get downloadQualityTitle => 'ダウンロード音質';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return '$platformのダウンロードリンクの取得にはログインが必要です。未ログインでは試聴のみで、完全な音質はダウンロードできません。\n\n$platformアカウントにログインしてから再試行してください。';
  }

  @override
  String get downloadRequiresLoginTitle => 'ダウンロードにはログインが必要です';

  @override
  String get menuComment => 'コメントを見る';

  @override
  String get menuDownload => 'ダウンロード';

  @override
  String get menuLike => 'お気に入りに追加';

  @override
  String get menuPlay => '再生';

  @override
  String get menuPlayNext => '次に再生';

  @override
  String get menuRemoveFromQueue => 'キューから削除';

  @override
  String get menuUnlike => 'お気に入りから削除';

  @override
  String get navHeaderAccount => 'アカウント';

  @override
  String get navHeaderComingSoon => '近日公開';

  @override
  String navHeaderKugouId(Object id) {
    return 'Kugou $id';
  }

  @override
  String get navHeaderKugouMusic => 'Kugou Music';

  @override
  String get navHeaderLoginAccount => 'ログイン（Netease / Kugou）';

  @override
  String get navHeaderLogout => 'ログアウト';

  @override
  String get navHeaderNeteaseAccount => 'Neteaseアカウント';

  @override
  String get navHeaderNeteaseMusic => 'Netease Music';

  @override
  String get navHeaderQqMusic => 'QQ Music';

  @override
  String get navHeaderQrLogin => 'QRコードでログイン';

  @override
  String get navHeaderSearchHint => '曲 / アーティスト / プレイリストを検索';

  @override
  String get navHeaderThemeDark => 'テーマ：ダーク';

  @override
  String get navHeaderThemeLight => 'テーマ：ライト';

  @override
  String get navHeaderThemeSystem => 'テーマ：システムに従う';

  @override
  String get playerBarBuffering => '読み込み中…';

  @override
  String get playerBarIdleHint => 'サイドバーをクリックするか、ソースを読み込むと再生を開始します';

  @override
  String get playerBarOpenPlayer => 'プレイヤーを開く';

  @override
  String get playerBarPlayPause => '再生/一時停止';

  @override
  String get playerBarPlaylist => 'プレイリスト';

  @override
  String get playerBarUntitled => '無題';

  @override
  String get queueClear => 'キューをクリア';

  @override
  String get queueEmpty => 'キューは空です';

  @override
  String get queueEmptyHint => 'リストで選択した曲がここに表示されます';

  @override
  String get queueRepeatList => 'リストリピート';

  @override
  String get queueRepeatMode => 'リピートモード';

  @override
  String get queueRepeatOne => '1曲リピート';

  @override
  String get queueShuffle => 'シャッフル再生';

  @override
  String get queueShuffleOff => 'シャッフルをオフ';

  @override
  String get queueTitle => '再生キュー';

  @override
  String queueTrackCount(Object count) {
    return '$count 曲';
  }

  @override
  String get sidebarBackHome => 'ホームに戻る';

  @override
  String get sidebarCollapse => 'サイドバーを折りたたむ';

  @override
  String get sidebarDownload => 'ダウンロード';

  @override
  String get sidebarExpand => 'サイドバーを展開';

  @override
  String get sidebarFavorites => 'お気に入り';

  @override
  String get sidebarGroupMusic => '音楽';

  @override
  String get sidebarGroupPersonal => 'パーソナル';

  @override
  String get sidebarHistory => '履歴';

  @override
  String get sidebarHome => 'ホーム';

  @override
  String get sidebarLibrary => 'ライブラリ';

  @override
  String get sidebarLiked => 'いいねした曲';

  @override
  String get songListAlbum => 'アルバム';

  @override
  String get songListDuration => '時間';

  @override
  String get songListTitle => 'タイトル';

  @override
  String get songListScrollTop => 'トップへ戻る';

  @override
  String get songListLocatePlaying => '再生位置を探す';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return 'ダウンロードキューに追加しました：$quality';
  }

  @override
  String get toastAddedToQueue => '再生キューに追加しました';

  @override
  String get toastDownloadEngineNotReady =>
      'ダウンロードエンジンが準備できていません。後でもう一度お試しください';

  @override
  String get toastLiked => 'お気に入りに追加しました';

  @override
  String get toastLoginRequiredKugou =>
      '操作に失敗しました（Kugouアカウントにログインしているか確認してください）';

  @override
  String get toastLoginRequiredNetease =>
      '操作に失敗しました（Neteaseアカウントにログインしているか確認してください）';

  @override
  String get toastNoQualityInfo => 'この曲に利用可能な音質情報がなく、ダウンロードできません';

  @override
  String get toastUnliked => 'お気に入りから削除しました';

  @override
  String get commonClear => 'クリア';

  @override
  String get commonEmptyContent => 'コンテンツがありません';

  @override
  String commonLoadFailed(Object msg) {
    return '読み込みに失敗しました：$msg';
  }

  @override
  String get commonRetry => '再試行';

  @override
  String get commentDuplicate => '同じ内容を繰り返し送信しないでください';

  @override
  String get commentEmpty => 'まだコメントはありません';

  @override
  String get commentHot => '人気';

  @override
  String get commentInputEmpty => 'コメントは空にできません';

  @override
  String get commentInputHint => 'コメントを入力…';

  @override
  String get commentLatest => '最新';

  @override
  String commentLoginRequired(Object platform) {
    return 'コメントするには$platformアカウントにログインしてください';
  }

  @override
  String commentNotFound(Object platform) {
    return 'この曲の$platformコメントが見つかりません';
  }

  @override
  String get commentPublished => 'コメントを投稿しました';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user：$text';
  }

  @override
  String get commentSend => '送信';

  @override
  String commentSendFailed(Object msg) {
    return '送信に失敗しました：$msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$month月$day日 $time';
  }

  @override
  String get commentTitle => 'コメント';

  @override
  String get folderAdd => '追加';

  @override
  String get folderBrowse => '参照';

  @override
  String get folderEmpty => 'スキャン用フォルダがまだありません。下のボタンで追加してください';

  @override
  String get folderExists => 'フォルダは既に存在するか、無効です';

  @override
  String get folderInvalid => 'フォルダが存在しない、既に存在する、または空です';

  @override
  String get folderPathHint => 'フォルダの絶対パスを入力';

  @override
  String get folderRemove => '削除';

  @override
  String get folderRemoveDescription => '削除後はこのフォルダをスキャンしません。取り込んだ曲は保持されます。';

  @override
  String get folderRemoveTitle => 'スキャンフォルダの削除';

  @override
  String get loginFetchingQr => 'QRコードを取得中…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return '$platformにログイン済み';
  }

  @override
  String loginKugouLogin(Object platform) {
    return '$platformでログイン';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return '$platformにQRコードでログイン';
  }

  @override
  String get loginKugouResponseMissingToken => 'ログイン応答に token/userid がありません';

  @override
  String loginKugouScanHint(Object platform) {
    return '$platform App でQRコードをスキャンしてください';
  }

  @override
  String loginKugouSession(Object platform) {
    return '$platformでログイン中';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return '$platformにログインしました。VIP曲が利用可能です';
  }

  @override
  String loginLoggedOut(Object platform) {
    return '$platformからログアウトしました';
  }

  @override
  String loginLogoutWithId(Object id) {
    return 'ログアウト（$id）';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return '$platformにQRコードでログイン';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return '$platform App でQRコードをスキャンしてください';
  }

  @override
  String get loginQrExpired => 'QRコードの有効期限が切れました';

  @override
  String get loginQrExpiredRegenerate => 'QRコードの有効期限が切れました。クリックして再生成してください';

  @override
  String get loginQrLogin => 'QRコードログイン';

  @override
  String get loginRefreshQr => 'QRコードを更新';

  @override
  String get loginRegenerate => '再生成';

  @override
  String get loginSuccess => 'ログインしました';

  @override
  String get loginWaitingConfirm => 'スキャンしました。スマートフォンでログインを確認してください';

  @override
  String get trackListArtistHotSongs => 'アーティストの人気曲';

  @override
  String get trackListArtistSongs => 'アーティストの曲';

  @override
  String get trackListDailyRecommend => 'デイリーおすすめ';

  @override
  String get trackListDailyRecommendSubtitle => '好みに合わせて毎日更新';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return '曲がありません（デイリーおすすめは$platformへのログインが必要）';
  }

  @override
  String get trackListNoPlayableSource => '再生可能なソースがありません（VIP / 試聴制限）';

  @override
  String get trackListPlayAll => 'すべて再生';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return '再生ソースの取得に失敗しました: $msg';
  }

  @override
  String get trayNext => '次の曲';

  @override
  String get trayPlayPause => '再生 / 一時停止';

  @override
  String get trayPrevious => '前の曲';

  @override
  String get trayQuit => '終了';

  @override
  String get trayShow => 'メインウィンドウを表示';

  @override
  String get commonPlayAll => 'すべて再生';

  @override
  String get commonPause => '一時停止';

  @override
  String get commonPlay => '再生';

  @override
  String get commonRefresh => '更新';

  @override
  String get commonSearch => '検索';

  @override
  String get commonSongs => '曲';

  @override
  String get commonAlbums => 'アルバム';

  @override
  String get commonArtists => 'アーティスト';

  @override
  String get commonPlaylists => 'プレイリスト';

  @override
  String get commonDone => '完了';

  @override
  String get commonUnknownError => '不明なエラー';

  @override
  String commonSongCountHint(Object count) {
    return '計 $count 曲 · クリックで再生';
  }

  @override
  String get platformNetease => 'NetEase';

  @override
  String get platformKugou => 'Kugou';

  @override
  String get platformAll => 'すべて';

  @override
  String toastPlayedAll(Object count) {
    return '$count 曲をすべて再生しました';
  }

  @override
  String toastPlayFailed(Object msg) {
    return '再生に失敗しました：$msg';
  }

  @override
  String get toastMissingLocalPath => 'ローカルファイルパスがありません';

  @override
  String get toastLocateComingSoon => 'ファイルマネージャーを開く（Phase 2 で対応）';

  @override
  String get toastRemovedFromLibrary => 'ライブラリから削除しました';

  @override
  String get toastRemoveFailed => '削除に失敗しました';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return 'デイリーおすすめには$platformアカウントのログインが必要です';
  }

  @override
  String get toastPlaylistEmpty => 'プレイリストに曲がありません';

  @override
  String get toastAlbumEmpty => 'アルバムに曲がありません';

  @override
  String get toastPausedAll => 'すべて一時停止しました';

  @override
  String get toastResumedAll => 'すべて再開しました';

  @override
  String get toastPaused => '一時停止しました';

  @override
  String get toastCanceledTask => 'キャンセルしタスクを削除しました';

  @override
  String get toastResumed => 'ダウンロードを再開しました';

  @override
  String get toastRequeued => 'キューに再追加しました';

  @override
  String get toastDeletedSelected => '選択したタスクを削除しました';

  @override
  String get toastDeletedSelectedWithMedia => '選択したタスクとメディアファイルを削除しました';

  @override
  String get toastCleared => 'ダウンロードタスクをクリアしました';

  @override
  String get toastClearedWithMedia => 'タスクをクリアしメディアファイルを削除しました';

  @override
  String get toastDeletedTask => 'タスクを削除しました';

  @override
  String get toastDeletedTaskWithMedia => 'タスクとメディアファイルを削除しました';

  @override
  String get pageHistoryRemoved => '履歴から削除しました';

  @override
  String get pageHistoryClearTitle => '再生履歴をクリア';

  @override
  String get pageHistoryClearMessage => 'すべての再生履歴をクリアしますか？元に戻せません。';

  @override
  String get pageHistoryCleared => '再生履歴をクリアしました';

  @override
  String get pageHistoryRemove => '履歴から削除';

  @override
  String get pageHistorySubtitleEmpty => 'ローカルに保存された再生記録';

  @override
  String get pageHistoryEmpty => 'まだ再生記録がありません';

  @override
  String get pageHistoryEmptyHint => '再生した曲は自動的にここに記録されます';

  @override
  String pageFavPlaylistCount(Object count) {
    return '$count 件のお気に入りプレイリスト';
  }

  @override
  String get pageFavPlaylistLoginHint => 'ログインするとお気に入りプレイリストを表示できます';

  @override
  String pageFavAlbumCount(Object count) {
    return '$count 枚のお気に入りアルバム';
  }

  @override
  String get pageFavAlbumLoginHint => 'ログインするとお気に入りアルバムを表示できます';

  @override
  String pageFavArtistCount(Object count) {
    return '$count 組のお気に入りアーティスト';
  }

  @override
  String get pageFavArtistLoginHint => 'ログインするとお気に入りアーティストを表示できます';

  @override
  String get pageFavLoadFailed => 'お気に入りの読み込みに失敗しました';

  @override
  String get pageFavEmpty => 'まだお気に入りがありません';

  @override
  String get pageFavEmptyHint => 'NetEase Cloud Music App でお気に入り登録すると自動同期';

  @override
  String get pageFavLoginTitle => 'ログインしてお気に入りを表示';

  @override
  String get pageFavLoginDesc =>
      'NetEase Cloud Music にQRログインし、お気に入りのプレイリスト・アルバム・アーティストを同期';

  @override
  String get pageFavKgCreated => '作成したプレイリスト';

  @override
  String get pageFavKgCollectedPlaylist => 'お気に入りのプレイリスト';

  @override
  String get pageFavKgCollectedAlbum => 'お気に入りのアルバム';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '$count 件の作成済みプレイリスト';
  }

  @override
  String get pageFavKgCreatedLoginHint => 'ログインすると作成したプレイリストを表示できます';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '$count 件のお気に入りプレイリスト';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'ログインするとお気に入りのプレイリストを表示できます';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '$count 件のお気に入りアルバム';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint => 'ログインするとお気に入りのアルバムを表示できます';

  @override
  String get pageFavKugouLoginDesc => 'QRコードで酷狗にログインし、作成・お気に入りのプレイリストとアルバムを同期';

  @override
  String get pageFavKugouEmptyHint => '酷狗アプリでお気に入りにすると自動同期されます';

  @override
  String pageSearchLoadingTrack(Object title) {
    return '読み込み開始：$title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — 詳細ページは今後対応';
  }

  @override
  String get menuViewArtist => 'アーティストを表示';

  @override
  String get pageSearchArtistComingSoon => 'アーティストページは Phase 2 で対応';

  @override
  String get pageSearchInputHint => 'キーワードを入力して検索';

  @override
  String get pageSearchInputSubtitle => '曲 / アルバム / アーティスト / プレイリストに対応';

  @override
  String get pageSearching => '検索中…';

  @override
  String get pageSearchEmpty => '関連するコンテンツが見つかりません';

  @override
  String get pageSearchEmptyHint => '別のキーワードを試してください';

  @override
  String get pageSearchFailed => '検索に失敗しました';

  @override
  String get pageLikedKugouLoginHint => 'ログインするとKugouの「お気に入り」を同期できます';

  @override
  String get pageLikedNeteaseLoginHint => 'ログインするとNetEaseのお気に入りを同期できます';

  @override
  String get pageLikedLoadFailed => 'お気に入りリストの読み込みに失敗しました';

  @override
  String get pageLikedEmpty => 'まだお気に入りの曲がありません';

  @override
  String get pageLikedKugouEmptyHint => 'Kugou App で「お気に入り」に追加すると自動同期';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'NetEase Cloud Music App でハートをタップすると自動同期';

  @override
  String get pageLikedLoginTitle => 'ログインしてお気に入りの曲を表示';

  @override
  String get pageLikedKugouLoginDesc => 'Kugou にQRログインし、「お気に入り」コレクションを同期';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'NetEase Cloud Music にQRログインし、ハートのコレクションを同期';

  @override
  String get libraryScanDirs => 'スキャンディレクトリ';

  @override
  String get libraryScanDirsDesc => 'ローカル音楽のスキャンディレクトリを管理。追加後すぐスキャン';

  @override
  String get libraryMediaStats => 'メディア統計';

  @override
  String get libraryMediaStatsDesc => 'ローカル音楽ライブラリの概要';

  @override
  String get libraryStatTracks => '曲数';

  @override
  String get libraryStatDuration => '合計時間';

  @override
  String get libraryStatSize => '合計サイズ';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count 曲';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count 件';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h 時間 $m 分';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m 分';
  }

  @override
  String librarySeconds(Object s) {
    return '$s 秒';
  }

  @override
  String get librarySearchHint => 'ローカルの曲を検索';

  @override
  String get libraryNoMatch => '一致する曲がありません';

  @override
  String get libraryScanningFiles => 'ファイルを集計中…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count 曲$extra';
  }

  @override
  String get libraryEmptyWaitScan => '初回スキャンを待機中';

  @override
  String get libraryEmpty => 'ローカル音楽ライブラリは空です';

  @override
  String get libraryEmptyScanHint => '下のボタンで今すぐスキャン';

  @override
  String get libraryEmptyAddHint => '音楽フォルダーを追加するとスキャンして取り込めます';

  @override
  String get libraryScanNow => '今すぐスキャン';

  @override
  String get libraryAddFolder => 'フォルダーを追加';

  @override
  String get menuLocateFile => 'ファイルの場所を開く';

  @override
  String get menuLocateFileComingSoon => 'ファイルマネージャーは Phase 2 で対応';

  @override
  String get menuRemoveFromLibrary => 'ライブラリから削除';

  @override
  String get playerBarCollapsePlayer => 'プレーヤーを折りたたむ';

  @override
  String get playerBarHideLyrics => '歌詞を非表示';

  @override
  String get playerBarShowLyrics => '歌詞を表示';

  @override
  String get playerPageNotPlaying => '再生中ではありません';

  @override
  String get playerPageLoadHint => 'ソースを読み込んでから再生を開始';

  @override
  String get playerPageQualityMenu => '音質を切り替え';

  @override
  String get pageHomeRankTitle => 'ランキング';

  @override
  String get pageHomePlaylistSquare => 'プレイリスト広場';

  @override
  String get pageHomeHotArtists => '人気アーティスト';

  @override
  String get pageHomePlaylists => 'おすすめプレイリスト';

  @override
  String get pageHomeNewAlbums => '新着アルバム';

  @override
  String get pageHomeRankSubtitle => '各チャートの人気曲をリアルタイムで';

  @override
  String get pageHomePlaylistSquareSubtitle => '素敵なプレイリストをもっと見つけよう';

  @override
  String get pageHomeArtistSubtitle => '人気アーティスト、丸いアバター';

  @override
  String get pageHomeLoadFailed => 'おすすめの読み込みに失敗しました';

  @override
  String get pageHomePlaylistsSubtitle => 'あなたの好みに合わせておすすめ';

  @override
  String get pageHomeNewAlbumsSubtitle => '最近注目の新譜アルバム';

  @override
  String get pageHomeHotArtistsSubtitle => 'みんなが聴いている';

  @override
  String get pageHomeDaily => 'デイリーおすすめ';

  @override
  String get pageHomeDailyLoggedIn => 'あなたの好みに合わせて厳選';

  @override
  String get pageHomeDailyLoginHint => 'NetEaseアカウントにログインすると毎日更新されます';

  @override
  String get pageHomeDailyPlay => '今日のおすすめを再生';

  @override
  String get pageHomeDailyLogin => 'ログインしてデイリーおすすめを解禁';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting、$name';
  }

  @override
  String get greetingLate => '夜更かしですね';

  @override
  String get greetingMorning => 'おはようございます';

  @override
  String get greetingAfternoon => 'こんにちは';

  @override
  String get greetingEvening => 'こんばんは';

  @override
  String get greetingFallback => '今日は何を聴きたいですか？';

  @override
  String get downloadDeleteTaskOnly => 'タスクのみ削除';

  @override
  String get downloadDeleteWithMedia => 'タスクとメディアファイルを削除';

  @override
  String downloadSelectedCount(Object count) {
    return '$count 項目を選択中';
  }

  @override
  String get downloadSelectAll => 'すべて選択';

  @override
  String get downloadDeselectAll => '選択を解除';

  @override
  String get downloadPauseAll => 'すべて一時停止';

  @override
  String get downloadResumeAll => 'すべて開始';

  @override
  String get downloadDeleteSelected => '選択したものを削除';

  @override
  String get downloadExitSelect => '一括選択を終了';

  @override
  String downloadActiveCount(Object count) {
    return '進行中 $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return '完了 $count';
  }

  @override
  String get downloadOpenDir => 'ダウンロードフォルダを開く';

  @override
  String get downloadSelectMode => '一括選択';

  @override
  String get downloadEmpty => 'ダウンロードタスクがありません';

  @override
  String get downloadEmptyHint => '曲を右クリック → ダウンロード でキューに追加';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return '選択した $count 件のタスクを削除';
  }

  @override
  String get downloadDeleteSelectedMessage =>
      '選択したタスクを削除し .tmp キャッシュをクリア；メディアファイルは完全一致で削除。';

  @override
  String get downloadClearTitle => 'ダウンロードタスクをクリア';

  @override
  String get downloadClearMessage =>
      'すべてのタスクを削除し .tmp キャッシュをクリア；メディアファイルは完全一致で削除。';

  @override
  String get downloadCancelTooltip => 'キャンセル（タスクを削除しキャッシュをクリア）';

  @override
  String get downloadResume => 'ダウンロードを再開';

  @override
  String get downloadOpenDirTask => '保存先フォルダを開く';

  @override
  String get downloadDeleteTask => 'タスクを削除';

  @override
  String get downloadDeleteWithMediaExact => 'タスクとメディアファイルを削除（完全一致）';

  @override
  String get downloadStatusQueued => 'キューイング中…';

  @override
  String get downloadStatusResolving => 'ダウンロードURLを解決中…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return 'ダウンロード中 $percent%（$received）$speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return 'ダウンロード中…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return '一時停止中（$received）';
  }

  @override
  String get downloadStatusPaused => '一時停止中';

  @override
  String downloadStatusFailed(Object error) {
    return '失敗：$error';
  }

  @override
  String get downloadStatusFailedUnknown => '失敗：不明なエラー';

  @override
  String get downloadStatusCanceled => 'キャンセル済み';

  @override
  String downloadStatusDone(Object size) {
    return '完了（$size）';
  }

  @override
  String get downloadStatusAlready => 'ファイルは既に存在します';

  @override
  String get pageHomeTitle => '発見';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsCatAppearance => '外観';

  @override
  String get settingsCatPlayback => '再生';

  @override
  String get settingsCatLyrics => '歌詞';

  @override
  String get settingsCatPreset => '動作';

  @override
  String get settingsCatDownload => 'ダウンロード';

  @override
  String get settingsCatStorage => 'ストレージ';

  @override
  String get settingsCatAbout => 'について';

  @override
  String get settingsAppearanceSubtitle => 'テーマ · インターフェース設定';

  @override
  String get settingsPlaybackSubtitle => 'オーディオエンジン · 再生動作';

  @override
  String get settingsLyricsSubtitle => 'プレーヤー歌詞 · デスクトップ歌詞';

  @override
  String get settingsPresetSubtitle => '再生フィルター · 歌詞復元 · リストタグ';

  @override
  String get settingsDownloadSubtitle =>
      'ダウンロードフォルダ · 同時実行 · 速度制限 · 音質 · グループ · ファイル名';

  @override
  String get settingsStorageSubtitle => 'データディレクトリ · データベースファイル';

  @override
  String get settingsAboutSubtitle => 'バージョン · プロジェクト情報';

  @override
  String get settingsCatDeveloper => '開発者';

  @override
  String get settingsDeveloperSubtitle => '開発者モード · 隠し機能';

  @override
  String get settingsDeveloperTitle => '開発者モード';

  @override
  String get settingsDeveloperMode => '開発者モード';

  @override
  String get settingsDeveloperModeOn => '有効（ダウンロード機能を表示）';

  @override
  String get settingsDeveloperModeOff => '無効（ダウンロード機能を非表示）';

  @override
  String get settingsDeveloperDownloadModule => 'ダウンロードモジュール';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      'サイドバーの「ダウンロード」、コンテキストメニューの「ダウンロード」、設定の「ダウンロード」カテゴリは開発者モード有効時のみ表示されます。';

  @override
  String get settingsDeveloperNote => '開発者モードはローカルデバッグと個人利用を想定しています。利用は自己責任です。';

  @override
  String get settingsDevFpsMonitor => 'FPS/メモリ監視オーバーレイ';

  @override
  String get settingsDevFpsMonitorDesc =>
      '右上に FPS・平均フレーム時間・プロセスメモリをリアルタイム表示（クリックで折りたたみ）。既定ではオフ。開発者モードをオフにすると一緒にオフになります。';

  @override
  String get settingsDeveloperEnabled => '開発者モードを有効にしました';

  @override
  String get settingsDeveloperDisabled => '開発者モードを無効にしました';

  @override
  String get settingsDeveloperHoldHint => '10秒長押しで開発者モードを有効化（マウス：押し続ける）';

  @override
  String get settingsSearchHint => '設定を検索…';

  @override
  String settingsSearchNoResult(Object query) {
    return '「$query」に関連する設定は見つかりませんでした';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '$count 件一致';
  }

  @override
  String get settingsSectionTheme => 'テーマ';

  @override
  String get settingsThemeMode => 'テーマモード';

  @override
  String get settingsThemeModeDesc => 'ライト / ダーク / システムに従う';

  @override
  String get settingsThemeLight => 'ライト';

  @override
  String get settingsThemeDark => 'ダーク';

  @override
  String get settingsThemeSystem => 'システムに従う';

  @override
  String get settingsThemeNote => 'デフォルトはダークテーマ；「システムに従う」はOSの外観に依存。';

  @override
  String get settingsSectionAccent => 'アクセントカラー';

  @override
  String get settingsAccentTitle => 'プライマリカラーシード';

  @override
  String settingsAccentSystem(Object color) {
    return 'システムアクセントに従う（$color）';
  }

  @override
  String get settingsAccentSystemFallback => 'システムアクセントに従う（読込失敗時はカスタムにフォールバック）';

  @override
  String get settingsAccentDefault => 'デフォルトの明るい青（デザインシステム）';

  @override
  String get settingsAccentCustom => 'カスタム（シードから配色を動的生成）';

  @override
  String get settingsAccentDefaultTooltip => 'デフォルトの青';

  @override
  String get settingsAccentSystemTooltip => 'システムアクセントに従う';

  @override
  String get settingsAccentCustomTooltip => 'カスタムカラーピッカー';

  @override
  String get settingsSectionLayout => 'レイアウト';

  @override
  String get settingsFloatingBar => 'フローティングプレーヤーバー';

  @override
  String get settingsFloatingBarOn => '下部中央の角丸カプセル（ガラス + 影）';

  @override
  String get settingsFloatingBarOff => '全幅ドック（デフォルト）';

  @override
  String get settingsSectionFont => 'インターフェースフォント';

  @override
  String get settingsFontTitle => 'インターフェースフォント';

  @override
  String get settingsFontMiSans => 'MiSans（デフォルト）';

  @override
  String get settingsFontNoto => 'Noto Sans JP（標準メトリクス）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans（フリー商用）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans JP';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => 'インターフェース言語';

  @override
  String get settingsLanguageTitle => 'インターフェース言語';

  @override
  String get settingsLanguageDesc => 'インターフェースの表示言語を切り替え';

  @override
  String get settingsLangSystem => 'システムに従う';

  @override
  String get settingsSectionCover => 'カバーアート';

  @override
  String get settingsCoverRadius => 'カバー角丸';

  @override
  String get settingsCoverRadiusSharp => 'スクエア（情報密度高）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return '${radius}px 角丸';
  }

  @override
  String get settingsCoverRadiusSharpLabel => 'スクエア';

  @override
  String get settingsCoverRadiusRoundedLabel => '角丸';

  @override
  String get settingsCoverRadiusLargeLabel => '大きな角丸';

  @override
  String get settingsPickerTitle => 'カスタムアクセントカラー';

  @override
  String get settingsPickerHexLabel => 'カラー値（#RRGGBB）';

  @override
  String get settingsApply => '適用';

  @override
  String get settingsSectionAudio => 'オーディオ';

  @override
  String get settingsPassthrough => '原音質パススルー（トランスコードなし）';

  @override
  String get settingsPassthroughOn => 'ソースサンプルレートを維持（Hi-Res/ロスレス無劣化）';

  @override
  String get settingsPassthroughOff => '統一48kHzトランスコードパイプライン';

  @override
  String get settingsPassthroughNote =>
      'トランスコードOFFでソースのサンプルレートを維持、ONで48kHzに統一出力；切替後は現在の曲を自動リロードして有効。';

  @override
  String get volumeMute => 'ミュート';

  @override
  String get volumeUnmute => 'ミュート解除';

  @override
  String get settingsSectionMemory => 'メモリと起動';

  @override
  String get settingsSessionMemory => 'セッションメモリ';

  @override
  String get settingsSessionMemoryOn => '再生キュー、位置、モードを記憶し、次回起動時に復元';

  @override
  String get settingsSessionMemoryOff => '記憶しない（次回起動時は空）';

  @override
  String get settingsAutoPlay => '起動時に自動再生';

  @override
  String get settingsAutoPlayNeedMemory => '先に「セッションメモリ」を有効にしてください';

  @override
  String get settingsAutoPlayOn => '前回のセッションを復元して自動再生';

  @override
  String get settingsAutoPlayOff => 'セッションのみ復元し、自動再生しない';

  @override
  String get settingsSectionSpectrum => 'スペクトラム';

  @override
  String get settingsSpectrum => 'スペクトラムビジュアライザー';

  @override
  String get settingsSpectrumOn => '再生画面にスペクトラムバーを表示（再生0.65 / 一時停止0.15透明度）';

  @override
  String get settingsSpectrumOff => '再生画面にスペクトラムを表示しない';

  @override
  String get settingsSpectrumBarWidth => 'スペクトラムバー幅';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12、フルスクリーンプレーヤー）';
  }

  @override
  String get settingsBarSpectrum => 'プレイバーのスペクトラム';

  @override
  String get settingsBarSpectrumOn => '時刻の下にミニスペクトラムを表示（歌詞なしまたはミニ歌詞オフ時）';

  @override
  String get settingsBarSpectrumOff => 'プレイバーにミニスペクトラムを表示しない';

  @override
  String get settingsCoverBeatScale => 'カバーをビートに合わせて拡大';

  @override
  String get settingsCoverBeatScaleOn => 'カバーがビートに合わせてパルス';

  @override
  String get settingsCoverBeatScaleOff => 'カバーは静止（再生/一時停止のみ）';

  @override
  String get settingsTransitionStyle => 'メディア情報の切り替えアニメーション';

  @override
  String get settingsTransitionStyleDesc =>
      '曲の切り替え時にアルバムカバーと曲情報のトランジションアニメーション';

  @override
  String get settingsTransitionStyleScale => 'スケール';

  @override
  String get settingsTransitionStyleSlide => 'スライド';

  @override
  String get settingsSectionShortcuts => 'ショートカット';

  @override
  String get settingsShortcutSpace => 'スペース';

  @override
  String get settingsShortcutSpaceDesc => '再生 / 一時停止';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => '10秒戻る / 10秒進む';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => '音楽ライブラリ';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc => '戻る（ダイアログを閉じる / フルスクリーンプレーヤーを終了）';

  @override
  String get settingsSectionPlayerLyrics => 'プレーヤー歌詞';

  @override
  String get settingsPlayerLyrics => 'プレーヤー内歌詞';

  @override
  String get settingsPlayerLyricsOn => 'フルスクリーンプレーヤー右側に歌詞（現在行ハイライト、クリックでジャンプ）';

  @override
  String get settingsPlayerLyricsOff => 'フルスクリーンプレーヤーに歌詞を表示しない';

  @override
  String get settingsBarLyrics => 'プレイバーの歌詞';

  @override
  String get settingsBarLyricsOn => '時刻の下に現在の歌詞を表示（長い場合は自動スクロール）';

  @override
  String get settingsBarLyricsOff => 'プレイバーにミニ歌詞を表示しない';

  @override
  String get settingsShowTranslation => '翻訳を表示';

  @override
  String get settingsShowTranslationOn => '原句の後の括弧内に翻訳を表示';

  @override
  String get settingsShowTranslationOff => '歌詞の翻訳を表示しない';

  @override
  String get settingsSectionLyricStyle => '歌詞スタイル';

  @override
  String get settingsLyricFontSize => '歌詞フォントサイズ';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（現在行は拡大ハイライト）';
  }

  @override
  String get settingsLyricLineHeight => '歌詞行高';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（行間含む）';
  }

  @override
  String get settingsLyricPlayedColor => '再生済み色';

  @override
  String get settingsLyricPlayedColorDesc => '現在の歌詞行のハイライト色';

  @override
  String get settingsLyricUnplayedColor => '未再生色';

  @override
  String get settingsLyricUnplayedColorDesc => '今後の歌詞行の色';

  @override
  String get settingsLyricsNote => '歌詞スタイルはフルスクリーンプレーヤーの歌詞のみに適用';

  @override
  String get settingsSectionFilter => '再生フィルター';

  @override
  String get settingsDjMode => 'Fuck DJ Mode';

  @override
  String get settingsDjModeOn => 'DJ / ありきたりな曲を自動スキップ';

  @override
  String get settingsDjModeOff => 'DJ版の曲を検出したら自動で次の曲へ';

  @override
  String get settingsSectionLyricsFilter => '歌詞';

  @override
  String get settingsUncensor => '不適切語のロック解除';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => 'リスト表示';

  @override
  String get settingsHideVip => 'VIPタグを非表示';

  @override
  String get settingsHideVipOn => 'リストにVIP / 有料バッジを表示しない';

  @override
  String get settingsHideVipOff => '有料バッジを表示（VIP / EP）';

  @override
  String get settingsHideQuality => '音質タグを非表示';

  @override
  String get settingsHideQualityOn => 'リストに音質バッジを表示しない';

  @override
  String get settingsHideQualityOff => '利用可能な最高音質を表示（Hi-Res / ロスレス / HQ…）';

  @override
  String get settingsShowSubtitle => 'サブタイトルを表示';

  @override
  String get settingsShowSubtitleOn => '曲名の後に別名を表示（例：(Live)）';

  @override
  String get settingsShowSubtitleOff => 'リストに別名を表示しない';

  @override
  String get settingsEnergySaving => '省エネモード';

  @override
  String get settingsEnergySavingNote =>
      '有効にするとスペクトル取得頻度が約 300ms に下がり（既定 100ms）、CPU 使用量を削減。レンダリングと補間には影響せず、即時反映されます。';

  @override
  String get settingsEnergySavingOn => '現在フレーム間引きモード';

  @override
  String get settingsEnergySavingOff => '現在標準モード';

  @override
  String get settingsSearchEnergySavingSubtitle => 'スペクトル取得頻度を下げて CPU を節約';

  @override
  String get settingsPerformanceMode => 'パフォーマンスモード';

  @override
  String get settingsPerformanceModeOn => '現在凍結モード';

  @override
  String get settingsPerformanceModeOff => '現在アニメーションモード';

  @override
  String get settingsSectionDir => 'ディレクトリ';

  @override
  String get settingsDownloadRootHint => 'ダウンロードフォルダ（Enterで保存）';

  @override
  String get settingsRestoreDefault => 'デフォルトに戻す';

  @override
  String get settingsDownloadRootNote =>
      'デフォルト: メディアライブラリのフォルダに従う；フォルダを変更してEnterで保存。進行中のダウンロードは終了します。';

  @override
  String get settingsSectionFilename => 'ファイル名';

  @override
  String get settingsDownloadTemplateHint => 'ファイル名テンプレート（Enterで保存）';

  @override
  String get settingsDownloadTemplateNote =>
      'プレースホルダー: <artist> · <title> · <album>；以降にキューされたタスクのみに影響。Enterで保存、即座に有効。';

  @override
  String get settingsSectionQuality => '音質';

  @override
  String get settingsDownloadQuality => 'デフォルトダウンロード音質';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return 'ダウンロードダイアログのデフォルトは $quality；不足時は自動でダウングレード';
  }

  @override
  String get settingsDownloadQualityNote =>
      'ティアは高い順: Hi-Res → ロスレス → HQ → SQ → LQ；欠けた場合はこの順で自動ダウングレード。';

  @override
  String get settingsSectionConcurrent => '同時実行';

  @override
  String get settingsDownloadConcurrent => '同時ダウンロード数';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count 個の並列タスク（1~5）';
  }

  @override
  String get settingsDownloadGrouping => 'フォルダグループ化';

  @override
  String get settingsGroupingFlat => 'すべてダウンロードフォルダにフラットに配置';

  @override
  String get settingsGroupingPlatform => 'プラットフォーム別サブフォルダ（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => 'アーティスト別サブフォルダ';

  @override
  String get settingsGroupingFlatLabel => 'フラット';

  @override
  String get settingsGroupingPlatformLabel => 'プラットフォーム別';

  @override
  String get settingsGroupingArtistLabel => 'アーティスト別';

  @override
  String get settingsSectionSpeedLimit => '速度制限';

  @override
  String get settingsDownloadSpeedLimit => 'ダウンロード速度制限';

  @override
  String get settingsSpeedUnlimited => '無制限（デフォルト）';

  @override
  String settingsSpeedLimited(Object speed) {
    return '$speed に制限、即座に有効';
  }

  @override
  String get settingsSpeedUnlimitedLabel => '無制限';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote =>
      '速度制限は即時有効で進行中のタスクは中断しません（0.5 MB/s刻み、0 = 無制限）。';

  @override
  String get settingsSectionHistory => '履歴';

  @override
  String get settingsDownloadHistoryLimit => 'ダウンロード履歴の上限';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count 件（10~500）· 上限超過で古いものから自動削除';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count エントリ';
  }

  @override
  String get settingsDownloadHistoryNote =>
      '失敗 / キャンセル記録のみ古いものから削除；進行中のタスクは影響を受けません。';

  @override
  String get settingsGroupingNote =>
      'アーティスト別グループ化 v2 対応（フラット / プラットフォーム別 / アーティスト別）。';

  @override
  String get toastDownloadRootEmpty => 'ダウンロードフォルダは空にできません';

  @override
  String get toastDownloadRootUpdated => 'ダウンロードフォルダを更新しました';

  @override
  String get toastTemplateEmpty => 'ファイル名テンプレートは空にできません';

  @override
  String get toastTemplateUpdated => 'ファイル名テンプレートを更新しました';

  @override
  String settingsSpeedBs(Object n) {
    return '$n B/s';
  }

  @override
  String settingsSpeedKbs(Object n) {
    return '$n KB/s';
  }

  @override
  String settingsSpeedMbs(Object n) {
    return '$n MB/s';
  }

  @override
  String get settingsSectionFileLocation => 'ファイルの場所';

  @override
  String get settingsDataDir => 'データディレクトリ';

  @override
  String get settingsLibraryDb => 'メディアライブラリデータベース';

  @override
  String get settingsUserDb => 'ユーザーデータベース（暗号化）';

  @override
  String get settingsLibraryDbLabel => 'ライブラリパス';

  @override
  String get settingsUserDbLabel => 'ユーザーデータパス';

  @override
  String get settingsCopy => 'コピー';

  @override
  String toastCopied(Object label) {
    return '$label をコピーしました';
  }

  @override
  String get settingsStorageNote =>
      'メディアライブラリとユーザーデータは物理的に分離；パスは環境変数 ARCHOERA_DATA_DIR で上書き可能。';

  @override
  String get settingsSectionCache => 'キャッシュ管理';

  @override
  String get settingsCacheNote =>
      'キャッシュは閲覧と再生を高速化します。削除後は自動的に再構築され、ライブラリ・履歴・アカウントには影響しません。';

  @override
  String get settingsCacheGroupDisk => 'データベースキャッシュ（ディスク）';

  @override
  String get settingsCacheGroupMem => 'メモリキャッシュ（プロセス内）';

  @override
  String get settingsCacheLiked => '「いいね」リストキャッシュ';

  @override
  String get settingsCacheLyric => '歌詞コンテンツキャッシュ';

  @override
  String get settingsCacheLyricMatch => '歌詞マッチングキャッシュ';

  @override
  String get settingsCacheLyricTtml => 'TTML歌詞キャッシュ';

  @override
  String get settingsCacheCover => 'ジャケット画像キャッシュ';

  @override
  String settingsCacheEntries(Object count) {
    return '$count 件';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count 枚';
  }

  @override
  String get settingsCacheRefresh => '更新';

  @override
  String get settingsCacheClear => '削除';

  @override
  String get settingsCacheClearAll => 'すべて削除';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '「$name」を削除しますか？';
  }

  @override
  String get settingsCacheClearConfirmDesc =>
      'このキャッシュの全データを削除します。次回使用時に自動的に再構築され、取り消しはできません。';

  @override
  String get settingsCacheClearAllConfirmTitle => 'すべてのキャッシュを削除しますか？';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      '上記の全キャッシュ（メモリとディスク）を削除します。ライブラリ・履歴・アカウントには影響しません。';

  @override
  String toastCacheCleared(Object name) {
    return '$nameのキャッシュを削除しました';
  }

  @override
  String get toastCacheAllCleared => 'すべてのキャッシュを削除しました';

  @override
  String get settingsSecuritySection => '安全な破棄';

  @override
  String get settingsSecurityNote =>
      '本機の全アカウント資格情報とログインセッション（ストリーミングサーバーのパスワード、網易雲/酷狗のログイン状態、ローカル Subsonic アカウント）を不可逆に削除し、プラットフォームのトークンを無効化します。ライブラリ・履歴・ダウンロードファイルには影響しません。';

  @override
  String get settingsSecurityStreaming => 'ストリーミングサーバー資格情報';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count 台のサーバー';
  }

  @override
  String get settingsSecurityStreamingDesc => 'パスワードとアクセストークン';

  @override
  String get settingsSecuritySession => 'サードパーティのセッション';

  @override
  String get settingsSecuritySessionDesc => '網易雲 / 酷狗 のログイン状態';

  @override
  String get settingsSecurityUserDb => 'ローカルユーザーデータベース';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic アカウントとお気に入り';

  @override
  String get settingsSecurityLoggedIn => 'ログイン中';

  @override
  String get settingsSecurityDestroy => '破棄';

  @override
  String get settingsSecurityDestroyAll => 'すべて破棄';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '「$name」を破棄しますか？';
  }

  @override
  String get settingsSecurityConfirmAllTitle => 'すべての機密データを破棄しますか？';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return '関連プラットフォームのトークンを無効化し、ファイルを上書きして削除します。この操作は元に戻せません。続行するには「$word」と入力してください。';
  }

  @override
  String get settingsSecurityConfirmWord => '破棄';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return '「$word」と入力';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return '破棄しました：$name';
  }

  @override
  String get toastSecurityAllDestroyed => 'すべての機密データを破棄しました';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return '破棄に失敗しました。ファイルが残っている可能性があります：$path';
  }

  @override
  String get settingsVersion => 'バージョン';

  @override
  String get settingsVersionUnknown => 'v 不明 · Flutter デスクトップ';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter デスクトップ';
  }

  @override
  String get settingsAudioEngine => 'オーディオエンジン';

  @override
  String get settingsAudioEngineDesc => 'ビルトインCエンジン（miniaudio）· ネイティブFFI';

  @override
  String get settingsSubsonicServer => 'Subsonicサーバー';

  @override
  String get settingsSubsonicDesc => 'Go FFI · セルフホスト音楽ライブラリ';

  @override
  String get settingsAboutDesc =>
      '自前開発の音楽プレーヤー：ローカルライブラリ、音源ダイレクト接続、セルフホストSubsonic、ネイティブオーディオエンジン。';

  @override
  String get settingsSectionDeclaration => 'ソフトウェア声明';

  @override
  String get settingsDeclineText =>
      'このソフトウェア（ArchoeraMusic）は、個人の学習・研究目的の無料・オープンソースのデスクトップ音楽プレーヤーです。\n\n';

  @override
  String get settingsDecline1Title => '1. ソフトウェアの性質\n';

  @override
  String get settingsDecline1Body =>
      'このソフトウェアはサードパーティクライアントであり、各音楽プラットフォームおよびその公式クライアントとは一切の関連、提携、許諾関係はありません。\n\n';

  @override
  String get settingsDecline2Title => '2. コンテンツソースと著作権\n';

  @override
  String get settingsDecline2Body =>
      'このソフトウェア自体は音楽コンテンツを提供、保存、配布しません。著作権は元の権利者およびプラットフォームに帰属します。\n\n';

  @override
  String get settingsDecline3Title => '3. 著作権データ処理義務\n';

  @override
  String get settingsDecline3Body =>
      '著作権データは個人の試聴と学習研究のみを目的とし、商業目的または公衆への配布には使用しないでください。\n\n';

  @override
  String get settingsDecline4Title => '4. 使用制限\n';

  @override
  String get settingsDecline4Body =>
      '商業活動、一括スクレイピング、クローリング、転売に使用しないでください；法令または利用規約に違反する方法で使用しないでください。\n\n';

  @override
  String get settingsDecline5Title => '5. 免責事項\n';

  @override
  String get settingsDecline5Body =>
      'このソフトウェアは「現状のまま」提供され、明示または黙示のいかなる保証も行いません。\n\n';

  @override
  String get settingsDeclineFooter => 'このソフトウェアは技術的な探求と研究のみを目的としています。';

  @override
  String get settingsSectionFontCredits => 'フォントクレジット';

  @override
  String get settingsFontCreditsText =>
      '本ソフトウェアには以下のフォントが同梱されています。\n· Noto Sans CJK SC（SIL Open Font License 1.1）\n· MiSans（© Xiaomi、MiSans フォント知的財産権許諾契約に基づき使用）\n· HarmonyOS Sans SC（© Huawei、HarmonyOS Sans フォント許諾契約に基づき使用）';

  @override
  String get commonNoLyrics => '歌詞がありません';

  @override
  String commonTrackCount(Object count) {
    return '$count曲';
  }

  @override
  String get settingsSearchColorTitle => '再生済み / 未再生色';

  @override
  String get settingsSearchColorSubtitle => '現在行のハイライトと通常行の色';

  @override
  String get settingsSearchDesktopLyricsTitle => 'デスクトップ歌詞';

  @override
  String get settingsSearchDesktopLyricsSubtitle => '最前面の独立歌詞ウィンドウ';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => 'ファイル名テンプレート';

  @override
  String get settingsSearchAccentSubtitle => 'カスタムプライマリカラーシード · パレット';

  @override
  String get settingsThemeSource => 'テーマカラーソース';

  @override
  String get settingsThemeSourceDesc => 'プライマリカラーの取得元';

  @override
  String get settingsThemeSourceDefault => 'システムに従う';

  @override
  String get settingsThemeSourceCustom => 'カスタム';

  @override
  String get settingsThemeSourceCover => 'ジャケット連動';

  @override
  String get settingsThemeSourceSolid => 'なし';

  @override
  String get settingsThemeSourceCustomHint => 'シード色を選ぶと、プライマリ/セカンダリが動的に生成されます';

  @override
  String get settingsThemeSourceCoverHint =>
      '現在再生中のジャケットから代表色をリアルタイム抽出（取得できない場合はデフォルトにフォールバック）';

  @override
  String get settingsGlobalTint => 'グローバルティント';

  @override
  String get settingsGlobalTintDesc => 'テーマカラーをインターフェース全体に微妙に適用';

  @override
  String get settingsGlobalTintNote =>
      'テーマカラー（カスタム/ジャケット連動）がある場合に有効。画像背景モードでは強制オン。';

  @override
  String get settingsSectionStyle => '背景スタイル';

  @override
  String get settingsAppearanceStyle => '外観スタイル';

  @override
  String get settingsAppearanceStyleDesc => 'メイン背景の表示方法';

  @override
  String get settingsAppearanceStyleSolid => '単色';

  @override
  String get settingsAppearanceStyleImage => '画像';

  @override
  String get settingsBackgroundImage => '背景画像';

  @override
  String get settingsBackgroundImageDesc =>
      'ローカル画像をアプリの背景に選択（画像モードはダーク + グローバルティント強制）';

  @override
  String get settingsBackgroundPick => '画像を選択';

  @override
  String get settingsBackgroundReplace => '変更';

  @override
  String get settingsBackgroundClear => 'クリア';

  @override
  String get settingsBackgroundBlur => '背景ぼかし';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return '背景画像にガウスぼかしを適用（${blur}px）';
  }

  @override
  String get settingsBackgroundDim => 'マスク濃度';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return '黒のオーバーレイ透明度（$dim%）— 高いほど前景が読みやすく';
  }

  @override
  String get settingsBackgroundScale => 'ズームサイズ';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return '背景画像のズーム倍率（${scale}x）';
  }

  @override
  String get settingsSidebarCollapsed => 'サイドバーを折りたたむ';

  @override
  String get settingsSidebarCollapsedDesc => 'サイドバーをアイコンのみ表示に折りたたむ';

  @override
  String get settingsSidebarNavStyle => 'ナビハイライトアニメ';

  @override
  String get settingsSidebarNavStyleDesc => 'ナビゲーションのハイライトインジケータのアニメーションスタイル';

  @override
  String get settingsSidebarNavStyleDefault => '静的';

  @override
  String get settingsSidebarNavStyleAnimated => 'スライド';

  @override
  String get settingsRouteTransition => 'ページ遷移アニメ';

  @override
  String get settingsRouteTransitionDesc => 'ページ切り替え時のトランジションアニメーション';

  @override
  String get settingsRouteTransitionNone => 'なし';

  @override
  String get settingsRouteTransitionFade => 'フェード';

  @override
  String get settingsRouteTransitionSlide => 'スライド';

  @override
  String get settingsRouteTransitionZoom => 'ズーム';

  @override
  String get settingsSearchThemeSourceSubtitle => 'デフォルト · カスタム · ジャケット連動 · なし';

  @override
  String get settingsSearchGlobalTintSubtitle => 'テーマカラーをインターフェース全体に適用';

  @override
  String get settingsSearchBackgroundSubtitle => '単色 / 画像 · ぼかし · マスク · ズーム';

  @override
  String get settingsSearchSidebarSubtitle => 'サイドバー折りたたみ · 静的 / スライドハイライト';

  @override
  String get settingsSearchRouteTransitionSubtitle => 'なし · フェード · スライド · ズーム';

  @override
  String get settingsSearchFloatingBarSubtitle => '下部のフローティングカプセル · 全幅ドック';

  @override
  String get settingsSearchFontSubtitle =>
      'MiSans · Noto Sans · HarmonyOS Sans';

  @override
  String get settingsSearchLanguageSubtitle => 'システムに従う · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle => 'スクエア · 角丸 · 大きな角丸';

  @override
  String get settingsSectionWeather => '天気';

  @override
  String get settingsWeather => '天気ウィジェット';

  @override
  String get settingsWeatherDesc => 'アバター左にミニ天気（アイコン＋気温）';

  @override
  String get settingsWeatherAutoLocate => '自動位置情報';

  @override
  String get settingsWeatherAutoLocateDesc =>
      'ネットワーク IP でおおよその位置を取得（プライバシー：初期オフ）';

  @override
  String get settingsWeatherCity => '手動の都市';

  @override
  String get settingsWeatherCityHint => '入力後は IP 位置情報を使わない（例：東京）';

  @override
  String get settingsWeatherNote =>
      'プライバシー：天気データは Open-Meteo（無料・キー不要）。自動位置情報を有効にすると IP を ip-api.com に送信し大まかな位置を得ます。天気取得のみに使用し保存しません。ウィジェットと位置情報は初期状態でオフです。';

  @override
  String get settingsSearchWeatherSubtitle => '上部バーのミニ天気ウィジェット（アイコン＋気温）';

  @override
  String get weatherRefresh => '天気を更新';

  @override
  String get weatherNoLocation => '設定で都市を入力するか自動位置情報を有効にしてください';

  @override
  String get weatherUnavailable => '天気を取得できません。タップで再試行';

  @override
  String get settingsSearchPassthroughSubtitle => 'トランスコードなし · 48kHzパイプライン';

  @override
  String get settingsSearchSessionMemorySubtitle => '再生セッションの記録/復元';

  @override
  String get settingsSearchAutoPlaySubtitle => '自動再生トグル';

  @override
  String get settingsSearchSpectrumSubtitle => 'プレーヤースペクトラムトグル · 透明度';

  @override
  String get settingsSearchSpectrumWidthSubtitle => '1~12px バー幅';

  @override
  String get settingsSearchPlayerLyricsSubtitle => 'フルスクリーンプレーヤーの歌詞表示';

  @override
  String get settingsSearchLyricFontSizeSubtitle => '14~28px プレーヤー歌詞フォントサイズ';

  @override
  String get settingsSearchLyricLineHeightSubtitle => '42~64px 行高';

  @override
  String get settingsSearchUncensorSubtitle => '歌詞の伏せ字を復元';

  @override
  String get settingsSearchHideVipSubtitle => '曲リストのVIP/有料バッジを非表示';

  @override
  String get settingsSearchHideQualitySubtitle => '曲リストの音質バッジを非表示';

  @override
  String get settingsSearchSubtitleSubtitle => '曲リストに別名を表示（例: (Live)）';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      'ダウンロード保存先（デフォルト ~/Music/ArchoeraMusic）';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> プレースホルダー設定可能';

  @override
  String get settingsSearchConcurrentSubtitle => '1~5個の並列ダウンロードタスク';

  @override
  String get settingsSearchSpeedLimitSubtitle => '無制限 · 0.5~20 MB/s 即座に有効';

  @override
  String get settingsSearchQualitySubtitle => 'Hi-Res · ロスレス · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle => 'フラット · プラットフォーム別 · アーティスト別';

  @override
  String get settingsSearchHistoryLimitSubtitle => '上限超過で古いものから自動削除（10~500）';

  @override
  String get settingsSearchStorageSubtitle => 'メディアライブラリ · ユーザーDBパス';

  @override
  String get settingsSearchAboutSubtitle => 'オーディオエンジン · Subsonicサーバー';

  @override
  String get qualityLossless => 'ロスレス';

  @override
  String get repeatModeList => 'リストリピート';

  @override
  String get repeatModeOne => '1曲リピート';

  @override
  String get commonUnknownTrack => '不明なトラック';

  @override
  String get commonAnonymousUser => '匿名ユーザー';

  @override
  String get commonCanceled => 'キャンセル済み';

  @override
  String get commonILike => 'お気に入り';

  @override
  String get sidebarStreaming => 'ストリーミング';

  @override
  String get settingsCatMediaSource => 'メディアソース';

  @override
  String get settingsMediaSourceSubtitle =>
      'ストリーミングサーバー（Subsonic / Jellyfin / Emby）';

  @override
  String get settingsCatScrape => 'スクレイピング';

  @override
  String get settingsScrapeSubtitle => '複数ソースのメタデータ補完：カバー / 歌詞 / タグ';

  @override
  String get settingsSectionScrapeDirs => 'スクレイプ対象ディレクトリ';

  @override
  String get settingsScrapeDirsHint => '1行に1ディレクトリ。空欄ならライブラリのスキャン先に従う';

  @override
  String get settingsScrapeDirsEmptyNote => 'スクレイプ先が未設定のため、ライブラリのスキャン先を使用します。';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return '現在有効なディレクトリ：$dirs';
  }

  @override
  String get settingsSectionScrapeSources => 'データソース';

  @override
  String get settingsScrapeSourceMusicBrainz => 'MusicBrainz';

  @override
  String get settingsScrapeSourceDeezer => 'Deezer';

  @override
  String get settingsScrapeSourceItunes => 'iTunes';

  @override
  String get settingsScrapeSourceNetease => 'Netease Cloud Music';

  @override
  String get settingsScrapeSourceQQMusic => 'QQ 音楽';

  @override
  String get settingsScrapeSourceKugou => '酷狗音楽';

  @override
  String get settingsScrapeSourceKuwo => '酷我音楽';

  @override
  String get settingsScrapeSourceMigu => '咪咕音楽';

  @override
  String get settingsScrapeSourceAcoustID => 'AcoustID（音声フィンガープリント）';

  @override
  String get settingsScrapeSourceDesc => '有効にすると、複数ソースの検索・類似度照合・スコア統合に参加します';

  @override
  String get settingsSectionScrapeProgress => 'スクレイプ進捗';

  @override
  String get settingsScrapeStart => 'スクレイプ開始';

  @override
  String get settingsScrapeCancel => 'スクレイプ中止';

  @override
  String get settingsScrapeScanning => 'ディレクトリをスキャン中…';

  @override
  String settingsScrapeCurrent(Object file) {
    return '処理中：$file';
  }

  @override
  String get settingsScrapeSuccess => '成功';

  @override
  String get settingsScrapeFailed => '失敗';

  @override
  String get settingsScrapeSkipped => 'スキップ';

  @override
  String get settingsScrapeNotFound => '未マッチ';

  @override
  String get settingsScrapeIdle => 'まだ実行されていません。下のボタンから開始してください。';

  @override
  String get settingsScrapeNoDirs =>
      'スクレイプ対象のディレクトリがありません。スクレイプ先またはライブラリのスキャン先を設定してください。';

  @override
  String get settingsScrapeDone => 'スクレイプ完了';

  @override
  String get settingsScrapeCanceled => 'スクレイプ中止';

  @override
  String get toastScrapeNoDirs => 'スクレイプ対象のディレクトリがありません';

  @override
  String get toastScrapeDirsUpdated => 'スクレイプ先を保存しました';

  @override
  String get toastScrapeStarted => 'スクレイプを開始しました';

  @override
  String get commonDelete => '削除';

  @override
  String get commonSave => '保存';

  @override
  String get commonConfirm => '確定';

  @override
  String get streamingHint => 'メディアソース';

  @override
  String get streamingHintDetail =>
      'ストリーミングサーバーを追加して、サーバー上の音楽を閲覧・再生します（Subsonic 系 / Jellyfin / Emby、内蔵ローカル Subsonic サーバーを含む）。';

  @override
  String get streamingServerAdd => 'サーバーを追加';

  @override
  String get streamingEmptyNoServer => 'ストリーミングサーバーがまだありません';

  @override
  String get streamingEmptyAddHint => '上のボタンからサーバーを追加してください';

  @override
  String get streamingServerConnected => '接続済み';

  @override
  String get streamingServerDisconnected => '未接続';

  @override
  String get streamingServerLastConnected => '最終接続';

  @override
  String get streamingServerDisconnect => '切断';

  @override
  String get streamingToastDisconnected => 'サーバーから切断しました';

  @override
  String get streamingServerConnect => '接続';

  @override
  String streamingToastConnected(Object name) {
    return '$name に接続しました';
  }

  @override
  String get streamingServerConnectFailed => '接続に失敗しました';

  @override
  String get streamingServerEdit => '編集';

  @override
  String get streamingServerDeleteConfirmTitle => 'サーバーを削除';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return 'サーバー「$name」を削除しますか？';
  }

  @override
  String get streamingServerRemoved => 'サーバーを削除しました';

  @override
  String get streamingServerErrorNameEmpty => 'サーバー名を入力してください';

  @override
  String get streamingServerErrorHostEmpty => 'サーバーアドレスを入力してください';

  @override
  String get streamingServerErrorPortInvalid => 'ポートが無効です（1〜65535）';

  @override
  String get streamingServerErrorUsernameEmpty => 'ユーザー名を入力してください';

  @override
  String get streamingServerErrorPasswordEmpty => 'パスワードを入力してください';

  @override
  String get streamingServerAdded => 'サーバーを追加しました';

  @override
  String get streamingServerUpdated => 'サーバーを更新しました';

  @override
  String get streamingServerType => 'タイプ';

  @override
  String get streamingServerName => '名前';

  @override
  String get streamingServerNamePlaceholder => '例：マイ Navidrome';

  @override
  String get streamingServerHost => 'サーバーアドレス';

  @override
  String get streamingServerHostPlaceholder => '例：192.168.1.10:4533';

  @override
  String get streamingServerPort => 'ポート';

  @override
  String get streamingServerPortNote =>
      'デフォルトポート：4533（Subsonic）/ 8096（Jellyfin）。空欄で自動検出。';

  @override
  String get streamingServerLocalTitle => '内蔵ローカルサーバー';

  @override
  String get streamingServerLocalDesc => '内蔵 Subsonic サーバー（ローカルライブラリ）を使用';

  @override
  String get streamingServerUsername => 'ユーザー名';

  @override
  String get streamingServerPassword => 'パスワード';

  @override
  String get streamingServerTestOk => '接続成功';

  @override
  String get streamingServerTestFail => '接続失敗';

  @override
  String get streamingServerTest => '接続テスト';

  @override
  String get streamingTabsSongs => '曲';

  @override
  String get streamingTabsAlbums => 'アルバム';

  @override
  String get streamingTabsArtists => 'アーティスト';

  @override
  String get streamingTabsPlaylists => 'プレイリスト';

  @override
  String get streamingEmptyGoToSettings => '設定へ';

  @override
  String get streamingEmptyNotConnected => 'どのサーバーにも接続されていません';

  @override
  String streamingTotalSongs(Object count) {
    return '$count 曲';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count 枚のアルバム';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count 人のアーティスト';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count 個のプレイリスト';
  }

  @override
  String get streamingEmptyNoResults => '一致する結果がありません';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count 曲';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count 枚のアルバム';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count 曲';
  }
}
