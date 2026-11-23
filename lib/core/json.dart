/// Tolerant JSON readers. The API grew over years and the same field can arrive
/// as a number, a numeric string, null or missing; these never throw.
typedef Json = Map<String, dynamic>;

Json asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return <String, dynamic>{};
}

List<dynamic> asList(dynamic v) => v is List ? v : const [];

List<Json> asMapList(dynamic v) => asList(v).whereType<Map>().map(asMap).toList();

String asString(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  if (v is Map && v[r'$oid'] != null) return v[r'$oid'].toString();
  if (v is Map && v['_id'] != null) return asString(v['_id']);
  return fallback;
}

String? asStringOrNull(dynamic v) {
  final s = asString(v);
  return s.isEmpty ? null : s;
}

double asDouble(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(',', '.')) ?? fallback;
  return fallback;
}

int asInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round() ?? fallback;
  return fallback;
}

bool asBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is String) return v == 'true' || v == '1';
  if (v is num) return v != 0;
  return fallback;
}

List<String> asStringList(dynamic v) =>
    asList(v).map((e) => asString(e)).where((e) => e.isNotEmpty).toList();

DateTime? asDate(dynamic v) {
  if (v is DateTime) return v;
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
  return null;
}

/// A calendar day from an API date. Uses the yyyy-MM-dd part as written, so a
/// stored UTC midnight never shifts to the previous day west of UTC.
DateTime? asDay(dynamic v) {
  if (v is DateTime) return DateTime(v.year, v.month, v.day);
  if (v is String && v.length >= 10) {
    final d = DateTime.tryParse(v.substring(0, 10));
    if (d != null) return DateTime(d.year, d.month, d.day);
  }
  return null;
}

/// Reads a value at a dotted path: `pick(json, 'locationDetails.city')`.
dynamic pick(dynamic json, String path) {
  dynamic cur = json;
  for (final part in path.split('.')) {
    if (cur is Map) {
      cur = cur[part];
    } else {
      return null;
    }
  }
  return cur;
}

T? firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final e in items) {
    if (test(e)) return e;
  }
  return null;
}
