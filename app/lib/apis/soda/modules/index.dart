// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水模块注册表（key → [SodaModule]）。
library;

import '../core/types.dart';

import 'album.dart';
import 'comment.dart';
import 'login_qr.dart';
import 'playlist.dart';
import 'search.dart';
import 'track.dart';

final Map<String, SodaModule> sodaModules = {
  'search': sodaSearch,
  'seo_track': sodaSeoTrack,
  'play_info': sodaPlayInfo,
  'playlist': sodaPlaylist,
  'album': sodaAlbum,
  'comments': sodaComments,
  'send_comment': sodaSendComment,
  'login_qr_key': sodaLoginQrKey,
  'login_qr_check': sodaLoginQrCheck,
  'login_send_code': sodaLoginSendCode,
  'login_validate_code': sodaLoginValidateCode,
  'login_upsms': sodaLoginUpSms,
};
