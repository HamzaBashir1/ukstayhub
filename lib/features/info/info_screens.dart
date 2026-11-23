import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../widgets/chrome.dart';
import '../../widgets/common.dart';
import '../search/search_screen.dart' show FooterNav;

class _Page extends StatelessWidget {
  const _Page({required this.children, this.background = AppColors.cream});
  final List<Widget> children;
  final Color background;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: background,
        appBar: const StayHubHeader(),
        endDrawer: const StayHubDrawer(),
        body: ListView(children: [...children, const StayHubFooter()]),
        // Shared/FooterNav.js – the website shows it on every one of these pages below lg.
        bottomNavigationBar: context.lg ? null : const FooterNav(),
      );
}

// ───────────────────────────── About (/o-nas) ─────────────────────────────
// About page: Hero and SectionCompany on a white page with the soft BgGlassmorphism blobs.
const _ink1a = Color(0xFF1A1A1A);

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final w = MediaQuery.sizeOf(context).width;
    final md = w >= 768, lg = w >= 1024, sm = w >= 640;

    // ── Hero.js: h1 text-5xl/md:text-7xl Fraunces, leading-[0.95], tracking-tight;
    //    description with a 2px #38a186 left rule; 500px image, rounded 2.5rem.
    final h1Size = md ? 72.0 : 48.0;
    final heroText = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t('about_us_heading', '👋 O nás.'),
          style: AppText.fraunces(size: h1Size, weight: FontWeight.w400, color: _ink1a, height: 0.95, letterSpacing: -0.025 * h1Size)),
      const SizedBox(height: 40),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 448),
        child: Container(
          padding: const EdgeInsets.only(left: 24),
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFF38A186), width: 2))),
          child: Text(t('about_us_description', '').trim(), style: AppText.inter(size: 18, color: const Color(0xFF525252), height: 1.625)),
        ),
      ),
    ]);
    final heroImage = Container(
      height: 500,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
      ),
      child: Image.asset('assets/images/about-hero.webp',
          fit: BoxFit.cover, width: double.infinity, cacheWidth: 1280,
          semanticLabel: 'UK Stay Hub team and London stays'),
    );
    final hero = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 64),
      child: lg
          ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(child: heroText),
              const SizedBox(width: 64),
              Expanded(child: heroImage),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [heroText, const SizedBox(height: 64), heroImage]),
    );

    // ── SectionCompany.js: bordered white card, dl grid (sm:2 columns).
    final rows = [
      (t.pick('Obchodné meno', 'Company'), 'UK Stay Hub Ltd'),
      ('Registered in', 'England and Wales'),
      ('Websites', 'ukstayhub.co.uk · ukstayhub.com'),
      ('Email', AppConfig.supportEmail),
    ];
    Widget row((String, String) r) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.$1.toUpperCase(), style: AppText.inter(size: 12, weight: FontWeight.w600, color: const Color(0xFF737373), letterSpacing: 0.6)),
          const SizedBox(height: 4),
          Text(r.$2, style: AppText.inter(size: 16, weight: FontWeight.w500, color: _ink1a, height: 1.5)),
        ]);
    final company = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(sm ? 32 : 24),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.pick('Údaje o spoločnosti', 'Company details'), style: AppText.fraunces(size: 24, weight: FontWeight.w600, color: _ink1a, letterSpacing: -0.6)),
          const SizedBox(height: 8),
          Text(t.pick('Prevádzkovateľom ukstayhub.co.uk je:', 'ukstayhub.co.uk is operated by:'), style: AppText.inter(size: 14, color: const Color(0xFF737373))),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, c) {
            final cols = sm ? 2 : 1;
            final itemW = (c.maxWidth - 32 * (cols - 1)) / cols;
            return Wrap(spacing: 32, runSpacing: 16, children: [for (final r in rows) SizedBox(width: itemW, child: row(r))]);
          }),
        ]),
      ),
    );

    // BgGlassmorphism: two blurred 10% circles (#ef233c, #04868b) behind the hero.
    Widget blob(Color c) => ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 64, sigmaY: 64, tileMode: TileMode.decal),
          child: Container(width: lg ? 384 : 288, height: lg ? 384 : 288, decoration: BoxDecoration(color: c.withValues(alpha: 0.1), shape: BoxShape.circle)),
        );

    return _Page(background: Colors.white, children: [
      Stack(clipBehavior: Clip.hardEdge, children: [
        Positioned(left: 80, top: md ? 136 : 96, child: blob(const Color(0xFFEF233C))),
        Positioned(left: 80 + (lg ? 384 : 288) - 80, top: (md ? 136 : 96) + 160, child: blob(const Color(0xFF04868B))),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Padding(
              padding: EdgeInsets.only(top: lg ? 40 : 0, bottom: lg ? 80 : 40),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                hero,
                const SizedBox(height: 40),
                company,
              ]),
            ),
          ),
        ),
      ]),
    ]);
  }
}

