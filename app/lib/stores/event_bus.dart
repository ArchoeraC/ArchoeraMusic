import 'dart:async';

/// 应用层统一事件通道。
///
/// StreamController 多路复用：全量广播 + 按类型过滤订阅。
/// 各模块事件（播放状态 / 扫描进度 / FFT 等）emit 到总线，
/// UI 层统一 `bus.on<T>()` 消费。
class EventBus {
  final StreamController<Object> _controller =
      StreamController<Object>.broadcast(sync: true);

  /// 全量事件流（调试用）。
  Stream<Object> get stream => _controller.stream;

  /// 按类型订阅事件。
  Stream<T> on<T>() => _controller.stream.where((e) => e is T).cast<T>();

  /// 广播事件。
  void emit(Object event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}
