// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get menuTrackDetail => '媒体详细信息';

  @override
  String get trackDetailDuration => '时长';

  @override
  String get trackDetailArtist => '歌手';

  @override
  String get trackDetailAlbum => '专辑';

  @override
  String get trackDetailSource => '来源';

  @override
  String get trackDetailPath => '路径';

  @override
  String get trackDetailFileSize => '文件大小';

  @override
  String get trackDetailCodec => '编码';

  @override
  String get trackDetailSampleRate => '采样率';

  @override
  String get trackDetailBitDepth => '位深';

  @override
  String get trackDetailBitrate => '比特率';

  @override
  String get trackDetailChannels => '声道';

  @override
  String get trackSourceLocal => '本地文件';

  @override
  String get trackSourceStreaming => '流媒体';

  @override
  String get trackDetailQuality => '音质';

  @override
  String get batchSelectAll => '全选';

  @override
  String get batchInvert => '反选';

  @override
  String get batchPlay => '播放所选';

  @override
  String get batchAddQueue => '加入队列';

  @override
  String get batchDownload => '批量下载';

  @override
  String get batchExit => '退出多选';

  @override
  String get batchSelectHint => '批量选择';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '已加入播放队列 $count 首';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '已加入下载队列 $count 首';
  }

  @override
  String get settingsBarEnhancedLyrics => '播放条高级歌词';

  @override
  String get settingsBarEnhancedLyricsOn => '歌词含逐字时间轴时显示卡拉OK高亮';

  @override
  String get settingsBarEnhancedLyricsOff => '播放条始终显示普通歌词';

  @override
  String get settingsSectionClose => '关闭应用';

  @override
  String get settingsSectionPower => '节能';

  @override
  String get settingsPowerSaver => '节能模式';

  @override
  String get settingsPowerSaverOn => '后台自动降帧（最小化 5 FPS，失焦/熄屏 1 FPS）';

  @override
  String get settingsPowerSaverOff => '始终满帧渲染';

  @override
  String get settingsSuppressSleep => '禁用系统休眠';

  @override
  String get settingsSuppressSleepOn => '播放时保持系统唤醒，防止后台播放中断';

  @override
  String get settingsSuppressSleepOff => '系统可能按空闲计划休眠';

  @override
  String get settingsPowerSaverNote =>
      '节能模式监听窗口状态事件自动降帧，无需轮询；窗口不可见或显示器关闭时，渲染引擎本身已停止绘制。「禁用系统休眠」仅在播放中生效。';

  @override
  String get settingsCloseBehavior => '关闭应用时';

  @override
  String get settingsCloseBehaviorAsk => '每次询问';

  @override
  String get settingsCloseBehaviorBackground => '后台播放';

  @override
  String get settingsCloseBehaviorQuit => '直接退出';

  @override
  String get commonCloseConfirmTitle => '退出应用';

  @override
  String get commonCloseConfirmMessage => '关闭主窗口后将';

  @override
  String get commonCloseConfirmRemember => '记住我的选择，不再询问';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => '网易云音乐';

  @override
  String get brandKugou => '酷狗音乐';

  @override
  String get commonBack => '返回';

  @override
  String get commonCancel => '取消';

  @override
  String get commonClose => '关闭';

  @override
  String get commonDefault => '默认';

  @override
  String get commonGoLogin => '去登录';

  @override
  String get commonLike => '喜欢';

  @override
  String get commonLoading => '加载中';

  @override
  String get commonLossless => '无损';

  @override
  String get commonOriginal => '原唱';

  @override
  String get commonMore => '更多';

  @override
  String get commonNext => '下一首';

  @override
  String get commonNoMore => '没有更多了';

  @override
  String get commonPrevious => '上一首';

  @override
  String get commonSettings => '全局设置';

  @override
  String get commonUnknownAlbum => '未知专辑';

  @override
  String get commonUnknownArtist => '未知歌手';

  @override
  String get commonUnlike => '取消喜欢';

  @override
  String get downloadQualityTitle => '下载音质';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return '获取$platform下载链接需登录，未登录只能试听，无法下载完整音质。\n\n请先登录$platform账号后重试。';
  }

  @override
  String get downloadRequiresLoginTitle => '下载需要登录';

  @override
  String get menuComment => '查看评论';

  @override
  String get menuDownload => '下载';

  @override
  String get menuLike => '添加到收藏';

  @override
  String get menuPlay => '播放';

  @override
  String get menuPlayNext => '下一首播放';

  @override
  String get menuRemoveFromQueue => '从队列移除';

  @override
  String get menuUnlike => '取消收藏';

  @override
  String get navHeaderAccount => '账号';

  @override
  String get navHeaderComingSoon => '敬请期待';

  @override
  String navHeaderKugouId(Object id) {
    return '酷狗 $id';
  }

  @override
  String get navHeaderKugouMusic => '酷狗音乐';

  @override
  String get navHeaderLoginAccount => '登录账号（网易云 / 酷狗）';

  @override
  String get navHeaderLogout => '退出登录';

  @override
  String get navHeaderNeteaseAccount => '网易云账号';

  @override
  String get navHeaderNeteaseMusic => '网易云音乐';

  @override
  String get navHeaderQqMusic => 'QQ 音乐';

  @override
  String get navHeaderQrLogin => '扫码登录';

  @override
  String get navHeaderSearchHint => '搜索歌曲 / 歌手 / 歌单';

  @override
  String get navHeaderThemeDark => '主题：暗色';

  @override
  String get navHeaderThemeLight => '主题：亮色';

  @override
  String get navHeaderThemeSystem => '主题：跟随系统';

  @override
  String get playerBarBuffering => '加载中…';

  @override
  String get playerBarIdleHint => '点击侧边栏或加载源开始播放';

  @override
  String get playerBarOpenPlayer => '打开播放页';

  @override
  String get playerBarPlayPause => '播放/暂停';

  @override
  String get playerBarPlaylist => '播放列表';

  @override
  String get playerBarUntitled => '未命名';

  @override
  String get queueClear => '清空队列';

  @override
  String get queueEmpty => '队列为空';

  @override
  String get queueEmptyHint => '在列表中选择歌曲后将出现在这里';

  @override
  String get queueRepeatList => '列表循环';

  @override
  String get queueRepeatMode => '播放模式';

  @override
  String get queueRepeatOne => '单曲循环';

  @override
  String get queueShuffle => '随机播放';

  @override
  String get queueShuffleOff => '关闭随机播放';

  @override
  String get queueTitle => '播放队列';

  @override
  String queueTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String get sidebarBackHome => '返回首页';

  @override
  String get sidebarCollapse => '折叠侧边栏';

  @override
  String get sidebarDownload => '下载';

  @override
  String get sidebarExpand => '展开侧边栏';

  @override
  String get sidebarFavorites => '收藏';

  @override
  String get sidebarGroupMusic => '音乐';

  @override
  String get sidebarGroupPersonal => '个人';

  @override
  String get sidebarHistory => '历史';

  @override
  String get sidebarHome => '首页';

  @override
  String get sidebarLibrary => '音乐库';

  @override
  String get sidebarLiked => '我喜欢';

  @override
  String get songListAlbum => '专辑';

  @override
  String get songListDuration => '时长';

  @override
  String get songListTitle => '标题';

  @override
  String get songListScrollTop => '回到顶部';

  @override
  String get songListLocatePlaying => '定位播放位置';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return '已加入下载队列：$quality';
  }

  @override
  String get toastAddedToQueue => '已加入播放队列';

  @override
  String get toastDownloadEngineNotReady => '下载引擎未就绪，请稍后再试';

  @override
  String get toastLiked => '已添加到收藏';

  @override
  String get toastLoginRequiredKugou => '操作失败（请确认已登录酷狗账号）';

  @override
  String get toastLoginRequiredNetease => '操作失败（请确认已登录网易云账号）';

  @override
  String get toastNoQualityInfo => '该曲目无可用音质信息，无法下载';

  @override
  String get toastUnliked => '已取消收藏';

  @override
  String get commonClear => '清除';

  @override
  String get commonEmptyContent => '暂无内容';

  @override
  String commonLoadFailed(Object msg) {
    return '加载失败：$msg';
  }

  @override
  String get commonRetry => '重试';

  @override
  String get commentDuplicate => '请勿重复发送相同内容';

  @override
  String get commentEmpty => '暂时没有评论';

  @override
  String get commentHot => '热门';

  @override
  String get commentInputEmpty => '评论内容不能为空';

  @override
  String get commentInputHint => '说点什么…';

  @override
  String get commentLatest => '最新';

  @override
  String commentLoginRequired(Object platform) {
    return '发送评论需要登录$platform账号';
  }

  @override
  String commentNotFound(Object platform) {
    return '未找到该歌曲的$platform评论';
  }

  @override
  String get commentPublished => '评论已发布';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user：$text';
  }

  @override
  String get commentSend => '发送';

  @override
  String commentSendFailed(Object msg) {
    return '发送失败：$msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$month月$day日 $time';
  }

  @override
  String get commentTitle => '歌曲评论';

  @override
  String get folderAdd => '添加';

  @override
  String get folderBrowse => '浏览';

  @override
  String get folderEmpty => '尚未添加扫描目录，点击下方按钮添加';

  @override
  String get folderExists => '目录已存在或无效';

  @override
  String get folderInvalid => '目录不存在、已存在或为空';

  @override
  String get folderPathHint => '输入目录绝对路径';

  @override
  String get folderRemove => '移除';

  @override
  String get folderRemoveDescription => '移除后不再扫描该目录，已入库曲目保留。';

  @override
  String get folderRemoveTitle => '移除扫描目录';

  @override
  String get loginFetchingQr => '正在获取二维码…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return '$platform已登录';
  }

  @override
  String loginKugouLogin(Object platform) {
    return '$platform登录';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return '$platform扫码登录';
  }

  @override
  String get loginKugouResponseMissingToken => '登录响应缺少 token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return '请使用$platform App 扫一扫登录';
  }

  @override
  String loginKugouSession(Object platform) {
    return '$platform登录态';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return '$platform登录成功，VIP 曲目已解锁';
  }

  @override
  String loginLoggedOut(Object platform) {
    return '已退出$platform登录';
  }

  @override
  String loginLogoutWithId(Object id) {
    return '退出登录（$id）';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return '扫码登录$platform';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return '请使用$platform App 扫码登录';
  }

  @override
  String get loginQrExpired => '二维码已过期';

  @override
  String get loginQrExpiredRegenerate => '二维码已过期，请点击重新生成';

  @override
  String get loginQrLogin => '扫码登录';

  @override
  String get loginRefreshQr => '刷新二维码';

  @override
  String get loginRegenerate => '重新生成';

  @override
  String get loginSuccess => '登录成功';

  @override
  String get loginWaitingConfirm => '已扫码，请在手机上确认登录';

  @override
  String get trackListArtistHotSongs => '艺人热门歌曲';

  @override
  String get trackListArtistSongs => '歌手单曲';

  @override
  String get trackListDailyRecommend => '每日推荐';

  @override
  String get trackListDailyRecommendSubtitle => '根据口味每天更新';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return '暂无歌曲（每日推荐需登录$platform）';
  }

  @override
  String get trackListNoPlayableSource => '无可用播放源（VIP / 试听限制）';

  @override
  String get trackListPlayAll => '播放全部';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return '获取播放源失败: $msg';
  }

  @override
  String get trayNext => '下一首';

  @override
  String get trayPlayPause => '播放 / 暂停';

  @override
  String get trayPrevious => '上一首';

  @override
  String get trayQuit => '退出';

  @override
  String get trayShow => '显示主窗口';

  @override
  String get commonPlayAll => '播放全部';

  @override
  String get commonPause => '暂停';

  @override
  String get commonPlay => '播放';

  @override
  String get commonRefresh => '刷新';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonSongs => '歌曲';

  @override
  String get commonAlbums => '专辑';

  @override
  String get commonArtists => '歌手';

  @override
  String get commonPlaylists => '歌单';

  @override
  String get commonDone => '完成';

  @override
  String get commonUnknownError => '未知错误';

  @override
  String commonSongCountHint(Object count) {
    return '共 $count 首歌曲 · 点击播放';
  }

  @override
  String get platformNetease => '网易云';

  @override
  String get platformKugou => '酷狗';

  @override
  String get platformAll => '聚合';

  @override
  String toastPlayedAll(Object count) {
    return '已播放全部 $count 首';
  }

  @override
  String toastPlayFailed(Object msg) {
    return '播放失败：$msg';
  }

  @override
  String get toastMissingLocalPath => '缺少本地文件路径';

  @override
  String get toastLocateComingSoon => '打开文件管理器（Phase 2 接入）';

  @override
  String get toastRemovedFromLibrary => '已从曲库移除';

  @override
  String get toastRemoveFailed => '移除失败';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return '每日推荐需要登录$platform账号';
  }

  @override
  String get toastPlaylistEmpty => '歌单暂无歌曲';

  @override
  String get toastAlbumEmpty => '专辑暂无歌曲';

  @override
  String get toastPausedAll => '已全部暂停';

  @override
  String get toastResumedAll => '已全部开始';

  @override
  String get toastPaused => '已暂停';

  @override
  String get toastCanceledTask => '已取消并删除任务';

  @override
  String get toastResumed => '已恢复下载';

  @override
  String get toastRequeued => '已重新加入队列';

  @override
  String get toastDeletedSelected => '已删除所选任务';

  @override
  String get toastDeletedSelectedWithMedia => '已删除所选任务及媒体文件';

  @override
  String get toastCleared => '已清空下载任务';

  @override
  String get toastClearedWithMedia => '已清空任务并删除媒体文件';

  @override
  String get toastDeletedTask => '已删除任务';

  @override
  String get toastDeletedTaskWithMedia => '已删除任务及媒体文件';

  @override
  String get pageHistoryRemoved => '已从历史移除';

  @override
  String get pageHistoryClearTitle => '清空播放历史';

  @override
  String get pageHistoryClearMessage => '确定清空全部播放历史？此操作不可撤销。';

  @override
  String get pageHistoryCleared => '播放历史已清空';

  @override
  String get pageHistoryRemove => '从历史移除';

  @override
  String get pageHistorySubtitleEmpty => '本地存储的播放记录';

  @override
  String get pageHistoryEmpty => '还没有播放记录';

  @override
  String get pageHistoryEmptyHint => '播放过的歌曲会自动记录在这里';

  @override
  String pageFavPlaylistCount(Object count) {
    return '共 $count 个收藏歌单';
  }

  @override
  String get pageFavPlaylistLoginHint => '登录后可查看收藏的歌单';

  @override
  String pageFavAlbumCount(Object count) {
    return '共 $count 张收藏专辑';
  }

  @override
  String get pageFavAlbumLoginHint => '登录后可查看收藏的专辑';

  @override
  String pageFavArtistCount(Object count) {
    return '共 $count 位收藏歌手';
  }

  @override
  String get pageFavArtistLoginHint => '登录后可查看收藏的歌手';

  @override
  String get pageFavLoadFailed => '加载收藏失败';

  @override
  String get pageFavEmpty => '还没有收藏';

  @override
  String get pageFavEmptyHint => '在网易云 App 收藏后自动同步';

  @override
  String get pageFavLoginTitle => '登录后查看收藏';

  @override
  String get pageFavLoginDesc => '扫码登录网易云，同步收藏的歌单、专辑与歌手';

  @override
  String get pageFavKgCreated => '创建的歌单';

  @override
  String get pageFavKgCollectedPlaylist => '收藏的歌单';

  @override
  String get pageFavKgCollectedAlbum => '收藏的专辑';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '共 $count 个创建的歌单';
  }

  @override
  String get pageFavKgCreatedLoginHint => '登录后可查看创建的歌单';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '共 $count 个收藏歌单';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint => '登录后可查看收藏的歌单';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '共 $count 张收藏专辑';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint => '登录后可查看收藏的专辑';

  @override
  String get pageFavKugouLoginDesc => '扫码登录酷狗，同步创建与收藏的歌单、专辑';

  @override
  String get pageFavKugouEmptyHint => '在酷狗 App 收藏后自动同步';

  @override
  String pageSearchLoadingTrack(Object title) {
    return '开始加载：$title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — 详情页待接入';
  }

  @override
  String get menuViewArtist => '查看歌手';

  @override
  String get pageSearchArtistComingSoon => '歌手页 Phase 2 接入';

  @override
  String get pageSearchInputHint => '输入关键词开始搜索';

  @override
  String get pageSearchInputSubtitle => '支持歌曲 / 专辑 / 歌手 / 歌单';

  @override
  String get pageSearching => '搜索中…';

  @override
  String get pageSearchEmpty => '没有找到相关内容';

  @override
  String get pageSearchEmptyHint => '换个关键词试试';

  @override
  String get pageSearchFailed => '搜索失败';

  @override
  String get pageLikedKugouLoginHint => '登录后可同步酷狗「我喜欢」';

  @override
  String get pageLikedNeteaseLoginHint => '登录后可同步网易云收藏';

  @override
  String get pageLikedLoadFailed => '加载喜欢列表失败';

  @override
  String get pageLikedEmpty => '还没有喜欢的歌曲';

  @override
  String get pageLikedKugouEmptyHint => '在酷狗 App 收藏后自动同步';

  @override
  String get pageLikedNeteaseEmptyHint => '在网易云 App 点亮红心后自动同步';

  @override
  String get pageLikedLoginTitle => '登录后查看我喜欢的歌曲';

  @override
  String get pageLikedKugouLoginDesc => '扫码登录酷狗，同步「我喜欢」收藏';

  @override
  String get pageLikedNeteaseLoginDesc => '扫码登录网易云，同步红心收藏';

  @override
  String get libraryScanDirs => '扫描目录';

  @override
  String get libraryScanDirsDesc => '管理本地扫描目录，添加后立即扫描';

  @override
  String get libraryMediaStats => '媒体统计';

  @override
  String get libraryMediaStatsDesc => '本地音乐库概况';

  @override
  String get libraryStatTracks => '曲目数';

  @override
  String get libraryStatDuration => '总时长';

  @override
  String get libraryStatSize => '总大小';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count 个';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h 小时 $m 分钟';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m 分钟';
  }

  @override
  String librarySeconds(Object s) {
    return '$s 秒';
  }

  @override
  String get librarySearchHint => '搜索本地曲目';

  @override
  String get libraryNoMatch => '没有匹配的曲目';

  @override
  String get libraryScanningFiles => '正在统计文件…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count 首$extra';
  }

  @override
  String get libraryEmptyWaitScan => '正在等待首次扫描';

  @override
  String get libraryEmpty => '本地音乐库为空';

  @override
  String get libraryEmptyScanHint => '点击下方按钮立即扫描';

  @override
  String get libraryEmptyAddHint => '添加音乐文件夹后即可扫描入库';

  @override
  String get libraryScanNow => '立即扫描';

  @override
  String get libraryAddFolder => '添加文件夹';

  @override
  String get menuLocateFile => '定位文件';

  @override
  String get menuLocateFileComingSoon => '打开文件管理器 Phase 2 接入';

  @override
  String get menuRemoveFromLibrary => '从曲库移除';

  @override
  String get playerBarCollapsePlayer => '收起播放器';

  @override
  String get playerBarHideLyrics => '隐藏歌词';

  @override
  String get playerBarShowLyrics => '显示歌词';

  @override
  String get playerPageNotPlaying => '未在播放';

  @override
  String get playerPageLoadHint => '加载源后开始播放';

  @override
  String get playerPageQualityMenu => '切换音质';

  @override
  String get pageHomeRankTitle => '排行榜';

  @override
  String get pageHomePlaylistSquare => '歌单广场';

  @override
  String get pageHomeHotArtists => '热门歌手';

  @override
  String get pageHomePlaylists => '推荐歌单';

  @override
  String get pageHomeNewAlbums => '新碟上架';

  @override
  String get pageHomeRankSubtitle => '各大榜单实时热歌';

  @override
  String get pageHomePlaylistSquareSubtitle => '发现更多精彩歌单';

  @override
  String get pageHomeArtistSubtitle => '热门歌手，圆形头像';

  @override
  String get pageHomeLoadFailed => '加载推荐失败';

  @override
  String get pageHomePlaylistsSubtitle => '根据你的口味为你推荐';

  @override
  String get pageHomeNewAlbumsSubtitle => '近期值得一听的新专辑';

  @override
  String get pageHomeHotArtistsSubtitle => '大家都在听';

  @override
  String get pageHomeDaily => '每日推荐';

  @override
  String get pageHomeDailyLoggedIn => '根据你的口味，为你精心挑选';

  @override
  String get pageHomeDailyLoginHint => '登录网易云账号后，每天为你更新';

  @override
  String get pageHomeDailyPlay => '播放今日推荐';

  @override
  String get pageHomeDailyLogin => '登录解锁每日推荐';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting，$name';
  }

  @override
  String get greetingLate => '夜深了';

  @override
  String get greetingMorning => '早上好';

  @override
  String get greetingAfternoon => '下午好';

  @override
  String get greetingEvening => '晚上好';

  @override
  String get greetingFallback => '今天想听点什么？';

  @override
  String get downloadDeleteTaskOnly => '仅删除任务';

  @override
  String get downloadDeleteWithMedia => '删除任务及媒体文件';

  @override
  String downloadSelectedCount(Object count) {
    return '已选 $count 项';
  }

  @override
  String get downloadSelectAll => '全选';

  @override
  String get downloadDeselectAll => '全不选';

  @override
  String get downloadPauseAll => '全部暂停';

  @override
  String get downloadResumeAll => '全部开始';

  @override
  String get downloadDeleteSelected => '删除所选';

  @override
  String get downloadExitSelect => '退出批量选择';

  @override
  String downloadActiveCount(Object count) {
    return '进行中 $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return '已完成 $count';
  }

  @override
  String get downloadOpenDir => '打开下载目录';

  @override
  String get downloadSelectMode => '批量选择';

  @override
  String get downloadEmpty => '暂无下载任务';

  @override
  String get downloadEmptyHint => '在歌曲上右键 → 下载，即可加入队列';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return '删除所选 $count 个任务';
  }

  @override
  String get downloadDeleteSelectedMessage => '删除所选任务并清空 .tmp 缓存；媒体文件精确匹配删除。';

  @override
  String get downloadClearTitle => '清空下载任务';

  @override
  String get downloadClearMessage => '删除全部任务并清空 .tmp 缓存；媒体文件精确匹配删除。';

  @override
  String get downloadCancelTooltip => '取消（删除任务并清缓存）';

  @override
  String get downloadResume => '恢复下载';

  @override
  String get downloadOpenDirTask => '打开所在目录';

  @override
  String get downloadDeleteTask => '删除任务';

  @override
  String get downloadDeleteWithMediaExact => '删除任务及媒体文件（精确匹配）';

  @override
  String get downloadStatusQueued => '排队中…';

  @override
  String get downloadStatusResolving => '解析下载地址…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return '下载中 $percent%（$received）$speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return '下载中…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return '已暂停（$received）';
  }

  @override
  String get downloadStatusPaused => '已暂停';

  @override
  String downloadStatusFailed(Object error) {
    return '失败：$error';
  }

  @override
  String get downloadStatusFailedUnknown => '失败：未知错误';

  @override
  String get downloadStatusCanceled => '已取消';

  @override
  String downloadStatusDone(Object size) {
    return '完成（$size）';
  }

  @override
  String get downloadStatusAlready => '文件已存在';

  @override
  String get pageHomeTitle => '发现';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsCatAppearance => '外观';

  @override
  String get settingsCatPlayback => '播放';

  @override
  String get settingsCatLyrics => '歌词';

  @override
  String get settingsCatPreset => '强迫症';

  @override
  String get settingsCatDownload => '下载';

  @override
  String get settingsCatStorage => '存储';

  @override
  String get settingsCatAbout => '关于';

  @override
  String get settingsAppearanceSubtitle => '主题模式 · 界面偏好';

  @override
  String get settingsPlaybackSubtitle => '音频引擎 · 播放行为';

  @override
  String get settingsLyricsSubtitle => '播放器歌词 · 桌面歌词';

  @override
  String get settingsPresetSubtitle => '播放过滤 · 歌词还原 · 列表标签';

  @override
  String get settingsDownloadSubtitle => '下载目录 · 并发 · 限速 · 音质 · 分组 · 文件名';

  @override
  String get settingsStorageSubtitle => '数据目录 · 数据库文件';

  @override
  String get settingsAboutSubtitle => '版本 · 项目信息';

  @override
  String get settingsCatDeveloper => '开发者';

  @override
  String get settingsDeveloperSubtitle => '开发者模式 · 隐藏接口';

  @override
  String get settingsDeveloperTitle => '开发者模式';

  @override
  String get settingsDeveloperMode => '开发者模式';

  @override
  String get settingsDeveloperModeOn => '已开启（下载接口可见）';

  @override
  String get settingsDeveloperModeOff => '已关闭（下载接口隐藏）';

  @override
  String get settingsDeveloperDownloadModule => '下载模块';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      '侧边栏「下载」入口、曲目右键「下载」与设置「下载」分类仅在开发者模式开启后显示。';

  @override
  String get settingsDeveloperNote => '开发者模式面向本地调试与自用，开启后请自行承担相关责任。';

  @override
  String get settingsDevFpsMonitor => 'FPS/内存监控浮层';

  @override
  String get settingsDevFpsMonitorDesc =>
      '右上角实时显示 FPS、平均帧耗时与进程内存（点击可收起）。默认关闭；关闭开发者模式时一并关闭。';

  @override
  String get settingsDeveloperEnabled => '开发者模式已开启';

  @override
  String get settingsDeveloperDisabled => '开发者模式已关闭';

  @override
  String get settingsDeveloperHoldHint => '长按 10 秒开启开发者模式（鼠标：按住不放）';

  @override
  String get settingsSearchHint => '搜索设置…';

  @override
  String settingsSearchNoResult(Object query) {
    return '未找到「$query」相关设置';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '匹配 $count 项';
  }

  @override
  String get settingsSectionTheme => '主题';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get settingsThemeModeDesc => '亮色 / 深色 / 跟随系统';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsThemeNote => '默认深色主题；「跟随系统」由系统外观决定。';

  @override
  String get settingsSectionAccent => '主题色';

  @override
  String get settingsAccentTitle => '主色种子';

  @override
  String settingsAccentSystem(Object color) {
    return '跟随系统主题色（$color）';
  }

  @override
  String get settingsAccentSystemFallback => '跟随系统主题色（读取失败，回退自定义）';

  @override
  String get settingsAccentDefault => '默认亮蓝（设计体系）';

  @override
  String get settingsAccentCustom => '自定义（按种子动态生成配色）';

  @override
  String get settingsAccentDefaultTooltip => '默认亮蓝';

  @override
  String get settingsAccentSystemTooltip => '跟随系统主题色';

  @override
  String get settingsAccentCustomTooltip => '自定义取色';

  @override
  String get settingsSectionLayout => '布局';

  @override
  String get settingsFloatingBar => '悬浮播放条';

  @override
  String get settingsFloatingBarOn => '底部居中圆角胶囊（毛玻璃 + 阴影）';

  @override
  String get settingsFloatingBarOff => '全宽停靠（默认）';

  @override
  String get settingsSectionFont => '界面字体';

  @override
  String get settingsFontTitle => '界面字体';

  @override
  String get settingsFontMiSans => 'MiSans（默认）';

  @override
  String get settingsFontNoto => 'Noto Sans SC（标准度量）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans SC（免费商用）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans SC';

  @override
  String get settingsFontHarmonyLabel => '鸿蒙黑体';

  @override
  String get settingsSectionLanguage => '界面语言';

  @override
  String get settingsLanguageTitle => '界面语言';

  @override
  String get settingsLanguageDesc => '切换界面显示语言';

  @override
  String get settingsLangSystem => '跟随系统';

  @override
  String get settingsSectionCover => '封面';

  @override
  String get settingsCoverRadius => '封面圆角';

  @override
  String get settingsCoverRadiusSharp => '直角（信息密度高）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return '${radius}px 圆角';
  }

  @override
  String get settingsCoverRadiusSharpLabel => '直角';

  @override
  String get settingsCoverRadiusRoundedLabel => '圆角';

  @override
  String get settingsCoverRadiusLargeLabel => '大圆角';

  @override
  String get settingsPickerTitle => '自定义主题色';

  @override
  String get settingsPickerHexLabel => '颜色值（#RRGGBB）';

  @override
  String get settingsApply => '应用';

  @override
  String get settingsSectionAudio => '音频';

  @override
  String get settingsPassthrough => '原音质直通（不转码）';

  @override
  String get settingsPassthroughOn => '保持源采样率（Hi-Res/无损不降质）';

  @override
  String get settingsPassthroughOff => '统一 48kHz 转码管线';

  @override
  String get settingsPassthroughNote =>
      '关闭转码保持源采样率播放，开启则统一 48kHz 输出；切换后自动重载当前曲目生效。';

  @override
  String get volumeMute => '静音';

  @override
  String get volumeUnmute => '取消静音';

  @override
  String get settingsSectionMemory => '记忆与启动';

  @override
  String get settingsSessionMemory => '会话记忆';

  @override
  String get settingsSessionMemoryOn => '记录播放队列、位置与模式，下次启动恢复现场';

  @override
  String get settingsSessionMemoryOff => '不记录播放现场，下次启动为空';

  @override
  String get settingsAutoPlay => '启动时自动播放';

  @override
  String get settingsAutoPlayNeedMemory => '需先开启「会话记忆」';

  @override
  String get settingsAutoPlayOn => '恢复上次会话并自动续播';

  @override
  String get settingsAutoPlayOff => '仅恢复播放现场，不自动续播';

  @override
  String get settingsSectionSpectrum => '频谱';

  @override
  String get settingsSpectrum => '频谱可视化';

  @override
  String get settingsSpectrumOn => '播放界面显示频谱柱（播放 0.65 / 暂停 0.15 透明度）';

  @override
  String get settingsSpectrumOff => '播放界面不渲染频谱';

  @override
  String get settingsSpectrumBarWidth => '频谱柱宽';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12，全屏播放器）';
  }

  @override
  String get settingsBarSpectrum => '播放条频谱';

  @override
  String get settingsSpectrumStyle => '频谱样式';

  @override
  String get settingsSpectrumStyleDesc => '频谱可视化效果（条形 / 波形 / 单向波形）';

  @override
  String get settingsSpectrumStyleBars => '条形';

  @override
  String get settingsSpectrumStyleWave => '波形';

  @override
  String get settingsSpectrumStyleWaveUp => '单向波形';

  @override
  String get settingsBarSpectrumOn => '播放条时间下方显示迷你频谱（无歌词或关闭迷你歌词时）';

  @override
  String get settingsBarSpectrumOff => '播放条不显示迷你频谱';

  @override
  String get settingsCoverBeatScale => '封面跟随节奏缩放';

  @override
  String get settingsCoverBeatScaleOn => '封面随鼓点轻微缩放';

  @override
  String get settingsCoverBeatScaleOff => '封面静止（仅播放/暂停缩放）';

  @override
  String get settingsTransitionStyle => '媒体信息切换动效';

  @override
  String get settingsTransitionStyleDesc => '切歌时封面与歌曲信息的过渡动画效果';

  @override
  String get settingsTransitionStyleScale => '缩放';

  @override
  String get settingsTransitionStyleSlide => '侧边滑动';

  @override
  String get settingsSectionShortcuts => '快捷键';

  @override
  String get settingsShortcutSpace => '空格';

  @override
  String get settingsShortcutSpaceDesc => '播放 / 暂停';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => '后退 / 前进 10 秒';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => '音乐库';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc => '返回（关闭弹窗 / 全屏播放器）';

  @override
  String get settingsSectionPlayerLyrics => '播放器歌词';

  @override
  String get settingsPlayerLyrics => '播放器内歌词';

  @override
  String get settingsPlayerLyricsOn => '全屏播放器右侧歌词（当前行高亮，可点击跳转）';

  @override
  String get settingsPlayerLyricsOff => '全屏播放器不显示歌词';

  @override
  String get settingsBarLyrics => '播放条歌词';

  @override
  String get settingsBarLyricsOn => '播放条时间下方显示当前歌词（过长自动滚动）';

  @override
  String get settingsBarLyricsOff => '播放条不显示迷你歌词';

  @override
  String get settingsShowTranslation => '显示翻译';

  @override
  String get settingsShowTranslationOn => '歌词翻译显示在原句后的括号内';

  @override
  String get settingsShowTranslationOff => '不显示歌词翻译';

  @override
  String get settingsSectionLyricStyle => '歌词样式';

  @override
  String get settingsLyricFontSize => '歌词字号';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（当前行放大高亮）';
  }

  @override
  String get settingsLyricLineHeight => '歌词行距';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（含行间距）';
  }

  @override
  String get settingsLyricPlayedColor => '已唱颜色';

  @override
  String get settingsLyricPlayedColorDesc => '当前行歌词高亮色';

  @override
  String get settingsLyricUnplayedColor => '未唱颜色';

  @override
  String get settingsLyricUnplayedColorDesc => '未播放行歌词颜色';

  @override
  String get settingsLyricsNote => '歌词样式仅作用于全屏播放器歌词';

  @override
  String get settingsSectionFilter => '播放过滤';

  @override
  String get settingsDjMode => '去™的 DJ';

  @override
  String get settingsDjModeOn => '世界清净了awa';

  @override
  String get settingsDjModeOff => '哎嘿嘿(ˉ﹃ˉ)';

  @override
  String get settingsSectionLyricsFilter => '歌词';

  @override
  String get settingsUncensor => '解锁脏话';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => '列表显示';

  @override
  String get settingsHideVip => '隐藏 VIP 标签';

  @override
  String get settingsHideVipOn => '列表不显示 VIP / 付费角标';

  @override
  String get settingsHideVipOff => '显示付费角标（VIP / EP）';

  @override
  String get settingsHideQuality => '隐藏音质标签';

  @override
  String get settingsHideQualityOn => '列表不显示音质角标';

  @override
  String get settingsHideQualityOff => '显示可用最高音质（Hi-Res / 无损 / HQ…）';

  @override
  String get settingsShowSubtitle => '显示副标题';

  @override
  String get settingsShowSubtitleOn => '歌名后展示别名，如 (Live)';

  @override
  String get settingsShowSubtitleOff => '列表不展示别名';

  @override
  String get settingsEnergySaving => '节能模式';

  @override
  String get settingsEnergySavingNote =>
      '开启后频谱取帧频率降至约 300ms 一帧（默认 100ms 基线），降低 CPU 占用；频谱渲染与插值不受影响，切换实时生效。';

  @override
  String get settingsEnergySavingOn => '当前为降帧模式';

  @override
  String get settingsEnergySavingOff => '当前为标准模式';

  @override
  String get settingsSearchEnergySavingSubtitle => '降低频谱取帧频率以节省 CPU';

  @override
  String get settingsPerformanceMode => '性能模式';

  @override
  String get settingsPerformanceModeOn => '当前为冻效模式';

  @override
  String get settingsPerformanceModeOff => '当前为动效模式';

  @override
  String get settingsSectionDir => '目录';

  @override
  String get settingsDownloadRootHint => '下载目录（回车保存）';

  @override
  String get settingsRestoreDefault => '恢复默认';

  @override
  String get settingsDownloadRootNote => '默认跟随媒体库目录；修改目录回车保存，进行中的下载任务会终止。';

  @override
  String get settingsSectionFilename => '文件名';

  @override
  String get settingsDownloadTemplateHint => '文件名模板（回车保存）';

  @override
  String get settingsDownloadTemplateNote =>
      '占位符：<artist> · <title> · <album>；只影响之后入队的任务，回车保存立即生效。';

  @override
  String get settingsSectionQuality => '音质';

  @override
  String get settingsDownloadQuality => '默认下载音质';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return '下载弹窗默认选中 $quality，档位不足时自动降级';
  }

  @override
  String get settingsDownloadQualityNote =>
      '档位从高到低：Hi-Res → 无损 → HQ → SQ → LQ，缺失时按此顺序自动降级。';

  @override
  String get settingsSectionConcurrent => '并发';

  @override
  String get settingsDownloadConcurrent => '同时下载数';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count 个并行任务（1~5）';
  }

  @override
  String get settingsDownloadGrouping => '目录分组';

  @override
  String get settingsGroupingFlat => '全部平铺在下载目录下';

  @override
  String get settingsGroupingPlatform => '按平台建子目录（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => '按歌手建子目录';

  @override
  String get settingsGroupingFlatLabel => '平铺';

  @override
  String get settingsGroupingPlatformLabel => '按平台';

  @override
  String get settingsGroupingArtistLabel => '按歌手';

  @override
  String get settingsSectionSpeedLimit => '限速';

  @override
  String get settingsDownloadSpeedLimit => '下载限速';

  @override
  String get settingsSpeedUnlimited => '不限速（默认）';

  @override
  String settingsSpeedLimited(Object speed) {
    return '限 $speed，实时生效';
  }

  @override
  String get settingsSpeedUnlimitedLabel => '不限速';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote => '限速实时生效，不打断在途任务（0.5 MB/s 步进，0 = 不限速）。';

  @override
  String get settingsSectionHistory => '记录';

  @override
  String get settingsDownloadHistoryLimit => '下载记录上限';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count 条（10~500）· 超上限自动淘汰最旧';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count 条';
  }

  @override
  String get settingsDownloadHistoryNote => '仅淘汰失败 / 已取消记录中最旧的，进行中任务不受影响。';

  @override
  String get settingsGroupingNote => '按歌手分组 v2 已支持（平铺 / 按平台 / 按歌手）。';

  @override
  String get settingsSectionFingerprint => '设备指纹';

  @override
  String get settingsFingerprintNote =>
      '下载器向酷狗 / 网易请求时携带的设备标识；首次启动生成后固定，不同用户互不相同。';

  @override
  String get settingsDownloadDynamicFingerprint => '动态设备指纹';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      '开启后设备标识每次启动随机生成（旧版行为），可能触发平台风控，默认关闭。';

  @override
  String get settingsResetFingerprint => '重置设备指纹';

  @override
  String get settingsResetFingerprintDesc =>
      '重置后本机在酷狗 / 网易看来是新设备，旧指纹下的在线状态可能失效。确定重置？';

  @override
  String get toastFingerprintReset => '已重置设备指纹';

  @override
  String get toastDownloadRootEmpty => '下载目录不能为空';

  @override
  String get toastDownloadRootUpdated => '已更新下载目录';

  @override
  String get toastTemplateEmpty => '文件名模板不能为空';

  @override
  String get toastTemplateUpdated => '已更新文件名模板';

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
  String get settingsSectionFileLocation => '文件位置';

  @override
  String get settingsDataDir => '数据目录';

  @override
  String get settingsLibraryDb => '媒体库数据库';

  @override
  String get settingsUserDb => '用户数据库（加密）';

  @override
  String get settingsLibraryDbLabel => '媒体库路径';

  @override
  String get settingsUserDbLabel => '用户库路径';

  @override
  String get settingsCopy => '复制';

  @override
  String toastCopied(Object label) {
    return '已复制$label';
  }

  @override
  String get settingsStorageNote =>
      '媒体库与用户数据物理拆分；路径可用环境变量 ARCHOERA_DATA_DIR 覆盖。';

  @override
  String get settingsSectionCache => '缓存管理';

  @override
  String get settingsCacheNote => '缓存用于加速浏览与播放，清除后会自动重建；不会影响曲库、历史与账号信息。';

  @override
  String get settingsCacheGroupDisk => '数据库缓存（磁盘）';

  @override
  String get settingsCacheGroupMem => '内存缓存（进程内）';

  @override
  String get settingsCacheLimitLyric => '歌词缓存上限';

  @override
  String get settingsCacheLimitCover => '封面图片缓存上限';

  @override
  String get settingsCacheLimitUnlimited => '无上限';

  @override
  String get settingsCacheNoLimitConfirmTitle => '取消缓存上限？';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      '无上限时歌词与封面图片缓存可无限制占用内存，可能造成内存压力与卡顿。确认取消上限？';

  @override
  String get settingsCacheNoLimitConfirm => '确认取消上限';

  @override
  String get settingsSongCache => '歌曲缓存';

  @override
  String get settingsSongCacheNote =>
      '播放过的在线歌曲会缓存到本地磁盘，重播直接读取（省流量、加速、断网可播）。超过上限按 LRU 自动淘汰最旧曲目；下限 16 MiB 可完整缓存一首 320kbps 高品曲目（约 2.4 MiB/分钟）。清除后自动重建，不影响曲库、历史与账号。';

  @override
  String get settingsSongCacheOn => '已开启，重播命中直接读取本地文件';

  @override
  String get settingsSongCacheOff => '已关闭，媒体缓存将不会保存到本地';

  @override
  String get settingsSongCacheLimitTitle => '缓存上限';

  @override
  String settingsCacheSongs(Object count) {
    return '$count 首';
  }

  @override
  String get settingsSearchSongCacheSubtitle => '在线歌曲磁盘缓存开关与 MiB 上限';

  @override
  String get settingsCacheLiked => '「我喜欢」列表缓存';

  @override
  String get settingsCacheLyric => '歌词内容缓存';

  @override
  String get settingsCacheLyricMatch => '歌词匹配缓存';

  @override
  String get settingsCacheLyricTtml => 'TTML 歌词缓存';

  @override
  String get settingsCacheCover => '封面图片缓存';

  @override
  String settingsCacheEntries(Object count) {
    return '$count 条';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count 张';
  }

  @override
  String get settingsCacheRefresh => '刷新';

  @override
  String get settingsCacheClear => '清除';

  @override
  String get settingsCacheClearAll => '清空全部';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '清除「$name」？';
  }

  @override
  String get settingsCacheClearConfirmDesc => '将删除该缓存下的全部数据，下次使用时自动重建，不可撤销。';

  @override
  String get settingsCacheClearAllConfirmTitle => '清空全部缓存？';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      '将删除上方全部缓存（内存与磁盘），不影响曲库、历史与账号信息。';

  @override
  String toastCacheCleared(Object name) {
    return '已清除$name缓存';
  }

  @override
  String get toastCacheAllCleared => '已清空全部缓存';

  @override
  String get settingsSecuritySection => '安全销毁';

  @override
  String get settingsSecurityNote =>
      '不可逆删除本机全部账号凭据与登录会话（流媒体服务器密码、网易云/酷狗登录态、本地 Subsonic 账号），并主动失效平台 token；不影响曲库、历史与下载文件。';

  @override
  String get settingsSecurityStreaming => '流媒体服务器凭据';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count 台服务器';
  }

  @override
  String get settingsSecurityStreamingDesc => '密码与访问令牌';

  @override
  String get settingsSecuritySession => '第三方账号会话';

  @override
  String get settingsSecuritySessionDesc => '网易云 / 酷狗 登录状态';

  @override
  String get settingsSecurityUserDb => '本地用户库';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic 账号与收藏数据';

  @override
  String get settingsSecurityLoggedIn => '已登录';

  @override
  String get settingsSecurityDestroy => '销毁';

  @override
  String get settingsSecurityDestroyAll => '一键销毁全部';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '销毁「$name」？';
  }

  @override
  String get settingsSecurityConfirmAllTitle => '确认销毁全部敏感数据？';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return '将主动失效相关平台 token、覆盖写入并删除文件，此操作不可恢复。输入「$word」以确认。';
  }

  @override
  String get settingsSecurityConfirmWord => '销毁';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return '输入「$word」';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return '已销毁：$name';
  }

  @override
  String get toastSecurityAllDestroyed => '全部敏感数据已销毁';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return '销毁失败，文件仍可能残留：$path';
  }

  @override
  String get settingsDeviceBindSection => '高级 · 设备绑定';

  @override
  String get settingsDeviceBindNote =>
      '增强型可选项（opt-in）：本机免密 + 设备变更走恢复口令，不依赖系统安全存储。开启将读取本机设备标识（仅存本地、不会上传）。默认关闭，普通用户使用 v1 加密已足够。';

  @override
  String get settingsDeviceBindSwitch => '设备绑定免密';

  @override
  String get settingsDeviceBindSwitchDesc => '本机自动解锁；换机/重装走恢复口令';

  @override
  String get settingsDeviceBindSwitchOffDesc =>
      '未启用。当前系统安全存储不可用，可开启设备绑定实现本机免密（无需口令）';

  @override
  String get settingsDeviceBindSwitchV1Desc =>
      '当前为 v1（系统安全存储）模式；开启将升级为设备绑定（免密 + 恢复口令，既有数据保留）';

  @override
  String get settingsDeviceBindSwitchV2Desc =>
      '当前为 v2（口令）模式；开启需先输入当前口令解锁，随后升级为设备绑定（本机免密）';

  @override
  String get settingsDeviceBindPrivacyTitle => '开启设备绑定免密？';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      '将读取本机设备标识（Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID）用于绑定，仅存储于本地，不会上传。注意：此操作不可回到当前 OS 免密模式——日后关闭设备绑定将回落为口令模式（每次启动需输入口令）。';

  @override
  String get settingsDeviceBindEnable => '开启';

  @override
  String get settingsDeviceBindRecoveryTitle => '设置恢复口令（可选）';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      '换机/重装后需用恢复口令解锁凭据。留空则不设置：设备变更后无法恢复（fail-closed，需销毁重建凭据）。';

  @override
  String get settingsDeviceBindRecoveryHint => '恢复口令';

  @override
  String get settingsDeviceBindSkip => '不设口令，直接开启';

  @override
  String get settingsDeviceBindChangeRecovery => '设置 / 修改恢复口令';

  @override
  String get settingsDeviceBindChangeRecoveryTitle => '设置新的恢复口令';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      '修改后旧口令立即失效。请务必记住新口令：换机/重装后凭据解锁将依赖它。';

  @override
  String get settingsDeviceBindRebind => '重新绑定当前设备';

  @override
  String get settingsDeviceBindRebindDesc => '用当前设备指纹重密封，旧指纹立即失效（换机恢复后使用）';

  @override
  String get settingsDeviceBindRebindTitle => '重新绑定当前设备？';

  @override
  String get settingsDeviceBindRebindConfirm => '立即重新绑定';

  @override
  String get settingsDeviceBindClose => '关闭设备绑定';

  @override
  String get settingsDeviceBindCloseDesc => '清除设备熵绑定，vault 转为口令模式';

  @override
  String get settingsDeviceBindCloseTitle => '关闭设备绑定？';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      '将删除设备熵绑定，vault 转为口令模式：此后每次会话需输入口令。该口令即新会话口令，请牢记。输入当前恢复口令以确认。';

  @override
  String get settingsDeviceBindCloseHint => '当前恢复口令';

  @override
  String get settingsDeviceBindRecoveryBanner => '检测到设备变更或熵文件损坏：凭据已锁定，需恢复口令解锁';

  @override
  String get settingsDeviceBindRecover => '恢复';

  @override
  String get settingsDeviceBindRecoverTitle => '输入恢复口令';

  @override
  String get settingsDeviceBindRecoverDesc => '用恢复口令解锁凭据；成功后建议立即重新绑定当前设备恢复免密。';

  @override
  String get settingsDeviceBindShowPassword => '显示 / 隐藏口令';

  @override
  String get toastDeviceBindEnabled => '设备绑定免密已开启';

  @override
  String get toastDeviceBindRecoverySet => '恢复口令已更新';

  @override
  String get toastDeviceBindRebound => '已重新绑定当前设备';

  @override
  String get toastDeviceBindClosed => '设备绑定已关闭，vault 已转为口令模式';

  @override
  String get toastDeviceBindRecoveryNeeded => '未设置恢复口令，无法关闭设备绑定';

  @override
  String toastDeviceBindCloseFailed(Object error) {
    return '关闭失败：$error';
  }

  @override
  String get toastDeviceBindRecovered => '凭据已恢复，可重新绑定本机恢复免密';

  @override
  String get toastDeviceBindRecoverFailed => '恢复口令错误或解锁失败，凭据保持锁定';

  @override
  String get settingsSchemeIntroTitle => '加密方案说明';

  @override
  String get settingsSchemeIntroDesc =>
      '登录凭据（cookie）由加密方案保护。已为你启用 LEGACY 方案（推荐）：主密钥存于操作系统安全存储，稳定可靠。如需更高安全性，可在「设置 → 凭据加密方案」切换到 Vault（实验性）——注意该方案切换会重建数据库并丢失全部登录凭据。';

  @override
  String get settingsSchemeIntroGotIt => '知道了，继续';

  @override
  String get settingsSchemeSection => '凭据加密方案';

  @override
  String get settingsSchemeNote =>
      '选择登录凭据的加密方案。LEGACY：操作系统安全存储加密，稳定可靠（推荐）；文件密钥：主密钥存本地 secret.key 文件，免 OS 钥匙串，供 Docker/无图形环境使用（本地文件单点风险）；Vault：2-of-2 双因子实验性方案，安全性更高但存在异常丢失 Cookie 风险。切换方案需重建数据库并重新登录。';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => '推荐';

  @override
  String get settingsSchemeCryptoDesc =>
      'cookie 由操作系统安全存储加密（Windows DPAPI / macOS 钥匙串 / Linux libsecret），稳定可靠。';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'LEGACY 方案：主密钥整体由操作系统安全存储保护，加密强度与可用性稳定，适合日常使用。';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => '兼容';

  @override
  String get settingsSchemeFileDesc =>
      '主密钥存本地 secret.key 文件（0600 权限），免 OS 钥匙串，供无图形环境的 Docker/服务器使用。本地文件单点：密钥文件泄露即凭据全泄露。';

  @override
  String get settingsSchemeFileModeDesc =>
      'FILK（文件密钥）方案：主密钥落盘 secret.key（0600 原子写），经典的服务端加密形态；仅在无 OS 钥匙串的 headless/Docker 环境使用。';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => '实验性';

  @override
  String get settingsSchemeVaultDesc =>
      '2-of-2 双因子加密（系统份额 + 用户份额缺一不可），抵御离线攻击更强，但存在异常丢失 Cookie 风险。';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Vault 方案：主密钥拆分为系统份额与用户份额，双因子缺一不可；可再选 v1 系统保护 / v2 口令保护 / v3 设备绑定加密等级。';

  @override
  String get settingsSchemeSwitchTitle => '切换加密方案？';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault 为实验性方案：切换后存在异常丢失 Cookie 的风险。';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'FILK 为兼容性降级方案：主密钥存于本地文件，一旦泄露全部凭据即暴露。仅限无 OS 钥匙串的 headless/Docker 环境使用。';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      '各方案加密数据结构不兼容，切换将销毁现有保险库并重建数据库，所有登录凭据（网易云 / 酷狗 / 流媒体账号）将丢失，需重新登录。';

  @override
  String get settingsSchemeSwitchKeep => '保持当前';

  @override
  String get settingsSchemeSwitchConfirm => '切换并重建';

  @override
  String get toastSchemeSwitched => '加密方案已切换，重启后生效';

  @override
  String get settingsVaultSection => '凭据加密';

  @override
  String get settingsVaultNote =>
      '选择凭据的加密保护等级：v1 系统保护（默认）/ v2 口令保护 / v3 设备绑定（增强项 opt-in，读取本机设备标识，仅存本地、不会上传）。v1 ↔ v2 可随时互切；v3 为终点档，关闭后回落为 v2。';

  @override
  String get settingsVaultModeV1 => 'v1 系统保护';

  @override
  String get settingsVaultModeV2 => 'v2 口令保护';

  @override
  String get settingsVaultModeV3 => 'v3 设备绑定';

  @override
  String get settingsVaultModeDescOs =>
      'v1 系统保护：凭据由操作系统安全存储加密（Windows DPAPI / macOS 钥匙串 / Linux libsecret），本机免密。';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 口令保护：凭据由口令加密，每次启动需输入口令解锁。可随时切回 v1 系统保护。';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 设备绑定：本机免密，设备变更时需恢复口令解锁。不可直接降回 v1——关闭后将回落为 v2 口令模式。';

  @override
  String get settingsVaultModeDescUnknown => '加密等级读取中…';

  @override
  String get settingsVaultSwitchToPasswordTitle => '切换到口令保护（v2）';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      '凭据将改由口令加密保护，每次启动需输入口令。主密钥与已有数据保留，此操作可随时切回系统保护（v1）。';

  @override
  String get settingsVaultSwitchToPasswordNewHint => '设置新口令';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint => '再次输入新口令';

  @override
  String get settingsVaultSwitchToPasswordMismatch => '两次输入不一致';

  @override
  String get settingsVaultSwitchToOsTitle => '切换回系统保护（v1）';

  @override
  String get settingsVaultSwitchToOsDesc =>
      '凭据将改由操作系统安全存储保护，无需再输入口令。此操作可随时切回口令保护（v2）。';

  @override
  String get settingsVaultNeedUnlockFirst => '当前口令保护未解锁：请先解锁后再切换';

  @override
  String get settingsVaultV3NoDirectV1 =>
      '设备绑定（v3）不可直接降回 v1：请先关闭设备绑定，回落为 v2 口令模式';

  @override
  String get settingsVaultCloseV3PasswordTitle => '关闭设备绑定：设置新口令';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      '设备绑定开启时未设置恢复口令（本机免密），关闭后将转为口令保护（v2）：请设置新的解锁口令。主密钥与已有数据保留，此口令每次启动都需输入。';

  @override
  String get toastVaultSwitchedToPassword => '已切换到口令保护（v2）';

  @override
  String get toastVaultSwitchedToOs => '已切换回系统保护（v1）';

  @override
  String get settingsVaultShareBrokenBanner =>
      '凭据保险库份额不配对：存储后端不符或份额缺失，本地凭据无法解密。需销毁重建后重新登录。';

  @override
  String get settingsVaultShareBrokenRebuild => '销毁重建';

  @override
  String get settingsVaultRestartTitle => '需要重启应用';

  @override
  String get settingsVaultRestartDesc =>
      '加密等级已切换成功。为保证数据库完整性与各模块状态一致，请重启应用生效。若为口令保护模式（v2），重启后将要求输入口令解锁，解锁前登录态与流媒体凭据暂不可用（显示为未登录）；重启期间播放与下载会中断。';

  @override
  String get settingsVaultRestartNow => '立即重启';

  @override
  String get settingsVaultRestartLater => '稍后重启';

  @override
  String get vaultCrashTitle => '凭据模块异常退出';

  @override
  String get vaultCrashDesc => '凭据保险库进程意外终止，本地凭据可能已暴露。建议重新登录或销毁 vault 以重建凭据。';

  @override
  String get vaultCrashReset => '销毁并重建';

  @override
  String get vaultCrashDismiss => '知道了';

  @override
  String get vaultVersionTitle => '凭据保险库版本异常';

  @override
  String get vaultVersionDesc =>
      '检测到凭据保险库组件异常：其二进制副本可能已被替换或非官方构建，本地凭据可能已暴露。已删除异常副本并拒绝解密。请退出并重新安装应用。';

  @override
  String get vaultVersionExit => '退出';

  @override
  String get vaultVersionReasonReplaced =>
      '检测到 vault 二进制被替换或非官方构建，已删除异常副本并拒绝解密。';

  @override
  String get vaultVersionReasonMarkerMissing => 'vault 握手应答缺少官方构建标记。';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'vault 构建标记与官方产物不符，已删除异常副本并拒绝解密。';

  @override
  String get vaultUnlockTitle => '解锁凭据保险库';

  @override
  String get vaultUnlockDesc => '凭据保险库为口令保护模式（v2）。请输入口令以解锁本地登录凭据与流媒体账号。';

  @override
  String get vaultUnlockHint => '口令';

  @override
  String get vaultUnlockConfirm => '解锁';

  @override
  String get vaultUnlockSkip => '暂不解锁';

  @override
  String get vaultUnlockFailed => '口令错误，请重试';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsVersionUnknown => 'v未知 · Flutter 桌面端';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter 桌面端';
  }

  @override
  String get settingsAudioEngine => '音频引擎';

  @override
  String get settingsAudioEngineDesc => '内置 C 引擎（miniaudio）· 原生 FFI';

  @override
  String get settingsSubsonicServer => 'Subsonic 服务端';

  @override
  String get settingsSubsonicDesc => 'Go FFI · 曲库自托管';

  @override
  String get settingsAboutDesc => '自研音乐播放器：本地曲库、直连音源、自托管 Subsonic、原生音频引擎。';

  @override
  String get settingsSectionDeclaration => '软件声明';

  @override
  String get settingsDeclineText =>
      '本软件（ArchoeraMusic）是一款免费、开源的桌面音乐播放器，为个人学习研究用途，非商业软件。使用前请阅读以下声明：\n\n';

  @override
  String get settingsDecline1Title => '一、软件性质\n';

  @override
  String get settingsDecline1Body =>
      '本软件为第三方客户端，与各音乐平台及其官方客户端无任何关联、合作或授权关系；不以营利为目的，不接受任何商业合作、广告或捐赠。如需更完善的功能，请下载官方客户端体验。\n\n';

  @override
  String get settingsDecline2Title => '二、内容来源与版权\n';

  @override
  String get settingsDecline2Body =>
      '本软件自身不提供、不存储、不分发任何音乐内容。音频、歌词、封面等均来自您的本地文件或各音乐平台公开接口，其版权归原权利人及平台所有，本软件不主张任何所有权。\n\n';

  @override
  String get settingsDecline3Title => '三、版权数据处理义务\n';

  @override
  String get settingsDecline3Body =>
      '使用过程中产生的版权数据（播放链接、歌词、封面等）仅供您个人试听与学习研究，请勿用于商业或公开传播；建议在产生后 24 小时内清除。如需长期欣赏，请通过正版渠道购买或订阅，支持正版音乐。\n\n';

  @override
  String get settingsDecline4Title => '四、使用限制\n';

  @override
  String get settingsDecline4Body =>
      '请勿利用本软件从事商业行为、批量抓取、爬取或转售内容；请勿在违反当地法律法规或相关平台服务条款的情况下使用本软件；请勿绕过在线平台的技术保护措施、访问控制或服务条款。\n\n';

  @override
  String get settingsDecline5Title => '五、免责声明\n';

  @override
  String get settingsDecline5Body =>
      '本软件按「现状」提供，不对其作出任何明示或默示的保证。因使用或无法使用本软件，或因在线平台接口变更、账号限制、功能失效等产生的任何直接或间接损失，均由使用者自行承担。\n\n';

  @override
  String get settingsDeclineFooter =>
      '本软件仅用于技术探索与研究。如相关平台认为本软件不妥，可随时联系开发者进行调整或移除。';

  @override
  String get settingsSectionFontCredits => '字体署名';

  @override
  String get settingsFontCreditsText =>
      '本软件内置以下字体：\n· Noto Sans CJK SC（SIL Open Font License 1.1）\n· MiSans（© Xiaomi，依据《MiSans 字体知识产权许可协议》授权使用）\n· HarmonyOS Sans SC（© Huawei，依据《HarmonyOS Sans 字体许可协议》授权使用）';

  @override
  String get commonNoLyrics => '暂无歌词';

  @override
  String commonTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String get settingsSearchColorTitle => '已唱 / 未唱颜色';

  @override
  String get settingsSearchColorSubtitle => '歌词行高亮与普通行颜色';

  @override
  String get settingsSearchDesktopLyricsTitle => '桌面歌词';

  @override
  String get settingsSearchDesktopLyricsSubtitle => '置顶独立歌词窗';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => '文件名模板';

  @override
  String get settingsSearchAccentSubtitle => '自定义主色种子 · 色板';

  @override
  String get settingsThemeSource => '主题色来源';

  @override
  String get settingsThemeSourceDesc => '主题色的获取方式';

  @override
  String get settingsThemeSourceDefault => '跟随系统';

  @override
  String get settingsThemeSourceCustom => '自定义主色';

  @override
  String get settingsThemeSourceCover => '跟随封面';

  @override
  String get settingsThemeSourceSolid => '无主题色';

  @override
  String get settingsThemeSourceCustomHint => '选取主色种子，主/次色由它动态生成';

  @override
  String get settingsThemeSourceCoverHint => '实时从当前播放封面提取主色（不可用时回退默认色）';

  @override
  String get settingsGlobalTint => '全局着色';

  @override
  String get settingsGlobalTintDesc => '将主题色应用到全局界面';

  @override
  String get settingsGlobalTintNote => '存在主题色（自定义/跟随封面）时生效；图片背景模式下强制开启。';

  @override
  String get settingsSectionStyle => '背景风格';

  @override
  String get settingsAppearanceStyle => '外观风格';

  @override
  String get settingsAppearanceStyleDesc => '应用主背景的呈现方式';

  @override
  String get settingsAppearanceStyleSolid => '纯色背景';

  @override
  String get settingsAppearanceStyleImage => '自定义图片';

  @override
  String get settingsBackgroundImage => '背景图片';

  @override
  String get settingsBackgroundImageDesc => '选择本地图片作为应用背景；图片模式强制暗色 + 全局着色';

  @override
  String get settingsBackgroundPick => '选择图片';

  @override
  String get settingsBackgroundReplace => '更换';

  @override
  String get settingsBackgroundClear => '清除';

  @override
  String get settingsBackgroundBlur => '背景模糊';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return '对背景图片应用高斯模糊（${blur}px）';
  }

  @override
  String get settingsBackgroundDim => '遮罩浓度';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return '叠加的黑色遮罩透明度（$dim%），越高前景越易读';
  }

  @override
  String get settingsBackgroundScale => '缩放大小';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return '背景图的缩放倍数（${scale}x）';
  }

  @override
  String get settingsSidebarCollapsed => '折叠侧边栏';

  @override
  String get settingsSidebarCollapsedDesc => '将侧边栏折叠为图标模式';

  @override
  String get settingsSidebarNavStyle => '导航高亮动效';

  @override
  String get settingsSidebarNavStyleDesc => '切换侧边栏导航高亮指示器的动画风格';

  @override
  String get settingsSidebarNavStyleDefault => '静态';

  @override
  String get settingsSidebarNavStyleAnimated => '滑动';

  @override
  String get settingsRouteTransition => '页面切换动效';

  @override
  String get settingsRouteTransitionDesc => '切换页面时的过渡动画效果';

  @override
  String get settingsRouteTransitionNone => '无';

  @override
  String get settingsRouteTransitionFade => '淡入淡出';

  @override
  String get settingsRouteTransitionSlide => '滑动';

  @override
  String get settingsRouteTransitionZoom => '缩放';

  @override
  String get settingsSearchThemeSourceSubtitle => '默认主题色 · 自定义主色 · 跟随封面 · 无主题色';

  @override
  String get settingsSearchGlobalTintSubtitle => '将主题色应用到全局界面';

  @override
  String get settingsSearchBackgroundSubtitle => '纯色 / 图片 · 模糊 · 遮罩 · 缩放';

  @override
  String get settingsSearchSidebarSubtitle => '折叠侧边栏 · 静态 / 滑动高亮';

  @override
  String get settingsSearchRouteTransitionSubtitle => '无 · 淡入淡出 · 滑动 · 缩放';

  @override
  String get settingsSearchFloatingBarSubtitle => '底部悬浮胶囊 · 全宽停靠';

  @override
  String get settingsSearchFontSubtitle => 'MiSans · HarmonyOS Sans SC';

  @override
  String get settingsSearchLanguageSubtitle => '跟随系统 · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle => '直角 · 圆角 · 大圆角';

  @override
  String get settingsSectionWeather => '天气';

  @override
  String get settingsWeather => '天气组件';

  @override
  String get settingsWeatherDesc => '顶栏头像左侧显示微型天气（图标 + 温度）';

  @override
  String get settingsWeatherAutoLocate => '自动定位';

  @override
  String get settingsWeatherAutoLocateDesc => '按网络 IP 获取大致位置查询天气（涉及隐私，默认关闭）';

  @override
  String get settingsWeatherCity => '手动城市';

  @override
  String get settingsWeatherCityHint => '填写城市名后不再进行 IP 定位（例如：杭州）';

  @override
  String get settingsWeatherNote =>
      '隐私说明：天气数据来自 Open-Meteo（免费、无需密钥）。开启「自动定位」时，本机 IP 会发送至 ip-api.com 换取大致位置，仅用于查询天气、不落盘。天气组件与定位默认均关闭。';

  @override
  String get settingsSearchWeatherSubtitle => '顶栏显示微型天气组件（图标 + 温度）';

  @override
  String get weatherRefresh => '刷新天气';

  @override
  String get weatherNoLocation => '请在设置中填写城市或开启自动定位';

  @override
  String get weatherUnavailable => '天气获取失败，点击重试';

  @override
  String get settingsSearchPassthroughSubtitle => '不转码 · 48kHz 转码管线';

  @override
  String get settingsSearchSessionMemorySubtitle => '记录/恢复播放现场';

  @override
  String get settingsSearchAutoPlaySubtitle => '自动续播开关';

  @override
  String get settingsSearchSpectrumSubtitle => '播放界面频谱开关 · 透明度';

  @override
  String get settingsSearchSpectrumWidthSubtitle => '1~12px 柱宽调节';

  @override
  String get settingsSearchPlayerLyricsSubtitle => '全屏播放器歌词显示';

  @override
  String get settingsSearchLyricFontSizeSubtitle => '14~28px 播放器歌词字号';

  @override
  String get settingsSearchLyricLineHeightSubtitle => '42~64px 行高调节';

  @override
  String get settingsSearchUncensorSubtitle => '还原歌词中被星号遮盖的词';

  @override
  String get settingsSearchHideVipSubtitle => '歌曲列表 VIP / 付费角标隐藏';

  @override
  String get settingsSearchHideQualitySubtitle => '歌曲列表音质角标隐藏';

  @override
  String get settingsSearchSubtitleSubtitle => '歌曲列表展示别名（如 (Live)）';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      '下载保存位置（默认 ~/Music/ArchoeraMusic）';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> 占位符可配置';

  @override
  String get settingsSearchConcurrentSubtitle => '1~5 个并行下载任务';

  @override
  String get settingsSearchSpeedLimitSubtitle => '不限速 · 0.5~20 MB/s 实时生效';

  @override
  String get settingsSearchQualitySubtitle => 'Hi-Res · 无损 · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle => '平铺 · 按平台 · 按歌手';

  @override
  String get settingsSearchHistoryLimitSubtitle => '超上限自动淘汰最旧（10~500）';

  @override
  String get settingsSearchStorageSubtitle => '媒体库 · 用户数据库路径';

  @override
  String get settingsSearchAboutSubtitle => '音频引擎 · Subsonic 服务端';

  @override
  String get qualityLossless => '无损';

  @override
  String get repeatModeList => '列表循环';

  @override
  String get repeatModeOne => '单曲循环';

  @override
  String get commonUnknownTrack => '未知名歌曲';

  @override
  String get commonAnonymousUser => '匿名用户';

  @override
  String get commonCanceled => '已取消';

  @override
  String get commonILike => '我喜欢';

  @override
  String get sidebarStreaming => '流媒体';

  @override
  String get settingsCatMediaSource => '媒体源';

  @override
  String get settingsMediaSourceSubtitle =>
      '流媒体服务器（Subsonic / Jellyfin / Emby）';

  @override
  String get settingsCatScrape => '刮削';

  @override
  String get settingsScrapeSubtitle => '多源元数据补齐 · 封面 / 歌词 / 标签';

  @override
  String get settingsSectionScrapeDirs => '刮削目录';

  @override
  String get settingsScrapeDirsHint => '每行一个目录；留空跟随媒体库扫描目录';

  @override
  String get settingsScrapeDirsEmptyNote => '未配置刮削目录，刮削时将跟随媒体库扫描目录。';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return '当前生效目录：$dirs';
  }

  @override
  String get settingsSectionScrapeSources => '数据源';

  @override
  String get settingsScrapeSourceMusicBrainz => 'MusicBrainz';

  @override
  String get settingsScrapeSourceDeezer => 'Deezer';

  @override
  String get settingsScrapeSourceItunes => 'iTunes';

  @override
  String get settingsScrapeSourceNetease => '网易云音乐';

  @override
  String get settingsScrapeSourceQQMusic => 'QQ 音乐';

  @override
  String get settingsScrapeSourceKugou => '酷狗音乐';

  @override
  String get settingsScrapeSourceKuwo => '酷我音乐';

  @override
  String get settingsScrapeSourceMigu => '咪咕音乐';

  @override
  String get settingsScrapeSourceAcoustID => 'AcoustID（音频指纹）';

  @override
  String get settingsScrapeSourceDesc => '开启后参与多源查询、相似度比对与评分合并';

  @override
  String get settingsSectionScrapeProgress => '刮削进度';

  @override
  String get settingsScrapeStart => '开始刮削';

  @override
  String get settingsScrapeCancel => '取消刮削';

  @override
  String get settingsScrapeScanning => '正在扫描目录…';

  @override
  String settingsScrapeCurrent(Object file) {
    return '正在处理：$file';
  }

  @override
  String get settingsScrapeSuccess => '成功';

  @override
  String get settingsScrapeFailed => '失败';

  @override
  String get settingsScrapeSkipped => '跳过';

  @override
  String get settingsScrapeNotFound => '未匹配';

  @override
  String get settingsScrapeIdle => '尚未刮削，点击下方按钮开始。';

  @override
  String get settingsScrapeNoDirs => '没有可刮削的目录，请先配置刮削目录或媒体库扫描目录。';

  @override
  String get settingsScrapeDone => '刮削完成';

  @override
  String get settingsScrapeCanceled => '刮削已取消';

  @override
  String get toastScrapeNoDirs => '没有可刮削的目录';

  @override
  String get toastScrapeDirsUpdated => '刮削目录已保存';

  @override
  String get toastScrapeStarted => '已开始刮削';

  @override
  String get commonDelete => '删除';

  @override
  String get commonSave => '保存';

  @override
  String get commonConfirm => '确定';

  @override
  String get streamingHint => '媒体源';

  @override
  String get streamingHintDetail =>
      '添加流媒体服务器，浏览并播放服务器上的音乐（支持 Subsonic 家族 / Jellyfin / Emby，含本机内置 Subsonic 服务端）。';

  @override
  String get streamingServerAdd => '添加服务器';

  @override
  String get streamingEmptyNoServer => '还没有流媒体服务器';

  @override
  String get streamingEmptyAddHint => '点击上方按钮添加一个服务器';

  @override
  String get streamingServerConnected => '已连接';

  @override
  String get streamingServerDisconnected => '未连接';

  @override
  String get streamingServerLastConnected => '最近连接';

  @override
  String get streamingServerDisconnect => '断开连接';

  @override
  String get streamingToastDisconnected => '已断开服务器连接';

  @override
  String get streamingServerConnect => '连接';

  @override
  String streamingToastConnected(Object name) {
    return '已连接 $name';
  }

  @override
  String get streamingServerConnectFailed => '连接失败';

  @override
  String get streamingServerEdit => '编辑';

  @override
  String get streamingServerDeleteConfirmTitle => '删除服务器';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return '确定删除服务器「$name」吗？';
  }

  @override
  String get streamingServerRemoved => '服务器已删除';

  @override
  String get streamingServerErrorNameEmpty => '请输入服务器名称';

  @override
  String get streamingServerErrorHostEmpty => '请输入服务器地址';

  @override
  String get streamingServerErrorPortInvalid => '端口无效（1~65535）';

  @override
  String get streamingServerErrorUsernameEmpty => '请输入用户名';

  @override
  String get streamingServerErrorPasswordEmpty => '请输入密码';

  @override
  String get streamingServerAdded => '服务器已添加';

  @override
  String get streamingServerUpdated => '服务器已更新';

  @override
  String get streamingServerType => '类型';

  @override
  String get streamingServerName => '名称';

  @override
  String get streamingServerNamePlaceholder => '例如：我的 Navidrome';

  @override
  String get streamingServerHost => '服务器地址';

  @override
  String get streamingServerHostPlaceholder => '例如：192.168.1.10:4533';

  @override
  String get streamingServerPort => '端口';

  @override
  String get streamingServerPortNote =>
      '默认端口为 4533（Subsonic）/ 8096（Jellyfin）；留空自动匹配。';

  @override
  String get streamingServerLocalTitle => '本机内置服务端';

  @override
  String get streamingServerLocalDesc => '使用内置 Subsonic 服务端（本机媒体库）';

  @override
  String get streamingServerUsername => '用户名';

  @override
  String get streamingServerPassword => '密码';

  @override
  String get streamingServerTestOk => '连接成功';

  @override
  String get streamingServerTestFail => '连接失败';

  @override
  String get streamingServerTest => '测试连接';

  @override
  String get streamingTabsSongs => '歌曲';

  @override
  String get streamingTabsAlbums => '专辑';

  @override
  String get streamingTabsArtists => '歌手';

  @override
  String get streamingTabsPlaylists => '歌单';

  @override
  String get streamingEmptyGoToSettings => '去设置';

  @override
  String get streamingEmptyNotConnected => '未连接到任何服务器';

  @override
  String streamingTotalSongs(Object count) {
    return '$count 首歌曲';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count 张专辑';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count 位歌手';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count 个歌单';
  }

  @override
  String get streamingEmptyNoResults => '没有匹配的结果';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count 首歌曲';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count 张专辑';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count 首歌曲';
  }
}

