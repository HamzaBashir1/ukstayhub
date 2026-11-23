import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The UK Stay Hub mark – a soft-cornered house with a chimney whose doorway
/// is a map pin (cut out), with a gold dot in the pin, the "hub" – as vector
/// paths, so it can be drawn stroke-by-stroke and then filled for the launch
/// animation. Same geometry as tool/brand/make_icons.py, which renders the app
/// icons and PNG logos.
///
/// Geometry lives in a 500×500 design box and is built once, then scaled.
class StayHubMarkPaths {
  StayHubMarkPaths._();

  static const designSize = 500.0;
  static const teal = Color(0xFF01A48F);
  static const deep = Color(0xFF077B68);
  static const gold = Color(0xFFDFBA73);

  static const _pinC = Offset(250, 318);
  static const _pinR = 84.0;
  static const _pinTip = Offset(250, 440);

  /// Whole silhouette: the house with the pin-shaped doorway punched out.
  static final Path full = Path.combine(PathOperation.difference, _house(), _pin());

  /// The gold hub dot inside the pin.
  static final Path dot = Path()..addOval(Rect.fromCircle(center: _pinC, radius: 33));

  /// Outline contours with their lengths, measured once.
  static final List<ui.PathMetric> outline = full.computeMetrics().toList(growable: false);
  static final double outlineLength = outline.fold(0.0, (s, m) => s + m.length);

  static Path _house() {
    const k = (214 - 34) / (446 - 250); // roof slope
    const pts = [
      Offset(250, 34),
      Offset(338, 34 + k * 88), Offset(338, 66), Offset(380, 66), Offset(380, 34 + k * 130), // chimney
      Offset(446, 214), Offset(446, 470), Offset(54, 470), Offset(54, 214),
    ];
    const radii = [44.0, 6.0, 6.0, 6.0, 6.0, 38.0, 40.0, 40.0, 38.0];
    Offset toward(Offset a, Offset b, double d) => a + (b - a) / (b - a).distance * d;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final p0 = pts[(i - 1 + pts.length) % pts.length], p1 = pts[i], p2 = pts[(i + 1) % pts.length];
      final a = toward(p1, p0, radii[i]), b = toward(p1, p2, radii[i]);
      i == 0 ? path.moveTo(a.dx, a.dy) : path.lineTo(a.dx, a.dy);
      path.quadraticBezierTo(p1.dx, p1.dy, b.dx, b.dy);
    }
    return path..close();
  }

  static Path _pin() {
    // Tangent points from the tip to the circle.
    final th = math.acos(_pinR / (_pinTip.dy - _pinC.dy));
    final dx = _pinR * math.sin(th), dy = _pinR * math.cos(th);
    return Path.combine(
      PathOperation.union,
      Path()..addOval(Rect.fromCircle(center: _pinC, radius: _pinR)),
      Path()
        ..moveTo(_pinC.dx - dx, _pinC.dy + dy)
        ..lineTo(_pinC.dx + dx, _pinC.dy + dy)
        ..lineTo(_pinTip.dx, _pinTip.dy)
        ..close(),
    );
  }
}

/// A static brand mark at any size (no animation).
class StayHubMark extends StatelessWidget {
  const StayHubMark({super.key, this.size = 32, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: StayHubMarkPainter(trace: 0, fill: 1, color: color),
      );
}

/// Mark + "UK Stay Hub" logotype. [onDark] draws it in white for green panels.
class StayHubLogo extends StatelessWidget {
  const StayHubLogo({super.key, this.height = 32, this.onDark = false});
  final double height;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final style = AppText.inter(size: height * 0.6, weight: FontWeight.w800, letterSpacing: -0.02 * height, height: 1);
    return Semantics(
      label: 'UK Stay Hub',
      child: ExcludeSemantics(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          StayHubMark(size: height, color: onDark ? Colors.white : null),
          SizedBox(width: height * 0.16),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: 'UK ', style: style.copyWith(color: onDark ? Colors.white : StayHubMarkPaths.deep)),
              TextSpan(text: 'Stay Hub', style: style.copyWith(color: onDark ? Colors.white : StayHubMarkPaths.teal)),
            ]),
            maxLines: 1,
            softWrap: false,
          ),
        ]),
      ),
    );
  }
}