// ───────────────────────────── FAQ (/caste-otazky) ─────────────────────────────
// 1:1 with ukstayhub.co.uk/caste-otazky (frontend/src/app/FAQ/component/FAQ.js): "FAQ"
// eyebrow, light title, two tabs (customers / providers – providers open by
// default) and a divided plus/minus accordion. Texts: assets/data/faq.json,
// copied from the website's locales (faqsC / faqs).
final _faqProvider = FutureProvider<Json>((ref) async => asMap(jsonDecode(await rootBundle.loadString('assets/data/faq.json'))));

const _faqGreen = Color(0xFF14634B);

class FaqScreen extends ConsumerStatefulWidget {
  const FaqScreen({super.key});
  @override
  ConsumerState<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends ConsumerState<FaqScreen> {
  String _tab = 'accommodation';
  int? _open;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final f = asMap(ref.watch(_faqProvider).valueOrNull?[t.lang]);
    if (f.isEmpty) return const Scaffold(body: LoadingView());
    final w = MediaQuery.sizeOf(context).width;
    final md = w >= 768, lg = w >= 1024;
    final faqs = asMapList(_tab == 'customer' ? f['customers'] : f['providers']);

    Widget tabButton(String id, String label) {
      final active = _tab == id;
      return Material(
        color: active ? _faqGreen.withValues(alpha: 0.05) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() {
            _tab = id;
            _open = null;
          }),
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: lg ? 12 : 8),
              child: Text(label,
                  style: AppText.inter(size: 14, weight: active ? FontWeight.w600 : FontWeight.w500, color: active ? _faqGreen : const Color(0xFF9CA3AF), letterSpacing: 0.35)),
            ),
            if (active && lg)
              Positioned(left: 0, top: 0, bottom: 0, child: Container(width: 4, decoration: BoxDecoration(color: _faqGreen, borderRadius: BorderRadius.circular(99)))),
          ]),
        ),
      );
    }

    final tabs = Container(
      padding: EdgeInsets.only(bottom: lg ? 0 : 16, left: lg ? 24 : 0),
      decoration: BoxDecoration(
        border: lg ? const Border(left: BorderSide(color: Color(0xFFE5E7EB))) : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: lg
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              tabButton('customer', asString(f['customersLabel'])),
              const SizedBox(height: 8),
              tabButton('accommodation', asString(f['providersLabel'])),
            ])
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                tabButton('customer', asString(f['customersLabel'])),
                const SizedBox(width: 8),
                tabButton('accommodation', asString(f['providersLabel'])),
              ]),
            ),
    );

    Widget item(int i, Json q) {
      final open = _open == i;
      return Container(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 24, bottom: i == faqs.length - 1 ? 0 : 24),
        decoration: BoxDecoration(
          border: i == faqs.length - 1 ? null : Border(bottom: BorderSide(color: const Color(0xFFE5E7EB).withValues(alpha: 0.8))),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: () => setState(() => _open = open ? null : i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(asString(q['question']),
                          style: AppText.inter(size: md ? 20 : 18, weight: FontWeight.w300, color: open ? _faqGreen : const Color(0xFF111827), height: 1.4, letterSpacing: -0.4)),
                    ),
                  ),
                  // Plus / minus made of two 1.5px bars; the vertical one fades out when open.
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: Stack(alignment: Alignment.center, children: [
                        Container(width: 16, height: 1.5, color: open ? _faqGreen : const Color(0xFF9CA3AF)),
                        AnimatedOpacity(
                          opacity: open ? 0 : 1,
                          duration: const Duration(milliseconds: 300),
                          child: AnimatedRotation(
                            turns: open ? 0.25 : 0,
                            duration: const Duration(milliseconds: 300),
                            child: Container(width: 1.5, height: 16, color: const Color(0xFF9CA3AF)),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 672),
                      child: Text(asString(q['answer']),
                          style: AppText.inter(size: md ? 16 : 14, weight: FontWeight.w300, color: const Color(0xFF6B7280), height: 1.625)),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ]),
      );
    }

    final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < faqs.length; i++) item(i, faqs[i])]);
    final titleSize = lg ? 60.0 : (md ? 48.0 : 36.0);

    return _Page(background: Colors.white, children: [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: lg ? 128 : 24, vertical: md ? 112 : 64),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1024),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 672),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('FAQ', style: AppText.inter(size: 12, weight: FontWeight.w600, color: _faqGreen, letterSpacing: 1.2)),
                  const SizedBox(height: 12),
                  Text(asString(f['title']),
                      style: AppText.inter(size: titleSize, weight: FontWeight.w300, color: const Color(0xFF111827), height: 1.25, letterSpacing: -0.025 * titleSize)),
                  const SizedBox(height: 24),
                  Text(asString(f['description']), style: AppText.inter(size: md ? 18 : 16, weight: FontWeight.w300, color: const Color(0xFF6B7280), height: 1.625)),
                ]),
              ),
              SizedBox(height: md ? 96 : 64),
              lg
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 4, child: tabs),
                      const SizedBox(width: 64),
                      Expanded(flex: 8, child: list),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [tabs, const SizedBox(height: 48), list]),
            ]),
          ),
        ),
      ),
    ]);
  }
}

