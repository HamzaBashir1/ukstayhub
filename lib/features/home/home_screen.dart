import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../../widgets/chrome.dart';
import '../../widgets/common.dart';
import '../../widgets/search_form.dart';
import '../../widgets/stay_card.dart';

/// app/page.js – the home page, section for section, at every width the site
/// supports (Tailwind sm 640 / md 768 / lg 1024 / xl 1280).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scroll = ScrollController();
  final _formKey = GlobalKey();
  bool _formHidden = false;
  bool _footerNear = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    final box = _formKey.currentContext?.findRenderObject() as RenderBox?;
    var visible = true;
    if (box != null && box.attached) {
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      visible = bottom > (context.lg ? 72 : 60);
    }
    final footerNear = _scroll.position.extentAfter < 220;
    if (visible == _formHidden || footerNear != _footerNear) {
      setState(() {
        _formHidden = !visible;
        _footerNear = footerNear;
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(recommendedProvider);
    ref.invalidate(latestProvider);
    ref.invalidate(destinationsProvider);
    ref.invalidate(listingStatsProvider);
    await ref.read(recommendedProvider.future).catchError((_) => <Listing>[]);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final lg = context.lg;
    // StickySearchMobile is lg:hidden; on desktop the header grows a search bar instead.
    final showSticky = !lg && _formHidden && !_footerNear;
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: StayHubHeader(logo: true, compactSearch: lg && _formHidden),
      endDrawer: const StayHubDrawer(),
      body: Stack(children: [
        RefreshIndicator(
          color: AppColors.green,
          onRefresh: _refresh,
          child: CustomScrollView(
            controller: _scroll,
            cacheExtent: 800,
            slivers: [
              SliverToBoxAdapter(child: _Hero(formKey: _formKey)),
              const SliverToBoxAdapter(child: _SavingsStrip()),
              const SliverToBoxAdapter(child: _PainPoints()),
              const SliverToBoxAdapter(child: _Destinations()),
              const SliverToBoxAdapter(child: _Benefits()),
              SliverToBoxAdapter(
                child: _ListingGrid(
                  provider: recommendedProvider,
                  title: t('RecommendedStay', 'Odporúčané ubytovania'),
                  buttonTopMd: 48,
                ),
              ),
              const SliverToBoxAdapter(child: _Testimonials()),
              const SliverToBoxAdapter(child: _HowItWorks()),
              SliverToBoxAdapter(
                child: _ListingGrid(
                  provider: latestProvider,
                  title: t('Otherbookings', 'Najnovšie ponuky'),
                  buttonTopMd: 56,
                ),
              ),
              const SliverToBoxAdapter(child: _PropertyBanner()),
              const SliverToBoxAdapter(child: _Faq()),
              const SliverToBoxAdapter(child: StayHubFooter()),
            ],
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          left: 0,
          right: 0,
          bottom: showSticky ? 24 + MediaQuery.of(context).padding.bottom : -80,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: showSticky ? 1 : 0,
            child: Center(child: StickySearchButton(onTap: () => openSearchSheet(context, ref))),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────────── Shared layout helpers ─────────────────────────────

/// `py-12 md:py-16 lg:py-20`, the vertical padding of almost every section.
double _py(BuildContext c) => c.lg ? 80 : (c.md ? 64 : 48);

/// `text-3xl md:text-4xl lg:text-5xl font-bold font-fraunces text-[#1A3A2E]`.
TextStyle _h2(BuildContext c, {bool tight = false}) {
  final size = c.lg ? 48.0 : (c.md ? 36.0 : 30.0);
  final height = tight ? 1.25 : (c.lg ? 1.0 : (c.md ? 40 / 36 : 36 / 30));
  return AppText.fraunces(size: size, height: height);
}

/// `text-[#64748B] font-inter text-lg`.
TextStyle get _lead => AppText.inter(size: 18, color: AppColors.slate, height: 28 / 18);

/// `container mx-auto px-4 max-w-*` (max-w-7xl by default).
class _Boxed extends StatelessWidget {
  const _Boxed({required this.child, this.maxWidth = 1280});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child),
        ),
      );
}

/// Centered section heading: title, 16px gap, lead text, inside max-w-2xl.
class _CenterHeader extends StatelessWidget {
  const _CenterHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 672),
          child: Column(children: [
            Text(title, textAlign: TextAlign.center, style: _h2(context)),
            const SizedBox(height: 16),
            Text(subtitle, textAlign: TextAlign.center, style: _lead),
          ]),
        ),
      );
}

/// A CSS grid: `cols` equal columns, rows of the given children.
class _Grid extends StatelessWidget {
  const _Grid({required this.cols, required this.gap, required this.children, this.stretch = false});
  final int cols;
  final double gap;
  final List<Widget> children;

  /// Every card in a row gets the height of the tallest one (`h-full`).
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += cols) {
      final cells = <Widget>[];
      for (var j = 0; j < cols; j++) {
        if (j > 0) cells.add(SizedBox(width: gap));
        cells.add(Expanded(child: i + j < children.length ? children[i + j] : const SizedBox.shrink()));
      }
      final row = Row(crossAxisAlignment: stretch ? CrossAxisAlignment.stretch : CrossAxisAlignment.start, children: cells);
      if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
      rows.add(stretch ? IntrinsicHeight(child: row) : row);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

// ───────────────────────────── Sticky search (mobile) ─────────────────────────────
class StickySearchButton extends ConsumerWidget {
  const StickySearchButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x73238869), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Material(
        color: AppColors.green,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.search, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Text(t('StickyCTA', 'Hľadaj overené ubytovanie →'),
                  style: AppText.inter(size: 14, weight: FontWeight.w600, color: Colors.white)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The bottom sheet the sticky button opens (search form + "Clear all").
Future<void> openSearchSheet(BuildContext context, WidgetRef ref) {
  final t = ref.read(stringsProvider);
  return showStayHubSheet(
    context,
    title: t('SearchAccommodation', 'Hľadaj ubytovanie'),
    action: TextButton(
      onPressed: () => ref.read(searchProvider.notifier).clearAll(),
      child: Text(t('Clearall', 'Vymazať všetko'),
          style: AppText.inter(size: 13, weight: FontWeight.w600, color: AppColors.neutral600, decoration: TextDecoration.underline)),
    ),
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: MobileSearchForm(card: false, onSearch: () => Navigator.of(ctx).pop()),
    ),
  );
}

// ───────────────────────────── Hero (HeroSection.js) ─────────────────────────────
class _Hero extends ConsumerWidget {
  const _Hero({required this.formKey});
  final GlobalKey formKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final sm = context.sm, md = context.md, lg = context.lg, xl = context.xl;
    final stats = ref.watch(listingStatsProvider).valueOrNull;
    final count = stats == null || stats['propertyCount'] == null
        ? t('Badge_DisplayCount', '441+')
        : '${asInt(stats['propertyCount'])}+';
    final verified = t('VerifiedStays', 'overených ubytovaní');

    // ── Headline + subtitle
    final h1 = xl ? 72.0 : (lg ? 60.0 : (sm ? 48.0 : 36.0));
    final h1Height = sm ? 1.0 : 1.08;
    final subtitle = t('Hero_Subtitle', '');
    final parts = subtitle.split(' · ');
    final subStyle = AppText.dmSans(
      size: lg ? 19 : (sm ? 18 : 15),
      weight: FontWeight.w600,
      color: AppColors.textDark,
      height: sm ? 28 / 18 : 1.625,
    );

    final copy = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(text: '${t('Hero_Accommodation', '')}\n'),
            TextSpan(
              text: t('Hero_WithinReach', ''),
              style: AppText.fraunces(
                  size: h1, color: AppColors.green, style: FontStyle.italic, height: h1Height, letterSpacing: -0.03 * h1),
            ),
          ]),
          style: AppText.fraunces(size: h1, color: AppColors.forestDark, height: h1Height, letterSpacing: -0.02 * h1),
        ),
        const SizedBox(height: 16),
        if (t.isEn)
          Text(subtitle, style: subStyle)
        else
          Text.rich(
            TextSpan(children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: Stack(clipBehavior: Clip.none, children: [
                  const Positioned(left: 0, right: 0, bottom: -6, height: 12, child: CustomPaint(painter: _SquigglePainter())),
                  Text(parts.first, style: subStyle),
                ]),
              ),
              if (parts.length > 1) TextSpan(text: ' · ${parts.skip(1).join(' · ')}'),
            ]),
            style: subStyle,
          ),
      ]),
    );

    // ── Trust elements: savings pill, then badges (sm+ only; the count badge lg+ only)
    final savings = Container(
      padding: EdgeInsets.symmetric(horizontal: sm ? 16 : 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.mintPill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.mintBorder),
        boxShadow: const [BoxShadow(color: Color(0x1A238869), blurRadius: 10, spreadRadius: -4, offset: Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.savings_outlined, size: 16, color: AppColors.green),
        const SizedBox(width: 10),
        Flexible(
          child: Text(t('Hero_SavingsLabel', 'Ušetríte priemerne £23 oproti iným platformám'),
              style: AppText.inter(
                  size: sm ? 14 : 12.5, weight: FontWeight.w600, color: AppColors.forestDark, height: sm ? 20 / 14 : 1.25)),
        ),
      ]),
    );
    final badges = [
      if (lg) _HeroBadge(lead: count, label: verified, strong: true),
      if (lg) const _HeroBadge(icon: Icons.paid_outlined, label: 'Online platba'),
      if (sm) _HeroBadge(icon: Icons.verified_outlined, label: t('Pill_VerifiedPhotos', 'Fotky overené naším tímom')),
      if (sm) _HeroBadge(icon: Icons.forum_outlined, label: t('Pill_HumanSupport', 'Podpora denne 8:00 – 18:00')),
    ];
    final trust = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      savings,
      // flex-col gap-2.5 on phones (the empty badge row still takes its gap);
      // on sm+ a zero-height line break (mb-0.5) between two gap-3 rows.
      SizedBox(height: sm ? 26 : 10),
      if (badges.isNotEmpty) Wrap(spacing: sm ? 10 : 8, runSpacing: sm ? 10 : 8, children: badges),
    ]);

    // ── Background photo + wash
    final background = [
      Positioned.fill(
        child: Image.asset(
          md ? 'assets/images/london-hero-wide.webp' : 'assets/images/london-hero-portrait.webp',
          fit: BoxFit.cover,
          alignment: lg ? Alignment.center : Alignment(0, md ? 0.04 : -0.04),
          cacheWidth: md ? 1920 : 900,
        ),
      ),
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: md
                ? const LinearGradient(
                    stops: [0, 0.42, 0.72, 1],
                    colors: [Color(0xF0F7FAF6), Color(0xCCF7FAF6), Color(0x42F7FAF6), Color(0x14112A22)],
                  )
                : const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, 0.38, 0.70, 1],
                    colors: [Color(0xE6F7FAF6), Color(0xADF7FAF6), Color(0x2EF7FAF6), Color(0x1A112A22)],
                  ),
          ),
        ),
      ),
    ];

    final hp = xl ? 48.0 : (lg ? 32.0 : (sm ? 24.0 : 16.0));

    // ── Desktop (lg+): copy + form in 7 of 12 columns, London postcard on the right.
    if (lg) {
      final gap = xl ? 48.0 : 32.0;
      return Stack(children: [
        ...background,
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1440),
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              final inner = w - 2 * hp;
              final left = (inner - 11 * gap) * 7 / 12 + 6 * gap;
              return SizedBox(width: w, child: Stack(children: [
                Positioned(
                  top: 40,
                  bottom: 96,
                  right: hp + (w >= 1536 ? 48.0 : (xl ? 16.0 : 0.0)),
                  width: w * (xl ? 0.34 : 0.32),
                  child: const Center(child: _LondonPostcard()),
                ),
                Padding(
                  // pt-20 minus the 52px of hero the fixed site header covers (main has lg:pt-5).
                  padding: EdgeInsets.fromLTRB(hp, 28, hp, 96),
                  child: SizedBox(
                    width: left,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        copy,
                        const SizedBox(height: 32),
                        trust,
                        SizedBox(height: 32 + (xl ? 24 : 16)),
                        Container(key: formKey, child: const DesktopSearchForm()),
                      ]),
                    ),
                  ),
                ),
              ]));
            }),
          ),
        ),
      ]);
    }

    // ── Phone / tablet: copy, London postcard, then the search form overlapping it.
    final statsFooter = Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: count, style: AppText.fraunces(size: sm ? 13 : 12, color: AppColors.green)),
          const TextSpan(text: ' '),
          TextSpan(text: verified, style: AppText.inter(size: sm ? 11 : 10, weight: FontWeight.w600, color: AppColors.forestDark)),
        ]),
        textAlign: TextAlign.center,
        maxLines: 1,
      ),
    );
    final form = md
        ? const DesktopSearchForm()
        : DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              boxShadow: const [BoxShadow(color: Color(0x33112A22), blurRadius: 60, spreadRadius: -15, offset: Offset(0, 24))],
            ),
            child: MobileSearchForm(footer: statsFooter),
          );

    // The postcard sits where the old mascot did; the form below overlaps it by 32px.
    final cardH = sm ? 340.0 : 280.0;
    final postcard = SizedBox(
      height: cardH - 32,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        maxHeight: cardH,
        child: Center(child: SizedBox(height: cardH, child: const _LondonPostcard())),
      ),
    );

    final column = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      copy,
      const SizedBox(height: 24),
      trust,
      const SizedBox(height: 32),
      if (sm) postcard else const SizedBox(height: 150),
      if (sm)
        Container(key: formKey, child: form)
      else
        // Phones: the form is pulled up by 51% of its height (-mb-[210px]);
        // this keeps the space the site leaves for it below the postcard.
        const SizedBox(height: 32 + 150),
    ]);

    return Stack(children: [
      ...background,
      ClipRect(
        child: Padding(
          padding: EdgeInsets.fromLTRB(hp, sm ? 48 : 16, hp, sm ? 64 : 0),
          child: column,
        ),
      ),
      if (!sm)
        Positioned(
          left: hp + 4,
          right: hp + 4,
          bottom: 13,
          child: Container(key: formKey, child: form),
        ),
    ]);
  }
}

