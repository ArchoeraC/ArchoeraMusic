// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get menuTrackDetail => 'Détails du média';

  @override
  String get trackDetailDuration => 'Durée';

  @override
  String get trackDetailArtist => 'Artiste';

  @override
  String get trackDetailAlbum => 'Album';

  @override
  String get trackDetailSource => 'Source';

  @override
  String get trackDetailPath => 'Chemin';

  @override
  String get trackDetailFileSize => 'Taille du fichier';

  @override
  String get trackDetailCodec => 'Codec';

  @override
  String get trackDetailSampleRate => 'Fréquence d\'échantillonnage';

  @override
  String get trackDetailBitDepth => 'Profondeur de bits';

  @override
  String get trackDetailBitrate => 'Débit binaire';

  @override
  String get trackDetailChannels => 'Canaux';

  @override
  String get trackSourceLocal => 'Fichier local';

  @override
  String get trackSourceStreaming => 'Streaming';

  @override
  String get trackDetailQuality => 'Qualité';

  @override
  String get batchSelectAll => 'Tout sélectionner';

  @override
  String get batchInvert => 'Inverser la sélection';

  @override
  String get batchPlay => 'Lire la sélection';

  @override
  String get batchAddQueue => 'Ajouter à la file';

  @override
  String get batchDownload => 'Téléchargement groupé';

  @override
  String get batchExit => 'Quitter la sélection multiple';

  @override
  String get batchSelectHint => 'Sélection multiple';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '$count pistes ajoutées à la file';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '$count pistes ajoutées à la file de téléchargement';
  }

  @override
  String get settingsBarEnhancedLyrics => 'Paroles de barre avancées';

  @override
  String get settingsBarEnhancedLyricsOn =>
      'Afficher le surlignage karaoké si les paroles sont synchronisées mot à mot';

  @override
  String get settingsBarEnhancedLyricsOff =>
      'Toujours afficher les paroles simples dans la barre';

  @override
  String get settingsSectionClose => 'Fermer l\'application';

  @override
  String get settingsSectionPower => 'Économie d\'énergie';

  @override
  String get settingsPowerSaver => 'Mode d\'économie d\'énergie';

  @override
  String get settingsPowerSaverOn =>
      'Réduire le rendu en arrière-plan (5 FPS en réduction, 1 FPS sans focus ou écran éteint)';

  @override
  String get settingsPowerSaverOff => 'Toujours rendre à pleine fréquence';

  @override
  String get settingsSuppressSleep => 'Empêcher la mise en veille du système';

  @override
  String get settingsSuppressSleepOn =>
      'Garder le système éveillé pendant la lecture pour ne pas interrompre la lecture en arrière-plan';

  @override
  String get settingsSuppressSleepOff =>
      'Le système peut se mettre en veille après inactivité';

  @override
  String get settingsPowerSaverNote =>
      'Le mode économie d\'énergie écoute les événements d\'état de fenêtre (sans sondage) ; le moteur arrête déjà le rendu quand la fenêtre est masquée ou l\'écran éteint. « Empêcher la mise en veille » ne s\'applique que pendant la lecture.';

  @override
  String get settingsCloseBehavior => 'À la fermeture de l\'application';

  @override
  String get settingsCloseBehaviorAsk => 'Demander à chaque fois';

  @override
  String get settingsCloseBehaviorBackground => 'Lecture en arrière-plan';

  @override
  String get settingsCloseBehaviorQuit => 'Quitter directement';

  @override
  String get commonCloseConfirmTitle => 'Quitter l\'application';

  @override
  String get commonCloseConfirmMessage =>
      'Après la fermeture de la fenêtre principale';

  @override
  String get commonCloseConfirmRemember =>
      'Mémoriser mon choix et ne plus demander';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => 'Netease Music';

  @override
  String get brandKugou => 'Kugou Music';

  @override
  String get commonBack => 'Retour';

  @override
  String get commonCancel => 'Annuler';

  @override
  String get commonClose => 'Fermer';

  @override
  String get commonDefault => 'Par défaut';

  @override
  String get commonGoLogin => 'Se connecter';

  @override
  String get commonLike => 'J\'aime';

  @override
  String get commonLoading => 'Chargement';

  @override
  String get commonLossless => 'Sans perte';

  @override
  String get commonOriginal => 'Original';

  @override
  String get commonMore => 'Plus';

  @override
  String get commonNext => 'Suivant';

  @override
  String get commonNoMore => 'Pas plus';

  @override
  String get commonPrevious => 'Précédent';

  @override
  String get commonSettings => 'Paramètres';

  @override
  String get commonUnknownAlbum => 'Album inconnu';

  @override
  String get commonUnknownArtist => 'Artiste inconnu';

  @override
  String get commonUnlike => 'Je n\'aime plus';

  @override
  String get downloadQualityTitle => 'Qualité de téléchargement';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return 'Obtenir le lien de téléchargement de $platform nécessite d\'être connecté. Sans connexion, seul l\'aperçu est possible, pas le téléchargement complet.\n\nConnectez-vous à votre compte $platform et réessayez.';
  }

  @override
  String get downloadRequiresLoginTitle => 'Connexion requise pour télécharger';

  @override
  String get menuComment => 'Voir les commentaires';

  @override
  String get menuDownload => 'Télécharger';

  @override
  String get menuLike => 'Ajouter aux favoris';

  @override
  String get menuPlay => 'Lecture';

  @override
  String get menuPlayNext => 'Lire ensuite';

  @override
  String get menuRemoveFromQueue => 'Retirer de la file';

  @override
  String get menuUnlike => 'Retirer des favoris';

  @override
  String get navHeaderAccount => 'Compte';

  @override
  String get navHeaderComingSoon => 'Bientôt disponible';

  @override
  String navHeaderKugouId(Object id) {
    return 'Kugou $id';
  }

  @override
  String get navHeaderKugouMusic => 'Kugou Music';

  @override
  String get navHeaderLoginAccount => 'Se connecter (Netease / Kugou)';

  @override
  String get navHeaderLogout => 'Se déconnecter';

  @override
  String get navHeaderNeteaseAccount => 'Compte Netease';

  @override
  String get navHeaderNeteaseMusic => 'Netease Music';

  @override
  String get navHeaderQqMusic => 'QQ Music';

  @override
  String get navHeaderQrLogin => 'Connexion par code QR';

  @override
  String get navHeaderSearchHint =>
      'Rechercher chansons / artistes / playlists';

  @override
  String get navHeaderThemeDark => 'Thème : Sombre';

  @override
  String get navHeaderThemeLight => 'Thème : Clair';

  @override
  String get navHeaderThemeSystem => 'Thème : Système';

  @override
  String get playerBarBuffering => 'Chargement…';

  @override
  String get playerBarIdleHint =>
      'Cliquez sur la barre latérale ou chargez une source pour commencer la lecture';

  @override
  String get playerBarOpenPlayer => 'Ouvrir le lecteur';

  @override
  String get playerBarPlayPause => 'Lecture/Pause';

  @override
  String get playerBarPlaylist => 'Liste de lecture';

  @override
  String get playerBarUntitled => 'Sans titre';

  @override
  String get queueClear => 'Vider la file';

  @override
  String get queueEmpty => 'La file est vide';

  @override
  String get queueEmptyHint =>
      'Les chansons sélectionnées dans la liste apparaîtront ici';

  @override
  String get queueRepeatList => 'Répéter la liste';

  @override
  String get queueRepeatMode => 'Mode de répétition';

  @override
  String get queueRepeatOne => 'Répéter une';

  @override
  String get queueShuffle => 'Lecture aléatoire';

  @override
  String get queueShuffleOff => 'Désactiver la lecture aléatoire';

  @override
  String get queueTitle => 'File de lecture';

  @override
  String queueTrackCount(Object count) {
    return '$count titres';
  }

  @override
  String get sidebarBackHome => 'Retour à l\'accueil';

  @override
  String get sidebarCollapse => 'Réduire la barre latérale';

  @override
  String get sidebarDownload => 'Téléchargements';

  @override
  String get sidebarExpand => 'Développer la barre latérale';

  @override
  String get sidebarFavorites => 'Favoris';

  @override
  String get sidebarGroupMusic => 'Musique';

  @override
  String get sidebarGroupPersonal => 'Personnel';

  @override
  String get sidebarHistory => 'Historique';

  @override
  String get sidebarHome => 'Accueil';

  @override
  String get sidebarLibrary => 'Bibliothèque';

  @override
  String get sidebarLiked => 'Mes favoris';

  @override
  String get songListAlbum => 'Album';

  @override
  String get songListDuration => 'Durée';

  @override
  String get songListTitle => 'Titre';

  @override
  String get songListScrollTop => 'Retour en haut';

  @override
  String get songListLocatePlaying => 'Localiser la lecture';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return 'Ajouté à la file de téléchargement : $quality';
  }

  @override
  String get toastAddedToQueue => 'Ajouté à la file de lecture';

  @override
  String get toastDownloadEngineNotReady =>
      'Le moteur de téléchargement n\'est pas prêt, veuillez réessayer plus tard';

  @override
  String get toastLiked => 'Ajouté aux favoris';

  @override
  String get toastLoginRequiredKugou =>
      'Échec de l\'opération (assurez-vous d\'être connecté à votre compte Kugou)';

  @override
  String get toastLoginRequiredNetease =>
      'Échec de l\'opération (assurez-vous d\'être connecté à votre compte Netease)';

  @override
  String get toastNoQualityInfo =>
      'Cette chanson n\'a aucune information de qualité disponible et ne peut pas être téléchargée';

  @override
  String get toastUnliked => 'Retiré des favoris';

  @override
  String get commonClear => 'Effacer';

  @override
  String get commonEmptyContent => 'Aucun contenu';

  @override
  String commonLoadFailed(Object msg) {
    return 'Échec du chargement : $msg';
  }

  @override
  String get commonRetry => 'Réessayer';

  @override
  String get commentDuplicate => 'Ne renvoyez pas le même contenu deux fois';

  @override
  String get commentEmpty => 'Aucun commentaire pour le moment';

  @override
  String get commentHot => 'Populaires';

  @override
  String get commentInputEmpty => 'Le commentaire ne peut pas être vide';

  @override
  String get commentInputHint => 'Dites quelque chose…';

  @override
  String get commentLatest => 'Récents';

  @override
  String commentLoginRequired(Object platform) {
    return 'Connectez-vous à votre compte $platform pour commenter';
  }

  @override
  String commentNotFound(Object platform) {
    return 'Aucun commentaire $platform trouvé pour cette chanson';
  }

  @override
  String get commentPublished => 'Commentaire publié';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user : $text';
  }

  @override
  String get commentSend => 'Envoyer';

  @override
  String commentSendFailed(Object msg) {
    return 'Échec de l\'envoi : $msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$day/$month $time';
  }

  @override
  String get commentTitle => 'Commentaires';

  @override
  String get folderAdd => 'Ajouter';

  @override
  String get folderBrowse => 'Parcourir';

  @override
  String get folderEmpty =>
      'Aucun dossier de scan pour le moment. Utilisez les boutons ci-dessous pour en ajouter un';

  @override
  String get folderExists => 'Le dossier existe déjà ou est invalide';

  @override
  String get folderInvalid =>
      'Le dossier n\'existe pas, existe déjà ou est vide';

  @override
  String get folderPathHint => 'Saisissez un chemin absolu de dossier';

  @override
  String get folderRemove => 'Retirer';

  @override
  String get folderRemoveDescription =>
      'Une fois retiré, ce dossier ne sera plus scanné. Les morceaux déjà catalogués sont conservés.';

  @override
  String get folderRemoveTitle => 'Retirer le dossier de scan';

  @override
  String get loginFetchingQr => 'Obtention du code QR…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return 'Connecté à $platform';
  }

  @override
  String loginKugouLogin(Object platform) {
    return 'Se connecter avec $platform';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return 'Se connecter à $platform par code QR';
  }

  @override
  String get loginKugouResponseMissingToken =>
      'La réponse de connexion ne contient pas token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return 'Utilisez l\'application $platform pour scanner le code QR';
  }

  @override
  String loginKugouSession(Object platform) {
    return 'Connecté avec $platform';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return 'Connexion à $platform réussie, morceaux VIP débloqués';
  }

  @override
  String loginLoggedOut(Object platform) {
    return 'Déconnecté de $platform';
  }

  @override
  String loginLogoutWithId(Object id) {
    return 'Se déconnecter ($id)';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return 'Se connecter à $platform par code QR';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return 'Utilisez l\'application $platform pour scanner le code QR';
  }

  @override
  String get loginQrExpired => 'Le code QR a expiré';

  @override
  String get loginQrExpiredRegenerate =>
      'Le code QR a expiré, cliquez pour le régénérer';

  @override
  String get loginQrLogin => 'Connexion par code QR';

  @override
  String get loginRefreshQr => 'Actualiser le code QR';

  @override
  String get loginRegenerate => 'Régénérer';

  @override
  String get loginSuccess => 'Connexion réussie';

  @override
  String get loginWaitingConfirm =>
      'Scanné, veuillez confirmer la connexion sur votre téléphone';

  @override
  String get trackListArtistHotSongs => 'Chansons populaires de l\'artiste';

  @override
  String get trackListArtistSongs => 'Chansons de l\'artiste';

  @override
  String get trackListDailyRecommend => 'Recommandation quotidienne';

  @override
  String get trackListDailyRecommendSubtitle =>
      'Mise à jour quotidienne selon vos goûts';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return 'Aucune chanson (la recommandation quotidienne nécessite la connexion à votre compte $platform)';
  }

  @override
  String get trackListNoPlayableSource =>
      'Aucune source lisible (restriction VIP / aperçu possible)';

  @override
  String get trackListPlayAll => 'Tout lire';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return 'Échec de l\'obtention de la source de lecture : $msg';
  }

  @override
  String get trayNext => 'Suivant';

  @override
  String get trayPlayPause => 'Lecture / Pause';

  @override
  String get trayPrevious => 'Précédent';

  @override
  String get trayQuit => 'Quitter';

  @override
  String get trayShow => 'Afficher la fenêtre principale';

  @override
  String get commonPlayAll => 'Tout lire';

  @override
  String get commonPause => 'Pause';

  @override
  String get commonPlay => 'Lecture';

  @override
  String get commonRefresh => 'Actualiser';

  @override
  String get commonSearch => 'Rechercher';

  @override
  String get commonSongs => 'Titres';

  @override
  String get commonAlbums => 'Albums';

  @override
  String get commonArtists => 'Artistes';

  @override
  String get commonPlaylists => 'Playlists';

  @override
  String get commonDone => 'Terminé';

  @override
  String get commonUnknownError => 'Erreur inconnue';

  @override
  String commonSongCountHint(Object count) {
    return '$count titres au total · Cliquer pour lire';
  }

  @override
  String get platformNetease => 'NetEase';

  @override
  String get platformKugou => 'Kugou';

  @override
  String get platformAll => 'Tout';

  @override
  String toastPlayedAll(Object count) {
    return '$count titres lus';
  }

  @override
  String toastPlayFailed(Object msg) {
    return 'Échec de lecture : $msg';
  }

  @override
  String get toastMissingLocalPath => 'Chemin du fichier local manquant';

  @override
  String get toastLocateComingSoon => 'Ouvrir l\'explorateur (phase 2)';

  @override
  String get toastRemovedFromLibrary => 'Retiré de la bibliothèque';

  @override
  String get toastRemoveFailed => 'Échec de la suppression';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return 'Les recommandations du jour nécessitent une connexion $platform';
  }

  @override
  String get toastPlaylistEmpty => 'Aucun titre dans la playlist';

  @override
  String get toastAlbumEmpty => 'Aucun titre dans l\'album';

  @override
  String get toastPausedAll => 'Tout en pause';

  @override
  String get toastResumedAll => 'Tout repris';

  @override
  String get toastPaused => 'En pause';

  @override
  String get toastCanceledTask => 'Tâche annulée et supprimée';

  @override
  String get toastResumed => 'Téléchargement repris';

  @override
  String get toastRequeued => 'Re-ajouté à la file';

  @override
  String get toastDeletedSelected => 'Tâches sélectionnées supprimées';

  @override
  String get toastDeletedSelectedWithMedia => 'Tâches et fichiers supprimés';

  @override
  String get toastCleared => 'Tâches effacées';

  @override
  String get toastClearedWithMedia => 'Tâches et fichiers effacés';

  @override
  String get toastDeletedTask => 'Tâche supprimée';

  @override
  String get toastDeletedTaskWithMedia => 'Tâche et fichiers supprimés';

  @override
  String get pageHistoryRemoved => 'Retiré de l\'historique';

  @override
  String get pageHistoryClearTitle => 'Effacer l\'historique de lecture';

  @override
  String get pageHistoryClearMessage =>
      'Voulez-vous vraiment effacer tout l\'historique ? Cette action est irréversible.';

  @override
  String get pageHistoryCleared => 'Historique effacé';

  @override
  String get pageHistoryRemove => 'Retirer de l\'historique';

  @override
  String get pageHistorySubtitleEmpty =>
      'Historique de lecture stocké localement';

  @override
  String get pageHistoryEmpty => 'Aucun historique pour le moment';

  @override
  String get pageHistoryEmptyHint =>
      'Les titres lus s\'enregistrent automatiquement ici';

  @override
  String pageFavPlaylistCount(Object count) {
    return '$count playlists favorites';
  }

  @override
  String get pageFavPlaylistLoginHint =>
      'Connectez-vous pour voir vos playlists';

  @override
  String pageFavAlbumCount(Object count) {
    return '$count albums favoris';
  }

  @override
  String get pageFavAlbumLoginHint => 'Connectez-vous pour voir vos albums';

  @override
  String pageFavArtistCount(Object count) {
    return '$count artistes favoris';
  }

  @override
  String get pageFavArtistLoginHint => 'Connectez-vous pour voir vos artistes';

  @override
  String get pageFavLoadFailed => 'Échec du chargement des favoris';

  @override
  String get pageFavEmpty => 'Aucun favori pour le moment';

  @override
  String get pageFavEmptyHint =>
      'Les favoris de l\'app NetEase se synchronisent automatiquement ici';

  @override
  String get pageFavLoginTitle => 'Connectez-vous pour voir vos favoris';

  @override
  String get pageFavLoginDesc =>
      'Connectez-vous par QR avec NetEase Cloud Music pour synchroniser playlists, albums et artistes';

  @override
  String get pageFavKgCreated => 'Playlists créées';

  @override
  String get pageFavKgCollectedPlaylist => 'Playlists enregistrées';

  @override
  String get pageFavKgCollectedAlbum => 'Albums enregistrés';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '$count playlists créées';
  }

  @override
  String get pageFavKgCreatedLoginHint =>
      'Connectez-vous pour voir vos playlists créées';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '$count playlists enregistrées';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'Connectez-vous pour voir vos playlists enregistrées';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '$count albums enregistrés';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint =>
      'Connectez-vous pour voir vos albums enregistrés';

  @override
  String get pageFavKugouLoginDesc =>
      'Connectez-vous par QR avec Kugou pour synchroniser playlists et albums créés ou enregistrés';

  @override
  String get pageFavKugouEmptyHint =>
      'Synchronisation automatique après favori dans l\'app Kugou';

  @override
  String pageSearchLoadingTrack(Object title) {
    return 'Chargement : $title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — Détail à venir';
  }

  @override
  String get menuViewArtist => 'Voir l\'artiste';

  @override
  String get pageSearchArtistComingSoon => 'Page artiste (phase 2)';

  @override
  String get pageSearchInputHint => 'Entrez un mot-clé pour rechercher';

  @override
  String get pageSearchInputSubtitle =>
      'Titres / Albums / Artistes / Playlists';

  @override
  String get pageSearching => 'Recherche…';

  @override
  String get pageSearchEmpty => 'Aucun résultat';

  @override
  String get pageSearchEmptyHint => 'Essayez d\'autres mots-clés';

  @override
  String get pageSearchFailed => 'Échec de la recherche';

  @override
  String get pageLikedKugouLoginHint =>
      'Connectez-vous pour synchroniser les « J\'aime » Kugou';

  @override
  String get pageLikedNeteaseLoginHint =>
      'Connectez-vous pour synchroniser les favoris NetEase';

  @override
  String get pageLikedLoadFailed => 'Échec du chargement des j\'aime';

  @override
  String get pageLikedEmpty => 'Aucun titre aimé pour le moment';

  @override
  String get pageLikedKugouEmptyHint =>
      'Les « J\'aime » dans l\'app Kugou se synchronisent ici';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'Les cœurs dans NetEase se synchronisent ici';

  @override
  String get pageLikedLoginTitle => 'Connectez-vous pour voir vos titres aimés';

  @override
  String get pageLikedKugouLoginDesc =>
      'Connectez-vous par QR avec Kugou pour synchroniser vos « J\'aime »';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'Connectez-vous par QR avec NetEase pour synchroniser vos cœurs';

  @override
  String get libraryScanDirs => 'Dossiers analysés';

  @override
  String get libraryScanDirsDesc =>
      'Gérez les dossiers de musique locale ; analyse immédiate après ajout';

  @override
  String get libraryMediaStats => 'Statistiques';

  @override
  String get libraryMediaStatsDesc => 'Aperçu de la bibliothèque locale';

  @override
  String get libraryStatTracks => 'Titres';

  @override
  String get libraryStatDuration => 'Durée totale';

  @override
  String get libraryStatSize => 'Taille totale';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count titres';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count dossiers';
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
    return '$s s';
  }

  @override
  String get librarySearchHint => 'Rechercher des titres locaux';

  @override
  String get libraryNoMatch => 'Aucun titre correspondant';

  @override
  String get libraryScanningFiles => 'Comptage des fichiers…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count titres$extra';
  }

  @override
  String get libraryEmptyWaitScan => 'En attente de la première analyse';

  @override
  String get libraryEmpty => 'La bibliothèque locale est vide';

  @override
  String get libraryEmptyScanHint =>
      'Cliquez ci-dessous pour analyser maintenant';

  @override
  String get libraryEmptyAddHint =>
      'Ajoutez des dossiers musicaux pour les importer';

  @override
  String get libraryScanNow => 'Analyser maintenant';

  @override
  String get libraryAddFolder => 'Ajouter un dossier';

  @override
  String get menuLocateFile => 'Ouvrir l\'emplacement';

  @override
  String get menuLocateFileComingSoon => 'Gestionnaire de fichiers en Phase 2';

  @override
  String get menuRemoveFromLibrary => 'Retirer de la bibliothèque';

  @override
  String get playerBarCollapsePlayer => 'Réduire le lecteur';

  @override
  String get playerBarHideLyrics => 'Masquer les paroles';

  @override
  String get playerBarShowLyrics => 'Afficher les paroles';

  @override
  String get playerPageNotPlaying => 'Aucune lecture';

  @override
  String get playerPageLoadHint => 'Chargez une source pour commencer';

  @override
  String get playerPageQualityMenu => 'Changer la qualité';

  @override
  String get pageHomeRankTitle => 'Classements';

  @override
  String get pageHomePlaylistSquare => 'Place des playlists';

  @override
  String get pageHomeHotArtists => 'Artistes populaires';

  @override
  String get pageHomePlaylists => 'Playlists recommandées';

  @override
  String get pageHomeNewAlbums => 'Nouveautés';

  @override
  String get pageHomeRankSubtitle => 'Tendances en temps réel';

  @override
  String get pageHomePlaylistSquareSubtitle => 'Découvrez plus de playlists';

  @override
  String get pageHomeArtistSubtitle => 'Artistes populaires, avatars ronds';

  @override
  String get pageHomeLoadFailed => 'Échec du chargement';

  @override
  String get pageHomePlaylistsSubtitle => 'Recommandé selon vos goûts';

  @override
  String get pageHomeNewAlbumsSubtitle => 'Nouveautés à écouter';

  @override
  String get pageHomeHotArtistsSubtitle => 'Tout le monde écoute ça';

  @override
  String get pageHomeDaily => 'Recommandation du jour';

  @override
  String get pageHomeDailyLoggedIn => 'Sélectionné pour vous';

  @override
  String get pageHomeDailyLoginHint =>
      'Connectez-vous à NetEase pour des mises à jour quotidiennes';

  @override
  String get pageHomeDailyPlay => 'Lire les recommandations du jour';

  @override
  String get pageHomeDailyLogin => 'Connectez-vous pour débloquer';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting, $name';
  }

  @override
  String get greetingLate => 'Il est tard';

  @override
  String get greetingMorning => 'Bonjour';

  @override
  String get greetingAfternoon => 'Bon après-midi';

  @override
  String get greetingEvening => 'Bonsoir';

  @override
  String get greetingFallback => 'Qu\'avez-vous envie d\'écouter ?';

  @override
  String get downloadDeleteTaskOnly => 'Supprimer uniquement la tâche';

  @override
  String get downloadDeleteWithMedia => 'Supprimer la tâche et les fichiers';

  @override
  String downloadSelectedCount(Object count) {
    return '$count sélectionné(s)';
  }

  @override
  String get downloadSelectAll => 'Tout sélectionner';

  @override
  String get downloadDeselectAll => 'Tout désélectionner';

  @override
  String get downloadPauseAll => 'Tout mettre en pause';

  @override
  String get downloadResumeAll => 'Tout reprendre';

  @override
  String get downloadDeleteSelected => 'Supprimer la sélection';

  @override
  String get downloadExitSelect => 'Quitter la sélection multiple';

  @override
  String downloadActiveCount(Object count) {
    return 'En cours $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return 'Terminées $count';
  }

  @override
  String get downloadOpenDir => 'Ouvrir le dossier de téléchargement';

  @override
  String get downloadSelectMode => 'Sélection multiple';

  @override
  String get downloadEmpty => 'Aucun téléchargement';

  @override
  String get downloadEmptyHint =>
      'Clic droit sur un titre → Télécharger pour l\'ajouter';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return 'Supprimer $count tâche(s) sélectionnée(s)';
  }

  @override
  String get downloadDeleteSelectedMessage =>
      'Supprime les tâches sélectionnées et vide le cache .tmp ; médias supprimés par correspondance exacte.';

  @override
  String get downloadClearTitle => 'Effacer les téléchargements';

  @override
  String get downloadClearMessage =>
      'Supprime toutes les tâches et vide le cache .tmp ; médias supprimés par correspondance exacte.';

  @override
  String get downloadCancelTooltip =>
      'Annuler (supprimer la tâche et vider le cache)';

  @override
  String get downloadResume => 'Reprendre';

  @override
  String get downloadOpenDirTask => 'Ouvrir le dossier';

  @override
  String get downloadDeleteTask => 'Supprimer la tâche';

  @override
  String get downloadDeleteWithMediaExact =>
      'Supprimer la tâche et les fichiers (correspondance exacte)';

  @override
  String get downloadStatusQueued => 'En file…';

  @override
  String get downloadStatusResolving => 'Résolution de l\'URL…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return 'Téléchargement $percent% ($received) $speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return 'Téléchargement…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return 'En pause ($received)';
  }

  @override
  String get downloadStatusPaused => 'En pause';

  @override
  String downloadStatusFailed(Object error) {
    return 'Échec : $error';
  }

  @override
  String get downloadStatusFailedUnknown => 'Échec : erreur inconnue';

  @override
  String get downloadStatusCanceled => 'Annulée';

  @override
  String downloadStatusDone(Object size) {
    return 'Terminé ($size)';
  }

  @override
  String get downloadStatusAlready => 'Le fichier existe déjà';

  @override
  String get pageHomeTitle => 'Découvrir';

  @override
  String get settingsTitle => 'Paramètres';

  @override
  String get settingsCatAppearance => 'Apparence';

  @override
  String get settingsCatPlayback => 'Lecture';

  @override
  String get settingsCatLyrics => 'Paroles';

  @override
  String get settingsCatPreset => 'Comportement';

  @override
  String get settingsCatDownload => 'Téléchargement';

  @override
  String get settingsCatStorage => 'Stockage';

  @override
  String get settingsCatAbout => 'À propos';

  @override
  String get settingsAppearanceSubtitle => 'Thème · Préférences d\'interface';

  @override
  String get settingsPlaybackSubtitle =>
      'Moteur audio · Comportement de lecture';

  @override
  String get settingsLyricsSubtitle => 'Paroles du lecteur · Paroles de bureau';

  @override
  String get settingsPresetSubtitle =>
      'Filtre de lecture · Restauration des paroles · Étiquettes de liste';

  @override
  String get settingsDownloadSubtitle =>
      'Dossier · Concurrence · Limite · Qualité · Groupement · Nom de fichier';

  @override
  String get settingsStorageSubtitle =>
      'Répertoire de données · Fichiers de base de données';

  @override
  String get settingsAboutSubtitle => 'Version · Informations sur le projet';

  @override
  String get settingsCatDeveloper => 'Développeur';

  @override
  String get settingsDeveloperSubtitle =>
      'Mode développeur · Fonctions masquées';

  @override
  String get settingsDeveloperTitle => 'Mode développeur';

  @override
  String get settingsDeveloperMode => 'Mode développeur';

  @override
  String get settingsDeveloperModeOn =>
      'Activé (fonctions de téléchargement visibles)';

  @override
  String get settingsDeveloperModeOff =>
      'Désactivé (fonctions de téléchargement masquées)';

  @override
  String get settingsDeveloperDownloadModule => 'Module de téléchargement';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      'L\'entrée « Télécharger » de la barre latérale, l\'élément « Télécharger » du menu contextuel et la catégorie « Télécharger » des réglages ne sont visibles que lorsque le mode développeur est activé.';

  @override
  String get settingsDeveloperNote =>
      'Le mode développeur est destiné au débogage local et à un usage personnel. Utilisation à vos risques et périls.';

  @override
  String get settingsDevFpsMonitor =>
      'Superposition de surveillance FPS/mémoire';

  @override
  String get settingsDevFpsMonitorDesc =>
      'Affiche en temps réel les FPS, le temps de frame moyen et la mémoire du processus en haut à droite (cliquer pour réduire). Désactivé par défaut ; désactivé aussi lorsque le mode développeur est coupé.';

  @override
  String get settingsDeveloperEnabled => 'Mode développeur activé';

  @override
  String get settingsDeveloperDisabled => 'Mode développeur désactivé';

  @override
  String get settingsDeveloperHoldHint =>
      'Maintenez 10 secondes pour activer le mode développeur (souris : maintenir enfoncé)';

  @override
  String get settingsSearchHint => 'Rechercher des paramètres…';

  @override
  String settingsSearchNoResult(Object query) {
    return 'Aucun paramètre trouvé pour「$query」';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '$count correspondances';
  }

  @override
  String get settingsSectionTheme => 'Thème';

  @override
  String get settingsThemeMode => 'Mode de thème';

  @override
  String get settingsThemeModeDesc => 'Clair / Sombre / Suivre le système';

  @override
  String get settingsThemeLight => 'Clair';

  @override
  String get settingsThemeDark => 'Sombre';

  @override
  String get settingsThemeSystem => 'Suivre le système';

  @override
  String get settingsThemeNote =>
      'Thème sombre par défaut ;「Suivre le système」suit l\'apparence du système.';

  @override
  String get settingsSectionAccent => 'Couleur d\'accent';

  @override
  String get settingsAccentTitle => 'Graine de couleur primaire';

  @override
  String settingsAccentSystem(Object color) {
    return 'Suivre l\'accent système（$color）';
  }

  @override
  String get settingsAccentSystemFallback =>
      'Suivre l\'accent système（échec de lecture, repli personnalisé）';

  @override
  String get settingsAccentDefault => 'Bleu vif par défaut（système de design）';

  @override
  String get settingsAccentCustom =>
      'Personnalisé（couleurs générées depuis la graine）';

  @override
  String get settingsAccentDefaultTooltip => 'Bleu par défaut';

  @override
  String get settingsAccentSystemTooltip => 'Suivre l\'accent système';

  @override
  String get settingsAccentCustomTooltip => 'Sélecteur de couleur personnalisé';

  @override
  String get settingsSectionLayout => 'Mise en page';

  @override
  String get settingsFloatingBar => 'Barre de lecteur flottante';

  @override
  String get settingsFloatingBarOn =>
      'Capsule arrondie centrée en bas（verre dépoli + ombre）';

  @override
  String get settingsFloatingBarOff => 'Ancré pleine largeur（par défaut）';

  @override
  String get settingsSectionFont => 'Police d\'interface';

  @override
  String get settingsFontTitle => 'Police d\'interface';

  @override
  String get settingsFontMiSans => 'MiSans（par défaut）';

  @override
  String get settingsFontNoto => 'Noto Sans SC（métriques standard）';

  @override
  String get settingsFontHarmony =>
      'HarmonyOS Sans SC（usage commercial gratuit）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans SC';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => 'Langue de l\'interface';

  @override
  String get settingsLanguageTitle => 'Langue de l\'interface';

  @override
  String get settingsLanguageDesc =>
      'Changer la langue d\'affichage de l\'interface';

  @override
  String get settingsLangSystem => 'Suivre le système';

  @override
  String get settingsSectionCover => 'Pochette';

  @override
  String get settingsCoverRadius => 'Rayon des coins de pochette';

  @override
  String get settingsCoverRadiusSharp => 'Carré（densité d\'information élevée）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return 'Rayon de ${radius}px';
  }

  @override
  String get settingsCoverRadiusSharpLabel => 'Carré';

  @override
  String get settingsCoverRadiusRoundedLabel => 'Arrondi';

  @override
  String get settingsCoverRadiusLargeLabel => 'Très arrondi';

  @override
  String get settingsPickerTitle => 'Couleur d\'accent personnalisée';

  @override
  String get settingsPickerHexLabel => 'Valeur de couleur（#RRGGBB）';

  @override
  String get settingsApply => 'Appliquer';

  @override
  String get settingsSectionAudio => 'Audio';

  @override
  String get settingsPassthrough =>
      'Passage de qualité d\'origine（pas de transcodage）';

  @override
  String get settingsPassthroughOn =>
      'Conserver la fréquence source（Hi-Res/sans perte）';

  @override
  String get settingsPassthroughOff => 'Pipeline de transcodage unifié 48kHz';

  @override
  String get settingsPassthroughNote =>
      'Le passthrough conserve la fréquence source ; sinon rééchantillonnage à 48kHz. Effet après rechargement de la piste.';

  @override
  String get volumeMute => 'Couper le son';

  @override
  String get volumeUnmute => 'Rétablir le son';

  @override
  String get settingsSectionMemory => 'Mémoire et démarrage';

  @override
  String get settingsSessionMemory => 'Mémoire de session';

  @override
  String get settingsSessionMemoryOn =>
      'Mémoriser la file, la position et le mode avant de quitter ; restaurer au prochain démarrage';

  @override
  String get settingsSessionMemoryOff =>
      'Ne pas mémoriser la session（vide au prochain démarrage）';

  @override
  String get settingsAutoPlay => 'Lecture automatique au démarrage';

  @override
  String get settingsAutoPlayNeedMemory =>
      'Activez d\'abord「Mémoire de session」';

  @override
  String get settingsAutoPlayOn =>
      'Restaurer la dernière session et lire automatiquement';

  @override
  String get settingsAutoPlayOff =>
      'Restaurer la session sans reprendre la lecture';

  @override
  String get settingsSectionSpectrum => 'Spectre';

  @override
  String get settingsSpectrum => 'Visualiseur de spectre';

  @override
  String get settingsSpectrumOn =>
      'Afficher les barres de spectre dans le lecteur（0.65 opacité lecture / 0.15 pause）';

  @override
  String get settingsSpectrumOff => 'Ne pas rendre le spectre dans le lecteur';

  @override
  String get settingsSpectrumBarWidth => 'Largeur des barres de spectre';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12, lecteur plein écran uniquement）';
  }

  @override
  String get settingsBarSpectrum => 'Spectre de la barre de lecture';

  @override
  String get settingsBarSpectrumOn =>
      'Mini spectre sous l\'heure (si pas de paroles ou mini paroles désactivées)';

  @override
  String get settingsBarSpectrumOff =>
      'Masquer le mini spectre de la barre de lecture';

  @override
  String get settingsCoverBeatScale =>
      'Mettre la pochette à l\'échelle du rythme';

  @override
  String get settingsCoverBeatScaleOn => 'La pochette pulse au rythme';

  @override
  String get settingsCoverBeatScaleOff =>
      'Pochette statique（seulement lecture/pause）';

  @override
  String get settingsTransitionStyle => 'Transition des médias';

  @override
  String get settingsTransitionStyleDesc =>
      'Animation de transition lors du changement de chanson';

  @override
  String get settingsTransitionStyleScale => 'Échelle';

  @override
  String get settingsTransitionStyleSlide => 'Glissement';

  @override
  String get settingsSectionShortcuts => 'Raccourcis';

  @override
  String get settingsShortcutSpace => 'Espace';

  @override
  String get settingsShortcutSpaceDesc => 'Lecture / Pause';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => 'Reculer / Avancer de 10 secondes';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => 'Bibliothèque musicale';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc =>
      'Retour（fermer la boîte de dialogue / quitter le lecteur plein écran）';

  @override
  String get settingsSectionPlayerLyrics => 'Paroles du lecteur';

  @override
  String get settingsPlayerLyrics => 'Paroles dans le lecteur';

  @override
  String get settingsPlayerLyricsOn =>
      'Panneau de paroles à droite du lecteur plein écran（ligne actuelle en surbrillance + clic pour chercher）';

  @override
  String get settingsPlayerLyricsOff =>
      'Pas de zone de paroles dans le lecteur plein écran';

  @override
  String get settingsBarLyrics => 'Paroles de la barre de lecture';

  @override
  String get settingsBarLyricsOn =>
      'Parole actuelle sous l\'heure (défilement automatique si trop long)';

  @override
  String get settingsBarLyricsOff =>
      'Masquer les mini paroles de la barre de lecture';

  @override
  String get settingsShowTranslation => 'Afficher la traduction';

  @override
  String get settingsShowTranslationOn =>
      'Traduction entre parenthèses après la ligne originale';

  @override
  String get settingsShowTranslationOff => 'Masquer la traduction des paroles';

  @override
  String get settingsSectionLyricStyle => 'Style des paroles';

  @override
  String get settingsLyricFontSize => 'Taille de police des paroles';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（ligne actuelle +3px en surbrillance）';
  }

  @override
  String get settingsLyricLineHeight => 'Hauteur de ligne des paroles';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（espacement inclus）';
  }

  @override
  String get settingsLyricPlayedColor => 'Couleur lue';

  @override
  String get settingsLyricPlayedColorDesc =>
      'Couleur de surbrillance pour la ligne de paroles actuelle';

  @override
  String get settingsLyricUnplayedColor => 'Couleur non lue';

  @override
  String get settingsLyricUnplayedColorDesc =>
      'Couleur pour les prochaines lignes de paroles';

  @override
  String get settingsLyricsNote =>
      'Style de paroles applicable uniquement au lecteur plein écran ; effet après intégration（Phase 2）.';

  @override
  String get settingsSectionFilter => 'Filtre de lecture';

  @override
  String get settingsDjMode => 'Fuck DJ Mode';

  @override
  String get settingsDjModeOn =>
      'Passer automatiquement les pistes de basse qualité comme les remix DJ';

  @override
  String get settingsDjModeOff =>
      'Passer automatiquement à la piste suivante quand une version DJ est détectée';

  @override
  String get settingsSectionLyricsFilter => 'Paroles';

  @override
  String get settingsUncensor => 'Débloquer les grossièretés';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => 'Affichage de la liste';

  @override
  String get settingsHideVip => 'Masquer les étiquettes VIP';

  @override
  String get settingsHideVipOn =>
      'Ne pas afficher les badges VIP / payants dans la liste de chansons';

  @override
  String get settingsHideVipOff =>
      'Afficher les badges de niveau payant par défaut（VIP / EP）';

  @override
  String get settingsHideQuality => 'Masquer les étiquettes de qualité';

  @override
  String get settingsHideQualityOn =>
      'Ne pas afficher les badges de qualité dans la liste de chansons';

  @override
  String get settingsHideQualityOff =>
      'Afficher la meilleure qualité disponible par défaut（Hi-Res / Sans perte / HQ…）';

  @override
  String get settingsShowSubtitle => 'Afficher le sous-titre';

  @override
  String get settingsShowSubtitleOn =>
      'Afficher les alias après le nom de la chanson, ex. (Live) / (Remix)';

  @override
  String get settingsShowSubtitleOff =>
      'La liste affiche uniquement l\'artiste, sans alias';

  @override
  String get settingsEnergySaving => 'Mode économie d\'énergie';

  @override
  String get settingsEnergySavingNote =>
      'Une fois activé, la fréquence du spectre passe à ~300ms (référence 100ms), économisant le CPU ; le rendu et l\'interpolation ne sont pas affectés, le changement s\'applique instantanément.';

  @override
  String get settingsEnergySavingOn =>
      'Actuellement en mode réduction de fréquence';

  @override
  String get settingsEnergySavingOff => 'Actuellement en mode standard';

  @override
  String get settingsSearchEnergySavingSubtitle =>
      'Réduire la fréquence du spectre pour économiser le CPU';

  @override
  String get settingsPerformanceMode => 'Mode performance';

  @override
  String get settingsPerformanceModeOn => 'Actuellement en mode figé';

  @override
  String get settingsPerformanceModeOff => 'Actuellement en mode animation';

  @override
  String get settingsSectionDir => 'Répertoire';

  @override
  String get settingsDownloadRootHint =>
      'Dossier de téléchargement（Entrée pour enregistrer）';

  @override
  String get settingsRestoreDefault => 'Restaurer la valeur par défaut';

  @override
  String get settingsDownloadRootNote =>
      'Par défaut : suit le dossier de la bibliothèque；changer de dossier interrompt les téléchargements en cours. Entrée pour valider.';

  @override
  String get settingsSectionFilename => 'Nom de fichier';

  @override
  String get settingsDownloadTemplateHint =>
      'Modèle de nom de fichier（Entrée pour enregistrer）';

  @override
  String get settingsDownloadTemplateNote =>
      'Espaces réservés : <artist> · <title> · <album>. S\'applique aux nouvelles tâches uniquement ; Entrée pour valider.';

  @override
  String get settingsSectionQuality => 'Qualité';

  @override
  String get settingsDownloadQuality => 'Qualité de téléchargement par défaut';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return 'Le dialogue「Télécharger」a pour défaut $quality ; rétrogradation automatique si le niveau manque';
  }

  @override
  String get settingsDownloadQualityNote =>
      'Niveaux : Hi-Res → Sans perte → HQ → SQ → LQ ; rétrogradation automatique si le niveau est indisponible.';

  @override
  String get settingsSectionConcurrent => 'Concurrence';

  @override
  String get settingsDownloadConcurrent => 'Téléchargements simultanés';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count tâches parallèles（1~5）';
  }

  @override
  String get settingsDownloadGrouping => 'Groupement de dossiers';

  @override
  String get settingsGroupingFlat =>
      'Tout à plat dans le dossier de téléchargement';

  @override
  String get settingsGroupingPlatform =>
      'Sous-dossier par plateforme（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => 'Sous-dossier par artiste';

  @override
  String get settingsGroupingFlatLabel => 'À plat';

  @override
  String get settingsGroupingPlatformLabel => 'Par plateforme';

  @override
  String get settingsGroupingArtistLabel => 'Par artiste';

  @override
  String get settingsSectionSpeedLimit => 'Limite de vitesse';

  @override
  String get settingsDownloadSpeedLimit =>
      'Limite de vitesse de téléchargement';

  @override
  String get settingsSpeedUnlimited => 'Illimité（par défaut）';

  @override
  String settingsSpeedLimited(Object speed) {
    return 'Limité à $speed, effet immédiat';
  }

  @override
  String get settingsSpeedUnlimitedLabel => 'Illimité';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote =>
      'Limite effective immédiatement, sans interrompre les tâches en cours（par pas de 0.5 MB/s, 0 = illimité）.';

  @override
  String get settingsSectionHistory => 'Historique';

  @override
  String get settingsDownloadHistoryLimit =>
      'Limite d\'historique de téléchargement';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count entrées（10~500）· purge automatique des plus anciennes au-delà de la limite';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count entrées';
  }

  @override
  String get settingsDownloadHistoryNote =>
      'Seuls les enregistrements échoués/annulés les plus anciens sont purgés au-delà de la limite ; tâches en cours non concernées.';

  @override
  String get settingsGroupingNote =>
      'Groupement par artiste v2 pris en charge（À plat / Par plateforme / Par artiste）.';

  @override
  String get settingsSectionFingerprint => 'Empreinte de l\'appareil';

  @override
  String get settingsFingerprintNote =>
      'Identifiant d\'appareil envoyé avec les téléchargements Kugou / Netease ; généré au premier lancement et stable, unique par utilisateur.';

  @override
  String get settingsDownloadDynamicFingerprint => 'Empreinte dynamique';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      'Régénère l\'identifiant d\'appareil à chaque lancement (ancien comportement) ; peut déclencher le contrôle des risques de la plateforme. Désactivé par défaut.';

  @override
  String get settingsResetFingerprint =>
      'Réinitialiser l\'empreinte de l\'appareil';

  @override
  String get settingsResetFingerprintDesc =>
      'Après réinitialisation, cette machine apparaîtra comme un nouvel appareil pour Kugou / Netease ; les sessions liées à l\'ancienne empreinte peuvent cesser de fonctionner. Réinitialiser ?';

  @override
  String get toastFingerprintReset => 'Empreinte de l\'appareil réinitialisée';

  @override
  String get toastDownloadRootEmpty =>
      'Le dossier de téléchargement ne peut pas être vide';

  @override
  String get toastDownloadRootUpdated => 'Dossier de téléchargement mis à jour';

  @override
  String get toastTemplateEmpty =>
      'Le modèle de nom de fichier ne peut pas être vide';

  @override
  String get toastTemplateUpdated => 'Modèle de nom de fichier mis à jour';

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
  String get settingsSectionFileLocation => 'Emplacements des fichiers';

  @override
  String get settingsDataDir => 'Répertoire de données';

  @override
  String get settingsLibraryDb =>
      'Base de données de la bibliothèque multimédia';

  @override
  String get settingsUserDb => 'Base de données utilisateur（chiffrée）';

  @override
  String get settingsLibraryDbLabel => 'Chemin de la bibliothèque';

  @override
  String get settingsUserDbLabel => 'Chemin des données utilisateur';

  @override
  String get settingsCopy => 'Copier';

  @override
  String toastCopied(Object label) {
    return '$label copié';
  }

  @override
  String get settingsStorageNote =>
      'Médias（tracks）et données utilisateur（subsonic_*）physiquement séparés ; chemins surchargeables via ARCHOERA_DATA_DIR.';

  @override
  String get settingsSectionCache => 'Gestion du cache';

  @override
  String get settingsCacheNote =>
      'Le cache accélère la navigation et la lecture ; il se reconstruit automatiquement après suppression. La bibliothèque, l\'historique et les comptes ne sont pas affectés.';

  @override
  String get settingsCacheGroupDisk => 'Cache de base de données (disque)';

  @override
  String get settingsCacheGroupMem => 'Cache en mémoire (dans le processus)';

  @override
  String get settingsCacheLimitLyric => 'Limite du cache de paroles';

  @override
  String get settingsCacheLimitCover => 'Limite du cache des pochettes';

  @override
  String get settingsCacheLimitUnlimited => 'Illimité';

  @override
  String get settingsCacheNoLimitConfirmTitle => 'Retirer la limite du cache ?';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      'Sans limite, les caches de paroles et de pochettes peuvent occuper une mémoire illimitée, entraînant pression mémoire et ralentissements. Retirer la limite ?';

  @override
  String get settingsCacheNoLimitConfirm => 'Retirer la limite';

  @override
  String get settingsSongCache => 'Cache des chansons';

  @override
  String get settingsSongCacheNote =>
      'Les chansons en ligne écoutées sont mises en cache sur le disque local ; la réécoute lit directement le fichier local (économie de données, plus rapide, lisible hors ligne). Au-delà de la limite, les titres les moins récemment utilisés sont supprimés automatiquement (LRU). Le minimum de 16 MiB permet de mettre en cache une chanson complète en 320 kbit/s (~2,4 MiB/min). Le cache se reconstruit automatiquement ; bibliothèque, historique et comptes ne sont pas affectés.';

  @override
  String get settingsSongCacheOn =>
      'Activé ; les lectures en cache passent par le disque local';

  @override
  String get settingsSongCacheOff =>
      'Désactivé : le cache multimédia ne sera pas enregistré localement';

  @override
  String get settingsSongCacheLimitTitle => 'Limite du cache';

  @override
  String settingsCacheSongs(Object count) {
    return '$count chansons';
  }

  @override
  String get settingsSearchSongCacheSubtitle =>
      'Activation et limite (MiB) du cache disque des chansons en ligne';

  @override
  String get settingsCacheLiked => 'Cache de la liste « J\'aime »';

  @override
  String get settingsCacheLyric => 'Cache du contenu des paroles';

  @override
  String get settingsCacheLyricMatch => 'Cache de correspondance des paroles';

  @override
  String get settingsCacheLyricTtml => 'Cache de paroles TTML';

  @override
  String get settingsCacheCover => 'Cache des pochettes';

  @override
  String settingsCacheEntries(Object count) {
    return '$count entrées';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count images';
  }

  @override
  String get settingsCacheRefresh => 'Actualiser';

  @override
  String get settingsCacheClear => 'Vider';

  @override
  String get settingsCacheClearAll => 'Tout vider';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return 'Vider « $name » ?';
  }

  @override
  String get settingsCacheClearConfirmDesc =>
      'Supprime toutes les données de ce cache ; il se reconstruit automatiquement à la prochaine utilisation. Irréversible.';

  @override
  String get settingsCacheClearAllConfirmTitle => 'Vider tous les caches ?';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      'Supprime tous les caches ci-dessus (mémoire et disque). La bibliothèque, l\'historique et les comptes ne sont pas affectés.';

  @override
  String toastCacheCleared(Object name) {
    return 'Cache $name vidé';
  }

  @override
  String get toastCacheAllCleared => 'Tous les caches vidés';

  @override
  String get settingsSecuritySection => 'Destruction sécurisée';

  @override
  String get settingsSecurityNote =>
      'Supprime de façon irréversible tous les identifiants et sessions de compte (mots de passe des serveurs de streaming, sessions Netease/Kugou, comptes Subsonic locaux) et invalide les jetons de la plateforme. La bibliothèque, l\'historique et les téléchargements ne sont pas affectés.';

  @override
  String get settingsSecurityStreaming =>
      'Identifiants des serveurs de streaming';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count serveur(s)';
  }

  @override
  String get settingsSecurityStreamingDesc =>
      'Mots de passe et jetons d\'accès';

  @override
  String get settingsSecuritySession => 'Sessions de comptes tiers';

  @override
  String get settingsSecuritySessionDesc => 'État de connexion Netease / Kugou';

  @override
  String get settingsSecurityUserDb => 'Base d\'utilisateurs locale';

  @override
  String get settingsSecurityUserDbDesc => 'Comptes Subsonic et favoris';

  @override
  String get settingsSecurityLoggedIn => 'Connecté';

  @override
  String get settingsSecurityDestroy => 'Détruire';

  @override
  String get settingsSecurityDestroyAll => 'Tout détruire';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return 'Détruire « $name » ?';
  }

  @override
  String get settingsSecurityConfirmAllTitle =>
      'Détruire toutes les données sensibles ?';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return 'Les jetons des plateformes concernées seront invalidés, puis les fichiers seront écrasés et supprimés. Cette opération est irréversible. Saisissez « $word » pour confirmer.';
  }

  @override
  String get settingsSecurityConfirmWord => 'détruire';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return 'Saisissez « $word »';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return 'Détruit : $name';
  }

  @override
  String get toastSecurityAllDestroyed =>
      'Toutes les données sensibles ont été détruites';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return 'Échec de la destruction, le fichier peut subsister : $path';
  }

  @override
  String get settingsDeviceBindSection => 'Avancé · Liaison à l\'appareil';

  @override
  String get settingsDeviceBindNote =>
      'Option avancée (opt-in) : sans mot de passe sur cet appareil + mot de passe de récupération après changement d\'appareil, sans dépendre du stockage sécurisé du système. L\'activer lit un identifiant d\'appareil local (stocké localement uniquement, jamais téléversé). Désactivé par défaut ; le chiffrement v1 par défaut suffit à la plupart des utilisateurs.';

  @override
  String get settingsDeviceBindSwitch => 'Sans mot de passe lié à l\'appareil';

  @override
  String get settingsDeviceBindSwitchDesc =>
      'Déverrouillage automatique sur cet appareil ; mot de passe de récupération après changement d\'appareil';

  @override
  String get settingsDeviceBindSwitchOffDesc =>
      'Désactivé. Le stockage sécurisé du système est indisponible ici ; activez la liaison à l\'appareil pour un déverrouillage sans mot de passe';

  @override
  String get settingsDeviceBindSwitchV1Desc =>
      'Mode v1 actuel (stockage sécurisé du système) ; activer met à niveau vers la liaison à l\'appareil (sans mot de passe + mot de passe de récupération, données existantes conservées)';

  @override
  String get settingsDeviceBindSwitchV2Desc =>
      'Mode v2 actuel (mot de passe) ; l\'activer nécessite d\'abord de saisir le mot de passe actuel pour déverrouiller, puis met à niveau vers la liaison à l\'appareil (sans mot de passe sur cet appareil)';

  @override
  String get settingsDeviceBindPrivacyTitle =>
      'Activer le sans mot de passe lié à l\'appareil ?';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      'Un identifiant d\'appareil local (Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID) sera lu et lié à votre coffre ; stocké localement uniquement, jamais téléversé. Remarque : cette opération ne peut pas revenir au mode sans mot de passe actuel du système — désactiver la liaison plus tard bascule en mode mot de passe (saisie à chaque lancement).';

  @override
  String get settingsDeviceBindEnable => 'Activer';

  @override
  String get settingsDeviceBindRecoveryTitle =>
      'Définir un mot de passe de récupération (facultatif)';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      'Utilisez le mot de passe de récupération pour déverrouiller les identifiants après un changement d\'appareil/réinstallation. Laissez vide pour ne pas en définir : aucune récupération possible après changement d\'appareil (fail-closed ; effacement et reconstruction requis).';

  @override
  String get settingsDeviceBindRecoveryHint => 'Mot de passe de récupération';

  @override
  String get settingsDeviceBindSkip => 'Activer sans mot de passe';

  @override
  String get settingsDeviceBindChangeRecovery =>
      'Définir / modifier le mot de passe de récupération';

  @override
  String get settingsDeviceBindChangeRecoveryTitle =>
      'Définir un nouveau mot de passe de récupération';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      'L\'ancien mot de passe devient immédiatement invalide. Retenez bien le nouveau : le déverrouillage des identifiants après changement d\'appareil en dépend.';

  @override
  String get settingsDeviceBindRebind => 'Relier de nouveau cet appareil';

  @override
  String get settingsDeviceBindRebindDesc =>
      'Re-sceller avec l\'empreinte actuelle de l\'appareil ; l\'ancienne empreinte devient immédiatement invalide (à utiliser après récupération)';

  @override
  String get settingsDeviceBindRebindTitle =>
      'Relier de nouveau cet appareil ?';

  @override
  String get settingsDeviceBindRebindConfirm => 'Relier maintenant';

  @override
  String get settingsDeviceBindClose => 'Désactiver la liaison à l\'appareil';

  @override
  String get settingsDeviceBindCloseDesc =>
      'Supprimer le scellé d\'entropie de l\'appareil ; le coffre repasse en mode mot de passe';

  @override
  String get settingsDeviceBindCloseTitle =>
      'Désactiver la liaison à l\'appareil ?';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      'Le scellé d\'entropie de l\'appareil sera supprimé et le coffre passe en mode mot de passe : un mot de passe sera requis à chaque session. Ce mot de passe devient votre nouveau mot de passe de session. Saisissez le mot de passe de récupération actuel pour confirmer.';

  @override
  String get settingsDeviceBindCloseHint =>
      'Mot de passe de récupération actuel';

  @override
  String get settingsDeviceBindRecoveryBanner =>
      'Changement d\'appareil ou fichier d\'entropie corrompu détecté : identifiants verrouillés, mot de passe de récupération requis';

  @override
  String get settingsDeviceBindRecover => 'Récupérer';

  @override
  String get settingsDeviceBindRecoverTitle =>
      'Saisir le mot de passe de récupération';

  @override
  String get settingsDeviceBindRecoverDesc =>
      'Déverrouillez les identifiants avec le mot de passe de récupération ; après succès, reliez de nouveau cet appareil pour restaurer le sans mot de passe.';

  @override
  String get settingsDeviceBindShowPassword =>
      'Afficher / masquer le mot de passe';

  @override
  String get toastDeviceBindEnabled =>
      'Sans mot de passe lié à l\'appareil activé';

  @override
  String get toastDeviceBindRecoverySet =>
      'Mot de passe de récupération mis à jour';

  @override
  String get toastDeviceBindRebound => 'Appareil relié de nouveau';

  @override
  String get toastDeviceBindClosed =>
      'Liaison désactivée ; le coffre utilise désormais le mode mot de passe';

  @override
  String get toastDeviceBindRecoveryNeeded =>
      'Aucun mot de passe de récupération défini ; impossible de désactiver la liaison';

  @override
  String toastDeviceBindCloseFailed(Object error) {
    return 'Échec de la désactivation : $error';
  }

  @override
  String get toastDeviceBindRecovered =>
      'Identifiants récupérés ; reliez de nouveau cet appareil pour restaurer le sans mot de passe';

  @override
  String get toastDeviceBindRecoverFailed =>
      'Mot de passe de récupération incorrect ou échec du déverrouillage ; identifiants toujours verrouillés';

  @override
  String get settingsSchemeIntroTitle => 'Méthode de chiffrement';

  @override
  String get settingsSchemeIntroDesc =>
      'Vos identifiants de connexion (cookies) sont protégés par une méthode de chiffrement. La méthode LEGACY (recommandée) est activée : la clé maîtresse vit dans le stockage sécurisé du système — stable et fiable. Pour une protection renforcée, passez à Vault (expérimental) dans Paramètres → Méthode de chiffrement des identifiants — notez que le changement reconstruit la base de données et perd tous les identifiants de connexion.';

  @override
  String get settingsSchemeIntroGotIt => 'Compris';

  @override
  String get settingsSchemeSection => 'Méthode de chiffrement des identifiants';

  @override
  String get settingsSchemeNote =>
      'Choisissez comment chiffrer les identifiants de connexion. LEGACY : stockage sécurisé du système, stable et fiable (recommandé). Vault : méthode expérimentale à double facteur 2-of-2 — protection renforcée mais risque de perte de cookies. Le changement de méthode reconstruit la base de données et nécessite une nouvelle connexion.';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => 'Recommandé';

  @override
  String get settingsSchemeCryptoDesc =>
      'Les cookies sont chiffrés par le stockage sécurisé du système (Windows DPAPI / macOS Trousseau / Linux libsecret). Stable et fiable.';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'Méthode LEGACY : la clé maîtresse est entièrement protégée par le stockage sécurisé du système. Bon équilibre entre sécurité et stabilité pour un usage quotidien.';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => 'Expérimental';

  @override
  String get settingsSchemeVaultDesc =>
      'Chiffrement à double facteur 2-of-2 (part système + part utilisateur, les deux requises). Plus résistant aux attaques hors ligne, mais des cookies peuvent être perdus en cas d\'anomalie.';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Méthode Vault : la clé maîtresse est divisée en une part système et une part utilisateur — les deux requises. Choisissez v1 protection système / v2 mot de passe / v3 liaison à l\'appareil comme niveau de scellement.';

  @override
  String get settingsSchemeSwitchTitle => 'Changer de méthode de chiffrement ?';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault est expérimental : des cookies peuvent être perdus après le changement.';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      'LEGACY et Vault utilisent des structures chiffrées incompatibles. Le changement détruit le coffre actuel et reconstruit la base de données ; tous les identifiants de connexion (Netease / Kugou / comptes de streaming) seront perdus et nécessiteront une nouvelle connexion.';

  @override
  String get settingsSchemeSwitchKeep => 'Conserver l\'actuel';

  @override
  String get settingsSchemeSwitchConfirm => 'Changer et reconstruire';

  @override
  String get toastSchemeSwitched =>
      'Méthode de chiffrement changée ; effective après redémarrage';

  @override
  String get settingsVaultSection => 'Chiffrement des identifiants';

  @override
  String get settingsVaultNote =>
      'Choisissez le niveau de protection des identifiants : v1 protection système (défaut) / v2 protection par mot de passe / v3 liaison à l\'appareil (option avancée opt-in ; lit un identifiant d\'appareil local, stocké localement uniquement, jamais téléversé). v1 ↔ v2 peuvent être alternés librement ; v3 est le niveau terminal et retombe sur v2 une fois désactivé.';

  @override
  String get settingsVaultModeV1 => 'v1 Protection système';

  @override
  String get settingsVaultModeV2 => 'v2 Mot de passe';

  @override
  String get settingsVaultModeV3 => 'v3 Liaison à l\'appareil';

  @override
  String get settingsVaultModeDescOs =>
      'v1 Protection système : identifiants chiffrés par le stockage sécurisé du système (Windows DPAPI / macOS Trousseau / Linux libsecret), sans mot de passe sur cet appareil.';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 Protection par mot de passe : identifiants chiffrés par un mot de passe saisi à chaque lancement. Vous pouvez revenir à la protection système (v1) à tout moment.';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 Liaison à l\'appareil : sans mot de passe sur cet appareil ; un mot de passe de récupération est requis après un changement d\'appareil. Impossible de redescendre directement en v1 — la désactivation retombe sur le mode mot de passe v2.';

  @override
  String get settingsVaultModeDescUnknown =>
      'Lecture du niveau de chiffrement…';

  @override
  String get settingsVaultSwitchToPasswordTitle =>
      'Passer à la protection par mot de passe (v2)';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      'Les identifiants seront protégés par un mot de passe saisi à chaque lancement. Votre clé maîtresse et vos données existantes sont conservées ; vous pouvez revenir à la protection système (v1) à tout moment.';

  @override
  String get settingsVaultSwitchToPasswordNewHint =>
      'Définir un nouveau mot de passe';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint =>
      'Ressaisir le nouveau mot de passe';

  @override
  String get settingsVaultSwitchToPasswordMismatch =>
      'Les deux saisies ne correspondent pas';

  @override
  String get settingsVaultSwitchToOsTitle =>
      'Revenir à la protection système (v1)';

  @override
  String get settingsVaultSwitchToOsDesc =>
      'Les identifiants seront protégés par le stockage sécurisé du système ; aucun mot de passe requis. Vous pouvez revenir à la protection par mot de passe (v2) à tout moment.';

  @override
  String get settingsVaultNeedUnlockFirst =>
      'La protection par mot de passe n\'est pas déverrouillée : déverrouillez d\'abord, puis changez';

  @override
  String get settingsVaultV3NoDirectV1 =>
      'La liaison à l\'appareil (v3) ne peut pas redescendre directement en v1 : désactivez d\'abord la liaison pour retomber en mode mot de passe v2';

  @override
  String get settingsVaultCloseV3PasswordTitle =>
      'Désactiver la liaison : définir un nouveau mot de passe';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      'Aucun mot de passe de récupération n\'a été défini lors de l\'activation de la liaison (sans mot de passe sur cet appareil). La désactiver passe en protection par mot de passe (v2) : définissez un nouveau mot de passe de déverrouillage. La clé maîtresse et les données existantes sont conservées ; ce mot de passe est requis à chaque lancement.';

  @override
  String get toastVaultSwitchedToPassword =>
      'Passé à la protection par mot de passe (v2)';

  @override
  String get toastVaultSwitchedToOs => 'Revenu à la protection système (v1)';

  @override
  String get settingsVaultShareBrokenBanner =>
      'Parts du coffre incompatibles : backend de stockage différent ou part manquante. Les identifiants locaux ne peuvent pas être déchiffrés. Reconstruisez le coffre et connectez-vous à nouveau.';

  @override
  String get settingsVaultShareBrokenRebuild => 'Reconstruire le coffre';

  @override
  String get settingsVaultRestartTitle => 'Redémarrage requis';

  @override
  String get settingsVaultRestartDesc =>
      'Le niveau de chiffrement a été changé avec succès. Redémarrez l\'application pour garantir l\'intégrité de la base de données et la cohérence des modules. En mode mot de passe (v2), vous devrez saisir votre mot de passe après le redémarrage ; la session et les identifiants de streaming sont indisponibles (affichés déconnectés) jusqu\'au déverrouillage. La lecture et les téléchargements sont interrompus pendant le redémarrage.';

  @override
  String get settingsVaultRestartNow => 'Redémarrer maintenant';

  @override
  String get settingsVaultRestartLater => 'Plus tard';

  @override
  String get vaultCrashTitle =>
      'Le module d\'identifiants s\'est terminé anormalement';

  @override
  String get vaultCrashDesc =>
      'Le processus du coffre d\'identifiants s\'est terminé de manière inattendue. Vos identifiants locaux ont pu être exposés. Reconnectez-vous ou effacez le coffre pour reconstruire les identifiants.';

  @override
  String get vaultCrashReset => 'Effacer et reconstruire';

  @override
  String get vaultCrashDismiss => 'OK';

  @override
  String get vaultVersionTitle => 'Version anormale du coffre d\'identifiants';

  @override
  String get vaultVersionDesc =>
      'Anomalie détectée dans le composant du coffre : sa copie binaire a pu être remplacée ou issue d\'une construction non officielle, exposant potentiellement vos identifiants locaux. La copie anormale a été supprimée et le déchiffrement refusé. Quittez et réinstallez l\'application.';

  @override
  String get vaultVersionExit => 'Quitter';

  @override
  String get vaultVersionReasonReplaced =>
      'Binaire du coffre remplacé ou construction non officielle détectée ; copie anormale supprimée et déchiffrement refusé.';

  @override
  String get vaultVersionReasonMarkerMissing =>
      'La réponse de poignée de main du coffre ne contient pas de marqueur de construction officielle.';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'Le marqueur de construction du coffre ne correspond pas à la version officielle ; copie anormale supprimée et déchiffrement refusé.';

  @override
  String get vaultUnlockTitle => 'Déverrouiller le coffre d\'identifiants';

  @override
  String get vaultUnlockDesc =>
      'Le coffre d\'identifiants est en mode mot de passe (v2). Saisissez le mot de passe pour déverrouiller vos identifiants de connexion et comptes de streaming.';

  @override
  String get vaultUnlockHint => 'Mot de passe';

  @override
  String get vaultUnlockConfirm => 'Déverrouiller';

  @override
  String get vaultUnlockSkip => 'Plus tard';

  @override
  String get vaultUnlockFailed => 'Mot de passe incorrect, réessayez';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsVersionUnknown => 'v inconnue · Flutter bureau';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter bureau';
  }

  @override
  String get settingsAudioEngine => 'Moteur audio';

  @override
  String get settingsAudioEngineDesc =>
      'Moteur C intégré（miniaudio）· FFI de transcodage/scan natif';

  @override
  String get settingsSubsonicServer => 'Serveur Subsonic';

  @override
  String get settingsSubsonicDesc =>
      'Go FFI（intégré）· Bibliothèque musicale auto-hébergée';

  @override
  String get settingsAboutDesc =>
      'Lecteur maison : bibliothèque locale, sources musicales directes, Subsonic auto-hébergé, moteur audio natif.';

  @override
  String get settingsSectionDeclaration => 'Déclaration logicielle';

  @override
  String get settingsDeclineText =>
      'Ce logiciel（ArchoeraMusic）est un lecteur de musique de bureau gratuit et open source à des fins d\'apprentissage et de recherche personnelle.\n\n';

  @override
  String get settingsDecline1Title => '1. Nature du logiciel\n';

  @override
  String get settingsDecline1Body =>
      'Ce logiciel est un client tiers sans affiliation, coopération ou autorisation avec aucune plateforme musicale.\n\n';

  @override
  String get settingsDecline2Title =>
      '2. Sources de contenu et droits d\'auteur\n';

  @override
  String get settingsDecline2Body =>
      'Ce logiciel lui-même ne fournit, ne stocke ni ne distribue aucun contenu musical. Les droits d\'auteur appartiennent aux titulaires originaux et aux plateformes.\n\n';

  @override
  String get settingsDecline3Title =>
      '3. Obligations de traitement des données de droits d\'auteur\n';

  @override
  String get settingsDecline3Body =>
      'Les données de droits d\'auteur sont uniquement pour la prévisualisation personnelle et la recherche ; ne pas utiliser pour la distribution commerciale ou publique.\n\n';

  @override
  String get settingsDecline4Title => '4. Restrictions d\'utilisation\n';

  @override
  String get settingsDecline4Body =>
      'Ne pas utiliser pour des activités commerciales, le scraping en masse ou la revente ; ne pas utiliser en violation des lois locales ou des conditions de service.\n\n';

  @override
  String get settingsDecline5Title => '5. Clause de non-responsabilité\n';

  @override
  String get settingsDecline5Body =>
      'Ce logiciel est fourni「tel quel」sans garanties expresses ou implicites.\n\n';

  @override
  String get settingsDeclineFooter =>
      'Ce logiciel est uniquement pour l\'exploration et la recherche techniques.';

  @override
  String get settingsSectionFontCredits => 'Crédits des polices';

  @override
  String get settingsFontCreditsText =>
      'Ce logiciel intègre les polices suivantes :\n· Noto Sans CJK SC (SIL Open Font License 1.1)\n· MiSans (© Xiaomi, utilisée conformément à l\'accord de licence de propriété intellectuelle de la police MiSans)\n· HarmonyOS Sans SC (© Huawei, utilisée conformément à l\'accord de licence de la police HarmonyOS Sans)';

  @override
  String get commonNoLyrics => 'Pas de paroles';

  @override
  String commonTrackCount(Object count) {
    return '$count pistes';
  }

  @override
  String get settingsSearchColorTitle => 'Couleur lu / non lu';

  @override
  String get settingsSearchColorSubtitle =>
      'Surbrillance ligne actuelle et couleur ligne normale';

  @override
  String get settingsSearchDesktopLyricsTitle => 'Paroles de bureau';

  @override
  String get settingsSearchDesktopLyricsSubtitle =>
      'Fenêtre de paroles toujours au premier plan · Suit la lecture';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => 'Modèle de nom de fichier';

  @override
  String get settingsSearchAccentSubtitle =>
      'Graine de couleur primaire personnalisée · Palette';

  @override
  String get settingsThemeSource => 'Source de la couleur du thème';

  @override
  String get settingsThemeSourceDesc => 'D\'où vient la couleur primaire';

  @override
  String get settingsThemeSourceDefault => 'Suivre le système';

  @override
  String get settingsThemeSourceCustom => 'Personnalisée';

  @override
  String get settingsThemeSourceCover => 'Suivre la pochette';

  @override
  String get settingsThemeSourceSolid => 'Aucune';

  @override
  String get settingsThemeSourceCustomHint =>
      'Choisissez une couleur de base ; le primaire/secondaire est généré à partir d\'elle';

  @override
  String get settingsThemeSourceCoverHint =>
      'Extrait la couleur dominante de la pochette actuelle en temps réel (repli sur la couleur par défaut si indisponible)';

  @override
  String get settingsGlobalTint => 'Teinte globale';

  @override
  String get settingsGlobalTintDesc =>
      'Applique subtilement la couleur du thème à toute l\'interface';

  @override
  String get settingsGlobalTintNote =>
      'Effectif lorsqu\'une couleur de thème existe (personnalisée / pochette) ; forcé en mode image de fond.';

  @override
  String get settingsSectionStyle => 'Style de fond';

  @override
  String get settingsAppearanceStyle => 'Style d\'apparence';

  @override
  String get settingsAppearanceStyleDesc =>
      'Comment le fond principal est rendu';

  @override
  String get settingsAppearanceStyleSolid => 'Couleur unie';

  @override
  String get settingsAppearanceStyleImage => 'Image';

  @override
  String get settingsBackgroundImage => 'Image de fond';

  @override
  String get settingsBackgroundImageDesc =>
      'Choisissez une image locale comme fond ; le mode image force le thème sombre et la teinte globale';

  @override
  String get settingsBackgroundPick => 'Choisir une image';

  @override
  String get settingsBackgroundReplace => 'Remplacer';

  @override
  String get settingsBackgroundClear => 'Effacer';

  @override
  String get settingsBackgroundBlur => 'Flou de fond';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return 'Flou gaussien appliqué à l\'image de fond (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => 'Intensité du voile';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return 'Opacité du voile noir ($dim%) ; plus élevée = premier plan plus lisible';
  }

  @override
  String get settingsBackgroundScale => 'Zoom';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return 'Facteur de zoom de l\'image de fond (${scale}x)';
  }

  @override
  String get settingsSidebarCollapsed => 'Barre latérale réduite';

  @override
  String get settingsSidebarCollapsedDesc =>
      'Réduire la barre latérale au mode icônes uniquement';

  @override
  String get settingsSidebarNavStyle => 'Animation du surlignage de navigation';

  @override
  String get settingsSidebarNavStyleDesc =>
      'Style d\'animation de l\'indicateur de navigation actif';

  @override
  String get settingsSidebarNavStyleDefault => 'Statique';

  @override
  String get settingsSidebarNavStyleAnimated => 'Animé';

  @override
  String get settingsRouteTransition => 'Transition de page';

  @override
  String get settingsRouteTransitionDesc =>
      'Animation de transition lors du changement de page';

  @override
  String get settingsRouteTransitionNone => 'Aucune';

  @override
  String get settingsRouteTransitionFade => 'Fondu';

  @override
  String get settingsRouteTransitionSlide => 'Glissement';

  @override
  String get settingsRouteTransitionZoom => 'Zoom';

  @override
  String get settingsSearchThemeSourceSubtitle =>
      'Thème par défaut · Personnalisée · Suivre la pochette · Aucun';

  @override
  String get settingsSearchGlobalTintSubtitle =>
      'Teinte toute l\'interface avec la couleur du thème';

  @override
  String get settingsSearchBackgroundSubtitle =>
      'Unie / Image · Flou · Voile · Zoom';

  @override
  String get settingsSearchSidebarSubtitle =>
      'Réduire la barre · Surlignage statique / animé';

  @override
  String get settingsSearchRouteTransitionSubtitle =>
      'Aucune · Fondu · Glissement · Zoom';

  @override
  String get settingsSearchFloatingBarSubtitle =>
      'Capsule flottante en bas · Ancré pleine largeur';

  @override
  String get settingsSearchFontSubtitle =>
      'MiSans · Noto Sans · HarmonyOS Sans';

  @override
  String get settingsSearchLanguageSubtitle =>
      'Suivre le système · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle =>
      'Carré · Arrondi · Très arrondi';

  @override
  String get settingsSectionWeather => 'Météo';

  @override
  String get settingsWeather => 'Widget météo';

  @override
  String get settingsWeatherDesc =>
      'Mini météo (icône + température) à gauche de l\'avatar';

  @override
  String get settingsWeatherAutoLocate => 'Localisation automatique';

  @override
  String get settingsWeatherAutoLocateDesc =>
      'Position approximative via IP (confidentialité : désactivée par défaut)';

  @override
  String get settingsWeatherCity => 'Ville manuelle';

  @override
  String get settingsWeatherCityHint =>
      'Plus de localisation IP une fois renseignée (ex. Paris)';

  @override
  String get settingsWeatherNote =>
      'Confidentialité : données météo d\'Open-Meteo (gratuit, sans clé). Avec la localisation automatique, votre IP est envoyée à ip-api.com pour une position approximative, utilisée uniquement pour la météo, non stockée. Widget et localisation sont désactivés par défaut.';

  @override
  String get settingsSearchWeatherSubtitle =>
      'Mini widget météo dans la barre supérieure (icône + température)';

  @override
  String get weatherRefresh => 'Actualiser la météo';

  @override
  String get weatherNoLocation =>
      'Saisissez une ville ou activez la localisation dans les réglages';

  @override
  String get weatherUnavailable => 'Météo indisponible, toucher pour réessayer';

  @override
  String get settingsSearchPassthroughSubtitle =>
      'Pas de transcodage · Pipeline 48kHz';

  @override
  String get settingsSearchSessionMemorySubtitle =>
      'Basculer mémoriser/restaurer la session';

  @override
  String get settingsSearchAutoPlaySubtitle =>
      'Basculer lecture automatique à la restauration';

  @override
  String get settingsSearchSpectrumSubtitle =>
      'Basculer spectre du lecteur · Opacité';

  @override
  String get settingsSearchSpectrumWidthSubtitle => 'Largeur de barre 1~12px';

  @override
  String get settingsSearchPlayerLyricsSubtitle =>
      'Affichage des paroles en lecteur plein écran';

  @override
  String get settingsSearchLyricFontSizeSubtitle =>
      'Taille de police des paroles 14~28px';

  @override
  String get settingsSearchLyricLineHeightSubtitle =>
      'Hauteur de ligne 42~64px';

  @override
  String get settingsSearchUncensorSubtitle =>
      'Restaurer les mots censurés comme f**k dans les paroles';

  @override
  String get settingsSearchHideVipSubtitle =>
      'Masquer badges VIP/payants dans la liste';

  @override
  String get settingsSearchHideQualitySubtitle =>
      'Masquer badges de qualité dans la liste';

  @override
  String get settingsSearchSubtitleSubtitle =>
      'Afficher les alias dans la liste (ex. (Live))';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      'Emplacement des téléchargements (défaut ~/Music/ArchoeraMusic)';

  @override
  String get settingsSearchFilenameSubtitle =>
      'Espaces réservés <artist>/<title>/<album> configurables';

  @override
  String get settingsSearchConcurrentSubtitle =>
      '1~5 tâches de téléchargement parallèles';

  @override
  String get settingsSearchSpeedLimitSubtitle =>
      'Illimité · 0.5~20 MB/s effet immédiat';

  @override
  String get settingsSearchQualitySubtitle =>
      'Hi-Res · Sans perte · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle =>
      'À plat · Par plateforme · Par artiste';

  @override
  String get settingsSearchHistoryLimitSubtitle =>
      'Les échecs/annulations purgent les plus anciens au-delà de la limite (10~500)';

  @override
  String get settingsSearchStorageSubtitle =>
      'Chemins bibliothèque multimédia · BD utilisateur';

  @override
  String get settingsSearchAboutSubtitle => 'Moteur audio · Serveur Subsonic';

  @override
  String get qualityLossless => 'Sans perte';

  @override
  String get repeatModeList => 'Répéter la liste';

  @override
  String get repeatModeOne => 'Répéter une';

  @override
  String get commonUnknownTrack => 'Piste inconnue';

  @override
  String get commonAnonymousUser => 'Utilisateur anonyme';

  @override
  String get commonCanceled => 'Annulé';

  @override
  String get commonILike => 'Mes favoris';

  @override
  String get sidebarStreaming => 'Streaming';

  @override
  String get settingsCatMediaSource => 'Source multimédia';

  @override
  String get settingsMediaSourceSubtitle =>
      'Serveurs de streaming (Subsonic / Jellyfin / Emby)';

  @override
  String get settingsCatScrape => 'Scraping';

  @override
  String get settingsScrapeSubtitle =>
      'Métadonnées multi-sources : pochette / paroles / tags';

  @override
  String get settingsSectionScrapeDirs => 'Répertoires de scraping';

  @override
  String get settingsScrapeDirsHint =>
      'Un répertoire par ligne ; vide suit les répertoires de scan de la bibliothèque';

  @override
  String get settingsScrapeDirsEmptyNote =>
      'Aucun répertoire de scraping configuré ; les répertoires de scan de la bibliothèque seront utilisés.';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return 'Répertoires effectifs : $dirs';
  }

  @override
  String get settingsSectionScrapeSources => 'Sources de données';

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
  String get settingsScrapeSourceAcoustID => 'AcoustID (empreinte audio)';

  @override
  String get settingsScrapeSourceDesc =>
      'Une fois activé, participe à la recherche multi-sources, à la comparaison de similarité et à la fusion des scores';

  @override
  String get settingsSectionScrapeProgress => 'Progression du scraping';

  @override
  String get settingsScrapeStart => 'Démarrer le scraping';

  @override
  String get settingsScrapeCancel => 'Annuler le scraping';

  @override
  String get settingsScrapeScanning => 'Analyse des répertoires…';

  @override
  String settingsScrapeCurrent(Object file) {
    return 'Traitement : $file';
  }

  @override
  String get settingsScrapeSuccess => 'Réussi';

  @override
  String get settingsScrapeFailed => 'Échec';

  @override
  String get settingsScrapeSkipped => 'Ignoré';

  @override
  String get settingsScrapeNotFound => 'Non trouvé';

  @override
  String get settingsScrapeIdle =>
      'Pas encore scrapé. Cliquez sur le bouton ci-dessous pour commencer.';

  @override
  String get settingsScrapeNoDirs =>
      'Aucun répertoire à scraper. Configurez d\'abord des répertoires de scraping ou de scan de la bibliothèque.';

  @override
  String get settingsScrapeDone => 'Scraping terminé';

  @override
  String get settingsScrapeCanceled => 'Scraping annulé';

  @override
  String get toastScrapeNoDirs => 'Aucun répertoire à scraper';

  @override
  String get toastScrapeDirsUpdated => 'Répertoires de scraping enregistrés';

  @override
  String get toastScrapeStarted => 'Scraping démarré';

  @override
  String get commonDelete => 'Supprimer';

  @override
  String get commonSave => 'Enregistrer';

  @override
  String get commonConfirm => 'Confirmer';

  @override
  String get streamingHint => 'Source multimédia';

  @override
  String get streamingHintDetail =>
      'Ajoutez un serveur de streaming pour parcourir et écouter sa musique (famille Subsonic / Jellyfin / Emby, y compris le serveur Subsonic local intégré).';

  @override
  String get streamingServerAdd => 'Ajouter un serveur';

  @override
  String get streamingEmptyNoServer => 'Aucun serveur de streaming';

  @override
  String get streamingEmptyAddHint =>
      'Cliquez sur le bouton ci-dessus pour ajouter un serveur';

  @override
  String get streamingServerConnected => 'Connecté';

  @override
  String get streamingServerDisconnected => 'Non connecté';

  @override
  String get streamingServerLastConnected => 'Dernière connexion';

  @override
  String get streamingServerDisconnect => 'Déconnecter';

  @override
  String get streamingToastDisconnected => 'Serveur déconnecté';

  @override
  String get streamingServerConnect => 'Connecter';

  @override
  String streamingToastConnected(Object name) {
    return 'Connecté à $name';
  }

  @override
  String get streamingServerConnectFailed => 'Échec de la connexion';

  @override
  String get streamingServerEdit => 'Modifier';

  @override
  String get streamingServerDeleteConfirmTitle => 'Supprimer le serveur';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return 'Supprimer le serveur « $name » ?';
  }

  @override
  String get streamingServerRemoved => 'Serveur supprimé';

  @override
  String get streamingServerErrorNameEmpty => 'Saisissez un nom de serveur';

  @override
  String get streamingServerErrorHostEmpty =>
      'Saisissez une adresse de serveur';

  @override
  String get streamingServerErrorPortInvalid => 'Port invalide (1~65535)';

  @override
  String get streamingServerErrorUsernameEmpty =>
      'Saisissez un nom d\'utilisateur';

  @override
  String get streamingServerErrorPasswordEmpty => 'Saisissez un mot de passe';

  @override
  String get streamingServerAdded => 'Serveur ajouté';

  @override
  String get streamingServerUpdated => 'Serveur mis à jour';

  @override
  String get streamingServerType => 'Type';

  @override
  String get streamingServerName => 'Nom';

  @override
  String get streamingServerNamePlaceholder => 'ex. Mon Navidrome';

  @override
  String get streamingServerHost => 'Adresse du serveur';

  @override
  String get streamingServerHostPlaceholder => 'ex. 192.168.1.10:4533';

  @override
  String get streamingServerPort => 'Port';

  @override
  String get streamingServerPortNote =>
      'Ports par défaut : 4533 (Subsonic) / 8096 (Jellyfin) ; laissez vide pour la détection automatique.';

  @override
  String get streamingServerLocalTitle => 'Serveur local intégré';

  @override
  String get streamingServerLocalDesc =>
      'Utiliser le serveur Subsonic intégré (bibliothèque locale)';

  @override
  String get streamingServerUsername => 'Nom d\'utilisateur';

  @override
  String get streamingServerPassword => 'Mot de passe';

  @override
  String get streamingServerTestOk => 'Connexion réussie';

  @override
  String get streamingServerTestFail => 'Échec de la connexion';

  @override
  String get streamingServerTest => 'Tester la connexion';

  @override
  String get streamingTabsSongs => 'Morceaux';

  @override
  String get streamingTabsAlbums => 'Albums';

  @override
  String get streamingTabsArtists => 'Artistes';

  @override
  String get streamingTabsPlaylists => 'Listes de lecture';

  @override
  String get streamingEmptyGoToSettings => 'Aller aux paramètres';

  @override
  String get streamingEmptyNotConnected => 'Aucun serveur connecté';

  @override
  String streamingTotalSongs(Object count) {
    return '$count morceaux';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count albums';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count artistes';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count listes';
  }

  @override
  String get streamingEmptyNoResults => 'Aucun résultat';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count morceaux';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count albums';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count morceaux';
  }
}
