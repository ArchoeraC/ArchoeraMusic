// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get settingsCatRender => 'Leistung & Rendering';

  @override
  String get settingsRenderSubtitle =>
      'GPU-Beschleunigung und Rendering-Kosten (experimentell)';

  @override
  String get settingsRippleShader => 'Ripple-GPU-Shader';

  @override
  String get settingsRippleShaderDesc =>
      'Player-Ripple mit Fragment-Shader zeichnen (aus = CPU-Mesh-Fallback)';

  @override
  String get settingsRippleLowRes => 'Dynamische Ebene in halber Auflösung';

  @override
  String get settingsRippleLowResDesc =>
      'Ripple-Ebene in halber Auflösung rendern und hochskalieren; nur CPU-Fallback';

  @override
  String get settingsRippleDamageClip => 'Schadensbereich-Clipping';

  @override
  String get settingsRippleDamageClipDesc =>
      'Nur aktive Ripple-Bänder neu zeichnen; nur CPU-Fallback';

  @override
  String get menuTrackDetail => 'Mediadetails';

  @override
  String get trackDetailDuration => 'Dauer';

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
  String toastBatchAddedToQueue({required Object count}) {
    return '$count Titel zur Warteschlange hinzugefügt';
  }

  @override
  String toastBatchAddedToDownloadQueue({required Object count}) {
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
      'Rendering im Hintergrund drosseln (beim Minimieren angehalten, 1 FPS bei Fokusverlust oder ausgeschaltetem Bildschirm)';

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
  String get settingsBackgroundUnload =>
      'Besuchte Seiten im Hintergrund entladen';

  @override
  String get settingsBackgroundUnloadSubtitle =>
      'Gibt Listen und Bilder bei Minimiert/Tray/Bildschirm aus frei; Neuaufbau bei Rückkehr (Scrollposition kann verloren gehen)';

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
  String get brandNetease => 'NT';

  @override
  String get brandKugou => 'KG';

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
  String downloadRequiresLoginContent({required Object platform}) {
    return 'Um Download-Links von $platform zu erhalten, ist eine Anmeldung erforderlich. Ohne Anmeldung nur Vorschau, keine volle Qualität.\n\nBitte melden Sie sich in Ihrem $platform-Konto an und versuchen Sie es erneut.';
  }

  @override
  String get downloadRequiresLoginTitle =>
      'Anmeldung zum Herunterladen erforderlich';

  @override
  String get downloadStreamingWarnTitle =>
      'Download von Streaming-Medien nicht empfohlen';

  @override
  String get downloadStreamingWarnBody =>
      'Wenn die Verfügbarkeit Ihres Streaming-Servers gewährleistet ist, Sie ihn selten nutzen oder selbst betreiben, ist ein lokaler Download nicht zu empfehlen.';

  @override
  String get downloadStreamingWarnDontAsk => 'Nicht mehr anzeigen';

  @override
  String get downloadStreamingWarnProceed => 'Trotzdem herunterladen';

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
  String navHeaderKugouId({required Object id}) {
    return 'KG $id';
  }

  @override
  String get navHeaderKugouMusic => 'KG';

  @override
  String get navHeaderLoginAccount => 'Anmelden (NT / KG)';

  @override
  String get navHeaderLogout => 'Abmelden';

  @override
  String get navHeaderNeteaseAccount => 'NT-Konto';

  @override
  String get navHeaderNeteaseMusic => 'NT';

  @override
  String get navHeaderQqMusic => 'QM';

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
  String get queueRepeatOff => 'Der Reihe nach';

  @override
  String get queueFinished => 'Wiedergabeliste beendet, Wiedergabe angehalten';

  @override
  String get queueShuffle => 'Zufallswiedergabe';

  @override
  String get queueShuffleOff => 'Zufallswiedergabe aus';

  @override
  String get queueTitle => 'Wiedergabewarteschlange';

  @override
  String queueTrackCount({required Object count}) {
    return '$count Titel';
  }

  @override
  String get searchHistory => 'Suchverlauf';

  @override
  String get searchHistoryClear => 'Leeren';

  @override
  String get searchHistoryEmpty => 'Kein Suchverlauf';

  @override
  String get searchHot => 'Trends';

  @override
  String searchQuick({required Object query}) {
    return '„$query“ suchen';
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
  String toastAddedToDownloadQueue({required Object quality}) {
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
      'Vorgang fehlgeschlagen (stellen Sie sicher, dass Sie in Ihrem KG-Konto angemeldet sind)';

  @override
  String get toastLoginRequiredNetease =>
      'Vorgang fehlgeschlagen (stellen Sie sicher, dass Sie in Ihrem NT-Konto angemeldet sind)';

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
  String commonLoadFailed({required Object msg}) {
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
  String commentLoginRequired({required Object platform}) {
    return 'Melden Sie sich in Ihrem $platform-Konto an, um zu kommentieren';
  }

  @override
  String commentNotFound({required Object platform}) {
    return 'Keine $platform-Kommentare für diesen Titel gefunden';
  }

  @override
  String get commentPublished => 'Kommentar veröffentlicht';

  @override
  String commentReplyFormat({required Object text, required Object user}) {
    return '@$user: $text';
  }

  @override
  String get commentSend => 'Senden';

  @override
  String commentSendFailed({required Object msg}) {
    return 'Senden fehlgeschlagen: $msg';
  }

  @override
  String get commentReply => 'Antworten';

  @override
  String commentReplyTo({required Object user}) {
    return 'Antwort an @$user';
  }

  @override
  String get commentDeleteConfirmBody =>
      'Kann nicht rückgängig gemacht werden. Fortfahren?';

  @override
  String get commentDeleted => 'Kommentar gelöscht';

  @override
  String commentDeleteFailed({required Object msg}) {
    return 'Löschen fehlgeschlagen: $msg';
  }

  @override
  String commentTimeFormat({
    required Object day,
    required Object month,
    required Object time,
  }) {
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
  String loginKugouLoggedIn({required Object platform}) {
    return 'Bei $platform angemeldet';
  }

  @override
  String loginKugouLogin({required Object platform}) {
    return 'Mit $platform anmelden';
  }

  @override
  String loginKugouQrLogin({required Object platform}) {
    return 'Per QR-Code bei $platform anmelden';
  }

  @override
  String get loginKugouResponseMissingToken =>
      'Anmeldeantwort enthält kein token/userid';

  @override
  String loginKugouScanHint({required Object platform}) {
    return 'Scannen Sie den QR-Code mit der $platform-App';
  }

  @override
  String loginKugouSession({required Object platform}) {
    return 'Mit $platform angemeldet';
  }

  @override
  String loginKugouSuccessVip({required Object platform}) {
    return 'Anmeldung bei $platform erfolgreich, VIP-Titel freigeschaltet';
  }

  @override
  String loginLoggedOut({required Object platform}) {
    return 'Bei $platform abgemeldet';
  }

  @override
  String loginLogoutWithId({required Object id}) {
    return 'Abmelden ($id)';
  }

  @override
  String loginNeteaseScanHint({required Object platform}) {
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
  String get loginRiskTitle => 'Anmelderisiko';

  @override
  String get loginRiskBody =>
      'Die Anmeldung über einen Drittanbieter-Client birgt folgende Risiken. Bitte bestätigen Sie, bevor Sie fortfahren:\n\n· Die Plattform kann gegenüber Anmeldungen von Drittanbieter-Clients Risikokontrollen, Einschränkungen oder Sperren verhängen, was zu Kontoanomalien oder eingeschränkten Funktionen führen kann;\n· QR- / Zugangsdaten-Anmeldung bedeutet, dass Sie dieser Software erlauben, mit Ihrem Konto auf die Plattform zuzugreifen; Aktionen wie Favorisieren, Abspielen und Kommentieren wirken sich tatsächlich auf Ihr Konto aus;\n· Anmeldedaten (Cookies / Token usw.) werden nur lokal verschlüsselt gespeichert und niemals an den Entwickler oder einen Nicht-Plattform-Server hochgeladen;\n· Bitte beachten Sie die Nutzungsbedingungen der jeweiligen Plattform; alle Folgen der Nutzung dieser Software tragen Sie selbst.\n\nMit dem Fortsetzen der Anmeldung bestätigen Sie, diese Risiken gelesen und akzeptiert zu haben.';

  @override
  String get loginRiskAgree => 'Verstanden, fortfahren';

  @override
  String get loginTabQr => 'QR-Code';

  @override
  String get loginTabPhone => 'Telefon';

  @override
  String get loginTabEmail => 'E-Mail';

  @override
  String loginTitleBrand({required String platform}) {
    return 'Bei $platform anmelden';
  }

  @override
  String get loginPhoneHint => 'Telefonnummer';

  @override
  String get loginCodeHint => 'SMS-Code';

  @override
  String get loginSendCode => 'Code senden';

  @override
  String get loginEmailHint => 'E-Mail';

  @override
  String get loginPasswordHint => 'Passwort';

  @override
  String get loginEmailRiskHint =>
      'Hinweis: Hat das Konto eine gebundene Telefonnummer, kann die Plattform bei der E-Mail-Anmeldung eine SMS-Verifizierung senden (Sicherheitsmaßnahme der Plattform, unabhängig von dieser Software).';

  @override
  String get loginSubmit => 'Anmelden';

  @override
  String get loginPhoneRequired => 'Bitte Telefonnummer eingeben';

  @override
  String get loginCodeRequired => 'Bitte Bestätigungscode eingeben';

  @override
  String get loginEmailRequired => 'Bitte E-Mail eingeben';

  @override
  String get loginPasswordRequired => 'Bitte Passwort eingeben';

  @override
  String get loginCodeSendFailed =>
      'Bestätigungscode konnte nicht gesendet werden';

  @override
  String get loginFailed => 'Anmeldung fehlgeschlagen';

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
  String trackListEmptyDailyLogin({required Object platform}) {
    return 'Keine Titel (tägliche Empfehlung erfordert $platform-Anmeldung)';
  }

  @override
  String get trackListNoPlayableSource =>
      'Keine abspielbare Quelle (VIP / Vorschau-Limit)';

  @override
  String get trackListPlayAll => 'Alle abspielen';

  @override
  String trackListPlaySourceFailed({required Object msg}) {
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
  String commonSongCountHint({required Object count}) {
    return 'Insgesamt $count Titel · Zum Abspielen klicken';
  }

  @override
  String get platformNetease => 'NT';

  @override
  String get platformKugou => 'KG';

  @override
  String get platformAll => 'Alle';

  @override
  String get menuDeleteFile => 'Datei löschen';

  @override
  String get libraryDeleteFileTitle => 'Datei löschen';

  @override
  String libraryDeleteFileMessage({required Object name}) {
    return '„$name“ wird dauerhaft gelöscht. Nicht rückgängig zu machen. Fortfahren?';
  }

  @override
  String get libraryDeleteFileConfirm => 'Löschen';

  @override
  String get toastFileDeleted => 'Datei gelöscht';

  @override
  String get toastDeleteFileFailed => 'Datei konnte nicht gelöscht werden';

  @override
  String get toastRevealFileFailed =>
      'Datei konnte nicht angezeigt werden (kein Dateimanager verfügbar)';

  @override
  String get settingsSectionThirdPartyService => 'Drittanbieter-Dienste';

  @override
  String get settingsNekoAttribution =>
      'Bereitgestellt mit Unterstützung der Neko Music API';

  @override
  String get settingsNekoApiDocs => 'Neko Music API-Dokumentation';

  @override
  String get settingsSongCacheMemoryHint =>
      '„In-Memory-Wiedergabe“ ist aktiv – der Song-Cache wird nicht auf die Festplatte geschrieben';

  @override
  String get platformNeko => 'NK';

  @override
  String get settingsCatExperimentalSource => 'Experimentelle Quellen';

  @override
  String get settingsExperimentalSourceSubtitle =>
      'Drittanbieter-Quellen (standardmäßig aus)';

  @override
  String get settingsNekoTitle => 'NekoMusic';

  @override
  String get settingsNekoNote =>
      'Experimentelle Drittanbieter-Quelle, inoffiziell; nur Anmeldung (keine Registrierung/VIP-Kauf). Kann jederzeit ausfallen.';

  @override
  String get settingsNekoEnable => 'NekoMusic aktivieren';

  @override
  String get settingsNekoEnableDesc =>
      'NK in Suche, Favoriten und Bibliothek anzeigen (standardmäßig aus)';

  @override
  String get settingsNekoLogin => 'Anmelden';

  @override
  String get settingsNekoLogout => 'Abmelden';

  @override
  String settingsNekoLoggedInAs({required Object name}) {
    return 'Angemeldet als $name';
  }

  @override
  String get settingsNekoNotLoggedIn => 'Nicht angemeldet';

  @override
  String get nekoLoginTitle => 'Bei NekoMusic anmelden';

  @override
  String get nekoLoginTabQr => 'QR-Code';

  @override
  String get nekoLoginTabPassword => 'E-Mail und Passwort';

  @override
  String get nekoLoginEmail => 'E-Mail';

  @override
  String get nekoLoginPassword => 'Passwort';

  @override
  String get nekoLoginPasswordHint => 'Passwort eingeben';

  @override
  String get nekoLoginSubmit => 'Anmelden';

  @override
  String get nekoLoginQrHint => 'Mit der NekoMusic-App scannen und anmelden';

  @override
  String get nekoQrScanned => 'Gescannt, bitte am Handy bestätigen';

  @override
  String get nekoQrCanceled => 'Anmeldung abgebrochen';

  @override
  String get nekoQrExpired => 'QR-Code abgelaufen, bitte neu erzeugen';

  @override
  String get toastLoginRequiredNeko =>
      'Aktion fehlgeschlagen (bitte prüfen, ob du bei deinem NK-Konto angemeldet bist)';

  @override
  String get pageLikedNekoLoginHint =>
      'Melde dich bei NK an, um deine Lieblingssongs zu sehen';

  @override
  String get pageLikedNekoLoginDesc =>
      'Melde dich bei NekoMusic an, um Lieblingssongs zu synchronisieren';

  @override
  String get pageLikedNekoEmptyHint =>
      'Noch keine Lieblingssongs – tippe in der Suche auf das Herz';

  @override
  String get pageFavNekoLoginDesc =>
      'Melde dich bei NekoMusic an, um Playlists und Favoriten zu sehen';

  @override
  String get pageFavNekoEmptyHint => 'Noch keine Playlists oder Favoriten';

  @override
  String toastPlayedAll({required Object count}) {
    return '$count Titel abgespielt';
  }

  @override
  String toastPlayFailed({required Object msg}) {
    return 'Wiedergabefehler: $msg';
  }

  @override
  String get toastMissingLocalPath => 'Lokaler Dateipfad fehlt';

  @override
  String get toastRemovedFromLibrary => 'Aus Bibliothek entfernt';

  @override
  String get toastRemoveFailed => 'Entfernen fehlgeschlagen';

  @override
  String toastDailyRequiresLogin({required Object platform}) {
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
  String pageFavPlaylistCount({required Object count}) {
    return '$count Lieblings-Wiedergabelisten';
  }

  @override
  String get pageFavPlaylistLoginHint => 'Zum Anmelden, um Favoriten anzusehen';

  @override
  String pageFavAlbumCount({required Object count}) {
    return '$count Lieblingsalben';
  }

  @override
  String get pageFavAlbumLoginHint => 'Zum Anmelden, um Alben anzusehen';

  @override
  String pageFavArtistCount({required Object count}) {
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
      'Nach Favorisieren in der NT-App automatisch synchronisiert';

  @override
  String get pageFavLoginTitle => 'Anmelden, um Favoriten anzusehen';

  @override
  String get pageFavLoginDesc =>
      'Per QR bei NT anmelden, Favoriten synchronisieren';

  @override
  String get pageFavKgCreated => 'Erstellte Wiedergabelisten';

  @override
  String get pageFavKgCollectedPlaylist => 'Gespeicherte Wiedergabelisten';

  @override
  String get pageFavKgCollectedAlbum => 'Gespeicherte Alben';

  @override
  String pageFavKgCreatedCount({required Object count}) {
    return '$count erstellte Wiedergabelisten';
  }

  @override
  String get pageFavKgCreatedLoginHint =>
      'Melde dich an, um deine erstellten Wiedergabelisten zu sehen';

  @override
  String pageFavKgCollectedPlaylistCount({required Object count}) {
    return '$count gespeicherte Wiedergabelisten';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'Melde dich an, um deine gespeicherten Wiedergabelisten zu sehen';

  @override
  String pageFavKgCollectedAlbumCount({required Object count}) {
    return '$count gespeicherte Alben';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint =>
      'Melde dich an, um deine gespeicherten Alben zu sehen';

  @override
  String get pageFavKugouLoginDesc =>
      'Per QR bei KG anmelden, um erstellte/gespeicherte Wiedergabelisten und Alben zu synchronisieren';

  @override
  String get pageFavKugouEmptyHint =>
      'Wird automatisch synchronisiert, wenn du in der KG-App favorisierst';

  @override
  String pageSearchLoadingTrack({required Object title}) {
    return 'Lade: $title';
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
      'Zum Anmelden, um KG-»Gefällt mir« zu synchronisieren';

  @override
  String get pageLikedNeteaseLoginHint =>
      'Zum Anmelden, um NT-Favoriten zu synchronisieren';

  @override
  String get pageLikedLoadFailed =>
      'Gefällt-mir-Liste konnte nicht geladen werden';

  @override
  String get pageLikedEmpty => 'Noch keine Lieblingstitel';

  @override
  String get pageLikedKugouEmptyHint =>
      'Nach »Gefällt mir« in der KG-App automatisch synchronisiert';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'Nach Herz in der NT-App automatisch synchronisiert';

  @override
  String get toastQqLikeSyncFailed =>
      'Synchronisierung der QQ-Music-Online-Favoriten fehlgeschlagen (experimentelle API); die Herz-Änderung wurde rückgängig gemacht';

  @override
  String get pageLikedQqHint =>
      'QQ-Music-Herzen werden lokal gespeichert und sind immer verfügbar; nach der Anmeldung können Online-Favoriten experimentell synchronisiert werden';

  @override
  String get pageLikedQqEmptyTitle => 'Noch keine QQ-Music-Lieblingstitel';

  @override
  String get pageLikedQqEmptyHint =>
      'Markiere ein QQ-Music-Lied in Suche oder Wiedergabe mit »Gefällt mir«, damit es hier erscheint (wird lokal gespeichert)';

  @override
  String get pageLikedQqLoginSync =>
      'Bei QM anmelden, um Online-Favoriten zu synchronisieren (experimentell)';

  @override
  String get pageLikedQqSyncOnline =>
      'Online-Favoriten synchronisieren (experimentell)';

  @override
  String pageLikedQqSynced({required Object count}) {
    return 'Online-Favoriten synchronisiert: $count neue Titel hinzugefügt';
  }

  @override
  String get pageLikedQqSyncedNone =>
      'Bereits synchronisiert - keine neuen Online-Favoriten';

  @override
  String get pageLikedLoginTitle => 'Anmelden, um Lieblingstitel anzusehen';

  @override
  String get pageLikedKugouLoginDesc =>
      'Per QR bei KG anmelden, »Gefällt mir« synchronisieren';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'Per QR bei NT anmelden, Herzen synchronisieren';

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
  String libraryStatTrackCount({required Object count}) {
    return '$count Titel';
  }

  @override
  String libraryScanDirCount({required Object count}) {
    return '$count Ordner';
  }

  @override
  String libraryHoursMinutes({required Object h, required Object m}) {
    return '$h Std. $m Min.';
  }

  @override
  String libraryMinutes({required Object m}) {
    return '$m Min.';
  }

  @override
  String librarySeconds({required Object s}) {
    return '$s Sek.';
  }

  @override
  String get librarySearchHint => 'Lokale Titel suchen';

  @override
  String get libraryNoMatch => 'Keine passenden Titel';

  @override
  String get libraryScanningFiles => 'Dateien werden gezählt…';

  @override
  String libraryTrackCount({required Object count, required Object extra}) {
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
  String get menuRemoveFromLibrary => 'Aus Bibliothek entfernen';

  @override
  String get playerBarCollapsePlayer => 'Player minimieren';

  @override
  String get playerBarExitFullscreen => 'Vollbild beenden';

  @override
  String get playerBarFullscreen => 'Vollbild';

  @override
  String get playerBarHideLyrics => 'Text ausblenden';

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
  String get pageHomeDailyLoginHint => 'Bei NT anmelden für tägliche Updates';

  @override
  String get pageHomeDailyPlay => 'Heutige Empfehlung abspielen';

  @override
  String get pageHomeDailyLogin => 'Anmelden zum Freischalten';

  @override
  String pageHomeSpotlightTitle({required Object song}) {
    return 'Start mit $song';
  }

  @override
  String pageHomeSpotlightSubtitle({required Object count}) {
    return '$count Titel zufällig gewählt';
  }

  @override
  String get pageHomeSpotlightShuffle => 'Neu mischen';

  @override
  String get pageHomeSpotlightEmpty => 'Nichts zum Abspielen';

  @override
  String pageHomeGreeting({required Object greeting, required Object name}) {
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
  String downloadSelectedCount({required Object count}) {
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
  String downloadActiveCount({required Object count}) {
    return 'Aktiv $count';
  }

  @override
  String downloadDoneCount({required Object count}) {
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
  String downloadDeleteSelectedTitle({required Object count}) {
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
  String downloadStatusRunning({
    required Object percent,
    required Object received,
    required Object speed,
  }) {
    return 'Herunterladen $percent% ($received) $speed';
  }

  @override
  String downloadStatusRunningNoPercent({required Object speed}) {
    return 'Herunterladen…$speed';
  }

  @override
  String downloadStatusPausedWith({required Object received}) {
    return 'Pausiert ($received)';
  }

  @override
  String get downloadStatusPaused => 'Pausiert';

  @override
  String downloadStatusFailed({required Object error}) {
    return 'Fehlgeschlagen: $error';
  }

  @override
  String get downloadStatusCanceled => 'Abgebrochen';

  @override
  String downloadStatusDone({required Object size}) {
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
  String get settingsSearchHint => 'Einstellungen suchen…';

  @override
  String settingsSearchNoResult({required Object query}) {
    return 'Keine Einstellungen für「$query」gefunden';
  }

  @override
  String settingsSearchMatchCount({required Object count}) {
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
  String get settingsAccentDefaultTooltip => 'Standard-Grau';

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
  String get settingsFontMiSansLabel => 'MiSans';

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
  String settingsCoverRadiusPx({required Object radius}) {
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
  String get settingsOutputDevice => 'Audioausgabegerät';

  @override
  String get settingsOutputDeviceSectionNote =>
      'Audio über ein bestimmtes Gerät ausgeben. Der Wechsel wirkt sofort bzw. ab dem nächsten Titel (kein Neustart nötig) und die Wahl wird gespeichert. Es wird nur bei expliziter Auswahl umgeschaltet; die App leitet niemals selbst um.';

  @override
  String get settingsOutputDeviceDefault => 'Systemstandard';

  @override
  String get settingsOutputDeviceDefaultDesc =>
      'Folgt der aktuellen Systemausgabe (keine automatische Umleitung)';

  @override
  String settingsOutputDeviceFormat({
    required Object channels,
    required Object rate,
  }) {
    return '$rate Hz · $channels Kanäle';
  }

  @override
  String get settingsOutputDeviceDefaultTag => 'Standard';

  @override
  String get settingsOutputDeviceLoadFailed =>
      'Audioausgabegeräte konnten nicht aufgelistet werden (Engine nicht verfügbar? Systemstandard bleibt aktiv).';

  @override
  String get settingsOutputDeviceHfpNote =>
      'Dieses Gerät läuft gerade in einem niedrigen Qualitätsmodus (z. B. Bluetooth-Freisprechen/HFP, meist 16 kHz mono). Die Engine gibt im nativen Format des Geräts aus, wodurch die Klangqualität eingeschränkt ist.';

  @override
  String get settingsOutputDeviceA2dpGuideTitle =>
      'Bluetooth A2DP (hohe Audioqualität) aktivieren';

  @override
  String get settingsOutputDeviceA2dpGuideDesc =>
      '1. Trennen Sie die Verbindung zum Bluetooth-Headset und verbinden Sie es erneut.\n2. Stellen Sie das Gerät in den Bluetooth-Systemeinstellungen auf „Audio/A2DP“ (auf manchen Systemen „Media-Audio“ genannt).\n3. Erscheint weiterhin nur Headset/Freisprechen, heben Sie die Kopplung auf und koppeln Sie das Gerät neu.\nDie genauen Menüs unterscheiden sich je nach System.';

  @override
  String get settingsOutputDeviceCallBadge => 'Anruf / niedrige Qualität';

  @override
  String get settingsOutputDeviceCallConfirmTitle =>
      'Musik über ein Anruf-Qualitätsgerät ausgeben?';

  @override
  String get settingsOutputDeviceCallConfirmDesc =>
      'Dieses Gerät gibt in Anruf-/Niedrigqualität aus: Musik wird fast zerstört (Freisprech-Audio). Die meisten Kopfhörer nutzen diesen Modus nicht für Musik, manche lehnen ihn bewusst ab — Stille oder Fehlverhalten möglich. Hochwertige Ausgabe (A2DP usw.) wird dringend empfohlen. Die App leitet niemals selbst um; dies gilt nur bei expliziter Auswahl.';

  @override
  String get settingsOutputDeviceUseQuality =>
      'Auf hochwertige Ausgabe wechseln';

  @override
  String get settingsOutputDeviceUseCall => 'Trotzdem verwenden';

  @override
  String get settingsOutputDeviceDefaultIsCall =>
      'Die Systemstandard-Ausgabe ist ein Anruf-/Niedrigqualitätsgerät (z. B. Freisprechen HFP). Musik würde fast zerstört; manche Kopfhörer lehnen dieses Profil bewusst ab (ggf. Stille oder Fehlverhalten). Wechseln Sie zu einer hochwertigen Ausgabe.';

  @override
  String get settingsOutputDeviceDefaultRowCallNote =>
      'Diese Wahl leitet Musik über den Anruf-/Niedrigqualitäts-Standard — der Klang wird fast zerstört. Nicht empfohlen.';

  @override
  String settingsOutputDeviceShowAll({required int count}) {
    return 'Alle Geräte anzeigen ($count)';
  }

  @override
  String get settingsOutputDeviceHideUnused => 'Nur nutzbare anzeigen';

  @override
  String get settingsOutputDeviceUnavailable => 'Nicht verfügbar';

  @override
  String get settingsOutputDeviceVirtualTag => 'Virtuell';

  @override
  String settingsSinkChangedFailed({required Object err}) {
    return 'Ausgabegerät konnte nicht gewechselt werden: $err';
  }

  @override
  String get settingsEngine => 'Dekodierungs-Engine';

  @override
  String get settingsEngineNote =>
      'Die Audio-Decode-Engine wird beim App-Start geladen; Änderungen greifen erst nach einem Kaltstart.';

  @override
  String get settingsEngineStableDesc =>
      'FFmpeg-Dekodierungskern. Ausgereift und die Standardwahl.';

  @override
  String get settingsEngineEraAudioDesc =>
      'Eigener Dekodierungskern. Neu; Leistung und Speicher werden noch benchmarkt.';

  @override
  String get settingsEngineExperimental => 'Experimentell';

  @override
  String get settingsEngineEraAudioNote =>
      'Experimenteller Kern: Leistung und Speicherbedarf werden noch gemessen; einzelne Formate oder Geräte können Probleme bereiten. Bei Problemen hier zurück auf Stable wechseln.';

  @override
  String get settingsEngineRestartTitle => 'Neustart erforderlich';

  @override
  String get settingsEngineRestartDesc =>
      'Die Engine-Wahl ist gespeichert. Die Engine wird beim App-Start geladen; starten Sie die App neu, um die Engine zu wechseln. Bis dahin läuft die aktuelle Engine weiter; Wiedergabe und Downloads werden während des Neustarts unterbrochen.';

  @override
  String get settingsEngineRestartNow => 'Jetzt neu starten';

  @override
  String get settingsEngineRestartLater => 'Später';

  @override
  String get settingsMemoryPlaySection => 'Wiedergabespeicher';

  @override
  String get settingsMemoryPlayTitle =>
      'Speicherwiedergabe (kein Decode-Cache auf Platte)';

  @override
  String get settingsMemoryPlayOn =>
      'Dekodiertes PCM bleibt im Speicher; keine stream.wav/stream.pcm';

  @override
  String get settingsMemoryPlayOff =>
      'Dateimodus: dekodiertes PCM wird auf Platte geschrieben (alt)';

  @override
  String get settingsMemoryFileModeNote =>
      'Aus = Engine schreibt stream.wav/stream.pcm (Dateimodus). Gilt ab dem nächsten Titel.';

  @override
  String get settingsMemoryPolicyAuto => 'Auto (nach verfügbarem Speicher)';

  @override
  String get settingsMemoryPolicyAutoSub =>
      '32 MiB harte Obergrenze; passt sich an freien RAM an';

  @override
  String get settingsMemoryPolicyLimit => 'Eigene Obergrenze';

  @override
  String get settingsMemoryPolicyUnlimited => 'Unbegrenzt';

  @override
  String get settingsMemoryPolicyUnlimitedSub =>
      'Gesamten dekodierten Titel im RAM halten; mit ausdrücklicher Warnung';

  @override
  String get settingsMemoryLimitTitle => 'Speicherlimit für dekodiertes PCM';

  @override
  String get settingsMemoryLimitHint => 'MB (48 kHz Stereo ≈ 0,38 MB/s)';

  @override
  String get settingsMemoryConfirm => 'Bestätigen';

  @override
  String get settingsMemoryCancel => 'Abbrechen';

  @override
  String get settingsMemoryUnlimitedWarnTitle =>
      'Gesamtes dekodiertes PCM im Speicher halten?';

  @override
  String get settingsMemoryUnlimitedWarnBody =>
      'Lange Titel können Hunderte MB bis mehrere GB RAM belegen (≈0,38 MB/s bei 48 kHz Stereo). Das kann den Rechner verlangsamen, die App unter Speicherdruck vom System beenden lassen oder das System instabil machen. Fortfahren?';

  @override
  String get memoryAlertTitle =>
      'Zu wenig Speicher · reine Speicherwiedergabe nicht verfügbar';

  @override
  String get memoryAlertActionStop => 'Stoppen';

  @override
  String get memoryAlertActionOnlineDirect => 'Online-Direktwiedergabe';

  @override
  String get memoryAlertOnlineDesc =>
      'Fortfahren nutzt die Online-Direktwiedergabe (Engine-Netzwerk). Andernfalls wird diese Wiedergabe gestoppt.';

  @override
  String get memorySourceFailNotHttp =>
      'Online-Quelle ist kein http(s)-Direktlink';

  @override
  String memorySourceFailIsolateSpawn({required Object error}) {
    return 'Speicherquellen-Worker konnte nicht starten: $error';
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
    return 'Gesamtinhalt ($content) überschreitet das Ganz-Titel-Limit für reinen Speicher ($limit)';
  }

  @override
  String memorySourceFailGrewCeiling({
    required Object got,
    required Object limit,
  }) {
    return 'Download überschritt unterwegs das Ganz-Titel-Limit für reinen Speicher ($got > $limit)';
  }

  @override
  String get memorySourceFailEmpty => 'Inhalt ist leer (0 Byte)';

  @override
  String get memorySourceFailSegOom =>
      'Zuweisung der Speicherquelle fehlgeschlagen (kein Speicher)';

  @override
  String get memorySourceFailSegFill =>
      'Schreiben in die Speicherquelle fehlgeschlagen';

  @override
  String memorySourceFailSegFillEx({required Object error}) {
    return 'Ausnahme beim Schreiben in die Speicherquelle: $error';
  }

  @override
  String memorySourceFailDownload({required Object error}) {
    return 'Download fehlgeschlagen: $error';
  }

  @override
  String get memorySourceFailUnknown => 'Unbekannter Grund';

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
  String settingsSpectrumBarWidthDesc({required Object width}) {
    return '${width}px（1~12, Vollbild-Player）';
  }

  @override
  String get settingsBarSpectrum => 'Spektrum der Playerleiste';

  @override
  String get settingsSpectrumStyle => 'Spektrum-Stil';

  @override
  String get settingsSpectrumStyleDesc =>
      'Spektrum-Visualisierung (Balken / Welle / Welle nach oben)';

  @override
  String get settingsSpectrumStyleBars => 'Balken';

  @override
  String get settingsSpectrumStyleWave => 'Welle';

  @override
  String get settingsSpectrumStyleWaveUp => 'Welle oben';

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
  String get settingsPlayerBackground => 'Player-Hintergrund';

  @override
  String get settingsPlayerBackgroundDesc =>
      'Hintergrundstil des Vollbild-Players';

  @override
  String get settingsPlayerBgGradient => 'Verlauf';

  @override
  String get settingsPlayerBgBlur => 'Weichzeichnen';

  @override
  String get settingsPlayerBgSolid => 'Einfarbig';

  @override
  String get settingsPlayerBgRipple => 'Wasserwelle';

  @override
  String get settingsPlayerBgRippleSpeed => 'Wellengeschwindigkeit';

  @override
  String settingsPlayerBgRippleSpeedDesc({required Object speed}) {
    return 'Fließgeschwindigkeit $speed';
  }

  @override
  String get settingsPlayerBgFluid => 'Fluid';

  @override
  String get settingsPlayerBgFlowSpeed => 'Fließgeschwindigkeit';

  @override
  String settingsPlayerBgFlowSpeedDesc({required Object speed}) {
    return 'Fließgeschwindigkeit $speed';
  }

  @override
  String get settingsPlayerBgRenderScale => 'Render-Skalierung';

  @override
  String settingsPlayerBgRenderScaleDesc({required Object scale}) {
    return 'Auflösung $scale× (niedriger spart Strom)';
  }

  @override
  String get settingsPlayerBgFps => 'Bildratenlimit';

  @override
  String settingsPlayerBgFpsDesc({required Object fps}) {
    return '$fps FPS';
  }

  @override
  String get settingsPlayerBgFreezeOnPause => 'Bei Pause einfrieren';

  @override
  String get settingsPlayerBgFreezeOnPauseOn =>
      'Hintergrund friert bei Pause ein';

  @override
  String get settingsPlayerBgFreezeOnPauseOff =>
      'Hintergrund fließt bei Pause weiter';

  @override
  String get settingsPlayerBgBeat => 'Bass-Puls';

  @override
  String get settingsPlayerBgBeatOn => 'Hintergrund pulsiert mit dem Bass';

  @override
  String get settingsPlayerBgBeatOff =>
      'Hintergrund pulsiert nicht mit dem Takt';

  @override
  String get settingsAdaptiveRenderQuality => 'Adaptive Renderqualität';

  @override
  String get settingsAdaptiveRenderQualityOn =>
      'Player-Hintergrund-Auflösung bei langsamen Frames verringern';

  @override
  String get settingsAdaptiveRenderQualityOff =>
      'Player-Hintergrund wird immer in voller Auflösung gerendert';

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
  String settingsLyricFontSizeDesc({required Object size}) {
    return '${size}px（aktuelle Zeile vergrößert）';
  }

  @override
  String get settingsLyricLineHeight => 'Songtext-Zeilenhöhe';

  @override
  String get settingsLyricPlayedColor => 'Abgespielte Farbe';

  @override
  String get settingsLyricPlayedColorDesc =>
      'Hervorhebungsfarbe für aktuelle Songtextzeile';

  @override
  String get settingsLyricFollowAccent => 'Akzentfarbe folgen';

  @override
  String get settingsLyricFollowAccentDesc =>
      'Akzentfarbe der App für die Hervorhebung der aktuellen Zeile verwenden';

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
  String get settingsDjEnhanced => 'Erweiterte Filterung';

  @override
  String get settingsDjEnhancedDesc =>
      'Überspringt zusätzlich Remix / Nightcore / sped up / slowed / Mashup usw.';

  @override
  String get settingsDjCustom => 'Eigene Skip-Schlüsselwörter';

  @override
  String get settingsDjCustomHint =>
      'Durch Komma oder Zeilenumbruch getrennt, z. B. Cover, Karaoke';

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
  String get settingsUnloadAllMemory =>
      'Beim Minimieren den gesamten Speicherzustand entladen';

  @override
  String get settingsUnloadAllMemorySubtitle =>
      'Im Hintergrund (Minimiert/Tray/Bildschirm aus) Seitendaten und Caches verwerfen; beim Zurückkehren neu aufbauen (evtl. zurück zur Startseite, Scrollposition verloren). Wiedergabe unbeeinflusst';

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
  String settingsDownloadQualityDesc({required Object quality}) {
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
  String settingsDownloadConcurrentDesc({required Object count}) {
    return '$count parallele Aufgaben（1~5）';
  }

  @override
  String get settingsDownloadGrouping => 'Ordner-Gruppierung';

  @override
  String get settingsGroupingFlat => 'Alles flach im Download-Ordner';

  @override
  String get settingsGroupingPlatform => 'Unterordner nach Plattform（KG / NT）';

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
  String settingsSpeedLimited({required Object speed}) {
    return 'Auf $speed begrenzt, sofort wirksam';
  }

  @override
  String get settingsSpeedUnlimitedLabel => 'Unbegrenzt';

  @override
  String settingsSpeedMbps({required Object speed}) {
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
  String settingsDownloadHistoryDesc({required Object count}) {
    return '$count Einträge（10~500）· über Limit automatisch älteste entfernen';
  }

  @override
  String settingsDownloadHistoryCount({required Object count}) {
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
      'Gerätekennung für KG-/NT-Downloads; beim ersten Start erzeugt und dauerhaft stabil, je Nutzer einzigartig.';

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
      'Nach dem Zurücksetzen erscheint dieser Rechner bei KG / NT als neues Gerät; Sitzungen unter dem alten Fingerprint könnten ungültig werden. Jetzt zurücksetzen?';

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
  String get settingsHistoryDb => 'Wiedergabeverlauf-Datenbank';

  @override
  String get settingsHistoryDbLabel => 'Pfad der Verlaufsdatenbank';

  @override
  String get settingsHistorySection => 'Wiedergabeverlauf';

  @override
  String get settingsHistoryNote =>
      'Der Wiedergabeverlauf wird in einer eigenen history.db gespeichert (getrennt von der Musikbibliothek). Beim Deaktivieren bleiben vorhandene Einträge erhalten; ohne Begrenzung wächst die Datenbank unbegrenzt und kann die Verlaufsseite verlangsamen.';

  @override
  String get settingsHistoryEnabled => 'Wiedergabeverlauf aufzeichnen';

  @override
  String get settingsHistoryEnabledOn =>
      'Aufzeichnung aktiv — Einträge nach Wiedergabe schreiben';

  @override
  String get settingsHistoryEnabledOff =>
      'Pausiert — vorhandene Einträge bleiben erhalten';

  @override
  String get settingsHistoryLimit => 'Begrenzung der Verlaufseinträge';

  @override
  String settingsHistoryLimitOn({required Object count}) {
    return 'Bis zu $count Einträge';
  }

  @override
  String get settingsHistoryLimitUnlimited => 'Unbegrenzt';

  @override
  String get settingsHistoryNoLimitConfirmTitle => 'Begrenzung entfernen?';

  @override
  String get settingsHistoryNoLimitConfirmDesc =>
      'Ohne Begrenzung kann der Verlauf unbegrenzt wachsen, Speicherplatz belegen und die Verlaufsseite sowie die App verlangsamen. Trotzdem entfernen?';

  @override
  String get settingsHistoryNoLimitConfirm => 'Unbegrenzt lassen';

  @override
  String get settingsHistoryStats => 'Verlaufsdaten';

  @override
  String get settingsCopy => 'Kopieren';

  @override
  String toastCopied({required Object label}) {
    return '$label kopiert';
  }

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
  String settingsCacheSongs({required Object count}) {
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
  String settingsCacheEntries({required Object count}) {
    return '$count Einträge';
  }

  @override
  String settingsCacheImages({required Object count}) {
    return '$count Bilder';
  }

  @override
  String get settingsCacheRefresh => 'Aktualisieren';

  @override
  String get settingsCacheClear => 'Leeren';

  @override
  String get settingsCacheClearAll => 'Alle leeren';

  @override
  String settingsCacheClearConfirmTitle({required Object name}) {
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
  String toastCacheCleared({required Object name}) {
    return '$name-Cache geleert';
  }

  @override
  String get toastCacheAllCleared => 'Alle Caches geleert';

  @override
  String get settingsLogToFile => 'Logs in Datei schreiben';

  @override
  String get settingsLogToFileOn => 'Logs werden im Ordner logs/ gespeichert';

  @override
  String get settingsLogToFileOff =>
      'Nur Konsole; nichts wird auf die Festplatte geschrieben';

  @override
  String get settingsLogToFileNote =>
      'Einzelne Datei, begrenzt auf 4 MiB (an Ort und Stelle gekürzt; keine zusätzlichen Dateien).';

  @override
  String get settingsSecuritySection => 'Sicheres Vernichten';

  @override
  String get settingsSecurityNote =>
      'Löscht unwiderruflich alle lokalen Anmeldedaten und Sitzungen (Streaming-Server-Passwörter, NT-/KG-Sitzungen, lokale Subsonic-Konten) und macht die Plattform-Tokens ungültig. Bibliothek, Verlauf und Downloads bleiben unberührt.';

  @override
  String get settingsSecurityStreaming => 'Streaming-Server-Anmeldedaten';

  @override
  String settingsSecurityStreamingCount({required Object count}) {
    return '$count Server';
  }

  @override
  String get settingsSecurityStreamingDesc => 'Passwörter und Zugriffstokens';

  @override
  String get settingsSecuritySession => 'Sitzungen von Drittanbieter-Konten';

  @override
  String get settingsSecuritySessionDesc => 'NT-/KG-Anmeldestatus';

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
  String settingsSecurityConfirmTitle({required Object name}) {
    return '„$name“ vernichten?';
  }

  @override
  String get settingsSecurityConfirmAllTitle =>
      'Alle sensiblen Daten vernichten?';

  @override
  String settingsSecurityConfirmDesc({required Object word}) {
    return 'Die Tokens der betroffenen Plattformen werden ungültig gemacht, Dateien werden überschrieben und gelöscht. Dieser Vorgang ist unwiderruflich. Geben Sie „$word“ ein, um zu bestätigen.';
  }

  @override
  String get settingsSecurityConfirmWord => 'vernichten';

  @override
  String settingsSecurityConfirmHint({required Object word}) {
    return '„$word“ eingeben';
  }

  @override
  String toastSecurityDestroyed({required Object name}) {
    return 'Vernichtet: $name';
  }

  @override
  String get toastSecurityAllDestroyed =>
      'Alle sensiblen Daten wurden vernichtet';

  @override
  String toastSecurityDestroyFailed({required Object path}) {
    return 'Vernichten fehlgeschlagen, Datei kann zurückbleiben: $path';
  }

  @override
  String get settingsDeviceBindPrivacyTitle =>
      'Passwortlose Gerätebindung aktivieren?';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      'Eine lokale Gerätekennung (Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID) wird gelesen und an Ihr Tresorgewölbe gebunden; nur lokal gespeichert, niemals hochgeladen. Hinweis: Dieser Vorgang kann nicht zum aktuellen passwortlosen Systemmodus zurückkehren — das spätere Deaktivieren der Gerätebindung führt zum Passwortmodus (Eingabe bei jedem Start).';

  @override
  String get settingsDeviceBindEnable => 'Aktivieren';

  @override
  String get settingsDeviceBindRecoveryTitle =>
      'Wiederherstellungspasswort festlegen (optional)';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      'Nach Gerätewechsel/Neuinstallation werden Anmeldedaten mit dem Wiederherstellungspasswort entsperrt. Leer lassen, um keines festzulegen: nach Gerätewechsel keine Wiederherstellung möglich (Fail-closed; Löschen und Neuaufbau erforderlich).';

  @override
  String get settingsDeviceBindRecoveryHint => 'Wiederherstellungspasswort';

  @override
  String get settingsDeviceBindSkip => 'Ohne Passwort aktivieren';

  @override
  String get settingsDeviceBindChangeRecovery =>
      'Wiederherstellungspasswort festlegen / ändern';

  @override
  String get settingsDeviceBindChangeRecoveryTitle =>
      'Neues Wiederherstellungspasswort festlegen';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      'Das alte Passwort wird sofort ungültig. Merken Sie sich das neue unbedingt: Die Entsperrung der Anmeldedaten nach Gerätewechsel hängt davon ab.';

  @override
  String get settingsDeviceBindRebind => 'Dieses Gerät neu binden';

  @override
  String get settingsDeviceBindRebindDesc =>
      'Mit dem aktuellen Gerätefingerabdruck neu versiegeln; der alte Fingerabdruck wird sofort ungültig (nach Wiederherstellung verwenden)';

  @override
  String get settingsDeviceBindRebindTitle => 'Dieses Gerät neu binden?';

  @override
  String get settingsDeviceBindRebindConfirm => 'Jetzt neu binden';

  @override
  String get settingsDeviceBindClose => 'Gerätebindung deaktivieren';

  @override
  String get settingsDeviceBindCloseDesc =>
      'Geräte-Entropie-Siegel entfernen; Tresor wechselt in den Passwortmodus';

  @override
  String get settingsDeviceBindCloseTitle => 'Gerätebindung deaktivieren?';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      'Das Geräte-Entropie-Siegel wird entfernt und der Tresor wechselt in den Passwortmodus: Ab dann ist bei jeder Sitzung ein Passwort erforderlich. Dieses Passwort wird Ihr neues Sitzungspasswort. Geben Sie zur Bestätigung das aktuelle Wiederherstellungspasswort ein.';

  @override
  String get settingsDeviceBindCloseHint =>
      'Aktuelles Wiederherstellungspasswort';

  @override
  String get settingsDeviceBindRecoveryBanner =>
      'Gerätewechsel oder beschädigte Entropiedatei erkannt: Anmeldedaten gesperrt, Wiederherstellungspasswort erforderlich';

  @override
  String get settingsDeviceBindRecover => 'Wiederherstellen';

  @override
  String get settingsDeviceBindRecoverTitle =>
      'Wiederherstellungspasswort eingeben';

  @override
  String get settingsDeviceBindRecoverDesc =>
      'Entsperren Sie die Anmeldedaten mit dem Wiederherstellungspasswort; nach Erfolg dieses Gerät neu binden, um die passwortlose Entsperrung wiederherzustellen.';

  @override
  String get settingsDeviceBindShowPassword => 'Passwort anzeigen / ausblenden';

  @override
  String get toastDeviceBindEnabled => 'Passwortlose Gerätebindung aktiviert';

  @override
  String get toastDeviceBindRecoverySet =>
      'Wiederherstellungspasswort aktualisiert';

  @override
  String get toastDeviceBindRebound => 'Gerät neu gebunden';

  @override
  String get toastDeviceBindClosed =>
      'Gerätebindung aus; Tresor verwendet jetzt den Passwortmodus';

  @override
  String get toastDeviceBindRecoveryNeeded =>
      'Kein Wiederherstellungspasswort festgelegt; Gerätebindung kann nicht deaktiviert werden';

  @override
  String toastDeviceBindCloseFailed({required Object error}) {
    return 'Deaktivierung fehlgeschlagen: $error';
  }

  @override
  String get toastDeviceBindRecovered =>
      'Anmeldedaten wiederhergestellt; Gerät neu binden, um passwortlos zu entsperren';

  @override
  String get toastDeviceBindRecoverFailed =>
      'Wiederherstellungspasswort falsch oder Entsperrung fehlgeschlagen; Anmeldedaten bleiben gesperrt';

  @override
  String get settingsSchemeIntroTitle => 'Verschlüsselungsverfahren';

  @override
  String get settingsSchemeIntroDesc =>
      'Ihre Anmeldedaten (Cookies) werden durch ein Verschlüsselungsverfahren geschützt. Das LEGACY-Verfahren (empfohlen) ist aktiviert: Der Hauptschlüssel liegt im sicheren Systemspeicher — stabil und zuverlässig. Für stärkeren Schutz können Sie in Einstellungen → Verschlüsselungsverfahren für Anmeldedaten auf Vault (experimentell) wechseln — beachten Sie, dass der Wechsel die Datenbank neu aufbaut und alle Anmeldedaten verliert.';

  @override
  String get settingsSchemeIntroGotIt => 'Verstanden';

  @override
  String get settingsSchemeSection =>
      'Verschlüsselungsverfahren für Anmeldedaten';

  @override
  String get settingsSchemeNote =>
      'Wählen Sie, wie Anmeldedaten verschlüsselt werden. LEGACY: sicherer Systemspeicher, stabil und zuverlässig (empfohlen). FILK (Dateischlüssel): Hauptschlüssel in lokaler secret.key-Datei — kein OS-Schlüsselbund, für headless/Docker (einzelner Schwachpunkt). Vault: experimentelles 2-of-2-Zwei-Faktor-Verfahren — stärkerer Schutz, aber gelegentlicher Cookie-Verlust möglich. Ein Wechsel baut die Datenbank neu auf und erfordert eine erneute Anmeldung.';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => 'Empfohlen';

  @override
  String get settingsSchemeCryptoDesc =>
      'Cookies werden durch den sicheren Systemspeicher verschlüsselt (Windows DPAPI / macOS Schlüsselbund / Linux libsecret). Stabil und zuverlässig.';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'LEGACY-Verfahren: Der Hauptschlüssel wird vollständig durch den sicheren Systemspeicher geschützt. Ausgewogene Sicherheit und Stabilität für den täglichen Gebrauch.';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => 'Kompatibel';

  @override
  String get settingsSchemeFileDesc =>
      'Hauptschlüssel liegt in einer lokalen Datei (secret.key, 0600). Kein OS-Schlüsselbund nötig — für headless Linux / Docker. Einzelner Schwachpunkt: Wenn die Schlüsseldatei ausläuft, sind alle Anmeldedaten offengelegt.';

  @override
  String get settingsSchemeFileModeDesc =>
      'FILK (Dateischlüssel)-Verfahren: Der Hauptschlüssel wird in secret.key (0600, atomares Schreiben) abgelegt — die klassische serverseitige Verschlüsselungsform. Nur ohne OS-Schlüsselbund (headless/Docker) verwenden.';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => 'Experimentell';

  @override
  String get settingsSchemeVaultDesc =>
      '2-of-2-Zwei-Faktor-Verschlüsselung (Systemanteil + Benutzeranteil, beide erforderlich). Stärker gegen Offline-Angriffe, aber Cookies können bei Anomalien verloren gehen.';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Vault-Verfahren: Der Hauptschlüssel wird in einen System- und einen Benutzeranteil geteilt — beide erforderlich. Wählen Sie v1 Systemschutz / v2 Passwort / v3 Gerätebindung als Versiegelungsstufe.';

  @override
  String get settingsSchemeSwitchTitle => 'Verschlüsselungsverfahren wechseln?';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault ist experimentell: Nach dem Wechsel können Cookies verloren gehen.';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'FILK ist ein Kompatibilitäts-Fallback: Der Hauptschlüssel liegt in einer lokalen Datei. Läuft diese aus, sind alle Anmeldedaten offengelegt. Nur für headless/Docker ohne OS-Schlüsselbund gedacht.';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      'Die Verfahren verwenden inkompatible verschlüsselte Strukturen. Der Wechsel zerstört das aktuelle Tresorgewölbe und baut die Datenbank neu auf; alle Anmeldedaten (NT / KG / Streaming-Konten) gehen verloren und erfordern eine erneute Anmeldung.';

  @override
  String get settingsSchemeSwitchKeep => 'Aktuelles beibehalten';

  @override
  String get settingsSchemeSwitchConfirm => 'Wechseln und neu aufbauen';

  @override
  String get toastSchemeSwitched =>
      'Verschlüsselungsverfahren gewechselt; wirksam nach Neustart';

  @override
  String get settingsVaultModeV1 => 'v1 Systemschutz';

  @override
  String get settingsVaultModeV2 => 'v2 Passwort';

  @override
  String get settingsVaultModeV3 => 'v3 Gerätebindung';

  @override
  String get settingsVaultModeDescOs =>
      'v1 Systemschutz: Anmeldedaten werden durch den sicheren Systemspeicher verschlüsselt (Windows DPAPI / macOS Schlüsselbund / Linux libsecret), auf diesem Gerät passwortlos.';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 Passwortschutz: Anmeldedaten werden durch ein Passwort verschlüsselt, das bei jedem Start eingegeben wird. Sie können jederzeit zum Systemschutz (v1) zurückkehren.';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 Gerätebindung: auf diesem Gerät passwortlos; nach Gerätewechsel ist ein Wiederherstellungspasswort erforderlich. Ein direkter Rückstieg auf v1 ist nicht möglich — beim Deaktivieren fällt es auf den Passwortmodus v2 zurück.';

  @override
  String get settingsVaultModeDescUnknown =>
      'Verschlüsselungsstufe wird gelesen…';

  @override
  String get settingsVaultSwitchToPasswordTitle =>
      'Zu Passwortschutz (v2) wechseln';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      'Anmeldedaten werden durch ein bei jedem Start eingegebenes Passwort geschützt. Hauptschlüssel und vorhandene Daten bleiben erhalten; Sie können jederzeit zum Systemschutz (v1) zurückkehren.';

  @override
  String get settingsVaultSwitchToPasswordNewHint => 'Neues Passwort festlegen';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint =>
      'Neues Passwort erneut eingeben';

  @override
  String get settingsVaultSwitchToPasswordMismatch =>
      'Die beiden Eingaben stimmen nicht überein';

  @override
  String get settingsVaultSwitchToOsTitle => 'Zurück zum Systemschutz (v1)';

  @override
  String get settingsVaultSwitchToOsDesc =>
      'Anmeldedaten werden durch den sicheren Systemspeicher geschützt; kein Passwort erforderlich. Sie können jederzeit zum Passwortschutz (v2) zurückkehren.';

  @override
  String get settingsVaultNeedUnlockFirst =>
      'Der Passwortschutz ist noch nicht entsperrt: zuerst entsperren, dann wechseln';

  @override
  String get settingsVaultV3NoDirectV1 =>
      'Gerätebindung (v3) kann nicht direkt auf v1 zurückgestuft werden: zuerst die Gerätebindung deaktivieren, um auf den Passwortmodus v2 zu fallen';

  @override
  String get settingsVaultCloseV3PasswordTitle =>
      'Gerätebindung deaktivieren: Neues Passwort festlegen';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      'Bei Aktivierung der Gerätebindung wurde kein Wiederherstellungspasswort festgelegt (auf diesem Gerät passwortlos). Beim Deaktivieren wird auf Passwortschutz (v2) umgestellt: Legen Sie ein neues Entsperrungspasswort fest. Hauptschlüssel und vorhandene Daten bleiben erhalten; dieses Passwort ist bei jedem Start erforderlich.';

  @override
  String get toastVaultSwitchedToPassword =>
      'Zu Passwortschutz (v2) gewechselt';

  @override
  String get toastVaultSwitchedToOs =>
      'Zurück zum Systemschutz (v1) gewechselt';

  @override
  String get settingsVaultShareBrokenBanner =>
      'Anteile des Tresors stimmen nicht überein: Speicher-Backend abweichend oder Anteil fehlt. Lokale Anmeldedaten können nicht entschlüsselt werden. Bauen Sie das Tresorgewölbe neu auf und melden Sie sich erneut an.';

  @override
  String get settingsVaultShareBrokenRebuild => 'Tresor neu aufbauen';

  @override
  String get settingsVaultRestartTitle => 'Neustart erforderlich';

  @override
  String get settingsVaultRestartDesc =>
      'Die Verschlüsselungsstufe wurde erfolgreich gewechselt. Starten Sie die App neu, um die Datenbankintegrität und einen konsistenten Zustand aller Module sicherzustellen. Im Passwortmodus (v2) wird nach dem Neustart Ihr Passwort abgefragt; bis zur Entsperrung sind Anmeldung und Streaming-Anmeldedaten nicht verfügbar (als abgemeldet angezeigt). Wiedergabe und Downloads werden während des Neustarts unterbrochen.';

  @override
  String get settingsVaultRestartNow => 'Jetzt neu starten';

  @override
  String get settingsVaultRestartLater => 'Später';

  @override
  String get vaultCrashTitle => 'Anmeldedatenmodul abnormal beendet';

  @override
  String get vaultCrashDesc =>
      'Der Prozess des Anmeldedaten-Tresors wurde unerwartet beendet. Lokale Anmeldedaten wurden möglicherweise offengelegt. Melden Sie sich erneut an oder löschen Sie den Tresor, um die Anmeldedaten neu aufzubauen.';

  @override
  String get vaultCrashReset => 'Löschen und neu aufbauen';

  @override
  String get vaultCrashDismiss => 'OK';

  @override
  String get vaultVersionTitle => 'Anormale Version des Anmeldedaten-Tresors';

  @override
  String get vaultVersionDesc =>
      'Anomalie in der Anmeldedaten-Tresor-Komponente erkannt: Die Binärkopie wurde möglicherweise ersetzt oder stammt aus einem nicht offiziellen Build, wodurch lokale Anmeldedaten offengelegt worden sein könnten. Die anormale Kopie wurde gelöscht und die Entschlüsselung verweigert. Beenden und installieren Sie die App neu.';

  @override
  String get vaultVersionExit => 'Beenden';

  @override
  String get vaultVersionReasonReplaced =>
      'Ersetzte Tresor-Binärdatei oder nicht offizieller Build erkannt; anormale Kopie gelöscht und Entschlüsselung verweigert.';

  @override
  String get vaultVersionReasonMarkerMissing =>
      'Der Handshake des Tresors enthält keinen offiziellen Build-Marker.';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'Der Build-Marker des Tresors stimmt nicht mit dem offiziellen Artefakt überein; anormale Kopie gelöscht und Entschlüsselung verweigert.';

  @override
  String get vaultUnlockTitle => 'Anmeldedaten-Tresor entsperren';

  @override
  String get vaultUnlockDesc =>
      'Der Anmeldedaten-Tresor befindet sich im Passwortmodus (v2). Geben Sie das Passwort ein, um lokale Anmeldedaten und Streaming-Konten zu entsperren.';

  @override
  String get vaultUnlockHint => 'Passwort';

  @override
  String get vaultUnlockConfirm => 'Entsperren';

  @override
  String get vaultUnlockSkip => 'Später';

  @override
  String get vaultUnlockFailed => 'Passwort falsch, bitte erneut versuchen';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsVersionUnknown => 'v unbekannt · Flutter Desktop';

  @override
  String settingsVersionFormat({required Object version}) {
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
  String get settingsNeverTap => 'Nicht antippen';

  @override
  String get easterEggGateTitle => 'Warnung';

  @override
  String get easterEggGateBody =>
      'Dieses Programm ausführen? Falls es irreversible Folgen hat, kannst du die Software schließen.';

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
  String get settingsDeclineLicenseTitle =>
      '2. Open-Source-Lizenz & Quellcode\n';

  @override
  String get settingsDeclineLicenseBody =>
      'Diese Software wird unter der GNU Affero General Public License Version 3 (AGPL-3.0) veröffentlicht. Im Rahmen dieser Lizenz dürfen Sie diese Software frei ausführen, untersuchen, verändern und weiterverbreiten, sofern Sie: die Urheberrechts- und Lizenzhinweise beibehalten; Ihre abgeleiteten Werke unter derselben Lizenz veröffentlichen; und, wenn Sie die Funktionalität dieser Software (einschließlich geänderter Versionen) Nutzern über ein Netzwerk bereitstellen, diesen Nutzern den entsprechenden vollständigen Quellcode zur Verfügung stellen. Dieses Projekt bietet keine Closed-Source-kommerzielle Lizenzierung außerhalb der AGPL-Pflichten an. Die vollständigen Bedingungen richten sich nach der beiliegenden LICENSE-Datei und https://www.gnu.org/licenses/agpl-3.0.html.\n\n';

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
  String get settingsDeclineLoginTitle => '5. Anmeldung & Konto\n';

  @override
  String get settingsDeclineLoginBody =>
      'Diese Software bietet QR-Code-Anmeldung (scannen Sie den von dieser Software angezeigten QR-Code mit der offiziellen App der jeweiligen Plattform) und Anmeldung mit Zugangsdaten, um Favoriten und Wiedergabelisten zu synchronisieren und Funktionen freizuschalten. Bitte beachten Sie:\n· Der QR-Code wird von der offiziellen Schnittstelle der jeweiligen Plattform erzeugt; diese Software erfasst, analysiert oder übermittelt Ihren Anmelde-QR-Code, Ihr Konto, Ihr Passwort oder Ihren SMS-Bestätigungscode nicht an Dritte;\n· Nach der Anmeldung erhaltene Sitzungsnachweise (Cookies / Token usw.) werden nur lokal gespeichert (verschlüsselt im Anmeldedaten-Tresor) und niemals an den Entwickler oder einen Nicht-Plattform-Server hochgeladen;\n· Die QR-Anmeldung bedeutet, dass Sie dieser Software erlauben, mit Ihrem Konto auf die Plattform zuzugreifen; Aktionen wie Favorisieren, Abspielen und Kommentieren wirken sich tatsächlich auf Ihr Konto aus;\n· Bewahren Sie Gerät und Systemkonto sicher auf; melden Sie sich auf öffentlichen oder gemeinsam genutzten Geräten anschließend umgehend ab und löschen Sie die Anmeldedaten;\n· Die Plattform kann gegenüber Anmeldungen von Drittanbieter-Clients Risikokontrollen, Einschränkungen oder Sperren verhängen; daraus entstehende Kontoanomalien oder eingeschränkte Funktionen liegen in Ihrer Verantwortung.\n\n';

  @override
  String get settingsDeclineThirdPartyTitle => '7. Dienste Dritter & Risiken\n';

  @override
  String get settingsDeclineThirdPartyBody =>
      'Die Schnittstellen, Authentifizierungsmethoden und die Verfügbarkeit von Online-Musikplattformen werden allein von den Plattformen bestimmt und können sich jederzeit ändern, eingeschränkt oder eingestellt werden, was zu Anmeldefehlern, nicht verfügbaren Funktionen oder nicht synchronisierten Daten führen kann; diese Software wird wie besehen bereitgestellt und übernimmt keine Zusicherung hinsichtlich der fortgesetzten Verfügbarkeit, Stabilität oder Datenintegrität von Diensten Dritter.\n\n';

  @override
  String get settingsDeclineMinorTitle => '8. Nutzung durch Minderjährige\n';

  @override
  String get settingsDeclineMinorBody =>
      'Diese Software ist ein Allzweckwerkzeug und nicht für Minderjährige konzipiert, noch erhebt sie personenbezogene Daten von ihnen. Wenn Sie minderjährig sind, lesen Sie diese Erklärung bitte in Begleitung und unter Anleitung eines Erziehungsberechtigten, holen Sie deren Einwilligung ein und verwenden Sie diese Software erst danach; planen Sie Ihre Zeit bitte vernünftig und vermeiden Sie übermäßige Nutzung.\n\n';

  @override
  String get settingsDecline5Title => '8. Haftungsausschluss\n';

  @override
  String get settingsDecline5Body =>
      'Diese Software wird「wie besehen」ohne ausdrückliche oder stillschweigende Garantien bereitgestellt. Alle direkten oder indirekten Verluste, die durch die Nutzung oder Unmöglichkeit der Nutzung oder durch Änderungen der Online-Plattform-Schnittstellen, Kontoeinschränkungen, abgelaufene Anmeldenachweise, Risikokontrollen oder Sperren von Konten oder Funktionsausfälle entstehen, trägt der Nutzer.\n\n';

  @override
  String get settingsDeclineFooter =>
      'Diese Software dient nur der technischen Erforschung und Forschung.';

  @override
  String get settingsDeclarationEntryDesc =>
      'Art, Open-Source-Lizenz, Nutzungsbeschränkungen und Haftungsausschlüsse';

  @override
  String get settingsSectionLegal => 'Rechtliches & Hinweise';

  @override
  String get settingsLegalIntro => 'Bitte vor der Nutzung lesen:';

  @override
  String get settingsSectionPrivacy => 'Datenschutzrichtlinie';

  @override
  String get settingsPrivacyEntryDesc =>
      'Wie wir Ihre Informationen verarbeiten und schützen';

  @override
  String get settingsPrivacyIntro =>
      'Willkommen bei ArchoeraMusic (nachfolgend „die Software\" oder „wir\"). Wir wissen um die Bedeutung Ihrer personenbezogenen Daten und setzen uns stets für den Schutz Ihrer Privatsphäre und Datensicherheit ein. Diese Richtlinie erläutert, wie wir Ihre Informationen während der Nutzung der Software verarbeiten, speichern und schützen und welche Rechte Ihnen zustehen.\n\nBitte lesen und verstehen Sie diese Richtlinie sorgfältig. Mit der Nutzung der Software bestätigen Sie, dass Sie alle ihre Inhalte gelesen, verstanden und ihnen zugestimmt haben.\n\n';

  @override
  String get settingsPrivacy1Title => '1. Grundprinzipien\n';

  @override
  String get settingsPrivacy1Body =>
      '1. Minimale Notwendigkeit: Wir verarbeiten nur die Daten, die zur Bereitstellung der Kernfunktionen, zur Gewährleistung der Sicherheit und zur Verbesserung des Erlebnisses erforderlich sind, und erheben keine personenbezogenen sensiblen Daten, die nicht mit dem Dienst zusammenhängen.\n2. Lokal zuerst: Ihre Bibliotheksmetadaten, Ihr Wiedergabeverlauf und Ihre Einstellungen werden standardmäßig auf Ihrem Gerät gespeichert und bleiben vollständig unter Ihrer Kontrolle.\n3. Transparent & kontrollierbar: Diese Software enthält keine Werbung, kein Tracking und keine Nutzerprofile; die Datenverarbeitung ist offen und transparent und kann von Ihnen jederzeit gelöscht werden.\n\n';

  @override
  String get settingsPrivacy2Title => '2. Informationen, die wir verarbeiten\n';

  @override
  String get settingsPrivacy2Body =>
      '· Von Ihnen bereitgestellte Informationen: Zugangsdaten für Musikplattformen Dritter (Cookies / Token aus der QR-Anmeldung, Konto und Passwort usw.), die Adresse und das Konto selbst gehosteter oder autorisierter Medienserver wie Subsonic sowie die von Ihnen gewählten lokalen Musikverzeichnisse. Zugangsdaten werden verschlüsselt im lokalen „Tresor\" gespeichert (v1 Systemsicherer Speicher / v2 Passphrasenschutz / v3 Gerätebindung) und niemals an den Entwickler oder einen Nicht-Plattform-Server hochgeladen.\n· Lokale Laufzeit- und Cache-Daten: Bibliotheksmetadaten (Titel, Künstler, Alben usw.), Wiedergabeverlauf, Favoriten, Downloadaufzeichnungen, Liedtext- und Cover-Caches sowie Einstellungen wie Oberflächensprache und Design.\n· Lokale Laufzeitprotokolle: Zur Fehlerbehebung erzeugt die Software Laufzeitprotokolle auf Ihrem Gerät (Dateigrößenlimit 4 MiB, bei Überschreitung wird die Datei an Ort und Stelle gekürzt). Protokolle verbleiben ausschließlich auf Ihrem Gerät und werden nur dann automatisch hochgeladen, wenn Sie sie aktiv entnehmen und dem Entwickler bereitstellen.\n\n';

  @override
  String get settingsPrivacy3Title => '3. Zwecke der Verwendung\n';

  @override
  String get settingsPrivacy3Body =>
      'Wir verarbeiten die oben genannten Informationen ausschließlich zu folgenden Zwecken: Bereitstellung von Kernfunktionen wie Musikdekodierung, Wiedergabe, Liedtextanzeige und Steueroberfläche; Wiederherstellung Ihrer persönlichen Einstellungen nach einem Neustart der Software; und Gewährleistung eines sicheren und stabilen Betriebs der Software auf Ihrem Gerät. Wir verwenden Ihre Daten niemals für Werbung, Nutzerprofile oder kommerzielles Marketing und verkaufen oder vermieten sie niemals an Dritte.\n\n';

  @override
  String get settingsPrivacy4Title => '4. Dienste Dritter\n';

  @override
  String get settingsPrivacy4Body =>
      '· Online-Musikplattformen und experimentelle Quellen: Wenn Sie sich anmelden oder entsprechende Funktionen nutzen, werden Anfragen direkt von Ihrem Gerät an die jeweilige Plattform gesendet (oder über deren öffentliche HTTP-Schnittstellen interagiert), und die Verarbeitung der zugehörigen Daten unterliegt zugleich den Nutzungsbedingungen und Datenschutzrichtlinien dieser Plattform.\n· Selbst gehostete oder persönliche Medienserver: Die Kommunikation mit Servern wie Subsonic erfolgt direkt zwischen Ihrem Client und Ihrem Server; die Datensicherheit und der Datenschutz auf der Serverseite liegen in Ihrer und der Verantwortung des Serverbetreibers.\n· Diese Software übernimmt keine Zusicherung hinsichtlich der fortgesetzten Verfügbarkeit, Stabilität oder Datenverarbeitungspraktiken von Diensten Dritter.\n\n';

  @override
  String get settingsPrivacy5Title =>
      '5. Speicherung, Aufbewahrung & Sicherheit\n';

  @override
  String get settingsPrivacy5Body =>
      'Der überwiegende Teil Ihrer Daten wird im lokalen Datenverzeichnis gespeichert (Linux: ~/.local/share/ArchoeraMusic; macOS: ~/Library/Application Support/ArchoeraMusic; Windows: %LOCALAPPDATA%\\ArchoeraMusic, überschreibbar über die Umgebungsvariable ARCHOERA_DATA_DIR), bis Sie sie selbst löschen. Sensible Zugangsdaten werden nach Möglichkeit mit dem nativen sicheren Speicher des Betriebssystems verschlüsselt und im Tresor isoliert; die Netzwerkübertragung nutzt HTTPS / TLS, sofern das Ziel dies unterstützt.\nObwohl wir angemessene Sicherheitsmaßnahmen ergreifen, kann aufgrund inhärenter Grenzen der Rechen- und Speichertechnik kein System absolute 100%ige Sicherheit garantieren; bewahren Sie Ihr Gerät und Ihre Zugangsdaten zu Konten Dritter sicher auf.\n\n';

  @override
  String get settingsPrivacy6Title => '6. Ihre Rechte & Datenverwaltung\n';

  @override
  String get settingsPrivacy6Body =>
      'Sie können Ihre Einstellungen, Ihre Streaming-Server-Informationen und Ihren Anmeldestatus jederzeit in den Einstellungen einsehen und ändern; Sie können unter „Speicher / Sicherheit / Verlauf\" Caches, Verlauf und festgelegte Daten löschen; Sie können das lokale Datenverzeichnis in den Einstellungen einsehen und selbst löschen oder es nach der Deinstallation manuell bereinigen, um alle von dieser Software auf Ihrem Gerät hinterlassenen Daten dauerhaft zu vernichten. Bitte beachten Sie: Das Deinstallieren der ausführbaren Datei löscht das Datenverzeichnis nicht zwangsläufig automatisch.\n\n';

  @override
  String get settingsPrivacy7Title => '7. Datenschutz Minderjähriger\n';

  @override
  String get settingsPrivacy7Body =>
      'Diese Software ist ein Allzweckwerkzeug und erhebt keinerlei personenbezogene Daten von Minderjährigen. Wenn Sie minderjährig sind, lesen Sie diese Richtlinie bitte in Begleitung und unter Anleitung eines Erziehungsberechtigten und verwenden Sie diese Software erst nach Einholung von deren Einwilligung.\n\n';

  @override
  String get settingsPrivacy8Title => '8. Aktualisierungen dieser Richtlinie\n';

  @override
  String get settingsPrivacy8Body =>
      'Wir können diese Richtlinie von Zeit zu Zeit anpassen, wenn sich Funktionen weiterentwickeln, sich die technische Architektur ändert oder Gesetze und Vorschriften aktualisiert werden. Aktualisierte Versionen werden mit der Software oder im offiziellen Repository veröffentlicht und gelten ab dem oben angegebenen Datum „Zuletzt aktualisiert\"; wenn Sie die Software nach einer Aktualisierung weiterhin nutzen, gilt dies als Ihr Lesen, Verstehen und Zustimmen zur aktualisierten Richtlinie.\n\n';

  @override
  String get settingsPrivacy9Title => '9. Kontakt\n';

  @override
  String get settingsPrivacy9Body =>
      'Bei Fragen, Anmerkungen oder Beschwerden zu dieser Richtlinie, Ihrer Informationssicherheit oder damit zusammenhängenden Angelegenheiten können Sie den Entwickler wie folgt kontaktieren:\n· GitHub-Repository & Issues: https://github.com/BetaStudio2/ArchoeraMusic\nWir antworten schnellstmöglich nach Eingang Ihres Feedbacks.\n\n';

  @override
  String get settingsPrivacyFooter =>
      'Diese Richtlinie wurde zuletzt am 29. September 2026 aktualisiert.';

  @override
  String get settingsSectionEnvInfo => 'Umgebung';

  @override
  String get settingsEnvVersion => 'Version';

  @override
  String get settingsEnvPlatform => 'Plattform';

  @override
  String get settingsEnvRuntime => 'Laufzeit';

  @override
  String get settingsSectionCommunity => 'Community';

  @override
  String get settingsCommunityRepo => 'GitHub-Repository';

  @override
  String get settingsSectionThanks => 'Besonderer Dank';

  @override
  String get settingsThanksDesign => 'Design-Inspiration';

  @override
  String get settingsThanksCore => 'Kernkomponenten';

  @override
  String get settingsThanksDecoder => 'Decoder-Referenzen';

  @override
  String get settingsThanksIcons => 'Icons';

  @override
  String get settingsSectionFontCredits => 'Schriftartennennung';

  @override
  String get settingsFontCreditsEntryDesc =>
      'Eingebundene Schriftarten und Lizenzinformationen anzeigen';

  @override
  String get settingsFontCreditsText =>
      'Diese Software enthält die folgende Schriftart:\n· MiSans (© Xiaomi, verwendet gemäß der MiSans Font Intellectual Property License Agreement)';

  @override
  String get commonNoLyrics => 'Keine Songtexte';

  @override
  String commonTrackCount({required Object count}) {
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
  String settingsBackgroundBlurDesc({required Object blur}) {
    return 'Gaußsche Unschärfe auf das Hintergrundbild angewendet (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => 'Maskenstärke';

  @override
  String settingsBackgroundDimDesc({required Object dim}) {
    return 'Deckkraft der schwarzen Überlagerung ($dim%); höher = Vordergrund besser lesbar';
  }

  @override
  String get settingsBackgroundScale => 'Zoomgröße';

  @override
  String settingsBackgroundScaleDesc({required Object scale}) {
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
  String get settingsSearchFontSubtitle => 'MiSans';

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
      'Datenschutz: Wetterdaten von Open-Meteo (kostenlos, kein API-Schlüssel). Bei automatischer Ortung wird die IP an ipwho.is gesendet, nur zur Wetterabfrage, nicht gespeichert. Widget und Ortung sind standardmäßig deaktiviert.';

  @override
  String get settingsWeatherPrivacyTitle => 'Wetter-Widget aktivieren?';

  @override
  String get settingsWeatherPrivacyBody =>
      'Beim Aktivieren werden Anfragen an den Drittanbieter-Wetterdienst Open-Meteo gesendet. Im manuellen Stadtmodus wird nur die von Ihnen eingegebene Stadt übertragen, keine weiteren persönlichen Daten.';

  @override
  String get settingsWeatherPrivacyEnable => 'Aktivieren';

  @override
  String get settingsWeatherAutoLocateTitle =>
      'Automatische Ortung aktivieren?';

  @override
  String get settingsWeatherAutoLocateBody =>
      'Die automatische Ortung ermittelt über ipwho.is eine ungefähre Position anhand der öffentlichen IP Ihres Netzwerks und sendet diese Koordinaten an Open-Meteo für die Wetterabfrage. Dabei könnte Ihre Stadt bzw. grobe Position sichtbar werden. Alternativ können Sie eine Stadt manuell eingeben.';

  @override
  String get settingsWeatherLocateSource => 'Ortungsquelle';

  @override
  String get settingsWeatherLocateSourceDesc =>
      'Systemortung ist genauer, wenn verfügbar; sonst automatisch IP';

  @override
  String get settingsWeatherLocateSourceIp => 'IP-Ortung';

  @override
  String get settingsWeatherLocateSourceSystem => 'System';

  @override
  String get settingsWeatherLocateSystemTitle => 'Zur Systemortung wechseln?';

  @override
  String get settingsWeatherLocateSystemBody =>
      'Die Systemortung nutzt den Ortungsdienst des Betriebssystems (Windows-Standort / Linux GeoClue) für eine genauere Position, nur für die Wetterabfrage. Das System fragt um Erlaubnis; bei Nichtverfügbarkeit wird automatisch auf IP zurückgegriffen.';

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
  String get repeatModeList => 'Liste wiederholen';

  @override
  String get repeatModeOne => 'Einen Titel wiederholen';

  @override
  String get repeatModeOff => 'Der Reihe nach';

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
  String settingsScrapeDirsNote({required Object dirs}) {
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
  String get settingsScrapeSourceQQMusic => 'QM';

  @override
  String get settingsScrapeSourceKugou => 'KG';

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
  String settingsScrapeCurrent({required Object file}) {
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
  String get streamingQualityTitle => 'Streaming-Qualität';

  @override
  String get streamingQualityNote =>
      'Original bevorzugt; Transcode-Stufen fordern vom Server universelles MP3 an – erfordert Serverunterstützung, Standardparameter bleiben mit anderen Servern kompatibel.';

  @override
  String get streamingQualityOriginal => 'Original';

  @override
  String get streamingQualityHigh => 'Hoch (320k)';

  @override
  String get streamingQualityMedium => 'Mittel (192k)';

  @override
  String get streamingQualityLow => 'Niedrig (128k)';

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
  String streamingToastConnected({required Object name}) {
    return 'Verbunden mit $name';
  }

  @override
  String get streamingServerConnectFailed => 'Verbindung fehlgeschlagen';

  @override
  String get streamingServerEdit => 'Bearbeiten';

  @override
  String get streamingServerDeleteConfirmTitle => 'Server löschen';

  @override
  String streamingServerDeleteConfirm({required Object name}) {
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
  String streamingTotalSongs({required Object count}) {
    return '$count Titel';
  }

  @override
  String streamingTotalAlbums({required Object count}) {
    return '$count Alben';
  }

  @override
  String streamingTotalArtists({required Object count}) {
    return '$count Künstler';
  }

  @override
  String streamingTotalPlaylists({required Object count}) {
    return '$count Wiedergabelisten';
  }

  @override
  String get streamingEmptyNoResults => 'Keine passenden Ergebnisse';

  @override
  String streamingAlbumSongs({required Object count}) {
    return '$count Titel';
  }

  @override
  String streamingArtistAlbums({required Object count}) {
    return '$count Alben';
  }

  @override
  String streamingPlaylistSongs({required Object count}) {
    return '$count Titel';
  }

  @override
  String get brandQqMusic => 'QM';

  @override
  String get platformQQMusic => 'QM';

  @override
  String get loginQqQrLogin => 'Mit QQ-Music-QR-Code anmelden';

  @override
  String get loginQqScanHint => 'Mit der QQ-App scannen, um dich anzumelden';

  @override
  String navHeaderQqId({required String id}) {
    return 'QQ $id';
  }

  @override
  String searchSourceFailed({required Object source}) {
    return '$source-Suche ist vorübergehend nicht verfügbar';
  }

  @override
  String searchQqRiskDetail({required Object code}) {
    return 'QM hat die Anfrage gedrosselt/risikogesperrt (Code $code); automatische Wiederholungen gestoppt, bitte später erneut versuchen';
  }

  @override
  String get searchNetworkError =>
      'Netzwerkfehler oder Zeitüberschreitung, bitte später erneut versuchen';

  @override
  String searchPlatformError({required Object code}) {
    return 'Plattformfehler ($code)';
  }

  @override
  String get searchWaitRetry =>
      'Zu viele Anfragen, bitte kurz warten und erneut versuchen';

  @override
  String get settingsValueAuto => 'Auto';

  @override
  String get settingsSectionScrapeWrite => 'Schreiboptionen';

  @override
  String get settingsScrapeWriteDesc =>
      'Nach erfolgreichem Scrape in die Audio-Tags geschrieben';

  @override
  String get settingsScrapeEmbedMetadata => 'Metadaten einbetten';

  @override
  String get settingsScrapeEmbedCover => 'Cover einbetten';

  @override
  String get settingsScrapeEmbedLyrics => 'Songtext einbetten';

  @override
  String get settingsScrapeSkipScraped =>
      'Bereits gescrapte Dateien überspringen';

  @override
  String get settingsScrapeSkipScrapedDesc =>
      'Dateien mit MusicBrainz-ID oder ISRC werden nicht erneut gescrapt';

  @override
  String get settingsSectionScrapeAdvanced => 'Erweitert';

  @override
  String get settingsScrapeWorkers => 'Parallele Worker';

  @override
  String settingsScrapeWorkersDesc({required Object value}) {
    return 'Parallele Multi-Quellen-Suchthreads (0=Auto, aktuell $value)';
  }

  @override
  String get settingsScrapeBatch => 'Stapelgröße';

  @override
  String settingsScrapeBatchDesc({required Object value}) {
    return 'Dateien pro Stapel (aktuell $value)';
  }

  @override
  String get settingsScrapeRetries => 'Max. Wiederholungen';

  @override
  String settingsScrapeRetriesDesc({required Object value}) {
    return 'Dateien, die öfter fehlschlagen, werden isoliert (aktuell $value)';
  }

  @override
  String get settingsSectionScrapeOrganize => 'Nur Organisieren';

  @override
  String get settingsScrapeOrganizeNote =>
      'Offline. Verschiebt Dateien aus Verzeichnissen per Vorlage in einen Zielbaum und behält Dateinamen und vorhandene Tags bei. Variablen: artist, albumArtist, album, genre, year, disc, track, title, ext; mit / Verzeichnisebenen trennen. Ohne Zielverzeichnis wird der Standard-Musikordner der Mediathek (erstes Scan-Verzeichnis) verwendet; ist noch keiner konfiguriert, zuerst einen hinzufügen.';

  @override
  String get settingsScrapeOrganizeTargetDir => 'Organisations-Zielverzeichnis';

  @override
  String get settingsScrapeOrganizeTargetHint =>
      'Leer lassen für den Standard-Musikordner der Mediathek (erstes Scan-Verzeichnis; ggf. zuerst einen Scan-Ordner hinzufügen)';

  @override
  String get settingsScrapeOrganizePattern => 'Organisations-Vorlage';

  @override
  String get settingsScrapeOrganizePatternHint =>
      'Die Vorlage bestimmt nur die Verzeichnisebenen; Dateinamen bleiben erhalten';

  @override
  String get settingsScrapeOrganizePresetArtistAlbum => 'Künstler/Album';

  @override
  String get settingsScrapeOrganizePresetArtistOnly => 'Nur Künstler';

  @override
  String get settingsScrapeOrganizePresetGenreArtistAlbum =>
      'Genre/Künstler/Album';

  @override
  String get settingsScrapeOrganizePresetYearArtistAlbum =>
      'Jahr/Künstler/Album';

  @override
  String get settingsScrapeOrganizeStart => 'Organisieren starten';

  @override
  String get settingsOrganizeRunning => 'Dateien werden organisiert…';

  @override
  String get settingsOrganizeMoved => 'Verschoben';

  @override
  String get settingsOrganizeSkipped => 'Übersprungen';

  @override
  String get settingsOrganizeFailed => 'Fehlgeschlagen';

  @override
  String settingsOrganizeDone({
    required Object failed,
    required Object moved,
    required Object skipped,
  }) {
    return 'Organisieren fertig: verschoben $moved, übersprungen $skipped, fehlgeschlagen $failed';
  }

  @override
  String get settingsOrganizeNoTarget =>
      'Kein Scan-Verzeichnis der Mediathek konfiguriert; Standard-Organisationsziel nicht ermittelbar';

  @override
  String settingsOrganizeUsingDefault({required Object dir}) {
    return 'Kein Ziel gesetzt; Standard-Musikordner wird verwendet: $dir';
  }

  @override
  String get toastOrganizeNoDirs => 'Keine Verzeichnisse zum Organisieren';

  @override
  String get toastOrganizeStarted => 'Organisieren gestartet';

  @override
  String get settingsCatScanner => 'Scannen';

  @override
  String get settingsScannerSubtitle =>
      'Mediathek-Scanner · Parallelität & Sicherheitsgrenzen · Quarantäne';

  @override
  String get settingsSectionScanRun => 'Laufzeit';

  @override
  String get settingsScanParallelism => 'Scan-Parallelität';

  @override
  String settingsScanParallelismDesc({required Object value}) {
    return 'Parallel geparste Dateien (0=Auto, aktuell $value)';
  }

  @override
  String get settingsScanBatch => 'Stapelgröße';

  @override
  String settingsScanBatchDesc({required Object value}) {
    return 'DB-Stapelschreiblimit (0=Auto, aktuell $value)';
  }

  @override
  String get settingsSectionScanLimits => 'Sicherheitsgrenzen';

  @override
  String get settingsScanLimitsNote =>
      'Schutzgrenzen für sehr große Mediatheken; leer lassen für Engine-Standard';

  @override
  String get settingsScanNumberDesc => 'Leer lassen für Engine-Standard';

  @override
  String get settingsScanMaxFileSizeMb => 'Max. Dateigröße (MB)';

  @override
  String get settingsScanMaxScanFiles => 'Max. Dateien pro Scan';

  @override
  String get settingsScanMaxErrors => 'Grenze aufeinanderfolgender Fehler';

  @override
  String get settingsSectionScanExts => 'Audio-Erweiterungen';

  @override
  String get settingsScanExtraExtsNote =>
      'Zusätzliche Audio-Erweiterungen zusätzlich zur eingebauten Allowlist';

  @override
  String get settingsScanExtraExtsHint =>
      'Mit Leerzeichen oder Komma getrennt, z. B. dsf m4b';

  @override
  String get settingsSectionScanQuarantine => 'Quarantäne';

  @override
  String settingsScanQuarantineNote({required Object dir}) {
    return 'Dateien, die 3+ Mal nicht geparst werden konnten, werden verschoben nach: $dir';
  }

  @override
  String get settingsScanQuarantineEmpty => 'Keine Dateien in Quarantäne';

  @override
  String get settingsScanQuarantineDelete => 'Diese Datei löschen';

  @override
  String get settingsScanQuarantineOpenDir => 'Ordner öffnen';

  @override
  String get settingsScanQuarantineClearAll => 'Quarantäne leeren';

  @override
  String get settingsScanQuarantineClearAllConfirm =>
      'Alle Dateien im Quarantäneordner löschen? Dies kann nicht rückgängig gemacht werden.';

  @override
  String get libraryFullScan => 'Vollständiger Scan';

  @override
  String get libraryFullScanConfirm => 'Vollständigen Scan ausführen?';

  @override
  String get libraryFullScanConfirmDesc =>
      'Die Mediathek-Datenbank wird geleert und aus den Scan-Verzeichnissen neu aufgebaut (Quelldateien bleiben erhalten). Nicht rückgängig zu machen; beansprucht währenddessen viel Festplatten-IO.';

  @override
  String get settingsSectionLyricEngine => 'Songtext-Engine';

  @override
  String get settingsLyricEngine => 'Engine';

  @override
  String get settingsLyricEngineSimple => 'Klassisch';

  @override
  String get settingsLyricEngineWall => 'Wand';

  @override
  String get settingsLyricEngineDesc =>
      'Renderer wählen; jederzeit umschaltbar';

  @override
  String get settingsLyricEngineNote =>
      'Gilt nur für den Songtextbereich des Vollbild-Players; AMLL = Apple-Music-artiges Wandscrollen, etwas aufwendiger.';

  @override
  String get settingsSectionLyricWall => 'Wand-Optionen';

  @override
  String get settingsAmllNote =>
      'Apple-Music-artige Wand-Songtextparameter, nur von der AMLL-Engine verwendet.';

  @override
  String get settingsAmllAlign => 'Position der aktiven Zeile';

  @override
  String get settingsAmllDim => 'Deckkraft inaktiver Zeilen';

  @override
  String get settingsAmllWordSweep => 'Wort-Sweep';

  @override
  String get settingsAmllSyntheticSweep =>
      'Synthetischer Sweep für einfache Lyrics';

  @override
  String get settingsAmllSyntheticSweepDesc =>
      'Wort-Timing aus der Zeilendauer schätzen (auch für Übersetzungen).';

  @override
  String get settingsAmllHidePassed => 'Gesungene Zeilen ausblenden';

  @override
  String get settingsAmllScale => 'Inaktive Zeilen verkleinern';

  @override
  String get settingsAmllBlur => 'Inaktive Zeilen weichzeichnen';

  @override
  String get settingsAmllBlurNote =>
      'Automatisch passt sich der Bildrate an: zuerst Weichzeichnen in einer Ebene, bei Bedarf automatisch aus.';

  @override
  String get settingsAmllBlurAuto => 'Automatisch';

  @override
  String get settingsAmllBlurFast => 'Schnell';

  @override
  String get settingsAmllBlurLite => 'Leicht (Näherung)';

  @override
  String get settingsAmllBlurQuality => 'Qualität';

  @override
  String get settingsAmllBlurOff => 'Aus';

  @override
  String get settingsAmllSpring => 'Scroll-Feder';

  @override
  String get toastSleepInhibitFailed =>
      'System-Standby konnte nicht verhindert werden';

  @override
  String get toastMediaSessionLost => 'System-Medien-Sitzung getrennt';

  @override
  String get instanceAlreadyRunning =>
      'Finden Sie das laufende Fenster im Infobereich oder in der Taskleiste.';

  @override
  String get instanceAlreadyRunningTitle =>
      'ArchoeraMusic wird bereits ausgeführt';

  @override
  String get settingsCatShortcuts => 'Tastenkürzel';

  @override
  String get settingsShortcutsSubtitle => 'Tastenbelegung anpassen';

  @override
  String get shortcutNote =>
      'Klicken Sie auf eine Belegung, um eine neue Tastenkombination aufzunehmen; drücken Sie die Kombination im Dialog.';

  @override
  String get shortcutResetAll => 'Alle zurücksetzen';

  @override
  String get shortcutUnbound => 'Nicht belegt';

  @override
  String get shortcutHintEdit => 'Zum Bearbeiten klicken';

  @override
  String get shortcutConflict => 'Konflikt mit einer anderen Aktion';

  @override
  String get shortcutCaptureTitle => 'Tastenkürzel aufnehmen';

  @override
  String get shortcutPressKeys => 'Tasten drücken…';

  @override
  String get shortcutCategoryPlayback => 'Wiedergabe';

  @override
  String get shortcutCategorySeek => 'Spulen';

  @override
  String get shortcutCategoryVolume => 'Lautstärke';

  @override
  String get shortcutCategoryQueue => 'Warteschlange';

  @override
  String get shortcutCategoryNavigation => 'Navigation';

  @override
  String get shortcutActionPlayPause => 'Wiedergabe / Pause';

  @override
  String get shortcutActionPlay => 'Wiedergabe';

  @override
  String get shortcutActionPause => 'Pause';

  @override
  String get shortcutActionStop => 'Stopp';

  @override
  String get shortcutActionNext => 'Nächster Titel';

  @override
  String get shortcutActionPrevious => 'Vorheriger Titel';

  @override
  String get shortcutActionLikeToggle => 'Gefällt mir an/aus';

  @override
  String get shortcutActionShuffleToggle => 'Zufallswiedergabe umschalten';

  @override
  String get shortcutActionRepeatCycle => 'Wiederholungsmodus wechseln';

  @override
  String get shortcutActionReload => 'Aktuellen Titel neu laden';

  @override
  String get shortcutActionSeekBackward => '10 s zurück';

  @override
  String get shortcutActionSeekForward => '10 s vor';

  @override
  String get shortcutActionSeekBackwardLong => '30 s zurück';

  @override
  String get shortcutActionSeekForwardLong => '30 s vor';

  @override
  String get shortcutActionVolumeUp => 'Lauter';

  @override
  String get shortcutActionVolumeDown => 'Leiser';

  @override
  String get shortcutActionMuteToggle => 'Stumm an/aus';

  @override
  String get shortcutActionJumpToFirst => 'Zum ersten in der Warteschlange';

  @override
  String get shortcutActionJumpToLast => 'Zum letzten in der Warteschlange';

  @override
  String get shortcutActionClearQueue => 'Warteschlange leeren';

  @override
  String get shortcutActionGoHome => 'Zur Startseite';

  @override
  String get shortcutActionGoLibrary => 'Zur Bibliothek';

  @override
  String get shortcutActionGoSearch => 'Zur Suche';

  @override
  String get shortcutActionGoLiked => 'Zu Gefällt mir';

  @override
  String get shortcutActionGoFavorites => 'Zu Favoriten';

  @override
  String get shortcutActionGoHistory => 'Zum Verlauf';

  @override
  String get shortcutActionGoDownload => 'Zu Downloads';

  @override
  String get shortcutActionGoStreaming => 'Zum Streaming';

  @override
  String get shortcutActionOpenPlayer => 'Player öffnen';

  @override
  String get shortcutActionOpenSettings => 'Einstellungen öffnen';

  @override
  String get shortcutActionBack => 'Zurück';

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
  String get settingsLyricTtml => 'Online-TTML-Liedtexte (Beta)';

  @override
  String get settingsLyricTtmlDesc =>
      'Lädt wortweise TTML-Liedtexte von AMLL DB und ersetzt bei Treffer die Plattform-Liedtexte; Internet erforderlich. Diese Funktion wird noch getestet.';

  @override
  String get settingsLyricTtmlEnable => 'Online-TTML-Liedtexte aktivieren';

  @override
  String get settingsLyricTtmlEnableDesc =>
      'AMLL DB-Text bevorzugen, wenn vorhanden';

  @override
  String get settingsLyricTtmlServer => 'AMLL DB-Server';

  @override
  String get settingsLyricTtmlServerDesc =>
      'URL-Vorlage für Liedtext-Anfragen; kann auf einen eigenen Server oder Spiegel zeigen';

  @override
  String get settingsLyricTtmlServerDialogTitle => 'AMLL DB-Servervorlage';

  @override
  String get settingsLyricTtmlServerHint =>
      'Die Vorlage muss %p (Plattform) und %s (Titel-ID) enthalten';

  @override
  String get settingsLyricTtmlServerInvalid =>
      'Die Vorlage muss %p und %s enthalten';

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
    return '$minutes Minuten';
  }

  @override
  String get sleepTimerMinutesUnit => 'Min.';

  @override
  String get sleepTimerCustom => 'Benutzerdefiniert…';

  @override
  String get sleepTimerCustomTitle => 'Benutzerdefinierter Sleep-Timer';

  @override
  String get sleepTimerCustomLabel => 'Minuten';

  @override
  String get sleepTimerCustomInvalid =>
      'Bitte Minuten zwischen 1 und 600 eingeben';

  @override
  String get sleepTimerPresets => 'Sleep-Timer-Voreinstellungen';

  @override
  String get sleepTimerPresetsDesc =>
      'Schnelldauern im Sleep-Timer-Menü. Einträge hinzufügen oder entfernen; leer lassen, um nur Benutzerdefiniert / Aktuellen Titel beenden / Aus anzuzeigen.';

  @override
  String get sleepTimerPresetsAdd => 'Hinzufügen';

  @override
  String get sleepTimerPresetsEmpty => 'Keine Voreinstellungen';

  @override
  String get sleepTimerPresetsDuplicate =>
      'Diese Dauer ist bereits eine Voreinstellung';

  @override
  String get sleepTimerPresetsEdit => 'Bearbeiten';

  @override
  String get settingsSectionSleepTimer => 'Sleep-Timer';

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

  @override
  String get settingsCatMcp => 'MCP-Zugriff';

  @override
  String get settingsMcpSubtitle =>
      'Lokale MCP-Steuerschnittstellen (standardmäßig aus)';

  @override
  String get settingsMcpTitle => 'MCP-Steuerdienst';

  @override
  String get settingsMcpNote =>
      'Lauscht nur auf der Loopback-Adresse 127.0.0.1 und benötigt keine Administratorrechte. Alle Fähigkeiten sind standardmäßig aus; aktivieren Sie sie gruppenweise. Der Hauptschalter aus beendet das Lauschen.';

  @override
  String get settingsMcpEnable => 'MCP-Steuerung aktivieren';

  @override
  String get settingsMcpEnableOn => 'An, lauscht auf dem Port';

  @override
  String get settingsMcpEnableOff => 'Standardmäßig aus';

  @override
  String get settingsMcpPort => 'Listen-Port';

  @override
  String get settingsMcpPortDesc =>
      '1024-65535; der Listener startet bei Änderung neu';

  @override
  String get settingsMcpKey => 'Zugriffsschlüssel';

  @override
  String get settingsMcpKeyCopy => 'Kopieren';

  @override
  String get settingsMcpKeyRegenerate => 'Schlüssel neu erzeugen';

  @override
  String get settingsMcpKeyCopied => 'Zugriffsschlüssel kopiert';

  @override
  String get settingsMcpKeyRegenerated => 'Zugriffsschlüssel neu erzeugt';

  @override
  String get settingsMcpAllowKeyless => 'Zugriff ohne Schlüssel erlauben';

  @override
  String get settingsMcpAllowKeylessDesc =>
      'Aus ist sicherer; an erlaubt jedem lokalen Programm den direkten Zugriff';

  @override
  String get settingsMcpCapsTitle => 'Fähigkeiten';

  @override
  String get settingsMcpCapsNote =>
      'Jede Gruppe ist unabhängig; deaktivierte Fähigkeiten erscheinen nicht in der MCP-Werkzeugliste oder den REST-Routen.';

  @override
  String get settingsMcpCapRead => 'Status lesen';

  @override
  String get settingsMcpCapReadDesc =>
      'Wiedergabestatus, aktueller Titel, Warteschlange, Dienstinfo und Quellenliste';

  @override
  String get settingsMcpCapPlayback => 'Wiedergabesteuerung';

  @override
  String get settingsMcpCapPlaybackDesc =>
      'Wiedergabe/Pause/Stopp, nächster/vorheriger, Springen, Lautstärke, Wiederholen/Zufall, Qualität, Titel abspielen';

  @override
  String get settingsMcpCapQueue => 'Warteschlange';

  @override
  String get settingsMcpCapQueueDesc =>
      'Einträge hinzufügen/entfernen/verschieben, Eintrag abspielen, Warteschlange leeren';

  @override
  String get settingsMcpCapSearch => 'Online-Suche';

  @override
  String get settingsMcpCapSearchDesc =>
      'Songs auf NetEase/KuGou/QQ Music und weiteren suchen';

  @override
  String get settingsMcpCapLibrary => 'Lokale Bibliothek';

  @override
  String get settingsMcpCapLibraryDesc =>
      'Lokale Bibliothek durchsuchen, Zufallstitel, Bibliotheksstatistik';

  @override
  String get settingsMcpCapPreferences => 'Einstellungen lesen';

  @override
  String get settingsMcpCapPreferencesDesc =>
      'Nur-Lese-Einstellungen (sensible Felder entfernt)';

  @override
  String get settingsMcpEndpointsTitle => 'Verbindungsadressen';

  @override
  String settingsMcpStatusRunning({required int port}) {
    return 'Läuft · Port $port';
  }

  @override
  String get settingsMcpStatusStopped => 'Gestoppt';

  @override
  String get settingsMcpStatusError =>
      'Start fehlgeschlagen (Port evtl. belegt)';

  @override
  String get settingsMcpStatusDesc =>
      'MCP für Agent-Clients; REST / WebSocket für Skripte und andere Programme';

  @override
  String get settingsMcpEndpointMcp => 'MCP (Streamable HTTP)';

  @override
  String get settingsMcpEndpointRest => 'REST-API';

  @override
  String get settingsMcpEndpointWs => 'WebSocket (JSON-RPC 2.0)';

  @override
  String get settingsMcpCapAppearance => 'Aussehen';

  @override
  String get settingsMcpCapAppearanceDesc =>
      'Hell / Dunkel / Systemthema umschalten';

  @override
  String get settingsMcpCapCollection => 'Favoriten';

  @override
  String get settingsMcpCapCollectionDesc =>
      'Favoritenstatus (Herz) abfragen und umschalten';

  @override
  String get settingsMcpCapHistory => 'Wiedergabeverlauf';

  @override
  String get settingsMcpCapHistoryDesc =>
      'Wiedergabeverlauf abfragen und leeren';

  @override
  String get settingsMcpCapLyrics => 'Songtext';

  @override
  String get settingsMcpCapLyricsDesc =>
      'Songtextzeilen des aktuellen Titels (nur Lesen)';

  @override
  String get settingsMcpCapDownload => 'Downloads';

  @override
  String get settingsMcpCapDownloadDesc =>
      'Download-Aufgaben auflisten, Titel einreihen, Aufgabe abbrechen';

  @override
  String get settingsMcpAllowLan => 'LAN-Zugriff erlauben';

  @override
  String get settingsMcpAllowLanDesc =>
      'Standardmäßig aus; an bindet an 0.0.0.0, andere Geräte im LAN können verbinden (Schlüssel weiterhin nötig)';

  @override
  String get settingsMcpAllowLanWarning =>
      'Warnung: LAN-Zugriff vergrößert die Angriffsfläche. Halten Sie den Zugriffsschlüssel geheim und nutzen Sie dies nur in vertrauenswürdigen Netzwerken.';

  @override
  String get settingsMcpAllowLanWarningTitle => 'LAN-Zugriff aktivieren?';

  @override
  String get settingsMcpAllowLanWarningBody =>
      'Danach können andere Geräte im selben LAN diesen Steuerdienst erreichen (der Zugriffsschlüssel ist weiterhin nötig). Aktivieren Sie dies nur in vertrauenswürdigen Netzwerken und bewahren Sie den Schlüssel sicher auf.';

  @override
  String get settingsMcpAllowLanWarningAgree => 'Ich verstehe, aktivieren';

  @override
  String get settingsMcpLanAddress => 'LAN-Adresse';

  @override
  String get settingsMcpShell => 'Kommandozeilen-Shell';

  @override
  String get settingsMcpShellDesc =>
      'Wenn an, im Terminal `<exe> archoerashell …` verwenden (kein Fenster); wenn aus, bricht der Unterbefehl mit Fehler ab';

  @override
  String get settingsMcpShellUsage => 'Beispielbefehl';

  @override
  String get settingsMcpShellCopy => 'Kopieren';

  @override
  String get settingsMcpShellCopied => 'Beispielbefehl kopiert';

  @override
  String get mcpShellUsage =>
      'archoerashell — ArchoeraMusic Kommandozeilen-Steuerung (Unix-artig)\n\nVerwendung:\n  archoera_music archoerashell [globale Optionen] <Befehl> [Argumente...]\n\nHinweis:\n  <Befehl> --help oder help <Befehl> für die Nutzung eines Befehls.\n\nGlobale Optionen:\n  -h, --help            Diese Hilfe anzeigen\n  -V, --version         Version anzeigen\n  -j, --json            JSON-Ausgabe (für Skripte)\n  -q, --quiet           Nur Fehler ausgeben\n      --host <host>     Serveradresse (Standard 127.0.0.1)\n  -p, --port <port>     Serverport (Standard aus den Einstellungen)\n  -k, --key  <key>      Zugriffsschlüssel (Standard aus den Einstellungen)\n\nWiedergabe:\n  status / now-playing / play|pause|toggle|stop|next|prev\n  seek <ms> / volume <0..1> / repeat <off|list|one> / shuffle <on|off>\n  quality <lq|sq|hq|lossless|hi-res> / play-track <ref>\n\nWarteschlange:\n  queue [list|play <index>|add <ref>...|rm <index>|move <from> <to>|clear]\n\nSuche / Bibliothek:\n  search <source> <Begriff> [-n n] [-p page]\n  search-all <Begriff> [-n n]\n  library [Begriff] [-n n] [--offset n] / library-random / library-stats\n\nFavoriten / Verlauf / Songtext:\n  like|unlike|like-status <ref> / list-liked <source> [-n n]\n  history [-n n] / history-clear / lyrics\n\nDownloads:\n  download [list|add <ref>... [--quality <q>]|cancel <id>|remove <id>]\n\nSonstiges:\n  theme <light|dark|system> / sleep <Minuten>|--end / sleep-cancel\n  prefs [Schlüssel...] / tools / info / call <Werkzeug> [--json <json>]\n\nBeispiele:\n  archoera_music archoerashell status\n  archoera_music archoerashell search netease Jay -n 10\n  archoera_music archoerashell play-track netease:186016\n  archoera_music archoerashell --json library Jay';

  @override
  String get mcpShellHint =>
      '<Befehl> --help oder help <Befehl> für die Nutzung eines Befehls, z. B. archoerashell search --help.';

  @override
  String get mcpShellUsageError => 'Nutzungsfehler';

  @override
  String get mcpShellErrorPrefix => 'Fehler';

  @override
  String get mcpShellDisabled =>
      'archoerashell ist in den Einstellungen deaktiviert (MCP-Zugriff → Kommandozeilen-Shell).';

  @override
  String get mcpShellHelpStatus =>
      'Verwendung: archoerashell status\n\nZeigt den Wiedergabestatus: Wiedergabe/Pause, Titel, Position, Lautstärke, Wiederholen/Zufall.';

  @override
  String get mcpShellHelpNowPlaying =>
      'Verwendung: archoerashell now-playing\n\nZeigt nur den aktuellen Titel und die Position.';

  @override
  String get mcpShellHelpPlay =>
      'Verwendung: archoerashell play\n\nWiedergabe starten/fortsetzen.';

  @override
  String get mcpShellHelpPause =>
      'Verwendung: archoerashell pause\n\nWiedergabe pausieren.';

  @override
  String get mcpShellHelpToggle =>
      'Verwendung: archoerashell toggle\n\nZwischen Wiedergabe und Pause wechseln.';

  @override
  String get mcpShellHelpStop =>
      'Verwendung: archoerashell stop\n\nWiedergabe stoppen.';

  @override
  String get mcpShellHelpNext =>
      'Verwendung: archoerashell next\n\nZum nächsten Titel springen.';

  @override
  String get mcpShellHelpPrev =>
      'Verwendung: archoerashell prev\n\nZum vorherigen Titel springen (wie previous).';

  @override
  String get mcpShellHelpPrevious =>
      'Verwendung: archoerashell previous\n\nZum vorherigen Titel springen (wie prev).';

  @override
  String get mcpShellHelpSeek =>
      'Verwendung: archoerashell seek <ms>\n\nAn die angegebene Position springen.\nBeispiel: archoerashell seek 30000';

  @override
  String get mcpShellHelpVolume =>
      'Verwendung: archoerashell volume <0..1>\n\nLautstärke setzen.\nBeispiel: archoerashell volume 0.6';

  @override
  String get mcpShellHelpRepeat =>
      'Verwendung: archoerashell repeat <off|list|one>\n\nWiederholmodus setzen.';

  @override
  String get mcpShellHelpShuffle =>
      'Verwendung: archoerashell shuffle <on|off>\n\nZufallswiedergabe umschalten.';

  @override
  String get mcpShellHelpQuality =>
      'Verwendung: archoerashell quality <lq|sq|hq|lossless|hi-res>\n\nQualitätsstufe wechseln.';

  @override
  String get mcpShellHelpPlayTrack =>
      'Verwendung: archoerashell play-track <ref>\n\nDen angegebenen Titel abspielen (ref ist source:id).\nBeispiel: archoerashell play-track netease:186016';

  @override
  String get mcpShellHelpSearch =>
      'Verwendung: archoerashell search <Quelle> <Begriff> [-n Anzahl] [-p Seite]\n\nSongs auf einer Quelle suchen.\n  Quelle: netease | kugou | qqmusic | neko\n  -n, --limit <n>   Anzahl (1-50, Standard 20)\n  -p, --page <n>    Seite (ab 1)\nBeispiel: archoerashell search netease Jay -n 10';

  @override
  String get mcpShellHelpSearchAll =>
      'Verwendung: archoerashell search-all <Begriff> [-n pro Quelle]\n\nAlle aktiven Quellen durchsuchen und nach Quelle gruppieren.\n  -n, --limit <n>   Treffer pro Quelle (1-30, Standard 10)';

  @override
  String get mcpShellHelpQueue =>
      'Verwendung: archoerashell queue [Unterbefehl]\n\n  queue                     Warteschlange anzeigen\n  queue play <index>        Eintrag abspielen\n  queue add <ref>...        Einreihen (--position next|end, Standard next)\n  queue rm <index>          Eintrag entfernen\n  queue move <from> <to>    Umsortieren\n  queue clear               Warteschlange leeren';

  @override
  String get mcpShellHelpLibrary =>
      'Verwendung: archoerashell library [Begriff] [-n Anzahl] [--offset n]\n\nLokale Bibliothek durchsuchen; ohne Begriff alles auflisten.';

  @override
  String get mcpShellHelpLibraryRandom =>
      'Verwendung: archoerashell library-random [-n Anzahl]\n\nZufällige lokale Titel (Standard 20).';

  @override
  String get mcpShellHelpLibraryStats =>
      'Verwendung: archoerashell library-stats\n\nStatistik der lokalen Bibliothek: Titelanzahl / Größe / Gesamtdauer.';

  @override
  String get mcpShellHelpPrefs =>
      'Verwendung: archoerashell prefs [Schlüssel...]\n\nApp-Einstellungen lesen (nur Lesen; sensible Schlüssel entfernt); ohne Schlüssel alles.';

  @override
  String get mcpShellHelpTheme =>
      'Verwendung: archoerashell theme <light|dark|system>\n\nThemamodus wechseln.';

  @override
  String get mcpShellHelpLike =>
      'Verwendung: archoerashell like <ref>\n\nDen angegebenen Titel favorisieren (Herz).';

  @override
  String get mcpShellHelpUnlike =>
      'Verwendung: archoerashell unlike <ref>\n\nDen angegebenen Titel aus den Favoriten entfernen.';

  @override
  String get mcpShellHelpLikeStatus =>
      'Verwendung: archoerashell like-status <ref>\n\nAbfragen, ob der Titel favorisiert ist.';

  @override
  String get mcpShellHelpListLiked =>
      'Verwendung: archoerashell list-liked <Quelle> [-n Anzahl]\n\nFavoriten der Quelle auflisten (leer ohne Anmeldung).';

  @override
  String get mcpShellHelpHistory =>
      'Verwendung: archoerashell history [-n Anzahl]\n\nWiedergabeverlauf (neueste zuerst, Standard 50).';

  @override
  String get mcpShellHelpHistoryClear =>
      'Verwendung: archoerashell history-clear\n\nWiedergabeverlauf leeren.';

  @override
  String get mcpShellHelpLyrics =>
      'Verwendung: archoerashell lyrics\n\nSongtextzeilen des aktuellen Titels.';

  @override
  String get mcpShellHelpDownload =>
      'Verwendung: archoerashell download [Unterbefehl]\n\n  download [list] [-n Anzahl]          Download-Aufgaben auflisten\n  download add <ref>... [--quality]    Download einreihen\n  download cancel <taskId>             Aufgabe abbrechen\n  download remove <taskId>             Eintrag entfernen (Datei bleibt)';

  @override
  String get mcpShellHelpSleep =>
      'Verwendung: archoerashell sleep <Minuten> | sleep --end\n\nSleep-Timer setzen: Minuten-Countdown oder --end pausiert nach dem aktuellen Titel.';

  @override
  String get mcpShellHelpSleepCancel =>
      'Verwendung: archoerashell sleep-cancel\n\nSleep-Timer abbrechen.';

  @override
  String get mcpShellHelpInfo =>
      'Verwendung: archoerashell info\n\nDienstinfo: App-Version, Port, Endpunkte, aktive Fähigkeiten.';

  @override
  String get mcpShellHelpTools =>
      'Verwendung: archoerashell tools\n\nAktive Werkzeuge auflisten (Name / Fähigkeit / Beschreibung).';

  @override
  String get mcpShellHelpCall =>
      'Verwendung: archoerashell call <Werkzeug> [--json <json>]\n\nEin beliebiges aktives Werkzeug direkt aufrufen; Argumente sind ein JSON-Objekt.';

  @override
  String mcpShellErrUnknownCommand({required String command}) {
    return 'Unbekannter Befehl: $command';
  }

  @override
  String mcpShellErrUnknownOption({required String option}) {
    return 'Unbekannte Option: $option';
  }

  @override
  String mcpShellErrNeedValue({required String option}) {
    return 'Option $option benötigt einen Wert';
  }

  @override
  String mcpShellErrBadPort({required String value}) {
    return 'Ungültiger Port: $value';
  }

  @override
  String mcpShellErrConnect({
    required String host,
    required int port,
    required String reason,
  }) {
    return 'Kann nicht mit $host:$port verbinden ($reason)';
  }

  @override
  String get mcpShellErrConnectHint =>
      'Stellen Sie sicher, dass die App läuft und der MCP-Zugriff in den Einstellungen aktiviert ist.';

  @override
  String mcpShellErrHttp({required String message}) {
    return 'HTTP-Fehler: $message';
  }

  @override
  String mcpShellErrTimeout({required String host, required int port}) {
    return 'Verbindungszeitüberschreitung: $host:$port';
  }
}