// ───────────────────────────── Contact (/kontakt) ─────────────────────────────
// 1:1 with ukstayhub.co.uk/kontakt (frontend/src/app/Contact/ContactContent.js +
// contact.module.css), including its mobile (<768px) sizes.
const _cInk = Color(0xFF203C31);
const _cMuted = Color(0xFF68776F);
const _cLine = Color(0xFFDCE5DC);
const _cCream = Color(0xFFF5F4E9);
const _cLeaf = Color(0xFF315F49);
const _cCitrus = Color(0xFFD7E78D);

TextStyle _dm(double size, {FontWeight weight = FontWeight.w400, Color color = _cMuted, double? height, double? spacing}) =>
    AppText.dmSans(size: size, weight: weight, color: color, height: height).copyWith(letterSpacing: spacing);

class ContactScreen extends ConsumerWidget {
  const ContactScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final c = t.isEn ? _contactEn : _contactSk;
    final w = MediaQuery.sizeOf(context).width;
    final mobile = w < 768;
    Future<void> mail() => launchUrl(Uri.parse('mailto:${AppConfig.supportEmail}?subject=${Uri.encodeComponent(c['emailSubject']!)}'));
    Future<void> call() => launchUrl(Uri.parse('tel:${AppConfig.supportPhone}'));

    // Eyebrow / section-number style: 10–11px DM Sans bold, .14em, uppercase.
    Text label(String s, {Color color = _cMuted, double? size}) =>
        Text(s.toUpperCase(), style: _dm(size ?? (mobile ? 10 : 11), weight: FontWeight.w700, color: color, spacing: (size ?? (mobile ? 10 : 11)) * 0.14));

