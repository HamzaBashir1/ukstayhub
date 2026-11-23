import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/config.dart';
import 'core/i18n.dart';
import 'core/storage.dart';
import 'core/theme.dart';
import 'features/splash/boot_splash.dart';
import 'router.dart';
import 'state/auth.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.assertSecureTransport();
  GoogleFonts.config.allowRuntimeFetching = true;

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  final container = ProviderContainer();

  // The first frame is the animated logo, not a blank window: startup work runs
  // while the logo draws itself, and the app is built underneath it.
  runApp(UncontrolledProviderScope(
    container: container,
    child: BootSplash(
      boot: _boot(container),
      appBuilder: (_) => const StayHubApp(),
    ),
  ));
}

/// Everything the first app frame needs, all in parallel (the session restore
/// used to wait for the others to finish first).
Future<void> _boot(ProviderContainer container) async {
  await Future.wait([
    Prefs.init(),
    Strings.load(),
    initializeDateFormatting('en_GB'),
    initializeDateFormatting('en'),
    container.read(authProvider.notifier).restore(),
  ]);
  // Warm the destination catalog (like the website's loadDestinationCatalog on
  // mount) so the first letter typed in search already shows suggestions.
  container.read(destinationsProvider);
  container.read(tourismRegionsProvider);
}

class StayHubApp extends ConsumerWidget {
  const StayHubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'UK Stay Hub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: router,
      locale: const Locale('en', 'GB'),
      supportedLocales: const [Locale('en', 'GB')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        // Respect accessibility text size, but cap it so layouts hold.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: 0.9, maxScaleFactor: 1.3)),
          child: child!,
        );
      },
    );
  }
}
