part of '../scrape_controller.dart';

mixin _ScrapeControllerPump on Notifier<ScrapeState>, _ScrapeControllerCore {
  @override
  Future<void> _ensurePumpDelivery() async {
    final ready = _pumpReady;
    if (ready == null) return;
    try {
      await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      if (!_stopped) _switchToPollFallback();
    }
  }

  @override
  void _startEventPump() {
    final h = _handleAddr;
    if (h == null || h == 0) return;
    final port = ReceivePort();
    _eventPort = port;
    port.listen(
      _onPumpMessage,
      onError: (Object e, StackTrace _) {
        final ready = _pumpReady;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(StateError('事件泵端口错误: $e'));
        }
      },
    );
    final exitPort = ReceivePort();
    _pumpExitPort = exitPort;
    unawaited(_spawnEventPump(h, port, exitPort));
  }

  Future<void> _spawnEventPump(
    int h,
    ReceivePort port,
    ReceivePort exitPort,
  ) async {
    try {
      final iso = await Isolate.spawn(
        _scraperPumpEntry,
        <Object?>[h, port.sendPort],
        debugName: 'scraper-event-pump-0x${h.toRadixString(16)}',
        onExit: exitPort.sendPort,
        onError: exitPort.sendPort,
      );
      _pumpIsolate = iso;
      exitPort.listen((_) {
        final ready = _pumpReady;
        if (!_stopped) {
          if (ready != null && !ready.isCompleted) {
            ready.completeError(StateError('事件泵退出'));
          }
          _switchToPollFallback();
        }
      });
    } catch (e) {
      final ready = _pumpReady;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(StateError('事件泵 spawn 失败: $e'));
      }
    }
  }

  void _onPumpMessage(Object? msg) {
    final ready = _pumpReady;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
      if (msg is int) return;
    }
    if (msg is String && !_stopped) {
      _handleEvent(msg);
      _kickFinishCheck();
    }
  }

  void _kickFinishCheck() {
    if (_stopped || ScrapeController._usePollFallback) return;
    _finishTimer?.cancel();
    _finishTimer = Timer(ScrapeController._finishDelay, () {
      _finishTimer = null;
      if (_stopped) return;
      final s = _scraper;
      if (s != null && s.isDone) _finish();
    });
  }

  void _switchToPollFallback() {
    if (_stopped || _timer != null) return;
    _teardownEventPump();
    _timer = Timer.periodic(ScrapeController._pollInterval, (_) => _poll());
  }

  @override
  void _teardownEventPump() {
    final ready = _pumpReady;
    _pumpReady = null;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
    _eventPort?.close();
    _eventPort = null;
    final iso = _pumpIsolate;
    _pumpIsolate = null;
    _pumpExitPort?.close();
    _pumpExitPort = null;
    iso?.kill(priority: Isolate.immediate);
  }
}

void _scraperPumpEntry(List<Object?> args) {
  final handleAddr = args[0] as int;
  final SendPort toMain = args[1] as SendPort;
  final bindings = ScraperBindings.instance;
  final ptr = Pointer<Void>.fromAddress(handleAddr);
  toMain.send(_scraperPumpHandshake);
  final buf = calloc<Uint8>(_scraperEventBufCap);
  try {
    while (true) {
      final r = bindings.waitEventInto(ptr, buf, _scraperEventBufCap, -1);
      if (r == 0 || r == -1) break;
      toMain.send(buf.cast<Utf8>().toDartString(length: r));
    }
  } finally {
    calloc.free(buf);
  }
}