/// Paints the mark at any stage of the animation.
///
/// * [trace] 0→1 draws the outline along its length.
/// * [fill] 0→1 fades the fill in.
/// * [strokeOpacity] lets the outline fade once the fill has landed.
class StayHubMarkPainter extends CustomPainter {
  StayHubMarkPainter({
    required this.trace,
    required this.fill,
    this.strokeOpacity = 1,
    this.strokeColor = StayHubMarkPaths.deep,
    this.color,
  });

  final Color? color;

  final double trace;
  final double fill;
  final double strokeOpacity;
  final Color strokeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / StayHubMarkPaths.designSize;
    canvas.save();
    canvas.translate((size.width - StayHubMarkPaths.designSize * s) / 2, (size.height - StayHubMarkPaths.designSize * s) / 2);
    canvas.scale(s);

    if (fill > 0) {
      final a = fill.clamp(0.0, 1.0);
      canvas.drawPath(StayHubMarkPaths.full, Paint()..color = (color ?? StayHubMarkPaths.teal).withValues(alpha: a));
      canvas.drawPath(StayHubMarkPaths.dot, Paint()..color = StayHubMarkPaths.gold.withValues(alpha: a));
    }

    if (trace > 0 && strokeOpacity > 0) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = strokeColor.withValues(alpha: strokeOpacity.clamp(0.0, 1.0));
      // Every contour is traced at the same time, each to the same fraction,
      // so the outer edge and the hole close together.
      final t = trace.clamp(0.0, 1.0);
      for (final m in StayHubMarkPaths.outline) {
        canvas.drawPath(m.extractPath(0, m.length * t), stroke);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(StayHubMarkPainter old) =>
      old.trace != trace || old.fill != fill || old.strokeOpacity != strokeOpacity || old.strokeColor != strokeColor || old.color != color;
}

/// Self-running animated logo: trace → fill → little pop.
///
/// Use it anywhere the logo appears (e.g. a pull-to-refresh header or an empty
/// state). Call [AnimatedStayHubMarkState.replay] through a GlobalKey to run it
/// again, or set [playOnTap] to replay on tap.
class AnimatedStayHubMark extends StatefulWidget {
  const AnimatedStayHubMark({
    super.key,
    this.size = 96,
    this.duration = const Duration(milliseconds: 1300),
    this.autoplay = true,
    this.playOnTap = false,
    this.onCompleted,
  });

  final double size;
  final Duration duration;
  final bool autoplay;
  final bool playOnTap;
  final VoidCallback? onCompleted;

  @override
  State<AnimatedStayHubMark> createState() => AnimatedStayHubMarkState();
}

class AnimatedStayHubMarkState extends State<AnimatedStayHubMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);

  // Timeline (fractions of [duration]):
  //  0.00–0.55 trace the outline
  //  0.42–0.72 fill fades in
  //  0.60–0.80 outline fades out
  //  0.62–1.00 pop: 1.0 → 1.08 → 1.0
  late final Animation<double> _trace = CurvedAnimation(parent: _c, curve: const Interval(0, .55, curve: Curves.easeInOutCubic));
  late final Animation<double> _fill = CurvedAnimation(parent: _c, curve: const Interval(.42, .72, curve: Curves.easeOut));
  late final Animation<double> _strokeOut = CurvedAnimation(parent: _c, curve: const Interval(.6, .8, curve: Curves.easeIn));
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: .92, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 62),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.08).chain(CurveTween(curve: Curves.easeOut)), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0).chain(CurveTween(curve: Curves.easeInOutBack)), weight: 22),
  ]).animate(_c);

  bool get _reduceMotion => WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onCompleted?.call();
    });
    if (widget.autoplay) replay();
  }

  /// Runs the animation from the start (jumps to the end with reduced motion).
  void replay() {
    if (_reduceMotion) {
      _c.value = 1;
      widget.onCompleted?.call();
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget mark = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Transform.scale(
          scale: _scale.value,
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: StayHubMarkPainter(trace: _trace.value, fill: _fill.value, strokeOpacity: 1 - _strokeOut.value),
          ),
        ),
      ),
    );
    if (widget.playOnTap) {
      mark = GestureDetector(behavior: HitTestBehavior.opaque, onTap: replay, child: mark);
    }
    return Semantics(label: 'UK Stay Hub', image: true, child: mark);
  }
}