/// A tilted London snapshot (Big Ben, phone box, red bus) beside the hero copy.
class _LondonPostcard extends StatelessWidget {
  const _LondonPostcard();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Transform.rotate(
        angle: 3 * math.pi / 180,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [BoxShadow(color: Color(0x33112A22), blurRadius: 40, spreadRadius: -8, offset: Offset(0, 20))],
          ),
          child: Stack(children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset('assets/images/london-postcard.webp', fit: BoxFit.cover, cacheWidth: 800, semanticLabel: 'London'),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.location_on_rounded, size: 16, color: AppColors.green),
                  const SizedBox(width: 4),
                  Text('London', style: AppText.inter(size: 13, weight: FontWeight.w700, color: AppColors.forestDark)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The hand-drawn double underline under the first subtitle phrase (SK only).
class _SquigglePainter extends CustomPainter {
  const _SquigglePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // viewBox 0 0 160 16, preserveAspectRatio="none" – strokes scale with the box.
    canvas.scale(size.width / 160, size.height / 16);
    Paint stroke(double w, double opacity) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = AppColors.green.withValues(alpha: opacity);
    canvas.drawPath(
      Path()
        ..moveTo(3, 9.5)
        ..cubicTo(18, 4.5, 33, 4, 48, 8.5)
        ..cubicTo(64, 13, 78, 13, 94, 7.5)
        ..cubicTo(111, 2, 127, 3, 157, 8),
      stroke(5.5, 0.78),
    );
    canvas.drawPath(
      Path()
        ..moveTo(7, 12)
        ..cubicTo(24, 8, 38, 8.5, 53, 11.5)
        ..cubicTo(69, 14.5, 84, 13.5, 99, 9)
        ..cubicTo(116, 4, 135, 5.5, 152, 10),
      stroke(2.25, 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.label, this.lead, this.icon, this.strong = false});
  final String label;
  final String? lead;
  final IconData? icon;
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: strong ? const Color(0xFFF0F7F4) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: strong ? AppColors.mintBorder : AppColors.fieldBorder),
          boxShadow: [
            BoxShadow(
                color: strong ? const Color(0x1F238869) : const Color(0x14112A22),
                blurRadius: 8,
                spreadRadius: -4,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (lead != null) ...[
            Text(lead!, style: AppText.fraunces(size: 14, color: AppColors.greenText, height: 1)),
            const SizedBox(width: 6),
          ],
          if (icon != null) ...[Icon(icon, size: 14, color: AppColors.green), const SizedBox(width: 6)],
          Text(label,
              style: AppText.dmSans(
                  size: 12.5,
                  weight: strong ? FontWeight.w700 : FontWeight.w600,
                  color: strong ? AppColors.forestDark : AppColors.mutedGreen,
                  height: 1)),
        ]),
      );
}

