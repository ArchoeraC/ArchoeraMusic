/// KG 模块函数签名——对齐 apis/kugou/core/types.ts。
library;

/// 业务参数
typedef KgParams = Map<String, dynamic>;

/// 模块函数签名
typedef KgModule = Future<Object?> Function(KgParams params);
