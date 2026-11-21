import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app ships in one language only: British English (en-GB).
///
/// Copy lives in assets/l10n/en.json, keyed like the website's translation
/// tables. Older call sites still pass a second-language fallback
/// (`t('Key', 'fallback')`, `t.pick(other, en)`); only the English side is used.
class Strings {
  Strings(this._map);
  final Map<String, String> _map;

  /// Language code passed to the API and used in a few lookups.
  String get lang => 'en';

  /// Always true – kept so existing `t.isEn ? … : …` branches stay valid.
  bool get isEn => true;

  /// `t('Search')` – value from en.json, or [fallback]/the key when missing.
  String call(String key, [String? fallback]) {
    final v = _map[key];
    if (v != null && v.isNotEmpty) return v;
    return fallback ?? key;
  }

  /// Inline copy written in code: returns the English text.
  String pick(String other, String en) => en;

  static Map<String, String> _table = const {};

  static Future<void> load() async {
    final raw = await rootBundle.loadString('assets/l10n/en.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    _table = decoded.map((k, v) => MapEntry(k, v.toString()));
  }

  static Strings get current => Strings(_table);
}

/// The single app language. Kept as a provider so widgets that watch it keep
/// compiling; it never changes.
final langProvider = Provider<String>((ref) => 'en');

final stringsProvider = Provider<Strings>((ref) => Strings.current);