// ───────────────────────────── Savings comparison ─────────────────────────────
class _SavingsStrip extends ConsumerWidget {
  const _SavingsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final md = context.md, lg = context.lg;
    const base = 89, feeA = 18, feeB = 14;

    Widget row(String a, String b, Color color, {FontWeight w = FontWeight.w400}) => Row(children: [
          Expanded(child: Text(a, style: AppText.inter(size: 14, color: color, weight: w, height: 20 / 14))),
          Text(b, style: AppText.inter(size: 14, color: color, weight: w, height: 20 / 14)),
        ]);

    Widget body({required Widget head, required Color text, required String fee, required Color feeColor, required Color line,
            required Widget total}) =>
        Column(children: [
          head,
          const SizedBox(height: 16),
          row(t('Savings_Accommodation', 'Ubytovanie'), '£$base', text),
          const SizedBox(height: 8),
          row(t('Savings_Fee', 'Poplatky platformy'), fee, feeColor, w: FontWeight.w500),
          const SizedBox(height: 16),
          Container(height: 1, color: line),
          const SizedBox(height: 16),
          total,
        ]);

    Widget other(String name, int fee) => Container(
          width: double.infinity,
          padding: EdgeInsets.all(lg ? 32 : 24),
          decoration: BoxDecoration(
            color: const Color(0x80F9FAFB),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF3F4F6)),
          ),
          child: body(
            head: Text(name.toUpperCase(),
                textAlign: TextAlign.center,
                style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFF6B7280), letterSpacing: 0.7)),
            text: const Color(0xFF4B5563),
            fee: '+ £$fee',
            feeColor: AppColors.red,
            line: const Color(0xFFE5E7EB),
            total: Row(children: [
              Expanded(
                  child: Text(t('Savings_Total', 'Spolu'),
                      style: AppText.inter(size: 16, weight: FontWeight.w500, color: const Color(0xFF1F2937)))),
              Text('£${base + fee}', style: AppText.fraunces(size: 24, color: const Color(0xFF1F2937), height: 32 / 24)),
            ]),
          ),
        );

    Widget ours = Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(lg ? 40 : 32),
        decoration: BoxDecoration(
          color: AppColors.mint,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.green, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x1A238869), blurRadius: 15, spreadRadius: -3, offset: Offset(0, 10))],
        ),
        child: body(
          head: Text('UK Stay Hub', style: AppText.fraunces(size: 20, color: AppColors.green, height: 28 / 20)),
          text: const Color(0xFF374151),
          fee: '+ £0',
          feeColor: AppColors.greenText,
          line: const Color(0x33238869),
          total: Row(children: [
            Expanded(child: Text(t('Savings_Total', 'Spolu'), style: AppText.inter(size: 16, weight: FontWeight.w500))),
            Text('£$base', style: AppText.fraunces(size: 30, color: AppColors.green, height: 36 / 30)),
          ]),
        ),
      ),
      Positioned(
        top: -16,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: AppColors.greenDeep, borderRadius: BorderRadius.circular(999)),
          child: Text('${t('Savings_Save', 'Ušetríte').toUpperCase()} £$feeA',
              style: AppText.inter(size: 12, weight: FontWeight.w700, color: Colors.white, letterSpacing: 0.6, height: 16 / 12)),
        ),
      ),
    ]);
    if (md) ours = Transform.scale(scale: 1.05, child: ours);

    final a = other(t('Savings_PlatformA', 'Iné platformy'), feeA);
    final b = other(t('Savings_PlatformB', 'Prenájom online'), feeB);
    final gap = lg ? 32.0 : 24.0;

    return Container(
      color: Colors.white,
      padding: EdgeInsets.symmetric(vertical: _py(context)),
      child: _Boxed(
        maxWidth: 1024,
        child: Column(children: [
          Text(t('Savings_Title', 'Rovnaké ubytovanie. Lepšia cena.'),
              textAlign: TextAlign.center,
              style: AppText.fraunces(size: md ? 36 : 30, height: md ? 40 / 36 : 36 / 30)),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 672),
            child: Text(t('Savings_Subtitle', 'Neplatíte skryté poplatky. Ušetrené peniaze môžete minúť na zážitky.'),
                textAlign: TextAlign.center,
                style: AppText.inter(size: md ? 18 : 16, color: AppColors.slate, height: md ? 28 / 18 : 1.5)),
          ),
          SizedBox(height: md ? 40 : 32),
          if (md)
            Row(children: [
              Expanded(child: a),
              SizedBox(width: gap),
              Expanded(child: ours),
              SizedBox(width: gap),
              Expanded(child: b),
            ])
          else ...[
            a,
            SizedBox(height: gap),
            ours,
            SizedBox(height: gap),
            b,
          ],
        ]),
      ),
    );
  }
}

