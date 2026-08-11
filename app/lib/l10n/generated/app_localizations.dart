import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('ja'),
    Locale('ko'),
    Locale('zh'),
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @menuTrackDetail.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体详细信息'**
  String get menuTrackDetail;

  /// No description provided for @trackDetailDuration.
  ///
  /// In zh_CN, this message translates to:
  /// **'时长'**
  String get trackDetailDuration;

  /// No description provided for @trackDetailArtist.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌手'**
  String get trackDetailArtist;

  /// No description provided for @trackDetailAlbum.
  ///
  /// In zh_CN, this message translates to:
  /// **'专辑'**
  String get trackDetailAlbum;

  /// No description provided for @trackDetailSource.
  ///
  /// In zh_CN, this message translates to:
  /// **'来源'**
  String get trackDetailSource;

  /// No description provided for @trackDetailPath.
  ///
  /// In zh_CN, this message translates to:
  /// **'路径'**
  String get trackDetailPath;

  /// No description provided for @trackDetailFileSize.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件大小'**
  String get trackDetailFileSize;

  /// No description provided for @trackDetailCodec.
  ///
  /// In zh_CN, this message translates to:
  /// **'编码'**
  String get trackDetailCodec;

  /// No description provided for @trackDetailSampleRate.
  ///
  /// In zh_CN, this message translates to:
  /// **'采样率'**
  String get trackDetailSampleRate;

  /// No description provided for @trackDetailBitDepth.
  ///
  /// In zh_CN, this message translates to:
  /// **'位深'**
  String get trackDetailBitDepth;

  /// No description provided for @trackDetailBitrate.
  ///
  /// In zh_CN, this message translates to:
  /// **'比特率'**
  String get trackDetailBitrate;

  /// No description provided for @trackDetailChannels.
  ///
  /// In zh_CN, this message translates to:
  /// **'声道'**
  String get trackDetailChannels;

  /// No description provided for @trackSourceLocal.
  ///
  /// In zh_CN, this message translates to:
  /// **'本地文件'**
  String get trackSourceLocal;

  /// No description provided for @trackSourceStreaming.
  ///
  /// In zh_CN, this message translates to:
  /// **'流媒体'**
  String get trackSourceStreaming;

  /// No description provided for @trackDetailQuality.
  ///
  /// In zh_CN, this message translates to:
  /// **'音质'**
  String get trackDetailQuality;

  /// No description provided for @batchSelectAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'全选'**
  String get batchSelectAll;

  /// No description provided for @batchInvert.
  ///
  /// In zh_CN, this message translates to:
  /// **'反选'**
  String get batchInvert;

  /// No description provided for @batchPlay.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放所选'**
  String get batchPlay;

  /// No description provided for @batchAddQueue.
  ///
  /// In zh_CN, this message translates to:
  /// **'加入队列'**
  String get batchAddQueue;

  /// No description provided for @batchDownload.
  ///
  /// In zh_CN, this message translates to:
  /// **'批量下载'**
  String get batchDownload;

  /// No description provided for @batchExit.
  ///
  /// In zh_CN, this message translates to:
  /// **'退出多选'**
  String get batchExit;

  /// No description provided for @batchSelectHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'批量选择'**
  String get batchSelectHint;

  /// No description provided for @toastBatchAddedToQueue.
  ///
  /// In zh_CN, this message translates to:
  /// **'已加入播放队列 {count} 首'**
  String toastBatchAddedToQueue(Object count);

  /// No description provided for @toastBatchAddedToDownloadQueue.
  ///
  /// In zh_CN, this message translates to:
  /// **'已加入下载队列 {count} 首'**
  String toastBatchAddedToDownloadQueue(Object count);

  /// No description provided for @settingsBarEnhancedLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条高级歌词'**
  String get settingsBarEnhancedLyrics;

  /// No description provided for @settingsBarEnhancedLyricsOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词含逐字时间轴时显示卡拉OK高亮'**
  String get settingsBarEnhancedLyricsOn;

  /// No description provided for @settingsBarEnhancedLyricsOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条始终显示普通歌词'**
  String get settingsBarEnhancedLyricsOff;

  /// No description provided for @settingsSectionClose.
  ///
  /// In zh_CN, this message translates to:
  /// **'关闭应用'**
  String get settingsSectionClose;

  /// No description provided for @settingsCloseBehavior.
  ///
  /// In zh_CN, this message translates to:
  /// **'关闭应用时'**
  String get settingsCloseBehavior;

  /// No description provided for @settingsCloseBehaviorAsk.
  ///
  /// In zh_CN, this message translates to:
  /// **'每次询问'**
  String get settingsCloseBehaviorAsk;

  /// No description provided for @settingsCloseBehaviorBackground.
  ///
  /// In zh_CN, this message translates to:
  /// **'后台播放'**
  String get settingsCloseBehaviorBackground;

  /// No description provided for @settingsCloseBehaviorQuit.
  ///
  /// In zh_CN, this message translates to:
  /// **'直接退出'**
  String get settingsCloseBehaviorQuit;

  /// No description provided for @commonCloseConfirmTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'退出应用'**
  String get commonCloseConfirmTitle;

  /// No description provided for @commonCloseConfirmMessage.
  ///
  /// In zh_CN, this message translates to:
  /// **'关闭主窗口后将'**
  String get commonCloseConfirmMessage;

  /// No description provided for @commonCloseConfirmRemember.
  ///
  /// In zh_CN, this message translates to:
  /// **'记住我的选择，不再询问'**
  String get commonCloseConfirmRemember;

  /// No description provided for @appName.
  ///
  /// In zh_CN, this message translates to:
  /// **'ArchoeraMusic'**
  String get appName;

  /// No description provided for @brandNetease.
  ///
  /// In zh_CN, this message translates to:
  /// **'网易云音乐'**
  String get brandNetease;

  /// No description provided for @brandKugou.
  ///
  /// In zh_CN, this message translates to:
  /// **'酷狗音乐'**
  String get brandKugou;

  /// No description provided for @commonBack.
  ///
  /// In zh_CN, this message translates to:
  /// **'返回'**
  String get commonBack;

  /// No description provided for @commonCancel.
  ///
  /// In zh_CN, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonClose.
  ///
  /// In zh_CN, this message translates to:
  /// **'关闭'**
  String get commonClose;

  /// No description provided for @commonDefault.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认'**
  String get commonDefault;

  /// No description provided for @commonGoLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'去登录'**
  String get commonGoLogin;

  /// No description provided for @commonLike.
  ///
  /// In zh_CN, this message translates to:
  /// **'喜欢'**
  String get commonLike;

  /// No description provided for @commonLoading.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载中'**
  String get commonLoading;

  /// No description provided for @commonLossless.
  ///
  /// In zh_CN, this message translates to:
  /// **'无损'**
  String get commonLossless;

  /// No description provided for @commonMore.
  ///
  /// In zh_CN, this message translates to:
  /// **'更多'**
  String get commonMore;

  /// No description provided for @commonNext.
  ///
  /// In zh_CN, this message translates to:
  /// **'下一首'**
  String get commonNext;

  /// No description provided for @commonNoMore.
  ///
  /// In zh_CN, this message translates to:
  /// **'没有更多了'**
  String get commonNoMore;

  /// No description provided for @commonPrevious.
  ///
  /// In zh_CN, this message translates to:
  /// **'上一首'**
  String get commonPrevious;

  /// No description provided for @commonSettings.
  ///
  /// In zh_CN, this message translates to:
  /// **'全局设置'**
  String get commonSettings;

  /// No description provided for @commonUnknownAlbum.
  ///
  /// In zh_CN, this message translates to:
  /// **'未知专辑'**
  String get commonUnknownAlbum;

  /// No description provided for @commonUnknownArtist.
  ///
  /// In zh_CN, this message translates to:
  /// **'未知歌手'**
  String get commonUnknownArtist;

  /// No description provided for @commonUnlike.
  ///
  /// In zh_CN, this message translates to:
  /// **'取消喜欢'**
  String get commonUnlike;

  /// No description provided for @downloadQualityTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载音质'**
  String get downloadQualityTitle;

  /// No description provided for @downloadRequiresLoginContent.
  ///
  /// In zh_CN, this message translates to:
  /// **'获取{platform}下载链接需登录，未登录只能试听，无法下载完整音质。\n\n请先登录{platform}账号后重试。'**
  String downloadRequiresLoginContent(Object platform);

  /// No description provided for @downloadRequiresLoginTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载需要登录'**
  String get downloadRequiresLoginTitle;

  /// No description provided for @menuComment.
  ///
  /// In zh_CN, this message translates to:
  /// **'查看评论'**
  String get menuComment;

  /// No description provided for @menuDownload.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载'**
  String get menuDownload;

  /// No description provided for @menuLike.
  ///
  /// In zh_CN, this message translates to:
  /// **'添加到收藏'**
  String get menuLike;

  /// No description provided for @menuPlay.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放'**
  String get menuPlay;

  /// No description provided for @menuPlayNext.
  ///
  /// In zh_CN, this message translates to:
  /// **'下一首播放'**
  String get menuPlayNext;

  /// No description provided for @menuRemoveFromQueue.
  ///
  /// In zh_CN, this message translates to:
  /// **'从队列移除'**
  String get menuRemoveFromQueue;

  /// No description provided for @menuUnlike.
  ///
  /// In zh_CN, this message translates to:
  /// **'取消收藏'**
  String get menuUnlike;

  /// No description provided for @navHeaderAccount.
  ///
  /// In zh_CN, this message translates to:
  /// **'账号'**
  String get navHeaderAccount;

  /// No description provided for @navHeaderComingSoon.
  ///
  /// In zh_CN, this message translates to:
  /// **'敬请期待'**
  String get navHeaderComingSoon;

  /// No description provided for @navHeaderKugouId.
  ///
  /// In zh_CN, this message translates to:
  /// **'酷狗 {id}'**
  String navHeaderKugouId(Object id);

  /// No description provided for @navHeaderKugouMusic.
  ///
  /// In zh_CN, this message translates to:
  /// **'酷狗音乐'**
  String get navHeaderKugouMusic;

  /// No description provided for @navHeaderLoginAccount.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录账号（网易云 / 酷狗）'**
  String get navHeaderLoginAccount;

  /// No description provided for @navHeaderLogout.
  ///
  /// In zh_CN, this message translates to:
  /// **'退出登录'**
  String get navHeaderLogout;

  /// No description provided for @navHeaderNeteaseAccount.
  ///
  /// In zh_CN, this message translates to:
  /// **'网易云账号'**
  String get navHeaderNeteaseAccount;

  /// No description provided for @navHeaderNeteaseMusic.
  ///
  /// In zh_CN, this message translates to:
  /// **'网易云音乐'**
  String get navHeaderNeteaseMusic;

  /// No description provided for @navHeaderQqMusic.
  ///
  /// In zh_CN, this message translates to:
  /// **'QQ 音乐'**
  String get navHeaderQqMusic;

  /// No description provided for @navHeaderQrLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫码登录'**
  String get navHeaderQrLogin;

  /// No description provided for @navHeaderSearchHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'搜索歌曲 / 歌手 / 歌单'**
  String get navHeaderSearchHint;

  /// No description provided for @navHeaderThemeDark.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题：暗色'**
  String get navHeaderThemeDark;

  /// No description provided for @navHeaderThemeLight.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题：亮色'**
  String get navHeaderThemeLight;

  /// No description provided for @navHeaderThemeSystem.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题：跟随系统'**
  String get navHeaderThemeSystem;

  /// No description provided for @playerBarBuffering.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载中…'**
  String get playerBarBuffering;

  /// No description provided for @playerBarIdleHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'点击侧边栏或加载源开始播放'**
  String get playerBarIdleHint;

  /// No description provided for @playerBarOpenPlayer.
  ///
  /// In zh_CN, this message translates to:
  /// **'打开播放页'**
  String get playerBarOpenPlayer;

  /// No description provided for @playerBarPlayPause.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放/暂停'**
  String get playerBarPlayPause;

  /// No description provided for @playerBarPlaylist.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放列表'**
  String get playerBarPlaylist;

  /// No description provided for @playerBarUntitled.
  ///
  /// In zh_CN, this message translates to:
  /// **'未命名'**
  String get playerBarUntitled;

  /// No description provided for @queueClear.
  ///
  /// In zh_CN, this message translates to:
  /// **'清空队列'**
  String get queueClear;

  /// No description provided for @queueEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'队列为空'**
  String get queueEmpty;

  /// No description provided for @queueEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'在列表中选择歌曲后将出现在这里'**
  String get queueEmptyHint;

  /// No description provided for @queueRepeatList.
  ///
  /// In zh_CN, this message translates to:
  /// **'列表循环'**
  String get queueRepeatList;

  /// No description provided for @queueRepeatMode.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放模式'**
  String get queueRepeatMode;

  /// No description provided for @queueRepeatOne.
  ///
  /// In zh_CN, this message translates to:
  /// **'单曲循环'**
  String get queueRepeatOne;

  /// No description provided for @queueShuffle.
  ///
  /// In zh_CN, this message translates to:
  /// **'随机播放'**
  String get queueShuffle;

  /// No description provided for @queueShuffleOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'关闭随机播放'**
  String get queueShuffleOff;

  /// No description provided for @queueTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放队列'**
  String get queueTitle;

  /// No description provided for @queueTrackCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首'**
  String queueTrackCount(Object count);

  /// No description provided for @sidebarBackHome.
  ///
  /// In zh_CN, this message translates to:
  /// **'返回首页'**
  String get sidebarBackHome;

  /// No description provided for @sidebarCollapse.
  ///
  /// In zh_CN, this message translates to:
  /// **'折叠侧边栏'**
  String get sidebarCollapse;

  /// No description provided for @sidebarDownload.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载'**
  String get sidebarDownload;

  /// No description provided for @sidebarExpand.
  ///
  /// In zh_CN, this message translates to:
  /// **'展开侧边栏'**
  String get sidebarExpand;

  /// No description provided for @sidebarFavorites.
  ///
  /// In zh_CN, this message translates to:
  /// **'收藏'**
  String get sidebarFavorites;

  /// No description provided for @sidebarGroupMusic.
  ///
  /// In zh_CN, this message translates to:
  /// **'音乐'**
  String get sidebarGroupMusic;

  /// No description provided for @sidebarGroupPersonal.
  ///
  /// In zh_CN, this message translates to:
  /// **'个人'**
  String get sidebarGroupPersonal;

  /// No description provided for @sidebarHistory.
  ///
  /// In zh_CN, this message translates to:
  /// **'历史'**
  String get sidebarHistory;

  /// No description provided for @sidebarHome.
  ///
  /// In zh_CN, this message translates to:
  /// **'首页'**
  String get sidebarHome;

  /// No description provided for @sidebarLibrary.
  ///
  /// In zh_CN, this message translates to:
  /// **'音乐库'**
  String get sidebarLibrary;

  /// No description provided for @sidebarLiked.
  ///
  /// In zh_CN, this message translates to:
  /// **'我喜欢'**
  String get sidebarLiked;

  /// No description provided for @songListAlbum.
  ///
  /// In zh_CN, this message translates to:
  /// **'专辑'**
  String get songListAlbum;

  /// No description provided for @songListDuration.
  ///
  /// In zh_CN, this message translates to:
  /// **'时长'**
  String get songListDuration;

  /// No description provided for @songListTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'标题'**
  String get songListTitle;

  /// No description provided for @toastAddedToDownloadQueue.
  ///
  /// In zh_CN, this message translates to:
  /// **'已加入下载队列：{quality}'**
  String toastAddedToDownloadQueue(Object quality);

  /// No description provided for @toastAddedToQueue.
  ///
  /// In zh_CN, this message translates to:
  /// **'已加入播放队列'**
  String get toastAddedToQueue;

  /// No description provided for @toastDownloadEngineNotReady.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载引擎未就绪，请稍后再试'**
  String get toastDownloadEngineNotReady;

  /// No description provided for @toastLiked.
  ///
  /// In zh_CN, this message translates to:
  /// **'已添加到收藏'**
  String get toastLiked;

  /// No description provided for @toastLoginRequiredKugou.
  ///
  /// In zh_CN, this message translates to:
  /// **'操作失败（请确认已登录酷狗账号）'**
  String get toastLoginRequiredKugou;

  /// No description provided for @toastLoginRequiredNetease.
  ///
  /// In zh_CN, this message translates to:
  /// **'操作失败（请确认已登录网易云账号）'**
  String get toastLoginRequiredNetease;

  /// No description provided for @toastNoQualityInfo.
  ///
  /// In zh_CN, this message translates to:
  /// **'该曲目无可用音质信息，无法下载'**
  String get toastNoQualityInfo;

  /// No description provided for @toastUnliked.
  ///
  /// In zh_CN, this message translates to:
  /// **'已取消收藏'**
  String get toastUnliked;

  /// No description provided for @commonClear.
  ///
  /// In zh_CN, this message translates to:
  /// **'清除'**
  String get commonClear;

  /// No description provided for @commonEmptyContent.
  ///
  /// In zh_CN, this message translates to:
  /// **'暂无内容'**
  String get commonEmptyContent;

  /// No description provided for @commonLoadFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载失败：{msg}'**
  String commonLoadFailed(Object msg);

  /// No description provided for @commonRetry.
  ///
  /// In zh_CN, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// No description provided for @commentDuplicate.
  ///
  /// In zh_CN, this message translates to:
  /// **'请勿重复发送相同内容'**
  String get commentDuplicate;

  /// No description provided for @commentEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'暂时没有评论'**
  String get commentEmpty;

  /// No description provided for @commentHot.
  ///
  /// In zh_CN, this message translates to:
  /// **'热门'**
  String get commentHot;

  /// No description provided for @commentInputEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'评论内容不能为空'**
  String get commentInputEmpty;

  /// No description provided for @commentInputHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'说点什么…'**
  String get commentInputHint;

  /// No description provided for @commentLatest.
  ///
  /// In zh_CN, this message translates to:
  /// **'最新'**
  String get commentLatest;

  /// No description provided for @commentLoginRequired.
  ///
  /// In zh_CN, this message translates to:
  /// **'发送评论需要登录{platform}账号'**
  String commentLoginRequired(Object platform);

  /// No description provided for @commentNotFound.
  ///
  /// In zh_CN, this message translates to:
  /// **'未找到该歌曲的{platform}评论'**
  String commentNotFound(Object platform);

  /// No description provided for @commentPublished.
  ///
  /// In zh_CN, this message translates to:
  /// **'评论已发布'**
  String get commentPublished;

  /// No description provided for @commentReplyFormat.
  ///
  /// In zh_CN, this message translates to:
  /// **'@{user}：{text}'**
  String commentReplyFormat(Object text, Object user);

  /// No description provided for @commentSend.
  ///
  /// In zh_CN, this message translates to:
  /// **'发送'**
  String get commentSend;

  /// No description provided for @commentSendFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'发送失败：{msg}'**
  String commentSendFailed(Object msg);

  /// No description provided for @commentTimeFormat.
  ///
  /// In zh_CN, this message translates to:
  /// **'{month}月{day}日 {time}'**
  String commentTimeFormat(Object day, Object month, Object time);

  /// No description provided for @commentTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌曲评论'**
  String get commentTitle;

  /// No description provided for @folderAdd.
  ///
  /// In zh_CN, this message translates to:
  /// **'添加'**
  String get folderAdd;

  /// No description provided for @folderBrowse.
  ///
  /// In zh_CN, this message translates to:
  /// **'浏览'**
  String get folderBrowse;

  /// No description provided for @folderEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'尚未添加扫描目录，点击下方按钮添加'**
  String get folderEmpty;

  /// No description provided for @folderExists.
  ///
  /// In zh_CN, this message translates to:
  /// **'目录已存在或无效'**
  String get folderExists;

  /// No description provided for @folderInvalid.
  ///
  /// In zh_CN, this message translates to:
  /// **'目录不存在、已存在或为空'**
  String get folderInvalid;

  /// No description provided for @folderPathHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'输入目录绝对路径'**
  String get folderPathHint;

  /// No description provided for @folderRemove.
  ///
  /// In zh_CN, this message translates to:
  /// **'移除'**
  String get folderRemove;

  /// No description provided for @folderRemoveDescription.
  ///
  /// In zh_CN, this message translates to:
  /// **'移除后不再扫描该目录，已入库曲目保留。'**
  String get folderRemoveDescription;

  /// No description provided for @folderRemoveTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'移除扫描目录'**
  String get folderRemoveTitle;

  /// No description provided for @loginFetchingQr.
  ///
  /// In zh_CN, this message translates to:
  /// **'正在获取二维码…'**
  String get loginFetchingQr;

  /// No description provided for @loginKugouLoggedIn.
  ///
  /// In zh_CN, this message translates to:
  /// **'{platform}已登录'**
  String loginKugouLoggedIn(Object platform);

  /// No description provided for @loginKugouLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'{platform}登录'**
  String loginKugouLogin(Object platform);

  /// No description provided for @loginKugouQrLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'{platform}扫码登录'**
  String loginKugouQrLogin(Object platform);

  /// No description provided for @loginKugouResponseMissingToken.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录响应缺少 token/userid'**
  String get loginKugouResponseMissingToken;

  /// No description provided for @loginKugouScanHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'请使用{platform} App 扫一扫登录'**
  String loginKugouScanHint(Object platform);

  /// No description provided for @loginKugouSession.
  ///
  /// In zh_CN, this message translates to:
  /// **'{platform}登录态'**
  String loginKugouSession(Object platform);

  /// No description provided for @loginKugouSuccessVip.
  ///
  /// In zh_CN, this message translates to:
  /// **'{platform}登录成功，VIP 曲目已解锁'**
  String loginKugouSuccessVip(Object platform);

  /// No description provided for @loginLoggedOut.
  ///
  /// In zh_CN, this message translates to:
  /// **'已退出{platform}登录'**
  String loginLoggedOut(Object platform);

  /// No description provided for @loginLogoutWithId.
  ///
  /// In zh_CN, this message translates to:
  /// **'退出登录（{id}）'**
  String loginLogoutWithId(Object id);

  /// No description provided for @loginNeteaseQrTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫码登录{platform}'**
  String loginNeteaseQrTitle(Object platform);

  /// No description provided for @loginNeteaseScanHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'请使用{platform} App 扫码登录'**
  String loginNeteaseScanHint(Object platform);

  /// No description provided for @loginQrExpired.
  ///
  /// In zh_CN, this message translates to:
  /// **'二维码已过期'**
  String get loginQrExpired;

  /// No description provided for @loginQrExpiredRegenerate.
  ///
  /// In zh_CN, this message translates to:
  /// **'二维码已过期，请点击重新生成'**
  String get loginQrExpiredRegenerate;

  /// No description provided for @loginQrLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫码登录'**
  String get loginQrLogin;

  /// No description provided for @loginRefreshQr.
  ///
  /// In zh_CN, this message translates to:
  /// **'刷新二维码'**
  String get loginRefreshQr;

  /// No description provided for @loginRegenerate.
  ///
  /// In zh_CN, this message translates to:
  /// **'重新生成'**
  String get loginRegenerate;

  /// No description provided for @loginSuccess.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录成功'**
  String get loginSuccess;

  /// No description provided for @loginWaitingConfirm.
  ///
  /// In zh_CN, this message translates to:
  /// **'已扫码，请在手机上确认登录'**
  String get loginWaitingConfirm;

  /// No description provided for @splashTagline.
  ///
  /// In zh_CN, this message translates to:
  /// **'本地 · 在线 · 自托管'**
  String get splashTagline;

  /// No description provided for @trackListArtistHotSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌手热门歌曲'**
  String get trackListArtistHotSongs;

  /// No description provided for @trackListArtistSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌手单曲'**
  String get trackListArtistSongs;

  /// No description provided for @trackListDailyRecommend.
  ///
  /// In zh_CN, this message translates to:
  /// **'每日推荐'**
  String get trackListDailyRecommend;

  /// No description provided for @trackListDailyRecommendSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'根据口味每天更新'**
  String get trackListDailyRecommendSubtitle;

  /// No description provided for @trackListEmptyDailyLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'暂无歌曲（每日推荐需登录{platform}）'**
  String trackListEmptyDailyLogin(Object platform);

  /// No description provided for @trackListNoPlayableSource.
  ///
  /// In zh_CN, this message translates to:
  /// **'无可用播放源（VIP / 试听限制）'**
  String get trackListNoPlayableSource;

  /// No description provided for @trackListPlayAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放全部'**
  String get trackListPlayAll;

  /// No description provided for @trackListPlaySourceFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'获取播放源失败: {msg}'**
  String trackListPlaySourceFailed(Object msg);

  /// No description provided for @trayNext.
  ///
  /// In zh_CN, this message translates to:
  /// **'下一首'**
  String get trayNext;

  /// No description provided for @trayPlayPause.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放 / 暂停'**
  String get trayPlayPause;

  /// No description provided for @trayPrevious.
  ///
  /// In zh_CN, this message translates to:
  /// **'上一首'**
  String get trayPrevious;

  /// No description provided for @trayQuit.
  ///
  /// In zh_CN, this message translates to:
  /// **'退出'**
  String get trayQuit;

  /// No description provided for @trayShow.
  ///
  /// In zh_CN, this message translates to:
  /// **'显示主窗口'**
  String get trayShow;

  /// No description provided for @commonPlayAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放全部'**
  String get commonPlayAll;

  /// No description provided for @commonPause.
  ///
  /// In zh_CN, this message translates to:
  /// **'暂停'**
  String get commonPause;

  /// No description provided for @commonPlay.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放'**
  String get commonPlay;

  /// No description provided for @commonRefresh.
  ///
  /// In zh_CN, this message translates to:
  /// **'刷新'**
  String get commonRefresh;

  /// No description provided for @commonSearch.
  ///
  /// In zh_CN, this message translates to:
  /// **'搜索'**
  String get commonSearch;

  /// No description provided for @commonSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌曲'**
  String get commonSongs;

  /// No description provided for @commonAlbums.
  ///
  /// In zh_CN, this message translates to:
  /// **'专辑'**
  String get commonAlbums;

  /// No description provided for @commonArtists.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌手'**
  String get commonArtists;

  /// No description provided for @commonPlaylists.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌单'**
  String get commonPlaylists;

  /// No description provided for @commonDone.
  ///
  /// In zh_CN, this message translates to:
  /// **'完成'**
  String get commonDone;

  /// No description provided for @commonUnknownError.
  ///
  /// In zh_CN, this message translates to:
  /// **'未知错误'**
  String get commonUnknownError;

  /// No description provided for @commonSongCountHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'共 {count} 首歌曲 · 点击播放'**
  String commonSongCountHint(Object count);

  /// No description provided for @platformNetease.
  ///
  /// In zh_CN, this message translates to:
  /// **'网易云'**
  String get platformNetease;

  /// No description provided for @platformKugou.
  ///
  /// In zh_CN, this message translates to:
  /// **'酷狗'**
  String get platformKugou;

  /// No description provided for @platformAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'聚合'**
  String get platformAll;

  /// No description provided for @toastPlayedAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'已播放全部 {count} 首'**
  String toastPlayedAll(Object count);

  /// No description provided for @toastPlayFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放失败：{msg}'**
  String toastPlayFailed(Object msg);

  /// No description provided for @toastMissingLocalPath.
  ///
  /// In zh_CN, this message translates to:
  /// **'缺少本地文件路径'**
  String get toastMissingLocalPath;

  /// No description provided for @toastLocateComingSoon.
  ///
  /// In zh_CN, this message translates to:
  /// **'打开文件管理器（Phase 2 接入）'**
  String get toastLocateComingSoon;

  /// No description provided for @toastRemovedFromLibrary.
  ///
  /// In zh_CN, this message translates to:
  /// **'已从曲库移除'**
  String get toastRemovedFromLibrary;

  /// No description provided for @toastRemoveFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'移除失败'**
  String get toastRemoveFailed;

  /// No description provided for @toastDailyRequiresLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'每日推荐需要登录{platform}账号'**
  String toastDailyRequiresLogin(Object platform);

  /// No description provided for @toastPlaylistEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌单暂无歌曲'**
  String get toastPlaylistEmpty;

  /// No description provided for @toastAlbumEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'专辑暂无歌曲'**
  String get toastAlbumEmpty;

  /// No description provided for @toastPausedAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'已全部暂停'**
  String get toastPausedAll;

  /// No description provided for @toastResumedAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'已全部开始'**
  String get toastResumedAll;

  /// No description provided for @toastPaused.
  ///
  /// In zh_CN, this message translates to:
  /// **'已暂停'**
  String get toastPaused;

  /// No description provided for @toastCanceledTask.
  ///
  /// In zh_CN, this message translates to:
  /// **'已取消并删除任务'**
  String get toastCanceledTask;

  /// No description provided for @toastResumed.
  ///
  /// In zh_CN, this message translates to:
  /// **'已恢复下载'**
  String get toastResumed;

  /// No description provided for @toastRequeued.
  ///
  /// In zh_CN, this message translates to:
  /// **'已重新加入队列'**
  String get toastRequeued;

  /// No description provided for @toastDeletedSelected.
  ///
  /// In zh_CN, this message translates to:
  /// **'已删除所选任务'**
  String get toastDeletedSelected;

  /// No description provided for @toastDeletedSelectedWithMedia.
  ///
  /// In zh_CN, this message translates to:
  /// **'已删除所选任务及媒体文件'**
  String get toastDeletedSelectedWithMedia;

  /// No description provided for @toastCleared.
  ///
  /// In zh_CN, this message translates to:
  /// **'已清空下载任务'**
  String get toastCleared;

  /// No description provided for @toastClearedWithMedia.
  ///
  /// In zh_CN, this message translates to:
  /// **'已清空任务并删除媒体文件'**
  String get toastClearedWithMedia;

  /// No description provided for @toastDeletedTask.
  ///
  /// In zh_CN, this message translates to:
  /// **'已删除任务'**
  String get toastDeletedTask;

  /// No description provided for @toastDeletedTaskWithMedia.
  ///
  /// In zh_CN, this message translates to:
  /// **'已删除任务及媒体文件'**
  String get toastDeletedTaskWithMedia;

  /// No description provided for @pageHistoryRemoved.
  ///
  /// In zh_CN, this message translates to:
  /// **'已从历史移除'**
  String get pageHistoryRemoved;

  /// No description provided for @pageHistoryClearTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'清空播放历史'**
  String get pageHistoryClearTitle;

  /// No description provided for @pageHistoryClearMessage.
  ///
  /// In zh_CN, this message translates to:
  /// **'确定清空全部播放历史？此操作不可撤销。'**
  String get pageHistoryClearMessage;

  /// No description provided for @pageHistoryCleared.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放历史已清空'**
  String get pageHistoryCleared;

  /// No description provided for @pageHistoryRemove.
  ///
  /// In zh_CN, this message translates to:
  /// **'从历史移除'**
  String get pageHistoryRemove;

  /// No description provided for @pageHistorySubtitleEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'本地存储的播放记录'**
  String get pageHistorySubtitleEmpty;

  /// No description provided for @pageHistoryEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'还没有播放记录'**
  String get pageHistoryEmpty;

  /// No description provided for @pageHistoryEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放过的歌曲会自动记录在这里'**
  String get pageHistoryEmptyHint;

  /// No description provided for @pageFavPlaylistCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'共 {count} 个收藏歌单'**
  String pageFavPlaylistCount(Object count);

  /// No description provided for @pageFavPlaylistLoginHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后可查看收藏的歌单'**
  String get pageFavPlaylistLoginHint;

  /// No description provided for @pageFavAlbumCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'共 {count} 张收藏专辑'**
  String pageFavAlbumCount(Object count);

  /// No description provided for @pageFavAlbumLoginHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后可查看收藏的专辑'**
  String get pageFavAlbumLoginHint;

  /// No description provided for @pageFavArtistCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'共 {count} 位收藏歌手'**
  String pageFavArtistCount(Object count);

  /// No description provided for @pageFavArtistLoginHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后可查看收藏的歌手'**
  String get pageFavArtistLoginHint;

  /// No description provided for @pageFavLoadFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载收藏失败'**
  String get pageFavLoadFailed;

  /// No description provided for @pageFavEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'还没有收藏'**
  String get pageFavEmpty;

  /// No description provided for @pageFavEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'在网易云 App 收藏后自动同步'**
  String get pageFavEmptyHint;

  /// No description provided for @pageFavLoginTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后查看收藏'**
  String get pageFavLoginTitle;

  /// No description provided for @pageFavLoginDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫码登录网易云，同步收藏的歌单、专辑与歌手'**
  String get pageFavLoginDesc;

  /// No description provided for @pageSearchLoadingTrack.
  ///
  /// In zh_CN, this message translates to:
  /// **'开始加载：{title}'**
  String pageSearchLoadingTrack(Object title);

  /// No description provided for @pageSearchDetailComingSoon.
  ///
  /// In zh_CN, this message translates to:
  /// **'{title} — 详情页待接入'**
  String pageSearchDetailComingSoon(Object title);

  /// No description provided for @menuViewArtist.
  ///
  /// In zh_CN, this message translates to:
  /// **'查看歌手'**
  String get menuViewArtist;

  /// No description provided for @pageSearchArtistComingSoon.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌手页 Phase 2 接入'**
  String get pageSearchArtistComingSoon;

  /// No description provided for @pageSearchInputHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'输入关键词开始搜索'**
  String get pageSearchInputHint;

  /// No description provided for @pageSearchInputSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'支持歌曲 / 专辑 / 歌手 / 歌单'**
  String get pageSearchInputSubtitle;

  /// No description provided for @pageSearching.
  ///
  /// In zh_CN, this message translates to:
  /// **'搜索中…'**
  String get pageSearching;

  /// No description provided for @pageSearchEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'没有找到相关内容'**
  String get pageSearchEmpty;

  /// No description provided for @pageSearchEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'换个关键词试试'**
  String get pageSearchEmptyHint;

  /// No description provided for @pageSearchFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'搜索失败'**
  String get pageSearchFailed;

  /// No description provided for @pageLikedKugouLoginHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后可同步酷狗「我喜欢」'**
  String get pageLikedKugouLoginHint;

  /// No description provided for @pageLikedNeteaseLoginHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后可同步网易云收藏'**
  String get pageLikedNeteaseLoginHint;

  /// No description provided for @pageLikedLoadFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载喜欢列表失败'**
  String get pageLikedLoadFailed;

  /// No description provided for @pageLikedEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'还没有喜欢的歌曲'**
  String get pageLikedEmpty;

  /// No description provided for @pageLikedKugouEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'在酷狗 App 收藏后自动同步'**
  String get pageLikedKugouEmptyHint;

  /// No description provided for @pageLikedNeteaseEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'在网易云 App 点亮红心后自动同步'**
  String get pageLikedNeteaseEmptyHint;

  /// No description provided for @pageLikedLoginTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录后查看我喜欢的歌曲'**
  String get pageLikedLoginTitle;

  /// No description provided for @pageLikedKugouLoginDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫码登录酷狗，同步「我喜欢」收藏'**
  String get pageLikedKugouLoginDesc;

  /// No description provided for @pageLikedNeteaseLoginDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫码登录网易云，同步红心收藏'**
  String get pageLikedNeteaseLoginDesc;

  /// No description provided for @libraryScanDirs.
  ///
  /// In zh_CN, this message translates to:
  /// **'扫描目录'**
  String get libraryScanDirs;

  /// No description provided for @libraryScanDirsDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'管理本地扫描目录，添加后立即扫描'**
  String get libraryScanDirsDesc;

  /// No description provided for @libraryMediaStats.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体统计'**
  String get libraryMediaStats;

  /// No description provided for @libraryMediaStatsDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'本地音乐库概况'**
  String get libraryMediaStatsDesc;

  /// No description provided for @libraryStatTracks.
  ///
  /// In zh_CN, this message translates to:
  /// **'曲目数'**
  String get libraryStatTracks;

  /// No description provided for @libraryStatDuration.
  ///
  /// In zh_CN, this message translates to:
  /// **'总时长'**
  String get libraryStatDuration;

  /// No description provided for @libraryStatSize.
  ///
  /// In zh_CN, this message translates to:
  /// **'总大小'**
  String get libraryStatSize;

  /// No description provided for @libraryStatTrackCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首'**
  String libraryStatTrackCount(Object count);

  /// No description provided for @libraryScanDirCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 个'**
  String libraryScanDirCount(Object count);

  /// No description provided for @libraryHoursMinutes.
  ///
  /// In zh_CN, this message translates to:
  /// **'{h} 小时 {m} 分钟'**
  String libraryHoursMinutes(Object h, Object m);

  /// No description provided for @libraryMinutes.
  ///
  /// In zh_CN, this message translates to:
  /// **'{m} 分钟'**
  String libraryMinutes(Object m);

  /// No description provided for @librarySeconds.
  ///
  /// In zh_CN, this message translates to:
  /// **'{s} 秒'**
  String librarySeconds(Object s);

  /// No description provided for @librarySearchHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'搜索本地曲目'**
  String get librarySearchHint;

  /// No description provided for @libraryNoMatch.
  ///
  /// In zh_CN, this message translates to:
  /// **'没有匹配的曲目'**
  String get libraryNoMatch;

  /// No description provided for @libraryScanningFiles.
  ///
  /// In zh_CN, this message translates to:
  /// **'正在统计文件…'**
  String get libraryScanningFiles;

  /// No description provided for @libraryTrackCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首{extra}'**
  String libraryTrackCount(Object count, Object extra);

  /// No description provided for @libraryEmptyWaitScan.
  ///
  /// In zh_CN, this message translates to:
  /// **'正在等待首次扫描'**
  String get libraryEmptyWaitScan;

  /// No description provided for @libraryEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'本地音乐库为空'**
  String get libraryEmpty;

  /// No description provided for @libraryEmptyScanHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'点击下方按钮立即扫描'**
  String get libraryEmptyScanHint;

  /// No description provided for @libraryEmptyAddHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'添加音乐文件夹后即可扫描入库'**
  String get libraryEmptyAddHint;

  /// No description provided for @libraryScanNow.
  ///
  /// In zh_CN, this message translates to:
  /// **'立即扫描'**
  String get libraryScanNow;

  /// No description provided for @libraryAddFolder.
  ///
  /// In zh_CN, this message translates to:
  /// **'添加文件夹'**
  String get libraryAddFolder;

  /// No description provided for @menuLocateFile.
  ///
  /// In zh_CN, this message translates to:
  /// **'定位文件'**
  String get menuLocateFile;

  /// No description provided for @menuLocateFileComingSoon.
  ///
  /// In zh_CN, this message translates to:
  /// **'打开文件管理器 Phase 2 接入'**
  String get menuLocateFileComingSoon;

  /// No description provided for @menuRemoveFromLibrary.
  ///
  /// In zh_CN, this message translates to:
  /// **'从曲库移除'**
  String get menuRemoveFromLibrary;

  /// No description provided for @playerBarCollapsePlayer.
  ///
  /// In zh_CN, this message translates to:
  /// **'收起播放器'**
  String get playerBarCollapsePlayer;

  /// No description provided for @playerBarHideLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'隐藏歌词'**
  String get playerBarHideLyrics;

  /// No description provided for @playerBarShowLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'显示歌词'**
  String get playerBarShowLyrics;

  /// No description provided for @playerPageNotPlaying.
  ///
  /// In zh_CN, this message translates to:
  /// **'未在播放'**
  String get playerPageNotPlaying;

  /// No description provided for @playerPageLoadHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载源后开始播放'**
  String get playerPageLoadHint;

  /// No description provided for @playerPageQualityMenu.
  ///
  /// In zh_CN, this message translates to:
  /// **'切换音质'**
  String get playerPageQualityMenu;

  /// No description provided for @pageHomeRankTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'排行榜'**
  String get pageHomeRankTitle;

  /// No description provided for @pageHomePlaylistSquare.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌单广场'**
  String get pageHomePlaylistSquare;

  /// No description provided for @pageHomeHotArtists.
  ///
  /// In zh_CN, this message translates to:
  /// **'热门歌手'**
  String get pageHomeHotArtists;

  /// No description provided for @pageHomePlaylists.
  ///
  /// In zh_CN, this message translates to:
  /// **'推荐歌单'**
  String get pageHomePlaylists;

  /// No description provided for @pageHomeNewAlbums.
  ///
  /// In zh_CN, this message translates to:
  /// **'新碟上架'**
  String get pageHomeNewAlbums;

  /// No description provided for @pageHomeRankSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'各大榜单实时热歌'**
  String get pageHomeRankSubtitle;

  /// No description provided for @pageHomePlaylistSquareSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'发现更多精彩歌单'**
  String get pageHomePlaylistSquareSubtitle;

  /// No description provided for @pageHomeArtistSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'热门歌手，圆形头像'**
  String get pageHomeArtistSubtitle;

  /// No description provided for @pageHomeLoadFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'加载推荐失败'**
  String get pageHomeLoadFailed;

  /// No description provided for @pageHomePlaylistsSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'根据你的口味为你推荐'**
  String get pageHomePlaylistsSubtitle;

  /// No description provided for @pageHomeNewAlbumsSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'近期值得一听的新专辑'**
  String get pageHomeNewAlbumsSubtitle;

  /// No description provided for @pageHomeHotArtistsSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'大家都在听'**
  String get pageHomeHotArtistsSubtitle;

  /// No description provided for @pageHomeDaily.
  ///
  /// In zh_CN, this message translates to:
  /// **'每日推荐'**
  String get pageHomeDaily;

  /// No description provided for @pageHomeDailyLoggedIn.
  ///
  /// In zh_CN, this message translates to:
  /// **'根据你的口味，为你精心挑选'**
  String get pageHomeDailyLoggedIn;

  /// No description provided for @pageHomeDailyLoginHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录网易云账号后，每天为你更新'**
  String get pageHomeDailyLoginHint;

  /// No description provided for @pageHomeDailyPlay.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放今日推荐'**
  String get pageHomeDailyPlay;

  /// No description provided for @pageHomeDailyLogin.
  ///
  /// In zh_CN, this message translates to:
  /// **'登录解锁每日推荐'**
  String get pageHomeDailyLogin;

  /// No description provided for @pageHomeGreeting.
  ///
  /// In zh_CN, this message translates to:
  /// **'{greeting}，{name}'**
  String pageHomeGreeting(Object greeting, Object name);

  /// No description provided for @greetingLate.
  ///
  /// In zh_CN, this message translates to:
  /// **'夜深了'**
  String get greetingLate;

  /// No description provided for @greetingMorning.
  ///
  /// In zh_CN, this message translates to:
  /// **'早上好'**
  String get greetingMorning;

  /// No description provided for @greetingAfternoon.
  ///
  /// In zh_CN, this message translates to:
  /// **'下午好'**
  String get greetingAfternoon;

  /// No description provided for @greetingEvening.
  ///
  /// In zh_CN, this message translates to:
  /// **'晚上好'**
  String get greetingEvening;

  /// No description provided for @greetingFallback.
  ///
  /// In zh_CN, this message translates to:
  /// **'今天想听点什么？'**
  String get greetingFallback;

  /// No description provided for @downloadDeleteTaskOnly.
  ///
  /// In zh_CN, this message translates to:
  /// **'仅删除任务'**
  String get downloadDeleteTaskOnly;

  /// No description provided for @downloadDeleteWithMedia.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除任务及媒体文件'**
  String get downloadDeleteWithMedia;

  /// No description provided for @downloadSelectedCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'已选 {count} 项'**
  String downloadSelectedCount(Object count);

  /// No description provided for @downloadSelectAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'全选'**
  String get downloadSelectAll;

  /// No description provided for @downloadDeselectAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'全不选'**
  String get downloadDeselectAll;

  /// No description provided for @downloadPauseAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'全部暂停'**
  String get downloadPauseAll;

  /// No description provided for @downloadResumeAll.
  ///
  /// In zh_CN, this message translates to:
  /// **'全部开始'**
  String get downloadResumeAll;

  /// No description provided for @downloadDeleteSelected.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除所选'**
  String get downloadDeleteSelected;

  /// No description provided for @downloadExitSelect.
  ///
  /// In zh_CN, this message translates to:
  /// **'退出批量选择'**
  String get downloadExitSelect;

  /// No description provided for @downloadActiveCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'进行中 {count}'**
  String downloadActiveCount(Object count);

  /// No description provided for @downloadDoneCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'已完成 {count}'**
  String downloadDoneCount(Object count);

  /// No description provided for @downloadOpenDir.
  ///
  /// In zh_CN, this message translates to:
  /// **'打开下载目录'**
  String get downloadOpenDir;

  /// No description provided for @downloadSelectMode.
  ///
  /// In zh_CN, this message translates to:
  /// **'批量选择'**
  String get downloadSelectMode;

  /// No description provided for @downloadEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'暂无下载任务'**
  String get downloadEmpty;

  /// No description provided for @downloadEmptyHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'在歌曲上右键 → 下载，即可加入队列'**
  String get downloadEmptyHint;

  /// No description provided for @downloadDeleteSelectedTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除所选 {count} 个任务'**
  String downloadDeleteSelectedTitle(Object count);

  /// No description provided for @downloadDeleteSelectedMessage.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除所选任务并清空 .tmp 缓存；媒体文件精确匹配删除。'**
  String get downloadDeleteSelectedMessage;

  /// No description provided for @downloadClearTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'清空下载任务'**
  String get downloadClearTitle;

  /// No description provided for @downloadClearMessage.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除全部任务并清空 .tmp 缓存；媒体文件精确匹配删除。'**
  String get downloadClearMessage;

  /// No description provided for @downloadCancelTooltip.
  ///
  /// In zh_CN, this message translates to:
  /// **'取消（删除任务并清缓存）'**
  String get downloadCancelTooltip;

  /// No description provided for @downloadResume.
  ///
  /// In zh_CN, this message translates to:
  /// **'恢复下载'**
  String get downloadResume;

  /// No description provided for @downloadOpenDirTask.
  ///
  /// In zh_CN, this message translates to:
  /// **'打开所在目录'**
  String get downloadOpenDirTask;

  /// No description provided for @downloadDeleteTask.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除任务'**
  String get downloadDeleteTask;

  /// No description provided for @downloadDeleteWithMediaExact.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除任务及媒体文件（精确匹配）'**
  String get downloadDeleteWithMediaExact;

  /// No description provided for @downloadStatusQueued.
  ///
  /// In zh_CN, this message translates to:
  /// **'排队中…'**
  String get downloadStatusQueued;

  /// No description provided for @downloadStatusResolving.
  ///
  /// In zh_CN, this message translates to:
  /// **'解析下载地址…'**
  String get downloadStatusResolving;

  /// No description provided for @downloadStatusRunning.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载中 {percent}%（{received}）{speed}'**
  String downloadStatusRunning(Object percent, Object received, Object speed);

  /// No description provided for @downloadStatusRunningNoPercent.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载中…{speed}'**
  String downloadStatusRunningNoPercent(Object speed);

  /// No description provided for @downloadStatusPausedWith.
  ///
  /// In zh_CN, this message translates to:
  /// **'已暂停（{received}）'**
  String downloadStatusPausedWith(Object received);

  /// No description provided for @downloadStatusPaused.
  ///
  /// In zh_CN, this message translates to:
  /// **'已暂停'**
  String get downloadStatusPaused;

  /// No description provided for @downloadStatusFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'失败：{error}'**
  String downloadStatusFailed(Object error);

  /// No description provided for @downloadStatusFailedUnknown.
  ///
  /// In zh_CN, this message translates to:
  /// **'失败：未知错误'**
  String get downloadStatusFailedUnknown;

  /// No description provided for @downloadStatusCanceled.
  ///
  /// In zh_CN, this message translates to:
  /// **'已取消'**
  String get downloadStatusCanceled;

  /// No description provided for @downloadStatusDone.
  ///
  /// In zh_CN, this message translates to:
  /// **'完成（{size}）'**
  String downloadStatusDone(Object size);

  /// No description provided for @downloadStatusAlready.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件已存在'**
  String get downloadStatusAlready;

  /// No description provided for @pageHomeTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'发现'**
  String get pageHomeTitle;

  /// No description provided for @settingsTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsCatAppearance.
  ///
  /// In zh_CN, this message translates to:
  /// **'外观'**
  String get settingsCatAppearance;

  /// No description provided for @settingsCatPlayback.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放'**
  String get settingsCatPlayback;

  /// No description provided for @settingsCatLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词'**
  String get settingsCatLyrics;

  /// No description provided for @settingsCatPreset.
  ///
  /// In zh_CN, this message translates to:
  /// **'强迫症'**
  String get settingsCatPreset;

  /// No description provided for @settingsCatDownload.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载'**
  String get settingsCatDownload;

  /// No description provided for @settingsCatStorage.
  ///
  /// In zh_CN, this message translates to:
  /// **'存储'**
  String get settingsCatStorage;

  /// No description provided for @settingsCatAbout.
  ///
  /// In zh_CN, this message translates to:
  /// **'关于'**
  String get settingsCatAbout;

  /// No description provided for @settingsAppearanceSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题模式 · 界面偏好'**
  String get settingsAppearanceSubtitle;

  /// No description provided for @settingsPlaybackSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'音频引擎 · 播放行为'**
  String get settingsPlaybackSubtitle;

  /// No description provided for @settingsLyricsSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放器歌词 · 桌面歌词'**
  String get settingsLyricsSubtitle;

  /// No description provided for @settingsPresetSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放过滤 · 歌词还原 · 列表标签'**
  String get settingsPresetSubtitle;

  /// No description provided for @settingsDownloadSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载目录 · 并发 · 限速 · 音质 · 分组 · 文件名'**
  String get settingsDownloadSubtitle;

  /// No description provided for @settingsStorageSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'数据目录 · 数据库文件'**
  String get settingsStorageSubtitle;

  /// No description provided for @settingsAboutSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'版本 · 项目信息'**
  String get settingsAboutSubtitle;

  /// No description provided for @settingsCatDeveloper.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者'**
  String get settingsCatDeveloper;

  /// No description provided for @settingsDeveloperSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者模式 · 隐藏接口'**
  String get settingsDeveloperSubtitle;

  /// No description provided for @settingsDeveloperTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者模式'**
  String get settingsDeveloperTitle;

  /// No description provided for @settingsDeveloperMode.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者模式'**
  String get settingsDeveloperMode;

  /// No description provided for @settingsDeveloperModeOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'已开启（下载接口可见）'**
  String get settingsDeveloperModeOn;

  /// No description provided for @settingsDeveloperModeOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'已关闭（下载接口隐藏）'**
  String get settingsDeveloperModeOff;

  /// No description provided for @settingsDeveloperDownloadModule.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载模块'**
  String get settingsDeveloperDownloadModule;

  /// No description provided for @settingsDeveloperDownloadModuleDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'侧边栏「下载」入口、曲目右键「下载」与设置「下载」分类仅在开发者模式开启后显示。'**
  String get settingsDeveloperDownloadModuleDesc;

  /// No description provided for @settingsDeveloperNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者模式面向本地调试与自用，开启后请自行承担相关责任。'**
  String get settingsDeveloperNote;

  /// No description provided for @settingsDeveloperEnabled.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者模式已开启'**
  String get settingsDeveloperEnabled;

  /// No description provided for @settingsDeveloperDisabled.
  ///
  /// In zh_CN, this message translates to:
  /// **'开发者模式已关闭'**
  String get settingsDeveloperDisabled;

  /// No description provided for @settingsDeveloperHoldHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'长按 10 秒开启开发者模式（鼠标：按住不放）'**
  String get settingsDeveloperHoldHint;

  /// No description provided for @settingsSearchHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'搜索设置…'**
  String get settingsSearchHint;

  /// No description provided for @settingsSearchNoResult.
  ///
  /// In zh_CN, this message translates to:
  /// **'未找到「{query}」相关设置'**
  String settingsSearchNoResult(Object query);

  /// No description provided for @settingsSearchMatchCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'匹配 {count} 项'**
  String settingsSearchMatchCount(Object count);

  /// No description provided for @settingsSectionTheme.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题'**
  String get settingsSectionTheme;

  /// No description provided for @settingsThemeMode.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题模式'**
  String get settingsThemeMode;

  /// No description provided for @settingsThemeModeDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'亮色 / 深色 / 跟随系统'**
  String get settingsThemeModeDesc;

  /// No description provided for @settingsThemeLight.
  ///
  /// In zh_CN, this message translates to:
  /// **'浅色'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In zh_CN, this message translates to:
  /// **'深色'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认深色主题；「跟随系统」由系统外观决定。'**
  String get settingsThemeNote;

  /// No description provided for @settingsSectionAccent.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题色'**
  String get settingsSectionAccent;

  /// No description provided for @settingsAccentTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'主色种子'**
  String get settingsAccentTitle;

  /// No description provided for @settingsAccentSystem.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统主题色（{color}）'**
  String settingsAccentSystem(Object color);

  /// No description provided for @settingsAccentSystemFallback.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统主题色（读取失败，回退自定义）'**
  String get settingsAccentSystemFallback;

  /// No description provided for @settingsAccentDefault.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认亮蓝（设计体系）'**
  String get settingsAccentDefault;

  /// No description provided for @settingsAccentCustom.
  ///
  /// In zh_CN, this message translates to:
  /// **'自定义（按种子动态生成配色）'**
  String get settingsAccentCustom;

  /// No description provided for @settingsAccentDefaultTooltip.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认亮蓝'**
  String get settingsAccentDefaultTooltip;

  /// No description provided for @settingsAccentSystemTooltip.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统主题色'**
  String get settingsAccentSystemTooltip;

  /// No description provided for @settingsAccentCustomTooltip.
  ///
  /// In zh_CN, this message translates to:
  /// **'自定义取色'**
  String get settingsAccentCustomTooltip;

  /// No description provided for @settingsSectionLayout.
  ///
  /// In zh_CN, this message translates to:
  /// **'布局'**
  String get settingsSectionLayout;

  /// No description provided for @settingsFloatingBar.
  ///
  /// In zh_CN, this message translates to:
  /// **'悬浮播放条'**
  String get settingsFloatingBar;

  /// No description provided for @settingsFloatingBarOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'底部居中圆角胶囊（毛玻璃 + 阴影）'**
  String get settingsFloatingBarOn;

  /// No description provided for @settingsFloatingBarOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'全宽停靠（默认）'**
  String get settingsFloatingBarOff;

  /// No description provided for @settingsSectionFont.
  ///
  /// In zh_CN, this message translates to:
  /// **'界面字体'**
  String get settingsSectionFont;

  /// No description provided for @settingsFontTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'界面字体'**
  String get settingsFontTitle;

  /// No description provided for @settingsFontMiSans.
  ///
  /// In zh_CN, this message translates to:
  /// **'MiSans（默认）'**
  String get settingsFontMiSans;

  /// No description provided for @settingsFontNoto.
  ///
  /// In zh_CN, this message translates to:
  /// **'Noto Sans SC（标准度量）'**
  String get settingsFontNoto;

  /// No description provided for @settingsFontHarmony.
  ///
  /// In zh_CN, this message translates to:
  /// **'HarmonyOS Sans SC（免费商用）'**
  String get settingsFontHarmony;

  /// No description provided for @settingsFontMiSansLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'MiSans'**
  String get settingsFontMiSansLabel;

  /// No description provided for @settingsFontNotoLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'Noto Sans SC'**
  String get settingsFontNotoLabel;

  /// No description provided for @settingsFontHarmonyLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'鸿蒙黑体'**
  String get settingsFontHarmonyLabel;

  /// No description provided for @settingsSectionLanguage.
  ///
  /// In zh_CN, this message translates to:
  /// **'界面语言'**
  String get settingsSectionLanguage;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'界面语言'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'切换界面显示语言'**
  String get settingsLanguageDesc;

  /// No description provided for @settingsLangSystem.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统'**
  String get settingsLangSystem;

  /// No description provided for @settingsSectionCover.
  ///
  /// In zh_CN, this message translates to:
  /// **'封面'**
  String get settingsSectionCover;

  /// No description provided for @settingsCoverRadius.
  ///
  /// In zh_CN, this message translates to:
  /// **'封面圆角'**
  String get settingsCoverRadius;

  /// No description provided for @settingsCoverRadiusSharp.
  ///
  /// In zh_CN, this message translates to:
  /// **'直角（信息密度高）'**
  String get settingsCoverRadiusSharp;

  /// No description provided for @settingsCoverRadiusPx.
  ///
  /// In zh_CN, this message translates to:
  /// **'{radius}px 圆角'**
  String settingsCoverRadiusPx(Object radius);

  /// No description provided for @settingsCoverRadiusSharpLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'直角'**
  String get settingsCoverRadiusSharpLabel;

  /// No description provided for @settingsCoverRadiusRoundedLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'圆角'**
  String get settingsCoverRadiusRoundedLabel;

  /// No description provided for @settingsCoverRadiusLargeLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'大圆角'**
  String get settingsCoverRadiusLargeLabel;

  /// No description provided for @settingsPickerTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'自定义主题色'**
  String get settingsPickerTitle;

  /// No description provided for @settingsPickerHexLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'颜色值（#RRGGBB）'**
  String get settingsPickerHexLabel;

  /// No description provided for @settingsApply.
  ///
  /// In zh_CN, this message translates to:
  /// **'应用'**
  String get settingsApply;

  /// No description provided for @settingsSectionAudio.
  ///
  /// In zh_CN, this message translates to:
  /// **'音频'**
  String get settingsSectionAudio;

  /// No description provided for @settingsPassthrough.
  ///
  /// In zh_CN, this message translates to:
  /// **'原音质直通（不转码）'**
  String get settingsPassthrough;

  /// No description provided for @settingsPassthroughOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'保持源采样率（Hi-Res/无损不降质）'**
  String get settingsPassthroughOn;

  /// No description provided for @settingsPassthroughOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'统一 48kHz 转码管线'**
  String get settingsPassthroughOff;

  /// No description provided for @settingsPassthroughNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'关闭转码保持源采样率播放，开启则统一 48kHz 输出；切换后自动重载当前曲目生效。'**
  String get settingsPassthroughNote;

  /// No description provided for @volumeMute.
  ///
  /// In zh_CN, this message translates to:
  /// **'静音'**
  String get volumeMute;

  /// No description provided for @volumeUnmute.
  ///
  /// In zh_CN, this message translates to:
  /// **'取消静音'**
  String get volumeUnmute;

  /// No description provided for @settingsSectionMemory.
  ///
  /// In zh_CN, this message translates to:
  /// **'记忆与启动'**
  String get settingsSectionMemory;

  /// No description provided for @settingsSessionMemory.
  ///
  /// In zh_CN, this message translates to:
  /// **'会话记忆'**
  String get settingsSessionMemory;

  /// No description provided for @settingsSessionMemoryOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'记录播放队列、位置与模式，下次启动恢复现场'**
  String get settingsSessionMemoryOn;

  /// No description provided for @settingsSessionMemoryOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'不记录播放现场，下次启动为空'**
  String get settingsSessionMemoryOff;

  /// No description provided for @settingsAutoPlay.
  ///
  /// In zh_CN, this message translates to:
  /// **'启动时自动播放'**
  String get settingsAutoPlay;

  /// No description provided for @settingsAutoPlayNeedMemory.
  ///
  /// In zh_CN, this message translates to:
  /// **'需先开启「会话记忆」'**
  String get settingsAutoPlayNeedMemory;

  /// No description provided for @settingsAutoPlayOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'恢复上次会话并自动续播'**
  String get settingsAutoPlayOn;

  /// No description provided for @settingsAutoPlayOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'仅恢复播放现场，不自动续播'**
  String get settingsAutoPlayOff;

  /// No description provided for @settingsSectionSpectrum.
  ///
  /// In zh_CN, this message translates to:
  /// **'频谱'**
  String get settingsSectionSpectrum;

  /// No description provided for @settingsSpectrum.
  ///
  /// In zh_CN, this message translates to:
  /// **'频谱可视化'**
  String get settingsSpectrum;

  /// No description provided for @settingsSpectrumOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放界面显示频谱柱（播放 0.65 / 暂停 0.15 透明度）'**
  String get settingsSpectrumOn;

  /// No description provided for @settingsSpectrumOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放界面不渲染频谱'**
  String get settingsSpectrumOff;

  /// No description provided for @settingsSpectrumBarWidth.
  ///
  /// In zh_CN, this message translates to:
  /// **'频谱柱宽'**
  String get settingsSpectrumBarWidth;

  /// No description provided for @settingsSpectrumBarWidthDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'{width}px（1~12，全屏播放器）'**
  String settingsSpectrumBarWidthDesc(Object width);

  /// No description provided for @settingsBarSpectrum.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条频谱'**
  String get settingsBarSpectrum;

  /// No description provided for @settingsBarSpectrumOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条时间下方显示迷你频谱（无歌词或关闭迷你歌词时）'**
  String get settingsBarSpectrumOn;

  /// No description provided for @settingsBarSpectrumOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条不显示迷你频谱'**
  String get settingsBarSpectrumOff;

  /// No description provided for @settingsCoverBeatScale.
  ///
  /// In zh_CN, this message translates to:
  /// **'封面跟随节奏缩放'**
  String get settingsCoverBeatScale;

  /// No description provided for @settingsCoverBeatScaleOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'封面随鼓点轻微缩放'**
  String get settingsCoverBeatScaleOn;

  /// No description provided for @settingsCoverBeatScaleOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'封面静止（仅播放/暂停缩放）'**
  String get settingsCoverBeatScaleOff;

  /// No description provided for @settingsTransitionStyle.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体信息切换动效'**
  String get settingsTransitionStyle;

  /// No description provided for @settingsTransitionStyleDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'切歌时封面与歌曲信息的过渡动画效果'**
  String get settingsTransitionStyleDesc;

  /// No description provided for @settingsTransitionStyleScale.
  ///
  /// In zh_CN, this message translates to:
  /// **'缩放'**
  String get settingsTransitionStyleScale;

  /// No description provided for @settingsTransitionStyleSlide.
  ///
  /// In zh_CN, this message translates to:
  /// **'侧边滑动'**
  String get settingsTransitionStyleSlide;

  /// No description provided for @settingsSectionShortcuts.
  ///
  /// In zh_CN, this message translates to:
  /// **'快捷键'**
  String get settingsSectionShortcuts;

  /// No description provided for @settingsShortcutSpace.
  ///
  /// In zh_CN, this message translates to:
  /// **'空格'**
  String get settingsShortcutSpace;

  /// No description provided for @settingsShortcutSpaceDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放 / 暂停'**
  String get settingsShortcutSpaceDesc;

  /// No description provided for @settingsShortcutArrows.
  ///
  /// In zh_CN, this message translates to:
  /// **'← / →'**
  String get settingsShortcutArrows;

  /// No description provided for @settingsShortcutArrowsDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'后退 / 前进 10 秒'**
  String get settingsShortcutArrowsDesc;

  /// No description provided for @settingsShortcutSearch.
  ///
  /// In zh_CN, this message translates to:
  /// **'Ctrl / Cmd + F'**
  String get settingsShortcutSearch;

  /// No description provided for @settingsShortcutLibrary.
  ///
  /// In zh_CN, this message translates to:
  /// **'Ctrl / Cmd + L'**
  String get settingsShortcutLibrary;

  /// No description provided for @settingsShortcutLibraryDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'音乐库'**
  String get settingsShortcutLibraryDesc;

  /// No description provided for @settingsShortcutEsc.
  ///
  /// In zh_CN, this message translates to:
  /// **'Esc'**
  String get settingsShortcutEsc;

  /// No description provided for @settingsShortcutEscDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'返回（关闭弹窗 / 全屏播放器）'**
  String get settingsShortcutEscDesc;

  /// No description provided for @settingsSectionPlayerLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放器歌词'**
  String get settingsSectionPlayerLyrics;

  /// No description provided for @settingsPlayerLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放器内歌词'**
  String get settingsPlayerLyrics;

  /// No description provided for @settingsPlayerLyricsOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'全屏播放器右侧歌词（当前行高亮，可点击跳转）'**
  String get settingsPlayerLyricsOn;

  /// No description provided for @settingsPlayerLyricsOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'全屏播放器不显示歌词'**
  String get settingsPlayerLyricsOff;

  /// No description provided for @settingsBarLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条歌词'**
  String get settingsBarLyrics;

  /// No description provided for @settingsBarLyricsOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条时间下方显示当前歌词（过长自动滚动）'**
  String get settingsBarLyricsOn;

  /// No description provided for @settingsBarLyricsOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放条不显示迷你歌词'**
  String get settingsBarLyricsOff;

  /// No description provided for @settingsShowTranslation.
  ///
  /// In zh_CN, this message translates to:
  /// **'显示翻译'**
  String get settingsShowTranslation;

  /// No description provided for @settingsShowTranslationOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词翻译显示在原句后的括号内'**
  String get settingsShowTranslationOn;

  /// No description provided for @settingsShowTranslationOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'不显示歌词翻译'**
  String get settingsShowTranslationOff;

  /// No description provided for @settingsSectionLyricStyle.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词样式'**
  String get settingsSectionLyricStyle;

  /// No description provided for @settingsLyricFontSize.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词字号'**
  String get settingsLyricFontSize;

  /// No description provided for @settingsLyricFontSizeDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'{size}px（当前行放大高亮）'**
  String settingsLyricFontSizeDesc(Object size);

  /// No description provided for @settingsLyricLineHeight.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词行距'**
  String get settingsLyricLineHeight;

  /// No description provided for @settingsLyricLineHeightDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'{height}px（含行间距）'**
  String settingsLyricLineHeightDesc(Object height);

  /// No description provided for @settingsLyricPlayedColor.
  ///
  /// In zh_CN, this message translates to:
  /// **'已唱颜色'**
  String get settingsLyricPlayedColor;

  /// No description provided for @settingsLyricPlayedColorDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'当前行歌词高亮色'**
  String get settingsLyricPlayedColorDesc;

  /// No description provided for @settingsLyricUnplayedColor.
  ///
  /// In zh_CN, this message translates to:
  /// **'未唱颜色'**
  String get settingsLyricUnplayedColor;

  /// No description provided for @settingsLyricUnplayedColorDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'未播放行歌词颜色'**
  String get settingsLyricUnplayedColorDesc;

  /// No description provided for @settingsLyricsNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词样式仅作用于全屏播放器歌词'**
  String get settingsLyricsNote;

  /// No description provided for @settingsSectionFilter.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放过滤'**
  String get settingsSectionFilter;

  /// No description provided for @settingsDjMode.
  ///
  /// In zh_CN, this message translates to:
  /// **'去™的 DJ'**
  String get settingsDjMode;

  /// No description provided for @settingsDjModeOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'世界清净了awa'**
  String get settingsDjModeOn;

  /// No description provided for @settingsDjModeOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'哎嘿嘿(ˉ﹃ˉ)'**
  String get settingsDjModeOff;

  /// No description provided for @settingsSectionLyricsFilter.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词'**
  String get settingsSectionLyricsFilter;

  /// No description provided for @settingsUncensor.
  ///
  /// In zh_CN, this message translates to:
  /// **'解锁脏话'**
  String get settingsUncensor;

  /// No description provided for @settingsUncensorOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'fuck'**
  String get settingsUncensorOn;

  /// No description provided for @settingsUncensorOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'f**k'**
  String get settingsUncensorOff;

  /// No description provided for @settingsSectionListDisplay.
  ///
  /// In zh_CN, this message translates to:
  /// **'列表显示'**
  String get settingsSectionListDisplay;

  /// No description provided for @settingsHideVip.
  ///
  /// In zh_CN, this message translates to:
  /// **'隐藏 VIP 标签'**
  String get settingsHideVip;

  /// No description provided for @settingsHideVipOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'列表不显示 VIP / 付费角标'**
  String get settingsHideVipOn;

  /// No description provided for @settingsHideVipOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'显示付费角标（VIP / EP）'**
  String get settingsHideVipOff;

  /// No description provided for @settingsHideQuality.
  ///
  /// In zh_CN, this message translates to:
  /// **'隐藏音质标签'**
  String get settingsHideQuality;

  /// No description provided for @settingsHideQualityOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'列表不显示音质角标'**
  String get settingsHideQualityOn;

  /// No description provided for @settingsHideQualityOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'显示可用最高音质（Hi-Res / 无损 / HQ…）'**
  String get settingsHideQualityOff;

  /// No description provided for @settingsShowSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'显示副标题'**
  String get settingsShowSubtitle;

  /// No description provided for @settingsShowSubtitleOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌名后展示别名，如 (Live)'**
  String get settingsShowSubtitleOn;

  /// No description provided for @settingsShowSubtitleOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'列表不展示别名'**
  String get settingsShowSubtitleOff;

  /// No description provided for @settingsPerformanceMode.
  ///
  /// In zh_CN, this message translates to:
  /// **'性能模式'**
  String get settingsPerformanceMode;

  /// No description provided for @settingsPerformanceModeOn.
  ///
  /// In zh_CN, this message translates to:
  /// **'当前为冻效模式'**
  String get settingsPerformanceModeOn;

  /// No description provided for @settingsPerformanceModeOff.
  ///
  /// In zh_CN, this message translates to:
  /// **'当前为动效模式'**
  String get settingsPerformanceModeOff;

  /// No description provided for @settingsSectionDir.
  ///
  /// In zh_CN, this message translates to:
  /// **'目录'**
  String get settingsSectionDir;

  /// No description provided for @settingsDownloadRootHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载目录（回车保存）'**
  String get settingsDownloadRootHint;

  /// No description provided for @settingsRestoreDefault.
  ///
  /// In zh_CN, this message translates to:
  /// **'恢复默认'**
  String get settingsRestoreDefault;

  /// No description provided for @settingsDownloadRootNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认跟随媒体库目录；修改目录回车保存，进行中的下载任务会终止。'**
  String get settingsDownloadRootNote;

  /// No description provided for @settingsSectionFilename.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件名'**
  String get settingsSectionFilename;

  /// No description provided for @settingsDownloadTemplateHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件名模板（回车保存）'**
  String get settingsDownloadTemplateHint;

  /// No description provided for @settingsDownloadTemplateNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'占位符：<artist> · <title> · <album>；只影响之后入队的任务，回车保存立即生效。'**
  String get settingsDownloadTemplateNote;

  /// No description provided for @settingsSectionQuality.
  ///
  /// In zh_CN, this message translates to:
  /// **'音质'**
  String get settingsSectionQuality;

  /// No description provided for @settingsDownloadQuality.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认下载音质'**
  String get settingsDownloadQuality;

  /// No description provided for @settingsDownloadQualityDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载弹窗默认选中 {quality}，档位不足时自动降级'**
  String settingsDownloadQualityDesc(Object quality);

  /// No description provided for @settingsDownloadQualityNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'档位从高到低：Hi-Res → 无损 → HQ → SQ → LQ，缺失时按此顺序自动降级。'**
  String get settingsDownloadQualityNote;

  /// No description provided for @settingsSectionConcurrent.
  ///
  /// In zh_CN, this message translates to:
  /// **'并发'**
  String get settingsSectionConcurrent;

  /// No description provided for @settingsDownloadConcurrent.
  ///
  /// In zh_CN, this message translates to:
  /// **'同时下载数'**
  String get settingsDownloadConcurrent;

  /// No description provided for @settingsDownloadConcurrentDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 个并行任务（1~5）'**
  String settingsDownloadConcurrentDesc(Object count);

  /// No description provided for @settingsDownloadGrouping.
  ///
  /// In zh_CN, this message translates to:
  /// **'目录分组'**
  String get settingsDownloadGrouping;

  /// No description provided for @settingsGroupingFlat.
  ///
  /// In zh_CN, this message translates to:
  /// **'全部平铺在下载目录下'**
  String get settingsGroupingFlat;

  /// No description provided for @settingsGroupingPlatform.
  ///
  /// In zh_CN, this message translates to:
  /// **'按平台建子目录（Kugou / Netease）'**
  String get settingsGroupingPlatform;

  /// No description provided for @settingsGroupingArtist.
  ///
  /// In zh_CN, this message translates to:
  /// **'按歌手建子目录'**
  String get settingsGroupingArtist;

  /// No description provided for @settingsGroupingFlatLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'平铺'**
  String get settingsGroupingFlatLabel;

  /// No description provided for @settingsGroupingPlatformLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'按平台'**
  String get settingsGroupingPlatformLabel;

  /// No description provided for @settingsGroupingArtistLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'按歌手'**
  String get settingsGroupingArtistLabel;

  /// No description provided for @settingsSectionSpeedLimit.
  ///
  /// In zh_CN, this message translates to:
  /// **'限速'**
  String get settingsSectionSpeedLimit;

  /// No description provided for @settingsDownloadSpeedLimit.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载限速'**
  String get settingsDownloadSpeedLimit;

  /// No description provided for @settingsSpeedUnlimited.
  ///
  /// In zh_CN, this message translates to:
  /// **'不限速（默认）'**
  String get settingsSpeedUnlimited;

  /// No description provided for @settingsSpeedLimited.
  ///
  /// In zh_CN, this message translates to:
  /// **'限 {speed}，实时生效'**
  String settingsSpeedLimited(Object speed);

  /// No description provided for @settingsSpeedUnlimitedLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'不限速'**
  String get settingsSpeedUnlimitedLabel;

  /// No description provided for @settingsSpeedMbps.
  ///
  /// In zh_CN, this message translates to:
  /// **'{speed} MB/s'**
  String settingsSpeedMbps(Object speed);

  /// No description provided for @settingsSpeedNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'限速实时生效，不打断在途任务（0.5 MB/s 步进，0 = 不限速）。'**
  String get settingsSpeedNote;

  /// No description provided for @settingsSectionHistory.
  ///
  /// In zh_CN, this message translates to:
  /// **'记录'**
  String get settingsSectionHistory;

  /// No description provided for @settingsDownloadHistoryLimit.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载记录上限'**
  String get settingsDownloadHistoryLimit;

  /// No description provided for @settingsDownloadHistoryDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 条（10~500）· 超上限自动淘汰最旧'**
  String settingsDownloadHistoryDesc(Object count);

  /// No description provided for @settingsDownloadHistoryCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 条'**
  String settingsDownloadHistoryCount(Object count);

  /// No description provided for @settingsDownloadHistoryNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'仅淘汰失败 / 已取消记录中最旧的，进行中任务不受影响。'**
  String get settingsDownloadHistoryNote;

  /// No description provided for @settingsGroupingNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'按歌手分组 v2 已支持（平铺 / 按平台 / 按歌手）。'**
  String get settingsGroupingNote;

  /// No description provided for @toastDownloadRootEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载目录不能为空'**
  String get toastDownloadRootEmpty;

  /// No description provided for @toastDownloadRootUpdated.
  ///
  /// In zh_CN, this message translates to:
  /// **'已更新下载目录'**
  String get toastDownloadRootUpdated;

  /// No description provided for @toastTemplateEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件名模板不能为空'**
  String get toastTemplateEmpty;

  /// No description provided for @toastTemplateUpdated.
  ///
  /// In zh_CN, this message translates to:
  /// **'已更新文件名模板'**
  String get toastTemplateUpdated;

  /// No description provided for @settingsSpeedBs.
  ///
  /// In zh_CN, this message translates to:
  /// **'{n} B/s'**
  String settingsSpeedBs(Object n);

  /// No description provided for @settingsSpeedKbs.
  ///
  /// In zh_CN, this message translates to:
  /// **'{n} KB/s'**
  String settingsSpeedKbs(Object n);

  /// No description provided for @settingsSpeedMbs.
  ///
  /// In zh_CN, this message translates to:
  /// **'{n} MB/s'**
  String settingsSpeedMbs(Object n);

  /// No description provided for @settingsSectionFileLocation.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件位置'**
  String get settingsSectionFileLocation;

  /// No description provided for @settingsDataDir.
  ///
  /// In zh_CN, this message translates to:
  /// **'数据目录'**
  String get settingsDataDir;

  /// No description provided for @settingsLibraryDb.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体库数据库'**
  String get settingsLibraryDb;

  /// No description provided for @settingsUserDb.
  ///
  /// In zh_CN, this message translates to:
  /// **'用户数据库（加密）'**
  String get settingsUserDb;

  /// No description provided for @settingsLibraryDbLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体库路径'**
  String get settingsLibraryDbLabel;

  /// No description provided for @settingsUserDbLabel.
  ///
  /// In zh_CN, this message translates to:
  /// **'用户库路径'**
  String get settingsUserDbLabel;

  /// No description provided for @settingsCopy.
  ///
  /// In zh_CN, this message translates to:
  /// **'复制'**
  String get settingsCopy;

  /// No description provided for @toastCopied.
  ///
  /// In zh_CN, this message translates to:
  /// **'已复制{label}'**
  String toastCopied(Object label);

  /// No description provided for @settingsStorageNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体库与用户数据物理拆分；路径可用环境变量 ARCHOERA_DATA_DIR 覆盖。'**
  String get settingsStorageNote;

  /// No description provided for @settingsVersion.
  ///
  /// In zh_CN, this message translates to:
  /// **'版本'**
  String get settingsVersion;

  /// No description provided for @settingsVersionUnknown.
  ///
  /// In zh_CN, this message translates to:
  /// **'v未知 · Flutter 桌面端'**
  String get settingsVersionUnknown;

  /// No description provided for @settingsVersionFormat.
  ///
  /// In zh_CN, this message translates to:
  /// **'v{version} · Flutter 桌面端'**
  String settingsVersionFormat(Object version);

  /// No description provided for @settingsAudioEngine.
  ///
  /// In zh_CN, this message translates to:
  /// **'音频引擎'**
  String get settingsAudioEngine;

  /// No description provided for @settingsAudioEngineDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'内置 C 引擎（miniaudio）· 原生 FFI'**
  String get settingsAudioEngineDesc;

  /// No description provided for @settingsSubsonicServer.
  ///
  /// In zh_CN, this message translates to:
  /// **'Subsonic 服务端'**
  String get settingsSubsonicServer;

  /// No description provided for @settingsSubsonicDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'Go FFI · 曲库自托管'**
  String get settingsSubsonicDesc;

  /// No description provided for @settingsAboutDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'自研音乐播放器：本地曲库、直连音源、自托管 Subsonic、原生音频引擎。'**
  String get settingsAboutDesc;

  /// No description provided for @settingsSectionDeclaration.
  ///
  /// In zh_CN, this message translates to:
  /// **'软件声明'**
  String get settingsSectionDeclaration;

  /// No description provided for @settingsDeclineText.
  ///
  /// In zh_CN, this message translates to:
  /// **'本软件（ArchoeraMusic）是一款免费、开源的桌面音乐播放器，为个人学习研究用途，非商业软件。使用前请阅读以下声明：\n\n'**
  String get settingsDeclineText;

  /// No description provided for @settingsDecline1Title.
  ///
  /// In zh_CN, this message translates to:
  /// **'一、软件性质\n'**
  String get settingsDecline1Title;

  /// No description provided for @settingsDecline1Body.
  ///
  /// In zh_CN, this message translates to:
  /// **'本软件为第三方客户端，与各音乐平台及其官方客户端无任何关联、合作或授权关系；不以营利为目的，不接受任何商业合作、广告或捐赠。如需更完善的功能，请下载官方客户端体验。\n\n'**
  String get settingsDecline1Body;

  /// No description provided for @settingsDecline2Title.
  ///
  /// In zh_CN, this message translates to:
  /// **'二、内容来源与版权\n'**
  String get settingsDecline2Title;

  /// No description provided for @settingsDecline2Body.
  ///
  /// In zh_CN, this message translates to:
  /// **'本软件自身不提供、不存储、不分发任何音乐内容。音频、歌词、封面等均来自您的本地文件或各音乐平台公开接口，其版权归原权利人及平台所有，本软件不主张任何所有权。\n\n'**
  String get settingsDecline2Body;

  /// No description provided for @settingsDecline3Title.
  ///
  /// In zh_CN, this message translates to:
  /// **'三、版权数据处理义务\n'**
  String get settingsDecline3Title;

  /// No description provided for @settingsDecline3Body.
  ///
  /// In zh_CN, this message translates to:
  /// **'使用过程中产生的版权数据（播放链接、歌词、封面等）仅供您个人试听与学习研究，请勿用于商业或公开传播；建议在产生后 24 小时内清除。如需长期欣赏，请通过正版渠道购买或订阅，支持正版音乐。\n\n'**
  String get settingsDecline3Body;

  /// No description provided for @settingsDecline4Title.
  ///
  /// In zh_CN, this message translates to:
  /// **'四、使用限制\n'**
  String get settingsDecline4Title;

  /// No description provided for @settingsDecline4Body.
  ///
  /// In zh_CN, this message translates to:
  /// **'请勿利用本软件从事商业行为、批量抓取、爬取或转售内容；请勿在违反当地法律法规或相关平台服务条款的情况下使用本软件；请勿绕过在线平台的技术保护措施、访问控制或服务条款。\n\n'**
  String get settingsDecline4Body;

  /// No description provided for @settingsDecline5Title.
  ///
  /// In zh_CN, this message translates to:
  /// **'五、免责声明\n'**
  String get settingsDecline5Title;

  /// No description provided for @settingsDecline5Body.
  ///
  /// In zh_CN, this message translates to:
  /// **'本软件按「现状」提供，不对其作出任何明示或默示的保证。因使用或无法使用本软件，或因在线平台接口变更、账号限制、功能失效等产生的任何直接或间接损失，均由使用者自行承担。\n\n'**
  String get settingsDecline5Body;

  /// No description provided for @settingsDeclineFooter.
  ///
  /// In zh_CN, this message translates to:
  /// **'本软件仅用于技术探索与研究。如相关平台认为本软件不妥，可随时联系开发者进行调整或移除。'**
  String get settingsDeclineFooter;

  /// No description provided for @settingsSectionFontCredits.
  ///
  /// In zh_CN, this message translates to:
  /// **'字体署名'**
  String get settingsSectionFontCredits;

  /// No description provided for @settingsFontCreditsText.
  ///
  /// In zh_CN, this message translates to:
  /// **'本软件内置以下字体：\n· Noto Sans CJK SC（SIL Open Font License 1.1）\n· MiSans（© Xiaomi，依据《MiSans 字体知识产权许可协议》授权使用）\n· HarmonyOS Sans SC（© Huawei，依据《HarmonyOS Sans 字体许可协议》授权使用）'**
  String get settingsFontCreditsText;

  /// No description provided for @commonNoLyrics.
  ///
  /// In zh_CN, this message translates to:
  /// **'暂无歌词'**
  String get commonNoLyrics;

  /// No description provided for @commonTrackCount.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首'**
  String commonTrackCount(Object count);

  /// No description provided for @settingsSearchColorTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'已唱 / 未唱颜色'**
  String get settingsSearchColorTitle;

  /// No description provided for @settingsSearchColorSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌词行高亮与普通行颜色'**
  String get settingsSearchColorSubtitle;

  /// No description provided for @settingsSearchDesktopLyricsTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'桌面歌词'**
  String get settingsSearchDesktopLyricsTitle;

  /// No description provided for @settingsSearchDesktopLyricsSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'置顶独立歌词窗'**
  String get settingsSearchDesktopLyricsSubtitle;

  /// No description provided for @settingsSearchDjModeTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'Fuck DJ Mode'**
  String get settingsSearchDjModeTitle;

  /// No description provided for @settingsSearchFilenameTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'文件名模板'**
  String get settingsSearchFilenameTitle;

  /// No description provided for @settingsSearchAccentSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'自定义主色种子 · 色板'**
  String get settingsSearchAccentSubtitle;

  /// No description provided for @settingsThemeSource.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题色来源'**
  String get settingsThemeSource;

  /// No description provided for @settingsThemeSourceDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'主题色的获取方式'**
  String get settingsThemeSourceDesc;

  /// No description provided for @settingsThemeSourceDefault.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSourceDefault;

  /// No description provided for @settingsThemeSourceCustom.
  ///
  /// In zh_CN, this message translates to:
  /// **'自定义主色'**
  String get settingsThemeSourceCustom;

  /// No description provided for @settingsThemeSourceCover.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随封面'**
  String get settingsThemeSourceCover;

  /// No description provided for @settingsThemeSourceSolid.
  ///
  /// In zh_CN, this message translates to:
  /// **'无主题色'**
  String get settingsThemeSourceSolid;

  /// No description provided for @settingsThemeSourceCustomHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'选取主色种子，主/次色由它动态生成'**
  String get settingsThemeSourceCustomHint;

  /// No description provided for @settingsThemeSourceCoverHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'实时从当前播放封面提取主色（不可用时回退默认色）'**
  String get settingsThemeSourceCoverHint;

  /// No description provided for @settingsGlobalTint.
  ///
  /// In zh_CN, this message translates to:
  /// **'全局着色'**
  String get settingsGlobalTint;

  /// No description provided for @settingsGlobalTintDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'将主题色应用到全局界面'**
  String get settingsGlobalTintDesc;

  /// No description provided for @settingsGlobalTintNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'存在主题色（自定义/跟随封面）时生效；图片背景模式下强制开启。'**
  String get settingsGlobalTintNote;

  /// No description provided for @settingsSectionStyle.
  ///
  /// In zh_CN, this message translates to:
  /// **'背景风格'**
  String get settingsSectionStyle;

  /// No description provided for @settingsAppearanceStyle.
  ///
  /// In zh_CN, this message translates to:
  /// **'外观风格'**
  String get settingsAppearanceStyle;

  /// No description provided for @settingsAppearanceStyleDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'应用主背景的呈现方式'**
  String get settingsAppearanceStyleDesc;

  /// No description provided for @settingsAppearanceStyleSolid.
  ///
  /// In zh_CN, this message translates to:
  /// **'纯色背景'**
  String get settingsAppearanceStyleSolid;

  /// No description provided for @settingsAppearanceStyleImage.
  ///
  /// In zh_CN, this message translates to:
  /// **'自定义图片'**
  String get settingsAppearanceStyleImage;

  /// No description provided for @settingsBackgroundImage.
  ///
  /// In zh_CN, this message translates to:
  /// **'背景图片'**
  String get settingsBackgroundImage;

  /// No description provided for @settingsBackgroundImageDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'选择本地图片作为应用背景；图片模式强制暗色 + 全局着色'**
  String get settingsBackgroundImageDesc;

  /// No description provided for @settingsBackgroundPick.
  ///
  /// In zh_CN, this message translates to:
  /// **'选择图片'**
  String get settingsBackgroundPick;

  /// No description provided for @settingsBackgroundReplace.
  ///
  /// In zh_CN, this message translates to:
  /// **'更换'**
  String get settingsBackgroundReplace;

  /// No description provided for @settingsBackgroundClear.
  ///
  /// In zh_CN, this message translates to:
  /// **'清除'**
  String get settingsBackgroundClear;

  /// No description provided for @settingsBackgroundBlur.
  ///
  /// In zh_CN, this message translates to:
  /// **'背景模糊'**
  String get settingsBackgroundBlur;

  /// No description provided for @settingsBackgroundBlurDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'对背景图片应用高斯模糊（{blur}px）'**
  String settingsBackgroundBlurDesc(Object blur);

  /// No description provided for @settingsBackgroundDim.
  ///
  /// In zh_CN, this message translates to:
  /// **'遮罩浓度'**
  String get settingsBackgroundDim;

  /// No description provided for @settingsBackgroundDimDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'叠加的黑色遮罩透明度（{dim}%），越高前景越易读'**
  String settingsBackgroundDimDesc(Object dim);

  /// No description provided for @settingsBackgroundScale.
  ///
  /// In zh_CN, this message translates to:
  /// **'缩放大小'**
  String get settingsBackgroundScale;

  /// No description provided for @settingsBackgroundScaleDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'背景图的缩放倍数（{scale}x）'**
  String settingsBackgroundScaleDesc(Object scale);

  /// No description provided for @settingsSidebarCollapsed.
  ///
  /// In zh_CN, this message translates to:
  /// **'折叠侧边栏'**
  String get settingsSidebarCollapsed;

  /// No description provided for @settingsSidebarCollapsedDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'将侧边栏折叠为图标模式'**
  String get settingsSidebarCollapsedDesc;

  /// No description provided for @settingsSidebarNavStyle.
  ///
  /// In zh_CN, this message translates to:
  /// **'导航高亮动效'**
  String get settingsSidebarNavStyle;

  /// No description provided for @settingsSidebarNavStyleDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'切换侧边栏导航高亮指示器的动画风格'**
  String get settingsSidebarNavStyleDesc;

  /// No description provided for @settingsSidebarNavStyleDefault.
  ///
  /// In zh_CN, this message translates to:
  /// **'静态'**
  String get settingsSidebarNavStyleDefault;

  /// No description provided for @settingsSidebarNavStyleAnimated.
  ///
  /// In zh_CN, this message translates to:
  /// **'滑动'**
  String get settingsSidebarNavStyleAnimated;

  /// No description provided for @settingsRouteTransition.
  ///
  /// In zh_CN, this message translates to:
  /// **'页面切换动效'**
  String get settingsRouteTransition;

  /// No description provided for @settingsRouteTransitionDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'切换页面时的过渡动画效果'**
  String get settingsRouteTransitionDesc;

  /// No description provided for @settingsRouteTransitionNone.
  ///
  /// In zh_CN, this message translates to:
  /// **'无'**
  String get settingsRouteTransitionNone;

  /// No description provided for @settingsRouteTransitionFade.
  ///
  /// In zh_CN, this message translates to:
  /// **'淡入淡出'**
  String get settingsRouteTransitionFade;

  /// No description provided for @settingsRouteTransitionSlide.
  ///
  /// In zh_CN, this message translates to:
  /// **'滑动'**
  String get settingsRouteTransitionSlide;

  /// No description provided for @settingsRouteTransitionZoom.
  ///
  /// In zh_CN, this message translates to:
  /// **'缩放'**
  String get settingsRouteTransitionZoom;

  /// No description provided for @settingsSearchThemeSourceSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认主题色 · 自定义主色 · 跟随封面 · 无主题色'**
  String get settingsSearchThemeSourceSubtitle;

  /// No description provided for @settingsSearchGlobalTintSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'将主题色应用到全局界面'**
  String get settingsSearchGlobalTintSubtitle;

  /// No description provided for @settingsSearchBackgroundSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'纯色 / 图片 · 模糊 · 遮罩 · 缩放'**
  String get settingsSearchBackgroundSubtitle;

  /// No description provided for @settingsSearchSidebarSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'折叠侧边栏 · 静态 / 滑动高亮'**
  String get settingsSearchSidebarSubtitle;

  /// No description provided for @settingsSearchRouteTransitionSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'无 · 淡入淡出 · 滑动 · 缩放'**
  String get settingsSearchRouteTransitionSubtitle;

  /// No description provided for @settingsSearchFloatingBarSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'底部悬浮胶囊 · 全宽停靠'**
  String get settingsSearchFloatingBarSubtitle;

  /// No description provided for @settingsSearchFontSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'MiSans · HarmonyOS Sans SC'**
  String get settingsSearchFontSubtitle;

  /// No description provided for @settingsSearchLanguageSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'跟随系统 · 简体中文 · English · 日本語'**
  String get settingsSearchLanguageSubtitle;

  /// No description provided for @settingsSearchCoverRadiusSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'直角 · 圆角 · 大圆角'**
  String get settingsSearchCoverRadiusSubtitle;

  /// No description provided for @settingsSearchPassthroughSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'不转码 · 48kHz 转码管线'**
  String get settingsSearchPassthroughSubtitle;

  /// No description provided for @settingsSearchSessionMemorySubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'记录/恢复播放现场'**
  String get settingsSearchSessionMemorySubtitle;

  /// No description provided for @settingsSearchAutoPlaySubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'自动续播开关'**
  String get settingsSearchAutoPlaySubtitle;

  /// No description provided for @settingsSearchSpectrumSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'播放界面频谱开关 · 透明度'**
  String get settingsSearchSpectrumSubtitle;

  /// No description provided for @settingsSearchSpectrumWidthSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'1~12px 柱宽调节'**
  String get settingsSearchSpectrumWidthSubtitle;

  /// No description provided for @settingsSearchPlayerLyricsSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'全屏播放器歌词显示'**
  String get settingsSearchPlayerLyricsSubtitle;

  /// No description provided for @settingsSearchLyricFontSizeSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'14~28px 播放器歌词字号'**
  String get settingsSearchLyricFontSizeSubtitle;

  /// No description provided for @settingsSearchLyricLineHeightSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'42~64px 行高调节'**
  String get settingsSearchLyricLineHeightSubtitle;

  /// No description provided for @settingsSearchUncensorSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'还原歌词中被星号遮盖的词'**
  String get settingsSearchUncensorSubtitle;

  /// No description provided for @settingsSearchHideVipSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌曲列表 VIP / 付费角标隐藏'**
  String get settingsSearchHideVipSubtitle;

  /// No description provided for @settingsSearchHideQualitySubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌曲列表音质角标隐藏'**
  String get settingsSearchHideQualitySubtitle;

  /// No description provided for @settingsSearchSubtitleSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌曲列表展示别名（如 (Live)）'**
  String get settingsSearchSubtitleSubtitle;

  /// No description provided for @settingsSearchDownloadDirSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'下载保存位置（默认 ~/Music/ArchoeraMusic）'**
  String get settingsSearchDownloadDirSubtitle;

  /// No description provided for @settingsSearchFilenameSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'<artist>/<title>/<album> 占位符可配置'**
  String get settingsSearchFilenameSubtitle;

  /// No description provided for @settingsSearchConcurrentSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'1~5 个并行下载任务'**
  String get settingsSearchConcurrentSubtitle;

  /// No description provided for @settingsSearchSpeedLimitSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'不限速 · 0.5~20 MB/s 实时生效'**
  String get settingsSearchSpeedLimitSubtitle;

  /// No description provided for @settingsSearchQualitySubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'Hi-Res · 无损 · HQ · SQ · LQ'**
  String get settingsSearchQualitySubtitle;

  /// No description provided for @settingsSearchGroupingSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'平铺 · 按平台 · 按歌手'**
  String get settingsSearchGroupingSubtitle;

  /// No description provided for @settingsSearchHistoryLimitSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'超上限自动淘汰最旧（10~500）'**
  String get settingsSearchHistoryLimitSubtitle;

  /// No description provided for @settingsSearchStorageSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体库 · 用户数据库路径'**
  String get settingsSearchStorageSubtitle;

  /// No description provided for @settingsSearchAboutSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'音频引擎 · Subsonic 服务端'**
  String get settingsSearchAboutSubtitle;

  /// No description provided for @qualityLossless.
  ///
  /// In zh_CN, this message translates to:
  /// **'无损'**
  String get qualityLossless;

  /// No description provided for @repeatModeList.
  ///
  /// In zh_CN, this message translates to:
  /// **'列表循环'**
  String get repeatModeList;

  /// No description provided for @repeatModeOne.
  ///
  /// In zh_CN, this message translates to:
  /// **'单曲循环'**
  String get repeatModeOne;

  /// No description provided for @commonUnknownTrack.
  ///
  /// In zh_CN, this message translates to:
  /// **'未知名歌曲'**
  String get commonUnknownTrack;

  /// No description provided for @commonAnonymousUser.
  ///
  /// In zh_CN, this message translates to:
  /// **'匿名用户'**
  String get commonAnonymousUser;

  /// No description provided for @commonCanceled.
  ///
  /// In zh_CN, this message translates to:
  /// **'已取消'**
  String get commonCanceled;

  /// No description provided for @commonILike.
  ///
  /// In zh_CN, this message translates to:
  /// **'我喜欢'**
  String get commonILike;

  /// No description provided for @sidebarStreaming.
  ///
  /// In zh_CN, this message translates to:
  /// **'流媒体'**
  String get sidebarStreaming;

  /// No description provided for @settingsCatMediaSource.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体源'**
  String get settingsCatMediaSource;

  /// No description provided for @settingsMediaSourceSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'流媒体服务器（Subsonic / Jellyfin / Emby）'**
  String get settingsMediaSourceSubtitle;

  /// No description provided for @settingsCatScrape.
  ///
  /// In zh_CN, this message translates to:
  /// **'刮削'**
  String get settingsCatScrape;

  /// No description provided for @settingsScrapeSubtitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'多源元数据补齐 · 封面 / 歌词 / 标签'**
  String get settingsScrapeSubtitle;

  /// No description provided for @settingsSectionScrapeDirs.
  ///
  /// In zh_CN, this message translates to:
  /// **'刮削目录'**
  String get settingsSectionScrapeDirs;

  /// No description provided for @settingsScrapeDirsHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'每行一个目录；留空跟随媒体库扫描目录'**
  String get settingsScrapeDirsHint;

  /// No description provided for @settingsScrapeDirsEmptyNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'未配置刮削目录，刮削时将跟随媒体库扫描目录。'**
  String get settingsScrapeDirsEmptyNote;

  /// No description provided for @settingsScrapeDirsNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'当前生效目录：{dirs}'**
  String settingsScrapeDirsNote(Object dirs);

  /// No description provided for @settingsSectionScrapeSources.
  ///
  /// In zh_CN, this message translates to:
  /// **'数据源'**
  String get settingsSectionScrapeSources;

  /// No description provided for @settingsScrapeSourceMusicBrainz.
  ///
  /// In zh_CN, this message translates to:
  /// **'MusicBrainz'**
  String get settingsScrapeSourceMusicBrainz;

  /// No description provided for @settingsScrapeSourceDeezer.
  ///
  /// In zh_CN, this message translates to:
  /// **'Deezer'**
  String get settingsScrapeSourceDeezer;

  /// No description provided for @settingsScrapeSourceItunes.
  ///
  /// In zh_CN, this message translates to:
  /// **'iTunes'**
  String get settingsScrapeSourceItunes;

  /// No description provided for @settingsScrapeSourceNetease.
  ///
  /// In zh_CN, this message translates to:
  /// **'网易云音乐'**
  String get settingsScrapeSourceNetease;

  /// No description provided for @settingsScrapeSourceQQMusic.
  ///
  /// In zh_CN, this message translates to:
  /// **'QQ 音乐'**
  String get settingsScrapeSourceQQMusic;

  /// No description provided for @settingsScrapeSourceKugou.
  ///
  /// In zh_CN, this message translates to:
  /// **'酷狗音乐'**
  String get settingsScrapeSourceKugou;

  /// No description provided for @settingsScrapeSourceKuwo.
  ///
  /// In zh_CN, this message translates to:
  /// **'酷我音乐'**
  String get settingsScrapeSourceKuwo;

  /// No description provided for @settingsScrapeSourceMigu.
  ///
  /// In zh_CN, this message translates to:
  /// **'咪咕音乐'**
  String get settingsScrapeSourceMigu;

  /// No description provided for @settingsScrapeSourceAcoustID.
  ///
  /// In zh_CN, this message translates to:
  /// **'AcoustID（音频指纹）'**
  String get settingsScrapeSourceAcoustID;

  /// No description provided for @settingsScrapeSourceDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'开启后参与多源查询、相似度比对与评分合并'**
  String get settingsScrapeSourceDesc;

  /// No description provided for @settingsSectionScrapeProgress.
  ///
  /// In zh_CN, this message translates to:
  /// **'刮削进度'**
  String get settingsSectionScrapeProgress;

  /// No description provided for @settingsScrapeStart.
  ///
  /// In zh_CN, this message translates to:
  /// **'开始刮削'**
  String get settingsScrapeStart;

  /// No description provided for @settingsScrapeCancel.
  ///
  /// In zh_CN, this message translates to:
  /// **'取消刮削'**
  String get settingsScrapeCancel;

  /// No description provided for @settingsScrapeScanning.
  ///
  /// In zh_CN, this message translates to:
  /// **'正在扫描目录…'**
  String get settingsScrapeScanning;

  /// No description provided for @settingsScrapeCurrent.
  ///
  /// In zh_CN, this message translates to:
  /// **'正在处理：{file}'**
  String settingsScrapeCurrent(Object file);

  /// No description provided for @settingsScrapeSuccess.
  ///
  /// In zh_CN, this message translates to:
  /// **'成功'**
  String get settingsScrapeSuccess;

  /// No description provided for @settingsScrapeFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'失败'**
  String get settingsScrapeFailed;

  /// No description provided for @settingsScrapeSkipped.
  ///
  /// In zh_CN, this message translates to:
  /// **'跳过'**
  String get settingsScrapeSkipped;

  /// No description provided for @settingsScrapeNotFound.
  ///
  /// In zh_CN, this message translates to:
  /// **'未匹配'**
  String get settingsScrapeNotFound;

  /// No description provided for @settingsScrapeIdle.
  ///
  /// In zh_CN, this message translates to:
  /// **'尚未刮削，点击下方按钮开始。'**
  String get settingsScrapeIdle;

  /// No description provided for @settingsScrapeNoDirs.
  ///
  /// In zh_CN, this message translates to:
  /// **'没有可刮削的目录，请先配置刮削目录或媒体库扫描目录。'**
  String get settingsScrapeNoDirs;

  /// No description provided for @settingsScrapeDone.
  ///
  /// In zh_CN, this message translates to:
  /// **'刮削完成'**
  String get settingsScrapeDone;

  /// No description provided for @settingsScrapeCanceled.
  ///
  /// In zh_CN, this message translates to:
  /// **'刮削已取消'**
  String get settingsScrapeCanceled;

  /// No description provided for @toastScrapeNoDirs.
  ///
  /// In zh_CN, this message translates to:
  /// **'没有可刮削的目录'**
  String get toastScrapeNoDirs;

  /// No description provided for @toastScrapeDirsUpdated.
  ///
  /// In zh_CN, this message translates to:
  /// **'刮削目录已保存'**
  String get toastScrapeDirsUpdated;

  /// No description provided for @toastScrapeStarted.
  ///
  /// In zh_CN, this message translates to:
  /// **'已开始刮削'**
  String get toastScrapeStarted;

  /// No description provided for @commonDelete.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除'**
  String get commonDelete;

  /// No description provided for @commonSave.
  ///
  /// In zh_CN, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonConfirm.
  ///
  /// In zh_CN, this message translates to:
  /// **'确定'**
  String get commonConfirm;

  /// No description provided for @streamingHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'媒体源'**
  String get streamingHint;

  /// No description provided for @streamingHintDetail.
  ///
  /// In zh_CN, this message translates to:
  /// **'添加流媒体服务器，浏览并播放服务器上的音乐（支持 Subsonic 家族 / Jellyfin / Emby，含本机内置 Subsonic 服务端）。'**
  String get streamingHintDetail;

  /// No description provided for @streamingServerAdd.
  ///
  /// In zh_CN, this message translates to:
  /// **'添加服务器'**
  String get streamingServerAdd;

  /// No description provided for @streamingEmptyNoServer.
  ///
  /// In zh_CN, this message translates to:
  /// **'还没有流媒体服务器'**
  String get streamingEmptyNoServer;

  /// No description provided for @streamingEmptyAddHint.
  ///
  /// In zh_CN, this message translates to:
  /// **'点击上方按钮添加一个服务器'**
  String get streamingEmptyAddHint;

  /// No description provided for @streamingServerConnected.
  ///
  /// In zh_CN, this message translates to:
  /// **'已连接'**
  String get streamingServerConnected;

  /// No description provided for @streamingServerDisconnected.
  ///
  /// In zh_CN, this message translates to:
  /// **'未连接'**
  String get streamingServerDisconnected;

  /// No description provided for @streamingServerLastConnected.
  ///
  /// In zh_CN, this message translates to:
  /// **'最近连接'**
  String get streamingServerLastConnected;

  /// No description provided for @streamingServerDisconnect.
  ///
  /// In zh_CN, this message translates to:
  /// **'断开连接'**
  String get streamingServerDisconnect;

  /// No description provided for @streamingToastDisconnected.
  ///
  /// In zh_CN, this message translates to:
  /// **'已断开服务器连接'**
  String get streamingToastDisconnected;

  /// No description provided for @streamingServerConnect.
  ///
  /// In zh_CN, this message translates to:
  /// **'连接'**
  String get streamingServerConnect;

  /// No description provided for @streamingToastConnected.
  ///
  /// In zh_CN, this message translates to:
  /// **'已连接 {name}'**
  String streamingToastConnected(Object name);

  /// No description provided for @streamingServerConnectFailed.
  ///
  /// In zh_CN, this message translates to:
  /// **'连接失败'**
  String get streamingServerConnectFailed;

  /// No description provided for @streamingServerEdit.
  ///
  /// In zh_CN, this message translates to:
  /// **'编辑'**
  String get streamingServerEdit;

  /// No description provided for @streamingServerDeleteConfirmTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'删除服务器'**
  String get streamingServerDeleteConfirmTitle;

  /// No description provided for @streamingServerDeleteConfirm.
  ///
  /// In zh_CN, this message translates to:
  /// **'确定删除服务器「{name}」吗？'**
  String streamingServerDeleteConfirm(Object name);

  /// No description provided for @streamingServerRemoved.
  ///
  /// In zh_CN, this message translates to:
  /// **'服务器已删除'**
  String get streamingServerRemoved;

  /// No description provided for @streamingServerErrorNameEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'请输入服务器名称'**
  String get streamingServerErrorNameEmpty;

  /// No description provided for @streamingServerErrorHostEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'请输入服务器地址'**
  String get streamingServerErrorHostEmpty;

  /// No description provided for @streamingServerErrorPortInvalid.
  ///
  /// In zh_CN, this message translates to:
  /// **'端口无效（1~65535）'**
  String get streamingServerErrorPortInvalid;

  /// No description provided for @streamingServerErrorUsernameEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'请输入用户名'**
  String get streamingServerErrorUsernameEmpty;

  /// No description provided for @streamingServerErrorPasswordEmpty.
  ///
  /// In zh_CN, this message translates to:
  /// **'请输入密码'**
  String get streamingServerErrorPasswordEmpty;

  /// No description provided for @streamingServerAdded.
  ///
  /// In zh_CN, this message translates to:
  /// **'服务器已添加'**
  String get streamingServerAdded;

  /// No description provided for @streamingServerUpdated.
  ///
  /// In zh_CN, this message translates to:
  /// **'服务器已更新'**
  String get streamingServerUpdated;

  /// No description provided for @streamingServerType.
  ///
  /// In zh_CN, this message translates to:
  /// **'类型'**
  String get streamingServerType;

  /// No description provided for @streamingServerName.
  ///
  /// In zh_CN, this message translates to:
  /// **'名称'**
  String get streamingServerName;

  /// No description provided for @streamingServerNamePlaceholder.
  ///
  /// In zh_CN, this message translates to:
  /// **'例如：我的 Navidrome'**
  String get streamingServerNamePlaceholder;

  /// No description provided for @streamingServerHost.
  ///
  /// In zh_CN, this message translates to:
  /// **'服务器地址'**
  String get streamingServerHost;

  /// No description provided for @streamingServerHostPlaceholder.
  ///
  /// In zh_CN, this message translates to:
  /// **'例如：192.168.1.10:4533'**
  String get streamingServerHostPlaceholder;

  /// No description provided for @streamingServerPort.
  ///
  /// In zh_CN, this message translates to:
  /// **'端口'**
  String get streamingServerPort;

  /// No description provided for @streamingServerPortNote.
  ///
  /// In zh_CN, this message translates to:
  /// **'默认端口为 4533（Subsonic）/ 8096（Jellyfin）；留空自动匹配。'**
  String get streamingServerPortNote;

  /// No description provided for @streamingServerLocalTitle.
  ///
  /// In zh_CN, this message translates to:
  /// **'本机内置服务端'**
  String get streamingServerLocalTitle;

  /// No description provided for @streamingServerLocalDesc.
  ///
  /// In zh_CN, this message translates to:
  /// **'使用内置 Subsonic 服务端（本机媒体库）'**
  String get streamingServerLocalDesc;

  /// No description provided for @streamingServerUsername.
  ///
  /// In zh_CN, this message translates to:
  /// **'用户名'**
  String get streamingServerUsername;

  /// No description provided for @streamingServerPassword.
  ///
  /// In zh_CN, this message translates to:
  /// **'密码'**
  String get streamingServerPassword;

  /// No description provided for @streamingServerTestOk.
  ///
  /// In zh_CN, this message translates to:
  /// **'连接成功'**
  String get streamingServerTestOk;

  /// No description provided for @streamingServerTestFail.
  ///
  /// In zh_CN, this message translates to:
  /// **'连接失败'**
  String get streamingServerTestFail;

  /// No description provided for @streamingServerTest.
  ///
  /// In zh_CN, this message translates to:
  /// **'测试连接'**
  String get streamingServerTest;

  /// No description provided for @streamingTabsSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌曲'**
  String get streamingTabsSongs;

  /// No description provided for @streamingTabsAlbums.
  ///
  /// In zh_CN, this message translates to:
  /// **'专辑'**
  String get streamingTabsAlbums;

  /// No description provided for @streamingTabsArtists.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌手'**
  String get streamingTabsArtists;

  /// No description provided for @streamingTabsPlaylists.
  ///
  /// In zh_CN, this message translates to:
  /// **'歌单'**
  String get streamingTabsPlaylists;

  /// No description provided for @streamingEmptyGoToSettings.
  ///
  /// In zh_CN, this message translates to:
  /// **'去设置'**
  String get streamingEmptyGoToSettings;

  /// No description provided for @streamingEmptyNotConnected.
  ///
  /// In zh_CN, this message translates to:
  /// **'未连接到任何服务器'**
  String get streamingEmptyNotConnected;

  /// No description provided for @streamingTotalSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首歌曲'**
  String streamingTotalSongs(Object count);

  /// No description provided for @streamingTotalAlbums.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 张专辑'**
  String streamingTotalAlbums(Object count);

  /// No description provided for @streamingTotalArtists.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 位歌手'**
  String streamingTotalArtists(Object count);

  /// No description provided for @streamingTotalPlaylists.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 个歌单'**
  String streamingTotalPlaylists(Object count);

  /// No description provided for @streamingEmptyNoResults.
  ///
  /// In zh_CN, this message translates to:
  /// **'没有匹配的结果'**
  String get streamingEmptyNoResults;

  /// No description provided for @streamingAlbumSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首歌曲'**
  String streamingAlbumSongs(Object count);

  /// No description provided for @streamingArtistAlbums.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 张专辑'**
  String streamingArtistAlbums(Object count);

  /// No description provided for @streamingPlaylistSongs.
  ///
  /// In zh_CN, this message translates to:
  /// **'{count} 首歌曲'**
  String streamingPlaylistSongs(Object count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'de',
    'en',
    'es',
    'fr',
    'ja',
    'ko',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'CN':
            return AppLocalizationsZhCn();
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
