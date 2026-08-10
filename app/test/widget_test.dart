// 基础单元测试：EventBus 多路复用通道。
//
// 说明：应用启动依赖侧车（Node）与 C 音频引擎，widget 级冒烟测试不适合
// 单元环境，此处以纯 Dart 的事件总线作为冒烟用例。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/event_bus.dart';

void main() {
  test('EventBus 按类型过滤订阅', () async {
    final bus = EventBus();
    final received = <String>[];

    final sub = bus.on<String>().listen(received.add);
    bus.emit('hello');
    bus.emit(42); // 非 String，不应被 String 订阅者收到
    bus.emit('world');

    await Future<void>.delayed(Duration.zero);
    expect(received, ['hello', 'world']);

    await sub.cancel();
    bus.dispose();
  });

  test('EventBus 全量广播', () async {
    final bus = EventBus();
    final received = <Object>[];

    final sub = bus.stream.listen(received.add);
    bus.emit('a');
    bus.emit(1);
    bus.emit(false);

    await Future<void>.delayed(Duration.zero);
    expect(received, ['a', 1, false]);

    await sub.cancel();
    bus.dispose();
  });
}