    // ── Hero
    final titleSize = mobile ? (w * 0.14).clamp(49.0, 69.0) : (w * 0.075).clamp(52.0, 88.0);
    final hoursPanel = Container(
      constraints: BoxConstraints(minWidth: mobile ? 250 : 260),
      padding: mobile ? const EdgeInsets.symmetric(horizontal: 19, vertical: 17) : const EdgeInsets.symmetric(horizontal: 21, vertical: 23),
      decoration: BoxDecoration(color: _cCream, borderRadius: BorderRadius.circular(3)),
      child: Stack(clipBehavior: Clip.none, children: [
        Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: _cCitrus, shape: BoxShape.circle),
            child: const Icon(Icons.schedule, size: 20, color: _cInk),
          ),
          const SizedBox(width: 15),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 2),
            Text(c['hoursLabel']!, style: _dm(12, height: 1.4)),
            const SizedBox(height: 7),
            Text(c['hours']!, style: AppText.fraunces(size: 25, weight: FontWeight.w500, color: _cInk, letterSpacing: -0.625)),
            const SizedBox(height: 5),
            Text(c['timezone']!, style: _dm(11)),
          ]),
          const SizedBox(width: 24),
        ]),
        Positioned(
          right: (mobile ? 0 : 0) - (mobile ? 3 : 5),
          top: mobile ? 0 : -6,
          child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Color(0xFF89A651), shape: BoxShape.circle)),
        ),
      ]),
    );
    final heroCopy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Color(0xFFA4BC59),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Color(0xFFEDF1DC), spreadRadius: 5)],
          ),
        ),
        const SizedBox(width: 11),
        Expanded(child: label(c['eyebrow']!, color: _cLeaf)),
      ]),
      SizedBox(height: mobile ? 18 : 22),
      Text(c['title']!, style: AppText.fraunces(size: titleSize, weight: FontWeight.w500, color: _cInk, height: 0.98, letterSpacing: -0.055 * titleSize)),
      SizedBox(height: mobile ? 17 : 24),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mobile ? 380 : 470),
        child: Text(c['intro']!, style: _dm(mobile ? 14 : 16, height: 1.7)),
      ),
    ]);
    final circleSize = mobile ? 190.0 : 275.0;
    final hero = Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _cLine))),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          right: mobile ? -76 : null,
          left: mobile ? null : 0,
          top: 27,
          child: mobile
              ? Container(width: circleSize, height: circleSize, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFFE6EADB))))
              : const SizedBox.shrink(),
        ),
        Padding(
          padding: mobile ? const EdgeInsets.fromLTRB(0, 52, 0, 27) : const EdgeInsets.fromLTRB(0, 78, 0, 56),
          child: mobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [heroCopy, const SizedBox(height: 25), hoursPanel])
              : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 650), child: heroCopy)),
                  const SizedBox(width: 38),
                  hoursPanel,
                ]),
        ),
        Positioned(right: 0, bottom: mobile ? 12 : 16, child: Text('P / 01', style: _dm(10, weight: FontWeight.w700, color: const Color(0xFF9AA79D), spacing: 1.2, height: 1))),
      ]),
    );

    // ── Email / phone cards
    Widget contactCard({required bool email, required IconData icon, required String eyebrow, required String title, required String text, required String action, required VoidCallback onTap}) =>
        Container(
          constraints: BoxConstraints(minHeight: mobile ? 228 : 255),
          padding: mobile ? const EdgeInsets.fromLTRB(21, 21, 21, 19) : const EdgeInsets.fromLTRB(29, 26, 29, 23),
          decoration: BoxDecoration(
            color: email ? const Color(0xFFF1F4E8) : const Color(0xFFF7F0E6),
            border: Border.all(color: email ? const Color(0xFFE5EAD6) : const Color(0xFFEEE4D5)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.72), shape: BoxShape.circle),
                child: Icon(icon, size: 19, color: _cLeaf),
              ),
              const SizedBox(width: 12),
              Expanded(child: label(eyebrow, size: 10)),
            ]),
            SizedBox(height: mobile ? 14 : 18),
            Text(title, style: AppText.fraunces(size: mobile ? 29 : 32, weight: FontWeight.w500, color: _cInk, letterSpacing: -0.035 * (mobile ? 29 : 32))),
            const SizedBox(height: 5),
            Text(text, style: _dm(14, height: 1.6)),
            SizedBox(height: mobile ? 16 : 19),
            InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(action, style: _dm(mobile ? 14 : 15, weight: FontWeight.w700, color: _cLeaf, height: 1.4))),
                  const SizedBox(width: 14),
                  const Icon(Icons.arrow_forward, size: 18, color: _cLeaf),
                ]),
              ),
            ),
          ]),
        );
    final emailCard = contactCard(email: true, icon: Icons.mail_outline, eyebrow: c['emailEyebrow']!, title: c['emailTitle']!, text: c['emailText']!, action: AppConfig.supportEmail, onTap: mail);
    final phoneCard = contactCard(email: false, icon: Icons.phone_outlined, eyebrow: c['phoneEyebrow']!, title: c['phoneTitle']!, text: c['phoneText']!, action: c['phoneAction']!, onTap: call);
    final grid = Padding(
      padding: EdgeInsets.only(top: mobile ? 20 : 34),
      child: mobile
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [emailCard, const SizedBox(height: 12), phoneCard])
          : IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: emailCard), const SizedBox(width: 18), Expanded(child: phoneCard)])),
    );

    // ── Safety note
    final note = Container(
      margin: EdgeInsets.only(top: mobile ? 13 : 20),
      padding: mobile ? const EdgeInsets.symmetric(horizontal: 13, vertical: 15) : const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      color: const Color(0xFFF3F2E8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: mobile ? 29 : 36, height: mobile ? 29 : 36, child: const Icon(Icons.description_outlined, size: 20, color: _cLeaf)),
        SizedBox(width: mobile ? 10 : 15),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 1),
            Text(c['noteTitle']!, style: _dm(mobile ? 12 : 13, weight: FontWeight.w700, color: _cInk, height: 1.4)),
            const SizedBox(height: 5),
            Text(c['noteBody']!, style: _dm(mobile ? 12 : 13, height: 1.65)),
          ]),
        ),
      ]),
    );

    // ── 01 — Audience rows
    final sectionTitleSize = mobile ? 34.0 : (w * 0.04).clamp(30.0, 43.0);
    TextStyle sectionTitle(Color color) => AppText.fraunces(size: sectionTitleSize, weight: FontWeight.w500, color: color, height: 1.08, letterSpacing: -0.04 * sectionTitleSize);
    Widget audienceRow(String letter, String title, String text, String semantics) => Container(
          constraints: BoxConstraints(minHeight: mobile ? 106 : 116),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _cLine))),
          child: Row(children: [
            Container(
              width: mobile ? 30 : 34,
              height: mobile ? 30 : 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFFCED9C6))),
              child: Text(letter, style: _dm(12, weight: FontWeight.w600, color: _cLeaf)),
            ),
            SizedBox(width: mobile ? 15 : 20),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: _dm(mobile ? 14 : 15, weight: FontWeight.w700, color: _cInk, height: 1.4)),
                const SizedBox(height: 5),
                Text(text, style: _dm(mobile ? 12 : 13, height: 1.55)),
              ]),
            ),
            SizedBox(width: mobile ? 11 : 16),
            Semantics(
              label: semantics,
              button: true,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: mail,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(color: Color(0xFFEDF0E3), shape: BoxShape.circle),
                  child: const Icon(Icons.arrow_forward, size: 18, color: _cLeaf),
                ),
              ),
            ),
          ]),
        );
    final audienceIntro = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 6),
      label('01 —', size: 10),
      SizedBox(height: mobile ? 11 : 16),
      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340), child: Text(c['audienceTitle']!, style: sectionTitle(_cInk))),
    ]);
    final audienceRows = Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: _cLine))),
      child: Column(children: [
        audienceRow('G', c['guestTitle']!, c['guestText']!, c['guestEmailAction']!),
        audienceRow('H', c['hostTitle']!, c['hostText']!, c['hostEmailAction']!),
      ]),
    );
    final audience = Padding(
      padding: mobile ? const EdgeInsets.fromLTRB(0, 56, 0, 52) : const EdgeInsets.fromLTRB(0, 84, 0, 79),
      child: mobile
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [audienceIntro, const SizedBox(height: 25), audienceRows])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 8, child: audienceIntro), const SizedBox(width: 70), Expanded(flex: 12, child: audienceRows)]),
    );

    // ── 02 — More help (green band)
    Widget helpLink(String text, String path, {bool first = false}) => InkWell(
          onTap: () => context.push(path),
          child: Container(
            constraints: BoxConstraints(minHeight: mobile ? 53 : 59),
            decoration: BoxDecoration(
              border: Border(
                top: first ? BorderSide(color: Colors.white.withValues(alpha: 0.25)) : BorderSide.none,
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
              ),
            ),
            child: Row(children: [
              Expanded(child: Text(text, style: _dm(mobile ? 13 : 14, weight: FontWeight.w600, color: Colors.white, height: 1.4))),
              const SizedBox(width: 15),
              const Icon(Icons.arrow_forward, size: 18, color: Colors.white),
            ]),
          ),
        );
    final moreCopy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      label('02 —', color: const Color(0xFFC5D39D), size: 10),
      SizedBox(height: mobile ? 11 : 12),
      ConstrainedBox(constraints: BoxConstraints(maxWidth: mobile ? 330 : 440), child: Text(c['moreTitle']!, style: sectionTitle(const Color(0xFFF7F7EF)))),
      const SizedBox(height: 12),
      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 430), child: Text(c['moreText']!, style: _dm(mobile ? 12 : 13, color: const Color(0xFFD4DFD3), height: 1.65))),
    ]);
    final moreLinks = Column(children: [
      helpLink(c['faq']!, '/caste-otazky', first: true),
      helpLink(c['guide']!, '/prirucka-hostitela'),
    ]);
    final more = Container(
      margin: EdgeInsets.only(bottom: mobile ? 52 : 82),
      padding: mobile ? const EdgeInsets.symmetric(horizontal: 22, vertical: 27) : const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      color: _cLeaf,
      child: mobile
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [moreCopy, const SizedBox(height: 24), moreLinks])
          : Row(children: [Expanded(child: moreCopy), const SizedBox(width: 50), Expanded(child: moreLinks)]),
    );

    return _Page(background: const Color(0xFFFBFBF6), children: [
      ClipRect(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: mobile ? 560 : 1120),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: mobile ? 18 : 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [hero, grid, note, audience, more]),
            ),
          ),
        ),
      ),
    ]);
  }
}

