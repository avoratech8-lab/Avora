import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ids.dart';

abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keystore/Keychain-backed storage for the session token and device id.
class SecureKeyValueStore implements KeyValueStore {
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryKeyValueStore implements KeyValueStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// The device id (made once per install) and the current session token.
class Credentials extends ChangeNotifier {
  Credentials._(this._store, this.deviceId, this._token);

  static const _deviceKey = 'device_id';
  static const _tokenKey = 'session_token';

  static Future<Credentials> load(KeyValueStore store) async {
    var device = await store.read(_deviceKey);
    if (device == null) {
      device = randomId();
      await store.write(_deviceKey, device);
    }
    return Credentials._(store, device, await store.read(_tokenKey));
  }

  final KeyValueStore _store;
  final String deviceId;
  String? _token;

  String? get token => _token;
  bool get signedIn => _token != null;

  Future<void> setToken(String? token) async {
    _token = token;
    if (token == null) {
      await _store.delete(_tokenKey);
    } else {
      await _store.write(_tokenKey, token);
    }
    notifyListeners();
  }
}
