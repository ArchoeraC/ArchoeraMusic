// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get settingsCatRender => 'パフォーマンス / レンダリング';

  @override
  String get settingsRenderSubtitle => 'GPU アクセラレーションとレンダリング負荷（実験的）';

  @override
  String get settingsRippleShader => '波紋 GPU シェーダー';

  @override
  String get settingsRippleShaderDesc =>
      'フラグメントシェーダーで再生画面の波紋を描画（オフ = CPU メッシュ）';

  @override
  String get settingsRippleLowRes => '動的レイヤーの半解像度化';

  @override
  String get settingsRippleLowResDesc =>
      '波紋の動的レイヤーを半解像度で描画して拡大；CPU フォールバック時のみ有効';

  @override
  String get settingsRippleDamageClip => 'ダメージ領域クリッピング';

  @override
  String get settingsRippleDamageClipDesc => 'アクティブな波紋帯のみ再描画；CPU フォールバック時のみ有効';

  @override
  String get menuTrackDetail => 'メディア詳細';

  @override
  String get menuEditTags => 'メタデータを編集';

  @override
  String get tagEditorTitle => 'メタデータを編集';

  @override
  String get tagEditorLoading => 'タグを読み込み中…';

  @override
  String get tagEditorLoadFailed => 'タグの読み込みに失敗しました';

  @override
  String get tagEditorFieldTitle => 'タイトル';

  @override
  String get tagEditorFieldArtist => 'アーティスト';

  @override
  String get tagEditorFieldAlbum => 'アルバム';

  @override
  String get tagEditorFieldAlbumArtist => 'アルバムアーティスト';

  @override
  String get tagEditorFieldComposer => '作曲者';

  @override
  String get tagEditorFieldGenre => 'ジャンル';

  @override
  String get tagEditorFieldTrackNumber => 'トラック番号';

  @override
  String get tagEditorFieldDiscNumber => 'ディスク番号';

  @override
  String get tagEditorFieldYear => '年';

  @override
  String get tagEditorFieldLyrics => '歌詞';

  @override
  String get tagEditorFieldCover => 'カバー';

  @override
  String get tagEditorCoverChange => 'カバーを変更';

  @override
  String get tagEditorCoverRemove => 'カバーを削除';

  @override
  String get tagEditorSave => '保存';

  @override
  String get tagEditorSaved => 'メタデータを保存しました';

  @override
  String get tagEditorSaveFailed => '保存に失敗しました';

  @override
  String get tagEditorNoPath => 'ローカルファイルのパスがありません';

  @override
  String get tagEditorDuration => '再生時間';

  @override
  String get tagEditorScrape => 'オンラインで取得';

  @override
  String get tagEditorScraping => '取得中…';

  @override
  String get tagEditorScrapeHint => '有効な音楽ソースから照合し、結果を下の欄に入力します（保存前に確認できます）';

  @override
  String get tagEditorScrapeDone => '取得結果を反映しました';

  @override
  String get tagEditorScrapeNotFound => '一致するオンラインメタデータが見つかりません';

  @override
  String get tagEditorScrapeFailed => '取得に失敗しました';

  @override
  String get tagEditorScrapeNeedQuery => '先にタイトルまたはアーティストを入力してください';

  @override
  String get menuBatchEditMetadata => 'メタデータを一括編集';

  @override
  String get tagEditorBatchTitle => 'メタデータを一括編集';

  @override
  String get tagEditorBatchHint => '変更したいフィールドのみ入力してください。空欄は元の値を保持します';

  @override
  String get tagEditorBatchCoverKeep => 'カバーを保持';

  @override
  String get tagEditorBatchCoverReplace => 'カバーを変更';

  @override
  String get tagEditorBatchCoverRemove => 'カバーを削除';

  @override
  String get tagEditorBatchApply => '選択項目に適用';

  @override
  String get tagEditorBatchNoEditable => '選択した曲はいずれもメタデータの編集に対応していません';

  @override
  String tagEditorBatchDone({required int success, required int failed}) {
    return '$success 件更新、$failed 件失敗';
  }

  @override
  String get tagEditorBatchStop => '停止';

  @override
  String get tagEditorBatchRules => 'タイトル / アーティストのルール';

  @override
  String get tagEditorBatchTitleRule => 'タイトル';

  @override
  String get tagEditorBatchArtistRule => 'アーティスト';

  @override
  String get tagEditorBatchRuleNone => '変更しない';

  @override
  String get tagEditorBatchRuleFindReplace => '検索と置換';

  @override
  String get tagEditorBatchRulePrefix => '接頭辞を追加';

  @override
  String get tagEditorBatchRuleSuffix => '接尾辞を追加';

  @override
  String get tagEditorBatchFindLabel => '検索';

  @override
  String get tagEditorBatchReplaceLabel => '置換後';

  @override
  String get tagEditorBatchAffixLabel => '内容';

  @override
  String get tagEditorBatchTokensHint =>
      '使用可能なプレースホルダー：[index] [track] [title] [artist] [album] [year]';

  @override
  String get tagEditorRuleApply => 'ルールを適用';

  @override
  String get tagEditorRuleTargetBoth => '両方';

  @override
  String get tagEditorRulePreview => 'プレビュー';

  @override
  String get tagEditorRuleRegex => '正規表現';

  @override
  String get tagEditorRuleCaseSensitive => '大文字と小文字を区別';

  @override
  String get tagEditorRulePresets => 'プリセット';

  @override
  String get tagEditorRulePresetTrim => '前後の空白を削除';

  @override
  String get tagEditorRulePresetStripBrackets => '末尾の括弧を削除';

  @override
  String get tagEditorRulePresetStripLive => 'Live 表記を削除';

  @override
  String get tagEditorRulePresetIndexSuffix => '[index] の接尾辞を追加';

  @override
  String get tagEditorRulePresetStripFeat => 'feat. 部分を削除';

  @override
  String get tagEditorRulePresetSave => 'プリセットとして保存';

  @override
  String get tagEditorRulePresetName => 'プリセット名';

  @override
  String get tagEditorRulePresetDelete => 'プリセットを削除';

  @override
  String get tagEditorRulePresetSaved => 'プリセットを保存しました';

  @override
  String get tagEditorRulePresetRename => '名前を変更';

  @override
  String get tagEditorRulePresetMoveUp => '上へ移動';

  @override
  String get tagEditorRulePresetMoveDown => '下へ移動';

  @override
  String tagEditorBatchProgress({required int done, required int total}) {
    return '処理中 $done/$total';
  }

  @override
  String get trackDetailDuration => '再生時間';

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
  String toastBatchAddedToQueue({required Object count}) {
    return 'キューに $count 曲追加しました';
  }

  @override
  String toastBatchAddedToDownloadQueue({required Object count}) {
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
      'バックグラウンドで描画を抑制（最小化時は描画停止、非フォーカス/画面オフ時 1 FPS）';

  @override
  String get settingsPowerSaverOff => '常にフルレートで描画';

  @override
  String get settingsSuppressSleep => 'システムのスリープを無効化';

  @override
  String get settingsSuppressSleepOn => '再生中はシステムを起動状態に保ち、バックグラウンド再生の中断を防ぐ';

  @override
  String get settingsSuppressSleepOff => 'システムはアイドル時にスリープする可能性があります';

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
  String get brandNetease => 'NT';

  @override
  String get brandKugou => 'KG';

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
  String downloadRequiresLoginContent({required Object platform}) {
    return '$platformのダウンロードリンクの取得にはログインが必要です。未ログインでは試聴のみで、完全な音質はダウンロードできません。\n\n$platformアカウントにログインしてから再試行してください。';
  }

  @override
  String get downloadRequiresLoginTitle => 'ダウンロードにはログインが必要です';

  @override
  String get downloadStreamingWarnTitle => 'ストリーミングのダウンロードは推奨されません';

  @override
  String get downloadStreamingWarnBody =>
      'ストリーミングの視聴が安定している場合、あまり使わない場合、または自分でサーバーを運用している場合は、ローカルへのダウンロードはおすすめしません。';

  @override
  String get downloadStreamingWarnDontAsk => '今後表示しない';

  @override
  String get downloadStreamingWarnProceed => 'それでもダウンロード';

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
  String navHeaderKugouId({required Object id}) {
    return 'KG $id';
  }

  @override
  String get navHeaderKugouMusic => 'KG';

  @override
  String get navHeaderLoginAccount => 'ログイン（NT / KG）';

  @override
  String get navHeaderLogout => 'ログアウト';

  @override
  String get navHeaderNeteaseAccount => 'NTアカウント';

  @override
  String get navHeaderNeteaseMusic => 'NT';

  @override
  String get navHeaderQqMusic => 'QM';

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
  String get queueRepeatOff => '順番に再生';

  @override
  String get queueFinished => 'プレイリストの再生が終了し、一時停止しました';

  @override
  String get queueShuffle => 'シャッフル再生';

  @override
  String get queueShuffleOff => 'シャッフルをオフ';

  @override
  String get queueTitle => '再生キュー';

  @override
  String queueTrackCount({required Object count}) {
    return '$count 曲';
  }

  @override
  String get searchHistory => '検索履歴';

  @override
  String get searchHistoryClear => 'クリア';

  @override
  String get searchHistoryEmpty => '検索履歴はありません';

  @override
  String get searchHot => 'ホット検索';

  @override
  String searchQuick({required Object query}) {
    return '「$query」を検索';
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
  String toastAddedToDownloadQueue({required Object quality}) {
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
  String get toastLoginRequiredKugou => '操作に失敗しました（KGアカウントにログインしているか確認してください）';

  @override
  String get toastLoginRequiredNetease =>
      '操作に失敗しました（NTアカウントにログインしているか確認してください）';

  @override
  String get toastNoQualityInfo => 'この曲に利用可能な音質情報がなく、ダウンロードできません';

  @override
  String get toastUnliked => 'お気に入りから削除しました';

  @override
  String get commonClear => 'クリア';

  @override
  String get commonEmptyContent => 'コンテンツがありません';

  @override
  String commonLoadFailed({required Object msg}) {
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
  String commentLoginRequired({required Object platform}) {
    return 'コメントするには$platformアカウントにログインしてください';
  }

  @override
  String commentNotFound({required Object platform}) {
    return 'この曲の$platformコメントが見つかりません';
  }

  @override
  String get commentPublished => 'コメントを投稿しました';

  @override
  String commentReplyFormat({required Object text, required Object user}) {
    return '@$user：$text';
  }

  @override
  String get commentSend => '送信';

  @override
  String commentSendFailed({required Object msg}) {
    return '送信に失敗しました：$msg';
  }

  @override
  String get commentReply => '返信';

  @override
  String commentReplyTo({required Object user}) {
    return '@$user へ返信';
  }

  @override
  String get commentDeleteConfirmBody => '削除すると元に戻せません。続行しますか？';

  @override
  String get commentDeleted => 'コメントを削除しました';

  @override
  String commentDeleteFailed({required Object msg}) {
    return '削除に失敗しました：$msg';
  }

  @override
  String commentTimeFormat({
    required Object day,
    required Object month,
    required Object time,
  }) {
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
  String loginKugouLoggedIn({required Object platform}) {
    return '$platformにログイン済み';
  }

  @override
  String loginKugouLogin({required Object platform}) {
    return '$platformでログイン';
  }

  @override
  String loginKugouQrLogin({required Object platform}) {
    return '$platformにQRコードでログイン';
  }

  @override
  String get loginKugouResponseMissingToken => 'ログイン応答に token/userid がありません';

  @override
  String loginKugouScanHint({required Object platform}) {
    return '$platform App でQRコードをスキャンしてください';
  }

  @override
  String loginKugouSession({required Object platform}) {
    return '$platformでログイン中';
  }

  @override
  String loginKugouSuccessVip({required Object platform}) {
    return '$platformにログインしました。VIP曲が利用可能です';
  }

  @override
  String loginLoggedOut({required Object platform}) {
    return '$platformからログアウトしました';
  }

  @override
  String loginLogoutWithId({required Object id}) {
    return 'ログアウト（$id）';
  }

  @override
  String loginNeteaseScanHint({required Object platform}) {
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
  String get loginRiskTitle => 'ログインのリスクについて';

  @override
  String get loginRiskBody =>
      'サードパーティクライアントへのログインには以下のリスクがあります。確認のうえ続行してください：\n\n· プラットフォームはサードパーティクライアントのログインに対してリスク管理・制限・凍結を行う場合があり、アカウント異常や機能制限を引き起こす可能性があります；\n· QR / 認証情報によるログインは、お客様のアカウントで本ソフトウェアがプラットフォームへアクセスすることを許可することを意味し、お気に入り・再生・コメント等の操作は実際にお客様のアカウントに反映されます；\n· ログイン資格情報（Cookie / トークン等）は本機にのみ暗号化して保存され、開発者やプラットフォーム以外のサーバーへアップロードされることはありません；\n· 各プラットフォームの利用規約を遵守してください。本ソフトウェアの使用による一切の結果はお客様が負担します。\n\nログインを続行すると、上記のリスクを読み理解し同意したものとみなされます。';

  @override
  String get loginRiskAgree => '理解しました、続行';

  @override
  String get loginTabQr => 'QR コード';

  @override
  String get loginTabPhone => '電話番号';

  @override
  String get loginTabEmail => 'メール';

  @override
  String loginTitleBrand({required String platform}) {
    return '$platform にログイン';
  }

  @override
  String get loginPhoneHint => '電話番号';

  @override
  String get loginCodeHint => 'SMS 認証コード';

  @override
  String get loginSendCode => 'コードを送信';

  @override
  String get loginEmailHint => 'メール';

  @override
  String get loginPasswordHint => 'パスワード';

  @override
  String get loginEmailRiskHint =>
      'ヒント：アカウントに電話番号が紐付いている場合、メールログイン時にプラットフォームが SMS 認証を送信することがあります（プラットフォームのセキュリティ対策であり、本ソフトウェアとは無関係です）。';

  @override
  String get loginSubmit => 'ログイン';

  @override
  String get loginPhoneRequired => '電話番号を入力してください';

  @override
  String get loginCodeRequired => '認証コードを入力してください';

  @override
  String get loginEmailRequired => 'メールアドレスを入力してください';

  @override
  String get loginPasswordRequired => 'パスワードを入力してください';

  @override
  String get loginCodeSendFailed => '認証コードの送信に失敗しました';

  @override
  String get loginFailed => 'ログインに失敗しました';

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
  String trackListEmptyDailyLogin({required Object platform}) {
    return '曲がありません（デイリーおすすめは$platformへのログインが必要）';
  }

  @override
  String get trackListNoPlayableSource => '再生可能なソースがありません（VIP / 試聴制限）';

  @override
  String get trackListPlayAll => 'すべて再生';

  @override
  String trackListPlaySourceFailed({required Object msg}) {
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
  String commonSongCountHint({required Object count}) {
    return '計 $count 曲 · クリックで再生';
  }

  @override
  String get platformNetease => 'NT';

  @override
  String get platformKugou => 'KG';

  @override
  String get platformAll => 'すべて';

  @override
  String get menuDeleteFile => 'ファイルを削除';

  @override
  String get libraryDeleteFileTitle => 'ファイルを削除';

  @override
  String libraryDeleteFileMessage({required Object name}) {
    return '「$name」を完全に削除します。元に戻せません。続行しますか？';
  }

  @override
  String get libraryDeleteFileConfirm => '削除';

  @override
  String get toastFileDeleted => 'ファイルを削除しました';

  @override
  String get toastDeleteFileFailed => 'ファイルの削除に失敗しました';

  @override
  String get toastRevealFileFailed => 'ファイルを表示できません（ファイルマネージャーが利用できません）';

  @override
  String get settingsSectionThirdPartyService => 'サードパーティサービス';

  @override
  String get settingsNekoAttribution => '本アプリは Neko Music API によって提供されています';

  @override
  String get settingsNekoApiDocs => 'Neko Music API ドキュメント';

  @override
  String get settingsSongCacheMemoryHint =>
      '「メモリ内再生」が有効なため、楽曲キャッシュはディスクに書き込まれません';

  @override
  String get platformNeko => 'NK';

  @override
  String get settingsCatExperimentalSource => '実験的音源';

  @override
  String get settingsExperimentalSourceSubtitle => 'サードパーティ音源（既定でオフ）';

  @override
  String get settingsNekoTitle => 'NekoMusic';

  @override
  String get settingsNekoNote =>
      'サードパーティの実験的音源です（非公式）。ログインのみ対応で、新規登録や VIP 購入はありません。予告なく利用できなくなる場合があります。';

  @override
  String get settingsNekoEnable => 'NekoMusic を有効化';

  @override
  String get settingsNekoEnableDesc => '検索・お気に入り・ライブラリに NK を表示（既定でオフ）';

  @override
  String get settingsNekoLogin => 'ログイン';

  @override
  String get settingsNekoLogout => 'ログアウト';

  @override
  String settingsNekoLoggedInAs({required Object name}) {
    return 'ログイン中：$name';
  }

  @override
  String get settingsNekoNotLoggedIn => '未ログイン';

  @override
  String get nekoLoginTitle => 'NekoMusic にログイン';

  @override
  String get nekoLoginTabQr => '二次元コード';

  @override
  String get nekoLoginTabPassword => 'メールとパスワード';

  @override
  String get nekoLoginEmail => 'メール';

  @override
  String get nekoLoginPassword => 'パスワード';

  @override
  String get nekoLoginPasswordHint => 'パスワードを入力';

  @override
  String get nekoLoginSubmit => 'ログイン';

  @override
  String get nekoLoginQrHint => 'NekoMusic アプリでスキャンしてログイン';

  @override
  String get nekoQrScanned => 'スキャン済み。スマホで確認してください';

  @override
  String get nekoQrCanceled => 'ログインをキャンセルしました';

  @override
  String get nekoQrExpired => '二次元コードの有効期限が切れました。再生成してください';

  @override
  String get toastLoginRequiredNeko => '操作に失敗しました（NK アカウントにログインしているか確認してください）';

  @override
  String get pageLikedNekoLoginHint => 'NK にログインしてお気に入りを表示';

  @override
  String get pageLikedNekoLoginDesc => 'NekoMusic にログインしてお気に入りを同期';

  @override
  String get pageLikedNekoEmptyHint => 'お気に入りの曲はまだありません。検索ページでハートをタップ';

  @override
  String get pageFavNekoLoginDesc => 'NekoMusic にログインしてプレイリストとお気に入りを表示';

  @override
  String get pageFavNekoEmptyHint => 'プレイリストやお気に入りはまだありません';

  @override
  String toastPlayedAll({required Object count}) {
    return '$count 曲をすべて再生しました';
  }

  @override
  String toastPlayFailed({required Object msg}) {
    return '再生に失敗しました：$msg';
  }

  @override
  String get toastMissingLocalPath => 'ローカルファイルパスがありません';

  @override
  String get toastRemovedFromLibrary => 'ライブラリから削除しました';

  @override
  String get toastRemoveFailed => '削除に失敗しました';

  @override
  String toastDailyRequiresLogin({required Object platform}) {
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
  String pageFavPlaylistCount({required Object count}) {
    return '$count 件のお気に入りプレイリスト';
  }

  @override
  String get pageFavPlaylistLoginHint => 'ログインするとお気に入りプレイリストを表示できます';

  @override
  String pageFavAlbumCount({required Object count}) {
    return '$count 枚のお気に入りアルバム';
  }

  @override
  String get pageFavAlbumLoginHint => 'ログインするとお気に入りアルバムを表示できます';

  @override
  String pageFavArtistCount({required Object count}) {
    return '$count 組のお気に入りアーティスト';
  }

  @override
  String get pageFavArtistLoginHint => 'ログインするとお気に入りアーティストを表示できます';

  @override
  String get pageFavLoadFailed => 'お気に入りの読み込みに失敗しました';

  @override
  String get pageFavEmpty => 'まだお気に入りがありません';

  @override
  String get pageFavEmptyHint => 'NT App でお気に入り登録すると自動同期';

  @override
  String get pageFavLoginTitle => 'ログインしてお気に入りを表示';

  @override
  String get pageFavLoginDesc => 'NT にQRログインし、お気に入りのプレイリスト・アルバム・アーティストを同期';

  @override
  String get pageFavKgCreated => '作成したプレイリスト';

  @override
  String get pageFavKgCollectedPlaylist => 'お気に入りのプレイリスト';

  @override
  String get pageFavKgCollectedAlbum => 'お気に入りのアルバム';

  @override
  String pageFavKgCreatedCount({required Object count}) {
    return '$count 件の作成済みプレイリスト';
  }

  @override
  String get pageFavKgCreatedLoginHint => 'ログインすると作成したプレイリストを表示できます';

  @override
  String pageFavKgCollectedPlaylistCount({required Object count}) {
    return '$count 件のお気に入りプレイリスト';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'ログインするとお気に入りのプレイリストを表示できます';

  @override
  String pageFavKgCollectedAlbumCount({required Object count}) {
    return '$count 件のお気に入りアルバム';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint => 'ログインするとお気に入りのアルバムを表示できます';

  @override
  String get pageFavKugouLoginDesc => 'QRコードでKGにログインし、作成・お気に入りのプレイリストとアルバムを同期';

  @override
  String get pageFavKugouEmptyHint => 'KGアプリでお気に入りにすると自動同期されます';

  @override
  String pageSearchLoadingTrack({required Object title}) {
    return '読み込み開始：$title';
  }

  @override
  String get menuViewArtist => 'アーティストを表示';

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
  String get pageLikedKugouLoginHint => 'ログインするとKGの「お気に入り」を同期できます';

  @override
  String get pageLikedNeteaseLoginHint => 'ログインするとNTのお気に入りを同期できます';

  @override
  String get pageLikedLoadFailed => 'お気に入りリストの読み込みに失敗しました';

  @override
  String get pageLikedEmpty => 'まだお気に入りの曲がありません';

  @override
  String get pageLikedKugouEmptyHint => 'KG App で「お気に入り」に追加すると自動同期';

  @override
  String get pageLikedNeteaseEmptyHint => 'NT App でハートをタップすると自動同期';

  @override
  String get toastQqLikeSyncFailed =>
      'QQ ミュージックのオンラインお気に入り同期に失敗しました（実験的API）。ハートの変更を取り消しました';

  @override
  String get pageLikedQqHint =>
      'QQ ミュージックのハートは端末に保存され常に利用できます。ログインするとオンラインお気に入りを実験的に同期できます';

  @override
  String get pageLikedQqEmptyTitle => 'まだ QQ ミュージックのお気に入り曲がありません';

  @override
  String get pageLikedQqEmptyHint =>
      '検索・再生ページで QQ ミュージックの曲をハートするとここに表示されます（端末に保存）';

  @override
  String get pageLikedQqLoginSync => 'ログインしてオンラインお気に入りを同期（実験）';

  @override
  String get pageLikedQqSyncOnline => 'オンラインお気に入りを同期（実験）';

  @override
  String pageLikedQqSynced({required Object count}) {
    return 'オンラインお気に入りを同期しました：$count 曲追加';
  }

  @override
  String get pageLikedQqSyncedNone => 'すでに同期済みです。追加するオンラインお気に入りはありません';

  @override
  String get pageLikedLoginTitle => 'ログインしてお気に入りの曲を表示';

  @override
  String get pageLikedKugouLoginDesc => 'KG にQRログインし、「お気に入り」コレクションを同期';

  @override
  String get pageLikedNeteaseLoginDesc => 'NT にQRログインし、ハートのコレクションを同期';

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
  String libraryStatTrackCount({required Object count}) {
    return '$count 曲';
  }

  @override
  String libraryScanDirCount({required Object count}) {
    return '$count 件';
  }

  @override
  String libraryHoursMinutes({required Object h, required Object m}) {
    return '$h 時間 $m 分';
  }

  @override
  String libraryMinutes({required Object m}) {
    return '$m 分';
  }

  @override
  String librarySeconds({required Object s}) {
    return '$s 秒';
  }

  @override
  String get librarySearchHint => 'ローカルの曲を検索';

  @override
  String get libraryNoMatch => '一致する曲がありません';

  @override
  String get libraryScanningFiles => 'ファイルを集計中…';

  @override
  String libraryTrackCount({required Object count, required Object extra}) {
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
  String get menuRemoveFromLibrary => 'ライブラリから削除';

  @override
  String get playerBarCollapsePlayer => 'プレーヤーを折りたたむ';

  @override
  String get playerBarExitFullscreen => '全画面を終了';

  @override
  String get playerBarFullscreen => '全画面';

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
  String get pageHomeDailyLoginHint => 'NTアカウントにログインすると毎日更新されます';

  @override
  String get pageHomeDailyPlay => '今日のおすすめを再生';

  @override
  String get pageHomeDailyLogin => 'ログインしてデイリーおすすめを解禁';

  @override
  String pageHomeSpotlightTitle({required Object song}) {
    return '「$song」から聴く';
  }

  @override
  String pageHomeSpotlightSubtitle({required Object count}) {
    return 'ランダムに $count 曲選びました';
  }

  @override
  String get pageHomeSpotlightShuffle => 'シャッフル';

  @override
  String get pageHomeSpotlightEmpty => '再生できる曲がありません';

  @override
  String pageHomeGreeting({required Object greeting, required Object name}) {
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
  String downloadSelectedCount({required Object count}) {
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
  String downloadActiveCount({required Object count}) {
    return '進行中 $count';
  }

  @override
  String downloadDoneCount({required Object count}) {
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
  String downloadDeleteSelectedTitle({required Object count}) {
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
  String downloadStatusRunning({
    required Object percent,
    required Object received,
    required Object speed,
  }) {
    return 'ダウンロード中 $percent%（$received）$speed';
  }

  @override
  String downloadStatusRunningNoPercent({required Object speed}) {
    return 'ダウンロード中…$speed';
  }

  @override
  String downloadStatusPausedWith({required Object received}) {
    return '一時停止中（$received）';
  }

  @override
  String get downloadStatusPaused => '一時停止中';

  @override
  String downloadStatusFailed({required Object error}) {
    return '失敗：$error';
  }

  @override
  String get downloadStatusCanceled => 'キャンセル済み';

  @override
  String downloadStatusDone({required Object size}) {
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
  String get settingsLyricsSubtitle => 'プレーヤー／バー歌詞・スタイル・ソース';

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
  String get settingsSearchHint => '設定を検索…';

  @override
  String settingsSearchNoResult({required Object query}) {
    return '「$query」に関連する設定は見つかりませんでした';
  }

  @override
  String settingsSearchMatchCount({required Object count}) {
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
  String get settingsAccentDefaultTooltip => 'デフォルトのグレー';

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
  String settingsCoverRadiusPx({required Object radius}) {
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
  String get settingsOutputDevice => '出力デバイス';

  @override
  String get settingsOutputDeviceSectionNote =>
      '指定したオーディオデバイスへ再生出力します。切り替えは即時／次の曲から有効（再起動不要）で、選択は保存されます。明示的に選んだ場合のみ切り替え、自動で切り替わることはありません。';

  @override
  String get settingsOutputDeviceDefault => 'システム既定';

  @override
  String get settingsOutputDeviceDefaultDesc => 'システムの現在の出力に従う（自動切替はしない）';

  @override
  String settingsOutputDeviceFormat({
    required Object channels,
    required Object rate,
  }) {
    return '$rate Hz · $channels ch';
  }

  @override
  String get settingsOutputDeviceDefaultTag => '既定';

  @override
  String get settingsOutputDeviceLoadFailed =>
      'オーディオ出力デバイスを列挙できません（エンジンが利用不可？システム既定のままにします）。';

  @override
  String get settingsOutputDeviceHfpNote =>
      'このデバイスは現在低品質モードです（Bluetooth ハンズフリー/通話 HFP など、多くは 16kHz モノラル）。エンジンはデバイスのネイティブ形式で出力するため、音質が制限されます。';

  @override
  String get settingsOutputDeviceA2dpGuideTitle =>
      'Bluetooth A2DP（高音質オーディオ）を有効にする方法';

  @override
  String get settingsOutputDeviceA2dpGuideDesc =>
      '1. Bluetooth ヘッドセットを切断して再接続します。\n2. システムの Bluetooth 設定でデバイスを「オーディオ/A2DP」（一部のシステムでは「メディアオーディオ」）に切り替えます。\n3. それでも Headset/ハンズフリーのままなら、ペアリングを解除して再ペアリングしてください。\n正確なメニューはシステムによって異なります。';

  @override
  String get settingsOutputDeviceCallBadge => '通話・低品質';

  @override
  String get settingsOutputDeviceCallConfirmTitle => '通話品質のデバイスで音楽を再生しますか？';

  @override
  String get settingsOutputDeviceCallConfirmDesc =>
      'このデバイスは通話・低品質グレードで出力され、音楽はほぼ台無しになります（音声通話並みの音質）。多くのヘッドフォンはこのモードで音楽を再生せず、一部の機器は意図的に非対応で、無音になったり異常な動作をしたりすることがあります。A2DP など高品質出力への切り替えを強く推奨します。アプリが自動で切り替えることはありません——明示的に選んだ場合のみ適用されます。';

  @override
  String get settingsOutputDeviceUseQuality => '高品質出力に切り替え';

  @override
  String get settingsOutputDeviceUseCall => 'このまま使用';

  @override
  String get settingsOutputDeviceDefaultIsCall =>
      'システム既定の出力が通話・低品質デバイスです（例: ハンズフリー HFP）。音楽は通話品質でほぼ台無しになり、一部のヘッドフォンは意図的に非対応で無音・異常になることもあります。高品質出力への切り替えを推奨します。';

  @override
  String get settingsOutputDeviceDefaultRowCallNote =>
      'これを選ぶと音楽はシステム既定の通話・低品質デバイスへ流れ、音質がほぼ損なわれます。非推奨です。';

  @override
  String settingsOutputDeviceShowAll({required int count}) {
    return 'すべてのデバイスを表示（$count）';
  }

  @override
  String get settingsOutputDeviceHideUnused => '使用可能なもののみ表示';

  @override
  String get settingsOutputDeviceUnavailable => '利用不可';

  @override
  String get settingsOutputDeviceVirtualTag => '仮想デバイス';

  @override
  String settingsSinkChangedFailed({required Object err}) {
    return '出力デバイスの切り替えに失敗しました：$err';
  }

  @override
  String get settingsEngine => 'デコードエンジン';

  @override
  String get settingsEngineNote =>
      'デコードエンジンはアプリ起動時に読み込まれるため、変更はコールド再起動後に反映されます。';

  @override
  String get settingsEngineStableDesc => 'FFmpeg デコードカーネル。実績があり既定です。';

  @override
  String get settingsEngineEraAudioDesc =>
      '自社開発のデコードカーネル。新しく、性能・メモリはベンチマーク中です。';

  @override
  String get settingsEngineExperimental => '実験的';

  @override
  String get settingsEngineEraAudioNote =>
      '実験的カーネル：性能とメモリ使用量はまだベンチマーク中で、一部のフォーマット・端末で問題が起きる可能性があります。問題があればこの設定から Stable に戻せます。';

  @override
  String get settingsEngineRestartTitle => '再起動が必要です';

  @override
  String get settingsEngineRestartDesc =>
      'エンジン設定は保存されました。エンジンは起動時に読み込まれるため、切り替えには再起動が必要です。それまで現在のエンジンが動作し続け、再起動中は再生・ダウンロードが中断されます。';

  @override
  String get settingsEngineRestartNow => '今すぐ再起動';

  @override
  String get settingsEngineRestartLater => '後で';

  @override
  String get settingsMemoryPlaySection => '再生メモリ';

  @override
  String get settingsMemoryPlayTitle => 'メモリ再生（ディスクへデコードキャッシュを書き込まない）';

  @override
  String get settingsMemoryPlayOn =>
      'デコードしたPCMをメモリに常駐。stream.wav/stream.pcmは書き込みません';

  @override
  String get settingsMemoryPlayOff => 'ファイルモード：デコードしたPCMをディスクへ書き込み（旧動作）';

  @override
  String get settingsMemoryFileModeNote =>
      'オフ = エンジンがstream.wav/stream.pcmを書き込み（ファイルモード）。次曲から有効。';

  @override
  String get settingsMemoryPolicyAuto => '自動（空きメモリに応じて調整）';

  @override
  String get settingsMemoryPolicyAutoSub => '32 MiBのハード上限。空きRAMに応じて自動調整';

  @override
  String get settingsMemoryPolicyLimit => 'カスタム上限';

  @override
  String get settingsMemoryPolicyUnlimited => '無制限';

  @override
  String get settingsMemoryPolicyUnlimitedSub =>
      '楽曲全体のデコードをメモリに常駐。選択時に明示的な確認が必要';

  @override
  String get settingsMemoryLimitTitle => 'デコードPCMのメモリ上限';

  @override
  String get settingsMemoryLimitHint => 'MB（48kHzステレオ ≈ 0.38 MB/秒）';

  @override
  String get settingsMemoryConfirm => '確定';

  @override
  String get settingsMemoryCancel => 'キャンセル';

  @override
  String get settingsMemoryUnlimitedWarnTitle => 'デコードしたPCMをすべてメモリに常駐させますか？';

  @override
  String get settingsMemoryUnlimitedWarnBody =>
      '長い楽曲では数百MB～数GBのRAMを消費する可能性があります（48kHzステレオで≈0.38 MB/秒）。マシン全体が遅くなったり、メモリ不足でOSにアプリを終了させられたり、最悪の場合はシステムが不安定になる恐れがあります。続行しますか？';

  @override
  String get memoryAlertTitle => 'メモリ不足 · 純メモリ再生は利用できません';

  @override
  String get memoryAlertActionStop => '停止';

  @override
  String get memoryAlertActionOnlineDirect => 'オンライン直結で再生';

  @override
  String get memoryAlertOnlineDesc =>
      '続行するとオンライン直結（エンジンのネットワーク）で再生します。それ以外の場合は今回の再生を停止します。';

  @override
  String get memorySourceFailNotHttp => 'オンラインソースがhttp(s)の直リンクではありません';

  @override
  String memorySourceFailIsolateSpawn({required Object error}) {
    return 'メモリソースのワーカー起動に失敗：$error';
  }

  @override
  String memorySourceFailHttpStatus({
    required Object code,
    required Object status,
  }) {
    return 'HTTP $code $status';
  }

  @override
  String memorySourceFailOverWholeCeiling({
    required Object content,
    required Object limit,
  }) {
    return '楽曲全体の内容 $content が純メモリでの楽曲全体上限 $limit を超えています';
  }

  @override
  String memorySourceFailGrewCeiling({
    required Object got,
    required Object limit,
  }) {
    return 'ダウンロード途中で純メモリの楽曲全体上限を超えました（$got > $limit）';
  }

  @override
  String get memorySourceFailEmpty => '内容が空です（0バイト）';

  @override
  String get memorySourceFailSegOom => 'メモリソースの確保に失敗（メモリ不足）';

  @override
  String get memorySourceFailSegFill => 'メモリソースへの書き込みに失敗';

  @override
  String memorySourceFailSegFillEx({required Object error}) {
    return 'メモリソースへの書き込みで例外：$error';
  }

  @override
  String memorySourceFailDownload({required Object error}) {
    return 'ダウンロードに失敗：$error';
  }

  @override
  String get memorySourceFailUnknown => '不明な理由';

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
  String settingsSpectrumBarWidthDesc({required Object width}) {
    return '${width}px（1~12、フルスクリーンプレーヤー）';
  }

  @override
  String get settingsBarSpectrum => 'プレイバーのスペクトラム';

  @override
  String get settingsSpectrumStyle => 'スペクトルスタイル';

  @override
  String get settingsSpectrumStyleDesc => 'スペクトル可視化効果（バー / 波形 / 上向き波形）';

  @override
  String get settingsSpectrumStyleBars => 'バー';

  @override
  String get settingsSpectrumStyleWave => '波形';

  @override
  String get settingsSpectrumStyleWaveUp => '上向き波形';

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
  String get settingsPlayerBackground => 'プレイヤー背景';

  @override
  String get settingsPlayerBackgroundDesc => '全画面プレイヤーの背景スタイル';

  @override
  String get settingsPlayerBgGradient => 'グラデーション';

  @override
  String get settingsPlayerBgBlur => 'ぼかし';

  @override
  String get settingsPlayerBgSolid => '単色';

  @override
  String get settingsPlayerBgRipple => '水面の波紋';

  @override
  String get settingsPlayerBgRippleSpeed => '波紋の速度';

  @override
  String settingsPlayerBgRippleSpeedDesc({required Object speed}) {
    return '流れる速さ $speed';
  }

  @override
  String get settingsPlayerBgFluid => '流体';

  @override
  String get settingsPlayerBgFlowSpeed => '流れる速さ';

  @override
  String settingsPlayerBgFlowSpeedDesc({required Object speed}) {
    return '流体の速さ $speed';
  }

  @override
  String get settingsPlayerBgRenderScale => 'レンダリング解像度';

  @override
  String settingsPlayerBgRenderScaleDesc({required Object scale}) {
    return '解像度 $scale×（低いほど省電力）';
  }

  @override
  String get settingsPlayerBgFps => 'フレームレート上限';

  @override
  String settingsPlayerBgFpsDesc({required Object fps}) {
    return '$fps FPS';
  }

  @override
  String get settingsPlayerBgFreezeOnPause => '一時停止時に停止';

  @override
  String get settingsPlayerBgFreezeOnPauseOn => '一時停止中は背景を静止';

  @override
  String get settingsPlayerBgFreezeOnPauseOff => '一時停止中も背景が流れ続ける';

  @override
  String get settingsPlayerBgBeat => '低音ビートで脈動';

  @override
  String get settingsPlayerBgBeatOn => '低音に合わせて背景が脈動';

  @override
  String get settingsPlayerBgBeatOff => 'ビートで脈動しない';

  @override
  String get settingsAdaptiveRenderQuality => '適応レンダリング品質';

  @override
  String get settingsAdaptiveRenderQualityOn => 'フレームが遅いときにプレイヤー背景の解像度を下げる';

  @override
  String get settingsAdaptiveRenderQualityOff => 'プレイヤー背景は常にフル解像度で描画';

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
  String settingsLyricFontSizeDesc({required Object size}) {
    return '${size}px（現在行は拡大ハイライト）';
  }

  @override
  String get settingsLyricPlayedColor => '再生済み色';

  @override
  String get settingsLyricPlayedColorDesc => '現在の歌詞行のハイライト色';

  @override
  String get settingsLyricFollowAccent => 'アクセントカラーに追従';

  @override
  String get settingsLyricFollowAccentDesc => '現在の行のハイライトにアプリのアクセントカラーを使用';

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
  String get settingsDjEnhanced => '拡張フィルタ';

  @override
  String get settingsDjEnhancedDesc =>
      '基本キーワード（DJ / 抖音 / 0.8 / 0.9 …）に加え、Remix / Nightcore / 速度変更 / メドレー などもスキップ';

  @override
  String get settingsDjCustom => 'カスタム除外キーワード';

  @override
  String get settingsDjCustomHint => 'カンマまたは改行区切り（例：カバー, カラオケ）';

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
  String get settingsUnloadAllMemory => '最小化時に全メモリ状態を解放';

  @override
  String get settingsUnloadAllMemorySubtitle =>
      'バックグラウンド（最小化/トレイ/画面オフ）でページデータとキャッシュを破棄し、復帰時に再構築（ホームに戻る/スクロール位置が失われる場合あり）。再生には影響なし';

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
  String settingsDownloadQualityDesc({required Object quality}) {
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
  String settingsDownloadConcurrentDesc({required Object count}) {
    return '$count 個の並列タスク（1~5）';
  }

  @override
  String get settingsDownloadGrouping => 'フォルダグループ化';

  @override
  String get settingsGroupingFlat => 'すべてダウンロードフォルダにフラットに配置';

  @override
  String get settingsGroupingPlatform => 'プラットフォーム別サブフォルダ（KG / NT）';

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
  String settingsSpeedLimited({required Object speed}) {
    return '$speed に制限、即座に有効';
  }

  @override
  String get settingsSpeedUnlimitedLabel => '無制限';

  @override
  String settingsSpeedMbps({required Object speed}) {
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
  String settingsDownloadHistoryDesc({required Object count}) {
    return '$count 件（10~500）· 上限超過で古いものから自動削除';
  }

  @override
  String settingsDownloadHistoryCount({required Object count}) {
    return '$count エントリ';
  }

  @override
  String get settingsDownloadHistoryNote =>
      '失敗 / キャンセル記録のみ古いものから削除；進行中のタスクは影響を受けません。';

  @override
  String get settingsGroupingNote =>
      'アーティスト別グループ化 v2 対応（フラット / プラットフォーム別 / アーティスト別）。';

  @override
  String get settingsSectionFingerprint => 'デバイスフィンガープリント';

  @override
  String get settingsFingerprintNote =>
      'KG / NTのダウンロード要求に付与されるデバイス識別子。初回起動時に生成され固定、ユーザーごとに異なります。';

  @override
  String get settingsDownloadDynamicFingerprint => '動的デバイスフィンガープリント';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      '起動のたびにデバイス識別子をランダム生成します（旧動作）。プラットフォームのリスク管理を誘発する可能性があり、既定ではオフです。';

  @override
  String get settingsResetFingerprint => 'デバイスフィンガープリントをリセット';

  @override
  String get settingsResetFingerprintDesc =>
      'リセット後、この端末はKG / NTから新しいデバイスと見なされます。古いフィンガープリントのオンライン状態は無効になる可能性があります。リセットしますか？';

  @override
  String get toastFingerprintReset => 'デバイスフィンガープリントをリセットしました';

  @override
  String get toastDownloadRootEmpty => 'ダウンロードフォルダは空にできません';

  @override
  String get toastDownloadRootUpdated => 'ダウンロードフォルダを更新しました';

  @override
  String get toastTemplateEmpty => 'ファイル名テンプレートは空にできません';

  @override
  String get toastTemplateUpdated => 'ファイル名テンプレートを更新しました';

  @override
  String settingsSpeedBs({required Object n}) {
    return '$n B/s';
  }

  @override
  String settingsSpeedKbs({required Object n}) {
    return '$n KB/s';
  }

  @override
  String settingsSpeedMbs({required Object n}) {
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
  String get settingsHistoryDb => '再生履歴データベース';

  @override
  String get settingsHistoryDbLabel => '履歴データベースのパス';

  @override
  String get settingsHistorySection => '再生履歴';

  @override
  String get settingsHistoryNote =>
      '再生履歴は独自の history.db（ライブラリと分離）に保存されます。記録をオフにしても既存の履歴は保持されます。無制限にするとディスクを占有し、履歴ページの読み込みが遅くなる可能性があります。';

  @override
  String get settingsHistoryEnabled => '再生履歴を記録';

  @override
  String get settingsHistoryEnabledOn => '記録中 — 再生成功後に書き込み';

  @override
  String get settingsHistoryEnabledOff => '記録停止 — 既存の履歴は保持';

  @override
  String get settingsHistoryLimit => '履歴の上限件数';

  @override
  String settingsHistoryLimitOn({required Object count}) {
    return '最大 $count 件';
  }

  @override
  String get settingsHistoryLimitUnlimited => '無制限';

  @override
  String get settingsHistoryNoLimitConfirmTitle => '上限を解除しますか？';

  @override
  String get settingsHistoryNoLimitConfirmDesc =>
      '無制限の場合、再生履歴が際限なく増え、ディスク容量を占有し、履歴ページの読み込みやアプリの応答が遅くなる可能性があります。それでも解除しますか？';

  @override
  String get settingsHistoryNoLimitConfirm => '無制限のままにする';

  @override
  String get settingsHistoryStats => '履歴データ';

  @override
  String get settingsCopy => 'コピー';

  @override
  String toastCopied({required Object label}) {
    return '$label をコピーしました';
  }

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
  String get settingsCacheLimitLyric => '歌詞キャッシュ上限';

  @override
  String get settingsCacheLimitCover => 'カバー画像キャッシュ上限';

  @override
  String get settingsCacheLimitUnlimited => '無制限';

  @override
  String get settingsCacheNoLimitConfirmTitle => 'キャッシュ上限を解除しますか？';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      '上限なしの場合、歌詞とカバー画像のキャッシュがメモリを無制限に占有し、メモリ不足や動作が重くなる可能性があります。上限を解除しますか？';

  @override
  String get settingsCacheNoLimitConfirm => '上限を解除';

  @override
  String get settingsSongCache => '曲キャッシュ';

  @override
  String get settingsSongCacheNote =>
      '再生したオンライン曲をローカルディスクにキャッシュし、再再生時は直接読み込みます（通信量削減・高速化・オフライン再生）。上限超過時は LRU で最も古い曲から自動的に削除。下限 16 MiB は 320kbps 高音質の曲 1 曲（約 2.4 MiB/分）を丸ごとキャッシュ可能な値です。削除後は自動再構築され、ライブラリ・履歴・アカウントには影響しません。';

  @override
  String get settingsSongCacheOn => 'オン：キャッシュヒット時はローカルファイルを直接再生';

  @override
  String get settingsSongCacheOff => 'オフ：メディアキャッシュはローカルに保存されません';

  @override
  String get settingsSongCacheLimitTitle => 'キャッシュ上限';

  @override
  String settingsCacheSongs({required Object count}) {
    return '$count 曲';
  }

  @override
  String get settingsSearchSongCacheSubtitle => 'オンライン曲ディスクキャッシュの有効/無効と MiB 上限';

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
  String settingsCacheEntries({required Object count}) {
    return '$count 件';
  }

  @override
  String settingsCacheImages({required Object count}) {
    return '$count 枚';
  }

  @override
  String get settingsCacheRefresh => '更新';

  @override
  String get settingsCacheClear => '削除';

  @override
  String get settingsCacheClearAll => 'すべて削除';

  @override
  String settingsCacheClearConfirmTitle({required Object name}) {
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
  String toastCacheCleared({required Object name}) {
    return '$nameのキャッシュを削除しました';
  }

  @override
  String get toastCacheAllCleared => 'すべてのキャッシュを削除しました';

  @override
  String get settingsLogToFile => 'ログをファイルに書き込む';

  @override
  String get settingsLogToFileOn => 'ログは logs/ フォルダーに書き込まれます';

  @override
  String get settingsLogToFileOff => 'コンソールのみ。ディスクには書き込みません';

  @override
  String get settingsLogToFileNote => '単一ファイル、上限 4 MiB（その場で切り詰め。追加ファイルは作りません）。';

  @override
  String get settingsSecuritySection => '安全な破棄';

  @override
  String get settingsSecurityNote =>
      '本機の全アカウント資格情報とログインセッション（ストリーミングサーバーのパスワード、網易雲/KGのログイン状態、ローカル Subsonic アカウント）を不可逆に削除し、プラットフォームのトークンを無効化します。ライブラリ・履歴・ダウンロードファイルには影響しません。';

  @override
  String get settingsSecurityStreaming => 'ストリーミングサーバー資格情報';

  @override
  String settingsSecurityStreamingCount({required Object count}) {
    return '$count 台のサーバー';
  }

  @override
  String get settingsSecurityStreamingDesc => 'パスワードとアクセストークン';

  @override
  String get settingsSecuritySession => 'サードパーティのセッション';

  @override
  String get settingsSecuritySessionDesc => '網易雲 / KG のログイン状態';

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
  String settingsSecurityConfirmTitle({required Object name}) {
    return '「$name」を破棄しますか？';
  }

  @override
  String get settingsSecurityConfirmAllTitle => 'すべての機密データを破棄しますか？';

  @override
  String settingsSecurityConfirmDesc({required Object word}) {
    return '関連プラットフォームのトークンを無効化し、ファイルを上書きして削除します。この操作は元に戻せません。続行するには「$word」と入力してください。';
  }

  @override
  String get settingsSecurityConfirmWord => '破棄';

  @override
  String settingsSecurityConfirmHint({required Object word}) {
    return '「$word」と入力';
  }

  @override
  String toastSecurityDestroyed({required Object name}) {
    return '破棄しました：$name';
  }

  @override
  String get toastSecurityAllDestroyed => 'すべての機密データを破棄しました';

  @override
  String toastSecurityDestroyFailed({required Object path}) {
    return '破棄に失敗しました。ファイルが残っている可能性があります：$path';
  }

  @override
  String get settingsDeviceBindPrivacyTitle => 'デバイスバインドのパスワード不要を有効にしますか？';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      '本機のデバイス識別子（Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID）を読み取ってバインドします。ローカルのみに保存し、アップロードしません。注意：この操作は現在の OS パスワード不要モードに戻せません。後でデバイスバインドを無効にするとパスワードモード（毎回起動時に入力）に移行します。';

  @override
  String get settingsDeviceBindEnable => '有効にする';

  @override
  String get settingsDeviceBindRecoveryTitle => '復旧パスワードを設定（任意）';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      'デバイス変更・再インストール後は復旧パスワードで認証情報をロック解除します。空欄の場合は設定しません：デバイス変更後は復旧不可（fail-closed、破棄して再構築が必要）。';

  @override
  String get settingsDeviceBindRecoveryHint => '復旧パスワード';

  @override
  String get settingsDeviceBindSkip => 'パスワードを設定せず有効化';

  @override
  String get settingsDeviceBindChangeRecovery => '復旧パスワードの設定・変更';

  @override
  String get settingsDeviceBindChangeRecoveryTitle => '新しい復旧パスワードを設定';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      '変更後、古いパスワードは直ちに無効になります。新しいパスワードを必ず覚えておいてください：デバイス変更・再インストール後のロック解除はこれに依存します。';

  @override
  String get settingsDeviceBindRebind => '現在のデバイスを再バインド';

  @override
  String get settingsDeviceBindRebindDesc =>
      '現在のデバイスフィンガープリントで再封印します。古いフィンガープリントは直ちに無効（復旧後に使用）';

  @override
  String get settingsDeviceBindRebindTitle => '現在のデバイスを再バインドしますか？';

  @override
  String get settingsDeviceBindRebindConfirm => '今すぐ再バインド';

  @override
  String get settingsDeviceBindClose => 'デバイスバインドを無効にする';

  @override
  String get settingsDeviceBindCloseDesc => 'デバイスエントロピー封印を解除し、vault はパスワードモードへ';

  @override
  String get settingsDeviceBindCloseTitle => 'デバイスバインドを無効にしますか？';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      'デバイスエントロピー封印を削除し、vault はパスワードモードに移行：以降、毎セッションでパスワード入力が必要です。そのパスワードが新しいセッションパスワードになります。現在の復旧パスワードを入力して確認してください。';

  @override
  String get settingsDeviceBindCloseHint => '現在の復旧パスワード';

  @override
  String get settingsDeviceBindRecoveryBanner =>
      'デバイスの変更またはエントロピーファイルの破損を検出：認証情報はロックされており、復旧パスワードが必要です';

  @override
  String get settingsDeviceBindRecover => '復旧';

  @override
  String get settingsDeviceBindRecoverTitle => '復旧パスワードを入力';

  @override
  String get settingsDeviceBindRecoverDesc =>
      '復旧パスワードで認証情報をロック解除します。成功後は現在のデバイスを再バインドしてパスワード不要に戻すことをお勧めします。';

  @override
  String get settingsDeviceBindShowPassword => 'パスワードの表示・非表示';

  @override
  String get toastDeviceBindEnabled => 'デバイスバインドのパスワード不要を有効にしました';

  @override
  String get toastDeviceBindRecoverySet => '復旧パスワードを更新しました';

  @override
  String get toastDeviceBindRebound => '現在のデバイスを再バインドしました';

  @override
  String get toastDeviceBindClosed => 'デバイスバインドを無効にしました。vault はパスワードモードです';

  @override
  String get toastDeviceBindRecoveryNeeded => '復旧パスワード未設定のため、デバイスバインドを無効にできません';

  @override
  String toastDeviceBindCloseFailed({required Object error}) {
    return '無効化に失敗しました：$error';
  }

  @override
  String get toastDeviceBindRecovered => '認証情報を復旧しました。再バインドでパスワード不要に戻せます';

  @override
  String get toastDeviceBindRecoverFailed =>
      '復旧パスワードの誤りまたはロック解除失敗。認証情報はロックのままです';

  @override
  String get settingsSchemeIntroTitle => '暗号化スキームの説明';

  @override
  String get settingsSchemeIntroDesc =>
      'ログイン認証情報（クッキー）は暗号化スキームで保護されます。LEGACY スキーム（推奨）を有効にしました：マスターキーは OS のセキュアストレージに保存され、安定・信頼性が高いです。より高い安全性が必要な場合は「設定 → 認証情報の暗号化スキーム」で Vault（実験的）に切り替えられます。なお、切り替え時はデータベースが再構築され、すべてのログイン認証情報が失われます。';

  @override
  String get settingsSchemeIntroGotIt => '了解しました';

  @override
  String get settingsSchemeSection => '認証情報の暗号化スキーム';

  @override
  String get settingsSchemeNote =>
      'ログイン認証情報の暗号化スキームを選択します。LEGACY：OS のセキュアストレージで暗号化、安定・信頼性が高い（推奨）。FILK（ファイルキー）：マスターキーをローカルの secret.key に保存、OS キーチェーン不要（単一障害点）。Vault：2-of-2 双因子の実験的スキームで安全性は高いが、クッキーが失われるリスクがあります。スキームの切り替え時はデータベースを再構築し、再ログインが必要です。';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => '推奨';

  @override
  String get settingsSchemeCryptoDesc =>
      'クッキーは OS のセキュアストレージで暗号化されます（Windows DPAPI / macOS キーチェーン / Linux libsecret）。安定・信頼性が高いです。';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'LEGACY スキーム：マスターキー全体を OS のセキュアストレージが保護します。暗号強度と可用性のバランスが良く、日常利用に適しています。';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => '互換';

  @override
  String get settingsSchemeFileDesc =>
      'マスターキーをローカルの secret.key ファイル（0600）に保存。OS キーチェーン不要で、ヘッドレス Linux / Docker 向け。ローカルファイル単一障害点：キーファイルが漏れるとすべての認証情報が露出します。';

  @override
  String get settingsSchemeFileModeDesc =>
      'FILK（ファイルキー）方式：マスターキーを secret.key（0600 原子書き込み）に保存。古典的なサーバー側暗号化の形態。OS キーチェーンが無い環境（headless/Docker）でのみ使用してください。';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => '実験的';

  @override
  String get settingsSchemeVaultDesc =>
      '2-of-2 双因子暗号化（システムシェア＋ユーザーシェアが両方必要）。オフライン攻撃への耐性が高い一方、異常時にクッキーが失われる可能性があります。';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Vault スキーム：マスターキーをシステムシェアとユーザーシェアに分割、双因子が両方必要。封印レベルとして v1 システム保護 / v2 パスワード保護 / v3 デバイスバインドを選択できます。';

  @override
  String get settingsSchemeSwitchTitle => '暗号化スキームを切り替えますか？';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault は実験的スキームです：切り替え後、クッキーが失われるリスクがあります。';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'FILK は互換性フォールバックです：マスターキーはローカルファイルに保存され、漏洩するとすべての認証情報が露出します。OS キーチェーンが無いヘッドレス/Docker 環境専用です。';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      '各スキームは暗号化データ構造が互換でないため、切り替え時は既存の vault を破棄してデータベースを再構築します。すべてのログイン認証情報（NT / KG / ストリーミングアカウント）が失われ、再ログインが必要です。';

  @override
  String get settingsSchemeSwitchKeep => '現在のまま';

  @override
  String get settingsSchemeSwitchConfirm => '切り替えて再構築';

  @override
  String get toastSchemeSwitched => '暗号化スキームを切り替えました。再起動後に有効になります';

  @override
  String get settingsVaultModeV1 => 'v1 システム保護';

  @override
  String get settingsVaultModeV2 => 'v2 パスワード保護';

  @override
  String get settingsVaultModeV3 => 'v3 デバイスバインド';

  @override
  String get settingsVaultModeDescOs =>
      'v1 システム保護：認証情報は OS のセキュアストレージで暗号化（Windows DPAPI / macOS キーチェーン / Linux libsecret）。本機ではパスワード不要。';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 パスワード保護：認証情報はパスワードで暗号化され、起動のたびに入力が必要。いつでも v1 システム保護に戻せます。';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 デバイスバインド：本機ではパスワード不要。デバイス変更時は復旧パスワードが必要。v1 へ直接降格できません——無効化すると v2 パスワードモードに戻ります。';

  @override
  String get settingsVaultModeDescUnknown => '暗号化レベルを読み込み中…';

  @override
  String get settingsVaultSwitchToPasswordTitle => 'パスワード保護（v2）に切り替え';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      '認証情報はパスワードで暗号化され、起動のたびに入力が必要になります。マスターキーと既存データは保持され、いつでもシステム保護（v1）に戻せます。';

  @override
  String get settingsVaultSwitchToPasswordNewHint => '新しいパスワードを設定';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint => '新しいパスワードを再入力';

  @override
  String get settingsVaultSwitchToPasswordMismatch => '2 回の入力が一致しません';

  @override
  String get settingsVaultSwitchToOsTitle => 'システム保護（v1）に戻す';

  @override
  String get settingsVaultSwitchToOsDesc =>
      '認証情報は OS のセキュアストレージで保護され、パスワード入力は不要になります。いつでもパスワード保護（v2）に戻せます。';

  @override
  String get settingsVaultNeedUnlockFirst =>
      '現在パスワード保護がロック解除されていません：先にロック解除してから切り替えてください';

  @override
  String get settingsVaultV3NoDirectV1 =>
      'デバイスバインド（v3）は v1 へ直接降格できません：先にデバイスバインドを無効化し、v2 パスワードモードに戻してください';

  @override
  String get settingsVaultCloseV3PasswordTitle => 'デバイスバインドを無効化：新しいパスワードを設定';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      'デバイスバインド有効時に復旧パスワード未設定（本機パスワード不要）の場合、無効化するとパスワード保護（v2）に移行します：新しいロック解除パスワードを設定してください。マスターキーと既存データは保持され、このパスワードは起動のたびに入力が必要です。';

  @override
  String get toastVaultSwitchedToPassword => 'パスワード保護（v2）に切り替えました';

  @override
  String get toastVaultSwitchedToOs => 'システム保護（v1）に戻しました';

  @override
  String get settingsVaultShareBrokenBanner =>
      'vault のシェアが不整合です：ストレージバックエンドの不一致またはシェアの欠落。ローカルの認証情報を復号できません。vault を再構築して再ログインしてください。';

  @override
  String get settingsVaultShareBrokenRebuild => 'vault を再構築';

  @override
  String get settingsVaultRestartTitle => 'アプリの再起動が必要';

  @override
  String get settingsVaultRestartDesc =>
      '暗号化レベルを切り替えました。データベースの整合性と各モジュールの状態を揃えるため、再起動してください。パスワード保護モード（v2）の場合、再起動後にパスワード入力が必要です。ロック解除前はログイン状態とストリーミング認証情報が利用不可（未ログイン表示）です。再起動中は再生・ダウンロードが中断されます。';

  @override
  String get settingsVaultRestartNow => '今すぐ再起動';

  @override
  String get settingsVaultRestartLater => '後で再起動';

  @override
  String get vaultCrashTitle => '認証情報モジュールが異常終了';

  @override
  String get vaultCrashDesc =>
      '認証情報 vault プロセスが予期せず終了しました。ローカルの認証情報が露出した可能性があります。再ログインするか、vault を破棄して認証情報を再構築してください。';

  @override
  String get vaultCrashReset => '破棄して再構築';

  @override
  String get vaultCrashDismiss => '了解';

  @override
  String get vaultVersionTitle => '認証情報 vault のバージョン異常';

  @override
  String get vaultVersionDesc =>
      '認証情報 vault コンポーネントに異常を検出しました：バイナリのコピーが差し替えられた、または非公式ビルドの可能性があり、ローカルの認証情報が露出した可能性があります。異常なコピーを削除し、復号を拒否しました。アプリを終了して再インストールしてください。';

  @override
  String get vaultVersionExit => '終了';

  @override
  String get vaultVersionReasonReplaced =>
      'vault バイナリの差し替えまたは非公式ビルドを検出しました。異常なコピーを削除し、復号を拒否しました。';

  @override
  String get vaultVersionReasonMarkerMissing =>
      'vault のハンドシェイク応答に公式ビルドマーカーがありません。';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'vault のビルドマーカーが公式成果物と一致しません。異常なコピーを削除し、復号を拒否しました。';

  @override
  String get vaultUnlockTitle => '認証情報 vault をロック解除';

  @override
  String get vaultUnlockDesc =>
      '認証情報 vault はパスワード保護モード（v2）です。ローカルのログイン認証情報とストリーミングアカウントをロック解除するにはパスワードを入力してください。';

  @override
  String get vaultUnlockHint => 'パスワード';

  @override
  String get vaultUnlockConfirm => 'ロック解除';

  @override
  String get vaultUnlockSkip => 'あとでロック解除';

  @override
  String get vaultUnlockFailed => 'パスワードが正しくありません。再試行してください';

  @override
  String get settingsVersion => 'バージョン';

  @override
  String get settingsVersionUnknown => 'v 不明 · Flutter デスクトップ';

  @override
  String settingsVersionFormat({required Object version}) {
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
  String get settingsNeverTap => '絶対に押さないで';

  @override
  String get easterEggGateTitle => '警告';

  @override
  String get easterEggGateBody =>
      'このプログラムを実行しますか？取り返しのつかない結果になった場合、ソフトウェアを終了することを選択できます。';

  @override
  String get settingsWeirdEffects => '奇妙なエフェクト';

  @override
  String get settingsWeirdEffectsOn => '逆再生いたずら中——「降参します」で元に戻せます';

  @override
  String get settingsWeirdEffectsOff =>
      'エイプリルフール当日のみ表示。一度有効にすると次のエイプリルフールまで消えます';

  @override
  String get aprilFoolsSurrender => '降参します 🙌';

  @override
  String get aprilFoolsSurrenderToast => 'エイプリルフールおめでとう！すべて元に戻りました。';

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
  String get settingsDeclineLicenseTitle => '2. オープンソースライセンスとソースコード\n';

  @override
  String get settingsDeclineLicenseBody =>
      '本ソフトウェアは GNU Affero 一般公衆利用許諾契約書第 3 版（AGPL-3.0）に基づいて公開されています。このライセンスの範囲内で、本ソフトウェアを自由に実行・研究・改変・再配布できますが、以下の条件を遵守する必要があります：著作権およびライセンス表示を保持すること；派生作品を同一ライセンスで公開すること；本ソフトウェア（改変版を含む）の機能をネットワーク経由で利用者に提供する場合、その利用者に対応する完全なソースコードを提供すること。本プロジェクトは AGPL の義務を回避するクローズドソースの商用ライセンスを提供しません。完全な条件は添付の LICENSE ファイルおよび https://www.gnu.org/licenses/agpl-3.0.html に準拠します。\n\n';

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
  String get settingsDeclineLoginTitle => '5. ログインとアカウント\n';

  @override
  String get settingsDeclineLoginBody =>
      '本ソフトウェアは、QR コードログイン（各音楽プラットフォームの公式アプリで本ソフトウェアが表示する QR コードをスキャン）と認証情報によるログインを提供し、お気に入りやプレイリストの同期、および機能の解放を行います。ご注意ください：\n· QR コードは該当プラットフォームの公式インターフェースが生成するもので、本ソフトウェアはログイン用 QR コード、アカウント、パスワード、SMS 認証コードを収集・解析・第三者への送信を行いません；\n· ログイン成功後に取得されるセッション資格情報（Cookie / トークン等）は本機にのみ保存され（資格情報保管庫で暗号化）、開発者やプラットフォーム以外のサーバーへアップロードされることはありません；\n· QR ログインは、お客様のアカウントで本ソフトウェアが該当プラットフォームへアクセスすることを許可することを意味し、お気に入り登録・再生・コメント等の操作は実際にお客様のアカウントに反映されます；\n· 端末とシステムアカウントを適切に管理し、公共または共用の端末でログインした後は速やかにログアウトし資格情報を削除してください；\n· プラットフォームはサードパーティクライアントのログインに対してリスク管理・制限・凍結を行う場合があり、それにより生じるアカウント異常や機能制限のリスクはお客様が負担します。\n\n';

  @override
  String get settingsDeclineThirdPartyTitle => '7. サードパーティサービスとリスク\n';

  @override
  String get settingsDeclineThirdPartyBody =>
      'オンライン音楽プラットフォームのインターフェース、認証方式、可用性はプラットフォーム側が単独で決定し、いつでも変更・制限・停止される可能性があり、ログイン失効、機能利用不可、データ同期不能を引き起こすことがあります；本ソフトウェアは現状のまま提供され、サードパーティサービスの継続的な可用性、安定性、データ完全性について一切保証しません。\n\n';

  @override
  String get settingsDeclineMinorTitle => '8. 未成年者の利用\n';

  @override
  String get settingsDeclineMinorBody =>
      '本ソフトウェアは汎用ツールであり、未成年者向けに設計されておらず、未成年者から個人情報を収集しません。未成年者の方は、保護者の同伴と指導のもとで本声明をお読みいただき、保護者の同意を得たうえで本ソフトウェアをご利用ください；また、利用時間を適切に管理し、過度な利用を避けてください。\n\n';

  @override
  String get settingsDecline5Title => '8. 免責事項\n';

  @override
  String get settingsDecline5Body =>
      'このソフトウェアは「現状のまま」提供され、明示または黙示のいかなる保証も行いません。本ソフトウェアの使用または使用不能、あるいはオンラインプラットフォームのインターフェース変更、アカウント制限、ログイン資格情報の失効、アカウントのリスク管理・凍結、機能不全等により生じたいかなる直接的または間接的損失も、利用者が負担するものとします。\n\n';

  @override
  String get settingsDeclineFooter => 'このソフトウェアは技術的な探求と研究のみを目的としています。';

  @override
  String get settingsDeclarationEntryDesc =>
      'ソフトウェアの性質、オープンソースライセンス、利用制限および免責事項';

  @override
  String get settingsSectionLegal => '法的情報と声明';

  @override
  String get settingsLegalIntro => 'ご利用前にお読みください：';

  @override
  String get settingsSectionPrivacy => 'プライバシーポリシー';

  @override
  String get settingsPrivacyEntryDesc => 'お客様の情報の取り扱いと保護について';

  @override
  String get settingsPrivacyIntro =>
      'ArchoeraMusic（以下「本ソフトウェア」または「当方」）へようこそ。当方は、お客様の個人情報の重要性を十分に認識し、お客様のプライバシーとデータの安全保護に常に努めています。本ポリシーでは、本ソフトウェアの利用過程において、当方がお客様の情報をどのように取り扱い、保存し、保護するか、およびお客様が享有する関連する権利について説明します。\n\n本ポリシーを必ずよくお読みいただき、十分にご理解ください。本ソフトウェアの利用を開始された時点で、お客様は本ポリシーに記載されたすべての内容を読み、理解し、同意されたものとみなします。\n\n';

  @override
  String get settingsPrivacy1Title => '1. 基本原則\n';

  @override
  String get settingsPrivacy1Body =>
      '1. 最小限の必要性：基本機能の提供、安全の確保および体験の改善に必要なデータのみを処理し、サービスと無関係な個人の機微情報は収集しません。\n2. ローカル優先：お客様のライブラリメタデータ、再生履歴および環境設定は既定で本機に保存され、お客様ご自身が完全に管理できます。\n3. 透明で制御可能：本ソフトウェアには広告、トラッキング、ユーザープロファイリングは含まれず、データの取り扱いは公開・透明で、いつでもお客様が削除できます。\n\n';

  @override
  String get settingsPrivacy2Title => '2. 当方が処理する情報\n';

  @override
  String get settingsPrivacy2Body =>
      '· お客様が自ら提供する情報：第三者音楽プラットフォームのアカウント資格情報（QR ログインで取得した Cookie / トークン、アカウントとパスワードなど）、自前またはアクセス権のある Subsonic 等のメディアサーバーのアドレスとアカウント、お客様が選択したローカル音楽ディレクトリなど。資格情報は本機の「資格情報保管庫」で暗号化して保存され（v1 システム安全ストレージ / v2 パスフレーズ保護 / v3 デバイスバインド）、開発者やプラットフォーム以外のサーバーへアップロードされることはありません。\n· ローカルの実行・キャッシュデータ：ライブラリメタデータ（曲名、アーティスト、アルバムなど）、再生履歴、お気に入り、ダウンロード記録、歌詞とカバーのキャッシュ、インターフェース言語やテーマなどの環境設定。\n· ローカルの実行ログ：障害調査のため、ソフトウェアは本機で実行ログを生成します（単一ファイル上限 4 MiB、超過時はその場で切り詰め）。ログは本機にのみ保存され、お客様が自ら抽出して開発者に提供しない限り、自動的にアップロードされることはありません。\n\n';

  @override
  String get settingsPrivacy3Title => '3. 情報の利用目的\n';

  @override
  String get settingsPrivacy3Body =>
      '当方は、上記の情報を以下の目的に限って処理します：音楽のデコード、再生、歌詞表示、コントロール画面などの基本機能を提供すること；ソフトウェアの再起動後にお客様の個別設定を復元すること；ソフトウェアがお客様のデバイス上で安全かつ安定して動作することを確保すること。当方はお客様のデータを広告配信、ユーザープロファイリング、商業マーケティングに利用することは決してなく、いかなる第三者へ販売または貸与することも決してありません。\n\n';

  @override
  String get settingsPrivacy4Title => '4. 第三者サービス\n';

  @override
  String get settingsPrivacy4Body =>
      '· オンライン音楽プラットフォームと実験的音源：お客様がログインまたは関連機能を利用する際、リクエストはお客様のデバイスから該当プラットフォームへ直接送信され（またはその公開 HTTP インターフェースを介して相互運用され）、関連データの取り扱いは当該プラットフォーム自身の利用規約とプライバシーポリシーにも従います。\n· 自前または個人のメディアサーバー：Subsonic 等のサーバーとの通信は、お客様のクライアントとサーバーとの間で直接行われ、サーバー側のデータ安全とプライバシー保護はお客様および当該サーバーの運営者が自ら負担します。\n· 本ソフトウェアは、第三者サービスの継続的な可用性、安定性またはデータの取り扱い方法について一切保証しません。\n\n';

  @override
  String get settingsPrivacy5Title => '5. 保存、保存期間および安全保護\n';

  @override
  String get settingsPrivacy5Body =>
      'お客様のデータの大部分は、お客様が自ら削除するまで、本機のデータディレクトリ（Linux：~/.local/share/ArchoeraMusic；macOS：~/Library/Application Support/ArchoeraMusic；Windows：%LOCALAPPDATA%\\ArchoeraMusic、環境変数 ARCHOERA_DATA_DIR で上書き可能）に保存されます。機微な資格情報は、オペレーティングシステムのネイティブな安全ストレージによる暗号化を優先し、資格情報保管庫内で隔離して保管します；ネットワーク伝送を伴う部分は、宛先が対応している場合に HTTPS / TLS を優先して使用します。\n当方は合理的な安全対策を講じていますが、コンピューターおよびストレージ技術の固有の限界により、100% 絶対的な安全を保証できるシステムは存在しません。お客様のデバイスと第三者アカウントの資格情報を適切に保管してください。\n\n';

  @override
  String get settingsPrivacy6Title => '6. お客様の権利とデータ管理\n';

  @override
  String get settingsPrivacy6Body =>
      'お客様は、設定で環境設定、ストリーミングサーバー情報、ログイン状態をいつでも確認・変更できます；「ストレージ / セキュリティ / 履歴」でキャッシュ、履歴、指定データを消去できます；設定で本機のデータディレクトリを確認して自ら削除するか、アンインストール後に手動でそのディレクトリを整理することで、本ソフトウェアが本機に残したすべてのデータを永久に破棄できます。ご注意：実行ファイルをアンインストールしても、データディレクトリが自動的に削除されるとは限りません。\n\n';

  @override
  String get settingsPrivacy7Title => '7. 未成年者のプライバシー保護\n';

  @override
  String get settingsPrivacy7Body =>
      '本ソフトウェアは汎用ツールであり、未成年者からいかなる個人情報も収集しません。未成年者の方は、保護者の同伴と指導のもとで本ポリシーをお読みいただき、保護者の同意を得たうえで本ソフトウェアをご利用ください。\n\n';

  @override
  String get settingsPrivacy8Title => '8. プライバシーポリシーの更新\n';

  @override
  String get settingsPrivacy8Body =>
      '当方は、機能の反復、技術アーキテクチャの進化または法令の変更に応じて、本ポリシーを適宜改訂することがあります。更新後のバージョンはソフトウェアまたは公式リポジトリとともに公開され、冒頭に記載された「最終更新」日から効力を生じます；更新後も本ソフトウェアを引き続きご利用になる場合、お客様は更新後のポリシーを読み、理解し、同意したものとみなします。\n\n';

  @override
  String get settingsPrivacy9Title => '9. お問い合わせ\n';

  @override
  String get settingsPrivacy9Body =>
      '本ポリシーの内容、お客様の情報セキュリティまたは関連事項についてご不明な点、ご意見、お申し立てがある場合は、以下の方法で開発者までご連絡ください：\n· GitHub リポジトリと Issue：https://github.com/BetaStudio2/ArchoeraMusic\nフィードバックを受領後、できるだけ早く回答いたします。\n\n';

  @override
  String get settingsPrivacyFooter => '本ポリシーの最終更新：2026 年 9 月 29 日。';

  @override
  String get settingsSectionEnvInfo => '環境情報';

  @override
  String get settingsEnvVersion => 'バージョン';

  @override
  String get settingsEnvPlatform => 'プラットフォーム';

  @override
  String get settingsEnvRuntime => 'ランタイム';

  @override
  String get settingsSectionCommunity => 'コミュニティ';

  @override
  String get settingsCommunityRepo => 'GitHub リポジトリ';

  @override
  String get settingsSectionThanks => '特別な謝辞';

  @override
  String get settingsThanksDesign => '設計の参考';

  @override
  String get settingsThanksCore => '主要コンポーネント';

  @override
  String get settingsThanksDecoder => 'デコーダ参考';

  @override
  String get settingsThanksIcons => 'アイコン';

  @override
  String get settingsSectionFontCredits => 'フォントクレジット';

  @override
  String get settingsFontCreditsEntryDesc => '同梱フォントとライセンス情報を表示';

  @override
  String get settingsFontCreditsText =>
      '本ソフトウェアには以下のフォントが同梱されています。\n· MiSans（© Xiaomi、MiSans フォント知的財産権許諾契約に基づき使用）\n· Manrope（© The Manrope Project Authors、SIL Open Font License 1.1）\n· EtaIcons（自作アイコンフォント、字形は MingCute / Tabler / Lucide 由来）\n· EtaMark（自作ブランドマークフォント）\n\n以下に各フォント・字形の公式ライセンス全文を掲載します。';

  @override
  String get commonNoLyrics => '歌詞がありません';

  @override
  String commonTrackCount({required Object count}) {
    return '$count曲';
  }

  @override
  String get settingsSearchColorTitle => '再生済み / 未再生色';

  @override
  String get settingsSearchColorSubtitle => '現在行のハイライトと通常行の色';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => 'ファイル名テンプレート';

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
  String settingsBackgroundBlurDesc({required Object blur}) {
    return '背景画像にガウスぼかしを適用（${blur}px）';
  }

  @override
  String get settingsBackgroundDim => 'マスク濃度';

  @override
  String settingsBackgroundDimDesc({required Object dim}) {
    return '黒のオーバーレイ透明度（$dim%）— 高いほど前景が読みやすく';
  }

  @override
  String get settingsBackgroundScale => 'ズームサイズ';

  @override
  String settingsBackgroundScaleDesc({required Object scale}) {
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
  String get settingsSearchFontSubtitle => 'MiSans';

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
      'プライバシー：天気データは Open-Meteo（無料・キー不要）。自動位置情報を有効にすると IP を ipwho.is に送信し大まかな位置を得ます。天気取得のみに使用し保存しません。ウィジェットと位置情報は初期状態でオフです。';

  @override
  String get settingsWeatherPrivacyTitle => '天気ウィジェットを有効にしますか？';

  @override
  String get settingsWeatherPrivacyBody =>
      '有効にすると、第三者気象サービス Open-Meteo にリクエストを送信します。手動都市モードでは入力した都市名のみが送信され、その他の個人情報は送信されません。';

  @override
  String get settingsWeatherPrivacyEnable => '有効にする';

  @override
  String get settingsWeatherAutoLocateTitle => '自動位置情報を有効にしますか？';

  @override
  String get settingsWeatherAutoLocateBody =>
      '自動位置情報は ipwho.is を使い、ネットワークの出口 IP からおおよその位置を取得し、その座標を Open-Meteo に送信して天気を取得します。お住まいの都市などおおよその位置が判明する可能性があります。手動で都市を入力することもできます。';

  @override
  String get settingsWeatherLocateSource => '位置情報の取得方法';

  @override
  String get settingsWeatherLocateSourceDesc =>
      'システム位置情報が利用可能なら優先（より正確）；失敗時は IP に自動フォールバック';

  @override
  String get settingsWeatherLocateSourceIp => 'IP 位置情報';

  @override
  String get settingsWeatherLocateSourceSystem => 'システム';

  @override
  String get settingsWeatherLocateSystemTitle => 'システム位置情報に切り替えますか？';

  @override
  String get settingsWeatherLocateSystemBody =>
      'システム位置情報は OS の位置情報サービス（Windows Location / Linux GeoClue）を利用し、より正確な位置を取得します（天気の確認のみに使用）。システムが許可を求めます。利用できない場合は IP に自動フォールバックします。';

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
  String get repeatModeList => 'リストリピート';

  @override
  String get repeatModeOne => '1曲リピート';

  @override
  String get repeatModeOff => '順番に再生';

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
  String settingsScrapeDirsNote({required Object dirs}) {
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
  String get settingsScrapeSourceKugou => 'KG音楽';

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
  String settingsScrapeCurrent({required Object file}) {
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
  String get streamingQualityTitle => 'ストリーミング音質';

  @override
  String get streamingQualityNote =>
      '原本を優先。トランスコード段はサーバーに汎用 MP3 への変換を要求します（サーバー対応が必要、標準パラメータで他サーバーと互換）。';

  @override
  String get streamingQualityOriginal => '原本';

  @override
  String get streamingQualityHigh => '高 (320k)';

  @override
  String get streamingQualityMedium => '中 (192k)';

  @override
  String get streamingQualityLow => '低 (128k)';

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
  String streamingToastConnected({required Object name}) {
    return '$name に接続しました';
  }

  @override
  String get streamingServerConnectFailed => '接続に失敗しました';

  @override
  String get streamingServerEdit => '編集';

  @override
  String get streamingServerDeleteConfirmTitle => 'サーバーを削除';

  @override
  String streamingServerDeleteConfirm({required Object name}) {
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
  String streamingTotalSongs({required Object count}) {
    return '$count 曲';
  }

  @override
  String streamingTotalAlbums({required Object count}) {
    return '$count 枚のアルバム';
  }

  @override
  String streamingTotalArtists({required Object count}) {
    return '$count 人のアーティスト';
  }

  @override
  String streamingTotalPlaylists({required Object count}) {
    return '$count 個のプレイリスト';
  }

  @override
  String get streamingEmptyNoResults => '一致する結果がありません';

  @override
  String streamingAlbumSongs({required Object count}) {
    return '$count 曲';
  }

  @override
  String streamingArtistAlbums({required Object count}) {
    return '$count 枚のアルバム';
  }

  @override
  String streamingPlaylistSongs({required Object count}) {
    return '$count 曲';
  }

  @override
  String get brandQqMusic => 'QM';

  @override
  String get platformQQMusic => 'QM';

  @override
  String get loginQqQrLogin => 'QQ ミュージック QR コードでログイン';

  @override
  String get loginQqScanHint => 'QQ アプリでスキャンしてログインしてください';

  @override
  String navHeaderQqId({required String id}) {
    return 'QQ $id';
  }

  @override
  String searchSourceFailed({required Object source}) {
    return '$source の検索は一時的に利用できません';
  }

  @override
  String searchQqRiskDetail({required Object code}) {
    return 'QM がアクセスを制限・遮断しました（コード $code）。自動再試行は停止しました。しばらくしてから再試行してください';
  }

  @override
  String get searchNetworkError => 'ネットワークエラーまたはタイムアウトです。しばらくしてから再試行してください';

  @override
  String searchPlatformError({required Object code}) {
    return 'プラットフォームがエラーを返しました（$code）';
  }

  @override
  String get searchWaitRetry => 'リクエストが多すぎます。しばらくしてから再試行してください';

  @override
  String get settingsValueAuto => '自動';

  @override
  String get settingsSectionScrapeWrite => '書き込みオプション';

  @override
  String get settingsScrapeWriteDesc => 'スクレイプ成功後にオーディオタグへ書き込みます';

  @override
  String get settingsScrapeEmbedMetadata => 'メタデータを埋め込む';

  @override
  String get settingsScrapeEmbedCover => 'カバーアートを埋め込む';

  @override
  String get settingsScrapeEmbedLyrics => '歌詞を埋め込む';

  @override
  String get settingsScrapeSkipScraped => 'スクレイプ済みファイルをスキップ';

  @override
  String get settingsScrapeSkipScrapedDesc =>
      'MusicBrainz IDまたはISRCを持つファイルは再スクレイプしません';

  @override
  String get settingsSectionScrapeAdvanced => '詳細設定';

  @override
  String get settingsScrapeWorkers => '並列ワーカー';

  @override
  String settingsScrapeWorkersDesc({required Object value}) {
    return 'マルチソース並列検索スレッド数（0=自動、現在 $value）';
  }

  @override
  String get settingsScrapeBatch => 'バッチサイズ';

  @override
  String settingsScrapeBatchDesc({required Object value}) {
    return '1バッチあたりの処理ファイル数（現在 $value）';
  }

  @override
  String get settingsScrapeRetries => '最大リトライ回数';

  @override
  String settingsScrapeRetriesDesc({required Object value}) {
    return 'これを超えて失敗したファイルは隔離されます（現在 $value）';
  }

  @override
  String get settingsSectionScrapeOrganize => 'ディレクトリ整理のみ';

  @override
  String get settingsScrapeOrganizeNote =>
      'オフライン。テンプレートに従い、ディレクトリ内のファイルを対象ツリーへ移動します（元のファイル名と既存タグは保持）。変数：artist、albumArtist、album、genre、year、disc、track、title、ext。ディレクトリ階層は / で区切ります。対象ディレクトリ未設定時は、メディアライブラリの既定の音楽フォルダ（最初のスキャンディレクトリ）を使用します。メディアライブラリ未設定の場合は、先にスキャンディレクトリを追加してください。';

  @override
  String get settingsScrapeOrganizeTargetDir => '整理の対象ディレクトリ';

  @override
  String get settingsScrapeOrganizeTargetHint =>
      '空欄の場合はメディアライブラリの既定の音楽フォルダ（最初のスキャンディレクトリ）を使用。未設定なら先にスキャンディレクトリを追加してください';

  @override
  String get settingsScrapeOrganizePattern => '整理テンプレート';

  @override
  String get settingsScrapeOrganizePatternHint =>
      'テンプレートはディレクトリ階層のみを決定し、ファイル名は変更しません';

  @override
  String get settingsScrapeOrganizePresetArtistAlbum => 'アーティスト/アルバム';

  @override
  String get settingsScrapeOrganizePresetArtistOnly => 'アーティストのみ';

  @override
  String get settingsScrapeOrganizePresetGenreArtistAlbum => 'ジャンル/アーティスト/アルバム';

  @override
  String get settingsScrapeOrganizePresetYearArtistAlbum => '年/アーティスト/アルバム';

  @override
  String get settingsScrapeOrganizeStart => '整理を開始';

  @override
  String get settingsOrganizeRunning => 'ファイルを整理中…';

  @override
  String get settingsOrganizeMoved => '移動';

  @override
  String get settingsOrganizeSkipped => 'スキップ';

  @override
  String get settingsOrganizeFailed => '失敗';

  @override
  String settingsOrganizeDone({
    required Object failed,
    required Object moved,
    required Object skipped,
  }) {
    return '整理完了：移動 $moved、スキップ $skipped、失敗 $failed';
  }

  @override
  String get settingsOrganizeNoTarget =>
      'メディアライブラリのスキャンディレクトリが未設定のため、既定の整理先を特定できません';

  @override
  String settingsOrganizeUsingDefault({required Object dir}) {
    return '整理先が未設定のため、既定の音楽フォルダを使用します：$dir';
  }

  @override
  String get toastOrganizeNoDirs => '整理できるディレクトリがありません';

  @override
  String get toastOrganizeStarted => '整理を開始しました';

  @override
  String get settingsCatScanner => 'スキャン';

  @override
  String get settingsScannerSubtitle => 'メディアライブラリスキャナー · 並列度と安全上限 · 隔離';

  @override
  String get settingsSectionScanRun => '実行設定';

  @override
  String get settingsScanParallelism => 'スキャン並列度';

  @override
  String settingsScanParallelismDesc({required Object value}) {
    return '並列解析するファイル数（0=自動、現在 $value）';
  }

  @override
  String get settingsScanBatch => 'バッチサイズ';

  @override
  String settingsScanBatchDesc({required Object value}) {
    return 'DBの一括書き込み上限（0=自動、現在 $value）';
  }

  @override
  String get settingsScanAnalyzeLoudness => 'スキャン時にラウドネスを解析';

  @override
  String get settingsScanAnalyzeLoudnessOn =>
      'オン：各ファイルをデコードして測定（低速）；既存曲には全スキャンが必要';

  @override
  String get settingsScanAnalyzeLoudnessOff =>
      'オフ：測定しない（正規化はファイル内 ReplayGain タグのみ使用）';

  @override
  String get settingsSectionScanLimits => '安全上限';

  @override
  String get settingsScanLimitsNote => '大規模ライブラリ向けの保護上限。空欄の場合はエンジン既定値を使用';

  @override
  String get settingsScanNumberDesc => '空欄の場合はエンジン既定値を使用';

  @override
  String get settingsScanMaxFileSizeMb => '単一ファイルの最大サイズ（MB）';

  @override
  String get settingsScanMaxScanFiles => '最大スキャンファイル数';

  @override
  String get settingsScanMaxErrors => '連続エラー上限';

  @override
  String get settingsSectionScanExts => 'オーディオ拡張子';

  @override
  String get settingsScanExtraExtsNote => 'エンジン内蔵の許可リストに加えてスキャンするオーディオ拡張子';

  @override
  String get settingsScanExtraExtsHint => 'スペースまたはカンマ区切り（例：dsf m4b）';

  @override
  String get settingsSectionScanQuarantine => '破損ファイルの隔離';

  @override
  String settingsScanQuarantineNote({required Object dir}) {
    return '解析に3回以上失敗したファイルは次の場所へ移動されます：$dir';
  }

  @override
  String get settingsScanQuarantineEmpty => '隔離されたファイルはありません';

  @override
  String get settingsScanQuarantineDelete => 'このファイルを削除';

  @override
  String get settingsScanQuarantineOpenDir => 'フォルダを開く';

  @override
  String get settingsScanQuarantineClearAll => '隔離をすべて削除';

  @override
  String get settingsScanQuarantineClearAllConfirm =>
      '隔離フォルダ内のすべてのファイルを削除しますか？この操作は元に戻せません。';

  @override
  String get libraryFullScan => '全件スキャン';

  @override
  String get libraryFullScanConfirm => '全件スキャンを実行しますか？';

  @override
  String get libraryFullScanConfirmDesc =>
      'ライブラリデータベースを消去し、スキャンディレクトリから再構築します（元ファイルは保持）。元に戻せず、実行中はディスクI/Oを多く消費します。';

  @override
  String get settingsSectionLyricEngine => '歌詞エンジン';

  @override
  String get settingsLyricEngine => 'エンジン';

  @override
  String get settingsLyricEngineSimple => 'クラシック';

  @override
  String get settingsLyricEngineWall => '歌詞ウォール';

  @override
  String get settingsLyricEngineDesc => 'レンダラーを選択。いつでも切り替え可能';

  @override
  String get settingsLyricEngineNote =>
      '全画面プレーヤーの歌詞エリアにのみ適用。AMLL = Apple Music風のウォールスクロールで、やや負荷が高め。';

  @override
  String get settingsSectionLyricWall => 'ウォール設定';

  @override
  String get settingsAmllNote => 'Apple Music風ウォール歌詞のパラメータ。AMLLエンジンのみが使用します。';

  @override
  String get settingsAmllAlign => 'アクティブ行の位置';

  @override
  String get settingsAmllDim => '非アクティブ行の透明度';

  @override
  String get settingsAmllWordSweep => 'ワードスイープ';

  @override
  String get settingsAmllSyntheticSweep => '通常歌詞の合成スイープ';

  @override
  String get settingsAmllSyntheticSweepDesc =>
      '逐字タイミングの無い歌詞を行の長さから推定してスイープ（翻訳・ルビにも適用）';

  @override
  String get settingsAmllHidePassed => '歌い終わった行を隠す';

  @override
  String get settingsAmllScale => '非アクティブ行を縮小';

  @override
  String get settingsAmllBlur => '非アクティブ行をぼかす';

  @override
  String get settingsAmllBlurNote =>
      '自動はフレームレートに合わせて調整します（まず 1 レイヤーでぼかし、重ければ自動でオフ）。';

  @override
  String get settingsAmllBlurAuto => '自動';

  @override
  String get settingsAmllBlurFast => '軽量';

  @override
  String get settingsAmllBlurLite => '軽量（近似）';

  @override
  String get settingsAmllBlurQuality => '高画質';

  @override
  String get settingsAmllBlurOff => 'オフ';

  @override
  String get settingsAmllSpring => 'スクロールのバネ';

  @override
  String get toastSleepInhibitFailed => 'システムのスリープ防止に失敗しました';

  @override
  String get toastMediaSessionLost => 'システムメディアセッションが切断されました';

  @override
  String get instanceAlreadyRunning => 'システムトレイまたはタスクバーで実行中のウィンドウを探してください。';

  @override
  String get instanceAlreadyRunningTitle => 'ArchoeraMusic は既に起動しています';

  @override
  String get settingsCatShortcuts => 'ショートカット';

  @override
  String get settingsShortcutsSubtitle => 'キー割り当てをカスタマイズ';

  @override
  String get shortcutNote =>
      '割り当てをクリックして新しいショートカットを記録します。ダイアログでキーの組み合わせを押してください。';

  @override
  String get shortcutResetAll => 'すべてリセット';

  @override
  String get shortcutUnbound => '未割り当て';

  @override
  String get shortcutHintEdit => 'クリックして編集';

  @override
  String get shortcutConflict => '他の操作と競合しています';

  @override
  String get shortcutCaptureTitle => 'ショートカットを記録';

  @override
  String get shortcutPressKeys => 'キーを押してください…';

  @override
  String get shortcutCategoryPlayback => '再生';

  @override
  String get shortcutCategorySeek => 'シーク';

  @override
  String get shortcutCategoryVolume => '音量';

  @override
  String get shortcutCategoryQueue => 'キュー';

  @override
  String get shortcutCategoryNavigation => 'ナビゲーション';

  @override
  String get shortcutActionPlayPause => '再生 / 一時停止';

  @override
  String get shortcutActionPlay => '再生';

  @override
  String get shortcutActionPause => '一時停止';

  @override
  String get shortcutActionStop => '停止';

  @override
  String get shortcutActionNext => '次の曲';

  @override
  String get shortcutActionPrevious => '前の曲';

  @override
  String get shortcutActionLikeToggle => 'お気に入り切替';

  @override
  String get shortcutActionShuffleToggle => 'シャッフル切替';

  @override
  String get shortcutActionRepeatCycle => 'リピートモード切替';

  @override
  String get shortcutActionReload => '現在の曲を再読み込み';

  @override
  String get shortcutActionSeekBackward => '10秒戻る';

  @override
  String get shortcutActionSeekForward => '10秒進む';

  @override
  String get shortcutActionSeekBackwardLong => '30秒戻る';

  @override
  String get shortcutActionSeekForwardLong => '30秒進む';

  @override
  String get shortcutActionVolumeUp => '音量を上げる';

  @override
  String get shortcutActionVolumeDown => '音量を下げる';

  @override
  String get shortcutActionMuteToggle => 'ミュート切替';

  @override
  String get shortcutActionJumpToFirst => 'キューの先頭へ';

  @override
  String get shortcutActionJumpToLast => 'キューの末尾へ';

  @override
  String get shortcutActionClearQueue => 'キューを空にする';

  @override
  String get shortcutActionGoHome => 'ホームへ';

  @override
  String get shortcutActionGoLibrary => 'ライブラリへ';

  @override
  String get shortcutActionGoSearch => '検索へ';

  @override
  String get shortcutActionGoLiked => 'お気に入りへ';

  @override
  String get shortcutActionGoFavorites => 'コレクションへ';

  @override
  String get shortcutActionGoHistory => '履歴へ';

  @override
  String get shortcutActionGoDownload => 'ダウンロードへ';

  @override
  String get shortcutActionGoStreaming => 'ストリーミングへ';

  @override
  String get shortcutActionOpenPlayer => 'プレイヤーを開く';

  @override
  String get shortcutActionOpenSettings => '設定を開く';

  @override
  String get shortcutActionBack => '戻る';

  @override
  String get commonReset => 'Reset';

  @override
  String get settingsDevDownloadModuleOn => 'Download module enabled';

  @override
  String get settingsDevDownloadModuleOff => 'Download module disabled';

  @override
  String get settingsDevDownloadWarningTitle => 'Enable download module?';

  @override
  String get settingsDevDownloadWarningBody =>
      'The download module is intended for local debugging and personal use. It may involve copyright and terms-of-service risks with third-party platforms. Use at your own discretion.';

  @override
  String get settingsDevDownloadWarningAgree => 'I understand, enable';

  @override
  String get settingsSidebarCustomize => 'Customize sidebar';

  @override
  String get settingsSidebarCustomizeDesc =>
      'Show, hide and reorder sidebar items';

  @override
  String get settingsSidebarCustomizeTitle => 'Customize sidebar';

  @override
  String get settingsSidebarCustomizeHint =>
      'Drag to reorder; use the switch to show or hide';

  @override
  String get settingsShowProgressTooltip => 'Progress hover tooltip';

  @override
  String get settingsShowProgressTooltipDesc =>
      'Show the time under the cursor when hovering the progress bar';

  @override
  String get settingsShowProgressLyric => 'Show lyric on progress bar';

  @override
  String get settingsShowProgressLyricDesc =>
      'Show the current lyric above the progress bar in the full player';

  @override
  String get settingsSnapToLyric => 'Snap to lyric';

  @override
  String get settingsSnapToLyricDesc =>
      'Snap to the nearest lyric line when releasing the progress bar';

  @override
  String get settingsTimeFormat => 'Time format';

  @override
  String get settingsTimeFormatDesc => 'How playback time is displayed';

  @override
  String get settingsTimeFormatCurrentTotal => 'Elapsed / total';

  @override
  String get settingsTimeFormatRemainingTotal => 'Remaining / total';

  @override
  String get settingsTimeFormatCurrentRemaining => 'Elapsed / remaining';

  @override
  String get settingsShowPlaybackSource => 'Show playback source';

  @override
  String get settingsShowPlaybackSourceDesc =>
      'Show the source platform of the current track in the player bar';

  @override
  String get settingsCoverLayout => 'Cover layout';

  @override
  String get settingsCoverLayoutDesc =>
      'How the cover is presented in the full player';

  @override
  String get settingsCoverLayoutDefault => 'Default';

  @override
  String get settingsCoverLayoutFullscreen => 'Fullscreen cover';

  @override
  String get settingsCoverLyricRatio => 'Cover / lyrics ratio';

  @override
  String get settingsCoverLyricRatioDesc =>
      'Width ratio of the cover and lyrics areas';

  @override
  String get settingsAutoCenterCover => 'Auto-center cover';

  @override
  String get settingsAutoCenterCoverDesc =>
      'Center the cover and hide lyrics when there are no lyrics';

  @override
  String get settingsFollowCoverColor => 'Follow cover color';

  @override
  String get settingsFollowCoverColorDesc =>
      'Lyric colors follow the dominant color of the current cover';

  @override
  String get settingsLyricSourceOrder => 'Lyric source order';

  @override
  String get settingsLyricSourceOrderDesc =>
      'Fall back to other platforms in this order when the current platform has no lyrics';

  @override
  String get settingsLyricFormatOrder => 'Lyric format order';

  @override
  String get settingsLyricFormatOrderDesc =>
      'Preferred lyric formats (word-by-word / standard)';

  @override
  String get settingsLyricOrderHint =>
      'Drag to reorder; higher position means higher priority';

  @override
  String get settingsLyricOrderReset => 'Reset';

  @override
  String get settingsSectionLyricExclude => 'Lyric exclusion rules';

  @override
  String get settingsLyricExcludeEnabled => 'Enable lyric exclusion';

  @override
  String get settingsLyricExcludeEnabledOn =>
      'Matching lyric lines are excluded';

  @override
  String get settingsLyricExcludeEnabledOff => 'No lines are excluded when off';

  @override
  String get settingsLyricExcludeRules => 'Exclusion rules';

  @override
  String get settingsLyricExcludeRulesDesc =>
      'Exclude lyric lines matching keywords or regular expressions';

  @override
  String get settingsLyricExcludeDialogTitle => 'Lyric exclusion rules';

  @override
  String get settingsLyricExcludeDialogHint =>
      'Matching lines will be hidden; keywords are case-insensitive';

  @override
  String get settingsLyricExcludeTabKeywords => 'Keywords';

  @override
  String get settingsLyricExcludeTabRegex => 'Regex';

  @override
  String get settingsLyricExcludeKeywordHint =>
      'Exclude any line containing this keyword';

  @override
  String get settingsLyricExcludeRegexHint =>
      'Regular expressions supported (Dart RegExp syntax)';

  @override
  String get settingsLyricExcludePlaceholder =>
      'Type and press enter, or click add';

  @override
  String get settingsLyricExcludeAdd => 'Add';

  @override
  String get settingsLyricExcludeEmpty => 'No rules yet';

  @override
  String get settingsLyricExcludeInvalidRegex => 'Invalid regular expression';

  @override
  String get settingsLyricExcludeDuplicate => 'Rule already exists';

  @override
  String get settingsLyricExcludeClear => 'Clear';

  @override
  String get settingsLyricTtml => 'オンライン TTML 歌詞（Beta）';

  @override
  String get settingsLyricTtmlDesc =>
      'AMLL DB から単語ごとの TTML 歌詞を取得し、ヒット時はプラットフォームの歌詞を上書きします（ネット接続が必要）。この機能はテスト中です。';

  @override
  String get settingsLyricTtmlEnable => 'オンライン TTML 歌詞を有効化';

  @override
  String get settingsLyricTtmlEnableDesc => 'AMLL DB に一致する歌詞があれば優先的に使用';

  @override
  String get settingsLyricTtmlServer => 'AMLL DB サーバー';

  @override
  String get settingsLyricTtmlServerDialogTitle => 'AMLL DB サーバーテンプレート';

  @override
  String get settingsLyricTtmlServerHint =>
      'テンプレートには %p（プラットフォーム）と %s（曲 ID）の両方が必要です';

  @override
  String get settingsLyricTtmlServerInvalid =>
      'テンプレートには %p と %s の両方を含める必要があります';

  @override
  String get commonConfigure => 'Configure';

  @override
  String get settingsShowRomanization => 'Show romanization';

  @override
  String get settingsShowRomanizationOn =>
      'On: show romanization below the current line';

  @override
  String get settingsShowRomanizationOff => 'Off: hide romanization';

  @override
  String get settingsLyricAdaptiveFontSize => 'Adaptive font size';

  @override
  String get settingsLyricAdaptiveFontSizeOn => 'On: scales with the window';

  @override
  String get settingsLyricAdaptiveFontSizeOff => 'Off: fixed font size';

  @override
  String get settingsLyricFontWeight => 'Lyric font weight';

  @override
  String get settingsLyricFontWeightDesc => 'Weight of the active lyric line';

  @override
  String get settingsLyricWeightRegular => 'Regular';

  @override
  String get settingsLyricWeightMedium => 'Medium';

  @override
  String get settingsLyricWeightSemiBold => 'Semibold';

  @override
  String get settingsLyricWeightBold => 'Bold';

  @override
  String get sleepTimer => 'Sleep timer';

  @override
  String get sleepTimerOff => 'Off';

  @override
  String get sleepTimerEndOfTrack => 'End of current track';

  @override
  String get sleepTimerFired => 'Sleep timer reached; playback paused';

  @override
  String get sleepTimerFinishTrack => 'Finish current track before pausing';

  @override
  String get sleepTimerWaitingTrackEnd =>
      'Sleep timer reached; will pause after the current track';

  @override
  String sleepTimerMinutes({required int minutes}) {
    return '$minutes 分';
  }

  @override
  String get sleepTimerMinutesUnit => '分';

  @override
  String get sleepTimerCustom => 'カスタム…';

  @override
  String get sleepTimerCustomTitle => 'カスタムスリープタイマー';

  @override
  String get sleepTimerCustomLabel => '分';

  @override
  String get sleepTimerCustomInvalid => '1〜600 分の整数を入力してください';

  @override
  String get sleepTimerPresets => 'スリープタイマーのプリセット';

  @override
  String get sleepTimerPresetsDesc =>
      'スリープタイマーメニューに表示するクイック時間。追加・削除でき、空にすると「カスタム / 現在の曲を最後まで / オフ」のみ表示します。';

  @override
  String get sleepTimerPresetsAdd => '追加';

  @override
  String get sleepTimerPresetsEmpty => 'プリセットなし';

  @override
  String get sleepTimerPresetsDuplicate => 'その時間は既にプリセットにあります';

  @override
  String get sleepTimerPresetsEdit => '編集';

  @override
  String get settingsSectionSleepTimer => 'スリープタイマー';

  @override
  String get settingsReverseSpectrum => 'Reverse spectrum';

  @override
  String get settingsReverseSpectrumDesc => 'Flip the spectrum horizontally';

  @override
  String get settingsAutoImmersive => 'Auto immersive';

  @override
  String get settingsAutoImmersiveDesc =>
      'Hide the top and bottom bars when the pointer leaves or is idle';

  @override
  String get settingsMediaSession => 'System media session';

  @override
  String get settingsMediaSessionDesc =>
      'Sync with system media controls (media keys / Bluetooth)';

  @override
  String get settingsCrossfade => 'Fade in on track change';

  @override
  String get settingsCrossfadeDesc =>
      'Ramp volume from 0 on new tracks to avoid hard starts';

  @override
  String get settingsCrossfadeDuration => 'Fade-in duration';

  @override
  String get settingsSectionExperience => 'Playback experience';

  @override
  String get settingsCatAudioEffects => 'Audio effects';

  @override
  String get settingsAudioEffectsSubtitle => 'Equalizer · loudness · speed';

  @override
  String get settingsSectionEqualizer => 'Equalizer';

  @override
  String get settingsEqEnabled => 'Enable equalizer';

  @override
  String get settingsEqEnabledOn => 'Enabled';

  @override
  String get settingsEqEnabledOff => 'Disabled';

  @override
  String get settingsEqPreset => 'Equalizer preset';

  @override
  String get settingsEqPreamp => 'Preamp';

  @override
  String get settingsEqLimiter => 'Limiter';

  @override
  String get settingsEqLimiterDesc => 'Prevent clipping distortion';

  @override
  String get settingsEqReset => 'Reset equalizer';

  @override
  String get settingsEqPresetFlat => 'Flat';

  @override
  String get settingsEqPresetPop => 'Pop';

  @override
  String get settingsEqPresetRock => 'Rock';

  @override
  String get settingsEqPresetJazz => 'Jazz';

  @override
  String get settingsEqPresetClassical => 'Classical';

  @override
  String get settingsEqPresetVocal => 'Vocal';

  @override
  String get settingsEqPresetBass => 'Bass boost';

  @override
  String get settingsEqPresetCustom => 'Custom';

  @override
  String get settingsSectionNormalization => 'Loudness normalization';

  @override
  String get settingsNormalization => 'Loudness normalization';

  @override
  String get settingsNormalizationDesc =>
      'Adjust volume so tracks have consistent loudness';

  @override
  String get settingsNormalizationOn => 'On';

  @override
  String get settingsNormalizationOff => 'Off';

  @override
  String get settingsNormalizationMode => 'ReplayGain モード';

  @override
  String get settingsNormalizationModeDesc =>
      'ReplayGain タグがある場合の適用基準（オフライン解析はトラック単位）';

  @override
  String get settingsNormalizationModeTrack => 'トラック';

  @override
  String get settingsNormalizationModeAlbum => 'アルバム';

  @override
  String get settingsSectionSpeed => 'Playback speed';

  @override
  String get settingsPlaybackSpeed => 'Playback speed';

  @override
  String get settingsPlaybackSpeedDesc => 'Time-stretch without changing pitch';

  @override
  String get settingsPlaybackSpeedNormal => 'Normal speed';

  @override
  String get settingsSectionPitch => 'ピッチ';

  @override
  String get settingsPitch => 'ピッチシフト';

  @override
  String get settingsPitchDesc => '再生速度を変えずにピッチを変更';

  @override
  String get settingsPitchNormal => '原音のピッチ';

  @override
  String get settingsPitchUnit => '半音';

  @override
  String get settingsSectionSystem => 'System integration';

  @override
  String get settingsRegisterProtocol => 'Register archoera:// protocol';

  @override
  String get settingsRegisterProtocolDesc =>
      'Allow browsers and other apps to wake this app via archoera:// links';

  @override
  String get settingsRegisterProtocolOn => 'Registered';

  @override
  String get settingsRegisterProtocolOff => 'Not registered';

  @override
  String get settingsRegisterProtocolUnavailable =>
      'Not supported on this platform';

  @override
  String get settingsRegisterProtocolFailed => 'Failed to register protocol';

  @override
  String get settingsCatMcp => 'MCP 連携';

  @override
  String get settingsMcpSubtitle => 'ローカル MCP 制御インターフェース（既定で無効）';

  @override
  String get settingsMcpTitle => 'MCP 制御サービス';

  @override
  String get settingsMcpNote =>
      'ループバック アドレス 127.0.0.1 のみで待ち受け、管理者権限は不要です。すべての機能は既定で無効で、グループ単位で有効化します。メインスイッチを切ると待ち受けを停止します。';

  @override
  String get settingsMcpEnable => 'MCP 制御を有効化';

  @override
  String get settingsMcpEnableOn => '有効・ポートで待ち受け中';

  @override
  String get settingsMcpEnableOff => '既定で無効';

  @override
  String get settingsMcpPort => '待ち受けポート';

  @override
  String get settingsMcpPortDesc => '1024〜65535。変更すると待ち受けを再起動します';

  @override
  String get settingsMcpKey => 'アクセスキー';

  @override
  String get settingsMcpKeyCopy => 'コピー';

  @override
  String get settingsMcpKeyRegenerate => 'キーを再生成';

  @override
  String get settingsMcpKeyCopied => 'アクセスキーをコピーしました';

  @override
  String get settingsMcpKeyRegenerated => 'アクセスキーを再生成しました';

  @override
  String get settingsMcpAllowKeyless => 'キーなしアクセスを許可';

  @override
  String get settingsMcpAllowKeylessDesc =>
      'オフの方が安全です。オンにすると本機の任意のプログラムが直接アクセスできます';

  @override
  String get settingsMcpCapsTitle => '機能';

  @override
  String get settingsMcpCapsNote =>
      '各グループは独立です。無効な機能は MCP ツール一覧や REST ルートに表示されません。';

  @override
  String get settingsMcpCapRead => '状態の読み取り';

  @override
  String get settingsMcpCapReadDesc => '再生状態・現在の曲・キュー・サービス情報・音源一覧';

  @override
  String get settingsMcpCapPlayback => '再生制御';

  @override
  String get settingsMcpCapPlaybackDesc =>
      '再生/一時停止/停止・次/前・シーク・音量・リピート/シャッフル・音質・曲の再生';

  @override
  String get settingsMcpCapQueue => 'キュー操作';

  @override
  String get settingsMcpCapQueueDesc => '項目の追加/削除/移動・指定項目の再生・キューのクリア';

  @override
  String get settingsMcpCapSearch => 'オンライン検索';

  @override
  String get settingsMcpCapSearchDesc => 'NetEase/KuGou/QQ Music などで曲を検索';

  @override
  String get settingsMcpCapLibrary => 'ローカルライブラリ';

  @override
  String get settingsMcpCapLibraryDesc => 'ローカルライブラリの検索・ランダム抽出・統計';

  @override
  String get settingsMcpCapPreferences => '設定の読み取り';

  @override
  String get settingsMcpCapPreferencesDesc => 'アプリ設定を読み取り専用で返す（機密項目は除外）';

  @override
  String get settingsMcpEndpointsTitle => '接続先アドレス';

  @override
  String settingsMcpStatusRunning({required int port}) {
    return '実行中 · ポート $port';
  }

  @override
  String get settingsMcpStatusStopped => '停止中';

  @override
  String get settingsMcpStatusError => '起動に失敗（ポートが使用中の可能性）';

  @override
  String get settingsMcpStatusDesc =>
      'MCP はエージェント向け、REST / WebSocket はスクリプトや他プログラム向け';

  @override
  String get settingsMcpEndpointMcp => 'MCP（Streamable HTTP）';

  @override
  String get settingsMcpEndpointRest => 'REST API';

  @override
  String get settingsMcpEndpointWs => 'WebSocket（JSON-RPC 2.0）';

  @override
  String get settingsMcpCapAppearance => '外観';

  @override
  String get settingsMcpCapAppearanceDesc => 'ライト / ダーク / システムテーマの切替';

  @override
  String get settingsMcpCapCollection => 'お気に入り';

  @override
  String get settingsMcpCapCollectionDesc => '曲のお気に入り（ハート）状態の照会と切替';

  @override
  String get settingsMcpCapHistory => '再生履歴';

  @override
  String get settingsMcpCapHistoryDesc => '再生履歴の照会と消去';

  @override
  String get settingsMcpCapLyrics => '歌詞';

  @override
  String get settingsMcpCapLyricsDesc => '現在の曲の歌詞行を読み取り専用で返す';

  @override
  String get settingsMcpCapDownload => 'ダウンロード';

  @override
  String get settingsMcpCapDownloadDesc => 'ダウンロード一覧・曲の追加・タスクのキャンセル';

  @override
  String get settingsMcpAllowLan => 'LAN アクセスを許可';

  @override
  String get settingsMcpAllowLanDesc =>
      '既定で無効。オンにすると 0.0.0.0 にバインドし、同一 LAN の他端末から接続可能（キーは依然必要）';

  @override
  String get settingsMcpAllowLanWarning =>
      '警告：LAN アクセスは攻撃面を広げます。アクセスキーを秘密に保ち、信頼できるネットワークでのみ使用してください。';

  @override
  String get settingsMcpAllowLanWarningTitle => 'LAN アクセスを有効にしますか？';

  @override
  String get settingsMcpAllowLanWarningBody =>
      '有効にすると、同じ LAN 上の他端末がこの制御サービスにアクセスできます（キーは依然必要）。信頼できるネットワークでのみ有効にし、キーを安全に保管してください。';

  @override
  String get settingsMcpAllowLanWarningAgree => '理解しました、有効にする';

  @override
  String get settingsMcpLanAddress => 'LAN アドレス';

  @override
  String get settingsMcpShell => 'コマンドライン shell';

  @override
  String get settingsMcpShellDesc =>
      '有効にするとターミナルで `<exe> archoerashell …` を使用（ウィンドウは開きません）。無効にするとサブコマンドはエラー終了します';

  @override
  String get settingsMcpShellUsage => 'コマンド例';

  @override
  String get settingsMcpShellCopy => 'コピー';

  @override
  String get settingsMcpShellCopied => 'コマンド例をコピーしました';

  @override
  String get mcpShellUsage =>
      'archoerashell — ArchoeraMusic コマンドライン制御（Unix 風）\n\n使い方:\n  archoera_music archoerashell [グローバルオプション] <コマンド> [引数...]\n\nヒント:\n  <コマンド> --help または help <コマンド> で個別の使い方を表示。\n\nグローバルオプション:\n  -h, --help            このヘルプを表示\n  -V, --version         バージョンを表示\n  -j, --json            JSON 出力（スクリプト向け）\n  -q, --quiet           エラーのみ出力\n      --host <host>     サーバーアドレス（既定 127.0.0.1）\n  -p, --port <port>     サーバーポート（既定はアプリ設定）\n  -k, --key  <key>      アクセスキー（既定はアプリ設定）\n\n再生:\n  status / now-playing / play|pause|toggle|stop|next|prev\n  seek <ms> / volume <0..1> / repeat <off|list|one> / shuffle <on|off>\n  quality <lq|sq|hq|lossless|hi-res> / play-track <ref>\n\nキュー:\n  queue [list|play <index>|add <ref>...|rm <index>|move <from> <to>|clear]\n\n検索 / ライブラリ:\n  search <source> <キーワード> [-n n] [-p page]\n  search-all <キーワード> [-n n]\n  library [キーワード] [-n n] [--offset n] / library-random / library-stats\n\nお気に入り / 履歴 / 歌詞:\n  like|unlike|like-status <ref> / list-liked <source> [-n n]\n  history [-n n] / history-clear / lyrics\n\nダウンロード:\n  download [list|add <ref>... [--quality <q>]|cancel <id>|remove <id>]\n\nその他:\n  theme <light|dark|system> / sleep <分>|--end / sleep-cancel\n  prefs [キー...] / tools / info / call <ツール> [--json <json>]\n\n例:\n  archoera_music archoerashell status\n  archoera_music archoerashell search netease 周杰倫 -n 10\n  archoera_music archoerashell play-track netease:186016\n  archoera_music archoerashell --json library 周杰倫';

  @override
  String get mcpShellHint =>
      '<コマンド> --help または help <コマンド> で個別の使い方を表示（例: archoerashell search --help）。';

  @override
  String get mcpShellUsageError => '使い方エラー';

  @override
  String get mcpShellErrorPrefix => 'エラー';

  @override
  String get mcpShellDisabled =>
      'archoerashell は設定で無効になっています（MCP 連携 → コマンドライン shell）。';

  @override
  String get mcpShellHelpStatus =>
      '使い方: archoerashell status\n\n再生状態を表示：再生/一時停止・曲・位置・音量・リピート/シャッフル。';

  @override
  String get mcpShellHelpNowPlaying =>
      '使い方: archoerashell now-playing\n\n現在の曲と位置のみ表示。';

  @override
  String get mcpShellHelpPlay => '使い方: archoerashell play\n\n再生を開始/再開。';

  @override
  String get mcpShellHelpPause => '使い方: archoerashell pause\n\n一時停止。';

  @override
  String get mcpShellHelpToggle => '使い方: archoerashell toggle\n\n再生/一時停止を切替。';

  @override
  String get mcpShellHelpStop => '使い方: archoerashell stop\n\n再生を停止。';

  @override
  String get mcpShellHelpNext => '使い方: archoerashell next\n\n次の曲へ。';

  @override
  String get mcpShellHelpPrev =>
      '使い方: archoerashell prev\n\n前の曲へ（previous と同じ）。';

  @override
  String get mcpShellHelpPrevious =>
      '使い方: archoerashell previous\n\n前の曲へ（prev と同じ）。';

  @override
  String get mcpShellHelpSeek =>
      '使い方: archoerashell seek <ms>\n\n指定位置へシーク。\n例: archoerashell seek 30000';

  @override
  String get mcpShellHelpVolume =>
      '使い方: archoerashell volume <0..1>\n\n音量を設定。\n例: archoerashell volume 0.6';

  @override
  String get mcpShellHelpRepeat =>
      '使い方: archoerashell repeat <off|list|one>\n\nリピートモードを設定。';

  @override
  String get mcpShellHelpShuffle =>
      '使い方: archoerashell shuffle <on|off>\n\nシャッフルを切替。';

  @override
  String get mcpShellHelpQuality =>
      '使い方: archoerashell quality <lq|sq|hq|lossless|hi-res>\n\n音質を切替。';

  @override
  String get mcpShellHelpPlayTrack =>
      '使い方: archoerashell play-track <ref>\n\n指定した曲を再生（ref は source:id）。\n例: archoerashell play-track netease:186016';

  @override
  String get mcpShellHelpSearch =>
      '使い方: archoerashell search <音源> <キーワード> [-n 件数] [-p ページ]\n\n指定音源で曲を検索。\n  音源: netease | kugou | qqmusic | neko\n  -n, --limit <n>   件数（1〜50、既定 20）\n  -p, --page <n>    ページ（1 から）\n例: archoerashell search netease 周杰倫 -n 10';

  @override
  String get mcpShellHelpSearchAll =>
      '使い方: archoerashell search-all <キーワード> [-n 各音源件数]\n\n有効な全音源を検索し、音源ごとにグループ表示。\n  -n, --limit <n>   音源ごとの件数（1〜30、既定 10）';

  @override
  String get mcpShellHelpQueue =>
      '使い方: archoerashell queue [サブコマンド]\n\n  queue                     キューを表示\n  queue play <index>        指定項目を再生\n  queue add <ref>...        追加（--position next|end、既定 next）\n  queue rm <index>          項目を削除\n  queue move <from> <to>    並べ替え\n  queue clear               キューを消去';

  @override
  String get mcpShellHelpLibrary =>
      '使い方: archoerashell library [キーワード] [-n 件数] [--offset n]\n\nローカルライブラリを検索。キーワード省略で全件。';

  @override
  String get mcpShellHelpLibraryRandom =>
      '使い方: archoerashell library-random [-n 件数]\n\nローカル曲をランダム抽出（既定 20）。';

  @override
  String get mcpShellHelpLibraryStats =>
      '使い方: archoerashell library-stats\n\nローカルライブラリ統計：曲数 / 合計サイズ / 合計時間。';

  @override
  String get mcpShellHelpPrefs =>
      '使い方: archoerashell prefs [キー...]\n\nアプリ設定を読み取り（読み取り専用・機密キーは除外）。キー省略で全件。';

  @override
  String get mcpShellHelpTheme =>
      '使い方: archoerashell theme <light|dark|system>\n\nテーマモードを切替。';

  @override
  String get mcpShellHelpLike =>
      '使い方: archoerashell like <ref>\n\n指定した曲をお気に入りに追加。';

  @override
  String get mcpShellHelpUnlike =>
      '使い方: archoerashell unlike <ref>\n\n指定した曲をお気に入りから削除。';

  @override
  String get mcpShellHelpLikeStatus =>
      '使い方: archoerashell like-status <ref>\n\n指定した曲のお気に入り状態を照会。';

  @override
  String get mcpShellHelpListLiked =>
      '使い方: archoerashell list-liked <音源> [-n 件数]\n\nその音源のお気に入り一覧（未ログイン時は空）。';

  @override
  String get mcpShellHelpHistory =>
      '使い方: archoerashell history [-n 件数]\n\n再生履歴（新しい順、既定 50）。';

  @override
  String get mcpShellHelpHistoryClear =>
      '使い方: archoerashell history-clear\n\n再生履歴を消去。';

  @override
  String get mcpShellHelpLyrics => '使い方: archoerashell lyrics\n\n現在の曲の歌詞行。';

  @override
  String get mcpShellHelpDownload =>
      '使い方: archoerashell download [サブコマンド]\n\n  download [list] [-n 件数]            ダウンロード一覧\n  download add <ref>... [--quality]     ダウンロードに追加\n  download cancel <taskId>              タスクをキャンセル\n  download remove <taskId>              記録を削除（ファイルは残す）';

  @override
  String get mcpShellHelpSleep =>
      '使い方: archoerashell sleep <分> | sleep --end\n\nスリープタイマー：分指定、または --end で現在の曲の後に一時停止。';

  @override
  String get mcpShellHelpSleepCancel =>
      '使い方: archoerashell sleep-cancel\n\nスリープタイマーを解除。';

  @override
  String get mcpShellHelpInfo =>
      '使い方: archoerashell info\n\nサービス情報：アプリ版・ポート・エンドポイント・有効な機能。';

  @override
  String get mcpShellHelpTools =>
      '使い方: archoerashell tools\n\n有効なツール一覧（名前 / 機能 / 説明）。';

  @override
  String get mcpShellHelpCall =>
      '使い方: archoerashell call <ツール> [--json <json>]\n\n任意の有効ツールを直接呼び出す。引数は JSON オブジェクト。';

  @override
  String mcpShellErrUnknownCommand({required String command}) {
    return '不明なコマンド: $command';
  }

  @override
  String mcpShellErrUnknownOption({required String option}) {
    return '不明なオプション: $option';
  }

  @override
  String mcpShellErrNeedValue({required String option}) {
    return 'オプション $option には値が必要です';
  }

  @override
  String mcpShellErrBadPort({required String value}) {
    return '無効なポート: $value';
  }

  @override
  String mcpShellErrConnect({
    required String host,
    required int port,
    required String reason,
  }) {
    return '$host:$port に接続できません（$reason）';
  }

  @override
  String get mcpShellErrConnectHint =>
      'アプリが起動しており、設定で MCP アクセスが有効になっているか確認してください。';

  @override
  String mcpShellErrHttp({required String message}) {
    return 'HTTP エラー: $message';
  }

  @override
  String mcpShellErrTimeout({required String host, required int port}) {
    return '接続がタイムアウトしました: $host:$port';
  }

  @override
  String get mcpShellLblPlaying => '再生中';

  @override
  String get mcpShellLblPaused => '一時停止中';

  @override
  String get mcpShellLblBuffering => 'バッファリング中';

  @override
  String get mcpShellLblVolume => '音量';

  @override
  String get mcpShellLblQuality => '音質';

  @override
  String get mcpShellLblRepeat => 'リピート';

  @override
  String get mcpShellLblShuffleOn => 'シャッフルON';

  @override
  String get mcpShellLblShuffleOff => 'シャッフルOFF';

  @override
  String get mcpShellLblNowPlaying => '再生';

  @override
  String get mcpShellLblTotal => '合計';

  @override
  String get mcpShellLblEmpty => 'なし';

  @override
  String get mcpShellLblColTitle => 'タイトル';

  @override
  String get mcpShellLblColArtist => 'アーティスト';

  @override
  String get mcpShellLblColRef => '参照';

  @override
  String get mcpShellLblColWhen => '日時';

  @override
  String get mcpShellLblSearch => '検索';

  @override
  String get mcpShellLblQuery => 'クエリ';

  @override
  String get mcpShellLblPage => 'ページ';

  @override
  String get mcpShellLblQueue => 'キュー';

  @override
  String get mcpShellLblIndex => 'インデックス';

  @override
  String get mcpShellLblLiked => 'お気に入り';

  @override
  String get mcpShellLblNotLiked => 'お気に入り未登録';

  @override
  String get mcpShellLblUnliked => 'お気に入り解除';

  @override
  String get mcpShellLblVersion => 'バージョン';

  @override
  String get mcpShellLblPlatform => 'プラットフォーム';

  @override
  String get mcpShellLblPort => 'ポート';

  @override
  String get mcpShellLblProtocol => 'プロトコル';

  @override
  String get mcpShellLblEndpoints => 'エンドポイント';

  @override
  String get mcpShellLblCaps => '機能';

  @override
  String get mcpShellLblLoopback => 'ループバック';

  @override
  String get mcpShellLblLan => 'LAN';

  @override
  String get mcpShellLblLibrary => 'ライブラリ';

  @override
  String get mcpShellLblTracks => 'トラック';

  @override
  String get mcpShellLblSize => 'サイズ';

  @override
  String get mcpShellLblDuration => '再生時間';

  @override
  String get mcpShellLblSleep => 'スリープ';

  @override
  String get mcpShellLblEndOfTrack => '再生後停止';

  @override
  String get mcpShellLblTask => 'タスク';

  @override
  String get mcpShellLblQueued => 'キュー追加済み';

  @override
  String get mcpShellLblCount => '件数';

  @override
  String get mcpShellLblTheme => 'テーマ';

  @override
  String get mcpShellLblOk => '完了';

  @override
  String get mcpShellLblToolName => '名前';

  @override
  String get mcpShellLblToolCap => '機能';

  @override
  String get mcpShellLblToolTitle => '説明';

  @override
  String get mcpShellLblLoggedIn => 'ログイン済み';

  @override
  String get mcpShellLblLoggedOut => '未ログイン';

  @override
  String get mcpShellLblRef => '参照';

  @override
  String get mcpShellLblError => 'エラー';

  @override
  String get mcpShellLblTagPlaying => '[再生中]';

  @override
  String get mcpShellLblTagPaused => '[一時停止]';
}
