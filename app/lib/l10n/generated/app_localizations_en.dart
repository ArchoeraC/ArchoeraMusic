// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsCatRender => 'Performance & Rendering';

  @override
  String get settingsRenderSubtitle =>
      'GPU acceleration and rendering cost (experimental)';

  @override
  String get settingsRippleShader => 'Ripple GPU shader';

  @override
  String get settingsRippleShaderDesc =>
      'Draw the player ripple with a fragment shader (off = CPU mesh fallback)';

  @override
  String get settingsRippleLowRes => 'Half-resolution dynamic layer';

  @override
  String get settingsRippleLowResDesc =>
      'Render the ripple dynamic layer at half resolution then upscale; CPU fallback path only';

  @override
  String get settingsRippleDamageClip => 'Damage-region clipping';

  @override
  String get settingsRippleDamageClipDesc =>
      'Redraw only active ripple bands; CPU fallback path only';

  @override
  String get menuTrackDetail => 'Media details';

  @override
  String get trackDetailDuration => 'Duration';

  @override
  String get trackDetailAlbum => 'Album';

  @override
  String get trackDetailSource => 'Source';

  @override
  String get trackDetailPath => 'Path';

  @override
  String get trackDetailFileSize => 'File size';

  @override
  String get trackDetailCodec => 'Codec';

  @override
  String get trackDetailSampleRate => 'Sample rate';

  @override
  String get trackDetailBitDepth => 'Bit depth';

  @override
  String get trackDetailBitrate => 'Bitrate';

  @override
  String get trackDetailChannels => 'Channels';

  @override
  String get trackSourceLocal => 'Local file';

  @override
  String get trackSourceStreaming => 'Streaming';

  @override
  String get trackDetailQuality => 'Quality';

  @override
  String get batchSelectAll => 'Select all';

  @override
  String get batchInvert => 'Invert selection';

  @override
  String get batchPlay => 'Play selected';

  @override
  String get batchAddQueue => 'Add to queue';

  @override
  String get batchDownload => 'Batch download';

  @override
  String get batchExit => 'Exit multi-select';

  @override
  String get batchSelectHint => 'Multi-select';

  @override
  String toastBatchAddedToQueue({required Object count}) {
    return '$count tracks added to queue';
  }

  @override
  String toastBatchAddedToDownloadQueue({required Object count}) {
    return '$count tracks added to download queue';
  }

  @override
  String get settingsBarEnhancedLyrics => 'Enhanced bar lyrics';

  @override
  String get settingsBarEnhancedLyricsOn =>
      'Show karaoke highlight when word-timed lyrics are available';

  @override
  String get settingsBarEnhancedLyricsOff =>
      'Always show plain lyrics in the bar';

  @override
  String get settingsSectionClose => 'Closing app';

  @override
  String get settingsSectionPower => 'Power saving';

  @override
  String get settingsPowerSaver => 'Power Saving Mode';

  @override
  String get settingsPowerSaverOn =>
      'Throttle rendering in background (5 FPS minimized, 1 FPS unfocused or screen off)';

  @override
  String get settingsPowerSaverOff => 'Always render at full frame rate';

  @override
  String get settingsSuppressSleep => 'Prevent system sleep';

  @override
  String get settingsSuppressSleepOn =>
      'Keep system awake during playback so background playback isn\'t interrupted';

  @override
  String get settingsSuppressSleepOff => 'System may sleep on idle schedule';

  @override
  String get settingsCloseBehavior => 'When closing the app';

  @override
  String get settingsCloseBehaviorAsk => 'Ask each time';

  @override
  String get settingsCloseBehaviorBackground => 'Play in background';

  @override
  String get settingsCloseBehaviorQuit => 'Quit directly';

  @override
  String get commonCloseConfirmTitle => 'Quit app';

  @override
  String get commonCloseConfirmMessage => 'After closing the main window';

  @override
  String get commonCloseConfirmRemember =>
      'Remember my choice and don\'t ask again';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => 'NT';

  @override
  String get brandKugou => 'KG';

  @override
  String get commonBack => 'Back';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonClose => 'Close';

  @override
  String get commonDefault => 'Default';

  @override
  String get commonGoLogin => 'Log in';

  @override
  String get commonLike => 'Like';

  @override
  String get commonLoading => 'Loading';

  @override
  String get commonOriginal => 'Original';

  @override
  String get commonMore => 'More';

  @override
  String get commonNext => 'Next';

  @override
  String get commonNoMore => 'No more';

  @override
  String get commonPrevious => 'Previous';

  @override
  String get commonSettings => 'Settings';

  @override
  String get commonUnknownAlbum => 'Unknown album';

  @override
  String get commonUnknownArtist => 'Unknown artist';

  @override
  String get commonUnlike => 'Unlike';

  @override
  String get downloadQualityTitle => 'Download quality';

  @override
  String downloadRequiresLoginContent({required Object platform}) {
    return 'Getting a download link from $platform requires login. Without it, you can only preview and cannot download full quality.\n\nPlease log in to your $platform account and retry.';
  }

  @override
  String get downloadRequiresLoginTitle => 'Login required to download';

  @override
  String get downloadStreamingWarnTitle =>
      'Downloading streaming media is not recommended';

  @override
  String get downloadStreamingWarnBody =>
      'If you can rely on your streaming server\'s availability, don\'t use it often, or run the media server yourself, downloading to local storage is generally not recommended.';

  @override
  String get downloadStreamingWarnDontAsk => 'Don\'t show again';

  @override
  String get downloadStreamingWarnProceed => 'Download anyway';

  @override
  String get menuComment => 'View comments';

  @override
  String get menuDownload => 'Download';

  @override
  String get menuLike => 'Add to favorites';

  @override
  String get menuPlay => 'Play';

  @override
  String get menuPlayNext => 'Play next';

  @override
  String get menuRemoveFromQueue => 'Remove from queue';

  @override
  String get menuUnlike => 'Remove from favorites';

  @override
  String get navHeaderAccount => 'Account';

  @override
  String navHeaderKugouId({required Object id}) {
    return 'KG $id';
  }

  @override
  String get navHeaderKugouMusic => 'KG';

  @override
  String get navHeaderLoginAccount => 'Log in (NT / KG)';

  @override
  String get navHeaderLogout => 'Log out';

  @override
  String get navHeaderNeteaseAccount => 'NT account';

  @override
  String get navHeaderNeteaseMusic => 'NT';

  @override
  String get navHeaderQqMusic => 'QM';

  @override
  String get navHeaderQrLogin => 'QR code login';

  @override
  String get navHeaderSearchHint => 'Search songs / artists / playlists';

  @override
  String get navHeaderThemeDark => 'Theme: Dark';

  @override
  String get navHeaderThemeLight => 'Theme: Light';

  @override
  String get navHeaderThemeSystem => 'Theme: System';

  @override
  String get playerBarBuffering => 'Loading…';

  @override
  String get playerBarIdleHint =>
      'Click the sidebar or load a source to start playing';

  @override
  String get playerBarOpenPlayer => 'Open player';

  @override
  String get playerBarPlayPause => 'Play/Pause';

  @override
  String get playerBarPlaylist => 'Playlist';

  @override
  String get playerBarUntitled => 'Untitled';

  @override
  String get queueClear => 'Clear queue';

  @override
  String get queueEmpty => 'Queue is empty';

  @override
  String get queueEmptyHint => 'Songs you select in the list will appear here';

  @override
  String get queueRepeatList => 'Repeat list';

  @override
  String get queueRepeatMode => 'Repeat mode';

  @override
  String get queueRepeatOne => 'Repeat one';

  @override
  String get queueRepeatOff => 'Play in order';

  @override
  String get queueFinished => 'Playlist finished, playback paused';

  @override
  String get queueShuffle => 'Shuffle';

  @override
  String get queueShuffleOff => 'Turn off shuffle';

  @override
  String get queueTitle => 'Playback queue';

  @override
  String queueTrackCount({required Object count}) {
    return '$count tracks';
  }

  @override
  String get searchHistory => 'Search history';

  @override
  String get searchHistoryClear => 'Clear';

  @override
  String get searchHistoryEmpty => 'No search history';

  @override
  String get searchHot => 'Hot search';

  @override
  String searchQuick({required Object query}) {
    return 'Search “$query”';
  }

  @override
  String get sidebarBackHome => 'Back to home';

  @override
  String get sidebarCollapse => 'Collapse sidebar';

  @override
  String get sidebarDownload => 'Downloads';

  @override
  String get sidebarExpand => 'Expand sidebar';

  @override
  String get sidebarFavorites => 'Favorites';

  @override
  String get sidebarGroupMusic => 'Music';

  @override
  String get sidebarGroupPersonal => 'Personal';

  @override
  String get sidebarHistory => 'History';

  @override
  String get sidebarHome => 'Home';

  @override
  String get sidebarLibrary => 'Library';

  @override
  String get sidebarLiked => 'My likes';

  @override
  String get songListAlbum => 'Album';

  @override
  String get songListDuration => 'Duration';

  @override
  String get songListTitle => 'Title';

  @override
  String get songListScrollTop => 'Back to top';

  @override
  String get songListLocatePlaying => 'Locate playing song';

  @override
  String toastAddedToDownloadQueue({required Object quality}) {
    return 'Added to download queue: $quality';
  }

  @override
  String get toastAddedToQueue => 'Added to playback queue';

  @override
  String get toastDownloadEngineNotReady =>
      'Download engine is not ready, please try again later';

  @override
  String get toastLiked => 'Added to favorites';

  @override
  String get toastLoginRequiredKugou =>
      'Operation failed (please make sure you are logged in to your KG account)';

  @override
  String get toastLoginRequiredNetease =>
      'Operation failed (please make sure you are logged in to your NT account)';

  @override
  String get toastNoQualityInfo =>
      'No quality info available for this track; cannot download';

  @override
  String get toastUnliked => 'Removed from favorites';

  @override
  String get commonClear => 'Clear';

  @override
  String get commonEmptyContent => 'No content';

  @override
  String commonLoadFailed({required Object msg}) {
    return 'Failed to load: $msg';
  }

  @override
  String get commonRetry => 'Retry';

  @override
  String get commentDuplicate => 'Please don\'t send the same content twice';

  @override
  String get commentEmpty => 'No comments yet';

  @override
  String get commentHot => 'Hot';

  @override
  String get commentInputEmpty => 'Comment cannot be empty';

  @override
  String get commentInputHint => 'Say something…';

  @override
  String get commentLatest => 'Latest';

  @override
  String commentLoginRequired({required Object platform}) {
    return 'Log in to your $platform account to comment';
  }

  @override
  String commentNotFound({required Object platform}) {
    return 'No $platform comments found for this song';
  }

  @override
  String get commentPublished => 'Comment posted';

  @override
  String commentReplyFormat({required Object text, required Object user}) {
    return '@$user: $text';
  }

  @override
  String get commentSend => 'Send';

  @override
  String commentSendFailed({required Object msg}) {
    return 'Failed to send: $msg';
  }

  @override
  String get commentReply => 'Reply';

  @override
  String commentReplyTo({required Object user}) {
    return 'Reply to @$user';
  }

  @override
  String get commentDeleteConfirmBody => 'This cannot be undone. Continue?';

  @override
  String get commentDeleted => 'Comment deleted';

  @override
  String commentDeleteFailed({required Object msg}) {
    return 'Delete failed: $msg';
  }

  @override
  String commentTimeFormat({
    required Object day,
    required Object month,
    required Object time,
  }) {
    return '$month/$day $time';
  }

  @override
  String get commentTitle => 'Comments';

  @override
  String get folderAdd => 'Add';

  @override
  String get folderBrowse => 'Browse';

  @override
  String get folderEmpty =>
      'No scan folders yet. Use the buttons below to add one';

  @override
  String get folderExists => 'Folder already exists or is invalid';

  @override
  String get folderInvalid =>
      'Folder does not exist, already exists, or is empty';

  @override
  String get folderPathHint => 'Enter an absolute folder path';

  @override
  String get folderRemove => 'Remove';

  @override
  String get folderRemoveDescription =>
      'Folder won\'t be scanned after removal; already-scanned tracks are kept.';

  @override
  String get folderRemoveTitle => 'Remove scan folder';

  @override
  String get loginFetchingQr => 'Getting QR code…';

  @override
  String loginKugouLoggedIn({required Object platform}) {
    return '$platform logged in';
  }

  @override
  String loginKugouLogin({required Object platform}) {
    return 'Log in with $platform';
  }

  @override
  String loginKugouQrLogin({required Object platform}) {
    return 'Scan to log in to $platform';
  }

  @override
  String get loginKugouResponseMissingToken =>
      'Login response missing token/userid';

  @override
  String loginKugouScanHint({required Object platform}) {
    return 'Use the $platform app to scan the QR code';
  }

  @override
  String loginKugouSession({required Object platform}) {
    return 'Logged in with $platform';
  }

  @override
  String loginKugouSuccessVip({required Object platform}) {
    return '$platform login successful, VIP tracks unlocked';
  }

  @override
  String loginLoggedOut({required Object platform}) {
    return 'Logged out of $platform';
  }

  @override
  String loginLogoutWithId({required Object id}) {
    return 'Log out ($id)';
  }

  @override
  String loginNeteaseScanHint({required Object platform}) {
    return 'Use the $platform app to scan the QR code';
  }

  @override
  String get loginQrExpired => 'QR code expired';

  @override
  String get loginQrExpiredRegenerate => 'QR code expired, click to regenerate';

  @override
  String get loginQrLogin => 'QR code login';

  @override
  String get loginRefreshQr => 'Refresh QR code';

  @override
  String get loginRegenerate => 'Regenerate';

  @override
  String get loginRiskTitle => 'Login risk notice';

  @override
  String get loginRiskBody =>
      'Logging into a third-party client involves the following risks. Please confirm before continuing:\n\n- The platform may apply risk control, restrictions or bans to third-party client logins, which may cause account anomalies or limited features;\n- QR / credential login authorizes this software to access the platform with your account; actions such as favoriting, playing and commenting will genuinely affect your account;\n- Login credentials (cookies / tokens, etc.) are stored only on this device, encrypted, and are never uploaded to the developer or any non-platform server;\n- Please comply with the platform\'s terms of service; you bear all consequences of using this software.\n\nContinuing to log in means you have read and accepted the above risks.';

  @override
  String get loginRiskAgree => 'I understand, continue';

  @override
  String get loginTabQr => 'QR code';

  @override
  String get loginTabPhone => 'Phone';

  @override
  String get loginTabEmail => 'Email';

  @override
  String loginTitleBrand({required String platform}) {
    return 'Sign in to $platform';
  }

  @override
  String get loginPhoneHint => 'Phone number';

  @override
  String get loginCodeHint => 'SMS code';

  @override
  String get loginSendCode => 'Send code';

  @override
  String get loginEmailHint => 'Email';

  @override
  String get loginPasswordHint => 'Password';

  @override
  String get loginEmailRiskHint =>
      'Note: if the account has a bound phone number, the platform may send an SMS verification on email login (a platform security measure, unrelated to this software).';

  @override
  String get loginSubmit => 'Sign in';

  @override
  String get loginPhoneRequired => 'Please enter your phone number';

  @override
  String get loginCodeRequired => 'Please enter the verification code';

  @override
  String get loginEmailRequired => 'Please enter your email';

  @override
  String get loginPasswordRequired => 'Please enter your password';

  @override
  String get loginCodeSendFailed => 'Failed to send the verification code';

  @override
  String get loginFailed => 'Login failed';

  @override
  String get loginSuccess => 'Logged in successfully';

  @override
  String get loginWaitingConfirm =>
      'Scanned, please confirm the login on your phone';

  @override
  String get trackListArtistHotSongs => 'Artist hot songs';

  @override
  String get trackListArtistSongs => 'Artist songs';

  @override
  String get trackListDailyRecommend => 'Daily Recommendation';

  @override
  String get trackListDailyRecommendSubtitle =>
      'Refreshed daily based on your taste';

  @override
  String trackListEmptyDailyLogin({required Object platform}) {
    return 'No songs (Daily Recommendation requires $platform login)';
  }

  @override
  String get trackListNoPlayableSource =>
      'No playable source (VIP / preview restriction)';

  @override
  String get trackListPlayAll => 'Play all';

  @override
  String trackListPlaySourceFailed({required Object msg}) {
    return 'Failed to get play source: $msg';
  }

  @override
  String get trayNext => 'Next';

  @override
  String get trayPlayPause => 'Play / Pause';

  @override
  String get trayPrevious => 'Previous';

  @override
  String get trayQuit => 'Quit';

  @override
  String get trayShow => 'Show main window';

  @override
  String get commonPlayAll => 'Play all';

  @override
  String get commonPause => 'Pause';

  @override
  String get commonPlay => 'Play';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get commonSearch => 'Search';

  @override
  String get commonSongs => 'Songs';

  @override
  String get commonAlbums => 'Albums';

  @override
  String get commonArtists => 'Artists';

  @override
  String get commonPlaylists => 'Playlists';

  @override
  String get commonDone => 'Done';

  @override
  String get commonUnknownError => 'Unknown error';

  @override
  String commonSongCountHint({required Object count}) {
    return '$count songs · Click to play';
  }

  @override
  String get platformNetease => 'NT';

  @override
  String get platformKugou => 'KG';

  @override
  String get platformAll => 'All';

  @override
  String get menuDeleteFile => 'Delete file';

  @override
  String get libraryDeleteFileTitle => 'Delete file';

  @override
  String libraryDeleteFileMessage({required Object name}) {
    return 'This permanently deletes \"$name\" and cannot be undone. Continue?';
  }

  @override
  String get libraryDeleteFileConfirm => 'Delete';

  @override
  String get toastFileDeleted => 'File deleted';

  @override
  String get toastDeleteFileFailed => 'Failed to delete file';

  @override
  String get toastRevealFileFailed =>
      'Couldn\'t reveal the file (no file manager available)';

  @override
  String get settingsSectionThirdPartyService => 'Third-party services';

  @override
  String get settingsNekoAttribution => 'Powered by Neko Music API';

  @override
  String get settingsNekoApiDocs => 'Neko Music API docs';

  @override
  String get settingsSongCacheMemoryHint =>
      '\"In-memory playback\" is on — song cache won\'t be written to disk';

  @override
  String get platformNeko => 'NK';

  @override
  String get settingsCatExperimentalSource => 'Experimental sources';

  @override
  String get settingsExperimentalSourceSubtitle =>
      'Third-party sources (off by default)';

  @override
  String get settingsNekoTitle => 'NekoMusic';

  @override
  String get settingsNekoNote =>
      'Third-party experimental source, unofficial; login only — no sign-up or VIP purchase. May stop working at any time.';

  @override
  String get settingsNekoEnable => 'Enable NekoMusic';

  @override
  String get settingsNekoEnableDesc =>
      'Show NK in search, liked and favorites (off by default)';

  @override
  String get settingsNekoLogin => 'Log in';

  @override
  String get settingsNekoLogout => 'Log out';

  @override
  String settingsNekoLoggedInAs({required Object name}) {
    return 'Signed in as $name';
  }

  @override
  String get settingsNekoNotLoggedIn => 'Not signed in';

  @override
  String get nekoLoginTitle => 'Sign in to NekoMusic';

  @override
  String get nekoLoginTabQr => 'QR code';

  @override
  String get nekoLoginTabPassword => 'Email & password';

  @override
  String get nekoLoginEmail => 'Email';

  @override
  String get nekoLoginPassword => 'Password';

  @override
  String get nekoLoginPasswordHint => 'Enter your password';

  @override
  String get nekoLoginSubmit => 'Sign in';

  @override
  String get nekoLoginQrHint => 'Scan with the NekoMusic mobile app to sign in';

  @override
  String get nekoQrScanned => 'Scanned, confirm on your phone';

  @override
  String get nekoQrCanceled => 'Sign-in canceled';

  @override
  String get nekoQrExpired => 'QR code expired, please regenerate';

  @override
  String get toastLoginRequiredNeko =>
      'Operation failed (please make sure you are logged in to your NK account)';

  @override
  String get pageLikedNekoLoginHint => 'Sign in to NK to view your liked songs';

  @override
  String get pageLikedNekoLoginDesc =>
      'Sign in to NekoMusic to sync your liked songs';

  @override
  String get pageLikedNekoEmptyHint =>
      'No liked songs yet — tap the heart on the search page';

  @override
  String get pageFavNekoLoginDesc =>
      'Sign in to NekoMusic to view playlists and favorites';

  @override
  String get pageFavNekoEmptyHint => 'No playlists or favorites yet';

  @override
  String toastPlayedAll({required Object count}) {
    return 'Played all $count songs';
  }

  @override
  String toastPlayFailed({required Object msg}) {
    return 'Failed to play: $msg';
  }

  @override
  String get toastMissingLocalPath => 'Missing local file path';

  @override
  String get toastRemovedFromLibrary => 'Removed from library';

  @override
  String get toastRemoveFailed => 'Remove failed';

  @override
  String toastDailyRequiresLogin({required Object platform}) {
    return 'Daily recommend requires signing in with your $platform account';
  }

  @override
  String get toastPlaylistEmpty => 'This playlist has no songs';

  @override
  String get toastAlbumEmpty => 'This album has no songs';

  @override
  String get toastPausedAll => 'All paused';

  @override
  String get toastResumedAll => 'All started';

  @override
  String get toastPaused => 'Paused';

  @override
  String get toastCanceledTask => 'Task canceled and deleted';

  @override
  String get toastResumed => 'Download resumed';

  @override
  String get toastRequeued => 'Requeued';

  @override
  String get toastDeletedSelected => 'Deleted selected tasks';

  @override
  String get toastDeletedSelectedWithMedia =>
      'Deleted selected tasks and media files';

  @override
  String get toastCleared => 'Cleared download tasks';

  @override
  String get toastClearedWithMedia => 'Cleared tasks and deleted media files';

  @override
  String get toastDeletedTask => 'Task deleted';

  @override
  String get toastDeletedTaskWithMedia => 'Task and media file deleted';

  @override
  String get pageHistoryRemoved => 'Removed from history';

  @override
  String get pageHistoryClearTitle => 'Clear play history';

  @override
  String get pageHistoryClearMessage =>
      'Clear all play history? This can\'t be undone.';

  @override
  String get pageHistoryCleared => 'Play history cleared';

  @override
  String get pageHistoryRemove => 'Remove from history';

  @override
  String get pageHistorySubtitleEmpty => 'Play records stored locally';

  @override
  String get pageHistoryEmpty => 'No play history yet';

  @override
  String get pageHistoryEmptyHint =>
      'Songs you play are recorded here automatically';

  @override
  String pageFavPlaylistCount({required Object count}) {
    return '$count favorite playlists';
  }

  @override
  String get pageFavPlaylistLoginHint => 'Sign in to see favorite playlists';

  @override
  String pageFavAlbumCount({required Object count}) {
    return '$count favorite albums';
  }

  @override
  String get pageFavAlbumLoginHint => 'Sign in to see favorite albums';

  @override
  String pageFavArtistCount({required Object count}) {
    return '$count favorite artists';
  }

  @override
  String get pageFavArtistLoginHint => 'Sign in to see favorite artists';

  @override
  String get pageFavLoadFailed => 'Failed to load favorites';

  @override
  String get pageFavEmpty => 'No favorites yet';

  @override
  String get pageFavEmptyHint =>
      'Favorites in the NT app sync here automatically';

  @override
  String get pageFavLoginTitle => 'Sign in to view favorites';

  @override
  String get pageFavLoginDesc =>
      'Scan to log in to NT and sync favorite playlists, albums and artists';

  @override
  String get pageFavKgCreated => 'Created playlists';

  @override
  String get pageFavKgCollectedPlaylist => 'Collected playlists';

  @override
  String get pageFavKgCollectedAlbum => 'Collected albums';

  @override
  String pageFavKgCreatedCount({required Object count}) {
    return '$count created playlists';
  }

  @override
  String get pageFavKgCreatedLoginHint =>
      'Log in to view your created playlists';

  @override
  String pageFavKgCollectedPlaylistCount({required Object count}) {
    return '$count collected playlists';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'Log in to view your collected playlists';

  @override
  String pageFavKgCollectedAlbumCount({required Object count}) {
    return '$count collected albums';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint =>
      'Log in to view your collected albums';

  @override
  String get pageFavKugouLoginDesc =>
      'Scan to log in to KG and sync created and collected playlists and albums';

  @override
  String get pageFavKugouEmptyHint =>
      'Synced automatically when you favorite in the KG app';

  @override
  String pageSearchLoadingTrack({required Object title}) {
    return 'Loading: $title';
  }

  @override
  String get menuViewArtist => 'View artist';

  @override
  String get pageSearchArtistComingSoon => 'Artist page coming in Phase 2';

  @override
  String get pageSearchInputHint => 'Type a keyword to search';

  @override
  String get pageSearchInputSubtitle =>
      'Search songs, albums, artists and playlists';

  @override
  String get pageSearching => 'Searching…';

  @override
  String get pageSearchEmpty => 'Nothing found';

  @override
  String get pageSearchEmptyHint => 'Try another keyword';

  @override
  String get pageSearchFailed => 'Search failed';

  @override
  String get pageLikedKugouLoginHint => 'Sign in to sync your KuGou favorites';

  @override
  String get pageLikedNeteaseLoginHint => 'Sign in to sync NT favorites';

  @override
  String get pageLikedLoadFailed => 'Failed to load liked songs';

  @override
  String get pageLikedEmpty => 'No liked songs yet';

  @override
  String get pageLikedKugouEmptyHint =>
      'Favorites in the KuGou app sync here automatically';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'Liked songs in the NT app sync here automatically';

  @override
  String get toastQqLikeSyncFailed =>
      'QM online favorites sync failed (experimental API); the heart change was reverted';

  @override
  String get pageLikedQqHint =>
      'QM hearts are stored on this device and always available; sign in to experimentally sync online favorites';

  @override
  String get pageLikedQqEmptyTitle => 'No QM liked songs yet';

  @override
  String get pageLikedQqEmptyHint =>
      'Like any QM song in search or playback to keep it here (stored on this device)';

  @override
  String get pageLikedQqLoginSync =>
      'Sign in to QM to sync online favorites (experimental)';

  @override
  String get pageLikedQqSyncOnline => 'Sync online favorites (experimental)';

  @override
  String pageLikedQqSynced({required Object count}) {
    return 'Online favorites synced: $count new song(s) added';
  }

  @override
  String get pageLikedQqSyncedNone =>
      'Already in sync - no new online favorites to add';

  @override
  String get pageLikedLoginTitle => 'Sign in to view your liked songs';

  @override
  String get pageLikedKugouLoginDesc =>
      'Scan to log in to KuGou and sync your favorites';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'Scan to log in to NT and sync liked songs';

  @override
  String get libraryScanDirs => 'Scan directories';

  @override
  String get libraryScanDirsDesc =>
      'Manage local scan folders; added folders are scanned immediately';

  @override
  String get libraryMediaStats => 'Media statistics';

  @override
  String get libraryMediaStatsDesc => 'Local library overview';

  @override
  String get libraryStatTracks => 'Tracks';

  @override
  String get libraryStatDuration => 'Total duration';

  @override
  String get libraryStatSize => 'Total size';

  @override
  String libraryStatTrackCount({required Object count}) {
    return '$count songs';
  }

  @override
  String libraryScanDirCount({required Object count}) {
    return '$count';
  }

  @override
  String libraryHoursMinutes({required Object h, required Object m}) {
    return '$h h $m min';
  }

  @override
  String libraryMinutes({required Object m}) {
    return '$m min';
  }

  @override
  String librarySeconds({required Object s}) {
    return '$s sec';
  }

  @override
  String get librarySearchHint => 'Search local tracks';

  @override
  String get libraryNoMatch => 'No matching tracks';

  @override
  String get libraryScanningFiles => 'Counting files…';

  @override
  String libraryTrackCount({required Object count, required Object extra}) {
    return '$count songs$extra';
  }

  @override
  String get libraryEmptyWaitScan => 'Waiting for the first scan';

  @override
  String get libraryEmpty => 'Local library is empty';

  @override
  String get libraryEmptyScanHint => 'Click the button below to scan now';

  @override
  String get libraryEmptyAddHint =>
      'Add a music folder to scan it into the library';

  @override
  String get libraryScanNow => 'Scan now';

  @override
  String get libraryAddFolder => 'Add folder';

  @override
  String get menuLocateFile => 'Locate file';

  @override
  String get menuRemoveFromLibrary => 'Remove from library';

  @override
  String get playerBarCollapsePlayer => 'Collapse player';

  @override
  String get playerBarExitFullscreen => 'Exit Fullscreen';

  @override
  String get playerBarFullscreen => 'Fullscreen';

  @override
  String get playerBarHideLyrics => 'Hide lyrics';

  @override
  String get playerBarShowLyrics => 'Show lyrics';

  @override
  String get playerPageNotPlaying => 'Not playing';

  @override
  String get playerPageLoadHint => 'Load a source to start playing';

  @override
  String get playerPageQualityMenu => 'Switch quality';

  @override
  String get pageHomeRankTitle => 'Charts';

  @override
  String get pageHomePlaylistSquare => 'Playlist plaza';

  @override
  String get pageHomeHotArtists => 'Popular artists';

  @override
  String get pageHomePlaylists => 'Recommended playlists';

  @override
  String get pageHomeNewAlbums => 'New albums';

  @override
  String get pageHomeRankSubtitle => 'Hot songs from all charts';

  @override
  String get pageHomePlaylistSquareSubtitle => 'Discover more great playlists';

  @override
  String get pageHomeArtistSubtitle => 'Popular artists with circular avatars';

  @override
  String get pageHomeLoadFailed => 'Failed to load recommendations';

  @override
  String get pageHomePlaylistsSubtitle => 'Recommended based on your taste';

  @override
  String get pageHomeNewAlbumsSubtitle => 'New albums worth a listen';

  @override
  String get pageHomeHotArtistsSubtitle => 'What everyone is listening to';

  @override
  String get pageHomeDaily => 'Daily recommend';

  @override
  String get pageHomeDailyLoggedIn => 'Hand-picked for your taste';

  @override
  String get pageHomeDailyLoginHint =>
      'Updates daily after you sign in with your NT account';

  @override
  String get pageHomeDailyPlay => 'Play today\'s picks';

  @override
  String get pageHomeDailyLogin => 'Sign in to unlock daily recommend';

  @override
  String pageHomeGreeting({required Object greeting, required Object name}) {
    return '$greeting, $name';
  }

  @override
  String get greetingLate => 'Late night';

  @override
  String get greetingMorning => 'Good morning';

  @override
  String get greetingAfternoon => 'Good afternoon';

  @override
  String get greetingEvening => 'Good evening';

  @override
  String get greetingFallback => 'What would you like to listen to today?';

  @override
  String get downloadDeleteTaskOnly => 'Delete task only';

  @override
  String get downloadDeleteWithMedia => 'Delete task and media files';

  @override
  String downloadSelectedCount({required Object count}) {
    return '$count selected';
  }

  @override
  String get downloadSelectAll => 'Select all';

  @override
  String get downloadDeselectAll => 'Deselect all';

  @override
  String get downloadPauseAll => 'Pause all';

  @override
  String get downloadResumeAll => 'Start all';

  @override
  String get downloadDeleteSelected => 'Delete selected';

  @override
  String get downloadExitSelect => 'Exit multi-select';

  @override
  String downloadActiveCount({required Object count}) {
    return 'Active $count';
  }

  @override
  String downloadDoneCount({required Object count}) {
    return 'Done $count';
  }

  @override
  String get downloadOpenDir => 'Open download folder';

  @override
  String get downloadSelectMode => 'Multi-select';

  @override
  String get downloadEmpty => 'No download tasks';

  @override
  String get downloadEmptyHint => 'Right-click a song → Download to queue it';

  @override
  String downloadDeleteSelectedTitle({required Object count}) {
    return 'Delete $count selected tasks';
  }

  @override
  String get downloadDeleteSelectedMessage =>
      'Delete selected tasks and clear .tmp cache; media files deleted by exact match.';

  @override
  String get downloadClearTitle => 'Clear download tasks';

  @override
  String get downloadClearMessage =>
      'Delete all tasks and clear .tmp cache; media files deleted by exact match.';

  @override
  String get downloadCancelTooltip => 'Cancel (delete task and cache)';

  @override
  String get downloadResume => 'Resume download';

  @override
  String get downloadOpenDirTask => 'Open containing folder';

  @override
  String get downloadDeleteTask => 'Delete task';

  @override
  String get downloadDeleteWithMediaExact =>
      'Delete task and media files (exact match)';

  @override
  String get downloadStatusQueued => 'Queued…';

  @override
  String get downloadStatusResolving => 'Resolving download URL…';

  @override
  String downloadStatusRunning({
    required Object percent,
    required Object received,
    required Object speed,
  }) {
    return 'Downloading $percent% ($received)$speed';
  }

  @override
  String downloadStatusRunningNoPercent({required Object speed}) {
    return 'Downloading…$speed';
  }

  @override
  String downloadStatusPausedWith({required Object received}) {
    return 'Paused ($received)';
  }

  @override
  String get downloadStatusPaused => 'Paused';

  @override
  String downloadStatusFailed({required Object error}) {
    return 'Failed: $error';
  }

  @override
  String get downloadStatusCanceled => 'Canceled';

  @override
  String downloadStatusDone({required Object size}) {
    return 'Done ($size)';
  }

  @override
  String get downloadStatusAlready => 'File already exists';

  @override
  String get pageHomeTitle => 'Discover';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsCatAppearance => 'Appearance';

  @override
  String get settingsCatPlayback => 'Playback';

  @override
  String get settingsCatLyrics => 'Lyrics';

  @override
  String get settingsCatPreset => 'Behavior';

  @override
  String get settingsCatDownload => 'Download';

  @override
  String get settingsCatStorage => 'Storage';

  @override
  String get settingsCatAbout => 'About';

  @override
  String get settingsAppearanceSubtitle => 'Theme · Interface preferences';

  @override
  String get settingsPlaybackSubtitle => 'Audio engine · Playback behavior';

  @override
  String get settingsLyricsSubtitle => 'Player lyrics · Desktop lyrics';

  @override
  String get settingsPresetSubtitle =>
      'Playback filter · Lyrics restore · List tags';

  @override
  String get settingsDownloadSubtitle =>
      'Folder · Concurrency · Speed limit · Quality · Grouping · Filename';

  @override
  String get settingsStorageSubtitle => 'Data directory · Database files';

  @override
  String get settingsAboutSubtitle => 'Version · Project info';

  @override
  String get settingsCatDeveloper => 'Developer';

  @override
  String get settingsDeveloperSubtitle => 'Developer mode · Hidden features';

  @override
  String get settingsDeveloperTitle => 'Developer Mode';

  @override
  String get settingsDeveloperMode => 'Developer Mode';

  @override
  String get settingsDeveloperModeOn => 'Enabled (download features visible)';

  @override
  String get settingsDeveloperModeOff => 'Disabled (download features hidden)';

  @override
  String get settingsDeveloperDownloadModule => 'Download Module';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      'The sidebar “Download” entry, the “Download” context-menu item, and the “Download” settings category are only shown when Developer Mode is on.';

  @override
  String get settingsDeveloperNote =>
      'Developer Mode is intended for local debugging and personal use. Use at your own risk.';

  @override
  String get settingsDevFpsMonitor => 'FPS/Memory monitor overlay';

  @override
  String get settingsDevFpsMonitorDesc =>
      'Shows FPS, average frame time and process memory in real time at the top-right corner (tap to collapse). Off by default; also turned off when developer mode is disabled.';

  @override
  String get settingsDeveloperEnabled => 'Developer Mode enabled';

  @override
  String get settingsDeveloperDisabled => 'Developer Mode disabled';

  @override
  String get settingsSearchHint => 'Search settings…';

  @override
  String settingsSearchNoResult({required Object query}) {
    return 'No settings found for \"$query\"';
  }

  @override
  String settingsSearchMatchCount({required Object count}) {
    return '$count matches';
  }

  @override
  String get settingsSectionTheme => 'Theme';

  @override
  String get settingsThemeMode => 'Theme mode';

  @override
  String get settingsThemeModeDesc => 'Light / Dark / Follow system';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeSystem => 'Follow system';

  @override
  String get settingsThemeNote =>
      'Dark by default; \"Follow system\" follows the OS appearance.';

  @override
  String get settingsSectionAccent => 'Accent color';

  @override
  String get settingsAccentTitle => 'Primary color seed';

  @override
  String get settingsAccentDefaultTooltip => 'Default gray';

  @override
  String get settingsAccentCustomTooltip => 'Custom color picker';

  @override
  String get settingsSectionLayout => 'Layout';

  @override
  String get settingsFloatingBar => 'Floating player bar';

  @override
  String get settingsFloatingBarOn =>
      'Centered capsule at bottom (frosted glass + shadow)';

  @override
  String get settingsFloatingBarOff => 'Full-width docked (default)';

  @override
  String get settingsSectionFont => 'Interface font';

  @override
  String get settingsFontTitle => 'Interface font';

  @override
  String get settingsFontMiSans => 'MiSans (default)';

  @override
  String get settingsFontNoto => 'Noto Sans SC (standard metrics)';

  @override
  String get settingsFontHarmony =>
      'HarmonyOS Sans SC (free for commercial use)';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans SC';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => 'Interface language';

  @override
  String get settingsLanguageTitle => 'Interface language';

  @override
  String get settingsLanguageDesc => 'Switch interface display language';

  @override
  String get settingsLangSystem => 'Follow system';

  @override
  String get settingsSectionCover => 'Cover art';

  @override
  String get settingsCoverRadius => 'Cover corner radius';

  @override
  String get settingsCoverRadiusSharp => 'Square (dense layout)';

  @override
  String settingsCoverRadiusPx({required Object radius}) {
    return '${radius}px radius';
  }

  @override
  String get settingsCoverRadiusSharpLabel => 'Square';

  @override
  String get settingsCoverRadiusRoundedLabel => 'Rounded';

  @override
  String get settingsCoverRadiusLargeLabel => 'Large rounded';

  @override
  String get settingsPickerTitle => 'Custom accent color';

  @override
  String get settingsPickerHexLabel => 'Color value (#RRGGBB)';

  @override
  String get settingsApply => 'Apply';

  @override
  String get settingsSectionAudio => 'Audio';

  @override
  String get settingsPassthrough =>
      'Original quality passthrough (no transcoding)';

  @override
  String get settingsPassthroughOn =>
      'Keep source sample rate (Hi-Res/lossless unchanged)';

  @override
  String get settingsPassthroughOff => 'Unified 48kHz transcoding pipeline';

  @override
  String get settingsOutputDevice => 'Output device';

  @override
  String get settingsOutputDeviceSectionNote =>
      'Play through a specific audio device. Changes take effect immediately or from the next track (no restart needed) and the choice is saved. It only switches when you pick explicitly; the app never reroutes on its own.';

  @override
  String get settingsOutputDeviceDefault => 'System default';

  @override
  String get settingsOutputDeviceDefaultDesc =>
      'Follows the system\'s current output (no automatic rerouting)';

  @override
  String settingsOutputDeviceFormat({
    required Object channels,
    required Object rate,
  }) {
    return '$rate Hz · $channels ch';
  }

  @override
  String get settingsOutputDeviceDefaultTag => 'Default';

  @override
  String get settingsOutputDeviceLoadFailed =>
      'Could not enumerate audio output devices (engine unavailable? staying on system default).';

  @override
  String get settingsOutputDeviceHfpNote =>
      'This device is currently in a low-quality mode (e.g. Bluetooth hands-free/call HFP, typically 16 kHz mono). The engine outputs at the device\'s native format, so quality will be limited.';

  @override
  String get settingsOutputDeviceA2dpGuideTitle =>
      'How to enable Bluetooth A2DP (high-quality audio)';

  @override
  String get settingsOutputDeviceA2dpGuideDesc =>
      '1. Disconnect the Bluetooth headset, then reconnect it.\n2. In the system Bluetooth settings, switch the device to “Audio/A2DP” (on some systems labeled “Media audio”).\n3. If it still only appears as Headset/hands-free, unpair and pair it again.\nExact menus vary by system.';

  @override
  String get settingsOutputDeviceCallBadge => 'Call / low quality';

  @override
  String get settingsOutputDeviceCallConfirmTitle =>
      'Play music through a call-quality device?';

  @override
  String get settingsOutputDeviceCallConfirmDesc =>
      'This device outputs at call/low-quality grade, so music is nearly ruined (voice-grade audio). Most headphones won\'t use this mode for music, and some deliberately reject it — you may get silence or odd behavior. A2DP or another high-quality output is strongly recommended. The app never reroutes on its own; this only applies when you pick it explicitly.';

  @override
  String get settingsOutputDeviceUseQuality => 'Switch to high-quality output';

  @override
  String get settingsOutputDeviceUseCall => 'Use call-quality anyway';

  @override
  String get settingsOutputDeviceDefaultIsCall =>
      'The system default output is a call/low-quality device (e.g. hands-free HFP). Music would play at voice grade — nearly ruined — and some headphones deliberately reject this profile, possibly staying silent or misbehaving. Switch to a high-quality output.';

  @override
  String get settingsOutputDeviceDefaultRowCallNote =>
      'Selecting this routes music through the call/low-quality system default — the sound is nearly ruined; not recommended.';

  @override
  String settingsOutputDeviceShowAll({required int count}) {
    return 'Show all devices ($count)';
  }

  @override
  String get settingsOutputDeviceHideUnused => 'Show usable only';

  @override
  String get settingsOutputDeviceUnavailable => 'Unavailable';

  @override
  String get settingsOutputDeviceVirtualTag => 'Virtual';

  @override
  String settingsSinkChangedFailed({required Object err}) {
    return 'Failed to switch output device: $err';
  }

  @override
  String get settingsEngine => 'Decode engine';

  @override
  String get settingsEngineNote =>
      'The decode engine is loaded when the app starts; changes only apply after a cold restart.';

  @override
  String get settingsEngineStableDesc =>
      'FFmpeg decode kernel. Well-tested and the default.';

  @override
  String get settingsEngineEraAudioDesc =>
      'In-house decode kernel. Newer; performance and memory are still being benchmarked.';

  @override
  String get settingsEngineExperimental => 'Experimental';

  @override
  String get settingsEngineEraAudioNote =>
      'Experimental kernel: performance and memory are still under benchmark, and some formats or devices may misbehave. If you run into issues, switch back to Stable.';

  @override
  String get settingsEngineRestartTitle => 'Restart required';

  @override
  String get settingsEngineRestartDesc =>
      'The decode engine preference is saved. The engine is loaded when the app starts, so restart the app to switch engines. The current engine keeps working until then; playback and downloads are interrupted during the restart.';

  @override
  String get settingsEngineRestartNow => 'Restart now';

  @override
  String get settingsEngineRestartLater => 'Later';

  @override
  String get settingsMemoryPlaySection => 'Playback memory';

  @override
  String get settingsMemoryPlayTitle => 'Memory playback (no disk decode)';

  @override
  String get settingsMemoryPlayOn =>
      'Decoded PCM stays in memory; no stream.wav/stream.pcm written';

  @override
  String get settingsMemoryPlayOff =>
      'File mode: decoded PCM written to disk (legacy)';

  @override
  String get settingsMemoryFileModeNote =>
      'Off = engine writes stream.wav/stream.pcm (file mode). Takes effect from the next track.';

  @override
  String get settingsMemoryPolicyAuto => 'Auto (balance with available memory)';

  @override
  String get settingsMemoryPolicyAutoSub =>
      '0.8 GiB hard cap; adapts to free RAM';

  @override
  String get settingsMemoryPolicyLimit => 'Custom limit';

  @override
  String get settingsMemoryPolicyUnlimited => 'Unlimited';

  @override
  String get settingsMemoryPolicyUnlimitedSub =>
      'Keep the entire decoded track in RAM; shown with an explicit warning';

  @override
  String get settingsMemoryLimitTitle => 'Decoded PCM memory limit';

  @override
  String get settingsMemoryLimitHint => 'MB (48 kHz stereo ≈ 0.38 MB/s)';

  @override
  String get settingsMemoryConfirm => 'Confirm';

  @override
  String get settingsMemoryCancel => 'Cancel';

  @override
  String get settingsMemoryUnlimitedWarnTitle =>
      'Keep all decoded PCM in memory?';

  @override
  String get settingsMemoryUnlimitedWarnBody =>
      'Long tracks can accumulate hundreds of MB to several GB in RAM (≈0.38 MB/s at 48 kHz stereo), which may slow the whole machine, cause the app to be reclaimed by the OS under memory pressure, or make the system unstable. Continue?';

  @override
  String get memoryAlertTitle =>
      'Out of memory · pure in-memory playback unavailable';

  @override
  String get memoryAlertActionStop => 'Stop';

  @override
  String get memoryAlertActionOnlineDirect => 'Play via online direct';

  @override
  String get memoryAlertOnlineDesc =>
      'Continuing will play via online direct (engine network). Otherwise, stop this playback.';

  @override
  String get memorySourceFailNotHttp =>
      'Online source is not an http(s) direct link';

  @override
  String memorySourceFailIsolateSpawn({required Object error}) {
    return 'In-memory source worker failed to start: $error';
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
    return 'Whole-track content ($content) exceeds the pure-memory whole-track limit ($limit)';
  }

  @override
  String memorySourceFailGrewCeiling({
    required Object got,
    required Object limit,
  }) {
    return 'Download exceeded the pure-memory whole-track limit mid-way ($got > $limit)';
  }

  @override
  String get memorySourceFailEmpty => 'Content is empty (0 bytes)';

  @override
  String get memorySourceFailSegOom =>
      'In-memory source allocation failed (out of memory)';

  @override
  String get memorySourceFailSegFill => 'In-memory source write failed';

  @override
  String memorySourceFailSegFillEx({required Object error}) {
    return 'In-memory source write exception: $error';
  }

  @override
  String memorySourceFailDownload({required Object error}) {
    return 'Download failed: $error';
  }

  @override
  String get memorySourceFailUnknown => 'Unknown reason';

  @override
  String get volumeMute => 'Mute';

  @override
  String get volumeUnmute => 'Unmute';

  @override
  String get settingsSectionMemory => 'Memory & startup';

  @override
  String get settingsSessionMemory => 'Session memory';

  @override
  String get settingsSessionMemoryOn =>
      'Remember queue, position and mode; restore on next launch';

  @override
  String get settingsSessionMemoryOff =>
      'Don\'t remember session (starts empty next launch)';

  @override
  String get settingsAutoPlay => 'Auto-play on startup';

  @override
  String get settingsAutoPlayNeedMemory => 'Enable \"Session memory\" first';

  @override
  String get settingsAutoPlayOn => 'Restore last session and auto-play';

  @override
  String get settingsAutoPlayOff => 'Restore session only, no auto-resume';

  @override
  String get settingsSectionSpectrum => 'Spectrum';

  @override
  String get settingsSpectrum => 'Spectrum visualizer';

  @override
  String get settingsSpectrumOn =>
      'Show spectrum bars (playing 0.65 / paused 0.15 opacity)';

  @override
  String get settingsSpectrumOff => 'No spectrum in player';

  @override
  String get settingsSpectrumBarWidth => 'Spectrum bar width';

  @override
  String settingsSpectrumBarWidthDesc({required Object width}) {
    return '${width}px (1~12, full-screen player)';
  }

  @override
  String get settingsBarSpectrum => 'Player-bar spectrum';

  @override
  String get settingsSpectrumStyle => 'Spectrum style';

  @override
  String get settingsSpectrumStyleDesc =>
      'Spectrum visualization effect (bars / wave / up wave)';

  @override
  String get settingsSpectrumStyleBars => 'Bars';

  @override
  String get settingsSpectrumStyleWave => 'Wave';

  @override
  String get settingsSpectrumStyleWaveUp => 'Up wave';

  @override
  String get settingsBarSpectrumOn =>
      'Mini spectrum under the time (when no lyrics or mini lyrics off)';

  @override
  String get settingsBarSpectrumOff => 'No mini spectrum in the player bar';

  @override
  String get settingsCoverBeatScale => 'Scale cover to beat';

  @override
  String get settingsCoverBeatScaleOn => 'Cover pulses with the beat';

  @override
  String get settingsCoverBeatScaleOff =>
      'Cover stays static (play/pause scale only)';

  @override
  String get settingsTransitionStyle => 'Track Transition';

  @override
  String get settingsTransitionStyleDesc =>
      'Transition animation when switching tracks';

  @override
  String get settingsTransitionStyleScale => 'Scale';

  @override
  String get settingsTransitionStyleSlide => 'Slide';

  @override
  String get settingsPlayerBackground => 'Player Background';

  @override
  String get settingsPlayerBackgroundDesc =>
      'Full-screen player background style';

  @override
  String get settingsPlayerBgGradient => 'Gradient';

  @override
  String get settingsPlayerBgBlur => 'Blur';

  @override
  String get settingsPlayerBgSolid => 'Solid';

  @override
  String get settingsPlayerBgRipple => 'Water Ripple';

  @override
  String get settingsPlayerBgRippleSpeed => 'Ripple Speed';

  @override
  String settingsPlayerBgRippleSpeedDesc({required Object speed}) {
    return 'Flow speed $speed';
  }

  @override
  String get settingsPlayerBgFluid => 'Fluid';

  @override
  String get settingsPlayerBgFlowSpeed => 'Flow Speed';

  @override
  String settingsPlayerBgFlowSpeedDesc({required Object speed}) {
    return 'Fluid flow speed $speed';
  }

  @override
  String get settingsPlayerBgRenderScale => 'Render Scale';

  @override
  String settingsPlayerBgRenderScaleDesc({required Object scale}) {
    return 'Resolution $scale× (lower saves power)';
  }

  @override
  String get settingsPlayerBgFps => 'Frame Rate Limit';

  @override
  String settingsPlayerBgFpsDesc({required Object fps}) {
    return '$fps FPS';
  }

  @override
  String get settingsPlayerBgFreezeOnPause => 'Freeze on Pause';

  @override
  String get settingsPlayerBgFreezeOnPauseOn =>
      'Background freezes while paused';

  @override
  String get settingsPlayerBgFreezeOnPauseOff =>
      'Background keeps flowing while paused';

  @override
  String get settingsPlayerBgBeat => 'Bass Beat Pulse';

  @override
  String get settingsPlayerBgBeatOn => 'Background pulses with the bass';

  @override
  String get settingsPlayerBgBeatOff =>
      'Background does not pulse with the beat';

  @override
  String get settingsAdaptiveRenderQuality => 'Adaptive Render Quality';

  @override
  String get settingsAdaptiveRenderQualityOn =>
      'Lower the player background resolution when frames run slow';

  @override
  String get settingsAdaptiveRenderQualityOff =>
      'Player background always renders at full resolution';

  @override
  String get settingsSectionPlayerLyrics => 'Player lyrics';

  @override
  String get settingsPlayerLyrics => 'In-player lyrics';

  @override
  String get settingsPlayerLyricsOn =>
      'Lyrics on the right of full-screen player (highlighted line, click to seek)';

  @override
  String get settingsPlayerLyricsOff => 'No lyrics in full-screen player';

  @override
  String get settingsBarLyrics => 'Player-bar lyrics';

  @override
  String get settingsBarLyricsOn =>
      'Show current lyric under the time (auto-scroll when too long)';

  @override
  String get settingsBarLyricsOff => 'No mini lyrics in the player bar';

  @override
  String get settingsShowTranslation => 'Show translation';

  @override
  String get settingsShowTranslationOn =>
      'Show translation in brackets after the original line';

  @override
  String get settingsShowTranslationOff => 'Hide lyric translation';

  @override
  String get settingsSectionLyricStyle => 'Lyrics style';

  @override
  String get settingsLyricFontSize => 'Lyrics font size';

  @override
  String settingsLyricFontSizeDesc({required Object size}) {
    return '${size}px (current line enlarged & highlighted)';
  }

  @override
  String get settingsLyricLineHeight => 'Lyrics line height';

  @override
  String get settingsLyricPlayedColor => 'Played color';

  @override
  String get settingsLyricPlayedColorDesc =>
      'Highlight color for current lyric line';

  @override
  String get settingsLyricFollowAccent => 'Follow Accent Color';

  @override
  String get settingsLyricFollowAccentDesc =>
      'Use the app accent color for the current line highlight';

  @override
  String get settingsLyricUnplayedColor => 'Unplayed color';

  @override
  String get settingsLyricUnplayedColorDesc => 'Color for upcoming lyric lines';

  @override
  String get settingsLyricsNote =>
      'Lyrics style only applies to full-screen player lyrics';

  @override
  String get settingsSectionFilter => 'Playback filter';

  @override
  String get settingsDjMode => 'Fuck DJ Mode';

  @override
  String get settingsDjModeOn => 'Auto-skip DJ remixes / car hits';

  @override
  String get settingsDjModeOff => 'Auto-skip to next track on DJ versions';

  @override
  String get settingsDjEnhanced => 'Enhanced filtering';

  @override
  String get settingsDjEnhancedDesc =>
      'Also skip Remix / Nightcore / sped-up / slowed / mashup etc. beyond the basic keywords';

  @override
  String get settingsDjCustom => 'Custom skip keywords';

  @override
  String get settingsDjCustomHint =>
      'Comma or newline separated, e.g. cover, karaoke';

  @override
  String get settingsSectionLyricsFilter => 'Lyrics';

  @override
  String get settingsUncensor => 'Unlock profanity';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => 'List display';

  @override
  String get settingsHideVip => 'Hide VIP tags';

  @override
  String get settingsHideVipOn => 'No VIP / paid badges in list';

  @override
  String get settingsHideVipOff => 'Show paid badges (VIP / EP)';

  @override
  String get settingsHideQuality => 'Hide quality tags';

  @override
  String get settingsHideQualityOn => 'No quality badges in list';

  @override
  String get settingsHideQualityOff =>
      'Show highest available quality (Hi-Res / Lossless / HQ…)';

  @override
  String get settingsShowSubtitle => 'Show subtitle';

  @override
  String get settingsShowSubtitleOn =>
      'Show aliases after song title, e.g. (Live)';

  @override
  String get settingsShowSubtitleOff => 'No aliases in list';

  @override
  String get settingsEnergySaving => 'Energy Saving Mode';

  @override
  String get settingsEnergySavingNote =>
      'When enabled, spectrum frames drop to ~300ms apart (100ms baseline by default), lowering CPU usage; rendering and interpolation are unaffected, and the change applies instantly.';

  @override
  String get settingsEnergySavingOn => 'Currently in frame-throttled mode';

  @override
  String get settingsEnergySavingOff => 'Currently in standard mode';

  @override
  String get settingsSearchEnergySavingSubtitle =>
      'Lower spectrum frame rate to save CPU';

  @override
  String get settingsPerformanceMode => 'Performance Mode';

  @override
  String get settingsPerformanceModeOn => 'Currently in frozen mode';

  @override
  String get settingsPerformanceModeOff => 'Currently in motion mode';

  @override
  String get settingsSectionDir => 'Directory';

  @override
  String get settingsDownloadRootHint => 'Download folder (Enter to save)';

  @override
  String get settingsRestoreDefault => 'Restore default';

  @override
  String get settingsSectionFilename => 'Filename';

  @override
  String get settingsDownloadTemplateHint =>
      'Filename template (Enter to save)';

  @override
  String get settingsDownloadTemplateNote =>
      'Placeholders: <artist> · <title> · <album>. Only affects tasks queued later; press Enter to save.';

  @override
  String get settingsSectionQuality => 'Quality';

  @override
  String get settingsDownloadQuality => 'Default download quality';

  @override
  String settingsDownloadQualityDesc({required Object quality}) {
    return 'Download dialog defaults to $quality; auto-downgrades if unavailable';
  }

  @override
  String get settingsDownloadQualityNote =>
      'Tiers high to low: Hi-Res → Lossless → HQ → SQ → LQ; auto-downgrades in this order when missing.';

  @override
  String get settingsSectionConcurrent => 'Concurrency';

  @override
  String get settingsDownloadConcurrent => 'Concurrent downloads';

  @override
  String settingsDownloadConcurrentDesc({required Object count}) {
    return '$count parallel tasks (1~5)';
  }

  @override
  String get settingsDownloadGrouping => 'Folder grouping';

  @override
  String get settingsGroupingFlat => 'All flat in download folder';

  @override
  String get settingsGroupingPlatform => 'Subfolder by platform (KG / NT)';

  @override
  String get settingsGroupingArtist => 'Subfolder by artist';

  @override
  String get settingsGroupingFlatLabel => 'Flat';

  @override
  String get settingsGroupingPlatformLabel => 'By platform';

  @override
  String get settingsGroupingArtistLabel => 'By artist';

  @override
  String get settingsSectionSpeedLimit => 'Speed limit';

  @override
  String get settingsDownloadSpeedLimit => 'Download speed limit';

  @override
  String get settingsSpeedUnlimited => 'Unlimited (default)';

  @override
  String settingsSpeedLimited({required Object speed}) {
    return 'Limited to $speed, takes effect immediately';
  }

  @override
  String get settingsSpeedUnlimitedLabel => 'Unlimited';

  @override
  String settingsSpeedMbps({required Object speed}) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote =>
      'Limit applies immediately, without interrupting in-flight tasks (0.5 MB/s steps, 0 = unlimited).';

  @override
  String get settingsSectionHistory => 'History';

  @override
  String get settingsDownloadHistoryLimit => 'Download history limit';

  @override
  String settingsDownloadHistoryDesc({required Object count}) {
    return '$count entries (10~500) · auto-purges oldest beyond limit';
  }

  @override
  String settingsDownloadHistoryCount({required Object count}) {
    return '$count entries';
  }

  @override
  String get settingsDownloadHistoryNote =>
      'Only purges oldest failed / canceled records; in-progress tasks unaffected.';

  @override
  String get settingsGroupingNote =>
      'Artist grouping v2 supported (Flat / By platform / By artist).';

  @override
  String get settingsSectionFingerprint => 'Device fingerprint';

  @override
  String get settingsFingerprintNote =>
      'Device ID carried in KG / NT download requests; generated on first launch and kept stable, unique per user.';

  @override
  String get settingsDownloadDynamicFingerprint => 'Dynamic device fingerprint';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      'Regenerates the device ID on every launch (legacy behavior); may trigger platform risk control. Off by default.';

  @override
  String get settingsResetFingerprint => 'Reset device fingerprint';

  @override
  String get settingsResetFingerprintDesc =>
      'After reset, this machine appears as a new device to KG / NT; online sessions under the old fingerprint may stop working. Reset now?';

  @override
  String get toastFingerprintReset => 'Device fingerprint reset';

  @override
  String get toastDownloadRootEmpty => 'Download folder cannot be empty';

  @override
  String get toastDownloadRootUpdated => 'Download folder updated';

  @override
  String get toastTemplateEmpty => 'Filename template cannot be empty';

  @override
  String get toastTemplateUpdated => 'Filename template updated';

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
  String get settingsSectionFileLocation => 'File locations';

  @override
  String get settingsDataDir => 'Data directory';

  @override
  String get settingsLibraryDb => 'Media library database';

  @override
  String get settingsUserDb => 'User database (encrypted)';

  @override
  String get settingsLibraryDbLabel => 'Library path';

  @override
  String get settingsUserDbLabel => 'User data path';

  @override
  String get settingsHistoryDb => 'Play history database';

  @override
  String get settingsHistoryDbLabel => 'History database path';

  @override
  String get settingsHistorySection => 'Play History';

  @override
  String get settingsHistoryNote =>
      'Play history is stored in its own history.db (separate from the music library). Turning recording off keeps existing entries; without a limit the database keeps growing on disk and may slow down the history page.';

  @override
  String get settingsHistoryEnabled => 'Record play history';

  @override
  String get settingsHistoryEnabledOn =>
      'Recording — entries are written after playback';

  @override
  String get settingsHistoryEnabledOff => 'Paused — existing entries are kept';

  @override
  String get settingsHistoryLimit => 'History size limit';

  @override
  String settingsHistoryLimitOn({required Object count}) {
    return 'Up to $count entries';
  }

  @override
  String get settingsHistoryLimitUnlimited => 'Unlimited';

  @override
  String get settingsHistoryNoLimitConfirmTitle => 'Remove the size limit?';

  @override
  String get settingsHistoryNoLimitConfirmDesc =>
      'Without a limit, play history can grow indefinitely, taking up disk space and potentially slowing down the history page and the app. Remove the limit anyway?';

  @override
  String get settingsHistoryNoLimitConfirm => 'Keep it unlimited';

  @override
  String get settingsHistoryStats => 'History data';

  @override
  String get settingsCopy => 'Copy';

  @override
  String toastCopied({required Object label}) {
    return '$label copied';
  }

  @override
  String get settingsSectionCache => 'Cache management';

  @override
  String get settingsCacheNote =>
      'Caches speed up browsing and playback; they rebuild automatically after clearing. Your library, history and accounts are not affected.';

  @override
  String get settingsCacheGroupDisk => 'Database caches (disk)';

  @override
  String get settingsCacheGroupMem => 'Memory caches (in-process)';

  @override
  String get settingsCacheLimitLyric => 'Lyric cache limit';

  @override
  String get settingsCacheLimitCover => 'Cover image cache limit';

  @override
  String get settingsCacheLimitUnlimited => 'Unlimited';

  @override
  String get settingsCacheNoLimitConfirmTitle => 'Remove cache limit?';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      'Without a limit, lyric and cover-image caches can grow unbounded in memory, causing memory pressure and lag. Remove the limit?';

  @override
  String get settingsCacheNoLimitConfirm => 'Remove limit';

  @override
  String get settingsSongCache => 'Song cache';

  @override
  String get settingsSongCacheNote =>
      'Played online songs are cached to local disk so replays read the local file directly (saves traffic, faster, playable offline). Over the limit, the least recently used tracks are evicted automatically. The 16 MiB minimum fits a full 320kbps high-quality track (~2.4 MiB/min). Cleared caches rebuild automatically; library, history and accounts are not affected.';

  @override
  String get settingsSongCacheOn => 'On; cached replays read from local disk';

  @override
  String get settingsSongCacheOff =>
      'Off; the media cache will not be saved locally';

  @override
  String get settingsSongCacheLimitTitle => 'Cache limit';

  @override
  String settingsCacheSongs({required Object count}) {
    return '$count songs';
  }

  @override
  String get settingsSearchSongCacheSubtitle =>
      'Online-song disk cache toggle and MiB limit';

  @override
  String get settingsCacheLiked => '\"Liked\" list cache';

  @override
  String get settingsCacheLyric => 'Lyric content cache';

  @override
  String get settingsCacheLyricMatch => 'Lyric match cache';

  @override
  String get settingsCacheLyricTtml => 'TTML lyric cache';

  @override
  String get settingsCacheCover => 'Cover image cache';

  @override
  String settingsCacheEntries({required Object count}) {
    return '$count entries';
  }

  @override
  String settingsCacheImages({required Object count}) {
    return '$count images';
  }

  @override
  String get settingsCacheRefresh => 'Refresh';

  @override
  String get settingsCacheClear => 'Clear';

  @override
  String get settingsCacheClearAll => 'Clear all';

  @override
  String settingsCacheClearConfirmTitle({required Object name}) {
    return 'Clear \"$name\"?';
  }

  @override
  String get settingsCacheClearConfirmDesc =>
      'This deletes all data of this cache; it rebuilds automatically on next use. This cannot be undone.';

  @override
  String get settingsCacheClearAllConfirmTitle => 'Clear all caches?';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      'This deletes all caches above (memory and disk). Your library, history and accounts are not affected.';

  @override
  String toastCacheCleared({required Object name}) {
    return '$name cache cleared';
  }

  @override
  String get toastCacheAllCleared => 'All caches cleared';

  @override
  String get settingsSecuritySection => 'Secure wipe';

  @override
  String get settingsSecurityNote =>
      'Irreversibly deletes all local account credentials and sessions (streaming server passwords, NT/KG sessions, local Subsonic accounts) and revokes platform tokens. Library, history and downloads are not affected.';

  @override
  String get settingsSecurityStreaming => 'Streaming server credentials';

  @override
  String settingsSecurityStreamingCount({required Object count}) {
    return '$count servers';
  }

  @override
  String get settingsSecurityStreamingDesc => 'Passwords and access tokens';

  @override
  String get settingsSecuritySession => 'Third-party account sessions';

  @override
  String get settingsSecuritySessionDesc => 'NT / KG sign-in status';

  @override
  String get settingsSecurityUserDb => 'Local user database';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic accounts and favorites';

  @override
  String get settingsSecurityLoggedIn => 'Signed in';

  @override
  String get settingsSecurityDestroy => 'Wipe';

  @override
  String get settingsSecurityDestroyAll => 'Wipe all';

  @override
  String settingsSecurityConfirmTitle({required Object name}) {
    return 'Wipe “$name”?';
  }

  @override
  String get settingsSecurityConfirmAllTitle => 'Wipe all sensitive data?';

  @override
  String settingsSecurityConfirmDesc({required Object word}) {
    return 'Tokens on the affected platforms will be revoked, then files are overwritten and deleted. This cannot be undone. Type “$word” to confirm.';
  }

  @override
  String get settingsSecurityConfirmWord => 'wipe';

  @override
  String settingsSecurityConfirmHint({required Object word}) {
    return 'Type “$word”';
  }

  @override
  String toastSecurityDestroyed({required Object name}) {
    return 'Wiped: $name';
  }

  @override
  String get toastSecurityAllDestroyed => 'All sensitive data wiped';

  @override
  String toastSecurityDestroyFailed({required Object path}) {
    return 'Wipe failed, file may remain: $path';
  }

  @override
  String get settingsDeviceBindPrivacyTitle =>
      'Enable device-bound passwordless?';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      'A local device identifier (Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID) will be read and bound to your vault; it is stored locally only and never uploaded. Note: this cannot be reverted to the current OS passwordless mode — disabling device binding later falls back to password mode (enter your password at every launch).';

  @override
  String get settingsDeviceBindEnable => 'Enable';

  @override
  String get settingsDeviceBindRecoveryTitle =>
      'Set a recovery password (optional)';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      'Use the recovery password to unlock credentials after a device change/reinstall. Leave blank to skip: credentials cannot be recovered after a device change (fail-closed; wipe and rebuild).';

  @override
  String get settingsDeviceBindRecoveryHint => 'Recovery password';

  @override
  String get settingsDeviceBindSkip => 'Enable without a password';

  @override
  String get settingsDeviceBindChangeRecovery =>
      'Set / change recovery password';

  @override
  String get settingsDeviceBindChangeRecoveryTitle =>
      'Set a new recovery password';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      'The old password becomes invalid immediately. Remember the new one: it is required to unlock credentials after a device change.';

  @override
  String get settingsDeviceBindRebind => 'Rebind this device';

  @override
  String get settingsDeviceBindRebindDesc =>
      'Re-seal with the current device fingerprint; the old fingerprint becomes invalid immediately (use after recovery)';

  @override
  String get settingsDeviceBindRebindTitle => 'Rebind this device?';

  @override
  String get settingsDeviceBindRebindConfirm => 'Rebind now';

  @override
  String get settingsDeviceBindClose => 'Turn off device binding';

  @override
  String get settingsDeviceBindCloseDesc =>
      'Remove device-entropy seal; vault falls back to password mode';

  @override
  String get settingsDeviceBindCloseTitle => 'Turn off device binding?';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      'The device-entropy seal will be removed and the vault switches to password mode: a password is required for each session. That password becomes your new session password. Enter the current recovery password to confirm.';

  @override
  String get settingsDeviceBindCloseHint => 'Current recovery password';

  @override
  String get settingsDeviceBindRecoveryBanner =>
      'Device changed or entropy file corrupted: credentials are locked and require the recovery password';

  @override
  String get settingsDeviceBindRecover => 'Recover';

  @override
  String get settingsDeviceBindRecoverTitle => 'Enter recovery password';

  @override
  String get settingsDeviceBindRecoverDesc =>
      'Unlock credentials with the recovery password; after success, rebind this device to restore passwordless unlock.';

  @override
  String get settingsDeviceBindShowPassword => 'Show / hide password';

  @override
  String get toastDeviceBindEnabled => 'Device-bound passwordless enabled';

  @override
  String get toastDeviceBindRecoverySet => 'Recovery password updated';

  @override
  String get toastDeviceBindRebound => 'Device rebound';

  @override
  String get toastDeviceBindClosed =>
      'Device binding off; vault now uses password mode';

  @override
  String get toastDeviceBindRecoveryNeeded =>
      'No recovery password set; cannot turn off device binding';

  @override
  String toastDeviceBindCloseFailed({required Object error}) {
    return 'Failed to turn off: $error';
  }

  @override
  String get toastDeviceBindRecovered =>
      'Credentials recovered; rebind this device to restore passwordless';

  @override
  String get toastDeviceBindRecoverFailed =>
      'Recovery password incorrect or unlock failed; credentials stay locked';

  @override
  String get settingsSchemeIntroTitle => 'Encryption scheme';

  @override
  String get settingsSchemeIntroDesc =>
      'Your login credentials (cookies) are protected by an encryption scheme. LEGACY (recommended) is enabled: the master key lives in OS secure storage — stable and reliable. For stronger protection you can switch to Vault (experimental) in Settings → Credential encryption scheme — note that switching rebuilds the database and loses all login credentials.';

  @override
  String get settingsSchemeIntroGotIt => 'Got it';

  @override
  String get settingsSchemeSection => 'Credential encryption scheme';

  @override
  String get settingsSchemeNote =>
      'Choose how login credentials are encrypted. LEGACY: OS secure storage, stable and reliable (recommended). FILK (file key): master key in a local secret.key file — no OS keychain, for headless/Docker (single point of failure). Vault: 2-of-2 dual-factor experimental scheme — stronger protection but may occasionally lose cookies. Switching schemes rebuilds the database and requires re-login.';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => 'Recommended';

  @override
  String get settingsSchemeCryptoDesc =>
      'Cookies are encrypted by OS secure storage (Windows DPAPI / macOS Keychain / Linux libsecret). Stable and reliable.';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'LEGACY: the master key is protected entirely by the OS secure store. Balanced security and stability for daily use.';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => 'Compat';

  @override
  String get settingsSchemeFileDesc =>
      'Master key stored in a local file (secret.key, 0600). No OS keychain needed — for headless Linux / Docker servers. Single point: if the key file leaks, all credentials are exposed.';

  @override
  String get settingsSchemeFileModeDesc =>
      'FILK (file key): the master key is stored in a local file (secret.key, 0600 atomic write) — the classic service-side encryption layout. Use only when OS secure storage is unavailable (headless/Docker).';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => 'Experimental';

  @override
  String get settingsSchemeVaultDesc =>
      '2-of-2 dual-factor encryption (system share + user share, both required). Stronger against offline attacks, but cookies may be lost on anomalies.';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Vault: the master key is split into a system share and a user share — both required. Choose v1 OS / v2 password / v3 device binding as the sealing tier.';

  @override
  String get settingsSchemeSwitchTitle => 'Switch encryption scheme?';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault is experimental: cookies may be lost after switching.';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'FILK is a compatibility fallback: the master key lives in a local file. If that file leaks, all credentials are exposed. Use only for headless/Docker servers without an OS keychain.';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      'The schemes use incompatible encrypted structures. Switching destroys the current vault and rebuilds the database; all login credentials (NT / KG / streaming accounts) will be lost and require re-login.';

  @override
  String get settingsSchemeSwitchKeep => 'Keep current';

  @override
  String get settingsSchemeSwitchConfirm => 'Switch and rebuild';

  @override
  String get toastSchemeSwitched =>
      'Encryption scheme switched; effective after restart';

  @override
  String get settingsVaultModeV1 => 'v1 OS protection';

  @override
  String get settingsVaultModeV2 => 'v2 Password';

  @override
  String get settingsVaultModeV3 => 'v3 Device binding';

  @override
  String get settingsVaultModeDescOs =>
      'v1 OS protection: credentials are encrypted by OS secure storage (Windows DPAPI / macOS Keychain / Linux libsecret), passwordless on this machine.';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 Password protection: credentials are encrypted by a password; enter it at every launch to unlock. You can switch back to v1 OS protection anytime.';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 Device binding: passwordless on this device; a recovery password is required after a device change. It cannot drop straight back to v1 — disabling it falls back to v2 password mode.';

  @override
  String get settingsVaultModeDescUnknown => 'Reading encryption tier…';

  @override
  String get settingsVaultSwitchToPasswordTitle =>
      'Switch to password protection (v2)';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      'Credentials will be protected by a password entered at every launch. Your master key and existing data are kept; you can switch back to OS protection (v1) anytime.';

  @override
  String get settingsVaultSwitchToPasswordNewHint => 'Set a new password';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint =>
      'Re-enter the new password';

  @override
  String get settingsVaultSwitchToPasswordMismatch =>
      'The two entries do not match';

  @override
  String get settingsVaultSwitchToOsTitle =>
      'Switch back to OS protection (v1)';

  @override
  String get settingsVaultSwitchToOsDesc =>
      'Credentials will be protected by the operating system\'s secure storage; no password needed. You can switch back to password protection (v2) anytime.';

  @override
  String get settingsVaultNeedUnlockFirst =>
      'Password protection is not unlocked yet: unlock it first, then switch';

  @override
  String get settingsVaultV3NoDirectV1 =>
      'Device binding (v3) cannot drop straight back to v1: disable device binding first to fall back to v2 password mode';

  @override
  String get settingsVaultCloseV3PasswordTitle =>
      'Disable Device Binding: Set New Password';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      'No recovery password was set when device binding was enabled (passwordless on this device). Disabling it switches to password protection (v2): please set a new unlock password. The master key and existing data are preserved; this password is required at every launch.';

  @override
  String get toastVaultSwitchedToPassword =>
      'Switched to password protection (v2)';

  @override
  String get toastVaultSwitchedToOs => 'Switched back to OS protection (v1)';

  @override
  String get settingsVaultShareBrokenBanner =>
      'Credential vault shares are mismatched: storage backend mismatch or missing share. Local credentials cannot be decrypted. Rebuild the vault and sign in again.';

  @override
  String get settingsVaultShareBrokenRebuild => 'Rebuild vault';

  @override
  String get settingsVaultRestartTitle => 'Restart required';

  @override
  String get settingsVaultRestartDesc =>
      'The encryption tier has been switched successfully. Restart the app to ensure database integrity and consistent state across all modules. In password protection mode (v2), you will be asked for your password after restart; login and streaming credentials are unavailable (shown as signed out) until then. Playback and downloads are interrupted during the restart.';

  @override
  String get settingsVaultRestartNow => 'Restart now';

  @override
  String get settingsVaultRestartLater => 'Later';

  @override
  String get vaultCrashTitle => 'Credential module exited abnormally';

  @override
  String get vaultCrashDesc =>
      'The credential vault process terminated unexpectedly. Local credentials may have been exposed. Sign in again or wipe the vault to rebuild credentials.';

  @override
  String get vaultCrashReset => 'Wipe and rebuild';

  @override
  String get vaultCrashDismiss => 'OK';

  @override
  String get vaultVersionTitle => 'Credential vault version anomaly';

  @override
  String get vaultVersionDesc =>
      'The credential vault component is anomalous: its binary may have been replaced or is a non-official build, and local credentials may have been exposed. The anomalous copy has been deleted and decryption refused. Please exit and reinstall the app.';

  @override
  String get vaultVersionExit => 'Exit';

  @override
  String get vaultVersionReasonReplaced =>
      'The vault binary was replaced or is not an official build. The anomalous copy has been deleted and decryption refused.';

  @override
  String get vaultVersionReasonMarkerMissing =>
      'The vault handshake response is missing the official build marker.';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'The vault build marker does not match the official build. The anomalous copy has been deleted and decryption refused.';

  @override
  String get vaultUnlockTitle => 'Unlock credential vault';

  @override
  String get vaultUnlockDesc =>
      'The credential vault is in password-protected mode (v2). Enter your password to unlock local login credentials and streaming accounts.';

  @override
  String get vaultUnlockHint => 'Password';

  @override
  String get vaultUnlockConfirm => 'Unlock';

  @override
  String get vaultUnlockSkip => 'Skip for now';

  @override
  String get vaultUnlockFailed => 'Wrong password, try again';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsVersionUnknown => 'v unknown · Flutter desktop';

  @override
  String settingsVersionFormat({required Object version}) {
    return 'v$version · Flutter desktop';
  }

  @override
  String get settingsAudioEngine => 'Audio engine';

  @override
  String get settingsAudioEngineDesc =>
      'Built-in C engine (miniaudio) · Native FFI';

  @override
  String get settingsSubsonicServer => 'Subsonic server';

  @override
  String get settingsSubsonicDesc => 'Go FFI · Self-hosted library';

  @override
  String get settingsAboutDesc =>
      'Self-developed player: local library, direct sources, self-hosted Subsonic, native audio engine.';

  @override
  String get settingsSectionDeclaration => 'Software declaration';

  @override
  String get settingsDeclineText =>
      'This software (ArchoeraMusic) is open source under AGPL-3.0: you may freely use, study, modify and redistribute it, and comply-compliant commercial use is permitted; we do not offer closed-source commercial licensing outside AGPL obligations. Please read the following before use:\n\n';

  @override
  String get settingsDecline1Title => '1. Software nature\n';

  @override
  String get settingsDecline1Body =>
      'This software is a third-party open-source client, not affiliated with, authorized by, or cooperating with any music platform or its official client. The project itself is not run for profit and accepts no commercial partnerships, ads or donations (commercial use of the code remains governed by AGPL-3.0). For richer features, please use the official client.\n\n';

  @override
  String get settingsDecline2Title => '2. Content sources & copyright\n';

  @override
  String get settingsDecline2Body =>
      'This software does not provide, store or distribute any music content itself. Audio, lyrics and covers come from your local files or public APIs of music platforms; copyright belongs to original rights holders and platforms. This software claims no ownership.\n\n';

  @override
  String get settingsDecline3Title =>
      '3. Copyright data processing obligations\n';

  @override
  String get settingsDecline3Body =>
      'Copyright data (playback URLs, lyrics, covers) generated during use is for your personal preview and research only; do not use for commercial or public distribution. It is recommended to clear within 24 hours. For long-term enjoyment, please purchase or subscribe through official channels to support legitimate music.\n\n';

  @override
  String get settingsDecline4Title => '4. Usage restrictions\n';

  @override
  String get settingsDecline4Body =>
      'Do not use this software for commercial activities, bulk scraping, crawling or resale; do not use in violation of local laws or platform terms of service; do not bypass technical protection measures, access controls or terms of service of online platforms.\n\n';

  @override
  String get settingsDeclineLoginTitle => '5. Login & account\n';

  @override
  String get settingsDeclineLoginBody =>
      'This software offers QR-code login (scan the QR code shown by this software with the platform\'s official app) and credential login, to sync favorites and playlists and unlock related features. Please note:\n- The QR code is generated by the corresponding platform\'s official API; this software does not collect, parse or send your login QR code, account, password or SMS verification code to any third party;\n- Session credentials obtained after login (cookies / tokens, etc.) are stored only on your device (encrypted in the credential vault) and are never uploaded to the developer or any non-platform server;\n- QR login means you authorize this software to access the platform with your account; actions such as favoriting, playing and commenting will genuinely affect your account;\n- Keep your device and system account secure; after logging in on a public or shared device, log out and clear credentials promptly;\n- The platform may apply risk control, restrictions or bans to third-party client logins; any account anomalies or restricted features arising from this are borne by you.\n\n';

  @override
  String get settingsDeclinePrivacyTitle => '6. Privacy & local data\n';

  @override
  String get settingsDeclinePrivacyBody =>
      'This software has no developer server and does not collect or upload your personal information, usage behavior, library contents or login credentials; your library, history, favorites, downloads, settings and login state are stored in the local data directory and can be removed by uninstalling or using the delete function under Security; when interacting with online platforms, requests are sent directly from your device to the corresponding platform and are governed by that platform\'s privacy policy and terms of service.\n\n';

  @override
  String get settingsDeclineThirdPartyTitle =>
      '7. Third-party services & risks\n';

  @override
  String get settingsDeclineThirdPartyBody =>
      'The APIs, authentication methods and availability of online music platforms are determined solely by the platforms and may change, be restricted or shut down at any time, causing login failures, unavailable features or unsynced data; this software is provided as is and makes no commitment regarding the continued availability, stability or data integrity of third-party services.\n\n';

  @override
  String get settingsDecline5Title => '8. Disclaimer\n';

  @override
  String get settingsDecline5Body =>
      'This software is provided \"as is\" without any express or implied warranties. Any direct or indirect losses arising from use or inability to use, or from API changes, account restrictions, expired login credentials, account risk control or bans, feature failures of online platforms shall be borne by the user.\n\n';

  @override
  String get settingsDeclineFooter =>
      'This software is for technical exploration and research only. If any platform finds this software inappropriate, please contact the developer for adjustment or removal.';

  @override
  String get settingsSectionEnvInfo => 'Environment';

  @override
  String get settingsEnvVersion => 'Version';

  @override
  String get settingsEnvPlatform => 'Platform';

  @override
  String get settingsEnvRuntime => 'Runtime';

  @override
  String get settingsSectionCommunity => 'Community';

  @override
  String get settingsCommunityRepo => 'GitHub repository';

  @override
  String get settingsSectionThanks => 'Special thanks';

  @override
  String get settingsThanksDesign => 'Design inspiration';

  @override
  String get settingsThanksCore => 'Core components';

  @override
  String get settingsThanksDecoder => 'Decoder references';

  @override
  String get settingsThanksIcons => 'Icons';

  @override
  String get settingsSectionFontCredits => 'Font Credits';

  @override
  String get settingsFontCreditsText =>
      'This software bundles the following fonts:\n· Noto Sans CJK SC (SIL Open Font License 1.1)\n· MiSans (© Xiaomi, used under the MiSans Font Intellectual Property License Agreement)\n· HarmonyOS Sans SC (© Huawei, used under the HarmonyOS Sans Font License Agreement)';

  @override
  String get commonNoLyrics => 'No lyrics';

  @override
  String commonTrackCount({required Object count}) {
    return '$count tracks';
  }

  @override
  String get settingsSearchColorTitle => 'Played / Unplayed color';

  @override
  String get settingsSearchColorSubtitle =>
      'Current line highlight and regular line color';

  @override
  String get settingsSearchDesktopLyricsTitle => 'Desktop lyrics';

  @override
  String get settingsSearchDesktopLyricsSubtitle =>
      'Always-on-top lyrics window';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => 'Filename template';

  @override
  String get settingsThemeSource => 'Theme color source';

  @override
  String get settingsThemeSourceDesc => 'Where the primary color comes from';

  @override
  String get settingsThemeSourceDefault => 'Follow system';

  @override
  String get settingsThemeSourceCustom => 'Custom';

  @override
  String get settingsThemeSourceCover => 'Follow cover';

  @override
  String get settingsThemeSourceSolid => 'None';

  @override
  String get settingsThemeSourceCustomHint =>
      'Pick a seed color; primary/secondary are generated from it';

  @override
  String get settingsThemeSourceCoverHint =>
      'Extracts the dominant color from the current cover in real time (falls back to default when unavailable)';

  @override
  String get settingsGlobalTint => 'Global tint';

  @override
  String get settingsGlobalTintDesc =>
      'Apply the theme color subtly to the whole interface';

  @override
  String get settingsGlobalTintNote =>
      'Takes effect when a theme color is available (custom / cover); forced on in image background mode.';

  @override
  String get settingsSectionStyle => 'Background style';

  @override
  String get settingsAppearanceStyle => 'Appearance style';

  @override
  String get settingsAppearanceStyleDesc =>
      'How the main background is rendered';

  @override
  String get settingsAppearanceStyleSolid => 'Solid';

  @override
  String get settingsAppearanceStyleImage => 'Image';

  @override
  String get settingsBackgroundImage => 'Background image';

  @override
  String get settingsBackgroundImageDesc =>
      'Pick a local image as the app background; image mode forces dark theme and global tint';

  @override
  String get settingsBackgroundPick => 'Choose image';

  @override
  String get settingsBackgroundReplace => 'Replace';

  @override
  String get settingsBackgroundClear => 'Clear';

  @override
  String get settingsBackgroundBlur => 'Background blur';

  @override
  String settingsBackgroundBlurDesc({required Object blur}) {
    return 'Gaussian blur applied to the background image (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => 'Mask strength';

  @override
  String settingsBackgroundDimDesc({required Object dim}) {
    return 'Dark overlay opacity ($dim%); higher keeps the foreground more readable';
  }

  @override
  String get settingsBackgroundScale => 'Zoom size';

  @override
  String settingsBackgroundScaleDesc({required Object scale}) {
    return 'Zoom factor of the background image (${scale}x)';
  }

  @override
  String get settingsSidebarCollapsed => 'Collapsed sidebar';

  @override
  String get settingsSidebarCollapsedDesc =>
      'Collapse the sidebar to icon-only mode';

  @override
  String get settingsSidebarNavStyle => 'Nav highlight animation';

  @override
  String get settingsSidebarNavStyleDesc =>
      'Animation style of the active navigation highlight';

  @override
  String get settingsSidebarNavStyleDefault => 'Static';

  @override
  String get settingsSidebarNavStyleAnimated => 'Animated';

  @override
  String get settingsRouteTransition => 'Page transition';

  @override
  String get settingsRouteTransitionDesc =>
      'Transition animation when switching pages';

  @override
  String get settingsRouteTransitionNone => 'None';

  @override
  String get settingsRouteTransitionFade => 'Fade';

  @override
  String get settingsRouteTransitionSlide => 'Slide';

  @override
  String get settingsRouteTransitionZoom => 'Zoom';

  @override
  String get settingsSearchThemeSourceSubtitle =>
      'Default theme · Custom · Follow cover · No theme';

  @override
  String get settingsSearchGlobalTintSubtitle =>
      'Tint the whole interface with the theme color';

  @override
  String get settingsSearchBackgroundSubtitle =>
      'Solid / Image · Blur · Mask · Zoom';

  @override
  String get settingsSearchSidebarSubtitle =>
      'Collapse sidebar · Static / Animated highlight';

  @override
  String get settingsSearchRouteTransitionSubtitle =>
      'None · Fade · Slide · Zoom';

  @override
  String get settingsSearchFloatingBarSubtitle =>
      'Floating capsule at bottom · Full-width docked';

  @override
  String get settingsSearchFontSubtitle =>
      'MiSans · Noto Sans · HarmonyOS Sans';

  @override
  String get settingsSearchLanguageSubtitle =>
      'Follow system · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle =>
      'Square · Rounded · Large rounded';

  @override
  String get settingsSectionWeather => 'Weather';

  @override
  String get settingsWeather => 'Weather widget';

  @override
  String get settingsWeatherDesc =>
      'Mini weather (icon + temperature) on the left of the avatar';

  @override
  String get settingsWeatherAutoLocate => 'Auto locate';

  @override
  String get settingsWeatherAutoLocateDesc =>
      'Use network IP for a rough location (privacy: off by default)';

  @override
  String get settingsWeatherCity => 'Manual city';

  @override
  String get settingsWeatherCityHint => 'No IP lookup once set (e.g. Hangzhou)';

  @override
  String get settingsWeatherNote =>
      'Privacy: weather data from Open-Meteo (free, no API key). When auto locate is on, your IP is sent to ipwho.is for a rough location, used only to fetch weather and not stored. Both the widget and location are off by default.';

  @override
  String get settingsWeatherPrivacyTitle => 'Enable weather widget?';

  @override
  String get settingsWeatherPrivacyBody =>
      'Enabling will send requests to the third-party weather service Open-Meteo. In manual city mode, only the city name you entered is sent; no other personal information is uploaded.';

  @override
  String get settingsWeatherPrivacyEnable => 'Enable';

  @override
  String get settingsWeatherAutoLocateTitle => 'Enable auto locate?';

  @override
  String get settingsWeatherAutoLocateBody =>
      'Auto locate uses ipwho.is to determine an approximate location from your network\'s public IP and sends those coordinates to Open-Meteo for weather. This may reveal the city or general area you are in. You can instead enter a city manually.';

  @override
  String get settingsWeatherLocateSource => 'Location source';

  @override
  String get settingsWeatherLocateSourceDesc =>
      'System location is more accurate when available; falls back to IP';

  @override
  String get settingsWeatherLocateSourceIp => 'IP locate';

  @override
  String get settingsWeatherLocateSourceSystem => 'System';

  @override
  String get settingsWeatherLocateSystemTitle => 'Switch to system location?';

  @override
  String get settingsWeatherLocateSystemBody =>
      'System location calls the operating system\'s location service (Windows Location / Linux GeoClue) for a more accurate position, used only for weather. The system will prompt for permission; falls back to IP when unavailable.';

  @override
  String get settingsSearchWeatherSubtitle =>
      'Mini weather widget in the top bar (icon + temperature)';

  @override
  String get weatherRefresh => 'Refresh weather';

  @override
  String get weatherNoLocation =>
      'Set a city or enable auto locate in settings';

  @override
  String get weatherUnavailable => 'Weather unavailable, tap to retry';

  @override
  String get settingsSearchPassthroughSubtitle =>
      'No transcoding · 48kHz pipeline';

  @override
  String get settingsSearchSessionMemorySubtitle =>
      'Remember/restore playback session';

  @override
  String get settingsSearchAutoPlaySubtitle => 'Auto-resume toggle';

  @override
  String get settingsSearchSpectrumSubtitle =>
      'Player spectrum toggle · Opacity';

  @override
  String get settingsSearchSpectrumWidthSubtitle => '1~12px bar width';

  @override
  String get settingsSearchPlayerLyricsSubtitle =>
      'Full-screen player lyrics display';

  @override
  String get settingsSearchLyricFontSizeSubtitle =>
      '14~28px player lyrics font size';

  @override
  String get settingsSearchLyricLineHeightSubtitle => '42~64px line height';

  @override
  String get settingsSearchUncensorSubtitle =>
      'Restore *-masked words in lyrics';

  @override
  String get settingsSearchHideVipSubtitle =>
      'Hide VIP / paid badges in song list';

  @override
  String get settingsSearchHideQualitySubtitle =>
      'Hide quality badges in song list';

  @override
  String get settingsSearchSubtitleSubtitle =>
      'Show aliases in song list (e.g. (Live))';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      'Download folder (defaults to media library; falls back to app data dir)';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> placeholders configurable';

  @override
  String get settingsSearchConcurrentSubtitle => '1~5 parallel download tasks';

  @override
  String get settingsSearchSpeedLimitSubtitle =>
      'Unlimited · 0.5~20 MB/s immediate effect';

  @override
  String get settingsSearchQualitySubtitle =>
      'Hi-Res · Lossless · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle => 'Flat · By platform · By artist';

  @override
  String get settingsSearchHistoryLimitSubtitle =>
      'Auto-purge oldest beyond limit (10~500)';

  @override
  String get settingsSearchStorageSubtitle =>
      'Media library · User database paths';

  @override
  String get settingsSearchAboutSubtitle => 'Audio engine · Subsonic server';

  @override
  String get repeatModeList => 'Repeat list';

  @override
  String get repeatModeOne => 'Repeat one';

  @override
  String get repeatModeOff => 'Play in order';

  @override
  String get sidebarStreaming => 'Streaming';

  @override
  String get settingsCatMediaSource => 'Media source';

  @override
  String get settingsMediaSourceSubtitle =>
      'Streaming servers (Subsonic / Jellyfin / Emby)';

  @override
  String get settingsCatScrape => 'Scrape';

  @override
  String get settingsScrapeSubtitle =>
      'Multi-source metadata: cover / lyrics / tags';

  @override
  String get settingsSectionScrapeDirs => 'Scrape Directories';

  @override
  String get settingsScrapeDirsHint =>
      'One directory per line; leave empty to follow library scan dirs';

  @override
  String get settingsScrapeDirsEmptyNote =>
      'No scrape dirs configured; library scan dirs will be used.';

  @override
  String settingsScrapeDirsNote({required Object dirs}) {
    return 'Effective dirs: $dirs';
  }

  @override
  String get settingsSectionScrapeSources => 'Data Sources';

  @override
  String get settingsScrapeSourceMusicBrainz => 'MusicBrainz';

  @override
  String get settingsScrapeSourceDeezer => 'Deezer';

  @override
  String get settingsScrapeSourceItunes => 'iTunes';

  @override
  String get settingsScrapeSourceNetease => 'Netease Cloud Music';

  @override
  String get settingsScrapeSourceQQMusic => 'QM';

  @override
  String get settingsScrapeSourceKugou => 'KG';

  @override
  String get settingsScrapeSourceKuwo => 'Kuwo Music';

  @override
  String get settingsScrapeSourceMigu => 'Migu Music';

  @override
  String get settingsScrapeSourceAcoustID => 'AcoustID (audio fingerprint)';

  @override
  String get settingsScrapeSourceDesc =>
      'When enabled, participates in multi-source lookup, similarity matching and score merging';

  @override
  String get settingsSectionScrapeProgress => 'Scrape Progress';

  @override
  String get settingsScrapeStart => 'Start Scraping';

  @override
  String get settingsScrapeCancel => 'Cancel Scraping';

  @override
  String get settingsScrapeScanning => 'Scanning directories…';

  @override
  String settingsScrapeCurrent({required Object file}) {
    return 'Processing: $file';
  }

  @override
  String get settingsScrapeSuccess => 'Success';

  @override
  String get settingsScrapeFailed => 'Failed';

  @override
  String get settingsScrapeSkipped => 'Skipped';

  @override
  String get settingsScrapeNotFound => 'Not matched';

  @override
  String get settingsScrapeIdle =>
      'Not scraped yet. Click the button below to start.';

  @override
  String get settingsScrapeNoDirs =>
      'No directories to scrape. Configure scrape dirs or library scan dirs first.';

  @override
  String get settingsScrapeDone => 'Scraping complete';

  @override
  String get settingsScrapeCanceled => 'Scraping canceled';

  @override
  String get toastScrapeNoDirs => 'No directories to scrape';

  @override
  String get toastScrapeDirsUpdated => 'Scrape dirs saved';

  @override
  String get toastScrapeStarted => 'Scraping started';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonSave => 'Save';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get streamingHint => 'Media source';

  @override
  String get streamingQualityTitle => 'Streaming quality';

  @override
  String get streamingQualityNote =>
      'Original first; transcode tiers ask the server to transcode to universal MP3 — requires server support, standard params keep other servers compatible.';

  @override
  String get streamingQualityOriginal => 'Original';

  @override
  String get streamingQualityHigh => 'High (320k)';

  @override
  String get streamingQualityMedium => 'Medium (192k)';

  @override
  String get streamingQualityLow => 'Low (128k)';

  @override
  String get streamingHintDetail =>
      'Add a streaming server to browse and play its music (Subsonic family / Jellyfin / Emby, including the built-in local Subsonic server).';

  @override
  String get streamingServerAdd => 'Add server';

  @override
  String get streamingEmptyNoServer => 'No streaming server yet';

  @override
  String get streamingEmptyAddHint => 'Click the button above to add a server';

  @override
  String get streamingServerConnected => 'Connected';

  @override
  String get streamingServerDisconnected => 'Not connected';

  @override
  String get streamingServerLastConnected => 'Last connected';

  @override
  String get streamingServerDisconnect => 'Disconnect';

  @override
  String get streamingToastDisconnected => 'Server disconnected';

  @override
  String get streamingServerConnect => 'Connect';

  @override
  String streamingToastConnected({required Object name}) {
    return 'Connected to $name';
  }

  @override
  String get streamingServerConnectFailed => 'Connection failed';

  @override
  String get streamingServerEdit => 'Edit';

  @override
  String get streamingServerDeleteConfirmTitle => 'Delete server';

  @override
  String streamingServerDeleteConfirm({required Object name}) {
    return 'Delete server \"$name\"?';
  }

  @override
  String get streamingServerRemoved => 'Server removed';

  @override
  String get streamingServerErrorNameEmpty => 'Enter a server name';

  @override
  String get streamingServerErrorHostEmpty => 'Enter a server address';

  @override
  String get streamingServerErrorPortInvalid => 'Invalid port (1~65535)';

  @override
  String get streamingServerErrorUsernameEmpty => 'Enter a username';

  @override
  String get streamingServerErrorPasswordEmpty => 'Enter a password';

  @override
  String get streamingServerAdded => 'Server added';

  @override
  String get streamingServerUpdated => 'Server updated';

  @override
  String get streamingServerType => 'Type';

  @override
  String get streamingServerName => 'Name';

  @override
  String get streamingServerNamePlaceholder => 'e.g. My Navidrome';

  @override
  String get streamingServerHost => 'Server address';

  @override
  String get streamingServerHostPlaceholder => 'e.g. 192.168.1.10:4533';

  @override
  String get streamingServerPort => 'Port';

  @override
  String get streamingServerPortNote =>
      'Default ports: 4533 (Subsonic) / 8096 (Jellyfin); leave empty to auto-detect.';

  @override
  String get streamingServerLocalTitle => 'Built-in local server';

  @override
  String get streamingServerLocalDesc =>
      'Use the built-in Subsonic server (local library)';

  @override
  String get streamingServerUsername => 'Username';

  @override
  String get streamingServerPassword => 'Password';

  @override
  String get streamingServerTestOk => 'Connection OK';

  @override
  String get streamingServerTestFail => 'Connection failed';

  @override
  String get streamingServerTest => 'Test connection';

  @override
  String get streamingTabsSongs => 'Songs';

  @override
  String get streamingTabsAlbums => 'Albums';

  @override
  String get streamingTabsArtists => 'Artists';

  @override
  String get streamingTabsPlaylists => 'Playlists';

  @override
  String get streamingEmptyGoToSettings => 'Go to settings';

  @override
  String get streamingEmptyNotConnected => 'Not connected to any server';

  @override
  String streamingTotalSongs({required Object count}) {
    return '$count songs';
  }

  @override
  String streamingTotalAlbums({required Object count}) {
    return '$count albums';
  }

  @override
  String streamingTotalArtists({required Object count}) {
    return '$count artists';
  }

  @override
  String streamingTotalPlaylists({required Object count}) {
    return '$count playlists';
  }

  @override
  String get streamingEmptyNoResults => 'No matching results';

  @override
  String streamingAlbumSongs({required Object count}) {
    return '$count songs';
  }

  @override
  String streamingArtistAlbums({required Object count}) {
    return '$count albums';
  }

  @override
  String streamingPlaylistSongs({required Object count}) {
    return '$count songs';
  }

  @override
  String get brandQqMusic => 'QM';

  @override
  String get platformQQMusic => 'QM';

  @override
  String get loginQqQrLogin => 'Sign in with QM QR code';

  @override
  String get loginQqScanHint => 'Scan with the QQ app to sign in';

  @override
  String navHeaderQqId({required String id}) {
    return 'QQ $id';
  }

  @override
  String searchSourceFailed({required Object source}) {
    return '$source search is temporarily unavailable';
  }

  @override
  String searchQqRiskDetail({required Object code}) {
    return 'QM rate-limited or risk-blocked the request (code $code); auto-retry is paused, please try again later';
  }

  @override
  String get searchNetworkError =>
      'Network error or request timeout, please try again later';

  @override
  String searchPlatformError({required Object code}) {
    return 'Platform returned an error ($code)';
  }

  @override
  String get searchWaitRetry =>
      'Too many requests, please wait a moment and retry';

  @override
  String get settingsValueAuto => 'Auto';

  @override
  String get settingsSectionScrapeWrite => 'Write Options';

  @override
  String get settingsScrapeWriteDesc =>
      'Written into audio tags after a successful scrape';

  @override
  String get settingsScrapeEmbedMetadata => 'Embed metadata';

  @override
  String get settingsScrapeEmbedCover => 'Embed cover art';

  @override
  String get settingsScrapeEmbedLyrics => 'Embed lyrics';

  @override
  String get settingsScrapeSkipScraped => 'Skip scraped files';

  @override
  String get settingsScrapeSkipScrapedDesc =>
      'Files that already carry a MusicBrainz ID or ISRC are not scraped again';

  @override
  String get settingsSectionScrapeAdvanced => 'Advanced';

  @override
  String get settingsScrapeWorkers => 'Concurrent workers';

  @override
  String settingsScrapeWorkersDesc({required Object value}) {
    return 'Multi-source concurrent lookup threads (0=auto, current $value)';
  }

  @override
  String get settingsScrapeBatch => 'Batch size';

  @override
  String settingsScrapeBatchDesc({required Object value}) {
    return 'Files processed per batch (current $value)';
  }

  @override
  String get settingsScrapeRetries => 'Max retries';

  @override
  String settingsScrapeRetriesDesc({required Object value}) {
    return 'Files failing more than this are isolated (current $value)';
  }

  @override
  String get settingsSectionScrapeOrganize => 'Organize Only';

  @override
  String get settingsScrapeOrganizeNote =>
      'Offline. Moves files under directories into a target tree by template, keeping original file names and existing tags. Variables: artist, albumArtist, album, genre, year, disc, track, title, ext; use / to separate directory levels. When no target directory is set, the media library\'s default music folder (first scan dir) is used; if no library scan directory is configured yet, add one first.';

  @override
  String get settingsScrapeOrganizeTargetDir => 'Organize Target Directory';

  @override
  String get settingsScrapeOrganizeTargetHint =>
      'Leave empty to use the media library\'s default music folder (first scan dir; add a library scan dir first if none is configured)';

  @override
  String get settingsScrapeOrganizePattern => 'Organize Pattern';

  @override
  String get settingsScrapeOrganizePatternHint =>
      'The pattern only decides directory levels; file names are kept';

  @override
  String get settingsScrapeOrganizePresetArtistAlbum => 'Artist/Album';

  @override
  String get settingsScrapeOrganizePresetArtistOnly => 'Artist only';

  @override
  String get settingsScrapeOrganizePresetGenreArtistAlbum =>
      'Genre/Artist/Album';

  @override
  String get settingsScrapeOrganizePresetYearArtistAlbum => 'Year/Artist/Album';

  @override
  String get settingsScrapeOrganizeStart => 'Start Organizing';

  @override
  String get settingsOrganizeRunning => 'Organizing files…';

  @override
  String get settingsOrganizeMoved => 'Moved';

  @override
  String get settingsOrganizeSkipped => 'Skipped';

  @override
  String get settingsOrganizeFailed => 'Failed';

  @override
  String settingsOrganizeDone({
    required Object failed,
    required Object moved,
    required Object skipped,
  }) {
    return 'Organize done: moved $moved, skipped $skipped, failed $failed';
  }

  @override
  String get settingsOrganizeNoTarget =>
      'No media library scan directory is configured, so the default organize target cannot be resolved';

  @override
  String settingsOrganizeUsingDefault({required Object dir}) {
    return 'No target set; using the default music folder: $dir';
  }

  @override
  String get toastOrganizeNoDirs => 'No directories to organize';

  @override
  String get toastOrganizeStarted => 'Organizing started';

  @override
  String get settingsCatScanner => 'Scanning';

  @override
  String get settingsScannerSubtitle =>
      'Library scanner · parallelism & safety caps · quarantine';

  @override
  String get settingsSectionScanRun => 'Runtime';

  @override
  String get settingsScanParallelism => 'Scan parallelism';

  @override
  String settingsScanParallelismDesc({required Object value}) {
    return 'Files parsed in parallel (0=auto, current $value)';
  }

  @override
  String get settingsScanBatch => 'Batch size';

  @override
  String settingsScanBatchDesc({required Object value}) {
    return 'DB batch write cap (0=auto, current $value)';
  }

  @override
  String get settingsSectionScanLimits => 'Safety Caps';

  @override
  String get settingsScanLimitsNote =>
      'Protective caps for very large libraries; leave empty to use engine defaults';

  @override
  String get settingsScanNumberDesc => 'Leave empty to use engine defaults';

  @override
  String get settingsScanMaxFileSizeMb => 'Max file size (MB)';

  @override
  String get settingsScanMaxScanFiles => 'Max files per scan';

  @override
  String get settingsScanMaxErrors => 'Consecutive error cap';

  @override
  String get settingsSectionScanExts => 'Audio Extensions';

  @override
  String get settingsScanExtraExtsNote =>
      'Extra audio extensions scanned on top of the built-in allowlist';

  @override
  String get settingsScanExtraExtsHint =>
      'Space or comma separated, e.g. dsf m4b';

  @override
  String get settingsSectionScanQuarantine => 'Quarantine';

  @override
  String settingsScanQuarantineNote({required Object dir}) {
    return 'Files failing to parse 3+ times are moved to: $dir';
  }

  @override
  String get settingsScanQuarantineEmpty => 'No quarantined files';

  @override
  String get settingsScanQuarantineDelete => 'Delete this file';

  @override
  String get settingsScanQuarantineOpenDir => 'Open folder';

  @override
  String get settingsScanQuarantineClearAll => 'Clear quarantine';

  @override
  String get settingsScanQuarantineClearAllConfirm =>
      'Delete every file in the quarantine folder? This cannot be undone.';

  @override
  String get libraryFullScan => 'Full Scan';

  @override
  String get libraryFullScanConfirm => 'Run a full scan?';

  @override
  String get libraryFullScanConfirmDesc =>
      'The library database will be cleared and rebuilt from the scan directories (source files are kept). This cannot be undone and uses significant disk IO while running.';

  @override
  String get settingsSectionLyricEngine => 'Lyrics Engine';

  @override
  String get settingsLyricEngine => 'Engine';

  @override
  String get settingsLyricEngineSimple => 'Classic';

  @override
  String get settingsLyricEngineWall => 'Wall';

  @override
  String get settingsLyricEngineDesc =>
      'Choose the renderer; switchable anytime';

  @override
  String get settingsLyricEngineNote =>
      'Applies to the full-player lyric area only; AMLL = Apple Music-style wall scrolling, slightly heavier.';

  @override
  String get settingsSectionLyricWall => 'Wall Options';

  @override
  String get settingsAmllNote =>
      'Apple Music-style wall lyric parameters, used only by the AMLL engine.';

  @override
  String get settingsAmllAlign => 'Active line position';

  @override
  String get settingsAmllDim => 'Inactive line dim';

  @override
  String get settingsAmllWordSweep => 'Word sweep';

  @override
  String get settingsAmllHidePassed => 'Hide passed lines';

  @override
  String get settingsAmllScale => 'Shrink inactive lines';

  @override
  String get settingsAmllBlur => 'Blur inactive lines';

  @override
  String get settingsAmllBlurNote =>
      'Auto adapts to your frame rate: blurs in a single layer first, and turns itself off if that is still too heavy.';

  @override
  String get settingsAmllBlurAuto => 'Auto';

  @override
  String get settingsAmllBlurFast => 'Fast';

  @override
  String get settingsAmllBlurLite => 'Light (approximate)';

  @override
  String get settingsAmllBlurQuality => 'Quality';

  @override
  String get settingsAmllBlurOff => 'Off';

  @override
  String get settingsAmllSpring => 'Scroll spring';

  @override
  String get toastSleepInhibitFailed => 'Failed to keep the system awake';

  @override
  String get toastMediaSessionLost => 'System media session disconnected';

  @override
  String get instanceAlreadyRunning =>
      'Find the running window in the system tray or taskbar.';

  @override
  String get instanceAlreadyRunningTitle => 'ArchoeraMusic is already running';

  @override
  String get settingsCatShortcuts => 'Shortcuts';

  @override
  String get settingsShortcutsSubtitle => 'Custom key bindings';

  @override
  String get shortcutNote =>
      'Click a binding to record a new shortcut; press the key combination in the dialog.';

  @override
  String get shortcutResetAll => 'Reset all';

  @override
  String get shortcutUnbound => 'Unbound';

  @override
  String get shortcutHintEdit => 'Click to edit';

  @override
  String get shortcutConflict => 'Conflicts with another action';

  @override
  String get shortcutCaptureTitle => 'Record shortcut';

  @override
  String get shortcutPressKeys => 'Press keys…';

  @override
  String get shortcutCategoryPlayback => 'Playback';

  @override
  String get shortcutCategorySeek => 'Seek';

  @override
  String get shortcutCategoryVolume => 'Volume';

  @override
  String get shortcutCategoryQueue => 'Queue';

  @override
  String get shortcutCategoryNavigation => 'Navigation';

  @override
  String get shortcutActionPlayPause => 'Play / Pause';

  @override
  String get shortcutActionPlay => 'Play';

  @override
  String get shortcutActionPause => 'Pause';

  @override
  String get shortcutActionStop => 'Stop';

  @override
  String get shortcutActionNext => 'Next track';

  @override
  String get shortcutActionPrevious => 'Previous track';

  @override
  String get shortcutActionLikeToggle => 'Like / Unlike';

  @override
  String get shortcutActionShuffleToggle => 'Toggle shuffle';

  @override
  String get shortcutActionRepeatCycle => 'Cycle repeat mode';

  @override
  String get shortcutActionReload => 'Reload current track';

  @override
  String get shortcutActionSeekBackward => 'Seek back 10s';

  @override
  String get shortcutActionSeekForward => 'Seek forward 10s';

  @override
  String get shortcutActionSeekBackwardLong => 'Seek back 30s';

  @override
  String get shortcutActionSeekForwardLong => 'Seek forward 30s';

  @override
  String get shortcutActionVolumeUp => 'Volume up';

  @override
  String get shortcutActionVolumeDown => 'Volume down';

  @override
  String get shortcutActionMuteToggle => 'Mute / Unmute';

  @override
  String get shortcutActionJumpToFirst => 'Jump to first in queue';

  @override
  String get shortcutActionJumpToLast => 'Jump to last in queue';

  @override
  String get shortcutActionClearQueue => 'Clear queue';

  @override
  String get shortcutActionGoHome => 'Go to Home';

  @override
  String get shortcutActionGoLibrary => 'Go to Library';

  @override
  String get shortcutActionGoSearch => 'Go to Search';

  @override
  String get shortcutActionGoLiked => 'Go to Liked';

  @override
  String get shortcutActionGoFavorites => 'Go to Favorites';

  @override
  String get shortcutActionGoHistory => 'Go to History';

  @override
  String get shortcutActionGoDownload => 'Go to Downloads';

  @override
  String get shortcutActionGoStreaming => 'Go to Streaming';

  @override
  String get shortcutActionOpenPlayer => 'Open player';

  @override
  String get shortcutActionOpenSettings => 'Open settings';

  @override
  String get shortcutActionBack => 'Back';

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
    return '$minutes minutes';
  }

  @override
  String get sleepTimerMinutesUnit => 'min';

  @override
  String get sleepTimerCustom => 'Custom…';

  @override
  String get sleepTimerCustomTitle => 'Custom sleep timer';

  @override
  String get sleepTimerCustomLabel => 'Minutes';

  @override
  String get sleepTimerCustomInvalid => 'Enter minutes between 1 and 600';

  @override
  String get sleepTimerPresets => 'Sleep timer presets';

  @override
  String get sleepTimerPresetsDesc =>
      'Quick durations shown in the sleep timer menu. Add or remove entries; leave empty to show only Custom / End of current track / Off.';

  @override
  String get sleepTimerPresetsAdd => 'Add';

  @override
  String get sleepTimerPresetsEmpty => 'No presets';

  @override
  String get sleepTimerPresetsDuplicate => 'That duration is already a preset';

  @override
  String get sleepTimerPresetsEdit => 'Edit';

  @override
  String get settingsSectionSleepTimer => 'Sleep timer';

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
  String get settingsSectionSpeed => 'Playback speed';

  @override
  String get settingsPlaybackSpeed => 'Playback speed';

  @override
  String get settingsPlaybackSpeedDesc => 'Time-stretch without changing pitch';

  @override
  String get settingsPlaybackSpeedNormal => 'Normal speed';

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
}
