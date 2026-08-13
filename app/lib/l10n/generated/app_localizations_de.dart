// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get menuTrackDetail => 'Mediadetails';

  @override
  String get trackDetailDuration => 'Dauer';

  @override
  String get trackDetailArtist => 'Interpret';

  @override
  String get trackDetailAlbum => 'Album';

  @override
  String get trackDetailSource => 'Quelle';

  @override
  String get trackDetailPath => 'Pfad';

  @override
  String get trackDetailFileSize => 'Dateigröße';

  @override
  String get trackDetailCodec => 'Codec';

  @override
  String get trackDetailSampleRate => 'Abtastrate';

  @override
  String get trackDetailBitDepth => 'Bittiefe';

  @override
  String get trackDetailBitrate => 'Bitrate';

  @override
  String get trackDetailChannels => 'Kanäle';

  @override
  String get trackSourceLocal => 'Lokale Datei';

  @override
  String get trackSourceStreaming => 'Streaming';

  @override
  String get trackDetailQuality => 'Qualität';

  @override
  String get batchSelectAll => 'Alle auswählen';

  @override
  String get batchInvert => 'Auswahl umkehren';

  @override
  String get batchPlay => 'Auswahl abspielen';

  @override
  String get batchAddQueue => 'Zur Warteschlange hinzufügen';

  @override
  String get batchDownload => 'Massen-Download';

  @override
  String get batchExit => 'Mehrfachauswahl beenden';

  @override
  String get batchSelectHint => 'Mehrfachauswahl';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '$count Titel zur Warteschlange hinzugefügt';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '$count Titel zur Download-Warteschlange hinzugefügt';
  }

  @override
  String get settingsBarEnhancedLyrics => 'Erweiterte Leiste-Lyrics';

  @override
  String get settingsBarEnhancedLyricsOn =>
      'Karaoke-Hervorhebung anzeigen, wenn wortgenaue Lyrics verfügbar sind';

  @override
  String get settingsBarEnhancedLyricsOff =>
      'Immer einfache Lyrics in der Leiste anzeigen';

  @override
  String get settingsSectionClose => 'App schließen';

  @override
  String get settingsSectionPower => 'Energiesparen';

  @override
  String get settingsPowerSaver => 'Energiesparmodus';

  @override
  String get settingsPowerSaverOn =>
      'Rendering im Hintergrund drosseln (5 FPS minimiert, 1 FPS bei Fokusverlust oder ausgeschaltetem Bildschirm)';

  @override
  String get settingsPowerSaverOff => 'Immer mit voller Bildrate rendern';

  @override
  String get settingsSuppressSleep => 'Systemschlaf verhindern';

  @override
  String get settingsSuppressSleepOn =>
      'System während der Wiedergabe wach halten, damit die Hintergrundwiedergabe nicht unterbrochen wird';

  @override
  String get settingsSuppressSleepOff =>
      'System kann je nach Leerlaufplan schlafen';

  @override
  String get settingsPowerSaverNote =>
      'Der Energiesparmodus senkt die Bildrate über Fensterzustandsereignisse (kein Polling). Bei ausgeblendetem Fenster oder ausgeschaltetem Display stoppt die Engine das Rendering bereits. „Systemschlaf verhindern“ gilt nur während der Wiedergabe.';

  @override
  String get settingsCloseBehavior => 'Beim Schließen der App';

  @override
  String get settingsCloseBehaviorAsk => 'Jedes Mal fragen';

  @override
  String get settingsCloseBehaviorBackground => 'Im Hintergrund abspielen';

  @override
  String get settingsCloseBehaviorQuit => 'Direkt beenden';

  @override
  String get commonCloseConfirmTitle => 'App beenden';

  @override
  String get commonCloseConfirmMessage =>
      'Nach dem Schließen des Hauptfensters';

  @override
  String get commonCloseConfirmRemember =>
      'Meine Auswahl merken und nicht erneut fragen';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => 'Netease Music';

  @override
  String get brandKugou => 'Kugou Music';

  @override
  String get commonBack => 'Zurück';

  @override
  String get commonCancel => 'Abbrechen';

  @override
  String get commonClose => 'Schließen';

  @override
  String get commonDefault => 'Standard';

  @override
  String get commonGoLogin => 'Anmelden';

  @override
  String get commonLike => 'Gefällt mir';

  @override
  String get commonLoading => 'Wird geladen';

  @override
  String get commonLossless => 'Verlustfrei';

  @override
  String get commonOriginal => 'Original';

  @override
  String get commonMore => 'Mehr';

  @override
  String get commonNext => 'Nächstes';

  @override
  String get commonNoMore => 'Nichts mehr';

  @override
  String get commonPrevious => 'Vorheriges';

  @override
  String get commonSettings => 'Einstellungen';

  @override
  String get commonUnknownAlbum => 'Unbekanntes Album';

  @override
  String get commonUnknownArtist => 'Unbekannter Künstler';

  @override
  String get commonUnlike => 'Gefällt mir nicht mehr';

  @override
  String get downloadQualityTitle => 'Download-Qualität';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return 'Um Download-Links von $platform zu erhalten, ist eine Anmeldung erforderlich. Ohne Anmeldung nur Vorschau, keine volle Qualität.\n\nBitte melden Sie sich in Ihrem $platform-Konto an und versuchen Sie es erneut.';
  }

  @override
  String get downloadRequiresLoginTitle =>
      'Anmeldung zum Herunterladen erforderlich';

  @override
  String get menuComment => 'Kommentare anzeigen';

  @override
  String get menuDownload => 'Herunterladen';

  @override
  String get menuLike => 'Zu Favoriten hinzufügen';

  @override
  String get menuPlay => 'Abspielen';

  @override
  String get menuPlayNext => 'Als Nächstes abspielen';

  @override
  String get menuRemoveFromQueue => 'Aus Warteschlange entfernen';

  @override
  String get menuUnlike => 'Aus Favoriten entfernen';

  @override
  String get navHeaderAccount => 'Konto';

  @override
  String get navHeaderComingSoon => 'Bald verfügbar';

  @override
  String navHeaderKugouId(Object id) {
    return 'Kugou $id';
  }

  @override
  String get navHeaderKugouMusic => 'Kugou Music';

  @override
  String get navHeaderLoginAccount => 'Anmelden (Netease / Kugou)';

  @override
  String get navHeaderLogout => 'Abmelden';

  @override
  String get navHeaderNeteaseAccount => 'Netease-Konto';

  @override
  String get navHeaderNeteaseMusic => 'Netease Music';

  @override
  String get navHeaderQqMusic => 'QQ Music';

  @override
  String get navHeaderQrLogin => 'Per QR-Code anmelden';

  @override
  String get navHeaderSearchHint =>
      'Songs / Künstler / Wiedergabelisten suchen';

  @override
  String get navHeaderThemeDark => 'Design: Dunkel';

  @override
  String get navHeaderThemeLight => 'Design: Hell';

  @override
  String get navHeaderThemeSystem => 'Design: System';

  @override
  String get playerBarBuffering => 'Wird geladen…';

  @override
  String get playerBarIdleHint =>
      'Klicken Sie auf die Seitenleiste oder laden Sie eine Quelle, um die Wiedergabe zu starten';

  @override
  String get playerBarOpenPlayer => 'Player öffnen';

  @override
  String get playerBarPlayPause => 'Abspielen/Pause';

  @override
  String get playerBarPlaylist => 'Wiedergabeliste';

  @override
  String get playerBarUntitled => 'Ohne Titel';

  @override
  String get queueClear => 'Warteschlange leeren';

  @override
  String get queueEmpty => 'Warteschlange ist leer';

  @override
  String get queueEmptyHint => 'In der Liste ausgewählte Titel erscheinen hier';

  @override
  String get queueRepeatList => 'Liste wiederholen';

  @override
  String get queueRepeatMode => 'Wiederholungsmodus';

  @override
  String get queueRepeatOne => 'Einen wiederholen';

  @override
  String get queueShuffle => 'Zufallswiedergabe';

  @override
  String get queueShuffleOff => 'Zufallswiedergabe aus';

  @override
  String get queueTitle => 'Wiedergabewarteschlange';

  @override
  String queueTrackCount(Object count) {
    return '$count Titel';
  }

  @override
  String get sidebarBackHome => 'Zurück zur Startseite';

  @override
  String get sidebarCollapse => 'Seitenleiste einklappen';

  @override
  String get sidebarDownload => 'Downloads';

  @override
  String get sidebarExpand => 'Seitenleiste ausklappen';

  @override
  String get sidebarFavorites => 'Favoriten';

  @override
  String get sidebarGroupMusic => 'Musik';

  @override
  String get sidebarGroupPersonal => 'Persönlich';

  @override
  String get sidebarHistory => 'Verlauf';

  @override
  String get sidebarHome => 'Start';

  @override
  String get sidebarLibrary => 'Bibliothek';

  @override
  String get sidebarLiked => 'Meine Likes';

  @override
  String get songListAlbum => 'Album';

  @override
  String get songListDuration => 'Dauer';

  @override
  String get songListTitle => 'Titel';

  @override
  String get songListScrollTop => 'Nach oben';

  @override
  String get songListLocatePlaying => 'Wiedergabe finden';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return 'Zur Download-Warteschlange hinzugefügt: $quality';
  }

  @override
  String get toastAddedToQueue => 'Zur Wiedergabewarteschlange hinzugefügt';

  @override
  String get toastDownloadEngineNotReady =>
      'Die Download-Engine ist nicht bereit. Bitte versuchen Sie es später erneut';

  @override
  String get toastLiked => 'Zu Favoriten hinzugefügt';

  @override
  String get toastLoginRequiredKugou =>
      'Vorgang fehlgeschlagen (stellen Sie sicher, dass Sie in Ihrem Kugou-Konto angemeldet sind)';

  @override
  String get toastLoginRequiredNetease =>
      'Vorgang fehlgeschlagen (stellen Sie sicher, dass Sie in Ihrem Netease-Konto angemeldet sind)';

  @override
  String get toastNoQualityInfo =>
      'Keine Qualitätsinformationen; Download nicht möglich';

  @override
  String get toastUnliked => 'Aus Favoriten entfernt';

  @override
  String get commonClear => 'Leeren';

  @override
  String get commonEmptyContent => 'Kein Inhalt';

  @override
  String commonLoadFailed(Object msg) {
    return 'Laden fehlgeschlagen: $msg';
  }

  @override
  String get commonRetry => 'Erneut versuchen';

  @override
  String get commentDuplicate => 'Senden Sie nicht denselben Inhalt zweimal';

  @override
  String get commentEmpty => 'Noch keine Kommentare';

  @override
  String get commentHot => 'Beliebt';

  @override
  String get commentInputEmpty => 'Der Kommentar darf nicht leer sein';

  @override
  String get commentInputHint => 'Sag etwas…';

  @override
  String get commentLatest => 'Neueste';

  @override
  String commentLoginRequired(Object platform) {
    return 'Melden Sie sich in Ihrem $platform-Konto an, um zu kommentieren';
  }

  @override
  String commentNotFound(Object platform) {
    return 'Keine $platform-Kommentare für diesen Titel gefunden';
  }

  @override
  String get commentPublished => 'Kommentar veröffentlicht';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user: $text';
  }

  @override
  String get commentSend => 'Senden';

  @override
  String commentSendFailed(Object msg) {
    return 'Senden fehlgeschlagen: $msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$day.$month. $time';
  }

  @override
  String get commentTitle => 'Kommentare';

  @override
  String get folderAdd => 'Hinzufügen';

  @override
  String get folderBrowse => 'Durchsuchen';

  @override
  String get folderEmpty =>
      'Noch keine Scan-Ordner. Verwenden Sie die Schaltflächen unten, um einen hinzuzufügen';

  @override
  String get folderExists => 'Ordner existiert bereits oder ist ungültig';

  @override
  String get folderInvalid =>
      'Ordner existiert nicht, existiert bereits oder ist leer';

  @override
  String get folderPathHint => 'Absoluten Ordnerpfad eingeben';

  @override
  String get folderRemove => 'Entfernen';

  @override
  String get folderRemoveDescription =>
      'Ordner wird nicht mehr gescannt; bereits katalogisierte Titel bleiben erhalten.';

  @override
  String get folderRemoveTitle => 'Scan-Ordner entfernen';

  @override
  String get loginFetchingQr => 'QR-Code wird abgerufen…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return 'Bei $platform angemeldet';
  }

  @override
  String loginKugouLogin(Object platform) {
    return 'Mit $platform anmelden';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return 'Per QR-Code bei $platform anmelden';
  }

  @override
  String get loginKugouResponseMissingToken =>
      'Anmeldeantwort enthält kein token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return 'Scannen Sie den QR-Code mit der $platform-App';
  }

  @override
  String loginKugouSession(Object platform) {
    return 'Mit $platform angemeldet';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return 'Anmeldung bei $platform erfolgreich, VIP-Titel freigeschaltet';
  }

  @override
  String loginLoggedOut(Object platform) {
    return 'Bei $platform abgemeldet';
  }

  @override
  String loginLogoutWithId(Object id) {
    return 'Abmelden ($id)';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return 'Per QR-Code bei $platform anmelden';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return 'Scannen Sie den QR-Code mit der $platform-App';
  }

  @override
  String get loginQrExpired => 'QR-Code abgelaufen';

  @override
  String get loginQrExpiredRegenerate =>
      'QR-Code abgelaufen, klicken Sie zum Neugenerieren';

  @override
  String get loginQrLogin => 'Per QR-Code anmelden';

  @override
  String get loginRefreshQr => 'QR-Code aktualisieren';

  @override
  String get loginRegenerate => 'Neu generieren';

  @override
  String get loginSuccess => 'Erfolgreich angemeldet';

  @override
  String get loginWaitingConfirm =>
      'Gescannt, bitte bestätigen Sie die Anmeldung auf Ihrem Telefon';

  @override
  String get trackListArtistHotSongs => 'Beliebte Songs des Künstlers';

  @override
  String get trackListArtistSongs => 'Künstler-Titel';

  @override
  String get trackListDailyRecommend => 'Tägliche Empfehlung';

  @override
  String get trackListDailyRecommendSubtitle =>
      'Täglich nach Ihrem Geschmack aktualisiert';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return 'Keine Titel (tägliche Empfehlung erfordert $platform-Anmeldung)';
  }

  @override
  String get trackListNoPlayableSource =>
      'Keine abspielbare Quelle (VIP / Vorschau-Limit)';

  @override
  String get trackListPlayAll => 'Alle abspielen';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return 'Abrufen der Wiedergabequelle fehlgeschlagen: $msg';
  }

  @override
  String get trayNext => 'Weiter';

  @override
  String get trayPlayPause => 'Abspielen / Pause';

  @override
  String get trayPrevious => 'Zurück';

  @override
  String get trayQuit => 'Beenden';

  @override
  String get trayShow => 'Hauptfenster anzeigen';

  @override
  String get commonPlayAll => 'Alle abspielen';

  @override
  String get commonPause => 'Pause';

  @override
  String get commonPlay => 'Wiedergabe';

  @override
  String get commonRefresh => 'Aktualisieren';

  @override
  String get commonSearch => 'Suchen';

  @override
  String get commonSongs => 'Titel';

  @override
  String get commonAlbums => 'Alben';

  @override
  String get commonArtists => 'Künstler';

  @override
  String get commonPlaylists => 'Wiedergabelisten';

  @override
  String get commonDone => 'Fertig';

  @override
  String get commonUnknownError => 'Unbekannter Fehler';

  @override
  String commonSongCountHint(Object count) {
    return 'Insgesamt $count Titel · Zum Abspielen klicken';
  }

  @override
  String get platformNetease => 'NetEase';

  @override
  String get platformKugou => 'Kugou';

  @override
  String get platformAll => 'Alle';

  @override
  String toastPlayedAll(Object count) {
    return '$count Titel abgespielt';
  }

  @override
  String toastPlayFailed(Object msg) {
    return 'Wiedergabefehler: $msg';
  }

  @override
  String get toastMissingLocalPath => 'Lokaler Dateipfad fehlt';

  @override
  String get toastLocateComingSoon => 'Dateimanager öffnen (Phase 2)';

  @override
  String get toastRemovedFromLibrary => 'Aus Bibliothek entfernt';

  @override
  String get toastRemoveFailed => 'Entfernen fehlgeschlagen';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return 'Tagesempfehlungen erfordern $platform-Anmeldung';
  }

  @override
  String get toastPlaylistEmpty => 'Wiedergabeliste enthält keine Titel';

  @override
  String get toastAlbumEmpty => 'Album enthält keine Titel';

  @override
  String get toastPausedAll => 'Alle pausiert';

  @override
  String get toastResumedAll => 'Alle fortgesetzt';

  @override
  String get toastPaused => 'Pausiert';

  @override
  String get toastCanceledTask => 'Abgebrochen und Aufgabe gelöscht';

  @override
  String get toastResumed => 'Download fortgesetzt';

  @override
  String get toastRequeued => 'Erneut zur Warteschlange hinzugefügt';

  @override
  String get toastDeletedSelected => 'Ausgewählte Aufgaben gelöscht';

  @override
  String get toastDeletedSelectedWithMedia =>
      'Aufgaben und Mediendateien gelöscht';

  @override
  String get toastCleared => 'Download-Aufgaben geleert';

  @override
  String get toastClearedWithMedia => 'Aufgaben geleert und Dateien gelöscht';

  @override
  String get toastDeletedTask => 'Aufgabe gelöscht';

  @override
  String get toastDeletedTaskWithMedia => 'Aufgabe und Dateien gelöscht';

  @override
  String get pageHistoryRemoved => 'Aus Verlauf entfernt';

  @override
  String get pageHistoryClearTitle => 'Wiedergabeverlauf leeren';

  @override
  String get pageHistoryClearMessage =>
      'Gesamten Verlauf wirklich leeren? Kann nicht rückgängig gemacht werden.';

  @override
  String get pageHistoryCleared => 'Verlauf geleert';

  @override
  String get pageHistoryRemove => 'Aus Verlauf entfernen';

  @override
  String get pageHistorySubtitleEmpty =>
      'Lokal gespeicherte Wiedergabeverläufe';

  @override
  String get pageHistoryEmpty => 'Noch keine Wiedergabeverläufe';

  @override
  String get pageHistoryEmptyHint =>
      'Abgespielte Titel werden automatisch hier aufgezeichnet';

  @override
  String pageFavPlaylistCount(Object count) {
    return '$count Lieblings-Wiedergabelisten';
  }

  @override
  String get pageFavPlaylistLoginHint => 'Zum Anmelden, um Favoriten anzusehen';

  @override
  String pageFavAlbumCount(Object count) {
    return '$count Lieblingsalben';
  }

  @override
  String get pageFavAlbumLoginHint => 'Zum Anmelden, um Alben anzusehen';

  @override
  String pageFavArtistCount(Object count) {
    return '$count Lieblingskünstler';
  }

  @override
  String get pageFavArtistLoginHint => 'Zum Anmelden, um Künstler anzusehen';

  @override
  String get pageFavLoadFailed => 'Favoriten konnten nicht geladen werden';

  @override
  String get pageFavEmpty => 'Noch keine Favoriten';

  @override
  String get pageFavEmptyHint =>
      'Nach Favorisieren in der NetEase-App automatisch synchronisiert';

  @override
  String get pageFavLoginTitle => 'Anmelden, um Favoriten anzusehen';

  @override
  String get pageFavLoginDesc =>
      'Per QR bei NetEase anmelden, Favoriten synchronisieren';

  @override
  String get pageFavKgCreated => 'Erstellte Wiedergabelisten';

  @override
  String get pageFavKgCollectedPlaylist => 'Gespeicherte Wiedergabelisten';

  @override
  String get pageFavKgCollectedAlbum => 'Gespeicherte Alben';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '$count erstellte Wiedergabelisten';
  }

  @override
  String get pageFavKgCreatedLoginHint =>
      'Melde dich an, um deine erstellten Wiedergabelisten zu sehen';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '$count gespeicherte Wiedergabelisten';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'Melde dich an, um deine gespeicherten Wiedergabelisten zu sehen';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '$count gespeicherte Alben';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint =>
      'Melde dich an, um deine gespeicherten Alben zu sehen';

  @override
  String get pageFavKugouLoginDesc =>
      'Per QR bei Kugou anmelden, um erstellte/gespeicherte Wiedergabelisten und Alben zu synchronisieren';

  @override
  String get pageFavKugouEmptyHint =>
      'Wird automatisch synchronisiert, wenn du in der Kugou-App favorisierst';

  @override
  String pageSearchLoadingTrack(Object title) {
    return 'Lade: $title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — Detailseite folgt';
  }

  @override
  String get menuViewArtist => 'Künstler ansehen';

  @override
  String get pageSearchArtistComingSoon => 'Künstlerseite (Phase 2)';

  @override
  String get pageSearchInputHint => 'Suchbegriff eingeben';

  @override
  String get pageSearchInputSubtitle => 'Titel / Alben / Künstler / Playlists';

  @override
  String get pageSearching => 'Suche…';

  @override
  String get pageSearchEmpty => 'Keine Ergebnisse';

  @override
  String get pageSearchEmptyHint => 'Anderen Suchbegriff versuchen';

  @override
  String get pageSearchFailed => 'Suche fehlgeschlagen';

  @override
  String get pageLikedKugouLoginHint =>
      'Zum Anmelden, um Kugou-»Gefällt mir« zu synchronisieren';

  @override
  String get pageLikedNeteaseLoginHint =>
      'Zum Anmelden, um NetEase-Favoriten zu synchronisieren';

  @override
  String get pageLikedLoadFailed =>
      'Gefällt-mir-Liste konnte nicht geladen werden';

  @override
  String get pageLikedEmpty => 'Noch keine Lieblingstitel';

  @override
  String get pageLikedKugouEmptyHint =>
      'Nach »Gefällt mir« in der Kugou-App automatisch synchronisiert';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'Nach Herz in der NetEase-App automatisch synchronisiert';

  @override
  String get pageLikedLoginTitle => 'Anmelden, um Lieblingstitel anzusehen';

  @override
  String get pageLikedKugouLoginDesc =>
      'Per QR bei Kugou anmelden, »Gefällt mir« synchronisieren';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'Per QR bei NetEase anmelden, Herzen synchronisieren';

  @override
  String get libraryScanDirs => 'Scan-Ordner';

  @override
  String get libraryScanDirsDesc =>
      'Lokale Scan-Ordner verwalten; sofort nach Hinzufügen gescannt';

  @override
  String get libraryMediaStats => 'Medienstatistiken';

  @override
  String get libraryMediaStatsDesc => 'Übersicht der lokalen Bibliothek';

  @override
  String get libraryStatTracks => 'Titel';

  @override
  String get libraryStatDuration => 'Gesamtdauer';

  @override
  String get libraryStatSize => 'Gesamtgröße';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count Titel';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count Ordner';
  }

  @override
  String libraryHoursMinutes(Object h, Object m) {
    return '$h Std. $m Min.';
  }

  @override
  String libraryMinutes(Object m) {
    return '$m Min.';
  }

  @override
  String librarySeconds(Object s) {
    return '$s Sek.';
  }

  @override
  String get librarySearchHint => 'Lokale Titel suchen';

  @override
  String get libraryNoMatch => 'Keine passenden Titel';

  @override
  String get libraryScanningFiles => 'Dateien werden gezählt…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count Titel$extra';
  }

  @override
  String get libraryEmptyWaitScan => 'Erwarte ersten Scan';

  @override
  String get libraryEmpty => 'Lokale Bibliothek ist leer';

  @override
  String get libraryEmptyScanHint => 'Unten klicken, um jetzt zu scannen';

  @override
  String get libraryEmptyAddHint =>
      'Musikordner hinzufügen, um sie zu importieren';

  @override
  String get libraryScanNow => 'Jetzt scannen';

  @override
  String get libraryAddFolder => 'Ordner hinzufügen';

  @override
  String get menuLocateFile => 'Dateipfad öffnen';

  @override
  String get menuLocateFileComingSoon => 'Dateimanager in Phase 2';

  @override
  String get menuRemoveFromLibrary => 'Aus Bibliothek entfernen';

  @override
  String get playerBarCollapsePlayer => 'Player minimieren';

  @override
  String get playerBarHideLyrics => 'Songtext ausblenden';

  @override
  String get playerBarShowLyrics => 'Songtext anzeigen';

  @override
  String get playerPageNotPlaying => 'Wird nicht abgespielt';

  @override
  String get playerPageLoadHint => 'Quelle laden, um zu starten';

  @override
  String get playerPageQualityMenu => 'Qualität wechseln';

  @override
  String get pageHomeRankTitle => 'Charts';

  @override
  String get pageHomePlaylistSquare => 'Playlist-Platz';

  @override
  String get pageHomeHotArtists => 'Beliebte Künstler';

  @override
  String get pageHomePlaylists => 'Empfohlene Playlists';

  @override
  String get pageHomeNewAlbums => 'Neue Alben';

  @override
  String get pageHomeRankSubtitle => 'Echtzeit-Trends';

  @override
  String get pageHomePlaylistSquareSubtitle => 'Entdecke mehr Playlists';

  @override
  String get pageHomeArtistSubtitle => 'Beliebte Künstler, runde Avatare';

  @override
  String get pageHomeLoadFailed => 'Empfehlungen konnten nicht geladen werden';

  @override
  String get pageHomePlaylistsSubtitle => 'Deinem Geschmack entsprechend';

  @override
  String get pageHomeNewAlbumsSubtitle => 'Aktuelle neue Alben';

  @override
  String get pageHomeHotArtistsSubtitle => 'Alle hören das';

  @override
  String get pageHomeDaily => 'Tagesempfehlung';

  @override
  String get pageHomeDailyLoggedIn => 'Für dich ausgewählt';

  @override
  String get pageHomeDailyLoginHint =>
      'Bei NetEase anmelden für tägliche Updates';

  @override
  String get pageHomeDailyPlay => 'Heutige Empfehlung abspielen';

  @override
  String get pageHomeDailyLogin => 'Anmelden zum Freischalten';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting, $name';
  }

  @override
  String get greetingLate => 'Es ist spät';

  @override
  String get greetingMorning => 'Guten Morgen';

  @override
  String get greetingAfternoon => 'Guten Tag';

  @override
  String get greetingEvening => 'Guten Abend';

  @override
  String get greetingFallback => 'Worauf hast du heute Lust?';

  @override
  String get downloadDeleteTaskOnly => 'Nur Aufgabe löschen';

  @override
  String get downloadDeleteWithMedia => 'Aufgabe und Dateien löschen';

  @override
  String downloadSelectedCount(Object count) {
    return '$count ausgewählt';
  }

  @override
  String get downloadSelectAll => 'Alle auswählen';

  @override
  String get downloadDeselectAll => 'Alle abwählen';

  @override
  String get downloadPauseAll => 'Alle pausieren';

  @override
  String get downloadResumeAll => 'Alle fortsetzen';

  @override
  String get downloadDeleteSelected => 'Auswahl löschen';

  @override
  String get downloadExitSelect => 'Mehrfachauswahl beenden';

  @override
  String downloadActiveCount(Object count) {
    return 'Aktiv $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return 'Abgeschlossen $count';
  }

  @override
  String get downloadOpenDir => 'Download-Ordner öffnen';

  @override
  String get downloadSelectMode => 'Mehrfachauswahl';

  @override
  String get downloadEmpty => 'Keine Downloads';

  @override
  String get downloadEmptyHint =>
      'Rechtsklick auf Titel → Download zum Hinzufügen';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return '$count ausgewählte Aufgaben löschen';
  }

  @override
  String get downloadDeleteSelectedMessage =>
      'Ausgewählte Aufgaben und .tmp-Cache löschen; Mediendateien exakt passend löschen.';

  @override
  String get downloadClearTitle => 'Downloads leeren';

  @override
  String get downloadClearMessage =>
      'Alle Aufgaben und .tmp-Cache löschen; Mediendateien exakt passend löschen.';

  @override
  String get downloadCancelTooltip =>
      'Abbrechen (Aufgabe löschen und Cache leeren)';

  @override
  String get downloadResume => 'Fortsetzen';

  @override
  String get downloadOpenDirTask => 'Ordner öffnen';

  @override
  String get downloadDeleteTask => 'Aufgabe löschen';

  @override
  String get downloadDeleteWithMediaExact =>
      'Aufgabe und Dateien löschen (exakt)';

  @override
  String get downloadStatusQueued => 'In Warteschlange…';

  @override
  String get downloadStatusResolving => 'Download-URL wird aufgelöst…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return 'Herunterladen $percent% ($received) $speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return 'Herunterladen…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return 'Pausiert ($received)';
  }

  @override
  String get downloadStatusPaused => 'Pausiert';

  @override
  String downloadStatusFailed(Object error) {
    return 'Fehlgeschlagen: $error';
  }

  @override
  String get downloadStatusFailedUnknown =>
      'Fehlgeschlagen: Unbekannter Fehler';

  @override
  String get downloadStatusCanceled => 'Abgebrochen';

  @override
  String downloadStatusDone(Object size) {
    return 'Abgeschlossen ($size)';
  }

  @override
  String get downloadStatusAlready => 'Datei existiert bereits';

  @override
  String get pageHomeTitle => 'Entdecken';

  @override
  String get settingsTitle => 'Einstellungen';

  @override
  String get settingsCatAppearance => 'Darstellung';

  @override
  String get settingsCatPlayback => 'Wiedergabe';

  @override
  String get settingsCatLyrics => 'Songtexte';

  @override
  String get settingsCatPreset => 'Verhalten';

  @override
  String get settingsCatDownload => 'Download';

  @override
  String get settingsCatStorage => 'Speicher';

  @override
  String get settingsCatAbout => 'Über';

  @override
  String get settingsAppearanceSubtitle => 'Theme · Oberflächeneinstellungen';

  @override
  String get settingsPlaybackSubtitle => 'Audio-Engine · Wiedergabeverhalten';

  @override
  String get settingsLyricsSubtitle => 'Player-Songtexte · Desktop-Songtexte';

  @override
  String get settingsPresetSubtitle =>
      'Wiedergabefilter · Songtext-Wiederherstellung · Liste-Tags';

  @override
  String get settingsDownloadSubtitle =>
      'Download-Ordner · Parallelität · Limit · Qualität · Gruppierung · Dateiname';

  @override
  String get settingsStorageSubtitle => 'Datenverzeichnis · Datenbankdateien';

  @override
  String get settingsAboutSubtitle => 'Version · Projektinfo';

  @override
  String get settingsCatDeveloper => 'Entwickler';

  @override
  String get settingsDeveloperSubtitle =>
      'Entwicklermodus · Versteckte Funktionen';

  @override
  String get settingsDeveloperTitle => 'Entwicklermodus';

  @override
  String get settingsDeveloperMode => 'Entwicklermodus';

  @override
  String get settingsDeveloperModeOn =>
      'Aktiviert (Download-Funktionen sichtbar)';

  @override
  String get settingsDeveloperModeOff =>
      'Deaktiviert (Download-Funktionen ausgeblendet)';

  @override
  String get settingsDeveloperDownloadModule => 'Download-Modul';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      'Der Eintrag „Download“ in der Seitenleiste, der Menüpunkt „Download“ im Kontextmenü und die Kategorie „Download“ in den Einstellungen werden nur im Entwicklermodus angezeigt.';

  @override
  String get settingsDeveloperNote =>
      'Der Entwicklermodus ist für lokale Fehlersuche und den Eigengebrauch gedacht. Nutzung auf eigene Verantwortung.';

  @override
  String get settingsDevFpsMonitor => 'FPS-/Speicher-Monitor-Overlay';

  @override
  String get settingsDevFpsMonitorDesc =>
      'Zeigt FPS, durchschnittliche Framedauer und Prozessspeicher oben rechts in Echtzeit (zum Einklappen klicken). Standardmäßig aus; wird zusammen mit dem Entwicklermodus deaktiviert.';

  @override
  String get settingsDeveloperEnabled => 'Entwicklermodus aktiviert';

  @override
  String get settingsDeveloperDisabled => 'Entwicklermodus deaktiviert';

  @override
  String get settingsDeveloperHoldHint =>
      '10 Sekunden gedrückt halten, um den Entwicklermodus zu aktivieren (Maus: gedrückt halten)';

  @override
  String get settingsSearchHint => 'Einstellungen suchen…';

  @override
  String settingsSearchNoResult(Object query) {
    return 'Keine Einstellungen für「$query」gefunden';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '$count Treffer';
  }

  @override
  String get settingsSectionTheme => 'Theme';

  @override
  String get settingsThemeMode => 'Theme-Modus';

  @override
  String get settingsThemeModeDesc => 'Hell / Dunkel / System folgen';

  @override
  String get settingsThemeLight => 'Hell';

  @override
  String get settingsThemeDark => 'Dunkel';

  @override
  String get settingsThemeSystem => 'System folgen';

  @override
  String get settingsThemeNote =>
      'Standard: dunkles Theme;「System folgen」folgt der Systemdarstellung.';

  @override
  String get settingsSectionAccent => 'Akzentfarbe';

  @override
  String get settingsAccentTitle => 'Primärfarb-Seed';

  @override
  String settingsAccentSystem(Object color) {
    return 'Systemakzent folgen（$color）';
  }

  @override
  String get settingsAccentSystemFallback =>
      'Systemakzent folgen（Lesen fehlgeschlagen, Fallback benutzerdefiniert）';

  @override
  String get settingsAccentDefault => 'Standard-Hellblau（Design-System）';

  @override
  String get settingsAccentCustom =>
      'Benutzerdefiniert（Farben dynamisch aus Seed generiert）';

  @override
  String get settingsAccentDefaultTooltip => 'Standard-Blau';

  @override
  String get settingsAccentSystemTooltip => 'Systemakzent folgen';

  @override
  String get settingsAccentCustomTooltip => 'Farbwähler';

  @override
  String get settingsSectionLayout => 'Layout';

  @override
  String get settingsFloatingBar => 'Schwebende Player-Leiste';

  @override
  String get settingsFloatingBarOn =>
      'Zentrierte runde Kapsel unten（Glas + Schatten）';

  @override
  String get settingsFloatingBarOff => 'Breit angedockt（Standard）';

  @override
  String get settingsSectionFont => 'Oberflächenschriftart';

  @override
  String get settingsFontTitle => 'Oberflächenschriftart';

  @override
  String get settingsFontMiSans => 'MiSans（Standard）';

  @override
  String get settingsFontNoto => 'Noto Sans SC（Standardmetriken）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans SC（kostenlos kommerziell）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans SC';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => 'Oberflächensprache';

  @override
  String get settingsLanguageTitle => 'Oberflächensprache';

  @override
  String get settingsLanguageDesc => 'Anzeigesprache der Oberfläche wechseln';

  @override
  String get settingsLangSystem => 'System folgen';

  @override
  String get settingsSectionCover => 'Cover';

  @override
  String get settingsCoverRadius => 'Cover-Eckradius';

  @override
  String get settingsCoverRadiusSharp => 'Quadratisch（hohe Informationsdichte）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return '${radius}px Radius';
  }

  @override
  String get settingsCoverRadiusSharpLabel => 'Quadratisch';

  @override
  String get settingsCoverRadiusRoundedLabel => 'Abgerundet';

  @override
  String get settingsCoverRadiusLargeLabel => 'Stark abgerundet';

  @override
  String get settingsPickerTitle => 'Benutzerdefinierte Akzentfarbe';

  @override
  String get settingsPickerHexLabel => 'Farbwert（#RRGGBB）';

  @override
  String get settingsApply => 'Anwenden';

  @override
  String get settingsSectionAudio => 'Audio';

  @override
  String get settingsPassthrough =>
      'Originalqualität-Passthrough（keine Transcodierung）';

  @override
  String get settingsPassthroughOn =>
      'Quell-Samplerate beibehalten（Hi-Res/Verlustfrei ohne Verlust）';

  @override
  String get settingsPassthroughOff =>
      'Einheitliche 48kHz-Transcodierungs-Pipeline';

  @override
  String get settingsPassthroughNote =>
      'Passthrough an: Quell-Samplerate; aus: 48kHz-Ausgabe. Gilt nach Neuladen des Titels.';

  @override
  String get volumeMute => 'Stummschalten';

  @override
  String get volumeUnmute => 'Ton einschalten';

  @override
  String get settingsSectionMemory => 'Speicher & Start';

  @override
  String get settingsSessionMemory => 'Sitzungsspeicher';

  @override
  String get settingsSessionMemoryOn =>
      'Warteschlange, Position und Modus merken; beim nächsten Start wiederherstellen';

  @override
  String get settingsSessionMemoryOff => 'Nicht merken（nächster Start leer）';

  @override
  String get settingsAutoPlay => 'Automatische Wiedergabe beim Start';

  @override
  String get settingsAutoPlayNeedMemory =>
      'Aktivieren Sie zuerst「Sitzungsspeicher」';

  @override
  String get settingsAutoPlayOn =>
      'Letzte Sitzung wiederherstellen und automatisch abspielen';

  @override
  String get settingsAutoPlayOff =>
      'Nur Sitzung wiederherstellen, nicht automatisch weiterspielen';

  @override
  String get settingsSectionSpectrum => 'Spektrum';

  @override
  String get settingsSpectrum => 'Spektrum-Visualisierer';

  @override
  String get settingsSpectrumOn =>
      'Spektrumbalken anzeigen（0.65 Wiedergabe / 0.15 Pause）';

  @override
  String get settingsSpectrumOff => 'Kein Spektrum im Player';

  @override
  String get settingsSpectrumBarWidth => 'Spektrumbalken-Breite';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12, Vollbild-Player）';
  }

  @override
  String get settingsBarSpectrum => 'Spektrum der Playerleiste';

  @override
  String get settingsBarSpectrumOn =>
      'Mini-Spektrum unter der Zeit (keine Lyrics oder Mini-Lyrics aus)';

  @override
  String get settingsBarSpectrumOff => 'Kein Mini-Spektrum in der Playerleiste';

  @override
  String get settingsCoverBeatScale => 'Cover im Takt skalieren';

  @override
  String get settingsCoverBeatScaleOn => 'Cover pulsiert mit dem Beat';

  @override
  String get settingsCoverBeatScaleOff =>
      'Cover statisch（nur Wiedergabe/Pause）';

  @override
  String get settingsTransitionStyle => 'Medienübergang';

  @override
  String get settingsTransitionStyleDesc =>
      'Übergangsanimation beim Titelwechsel';

  @override
  String get settingsTransitionStyleScale => 'Skalierung';

  @override
  String get settingsTransitionStyleSlide => 'Schieben';

  @override
  String get settingsSectionShortcuts => 'Tastenkürzel';

  @override
  String get settingsShortcutSpace => 'Leertaste';

  @override
  String get settingsShortcutSpaceDesc => 'Wiedergabe / Pause';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => '10 Sekunden zurück / vor';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => 'Musikbibliothek';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc =>
      'Zurück（Dialog schließen / Vollbild-Player verlassen）';

  @override
  String get settingsSectionPlayerLyrics => 'Player-Songtexte';

  @override
  String get settingsPlayerLyrics => 'Songtexte im Player';

  @override
  String get settingsPlayerLyricsOn =>
      'Songtexte rechts im Vollbild-Player（aktuelle Zeile hervorgehoben, Klick zum Springen）';

  @override
  String get settingsPlayerLyricsOff => 'Keine Songtexte im Vollbild-Player';

  @override
  String get settingsBarLyrics => 'Lyrics der Playerleiste';

  @override
  String get settingsBarLyricsOn =>
      'Aktueller Liedtext unter der Zeit (automatisches Scrollen bei Überlänge)';

  @override
  String get settingsBarLyricsOff => 'Keine Mini-Lyrics in der Playerleiste';

  @override
  String get settingsShowTranslation => 'Übersetzung anzeigen';

  @override
  String get settingsShowTranslationOn =>
      'Übersetzung in Klammern hinter der Originalzeile';

  @override
  String get settingsShowTranslationOff => 'Liedtext-Übersetzung ausblenden';

  @override
  String get settingsSectionLyricStyle => 'Songtext-Stil';

  @override
  String get settingsLyricFontSize => 'Songtext-Schriftgröße';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（aktuelle Zeile vergrößert）';
  }

  @override
  String get settingsLyricLineHeight => 'Songtext-Zeilenhöhe';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（inkl. Zeilenabstand）';
  }

  @override
  String get settingsLyricPlayedColor => 'Abgespielte Farbe';

  @override
  String get settingsLyricPlayedColorDesc =>
      'Hervorhebungsfarbe für aktuelle Songtextzeile';

  @override
  String get settingsLyricUnplayedColor => 'Nicht abgespielte Farbe';

  @override
  String get settingsLyricUnplayedColorDesc =>
      'Farbe für kommende Songtextzeilen';

  @override
  String get settingsLyricsNote =>
      'Songtext-Stil gilt nur für Songtexte im Vollbild-Player';

  @override
  String get settingsSectionFilter => 'Wiedergabefilter';

  @override
  String get settingsDjMode => 'Fuck DJ Mode';

  @override
  String get settingsDjModeOn =>
      'DJ-/Mainstream-Titel automatisch überspringen';

  @override
  String get settingsDjModeOff =>
      'Bei DJ-Version automatisch zum nächsten Titel springen';

  @override
  String get settingsSectionLyricsFilter => 'Songtexte';

  @override
  String get settingsUncensor => 'Unanständige Wörter entsperren';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => 'Listendarstellung';

  @override
  String get settingsHideVip => 'VIP-Tags ausblenden';

  @override
  String get settingsHideVipOn => 'Keine VIP-/Bezahlt-Badges in der Liste';

  @override
  String get settingsHideVipOff => 'Bezahlt-Badges anzeigen（VIP / EP）';

  @override
  String get settingsHideQuality => 'Qualitäts-Tags ausblenden';

  @override
  String get settingsHideQualityOn => 'Keine Qualitäts-Badges in der Liste';

  @override
  String get settingsHideQualityOff =>
      'Höchste verfügbare Qualität anzeigen（Hi-Res / Verlustfrei / HQ…）';

  @override
  String get settingsShowSubtitle => 'Untertitel anzeigen';

  @override
  String get settingsShowSubtitleOn =>
      'Alias nach Songnamen anzeigen, z.B. (Live)';

  @override
  String get settingsShowSubtitleOff => 'Keine Aliase in der Liste';

  @override
  String get settingsEnergySaving => 'Energiesparmodus';

  @override
  String get settingsEnergySavingNote =>
      'Wenn aktiviert, sinkt die Spektrum-Framerate auf ~300ms (Standard: 100ms) und spart CPU; Rendering und Interpolation bleiben unberührt, die Änderung greift sofort.';

  @override
  String get settingsEnergySavingOn => 'Derzeit im Frameraten-Modus';

  @override
  String get settingsEnergySavingOff => 'Derzeit im Standardmodus';

  @override
  String get settingsSearchEnergySavingSubtitle =>
      'Spektrum-Framerate senken, um CPU zu sparen';

  @override
  String get settingsPerformanceMode => 'Leistungsmodus';

  @override
  String get settingsPerformanceModeOn => 'Derzeit im eingefrorenen Modus';

  @override
  String get settingsPerformanceModeOff => 'Derzeit im Animationsmodus';

  @override
  String get settingsSectionDir => 'Verzeichnis';

  @override
  String get settingsDownloadRootHint => 'Download-Ordner（Enter zum Speichern）';

  @override
  String get settingsRestoreDefault => 'Standard wiederherstellen';

  @override
  String get settingsDownloadRootNote =>
      'Standard: folgt dem Bibliotheksordner; Ordnerwechsel beendet laufende Downloads. Enter zum Speichern.';

  @override
  String get settingsSectionFilename => 'Dateiname';

  @override
  String get settingsDownloadTemplateHint =>
      'Dateinamenvorlage（Enter zum Speichern）';

  @override
  String get settingsDownloadTemplateNote =>
      'Platzhalter: <artist> · <title> · <album>; gilt nur für neue Aufgaben. Enter zum Speichern, sofort wirksam.';

  @override
  String get settingsSectionQuality => 'Qualität';

  @override
  String get settingsDownloadQuality => 'Standard-Download-Qualität';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return 'Standard $quality im Download-Dialog; automatischer Fallback bei fehlender Stufe';
  }

  @override
  String get settingsDownloadQualityNote =>
      'Stufen (hoch → niedrig): Hi-Res → Verlustfrei → HQ → SQ → LQ; automatischer Fallback in dieser Reihenfolge.';

  @override
  String get settingsSectionConcurrent => 'Parallelität';

  @override
  String get settingsDownloadConcurrent => 'Gleichzeitige Downloads';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count parallele Aufgaben（1~5）';
  }

  @override
  String get settingsDownloadGrouping => 'Ordner-Gruppierung';

  @override
  String get settingsGroupingFlat => 'Alles flach im Download-Ordner';

  @override
  String get settingsGroupingPlatform =>
      'Unterordner nach Plattform（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => 'Unterordner nach Künstler';

  @override
  String get settingsGroupingFlatLabel => 'Flach';

  @override
  String get settingsGroupingPlatformLabel => 'Nach Plattform';

  @override
  String get settingsGroupingArtistLabel => 'Nach Künstler';

  @override
  String get settingsSectionSpeedLimit => 'Geschwindigkeitsbegrenzung';

  @override
  String get settingsDownloadSpeedLimit =>
      'Download-Geschwindigkeitsbegrenzung';

  @override
  String get settingsSpeedUnlimited => 'Unbegrenzt（Standard）';

  @override
  String settingsSpeedLimited(Object speed) {
    return 'Auf $speed begrenzt, sofort wirksam';
  }

  @override
  String get settingsSpeedUnlimitedLabel => 'Unbegrenzt';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote =>
      'Limit gilt sofort, unterbricht laufende Aufgaben nicht（0.5 MB/s-Schritte, 0 = unbegrenzt）';

  @override
  String get settingsSectionHistory => 'Verlauf';

  @override
  String get settingsDownloadHistoryLimit => 'Download-Verlauf-Obergrenze';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count Einträge（10~500）· über Limit automatisch älteste entfernen';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count Einträge';
  }

  @override
  String get settingsDownloadHistoryNote =>
      'Nur älteste fehlgeschlagene/abgebrochene Einträge entfernen; laufende Aufgaben nicht betroffen.';

  @override
  String get settingsGroupingNote =>
      'Künstler-Gruppierung v2 unterstützt（Flach / Nach Plattform / Nach Künstler）';

  @override
  String get settingsSectionFingerprint => 'Geräte-Fingerprint';

  @override
  String get settingsFingerprintNote =>
      'Gerätekennung für Kugou-/Netease-Downloads; beim ersten Start erzeugt und dauerhaft stabil, je Nutzer einzigartig.';

  @override
  String get settingsDownloadDynamicFingerprint =>
      'Dynamischer Geräte-Fingerprint';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      'Erzeugt die Gerätekennung bei jedem Start neu (altes Verhalten); kann die Risikokontrolle der Plattform auslösen. Standardmäßig aus.';

  @override
  String get settingsResetFingerprint => 'Geräte-Fingerprint zurücksetzen';

  @override
  String get settingsResetFingerprintDesc =>
      'Nach dem Zurücksetzen erscheint dieser Rechner bei Kugou / Netease als neues Gerät; Sitzungen unter dem alten Fingerprint könnten ungültig werden. Jetzt zurücksetzen?';

  @override
  String get toastFingerprintReset => 'Geräte-Fingerprint zurückgesetzt';

  @override
  String get toastDownloadRootEmpty => 'Download-Ordner darf nicht leer sein';

  @override
  String get toastDownloadRootUpdated => 'Download-Ordner aktualisiert';

  @override
  String get toastTemplateEmpty => 'Dateinamenvorlage darf nicht leer sein';

  @override
  String get toastTemplateUpdated => 'Dateinamenvorlage aktualisiert';

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
  String get settingsSectionFileLocation => 'Dateispeicherorte';

  @override
  String get settingsDataDir => 'Datenverzeichnis';

  @override
  String get settingsLibraryDb => 'Medienbibliothek-Datenbank';

  @override
  String get settingsUserDb => 'Benutzerdatenbank（verschlüsselt）';

  @override
  String get settingsLibraryDbLabel => 'Bibliothekspfad';

  @override
  String get settingsUserDbLabel => 'Benutzerdatenpfad';

  @override
  String get settingsCopy => 'Kopieren';

  @override
  String toastCopied(Object label) {
    return '$label kopiert';
  }

  @override
  String get settingsStorageNote =>
      'Medienbibliothek und Benutzerdaten physisch getrennt; Pfade über ARCHOERA_DATA_DIR überschreibbar.';

  @override
  String get settingsSectionCache => 'Cache-Verwaltung';

  @override
  String get settingsCacheNote =>
      'Caches beschleunigen Surfen und Wiedergabe; sie werden nach dem Leeren automatisch neu aufgebaut. Bibliothek, Verlauf und Konten sind nicht betroffen.';

  @override
  String get settingsCacheGroupDisk => 'Datenbank-Caches (Datenträger)';

  @override
  String get settingsCacheGroupMem => 'Arbeitsspeicher-Caches (im Prozess)';

  @override
  String get settingsCacheLimitLyric => 'Lyrik-Cache-Limit';

  @override
  String get settingsCacheLimitCover => 'Coverbild-Cache-Limit';

  @override
  String get settingsCacheLimitUnlimited => 'Unbegrenzt';

  @override
  String get settingsCacheNoLimitConfirmTitle => 'Cache-Limit entfernen?';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      'Ohne Limit können Lyrik- und Coverbild-Caches unbegrenzt Speicher belegen und zu Speicherdruck und Verzögerungen führen. Limit entfernen?';

  @override
  String get settingsCacheNoLimitConfirm => 'Limit entfernen';

  @override
  String get settingsSongCache => 'Song-Cache';

  @override
  String get settingsSongCacheNote =>
      'Abgespielte Online-Songs werden lokal zwischengespeichert; bei erneutem Abspielen wird direkt von der Festplatte gelesen (spart Daten, schneller, offline abspielbar). Bei Überschreitung werden die am längsten nicht genutzten Titel per LRU automatisch entfernt. Die Mindestgröße von 16 MiB reicht für einen vollständigen 320-kbps-Titel (~2,4 MiB/Min). Gelöschte Caches werden automatisch neu aufgebaut; Bibliothek, Verlauf und Konten bleiben unberührt.';

  @override
  String get settingsSongCacheOn =>
      'Ein; Treffer werden von der lokalen Festplatte abgespielt';

  @override
  String get settingsSongCacheOff =>
      'Aus; der Medien-Cache wird nicht lokal gespeichert';

  @override
  String get settingsSongCacheLimitTitle => 'Cache-Limit';

  @override
  String settingsCacheSongs(Object count) {
    return '$count Titel';
  }

  @override
  String get settingsSearchSongCacheSubtitle =>
      'Schalter und MiB-Limit für den Online-Song-Disk-Cache';

  @override
  String get settingsCacheLiked => '\"Gemocht\"-Listencache';

  @override
  String get settingsCacheLyric => 'Liedtext-Cache';

  @override
  String get settingsCacheLyricMatch => 'Liedtext-Abgleich-Cache';

  @override
  String get settingsCacheLyricTtml => 'TTML-Liedtext-Cache';

  @override
  String get settingsCacheCover => 'Coverbild-Cache';

  @override
  String settingsCacheEntries(Object count) {
    return '$count Einträge';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count Bilder';
  }

  @override
  String get settingsCacheRefresh => 'Aktualisieren';

  @override
  String get settingsCacheClear => 'Leeren';

  @override
  String get settingsCacheClearAll => 'Alle leeren';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '\"$name\" leeren?';
  }

  @override
  String get settingsCacheClearConfirmDesc =>
      'Alle Daten dieses Caches werden gelöscht; er wird bei der nächsten Nutzung automatisch neu aufgebaut. Nicht rückgängig zu machen.';

  @override
  String get settingsCacheClearAllConfirmTitle => 'Alle Caches leeren?';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      'Löscht alle obigen Caches (Arbeitsspeicher und Datenträger). Bibliothek, Verlauf und Konten sind nicht betroffen.';

  @override
  String toastCacheCleared(Object name) {
    return '$name-Cache geleert';
  }

  @override
  String get toastCacheAllCleared => 'Alle Caches geleert';

  @override
  String get settingsSecuritySection => 'Sicheres Vernichten';

  @override
  String get settingsSecurityNote =>
      'Löscht unwiderruflich alle lokalen Anmeldedaten und Sitzungen (Streaming-Server-Passwörter, Netease-/Kugou-Sitzungen, lokale Subsonic-Konten) und macht die Plattform-Tokens ungültig. Bibliothek, Verlauf und Downloads bleiben unberührt.';

  @override
  String get settingsSecurityStreaming => 'Streaming-Server-Anmeldedaten';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count Server';
  }

  @override
  String get settingsSecurityStreamingDesc => 'Passwörter und Zugriffstokens';

  @override
  String get settingsSecuritySession => 'Sitzungen von Drittanbieter-Konten';

  @override
  String get settingsSecuritySessionDesc => 'Netease-/Kugou-Anmeldestatus';

  @override
  String get settingsSecurityUserDb => 'Lokale Benutzerdatenbank';

  @override
  String get settingsSecurityUserDbDesc => 'Subsonic-Konten und Favoriten';

  @override
  String get settingsSecurityLoggedIn => 'Angemeldet';

  @override
  String get settingsSecurityDestroy => 'Vernichten';

  @override
  String get settingsSecurityDestroyAll => 'Alles vernichten';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '„$name“ vernichten?';
  }

  @override
  String get settingsSecurityConfirmAllTitle =>
      'Alle sensiblen Daten vernichten?';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return 'Die Tokens der betroffenen Plattformen werden ungültig gemacht, Dateien werden überschrieben und gelöscht. Dieser Vorgang ist unwiderruflich. Geben Sie „$word“ ein, um zu bestätigen.';
  }

  @override
  String get settingsSecurityConfirmWord => 'vernichten';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return '„$word“ eingeben';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return 'Vernichtet: $name';
  }

  @override
  String get toastSecurityAllDestroyed =>
      'Alle sensiblen Daten wurden vernichtet';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return 'Vernichten fehlgeschlagen, Datei kann zurückbleiben: $path';
  }

  @override
  String get settingsDeviceBindSection => '高级 · 设备绑定';

  @override
  String get settingsDeviceBindNote =>
      '增强型可选项（opt-in）：本机免密 + 设备变更走恢复口令，不依赖系统安全存储。开启将读取本机设备标识（仅存本地、绝不上传）。默认关闭，普通用户使用 v1 加密已足够。';

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
      '将读取本机设备标识（Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID）用于绑定，仅存储于本地，绝不上传。注意：此操作不可回到当前 OS 免密模式——日后关闭设备绑定将回落为口令模式（每次启动需输入口令）。';

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
  String get settingsVaultSection => '凭据加密';

  @override
  String get settingsVaultNote =>
      '选择凭据的加密保护等级：v1 系统保护（默认）/ v2 口令保护 / v3 设备绑定（增强项 opt-in，读取本机设备标识，仅存本地、绝不上传）。v1 ↔ v2 可随时互切；v3 为终点档，关闭后回落为 v2。';

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
      'Credential vault shares are mismatched: storage backend mismatch or missing share. Local credentials cannot be decrypted. Rebuild the vault and sign in again.';

  @override
  String get settingsVaultShareBrokenRebuild => 'Rebuild vault';

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
  String get settingsVersion => 'Version';

  @override
  String get settingsVersionUnknown => 'v unbekannt · Flutter Desktop';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter Desktop';
  }

  @override
  String get settingsAudioEngine => 'Audio-Engine';

  @override
  String get settingsAudioEngineDesc =>
      'Eingebaute C-Engine（miniaudio）· Native FFI';

  @override
  String get settingsSubsonicServer => 'Subsonic-Server';

  @override
  String get settingsSubsonicDesc => 'Go FFI · Selbst gehostete Bibliothek';

  @override
  String get settingsAboutDesc =>
      'Eigener Musikplayer: lokale Bibliothek, direkte Quellen, selbst gehostetes Subsonic, native Audio-Engine';

  @override
  String get settingsSectionDeclaration => 'Software-Erklärung';

  @override
  String get settingsDeclineText =>
      'Diese Software（ArchoeraMusic）ist ein kostenloser Open-Source-Desktop-Musikplayer für persönliche Lern- und Forschungszwecke.\n\n';

  @override
  String get settingsDecline1Title => '1. Art der Software\n';

  @override
  String get settingsDecline1Body =>
      'Diese Software ist ein Drittanbieter-Client ohne Zugehörigkeit, Zusammenarbeit oder Autorisierung mit irgendeiner Musikplattform.\n\n';

  @override
  String get settingsDecline2Title => '2. Inhaltsquellen & Urheberrecht\n';

  @override
  String get settingsDecline2Body =>
      'Diese Software selbst bietet, speichert oder verteilt keine Musikinhalte. Urheberrechte liegen bei ursprünglichen Rechteinhabern und Plattformen.\n\n';

  @override
  String get settingsDecline3Title =>
      '3. Urheberrechtsdaten-Verarbeitungspflichten\n';

  @override
  String get settingsDecline3Body =>
      'Urheberrechtsdaten dienen nur zur persönlichen Vorschau und Forschung; nicht für kommerzielle oder öffentliche Verbreitung verwenden.\n\n';

  @override
  String get settingsDecline4Title => '4. Nutzungsbeschränkungen\n';

  @override
  String get settingsDecline4Body =>
      'Nicht für kommerzielle Aktivitäten, Massen-Scraping oder Wiederverkauf verwenden; nicht unter Verstoß gegen lokale Gesetze oder Nutzungsbedingungen verwenden.\n\n';

  @override
  String get settingsDecline5Title => '5. Haftungsausschluss\n';

  @override
  String get settingsDecline5Body =>
      'Diese Software wird「wie besehen」ohne ausdrückliche oder stillschweigende Garantien bereitgestellt.\n\n';

  @override
  String get settingsDeclineFooter =>
      'Diese Software dient nur der technischen Erforschung und Forschung.';

  @override
  String get settingsSectionFontCredits => 'Schriftartennennung';

  @override
  String get settingsFontCreditsText =>
      'Diese Software enthält die folgenden Schriftarten:\n· Noto Sans CJK SC (SIL Open Font License 1.1)\n· MiSans (© Xiaomi, verwendet gemäß der MiSans Font Intellectual Property License Agreement)\n· HarmonyOS Sans SC (© Huawei, verwendet gemäß der HarmonyOS Sans Font License Agreement)';

  @override
  String get commonNoLyrics => 'Keine Songtexte';

  @override
  String commonTrackCount(Object count) {
    return '$count Titel';
  }

  @override
  String get settingsSearchColorTitle => 'Abgespielt / Nicht abgespielt Farbe';

  @override
  String get settingsSearchColorSubtitle =>
      'Aktuelle Zeile Hervorhebung und normale Zeilenfarbe';

  @override
  String get settingsSearchDesktopLyricsTitle => 'Desktop-Songtexte';

  @override
  String get settingsSearchDesktopLyricsSubtitle =>
      'Eigenes Songtextfenster, immer im Vordergrund';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => 'Dateinamenvorlage';

  @override
  String get settingsSearchAccentSubtitle =>
      'Benutzerdefinierte Primärfarb-Seed · Palette';

  @override
  String get settingsThemeSource => 'Quelle der Themenfarbe';

  @override
  String get settingsThemeSourceDesc => 'Woher die Primärfarbe stammt';

  @override
  String get settingsThemeSourceDefault => 'System folgen';

  @override
  String get settingsThemeSourceCustom => 'Benutzerdefiniert';

  @override
  String get settingsThemeSourceCover => 'Cover folgen';

  @override
  String get settingsThemeSourceSolid => 'Keine';

  @override
  String get settingsThemeSourceCustomHint =>
      'Wählen Sie eine Seed-Farbe; Primär/Sekundär wird daraus generiert';

  @override
  String get settingsThemeSourceCoverHint =>
      'Extrahiert die dominante Farbe des aktuellen Covers in Echtzeit (Fallback auf Standard, wenn nicht verfügbar)';

  @override
  String get settingsGlobalTint => 'Globaler Farbton';

  @override
  String get settingsGlobalTintDesc =>
      'Themenfarbe dezent auf die gesamte Oberfläche anwenden';

  @override
  String get settingsGlobalTintNote =>
      'Wirksam, wenn eine Themenfarbe vorhanden ist (benutzerdefiniert / Cover); im Bildmodus erzwungen.';

  @override
  String get settingsSectionStyle => 'Hintergrundstil';

  @override
  String get settingsAppearanceStyle => 'Darstellungsstil';

  @override
  String get settingsAppearanceStyleDesc =>
      'Wie der Haupthintergrund dargestellt wird';

  @override
  String get settingsAppearanceStyleSolid => 'Einfarbig';

  @override
  String get settingsAppearanceStyleImage => 'Bild';

  @override
  String get settingsBackgroundImage => 'Hintergrundbild';

  @override
  String get settingsBackgroundImageDesc =>
      'Lokales Bild als App-Hintergrund wählen (Bildmodus erzwingt dunkles Design + globalen Farbton)';

  @override
  String get settingsBackgroundPick => 'Bild wählen';

  @override
  String get settingsBackgroundReplace => 'Ersetzen';

  @override
  String get settingsBackgroundClear => 'Löschen';

  @override
  String get settingsBackgroundBlur => 'Hintergrundunschärfe';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return 'Gaußsche Unschärfe auf das Hintergrundbild angewendet (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => 'Maskenstärke';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return 'Deckkraft der schwarzen Überlagerung ($dim%); höher = Vordergrund besser lesbar';
  }

  @override
  String get settingsBackgroundScale => 'Zoomgröße';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return 'Zoomfaktor des Hintergrundbilds (${scale}x)';
  }

  @override
  String get settingsSidebarCollapsed => 'Seitenleiste einklappen';

  @override
  String get settingsSidebarCollapsedDesc =>
      'Seitenleiste in den Nur-Symbole-Modus einklappen';

  @override
  String get settingsSidebarNavStyle => 'Navigations-Highlight-Animation';

  @override
  String get settingsSidebarNavStyleDesc =>
      'Animationsstil des aktiven Navigations-Highlights';

  @override
  String get settingsSidebarNavStyleDefault => 'Statisch';

  @override
  String get settingsSidebarNavStyleAnimated => 'Animiert';

  @override
  String get settingsRouteTransition => 'Seitenübergang';

  @override
  String get settingsRouteTransitionDesc =>
      'Übergangsanimation beim Wechseln der Seiten';

  @override
  String get settingsRouteTransitionNone => 'Keine';

  @override
  String get settingsRouteTransitionFade => 'Ausblenden';

  @override
  String get settingsRouteTransitionSlide => 'Schieben';

  @override
  String get settingsRouteTransitionZoom => 'Zoom';

  @override
  String get settingsSearchThemeSourceSubtitle =>
      'Standardthema · Benutzerdefiniert · Cover folgen · Kein Thema';

  @override
  String get settingsSearchGlobalTintSubtitle =>
      'Oberfläche mit der Themenfarbe einfärben';

  @override
  String get settingsSearchBackgroundSubtitle =>
      'Einfarbig / Bild · Unschärfe · Maske · Zoom';

  @override
  String get settingsSearchSidebarSubtitle =>
      'Seitenleiste einklappen · Statisch / Animiert';

  @override
  String get settingsSearchRouteTransitionSubtitle =>
      'Keine · Ausblenden · Schieben · Zoom';

  @override
  String get settingsSearchFloatingBarSubtitle =>
      'Fließende Kapsel unten · Breit angedockt';

  @override
  String get settingsSearchFontSubtitle =>
      'MiSans · Noto Sans · HarmonyOS Sans';

  @override
  String get settingsSearchLanguageSubtitle =>
      'System folgen · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle =>
      'Quadratisch · Abgerundet · Stark abgerundet';

  @override
  String get settingsSectionWeather => 'Wetter';

  @override
  String get settingsWeather => 'Wetter-Widget';

  @override
  String get settingsWeatherDesc =>
      'Mini-Wetter (Symbol + Temperatur) links vom Avatar';

  @override
  String get settingsWeatherAutoLocate => 'Automatische Ortung';

  @override
  String get settingsWeatherAutoLocateDesc =>
      'Grobe Position über Netzwerk-IP (Datenschutz: standardmäßig aus)';

  @override
  String get settingsWeatherCity => 'Manuelle Stadt';

  @override
  String get settingsWeatherCityHint =>
      'Keine IP-Ortung mehr nach Eintrag (z. B. München)';

  @override
  String get settingsWeatherNote =>
      'Datenschutz: Wetterdaten von Open-Meteo (kostenlos, kein API-Schlüssel). Bei automatischer Ortung wird die IP an ip-api.com gesendet, nur zur Wetterabfrage, nicht gespeichert. Widget und Ortung sind standardmäßig deaktiviert.';

  @override
  String get settingsSearchWeatherSubtitle =>
      'Mini-Wetter-Widget in der Kopfzeile (Symbol + Temperatur)';

  @override
  String get weatherRefresh => 'Wetter aktualisieren';

  @override
  String get weatherNoLocation =>
      'Stadt eintragen oder Ortung in den Einstellungen aktivieren';

  @override
  String get weatherUnavailable =>
      'Wetter nicht verfügbar, zum Wiederholen tippen';

  @override
  String get settingsSearchPassthroughSubtitle =>
      'Keine Transcodierung · 48kHz-Pipeline';

  @override
  String get settingsSearchSessionMemorySubtitle =>
      'Sitzung merken/wiederherstellen';

  @override
  String get settingsSearchAutoPlaySubtitle => 'Automatisch weiterspielen';

  @override
  String get settingsSearchSpectrumSubtitle =>
      'Spektrum des Players umschalten · Deckkraft';

  @override
  String get settingsSearchSpectrumWidthSubtitle => 'Balkenbreite 1~12px';

  @override
  String get settingsSearchPlayerLyricsSubtitle =>
      'Songtextanzeige im Vollbild-Player';

  @override
  String get settingsSearchLyricFontSizeSubtitle =>
      'Songtext-Schriftgröße 14~28px';

  @override
  String get settingsSearchLyricLineHeightSubtitle => 'Zeilenhöhe 42~64px';

  @override
  String get settingsSearchUncensorSubtitle =>
      'Zensierte Wörter in Songtexten wiederherstellen';

  @override
  String get settingsSearchHideVipSubtitle =>
      'VIP-/Bezahlt-Badges in Songliste ausblenden';

  @override
  String get settingsSearchHideQualitySubtitle =>
      'Qualitäts-Badges in Songliste ausblenden';

  @override
  String get settingsSearchSubtitleSubtitle =>
      'Aliase in Songliste anzeigen (z.B. (Live))';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      'Download-Speicherort (Standard ~/Music/ArchoeraMusic)';

  @override
  String get settingsSearchFilenameSubtitle =>
      '<artist>/<title>/<album> Platzhalter konfigurierbar';

  @override
  String get settingsSearchConcurrentSubtitle =>
      '1~5 parallele Download-Aufgaben';

  @override
  String get settingsSearchSpeedLimitSubtitle =>
      'Unbegrenzt · 0.5~20 MB/s sofort wirksam';

  @override
  String get settingsSearchQualitySubtitle =>
      'Hi-Res · Verlustfrei · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle =>
      'Flach · Nach Plattform · Nach Künstler';

  @override
  String get settingsSearchHistoryLimitSubtitle =>
      'Über Limit automatisch älteste entfernen (10~500)';

  @override
  String get settingsSearchStorageSubtitle =>
      'Pfade Medienbibliothek · Benutzer-DB';

  @override
  String get settingsSearchAboutSubtitle => 'Audio-Engine · Subsonic-Server';

  @override
  String get qualityLossless => 'Verlustfrei';

  @override
  String get repeatModeList => 'Liste wiederholen';

  @override
  String get repeatModeOne => 'Einen Titel wiederholen';

  @override
  String get commonUnknownTrack => 'Unbekannter Titel';

  @override
  String get commonAnonymousUser => 'Anonymer Benutzer';

  @override
  String get commonCanceled => 'Abgebrochen';

  @override
  String get commonILike => 'Meine Favoriten';

  @override
  String get sidebarStreaming => 'Streaming';

  @override
  String get settingsCatMediaSource => 'Medienquelle';

  @override
  String get settingsMediaSourceSubtitle =>
      'Streaming-Server (Subsonic / Jellyfin / Emby)';

  @override
  String get settingsCatScrape => 'Scraping';

  @override
  String get settingsScrapeSubtitle =>
      'Metadaten aus mehreren Quellen: Cover / Lyrics / Tags';

  @override
  String get settingsSectionScrapeDirs => 'Scrape-Verzeichnisse';

  @override
  String get settingsScrapeDirsHint =>
      'Ein Verzeichnis pro Zeile; leer lassen, um den Bibliotheks-Scanpfaden zu folgen';

  @override
  String get settingsScrapeDirsEmptyNote =>
      'Keine Scrape-Verzeichnisse konfiguriert; es werden die Bibliotheks-Scanpfade verwendet.';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return 'Aktive Verzeichnisse: $dirs';
  }

  @override
  String get settingsSectionScrapeSources => 'Datenquellen';

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
  String get settingsScrapeSourceAcoustID => 'AcoustID (Audio-Fingerabdruck)';

  @override
  String get settingsScrapeSourceDesc =>
      'Wenn aktiviert, nimmt an Mehrquellen-Abfrage, Ähnlichkeitsabgleich und Score-Zusammenführung teil';

  @override
  String get settingsSectionScrapeProgress => 'Scrape-Fortschritt';

  @override
  String get settingsScrapeStart => 'Scraping starten';

  @override
  String get settingsScrapeCancel => 'Scraping abbrechen';

  @override
  String get settingsScrapeScanning => 'Verzeichnisse werden gescannt…';

  @override
  String settingsScrapeCurrent(Object file) {
    return 'Verarbeite: $file';
  }

  @override
  String get settingsScrapeSuccess => 'Erfolg';

  @override
  String get settingsScrapeFailed => 'Fehlgeschlagen';

  @override
  String get settingsScrapeSkipped => 'Übersprungen';

  @override
  String get settingsScrapeNotFound => 'Nicht gefunden';

  @override
  String get settingsScrapeIdle =>
      'Noch nicht ausgeführt. Klicken Sie unten auf die Schaltfläche, um zu starten.';

  @override
  String get settingsScrapeNoDirs =>
      'Keine Verzeichnisse zum Scrapen. Konfigurieren Sie zuerst Scrape- oder Bibliotheks-Scanverzeichnisse.';

  @override
  String get settingsScrapeDone => 'Scraping abgeschlossen';

  @override
  String get settingsScrapeCanceled => 'Scraping abgebrochen';

  @override
  String get toastScrapeNoDirs => 'Keine Verzeichnisse zum Scrapen';

  @override
  String get toastScrapeDirsUpdated => 'Scrape-Verzeichnisse gespeichert';

  @override
  String get toastScrapeStarted => 'Scraping gestartet';

  @override
  String get commonDelete => 'Löschen';

  @override
  String get commonSave => 'Speichern';

  @override
  String get commonConfirm => 'Bestätigen';

  @override
  String get streamingHint => 'Medienquelle';

  @override
  String get streamingHintDetail =>
      'Streaming-Server hinzufügen, um dessen Musik zu durchsuchen und abzuspielen (Subsonic-Familie / Jellyfin / Emby, inkl. integriertem lokalem Subsonic-Server).';

  @override
  String get streamingServerAdd => 'Server hinzufügen';

  @override
  String get streamingEmptyNoServer => 'Noch kein Streaming-Server';

  @override
  String get streamingEmptyAddHint =>
      'Klicken Sie oben auf die Schaltfläche, um einen Server hinzuzufügen';

  @override
  String get streamingServerConnected => 'Verbunden';

  @override
  String get streamingServerDisconnected => 'Nicht verbunden';

  @override
  String get streamingServerLastConnected => 'Zuletzt verbunden';

  @override
  String get streamingServerDisconnect => 'Trennen';

  @override
  String get streamingToastDisconnected => 'Serververbindung getrennt';

  @override
  String get streamingServerConnect => 'Verbinden';

  @override
  String streamingToastConnected(Object name) {
    return 'Verbunden mit $name';
  }

  @override
  String get streamingServerConnectFailed => 'Verbindung fehlgeschlagen';

  @override
  String get streamingServerEdit => 'Bearbeiten';

  @override
  String get streamingServerDeleteConfirmTitle => 'Server löschen';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return 'Server „$name“ löschen?';
  }

  @override
  String get streamingServerRemoved => 'Server gelöscht';

  @override
  String get streamingServerErrorNameEmpty => 'Servernamen eingeben';

  @override
  String get streamingServerErrorHostEmpty => 'Serveradresse eingeben';

  @override
  String get streamingServerErrorPortInvalid => 'Ungültiger Port (1–65535)';

  @override
  String get streamingServerErrorUsernameEmpty => 'Benutzernamen eingeben';

  @override
  String get streamingServerErrorPasswordEmpty => 'Passwort eingeben';

  @override
  String get streamingServerAdded => 'Server hinzugefügt';

  @override
  String get streamingServerUpdated => 'Server aktualisiert';

  @override
  String get streamingServerType => 'Typ';

  @override
  String get streamingServerName => 'Name';

  @override
  String get streamingServerNamePlaceholder => 'z. B. Mein Navidrome';

  @override
  String get streamingServerHost => 'Serveradresse';

  @override
  String get streamingServerHostPlaceholder => 'z. B. 192.168.1.10:4533';

  @override
  String get streamingServerPort => 'Port';

  @override
  String get streamingServerPortNote =>
      'Standardports: 4533 (Subsonic) / 8096 (Jellyfin); leer lassen für Auto-Erkennung.';

  @override
  String get streamingServerLocalTitle => 'Integrierter lokaler Server';

  @override
  String get streamingServerLocalDesc =>
      'Integrierten Subsonic-Server verwenden (lokale Bibliothek)';

  @override
  String get streamingServerUsername => 'Benutzername';

  @override
  String get streamingServerPassword => 'Passwort';

  @override
  String get streamingServerTestOk => 'Verbindung OK';

  @override
  String get streamingServerTestFail => 'Verbindung fehlgeschlagen';

  @override
  String get streamingServerTest => 'Verbindung testen';

  @override
  String get streamingTabsSongs => 'Titel';

  @override
  String get streamingTabsAlbums => 'Alben';

  @override
  String get streamingTabsArtists => 'Künstler';

  @override
  String get streamingTabsPlaylists => 'Wiedergabelisten';

  @override
  String get streamingEmptyGoToSettings => 'Zu Einstellungen';

  @override
  String get streamingEmptyNotConnected => 'Mit keinem Server verbunden';

  @override
  String streamingTotalSongs(Object count) {
    return '$count Titel';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count Alben';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count Künstler';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count Wiedergabelisten';
  }

  @override
  String get streamingEmptyNoResults => 'Keine passenden Ergebnisse';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count Titel';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count Alben';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count Titel';
  }
}
