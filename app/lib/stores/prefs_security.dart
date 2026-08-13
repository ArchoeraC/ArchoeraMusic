import 'app_prefs.dart';

// ── 凭据加密方案（security. 前缀）──────────────────────────────

/// 凭据加密方案（cookie/密码的落盘保护实现）：
///   'crypto'（LEGACY，默认推荐）：单因子——主密钥 K 整体存 OS 安全存储
///     （DPAPI/Keychain/libsecret），稳定、无份额配对丢失风险；
///   'vault'（实验性）：2-of-2 拆分协同解密，抵御能力更强，但份额/口令/
///     设备绑定任一环节异常都可能导致凭据整体丢失（需销毁重建）。
const credentialSchemeKey = 'security.scheme';

/// 首次启动「加密方案选择」对话框是否已展示（一次性，避免每次启动打扰）。
const credentialSchemeDialogShownKey = 'security.schemeDialogShown';

const String defaultCredentialScheme = 'crypto';

/// 凭据加密方案偏好。
extension SecurityPrefs on AppPrefs {
  /// 当前方案（非法值回退默认 crypto）。
  String get credentialScheme {
    final v = data[credentialSchemeKey];
    if (v is String && (v == 'crypto' || v == 'vault')) return v;
    return defaultCredentialScheme;
  }

  /// 首次启动方案对话框是否已展示。
  bool get schemeDialogShown =>
      data[credentialSchemeDialogShownKey] as bool? ?? false;

  AppPrefs copyWithCredentialScheme(String value) =>
      AppPrefs(initialData: {...data, credentialSchemeKey: value});

  AppPrefs copyWithSchemeDialogShown(bool value) =>
      AppPrefs(initialData: {...data, credentialSchemeDialogShownKey: value});
}
