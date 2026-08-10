// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get menuTrackDetail => 'Media details';

  @override
  String get trackDetailDuration => 'Duration';

  @override
  String get trackDetailArtist => 'Artist';

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
  String toastBatchAddedToQueue(Object count) {
    return '$count tracks added to queue';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
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
  String get brandNetease => 'Netease Music';

  @override
  String get brandKugou => 'Kugou Music';

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
  String get commonLossless => 'Lossless';

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
  String downloadRequiresLoginContent(Object platform) {
    return 'Getting a download link from $platform requires login. Without it, you can only preview and cannot download full quality.\n\nPlease log in to your $platform account and retry.';
  }

  @override
  String get downloadRequiresLoginTitle => 'Login required to download';

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
  String get navHeaderComingSoon => 'Coming soon';

  @override
  String navHeaderKugouId(Object id) {
    return 'Kugou $id';
  }

  @override
  String get navHeaderKugouMusic => 'Kugou Music';

  @override
  String get navHeaderLoginAccount => 'Log in (Netease / Kugou)';

  @override
  String get navHeaderLogout => 'Log out';

  @override
  String get navHeaderNeteaseAccount => 'Netease account';

  @override
  String get navHeaderNeteaseMusic => 'Netease Music';

  @override
  String get navHeaderQqMusic => 'QQ Music';

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
  String get queueShuffle => 'Shuffle';

  @override
  String get queueShuffleOff => 'Turn off shuffle';

  @override
  String get queueTitle => 'Playback queue';

  @override
  String queueTrackCount(Object count) {
    return '$count tracks';
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
  String toastAddedToDownloadQueue(Object quality) {
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
      'Operation failed (please make sure you are logged in to your Kugou account)';

  @override
  String get toastLoginRequiredNetease =>
      'Operation failed (please make sure you are logged in to your Netease account)';

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
  String commonLoadFailed(Object msg) {
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
  String commentLoginRequired(Object platform) {
    return 'Log in to your $platform account to comment';
  }

  @override
  String commentNotFound(Object platform) {
    return 'No $platform comments found for this song';
  }

  @override
  String get commentPublished => 'Comment posted';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user: $text';
  }

  @override
  String get commentSend => 'Send';

  @override
  String commentSendFailed(Object msg) {
    return 'Failed to send: $msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
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
  String loginKugouLoggedIn(Object platform) {
    return '$platform logged in';
  }

  @override
  String loginKugouLogin(Object platform) {
    return 'Log in with $platform';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return 'Scan to log in to $platform';
  }

  @override
  String get loginKugouResponseMissingToken =>
      'Login response missing token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return 'Use the $platform app to scan the QR code';
  }

  @override
  String loginKugouSession(Object platform) {
    return 'Logged in with $platform';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return '$platform login successful, VIP tracks unlocked';
  }

  @override
  String loginLoggedOut(Object platform) {
    return 'Logged out of $platform';
  }

  @override
  String loginLogoutWithId(Object id) {
    return 'Log out ($id)';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return 'Scan to log in to $platform';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
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
  String get loginSuccess => 'Logged in successfully';

  @override
  String get loginWaitingConfirm =>
      'Scanned, please confirm the login on your phone';

  @override
  String get splashTagline => 'Local · Online · Self-hosted';

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
  String trackListEmptyDailyLogin(Object platform) {
    return 'No songs (Daily Recommendation requires $platform login)';
  }

  @override
  String get trackListNoPlayableSource =>
      'No playable source (VIP / preview restriction)';

  @override
  String get trackListPlayAll => 'Play all';

  @override
  String trackListPlaySourceFailed(Object msg) {
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
  String commonSongCountHint(Object count) {
    return '$count songs · Click to play';
  }

  @override
  String get platformNetease => 'Netease';

  @override
  String get platformKugou => 'KuGou';

  @override
  String get platformAll => 'All';

  @override
  String toastPlayedAll(Object count) {
    return 'Played all $count songs';
  }

  @override
  String toastPlayFailed(Object msg) {
    return 'Failed to play: $msg';
  }

  @override
  String get toastMissingLocalPath => 'Missing local file path';

  @override
  String get toastLocateComingSoon => 'Open file manager (Phase 2)';

  @override
  String get toastRemovedFromLibrary => 'Removed from library';

  @override
  String get toastRemoveFailed => 'Remove failed';

  @override
  String toastDailyRequiresLogin(Object platform) {
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
  String pageFavPlaylistCount(Object count) {
    return '$count favorite playlists';
  }

  @override
  String get pageFavPlaylistLoginHint => 'Sign in to see favorite playlists';

  @override
  String pageFavAlbumCount(Object count) {
    return '$count favorite albums';
  }

  @override
  String get pageFavAlbumLoginHint => 'Sign in to see favorite albums';

  @override
  String pageFavArtistCount(Object count) {
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
      'Favorites in the Netease app sync here automatically';

  @override
  String get pageFavLoginTitle => 'Sign in to view favorites';

  @override
  String get pageFavLoginDesc =>
      'Scan to log in to Netease and sync favorite playlists, albums and artists';

  @override
  String pageSearchLoadingTrack(Object title) {
    return 'Loading: $title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — detail page coming soon';
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
  String get pageLikedNeteaseLoginHint => 'Sign in to sync Netease favorites';

  @override
  String get pageLikedLoadFailed => 'Failed to load liked songs';

  @override
  String get pageLikedEmpty => 'No liked songs yet';

  @override
  String get pageLikedKugouEmptyHint =>
      'Favorites in the KuGou app sync here automatically';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'Liked songs in the Netease app sync here automatically';

  @override
  String get pageLikedLoginTitle => 'Sign in to view your liked songs';

  @override
  String get pageLikedKugouLoginDesc =>
      'Scan to log in to KuGou and sync your favorites';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'Scan to log in to Netease and sync liked songs';

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
  String libraryStatTrackCount(Object count) {
    return '$count songs';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h h $m min';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m min';
  }

  @override
  String librarySeconds(Object s) {
    return '$s sec';
  }

  @override
  String get librarySearchHint => 'Search local tracks';

  @override
  String get libraryNoMatch => 'No matching tracks';

  @override
  String get libraryScanningFiles => 'Counting files…';

  @override
  String libraryTrackCount(Object count, Object extra) {
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
  String get menuLocateFileComingSoon => 'File manager coming in Phase 2';

  @override
  String get menuRemoveFromLibrary => 'Remove from library';

  @override
  String get playerBarCollapsePlayer => 'Collapse player';

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
      'Updates daily after you sign in with your Netease account';

  @override
  String get pageHomeDailyPlay => 'Play today\'s picks';

  @override
  String get pageHomeDailyLogin => 'Sign in to unlock daily recommend';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
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
  String downloadSelectedCount(Object count) {
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
  String downloadActiveCount(Object count) {
    return 'Active $count';
  }

  @override
  String downloadDoneCount(Object count) {
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
  String downloadDeleteSelectedTitle(Object count) {
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
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return 'Downloading $percent% ($received)$speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return 'Downloading…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return 'Paused ($received)';
  }

  @override
  String get downloadStatusPaused => 'Paused';

  @override
  String downloadStatusFailed(Object error) {
    return 'Failed: $error';
  }

  @override
  String get downloadStatusFailedUnknown => 'Failed: unknown error';

  @override
  String get downloadStatusCanceled => 'Canceled';

  @override
  String downloadStatusDone(Object size) {
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
  String get settingsDeveloperEnabled => 'Developer Mode enabled';

  @override
  String get settingsDeveloperDisabled => 'Developer Mode disabled';

  @override
  String get settingsDeveloperHoldHint =>
      'Hold for 10 seconds to enable Developer Mode (mouse: press and hold)';

  @override
  String get settingsSearchHint => 'Search settings…';

  @override
  String settingsSearchNoResult(Object query) {
    return 'No settings found for \"$query\"';
  }

  @override
  String settingsSearchMatchCount(Object count) {
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
  String settingsAccentSystem(Object color) {
    return 'Follow system accent ($color)';
  }

  @override
  String get settingsAccentSystemFallback =>
      'Follow system accent (fallback to custom if read fails)';

  @override
  String get settingsAccentDefault => 'Default bright blue (design system)';

  @override
  String get settingsAccentCustom => 'Custom (palette generated from seed)';

  @override
  String get settingsAccentDefaultTooltip => 'Default blue';

  @override
  String get settingsAccentSystemTooltip => 'Follow system accent';

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
  String settingsCoverRadiusPx(Object radius) {
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
  String get settingsPassthroughNote =>
      'No transcoding: keep source sample rate; otherwise unify to 48kHz. Current track reloads to apply.';

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
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px (1~12, full-screen player)';
  }

  @override
  String get settingsBarSpectrum => 'Player-bar spectrum';

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
  String get settingsSectionShortcuts => 'Shortcuts';

  @override
  String get settingsShortcutSpace => 'Space';

  @override
  String get settingsShortcutSpaceDesc => 'Play / Pause';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => 'Seek backward / forward 10 seconds';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => 'Music library';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc =>
      'Back (close dialog / exit full-screen player)';

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
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px (current line enlarged & highlighted)';
  }

  @override
  String get settingsLyricLineHeight => 'Lyrics line height';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px (incl. line spacing)';
  }

  @override
  String get settingsLyricPlayedColor => 'Played color';

  @override
  String get settingsLyricPlayedColorDesc =>
      'Highlight color for current lyric line';

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
  String get settingsDownloadRootNote =>
      'Defaults to the library folder; changing folder terminates ongoing downloads. Press Enter to save.';

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
  String settingsDownloadQualityDesc(Object quality) {
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
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count parallel tasks (1~5)';
  }

  @override
  String get settingsDownloadGrouping => 'Folder grouping';

  @override
  String get settingsGroupingFlat => 'All flat in download folder';

  @override
  String get settingsGroupingPlatform =>
      'Subfolder by platform (Kugou / Netease)';

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
  String settingsSpeedLimited(Object speed) {
    return 'Limited to $speed, takes effect immediately';
  }

  @override
  String get settingsSpeedUnlimitedLabel => 'Unlimited';

  @override
  String settingsSpeedMbps(Object speed) {
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
  String settingsDownloadHistoryDesc(Object count) {
    return '$count entries (10~500) · auto-purges oldest beyond limit';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count entries';
  }

  @override
  String get settingsDownloadHistoryNote =>
      'Only purges oldest failed / canceled records; in-progress tasks unaffected.';

  @override
  String get settingsGroupingNote =>
      'Artist grouping v2 supported (Flat / By platform / By artist).';

  @override
  String get toastDownloadRootEmpty => 'Download folder cannot be empty';

  @override
  String get toastDownloadRootUpdated => 'Download folder updated';

  @override
  String get toastTemplateEmpty => 'Filename template cannot be empty';

  @override
  String get toastTemplateUpdated => 'Filename template updated';

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
  String get settingsCopy => 'Copy';

  @override
  String toastCopied(Object label) {
    return '$label copied';
  }

  @override
  String get settingsStorageNote =>
      'Media library and user data are physically separated; paths overridable via ARCHOERACAR_DATA.';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsVersionUnknown => 'v unknown · Flutter desktop';

  @override
  String settingsVersionFormat(Object version) {
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
      'This software (ArchoeraMusic) is a free, open-source desktop music player for personal learning and research purposes, not commercial software. Please read the following declaration before use:\n\n';

  @override
  String get settingsDecline1Title => '1. Software nature\n';

  @override
  String get settingsDecline1Body =>
      'This software is a third-party client with no affiliation, cooperation or authorization with any music platform or their official clients; it is non-profit and does not accept commercial partnerships, ads or donations. For complete features, please use official clients.\n\n';

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
  String get settingsDecline5Title => '5. Disclaimer\n';

  @override
  String get settingsDecline5Body =>
      'This software is provided \"as is\" without any express or implied warranties. Any direct or indirect losses arising from use or inability to use, or from API changes, account restrictions, feature failures of online platforms shall be borne by the user.\n\n';

  @override
  String get settingsDeclineFooter =>
      'This software is for technical exploration and research only. If any platform finds this software inappropriate, please contact the developer for adjustment or removal.';

  @override
  String get settingsSectionFontCredits => 'Font Credits';

  @override
  String get settingsFontCreditsText =>
      'This software bundles the following fonts:\n· Noto Sans CJK SC (SIL Open Font License 1.1)\n· MiSans (© Xiaomi, used under the MiSans Font Intellectual Property License Agreement)\n· HarmonyOS Sans SC (© Huawei, used under the HarmonyOS Sans Font License Agreement)';

  @override
  String get commonNoLyrics => 'No lyrics';

  @override
  String commonTrackCount(Object count) {
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
  String get settingsSearchAccentSubtitle =>
      'Custom primary color seed · Palette';

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
  String settingsBackgroundBlurDesc(Object blur) {
    return 'Gaussian blur applied to the background image (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => 'Mask strength';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return 'Dark overlay opacity ($dim%); higher keeps the foreground more readable';
  }

  @override
  String get settingsBackgroundScale => 'Zoom size';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
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
      'Download folder (default ~/Music/ArchoeraMusic)';

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
  String get qualityLossless => 'Lossless';

  @override
  String get repeatModeList => 'Repeat list';

  @override
  String get repeatModeOne => 'Repeat one';

  @override
  String get commonUnknownTrack => 'Unknown track';

  @override
  String get commonAnonymousUser => 'Anonymous user';

  @override
  String get commonCanceled => 'Canceled';

  @override
  String get commonILike => 'My Favorites';

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
  String settingsScrapeDirsNote(Object dirs) {
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
  String get settingsScrapeSourceQQMusic => 'QQ Music';

  @override
  String get settingsScrapeSourceKugou => 'Kugou Music';

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
  String settingsScrapeCurrent(Object file) {
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
  String streamingToastConnected(Object name) {
    return 'Connected to $name';
  }

  @override
  String get streamingServerConnectFailed => 'Connection failed';

  @override
  String get streamingServerEdit => 'Edit';

  @override
  String get streamingServerDeleteConfirmTitle => 'Delete server';

  @override
  String streamingServerDeleteConfirm(Object name) {
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
  String streamingTotalSongs(Object count) {
    return '$count songs';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count albums';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count artists';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count playlists';
  }

  @override
  String get streamingEmptyNoResults => 'No matching results';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count songs';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count albums';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count songs';
  }
}
