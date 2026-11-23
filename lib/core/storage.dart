import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Credentials go to the platform keystore (Keychain / Android Keystore),
/// never to plain preferences – the website keeps them in localStorage, which
/// on a phone would be readable from a backup.
class SecureStore {
  SecureStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _kToken = 'token';
  static const _kRole = 'role';
  static const _kUser = 'user';
  static const _kReservationTokens = 'reservationTokens';

  static Future<String?> token() => _storage.read(key: _kToken);
  static Future<String?> role() => _storage.read(key: _kRole);

  static Future<Map<String, dynamic>?> user() async {
    final raw = await _storage.read(key: _kUser);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSession({
    required String token,
    required String role,
    required Map<String, dynamic> user,
  }) async {
    await _storage.write(key: _kToken, value: token);
    await _storage.write(key: _kRole, value: role);
    await _storage.write(key: _kUser, value: jsonEncode(user));
  }

  static Future<void> saveUser(Map<String, dynamic> user) =>
      _storage.write(key: _kUser, value: jsonEncode(user));

  static Future<void> clearSession() async {
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kRole);
    await _storage.delete(key: _kUser);
  }

  /// Capability token issued when an anonymous guest creates a booking; it is
  /// their only proof the booking is theirs (same as apiFetch.js).
  static Future<void> rememberReservationToken(String reservationId, String token) async {
    final all = await _reservationTokens();
    all[reservationId] = token;
    await _storage.write(key: _kReservationTokens, value: jsonEncode(all));
  }

  static Future<String?> reservationToken(String reservationId) async =>
      (await _reservationTokens())[reservationId];

  static Future<Map<String, String>> _reservationTokens() async {
    final raw = await _storage.read(key: _kReservationTokens);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }
}

/// Non-sensitive preferences (last search, small UI state).
class Prefs {
  Prefs._();
  static late SharedPreferences _p;

  static Future<void> init() async => _p = await SharedPreferences.getInstance();

  static String? getString(String key) => _p.getString(key);
  static Future<void> putString(String key, String value) => _p.setString(key, value);
  static Future<void> remove(String key) => _p.remove(key);

  static String? get lastSearch => _p.getString('lastSearch');
  static Future<void> setLastSearch(String v) => _p.setString('lastSearch', v);
}