// ───────────────────────────── Pain points ─────────────────────────────
class _PainPoints extends ConsumerWidget {
  const _PainPoints();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final sm = context.sm, md = context.md, lg = context.lg;
    final items = [
      (Icons.photo_camera_outlined, t('PainPoint_1', 'Žiadne skryté poplatky')),
      (Icons.toll_outlined, t('PainPoint_2', 'Overení hostitelia')),
      (Icons.forum_outlined, t('PainPoint_3', 'Priama komunikácia')),
    ];

    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      Text(t('PainPoint_Resolution', 'Prečo práve my?'), style: AppText.fraunces(size: lg ? 24 : 20, color: AppColors.green)),
      if (md) ...[const SizedBox(width: 12), Container(width: 64, height: 1, color: const Color(0x4D238869))],
    ]);

    Widget item((IconData, String) e) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: AppColors.mint, shape: BoxShape.circle),
            child: Icon(e.$1, size: 20, color: AppColors.green),
          ),
          const SizedBox(width: 12),
          Flexible(child: Text(e.$2, style: AppText.inter(size: lg ? 16 : 14, weight: FontWeight.w500))),
        ]);

    final gap = lg ? 40.0 : 24.0;
    final list = sm
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Flexible(child: item(items[i])),
            ],
          ])
        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 24),
              item(items[i]),
            ],
          ]);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cream,
        border: Border.symmetric(horizontal: BorderSide(color: AppColors.neutral100)),
      ),
      padding: EdgeInsets.symmetric(vertical: md ? 48 : 40),
      child: _Boxed(
        maxWidth: 1024,
        child: md
            ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                title,
                const SizedBox(width: 16),
                Flexible(child: list),
              ])
            : Column(children: [title, const SizedBox(height: 32), list]),
      ),
    );
  }
}