/// The translations for Chinese, as used in China (`zh_CN`).
class AppLocalizationsZhCn extends AppLocalizationsZh {
  AppLocalizationsZhCn() : super('zh_CN');

  @override
  String get menuTrackDetail => '媒体详细信息';

  @override
  String get trackDetailDuration => '时长';

  @override
  String get trackDetailArtist => '歌手';

  @override
  String get trackDetailAlbum => '专辑';

  @override
  String get trackDetailSource => '来源';

  @override
  String get trackDetailPath => '路径';

  @override
  String get trackDetailFileSize => '文件大小';

  @override
  String get trackDetailCodec => '编码';

  @override
  String get trackDetailSampleRate => '采样率';

  @override
  String get trackDetailBitDepth => '位深';

  @override
  String get trackDetailBitrate => '比特率';

  @override
  String get trackDetailChannels => '声道';

  @override
  String get trackSourceLocal => '本地文件';

  @override
  String get trackSourceStreaming => '流媒体';

  @override
  String get trackDetailQuality => '音质';

  @override
  String get batchSelectAll => '全选';

  @override
  String get batchInvert => '反选';

  @override
  String get batchPlay => '播放所选';

  @override
  String get batchAddQueue => '加入队列';

  @override
  String get batchDownload => '批量下载';

