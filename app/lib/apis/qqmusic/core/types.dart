/// QM 模块函数签名——对齐 apis/qqmusic/core/types.ts。
///
/// 入参来自调用方非受控数据；module 内部直接解构即可。
library;

/// 业务参数
typedef QmParams = Map<String, dynamic>;

/// 模块函数签名
typedef QmModule = Future<Object?> Function(QmParams params);
