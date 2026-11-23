import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/i18n.dart';
import 'core/storage.dart';
import 'features/auth/auth_screens.dart';
import 'features/checkout/checkout_screen.dart';
import 'features/checkout/payment_result_screens.dart';
import 'features/guest/guest_account_screen.dart';
import 'features/home/home_screen.dart';
import 'features/host/host_account.dart';
import 'features/host/host_calendar.dart';
import 'features/host/host_listings.dart';
import 'features/host/host_messages.dart';
import 'features/host/host_onboard.dart';
import 'features/host/host_payouts.dart';
import 'features/host/host_profile.dart';
import 'features/host/host_reservations.dart';
import 'features/host/host_shell.dart';
import 'features/host/host_today.dart';
import 'features/info/info_screens.dart';
import 'features/listing/listing_screen.dart';
import 'features/misc/misc_screens.dart';
import 'features/search/search_screen.dart';
import 'state/auth.dart';

/// Lets go_router re-run its redirect whenever the session changes.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen<AuthState>(authProvider, (_, __) => notifyListeners());
  }
}

// ── Reopen where the user left off ──
// Android may close the app while it is in the background (low memory or the
// phone's battery saver). Opening it again from recent apps then starts it
// from scratch, which used to always land on the home page. The current page
// is saved on every navigation and used as the start page if the app is
// reopened within a few hours.
const _kLastLocation = 'lastLocation';
const _kLastLocationAt = 'lastLocationAt';
const _restoreWindow = Duration(hours: 6);

/// Pages that must not be reopened on their own: payment flows, one-off
/// result pages and the Stripe return pages.
bool _restorable(String location) {
  final path = Uri.parse(location).path;
  const never = ['/checkout', '/payment-success', '/payment-cancel', '/request-sent', '/host/onboard', '/login', '/registracia', '/reset-password', '/zabudnute-heslo', '/obnovit-heslo', '/overenie'];
  return path.isNotEmpty && path != '/' && !never.any((p) => path == p || path.startsWith('$p/'));
}

String _startLocation() {
  final saved = Prefs.getString(_kLastLocation);
  final at = int.tryParse(Prefs.getString(_kLastLocationAt) ?? '');
  if (saved == null || at == null || !_restorable(saved)) return '/';
  final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
  return age < _restoreWindow ? saved : '/';
}

