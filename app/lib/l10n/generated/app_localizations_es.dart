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
  String get settingsSectionPower => 'Ahorro de energía';

  @override
  String get settingsPowerSaver => 'Modo de ahorro de energía';

  @override
  String get settingsPowerSaverOn =>
      'Reducir el renderizado en segundo plano (5 FPS minimizado, 1 FPS sin foco o pantalla apagada)';

  @override
  String get settingsPowerSaverOff => 'Renderizar siempre a máxima frecuencia';

  @override
  String get settingsSuppressSleep => 'Evitar la suspensión del sistema';

  @override
  String get settingsSuppressSleepOn =>
      'Mantener el sistema despierto durante la reproducción para no interrumpir la reproducción en segundo plano';

  @override
  String get settingsSuppressSleepOff =>
      'El sistema puede suspender según el plan de inactividad';

  @override
  String get settingsPowerSaverNote =>
      'El modo ahorro de energía escucha eventos de estado de ventana (sin sondeo); el motor ya detiene el renderizado cuando la ventana está oculta o la pantalla apagada. Evitar la suspensión del sistema solo se aplica durante la reproducción.';

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
  String get commonOriginal => 'Original';

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
  String get songListScrollTop => 'Volver arriba';

  @override
  String get songListLocatePlaying => 'Ubicar reproducción';

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
  String get pageFavKgCreated => 'Listas creadas';

  @override
  String get pageFavKgCollectedPlaylist => 'Listas guardadas';

  @override
  String get pageFavKgCollectedAlbum => 'Álbumes guardados';

  @override
  String pageFavKgCreatedCount(Object count) {
    return '$count listas creadas';
  }

  @override
  String get pageFavKgCreatedLoginHint =>
      'Inicia sesión para ver tus listas creadas';

  @override
  String pageFavKgCollectedPlaylistCount(Object count) {
    return '$count listas guardadas';
  }

  @override
  String get pageFavKgCollectedPlaylistLoginHint =>
      'Inicia sesión para ver tus listas guardadas';

  @override
  String pageFavKgCollectedAlbumCount(Object count) {
    return '$count álbumes guardados';
  }

  @override
  String get pageFavKgCollectedAlbumLoginHint =>
      'Inicia sesión para ver tus álbumes guardados';

  @override
  String get pageFavKugouLoginDesc =>
      'Inicia sesión con QR en Kugou para sincronizar listas y álbumes creados o guardados';

  @override
  String get pageFavKugouEmptyHint =>
      'Se sincroniza automáticamente al guardar en la app de Kugou';

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
  String get settingsDevFpsMonitor => 'Superposición de monitor FPS/memoria';

  @override
  String get settingsDevFpsMonitorDesc =>
      'Muestra en tiempo real FPS, tiempo medio de fotograma y memoria del proceso en la esquina superior derecha (clic para plegar). Desactivado por defecto; también se desactiva al apagar el modo desarrollador.';

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
  String get settingsSpectrumStyle => 'Estilo de espectro';

  @override
  String get settingsSpectrumStyleDesc =>
      'Efecto de visualización del espectro (barras / onda / onda ascendente)';

  @override
  String get settingsSpectrumStyleBars => 'Barras';

  @override
  String get settingsSpectrumStyleWave => 'Onda';

  @override
  String get settingsSpectrumStyleWaveUp => 'Onda ascendente';

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
  String get settingsEnergySaving => 'Modo de ahorro de energía';

  @override
  String get settingsEnergySavingNote =>
      'Al activarlo, la frecuencia del espectro baja a ~300ms (base 100ms), ahorrando CPU; el renderizado y la interpolación no se ven afectados y el cambio se aplica al instante.';

  @override
  String get settingsEnergySavingOn =>
      'Actualmente en modo de reducción de fotogramas';

  @override
  String get settingsEnergySavingOff => 'Actualmente en modo estándar';

  @override
  String get settingsSearchEnergySavingSubtitle =>
      'Reducir la frecuencia del espectro para ahorrar CPU';

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
  String get settingsSectionFingerprint => 'Huella del dispositivo';

  @override
  String get settingsFingerprintNote =>
      'Identificador de dispositivo en las solicitudes de descarga de Kugou / Netease; se genera en el primer inicio y permanece fijo, único por usuario.';

  @override
  String get settingsDownloadDynamicFingerprint =>
      'Huella dinámica del dispositivo';

  @override
  String get settingsDownloadDynamicFingerprintDesc =>
      'Regenera el identificador de dispositivo en cada inicio (comportamiento anterior); puede activar el control de riesgo de la plataforma. Desactivado por defecto.';

  @override
  String get settingsResetFingerprint => 'Restablecer huella del dispositivo';

  @override
  String get settingsResetFingerprintDesc =>
      'Tras el restablecimiento, esta máquina aparecerá como un dispositivo nuevo ante Kugou / Netease; las sesiones con la huella anterior podrían dejar de funcionar. ¿Restablecer ahora?';

  @override
  String get toastFingerprintReset => 'Huella del dispositivo restablecida';

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
      'Biblioteca y datos de usuario separados físicamente; rutas anulables con ARCHOERA_DATA_DIR';

  @override
  String get settingsSectionCache => 'Gestión de caché';

  @override
  String get settingsCacheNote =>
      'La caché acelera la navegación y la reproducción; se reconstruye automáticamente al borrarla. No afecta a la biblioteca, el historial ni las cuentas.';

  @override
  String get settingsCacheGroupDisk => 'Caché de base de datos (disco)';

  @override
  String get settingsCacheGroupMem => 'Caché en memoria (en el proceso)';

  @override
  String get settingsCacheLimitLyric => 'Límite de caché de letras';

  @override
  String get settingsCacheLimitCover => 'Límite de caché de portadas';

  @override
  String get settingsCacheLimitUnlimited => 'Sin límite';

  @override
  String get settingsCacheNoLimitConfirmTitle =>
      '¿Eliminar el límite del caché?';

  @override
  String get settingsCacheNoLimitConfirmDesc =>
      'Sin límite, los cachés de letras y portadas pueden ocupar memoria ilimitada, causando presión de memoria y ralentizaciones. ¿Eliminar el límite?';

  @override
  String get settingsCacheNoLimitConfirm => 'Eliminar límite';

  @override
  String get settingsSongCache => 'Caché de canciones';

  @override
  String get settingsSongCacheNote =>
      'Las canciones en línea reproducidas se guardan en caché en el disco local; al reproducirlas de nuevo se leen directamente del archivo local (ahorra datos, más rápido, reproducible sin conexión). Al superar el límite, los títulos menos usados se eliminan automáticamente (LRU). El mínimo de 16 MiB permite almacenar una canción completa de 320 kbps (~2,4 MiB/min). El caché se reconstruye automáticamente; la biblioteca, el historial y las cuentas no se ven afectados.';

  @override
  String get settingsSongCacheOn =>
      'Activado; las reproducciones en caché usan el disco local';

  @override
  String get settingsSongCacheOff =>
      'Desactivado: la caché de medios no se guardará localmente';

  @override
  String get settingsSongCacheLimitTitle => 'Límite del caché';

  @override
  String settingsCacheSongs(Object count) {
    return '$count canciones';
  }

  @override
  String get settingsSearchSongCacheSubtitle =>
      'Activación y límite (MiB) del caché de canciones en línea';

  @override
  String get settingsCacheLiked => 'Caché de la lista «Me gusta»';

  @override
  String get settingsCacheLyric => 'Caché de letras';

  @override
  String get settingsCacheLyricMatch => 'Caché de coincidencias de letras';

  @override
  String get settingsCacheLyricTtml => 'Caché de letras TTML';

  @override
  String get settingsCacheCover => 'Caché de portadas';

  @override
  String settingsCacheEntries(Object count) {
    return '$count entradas';
  }

  @override
  String settingsCacheImages(Object count) {
    return '$count imágenes';
  }

  @override
  String get settingsCacheRefresh => 'Actualizar';

  @override
  String get settingsCacheClear => 'Borrar';

  @override
  String get settingsCacheClearAll => 'Borrar todo';

  @override
  String settingsCacheClearConfirmTitle(Object name) {
    return '¿Borrar «$name»?';
  }

  @override
  String get settingsCacheClearConfirmDesc =>
      'Se eliminarán todos los datos de esta caché; se reconstruirá automáticamente al usarla de nuevo. No se puede deshacer.';

  @override
  String get settingsCacheClearAllConfirmTitle => '¿Borrar toda la caché?';

  @override
  String get settingsCacheClearAllConfirmDesc =>
      'Se eliminará toda la caché anterior (memoria y disco). No afecta a la biblioteca, el historial ni las cuentas.';

  @override
  String toastCacheCleared(Object name) {
    return 'Caché de $name borrada';
  }

  @override
  String get toastCacheAllCleared => 'Toda la caché borrada';

  @override
  String get settingsSecuritySection => 'Destrucción segura';

  @override
  String get settingsSecurityNote =>
      'Elimina de forma irreversible todas las credenciales y sesiones de cuenta (contraseñas de servidores de streaming, sesiones de Netease/Kugou, cuentas locales de Subsonic) e invalida los tokens de las plataformas. No afecta a la biblioteca, el historial ni las descargas.';

  @override
  String get settingsSecurityStreaming =>
      'Credenciales de servidores de streaming';

  @override
  String settingsSecurityStreamingCount(Object count) {
    return '$count servidores';
  }

  @override
  String get settingsSecurityStreamingDesc => 'Contraseñas y tokens de acceso';

  @override
  String get settingsSecuritySession => 'Sesiones de cuentas de terceros';

  @override
  String get settingsSecuritySessionDesc =>
      'Estado de inicio de sesión de Netease / Kugou';

  @override
  String get settingsSecurityUserDb => 'Base de usuarios local';

  @override
  String get settingsSecurityUserDbDesc => 'Cuentas de Subsonic y favoritos';

  @override
  String get settingsSecurityLoggedIn => 'Sesión iniciada';

  @override
  String get settingsSecurityDestroy => 'Destruir';

  @override
  String get settingsSecurityDestroyAll => 'Destruir todo';

  @override
  String settingsSecurityConfirmTitle(Object name) {
    return '¿Destruir «$name»?';
  }

  @override
  String get settingsSecurityConfirmAllTitle =>
      '¿Destruir todos los datos sensibles?';

  @override
  String settingsSecurityConfirmDesc(Object word) {
    return 'Se invalidarán los tokens de las plataformas afectadas y los archivos se sobrescribirán y eliminarán. Esta operación es irreversible. Escriba «$word» para confirmar.';
  }

  @override
  String get settingsSecurityConfirmWord => 'destruir';

  @override
  String settingsSecurityConfirmHint(Object word) {
    return 'Escriba «$word»';
  }

  @override
  String toastSecurityDestroyed(Object name) {
    return 'Destruido: $name';
  }

  @override
  String get toastSecurityAllDestroyed =>
      'Se han destruido todos los datos sensibles';

  @override
  String toastSecurityDestroyFailed(Object path) {
    return 'Error al destruir, el archivo puede permanecer: $path';
  }

  @override
  String get settingsDeviceBindSection =>
      'Avanzado · Vinculación del dispositivo';

  @override
  String get settingsDeviceBindNote =>
      'Opción avanzada (opt-in): sin contraseña en este dispositivo + contraseña de recuperación tras un cambio de dispositivo, sin depender del almacenamiento seguro del sistema. Al activarla se lee un identificador local del dispositivo (solo se guarda localmente, nunca se sube). Desactivada por defecto; el cifrado v1 predeterminado es suficiente para la mayoría de usuarios.';

  @override
  String get settingsDeviceBindSwitch =>
      'Sin contraseña vinculada al dispositivo';

  @override
  String get settingsDeviceBindSwitchDesc =>
      'Desbloqueo automático en este dispositivo; contraseña de recuperación tras un cambio de dispositivo';

  @override
  String get settingsDeviceBindSwitchOffDesc =>
      'Desactivada. El almacenamiento seguro del sistema no está disponible aquí; active la vinculación del dispositivo para desbloquear sin contraseña';

  @override
  String get settingsDeviceBindSwitchV1Desc =>
      'Modo v1 actual (almacenamiento seguro del sistema); activar actualiza a la vinculación del dispositivo (sin contraseña + contraseña de recuperación, se conservan los datos existentes)';

  @override
  String get settingsDeviceBindSwitchV2Desc =>
      'Modo v2 actual (contraseña); activar requiere primero introducir la contraseña actual para desbloquear y luego actualiza a la vinculación del dispositivo (sin contraseña en este dispositivo)';

  @override
  String get settingsDeviceBindPrivacyTitle =>
      '¿Activar el modo sin contraseña vinculado al dispositivo?';

  @override
  String get settingsDeviceBindPrivacyDesc =>
      'Se leerá un identificador local del dispositivo (Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID) y se vinculará a su bóveda; solo se guarda localmente y nunca se sube. Nota: esta operación no puede volver al modo sin contraseña actual del sistema; desactivar la vinculación más tarde pasa al modo de contraseña (introducción en cada inicio).';

  @override
  String get settingsDeviceBindEnable => 'Activar';

  @override
  String get settingsDeviceBindRecoveryTitle =>
      'Establecer contraseña de recuperación (opcional)';

  @override
  String get settingsDeviceBindRecoveryDesc =>
      'Use la contraseña de recuperación para desbloquear los credenciales tras un cambio de dispositivo/reinstalación. Déjelo vacío para no establecerla: sin recuperación posible tras un cambio de dispositivo (fail-closed; se requiere borrar y reconstruir).';

  @override
  String get settingsDeviceBindRecoveryHint => 'Contraseña de recuperación';

  @override
  String get settingsDeviceBindSkip => 'Activar sin contraseña';

  @override
  String get settingsDeviceBindChangeRecovery =>
      'Establecer / cambiar contraseña de recuperación';

  @override
  String get settingsDeviceBindChangeRecoveryTitle =>
      'Establecer una nueva contraseña de recuperación';

  @override
  String get settingsDeviceBindChangeRecoveryDesc =>
      'La contraseña antigua queda invalidada de inmediato. Recuerde bien la nueva: el desbloqueo de credenciales tras un cambio de dispositivo depende de ella.';

  @override
  String get settingsDeviceBindRebind => 'Vincular de nuevo este dispositivo';

  @override
  String get settingsDeviceBindRebindDesc =>
      'Re-sellar con la huella actual del dispositivo; la huella antigua queda invalidada de inmediato (usar tras la recuperación)';

  @override
  String get settingsDeviceBindRebindTitle =>
      '¿Vincular de nuevo este dispositivo?';

  @override
  String get settingsDeviceBindRebindConfirm => 'Vincular ahora';

  @override
  String get settingsDeviceBindClose =>
      'Desactivar la vinculación del dispositivo';

  @override
  String get settingsDeviceBindCloseDesc =>
      'Eliminar el sello de entropía del dispositivo; la bóveda pasa al modo de contraseña';

  @override
  String get settingsDeviceBindCloseTitle =>
      '¿Desactivar la vinculación del dispositivo?';

  @override
  String get settingsDeviceBindCloseConfirmDesc =>
      'Se eliminará el sello de entropía del dispositivo y la bóveda pasará al modo de contraseña: a partir de entonces se requiere una contraseña en cada sesión. Esa contraseña se convierte en su nueva contraseña de sesión. Introduzca la contraseña de recuperación actual para confirmar.';

  @override
  String get settingsDeviceBindCloseHint => 'Contraseña de recuperación actual';

  @override
  String get settingsDeviceBindRecoveryBanner =>
      'Se ha detectado un cambio de dispositivo o un archivo de entropía dañado: credenciales bloqueados, se requiere la contraseña de recuperación';

  @override
  String get settingsDeviceBindRecover => 'Recuperar';

  @override
  String get settingsDeviceBindRecoverTitle =>
      'Introducir contraseña de recuperación';

  @override
  String get settingsDeviceBindRecoverDesc =>
      'Desbloquee los credenciales con la contraseña de recuperación; tras el éxito, vuelva a vincular este dispositivo para restaurar el modo sin contraseña.';

  @override
  String get settingsDeviceBindShowPassword => 'Mostrar / ocultar contraseña';

  @override
  String get toastDeviceBindEnabled =>
      'Modo sin contraseña vinculado al dispositivo activado';

  @override
  String get toastDeviceBindRecoverySet =>
      'Contraseña de recuperación actualizada';

  @override
  String get toastDeviceBindRebound => 'Dispositivo vinculado de nuevo';

  @override
  String get toastDeviceBindClosed =>
      'Vinculación desactivada; la bóveda usa ahora el modo de contraseña';

  @override
  String get toastDeviceBindRecoveryNeeded =>
      'No se ha establecido contraseña de recuperación; no se puede desactivar la vinculación';

  @override
  String toastDeviceBindCloseFailed(Object error) {
    return 'Error al desactivar: $error';
  }

  @override
  String get toastDeviceBindRecovered =>
      'Credenciales recuperados; vuelva a vincular este dispositivo para restaurar el modo sin contraseña';

  @override
  String get toastDeviceBindRecoverFailed =>
      'Contraseña de recuperación incorrecta o error de desbloqueo; credenciales siguen bloqueados';

  @override
  String get settingsSchemeIntroTitle => 'Método de cifrado';

  @override
  String get settingsSchemeIntroDesc =>
      'Sus credenciales de inicio de sesión (cookies) están protegidas por un método de cifrado. El método LEGACY (recomendado) está activado: la clave maestra vive en el almacenamiento seguro del sistema — estable y fiable. Para una mayor protección puede cambiar a Vault (experimental) en Ajustes → Método de cifrado de credenciales — tenga en cuenta que el cambio reconstruye la base de datos y pierde todos los credenciales de inicio de sesión.';

  @override
  String get settingsSchemeIntroGotIt => 'Entendido';

  @override
  String get settingsSchemeSection => 'Método de cifrado de credenciales';

  @override
  String get settingsSchemeNote =>
      'Elija cómo se cifran los credenciales de inicio de sesión. LEGACY: almacenamiento seguro del sistema, estable y fiable (recomendado). FILK (clave de archivo): clave maestra en un archivo local secret.key — sin llavero del sistema, para headless/Docker (punto único). Vault: método experimental de doble factor 2-of-2 — protección más fuerte pero posible pérdida de cookies. El cambio de método reconstruye la base de datos y requiere volver a iniciar sesión.';

  @override
  String get settingsSchemeCryptoTitle => 'LEGACY';

  @override
  String get settingsSchemeCryptoBadge => 'Recomendado';

  @override
  String get settingsSchemeCryptoDesc =>
      'Las cookies se cifran con el almacenamiento seguro del sistema (Windows DPAPI / macOS Llavero / Linux libsecret). Estable y fiable.';

  @override
  String get settingsSchemeCryptoModeDesc =>
      'Método LEGACY: la clave maestra está protegida por completo por el almacenamiento seguro del sistema. Buen equilibrio entre seguridad y estabilidad para el uso diario.';

  @override
  String get settingsSchemeFileTitle => 'FILK';

  @override
  String get settingsSchemeFileBadge => 'Compat.';

  @override
  String get settingsSchemeFileDesc =>
      'La clave maestra vive en un archivo local (secret.key, 0600). No requiere llavero del sistema — para Linux sin interfaz / Docker. Punto único: si el archivo de clave se filtra, todas las credenciales quedan expuestas.';

  @override
  String get settingsSchemeFileModeDesc =>
      'Modo FILK (clave de archivo): la clave maestra se guarda en secret.key (0600, escritura atómica) — la forma clásica de cifrado del lado del servidor. Usar solo sin llavero del sistema (headless/Docker).';

  @override
  String get settingsSchemeVaultTitle => 'Vault';

  @override
  String get settingsSchemeVaultBadge => 'Experimental';

  @override
  String get settingsSchemeVaultDesc =>
      'Cifrado de doble factor 2-of-2 (parte del sistema + parte del usuario, ambas necesarias). Más resistente a ataques sin conexión, pero las cookies pueden perderse ante anomalías.';

  @override
  String get settingsSchemeVaultModeDesc =>
      'Método Vault: la clave maestra se divide en una parte del sistema y una del usuario — ambas necesarias. Elija v1 protección del sistema / v2 contraseña / v3 vinculación del dispositivo como nivel de sellado.';

  @override
  String get settingsSchemeSwitchTitle => '¿Cambiar de método de cifrado?';

  @override
  String get settingsSchemeSwitchToVaultWarning =>
      'Vault es experimental: las cookies pueden perderse tras el cambio.';

  @override
  String get settingsSchemeSwitchToFileWarning =>
      'El modo FILK es un respaldo de compatibilidad: la clave maestra vive en un archivo local. Si se filtra, todas las credenciales quedan expuestas. Solo para entornos headless/Docker sin llavero del sistema.';

  @override
  String get settingsSchemeSwitchRebuildDesc =>
      'Los métodos usan estructuras cifradas incompatibles. El cambio destruye la bóveda actual y reconstruye la base de datos; todos los credenciales de inicio de sesión (Netease / Kugou / cuentas de streaming) se perderán y requerirán volver a iniciar sesión.';

  @override
  String get settingsSchemeSwitchKeep => 'Mantener el actual';

  @override
  String get settingsSchemeSwitchConfirm => 'Cambiar y reconstruir';

  @override
  String get toastSchemeSwitched =>
      'Método de cifrado cambiado; efectivo tras reiniciar';

  @override
  String get settingsVaultSection => 'Cifrado de credenciales';

  @override
  String get settingsVaultNote =>
      'Elija el nivel de protección de los credenciales: v1 protección del sistema (predeterminado) / v2 protección por contraseña / v3 vinculación del dispositivo (opción avanzada opt-in; lee un identificador local del dispositivo, solo se guarda localmente, nunca se sube). v1 ↔ v2 se pueden alternar libremente; v3 es el nivel final y vuelve a v2 al desactivarse.';

  @override
  String get settingsVaultModeV1 => 'v1 Protección del sistema';

  @override
  String get settingsVaultModeV2 => 'v2 Contraseña';

  @override
  String get settingsVaultModeV3 => 'v3 Vinculación del dispositivo';

  @override
  String get settingsVaultModeDescOs =>
      'v1 Protección del sistema: credenciales cifrados por el almacenamiento seguro del sistema (Windows DPAPI / macOS Llavero / Linux libsecret), sin contraseña en este dispositivo.';

  @override
  String get settingsVaultModeDescPassword =>
      'v2 Protección por contraseña: credenciales cifrados por una contraseña que se introduce en cada inicio. Puede volver a la protección del sistema (v1) en cualquier momento.';

  @override
  String get settingsVaultModeDescMultiseal =>
      'v3 Vinculación del dispositivo: sin contraseña en este dispositivo; se requiere una contraseña de recuperación tras un cambio de dispositivo. No puede bajar directamente a v1 — al desactivarse vuelve al modo de contraseña v2.';

  @override
  String get settingsVaultModeDescUnknown => 'Leyendo el nivel de cifrado…';

  @override
  String get settingsVaultSwitchToPasswordTitle =>
      'Cambiar a protección por contraseña (v2)';

  @override
  String get settingsVaultSwitchToPasswordDesc =>
      'Los credenciales estarán protegidos por una contraseña introducida en cada inicio. Su clave maestra y datos existentes se conservan; puede volver a la protección del sistema (v1) en cualquier momento.';

  @override
  String get settingsVaultSwitchToPasswordNewHint =>
      'Establecer nueva contraseña';

  @override
  String get settingsVaultSwitchToPasswordConfirmHint =>
      'Volver a introducir la nueva contraseña';

  @override
  String get settingsVaultSwitchToPasswordMismatch =>
      'Las dos entradas no coinciden';

  @override
  String get settingsVaultSwitchToOsTitle =>
      'Volver a la protección del sistema (v1)';

  @override
  String get settingsVaultSwitchToOsDesc =>
      'Los credenciales estarán protegidos por el almacenamiento seguro del sistema; no se requiere contraseña. Puede volver a la protección por contraseña (v2) en cualquier momento.';

  @override
  String get settingsVaultNeedUnlockFirst =>
      'La protección por contraseña aún no está desbloqueada: desbloquéela primero y luego cambie';

  @override
  String get settingsVaultV3NoDirectV1 =>
      'La vinculación del dispositivo (v3) no puede bajar directamente a v1: primero desactive la vinculación para volver al modo de contraseña v2';

  @override
  String get settingsVaultCloseV3PasswordTitle =>
      'Desactivar la vinculación: establecer nueva contraseña';

  @override
  String get settingsVaultCloseV3PasswordDesc =>
      'No se estableció una contraseña de recuperación al activar la vinculación (sin contraseña en este dispositivo). Al desactivarla se pasa a la protección por contraseña (v2): establezca una nueva contraseña de desbloqueo. La clave maestra y los datos existentes se conservan; esta contraseña se requiere en cada inicio.';

  @override
  String get toastVaultSwitchedToPassword =>
      'Cambiado a protección por contraseña (v2)';

  @override
  String get toastVaultSwitchedToOs =>
      'Vuelto a la protección del sistema (v1)';

  @override
  String get settingsVaultShareBrokenBanner =>
      'Las partes de la bóveda no coinciden: backend de almacenamiento distinto o parte faltante. No se pueden descifrar los credenciales locales. Reconstruya la bóveda e inicie sesión de nuevo.';

  @override
  String get settingsVaultShareBrokenRebuild => 'Reconstruir la bóveda';

  @override
  String get settingsVaultRestartTitle => 'Reinicio necesario';

  @override
  String get settingsVaultRestartDesc =>
      'El nivel de cifrado se ha cambiado correctamente. Reinicie la aplicación para garantizar la integridad de la base de datos y el estado coherente de todos los módulos. En el modo de contraseña (v2), se le pedirá su contraseña tras el reinicio; la sesión y los credenciales de streaming no están disponibles (mostrados como desconectados) hasta el desbloqueo. La reproducción y las descargas se interrumpen durante el reinicio.';

  @override
  String get settingsVaultRestartNow => 'Reiniciar ahora';

  @override
  String get settingsVaultRestartLater => 'Más tarde';

  @override
  String get vaultCrashTitle =>
      'El módulo de credenciales terminó de forma anómala';

  @override
  String get vaultCrashDesc =>
      'El proceso de la bóveda de credenciales terminó inesperadamente. Los credenciales locales pueden haber quedado expuestos. Vuelva a iniciar sesión o borre la bóveda para reconstruir los credenciales.';

  @override
  String get vaultCrashReset => 'Borrar y reconstruir';

  @override
  String get vaultCrashDismiss => 'OK';

  @override
  String get vaultVersionTitle =>
      'Versión anómala de la bóveda de credenciales';

  @override
  String get vaultVersionDesc =>
      'Se ha detectado una anomalía en el componente de la bóveda: su copia binaria pudo ser reemplazada o provenir de una compilación no oficial, lo que podría haber expuesto los credenciales locales. La copia anómala se eliminó y se denegó el descifrado. Salga y reinstale la aplicación.';

  @override
  String get vaultVersionExit => 'Salir';

  @override
  String get vaultVersionReasonReplaced =>
      'Se detectó un binario de la bóveda reemplazado o una compilación no oficial; copia anómala eliminada y descifrado denegado.';

  @override
  String get vaultVersionReasonMarkerMissing =>
      'La respuesta del protocolo de enlace de la bóveda no incluye el marcador de compilación oficial.';

  @override
  String get vaultVersionReasonMarkerMismatch =>
      'El marcador de compilación de la bóveda no coincide con el artefacto oficial; copia anómala eliminada y descifrado denegado.';

  @override
  String get vaultUnlockTitle => 'Desbloquear la bóveda de credenciales';

  @override
  String get vaultUnlockDesc =>
      'La bóveda de credenciales está en modo de contraseña (v2). Introduzca la contraseña para desbloquear los credenciales de inicio de sesión y las cuentas de streaming.';

  @override
  String get vaultUnlockHint => 'Contraseña';

  @override
  String get vaultUnlockConfirm => 'Desbloquear';

  @override
  String get vaultUnlockSkip => 'Más tarde';

  @override
  String get vaultUnlockFailed => 'Contraseña incorrecta, inténtelo de nuevo';

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
  String get settingsSectionWeather => 'Clima';

  @override
  String get settingsWeather => 'Widget de clima';

  @override
  String get settingsWeatherDesc =>
      'Clima mini (icono + temperatura) a la izquierda del avatar';

  @override
  String get settingsWeatherAutoLocate => 'Ubicación automática';

  @override
  String get settingsWeatherAutoLocateDesc =>
      'Ubicación aproximada por IP de red (privacidad: desactivada por defecto)';

  @override
  String get settingsWeatherCity => 'Ciudad manual';

  @override
  String get settingsWeatherCityHint =>
      'Sin ubicación por IP una vez rellenado (p. ej. Madrid)';

  @override
  String get settingsWeatherNote =>
      'Privacidad: datos de Open-Meteo (gratis, sin clave). Con ubicación automática, tu IP se envía a ip-api.com para una ubicación aproximada, solo para el clima, sin guardarse. Widget y ubicación están desactivados por defecto.';

  @override
  String get settingsSearchWeatherSubtitle =>
      'Widget de clima mini en la barra superior (icono + temperatura)';

  @override
  String get weatherRefresh => 'Actualizar clima';

  @override
  String get weatherNoLocation =>
      'Introduce una ciudad o activa la ubicación en ajustes';

  @override
  String get weatherUnavailable => 'Clima no disponible, toca para reintentar';

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
