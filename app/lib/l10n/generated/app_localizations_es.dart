// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get menuTrackDetail => 'Detalles del medio';

  @override
  String get trackDetailDuration => 'Duración';

  @override
  String get trackDetailArtist => 'Artista';

  @override
  String get trackDetailAlbum => 'Álbum';

  @override
  String get trackDetailSource => 'Fuente';

  @override
  String get trackDetailPath => 'Ruta';

  @override
  String get trackDetailFileSize => 'Tamaño del archivo';

  @override
  String get trackDetailCodec => 'Códec';

  @override
  String get trackDetailSampleRate => 'Frecuencia de muestreo';

  @override
  String get trackDetailBitDepth => 'Profundidad de bits';

  @override
  String get trackDetailBitrate => 'Tasa de bits';

  @override
  String get trackDetailChannels => 'Canales';

  @override
  String get trackSourceLocal => 'Archivo local';

  @override
  String get trackSourceStreaming => 'Streaming';

  @override
  String get trackDetailQuality => 'Calidad';

  @override
  String get batchSelectAll => 'Seleccionar todo';

  @override
  String get batchInvert => 'Invertir selección';

  @override
  String get batchPlay => 'Reproducir selección';

  @override
  String get batchAddQueue => 'Agregar a la cola';

  @override
  String get batchDownload => 'Descarga masiva';

  @override
  String get batchExit => 'Salir de selección múltiple';

  @override
  String get batchSelectHint => 'Selección múltiple';

  @override
  String toastBatchAddedToQueue(Object count) {
    return '$count pistas agregadas a la cola';
  }

  @override
  String toastBatchAddedToDownloadQueue(Object count) {
    return '$count pistas agregadas a la cola de descarga';
  }

  @override
  String get settingsBarEnhancedLyrics => 'Letra de barra avanzada';

  @override
  String get settingsBarEnhancedLyricsOn =>
      'Mostrar resaltado karaoke si hay letra sincronizada palabra a palabra';

  @override
  String get settingsBarEnhancedLyricsOff =>
      'Mostrar siempre letra simple en la barra';

  @override
  String get settingsSectionClose => 'Cerrar aplicación';

  @override
  String get settingsCloseBehavior => 'Al cerrar la aplicación';

  @override
  String get settingsCloseBehaviorAsk => 'Preguntar cada vez';

  @override
  String get settingsCloseBehaviorBackground => 'Reproducir en segundo plano';

  @override
  String get settingsCloseBehaviorQuit => 'Salir directamente';

  @override
  String get commonCloseConfirmTitle => 'Salir de la aplicación';

  @override
  String get commonCloseConfirmMessage =>
      'Después de cerrar la ventana principal';

  @override
  String get commonCloseConfirmRemember =>
      'Recordar mi elección y no volver a preguntar';

  @override
  String get appName => 'ArchoeraMusic';

  @override
  String get brandNetease => 'Netease Music';

  @override
  String get brandKugou => 'Kugou Music';

  @override
  String get commonBack => 'Atrás';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonClose => 'Cerrar';

  @override
  String get commonDefault => 'Predeterminado';

  @override
  String get commonGoLogin => 'Iniciar sesión';

  @override
  String get commonLike => 'Me gusta';

  @override
  String get commonLoading => 'Cargando';

  @override
  String get commonLossless => 'Sin pérdida';

  @override
  String get commonMore => 'Más';

  @override
  String get commonNext => 'Siguiente';

  @override
  String get commonNoMore => 'No hay más';

  @override
  String get commonPrevious => 'Anterior';

  @override
  String get commonSettings => 'Ajustes';

  @override
  String get commonUnknownAlbum => 'Álbum desconocido';

  @override
  String get commonUnknownArtist => 'Artista desconocido';

  @override
  String get commonUnlike => 'Ya no me gusta';

  @override
  String get downloadQualityTitle => 'Calidad de descarga';

  @override
  String downloadRequiresLoginContent(Object platform) {
    return 'Obtener el enlace de descarga de $platform requiere iniciar sesión; sin sesión solo hay vista previa, sin calidad completa.\n\nInicie sesión en $platform e inténtelo de nuevo.';
  }

  @override
  String get downloadRequiresLoginTitle =>
      'Se requiere iniciar sesión para descargar';

  @override
  String get menuComment => 'Ver comentarios';

  @override
  String get menuDownload => 'Descargar';

  @override
  String get menuLike => 'Añadir a favoritos';

  @override
  String get menuPlay => 'Reproducir';

  @override
  String get menuPlayNext => 'Reproducir a continuación';

  @override
  String get menuRemoveFromQueue => 'Quitar de la cola';

  @override
  String get menuUnlike => 'Quitar de favoritos';

  @override
  String get navHeaderAccount => 'Cuenta';

  @override
  String get navHeaderComingSoon => 'Próximamente';

  @override
  String navHeaderKugouId(Object id) {
    return 'Kugou $id';
  }

  @override
  String get navHeaderKugouMusic => 'Kugou Music';

  @override
  String get navHeaderLoginAccount => 'Iniciar sesión (Netease / Kugou)';

  @override
  String get navHeaderLogout => 'Cerrar sesión';

  @override
  String get navHeaderNeteaseAccount => 'Cuenta de Netease';

  @override
  String get navHeaderNeteaseMusic => 'Netease Music';

  @override
  String get navHeaderQqMusic => 'QQ Music';

  @override
  String get navHeaderQrLogin => 'Iniciar sesión con código QR';

  @override
  String get navHeaderSearchHint => 'Buscar canciones / artistas / listas';

  @override
  String get navHeaderThemeDark => 'Tema: Oscuro';

  @override
  String get navHeaderThemeLight => 'Tema: Claro';

  @override
  String get navHeaderThemeSystem => 'Tema: Sistema';

  @override
  String get playerBarBuffering => 'Cargando…';

  @override
  String get playerBarIdleHint =>
      'Haga clic en la barra lateral o cargue una fuente para comenzar a reproducir';

  @override
  String get playerBarOpenPlayer => 'Abrir reproductor';

  @override
  String get playerBarPlayPause => 'Reproducir/Pausar';

  @override
  String get playerBarPlaylist => 'Lista de reproducción';

  @override
  String get playerBarUntitled => 'Sin título';

  @override
  String get queueClear => 'Vaciar cola';

  @override
  String get queueEmpty => 'La cola está vacía';

  @override
  String get queueEmptyHint =>
      'Las canciones que seleccione en la lista aparecerán aquí';

  @override
  String get queueRepeatList => 'Repetir lista';

  @override
  String get queueRepeatMode => 'Modo de repetición';

  @override
  String get queueRepeatOne => 'Repetir una';

  @override
  String get queueShuffle => 'Aleatorio';

  @override
  String get queueShuffleOff => 'Desactivar aleatorio';

  @override
  String get queueTitle => 'Cola de reproducción';

  @override
  String queueTrackCount(Object count) {
    return '$count canciones';
  }

  @override
  String get sidebarBackHome => 'Volver al inicio';

  @override
  String get sidebarCollapse => 'Contraer barra lateral';

  @override
  String get sidebarDownload => 'Descargas';

  @override
  String get sidebarExpand => 'Expandir barra lateral';

  @override
  String get sidebarFavorites => 'Favoritos';

  @override
  String get sidebarGroupMusic => 'Música';

  @override
  String get sidebarGroupPersonal => 'Personal';

  @override
  String get sidebarHistory => 'Historial';

  @override
  String get sidebarHome => 'Inicio';

  @override
  String get sidebarLibrary => 'Biblioteca';

  @override
  String get sidebarLiked => 'Mis gustos';

  @override
  String get songListAlbum => 'Álbum';

  @override
  String get songListDuration => 'Duración';

  @override
  String get songListTitle => 'Título';

  @override
  String toastAddedToDownloadQueue(Object quality) {
    return 'Añadida a la cola de descargas: $quality';
  }

  @override
  String get toastAddedToQueue => 'Añadida a la cola de reproducción';

  @override
  String get toastDownloadEngineNotReady =>
      'El motor de descarga no está listo, inténtelo más tarde';

  @override
  String get toastLiked => 'Añadido a favoritos';

  @override
  String get toastLoginRequiredKugou =>
      'Operación fallida (asegúrese de haber iniciado sesión en su cuenta de Kugou)';

  @override
  String get toastLoginRequiredNetease =>
      'Operación fallida (asegúrese de haber iniciado sesión en su cuenta de Netease)';

  @override
  String get toastNoQualityInfo =>
      'Esta canción no tiene información de calidad; no se puede descargar';

  @override
  String get toastUnliked => 'Eliminado de favoritos';

  @override
  String get commonClear => 'Borrar';

  @override
  String get commonEmptyContent => 'Sin contenido';

  @override
  String commonLoadFailed(Object msg) {
    return 'Error al cargar: $msg';
  }

  @override
  String get commonRetry => 'Reintentar';

  @override
  String get commentDuplicate => 'No envíe el mismo contenido dos veces';

  @override
  String get commentEmpty => 'Aún no hay comentarios';

  @override
  String get commentHot => 'Populares';

  @override
  String get commentInputEmpty => 'El comentario no puede estar vacío';

  @override
  String get commentInputHint => 'Di algo…';

  @override
  String get commentLatest => 'Recientes';

  @override
  String commentLoginRequired(Object platform) {
    return 'Inicie sesión en su cuenta de $platform para comentar';
  }

  @override
  String commentNotFound(Object platform) {
    return 'No se encontraron comentarios de $platform para esta canción';
  }

  @override
  String get commentPublished => 'Comentario publicado';

  @override
  String commentReplyFormat(Object text, Object user) {
    return '@$user: $text';
  }

  @override
  String get commentSend => 'Enviar';

  @override
  String commentSendFailed(Object msg) {
    return 'Error al enviar: $msg';
  }

  @override
  String commentTimeFormat(Object day, Object month, Object time) {
    return '$day/$month $time';
  }

  @override
  String get commentTitle => 'Comentarios';

  @override
  String get folderAdd => 'Agregar';

  @override
  String get folderBrowse => 'Examinar';

  @override
  String get folderEmpty =>
      'Aún no hay carpetas de escaneo. Use los botones de abajo para agregar una';

  @override
  String get folderExists => 'La carpeta ya existe o no es válida';

  @override
  String get folderInvalid => 'La carpeta no existe, ya existe o está vacía';

  @override
  String get folderPathHint => 'Introduzca una ruta absoluta de carpeta';

  @override
  String get folderRemove => 'Quitar';

  @override
  String get folderRemoveDescription =>
      'Tras quitarla, la carpeta ya no se escaneará; las canciones catalogadas se conservan.';

  @override
  String get folderRemoveTitle => 'Quitar carpeta de escaneo';

  @override
  String get loginFetchingQr => 'Obteniendo código QR…';

  @override
  String loginKugouLoggedIn(Object platform) {
    return 'Sesión iniciada con $platform';
  }

  @override
  String loginKugouLogin(Object platform) {
    return 'Iniciar sesión con $platform';
  }

  @override
  String loginKugouQrLogin(Object platform) {
    return 'Iniciar sesión en $platform con código QR';
  }

  @override
  String get loginKugouResponseMissingToken =>
      'La respuesta de inicio de sesión no tiene token/userid';

  @override
  String loginKugouScanHint(Object platform) {
    return 'Use la aplicación de $platform para escanear el código QR';
  }

  @override
  String loginKugouSession(Object platform) {
    return 'Conectado con $platform';
  }

  @override
  String loginKugouSuccessVip(Object platform) {
    return 'Inicio de sesión en $platform correcto, canciones VIP desbloqueadas';
  }

  @override
  String loginLoggedOut(Object platform) {
    return 'Sesión de $platform cerrada';
  }

  @override
  String loginLogoutWithId(Object id) {
    return 'Cerrar sesión ($id)';
  }

  @override
  String loginNeteaseQrTitle(Object platform) {
    return 'Iniciar sesión en $platform con código QR';
  }

  @override
  String loginNeteaseScanHint(Object platform) {
    return 'Use la aplicación de $platform para escanear el código QR';
  }

  @override
  String get loginQrExpired => 'El código QR ha caducado';

  @override
  String get loginQrExpiredRegenerate =>
      'El código QR ha caducado, haga clic para regenerarlo';

  @override
  String get loginQrLogin => 'Iniciar sesión con código QR';

  @override
  String get loginRefreshQr => 'Actualizar código QR';

  @override
  String get loginRegenerate => 'Regenerar';

  @override
  String get loginSuccess => 'Sesión iniciada correctamente';

  @override
  String get loginWaitingConfirm =>
      'Escaneado, confirme el inicio de sesión en su teléfono';

  @override
  String get splashTagline => 'Local · En línea · Autoalojado';

  @override
  String get trackListArtistHotSongs => 'Canciones populares del artista';

  @override
  String get trackListArtistSongs => 'Canciones del artista';

  @override
  String get trackListDailyRecommend => 'Recomendación diaria';

  @override
  String get trackListDailyRecommendSubtitle =>
      'Se actualiza cada día según sus gustos';

  @override
  String trackListEmptyDailyLogin(Object platform) {
    return 'Sin canciones (la recomendación diaria requiere sesión en $platform)';
  }

  @override
  String get trackListNoPlayableSource =>
      'Sin fuente reproducible (VIP / límite de vista previa)';

  @override
  String get trackListPlayAll => 'Reproducir todo';

  @override
  String trackListPlaySourceFailed(Object msg) {
    return 'Error al obtener la fuente de reproducción: $msg';
  }

  @override
  String get trayNext => 'Siguiente';

  @override
  String get trayPlayPause => 'Reproducir / Pausar';

  @override
  String get trayPrevious => 'Anterior';

  @override
  String get trayQuit => 'Salir';

  @override
  String get trayShow => 'Mostrar ventana principal';

  @override
  String get commonPlayAll => 'Reproducir todo';

  @override
  String get commonPause => 'Pausar';

  @override
  String get commonPlay => 'Reproducir';

  @override
  String get commonRefresh => 'Actualizar';

  @override
  String get commonSearch => 'Buscar';

  @override
  String get commonSongs => 'Canciones';

  @override
  String get commonAlbums => 'Álbumes';

  @override
  String get commonArtists => 'Artistas';

  @override
  String get commonPlaylists => 'Listas de reproducción';

  @override
  String get commonDone => 'Listo';

  @override
  String get commonUnknownError => 'Error desconocido';

  @override
  String commonSongCountHint(Object count) {
    return '$count canciones en total · Haz clic para reproducir';
  }

  @override
  String get platformNetease => 'NetEase';

  @override
  String get platformKugou => 'Kugou';

  @override
  String get platformAll => 'Todo';

  @override
  String toastPlayedAll(Object count) {
    return 'Se reprodujeron todas las $count canciones';
  }

  @override
  String toastPlayFailed(Object msg) {
    return 'Error de reproducción: $msg';
  }

  @override
  String get toastMissingLocalPath => 'Falta la ruta del archivo local';

  @override
  String get toastLocateComingSoon => 'Abrir explorador de archivos (fase 2)';

  @override
  String get toastRemovedFromLibrary => 'Eliminado de la biblioteca';

  @override
  String get toastRemoveFailed => 'Error al eliminar';

  @override
  String toastDailyRequiresLogin(Object platform) {
    return 'Las recomendaciones diarias requieren iniciar sesión en $platform';
  }

  @override
  String get toastPlaylistEmpty => 'La lista no tiene canciones';

  @override
  String get toastAlbumEmpty => 'El álbum no tiene canciones';

  @override
  String get toastPausedAll => 'Todo en pausa';

  @override
  String get toastResumedAll => 'Todo reanudado';

  @override
  String get toastPaused => 'En pausa';

  @override
  String get toastCanceledTask => 'Cancelado y tarea eliminada';

  @override
  String get toastResumed => 'Descarga reanudada';

  @override
  String get toastRequeued => 'Volver a añadir a la cola';

  @override
  String get toastDeletedSelected => 'Tareas seleccionadas eliminadas';

  @override
  String get toastDeletedSelectedWithMedia =>
      'Tareas y archivos multimedia eliminados';

  @override
  String get toastCleared => 'Tareas de descarga borradas';

  @override
  String get toastClearedWithMedia => 'Tareas borradas y archivos eliminados';

  @override
  String get toastDeletedTask => 'Tarea eliminada';

  @override
  String get toastDeletedTaskWithMedia => 'Tarea y archivos eliminados';

  @override
  String get pageHistoryRemoved => 'Eliminado del historial';

  @override
  String get pageHistoryClearTitle => 'Borrar historial de reproducción';

  @override
  String get pageHistoryClearMessage =>
      '¿Borrar todo el historial? Esta acción no se puede deshacer.';

  @override
  String get pageHistoryCleared => 'Historial borrado';

  @override
  String get pageHistoryRemove => 'Eliminar del historial';

  @override
  String get pageHistorySubtitleEmpty =>
      'Registros de reproducción guardados localmente';

  @override
  String get pageHistoryEmpty => 'Aún no hay registros';

  @override
  String get pageHistoryEmptyHint =>
      'Las canciones reproducidas se guardarán aquí automáticamente';

  @override
  String pageFavPlaylistCount(Object count) {
    return '$count listas favoritas';
  }

  @override
  String get pageFavPlaylistLoginHint =>
      'Inicia sesión para ver tus listas favoritas';

  @override
  String pageFavAlbumCount(Object count) {
    return '$count álbumes favoritos';
  }

  @override
  String get pageFavAlbumLoginHint =>
      'Inicia sesión para ver tus álbumes favoritos';

  @override
  String pageFavArtistCount(Object count) {
    return '$count artistas favoritos';
  }

  @override
  String get pageFavArtistLoginHint =>
      'Inicia sesión para ver tus artistas favoritos';

  @override
  String get pageFavLoadFailed => 'Error al cargar favoritos';

  @override
  String get pageFavEmpty => 'Aún no hay favoritos';

  @override
  String get pageFavEmptyHint =>
      'Los favoritos de NetEase se sincronizan automáticamente';

  @override
  String get pageFavLoginTitle => 'Inicia sesión para ver favoritos';

  @override
  String get pageFavLoginDesc =>
      'Inicia sesión con QR en NetEase para sincronizar listas, álbumes y artistas favoritos';

  @override
  String pageSearchLoadingTrack(Object title) {
    return 'Cargando: $title';
  }

  @override
  String pageSearchDetailComingSoon(Object title) {
    return '$title — Detalle próximamente';
  }

  @override
  String get menuViewArtist => 'Ver artista';

  @override
  String get pageSearchArtistComingSoon => 'Página de artista (fase 2)';

  @override
  String get pageSearchInputHint => 'Escribe palabras clave para buscar';

  @override
  String get pageSearchInputSubtitle =>
      'Canciones / Álbumes / Artistas / Listas';

  @override
  String get pageSearching => 'Buscando…';

  @override
  String get pageSearchEmpty => 'Sin resultados';

  @override
  String get pageSearchEmptyHint => 'Prueba con otras palabras clave';

  @override
  String get pageSearchFailed => 'Búsqueda fallida';

  @override
  String get pageLikedKugouLoginHint =>
      'Inicia sesión para sincronizar \'Me gusta\' de Kugou';

  @override
  String get pageLikedNeteaseLoginHint =>
      'Inicia sesión para sincronizar favoritos de NetEase';

  @override
  String get pageLikedLoadFailed => 'Error al cargar \'Me gusta\'';

  @override
  String get pageLikedEmpty => 'Aún no hay canciones que te gusten';

  @override
  String get pageLikedKugouEmptyHint =>
      'Los \'Me gusta\' en la app Kugou se sincronizan automáticamente';

  @override
  String get pageLikedNeteaseEmptyHint =>
      'Los corazones en NetEase se sincronizan automáticamente';

  @override
  String get pageLikedLoginTitle =>
      'Inicia sesión para ver tus canciones favoritas';

  @override
  String get pageLikedKugouLoginDesc =>
      'Inicia sesión con QR en Kugou para sincronizar \'Me gusta\'';

  @override
  String get pageLikedNeteaseLoginDesc =>
      'Inicia sesión con QR en NetEase para sincronizar favoritos del corazón';

  @override
  String get libraryScanDirs => 'Directorios de escaneo';

  @override
  String get libraryScanDirsDesc =>
      'Gestiona directorios locales; escaneo inmediato tras añadir';

  @override
  String get libraryMediaStats => 'Estadísticas multimedia';

  @override
  String get libraryMediaStatsDesc => 'Resumen de la biblioteca local';

  @override
  String get libraryStatTracks => 'Pistas';

  @override
  String get libraryStatDuration => 'Duración total';

  @override
  String get libraryStatSize => 'Tamaño total';

  @override
  String libraryStatTrackCount(Object count) {
    return '$count pistas';
  }

  @override
  String libraryScanDirCount(Object count) {
    return '$count directorios';
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
  String get librarySearchHint => 'Buscar pistas locales';

  @override
  String get libraryNoMatch => 'Sin coincidencias';

  @override
  String get libraryScanningFiles => 'Contando archivos…';

  @override
  String libraryTrackCount(Object count, Object extra) {
    return '$count pistas$extra';
  }

  @override
  String get libraryEmptyWaitScan => 'Esperando primer escaneo';

  @override
  String get libraryEmpty => 'La biblioteca local está vacía';

  @override
  String get libraryEmptyScanHint => 'Haz clic abajo para escanear';

  @override
  String get libraryEmptyAddHint => 'Añade carpetas de música para escanear';

  @override
  String get libraryScanNow => 'Escanear ahora';

  @override
  String get libraryAddFolder => 'Añadir carpeta';

  @override
  String get menuLocateFile => 'Abrir ubicación';

  @override
  String get menuLocateFileComingSoon => 'Gestor de archivos en Phase 2';

  @override
  String get menuRemoveFromLibrary => 'Eliminar de la biblioteca';

  @override
  String get playerBarCollapsePlayer => 'Contraer reproductor';

  @override
  String get playerBarHideLyrics => 'Ocultar letra';

  @override
  String get playerBarShowLyrics => 'Mostrar letra';

  @override
  String get playerPageNotPlaying => 'No se está reproduciendo';

  @override
  String get playerPageLoadHint => 'Carga una fuente para empezar';

  @override
  String get playerPageQualityMenu => 'Cambiar calidad';

  @override
  String get pageHomeRankTitle => 'Rankings';

  @override
  String get pageHomePlaylistSquare => 'Plaza de listas';

  @override
  String get pageHomeHotArtists => 'Artistas populares';

  @override
  String get pageHomePlaylists => 'Listas recomendadas';

  @override
  String get pageHomeNewAlbums => 'Nuevos álbumes';

  @override
  String get pageHomeRankSubtitle => 'Éxitos en tiempo real';

  @override
  String get pageHomePlaylistSquareSubtitle => 'Descubre más listas geniales';

  @override
  String get pageHomeArtistSubtitle => 'Artistas populares, avatares redondos';

  @override
  String get pageHomeLoadFailed => 'Error al cargar recomendaciones';

  @override
  String get pageHomePlaylistsSubtitle => 'Recomendado según tus gustos';

  @override
  String get pageHomeNewAlbumsSubtitle => 'Álbumes nuevos destacados';

  @override
  String get pageHomeHotArtistsSubtitle => 'Todo el mundo los escucha';

  @override
  String get pageHomeDaily => 'Recomendación diaria';

  @override
  String get pageHomeDailyLoggedIn => 'Seleccionado para ti';

  @override
  String get pageHomeDailyLoginHint =>
      'Inicia sesión en NetEase para recibir actualizaciones diarias';

  @override
  String get pageHomeDailyPlay => 'Reproducir recomendación de hoy';

  @override
  String get pageHomeDailyLogin => 'Inicia sesión para desbloquear';

  @override
  String pageHomeGreeting(Object greeting, Object name) {
    return '$greeting, $name';
  }

  @override
  String get greetingLate => 'Es tarde';

  @override
  String get greetingMorning => 'Buenos días';

  @override
  String get greetingAfternoon => 'Buenas tardes';

  @override
  String get greetingEvening => 'Buenas noches';

  @override
  String get greetingFallback => '¿Qué te apetece escuchar hoy?';

  @override
  String get downloadDeleteTaskOnly => 'Eliminar solo la tarea';

  @override
  String get downloadDeleteWithMedia => 'Eliminar tarea y archivos';

  @override
  String downloadSelectedCount(Object count) {
    return '$count seleccionados';
  }

  @override
  String get downloadSelectAll => 'Seleccionar todo';

  @override
  String get downloadDeselectAll => 'Deseleccionar todo';

  @override
  String get downloadPauseAll => 'Pausar todo';

  @override
  String get downloadResumeAll => 'Reanudar todo';

  @override
  String get downloadDeleteSelected => 'Eliminar seleccionados';

  @override
  String get downloadExitSelect => 'Salir de selección múltiple';

  @override
  String downloadActiveCount(Object count) {
    return 'En curso $count';
  }

  @override
  String downloadDoneCount(Object count) {
    return 'Completadas $count';
  }

  @override
  String get downloadOpenDir => 'Abrir carpeta de descargas';

  @override
  String get downloadSelectMode => 'Selección múltiple';

  @override
  String get downloadEmpty => 'No hay tareas de descarga';

  @override
  String get downloadEmptyHint =>
      'Clic derecho en canción → Descargar para añadir';

  @override
  String downloadDeleteSelectedTitle(Object count) {
    return 'Eliminar $count tareas seleccionadas';
  }

  @override
  String get downloadDeleteSelectedMessage =>
      'Eliminar las tareas seleccionadas y limpiar la caché .tmp; los medios se eliminan por coincidencia exacta.';

  @override
  String get downloadClearTitle => 'Borrar tareas de descarga';

  @override
  String get downloadClearMessage =>
      'Eliminar todas las tareas y limpiar la caché .tmp; los medios se eliminan por coincidencia exacta.';

  @override
  String get downloadCancelTooltip =>
      'Cancelar (eliminar tarea y limpiar caché)';

  @override
  String get downloadResume => 'Reanudar descarga';

  @override
  String get downloadOpenDirTask => 'Abrir carpeta';

  @override
  String get downloadDeleteTask => 'Eliminar tarea';

  @override
  String get downloadDeleteWithMediaExact =>
      'Eliminar tarea y archivos (coincidencia exacta)';

  @override
  String get downloadStatusQueued => 'En cola…';

  @override
  String get downloadStatusResolving => 'Resolviendo URL…';

  @override
  String downloadStatusRunning(Object percent, Object received, Object speed) {
    return 'Descargando $percent% ($received) $speed';
  }

  @override
  String downloadStatusRunningNoPercent(Object speed) {
    return 'Descargando…$speed';
  }

  @override
  String downloadStatusPausedWith(Object received) {
    return 'En pausa ($received)';
  }

  @override
  String get downloadStatusPaused => 'En pausa';

  @override
  String downloadStatusFailed(Object error) {
    return 'Error: $error';
  }

  @override
  String get downloadStatusFailedUnknown => 'Error: desconocido';

  @override
  String get downloadStatusCanceled => 'Cancelada';

  @override
  String downloadStatusDone(Object size) {
    return 'Completado ($size)';
  }

  @override
  String get downloadStatusAlready => 'El archivo ya existe';

  @override
  String get pageHomeTitle => 'Descubrir';

  @override
  String get settingsTitle => 'Configuración';

  @override
  String get settingsCatAppearance => 'Apariencia';

  @override
  String get settingsCatPlayback => 'Reproducción';

  @override
  String get settingsCatLyrics => 'Letras';

  @override
  String get settingsCatPreset => 'Comportamiento';

  @override
  String get settingsCatDownload => 'Descarga';

  @override
  String get settingsCatStorage => 'Almacenamiento';

  @override
  String get settingsCatAbout => 'Acerca de';

  @override
  String get settingsAppearanceSubtitle => 'Tema · Preferencias de interfaz';

  @override
  String get settingsPlaybackSubtitle =>
      'Motor de audio · Comportamiento de reproducción';

  @override
  String get settingsLyricsSubtitle =>
      'Letras del reproductor · Letras de escritorio';

  @override
  String get settingsPresetSubtitle =>
      'Filtro de reproducción · Restaurar letras · Etiquetas de lista';

  @override
  String get settingsDownloadSubtitle =>
      'Directorio · Concurrencia · Límite · Calidad · Agrupación · Nombre de archivo';

  @override
  String get settingsStorageSubtitle =>
      'Directorio de datos · Archivos de base de datos';

  @override
  String get settingsAboutSubtitle => 'Versión · Información del proyecto';

  @override
  String get settingsCatDeveloper => 'Desarrollador';

  @override
  String get settingsDeveloperSubtitle =>
      'Modo desarrollador · Funciones ocultas';

  @override
  String get settingsDeveloperTitle => 'Modo desarrollador';

  @override
  String get settingsDeveloperMode => 'Modo desarrollador';

  @override
  String get settingsDeveloperModeOn =>
      'Activado (funciones de descarga visibles)';

  @override
  String get settingsDeveloperModeOff =>
      'Desactivado (funciones de descarga ocultas)';

  @override
  String get settingsDeveloperDownloadModule => 'Módulo de descarga';

  @override
  String get settingsDeveloperDownloadModuleDesc =>
      'La entrada «Descargar» de la barra lateral, el elemento «Descargar» del menú contextual y la categoría «Descargar» de la configuración solo se muestran con el modo desarrollador activado.';

  @override
  String get settingsDeveloperNote =>
      'El modo desarrollador está pensado para depuración local y uso personal. Úsalo bajo tu responsabilidad.';

  @override
  String get settingsDeveloperEnabled => 'Modo desarrollador activado';

  @override
  String get settingsDeveloperDisabled => 'Modo desarrollador desactivado';

  @override
  String get settingsDeveloperHoldHint =>
      'Mantén pulsado 10 segundos para activar el modo desarrollador (ratón: mantener pulsado)';

  @override
  String get settingsSearchHint => 'Buscar ajustes…';

  @override
  String settingsSearchNoResult(Object query) {
    return 'No se encontraron ajustes para「$query」';
  }

  @override
  String settingsSearchMatchCount(Object count) {
    return '$count coincidencias';
  }

  @override
  String get settingsSectionTheme => 'Tema';

  @override
  String get settingsThemeMode => 'Modo de tema';

  @override
  String get settingsThemeModeDesc => 'Claro / Oscuro / Seguir sistema';

  @override
  String get settingsThemeLight => 'Claro';

  @override
  String get settingsThemeDark => 'Oscuro';

  @override
  String get settingsThemeSystem => 'Seguir sistema';

  @override
  String get settingsThemeNote =>
      'Tema oscuro por defecto;「Seguir sistema」según la apariencia del SO.';

  @override
  String get settingsSectionAccent => 'Color de acento';

  @override
  String get settingsAccentTitle => 'Semilla de color primario';

  @override
  String settingsAccentSystem(Object color) {
    return 'Seguir acento del sistema（$color）';
  }

  @override
  String get settingsAccentSystemFallback =>
      'Seguir acento del sistema（fallo de lectura, usa personalizado）';

  @override
  String get settingsAccentDefault =>
      'Azul brillante predeterminado（sistema de diseño）';

  @override
  String get settingsAccentCustom =>
      'Personalizado（colores generados desde la semilla）';

  @override
  String get settingsAccentDefaultTooltip => 'Azul predeterminado';

  @override
  String get settingsAccentSystemTooltip => 'Seguir acento del sistema';

  @override
  String get settingsAccentCustomTooltip => 'Selector de color personalizado';

  @override
  String get settingsSectionLayout => 'Diseño';

  @override
  String get settingsFloatingBar => 'Barra de reproductor flotante';

  @override
  String get settingsFloatingBarOn =>
      'Cápsula redondeada centrada abajo（cristal + sombra）';

  @override
  String get settingsFloatingBarOff =>
      'Acoplado ancho completo（predeterminado）';

  @override
  String get settingsSectionFont => 'Fuente de interfaz';

  @override
  String get settingsFontTitle => 'Fuente de interfaz';

  @override
  String get settingsFontMiSans => 'MiSans（predeterminada）';

  @override
  String get settingsFontNoto => 'Noto Sans SC（métricas estándar）';

  @override
  String get settingsFontHarmony => 'HarmonyOS Sans SC（uso comercial gratuito）';

  @override
  String get settingsFontMiSansLabel => 'MiSans';

  @override
  String get settingsFontNotoLabel => 'Noto Sans SC';

  @override
  String get settingsFontHarmonyLabel => 'HarmonyOS Sans';

  @override
  String get settingsSectionLanguage => 'Idioma de interfaz';

  @override
  String get settingsLanguageTitle => 'Idioma de interfaz';

  @override
  String get settingsLanguageDesc =>
      'Cambiar idioma de visualización de la interfaz';

  @override
  String get settingsLangSystem => 'Seguir sistema';

  @override
  String get settingsSectionCover => 'Carátula';

  @override
  String get settingsCoverRadius => 'Radio de esquina de carátula';

  @override
  String get settingsCoverRadiusSharp => 'Cuadrado（alta densidad）';

  @override
  String settingsCoverRadiusPx(Object radius) {
    return 'Radio de ${radius}px';
  }

  @override
  String get settingsCoverRadiusSharpLabel => 'Cuadrado';

  @override
  String get settingsCoverRadiusRoundedLabel => 'Redondeado';

  @override
  String get settingsCoverRadiusLargeLabel => 'Muy redondeado';

  @override
  String get settingsPickerTitle => 'Color de acento personalizado';

  @override
  String get settingsPickerHexLabel => 'Valor de color（#RRGGBB）';

  @override
  String get settingsApply => 'Aplicar';

  @override
  String get settingsSectionAudio => 'Audio';

  @override
  String get settingsPassthrough =>
      'Paso de calidad original（sin transcodificación）';

  @override
  String get settingsPassthroughOn =>
      'Mantener frecuencia de muestreo de origen（sin degradación）';

  @override
  String get settingsPassthroughOff =>
      'Pipeline de transcodificación unificado de 48kHz';

  @override
  String get settingsPassthroughNote =>
      'Paso activado: frecuencia original; desactivado: salida 48kHz. Efectivo al recargar la pista actual.';

  @override
  String get volumeMute => 'Silenciar';

  @override
  String get volumeUnmute => 'Activar sonido';

  @override
  String get settingsSectionMemory => 'Memoria e inicio';

  @override
  String get settingsSessionMemory => 'Memoria de sesión';

  @override
  String get settingsSessionMemoryOn =>
      'Recordar cola, posición y modo; restaurar en el próximo inicio';

  @override
  String get settingsSessionMemoryOff => 'No recordar sesión（vacío al iniciar）';

  @override
  String get settingsAutoPlay => 'Reproducción automática al iniciar';

  @override
  String get settingsAutoPlayNeedMemory => 'Activa primero「Memoria de sesión」';

  @override
  String get settingsAutoPlayOn =>
      'Restaurar última sesión y reproducir automáticamente';

  @override
  String get settingsAutoPlayOff =>
      'Solo restaurar sesión, sin reproducción automática';

  @override
  String get settingsSectionSpectrum => 'Espectro';

  @override
  String get settingsSpectrum => 'Visualizador de espectro';

  @override
  String get settingsSpectrumOn =>
      'Mostrar espectro en el reproductor（0.65 reproduciendo / 0.15 pausado）';

  @override
  String get settingsSpectrumOff => 'Sin espectro en el reproductor';

  @override
  String get settingsSpectrumBarWidth => 'Ancho de barra de espectro';

  @override
  String settingsSpectrumBarWidthDesc(Object width) {
    return '${width}px（1~12, pantalla completa）';
  }

  @override
  String get settingsBarSpectrum => 'Espectro de la barra de reproducción';

  @override
  String get settingsBarSpectrumOn =>
      'Mini espectro bajo la hora (sin letras o mini letras desactivadas)';

  @override
  String get settingsBarSpectrumOff =>
      'Ocultar mini espectro en la barra de reproducción';

  @override
  String get settingsCoverBeatScale => 'Escalar portada al ritmo';

  @override
  String get settingsCoverBeatScaleOn => 'La portada pulsa con el ritmo';

  @override
  String get settingsCoverBeatScaleOff =>
      'Portada estática（solo reproducción/pausa）';

  @override
  String get settingsTransitionStyle => 'Transición de medios';

  @override
  String get settingsTransitionStyleDesc =>
      'Animación de transición al cambiar de canción';

  @override
  String get settingsTransitionStyleScale => 'Escala';

  @override
  String get settingsTransitionStyleSlide => 'Deslizamiento';

  @override
  String get settingsSectionShortcuts => 'Atajos';

  @override
  String get settingsShortcutSpace => 'Espacio';

  @override
  String get settingsShortcutSpaceDesc => 'Reproducir / Pausar';

  @override
  String get settingsShortcutArrows => '← / →';

  @override
  String get settingsShortcutArrowsDesc => 'Retroceder / Avanzar 10 segundos';

  @override
  String get settingsShortcutSearch => 'Ctrl / Cmd + F';

  @override
  String get settingsShortcutLibrary => 'Ctrl / Cmd + L';

  @override
  String get settingsShortcutLibraryDesc => 'Biblioteca musical';

  @override
  String get settingsShortcutEsc => 'Esc';

  @override
  String get settingsShortcutEscDesc =>
      'Atrás（cerrar diálogo / salir de reproductor pantalla completa）';

  @override
  String get settingsSectionPlayerLyrics => 'Letras del reproductor';

  @override
  String get settingsPlayerLyrics => 'Letras en el reproductor';

  @override
  String get settingsPlayerLyricsOn =>
      'Letras a la derecha en pantalla completa（línea actual resaltada, clic para saltar）';

  @override
  String get settingsPlayerLyricsOff =>
      'Sin letras en el reproductor pantalla completa';

  @override
  String get settingsBarLyrics => 'Letras de la barra de reproducción';

  @override
  String get settingsBarLyricsOn =>
      'Letra actual bajo la hora (desplazamiento automático si es muy larga)';

  @override
  String get settingsBarLyricsOff =>
      'Ocultar mini letras en la barra de reproducción';

  @override
  String get settingsShowTranslation => 'Mostrar traducción';

  @override
  String get settingsShowTranslationOn =>
      'Traducción entre paréntesis después de la línea original';

  @override
  String get settingsShowTranslationOff => 'Ocultar traducción de letras';

  @override
  String get settingsSectionLyricStyle => 'Estilo de letras';

  @override
  String get settingsLyricFontSize => 'Tamaño de fuente de letras';

  @override
  String settingsLyricFontSizeDesc(Object size) {
    return '${size}px（línea actual agrandada）';
  }

  @override
  String get settingsLyricLineHeight => 'Altura de línea de letras';

  @override
  String settingsLyricLineHeightDesc(Object height) {
    return '${height}px（con interlineado）';
  }

  @override
  String get settingsLyricPlayedColor => 'Color reproducido';

  @override
  String get settingsLyricPlayedColorDesc =>
      'Color de resaltado para la línea actual de letras';

  @override
  String get settingsLyricUnplayedColor => 'Color no reproducido';

  @override
  String get settingsLyricUnplayedColorDesc =>
      'Color para próximas líneas de letras';

  @override
  String get settingsLyricsNote =>
      'El estilo solo afecta a las letras del reproductor pantalla completa';

  @override
  String get settingsSectionFilter => 'Filtro de reproducción';

  @override
  String get settingsDjMode => 'Fuck DJ Mode';

  @override
  String get settingsDjModeOn =>
      'Omitir automáticamente remixes DJ / canciones pop';

  @override
  String get settingsDjModeOff =>
      'Saltar a la siguiente al detectar versión DJ';

  @override
  String get settingsSectionLyricsFilter => 'Letras';

  @override
  String get settingsUncensor => 'Desbloquear palabrotas';

  @override
  String get settingsUncensorOn => 'fuck';

  @override
  String get settingsUncensorOff => 'f**k';

  @override
  String get settingsSectionListDisplay => 'Visualización de lista';

  @override
  String get settingsHideVip => 'Ocultar etiquetas VIP';

  @override
  String get settingsHideVipOn => 'Sin insignias VIP / de pago en la lista';

  @override
  String get settingsHideVipOff => 'Mostrar insignias de pago（VIP / EP）';

  @override
  String get settingsHideQuality => 'Ocultar etiquetas de calidad';

  @override
  String get settingsHideQualityOn => 'Sin insignias de calidad en la lista';

  @override
  String get settingsHideQualityOff =>
      'Mostrar la mejor calidad disponible（Hi-Res / Sin pérdida / HQ…）';

  @override
  String get settingsShowSubtitle => 'Mostrar subtítulo';

  @override
  String get settingsShowSubtitleOn =>
      'Mostrar alias tras el nombre, ej. (Live)';

  @override
  String get settingsShowSubtitleOff => 'Sin alias en la lista';

  @override
  String get settingsPerformanceMode => 'Modo de rendimiento';

  @override
  String get settingsPerformanceModeOn => 'Actualmente en modo congelado';

  @override
  String get settingsPerformanceModeOff => 'Actualmente en modo animación';

  @override
  String get settingsSectionDir => 'Directorio';

  @override
  String get settingsDownloadRootHint =>
      'Carpeta de descarga（Enter para guardar）';

  @override
  String get settingsRestoreDefault => 'Restaurar predeterminado';

  @override
  String get settingsDownloadRootNote =>
      'Por defecto: la carpeta de la biblioteca; cambiar carpeta termina descargas en curso. Enter para guardar.';

  @override
  String get settingsSectionFilename => 'Nombre de archivo';

  @override
  String get settingsDownloadTemplateHint =>
      'Plantilla de nombre de archivo（Enter para guardar）';

  @override
  String get settingsDownloadTemplateNote =>
      'Marcadores: <artist> · <title> · <album>. Solo afecta tareas futuras; Enter para guardar.';

  @override
  String get settingsSectionQuality => 'Calidad';

  @override
  String get settingsDownloadQuality => 'Calidad de descarga predeterminada';

  @override
  String settingsDownloadQualityDesc(Object quality) {
    return 'Diálogo de descarga: $quality por defecto; degradación automática si no hay nivel';
  }

  @override
  String get settingsDownloadQualityNote =>
      'De mayor a menor: Hi-Res → Sin pérdida → HQ → SQ → LQ; degrada automáticamente en este orden.';

  @override
  String get settingsSectionConcurrent => 'Concurrencia';

  @override
  String get settingsDownloadConcurrent => 'Descargas simultáneas';

  @override
  String settingsDownloadConcurrentDesc(Object count) {
    return '$count tareas paralelas（1~5）';
  }

  @override
  String get settingsDownloadGrouping => 'Agrupación de carpetas';

  @override
  String get settingsGroupingFlat => 'Todo plano en la carpeta de descarga';

  @override
  String get settingsGroupingPlatform =>
      'Subcarpeta por plataforma（Kugou / Netease）';

  @override
  String get settingsGroupingArtist => 'Subcarpeta por artista';

  @override
  String get settingsGroupingFlatLabel => 'Plano';

  @override
  String get settingsGroupingPlatformLabel => 'Por plataforma';

  @override
  String get settingsGroupingArtistLabel => 'Por artista';

  @override
  String get settingsSectionSpeedLimit => 'Límite de velocidad';

  @override
  String get settingsDownloadSpeedLimit => 'Límite de velocidad de descarga';

  @override
  String get settingsSpeedUnlimited => 'Ilimitado（predeterminado）';

  @override
  String settingsSpeedLimited(Object speed) {
    return 'Limitado a $speed, efecto inmediato';
  }

  @override
  String get settingsSpeedUnlimitedLabel => 'Ilimitado';

  @override
  String settingsSpeedMbps(Object speed) {
    return '$speed MB/s';
  }

  @override
  String get settingsSpeedNote =>
      'Efecto inmediato sin interrumpir tareas en curso（paso 0.5 MB/s, 0 = ilimitado）';

  @override
  String get settingsSectionHistory => 'Historial';

  @override
  String get settingsDownloadHistoryLimit => 'Límite de historial de descargas';

  @override
  String settingsDownloadHistoryDesc(Object count) {
    return '$count entradas（10~500）· elimina automáticamente las más antiguas';
  }

  @override
  String settingsDownloadHistoryCount(Object count) {
    return '$count entradas';
  }

  @override
  String get settingsDownloadHistoryNote =>
      'Solo elimina las más antiguas entre fallidas / canceladas; las en curso no se ven afectadas.';

  @override
  String get settingsGroupingNote =>
      'Agrupación por artista v2 disponible（Plano / Por plataforma / Por artista）';

  @override
  String get toastDownloadRootEmpty =>
      'La carpeta de descarga no puede estar vacía';

  @override
  String get toastDownloadRootUpdated => 'Carpeta de descarga actualizada';

  @override
  String get toastTemplateEmpty =>
      'La plantilla de nombre de archivo no puede estar vacía';

  @override
  String get toastTemplateUpdated =>
      'Plantilla de nombre de archivo actualizada';

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
  String get settingsSectionFileLocation => 'Ubicaciones de archivos';

  @override
  String get settingsDataDir => 'Directorio de datos';

  @override
  String get settingsLibraryDb => 'Base de datos de biblioteca multimedia';

  @override
  String get settingsUserDb => 'Base de datos de usuario（cifrada）';

  @override
  String get settingsLibraryDbLabel => 'Ruta de biblioteca';

  @override
  String get settingsUserDbLabel => 'Ruta de datos de usuario';

  @override
  String get settingsCopy => 'Copiar';

  @override
  String toastCopied(Object label) {
    return '$label copiado';
  }

  @override
  String get settingsStorageNote =>
      'Biblioteca y datos de usuario separados físicamente; rutas anulables con ARCHOERACAR_DATA';

  @override
  String get settingsVersion => 'Versión';

  @override
  String get settingsVersionUnknown => 'v desconocida · Flutter escritorio';

  @override
  String settingsVersionFormat(Object version) {
    return 'v$version · Flutter escritorio';
  }

  @override
  String get settingsAudioEngine => 'Motor de audio';

  @override
  String get settingsAudioEngineDesc =>
      'Motor C integrado（miniaudio）· FFI nativo';

  @override
  String get settingsSubsonicServer => 'Servidor Subsonic';

  @override
  String get settingsSubsonicDesc => 'Go FFI · Biblioteca autoalojada';

  @override
  String get settingsAboutDesc =>
      'Reproductor propio: biblioteca local, fuentes directas, Subsonic autoalojado, motor de audio nativo.';

  @override
  String get settingsSectionDeclaration => 'Declaración de software';

  @override
  String get settingsDeclineText =>
      'Este software（ArchoeraMusic）es un reproductor de música de escritorio gratuito y de código abierto para fines de aprendizaje e investigación personal.\n\n';

  @override
  String get settingsDecline1Title => '1. Naturaleza del software\n';

  @override
  String get settingsDecline1Body =>
      'Este software es un cliente de terceros sin afiliación, cooperación o autorización con ninguna plataforma musical.\n\n';

  @override
  String get settingsDecline2Title =>
      '2. Fuentes de contenido y derechos de autor\n';

  @override
  String get settingsDecline2Body =>
      'Este software no proporciona, almacena ni distribuye contenido musical. Los derechos de autor pertenecen a los titulares originales y plataformas.\n\n';

  @override
  String get settingsDecline3Title =>
      '3. Obligaciones de procesamiento de datos de derechos de autor\n';

  @override
  String get settingsDecline3Body =>
      'Los datos de derechos de autor son solo para vista previa personal e investigación; no usar para distribución comercial o pública.\n\n';

  @override
  String get settingsDecline4Title => '4. Restricciones de uso\n';

  @override
  String get settingsDecline4Body =>
      'No usar para actividades comerciales, scraping masivo o reventa; no usar en violación de leyes locales o términos de servicio.\n\n';

  @override
  String get settingsDecline5Title => '5. Descargo de responsabilidad\n';

  @override
  String get settingsDecline5Body =>
      'Este software se proporciona「tal cual」sin garantías expresas o implícitas.\n\n';

  @override
  String get settingsDeclineFooter =>
      'Este software es solo para exploración e investigación técnica.';

  @override
  String get settingsSectionFontCredits => 'Créditos de fuentes';

  @override
  String get settingsFontCreditsText =>
      'Este software incluye las siguientes fuentes:\n· Noto Sans CJK SC (SIL Open Font License 1.1)\n· MiSans (© Xiaomi, utilizada según el Acuerdo de Licencia de Propiedad Intelectual de la fuente MiSans)\n· HarmonyOS Sans SC (© Huawei, utilizada según el Acuerdo de Licencia de la fuente HarmonyOS Sans)';

  @override
  String get commonNoLyrics => 'Sin letras';

  @override
  String commonTrackCount(Object count) {
    return '$count pistas';
  }

  @override
  String get settingsSearchColorTitle => 'Color reproducido / no reproducido';

  @override
  String get settingsSearchColorSubtitle =>
      'Resaltado de línea actual y color de línea normal';

  @override
  String get settingsSearchDesktopLyricsTitle => 'Letras de escritorio';

  @override
  String get settingsSearchDesktopLyricsSubtitle =>
      'Ventana de letras independiente siempre arriba';

  @override
  String get settingsSearchDjModeTitle => 'Fuck DJ Mode';

  @override
  String get settingsSearchFilenameTitle => 'Plantilla de nombre de archivo';

  @override
  String get settingsSearchAccentSubtitle =>
      'Semilla de color primario personalizada · Paleta';

  @override
  String get settingsThemeSource => 'Origen del color de tema';

  @override
  String get settingsThemeSourceDesc => 'De dónde proviene el color primario';

  @override
  String get settingsThemeSourceDefault => 'Seguir el sistema';

  @override
  String get settingsThemeSourceCustom => 'Personalizado';

  @override
  String get settingsThemeSourceCover => 'Seguir portada';

  @override
  String get settingsThemeSourceSolid => 'Ninguno';

  @override
  String get settingsThemeSourceCustomHint =>
      'Elija una semilla de color; el color primario/secundario se genera a partir de ella';

  @override
  String get settingsThemeSourceCoverHint =>
      'Extrae el color dominante de la portada actual en tiempo real (usa el predeterminado si no está disponible)';

  @override
  String get settingsGlobalTint => 'Tinte global';

  @override
  String get settingsGlobalTintDesc =>
      'Aplica el color de tema sutilmente a toda la interfaz';

  @override
  String get settingsGlobalTintNote =>
      'Efectivo cuando hay un color de tema (personalizado / seguir portada); forzado en modo de imagen de fondo.';

  @override
  String get settingsSectionStyle => 'Estilo de fondo';

  @override
  String get settingsAppearanceStyle => 'Estilo de apariencia';

  @override
  String get settingsAppearanceStyleDesc =>
      'Cómo se representa el fondo principal';

  @override
  String get settingsAppearanceStyleSolid => 'Color sólido';

  @override
  String get settingsAppearanceStyleImage => 'Imagen';

  @override
  String get settingsBackgroundImage => 'Imagen de fondo';

  @override
  String get settingsBackgroundImageDesc =>
      'Elija una imagen local como fondo; el modo imagen fuerza tema oscuro y tinte global';

  @override
  String get settingsBackgroundPick => 'Elegir imagen';

  @override
  String get settingsBackgroundReplace => 'Reemplazar';

  @override
  String get settingsBackgroundClear => 'Limpiar';

  @override
  String get settingsBackgroundBlur => 'Desenfoque de fondo';

  @override
  String settingsBackgroundBlurDesc(Object blur) {
    return 'Desenfoque gaussiano aplicado a la imagen de fondo (${blur}px)';
  }

  @override
  String get settingsBackgroundDim => 'Intensidad de máscara';

  @override
  String settingsBackgroundDimDesc(Object dim) {
    return 'Opacidad de la superposición oscura ($dim%); mayor = más legible el primer plano';
  }

  @override
  String get settingsBackgroundScale => 'Tamaño de zoom';

  @override
  String settingsBackgroundScaleDesc(Object scale) {
    return 'Factor de zoom de la imagen de fondo (${scale}x)';
  }

  @override
  String get settingsSidebarCollapsed => 'Barra lateral contraída';

  @override
  String get settingsSidebarCollapsedDesc =>
      'Contraer la barra lateral al modo solo iconos';

  @override
  String get settingsSidebarNavStyle => 'Animación de resaltado de navegación';

  @override
  String get settingsSidebarNavStyleDesc =>
      'Estilo de animación del indicador de navegación activo';

  @override
  String get settingsSidebarNavStyleDefault => 'Estático';

  @override
  String get settingsSidebarNavStyleAnimated => 'Animado';

  @override
  String get settingsRouteTransition => 'Transición de página';

  @override
  String get settingsRouteTransitionDesc =>
      'Animación de transición al cambiar de página';

  @override
  String get settingsRouteTransitionNone => 'Ninguna';

  @override
  String get settingsRouteTransitionFade => 'Fundido';

  @override
  String get settingsRouteTransitionSlide => 'Deslizar';

  @override
  String get settingsRouteTransitionZoom => 'Zoom';

  @override
  String get settingsSearchThemeSourceSubtitle =>
      'Tema por defecto · Personalizado · Seguir portada · Sin tema';

  @override
  String get settingsSearchGlobalTintSubtitle =>
      'Tiñe toda la interfaz con el color de tema';

  @override
  String get settingsSearchBackgroundSubtitle =>
      'Sólido / Imagen · Desenfoque · Máscara · Zoom';

  @override
  String get settingsSearchSidebarSubtitle =>
      'Contraer barra · Resaltado estático / animado';

  @override
  String get settingsSearchRouteTransitionSubtitle =>
      'Ninguna · Fundido · Deslizar · Zoom';

  @override
  String get settingsSearchFloatingBarSubtitle =>
      'Cápsula flotante abajo · Anclado ancho completo';

  @override
  String get settingsSearchFontSubtitle =>
      'MiSans · Noto Sans · HarmonyOS Sans';

  @override
  String get settingsSearchLanguageSubtitle =>
      'Seguir sistema · 简体中文 · English · 日本語';

  @override
  String get settingsSearchCoverRadiusSubtitle =>
      'Cuadrado · Redondeado · Muy redondeado';

  @override
  String get settingsSearchPassthroughSubtitle =>
      'Sin transcodificación · Pipeline 48kHz';

  @override
  String get settingsSearchSessionMemorySubtitle => 'Recordar/restaurar sesión';

  @override
  String get settingsSearchAutoPlaySubtitle =>
      'Reproducción automática al restaurar sesión';

  @override
  String get settingsSearchSpectrumSubtitle =>
      'Alternar espectro del reproductor · Opacidad';

  @override
  String get settingsSearchSpectrumWidthSubtitle => 'Ancho de barra 1~12px';

  @override
  String get settingsSearchPlayerLyricsSubtitle =>
      'Visualización de letras en reproductor pantalla completa';

  @override
  String get settingsSearchLyricFontSizeSubtitle =>
      'Tamaño de fuente de letras 14~28px';

  @override
  String get settingsSearchLyricLineHeightSubtitle => 'Altura de línea 42~64px';

  @override
  String get settingsSearchUncensorSubtitle =>
      'Restaurar palabras con asteriscos en letras';

  @override
  String get settingsSearchHideVipSubtitle =>
      'Ocultar insignias VIP/pago en lista de canciones';

  @override
  String get settingsSearchHideQualitySubtitle =>
      'Ocultar insignias de calidad en lista de canciones';

  @override
  String get settingsSearchSubtitleSubtitle =>
      'Mostrar alias en lista de canciones (ej. (Live))';

  @override
  String get settingsSearchDownloadDirSubtitle =>
      'Ubicación de descargas: ~/Music/ArchoeraMusic por defecto';

  @override
  String get settingsSearchFilenameSubtitle =>
      'Marcadores <artist>/<title>/<album> configurables';

  @override
  String get settingsSearchConcurrentSubtitle =>
      '1~5 tareas de descarga paralelas';

  @override
  String get settingsSearchSpeedLimitSubtitle =>
      'Ilimitado · 0.5~20 MB/s efecto inmediato';

  @override
  String get settingsSearchQualitySubtitle =>
      'Hi-Res · Sin pérdida · HQ · SQ · LQ';

  @override
  String get settingsSearchGroupingSubtitle =>
      'Plano · Por plataforma · Por artista';

  @override
  String get settingsSearchHistoryLimitSubtitle =>
      'Elimina automáticamente los más antiguos al superar el límite (10~500)';

  @override
  String get settingsSearchStorageSubtitle =>
      'Rutas de biblioteca multimedia · BD de usuario';

  @override
  String get settingsSearchAboutSubtitle =>
      'Motor de audio · Servidor Subsonic';

  @override
  String get qualityLossless => 'Sin pérdida';

  @override
  String get repeatModeList => 'Repetir lista';

  @override
  String get repeatModeOne => 'Repetir una';

  @override
  String get commonUnknownTrack => 'Pista desconocida';

  @override
  String get commonAnonymousUser => 'Usuario anónimo';

  @override
  String get commonCanceled => 'Cancelado';

  @override
  String get commonILike => 'Mis favoritos';

  @override
  String get sidebarStreaming => 'Transmisión';

  @override
  String get settingsCatMediaSource => 'Fuente multimedia';

  @override
  String get settingsMediaSourceSubtitle =>
      'Servidores de streaming (Subsonic / Jellyfin / Emby)';

  @override
  String get settingsCatScrape => 'Raspado';

  @override
  String get settingsScrapeSubtitle =>
      'Metadatos multi-fuente: portada / letra / etiquetas';

  @override
  String get settingsSectionScrapeDirs => 'Directorios de raspado';

  @override
  String get settingsScrapeDirsHint =>
      'Un directorio por línea; vacío sigue los directorios de escaneo de la biblioteca';

  @override
  String get settingsScrapeDirsEmptyNote =>
      'Sin directorios de raspado configurados; se usarán los de escaneo de la biblioteca.';

  @override
  String settingsScrapeDirsNote(Object dirs) {
    return 'Directorios efectivos: $dirs';
  }

  @override
  String get settingsSectionScrapeSources => 'Fuentes de datos';

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
  String get settingsScrapeSourceAcoustID => 'AcoustID (huella de audio)';

  @override
  String get settingsScrapeSourceDesc =>
      'Si está activado, participa en la consulta multi-fuente, la comparación de similitud y la fusión de puntuaciones';

  @override
  String get settingsSectionScrapeProgress => 'Progreso del raspado';

  @override
  String get settingsScrapeStart => 'Iniciar raspado';

  @override
  String get settingsScrapeCancel => 'Cancelar raspado';

  @override
  String get settingsScrapeScanning => 'Escaneando directorios…';

  @override
  String settingsScrapeCurrent(Object file) {
    return 'Procesando: $file';
  }

  @override
  String get settingsScrapeSuccess => 'Éxito';

  @override
  String get settingsScrapeFailed => 'Fallido';

  @override
  String get settingsScrapeSkipped => 'Omitido';

  @override
  String get settingsScrapeNotFound => 'Sin coincidencia';

  @override
  String get settingsScrapeIdle =>
      'Aún no raspado. Haga clic en el botón de abajo para comenzar.';

  @override
  String get settingsScrapeNoDirs =>
      'No hay directorios para raspar. Configure directorios de raspado o de escaneo de la biblioteca primero.';

  @override
  String get settingsScrapeDone => 'Raspado completado';

  @override
  String get settingsScrapeCanceled => 'Raspado cancelado';

  @override
  String get toastScrapeNoDirs => 'No hay directorios para raspar';

  @override
  String get toastScrapeDirsUpdated => 'Directorios de raspado guardados';

  @override
  String get toastScrapeStarted => 'Raspado iniciado';

  @override
  String get commonDelete => 'Eliminar';

  @override
  String get commonSave => 'Guardar';

  @override
  String get commonConfirm => 'Confirmar';

  @override
  String get streamingHint => 'Fuente multimedia';

  @override
  String get streamingHintDetail =>
      'Añade un servidor de streaming para explorar y reproducir su música (familia Subsonic / Jellyfin / Emby, incluido el servidor Subsonic local integrado).';

  @override
  String get streamingServerAdd => 'Añadir servidor';

  @override
  String get streamingEmptyNoServer => 'Aún no hay servidores de streaming';

  @override
  String get streamingEmptyAddHint =>
      'Haz clic en el botón superior para añadir un servidor';

  @override
  String get streamingServerConnected => 'Conectado';

  @override
  String get streamingServerDisconnected => 'No conectado';

  @override
  String get streamingServerLastConnected => 'Última conexión';

  @override
  String get streamingServerDisconnect => 'Desconectar';

  @override
  String get streamingToastDisconnected => 'Servidor desconectado';

  @override
  String get streamingServerConnect => 'Conectar';

  @override
  String streamingToastConnected(Object name) {
    return 'Conectado a $name';
  }

  @override
  String get streamingServerConnectFailed => 'Error de conexión';

  @override
  String get streamingServerEdit => 'Editar';

  @override
  String get streamingServerDeleteConfirmTitle => 'Eliminar servidor';

  @override
  String streamingServerDeleteConfirm(Object name) {
    return '¿Eliminar el servidor «$name»?';
  }

  @override
  String get streamingServerRemoved => 'Servidor eliminado';

  @override
  String get streamingServerErrorNameEmpty =>
      'Introduce el nombre del servidor';

  @override
  String get streamingServerErrorHostEmpty =>
      'Introduce la dirección del servidor';

  @override
  String get streamingServerErrorPortInvalid => 'Puerto no válido (1~65535)';

  @override
  String get streamingServerErrorUsernameEmpty =>
      'Introduce un nombre de usuario';

  @override
  String get streamingServerErrorPasswordEmpty => 'Introduce una contraseña';

  @override
  String get streamingServerAdded => 'Servidor añadido';

  @override
  String get streamingServerUpdated => 'Servidor actualizado';

  @override
  String get streamingServerType => 'Tipo';

  @override
  String get streamingServerName => 'Nombre';

  @override
  String get streamingServerNamePlaceholder => 'p. ej. Mi Navidrome';

  @override
  String get streamingServerHost => 'Dirección del servidor';

  @override
  String get streamingServerHostPlaceholder => 'p. ej. 192.168.1.10:4533';

  @override
  String get streamingServerPort => 'Puerto';

  @override
  String get streamingServerPortNote =>
      'Puertos por defecto: 4533 (Subsonic) / 8096 (Jellyfin); déjalo vacío para autodetección.';

  @override
  String get streamingServerLocalTitle => 'Servidor local integrado';

  @override
  String get streamingServerLocalDesc =>
      'Usar el servidor Subsonic integrado (biblioteca local)';

  @override
  String get streamingServerUsername => 'Usuario';

  @override
  String get streamingServerPassword => 'Contraseña';

  @override
  String get streamingServerTestOk => 'Conexión correcta';

  @override
  String get streamingServerTestFail => 'Error de conexión';

  @override
  String get streamingServerTest => 'Probar conexión';

  @override
  String get streamingTabsSongs => 'Canciones';

  @override
  String get streamingTabsAlbums => 'Álbumes';

  @override
  String get streamingTabsArtists => 'Artistas';

  @override
  String get streamingTabsPlaylists => 'Listas';

  @override
  String get streamingEmptyGoToSettings => 'Ir a ajustes';

  @override
  String get streamingEmptyNotConnected => 'No conectado a ningún servidor';

  @override
  String streamingTotalSongs(Object count) {
    return '$count canciones';
  }

  @override
  String streamingTotalAlbums(Object count) {
    return '$count álbumes';
  }

  @override
  String streamingTotalArtists(Object count) {
    return '$count artistas';
  }

  @override
  String streamingTotalPlaylists(Object count) {
    return '$count listas';
  }

  @override
  String get streamingEmptyNoResults => 'Sin resultados coincidentes';

  @override
  String streamingAlbumSongs(Object count) {
    return '$count canciones';
  }

  @override
  String streamingArtistAlbums(Object count) {
    return '$count álbumes';
  }

  @override
  String streamingPlaylistSongs(Object count) {
    return '$count canciones';
  }
}
