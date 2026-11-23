import 'package:flutter/foundation.dart';

/// Build-time configuration. Override with --dart-define, e.g.
///   flutter run --dart-define=API_BASE_URL=https://backend-9k3q.onrender.com/api
///
/// Nothing secret lives here: the app talks only to the UK Stay Hub API, which holds
/// every key (Stripe, Cloudinary secret, Google). The Cloudinary values below
/// are the public unsigned-upload preset the website already ships.
class AppConfig {
  AppConfig._();

  static const String _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

  /// Local backend port. Not 5000: macOS AirPlay Receiver holds that port.
  static const int _localApiPort = 5001;

  /// The API root. A --dart-define wins; otherwise point at the local backend
  /// on the dev machine. The Android emulator reaches the host Mac at 10.0.2.2
  /// (its own `localhost` is the emulator); iOS Simulator, desktop and web
  /// share the Mac's network, so `localhost` works there.
  static String get apiBaseUrl {
    if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
    // return 'https://backend-9k3q.onrender.com/api';
    final host = !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : 'localhost';
    return 'http://$host:$_localApiPort/api';
  }

  /// The website origin. Stripe redirects here after checkout
  /// (CLIENT_SITE_URL on the backend), so the payment WebView watches for it.
  static const String siteUrl = String.fromEnvironment(
    'SITE_URL',
    defaultValue: 'https://ukstayhub.co.uk',
  );

  /// Every domain the website answers on. Stripe may come back to either one,
  /// with or without `www.`, so the payment WebView accepts all of them.
  static const List<String> siteDomains = ['ukstayhub.co.uk', 'ukstayhub.com'];

  static bool isSiteHost(String host) {
    final h = host.toLowerCase();
    final bare = h.startsWith('www.') ? h.substring(4) : h;
    return bare == Uri.parse(siteUrl).host || siteDomains.contains(bare);
  }

  static const String cloudinaryCloudName = String.fromEnvironment(
    'CLOUDINARY_CLOUD',
    defaultValue: 'dekgv22nb',
  );
  static const String cloudinaryUploadPreset = String.fromEnvironment(
    'CLOUDINARY_PRESET',
    defaultValue: 'Putkoproject',
  );

  static const String supportEmail = 'support@ukstayhub.co.uk';
  // TODO: replace with the real UK support line (020 7946 0xxx is Ofcom's reserved fictional range).
  static const String supportPhone = '+442079460000';

  /// Release builds refuse plain-HTTP API endpoints so a token can never be
  /// sent in the clear. Debug builds allow http for a local backend.
  static void assertSecureTransport() {
    if (kReleaseMode && !apiBaseUrl.startsWith('https://')) {
      throw StateError('API_BASE_URL must use https in release builds.');
    }
  }
}
