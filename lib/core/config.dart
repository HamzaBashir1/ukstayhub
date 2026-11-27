import 'package:flutter/foundation.dart';

/// Build-time configuration. Which backend the app talks to:
///   flutter run                       (debug)    → backend on this Mac (port 5001)
///   flutter build apk / ipa / web     (release)  → production API (Railway)
///   flutter run --profile / --release            → production API (Railway)
/// Overrides with --dart-define:
///   LOCAL_API=false   → production even in debug (e.g. on a real phone)
///   LOCAL_API=true    → this Mac even in a release/profile build
///   API_BASE_URL=https://…/api  → any other server
///
/// Nothing secret lives here: the app talks only to the UK Stay Hub API, which holds
/// every key (Stripe, Cloudinary secret, Google). The Cloudinary values below
/// are the public unsigned-upload preset the website already ships.
class AppConfig {
  AppConfig._();

  static const String _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');
  /// Local backend in debug runs, production in release/profile builds,
  /// unless LOCAL_API is passed explicitly.
  static const bool _localApi =
      bool.hasEnvironment('LOCAL_API') ? bool.fromEnvironment('LOCAL_API') : kDebugMode;

  /// The production backend on Railway.
  static const String productionApiUrl = 'https://ukstayhub-production.up.railway.app/api';

  /// Local backend port. Not 5000: macOS AirPlay Receiver holds that port.
  static const int _localApiPort = 5001;

  /// The API root: API_BASE_URL if given, else the local backend in debug and
  /// production in release (see [_localApi]). Locally the Android emulator reaches the host Mac at
  /// 10.0.2.2 (its own `localhost` is the emulator); iOS Simulator, desktop and
  /// web share the Mac's network, so `localhost` works there.
  static String get apiBaseUrl {
    if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
    if (!_localApi) return productionApiUrl;
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
