// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../scrape_controller.dart';

mixin _ScrapeControllerEvents on Notifier<ScrapeState>, _ScrapeControllerCore {
  @override
  void _poll() {
    final s = _scraper;
    if (s == null || _stopped) return;
    while (true) {
      final ev = s.pollEvent();
      if (ev == null) break;
      _handleEvent(ev);
    }
    if (s.isDone) {
      _finish();
    }
  }

  @override
  void _handleEvent(String json) {
    Map<String, dynamic> evt;
    try {
      evt = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (evt['type']) {
      case 'progress':
        state = state.copyWith(
          scraping: true,
          total: _num(evt, 'total', state.total),
          scraped: _num(evt, 'scraped', state.scraped),
          success: _num(evt, 'success', state.success),
          failed: _num(evt, 'failed', state.failed),
          skipped: _num(evt, 'skipped', state.skipped),
          notFound: _num(evt, 'notFound', state.notFound),
          current: evt['current']?.toString() ?? '',
        );
        break;
      case 'done':
        state = state.copyWith(
          scraping: false,
          total: _num(evt, 'total', state.total),
          scraped: _num(evt, 'scraped', state.scraped),
          success: _num(evt, 'success', state.success),
          failed: _num(evt, 'failed', state.failed),
          skipped: _num(evt, 'skipped', state.skipped),
          notFound: _num(evt, 'notFound', state.notFound),
          canceled: evt['canceled'] == true,
          current: '',
        );
        break;
      case 'empty':
        state = state.copyWith(
          scraping: false,
          current: evt['message']?.toString() ?? '',
        );
        break;
      case 'error':
        state = state.copyWith(
          scraping: false,
          error: evt['message']?.toString() ?? '未知错误',
        );
        break;
    }
  }

  int _num(Map<String, dynamic> evt, String key, int fallback) {
    final v = evt[key];
    return v is num ? v.toInt() : fallback;
  }
}
