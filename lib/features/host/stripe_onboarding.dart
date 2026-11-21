import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a Stripe Connect onboarding (Account Link) URL and brings the host
/// back to the app's own `/host/onboard/success` page afterwards.
///
/// The backend's Stripe `return_url` / `refresh_url` point at the website
/// (CLIENT_SITE_URL), so on their own they would leave the host on ukstayhub.co.uk.
/// Stripe does not support its hosted onboarding inside embedded WebViews, so
/// instead of intercepting it in a WebView we open it in the system in-app
/// browser (Chrome Custom Tabs / SFSafariViewController; a new tab on web) and,
/// as soon as the host comes back to the app, show the success page. That page
/// verifies the account with Stripe itself, so it is correct whether the host
/// finished, still has steps left, or gave up half-way.
Future<void> openStripeOnboarding(BuildContext context, String url, {String? returnTo}) async {
  final router = GoRouter.of(context);
  final target = Uri(
    path: '/host/onboard/success',
    queryParameters: (returnTo != null && returnTo.startsWith('/')) ? {'returnTo': returnTo} : null,
  ).toString();

  final opened = await launchUrl(
    Uri.parse(url),
    mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.inAppBrowserView,
    webOnlyWindowName: '_blank',
  );
  if (!opened) return;

  var left = false;
  late final AppLifecycleListener listener;
  listener = AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.inactive || state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
        left = true;
      } else if (state == AppLifecycleState.resumed && left) {
        listener.dispose();
        router.go(target);
      }
    },
  );
}