const _contactSk = {
  'eyebrow': 'Ľudská podpora UK Stay Hub',
  'title': 'Ozvite sa.\nSme tu pre vás.',
  'intro': 'Či cestujete, alebo ubytovávate hostí, radi vám pomôžeme nájsť ďalší krok.',
  'hoursLabel': 'Sme k dispozícii každý deň',
  'hours': '08:00 – 18:00',
  'timezone': 'Europe/London',
  'emailEyebrow': 'Napíšte nám',
  'emailTitle': 'E-mail',
  'emailText': 'Opíšte nám, s čím potrebujete pomôcť.',
  'phoneEyebrow': 'Porozprávajme sa',
  'phoneTitle': 'Zavolajte nám',
  'phoneText': 'Ak vám viac vyhovuje telefonát, sme na čísle:',
  'phoneAction': '+44 20 7946 0000',
  'noteTitle': 'Aby sme vám vedeli lepšie pomôcť',
  'noteBody': 'Pri otázke k pobytu uveďte ID rezervácie a stručne opíšte problém. Nikdy neposielajte údaje z platobnej karty ani heslo.',
  'audienceTitle': 'Podpora pre obe strany pobytu',
  'guestTitle': 'Ste hosť?',
  'guestText': 'Pomôžeme vám zorientovať sa v rezervácii alebo s otázkou k vášmu pobytu.',
  'guestEmailAction': 'Napísať e-mail podpore k otázke hostí',
  'hostTitle': 'Ste hostiteľ?',
  'hostText': 'Sme tu aj vtedy, keď potrebujete pomoc s ponukou alebo hostením.',
  'hostEmailAction': 'Napísať e-mail podpore pre hostiteľov',
  'moreTitle': 'Možno nájdete odpoveď hneď',
  'moreText': 'Pozrite si najčastejšie otázky alebo praktického sprievodcu používaním UK Stay Hub.',
  'faq': 'Prejsť na FAQ',
  'guide': 'Otvoriť sprievodcu',
  'emailSubject': 'Pomoc od UK Stay Hub',
};

