import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/brand_logo_mark.dart';

/// Shows the animated UK Stay Hub mark straight away while [boot] runs in the
/// background, then cross-fades into [appBuilder]'s app.
///
/// Before, `main()` awaited prefs, translations, date formats and the session
/// restore *before* `runApp`, so the phone showed a blank white window for
/// that whole time. Now the first Flutter frame is the logo, the work runs in
/// parallel with the animation, and the app is built *under* the splash so its
/// first frame is already rendered when the splash fades away.
class BootSplash extends StatefulWidget {
  const BootSplash({super.key, required this.boot, required this.appBuilder});

  final Future<void> boot;
  final WidgetBuilder appBuilder;

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> with SingleTickerProviderStateMixin {
  static const _background = Color(0xFFFFFEF9); // AppColors.cream

  bool _booted = false;
  bool _logoDone = false;
  bool _showSplash = true;
  bool _slowBoot = false;
  Timer? _slowTimer;

  late final AnimationController _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final Animation<double> _fadeOut =
      Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(parent: _exit, curve: Curves.easeInCubic));
  late final Animation<double> _grow =
      Tween(begin: 1.0, end: 1.12).animate(CurvedAnimation(parent: _exit, curve: Curves.easeInCubic));

  @override
  void initState() {
    super.initState();
    widget.boot.catchError((Object e, StackTrace st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st, library: 'boot'));
    }).whenComplete(() {
      if (!mounted) return;
      setState(() => _booted = true);
      _maybeExit();
    });
  }

  void _onLogoDone() {
    _logoDone = true;
    // Only if loading takes noticeably longer than the animation, show a
    // quiet progress bar so the app never looks frozen.
    _slowTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && !_booted) setState(() => _slowBoot = true);
    });
    _maybeExit();
  }

  Future<void> _maybeExit() async {
    if (!_booted || !_logoDone || !_showSplash) return;
    _slowTimer?.cancel();
    // Give the app (already built underneath) one frame to settle.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _exit.forward();
    if (mounted) setState(() => _showSplash = false);
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final splash = ColoredBox(
      color: _background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedStayHubMark(size: 112, onCompleted: _onLogoDone),
            const SizedBox(height: 28),
            SizedBox(
              width: 72,
              height: 3,
              child: AnimatedOpacity(
                opacity: _slowBoot ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: const ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                  child: LinearProgressIndicator(
                    backgroundColor: Color(0xFFE9F3F0),
                    valueColor: AlwaysStoppedAnimation(StayHubMarkPaths.teal),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_booted) widget.appBuilder(context) else const ColoredBox(color: _background),
          if (_showSplash)
            // Splash fades out while the mark grows slightly, so it feels like
            // the logo "opens" into the app.
            // FadeTransition/ScaleTransition skip rebuilds and only repaint.
            // Swallow taps until the splash is gone, so nothing invisible gets pressed.
            AbsorbPointer(
              child: FadeTransition(
                opacity: _fadeOut,
                child: ScaleTransition(scale: _grow, child: splash),
              ),
            ),
        ],
      ),
    );
  }
}
