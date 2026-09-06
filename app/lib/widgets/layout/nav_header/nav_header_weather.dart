// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../nav_header.dart';

class _WeatherMini extends ConsumerStatefulWidget {
  const _WeatherMini();

  @override
  ConsumerState<_WeatherMini> createState() => _WeatherMiniState();
}

class _WeatherMiniState extends ConsumerState<_WeatherMini> {
  static const _refreshInterval = Duration(minutes: 30);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  ({bool autoLocate, String? city, String locateSource}) get _locator {
    final prefs = ref.read(appPrefsProvider);
    return (
      autoLocate: prefs.weatherAutoLocate,
      city: prefs.weatherCity,
      locateSource: prefs.weatherLocateSource,
    );
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!ref.read(appPrefsProvider).weatherEnabled) return;
    final loc = _locator;
    ref
        .read(weatherProvider)
        .refresh(
          autoLocate: loc.autoLocate,
          city: loc.city,
          locateSource: loc.locateSource,
        );
    _timer = Timer.periodic(_refreshInterval, (_) {
      final l = _locator;
      ref
          .read(weatherProvider)
          .refresh(
            autoLocate: l.autoLocate,
            city: l.city,
            locateSource: l.locateSource,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPrefsProvider);
    ref.listen(appPrefsProvider, (prev, next) {
      if (prev?.weatherEnabled != next.weatherEnabled ||
          prev?.weatherAutoLocate != next.weatherAutoLocate ||
          prev?.weatherLocateSource != next.weatherLocateSource ||
          prev?.weatherCity != next.weatherCity) {
        _sync();
      }
    });
    if (!prefs.weatherEnabled) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final w = ref.watch(weatherProvider);
    final loc = _locator;

    final Widget content;
    final String tooltip;
    final now = w.now;
    if (now != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(now.icon, size: 20, color: now.color),
          const SizedBox(width: 5),
          Text(
            '${now.tempC.round()}°',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      );
      tooltip =
          '${now.city} · ${now.tempC.toStringAsFixed(1)}°C · '
          '${l10n.weatherRefresh}';
    } else if (w.loading) {
      content = Icon(
        Icons.cloud_outlined,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
      tooltip = '';
    } else if (w.error == weatherNoLocationError) {
      content = Icon(
        Icons.cloud_off_outlined,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      );
      tooltip = l10n.weatherNoLocation;
    } else {
      content = Icon(
        Icons.cloud_off_outlined,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      );
      tooltip = l10n.weatherUnavailable;
    }

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ref
            .read(weatherProvider)
            .refresh(autoLocate: loc.autoLocate, city: loc.city),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: content,
        ),
      ),
    );
  }
}