const _contactEn = {
  'eyebrow': 'UK Stay Hub human support',
  'title': 'Get in touch.\nWe’re here for you.',
  'intro': 'Whether you’re travelling or welcoming guests, we’ll help you find your next step.',
  'hoursLabel': 'Here for you every day',
  'hours': '08:00–18:00',
  'timezone': 'Europe/London',
  'emailEyebrow': 'Send us a note',
  'emailTitle': 'Email',
  'emailText': 'Tell us a little about what you need help with.',
  'phoneEyebrow': 'Let’s talk',
  'phoneTitle': 'Call us',
  'phoneText': 'If you prefer to talk, reach us at:',
  'phoneAction': '+44 20 7946 0000',
  'noteTitle': 'Help us help you',
  'noteBody': 'For a question about a stay, include your reservation ID and briefly describe the issue. Never send card details or your password.',
  'audienceTitle': 'Support for every side of a stay',
  'guestTitle': 'Are you a guest?',
  'guestText': 'We can help you find your way around a reservation or answer a question about your stay.',
  'guestEmailAction': 'Email support about a guest question',
  'hostTitle': 'Are you a host?',
  'hostText': 'We’re here when you need help with your listing or hosting.',
  'hostEmailAction': 'Email support about hosting',
  'moreTitle': 'Your answer might be just a page away',
  'moreText': 'Browse frequently asked questions or our practical guide to using UK Stay Hub.',
  'faq': 'Visit the FAQ',
  'guide': 'Open the user guide',
  'emailSubject': 'Help from UK Stay Hub',
};