// ───────────────────────────── Destinations (GridCategoryBox.js) ─────────────────────────────
class _Destinations extends ConsumerStatefulWidget {
  const _Destinations();
  @override
  ConsumerState<_Destinations> createState() => _DestinationsState();
}

class _DestinationsState extends ConsumerState<_Destinations> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _step(int dir, double by) {
    if (!_ctrl.hasClients) return;
    final p = _ctrl.position;
    _ctrl.animateTo((p.pixels + dir * by).clamp(0, p.maxScrollExtent),
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  void _viewAll() {
    ref.read(searchProvider.notifier).setDestination(null);
    context.push('/ubytovanie');
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final regions = ref.watch(regionCardsProvider);
    final vw = context.vw, sm = context.sm, md = context.md;

    // Swiper breakpoints: slidesPerView / spaceBetween.
    final (perView, gap) = vw >= 1024 ? (4.0, 24.0) : (vw >= 768 ? (2.45, 20.0) : (vw >= 480 ? (2.08, 16.0) : (1.12, 16.0)));
    final inner = math.min(vw, 1280) - 32;
    final cardW = (inner - (perView - 1) * gap) / perView;
    final cardH = cardW * 10 / 16;

    Widget strip(int count, Widget Function(int) build) => SizedBox(
          height: cardH,
          child: ListView.separated(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            itemCount: count,
            separatorBuilder: (_, __) => SizedBox(width: gap),
            itemBuilder: (_, i) => SizedBox(width: cardW, child: build(i)),
          ),
        );

    Widget notice(String text) => Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 144),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          decoration: BoxDecoration(color: const Color(0xFFF3F7F5), borderRadius: BorderRadius.circular(20)),
          child: Text(text, textAlign: TextAlign.center, style: AppText.inter(size: 16, color: AppColors.mutedGreen)),
        );

    final Widget body;
    if (regions.isLoading) {
      body = strip(4, (_) => const Shimmer(radius: 20));
    } else if (regions.hasError) {
      // Re-fetch the catalog; regionCardsProvider rebuilds from it.
      body = InlineErrorBox(error: regions.error!, onRetry: () => ref.invalidate(destinationsProvider));
    } else {
      final list = regions.value ?? const <Region>[];
      body = list.isEmpty
          ? notice(t('PopularDestinations_Empty', 'Momentálne nie sú dostupné žiadne destinácie.'))
          : strip(list.length, (i) => RegionCard(region: list[i]));
    }

    Widget navBtn(IconData icon, int dir) => SizedBox(
          width: 48,
          height: 48,
          child: OutlinedButton(
            onPressed: () => _step(dir, cardW + gap),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
              side: const BorderSide(color: AppColors.neutral200),
              foregroundColor: AppColors.neutral600,
            ),
            child: Icon(icon, size: 20),
          ),
        );

    final heading = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 672),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('PopularDestinations_Title', 'Obľúbené destinácie'), style: _h2(context, tight: true)),
        const SizedBox(height: 12),
        Text(t('PopularDestinations_Subtitle', 'Objavte miesta s aktuálne dostupnými pobytmi.'),
            style: AppText.inter(size: 16, color: AppColors.muted, height: 1.5)),
      ]),
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: _py(context)),
      child: _Boxed(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (sm)
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: Align(alignment: Alignment.centerLeft, child: heading)),
              SizedBox(width: md ? 24 : 20),
              LinkText(t('Viewall', 'Zobraziť všetky'), onTap: _viewAll, arrow: true, size: 16),
              const SizedBox(width: 16),
              navBtn(Icons.chevron_left, -1),
              const SizedBox(width: 8),
              navBtn(Icons.chevron_right, 1),
            ])
          else
            heading,
          SizedBox(height: md ? 40 : 32),
          body,
          if (!sm) ...[
            const SizedBox(height: 24),
            OutlineBtn(label: t('Viewall', 'Zobraziť všetky'), height: 48, onPressed: _viewAll),
          ],
        ]),
      ),
    );
  }
}