/// Paths mirror the website's (original slugs included) so links shared from
/// ukstayhub.co.uk map one-to-one onto app screens.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: _startLocation(),
    refreshListenable: refresh,
    errorBuilder: (_, __) => const NotFoundScreen(),
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final path = state.uri.path;
      final wantsHost = path == '/host' || path.startsWith('/host/');
      final wantsGuest = path == '/guest';
      if ((wantsHost || wantsGuest) && !auth.loggedIn) {
        return '/login?redirect=${Uri.encodeComponent(state.uri.toString())}';
      }
      if (wantsHost && !auth.isHost) return '/guest';
      if (wantsGuest && auth.isHost) return '/host';
      if ((path == '/login' || path == '/registracia') && auth.loggedIn) {
        return auth.isHost ? '/host' : '/';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/mapa', builder: (_, __) => const SearchScreen()),
      GoRoute(path: '/listing-stay-map', redirect: (_, __) => '/mapa'),
      GoRoute(path: '/listings/:slug', builder: (_, s) => ListingScreen(slug: s.pathParameters['slug']!)),
      GoRoute(path: '/ubytovanie', builder: (_, __) => const RegionsScreen()),
      GoRoute(
        path: '/checkout',
        redirect: (_, s) => s.extra is BookingDraft ? null : '/mapa',
        builder: (_, s) => CheckoutScreen(draft: s.extra! as BookingDraft),
      ),
      GoRoute(
        path: '/payment-success',
        builder: (_, s) => PaymentSuccessScreen(
          sessionId: s.uri.queryParameters['session_id'] ?? '',
          reservationId: s.uri.queryParameters['reservationId'],
        ),
      ),
      GoRoute(path: '/payment-cancel', builder: (_, __) => const PaymentCancelScreen()),
      GoRoute(
        path: '/request-sent',
        builder: (_, s) => RequestSentScreen(reservationId: s.uri.queryParameters['reservationId'] ?? ''),
      ),
      GoRoute(path: '/login', builder: (_, s) => LoginScreen(redirect: s.uri.queryParameters['redirect'])),
      GoRoute(path: '/registracia', builder: (_, __) => const SignupScreen()),
      GoRoute(path: '/Signup', redirect: (_, __) => '/registracia'),
      GoRoute(path: '/zabudnute-heslo', builder: (_, __) => const ForgotPasswordScreen()),
      GoRoute(
        path: '/reset-password/:token',
        builder: (_, s) => ResetPasswordScreen(token: s.pathParameters['token']!, role: s.uri.queryParameters['role']),
      ),
      GoRoute(
        path: '/guest',
        builder: (_, s) => GuestAccountScreen(
          initialTab: s.uri.queryParameters['tab'] ?? 'profile',
          forcePasswordChange: s.uri.queryParameters['changePassword'] == '1',
        ),
      ),
      GoRoute(path: '/review/:id', builder: (_, s) => ReviewScreen(accommodationId: s.pathParameters['id']!)),
      GoRoute(path: '/host-detail/:id', builder: (_, s) => HostDetailScreen(hostId: s.pathParameters['id']!)),
      GoRoute(path: '/blog', builder: (_, __) => const BlogListScreen()),
      GoRoute(path: '/blog/:slug', builder: (_, s) => BlogDetailScreen(slug: s.pathParameters['slug']!)),
      GoRoute(path: '/o-nas', builder: (_, __) => const AboutScreen()),
      GoRoute(path: '/caste-otazky', builder: (_, __) => const FaqScreen()),
      GoRoute(path: '/kontakt', builder: (_, __) => const ContactScreen()),
      GoRoute(path: '/prirucka-hostitela', builder: (_, __) => const HostGuideScreen()),
      GoRoute(
        path: '/ochrana-osobnych-udajov',
        builder: (context, _) => Consumer(
          builder: (_, ref, __) => WebPageScreen(path: '/ochrana-osobnych-udajov', title: ref.watch(stringsProvider)('PrivacyPolicy', 'Ochrana osobných údajov')),
        ),
      ),
      GoRoute(
        path: '/obchodne-podmienky',
        builder: (context, _) => Consumer(
          builder: (_, ref, __) => WebPageScreen(path: '/obchodne-podmienky', title: ref.watch(stringsProvider)('TermCondition', 'Obchodné podmienky')),
        ),
      ),

      // Listing editor is full-screen (the site hides the workspace chrome).
      GoRoute(path: '/host/listings/new', redirect: (_, __) => '/host/listings'),
      // Stripe onboarding return pages (outside the workspace chrome, like the site's own layout).
      GoRoute(path: '/host/onboard/success', builder: (_, s) => HostOnboardSuccessScreen(returnTo: s.uri.queryParameters['returnTo'])),
      GoRoute(path: '/host/onboard/refresh', builder: (_, __) => const HostOnboardRefreshScreen()),

      ShellRoute(
        builder: (context, state, child) => HostShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/host', pageBuilder: (_, __) => const NoTransitionPage(child: HostTodayScreen())),
          GoRoute(path: '/host/listings', pageBuilder: (_, __) => const NoTransitionPage(child: HostListingsScreen())),
          GoRoute(path: '/host/listings/:id', pageBuilder: (_, s) => NoTransitionPage(key: ValueKey(s.pathParameters['id']), child: ListingEditorScreen(id: s.pathParameters['id']!, step: s.uri.queryParameters['step'], review: s.uri.queryParameters['review'] == '1'))),
          GoRoute(
            path: '/host/calendar',
            pageBuilder: (_, s) => NoTransitionPage(child: HostCalendarScreen(initialListingId: s.uri.queryParameters['property'])),
          ),
          GoRoute(
            path: '/host/reservations',
            pageBuilder: (_, s) => NoTransitionPage(child: HostReservationsScreen(stage: s.uri.queryParameters['stage'])),
          ),
          GoRoute(path: '/host/reservations/:id', builder: (_, s) => HostReservationDetailScreen(id: s.pathParameters['id']!)),
          GoRoute(path: '/host/messages', pageBuilder: (_, __) => const NoTransitionPage(child: HostMessagesScreen())),
          GoRoute(path: '/host/messages/:id', builder: (_, s) => HostConversationScreen(id: s.pathParameters['id']!)),
          GoRoute(path: '/host/profile', pageBuilder: (_, __) => const NoTransitionPage(child: HostProfileScreen())),
          GoRoute(path: '/host/payouts', pageBuilder: (_, __) => const NoTransitionPage(child: HostPayoutsScreen())),
          GoRoute(path: '/host/account', pageBuilder: (_, __) => const NoTransitionPage(child: HostAccountScreen())),
        ],
      ),
    ],
  );

  void remember() {
    final location = router.routerDelegate.currentConfiguration.uri.toString();
    if (location.isEmpty) return;
    Prefs.putString(_kLastLocation, location);
    Prefs.putString(_kLastLocationAt, '${DateTime.now().millisecondsSinceEpoch}');
  }

  router.routerDelegate.addListener(remember);
  ref.onDispose(() => router.routerDelegate.removeListener(remember));
  return router;
});
