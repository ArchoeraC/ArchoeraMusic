part of '../download_controller.dart';

Map<String, dynamic> buildDownloadRequest(
  Track track, {
  String quality = 'hq',
}) {
  final kugou = track.kugou;
  return {
    'trackId': track.id,
    'source': track.source,
    'platformId': track.id,
    'quality': quality,
    'title': track.title,
    'artist': track.artistNames,
    'album': track.album?.name,
    'extra': (track.source == 'kugou' && kugou != null)
        ? {'hashes': kugou.hashes, 'sizes': kugou.sizes}
        : const <String, dynamic>{},
  };
}