/// CardCategorySlider.js
class RegionCard extends ConsumerWidget {
  const RegionCard({super.key, required this.region});
  final Region region;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final lg = context.lg;
    final asset = destinationAsset(region.id);
    return GestureDetector(
      onTap: () {
        ref.read(searchProvider.notifier).setDestination(Destination.region(region.name(t.lang), region.cities, region.id));
        context.push('/mapa');
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(fit: StackFit.expand, children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.forest, AppColors.green, Color(0xFF8BC9B5)],
              ),
            ),
          ),
          if (asset != null) Image.asset(asset, fit: BoxFit.cover, cacheWidth: 700),
          const Opacity(
            opacity: 0.9,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xD9000000), Color(0x40000000), Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned(
            left: lg ? 24 : 20,
            right: lg ? 24 : 20,
            bottom: lg ? 24 : 20,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(region.name(t.lang),
                  style: AppText.fraunces(size: lg ? 24 : 20, color: Colors.white)
                      .copyWith(shadows: const [Shadow(color: Color(0x66000000), blurRadius: 6)])),
              SizedBox(height: lg ? 6 : 4),
              Text(
                region.count > 0
                    ? '${region.count} ${t('properties', 'ubytovaní')}'.toUpperCase()
                    : t('properties', 'ubytovania').toUpperCase(),
                style: AppText.inter(
                    size: lg ? 14 : 12, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.9), letterSpacing: 0.4),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────────── Benefits ─────────────────────────────
class _Benefits extends ConsumerWidget {
  const _Benefits();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final md = context.md, lg = context.lg;
    final items = [
      (Icons.bolt_outlined, t('Benefits_1_Title', 'Rýchla rezervácia'), t('Benefits_1_Desc', 'Zarezervujte si pobyt behom pár minút.')),
      (Icons.check_circle_outline, t('Benefits_2_Title', 'Overení hostitelia'), t('Benefits_2_Desc', 'Všetky ubytovania prechádzajú našou kontrolou.')),
      (Icons.monetization_on_outlined, t('Benefits_3_Title', 'Bezpečné platby'), t('Benefits_3_Desc', 'Vaše platby sú u nás v bezpečí.')),
      (Icons.favorite_border, t('Benefits_4_Title', 'Lokálna podpora'), t('Benefits_4_Desc', 'Sme tu pre vás každý deň.')),
    ];
    final cards = [
      for (final (icon, title, desc) in items)
        Column(children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: AppColors.mint, borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, size: 24, color: AppColors.green),
          ),
          const SizedBox(height: 24),
          Text(title, textAlign: TextAlign.center, style: AppText.fraunces(size: 20, height: 28 / 20)),
          const SizedBox(height: 12),
          Text(desc,
              textAlign: TextAlign.center, style: AppText.inter(size: md ? 16 : 14, color: AppColors.slate, height: 1.625)),
        ]),
    ];

    // The page wraps BenefitsSection in its own white band (py-8 lg:py-14 px-4 lg:px-5).
    return Container(
      color: Colors.white,
      padding: EdgeInsets.symmetric(vertical: (lg ? 56 : 32) + _py(context), horizontal: lg ? 20 : 16),
      child: _Boxed(
        child: Column(children: [
          _CenterHeader(
            title: t('Benefits_Title', 'Prečo si vybrať UK Stay Hub?'),
            subtitle: t('Benefits_Subtitle', 'Snažíme sa robiť veci lepšie a s ohľadom na vás.'),
          ),
          SizedBox(height: md ? 48 : 40),
          _Grid(cols: lg ? 4 : (md ? 2 : 1), gap: lg ? 40 : 32, children: cards),
        ]),
      ),
    );
  }
}

// ───────────────────────────── Listing grids (GridFeaturePlaces / GridFeatureBooking) ─────────────────────────────
class _ListingGrid extends ConsumerWidget {
  const _ListingGrid({required this.provider, required this.title, required this.buttonTopMd});
  final FutureProvider<List<Listing>> provider;
  final String title;
  final double buttonTopMd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final sm = context.sm, md = context.md, lg = context.lg;
    final data = ref.watch(provider);
    final items = data.valueOrNull?.take(6).toList() ?? const <Listing>[];
    final loading = data.isLoading && items.isEmpty;
    final cols = lg ? 3 : (sm ? 2 : 1);
    final gap = md ? 32.0 : 24.0;

