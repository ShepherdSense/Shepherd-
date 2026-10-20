/// Secure storage for the ZMeta HTTPS ingest bearer token.
///
/// The ingest token is a long-lived credential (unlike the single-use
/// invite token), so it lives in the platform keystore/keychain via
/// flutter_secure_storage — never in SharedPreferences. One token per
/// platform_id; re-joining overwrites, and there is no cross-mesh
/// leakage by construction (the key embeds the platform id).
///
/// This file is Flutter-land (plugin method channels). Pure-Dart logic
/// stays in zmeta_https_ingest.dart.
library zmeta_ingest_store;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ZmetaIngestStore {
  // v11+: AndroidOptions() defaults to KeyStore-backed AES-GCM storage
  // (the old encryptedSharedPreferences flag was removed).
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  /// Storage key for a mesh's ingest token.
  static String keyFor(String platformId) => 'zmeta_ingest_token_$platformId';

  static Future<void> writeToken(String platformId, String token) =>
      _storage.write(key: keyFor(platformId), value: token);

  static Future<String?> readToken(String platformId) =>
      _storage.read(key: keyFor(platformId));

  static Future<void> deleteToken(String platformId) =>
      _storage.delete(key: keyFor(platformId));
}
