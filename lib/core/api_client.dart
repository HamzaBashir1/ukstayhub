import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'config.dart';
import 'json.dart';
import 'storage.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.status, this.code, this.data});
  final String message;
  final int? status;
  final String? code;
  final dynamic data;

  bool get isUnauthorized => status == 401;
  bool get isNetwork => status == null;
  bool get isTimeout => code == 'timeout';

  /// The phone couldn't reach the server at all (no internet, DNS failure,
  /// airplane mode) – as opposed to the server answering with an error.
  bool get isOffline => code == 'offline';

  @override
  String toString() => message;
}

/// One Dio instance for the whole app.
///
/// * Attaches the bearer token (kept in memory, persisted in the keystore).
/// * Attaches a booking's capability token when a call names `reservationId`.
/// * Turns every failure into an [ApiException] with the server's message.
/// * Reports 401s once so the session can be cleared (website: SESSION_EXPIRED_EVENT).
/// * Caches public GETs for a short time – home sections, destinations and
///   listing pages open instantly on revisit and the backend sees less load.
class ApiClient {
  ApiClient._() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      // The backend runs on Render, which sleeps when idle and can take
      // 30–60 s to wake up. On web, Dio's connectTimeout also covers the wait
      // for the response headers, so a short value aborts slow-but-fine calls.
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
      // Browsers can't time the upload of a body-less request; setting this
      // on web only produces the "sendTimeout cannot be used" warning.
      sendTimeout: kIsWeb ? null : const Duration(seconds: 60),
      // X-Client tells the backend this is the mobile app, so Stripe return
      // pages (Connect onboarding) come back to the app, not the website.
      headers: {'Accept': 'application/json', if (!kIsWeb) 'X-Client': 'app'},
      responseType: ResponseType.json,
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final t = token;
        if (t != null && t.isNotEmpty) options.headers['Authorization'] = 'Bearer $t';
        final rid = options.extra['reservationId'] as String?;
        if (rid != null) {
          final cap = await SecureStore.reservationToken(rid);
          if (cap != null) options.headers['X-Reservation-Token'] = cap;
        }
        handler.next(options);
      },
    ));
    if (kDebugMode) {
      _dio.interceptors.add(LogInterceptor(requestBody: false, responseBody: false));
    }
  }

  static final ApiClient instance = ApiClient._();
  late final Dio _dio;
  Dio get dio => _dio;

  String? token;

  /// Called (once per token) when the server rejects the session.
  void Function()? onSessionExpired;
  String? _expiredFor;

  final Map<String, _CacheEntry> _cache = {};

  void clearCache() => _cache.clear();

  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? cache,
    String? reservationId,
    CancelToken? cancelToken,
  }) async {
    final key = cache == null ? null : _cacheKey(path, query);
    if (key != null) {
      final hit = _cache[key];
      if (hit != null && hit.expires.isAfter(DateTime.now())) return hit.data;
    }
    final data = await _send(() => _dio.get(
          path,
          queryParameters: _clean(query),
          cancelToken: cancelToken,
          options: Options(extra: {'reservationId': reservationId}),
        ));
    if (key != null) {
      _cache[key] = _CacheEntry(data, DateTime.now().add(cache!));
      if (_cache.length > 200) _cache.remove(_cache.keys.first);
    }
    return data;
  }

  /// Raw bytes (PDF receipts), with the same auth headers as every other call.
  Future<List<int>> getBytes(String path, {Map<String, dynamic>? query, String? reservationId}) async {
    final data = await _send(() => _dio.get<List<int>>(
          path,
          queryParameters: _clean(query),
          options: Options(responseType: ResponseType.bytes, extra: {'reservationId': reservationId}),
        ));
    return data as List<int>;
  }

  Future<dynamic> post(String path, {Object? body, String? reservationId}) =>
      _send(() => _dio.post(path, data: body, options: Options(extra: {'reservationId': reservationId})));

  Future<dynamic> put(String path, {Object? body}) => _send(() => _dio.put(path, data: body));

  Future<dynamic> patch(String path, {Object? body}) => _send(() => _dio.patch(path, data: body));

  Future<dynamic> delete(String path, {Object? body}) => _send(() => _dio.delete(path, data: body));

  Future<dynamic> _send(Future<Response<dynamic>> Function() call) async {
    try {
      final res = await call();
      return res.data;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw ApiException('The server is taking too long to respond. Please try again in a moment.', code: 'timeout');
      }
      if (e.response == null &&
          (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.unknown)) {
        throw ApiException('No internet connection.', code: 'offline');
      }
      final status = e.response?.statusCode;
      final data = e.response?.data;
      final map = asMap(data);
      final message = asString(map['message']).isNotEmpty
          ? asString(map['message'])
          : asString(map['error']).isNotEmpty
              ? asString(map['error'])
              : status == null
                  ? 'Network error. Check your connection.'
                  : 'Request failed ($status)';
      if (status == 401 && token != null && _expiredFor != token) {
        _expiredFor = token;
        scheduleMicrotask(() => onSessionExpired?.call());
      }
      throw ApiException(message, status: status, code: asStringOrNull(map['code']), data: data);
    }
  }

  static Map<String, dynamic>? _clean(Map<String, dynamic>? q) {
    if (q == null) return null;
    final out = <String, dynamic>{};
    q.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      out[k] = v;
    });
    return out;
  }

  static String _cacheKey(String path, Map<String, dynamic>? q) {
    final c = _clean(q);
    if (c == null || c.isEmpty) return path;
    final keys = c.keys.toList()..sort();
    return '$path?${keys.map((k) => '$k=${c[k]}').join('&')}';
  }
}

class _CacheEntry {
  _CacheEntry(this.data, this.expires);
  final dynamic data;
  final DateTime expires;
}

final api = ApiClient.instance;