    final Widget grid;
    if (loading) {
      grid = _Grid(cols: cols, gap: gap, children: List.generate(6, (_) => const StayCardSkeleton()));
    } else if (items.isEmpty && data.hasError) {
      // Offline or server error: say so and let the user retry, instead of
      // claiming there are no stays.
      grid = InlineErrorBox(error: data.error!, onRetry: () => ref.invalidate(provider), minHeight: 200);
    } else if (items.isEmpty) {
      grid = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 64),
        decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
        child: Text(t('Noaccommodationfound', 'Nenašli sa žiadne ubytovania'),
            textAlign: TextAlign.center, style: AppText.inter(size: 18, color: AppColors.neutral500)),
      );
    } else {
      grid = _Grid(cols: cols, gap: gap, children: [for (final l in items) StayCard(listing: l)]);
    }

    final heading = Text(title, style: _h2(context, tight: true));

    return Padding(
      padding: EdgeInsets.symmetric(vertical: _py(context)),
      child: _Boxed(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (sm)
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: heading),
              const SizedBox(width: 24),
              LinkText(t('Viewall', 'Zobraziť všetky'), onTap: () => context.push('/mapa'), arrow: true, size: 16),
            ])
          else
            heading,
          SizedBox(height: md ? 40 : 32),
          grid,
          if (items.isNotEmpty) ...[
            SizedBox(height: md ? buttonTopMd : 40),
            Center(
              child: PrimaryButton(
                label: t('ShowAllListing', 'Zobraziť všetky ubytovania'),
                color: AppColors.greenDeep,
                height: 56,
                expand: !sm,
                onPressed: () => context.push('/mapa'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ───────────────────────────── Testimonials ─────────────────────────────
class _Testimonials extends ConsumerWidget {
  const _Testimonials();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final md = context.md, lg = context.lg;
    const meta = [
      ('JM', Color(0xFFE2F0CB)),
      ('MK', Color(0xFFFFE5E5)),
      ('LS', Color(0xFFE5F2FF)),
      ('PD', Color(0xFFFFF0E5)),
    ];

    Widget stars() => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 5; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            const Icon(Icons.star_rounded, size: 20, color: AppColors.star),
          ],
        ]);

    Widget card(int i) {
      final n = i + 1;
      final (ini, color) = meta[i];
      return Container(
        padding: EdgeInsets.all(lg ? 32 : 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.neutral100),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          stars(),
          const SizedBox(height: 16),
          Expanded(
            child: Text('"${t('Testimonial${n}_Text', '')}"',
                style: AppText.inter(size: 16, color: AppColors.slateDark, height: 1.625)),
          ),
          const SizedBox(height: 24),
          Container(height: 1, color: AppColors.neutral100),
          const SizedBox(height: 16),
          Row(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text(ini, style: AppText.inter(size: 14, weight: FontWeight.w700)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('Testimonial${n}_Name', ''), style: AppText.inter(size: 16, weight: FontWeight.w700)),
                Text('${t('Testimonial${n}_Location', '')} · ${t('Testimonial${n}_Date', '')}',
                    style: AppText.inter(size: 14, color: AppColors.slate)),
              ]),
            ),
          ]),
        ]),
      );
    }

    final heading = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 672),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('Reviews_Heading', 'Čo hovoria naši hostia?'), style: _h2(context, tight: true)),
        const SizedBox(height: 16),
        Text(t('Reviews_Subheading', 'Prečítajte si reálne skúsenosti od ľudí, ktorí si zarezervovali pobyt cez UK Stay Hub.'),
            style: _lead),
      ]),
    );
    final aggregate = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.neutral100),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
      ),
      child: Column(
        crossAxisAlignment: md ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('4.9', style: AppText.fraunces(size: 24, height: 32 / 24)),
            const SizedBox(width: 8),
            const StarRow(value: 5, size: 20),
          ]),
          const SizedBox(height: 4),
          Text('${t('Reviews_BasedOn', 'Založené na viac ako')} ${t('Reviews_AggCount', '2 500+ hodnoteniach')}',
              style: AppText.inter(size: 14, color: AppColors.slate)),
        ],
      ),
    );

    return Container(
      color: AppColors.neutral50,
      padding: EdgeInsets.symmetric(vertical: _py(context)),
      child: Column(children: [
        _Boxed(
          child: md
              ? Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: heading)),
                  const SizedBox(width: 24),
                  aggregate,
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [heading, const SizedBox(height: 24), aggregate]),
        ),
        SizedBox(height: md ? 48 : 40),
        if (md)
          _Boxed(child: _Grid(cols: lg ? 4 : 2, gap: 24, stretch: true, children: List.generate(meta.length, card)))
        else
          // Phones: a sideways scroller of 85vw cards (-mx-4 px-4), equal heights.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < meta.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  SizedBox(width: context.vw * 0.85, child: card(i)),
                ],
              ]),
            ),
          ),
      ]),
    );
  }
}

// ───────────────────────────── How it works ─────────────────────────────
class _HowItWorks extends ConsumerWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final md = context.md, lg = context.lg;
    final items = [
      (Icons.favorite_border, t('HowItWorks_1_Title', 'Vyhľadajte si ubytovanie'), t('HowItWorks_1_Desc', '')),
      (Icons.calendar_today_outlined, t('HowItWorks_2_Title', 'Rezervujte a zaplaťte'), t('HowItWorks_2_Desc', '')),
      (Icons.check_circle_outline, t('HowItWorks_3_Title', 'Užite si pobyt'), t('HowItWorks_3_Desc', '')),
    ];
    final steps = [
      for (var i = 0; i < items.length; i++)
        Column(children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.forest, shape: BoxShape.circle),
            child: Text('${i + 1}', style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white)),
          ),
          const SizedBox(height: 16),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.green,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [BoxShadow(color: Color(0x33238869), blurRadius: 25, offset: Offset(0, 20), spreadRadius: -5)],
            ),
            child: Icon(items[i].$1, size: 28, color: Colors.white),
          ),
          const SizedBox(height: 24),
          Text(items[i].$2, textAlign: TextAlign.center, style: AppText.fraunces(size: 24, height: 32 / 24)),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 384),
            child: Text(items[i].$3,
                textAlign: TextAlign.center, style: AppText.inter(size: 16, color: AppColors.slate, height: 1.625)),
          ),
        ]),
    ];
    final gap = lg ? 48.0 : 32.0;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cream,
        border: Border(top: BorderSide(color: AppColors.neutral100)),
      ),
      padding: EdgeInsets.symmetric(vertical: _py(context)),
      child: _Boxed(
        child: Column(children: [
          _CenterHeader(
            title: t('HowItWorks_Title', 'Ako to funguje?'),
            subtitle: t('HowItWorks_Subtitle', 'Celý proces od hľadania až po samotný pobyt je s nami rýchly a jednoduchý.'),
          ),
          SizedBox(height: md ? 48 : 40),
          if (md)
            LayoutBuilder(
              builder: (_, c) => Stack(children: [
                // Connector line behind the icons.
                Positioned(
                  top: 88,
                  left: c.maxWidth * 0.15,
                  right: c.maxWidth * 0.15,
                  height: 2,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color(0x00238869), Color(0x33238869), Color(0x00238869)]),
                    ),
                  ),
                ),
                _Grid(cols: 3, gap: gap, children: steps),
              ]),
            )
          else
            _Grid(cols: 1, gap: gap, children: steps),
        ]),
      ),
    );
  }
}