  @override
  String get batchExit => '退出多选';

  @override
  String get batchSelectHint => '批量选择';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '已加入播放队列 $count 首';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '已加入下载队列 $count 首';
  }

  @override
  String get settingsBarEnhancedLyrics => '播放条高级歌词';

  @override
  String get settingsBarEnhancedLyricsOn => '歌词含逐字时间轴时显示卡拉OK高亮';

  @override
  String get settingsBarEnhancedLyricsOff => '播放条始终显示普通歌词';

  @override
  String get settingsSectionClose => '关闭应用';

  @override
  String get settingsSectionPower => '节能';

  @override
  String get settingsPowerSaver => '节能模式';

  @override
  String get settingsPowerSaverOn => '后台自动降帧（最小化 5 FPS，失焦/熄屏 1 FPS）';

  @override
  String get settingsPowerSaverOff => '始终满帧渲染';

  @override
  String get settingsSuppressSleep => '禁用系统休眠';

  @override
  String get settingsSuppressSleepOn => '播放时保持系统唤醒，防止后台播放中断';

  @override
  String get settingsSuppressSleepOff => '系统可能按空闲计划休眠';

  @override
  String get settingsPowerSaverNote =>
      '节能模式监听窗口状态事件自动降帧，无需轮询；窗口不可见或显示器关闭时，渲染引擎本身已停止绘制。「禁用系统休眠」仅在播放中生效。';

  @override
  String get settingsCloseBehavior => '关闭应用时';

  @override
  String get settingsCloseBehaviorAsk => '每次询问';

  @override
  String get settingsCloseBehaviorBackground => '后台播放';

  @override
  String get settingsCloseBehaviorQuit => '直接退出';

  @override
  String get commonCloseConfirmTitle => '退出应用';

  @override
  String get commonCloseConfirmMessage => '关闭主窗口后将';

  @override
  String get commonCloseConfirmRemember => '记住我的选择，不再询问';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => '网易云音乐';

  @override
  String get brandKugou => '酷狗音乐';

  @override
  String get commonBack => '返回';

  @override
  String get commonCancel => '取消';

  @override
  String get commonClose => '关闭';

  @override
  String get commonDefault => '默认';

  @override
  String get commonGoLogin => '去登录';

  @override
  String get commonLike => '喜欢';

  @override
  String get commonLoading => '加载中';

  @override
  String get commonLossless => '无损';

  @override
  String get commonOriginal => '原唱';

  @override
  String get commonMore => '更多';

  @override
  String get commonNext => '下一首';

  @override
  String get commonNoMore => '没有更多了';

  @override
  String get commonPrevious => '上一首';

  @override
  String get commonSettings => '全局设置';

  @override
  String get commonUnknownAlbum => '未知专辑';

  @override
  String get commonUnknownArtist => '未知歌手';

  @override
  String get commonUnlike => '取消喜欢';

  @override
  String get downloadQualityTitle => '下载音质';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return '获取$platform下载链接需登录，未登录只能试听，无法下载完整音质。\n\n请先登录$platform账号后重试。';
  }

  @override
  String get downloadRequiresLoginTitle => '下载需要登录';

  @override
  String get menuComment => '查看评论';

  @override
  String get menuDownload => '下载';

  @override
  String get menuLike => '添加到收藏';

  @override
  String get menuPlay => '播放';

  @override
  String get menuPlayNext => '下一首播放';

  @override
  String get menuRemoveFromQueue => '从队列移除';

  @override
  String get menuUnlike => '取消收藏';

  @override
  String get navHeaderAccount => '账号';

  @override
  String get navHeaderComingSoon => '敬请期待';

  @override
  String navHeaderKugouId(Object id) {
    return '酷狗 $id';
  }

  @override
  String get navHeaderKugouMusic => '酷狗音乐';

  @override
  String get navHeaderLoginAccount => '登录账号（网易云 / 酷狗）';

  @override
  String get navHeaderLogout => '退出登录';

  @override
  String get navHeaderNeteaseAccount => '网易云账号';

  @override
  String get navHeaderNeteaseMusic => '网易云音乐';

  @override
  String get navHeaderQqMusic => 'QQ 音乐';

  @override
  String get navHeaderQrLogin => '扫码登录';

  @override
  String get navHeaderSearchHint => '搜索歌曲 / 歌手 / 歌单';

  @override
  String get navHeaderThemeDark => '主题：暗色';

  @override
  String get navHeaderThemeLight => '主题：亮色';

  @override
  String get navHeaderThemeSystem => '主题：跟随系统';

  @override
  String get playerBarBuffering => '加载中…';

  @override
  String get playerBarIdleHint => '点击侧边栏或加载源开始播放';

  @override
  String get playerBarOpenPlayer => '打开播放页';

  @override
  String get playerBarPlayPause => '播放/暂停';

  @override
  String get playerBarPlaylist => '播放列表';

  @override
  String get playerBarUntitled => '未命名';

  @override
  String get queueClear => '清空队列';

  @override
  String get queueEmpty => '队列为空';

  @override
  String get queueEmptyHint => '在列表中选择歌曲后将出现在这里';

  @override
  String get queueRepeatList => '列表循环';

  @override
  String get queueRepeatMode => '播放模式';

  @override
  String get queueRepeatOne => '单曲循环';

  @override
  String get queueShuffle => '随机播放';

  @override
  String get queueShuffleOff => '关闭随机播放';

  @override
  String get queueTitle => '播放队列';

  @override
  String queueTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String get sidebarBackHome => '返回首页';

  @override
  String get sidebarCollapse => '折叠侧边栏';

  @override
  String get sidebarDownload => '下载';

  @override
  String get sidebarExpand => '展开侧边栏';

  @override
  String get sidebarFavorites => '收藏';

  @override
  String get sidebarGroupMusic => '音乐';

  @override
  String get sidebarGroupPersonal => '个人';

  @override
  String get sidebarHistory => '历史';

  @override
  String get sidebarHome => '首页';

  @override
  String get sidebarLibrary => '音乐库';

  @override
  String get sidebarLiked => '我喜欢';

  @override
  String get songListAlbum => '专辑';

  @override
  String get songListDuration => '时长';

  @override
  String get songListTitle => '标题';

  @override
  String get songListScrollTop => '回到顶部';

  @override
  String get songListLocatePlaying => '定位播放位置';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return '已加入下载队列：$quality';
  }

  @override
  String get toastAddedToQueue => '已加入播放队列';

  @override
  String get toastDownloadEngineNotReady => '下载引擎未就绪，请稍后再试';

  @override
  String get toastLiked => '已添加到收藏';

  @override
  String get toastLoginRequiredKugou => '操作失败（请确认已登录酷狗账号）';

  @override
  String get toastLoginRequiredNetease => '操作失败（请确认已登录网易云账号）';

  @override
  String get toastNoQualityInfo => '该曲目无可用音质信息，无法下载';

  @override
  String get toastUnliked => '已取消收藏';

  @override
  String get commonClear => '清除';

  @override
  String get commonEmptyContent => '暂无内容';

  @override
  String commonLoadFailed(Object msg) {
    return '加载失败：$msg';
  }

  @override
  String get commonRetry => '重试';

  @override
  String get commentDuplicate => '请勿重复发送相同内容';

  @override
  String get commentEmpty => '暂时没有评论';

  @override
  String get commentHot => '热门';

  @override
  String get commentInputEmpty => '评论内容不能为空';

  @override
  String get commentInputHint => '说点什么…';

  @override
  String get commentLatest => '最新';

  @override
  String commentLoginRequired(Object platform) {
    return '发送评论需要登录$platform账号';
  }

  @override
  String commentNotFound(Object platform) {
    return '未找到该歌曲的$platform评论';
  }

  @override
  String get commentPublished => '评论已发布';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user：$text';
  }

  @override
  String get commentSend => '发送';

  @override
  String commentSendFailed(Object msg) {
    return '发送失败：$msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$month月$day日 $time';
  }

  @override
  String get commentTitle => '歌曲评论';

  @override
  String get folderAdd => '添加';

  @override
  String get folderBrowse => '浏览';

  @override
  String get folderEmpty => '尚未添加扫描目录，点击下方按钮添加';

  @override
  String get folderExists => '目录已存在或无效';

  @override
  String get folderInvalid => '目录不存在、已存在或为空';

  @override
  String get folderPathHint => '输入目录绝对路径';

  @override
  String get folderRemove => '移除';

  @override
  String get folderRemoveDescription => '移除后不再扫描该目录，已入库曲目保留。';

  @override
  String get folderRemoveTitle => '移除扫描目录';

  @override
  String get loginFetchingQr => '正在获取二维码…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return '$platform已登录';
  }

  @override
  String loginKugouLogin(Object platform) {
    return '$platform登录';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return '$platform扫码登录';
  }

  @override
  String get loginKugouResponseMissingToken => '登录响应缺少 token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return '请使用$platform App 扫一扫登录';
  }

  @override
  String loginKugouSession(Object platform) {
    return '$platform登录态';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return '$platform登录成功，VIP 曲目已解锁';
  }

  @override
  String loginLoggedOut(Object platform) {
    return '已退出$platform登录';
  }

  @override
  String loginLogoutWithId(Object id) {
    return '退出登录（$id）';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return '扫码登录$platform';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return '请使用$platform App 扫码登录';
  }

  @override
  String get loginQrExpired => '二维码已过期';

  @override
  String get loginQrExpiredRegenerate => '二维码已过期，请点击重新生成';

  @override
  String get loginQrLogin => '扫码登录';

  @override
  String get loginRefreshQr => '刷新二维码';

  @override
  String get loginRegenerate => '重新生成';

  @override
  String get loginSuccess => '登录成功';

  @override
  String get loginWaitingConfirm => '已扫码，请在手机上确认登录';

  @override
  String get trackListArtistHotSongs => '艺人热门歌曲';

  @override
  String get trackListArtistSongs => '歌手单曲';

  @override
  String get trackListDailyRecommend => '每日推荐';

  @override
  String get trackListDailyRecommendSubtitle => '根据口味每天更新';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return '暂无歌曲（每日推荐需登录$platform）';
  }

  @override
  String get trackListNoPlayableSource => '无可用播放源（VIP / 试听限制）';

  @override
  String get trackListPlayAll => '播放全部';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return '获取播放源失败: $msg';
  }

  @override
  String get trayNext => '下一首';

  @override
  String get trayPlayPause => '播放 / 暂停';

  @override
  String get trayPrevious => '上一首';

  @override
  String get trayQuit => '退出';

  @override
  String get trayShow => '显示主窗口';

  @override
  String get commonPlayAll => '播放全部';

  @override
  String get commonPause => '暂停';

  @override
  String get commonPlay => '播放';

  @override
  String get commonRefresh => '刷新';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonSongs => '歌曲';

  @override
  String get commonAlbums => '专辑';

  @override
  String get commonArtists => '歌手';

  @override
  String get commonPlaylists => '歌单';

  @override
  String get commonDone => '完成';

  @override
  String get commonUnknownError => '未知错误';

  @override
  String commonSongCountHint(Object count) {
    return '共 $count 首歌曲 · 点击播放';
  }

  @override
  String get platformNetease => '网易云';

  @override
  String get platformKugou => '酷狗';

  @override
  String get platformAll => '聚合';

  @override
  String toastPlayedAll(Object count) {
    return '已播放全部 $count 首';
  }

  @override
  String toastPlayFailed(Object msg) {
    return '播放失败：$msg';
  }

  @override
  String get toastMissingLocalPath => '缺少本地文件路径';

  @override
  String get toastLocateComingSoon => '打开文件管理器（Phase 2 接入）';

  @override
  String get toastRemovedFromLibrary => '已从曲库移除';

  @override
  String get toastRemoveFailed => '移除失败';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return '每日推荐需要登录$platform账号';
  }

  @override
  String get toastPlaylistEmpty => '歌单暂无歌曲';

  @override
  String get toastAlbumEmpty => '专辑暂无歌曲';

  @override
  String get toastPausedAll => '已全部暂停';

  @override
  String get toastResumedAll => '已全部开始';

  @override
  String get toastPaused => '已暂停';

  @override
  String get toastCanceledTask => '已取消并删除任务';

  @override
  String get toastResumed => '已恢复下载';

  @override
  String get toastRequeued => '已重新加入队列';

  @override
  String get toastDeletedSelected => '已删除所选任务';

  @override
  String get toastDeletedSelectedWithMedia => '已删除所选任务及媒体文件';

  @override
  String get toastCleared => '已清空下载任务';

  @override
  String get toastClearedWithMedia => '已清空任务并删除媒体文件';

  @override
  String get toastDeletedTask => '已删除任务';

  @override
  String get toastDeletedTaskWithMedia => '已删除任务及媒体文件';

  @override
  String get pageHistoryRemoved => '已从历史移除';

  @override
  String get pageHistoryClearTitle => '清空播放历史';

  @override
  String get pageHistoryClearMessage => '确定清空全部播放历史？此操作不可撤销。';

  @override
  String get pageHistoryCleared => '播放历史已清空';

  @override
  String get pageHistoryRemove => '从历史移除';

  @override
  String get pageHistorySubtitleEmpty => '本地存储的播放记录';

  @override
  String get pageHistoryEmpty => '还没有播放记录';

  @override
  String get pageHistoryEmptyHint => '播放过的歌曲会自动记录在这里';

  @override
  String pageFavPlaylistCount(Object count) {
    return '共 $count 个收藏歌单';
  }

  @override
  String get pageFavPlaylistLoginHint => '登录后可查看收藏的歌单';

  @override
  String pageFavAlbumCount(Object count) {
    return '共 $count 张收藏专辑';
  }

  @override
  String get pageFavAlbumLoginHint => '登录后可查看收藏的专辑';

  @override
  String pageFavArtistCount(Object count) {
    return '共 $count 位收藏歌手';
  }

  @override
  String get pageFavArtistLoginHint => '登录后可查看收藏的歌手';

  @override
  String get pageFavLoadFailed => '加载收藏失败';

  @override
  String get pageFavEmpty => '还没有收藏';

  @override
  String get pageFavEmptyHint => '在网易云 App 收藏后自动同步';

  @override
  String get pageFavLoginTitle => '登录后查看收藏';

  @override
  String get pageFavLoginDesc => '扫码登录网易云，同步收藏的歌单、专辑与歌手';

  @override
  String get pageFavKgCreated => '创建的歌单';

  @override
  String get pageFavKgCollectedPlaylist => '收藏的歌单';

  @override
  String get pageFavKgCollectedAlbum => '收藏的专辑';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '共 $count 个创建的歌单';
  }

  @override
  String get pageFavKgCreatedLoginHint => '登录后可查看创建的歌单';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '共 $count 个收藏歌单';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint => '登录后可查看收藏的歌单';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '共 $count 张收藏专辑';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint => '登录后可查看收藏的专辑';

  @override
  String get pageFavKugouLoginDesc => '扫码登录酷狗，同步创建与收藏的歌单、专辑';

  @override
  String get pageFavKugouEmptyHint => '在酷狗 App 收藏后自动同步';

  @override
  String pageSearchLoadingTrack(Object title) {
    return '开始加载：$title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — 详情页待接入';
  }

  @override
  String get menuViewArtist => '查看歌手';

  @override
  String get pageSearchArtistComingSoon => '歌手页 Phase 2 接入';

  @override
  String get pageSearchInputHint => '输入关键词开始搜索';

  @override
  String get pageSearchInputSubtitle => '支持歌曲 / 专辑 / 歌手 / 歌单';

  @override
  String get pageSearching => '搜索中…';

  @override
  String get pageSearchEmpty => '没有找到相关内容';

  @override
  String get pageSearchEmptyHint => '换个关键词试试';

  @override
  String get pageSearchFailed => '搜索失败';

  @override
  String get pageLikedKugouLoginHint => '登录后可同步酷狗「我喜欢」';

  @override
  String get pageLikedNeteaseLoginHint => '登录后可同步网易云收藏';

  @override
  String get pageLikedLoadFailed => '加载喜欢列表失败';

  @override
  String get pageLikedEmpty => '还没有喜欢的歌曲';

  @override
  String get pageLikedKugouEmptyHint => '在酷狗 App 收藏后自动同步';

  @override
  String get pageLikedNeteaseEmptyHint => '在网易云 App 点亮红心后自动同步';

  @override
  String get pageLikedLoginTitle => '登录后查看我喜欢的歌曲';

  @override
  String get pageLikedKugouLoginDesc => '扫码登录酷狗，同步「我喜欢」收藏';

  @override
  String get pageLikedNeteaseLoginDesc => '扫码登录网易云，同步红心收藏';

  @override
  String get libraryScanDirs => '扫描目录';

  @override
  String get libraryScanDirsDesc => '管理本地扫描目录，添加后立即扫描';

  @override
  String get libraryMediaStats => '媒体统计';

  @override
  String get libraryMediaStatsDesc => '本地音乐库概况';

  @override
  String get libraryStatTracks => '曲目数';

  @override
  String get libraryStatDuration => '总时长';

  @override
  String get libraryStatSize => '总大小';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count 个';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h 小时 $m 分钟';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m 分钟';
  }

  @override
  String librarySeconds(Object s) {
    return '$s 秒';
  }

  @override
  String get librarySearchHint => '搜索本地曲目';

  @override
  String get libraryNoMatch => '没有匹配的曲目';

  @override
  String get libraryScanningFiles => '正在统计文件…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count 首$extra';
  }

  @override
  String get libraryEmptyWaitScan => '正在等待首次扫描';

  @override
  String get libraryEmpty => '本地音乐库为空';

  @override
  String get libraryEmptyScanHint => '点击下方按钮立即扫描';

  @override
  String get libraryEmptyAddHint => '添加音乐文件夹后即可扫描入库';

  @override
  String get libraryScanNow => '立即扫描';

  @override
  String get libraryAddFolder => '添加文件夹';

  @override
  String get menuLocateFile => '定位文件';

  @override
  String get menuLocateFileComingSoon => '打开文件管理器 Phase 2 接入';

  @override
  String get menuRemoveFromLibrary => '从曲库移除';

  @override
  String get playerBarCollapsePlayer => '收起播放器';

  @override
  String get playerBarHideLyrics => '隐藏歌词';

  @override
  String get playerBarShowLyrics => '显示歌词';

  @override
  String get playerPageNotPlaying => '未在播放';

  @override
  String get playerPageLoadHint => '加载源后开始播放';

  @override
  String get playerPageQualityMenu => '切换音质';

  @override
  String get pageHomeRankTitle => '排行榜';

  @override
  String get pageHomePlaylistSquare => '歌单广场';

  @override
  String get pageHomeHotArtists => '热门歌手';

  @override
  String get pageHomePlaylists => '推荐歌单';

  @override
  String get pageHomeNewAlbums => '新碟上架';

  @override
  String get pageHomeRankSubtitle => '各大榜单实时热歌';

  @override
  String get pageHomePlaylistSquareSubtitle => '发现更多精彩歌单';

  @override
  String get pageHomeArtistSubtitle => '热门歌手，圆形头像';

  @override
  String get pageHomeLoadFailed => '加载推荐失败';

  @override
  String get pageHomePlaylistsSubtitle => '根据你的口味为你推荐';

  @override
  String get pageHomeNewAlbumsSubtitle => '近期值得一听的新专辑';

  @override
  String get pageHomeHotArtistsSubtitle => '大家都在听';

  @override
  String get pageHomeDaily => '每日推荐';

  @override
  String get pageHomeDailyLoggedIn => '根据你的口味，为你精心挑选';

  @override
  String get pageHomeDailyLoginHint => '登录网易云账号后，每天为你更新';

  @override
  String get pageHomeDailyPlay => '播放今日推荐';

  @override
  String get pageHomeDailyLogin => '登录解锁每日推荐';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting，$name';
  }

  @override
  String get greetingLate => '夜深了';

  @override
  String get greetingMorning => '早上好';

  @override
  String get greetingAfternoon => '下午好';

  @override
  String get greetingEvening => '晚上好';

  @override
  String get greetingFallback => '今天想听点什么？';

  @override
  String get downloadDeleteTaskOnly => '仅删除任务';

  @override
  String get downloadDeleteWithMedia => '删除任务及媒体文件';

  @override
  String downloadSelectedCount(Object count) {
    return '已选 $count 项';
  }

  @override
  String get downloadSelectAll => '全选';

  @override
  String get downloadDeselectAll => '全不选';

  @override
  String get downloadPauseAll => '全部暂停';

  @override
  String get downloadResumeAll => '全部开始';

  @override
  String get downloadDeleteSelected => '删除所选';

  @override
  String get downloadExitSelect => '退出批量选择';

  @override
  String downloadActiveCount(Object count) {
    return '进行中 $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return '已完成 $count';
  }

  @override
  String get downloadOpenDir => '打开下载目录';

  @override
  String get downloadSelectMode => '批量选择';

  @override
  String get downloadEmpty => '暂无下载任务';

  @override
  String get downloadEmptyHint => '在歌曲上右键 → 下载，即可加入队列';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return '删除所选 $count 个任务';
  }

  @override
  String get downloadDeleteSelectedMessage => '删除所选任务并清空 .tmp 缓存；媒体文件精确匹配删除。';

  @override
  String get downloadClearTitle => '清空下载任务';

  @override
  String get downloadClearMessage => '删除全部任务并清空 .tmp 缓存；媒体文件精确匹配删除。';

  @override
  String get downloadCancelTooltip => '取消（删除任务并清缓存）';

  @override
  String get downloadResume => '恢复下载';

  @override
  String get downloadOpenDirTask => '打开所在目录';

  @override
  String get downloadDeleteTask => '删除任务';

  @override
  String get downloadDeleteWithMediaExact => '删除任务及媒体文件（精确匹配）';

  @override
  String get downloadStatusQueued => '排队中…';

  @override
  String get downloadStatusResolving => '解析下载地址…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return '下载中 $percent%（$received）$speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return '下载中…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return '已暂停（$received）';
  }

  @override
  String get downloadStatusPaused => '已暂停';

  @override
  String downloadStatusFailed(Object error) {
    return '失败：$error';
  }

  @override
  String get downloadStatusFailedUnknown => '失败：未知错误';

  @override
  String get downloadStatusCanceled => '已取消';

  @override
  String downloadStatusDone(Object size) {
    return '完成（$size）';
  }

  @override
  String get downloadStatusAlready => '文件已存在';

  @override
  String get pageHomeTitle => '发现';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsCatAppearance => '外观';

  @override
  String get settingsCatPlayback => '播放';

  @override
  String get settingsCatLyrics => '歌词';

  @override
  String get settingsCatPreset => '强迫症';

  @override
  String get settingsCatDownload => '下载';

  @override
  String get settingsCatStorage => '存储';

  @override
  String get settingsCatAbout => '关于';

  @override
  String get settingsAppearanceSubtitle => '主题模式 · 界面偏好';

  @override
  String get settingsPlaybackSubtitle => '音频引擎 · 播放行为';

  @override
  String get settingsLyricsSubtitle => '播放器歌词 · 桌面歌词';

  @override
  String get settingsPresetSubtitle => '播放过滤 · 歌词还原 · 列表标签';

  @override
  String get settingsDownloadSubtitle => '下载目录 · 并发 · 限速 · 音质 · 分组 · 文件名';

  @override
  String get settingsStorageSubtitle => '数据目录 · 数据库文件';

  @override
  String get settingsAboutSubtitle => '版本 · 项目信息';

  @override
  String get settingsCatDeveloper => '开发者';

  @override
  String get settingsDeveloperSubtitle => '开发者模式 · 隐藏接口';

  @override
  String get settingsDeveloperTitle => '开发者模式';

  @override
  String get settingsDeveloperMode => '开发者模式';

  @override
  String get settingsDeveloperModeOn => '已开启（下载接口可见）';

  @override
  String get settingsDeveloperModeOff => '已关闭（下载接口隐藏）';

  @override
  String get settingsDeveloperDownloadModule => '下载模块';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      '侧边栏「下载」入口、曲目右键「下载」与设置「下载」分类仅在开发者模式开启后显示。';

  @override
  String get settingsDeveloperNote => '开发者模式面向本地调试与自用，开启后请自行承担相关责任。';

  @override
  String get settingsDevFpsMonitor => 'FPS/内存监控浮层';

  @override
  String get settingsDevFpsMonitorDesc =>
      '右上角实时显示 FPS、平均帧耗时与进程内存（点击可收起）。默认关闭；关闭开发者模式时一并关闭。';

  @override
  String get settingsDeveloperEnabled => '开发者模式已开启';

  @override
  String get settingsDeveloperDisabled => '开发者模式已关闭';

  @override
  String get settingsDeveloperHoldHint => '长按 10 秒开启开发者模式（鼠标：按住不放）';

  @override
  String get settingsSearchHint => '搜索设置…';

  @override
  String settingsSearchNoResult(Object query) {
    return '未找到「$query」相关设置';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '匹配 $count 项';
  }

  @override
  String get settingsSectionTheme => '主题';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get settingsThemeModeDesc => '亮色 / 深色 / 跟随系统';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsThemeNote => '默认深色主题；「跟随系统」由系统外观决定。';

  @override
  String get settingsSectionAccent => '主题色';

  @override
  String get settingsAccentTitle => '主色种子';

  @override
  String settingsAccentSystem(Object color) {
    return '跟随系统主题色（$color）';
  }

  @override
  String get settingsAccentSystemFallback => '跟随系统主题色（读取失败，回退自定义）';

  @override
  String get settingsAccentDefault => '默认亮蓝（设计体系）';

  @override
  String get settingsAccentCustom => '自定义（按种子动态生成配色）';

  @override
  String get settingsAccentDefaultTooltip => '默认亮蓝';

  @override
  String get settingsAccentSystemTooltip => '跟随系统主题色';

  @override
  String get settingsAccentCustomTooltip => '自定义取色';

  @override
  String get settingsSectionLayout => '布局';

  @override
  String get settingsFloatingBar => '悬浮播放条';

  @override
  String get settingsFloatingBarOn => '底部居中圆角胶囊（毛玻璃 + 阴影）';

  @override
  String get settingsFloatingBarOff => '全宽停靠（默认）';

  @override
  String get settingsSectionFont => '界面字体';

  @override
  String get settingsFontTitle => '界面字体';

  @override
  String get settingsFontMiSans => 'MiSans（默认）';

  @override
  String get settingsFontNoto => 'Noto Sans SC（标准度量）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans SC（免费商用）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans SC';

  @override
  String get settingsFontHarmonyLabel => '鸿蒙黑体';

  @override
  String get settingsSectionLanguage => '界面语言';

  @override
  String get settingsLanguageTitle => '界面语言';

  @override
  String get settingsLanguageDesc => '切换界面显示语言';

  @override
  String get settingsLangSystem => '跟随系统';

  @override
  String get settingsSectionCover => '封面';

  @override
  String get settingsCoverRadius => '封面圆角';

  @override
  String get settingsCoverRadiusSharp => '直角（信息密度高）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return '${radius}px 圆角';
  }

  @override
  String get settingsCoverRadiusSharpLabel => '直角';

  @override
  String get settingsCoverRadiusRoundedLabel => '圆角';

  @override
  String get settingsCoverRadiusLargeLabel => '大圆角';

  @override
  String get settingsPickerTitle => '自定义主题色';

  @override
  String get settingsPickerHexLabel => '颜色值（#RRGGBB）';

  @override
  String get settingsApply => '应用';

  @override
  String get settingsSectionAudio => '音频';

  @override
  String get settingsPassthrough => '原音质直通（不转码）';

  @override
  String get settingsPassthroughOn => '保持源采样率（Hi-Res/无损不降质）';

  @override
  String get settingsPassthroughOff => '统一 48kHz 转码管线';

  @override
  String get settingsPassthroughNote =>
      '关闭转码保持源采样率播放，开启则统一 48kHz 输出；切换后自动重载当前曲目生效。';

  @override
  String get volumeMute => '静音';

  @override
  String get volumeUnmute => '取消静音';

  @override
  String get settingsSectionMemory => '记忆与启动';

  @override
  String get settingsSessionMemory => '会话记忆';

  @override
  String get settingsSessionMemoryOn => '记录播放队列、位置与模式，下次启动恢复现场';

  @override
  String get settingsSessionMemoryOff => '不记录播放现场，下次启动为空';

  @override
  String get settingsAutoPlay => '启动时自动播放';

  @override
  String get settingsAutoPlayNeedMemory => '需先开启「会话记忆」';

  @override
  String get settingsAutoPlayOn => '恢复上次会话并自动续播';

  @override
  String get settingsAutoPlayOff => '仅恢复播放现场，不自动续播';

  @override
  String get settingsSectionSpectrum => '频谱';

  @override
  String get settingsSpectrum => '频谱可视化';

  @override
  String get settingsSpectrumOn => '播放界面显示频谱柱（播放 0.65 / 暂停 0.15 透明度）';

  @override
  String get settingsSpectrumOff => '播放界面不渲染频谱';

  @override
  String get settingsSpectrumBarWidth => '频谱柱宽';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12，全屏播放器）';
  }

  @override
  String get settingsBarSpectrum => '播放条频谱';

  @override
  String get settingsSpectrumStyle => '频谱样式';

  @override
  String get settingsSpectrumStyleDesc => '频谱可视化效果（条形 / 波形 / 单向波形）';

  @override
  String get settingsSpectrumStyleBars => '条形';

  @override
  String get settingsSpectrumStyleWave => '波形';

  @override
  String get settingsSpectrumStyleWaveUp => '单向波形';

  @override
  String get settingsBarSpectrumOn => '播放条时间下方显示迷你频谱（无歌词或关闭迷你歌词时）';

  @override
  String get settingsBarSpectrumOff => '播放条不显示迷你频谱';

  @override
  String get settingsCoverBeatScale => '封面跟随节奏缩放';

  @override
  String get settingsCoverBeatScaleOn => '封面随鼓点轻微缩放';

  @override
  String get settingsCoverBeatScaleOff => '封面静止（仅播放/暂停缩放）';

  @override
  String get settingsTransitionStyle => '媒体信息切换动效';

  @override
  String get settingsTransitionStyleDesc => '切歌时封面与歌曲信息的过渡动画效果';

  @override
  String get settingsTransitionStyleScale => '缩放';

  @override
  String get settingsTransitionStyleSlide => '侧边滑动';

  @override
  String get settingsSectionShortcuts => '快捷键';

  @override
  String get settingsShortcutSpace => '空格';

  @override
  String get settingsShortcutSpaceDesc => '播放 / 暂停';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => '后退 / 前进 10 秒';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => '音乐库';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc => '返回（关闭弹窗 / 全屏播放器）';

  @override
  String get settingsSectionPlayerLyrics => '播放器歌词';

  @override
  String get settingsPlayerLyrics => '播放器内歌词';

  @override
  String get settingsPlayerLyricsOn => '全屏播放器右侧歌词（当前行高亮，可点击跳转）';

  @override
  String get settingsPlayerLyricsOff => '全屏播放器不显示歌词';

  @override
  String get settingsBarLyrics => '播放条歌词';

  @override
  String get settingsBarLyricsOn => '播放条时间下方显示当前歌词（过长自动滚动）';

  @override
  String get settingsBarLyricsOff => '播放条不显示迷你歌词';

  @override
  String get settingsShowTranslation => '显示翻译';

  @override
  String get settingsShowTranslationOn => '歌词翻译显示在原句后的括号内';

  @override
  String get settingsShowTranslationOff => '不显示歌词翻译';

  @override
  String get settingsSectionLyricStyle => '歌词样式';

  @override
  String get settingsLyricFontSize => '歌词字号';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（当前行放大高亮）';
  }

  @override
  String get settingsLyricLineHeight => '歌词行距';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（含行间距）';
  }

  @override
  String get settingsLyricPlayedColor => '已唱颜色';

  @override
  String get settingsLyricPlayedColorDesc => '当前行歌词高亮色';

  @override
  String get settingsLyricUnplayedColor => '未唱颜色';

  @override
  String get settingsLyricUnplayedColorDesc => '未播放行歌词颜色';

  @override
  String get settingsLyricsNote => '歌词样式仅作用于全屏播放器歌词';

  @override
  String get settingsSectionFilter => '播放过滤';

  @override
  String get settingsDjMode => '去™的 DJ';

  @override
  String get settingsDjModeOn => '世界清净了awa';

  @override
  String get settingsDjModeOff => '哎嘿嘿(ˉ﹃ˉ)';

  @override
  String get settingsSectionLyricsFilter => '歌词';

  @override
  String get settingsUncensor => '解锁脏话';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => '列表显示';

  @override
  String get settingsHideVip => '隐藏 VIP 标签';

  @override
  String get settingsHideVipOn => '列表不显示 VIP / 付费角标';

  @override
  String get settingsHideVipOff => '显示付费角标（VIP / EP）';

  @override
  String get settingsHideQuality => '隐藏音质标签';

  @override
  String get settingsHideQualityOn => '列表不显示音质角标';

  @override
  String get settingsHideQualityOff => '显示可用最高音质（Hi-Res / 无损 / HQ…）';

  @override
  String get settingsShowSubtitle => '显示副标题';

  @override
  String get settingsShowSubtitleOn => '歌名后展示别名，如 (Live)';

  @override
  String get settingsShowSubtitleOff => '列表不展示别名';

  @override
  String get settingsEnergySaving => '节能模式';

  @override
  String get settingsEnergySavingNote =>
      '开启后频谱取帧频率降至约 300ms 一帧（默认 100ms 基线），降低 CPU 占用；频谱渲染与插值不受影响，切换实时生效。';

  @override
  String get settingsEnergySavingOn => '当前为降帧模式';

  @override
  String get settingsEnergySavingOff => '当前为标准模式';

  @override
  String get settingsSearchEnergySavingSubtitle => '降低频谱取帧频率以节省 CPU';

  @override
  String get settingsPerformanceMode => '性能模式';

  @override
  String get settingsPerformanceModeOn => '当前为冻效模式';

  @override
  String get settingsPerformanceModeOff => '当前为动效模式';

  @override
  String get settingsSectionDir => '目录';

  @override
  String get settingsDownloadRootHint => '下载目录（回车保存）';

  @override
  String get settingsRestoreDefault => '恢复默认';

  @override
  String get settingsDownloadRootNote => '默认跟随媒体库目录；修改目录回车保存，进行中的下载任务会终止。';

  @override
  String get settingsSectionFilename => '文件名';

  @override
  String get settingsDownloadTemplateHint => '文件名模板（回车保存）';

  @override
  String get settingsDownloadTemplateNote =>
      '占位符：<artist> · <title> · <album>；只影响之后入队的任务，回车保存立即生效。';

  @override
  String get settingsSectionQuality => '音质';

  @override
  String get settingsDownloadQuality => '默认下载音质';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return '下载弹窗默认选中 $quality，档位不足时自动降级';
  }

  @override
  String get settingsDownloadQualityNote =>
      '档位从高到低：Hi-Res → 无损 → HQ → SQ → LQ，缺失时按此顺序自动降级。';

  @override
  String get settingsSectionConcurrent => '并发';

  @override
  String get settingsDownloadConcurrent => '同时下载数';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count 个并行任务（1~5）';
  }

  @override
  String get settingsDownloadGrouping => '目录分组';

  @override
  String get settingsGroupingFlat => '全部平铺在下载目录下';

  @override
  String get settingsGroupingPlatform => '按平台建子目录（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => '按歌手建子目录';

  @override
  String get settingsGroupingFlatLabel => '平铺';

  @override
  String get settingsGroupingPlatformLabel => '按平台';

  @override
  String get settingsGroupingArtistLabel => '按歌手';

  @override
  String get settingsSectionSpeedLimit => '限速';

  @override
  String get settingsDownloadSpeedLimit => '下载限速';

  @override
  String get settingsSpeedUnlimited => '不限速（默认）';

  @override
  String settingsSpeedLimited(Object speed) {
    return '限 $speed，实时生效';
  }

  @override
  String get settingsSpeedUnlimitedLabel => '不限速';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote => '限速实时生效，不打断在途任务（0.5 MB/s 步进，0 = 不限速）。';

  @override
  String get settingsSectionHistory => '记录';

  @override
  String get settingsDownloadHistoryLimit => '下载记录上限';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count 条（10~500）· 超上限自动淘汰最旧';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count 条';
  }

  @override
  String get settingsDownloadHistoryNote => '仅淘汰失败 / 已取消记录中最旧的，进行中任务不受影响。';

  @override
  String get settingsGroupingNote => '按歌手分组 v2 已支持（平铺 / 按平台 / 按歌手）。';

  @override
  String get settingsSectionFingerprint => '设备指纹';

  @override
  String get settingsFingerprintNote =>
      '下载器向酷狗 / 网易请求时携带的设备标识；首次启动生成后固定，不同用户互不相同。';

  @override
  String get settingsDownloadDynamicFingerprint => '动态设备指纹';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      '开启后设备标识每次启动随机生成（旧版行为），可能触发平台风控，默认关闭。';

  @override
  String get settingsResetFingerprint => '重置设备指纹';

  @override
  String get settingsResetFingerprintDesc =>
      '重置后本机在酷狗 / 网易看来是新设备，旧指纹下的在线状态可能失效。确定重置？';

  @override
  String get toastFingerprintReset => '已重置设备指纹';

  @override
  String get toastDownloadRootEmpty => '下载目录不能为空';

  @override
  String get toastDownloadRootUpdated => '已更新下载目录';

  @override
  String get toastTemplateEmpty => '文件名模板不能为空';

  @override
  String get toastTemplateUpdated => '已更新文件名模板';

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
  String get settingsSectionFileLocation => '文件位置';

  @override
  String get settingsDataDir => '数据目录';

  @override
  String get settingsLibraryDb => '媒体库数据库';

  @override
  String get settingsUserDb => '用户数据库（加密）';

  @override
  String get settingsLibraryDbLabel => '媒体库路径';

  @override
  String get settingsUserDbLabel => '用户库路径';

  @override
  String get settingsCopy => '复制';

  @override
  String toastCopied(Object label) {
    return '已复制$label';
  }

  @override
  String get settingsStorageNote =>
      '媒体库与用户数据物理拆分；路径可用环境变量 ARCHOERA_DATA_DIR 覆盖。';

  @override
  String get settingsSectionCache => '缓存管理';

  @override
  String get settingsCacheNote => '缓存用于加速浏览与播放，清除后会自动重建；不会影响曲库、历史与账号信息。';

  @override
  String get settingsCacheGroupDisk => '数据库缓存（磁盘）';

  @override
  String get settingsCacheGroupMem => '内存缓存（进程内）';

  @override
  String get settingsCacheLimitLyric => '歌词缓存上限';

  @override
  String get settingsCacheLimitCover => '封面图片缓存上限';

  @override
  String get settingsCacheLimitUnlimited => '无上限';

  @override
  String get settingsCacheNoLimitConfirmTitle => '取消缓存上限？';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      '无上限时歌词与封面图片缓存可无限制占用内存，可能造成内存压力与卡顿。确认取消上限？';

  @override
  String get settingsCacheNoLimitConfirm => '确认取消上限';

  @override
  String get settingsSongCache => '歌曲缓存';

  @override
  String get settingsSongCacheNote =>
      '播放过的在线歌曲会缓存到本地磁盘，重播直接读取（省流量、加速、断网可播）。超过上限按 LRU 自动淘汰最旧曲目；下限 16 MiB 可完整缓存一首 320kbps 高品曲目（约 2.4 MiB/分钟）。清除后自动重建，不影响曲库、历史与账号。';

  @override
  String get settingsSongCacheOn => '已开启，重播命中直接读取本地文件';

  @override
  String get settingsSongCacheOff => '已关闭，媒体缓存将不会保存到本地';

  @override
  String get settingsSongCacheLimitTitle => '缓存上限';

  @override
  String settingsCacheSongs(Object count) {
    return '$count 首';
  }

  @override
  String get settingsSearchSongCacheSubtitle => '在线歌曲磁盘缓存开关与 MiB 上限';

  @override
  String get settingsCacheLiked => '「我喜欢」列表缓存';

  @override
  String get settingsCacheLyric => '歌词内容缓存';

  @override
  String get settingsCacheLyricMatch => '歌词匹配缓存';

  @override
  String get settingsCacheLyricTtml => 'TTML 歌词缓存';

  @override
  String get settingsCacheCover => '封面图片缓存';

  @override
  String settingsCacheEntries(Object count) {
    return '$count 条';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count 张';
  }

  @override
  String get settingsCacheRefresh => '刷新';

  @override
  String get settingsCacheClear => '清除';

  @override
  String get settingsCacheClearAll => '清空全部';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '清除「$name」？';
  }

  @override
  String get settingsCacheClearConfirmDesc => '将删除该缓存下的全部数据，下次使用时自动重建，不可撤销。';

  @override
  String get settingsCacheClearAllConfirmTitle => '清空全部缓存？';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      '将删除上方全部缓存（内存与磁盘），不影响曲库、历史与账号信息。';

  @override
  String toastCacheCleared(Object name) {
    return '已清除$name缓存';
  }

  @override
  String get toastCacheAllCleared => '已清空全部缓存';

  @override
  String get settingsSecuritySection => '安全销毁';

  @override
  String get settingsSecurityNote =>
      '不可逆删除本机全部账号凭据与登录会话（流媒体服务器密码、网易云/酷狗登录态、本地 Subsonic 账号），并主动失效平台 token；不影响曲库、历史与下载文件。';

  @override
  String get settingsSecurityStreaming => '流媒体服务器凭据';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count 台服务器';
  }

  @override
  String get settingsSecurityStreamingDesc => '密码与访问令牌';

  @override
  String get settingsSecuritySession => '第三方账号会话';

  @override
  String get settingsSecuritySessionDesc => '网易云 / 酷狗 登录状态';

  @override
  String get settingsSecurityUserDb => '本地用户库';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic 账号与收藏数据';

  @override
  String get settingsSecurityLoggedIn => '已登录';

  @override
  String get settingsSecurityDestroy => '销毁';

  @override
  String get settingsSecurityDestroyAll => '一键销毁全部';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '销毁「$name」？';
  }

  @override
  String get settingsSecurityConfirmAllTitle => '确认销毁全部敏感数据？';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return '将主动失效相关平台 token、覆盖写入并删除文件，此操作不可恢复。输入「$word」以确认。';
  }

  @override
  String get settingsSecurityConfirmWord => '销毁';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return '输入「$word」';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return '已销毁：$name';
  }

  @override
  String get toastSecurityAllDestroyed => '全部敏感数据已销毁';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return '销毁失败，文件仍可能残留：$path';
  }

  @override
  String get settingsDeviceBindSection => '高级 · 设备绑定';

  @override
  String get settingsDeviceBindNote =>
      '增强型可选项（opt-in）：本机免密 + 设备变更走恢复口令，不依赖系统安全存储。开启将读取本机设备标识（仅存本地、不会上传）。默认关闭，普通用户使用 v1 加密已足够。';

  @override
  String get settingsDeviceBindSwitch => '设备绑定免密';

  @override
  String get settingsDeviceBindSwitchDesc => '本机自动解锁；换机/重装走恢复口令';

  @override
  String get settingsDeviceBindSwitchOffDesc =>
      '未启用。当前系统安全存储不可用，可开启设备绑定实现本机免密（无需口令）';

  @override
  String get settingsDeviceBindSwitchV1Desc =>
      '当前为 v1（系统安全存储）模式；开启将升级为设备绑定（免密 + 恢复口令，既有数据保留）';

  @override
  String get settingsDeviceBindSwitchV2Desc =>
      '当前为 v2（口令）模式；开启需先输入当前口令解锁，随后升级为设备绑定（本机免密）';

  @override
  String get settingsDeviceBindPrivacyTitle => '开启设备绑定免密？';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      '将读取本机设备标识（Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID）用于绑定，仅存储于本地，不会上传。注意：此操作不可回到当前 OS 免密模式——日后关闭设备绑定将回落为口令模式（每次启动需输入口令）。';

  @override
  String get settingsDeviceBindEnable => '开启';

  @override
  String get settingsDeviceBindRecoveryTitle => '设置恢复口令（可选）';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      '换机/重装后需用恢复口令解锁凭据。留空则不设置：设备变更后无法恢复（fail-closed，需销毁重建凭据）。';

  @override
  String get settingsDeviceBindRecoveryHint => '恢复口令';

  @override
  String get settingsDeviceBindSkip => '不设口令，直接开启';

  @override
  String get settingsDeviceBindChangeRecovery => '设置 / 修改恢复口令';

  @override
  String get settingsDeviceBindChangeRecoveryTitle => '设置新的恢复口令';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      '修改后旧口令立即失效。请务必记住新口令：换机/重装后凭据解锁将依赖它。';

  @override
  String get settingsDeviceBindRebind => '重新绑定当前设备';

  @override
  String get settingsDeviceBindRebindDesc => '用当前设备指纹重密封，旧指纹立即失效（换机恢复后使用）';

  @override
  String get settingsDeviceBindRebindTitle => '重新绑定当前设备？';

  @override
  String get settingsDeviceBindRebindConfirm => '立即重新绑定';

  @override
  String get settingsDeviceBindClose => '关闭设备绑定';

  @override
  String get settingsDeviceBindCloseDesc => '清除设备熵绑定，vault 转为口令模式';

  @override
  String get settingsDeviceBindCloseTitle => '关闭设备绑定？';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      '将删除设备熵绑定，vault 转为口令模式：此后每次会话需输入口令。该口令即新会话口令，请牢记。输入当前恢复口令以确认。';

  @override
  String get settingsDeviceBindCloseHint => '当前恢复口令';

  @override
  String get settingsDeviceBindRecoveryBanner => '检测到设备变更或熵文件损坏：凭据已锁定，需恢复口令解锁';

  @override
  String get settingsDeviceBindRecover => '恢复';

  @override
  String get settingsDeviceBindRecoverTitle => '输入恢复口令';

  @override
  String get settingsDeviceBindRecoverDesc => '用恢复口令解锁凭据；成功后建议立即重新绑定当前设备恢复免密。';

  @override
  String get settingsDeviceBindShowPassword => '显示 / 隐藏口令';

  @override
  String get toastDeviceBindEnabled => '设备绑定免密已开启';

  @override
  String get toastDeviceBindRecoverySet => '恢复口令已更新';

  @override
  String get toastDeviceBindRebound => '已重新绑定当前设备';

  @override
  String get toastDeviceBindClosed => '设备绑定已关闭，vault 已转为口令模式';

  @override
  String get toastDeviceBindRecoveryNeeded => '未设置恢复口令，无法关闭设备绑定';

  @override
  String toastDeviceBindCloseFailed(Object error) {
    return '关闭失败：$error';
  }

  @override
  String get toastDeviceBindRecovered => '凭据已恢复，可重新绑定本机恢复免密';

  @override
  String get toastDeviceBindRecoverFailed => '恢复口令错误或解锁失败，凭据保持锁定';

  @override
  String get settingsSchemeIntroTitle => '加密方案说明';

  @override
  String get settingsSchemeIntroDesc =>
      '登录凭据（cookie）由加密方案保护。已为你启用 LEGACY 方案（推荐）：主密钥存于操作系统安全存储，稳定可靠。如需更高安全性，可在「设置 → 凭据加密方案」切换到 Vault（实验性）——注意该方案切换会重建数据库并丢失全部登录凭据。';

  @override
  String get settingsSchemeIntroGotIt => '知道了，继续';

  @override
  String get settingsSchemeSection => '凭据加密方案';

  @override
  String get settingsSchemeNote =>
      '选择登录凭据的加密方案。LEGACY：操作系统安全存储加密，稳定可靠（推荐）；FILK（文件密钥）：主密钥存本地 secret.key 文件，免 OS 钥匙串，供 Docker/无图形环境使用（本地文件单点风险）；Vault：2-of-2 双因子实验性方案，安全性更高但存在异常丢失 Cookie 风险。切换方案需重建数据库并重新登录。';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => '推荐';

  @override
  String get settingsSchemeCryptoDesc =>
      'cookie 由操作系统安全存储加密（Windows DPAPI / macOS 钥匙串 / Linux libsecret），稳定可靠。';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'LEGACY 方案：主密钥整体由操作系统安全存储保护，加密强度与可用性稳定，适合日常使用。';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => '兼容';

  @override
  String get settingsSchemeFileDesc =>
      '主密钥存本地 secret.key 文件（0600 权限），免 OS 钥匙串，供无图形环境的 Docker/服务器使用。本地文件单点：密钥文件泄露即凭据全泄露。';

  @override
  String get settingsSchemeFileModeDesc =>
      'FILK（文件密钥）方案：主密钥落盘 secret.key（0600 原子写），经典的服务端加密形态；仅在无 OS 钥匙串的 headless/Docker 环境使用。';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => '实验性';

  @override
  String get settingsSchemeVaultDesc =>
      '2-of-2 双因子加密（系统份额 + 用户份额缺一不可），抵御离线攻击更强，但存在异常丢失 Cookie 风险。';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Vault 方案：主密钥拆分为系统份额与用户份额，双因子缺一不可；可再选 v1 系统保护 / v2 口令保护 / v3 设备绑定加密等级。';

  @override
  String get settingsSchemeSwitchTitle => '切换加密方案？';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault 为实验性方案：切换后存在异常丢失 Cookie 的风险。';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'FILK 为兼容性降级方案：主密钥存于本地文件，一旦泄露全部凭据即暴露。仅限无 OS 钥匙串的 headless/Docker 环境使用。';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      '各方案加密数据结构不兼容，切换将销毁现有保险库并重建数据库，所有登录凭据（网易云 / 酷狗 / 流媒体账号）将丢失，需重新登录。';

  @override
  String get settingsSchemeSwitchKeep => '保持当前';

  @override
  String get settingsSchemeSwitchConfirm => '切换并重建';

  @override
  String get toastSchemeSwitched => '加密方案已切换，重启后生效';

  @override
  String get settingsVaultSection => '凭据加密';

  @override
  String get settingsVaultNote =>
      '选择凭据的加密保护等级：v1 系统保护（默认）/ v2 口令保护 / v3 设备绑定（增强项 opt-in，读取本机设备标识，仅存本地、不会上传）。v1 ↔ v2 可随时互切；v3 为终点档，关闭后回落为 v2。';

  @override
  String get settingsVaultModeV1 => 'v1 系统保护';

  @override
  String get settingsVaultModeV2 => 'v2 口令保护';

  @override
  String get settingsVaultModeV3 => 'v3 设备绑定';

  @override
  String get settingsVaultModeDescOs =>
      'v1 系统保护：凭据由操作系统安全存储加密（Windows DPAPI / macOS 钥匙串 / Linux libsecret），本机免密。';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 口令保护：凭据由口令加密，每次启动需输入口令解锁。可随时切回 v1 系统保护。';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 设备绑定：本机免密，设备变更时需恢复口令解锁。不可直接降回 v1——关闭后将回落为 v2 口令模式。';

  @override
  String get settingsVaultModeDescUnknown => '加密等级读取中…';

  @override
  String get settingsVaultSwitchToPasswordTitle => '切换到口令保护（v2）';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      '凭据将改由口令加密保护，每次启动需输入口令。主密钥与已有数据保留，此操作可随时切回系统保护（v1）。';

  @override
  String get settingsVaultSwitchToPasswordNewHint => '设置新口令';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint => '再次输入新口令';

  @override
  String get settingsVaultSwitchToPasswordMismatch => '两次输入不一致';

  @override
  String get settingsVaultSwitchToOsTitle => '切换回系统保护（v1）';

  @override
  String get settingsVaultSwitchToOsDesc =>
      '凭据将改由操作系统安全存储保护，无需再输入口令。此操作可随时切回口令保护（v2）。';

  @override
  String get settingsVaultNeedUnlockFirst => '当前口令保护未解锁：请先解锁后再切换';

  @override
  String get settingsVaultV3NoDirectV1 =>
      '设备绑定（v3）不可直接降回 v1：请先关闭设备绑定，回落为 v2 口令模式';

  @override
  String get settingsVaultCloseV3PasswordTitle => '关闭设备绑定：设置新口令';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      '设备绑定开启时未设置恢复口令（本机免密），关闭后将转为口令保护（v2）：请设置新的解锁口令。主密钥与已有数据保留，此口令每次启动都需输入。';

  @override
  String get toastVaultSwitchedToPassword => '已切换到口令保护（v2）';

  @override
  String get toastVaultSwitchedToOs => '已切换回系统保护（v1）';

  @override
  String get settingsVaultShareBrokenBanner =>
      '凭据保险库份额不配对：存储后端不符或份额缺失，本地凭据无法解密。需销毁重建后重新登录。';

  @override
  String get settingsVaultShareBrokenRebuild => '销毁重建';

  @override
  String get settingsVaultRestartTitle => '需要重启应用';

  @override
  String get settingsVaultRestartDesc =>
      '加密等级已切换成功。为保证数据库完整性与各模块状态一致，请重启应用生效。若为口令保护模式（v2），重启后将要求输入口令解锁，解锁前登录态与流媒体凭据暂不可用（显示为未登录）；重启期间播放与下载会中断。';

  @override
  String get settingsVaultRestartNow => '立即重启';

  @override
  String get settingsVaultRestartLater => '稍后重启';

  @override
  String get vaultCrashTitle => '凭据模块异常退出';

  @override
  String get vaultCrashDesc => '凭据保险库进程意外终止，本地凭据可能已暴露。建议重新登录或销毁 vault 以重建凭据。';

  @override
  String get vaultCrashReset => '销毁并重建';

  @override
  String get vaultCrashDismiss => '知道了';

  @override
  String get vaultVersionTitle => '凭据保险库版本异常';

  @override
  String get vaultVersionDesc =>
      '检测到凭据保险库组件异常：其二进制副本可能已被替换或非官方构建，本地凭据可能已暴露。已删除异常副本并拒绝解密。请退出并重新安装应用。';

  @override
  String get vaultVersionExit => '退出';

  @override
  String get vaultVersionReasonReplaced =>
      '检测到 vault 二进制被替换或非官方构建，已删除异常副本并拒绝解密。';

  @override
  String get vaultVersionReasonMarkerMissing => 'vault 握手应答缺少官方构建标记。';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'vault 构建标记与官方产物不符，已删除异常副本并拒绝解密。';

  @override
  String get vaultUnlockTitle => '解锁凭据保险库';

  @override
  String get vaultUnlockDesc => '凭据保险库为口令保护模式（v2）。请输入口令以解锁本地登录凭据与流媒体账号。';

  @override
  String get vaultUnlockHint => '口令';

  @override
  String get vaultUnlockConfirm => '解锁';

  @override
  String get vaultUnlockSkip => '暂不解锁';

  @override
  String get vaultUnlockFailed => '口令错误，请重试';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsVersionUnknown => 'v未知 · Flutter 桌面端';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter 桌面端';
  }

  @override
  String get settingsAudioEngine => '音频引擎';

  @override
  String get settingsAudioEngineDesc => '内置 C 引擎（miniaudio）· 原生 FFI';

  @override
  String get settingsSubsonicServer => 'Subsonic 服务端';

  @override
  String get settingsSubsonicDesc => 'Go FFI · 曲库自托管';

  @override
  String get settingsAboutDesc => '自研音乐播放器：本地曲库、直连音源、自托管 Subsonic、原生音频引擎。';

  @override
  String get settingsSectionDeclaration => '软件声明';

  @override
  String get settingsDeclineText =>
      '本软件（ArchoeraMusic）是一款免费、开源的桌面音乐播放器，为个人学习研究用途，非商业软件。使用前请阅读以下声明：\n\n';

  @override
  String get settingsDecline1Title => '一、软件性质\n';

  @override
  String get settingsDecline1Body =>
      '本软件为第三方客户端，与各音乐平台及其官方客户端无任何关联、合作或授权关系；不以营利为目的，不接受任何商业合作、广告或捐赠。如需更完善的功能，请下载官方客户端体验。\n\n';

  @override
  String get settingsDecline2Title => '二、内容来源与版权\n';

  @override
  String get settingsDecline2Body =>
      '本软件自身不提供、不存储、不分发任何音乐内容。音频、歌词、封面等均来自您的本地文件或各音乐平台公开接口，其版权归原权利人及平台所有，本软件不主张任何所有权。\n\n';

  @override
  String get settingsDecline3Title => '三、版权数据处理义务\n';

  @override
  String get settingsDecline3Body =>
      '使用过程中产生的版权数据（播放链接、歌词、封面等）仅供您个人试听与学习研究，请勿用于商业或公开传播；建议在产生后 24 小时内清除。如需长期欣赏，请通过正版渠道购买或订阅，支持正版音乐。\n\n';

  @override
  String get settingsDecline4Title => '四、使用限制\n';

  @override
  String get settingsDecline4Body =>
      '请勿利用本软件从事商业行为、批量抓取、爬取或转售内容；请勿在违反当地法律法规或相关平台服务条款的情况下使用本软件；请勿绕过在线平台的技术保护措施、访问控制或服务条款。\n\n';

  @override
  String get settingsDecline5Title => '五、免责声明\n';

  @override
  String get settingsDecline5Body =>
      '本软件按「现状」提供，不对其作出任何明示或默示的保证。因使用或无法使用本软件，或因在线平台接口变更、账号限制、功能失效等产生的任何直接或间接损失，均由使用者自行承担。\n\n';

  @override
  String get settingsDeclineFooter =>
      '本软件仅用于技术探索与研究。如相关平台认为本软件不妥，可随时联系开发者进行调整或移除。';

  @override
  String get settingsSectionFontCredits => '字体署名';

  @override
  String get settingsFontCreditsText =>
      '本软件内置以下字体：\n· Noto Sans CJK SC（SIL Open Font License 1.1）\n· MiSans（© Xiaomi，依据《MiSans 字体知识产权许可协议》授权使用）\n· HarmonyOS Sans SC（© Huawei，依据《HarmonyOS Sans 字体许可协议》授权使用）';

  @override
  String get commonNoLyrics => '暂无歌词';

  @override
  String commonTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String get settingsSearchColorTitle => '已唱 / 未唱颜色';

  @override
  String get settingsSearchColorSubtitle => '歌词行高亮与普通行颜色';

  @override
  String get settingsSearchDesktopLyricsTitle => '桌面歌词';

  @override
  String get settingsSearchDesktopLyricsSubtitle => '置顶独立歌词窗';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => '文件名模板';

  @override
  String get settingsSearchAccentSubtitle => '自定义主色种子 · 色板';

  @override
  String get settingsThemeSource => '主题色来源';

  @override
  String get settingsThemeSourceDesc => '主题色的获取方式';

  @override
  String get settingsThemeSourceDefault => '跟随系统';

  @override
  String get settingsThemeSourceCustom => '自定义主色';

  @override
  String get settingsThemeSourceCover => '跟随封面';

  @override
  String get settingsThemeSourceSolid => '无主题色';

  @override
  String get settingsThemeSourceCustomHint => '选取主色种子，主/次色由它动态生成';

  @override
  String get settingsThemeSourceCoverHint => '实时从当前播放封面提取主色（不可用时回退默认色）';

  @override
  String get settingsGlobalTint => '全局着色';

  @override
  String get settingsGlobalTintDesc => '将主题色应用到全局界面';

  @override
  String get settingsGlobalTintNote => '存在主题色（自定义/跟随封面）时生效；图片背景模式下强制开启。';

  @override
  String get settingsSectionStyle => '背景风格';

  @override
  String get settingsAppearanceStyle => '外观风格';

  @override
  String get settingsAppearanceStyleDesc => '应用主背景的呈现方式';

  @override
  String get settingsAppearanceStyleSolid => '纯色背景';

  @override
  String get settingsAppearanceStyleImage => '自定义图片';

  @override
  String get settingsBackgroundImage => '背景图片';

  @override
  String get settingsBackgroundImageDesc => '选择本地图片作为应用背景；图片模式强制暗色 + 全局着色';

  @override
  String get settingsBackgroundPick => '选择图片';

  @override
  String get settingsBackgroundReplace => '更换';

  @override
  String get settingsBackgroundClear => '清除';

  @override
  String get settingsBackgroundBlur => '背景模糊';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return '对背景图片应用高斯模糊（${blur}px）';
  }

  @override
  String get settingsBackgroundDim => '遮罩浓度';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return '叠加的黑色遮罩透明度（$dim%），越高前景越易读';
  }

  @override
  String get settingsBackgroundScale => '缩放大小';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return '背景图的缩放倍数（${scale}x）';
  }

  @override
  String get settingsSidebarCollapsed => '折叠侧边栏';

  @override
  String get settingsSidebarCollapsedDesc => '将侧边栏折叠为图标模式';

  @override
  String get settingsSidebarNavStyle => '导航高亮动效';

  @override
  String get settingsSidebarNavStyleDesc => '切换侧边栏导航高亮指示器的动画风格';

  @override
  String get settingsSidebarNavStyleDefault => '静态';

  @override
  String get settingsSidebarNavStyleAnimated => '滑动';

  @override
  String get settingsRouteTransition => '页面切换动效';

  @override
  String get settingsRouteTransitionDesc => '切换页面时的过渡动画效果';

  @override
  String get settingsRouteTransitionNone => '无';

  @override
  String get settingsRouteTransitionFade => '淡入淡出';

  @override
  String get settingsRouteTransitionSlide => '滑动';

  @override
  String get settingsRouteTransitionZoom => '缩放';

  @override
  String get settingsSearchThemeSourceSubtitle => '默认主题色 · 自定义主色 · 跟随封面 · 无主题色';

  @override
  String get settingsSearchGlobalTintSubtitle => '将主题色应用到全局界面';

  @override
  String get settingsSearchBackgroundSubtitle => '纯色 / 图片 · 模糊 · 遮罩 · 缩放';

  @override
  String get settingsSearchSidebarSubtitle => '折叠侧边栏 · 静态 / 滑动高亮';

  @override
  String get settingsSearchRouteTransitionSubtitle => '无 · 淡入淡出 · 滑动 · 缩放';

  @override
  String get settingsSearchFloatingBarSubtitle => '底部悬浮胶囊 · 全宽停靠';

  @override
  String get settingsSearchFontSubtitle => 'MiSans · HarmonyOS Sans SC';

  @override
  String get settingsSearchLanguageSubtitle => '跟随系统 · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle => '直角 · 圆角 · 大圆角';

  @override
  String get settingsSectionWeather => '天气';

  @override
  String get settingsWeather => '天气组件';

  @override
  String get settingsWeatherDesc => '顶栏头像左侧显示微型天气（图标 + 温度）';

  @override
  String get settingsWeatherAutoLocate => '自动定位';

  @override
  String get settingsWeatherAutoLocateDesc => '按网络 IP 获取大致位置查询天气（涉及隐私，默认关闭）';

  @override
  String get settingsWeatherCity => '手动城市';

  @override
  String get settingsWeatherCityHint => '填写城市名后不再进行 IP 定位（例如：杭州）';

  @override
  String get settingsWeatherNote =>
      '隐私说明：天气数据来自 Open-Meteo（免费、无需密钥）。开启「自动定位」时，本机 IP 会发送至 ip-api.com 换取大致位置，仅用于查询天气、不落盘。天气组件与定位默认均关闭。';

  @override
  String get settingsSearchWeatherSubtitle => '顶栏显示微型天气组件（图标 + 温度）';

  @override
  String get weatherRefresh => '刷新天气';

  @override
  String get weatherNoLocation => '请在设置中填写城市或开启自动定位';

  @override
  String get weatherUnavailable => '天气获取失败，点击重试';

  @override
  String get settingsSearchPassthroughSubtitle => '不转码 · 48kHz 转码管线';

  @override
  String get settingsSearchSessionMemorySubtitle => '记录/恢复播放现场';

  @override
  String get settingsSearchAutoPlaySubtitle => '自动续播开关';

  @override
  String get settingsSearchSpectrumSubtitle => '播放界面频谱开关 · 透明度';

  @override
  String get settingsSearchSpectrumWidthSubtitle => '1~12px 柱宽调节';

  @override
  String get settingsSearchPlayerLyricsSubtitle => '全屏播放器歌词显示';

  @override
  String get settingsSearchLyricFontSizeSubtitle => '14~28px 播放器歌词字号';

  @override
  String get settingsSearchLyricLineHeightSubtitle => '42~64px 行高调节';

  @override
  String get settingsSearchUncensorSubtitle => '还原歌词中被星号遮盖的词';

  @override
  String get settingsSearchHideVipSubtitle => '歌曲列表 VIP / 付费角标隐藏';

  @override
  String get settingsSearchHideQualitySubtitle => '歌曲列表音质角标隐藏';

  @override
  String get settingsSearchSubtitleSubtitle => '歌曲列表展示别名（如 (Live)）';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      '下载保存位置（默认 ~/Music/ArchoeraMusic）';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> 占位符可配置';

  @override
  String get settingsSearchConcurrentSubtitle => '1~5 个并行下载任务';

  @override
  String get settingsSearchSpeedLimitSubtitle => '不限速 · 0.5~20 MB/s 实时生效';

  @override
  String get settingsSearchQualitySubtitle => 'Hi-Res · 无损 · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle => '平铺 · 按平台 · 按歌手';

  @override
  String get settingsSearchHistoryLimitSubtitle => '超上限自动淘汰最旧（10~500）';

  @override
  String get settingsSearchStorageSubtitle => '媒体库 · 用户数据库路径';

  @override
  String get settingsSearchAboutSubtitle => '音频引擎 · Subsonic 服务端';

  @override
  String get qualityLossless => '无损';

  @override
  String get repeatModeList => '列表循环';

  @override
  String get repeatModeOne => '单曲循环';

  @override
  String get commonUnknownTrack => '未知名歌曲';

  @override
  String get commonAnonymousUser => '匿名用户';

  @override
  String get commonCanceled => '已取消';

  @override
  String get commonILike => '我喜欢';

  @override
  String get sidebarStreaming => '流媒体';

  @override
  String get settingsCatMediaSource => '媒体源';

  @override
  String get settingsMediaSourceSubtitle =>
      '流媒体服务器（Subsonic / Jellyfin / Emby）';

  @override
  String get settingsCatScrape => '刮削';

  @override
  String get settingsScrapeSubtitle => '多源元数据补齐 · 封面 / 歌词 / 标签';

  @override
  String get settingsSectionScrapeDirs => '刮削目录';

  @override
  String get settingsScrapeDirsHint => '每行一个目录；留空跟随媒体库扫描目录';

  @override
  String get settingsScrapeDirsEmptyNote => '未配置刮削目录，刮削时将跟随媒体库扫描目录。';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return '当前生效目录：$dirs';
  }

  @override
  String get settingsSectionScrapeSources => '数据源';

  @override
  String get settingsScrapeSourceMusicBrainz => 'MusicBrainz';

  @override
  String get settingsScrapeSourceDeezer => 'Deezer';

  @override
  String get settingsScrapeSourceItunes => 'iTunes';

  @override
  String get settingsScrapeSourceNetease => '网易云音乐';

  @override
  String get settingsScrapeSourceQQMusic => 'QQ 音乐';

  @override
  String get settingsScrapeSourceKugou => '酷狗音乐';

  @override
  String get settingsScrapeSourceKuwo => '酷我音乐';

  @override
  String get settingsScrapeSourceMigu => '咪咕音乐';

  @override
  String get settingsScrapeSourceAcoustID => 'AcoustID（音频指纹）';

  @override
  String get settingsScrapeSourceDesc => '开启后参与多源查询、相似度比对与评分合并';

  @override
  String get settingsSectionScrapeProgress => '刮削进度';

  @override
  String get settingsScrapeStart => '开始刮削';

  @override
  String get settingsScrapeCancel => '取消刮削';

  @override
  String get settingsScrapeScanning => '正在扫描目录…';

  @override
  String settingsScrapeCurrent(Object file) {
    return '正在处理：$file';
  }

  @override
  String get settingsScrapeSuccess => '成功';

  @override
  String get settingsScrapeFailed => '失败';

  @override
  String get settingsScrapeSkipped => '跳过';

  @override
  String get settingsScrapeNotFound => '未匹配';

  @override
  String get settingsScrapeIdle => '尚未刮削，点击下方按钮开始。';

  @override
  String get settingsScrapeNoDirs => '没有可刮削的目录，请先配置刮削目录或媒体库扫描目录。';

  @override
  String get settingsScrapeDone => '刮削完成';

  @override
  String get settingsScrapeCanceled => '刮削已取消';

  @override
  String get toastScrapeNoDirs => '没有可刮削的目录';

  @override
  String get toastScrapeDirsUpdated => '刮削目录已保存';

  @override
  String get toastScrapeStarted => '已开始刮削';

  @override
  String get commonDelete => '删除';

  @override
  String get commonSave => '保存';

  @override
  String get commonConfirm => '确定';

  @override
  String get streamingHint => '媒体源';

  @override
  String get streamingHintDetail =>
      '添加流媒体服务器，浏览并播放服务器上的音乐（支持 Subsonic 家族 / Jellyfin / Emby，含本机内置 Subsonic 服务端）。';

  @override
  String get streamingServerAdd => '添加服务器';

  @override
  String get streamingEmptyNoServer => '还没有流媒体服务器';

  @override
  String get streamingEmptyAddHint => '点击上方按钮添加一个服务器';

  @override
  String get streamingServerConnected => '已连接';

  @override
  String get streamingServerDisconnected => '未连接';

  @override
  String get streamingServerLastConnected => '最近连接';

  @override
  String get streamingServerDisconnect => '断开连接';

  @override
  String get streamingToastDisconnected => '已断开服务器连接';

  @override
  String get streamingServerConnect => '连接';

  @override
  String streamingToastConnected(Object name) {
    return '已连接 $name';
  }

  @override
  String get streamingServerConnectFailed => '连接失败';

  @override
  String get streamingServerEdit => '编辑';

  @override
  String get streamingServerDeleteConfirmTitle => '删除服务器';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return '确定删除服务器「$name」吗？';
  }

  @override
  String get streamingServerRemoved => '服务器已删除';

  @override
  String get streamingServerErrorNameEmpty => '请输入服务器名称';

  @override
  String get streamingServerErrorHostEmpty => '请输入服务器地址';

  @override
  String get streamingServerErrorPortInvalid => '端口无效（1~65535）';

  @override
  String get streamingServerErrorUsernameEmpty => '请输入用户名';

  @override
  String get streamingServerErrorPasswordEmpty => '请输入密码';

  @override
  String get streamingServerAdded => '服务器已添加';

  @override
  String get streamingServerUpdated => '服务器已更新';

  @override
  String get streamingServerType => '类型';

  @override
  String get streamingServerName => '名称';

  @override
  String get streamingServerNamePlaceholder => '例如：我的 Navidrome';

  @override
  String get streamingServerHost => '服务器地址';

  @override
  String get streamingServerHostPlaceholder => '例如：192.168.1.10:4533';

  @override
  String get streamingServerPort => '端口';

  @override
  String get streamingServerPortNote =>
      '默认端口为 4533（Subsonic）/ 8096（Jellyfin）；留空自动匹配。';

  @override
  String get streamingServerLocalTitle => '本机内置服务端';

  @override
  String get streamingServerLocalDesc => '使用内置 Subsonic 服务端（本机媒体库）';

  @override
  String get streamingServerUsername => '用户名';

  @override
  String get streamingServerPassword => '密码';

  @override
  String get streamingServerTestOk => '连接成功';

  @override
  String get streamingServerTestFail => '连接失败';

  @override
  String get streamingServerTest => '测试连接';

  @override
  String get streamingTabsSongs => '歌曲';

  @override
  String get streamingTabsAlbums => '专辑';

  @override
  String get streamingTabsArtists => '歌手';

  @override
  String get streamingTabsPlaylists => '歌单';

  @override
  String get streamingEmptyGoToSettings => '去设置';

  @override
  String get streamingEmptyNotConnected => '未连接到任何服务器';

  @override
  String streamingTotalSongs(Object count) {
    return '$count 首歌曲';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count 张专辑';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count 位歌手';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count 个歌单';
  }

  @override
  String get streamingEmptyNoResults => '没有匹配的结果';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count 首歌曲';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count 张专辑';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count 首歌曲';
  }
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get menuTrackDetail => '媒體詳細資訊';

  @override
  String get trackDetailDuration => '時長';

  @override
  String get trackDetailArtist => '歌手';

  @override
  String get trackDetailAlbum => '專輯';

  @override
  String get trackDetailSource => '來源';

  @override
  String get trackDetailPath => '路徑';

  @override
  String get trackDetailFileSize => '檔案大小';

  @override
  String get trackDetailCodec => '編碼';

  @override
  String get trackDetailSampleRate => '取樣率';

  @override
  String get trackDetailBitDepth => '位元深度';

  @override
  String get trackDetailBitrate => '位元率';

  @override
  String get trackDetailChannels => '聲道';

  @override
  String get trackSourceLocal => '本機檔案';

  @override
  String get trackSourceStreaming => '串流';

  @override
  String get trackDetailQuality => '音質';

  @override
  String get batchSelectAll => '全選';

  @override
  String get batchInvert => '反選';

  @override
  String get batchPlay => '播放所選';

  @override
  String get batchAddQueue => '加入佇列';

  @override
  String get batchDownload => '批次下載';

  @override
  String get batchExit => '退出多選';

  @override
  String get batchSelectHint => '批次選擇';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '已加入播放佇列 $count 首';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '已加入下載佇列 $count 首';
  }

  @override
  String get settingsBarEnhancedLyrics => '播放條進階歌詞';

  @override
  String get settingsBarEnhancedLyricsOn => '歌詞含逐字時間軸時顯示卡拉OK高亮';

  @override
  String get settingsBarEnhancedLyricsOff => '播放條始終顯示一般歌詞';

  @override
  String get settingsSectionClose => '關閉應用';

  @override
  String get settingsSectionPower => '節能';

  @override
  String get settingsPowerSaver => '節能模式';

  @override
  String get settingsPowerSaverOn => '背景自動降幀（最小化 5 FPS，失焦/熄屏 1 FPS）';

  @override
  String get settingsPowerSaverOff => '始終滿幀渲染';

  @override
  String get settingsSuppressSleep => '停用系統休眠';

  @override
  String get settingsSuppressSleepOn => '播放時保持系統喚醒，防止背景播放中斷';

  @override
  String get settingsSuppressSleepOff => '系統可能依閒置計畫休眠';

  @override
  String get settingsPowerSaverNote =>
      '節能模式監聽視窗狀態事件自動降幀，無需輪詢；視窗不可見或顯示器關閉時，渲染引擎本身已停止繪製。「停用系統休眠」僅在播放中生效。';

  @override
  String get settingsCloseBehavior => '關閉應用程式時';

  @override
  String get settingsCloseBehaviorAsk => '每次詢問';

  @override
  String get settingsCloseBehaviorBackground => '背景播放';

  @override
  String get settingsCloseBehaviorQuit => '直接結束';

  @override
  String get commonCloseConfirmTitle => '結束應用程式';

  @override
  String get commonCloseConfirmMessage => '關閉主視窗後';

  @override
  String get commonCloseConfirmRemember => '記住我的選擇，不再詢問';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => '網易雲音樂';

  @override
  String get brandKugou => '酷狗音樂';

  @override
  String get commonBack => '返回';

  @override
  String get commonCancel => '取消';

  @override
  String get commonClose => '關閉';

  @override
  String get commonDefault => '預設';

  @override
  String get commonGoLogin => '去登入';

  @override
  String get commonLike => '喜歡';

  @override
  String get commonLoading => '載入中';

  @override
  String get commonLossless => '無損';

  @override
  String get commonOriginal => '原唱';

  @override
  String get commonMore => '更多';

  @override
  String get commonNext => '下一首';

  @override
  String get commonNoMore => '沒有更多了';

  @override
  String get commonPrevious => '上一首';

  @override
  String get commonSettings => '全域設定';

  @override
  String get commonUnknownAlbum => '未知專輯';

  @override
  String get commonUnknownArtist => '未知歌手';

  @override
  String get commonUnlike => '取消喜歡';

  @override
  String get downloadQualityTitle => '下載音質';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return '取得$platform下載連結需登入，未登入只能試聽，無法下載完整音質。\n\n請先登入$platform帳號後重試。';
  }

  @override
  String get downloadRequiresLoginTitle => '下載需要登入';

  @override
  String get menuComment => '查看留言';

  @override
  String get menuDownload => '下載';

  @override
  String get menuLike => '加入收藏';

  @override
  String get menuPlay => '播放';

  @override
  String get menuPlayNext => '下一首播放';

  @override
  String get menuRemoveFromQueue => '從佇列移除';

  @override
  String get menuUnlike => '取消收藏';

  @override
  String get navHeaderAccount => '帳號';

  @override
  String get navHeaderComingSoon => '敬請期待';

  @override
  String navHeaderKugouId(Object id) {
    return '酷狗 $id';
  }

  @override
  String get navHeaderKugouMusic => '酷狗音樂';

  @override
  String get navHeaderLoginAccount => '登入帳號（網易雲 / 酷狗）';

  @override
  String get navHeaderLogout => '登出';

  @override
  String get navHeaderNeteaseAccount => '網易雲帳號';

  @override
  String get navHeaderNeteaseMusic => '網易雲音樂';

  @override
  String get navHeaderQqMusic => 'QQ 音樂';

  @override
  String get navHeaderQrLogin => '掃碼登入';

  @override
  String get navHeaderSearchHint => '搜尋歌曲 / 歌手 / 歌單';

  @override
  String get navHeaderThemeDark => '主題：暗色';

  @override
  String get navHeaderThemeLight => '主題：亮色';

  @override
  String get navHeaderThemeSystem => '主題：跟隨系統';

  @override
  String get playerBarBuffering => '載入中…';

  @override
  String get playerBarIdleHint => '點擊側邊欄或載入來源即可開始播放';

  @override
  String get playerBarOpenPlayer => '開啟播放頁';

  @override
  String get playerBarPlayPause => '播放/暫停';

  @override
  String get playerBarPlaylist => '播放清單';

  @override
  String get playerBarUntitled => '未命名';

  @override
  String get queueClear => '清空佇列';

  @override
  String get queueEmpty => '佇列為空';

  @override
  String get queueEmptyHint => '在清單中選擇歌曲後會出現在這裡';

  @override
  String get queueRepeatList => '清單循環';

  @override
  String get queueRepeatMode => '播放模式';

  @override
  String get queueRepeatOne => '單曲循環';

  @override
  String get queueShuffle => '隨機播放';

  @override
  String get queueShuffleOff => '關閉隨機播放';

  @override
  String get queueTitle => '播放佇列';

  @override
  String queueTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String get sidebarBackHome => '返回首頁';

  @override
  String get sidebarCollapse => '摺疊側邊欄';

  @override
  String get sidebarDownload => '下載';

  @override
  String get sidebarExpand => '展開側邊欄';

  @override
  String get sidebarFavorites => '收藏';

  @override
  String get sidebarGroupMusic => '音樂';

  @override
  String get sidebarGroupPersonal => '個人';

  @override
  String get sidebarHistory => '歷史';

  @override
  String get sidebarHome => '首頁';

  @override
  String get sidebarLibrary => '音樂庫';

  @override
  String get sidebarLiked => '我喜歡';

  @override
  String get songListAlbum => '專輯';

  @override
  String get songListDuration => '時長';

  @override
  String get songListTitle => '標題';

  @override
  String get songListScrollTop => '回到頂部';

  @override
  String get songListLocatePlaying => '定位播放位置';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return '已加入下載佇列：$quality';
  }

  @override
  String get toastAddedToQueue => '已加入播放佇列';

  @override
  String get toastDownloadEngineNotReady => '下載引擎未就緒，請稍後再試';

  @override
  String get toastLiked => '已加入收藏';

  @override
  String get toastLoginRequiredKugou => '操作失敗（請確認已登入酷狗帳號）';

  @override
  String get toastLoginRequiredNetease => '操作失敗（請確認已登入網易雲帳號）';

  @override
  String get toastNoQualityInfo => '該曲目無可用音質資訊，無法下載';

  @override
  String get toastUnliked => '已取消收藏';

  @override
  String get commonClear => '清除';

  @override
  String get commonEmptyContent => '暫無內容';

  @override
  String commonLoadFailed(Object msg) {
    return '載入失敗：$msg';
  }

  @override
  String get commonRetry => '重試';

  @override
  String get commentDuplicate => '請勿重複傳送相同內容';

  @override
  String get commentEmpty => '暫時沒有留言';

  @override
  String get commentHot => '熱門';

  @override
  String get commentInputEmpty => '留言內容不能為空';

  @override
  String get commentInputHint => '說點什麼…';

  @override
  String get commentLatest => '最新';

  @override
  String commentLoginRequired(Object platform) {
    return '傳送留言需要登入$platform帳號';
  }

  @override
  String commentNotFound(Object platform) {
    return '未找到該歌曲的$platform留言';
  }

  @override
  String get commentPublished => '留言已發布';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user：$text';
  }

  @override
  String get commentSend => '傳送';

  @override
  String commentSendFailed(Object msg) {
    return '傳送失敗：$msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$month月$day日 $time';
  }

  @override
  String get commentTitle => '歌曲留言';

  @override
  String get folderAdd => '新增';

  @override
  String get folderBrowse => '瀏覽';

  @override
  String get folderEmpty => '尚未新增掃描目錄，點擊下方按鈕新增';

  @override
  String get folderExists => '目錄已存在或無效';

  @override
  String get folderInvalid => '目錄不存在、已存在或為空';

  @override
  String get folderPathHint => '輸入目錄絕對路徑';

  @override
  String get folderRemove => '移除';

  @override
  String get folderRemoveDescription => '移除後不再掃描該目錄，已入庫曲目保留。';

  @override
  String get folderRemoveTitle => '移除掃描目錄';

  @override
  String get loginFetchingQr => '正在取得 QR Code…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return '$platform已登入';
  }

  @override
  String loginKugouLogin(Object platform) {
    return '$platform登入';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return '$platform掃碼登入';
  }

  @override
  String get loginKugouResponseMissingToken => '登入回應缺少 token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return '請使用$platform App 掃一掃登入';
  }

  @override
  String loginKugouSession(Object platform) {
    return '$platform登入狀態';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return '$platform登入成功，VIP 曲目已解鎖';
  }

  @override
  String loginLoggedOut(Object platform) {
    return '已退出$platform登入';
  }

  @override
  String loginLogoutWithId(Object id) {
    return '登出（$id）';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return '掃碼登入$platform';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return '請使用$platform App 掃碼登入';
  }

  @override
  String get loginQrExpired => 'QR Code 已過期';

  @override
  String get loginQrExpiredRegenerate => 'QR Code 已過期，請點擊重新產生';

  @override
  String get loginQrLogin => '掃碼登入';

  @override
  String get loginRefreshQr => '重新整理 QR Code';

  @override
  String get loginRegenerate => '重新產生';

  @override
  String get loginSuccess => '登入成功';

  @override
  String get loginWaitingConfirm => '已掃碼，請在手機上確認登入';

  @override
  String get trackListArtistHotSongs => '藝人熱門歌曲';

  @override
  String get trackListArtistSongs => '歌手單曲';

  @override
  String get trackListDailyRecommend => '每日推薦';

  @override
  String get trackListDailyRecommendSubtitle => '依口味每天更新';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return '暫無歌曲（每日推薦需登入$platform）';
  }

  @override
  String get trackListNoPlayableSource => '無可用播放來源（VIP / 試聽限制）';

  @override
  String get trackListPlayAll => '播放全部';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return '取得播放來源失敗: $msg';
  }

  @override
  String get trayNext => '下一首';

  @override
  String get trayPlayPause => '播放 / 暫停';

  @override
  String get trayPrevious => '上一首';

  @override
  String get trayQuit => '退出';

  @override
  String get trayShow => '顯示主視窗';

  @override
  String get commonPlayAll => '播放全部';

  @override
  String get commonPause => '暫停';

  @override
  String get commonPlay => '播放';

  @override
  String get commonRefresh => '重新整理';

  @override
  String get commonSearch => '搜尋';

  @override
  String get commonSongs => '歌曲';

  @override
  String get commonAlbums => '專輯';

  @override
  String get commonArtists => '歌手';

  @override
  String get commonPlaylists => '歌單';

  @override
  String get commonDone => '完成';

  @override
  String get commonUnknownError => '未知錯誤';

  @override
  String commonSongCountHint(Object count) {
    return '共 $count 首歌曲 · 點擊播放';
  }

  @override
  String get platformNetease => '網易雲';

  @override
  String get platformKugou => '酷狗';

  @override
  String get platformAll => '聚合';

  @override
  String toastPlayedAll(Object count) {
    return '已播放全部 $count 首';
  }

  @override
  String toastPlayFailed(Object msg) {
    return '播放失敗：$msg';
  }

  @override
  String get toastMissingLocalPath => '缺少本機檔案路徑';

  @override
  String get toastLocateComingSoon => '開啟檔案管理員（Phase 2 接入）';

  @override
  String get toastRemovedFromLibrary => '已從音樂庫移除';

  @override
  String get toastRemoveFailed => '移除失敗';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return '每日推薦需要登入$platform帳號';
  }

  @override
  String get toastPlaylistEmpty => '歌單暫無歌曲';

  @override
  String get toastAlbumEmpty => '專輯暫無歌曲';

  @override
  String get toastPausedAll => '已全部暫停';

  @override
  String get toastResumedAll => '已全部開始';

  @override
  String get toastPaused => '已暫停';

  @override
  String get toastCanceledTask => '已取消並刪除任務';

  @override
  String get toastResumed => '已恢復下載';

  @override
  String get toastRequeued => '已重新加入佇列';

  @override
  String get toastDeletedSelected => '已刪除所選任務';

  @override
  String get toastDeletedSelectedWithMedia => '已刪除所選任務及媒體檔案';

  @override
  String get toastCleared => '已清空下載任務';

  @override
  String get toastClearedWithMedia => '已清空任務並刪除媒體檔案';

  @override
  String get toastDeletedTask => '已刪除任務';

  @override
  String get toastDeletedTaskWithMedia => '已刪除任務及媒體檔案';

  @override
  String get pageHistoryRemoved => '已從歷史移除';

  @override
  String get pageHistoryClearTitle => '清空播放歷史';

  @override
  String get pageHistoryClearMessage => '確定清空全部播放歷史？此操作無法復原。';

  @override
  String get pageHistoryCleared => '播放歷史已清空';

  @override
  String get pageHistoryRemove => '從歷史移除';

  @override
  String get pageHistorySubtitleEmpty => '本機儲存的播放記錄';

  @override
  String get pageHistoryEmpty => '還沒有播放記錄';

  @override
  String get pageHistoryEmptyHint => '播放過的歌曲會自動記錄在這裡';

  @override
  String pageFavPlaylistCount(Object count) {
    return '共 $count 個收藏歌單';
  }

  @override
  String get pageFavPlaylistLoginHint => '登入後可檢視收藏的歌單';

  @override
  String pageFavAlbumCount(Object count) {
    return '共 $count 張收藏專輯';
  }

  @override
  String get pageFavAlbumLoginHint => '登入後可檢視收藏的專輯';

  @override
  String pageFavArtistCount(Object count) {
    return '共 $count 位收藏歌手';
  }

  @override
  String get pageFavArtistLoginHint => '登入後可檢視收藏的歌手';

  @override
  String get pageFavLoadFailed => '載入收藏失敗';

  @override
  String get pageFavEmpty => '還沒有收藏';

  @override
  String get pageFavEmptyHint => '在網易雲 App 收藏後自動同步';

  @override
  String get pageFavLoginTitle => '登入後檢視收藏';

  @override
  String get pageFavLoginDesc => '掃碼登入網易雲，同步收藏的歌單、專輯與歌手';

  @override
  String get pageFavKgCreated => '建立的歌單';

  @override
  String get pageFavKgCollectedPlaylist => '收藏的歌單';

  @override
  String get pageFavKgCollectedAlbum => '收藏的專輯';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '共 $count 個建立的歌單';
  }

  @override
  String get pageFavKgCreatedLoginHint => '登入後可查看建立的歌單';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '共 $count 個收藏歌單';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint => '登入後可查看收藏的歌單';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '共 $count 張收藏專輯';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint => '登入後可查看收藏的專輯';

  @override
  String get pageFavKugouLoginDesc => '掃碼登入酷狗，同步建立與收藏的歌單、專輯';

  @override
  String get pageFavKugouEmptyHint => '在酷狗 App 收藏後自動同步';

  @override
  String pageSearchLoadingTrack(Object title) {
    return '開始載入：$title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — 詳情頁待接入';
  }

  @override
  String get menuViewArtist => '檢視歌手';

  @override
  String get pageSearchArtistComingSoon => '歌手頁 Phase 2 接入';

  @override
  String get pageSearchInputHint => '輸入關鍵字開始搜尋';

  @override
  String get pageSearchInputSubtitle => '支援歌曲 / 專輯 / 歌手 / 歌單';

  @override
  String get pageSearching => '搜尋中…';

  @override
  String get pageSearchEmpty => '沒有找到相關內容';

  @override
  String get pageSearchEmptyHint => '換個關鍵字試試';

  @override
  String get pageSearchFailed => '搜尋失敗';

  @override
  String get pageLikedKugouLoginHint => '登入後可同步酷狗「我喜歡」';

  @override
  String get pageLikedNeteaseLoginHint => '登入後可同步網易雲收藏';

  @override
  String get pageLikedLoadFailed => '載入喜歡清單失敗';

  @override
  String get pageLikedEmpty => '還沒有喜歡的歌曲';

  @override
  String get pageLikedKugouEmptyHint => '在酷狗 App 收藏後自動同步';

  @override
  String get pageLikedNeteaseEmptyHint => '在網易雲 App 點亮紅心後自動同步';

  @override
  String get pageLikedLoginTitle => '登入後檢視我喜歡的歌曲';

  @override
  String get pageLikedKugouLoginDesc => '掃碼登入酷狗，同步「我喜歡」收藏';

  @override
  String get pageLikedNeteaseLoginDesc => '掃碼登入網易雲，同步紅心收藏';

  @override
  String get libraryScanDirs => '掃描目錄';

  @override
  String get libraryScanDirsDesc => '管理本機掃描目錄，新增後立即掃描';

  @override
  String get libraryMediaStats => '媒體統計';

  @override
  String get libraryMediaStatsDesc => '本機音樂庫概況';

  @override
  String get libraryStatTracks => '曲目數';

  @override
  String get libraryStatDuration => '總時長';

  @override
  String get libraryStatSize => '總大小';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count 個';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h 小時 $m 分鐘';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m 分鐘';
  }

  @override
  String librarySeconds(Object s) {
    return '$s 秒';
  }

  @override
  String get librarySearchHint => '搜尋本機曲目';

  @override
  String get libraryNoMatch => '沒有匹配的曲目';

  @override
  String get libraryScanningFiles => '正在統計檔案…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count 首$extra';
  }

  @override
  String get libraryEmptyWaitScan => '正在等待首次掃描';

  @override
  String get libraryEmpty => '本機音樂庫為空';

  @override
  String get libraryEmptyScanHint => '點擊下方按鈕立即掃描';

  @override
  String get libraryEmptyAddHint => '新增音樂資料夾後即可掃描入庫';

  @override
  String get libraryScanNow => '立即掃描';

  @override
  String get libraryAddFolder => '新增資料夾';

  @override
  String get menuLocateFile => '定位檔案';

  @override
  String get menuLocateFileComingSoon => '開啟檔案管理員 Phase 2 接入';

  @override
  String get menuRemoveFromLibrary => '從曲庫移除';

  @override
  String get playerBarCollapsePlayer => '收起播放器';

  @override
  String get playerBarHideLyrics => '隱藏歌詞';

  @override
  String get playerBarShowLyrics => '顯示歌詞';

  @override
  String get playerPageNotPlaying => '未在播放';

  @override
  String get playerPageLoadHint => '載入來源後開始播放';

  @override
  String get playerPageQualityMenu => '切換音質';

  @override
  String get pageHomeRankTitle => '排行榜';

  @override
  String get pageHomePlaylistSquare => '歌單廣場';

  @override
  String get pageHomeHotArtists => '熱門歌手';

  @override
  String get pageHomePlaylists => '推薦歌單';

  @override
  String get pageHomeNewAlbums => '新碟上架';

  @override
  String get pageHomeRankSubtitle => '各大榜單即時熱歌';

  @override
  String get pageHomePlaylistSquareSubtitle => '發現更多精彩歌單';

  @override
  String get pageHomeArtistSubtitle => '熱門歌手，圓形頭像';

  @override
  String get pageHomeLoadFailed => '載入推薦失敗';

  @override
  String get pageHomePlaylistsSubtitle => '根據你的口味為你推薦';

  @override
  String get pageHomeNewAlbumsSubtitle => '近期值得一聽的新專輯';

  @override
  String get pageHomeHotArtistsSubtitle => '大家都在聽';

  @override
  String get pageHomeDaily => '每日推薦';

  @override
  String get pageHomeDailyLoggedIn => '根據你的口味，為你精心挑選';

  @override
  String get pageHomeDailyLoginHint => '登入網易雲帳號後，每天為你更新';

  @override
  String get pageHomeDailyPlay => '播放今日推薦';

  @override
  String get pageHomeDailyLogin => '登入解鎖每日推薦';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting，$name';
  }

  @override
  String get greetingLate => '夜深了';

  @override
  String get greetingMorning => '早上好';

  @override
  String get greetingAfternoon => '下午好';

  @override
  String get greetingEvening => '晚上好';

  @override
  String get greetingFallback => '今天想聽點什麼？';

  @override
  String get downloadDeleteTaskOnly => '僅刪除任務';

  @override
  String get downloadDeleteWithMedia => '刪除任務及媒體檔案';

  @override
  String downloadSelectedCount(Object count) {
    return '已選 $count 項';
  }

  @override
  String get downloadSelectAll => '全選';

  @override
  String get downloadDeselectAll => '全不選';

  @override
  String get downloadPauseAll => '全部暫停';

  @override
  String get downloadResumeAll => '全部開始';

  @override
  String get downloadDeleteSelected => '刪除所選';

  @override
  String get downloadExitSelect => '退出批量選擇';

  @override
  String downloadActiveCount(Object count) {
    return '進行中 $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return '已完成 $count';
  }

  @override
  String get downloadOpenDir => '開啟下載目錄';

  @override
  String get downloadSelectMode => '批量選擇';

  @override
  String get downloadEmpty => '暫無下載任務';

  @override
  String get downloadEmptyHint => '在歌曲上右鍵 → 下載，即可加入佇列';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return '刪除所選 $count 個任務';
  }

  @override
  String get downloadDeleteSelectedMessage => '刪除所選任務並清空 .tmp 快取；媒體檔案精確匹配刪除。';

  @override
  String get downloadClearTitle => '清空下載任務';

  @override
  String get downloadClearMessage => '刪除全部任務並清空 .tmp 快取；媒體檔案精確匹配刪除。';

  @override
  String get downloadCancelTooltip => '取消（刪除任務並清快取）';

  @override
  String get downloadResume => '恢復下載';

  @override
  String get downloadOpenDirTask => '開啟所在目錄';

  @override
  String get downloadDeleteTask => '刪除任務';

  @override
  String get downloadDeleteWithMediaExact => '刪除任務及媒體檔案（精確匹配）';

  @override
  String get downloadStatusQueued => '排隊中…';

  @override
  String get downloadStatusResolving => '解析下載位址…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return '下載中 $percent%（$received）$speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return '下載中…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return '已暫停（$received）';
  }

  @override
  String get downloadStatusPaused => '已暫停';

  @override
  String downloadStatusFailed(Object error) {
    return '失敗：$error';
  }

  @override
  String get downloadStatusFailedUnknown => '失敗：未知錯誤';

  @override
  String get downloadStatusCanceled => '已取消';

  @override
  String downloadStatusDone(Object size) {
    return '完成（$size）';
  }

  @override
  String get downloadStatusAlready => '檔案已存在';

  @override
  String get pageHomeTitle => '發現';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsCatAppearance => '外觀';

  @override
  String get settingsCatPlayback => '播放';

  @override
  String get settingsCatLyrics => '歌詞';

  @override
  String get settingsCatPreset => '強迫症';

  @override
  String get settingsCatDownload => '下載';

  @override
  String get settingsCatStorage => '儲存';

  @override
  String get settingsCatAbout => '關於';

  @override
  String get settingsAppearanceSubtitle => '主題模式 · 介面偏好';

  @override
  String get settingsPlaybackSubtitle => '音訊引擎 · 播放行為';

  @override
  String get settingsLyricsSubtitle => '播放器歌詞 · 桌面歌詞';

  @override
  String get settingsPresetSubtitle => '播放過濾 · 歌詞還原 · 列表標籤';

  @override
  String get settingsDownloadSubtitle => '下載目錄 · 並發 · 限速 · 音質 · 分組 · 檔名';

  @override
  String get settingsStorageSubtitle => '資料目錄 · 資料庫檔案';

  @override
  String get settingsAboutSubtitle => '版本 · 專案資訊';

  @override
  String get settingsCatDeveloper => '開發者';

  @override
  String get settingsDeveloperSubtitle => '開發者模式 · 隱藏介面';

  @override
  String get settingsDeveloperTitle => '開發者模式';

  @override
  String get settingsDeveloperMode => '開發者模式';

  @override
  String get settingsDeveloperModeOn => '已開啟（下載介面可見）';

  @override
  String get settingsDeveloperModeOff => '已關閉（下載介面隱藏）';

  @override
  String get settingsDeveloperDownloadModule => '下載模組';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      '側邊欄「下載」入口、曲目右鍵「下載」與設定「下載」分類僅在開發者模式開啟後顯示。';

  @override
  String get settingsDeveloperNote => '開發者模式面向本機除錯與自用，開啟後請自行承擔相關責任。';

  @override
  String get settingsDevFpsMonitor => 'FPS/記憶體監控浮層';

  @override
  String get settingsDevFpsMonitorDesc =>
      '右上角即時顯示 FPS、平均影格耗時與程序記憶體（點擊可收起）。預設關閉；關閉開發者模式時一併關閉。';

  @override
  String get settingsDeveloperEnabled => '開發者模式已開啟';

  @override
  String get settingsDeveloperDisabled => '開發者模式已關閉';

  @override
  String get settingsDeveloperHoldHint => '長按 10 秒開啟開發者模式（滑鼠：按住不放）';

  @override
  String get settingsSearchHint => '搜尋設定…';

  @override
  String settingsSearchNoResult(Object query) {
    return '未找到「$query」相關設定';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '符合 $count 項';
  }

  @override
  String get settingsSectionTheme => '主題';

  @override
  String get settingsThemeMode => '主題模式';

  @override
  String get settingsThemeModeDesc => '淺色 / 深色 / 跟隨系統';

  @override
  String get settingsThemeLight => '淺色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeSystem => '跟隨系統';

  @override
  String get settingsThemeNote => '預設深色主題；「跟隨系統」由系統外觀決定。';

  @override
  String get settingsSectionAccent => '主題色';

  @override
  String get settingsAccentTitle => '主色種子';

  @override
  String settingsAccentSystem(Object color) {
    return '跟隨系統主題色（$color）';
  }

  @override
  String get settingsAccentSystemFallback => '跟隨系統主題色（讀取失敗，回退自訂）';

  @override
  String get settingsAccentDefault => '預設亮藍（設計體系）';

  @override
  String get settingsAccentCustom => '自訂（依種子動態生成配色）';

  @override
  String get settingsAccentDefaultTooltip => '預設亮藍';

  @override
  String get settingsAccentSystemTooltip => '跟隨系統主題色';

  @override
  String get settingsAccentCustomTooltip => '自訂取色';

  @override
  String get settingsSectionLayout => '佈局';

  @override
  String get settingsFloatingBar => '懸浮播放條';

  @override
  String get settingsFloatingBarOn => '底部置中圓角膠囊（毛玻璃 + 陰影）';

  @override
  String get settingsFloatingBarOff => '全寬停靠（預設）';

  @override
  String get settingsSectionFont => '介面字型';

  @override
  String get settingsFontTitle => '介面字型';

  @override
  String get settingsFontMiSans => 'MiSans（預設）';

  @override
  String get settingsFontNoto => 'Noto Sans TC（標準度量）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans TC（免費商用）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans TC';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => '介面語言';

  @override
  String get settingsLanguageTitle => '介面語言';

  @override
  String get settingsLanguageDesc => '切換介面顯示語言';

  @override
  String get settingsLangSystem => '跟隨系統';

  @override
  String get settingsSectionCover => '封面';

  @override
  String get settingsCoverRadius => '封面圓角';

  @override
  String get settingsCoverRadiusSharp => '直角（資訊密度高）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return '${radius}px 圓角';
  }

  @override
  String get settingsCoverRadiusSharpLabel => '直角';

  @override
  String get settingsCoverRadiusRoundedLabel => '圓角';

  @override
  String get settingsCoverRadiusLargeLabel => '大圓角';

  @override
  String get settingsPickerTitle => '自訂主題色';

  @override
  String get settingsPickerHexLabel => '顏色值（#RRGGBB）';

  @override
  String get settingsApply => '套用';

  @override
  String get settingsSectionAudio => '音訊';

  @override
  String get settingsPassthrough => '原音質直通（不轉碼）';

  @override
  String get settingsPassthroughOn => '保持源取樣率（Hi-Res/無損不降質）';

  @override
  String get settingsPassthroughOff => '統一 48kHz 轉碼管線';

  @override
  String get settingsPassthroughNote =>
      '關閉轉碼保持源取樣率播放，開啟則統一 48kHz 輸出；切換後自動重載目前曲目生效。';

  @override
  String get volumeMute => '靜音';

  @override
  String get volumeUnmute => '取消靜音';

  @override
  String get settingsSectionMemory => '記憶與啟動';

  @override
  String get settingsSessionMemory => '會話記憶';

  @override
  String get settingsSessionMemoryOn => '記錄播放佇列、位置與模式，下次啟動恢復現場';

  @override
  String get settingsSessionMemoryOff => '不記錄播放現場，下次啟動為空';

  @override
  String get settingsAutoPlay => '啟動時自動播放';

  @override
  String get settingsAutoPlayNeedMemory => '需先開啟「會話記憶」';

  @override
  String get settingsAutoPlayOn => '恢復上次會話並自動續播';

  @override
  String get settingsAutoPlayOff => '僅恢復播放現場，不自動續播';

  @override
  String get settingsSectionSpectrum => '頻譜';

  @override
  String get settingsSpectrum => '頻譜視覺化';

  @override
  String get settingsSpectrumOn => '播放介面顯示頻譜柱（播放 0.65 / 暫停 0.15 透明度）';

  @override
  String get settingsSpectrumOff => '播放介面不渲染頻譜';

  @override
  String get settingsSpectrumBarWidth => '頻譜柱寬';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12，全螢幕播放器）';
  }

  @override
  String get settingsBarSpectrum => '播放列頻譜';

  @override
  String get settingsSpectrumStyle => '頻譜樣式';

  @override
  String get settingsSpectrumStyleDesc => '頻譜可視化效果（條形 / 波形 / 單向波形）';

  @override
  String get settingsSpectrumStyleBars => '條形';

  @override
  String get settingsSpectrumStyleWave => '波形';

  @override
  String get settingsSpectrumStyleWaveUp => '單向波形';

  @override
  String get settingsBarSpectrumOn => '播放列時間下方顯示迷你頻譜（無歌詞或關閉迷你歌詞時）';

  @override
  String get settingsBarSpectrumOff => '播放列不顯示迷你頻譜';

  @override
  String get settingsCoverBeatScale => '封面跟隨節奏縮放';

  @override
  String get settingsCoverBeatScaleOn => '封面隨鼓點輕微縮放';

  @override
  String get settingsCoverBeatScaleOff => '封面靜止（僅播放/暫停縮放）';

  @override
  String get settingsTransitionStyle => '媒體資訊切換動效';

  @override
  String get settingsTransitionStyleDesc => '切換歌曲時封面與歌曲資訊的過渡動畫效果';

  @override
  String get settingsTransitionStyleScale => '縮放';

  @override
  String get settingsTransitionStyleSlide => '側邊滑動';

  @override
  String get settingsSectionShortcuts => '快速鍵';

  @override
  String get settingsShortcutSpace => '空白鍵';

  @override
  String get settingsShortcutSpaceDesc => '播放 / 暫停';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => '後退 / 前進 10 秒';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => '音樂庫';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc => '返回（關閉彈窗 / 全螢幕播放器）';

  @override
  String get settingsSectionPlayerLyrics => '播放器歌詞';

  @override
  String get settingsPlayerLyrics => '播放器內歌詞';

  @override
  String get settingsPlayerLyricsOn => '全螢幕播放器右側歌詞（目前行高亮，可點擊跳轉）';

  @override
  String get settingsPlayerLyricsOff => '全螢幕播放器不顯示歌詞';

  @override
  String get settingsBarLyrics => '播放列歌詞';

  @override
  String get settingsBarLyricsOn => '播放列時間下方顯示目前歌詞（過長自動捲動）';

  @override
  String get settingsBarLyricsOff => '播放列不顯示迷你歌詞';

  @override
  String get settingsShowTranslation => '顯示翻譯';

  @override
  String get settingsShowTranslationOn => '歌詞翻譯顯示在原句後的括號內';

  @override
  String get settingsShowTranslationOff => '不顯示歌詞翻譯';

  @override
  String get settingsSectionLyricStyle => '歌詞樣式';

  @override
  String get settingsLyricFontSize => '歌詞字級';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（目前行放大高亮）';
  }

  @override
  String get settingsLyricLineHeight => '歌詞行距';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（含行間距）';
  }

  @override
  String get settingsLyricPlayedColor => '已唱顏色';

  @override
  String get settingsLyricPlayedColorDesc => '目前行歌詞高亮色';

  @override
  String get settingsLyricUnplayedColor => '未唱顏色';

  @override
  String get settingsLyricUnplayedColorDesc => '未播放行歌詞顏色';

  @override
  String get settingsLyricsNote => '歌詞樣式僅作用於全螢幕播放器歌詞';

  @override
  String get settingsSectionFilter => '播放過濾';

  @override
  String get settingsDjMode => '去™的 DJ';

  @override
  String get settingsDjModeOn => '世界清淨了awa';

  @override
  String get settingsDjModeOff => '哎嘿嘿(ˉ﹃ˉ)';

  @override
  String get settingsSectionLyricsFilter => '歌詞';

  @override
  String get settingsUncensor => '解鎖髒話';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => '列表顯示';

  @override
  String get settingsHideVip => '隱藏 VIP 標籤';

  @override
  String get settingsHideVipOn => '列表不顯示 VIP / 付費角標';

  @override
  String get settingsHideVipOff => '顯示付費角標（VIP / EP）';

  @override
  String get settingsHideQuality => '隱藏音質標籤';

  @override
  String get settingsHideQualityOn => '列表不顯示音質角標';

  @override
  String get settingsHideQualityOff => '顯示可用最高音質（Hi-Res / 無損 / HQ…）';

  @override
  String get settingsShowSubtitle => '顯示副標題';

  @override
  String get settingsShowSubtitleOn => '歌名後展示別名，如 (Live)';

  @override
  String get settingsShowSubtitleOff => '列表不展示別名';

  @override
  String get settingsEnergySaving => '節能模式';

  @override
  String get settingsEnergySavingNote =>
      '開啟後頻譜取幀頻率降至約 300ms 一幀（預設 100ms 基線），降低 CPU 占用；頻譜渲染與插值不受影響，切換即時生效。';

  @override
  String get settingsEnergySavingOn => '目前為降幀模式';

  @override
  String get settingsEnergySavingOff => '目前為標準模式';

  @override
  String get settingsSearchEnergySavingSubtitle => '降低頻譜取幀頻率以節省 CPU';

  @override
  String get settingsPerformanceMode => '效能模式';

  @override
  String get settingsPerformanceModeOn => '目前為凍效模式';

  @override
  String get settingsPerformanceModeOff => '目前為動效模式';

  @override
  String get settingsSectionDir => '目錄';

  @override
  String get settingsDownloadRootHint => '下載目錄（Enter 儲存）';

  @override
  String get settingsRestoreDefault => '恢復預設';

  @override
  String get settingsDownloadRootNote =>
      '預設跟隨媒體庫目錄；修改目錄按 Enter 儲存，進行中的下載任務會終止。';

  @override
  String get settingsSectionFilename => '檔名';

  @override
  String get settingsDownloadTemplateHint => '檔名模板（Enter 儲存）';

  @override
  String get settingsDownloadTemplateNote =>
      '佔位符：<artist> · <title> · <album>；只影響之後入隊的任務，按 Enter 儲存立即生效。';

  @override
  String get settingsSectionQuality => '音質';

  @override
  String get settingsDownloadQuality => '預設下載音質';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return '下載彈窗預設選中 $quality，檔位不足時自動降級';
  }

  @override
  String get settingsDownloadQualityNote =>
      '檔位從高到低：Hi-Res → 無損 → HQ → SQ → LQ，缺失時依此順序自動降級。';

  @override
  String get settingsSectionConcurrent => '並發';

  @override
  String get settingsDownloadConcurrent => '同時下載數';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count 個平行任務（1~5）';
  }

  @override
  String get settingsDownloadGrouping => '目錄分組';

  @override
  String get settingsGroupingFlat => '全部平鋪在下載目錄下';

  @override
  String get settingsGroupingPlatform => '按平台建立子目錄（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => '按歌手建立子目錄';

  @override
  String get settingsGroupingFlatLabel => '平鋪';

  @override
  String get settingsGroupingPlatformLabel => '按平台';

  @override
  String get settingsGroupingArtistLabel => '按歌手';

  @override
  String get settingsSectionSpeedLimit => '限速';

  @override
  String get settingsDownloadSpeedLimit => '下載限速';

  @override
  String get settingsSpeedUnlimited => '不限速（預設）';

  @override
  String settingsSpeedLimited(Object speed) {
    return '限 $speed，即時生效';
  }

  @override
  String get settingsSpeedUnlimitedLabel => '不限速';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote => '限速即時生效，不打斷在途任務（0.5 MB/s 步進，0 = 不限速）。';

  @override
  String get settingsSectionHistory => '記錄';

  @override
  String get settingsDownloadHistoryLimit => '下載記錄上限';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count 條（10~500）· 超上限自動淘汰最舊';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count 條';
  }

  @override
  String get settingsDownloadHistoryNote => '僅淘汰失敗 / 已取消記錄中最舊的，進行中任務不受影響。';

  @override
  String get settingsGroupingNote => '按歌手分組 v2 已支援（平鋪 / 按平台 / 按歌手）。';

  @override
  String get settingsSectionFingerprint => '裝置指紋';

  @override
  String get settingsFingerprintNote =>
      '下載器向酷狗 / 網易請求時攜帶的裝置識別碼；首次啟動產生後固定，不同使用者互不相同。';

  @override
  String get settingsDownloadDynamicFingerprint => '動態裝置指紋';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      '開啟後裝置識別碼每次啟動隨機產生（舊版行為），可能觸發平台風控，預設關閉。';

  @override
  String get settingsResetFingerprint => '重置裝置指紋';

  @override
  String get settingsResetFingerprintDesc =>
      '重置後本機在酷狗 / 網易看來是新裝置，舊指紋下的線上狀態可能失效。確定重置？';

  @override
  String get toastFingerprintReset => '已重置裝置指紋';

  @override
  String get toastDownloadRootEmpty => '下載目錄不能為空';

  @override
  String get toastDownloadRootUpdated => '已更新下載目錄';

  @override
  String get toastTemplateEmpty => '檔名模板不能為空';

  @override
  String get toastTemplateUpdated => '已更新檔名模板';

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
  String get settingsSectionFileLocation => '檔案位置';

  @override
  String get settingsDataDir => '資料目錄';

  @override
  String get settingsLibraryDb => '媒體庫資料庫';

  @override
  String get settingsUserDb => '使用者資料庫（加密）';

  @override
  String get settingsLibraryDbLabel => '媒體庫路徑';

  @override
  String get settingsUserDbLabel => '使用者庫路徑';

  @override
  String get settingsCopy => '複製';

  @override
  String toastCopied(Object label) {
    return '已複製$label';
  }

  @override
  String get settingsStorageNote =>
      '媒體庫與使用者資料實體拆分；路徑可用環境變數 ARCHOERA_DATA_DIR 覆蓋。';

  @override
  String get settingsSectionCache => '快取管理';

  @override
  String get settingsCacheNote => '快取用於加速瀏覽與播放，清除後會自動重建；不會影響曲庫、歷史與帳號資訊。';

  @override
  String get settingsCacheGroupDisk => '資料庫快取（磁碟）';

  @override
  String get settingsCacheGroupMem => '記憶體快取（行程內）';

  @override
  String get settingsCacheLimitLyric => '歌詞快取上限';

  @override
  String get settingsCacheLimitCover => '封面圖片快取上限';

  @override
  String get settingsCacheLimitUnlimited => '無上限';

  @override
  String get settingsCacheNoLimitConfirmTitle => '取消快取上限？';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      '無上限時歌詞與封面圖片快取可無限制佔用記憶體，可能造成記憶體壓力與卡頓。確認取消上限？';

  @override
  String get settingsCacheNoLimitConfirm => '確認取消上限';

  @override
  String get settingsSongCache => '歌曲快取';

  @override
  String get settingsSongCacheNote =>
      '播放過的線上歌曲會快取到本機磁碟，重播直接讀取（省流量、加速、離線可播）。超過上限依 LRU 自動淘汰最舊曲目；下限 16 MiB 可完整快取一首 320kbps 高品曲目（約 2.4 MiB/分鐘）。清除後自動重建，不影響曲庫、歷史與帳號。';

  @override
  String get settingsSongCacheOn => '已開啟，重播命中直接讀取本機檔案';

  @override
  String get settingsSongCacheOff => '已關閉，媒體快取將不會儲存到本機';

  @override
  String get settingsSongCacheLimitTitle => '快取上限';

  @override
  String settingsCacheSongs(Object count) {
    return '$count 首';
  }

  @override
  String get settingsSearchSongCacheSubtitle => '線上歌曲磁碟快取開關與 MiB 上限';

  @override
  String get settingsCacheLiked => '「我喜歡」清單快取';

  @override
  String get settingsCacheLyric => '歌詞內容快取';

  @override
  String get settingsCacheLyricMatch => '歌詞比對快取';

  @override
  String get settingsCacheLyricTtml => 'TTML 歌詞快取';

  @override
  String get settingsCacheCover => '封面圖片快取';

  @override
  String settingsCacheEntries(Object count) {
    return '$count 筆';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count 張';
  }

  @override
  String get settingsCacheRefresh => '重新整理';

  @override
  String get settingsCacheClear => '清除';

  @override
  String get settingsCacheClearAll => '全部清空';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '清除「$name」？';
  }

  @override
  String get settingsCacheClearConfirmDesc => '將刪除該快取下的全部資料，下次使用時自動重建，不可復原。';

  @override
  String get settingsCacheClearAllConfirmTitle => '全部清空快取？';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      '將刪除上方全部快取（記憶體與磁碟），不影響曲庫、歷史與帳號資訊。';

  @override
  String toastCacheCleared(Object name) {
    return '已清除$name快取';
  }

  @override
  String get toastCacheAllCleared => '已全部清空快取';

  @override
  String get settingsSecuritySection => '安全銷毀';

  @override
  String get settingsSecurityNote =>
      '不可逆地刪除本機全部帳號憑證與登入會話（串流伺服器密碼、網易雲/酷狗登入態、本機 Subsonic 帳號），並主動失效平台 token；不影響曲庫、歷史與下載檔案。';

  @override
  String get settingsSecurityStreaming => '串流伺服器憑證';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count 台伺服器';
  }

  @override
  String get settingsSecurityStreamingDesc => '密碼與存取權杖';

  @override
  String get settingsSecuritySession => '第三方帳號會話';

  @override
  String get settingsSecuritySessionDesc => '網易雲 / 酷狗 登入狀態';

  @override
  String get settingsSecurityUserDb => '本機使用者庫';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic 帳號與收藏資料';

  @override
  String get settingsSecurityLoggedIn => '已登入';

  @override
  String get settingsSecurityDestroy => '銷毀';

  @override
  String get settingsSecurityDestroyAll => '一鍵銷毀全部';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '銷毀「$name」？';
  }

  @override
  String get settingsSecurityConfirmAllTitle => '確認銷毀全部敏感資料？';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return '將主動失效相關平台 token、覆蓋寫入並刪除檔案，此操作不可恢復。輸入「$word」以確認。';
  }

  @override
  String get settingsSecurityConfirmWord => '銷毀';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return '輸入「$word」';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return '已銷毀：$name';
  }

  @override
  String get toastSecurityAllDestroyed => '全部敏感資料已銷毀';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return '銷毀失敗，檔案仍可能殘留：$path';
  }

  @override
  String get settingsDeviceBindSection => '進階 · 裝置綁定';

  @override
  String get settingsDeviceBindNote =>
      '增強型可選項（opt-in）：本機免密 + 裝置變更走復原密碼，不依賴系統安全儲存。開啟將讀取本機裝置識別碼（僅存本機、不會上傳）。預設關閉，一般使用者使用 v1 加密已足夠。';

  @override
  String get settingsDeviceBindSwitch => '裝置綁定免密';

  @override
  String get settingsDeviceBindSwitchDesc => '本機自動解鎖；換機/重裝走復原密碼';

  @override
  String get settingsDeviceBindSwitchOffDesc =>
      '未啟用。目前系統安全儲存無法使用，可開啟裝置綁定實現本機免密（無需密碼）';

  @override
  String get settingsDeviceBindSwitchV1Desc =>
      '目前為 v1（系統安全儲存）模式；開啟將升級為裝置綁定（免密 + 復原密碼，既有資料保留）';

  @override
  String get settingsDeviceBindSwitchV2Desc =>
      '目前為 v2（密碼）模式；開啟需先輸入目前密碼解鎖，隨後升級為裝置綁定（本機免密）';

  @override
  String get settingsDeviceBindPrivacyTitle => '開啟裝置綁定免密？';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      '將讀取本機裝置識別碼（Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID）用於綁定，僅儲存於本機，不會上傳。注意：此操作無法回到目前 OS 免密模式——日後關閉裝置綁定將回落為密碼模式（每次啟動需輸入密碼）。';

  @override
  String get settingsDeviceBindEnable => '開啟';

  @override
  String get settingsDeviceBindRecoveryTitle => '設定復原密碼（可選）';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      '換機/重裝後需使用復原密碼解鎖憑證。留空則不設定：裝置變更後無法復原（fail-closed，需銷毀重建憑證）。';

  @override
  String get settingsDeviceBindRecoveryHint => '復原密碼';

  @override
  String get settingsDeviceBindSkip => '不設密碼，直接開啟';

  @override
  String get settingsDeviceBindChangeRecovery => '設定 / 修改復原密碼';

  @override
  String get settingsDeviceBindChangeRecoveryTitle => '設定新的復原密碼';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      '修改後舊密碼立即失效。請務必記住新密碼：換機/重裝後憑證解鎖將依賴它。';

  @override
  String get settingsDeviceBindRebind => '重新綁定目前裝置';

  @override
  String get settingsDeviceBindRebindDesc => '使用目前裝置指紋重新密封，舊指紋立即失效（換機復原後使用）';

  @override
  String get settingsDeviceBindRebindTitle => '重新綁定目前裝置？';

  @override
  String get settingsDeviceBindRebindConfirm => '立即重新綁定';

  @override
  String get settingsDeviceBindClose => '關閉裝置綁定';

  @override
  String get settingsDeviceBindCloseDesc => '清除裝置熵綁定，vault 轉為密碼模式';

  @override
  String get settingsDeviceBindCloseTitle => '關閉裝置綁定？';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      '將刪除裝置熵綁定，vault 轉為密碼模式：此後每次工作階段需輸入密碼。該密碼即新工作階段密碼，請牢記。輸入目前復原密碼以確認。';

  @override
  String get settingsDeviceBindCloseHint => '目前復原密碼';

  @override
  String get settingsDeviceBindRecoveryBanner => '偵測到裝置變更或熵檔案損壞：憑證已鎖定，需復原密碼解鎖';

  @override
  String get settingsDeviceBindRecover => '復原';

  @override
  String get settingsDeviceBindRecoverTitle => '輸入復原密碼';

  @override
  String get settingsDeviceBindRecoverDesc => '使用復原密碼解鎖憑證；成功後建議立即重新綁定目前裝置恢復免密。';

  @override
  String get settingsDeviceBindShowPassword => '顯示 / 隱藏密碼';

  @override
  String get toastDeviceBindEnabled => '裝置綁定免密已開啟';

  @override
  String get toastDeviceBindRecoverySet => '復原密碼已更新';

  @override
  String get toastDeviceBindRebound => '已重新綁定目前裝置';

  @override
  String get toastDeviceBindClosed => '裝置綁定已關閉，vault 已轉為密碼模式';

  @override
  String get toastDeviceBindRecoveryNeeded => '未設定復原密碼，無法關閉裝置綁定';

  @override
  String toastDeviceBindCloseFailed(Object error) {
    return '關閉失敗：$error';
  }

  @override
  String get toastDeviceBindRecovered => '憑證已復原，可重新綁定本機恢復免密';

  @override
  String get toastDeviceBindRecoverFailed => '復原密碼錯誤或解鎖失敗，憑證保持鎖定';

  @override
  String get settingsSchemeIntroTitle => '加密方案說明';

  @override
  String get settingsSchemeIntroDesc =>
      '登入憑證（cookie）由加密方案保護。已為你啟用 LEGACY 方案（推薦）：主金鑰存於作業系統安全儲存，穩定可靠。如需更高安全性，可在「設定 → 憑證加密方案」切換到 Vault（實驗性）——注意該方案切換會重建資料庫並遺失全部登入憑證。';

  @override
  String get settingsSchemeIntroGotIt => '知道了，繼續';

  @override
  String get settingsSchemeSection => '憑證加密方案';

  @override
  String get settingsSchemeNote =>
      '選擇登入憑證的加密方案。LEGACY：作業系統安全儲存加密，穩定可靠（推薦）；FILK（檔案金鑰）：主金鑰存本機 secret.key，免 OS 鑰匙圈，供 Docker/無圖形環境使用（本機檔案單點風險）；Vault：2-of-2 雙因子實驗性方案，安全性更高但存在異常遺失 Cookie 風險。切換方案需重建資料庫並重新登入。';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => '推薦';

  @override
  String get settingsSchemeCryptoDesc =>
      'cookie 由作業系統安全儲存加密（Windows DPAPI / macOS 鑰匙圈 / Linux libsecret），穩定可靠。';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'LEGACY 方案：主金鑰整體由作業系統安全儲存保護，加密強度與可用性穩定，適合日常使用。';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => '相容';

  @override
  String get settingsSchemeFileDesc =>
      '主金鑰存於本機 secret.key 檔案（0600 權限），免 OS 鑰匙圈，供無圖形環境的 Docker/伺服器使用。本機檔案單點：金鑰檔案外洩即憑證全部外洩。';

  @override
  String get settingsSchemeFileModeDesc =>
      'FILK（檔案金鑰）方案：主金鑰落盤 secret.key（0600 原子寫入），經典的服務端加密形態；僅在無 OS 鑰匙圈的 headless/Docker 環境使用。';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => '實驗性';

  @override
  String get settingsSchemeVaultDesc =>
      '2-of-2 雙因子加密（系統份額 + 使用者份額缺一不可），對離線攻擊防護更強，但存在異常遺失 Cookie 風險。';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Vault 方案：主金鑰拆分為系統份額與使用者份額，雙因子缺一不可；可再選 v1 系統保護 / v2 密碼保護 / v3 裝置綁定加密等級。';

  @override
  String get settingsSchemeSwitchTitle => '切換加密方案？';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault 為實驗性方案：切換後存在異常遺失 Cookie 的風險。';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'FILK 為相容性降級方案：主金鑰存於本機檔案，一旦外洩全部憑證即暴露。僅限無 OS 鑰匙圈的 headless/Docker 環境使用。';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      '各方案加密資料結構不相容，切換將銷毀現有保險庫並重建資料庫，所有登入憑證（網易雲 / 酷狗 / 串流帳號）將遺失，需重新登入。';

  @override
  String get settingsSchemeSwitchKeep => '保持目前';

  @override
  String get settingsSchemeSwitchConfirm => '切換並重建';

  @override
  String get toastSchemeSwitched => '加密方案已切換，重啟後生效';

  @override
  String get settingsVaultSection => '憑證加密';

  @override
  String get settingsVaultNote =>
      '選擇憑證的加密保護等級：v1 系統保護（預設）/ v2 密碼保護 / v3 裝置綁定（增強項 opt-in，讀取本機裝置識別碼，僅存本機、不會上傳）。v1 ↔ v2 可隨時互切；v3 為終點檔，關閉後回落為 v2。';

  @override
  String get settingsVaultModeV1 => 'v1 系統保護';

  @override
  String get settingsVaultModeV2 => 'v2 密碼保護';

  @override
  String get settingsVaultModeV3 => 'v3 裝置綁定';

  @override
  String get settingsVaultModeDescOs =>
      'v1 系統保護：憑證由作業系統安全儲存加密（Windows DPAPI / macOS 鑰匙圈 / Linux libsecret），本機免密。';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 密碼保護：憑證由密碼加密，每次啟動需輸入密碼解鎖。可隨時切回 v1 系統保護。';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 裝置綁定：本機免密，裝置變更時需復原密碼解鎖。不可直接降回 v1——關閉後將回落為 v2 密碼模式。';

  @override
  String get settingsVaultModeDescUnknown => '加密等級讀取中…';

  @override
  String get settingsVaultSwitchToPasswordTitle => '切換到密碼保護（v2）';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      '憑證將改由密碼加密保護，每次啟動需輸入密碼。主金鑰與既有資料保留，此操作可隨時切回系統保護（v1）。';

  @override
  String get settingsVaultSwitchToPasswordNewHint => '設定新密碼';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint => '再次輸入新密碼';

  @override
  String get settingsVaultSwitchToPasswordMismatch => '兩次輸入不一致';

  @override
  String get settingsVaultSwitchToOsTitle => '切換回系統保護（v1）';

  @override
  String get settingsVaultSwitchToOsDesc =>
      '憑證將改由作業系統安全儲存保護，無需再輸入密碼。此操作可隨時切回密碼保護（v2）。';

  @override
  String get settingsVaultNeedUnlockFirst => '目前密碼保護未解鎖：請先解鎖後再切換';

  @override
  String get settingsVaultV3NoDirectV1 =>
      '裝置綁定（v3）不可直接降回 v1：請先關閉裝置綁定，回落為 v2 密碼模式';

  @override
  String get settingsVaultCloseV3PasswordTitle => '關閉裝置綁定：設定新密碼';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      '裝置綁定開啟時未設定復原密碼（本機免密），關閉後將轉為密碼保護（v2）：請設定新的解鎖密碼。主金鑰與既有資料保留，此密碼每次啟動都需輸入。';

  @override
  String get toastVaultSwitchedToPassword => '已切換到密碼保護（v2）';

  @override
  String get toastVaultSwitchedToOs => '已切換回系統保護（v1）';

  @override
  String get settingsVaultShareBrokenBanner =>
      '憑證保險庫份額不配對：儲存後端不符或份額缺失，本機憑證無法解密。需銷毀重建後重新登入。';

  @override
  String get settingsVaultShareBrokenRebuild => '銷毀重建';

  @override
  String get settingsVaultRestartTitle => '需要重新啟動應用程式';

  @override
  String get settingsVaultRestartDesc =>
      '加密等級已切換成功。為保證資料庫完整性與各模組狀態一致，請重新啟動應用程式生效。若為密碼保護模式（v2），重新啟動後將要求輸入密碼解鎖，解鎖前登入狀態與串流憑證暫時不可用（顯示為未登入）；重新啟動期間播放與下載會中斷。';

  @override
  String get settingsVaultRestartNow => '立即重新啟動';

  @override
  String get settingsVaultRestartLater => '稍後重新啟動';

  @override
  String get vaultCrashTitle => '憑證模組異常結束';

  @override
  String get vaultCrashDesc => '憑證保險庫程序意外終止，本機憑證可能已外洩。建議重新登入或銷毀 vault 以重建憑證。';

  @override
  String get vaultCrashReset => '銷毀並重建';

  @override
  String get vaultCrashDismiss => '知道了';

  @override
  String get vaultVersionTitle => '憑證保險庫版本異常';

  @override
  String get vaultVersionDesc =>
      '偵測到憑證保險庫元件異常：其二進位副本可能已被替換或非官方建置，本機憑證可能已暴露。已刪除異常副本並拒絕解密。請退出並重新安裝應用程式。';

  @override
  String get vaultVersionExit => '退出';

  @override
  String get vaultVersionReasonReplaced =>
      '偵測到 vault 二進位被替換或非官方建置，已刪除異常副本並拒絕解密。';

  @override
  String get vaultVersionReasonMarkerMissing => 'vault 握手應答缺少官方建置標記。';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'vault 建置標記與官方產物不符，已刪除異常副本並拒絕解密。';

  @override
  String get vaultUnlockTitle => '解鎖憑證保險庫';

  @override
  String get vaultUnlockDesc => '憑證保險庫為密碼保護模式（v2）。請輸入密碼以解鎖本機登入憑證與串流媒體帳號。';

  @override
  String get vaultUnlockHint => '密碼';

  @override
  String get vaultUnlockConfirm => '解鎖';

  @override
  String get vaultUnlockSkip => '暫不解鎖';

  @override
  String get vaultUnlockFailed => '密碼錯誤，請重試';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsVersionUnknown => 'v未知 · Flutter 桌面端';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter 桌面端';
  }

  @override
  String get settingsAudioEngine => '音訊引擎';

  @override
  String get settingsAudioEngineDesc => '內建 C 引擎（miniaudio）· 原生 FFI';

  @override
  String get settingsSubsonicServer => 'Subsonic 伺服端';

  @override
  String get settingsSubsonicDesc => 'Go FFI · 曲庫自託管';

  @override
  String get settingsAboutDesc => '自研音樂播放器：本機曲庫、直連音源、自託管 Subsonic、原生音訊引擎。';

  @override
  String get settingsSectionDeclaration => '軟體聲明';

  @override
  String get settingsDeclineText =>
      '本軟體（ArchoeraMusic）是一款免費、開源的桌面音樂播放器，為個人學習研究用途，非商業軟體。使用前請閱讀以下聲明：\n\n';

  @override
  String get settingsDecline1Title => '一、軟體性質\n';

  @override
  String get settingsDecline1Body =>
      '本軟體為第三方用戶端，與各音樂平台及其官方用戶端無任何關聯、合作或授權關係；不以營利為目的，不接受任何商業合作、廣告或捐贈。如需更完善的功能，請下載官方用戶端體驗。\n\n';

  @override
  String get settingsDecline2Title => '二、內容來源與版權\n';

  @override
  String get settingsDecline2Body =>
      '本軟體自身不提供、不儲存、不分發任何音樂內容。音訊、歌詞、封面等均來自您的本機檔案或各音樂平台公開介面，其版權歸原權利人及平台所有，本軟體不主張任何所有權。\n\n';

  @override
  String get settingsDecline3Title => '三、版權資料處理義務\n';

  @override
  String get settingsDecline3Body =>
      '使用過程中產生的版權資料（播放連結、歌詞、封面等）僅供您個人試聽與學習研究，請勿用於商業或公開傳播；建議在產生後 24 小時內清除。如需長期欣賞，請透過正版管道購買或訂閱，支援正版音樂。\n\n';

  @override
  String get settingsDecline4Title => '四、使用限制\n';

  @override
  String get settingsDecline4Body =>
      '請勿利用本軟體從事商業行為、批量抓取、爬取或轉售內容；請勿在違反當地法律法規或相關平台服務條款的情況下使用本軟體；請勿繞過線上平台的技術保護措施、存取控制或服務條款。\n\n';

  @override
  String get settingsDecline5Title => '五、免責聲明\n';

  @override
  String get settingsDecline5Body =>
      '本軟體按「現狀」提供，不對其作出任何明示或默示的保證。因使用或無法使用本軟體，或因線上平台介面變更、帳號限制、功能失效等產生的任何直接或間接損失，均由使用者自行承擔。\n\n';

  @override
  String get settingsDeclineFooter =>
      '本軟體僅用於技術探索與研究。如相關平台認為本軟體不妥，可隨時聯繫開發者進行調整或移除。';

  @override
  String get settingsSectionFontCredits => '字體署名';

  @override
  String get settingsFontCreditsText =>
      '本軟體內建以下字體：\n· Noto Sans CJK SC（SIL Open Font License 1.1）\n· MiSans（© Xiaomi，依據《MiSans 字體知識產權許可協議》授權使用）\n· HarmonyOS Sans SC（© Huawei，依據《HarmonyOS Sans 字體許可協議》授權使用）';

  @override
  String get commonNoLyrics => '暫無歌詞';

  @override
  String commonTrackCount(Object count) {
    return '$count 首';
  }

  @override
  String get settingsSearchColorTitle => '已唱 / 未唱顏色';

  @override
  String get settingsSearchColorSubtitle => '歌詞行高亮與普通行顏色';

  @override
  String get settingsSearchDesktopLyricsTitle => '桌面歌詞';

  @override
  String get settingsSearchDesktopLyricsSubtitle => '置頂獨立歌詞視窗';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => '檔名模板';

  @override
  String get settingsSearchAccentSubtitle => '自訂主色種子 · 色板';

  @override
  String get settingsThemeSource => '主題色來源';

  @override
  String get settingsThemeSourceDesc => '主題色的取得方式';

  @override
  String get settingsThemeSourceDefault => '跟隨系統';

  @override
  String get settingsThemeSourceCustom => '自訂主色';

  @override
  String get settingsThemeSourceCover => '跟隨封面';

  @override
  String get settingsThemeSourceSolid => '無主題色';

  @override
  String get settingsThemeSourceCustomHint => '選取主色種子，主/次色由它動態產生';

  @override
  String get settingsThemeSourceCoverHint => '即時從目前播放封面擷取主色（無法取得時回退預設色）';

  @override
  String get settingsGlobalTint => '全域著色';

  @override
  String get settingsGlobalTintDesc => '將主題色套用到全域介面';

  @override
  String get settingsGlobalTintNote => '存在主題色（自訂/跟隨封面）時生效；圖片背景模式下強制開啟。';

  @override
  String get settingsSectionStyle => '背景風格';

  @override
  String get settingsAppearanceStyle => '外觀風格';

  @override
  String get settingsAppearanceStyleDesc => '應用主背景的呈現方式';

  @override
  String get settingsAppearanceStyleSolid => '純色背景';

  @override
  String get settingsAppearanceStyleImage => '自訂圖片';

  @override
  String get settingsBackgroundImage => '背景圖片';

  @override
  String get settingsBackgroundImageDesc => '選擇本機圖片作為應用背景；圖片模式強制深色 + 全域著色';

  @override
  String get settingsBackgroundPick => '選擇圖片';

  @override
  String get settingsBackgroundReplace => '更換';

  @override
  String get settingsBackgroundClear => '清除';

  @override
  String get settingsBackgroundBlur => '背景模糊';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return '對背景圖片套用高斯模糊（${blur}px）';
  }

  @override
  String get settingsBackgroundDim => '遮罩濃度';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return '疊加的黑色遮罩透明度（$dim%），越高前景越易讀';
  }

  @override
  String get settingsBackgroundScale => '縮放大小';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return '背景圖的縮放倍數（${scale}x）';
  }

  @override
  String get settingsSidebarCollapsed => '摺疊側邊欄';

  @override
  String get settingsSidebarCollapsedDesc => '將側邊欄摺疊為圖示模式';

  @override
  String get settingsSidebarNavStyle => '導覽高亮動效';

  @override
  String get settingsSidebarNavStyleDesc => '切換側邊欄導覽高亮指示器的動畫風格';

  @override
  String get settingsSidebarNavStyleDefault => '靜態';

  @override
  String get settingsSidebarNavStyleAnimated => '滑動';

  @override
  String get settingsRouteTransition => '頁面切換動效';

  @override
  String get settingsRouteTransitionDesc => '切換頁面時的轉場動畫效果';

  @override
  String get settingsRouteTransitionNone => '無';

  @override
  String get settingsRouteTransitionFade => '淡入淡出';

  @override
  String get settingsRouteTransitionSlide => '滑動';

  @override
  String get settingsRouteTransitionZoom => '縮放';

  @override
  String get settingsSearchThemeSourceSubtitle => '預設主題色 · 自訂主色 · 跟隨封面 · 無主題色';

  @override
  String get settingsSearchGlobalTintSubtitle => '將主題色套用到全域介面';

  @override
  String get settingsSearchBackgroundSubtitle => '純色 / 圖片 · 模糊 · 遮罩 · 縮放';

  @override
  String get settingsSearchSidebarSubtitle => '摺疊側邊欄 · 靜態 / 滑動高亮';

  @override
  String get settingsSearchRouteTransitionSubtitle => '無 · 淡入淡出 · 滑動 · 縮放';

  @override
  String get settingsSearchFloatingBarSubtitle => '底部懸浮膠囊 · 全寬停靠';

  @override
  String get settingsSearchFontSubtitle => 'MiSans · HarmonyOS Sans TC';

  @override
  String get settingsSearchLanguageSubtitle => '跟隨系統 · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle => '直角 · 圓角 · 大圓角';

  @override
  String get settingsSectionWeather => '天氣';

  @override
  String get settingsWeather => '天氣元件';

  @override
  String get settingsWeatherDesc => '頭像左側顯示微型天氣（圖示 + 溫度）';

  @override
  String get settingsWeatherAutoLocate => '自動定位';

  @override
  String get settingsWeatherAutoLocateDesc => '依網路 IP 取得大致位置查詢天氣（涉及隱私，預設關閉）';

  @override
  String get settingsWeatherCity => '手動城市';

  @override
  String get settingsWeatherCityHint => '填寫城市名後不再進行 IP 定位（例如：杭州）';

  @override
  String get settingsWeatherNote =>
      '隱私說明：天氣資料來自 Open-Meteo（免費、無需金鑰）。開啟「自動定位」時，本機 IP 會傳送至 ip-api.com 換取大致位置，僅用於查詢天氣、不落盤。天氣元件與定位預設均關閉。';

  @override
  String get settingsSearchWeatherSubtitle => '頂欄顯示微型天氣元件（圖示 + 溫度）';

  @override
  String get weatherRefresh => '重新整理天氣';

  @override
  String get weatherNoLocation => '請在設定中填寫城市或開啟自動定位';

  @override
  String get weatherUnavailable => '天氣取得失敗，點擊重試';

  @override
  String get settingsSearchPassthroughSubtitle => '不轉碼 · 48kHz 轉碼管線';

  @override
  String get settingsSearchSessionMemorySubtitle => '記錄/恢復播放現場';

  @override
  String get settingsSearchAutoPlaySubtitle => '自動續播開關';

  @override
  String get settingsSearchSpectrumSubtitle => '播放介面頻譜開關 · 透明度';

  @override
  String get settingsSearchSpectrumWidthSubtitle => '1~12px 柱寬調節';

  @override
  String get settingsSearchPlayerLyricsSubtitle => '全螢幕播放器歌詞顯示';

  @override
  String get settingsSearchLyricFontSizeSubtitle => '14~28px 播放器歌詞字級';

  @override
  String get settingsSearchLyricLineHeightSubtitle => '42~64px 行高調節';

  @override
  String get settingsSearchUncensorSubtitle => '還原歌詞中被星號遮蓋的詞';

  @override
  String get settingsSearchHideVipSubtitle => '歌曲列表 VIP / 付費角標隱藏';

  @override
  String get settingsSearchHideQualitySubtitle => '歌曲列表音質角標隱藏';

  @override
  String get settingsSearchSubtitleSubtitle => '歌曲列表展示別名（如 (Live)）';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      '下載儲存位置（預設 ~/Music/ArchoeraMusic）';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> 佔位符可配置';

  @override
  String get settingsSearchConcurrentSubtitle => '1~5 個平行下載任務';

  @override
  String get settingsSearchSpeedLimitSubtitle => '不限速 · 0.5~20 MB/s 即時生效';

  @override
  String get settingsSearchQualitySubtitle => 'Hi-Res · 無損 · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle => '平鋪 · 按平台 · 按歌手';

  @override
  String get settingsSearchHistoryLimitSubtitle => '超上限自動淘汰最舊（10~500）';

  @override
  String get settingsSearchStorageSubtitle => '媒體庫 · 使用者資料庫路徑';

  @override
  String get settingsSearchAboutSubtitle => '音訊引擎 · Subsonic 伺服端';

  @override
  String get qualityLossless => '無損';

  @override
  String get repeatModeList => '列表循環';

  @override
  String get repeatModeOne => '單曲循環';

  @override
  String get commonUnknownTrack => '未知名歌曲';

  @override
  String get commonAnonymousUser => '匿名使用者';

  @override
  String get commonCanceled => '已取消';

  @override
  String get commonILike => '我喜歡';

  @override
  String get sidebarStreaming => '串流媒體';

  @override
  String get settingsCatMediaSource => '媒體來源';

  @override
  String get settingsMediaSourceSubtitle =>
      '串流媒體伺服器（Subsonic / Jellyfin / Emby）';

  @override
  String get settingsCatScrape => '刮削';

  @override
  String get settingsScrapeSubtitle => '多來源中繼資料補齊 · 封面 / 歌詞 / 標籤';

  @override
  String get settingsSectionScrapeDirs => '刮削目錄';

  @override
  String get settingsScrapeDirsHint => '每行一個目錄；留空跟隨媒體庫掃描目錄';

  @override
  String get settingsScrapeDirsEmptyNote => '未設定刮削目錄，刮削時將跟隨媒體庫掃描目錄。';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return '目前生效目錄：$dirs';
  }

  @override
  String get settingsSectionScrapeSources => '資料來源';

  @override
  String get settingsScrapeSourceMusicBrainz => 'MusicBrainz';

  @override
  String get settingsScrapeSourceDeezer => 'Deezer';

  @override
  String get settingsScrapeSourceItunes => 'iTunes';

  @override
  String get settingsScrapeSourceNetease => '網易雲音樂';

  @override
  String get settingsScrapeSourceQQMusic => 'QQ 音樂';

  @override
  String get settingsScrapeSourceKugou => '酷狗音樂';

  @override
  String get settingsScrapeSourceKuwo => '酷我音樂';

  @override
  String get settingsScrapeSourceMigu => '咪咕音樂';

  @override
  String get settingsScrapeSourceAcoustID => 'AcoustID（音訊指紋）';

  @override
  String get settingsScrapeSourceDesc => '開啟後參與多來源查詢、相似度比對與評分合併';

  @override
  String get settingsSectionScrapeProgress => '刮削進度';

  @override
  String get settingsScrapeStart => '開始刮削';

  @override
  String get settingsScrapeCancel => '取消刮削';

  @override
  String get settingsScrapeScanning => '正在掃描目錄…';

  @override
  String settingsScrapeCurrent(Object file) {
    return '正在處理：$file';
  }

  @override
  String get settingsScrapeSuccess => '成功';

  @override
  String get settingsScrapeFailed => '失敗';

  @override
  String get settingsScrapeSkipped => '略過';

  @override
  String get settingsScrapeNotFound => '未比對';

  @override
  String get settingsScrapeIdle => '尚未刮削，點擊下方按鈕開始。';

  @override
  String get settingsScrapeNoDirs => '沒有可刮削的目錄，請先設定刮削目錄或媒體庫掃描目錄。';

  @override
  String get settingsScrapeDone => '刮削完成';

  @override
  String get settingsScrapeCanceled => '刮削已取消';

  @override
  String get toastScrapeNoDirs => '沒有可刮削的目錄';

  @override
  String get toastScrapeDirsUpdated => '刮削目錄已儲存';

  @override
  String get toastScrapeStarted => '已開始刮削';

  @override
  String get commonDelete => '刪除';

  @override
  String get commonSave => '儲存';

  @override
  String get commonConfirm => '確定';

  @override
  String get streamingHint => '媒體來源';

  @override
  String get streamingHintDetail =>
      '新增串流媒體伺服器，瀏覽並播放伺服器上的音樂（支援 Subsonic 家族 / Jellyfin / Emby，含本機內建 Subsonic 伺服器）。';

  @override
  String get streamingServerAdd => '新增伺服器';

  @override
  String get streamingEmptyNoServer => '還沒有串流媒體伺服器';

  @override
  String get streamingEmptyAddHint => '點擊上方按鈕新增一個伺服器';

  @override
  String get streamingServerConnected => '已連線';

  @override
  String get streamingServerDisconnected => '未連線';

  @override
  String get streamingServerLastConnected => '最近連線';

  @override
  String get streamingServerDisconnect => '中斷連線';

  @override
  String get streamingToastDisconnected => '已中斷伺服器連線';

  @override
  String get streamingServerConnect => '連線';

  @override
  String streamingToastConnected(Object name) {
    return '已連線 $name';
  }

  @override
  String get streamingServerConnectFailed => '連線失敗';

  @override
  String get streamingServerEdit => '編輯';

  @override
  String get streamingServerDeleteConfirmTitle => '刪除伺服器';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return '確定刪除伺服器「$name」嗎？';
  }

  @override
  String get streamingServerRemoved => '伺服器已刪除';

  @override
  String get streamingServerErrorNameEmpty => '請輸入伺服器名稱';

  @override
  String get streamingServerErrorHostEmpty => '請輸入伺服器位址';

  @override
  String get streamingServerErrorPortInvalid => '連接埠無效（1~65535）';

  @override
  String get streamingServerErrorUsernameEmpty => '請輸入使用者名稱';

  @override
  String get streamingServerErrorPasswordEmpty => '請輸入密碼';

  @override
  String get streamingServerAdded => '伺服器已新增';

  @override
  String get streamingServerUpdated => '伺服器已更新';

  @override
  String get streamingServerType => '類型';

  @override
  String get streamingServerName => '名稱';

  @override
  String get streamingServerNamePlaceholder => '例如：我的 Navidrome';

  @override
  String get streamingServerHost => '伺服器位址';

  @override
  String get streamingServerHostPlaceholder => '例如：192.168.1.10:4533';

  @override
  String get streamingServerPort => '連接埠';

  @override
  String get streamingServerPortNote =>
      '預設連接埠為 4533（Subsonic）/ 8096（Jellyfin）；留空自動比對。';

  @override
  String get streamingServerLocalTitle => '本機內建伺服器';

  @override
  String get streamingServerLocalDesc => '使用內建 Subsonic 伺服器（本機媒體庫）';

  @override
  String get streamingServerUsername => '使用者名稱';

  @override
  String get streamingServerPassword => '密碼';

  @override
  String get streamingServerTestOk => '連線成功';

  @override
  String get streamingServerTestFail => '連線失敗';

  @override
  String get streamingServerTest => '測試連線';

  @override
  String get streamingTabsSongs => '歌曲';

  @override
  String get streamingTabsAlbums => '專輯';

  @override
  String get streamingTabsArtists => '歌手';

  @override
  String get streamingTabsPlaylists => '播放清單';

  @override
  String get streamingEmptyGoToSettings => '前往設定';

  @override
  String get streamingEmptyNotConnected => '未連線到任何伺服器';

  @override
  String streamingTotalSongs(Object count) {
    return '$count 首歌曲';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count 張專輯';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count 位歌手';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count 個播放清單';
  }

  @override
  String get streamingEmptyNoResults => '沒有相符的結果';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count 首歌曲';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count 張專輯';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count 首歌曲';
  }
}
