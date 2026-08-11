// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get menuTrackDetail => '미디어 상세';

  @override
  String get trackDetailDuration => '재생 시간';

  @override
  String get trackDetailArtist => '아티스트';

  @override
  String get trackDetailAlbum => '앨범';

  @override
  String get trackDetailSource => '소스';

  @override
  String get trackDetailPath => '경로';

  @override
  String get trackDetailFileSize => '파일 크기';

  @override
  String get trackDetailCodec => '코덱';

  @override
  String get trackDetailSampleRate => '샘플레이트';

  @override
  String get trackDetailBitDepth => '비트 심도';

  @override
  String get trackDetailBitrate => '비트레이트';

  @override
  String get trackDetailChannels => '채널';

  @override
  String get trackSourceLocal => '로컬 파일';

  @override
  String get trackSourceStreaming => '스트리밍';

  @override
  String get trackDetailQuality => '음질';

  @override
  String get batchSelectAll => '전체 선택';

  @override
  String get batchInvert => '선택 반전';

  @override
  String get batchPlay => '선택 재생';

  @override
  String get batchAddQueue => '대기열에 추가';

  @override
  String get batchDownload => '일괄 다운로드';

  @override
  String get batchExit => '다중 선택 종료';

  @override
  String get batchSelectHint => '다중 선택';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '대기열에 $count곡 추가됨';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '다운로드 대기열에 $count곡 추가됨';
  }

  @override
  String get settingsBarEnhancedLyrics => '바 고급 가사';

  @override
  String get settingsBarEnhancedLyricsOn => '단어 시간 가사가 있으면 노래방 하이라이트 표시';

  @override
  String get settingsBarEnhancedLyricsOff => '바에 일반 가사 항상 표시';

  @override
  String get settingsSectionClose => '앱 닫기';

  @override
  String get settingsSectionPower => '절전';

  @override
  String get settingsPowerSaver => '절전 모드';

  @override
  String get settingsPowerSaverOn =>
      '백그라운드에서 렌더링 감소（최소화 시 5 FPS, 포커스 아님/화면 꺼짐 시 1 FPS）';

  @override
  String get settingsPowerSaverOff => '항상 최대 프레임으로 렌더링';

  @override
  String get settingsSuppressSleep => '시스템 절전 비활성화';

  @override
  String get settingsSuppressSleepOn =>
      '재생 중에는 시스템을 깨운 상태로 유지하여 백그라운드 재생이 중단되지 않게 합니다';

  @override
  String get settingsSuppressSleepOff => '시스템이 유휴 시 절전될 수 있습니다';

  @override
  String get settingsPowerSaverNote =>
      '절전 모드는 창 상태 이벤트를 수신하여 프레임을 낮춥니다（폴링 없음）. 창이 숨겨지거나 화면이 꺼지면 엔진이 이미 렌더링을 중단합니다.（시스템 절전 비활성화는 재생 중에만 적용됩니다.）';

  @override
  String get settingsCloseBehavior => '앱을 닫을 때';

  @override
  String get settingsCloseBehaviorAsk => '매번 물어보기';

  @override
  String get settingsCloseBehaviorBackground => '백그라운드 재생';

  @override
  String get settingsCloseBehaviorQuit => '바로 종료';

  @override
  String get commonCloseConfirmTitle => '앱 종료';

  @override
  String get commonCloseConfirmMessage => '메인 창을 닫은 후';

  @override
  String get commonCloseConfirmRemember => '선택을 기억하고 다시 묻지 않기';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => 'Netease Music';

  @override
  String get brandKugou => 'Kugou Music';

  @override
  String get commonBack => '뒤로';

  @override
  String get commonCancel => '취소';

  @override
  String get commonClose => '닫기';

  @override
  String get commonDefault => '기본';

  @override
  String get commonGoLogin => '로그인';

  @override
  String get commonLike => '좋아요';

  @override
  String get commonLoading => '로딩 중';

  @override
  String get commonLossless => '무손실';

  @override
  String get commonOriginal => '원곡';

  @override
  String get commonMore => '더 보기';

  @override
  String get commonNext => '다음 곡';

  @override
  String get commonNoMore => '더 이상 없습니다';

  @override
  String get commonPrevious => '이전 곡';

  @override
  String get commonSettings => '설정';

  @override
  String get commonUnknownAlbum => '알 수 없는 앨범';

  @override
  String get commonUnknownArtist => '알 수 없는 가수';

  @override
  String get commonUnlike => '좋아요 취소';

  @override
  String get downloadQualityTitle => '다운로드 음질';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return '$platform 다운로드 링크를 가져오려면 로그인이 필요합니다. 미로그인 시 미리 듣기만 가능하며 전체 음질은 다운로드할 수 없습니다.\n\n$platform 계정에 로그인한 후 다시 시도해 주세요.';
  }

  @override
  String get downloadRequiresLoginTitle => '다운로드하려면 로그인이 필요합니다';

  @override
  String get menuComment => '댓글 보기';

  @override
  String get menuDownload => '다운로드';

  @override
  String get menuLike => '즐겨찾기에 추가';

  @override
  String get menuPlay => '재생';

  @override
  String get menuPlayNext => '다음에 재생';

  @override
  String get menuRemoveFromQueue => '대기열에서 제거';

  @override
  String get menuUnlike => '즐겨찾기에서 제거';

  @override
  String get navHeaderAccount => '계정';

  @override
  String get navHeaderComingSoon => '곧 제공 예정';

  @override
  String navHeaderKugouId(Object id) {
    return 'Kugou $id';
  }

  @override
  String get navHeaderKugouMusic => 'Kugou Music';

  @override
  String get navHeaderLoginAccount => '로그인(Netease / Kugou)';

  @override
  String get navHeaderLogout => '로그아웃';

  @override
  String get navHeaderNeteaseAccount => 'Netease 계정';

  @override
  String get navHeaderNeteaseMusic => 'Netease 음악';

  @override
  String get navHeaderQqMusic => 'QQ 음악';

  @override
  String get navHeaderQrLogin => 'QR 코드 로그인';

  @override
  String get navHeaderSearchHint => '노래 / 가수 / 재생 목록 검색';

  @override
  String get navHeaderThemeDark => '테마: 다크';

  @override
  String get navHeaderThemeLight => '테마: 라이트';

  @override
  String get navHeaderThemeSystem => '테마: 시스템';

  @override
  String get playerBarBuffering => '로딩 중…';

  @override
  String get playerBarIdleHint => '사이드바를 클릭하거나 소스를 불러오면 재생이 시작됩니다';

  @override
  String get playerBarOpenPlayer => '플레이어 열기';

  @override
  String get playerBarPlayPause => '재생/일시정지';

  @override
  String get playerBarPlaylist => '재생 목록';

  @override
  String get playerBarUntitled => '제목 없음';

  @override
  String get queueClear => '대기열 비우기';

  @override
  String get queueEmpty => '대기열이 비어 있습니다';

  @override
  String get queueEmptyHint => '목록에서 선택한 노래가 여기에 표시됩니다';

  @override
  String get queueRepeatList => '목록 반복';

  @override
  String get queueRepeatMode => '반복 모드';

  @override
  String get queueRepeatOne => '한 곡 반복';

  @override
  String get queueShuffle => '셔플 재생';

  @override
  String get queueShuffleOff => '셔플 재생 끄기';

  @override
  String get queueTitle => '재생 대기열';

  @override
  String queueTrackCount(Object count) {
    return '$count곡';
  }

  @override
  String get sidebarBackHome => '홈으로 돌아가기';

  @override
  String get sidebarCollapse => '사이드바 접기';

  @override
  String get sidebarDownload => '다운로드';

  @override
  String get sidebarExpand => '사이드바 펼치기';

  @override
  String get sidebarFavorites => '즐겨찾기';

  @override
  String get sidebarGroupMusic => '음악';

  @override
  String get sidebarGroupPersonal => '개인';

  @override
  String get sidebarHistory => '기록';

  @override
  String get sidebarHome => '홈';

  @override
  String get sidebarLibrary => '라이브러리';

  @override
  String get sidebarLiked => '좋아요';

  @override
  String get songListAlbum => '앨범';

  @override
  String get songListDuration => '길이';

  @override
  String get songListTitle => '제목';

  @override
  String get songListScrollTop => '맨 위로';

  @override
  String get songListLocatePlaying => '재생 위치 찾기';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return '다운로드 대기열에 추가되었습니다: $quality';
  }

  @override
  String get toastAddedToQueue => '재생 대기열에 추가되었습니다';

  @override
  String get toastDownloadEngineNotReady =>
      '다운로드 엔진이 준비되지 않았습니다. 나중에 다시 시도해 주세요';

  @override
  String get toastLiked => '즐겨찾기에 추가되었습니다';

  @override
  String get toastLoginRequiredKugou => '작업에 실패했습니다(Kugou 계정에 로그인했는지 확인해 주세요)';

  @override
  String get toastLoginRequiredNetease =>
      '작업에 실패했습니다(Netease 계정에 로그인했는지 확인해 주세요)';

  @override
  String get toastNoQualityInfo => '이 곡은 사용 가능한 음질 정보가 없어 다운로드할 수 없습니다';

  @override
  String get toastUnliked => '즐겨찾기에서 제거되었습니다';

  @override
  String get commonClear => '지우기';

  @override
  String get commonEmptyContent => '콘텐츠 없음';

  @override
  String commonLoadFailed(Object msg) {
    return '로드 실패: $msg';
  }

  @override
  String get commonRetry => '다시 시도';

  @override
  String get commentDuplicate => '같은 내용을 반복해서 보내지 마세요';

  @override
  String get commentEmpty => '아직 댓글이 없습니다';

  @override
  String get commentHot => '인기';

  @override
  String get commentInputEmpty => '댓글 내용은 비워 둘 수 없습니다';

  @override
  String get commentInputHint => '댓글을 입력하세요…';

  @override
  String get commentLatest => '최신';

  @override
  String commentLoginRequired(Object platform) {
    return '댓글을 보내려면 $platform 계정에 로그인해야 합니다';
  }

  @override
  String commentNotFound(Object platform) {
    return '이 노래의 $platform 댓글을 찾을 수 없습니다';
  }

  @override
  String get commentPublished => '댓글이 게시되었습니다';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user: $text';
  }

  @override
  String get commentSend => '보내기';

  @override
  String commentSendFailed(Object msg) {
    return '보내기 실패: $msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$month월 $day일 $time';
  }

  @override
  String get commentTitle => '댓글';

  @override
  String get folderAdd => '추가';

  @override
  String get folderBrowse => '찾아보기';

  @override
  String get folderEmpty => '아직 스캔 폴더가 없습니다. 아래 버튼으로 추가하세요';

  @override
  String get folderExists => '폴더가 이미 존재하거나 유효하지 않습니다';

  @override
  String get folderInvalid => '폴더가 존재하지 않거나, 이미 존재하거나, 비어 있습니다';

  @override
  String get folderPathHint => '폴더 절대 경로 입력';

  @override
  String get folderRemove => '제거';

  @override
  String get folderRemoveDescription =>
      '제거 후 이 폴더는 더 이상 스캔되지 않습니다. 이미 라이브러리에 추가된 곡은 유지됩니다.';

  @override
  String get folderRemoveTitle => '스캔 폴더 제거';

  @override
  String get loginFetchingQr => 'QR 코드 가져오는 중…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return '$platform 로그인됨';
  }

  @override
  String loginKugouLogin(Object platform) {
    return '$platform로 로그인';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return '$platform QR 코드 로그인';
  }

  @override
  String get loginKugouResponseMissingToken => '로그인 응답에 token/userid가 없습니다';

  @override
  String loginKugouScanHint(Object platform) {
    return '$platform 앱으로 QR 코드를 스캔하세요';
  }

  @override
  String loginKugouSession(Object platform) {
    return '$platform 로그인 상태';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return '$platform 로그인 성공, VIP 곡이 잠금 해제되었습니다';
  }

  @override
  String loginLoggedOut(Object platform) {
    return '$platform 로그아웃됨';
  }

  @override
  String loginLogoutWithId(Object id) {
    return '로그아웃($id)';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return '$platform QR 코드 로그인';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return '$platform 앱으로 QR 코드를 스캔하세요';
  }

  @override
  String get loginQrExpired => 'QR 코드가 만료되었습니다';

  @override
  String get loginQrExpiredRegenerate => 'QR 코드가 만료되었습니다. 클릭하여 다시 생성하세요';

  @override
  String get loginQrLogin => 'QR 코드 로그인';

  @override
  String get loginRefreshQr => 'QR 코드 새로고침';

  @override
  String get loginRegenerate => '다시 생성';

  @override
  String get loginSuccess => '로그인 성공';

  @override
  String get loginWaitingConfirm => '스캔되었습니다. 휴대폰에서 로그인을 확인해 주세요';

  @override
  String get splashTagline => '로컬 · 온라인 · 자체 호스팅';

  @override
  String get trackListArtistHotSongs => '가수 인기곡';

  @override
  String get trackListArtistSongs => '가수 노래';

  @override
  String get trackListDailyRecommend => '매일 추천';

  @override
  String get trackListDailyRecommendSubtitle => '취향에 맞게 매일 업데이트';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return '노래가 없습니다(매일 추천은 $platform 계정 로그인이 필요합니다)';
  }

  @override
  String get trackListNoPlayableSource =>
      '재생 가능한 소스가 없습니다(VIP / 미리 듣기 제한일 수 있음)';

  @override
  String get trackListPlayAll => '모두 재생';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return '재생 소스 가져오기 실패: $msg';
  }

  @override
  String get trayNext => '다음 곡';

  @override
  String get trayPlayPause => '재생 / 일시정지';

  @override
  String get trayPrevious => '이전 곡';

  @override
  String get trayQuit => '종료';

  @override
  String get trayShow => '메인 창 표시';

  @override
  String get commonPlayAll => '모두 재생';

  @override
  String get commonPause => '일시정지';

  @override
  String get commonPlay => '재생';

  @override
  String get commonRefresh => '새로고침';

  @override
  String get commonSearch => '검색';

  @override
  String get commonSongs => '곡';

  @override
  String get commonAlbums => '앨범';

  @override
  String get commonArtists => '아티스트';

  @override
  String get commonPlaylists => '플레이리스트';

  @override
  String get commonDone => '완료';

  @override
  String get commonUnknownError => '알 수 없는 오류';

  @override
  String commonSongCountHint(Object count) {
    return '총 $count곡 · 클릭하여 재생';
  }

  @override
  String get platformNetease => 'NetEase';

  @override
  String get platformKugou => 'Kugou';

  @override
  String get platformAll => '전체';

  @override
  String toastPlayedAll(Object count) {
    return '$count곡을 모두 재생했습니다';
  }

  @override
  String toastPlayFailed(Object msg) {
    return '재생 실패: $msg';
  }

  @override
  String get toastMissingLocalPath => '로컬 파일 경로가 없습니다';

  @override
  String get toastLocateComingSoon => '파일 관리자 열기 (Phase 2 예정)';

  @override
  String get toastRemovedFromLibrary => '라이브러리에서 제거했습니다';

  @override
  String get toastRemoveFailed => '제거 실패';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return '일일 추천은 $platform 계정 로그인이 필요합니다';
  }

  @override
  String get toastPlaylistEmpty => '플레이리스트에 곡이 없습니다';

  @override
  String get toastAlbumEmpty => '앨범에 곡이 없습니다';

  @override
  String get toastPausedAll => '모두 일시정지했습니다';

  @override
  String get toastResumedAll => '모두 다시 시작했습니다';

  @override
  String get toastPaused => '일시정지했습니다';

  @override
  String get toastCanceledTask => '취소하고 작업을 삭제했습니다';

  @override
  String get toastResumed => '다운로드를 재개했습니다';

  @override
  String get toastRequeued => '큐에 다시 추가했습니다';

  @override
  String get toastDeletedSelected => '선택한 작업을 삭제했습니다';

  @override
  String get toastDeletedSelectedWithMedia => '선택한 작업과 미디어 파일을 삭제했습니다';

  @override
  String get toastCleared => '다운로드 작업을 비웠습니다';

  @override
  String get toastClearedWithMedia => '작업을 비우고 미디어 파일을 삭제했습니다';

  @override
  String get toastDeletedTask => '작업을 삭제했습니다';

  @override
  String get toastDeletedTaskWithMedia => '작업과 미디어 파일을 삭제했습니다';

  @override
  String get pageHistoryRemoved => '기록에서 제거했습니다';

  @override
  String get pageHistoryClearTitle => '재생 기록 비우기';

  @override
  String get pageHistoryClearMessage => '모든 재생 기록을 비우시겠습니까? 이 작업은 되돌릴 수 없습니다.';

  @override
  String get pageHistoryCleared => '재생 기록을 비웠습니다';

  @override
  String get pageHistoryRemove => '기록에서 제거';

  @override
  String get pageHistorySubtitleEmpty => '로컬에 저장된 재생 기록';

  @override
  String get pageHistoryEmpty => '아직 재생 기록이 없습니다';

  @override
  String get pageHistoryEmptyHint => '재생한 곡은 자동으로 여기에 기록됩니다';

  @override
  String pageFavPlaylistCount(Object count) {
    return '총 $count개의 즐겨찾기 플레이리스트';
  }

  @override
  String get pageFavPlaylistLoginHint => '로그인하면 즐겨찾기 플레이리스트를 볼 수 있습니다';

  @override
  String pageFavAlbumCount(Object count) {
    return '총 $count장의 즐겨찾기 앨범';
  }

  @override
  String get pageFavAlbumLoginHint => '로그인하면 즐겨찾기 앨범을 볼 수 있습니다';

  @override
  String pageFavArtistCount(Object count) {
    return '총 $count명의 즐겨찾기 아티스트';
  }

  @override
  String get pageFavArtistLoginHint => '로그인하면 즐겨찾기 아티스트를 볼 수 있습니다';

  @override
  String get pageFavLoadFailed => '즐겨찾기 불러오기 실패';

  @override
  String get pageFavEmpty => '아직 즐겨찾기가 없습니다';

  @override
  String get pageFavEmptyHint =>
      'NetEase Cloud Music 앱에서 즐겨찾기에 추가하면 여기에 자동 동기화됩니다';

  @override
  String get pageFavLoginTitle => '로그인하여 즐겨찾기 보기';

  @override
  String get pageFavLoginDesc =>
      'NetEase Cloud Music 계정으로 QR 로그인하여 즐겨찾기 플레이리스트, 앨범, 아티스트를 동기화하세요';

  @override
  String get pageFavKgCreated => '내가 만든 플레이리스트';

  @override
  String get pageFavKgCollectedPlaylist => '저장한 플레이리스트';

  @override
  String get pageFavKgCollectedAlbum => '저장한 앨범';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '생성한 플레이리스트 $count개';
  }

  @override
  String get pageFavKgCreatedLoginHint => '로그인하면 만든 플레이리스트를 볼 수 있습니다';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '저장한 플레이리스트 $count개';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      '로그인하면 저장한 플레이리스트를 볼 수 있습니다';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '저장한 앨범 $count장';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint => '로그인하면 저장한 앨범을 볼 수 있습니다';

  @override
  String get pageFavKugouLoginDesc => '쿠거우에 QR 로그인하여 생성·저장한 플레이리스트와 앨범을 동기화하세요';

  @override
  String get pageFavKugouEmptyHint => '쿠거우 앱에서 즐겨찾기하면 자동 동기화됩니다';

  @override
  String pageSearchLoadingTrack(Object title) {
    return '로드 시작: $title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — 상세 페이지는 추후 제공';
  }

  @override
  String get menuViewArtist => '아티스트 보기';

  @override
  String get pageSearchArtistComingSoon => '아티스트 페이지는 Phase 2 예정';

  @override
  String get pageSearchInputHint => '검색어를 입력하세요';

  @override
  String get pageSearchInputSubtitle => '곡 / 앨범 / 아티스트 / 플레이리스트 지원';

  @override
  String get pageSearching => '검색 중…';

  @override
  String get pageSearchEmpty => '관련 콘텐츠를 찾을 수 없습니다';

  @override
  String get pageSearchEmptyHint => '다른 검색어를 시도해 보세요';

  @override
  String get pageSearchFailed => '검색 실패';

  @override
  String get pageLikedKugouLoginHint => '로그인하면 Kugou \'좋아요\'를 동기화할 수 있습니다';

  @override
  String get pageLikedNeteaseLoginHint => '로그인하면 NetEase 즐겨찾기를 동기화할 수 있습니다';

  @override
  String get pageLikedLoadFailed => '좋아요 목록 불러오기 실패';

  @override
  String get pageLikedEmpty => '아직 좋아요한 곡이 없습니다';

  @override
  String get pageLikedKugouEmptyHint => 'Kugou 앱에서 \'좋아요\'에 추가하면 여기에 자동 동기화됩니다';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'NetEase Cloud Music 앱에서 하트를 누르면 여기에 자동 동기화됩니다';

  @override
  String get pageLikedLoginTitle => '로그인하여 좋아요한 곡 보기';

  @override
  String get pageLikedKugouLoginDesc =>
      'Kugou 앱으로 QR 로그인하여 \'좋아요\' 컬렉션을 동기화하세요';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'NetEase Cloud Music 계정으로 QR 로그인하여 하트 컬렉션을 동기화하세요';

  @override
  String get libraryScanDirs => '스캔 디렉터리';

  @override
  String get libraryScanDirsDesc => '로컬 음악 스캔 디렉터리를 관리합니다. 추가 후 즉시 스캔합니다';

  @override
  String get libraryMediaStats => '미디어 통계';

  @override
  String get libraryMediaStatsDesc => '로컬 음악 라이브러리 개요';

  @override
  String get libraryStatTracks => '곡 수';

  @override
  String get libraryStatDuration => '총 재생 시간';

  @override
  String get libraryStatSize => '총 크기';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count곡';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count개';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h시간 $m분';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m분';
  }

  @override
  String librarySeconds(Object s) {
    return '$s초';
  }

  @override
  String get librarySearchHint => '로컬 곡 검색';

  @override
  String get libraryNoMatch => '일치하는 곡이 없습니다';

  @override
  String get libraryScanningFiles => '파일 집계 중…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count곡$extra';
  }

  @override
  String get libraryEmptyWaitScan => '첫 스캔 대기 중';

  @override
  String get libraryEmpty => '로컬 음악 라이브러리가 비어 있습니다';

  @override
  String get libraryEmptyScanHint => '아래 버튼을 클릭하여 지금 로컬 곡 스캔';

  @override
  String get libraryEmptyAddHint => '음악 폴더를 추가하면 스캔하여 라이브러리에 추가합니다';

  @override
  String get libraryScanNow => '지금 스캔';

  @override
  String get libraryAddFolder => '폴더 추가';

  @override
  String get menuLocateFile => '파일 위치 찾기';

  @override
  String get menuLocateFileComingSoon => '파일 관리자는 Phase 2에서 지원';

  @override
  String get menuRemoveFromLibrary => '라이브러리에서 제거';

  @override
  String get playerBarCollapsePlayer => '플레이어 접기';

  @override
  String get playerBarHideLyrics => '가사 숨기기';

  @override
  String get playerBarShowLyrics => '가사 보기';

  @override
  String get playerPageNotPlaying => '재생 중이 아님';

  @override
  String get playerPageLoadHint => '소스를 로드한 후 재생을 시작하세요';

  @override
  String get playerPageQualityMenu => '음질 전환';

  @override
  String get pageHomeRankTitle => '순위';

  @override
  String get pageHomePlaylistSquare => '플레이리스트 광장';

  @override
  String get pageHomeHotArtists => '인기 아티스트';

  @override
  String get pageHomePlaylists => '추천 플레이리스트';

  @override
  String get pageHomeNewAlbums => '신규 앨범';

  @override
  String get pageHomeRankSubtitle => '각 차트의 실시간 인기곡';

  @override
  String get pageHomePlaylistSquareSubtitle => '더 멋진 플레이리스트 발견';

  @override
  String get pageHomeArtistSubtitle => '인기 아티스트, 원형 아바타';

  @override
  String get pageHomeLoadFailed => '추천 불러오기 실패';

  @override
  String get pageHomePlaylistsSubtitle => '당신의 취향에 맞춰 추천';

  @override
  String get pageHomeNewAlbumsSubtitle => '최근 주목할 새 앨범';

  @override
  String get pageHomeHotArtistsSubtitle => '모두가 듣고 있어요';

  @override
  String get pageHomeDaily => '일일 추천';

  @override
  String get pageHomeDailyLoggedIn => '당신의 취향에 맞춰 엄선';

  @override
  String get pageHomeDailyLoginHint => 'NetEase 계정에 로그인하면 매일 업데이트됩니다';

  @override
  String get pageHomeDailyPlay => '오늘의 추천 재생';

  @override
  String get pageHomeDailyLogin => '로그인하여 일일 추천 잠금 해제';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting, $name';
  }

  @override
  String get greetingLate => '늦은 밤이네요';

  @override
  String get greetingMorning => '좋은 아침';

  @override
  String get greetingAfternoon => '좋은 오후';

  @override
  String get greetingEvening => '좋은 저녁';

  @override
  String get greetingFallback => '오늘 뭐 듣고 싶으세요?';

  @override
  String get downloadDeleteTaskOnly => '작업만 삭제';

  @override
  String get downloadDeleteWithMedia => '작업 및 미디어 파일 삭제';

  @override
  String downloadSelectedCount(Object count) {
    return '$count개 선택됨';
  }

  @override
  String get downloadSelectAll => '모두 선택';

  @override
  String get downloadDeselectAll => '선택 해제';

  @override
  String get downloadPauseAll => '모두 일시정지';

  @override
  String get downloadResumeAll => '모두 시작';

  @override
  String get downloadDeleteSelected => '선택 항목 삭제';

  @override
  String get downloadExitSelect => '일괄 선택 종료';

  @override
  String downloadActiveCount(Object count) {
    return '진행 중 $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return '완료 $count';
  }

  @override
  String get downloadOpenDir => '다운로드 폴더 열기';

  @override
  String get downloadSelectMode => '일괄 선택';

  @override
  String get downloadEmpty => '다운로드 작업 없음';

  @override
  String get downloadEmptyHint => '곡에서 마우스 오른쪽 클릭 → 다운로드로 큐에 추가';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return '선택한 $count개 작업 삭제';
  }

  @override
  String get downloadDeleteSelectedMessage =>
      '선택 작업과 .tmp 캐시 삭제；미디어 파일은 정확히 일치할 때만 삭제.';

  @override
  String get downloadClearTitle => '다운로드 작업 비우기';

  @override
  String get downloadClearMessage => '모든 작업과 .tmp 캐시 삭제；미디어 파일은 정확히 일치할 때만 삭제.';

  @override
  String get downloadCancelTooltip => '취소 (작업 삭제 및 캐시 정리)';

  @override
  String get downloadResume => '다운로드 재개';

  @override
  String get downloadOpenDirTask => '저장 폴더 열기';

  @override
  String get downloadDeleteTask => '작업 삭제';

  @override
  String get downloadDeleteWithMediaExact => '작업 및 미디어 파일 삭제 (정확히 일치)';

  @override
  String get downloadStatusQueued => '대기 중…';

  @override
  String get downloadStatusResolving => '다운로드 주소 해석 중…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return '다운로드 중 $percent% ($received) $speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return '다운로드 중…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return '일시정지됨 ($received)';
  }

  @override
  String get downloadStatusPaused => '일시정지됨';

  @override
  String downloadStatusFailed(Object error) {
    return '실패: $error';
  }

  @override
  String get downloadStatusFailedUnknown => '실패: 알 수 없는 오류';

  @override
  String get downloadStatusCanceled => '취소됨';

  @override
  String downloadStatusDone(Object size) {
    return '완료 ($size)';
  }

  @override
  String get downloadStatusAlready => '파일이 이미 존재합니다';

  @override
  String get pageHomeTitle => '발견';

  @override
  String get settingsTitle => '설정';

  @override
  String get settingsCatAppearance => '외관';

  @override
  String get settingsCatPlayback => '재생';

  @override
  String get settingsCatLyrics => '가사';

  @override
  String get settingsCatPreset => '동작';

  @override
  String get settingsCatDownload => '다운로드';

  @override
  String get settingsCatStorage => '저장소';

  @override
  String get settingsCatAbout => '정보';

  @override
  String get settingsAppearanceSubtitle => '테마 · 인터페이스 환경설정';

  @override
  String get settingsPlaybackSubtitle => '오디오 엔진 · 재생 동작';

  @override
  String get settingsLyricsSubtitle => '플레이어 가사 · 데스크톱 가사';

  @override
  String get settingsPresetSubtitle => '재생 필터 · 가사 복원 · 목록 태그';

  @override
  String get settingsDownloadSubtitle =>
      '다운로드 폴더 · 동시 실행 · 속도 제한 · 음질 · 그룹화 · 파일명';

  @override
  String get settingsStorageSubtitle => '데이터 디렉토리 · 데이터베이스 파일';

  @override
  String get settingsAboutSubtitle => '버전 · 프로젝트 정보';

  @override
  String get settingsCatDeveloper => '개발자';

  @override
  String get settingsDeveloperSubtitle => '개발자 모드 · 숨김 기능';

  @override
  String get settingsDeveloperTitle => '개발자 모드';

  @override
  String get settingsDeveloperMode => '개발자 모드';

  @override
  String get settingsDeveloperModeOn => '활성화됨 (다운로드 기능 표시)';

  @override
  String get settingsDeveloperModeOff => '비활성화됨 (다운로드 기능 숨김)';

  @override
  String get settingsDeveloperDownloadModule => '다운로드 모듈';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      '사이드바의 \'다운로드\' 항목, 상황에 맞는 메뉴의 \'다운로드\', 설정의 \'다운로드\' 카테고리는 개발자 모드가 켜진 경우에만 표시됩니다.';

  @override
  String get settingsDeveloperNote =>
      '개발자 모드는 로컬 디버깅 및 개인 용도로 제공됩니다. 사용에 따른 책임은 본인에게 있습니다.';

  @override
  String get settingsDevFpsMonitor => 'FPS/메모리 모니터 오버레이';

  @override
  String get settingsDevFpsMonitorDesc =>
      '오른쪽 위에 FPS·평균 프레임 시간·프로세스 메모리를 실시간 표시(클릭 시 접기). 기본 꺼짐. 개발자 모드를 끄면 함께 꺼집니다.';

  @override
  String get settingsDeveloperEnabled => '개발자 모드가 활성화되었습니다';

  @override
  String get settingsDeveloperDisabled => '개발자 모드가 비활성화되었습니다';

  @override
  String get settingsDeveloperHoldHint =>
      '개발자 모드를 켜려면 10초 동안 길게 누르세요 (마우스: 누른 채 유지)';

  @override
  String get settingsSearchHint => '설정 검색…';

  @override
  String settingsSearchNoResult(Object query) {
    return '「$query」 관련 설정을 찾을 수 없습니다';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '$count개 일치';
  }

  @override
  String get settingsSectionTheme => '테마';

  @override
  String get settingsThemeMode => '테마 모드';

  @override
  String get settingsThemeModeDesc => '라이트 / 다크 / 시스템 따르기';

  @override
  String get settingsThemeLight => '라이트';

  @override
  String get settingsThemeDark => '다크';

  @override
  String get settingsThemeSystem => '시스템 따르기';

  @override
  String get settingsThemeNote => '기본은 다크 테마；「시스템 따르기」는 OS 설정을 따릅니다.';

  @override
  String get settingsSectionAccent => '강조 색상';

  @override
  String get settingsAccentTitle => '기본 색상 시드';

  @override
  String settingsAccentSystem(Object color) {
    return '시스템 강조 색상 따르기（$color）';
  }

  @override
  String get settingsAccentSystemFallback => '시스템 강조 색상 따르기（감지되지 않음, 커스텀로 폴백）';

  @override
  String get settingsAccentDefault => '기본 밝은 파랑（디자인 시스템）';

  @override
  String get settingsAccentCustom => '커스텀（시드에서 primary/secondary 동적 생성）';

  @override
  String get settingsAccentDefaultTooltip => '기본 파랑';

  @override
  String get settingsAccentSystemTooltip => '시스템 강조 색상 따르기';

  @override
  String get settingsAccentCustomTooltip => '커스텀 색상 선택기';

  @override
  String get settingsSectionLayout => '레이아웃';

  @override
  String get settingsFloatingBar => '플로팅 플레이어 바';

  @override
  String get settingsFloatingBarOn => '하단 중앙 둥근 캡슐（글래스 패널 + 그림자）';

  @override
  String get settingsFloatingBarOff => '전체 너비 도킹（기본）';

  @override
  String get settingsSectionFont => '인터페이스 글꼴';

  @override
  String get settingsFontTitle => '인터페이스 글꼴';

  @override
  String get settingsFontMiSans => 'MiSans（기본）';

  @override
  String get settingsFontNoto => 'Noto Sans KR（Google 표준 메트릭）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans（Huawei 무료 상업용）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans KR';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => '인터페이스 언어';

  @override
  String get settingsLanguageTitle => '인터페이스 언어';

  @override
  String get settingsLanguageDesc => '인터페이스 표시 언어 전환';

  @override
  String get settingsLangSystem => '시스템 따르기';

  @override
  String get settingsSectionCover => '커버 아트';

  @override
  String get settingsCoverRadius => '커버 모서리 둥글게';

  @override
  String get settingsCoverRadiusSharp => '직사각형（정보 밀도 높음）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return '${radius}px 둥글게';
  }

  @override
  String get settingsCoverRadiusSharpLabel => '직사각형';

  @override
  String get settingsCoverRadiusRoundedLabel => '둥글게';

  @override
  String get settingsCoverRadiusLargeLabel => '크게 둥글게';

  @override
  String get settingsPickerTitle => '커스텀 강조 색상';

  @override
  String get settingsPickerHexLabel => '색상 값（#RRGGBB）';

  @override
  String get settingsApply => '적용';

  @override
  String get settingsSectionAudio => '오디오';

  @override
  String get settingsPassthrough => '원음질 패스스루（트랜스코딩 안함）';

  @override
  String get settingsPassthroughOn => '소스 샘플레이트 유지（Hi-Res/무손실 품질 저하 없음）';

  @override
  String get settingsPassthroughOff => '통합 48kHz 트랜스코딩 파이프라인';

  @override
  String get settingsPassthroughNote =>
      '패스스루 ON 시 소스 샘플레이트 유지；OFF 시 48kHz로 리샘플링. 현재 곡 리로드 후 적용.';

  @override
  String get volumeMute => '음소거';

  @override
  String get volumeUnmute => '음소거 해제';

  @override
  String get settingsSectionMemory => '메모리 및 시작';

  @override
  String get settingsSessionMemory => '세션 메모리';

  @override
  String get settingsSessionMemoryOn => '종료 전 큐, 위치, 모드를 기억하고 다음 시작시 복원';

  @override
  String get settingsSessionMemoryOff => '세션 기억 안함（다음 시작시 비어있음）';

  @override
  String get settingsAutoPlay => '시작시 자동 재생';

  @override
  String get settingsAutoPlayNeedMemory => '먼저「세션 메모리」를 활성화하세요';

  @override
  String get settingsAutoPlayOn => '이전 세션을 복원하고 자동 재생';

  @override
  String get settingsAutoPlayOff => '세션만 복원（재생 중이었어도 일시 정지 상태 유지）';

  @override
  String get settingsSectionSpectrum => '스펙트럼';

  @override
  String get settingsSpectrum => '스펙트럼 비주얼라이저';

  @override
  String get settingsSpectrumOn => '플레이어에 스펙트럼 바 표시（재생시 0.65 / 일시정지 0.15 투명도）';

  @override
  String get settingsSpectrumOff => '플레이어에 스펙트럼 표시 안함';

  @override
  String get settingsSpectrumBarWidth => '스펙트럼 바 너비';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12, 전체화면 플레이어만）';
  }

  @override
  String get settingsBarSpectrum => '플레이바 스펙트럼';

  @override
  String get settingsBarSpectrumOn => '시간 아래에 미니 스펙트럼 표시（가사 없음 또는 미니 가사 끔 시）';

  @override
  String get settingsBarSpectrumOff => '플레이바에 미니 스펙트럼 표시 안 함';

  @override
  String get settingsCoverBeatScale => '커버 리듬에 맞춰 확대';

  @override
  String get settingsCoverBeatScaleOn => '커버가 박자에 맞춰 미세하게 펄스';

  @override
  String get settingsCoverBeatScaleOff => '커버 고정（재생/일시정지 확대만）';

  @override
  String get settingsTransitionStyle => '미디어 정보 전환';

  @override
  String get settingsTransitionStyleDesc => '곡 전환 시 앨범 커버와 곡 정보의 전환 애니메이션';

  @override
  String get settingsTransitionStyleScale => '스케일';

  @override
  String get settingsTransitionStyleSlide => '슬라이드';

  @override
  String get settingsSectionShortcuts => '단축키';

  @override
  String get settingsShortcutSpace => '스페이스';

  @override
  String get settingsShortcutSpaceDesc => '재생 / 일시 정지';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => '10초 뒤로 / 10초 앞으로';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => '음악 라이브러리';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc => '뒤로（대화상자 닫기 / 전체화면 플레이어 종료）';

  @override
  String get settingsSectionPlayerLyrics => '플레이어 가사';

  @override
  String get settingsPlayerLyrics => '플레이어 내 가사';

  @override
  String get settingsPlayerLyricsOn =>
      '전체화면 플레이어 오른쪽에 가사 패널（현재 줄 하이라이트 + 클릭으로 이동）';

  @override
  String get settingsPlayerLyricsOff => '전체화면 플레이어에 가사 영역 없음';

  @override
  String get settingsBarLyrics => '플레이바 가사';

  @override
  String get settingsBarLyricsOn => '시간 아래에 현재 가사 표시（길면 자동 스크롤）';

  @override
  String get settingsBarLyricsOff => '플레이바에 미니 가사 표시 안 함';

  @override
  String get settingsShowTranslation => '번역 표시';

  @override
  String get settingsShowTranslationOn => '원문 뒤 괄호 안에 번역 표시';

  @override
  String get settingsShowTranslationOff => '가사 번역 표시 안 함';

  @override
  String get settingsSectionLyricStyle => '가사 스타일';

  @override
  String get settingsLyricFontSize => '가사 글꼴 크기';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（현재 줄은 +3px로 확대 하이라이트）';
  }

  @override
  String get settingsLyricLineHeight => '가사 줄 높이';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（간격 포함）';
  }

  @override
  String get settingsLyricPlayedColor => '재생된 색상';

  @override
  String get settingsLyricPlayedColorDesc => '현재 가사 줄 하이라이트 색상';

  @override
  String get settingsLyricUnplayedColor => '재생 전 색상';

  @override
  String get settingsLyricUnplayedColorDesc => '다음 가사 줄 색상';

  @override
  String get settingsLyricsNote => '전체화면 플레이어 가사에만 적용；가사 통합（Phase 2）후 바로 적용.';

  @override
  String get settingsSectionFilter => '재생 필터';

  @override
  String get settingsDjMode => 'Fuck DJ Mode';

  @override
  String get settingsDjModeOn => 'DJ 리믹스 등 저품질 트랙 자동 건너뛰기';

  @override
  String get settingsDjModeOff => 'DJ 버전 감지시 자동으로 다음 곡으로 건너뛰기';

  @override
  String get settingsSectionLyricsFilter => '가사';

  @override
  String get settingsUncensor => '비속어 잠금 해제';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => '목록 표시';

  @override
  String get settingsHideVip => 'VIP 태그 숨기기';

  @override
  String get settingsHideVipOn => '곡 목록에 VIP / 유료 배지 표시 안함';

  @override
  String get settingsHideVipOff => '기본으로 유료 티어 배지 표시（VIP / EP）';

  @override
  String get settingsHideQuality => '음질 태그 숨기기';

  @override
  String get settingsHideQualityOn => '곡 목록에 음질 배지 표시 안함';

  @override
  String get settingsHideQualityOff => '기본으로 최고 음질 표시（Hi-Res / 무손실 / HQ…）';

  @override
  String get settingsShowSubtitle => '부제목 표시';

  @override
  String get settingsShowSubtitleOn => '곡명 뒤에 별칭 표시, 예: (Live) / (Remix)';

  @override
  String get settingsShowSubtitleOff => '목록에 아티스트만 표시, 별칭 없음';

  @override
  String get settingsPerformanceMode => '성능 모드';

  @override
  String get settingsPerformanceModeOn => '현재 동결 모드';

  @override
  String get settingsPerformanceModeOff => '현재 애니메이션 모드';

  @override
  String get settingsSectionDir => '디렉토리';

  @override
  String get settingsDownloadRootHint => '다운로드 폴더（Enter로 저장）';

  @override
  String get settingsRestoreDefault => '기본값으로 복원';

  @override
  String get settingsDownloadRootNote =>
      '기본은 미디어 라이브러리 폴더를 따름；폴더 변경 시 진행 중 다운로드 종료. Enter로 저장.';

  @override
  String get settingsSectionFilename => '파일명';

  @override
  String get settingsDownloadTemplateHint => '파일명 템플릿（Enter로 저장）';

  @override
  String get settingsDownloadTemplateNote =>
      '플레이스홀더: <artist> · <title> · <album>. 이후 큐에 추가된 작업에만 적용；Enter로 저장.';

  @override
  String get settingsSectionQuality => '음질';

  @override
  String get settingsDownloadQuality => '기본 다운로드 음질';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return '「다운로드」대화상자 기본값 $quality；해당 음질이 없으면 자동 다운그레이드';
  }

  @override
  String get settingsDownloadQualityNote =>
      '높은 순서: Hi-Res → 무손실 → HQ → SQ → LQ；해당 음질이 없으면 자동 다운그레이드.';

  @override
  String get settingsSectionConcurrent => '동시 실행';

  @override
  String get settingsDownloadConcurrent => '동시 다운로드 수';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count개 병렬 작업（1~5）';
  }

  @override
  String get settingsDownloadGrouping => '폴더 그룹화';

  @override
  String get settingsGroupingFlat => '모두 다운로드 폴더에 플랫하게 배치';

  @override
  String get settingsGroupingPlatform => '플랫폼별 하위 폴더（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => '아티스트별 하위 폴더';

  @override
  String get settingsGroupingFlatLabel => '플랫';

  @override
  String get settingsGroupingPlatformLabel => '플랫폼별';

  @override
  String get settingsGroupingArtistLabel => '아티스트별';

  @override
  String get settingsSectionSpeedLimit => '속도 제한';

  @override
  String get settingsDownloadSpeedLimit => '다운로드 속도 제한';

  @override
  String get settingsSpeedUnlimited => '무제한（기본）';

  @override
  String settingsSpeedLimited(Object speed) {
    return '$speed(으)로 제한, 즉시 적용';
  }

  @override
  String get settingsSpeedUnlimitedLabel => '무제한';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote =>
      '실시간 적용, 진행 중 작업 중단 안 함（0.5 MB/s 단위, 0 = 무제한）.';

  @override
  String get settingsSectionHistory => '기록';

  @override
  String get settingsDownloadHistoryLimit => '다운로드 기록 상한';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count개 항목（10~500）· 실패/취소가 상한 초과시 오래된 것부터 자동 삭제';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count개 항목';
  }

  @override
  String get settingsDownloadHistoryNote =>
      '실패/취소 기록만 상한 초과 시 오래된 순으로 삭제；진행 중 작업은 영향 없음.';

  @override
  String get settingsGroupingNote => '아티스트별 그룹화 v2 지원（플랫 / 플랫폼별 / 아티스트별）.';

  @override
  String get toastDownloadRootEmpty => '다운로드 폴더는 비워둘 수 없습니다';

  @override
  String get toastDownloadRootUpdated => '다운로드 폴더가 업데이트되었습니다';

  @override
  String get toastTemplateEmpty => '파일명 템플릿은 비워둘 수 없습니다';

  @override
  String get toastTemplateUpdated => '파일명 템플릿이 업데이트되었습니다';

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
  String get settingsSectionFileLocation => '파일 위치';

  @override
  String get settingsDataDir => '데이터 디렉토리';

  @override
  String get settingsLibraryDb => '미디어 라이브러리 데이터베이스';

  @override
  String get settingsUserDb => '사용자 데이터베이스（암호화）';

  @override
  String get settingsLibraryDbLabel => '라이브러리 경로';

  @override
  String get settingsUserDbLabel => '사용자 데이터 경로';

  @override
  String get settingsCopy => '복사';

  @override
  String toastCopied(Object label) {
    return '$label 복사됨';
  }

  @override
  String get settingsStorageNote =>
      '미디어 라이브러리와 사용자 데이터는 물리적으로 분리；경로는 ARCHOERA_DATA_DIR로 재정의 가능.';

  @override
  String get settingsSectionCache => '캐시 관리';

  @override
  String get settingsCacheNote =>
      '캐시는 탐색과 재생을 빠르게 합니다. 삭제 후 자동으로 다시 생성되며 라이브러리·기록·계정에는 영향을 주지 않습니다.';

  @override
  String get settingsCacheGroupDisk => '데이터베이스 캐시(디스크)';

  @override
  String get settingsCacheGroupMem => '메모리 캐시(프로세스 내)';

  @override
  String get settingsCacheLiked => '「좋아요」 목록 캐시';

  @override
  String get settingsCacheLyric => '가사 내용 캐시';

  @override
  String get settingsCacheLyricMatch => '가사 매칭 캐시';

  @override
  String get settingsCacheLyricTtml => 'TTML 가사 캐시';

  @override
  String get settingsCacheCover => '커버 이미지 캐시';

  @override
  String settingsCacheEntries(Object count) {
    return '$count개';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count장';
  }

  @override
  String get settingsCacheRefresh => '새로고침';

  @override
  String get settingsCacheClear => '삭제';

  @override
  String get settingsCacheClearAll => '모두 삭제';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '「$name」을(를) 삭제할까요?';
  }

  @override
  String get settingsCacheClearConfirmDesc =>
      '이 캐시의 모든 데이터가 삭제됩니다. 다음 사용 시 자동으로 다시 생성되며 되돌릴 수 없습니다.';

  @override
  String get settingsCacheClearAllConfirmTitle => '모든 캐시를 삭제할까요?';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      '위의 모든 캐시(메모리·디스크)가 삭제됩니다. 라이브러리·기록·계정에는 영향을 주지 않습니다.';

  @override
  String toastCacheCleared(Object name) {
    return '$name 캐시가 삭제되었습니다';
  }

  @override
  String get toastCacheAllCleared => '모든 캐시가 삭제되었습니다';

  @override
  String get settingsSecuritySection => '안전 파기';

  @override
  String get settingsSecurityNote =>
      '기기의 모든 계정 자격 증명과 로그인 세션(스트리밍 서버 비밀번호, Netease/Kugou 로그인 상태, 로컬 Subsonic 계정)을 되돌릴 수 없게 삭제하고 플랫폼 토큰을 무효화합니다. 라이브러리·기록·다운로드 파일에는 영향을 주지 않습니다.';

  @override
  String get settingsSecurityStreaming => '스트리밍 서버 자격 증명';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '서버 $count대';
  }

  @override
  String get settingsSecurityStreamingDesc => '비밀번호 및 액세스 토큰';

  @override
  String get settingsSecuritySession => '타사 계정 세션';

  @override
  String get settingsSecuritySessionDesc => 'Netease / Kugou 로그인 상태';

  @override
  String get settingsSecurityUserDb => '로컬 사용자 데이터베이스';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic 계정 및 즐겨찾기 데이터';

  @override
  String get settingsSecurityLoggedIn => '로그인됨';

  @override
  String get settingsSecurityDestroy => '파기';

  @override
  String get settingsSecurityDestroyAll => '모두 파기';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '「$name」을(를) 파기하시겠습니까?';
  }

  @override
  String get settingsSecurityConfirmAllTitle => '모든 민감한 데이터를 파기하시겠습니까?';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return '관련 플랫폼 토큰을 무효화하고 파일을 덮어쓴 후 삭제합니다. 이 작업은 되돌릴 수 없습니다. 계속하려면 「$word」를 입력하세요.';
  }

  @override
  String get settingsSecurityConfirmWord => '파기';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return '「$word」 입력';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return '파기됨: $name';
  }

  @override
  String get toastSecurityAllDestroyed => '모든 민감한 데이터가 파기되었습니다';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return '파기에 실패했습니다. 파일이 남아 있을 수 있습니다: $path';
  }

  @override
  String get settingsVersion => '버전';

  @override
  String get settingsVersionUnknown => 'v 알 수 없음 · Flutter 데스크톱';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter 데스크톱';
  }

  @override
  String get settingsAudioEngine => '오디오 엔진';

  @override
  String get settingsAudioEngineDesc => '내장 C 엔진（miniaudio）· 네이티브 트랜스코딩/스캔 FFI';

  @override
  String get settingsSubsonicServer => 'Subsonic 서버';

  @override
  String get settingsSubsonicDesc => 'Go FFI（내장）· 자체 호스팅 음악 라이브러리';

  @override
  String get settingsAboutDesc =>
      '자체 개발 플레이어: 로컬 라이브러리 스캔, 음악 소스 직결, 자체 호스팅 Subsonic, 네이티브 오디오 엔진.';

  @override
  String get settingsSectionDeclaration => '소프트웨어 고지';

  @override
  String get settingsDeclineText =>
      '이 소프트웨어（ArchoeraMusic）는 개인 학습 및 연구 목적의 무료 오픈소스 데스크톱 음악 플레이어입니다.\n\n';

  @override
  String get settingsDecline1Title => '1. 소프트웨어 성격\n';

  @override
  String get settingsDecline1Body =>
      '이 소프트웨어는 서드파티 클라이언트로, 각 음악 플랫폼 및 공식 클라이언트와 어떠한 관련, 협력 또는 권한 관계가 없습니다.\n\n';

  @override
  String get settingsDecline2Title => '2. 콘텐츠 출처 및 저작권\n';

  @override
  String get settingsDecline2Body =>
      '이 소프트웨어 자체는 음악 콘텐츠를 제공, 저장, 배포하지 않습니다. 저작권은 원저작권자 및 플랫폼에 귀속됩니다.\n\n';

  @override
  String get settingsDecline3Title => '3. 저작권 데이터 처리 의무\n';

  @override
  String get settingsDecline3Body =>
      '저작권 데이터는 개인 시청 및 학습 연구 목적으로만 사용되며, 상업적 또는 공개 배포에 사용되지 않습니다.\n\n';

  @override
  String get settingsDecline4Title => '4. 사용 제한\n';

  @override
  String get settingsDecline4Body =>
      '상업적 활동, 대량 스크래핑, 크롤링, 재판매에 사용하지 마십시오; 법률 또는 이용약관을 위반하는 방법으로 사용하지 마십시오.\n\n';

  @override
  String get settingsDecline5Title => '5. 면책 조항\n';

  @override
  String get settingsDecline5Body =>
      '이 소프트웨어는「현상태 그대로」제공되며, 명시적 또는 묵시적 보증을 하지 않습니다.\n\n';

  @override
  String get settingsDeclineFooter => '이 소프트웨어는 기술적 탐구와 연구만을 목적으로 합니다.';

  @override
  String get settingsSectionFontCredits => '글꼴 저작권 고지';

  @override
  String get settingsFontCreditsText =>
      '이 소프트웨어에는 다음 글꼴이 포함되어 있습니다.\n· Noto Sans CJK SC (SIL Open Font License 1.1)\n· MiSans (© Xiaomi, MiSans 글꼴 지식재산권 허락 계약에 따라 사용)\n· HarmonyOS Sans SC (© Huawei, HarmonyOS Sans 글꼴 허락 계약에 따라 사용)';

  @override
  String get commonNoLyrics => '가사 없음';

  @override
  String commonTrackCount(Object count) {
    return '$count곡';
  }

  @override
  String get settingsSearchColorTitle => '재생됨 / 재생 전 색상';

  @override
  String get settingsSearchColorSubtitle => '현재 줄 하이라이트 및 일반 줄 색상';

  @override
  String get settingsSearchDesktopLyricsTitle => '데스크톱 가사';

  @override
  String get settingsSearchDesktopLyricsSubtitle => '항상 위 가사 창 · 재생 추적';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => '파일명 템플릿';

  @override
  String get settingsSearchAccentSubtitle => '사용자 정의 기본 색상 시드 · 팔레트';

  @override
  String get settingsThemeSource => '테마 색상 소스';

  @override
  String get settingsThemeSourceDesc => '기본 색상을 가져오는 방식';

  @override
  String get settingsThemeSourceDefault => '시스템 따르기';

  @override
  String get settingsThemeSourceCustom => '사용자 정의';

  @override
  String get settingsThemeSourceCover => '커버 연동';

  @override
  String get settingsThemeSourceSolid => '없음';

  @override
  String get settingsThemeSourceCustomHint => '시드 색상을 고르면 기본/보조 색상이 동적으로 생성됩니다';

  @override
  String get settingsThemeSourceCoverHint =>
      '현재 재생 중인 커버에서 대표 색상을 실시간 추출 (불가 시 기본 색상으로 대체)';

  @override
  String get settingsGlobalTint => '글로벌 틴트';

  @override
  String get settingsGlobalTintDesc => '테마 색상을 인터페이스 전체에 은은하게 적용';

  @override
  String get settingsGlobalTintNote =>
      '테마 색상(사용자 정의/커버 연동)이 있을 때 적용됩니다. 이미지 배경 모드에서는 강제로 켜집니다.';

  @override
  String get settingsSectionStyle => '배경 스타일';

  @override
  String get settingsAppearanceStyle => '외관 스타일';

  @override
  String get settingsAppearanceStyleDesc => '메인 배경의 표시 방식';

  @override
  String get settingsAppearanceStyleSolid => '단색 배경';

  @override
  String get settingsAppearanceStyleImage => '이미지';

  @override
  String get settingsBackgroundImage => '배경 이미지';

  @override
  String get settingsBackgroundImageDesc =>
      '로컬 이미지를 앱 배경으로 선택 (이미지 모드는 다크 + 글로벌 틴트 강제)';

  @override
  String get settingsBackgroundPick => '이미지 선택';

  @override
  String get settingsBackgroundReplace => '변경';

  @override
  String get settingsBackgroundClear => '지우기';

  @override
  String get settingsBackgroundBlur => '배경 흐림';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return '배경 이미지에 가우시안 블러 적용 (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => '마스크 강도';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return '검은 오버레이 불투명도 ($dim%) — 높을수록 전경이 잘 보임';
  }

  @override
  String get settingsBackgroundScale => '확대 배율';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return '배경 이미지의 확대 배율 (${scale}x)';
  }

  @override
  String get settingsSidebarCollapsed => '사이드바 접기';

  @override
  String get settingsSidebarCollapsedDesc => '사이드바를 아이콘만 표시하는 모드로 접기';

  @override
  String get settingsSidebarNavStyle => '내비게이션 하이라이트 애니메이션';

  @override
  String get settingsSidebarNavStyleDesc => '활성 내비게이션 하이라이트 표시기의 애니메이션 스타일';

  @override
  String get settingsSidebarNavStyleDefault => '정적';

  @override
  String get settingsSidebarNavStyleAnimated => '슬라이드';

  @override
  String get settingsRouteTransition => '페이지 전환 애니메이션';

  @override
  String get settingsRouteTransitionDesc => '페이지 전환 시의 전환 애니메이션 효과';

  @override
  String get settingsRouteTransitionNone => '없음';

  @override
  String get settingsRouteTransitionFade => '페이드';

  @override
  String get settingsRouteTransitionSlide => '슬라이드';

  @override
  String get settingsRouteTransitionZoom => '확대';

  @override
  String get settingsSearchThemeSourceSubtitle => '기본 테마 · 사용자 정의 · 커버 연동 · 없음';

  @override
  String get settingsSearchGlobalTintSubtitle => '테마 색상을 인터페이스 전체에 적용';

  @override
  String get settingsSearchBackgroundSubtitle => '단색 / 이미지 · 블러 · 마스크 · 배율';

  @override
  String get settingsSearchSidebarSubtitle => '사이드바 접기 · 정적 / 슬라이드 하이라이트';

  @override
  String get settingsSearchRouteTransitionSubtitle => '없음 · 페이드 · 슬라이드 · 확대';

  @override
  String get settingsSearchFloatingBarSubtitle => '하단 플로팅 캡슐 · 전체 너비 도킹';

  @override
  String get settingsSearchFontSubtitle =>
      'MiSans · Noto Sans · HarmonyOS Sans';

  @override
  String get settingsSearchLanguageSubtitle => '시스템 따르기 · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle => '직사각형 · 둥글게 · 크게 둥글게';

  @override
  String get settingsSectionWeather => '날씨';

  @override
  String get settingsWeather => '날씨 위젯';

  @override
  String get settingsWeatherDesc => '아바타 왼쪽에 미니 날씨(아이콘+기온) 표시';

  @override
  String get settingsWeatherAutoLocate => '자동 위치';

  @override
  String get settingsWeatherAutoLocateDesc =>
      '네트워크 IP로 대략적인 위치 확인(개인정보: 기본 꺼짐)';

  @override
  String get settingsWeatherCity => '수동 도시';

  @override
  String get settingsWeatherCityHint => '입력하면 IP 위치를 사용하지 않음(예: 서울)';

  @override
  String get settingsWeatherNote =>
      '개인정보: 날씨 데이터는 Open-Meteo(무료, 키 불필요). 자동 위치를 켜면 IP가 ip-api.com으로 전송되어 대략적인 위치를 얻습니다. 날씨 조회에만 사용하며 저장하지 않습니다. 위젯과 위치는 기본 꺼짐입니다.';

  @override
  String get settingsSearchWeatherSubtitle => '상단 바의 미니 날씨 위젯(아이콘+기온)';

  @override
  String get weatherRefresh => '날씨 새로고침';

  @override
  String get weatherNoLocation => '설정에서 도시를 입력하거나 자동 위치를 켜세요';

  @override
  String get weatherUnavailable => '날씨를 불러오지 못했습니다. 탭하여 다시 시도';

  @override
  String get settingsSearchPassthroughSubtitle => '트랜스코딩 안함 · 48kHz 파이프라인';

  @override
  String get settingsSearchSessionMemorySubtitle => '재생 세션 기억/복원 토글';

  @override
  String get settingsSearchAutoPlaySubtitle => '세션 복원시 자동 재생 토글';

  @override
  String get settingsSearchSpectrumSubtitle => '플레이어 스펙트럼 토글 · 투명도';

  @override
  String get settingsSearchSpectrumWidthSubtitle => '1~12px 바 너비';

  @override
  String get settingsSearchPlayerLyricsSubtitle => '전체화면 플레이어 가사 표시';

  @override
  String get settingsSearchLyricFontSizeSubtitle => '14~28px 플레이어 가사 글꼴 크기';

  @override
  String get settingsSearchLyricLineHeightSubtitle => '42~64px 줄 높이';

  @override
  String get settingsSearchUncensorSubtitle => '가사의 f**k 등 가려진 단어 복원';

  @override
  String get settingsSearchHideVipSubtitle => '곡 목록의 VIP/유료 배지 숨기기';

  @override
  String get settingsSearchHideQualitySubtitle => '곡 목록의 음질 배지 숨기기';

  @override
  String get settingsSearchSubtitleSubtitle => '곡 목록에 별칭 표시（예: (Live)）';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      '다운로드 파일 위치（기본 ~/Music/ArchoeraMusic）';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> 플레이스홀더 설정 가능';

  @override
  String get settingsSearchConcurrentSubtitle => '1~5개 병렬 다운로드 작업';

  @override
  String get settingsSearchSpeedLimitSubtitle => '무제한 · 0.5~20 MB/s 즉시 적용';

  @override
  String get settingsSearchQualitySubtitle => 'Hi-Res · 무손실 · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle => '플랫 · 플랫폼별 · 아티스트별';

  @override
  String get settingsSearchHistoryLimitSubtitle =>
      '실패/취소 기록이 한도 초과시 오래된 것부터 자동 삭제（10~500）';

  @override
  String get settingsSearchStorageSubtitle => '미디어 라이브러리 · 사용자 DB 경로';

  @override
  String get settingsSearchAboutSubtitle => '오디오 엔진 · Subsonic 서버';

  @override
  String get qualityLossless => '무손실';

  @override
  String get repeatModeList => '목록 반복';

  @override
  String get repeatModeOne => '한 곡 반복';

  @override
  String get commonUnknownTrack => '알 수 없는 트랙';

  @override
  String get commonAnonymousUser => '익명 사용자';

  @override
  String get commonCanceled => '취소됨';

  @override
  String get commonILike => '내가 좋아하는';

  @override
  String get sidebarStreaming => '스트리밍';

  @override
  String get settingsCatMediaSource => '미디어 소스';

  @override
  String get settingsMediaSourceSubtitle =>
      '스트리밍 서버 (Subsonic / Jellyfin / Emby)';

  @override
  String get settingsCatScrape => '스크레이핑';

  @override
  String get settingsScrapeSubtitle => '다중 소스 메타데이터 보완 · 표지 / 가사 / 태그';

  @override
  String get settingsSectionScrapeDirs => '스크레이프 대상 디렉터리';

  @override
  String get settingsScrapeDirsHint => '한 줄에 하나의 디렉터리. 비워 두면 라이브러리 스캔 경로를 따름';

  @override
  String get settingsScrapeDirsEmptyNote =>
      '스크레이프 경로가 설정되지 않아 라이브러리 스캔 경로를 사용합니다.';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return '현재 적용 경로: $dirs';
  }

  @override
  String get settingsSectionScrapeSources => '데이터 소스';

  @override
  String get settingsScrapeSourceMusicBrainz => 'MusicBrainz';

  @override
  String get settingsScrapeSourceDeezer => 'Deezer';

  @override
  String get settingsScrapeSourceItunes => 'iTunes';

  @override
  String get settingsScrapeSourceNetease => 'Netease Cloud Music';

  @override
  String get settingsScrapeSourceQQMusic => 'QQ 뮤직';

  @override
  String get settingsScrapeSourceKugou => '쿠거우 뮤직';

  @override
  String get settingsScrapeSourceKuwo => '쿠워 뮤직';

  @override
  String get settingsScrapeSourceMigu => '미구 뮤직';

  @override
  String get settingsScrapeSourceAcoustID => 'AcoustID(오디오 지문)';

  @override
  String get settingsScrapeSourceDesc => '켜면 다중 소스 조회, 유사도 비교 및 점수 병합에 참여합니다';

  @override
  String get settingsSectionScrapeProgress => '스크레이프 진행';

  @override
  String get settingsScrapeStart => '스크레이프 시작';

  @override
  String get settingsScrapeCancel => '스크레이프 취소';

  @override
  String get settingsScrapeScanning => '디렉터리 스캔 중…';

  @override
  String settingsScrapeCurrent(Object file) {
    return '처리 중: $file';
  }

  @override
  String get settingsScrapeSuccess => '성공';

  @override
  String get settingsScrapeFailed => '실패';

  @override
  String get settingsScrapeSkipped => '건너뜀';

  @override
  String get settingsScrapeNotFound => '불일치';

  @override
  String get settingsScrapeIdle => '아직 실행되지 않았습니다. 아래 버튼으로 시작하세요.';

  @override
  String get settingsScrapeNoDirs =>
      '스크레이프할 디렉터리가 없습니다. 스크레이프 경로 또는 라이브러리 스캔 경로를 먼저 설정하세요.';

  @override
  String get settingsScrapeDone => '스크레이프 완료';

  @override
  String get settingsScrapeCanceled => '스크레이프 취소됨';

  @override
  String get toastScrapeNoDirs => '스크레이프할 디렉터리가 없습니다';

  @override
  String get toastScrapeDirsUpdated => '스크레이프 경로가 저장되었습니다';

  @override
  String get toastScrapeStarted => '스크레이프를 시작했습니다';

  @override
  String get commonDelete => '삭제';

  @override
  String get commonSave => '저장';

  @override
  String get commonConfirm => '확인';

  @override
  String get streamingHint => '미디어 소스';

  @override
  String get streamingHintDetail =>
      '스트리밍 서버를 추가하여 서버의 음악을 탐색하고 재생합니다 (Subsonic 계열 / Jellyfin / Emby, 내장 로컬 Subsonic 서버 포함).';

  @override
  String get streamingServerAdd => '서버 추가';

  @override
  String get streamingEmptyNoServer => '아직 스트리밍 서버가 없습니다';

  @override
  String get streamingEmptyAddHint => '위 버튼을 눌러 서버를 추가하세요';

  @override
  String get streamingServerConnected => '연결됨';

  @override
  String get streamingServerDisconnected => '연결 안 됨';

  @override
  String get streamingServerLastConnected => '마지막 연결';

  @override
  String get streamingServerDisconnect => '연결 끊기';

  @override
  String get streamingToastDisconnected => '서버 연결이 끊겼습니다';

  @override
  String get streamingServerConnect => '연결';

  @override
  String streamingToastConnected(Object name) {
    return '$name에 연결됨';
  }

  @override
  String get streamingServerConnectFailed => '연결 실패';

  @override
  String get streamingServerEdit => '편집';

  @override
  String get streamingServerDeleteConfirmTitle => '서버 삭제';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return '서버 \"$name\"을(를) 삭제하시겠습니까?';
  }

  @override
  String get streamingServerRemoved => '서버가 삭제되었습니다';

  @override
  String get streamingServerErrorNameEmpty => '서버 이름을 입력하세요';

  @override
  String get streamingServerErrorHostEmpty => '서버 주소를 입력하세요';

  @override
  String get streamingServerErrorPortInvalid => '포트가 잘못되었습니다 (1~65535)';

  @override
  String get streamingServerErrorUsernameEmpty => '사용자 이름을 입력하세요';

  @override
  String get streamingServerErrorPasswordEmpty => '비밀번호를 입력하세요';

  @override
  String get streamingServerAdded => '서버가 추가되었습니다';

  @override
  String get streamingServerUpdated => '서버가 업데이트되었습니다';

  @override
  String get streamingServerType => '유형';

  @override
  String get streamingServerName => '이름';

  @override
  String get streamingServerNamePlaceholder => '예: 내 Navidrome';

  @override
  String get streamingServerHost => '서버 주소';

  @override
  String get streamingServerHostPlaceholder => '예: 192.168.1.10:4533';

  @override
  String get streamingServerPort => '포트';

  @override
  String get streamingServerPortNote =>
      '기본 포트: 4533 (Subsonic) / 8096 (Jellyfin). 비우면 자동 감지합니다.';

  @override
  String get streamingServerLocalTitle => '내장 로컬 서버';

  @override
  String get streamingServerLocalDesc => '내장 Subsonic 서버 사용 (로컬 라이브러리)';

  @override
  String get streamingServerUsername => '사용자 이름';

  @override
  String get streamingServerPassword => '비밀번호';

  @override
  String get streamingServerTestOk => '연결 성공';

  @override
  String get streamingServerTestFail => '연결 실패';

  @override
  String get streamingServerTest => '연결 테스트';

  @override
  String get streamingTabsSongs => '노래';

  @override
  String get streamingTabsAlbums => '앨범';

  @override
  String get streamingTabsArtists => '아티스트';

  @override
  String get streamingTabsPlaylists => '플레이리스트';

  @override
  String get streamingEmptyGoToSettings => '설정으로';

  @override
  String get streamingEmptyNotConnected => '연결된 서버가 없습니다';

  @override
  String streamingTotalSongs(Object count) {
    return '노래 $count곡';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '앨범 $count장';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '아티스트 $count명';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '플레이리스트 $count개';
  }

  @override
  String get streamingEmptyNoResults => '일치하는 결과가 없습니다';

  @override
  String streamingAlbumSongs(Object count) {
    return '노래 $count곡';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '앨범 $count장';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '노래 $count곡';
  }
}