// ───────────────────────────── List your property (PropertyBanner.js) ─────────────────────────────
class _PropertyBanner extends ConsumerWidget {
  const _PropertyBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    final sm = context.sm, md = context.md, lg = context.lg;

    Future<void> list() async {
      if (!auth.loggedIn) {
        toast(context, t('Pleaseloginasahosttolistyourproperty', 'Prihláste sa prosím ako hostiteľ.'), error: true);
        context.push('/login');
        return;
      }
      if (auth.isHost) {
        context.go('/host');
        return;
      }
      try {
        await ref.read(authProvider.notifier).switchMode('host', t.lang);
        if (context.mounted) context.go('/host');
      } catch (_) {
        if (context.mounted) {
          toast(context, t('OnlyhostscanlistpropertiesPleaseloginasahost', 'Iba hostitelia môžu pridávať ubytovania.'), error: true);
        }
      }
    }

    final primary = PrimaryButton(
      label: t('Banner_ListProperty', 'Pridať ubytovanie'),
      color: Colors.white,
      textColor: AppColors.forest,
      height: 56,
      expand: !sm,
      onPressed: list,
    );
    final secondary = SizedBox(
      width: sm ? null : double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: () => context.push('/o-nas'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Color(0x33FFFFFF), width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(t('Banner_LearnMore', 'Viac informácií'),
            style: AppText.inter(size: 16, weight: FontWeight.w600, color: Colors.white)),
      ),
    );

    final align = md ? CrossAxisAlignment.start : CrossAxisAlignment.center;
    final textAlign = md ? TextAlign.left : TextAlign.center;
    final content = Padding(
      padding: EdgeInsets.all(lg ? 64 : (md ? 48 : 32)),
      child: Column(crossAxisAlignment: align, children: [
        Text(t('Banner_Title', 'Máte vlastné ubytovanie?'),
            textAlign: textAlign, style: _h2(context, tight: true).copyWith(color: Colors.white)),
        SizedBox(height: lg ? 24 : 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 448),
          child: Text(
            t('Banner_Desc', 'Pridajte sa k nám, prenajímajte bezpečne a získajte nových hostí bez zbytočných starostí.'),
            textAlign: textAlign,
            style: AppText.inter(size: md ? 18 : 16, color: Colors.white.withValues(alpha: 0.8), height: md ? 28 / 18 : 1.5),
          ),
        ),
        const SizedBox(height: 32),
        if (sm)
          Row(mainAxisSize: MainAxisSize.min, children: [primary, const SizedBox(width: 16), secondary])
        else
          Column(children: [primary, const SizedBox(height: 16), secondary]),
      ]),
    );
    final image = Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 384),
          child: Transform.rotate(
            angle: 3 * math.pi / 180,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 50, spreadRadius: -12, offset: Offset(0, 25))],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Image.asset('assets/images/london-postcard.webp', fit: BoxFit.cover, cacheWidth: 800),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // The page wraps PropertyBanner in py-8 lg:py-14 on top of its own padding.
    final outer = lg ? 56.0 : 32.0;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: outer + _py(context)),
      child: _Boxed(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            color: AppColors.forest,
            child: Stack(children: [
              const Positioned.fill(child: Opacity(opacity: 0.1, child: CustomPaint(painter: _DotsPainter()))),
              if (md)
                Row(children: [Expanded(child: content), Expanded(child: image)])
              else
                Column(children: [content, image]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  const _DotsPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white;
    for (double x = 2; x < size.width; x += 20) {
      for (double y = 2; y < size.height; y += 20) {
        canvas.drawCircle(Offset(x, y), 1.5, p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ───────────────────────────── FAQ ─────────────────────────────
class _Faq extends ConsumerWidget {
  const _Faq();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final md = context.md, lg = context.lg;
    final faqs = [
      for (var n = 1; n <= 6; n++)
        if (t('FAQ_Q$n', '').isNotEmpty) FaqTile(question: t('FAQ_Q$n', ''), answer: t('FAQ_A$n', '')),
    ];
    // SectionFAQ (py-12/16/20) inside the page's pb-10 lg:pb-20 wrapper.
    return Padding(
      padding: EdgeInsets.only(top: _py(context), bottom: _py(context) + (lg ? 80 : 40)),
      child: _Boxed(
        maxWidth: 768,
        child: Column(children: [
          _CenterHeader(
            title: t('FAQ_Title', 'Často kladené otázky'),
            subtitle: t('FAQ_Subtitle', 'Všetko, čo potrebujete vedieť o UK Stay Hub.'),
          ),
          SizedBox(height: md ? 48 : 40),
          for (var i = 0; i < faqs.length; i++) ...[if (i > 0) const SizedBox(height: 16), faqs[i]],
        ]),
      ),
    );
  }
}

class FaqTile extends StatefulWidget {
  const FaqTile({super.key, required this.question, required this.answer});
  final String question;
  final String answer;
  @override
  State<FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<FaqTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _open ? const Color(0x4D238869) : AppColors.neutral200),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text(widget.question,
                      style: AppText.inter(size: context.md ? 18 : 16, weight: FontWeight.w700, height: context.md ? 28 / 18 : 1.5)),
                ),
                const SizedBox(width: 16),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.green, size: 24),
                ),
              ]),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Text(widget.answer, style: AppText.inter(size: 16, color: AppColors.slate, height: 1.625)),
              ),
            ),
          ]),
        ),
      );
}
