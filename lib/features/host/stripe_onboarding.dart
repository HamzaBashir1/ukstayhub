import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

/// Callback scheme the backend's /app-return/host/onboard/* page redirects to
/// (`ukstayhub://stripe-return/host/onboard/<success|refresh>?…`).
const _callbackScheme = 'ukstayhub';

/// Opens a Stripe Connect onboarding (Account Link) URL and brings the host
/// back to the app's own `/host/onboard/...` page afterwards.
///
/// On iOS / Android it runs in a system auth session (ASWebAuthenticationSession
/// / Chrome Custom Tab, via flutter_web_auth_2). For the app the backend sets
/// Stripe's return_url to its /app-return/host/onboard/* page, which redirects
/// to ukstayhub://stripe-return/…; the session catches that, CLOSES THE BROWSER
/// ITSELF and hands us the URL – no "Open in app?" prompt, nothing to tap.
///
/// If the host closes the browser instead, they land on the success page
/// anyway: it verifies the account with Stripe itself, so it is correct
/// whether the host finished, still has steps left, or gave up half-way.
Future<void> openStripeOnboarding(BuildContext context, String url, {String? returnTo}) async {
  final router = GoRouter.of(context);
  final safeReturn = (returnTo != null && returnTo.startsWith('/')) ? returnTo : null;
  final fallback = Uri(
    path: '/host/onboard/success',
    queryParameters: safeReturn != null ? {'returnTo': safeReturn} : null,
  ).toString();

  if (kIsWeb) {
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    return;
  }

  String target = fallback;
  try {
    final result = await FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: _callbackScheme,
      // Ephemeral: no shared Safari cookies are needed, and it skips iOS's
      // "UK Stay Hub wants to use stripe.com to sign in" alert.
      options: const FlutterWebAuth2Options(preferEphemeral: true),
    );
    target = _targetFor(Uri.parse(result), safeReturn) ?? fallback;
  } catch (_) {
    // Closed by the host (or the session failed): still show the result page,
    // which re-checks the account with Stripe.
  }
  router.go(target);
}

/// ukstayhub://stripe-return/host/onboard/success?account=…&returnTo=…
///   → /host/onboard/success?account=…&returnTo=…
String? _targetFor(Uri cb, String? returnTo) {
  final path = cb.path;
  if (path != '/host/onboard/success' && path != '/host/onboard/refresh') return null;
  final q = Map<String, String>.from(cb.queryParameters);
  if (returnTo != null) q.putIfAbsent('returnTo', () => returnTo);
  return Uri(path: path, queryParameters: q.isEmpty ? null : q).toString();
}

/// Closes a leftover in-app browser sheet if one is on screen (older flow).
void closeStripeSheet() {
  if (!kIsWeb) closeInAppWebView().catchError((_) {});
}
