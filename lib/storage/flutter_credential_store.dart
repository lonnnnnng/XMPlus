import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

/// The only credential adapter which depends on Flutter platform channels.
class FlutterCredentialStore implements CredentialStore {
  FlutterCredentialStore({FlutterSecureStorage? storage})
    // long: 独立 Mac 应用无需跨应用共享钥匙串，普通钥匙串可安全保存凭据且不绑定开发机配置。
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