// ───────────────────────────── Legal pages ─────────────────────────────
/// Privacy policy and terms are legal texts the company edits on the website;
/// showing the live page guarantees the app never shows an outdated version.
class WebPageScreen extends ConsumerStatefulWidget {
  const WebPageScreen({super.key, required this.path, required this.title});
  final String path;
  final String title;
  @override
  ConsumerState<WebPageScreen> createState() => _WebPageScreenState();
}

class _WebPageScreenState extends ConsumerState<WebPageScreen> {
  late final WebViewController _c;
  int _p = 0;

  @override
  void initState() {
    super.initState();
    final lang = ref.read(langProvider);
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => setState(() => _p = p),
        onNavigationRequest: (r) {
          final u = Uri.tryParse(r.url);
          if (u != null && !AppConfig.isSiteHost(u.host)) {
            launchUrl(u, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(sitePath('${lang == 'en' ? '/en' : ''}${widget.path}')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: _p < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(value: _p / 100, minHeight: 2, color: AppColors.green),
                )
              : null,
        ),
        body: WebViewWidget(controller: _c),
      );
}

// ───────────────────────────── Host guide (/prirucka-hostitela) ─────────────────────────────
// Mirrors ukstayhub.co.uk/prirucka-hostitela: back link, contents, numbered sections,
// labelled callouts and an "Open this screen" link per section.
final _guideProvider = FutureProvider<Json>((ref) async => asMap(jsonDecode(await rootBundle.loadString('assets/data/guide.json'))));

class HostGuideScreen extends ConsumerStatefulWidget {
  const HostGuideScreen({super.key});
  @override
  ConsumerState<HostGuideScreen> createState() => _HostGuideScreenState();
}

class _HostGuideScreenState extends ConsumerState<HostGuideScreen> {
  final Map<String, GlobalKey> _keys = {};

  GlobalKey _key(String id) => _keys.putIfAbsent(id, () => GlobalKey());

  void _jump(String id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic, alignment: 0.02);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final g = asMap(ref.watch(_guideProvider).valueOrNull?[t.lang]);
    if (g.isEmpty) return const Scaffold(body: LoadingView());
    final sections = asMapList(g['sections']);
    final labels = asMap(g['labels']);
    final sm = context.sm;

    final contents = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.neutral200)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(asString(g['contents'], t.pick('Obsah', 'Contents')).toUpperCase(),
            style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        for (var i = 0; i < sections.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _jump(asString(sections[i]['id'])),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 28, child: Text('${i + 1}.', style: AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.green))),
                Expanded(child: Text(asString(sections[i]['title']), style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.forest))),
              ]),
            ),
          ),
      ]),
    );

    Widget section(int i, Json s) {
      final href = asString(s['href']);
      return Container(
        key: _key(asString(s['id'])),
        margin: const EdgeInsets.only(top: 20),
        padding: EdgeInsets.all(sm ? 28 : 20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.neutral200)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.mint, borderRadius: BorderRadius.circular(10)),
              child: Text('${i + 1}', style: AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.green)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(asString(s['title']), style: AppText.fraunces(size: 22, color: AppColors.forest, height: 1.25)))),
          ]),
          if (asString(s['intro']).isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(asString(s['intro']), style: AppText.inter(size: 15, color: AppColors.slate, height: 1.6)),
          ],
          for (final b in asMapList(s['blocks'])) _GuideBlock(block: b, labels: labels),
          if (href.isNotEmpty) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => context.go(href),
              icon: const Icon(Icons.arrow_forward, size: 16, color: AppColors.forest),
              label: Text(asString(g['openScreen'], t.pick('Otvoriť túto obrazovku', 'Open this screen')),
                  style: AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.forest)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.forest,
                side: const BorderSide(color: AppColors.neutral300),
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ]),
      );
    }

    return _Page(background: AppColors.hostBg, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextButton.icon(
            onPressed: () => context.go('/host'),
            icon: const Icon(Icons.arrow_back, size: 16, color: AppColors.forest),
            label: Text(asString(g['backToWorkspace'], t.pick('Späť do pracoviska hostiteľa', 'Back to host workspace')),
                style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.forest)),
            style: TextButton.styleFrom(foregroundColor: AppColors.forest, padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
          const SizedBox(height: 12),
          Text(asString(g['title']), style: AppText.fraunces(size: sm ? 44 : 34, color: AppColors.forestDark, height: 1.1)),
          const SizedBox(height: 12),
          Text(asString(g['subtitle']), style: AppText.inter(size: 16, color: AppColors.slate, height: 1.6)),
          const SizedBox(height: 24),
          contents,
          for (var i = 0; i < sections.length; i++) section(i, sections[i]),
        ]),
      ),
    ]);
  }
}

class _GuideBlock extends StatelessWidget {
  const _GuideBlock({required this.block, required this.labels});
  final Json block;
  final Json labels;

  @override
  Widget build(BuildContext context) {
    final type = asString(block['type']);
    if (type == 'tip' || type == 'note' || type == 'warning') {
      final (bg, border, fg, icon) = switch (type) {
        'warning' => (const Color(0xFFFFFBEB), const Color(0xFFFDE68A), const Color(0xFF92400E), Icons.warning_amber_rounded),
        'tip' => (AppColors.mint, AppColors.mintBorder, AppColors.forest, Icons.lightbulb_outline),
        _ => (const Color(0xFFEFF6FF), const Color(0xFFBFDBFE), const Color(0xFF1E40AF), Icons.info_outline),
      };
      final label = asString(labels[type]);
      return Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: border)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: fg)),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: [
              if (label.isNotEmpty) TextSpan(text: '$label: ', style: AppText.inter(size: 14, weight: FontWeight.w700, color: fg, height: 1.55)),
              TextSpan(text: asString(block['text']), style: AppText.inter(size: 14, color: fg, height: 1.55)),
            ])),
          ),
        ]),
      );
    }
    final items = asStringList(block['items']);
    final steps = type == 'steps';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (asString(block['title']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(asString(block['title']), style: AppText.inter(size: 15, weight: FontWeight.w700, color: AppColors.forest)),
          ),
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              steps
                  ? Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(right: 10, top: 1),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle),
                      child: Text('${i + 1}', style: AppText.inter(size: 11, weight: FontWeight.w700, color: Colors.white, height: 1)),
                    )
                  : Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(left: 6, right: 14, top: 9),
                      decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle),
                    ),
              Expanded(child: Text(items[i], style: AppText.inter(size: 14, color: AppColors.neutral700, height: 1.55))),
            ]),
          ),
      ]),
    );
  }
}
