import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../state/providers.dart';
import '../../widgets/chrome.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart' show RegionCard;
import '../search/search_screen.dart' show FooterNav, MobileSearchHeader, ResultCard;

// ───────────────────────────── Blog (/blog) ─────────────────────────────
class BlogListScreen extends ConsumerWidget {
  const BlogListScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(blogsProvider);
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: const StayHubHeader(showBack: true),
      endDrawer: const StayHubDrawer(),
      body: RefreshIndicator(
        color: AppColors.green,
        onRefresh: () => ref.refresh(blogsProvider.future),
        child: async.when(
          loading: () => const LoadingView(),
          error: (e, _) => ListView(children: [ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(blogsProvider))]),
          data: (blogs) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), children: [
            SectionHeader(title: 'Blog', subtitle: t.pick('Tipy na výlety, sprievodcovia a novinky z UK Stay Hub.', 'Trip ideas, guides and UK Stay Hub news.')),
            const SizedBox(height: 24),
            if (blogs.isEmpty) EmptyBox(t.pick('Zatiaľ žiadne články.', 'No articles yet.')),
            for (final b in blogs) ...[BlogCard(blog: b), const SizedBox(height: 20)],
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }
}

/// Blog/component/Card3.js
class BlogCard extends ConsumerWidget {
  const BlogCard({super.key, required this.blog});
  final Json blog;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final date = asDate(blog['createdAt']);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/blog/${asString(blog['slug'])}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(aspectRatio: 16 / 9, child: NetImage(cloudinary(asString(blog['image']), width: 900, ratio: 9 / 16), cacheWidth: 900)),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (asString(blog['categories']).isNotEmpty) Pill(asString(blog['categories'])),
              const SizedBox(height: 10),
              Text(asString(blog['title']), style: AppText.fraunces(size: 20, height: 1.25)),
              const SizedBox(height: 8),
              Text(asString(blog['summary']),
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, color: AppColors.slate, height: 1.55)),
              const SizedBox(height: 12),
              Text(
                [asString(blog['authorName'], asString(blog['author'], 'UK Stay Hub')), if (date != null) longDate(date, t.lang)].join(' · '),
                style: AppText.inter(size: 12, color: AppColors.neutral500),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class BlogDetailScreen extends ConsumerStatefulWidget {
  const BlogDetailScreen({super.key, required this.slug});
  final String slug;
  @override
  ConsumerState<BlogDetailScreen> createState() => _BlogDetailScreenState();
}

class _BlogDetailScreenState extends ConsumerState<BlogDetailScreen> {
  bool _counted = false;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(blogProvider(widget.slug));
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(backgroundColor: Colors.white),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(blogProvider(widget.slug))),
        data: (b) {
          final id = asString(b['_id']);
          if (!_counted && id.isNotEmpty) {
            _counted = true;
            publicRepo.blogView(id);
          }
          final date = asDate(b['createdAt']);
          return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
            if (asString(b['categories']).isNotEmpty) Align(alignment: Alignment.centerLeft, child: Pill(asString(b['categories']))),
            const SizedBox(height: 12),
            Text(asString(b['title']), style: AppText.fraunces(size: 30, height: 1.2)),
            const SizedBox(height: 12),
            Text([asString(b['authorName'], 'UK Stay Hub'), if (date != null) longDate(date, t.lang)].join(' · '),
                style: AppText.inter(size: 13, color: AppColors.neutral500)),
            const SizedBox(height: 20),
            if (asString(b['image']).isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: NetImage(cloudinary(asString(b['image']), width: 1200, crop: false), cacheWidth: 1200),
              ),
            const SizedBox(height: 20),
            HtmlWidget(
              asString(b['content']),
              textStyle: AppText.inter(size: 16, color: AppColors.neutral800, height: 1.7),
              onTapUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              customStylesBuilder: (el) => switch (el.localName) {
                'h1' || 'h2' => {'font-family': 'serif', 'color': '#1A3A2E', 'margin-top': '24px'},
                'a' => {'color': '#238869'},
                _ => null,
              },
            ),
            const SizedBox(height: 32),
            _BlogComments(blogId: id),
          ]);
        },
      ),
    );
  }
}

class _BlogComments extends ConsumerStatefulWidget {
  const _BlogComments({required this.blogId});
  final String blogId;
  @override
  ConsumerState<_BlogComments> createState() => _BlogCommentsState();
}

class _BlogCommentsState extends ConsumerState<_BlogComments> {
  List<Json> _items = [];
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final a = ref.read(authProvider);
    _name.text = a.name;
    _email.text = a.email;
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.blogId.isEmpty) return;
    try {
      final c = await publicRepo.blogComments(widget.blogId);
      if (mounted) setState(() => _items = c);
    } catch (_) {}
  }

  Future<void> _send() async {
    final t = ref.read(stringsProvider);
    if (_text.text.trim().isEmpty || _name.text.trim().isEmpty) {
      return toast(context, t('Pleasefillinallrequiredfieldscorrectly', 'Vyplňte povinné polia.'), error: true);
    }
    setState(() => _sending = true);
    try {
      await publicRepo.postBlogComment({
        'blogId': widget.blogId,
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        'comment': _text.text.trim(),
      });
      _text.clear();
      if (mounted) toast(context, t.pick('Komentár odoslaný.', 'Comment sent.'));
      _load();
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${t.pick('Komentáre', 'Comments')} (${_items.length})', style: AppText.fraunces(size: 22)),
      const SizedBox(height: 16),
      for (final c in _items)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(asString(c['name'], 'Anonym'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(asString(c['comment'] ?? c['content'] ?? c['text']), style: AppText.inter(size: 14, color: AppColors.neutral700, height: 1.5)),
          ]),
        ),
      const SizedBox(height: 8),
      StayHubField(label: t.pick('Meno', 'Name'), controller: _name, required: true),
      const SizedBox(height: 12),
      StayHubField(label: t('email', 'E-mail'), controller: _email, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 12),
      StayHubField(label: t.pick('Komentár', 'Comment'), controller: _text, maxLines: 4, required: true),
      const SizedBox(height: 16),
      PrimaryButton(label: t.pick('Odoslať', 'Send'), loading: _sending, onPressed: _send),
    ]);
  }
}

// ───────────────────────────── Regions (/ubytovanie) ─────────────────────────────
class RegionsScreen extends ConsumerWidget {
  const RegionsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(regionCardsProvider);
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: const StayHubHeader(showBack: true),
      endDrawer: const StayHubDrawer(),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(destinationsProvider)),
        data: (regions) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          SectionHeader(
            title: 'Stays in London',
            subtitle: t('PopularDestinations_Subtitle', 'Objavte miesta s aktuálne dostupnými pobytmi.'),
          ),
          const SizedBox(height: 24),
          for (final r in regions) ...[
            AspectRatio(aspectRatio: 16 / 10, child: RegionCard(region: r)),
            const SizedBox(height: 16),
          ],
        ]),
      ),
    );
  }
}

// ───────────────────────────── Host public page (/host-detail/:id) ─────────────────────────────
/// host-detail/[id]/ClientPage.js
class HostDetailScreen extends ConsumerStatefulWidget {
  const HostDetailScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<HostDetailScreen> createState() => _HostDetailScreenState();
}

// Shared/contants.js: the avatar background comes from the first letter.
const _avatarColors = [
  Color(0xFFFFDD00), Color(0xFFFBB034), Color(0xFFFF4C4C), Color(0xFFC1D82F), Color(0xFFF48924), Color(0xFF7AC143),
  Color(0xFF30C39E), Color(0xFF06BCAE), Color(0xFF0695BC), Color(0xFF037EF3), Color(0xFF146EB4), Color(0xFF8E43E7),
  Color(0xFFEA1D5D), Color(0xFFFC636B), Color(0xFFFF6319), Color(0xFFE01F3D), Color(0xFFA0AC48), Color(0xFF00D1B2),
  Color(0xFF472F92), Color(0xFF388ED1), Color(0xFFA6192E), Color(0xFF4A8594), Color(0xFF7B9FAB), Color(0xFF1393BD),
  Color(0xFF5E13BD), Color(0xFFE208A7),
];

class _HostDetailScreenState extends ConsumerState<HostDetailScreen> {
  static const _forest = AppColors.forestListing;
  static const _green = AppColors.greenListing;
  int _visible = 6;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final host = ref.watch(hostPublicProvider(widget.hostId));
    final listings = ref.watch(_hostListingsProvider(widget.hostId));
    final lg = context.lg;
    return Scaffold(
      backgroundColor: const Color(0xFFFCFDFA),
      endDrawer: const StayHubDrawer(),
      // Desktop header from lg; below it the sticky bar sits in the body.
      appBar: lg ? const StayHubHeader() : null,
      bottomNavigationBar: lg ? null : const FooterNav(),
      body: Column(children: [
        if (!lg)
          // `sticky top-0 … bg-white/90 border-b lg:hidden`
          Container(
            decoration: const BoxDecoration(color: Color(0xE6FFFFFF), border: Border(bottom: BorderSide(color: AppColors.neutral200))),
            child: const SafeArea(bottom: false, child: Padding(padding: EdgeInsets.symmetric(vertical: 22), child: MobileSearchHeader())),
          ),
        Expanded(
          child: host.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(hostPublicProvider(widget.hostId))),
            data: (h) => _content(context, t, h, listings),
          ),
        ),
      ]),
    );
  }

  Widget _content(BuildContext context, Strings t, Json h, AsyncValue<List<Listing>> listings) {
    final vw = context.vw;
    final sm = context.sm, md = context.md, lg = context.lg;
    final items = listings.valueOrNull ?? const <Listing>[];
    final name = asString(h['name']);
    final photo = asString(h['photo']);
    final verified = asBool(h['isVerified']);
    final about = asString(h['aboutYou']);
    final since = asDate(h['createdAt']);
    final sinceText = since == null ? 'Unknown' : DateFormat('LLLL yyyy', 'en_GB').format(since.toLocal());

    final bannerH = md ? 224.0 : (sm ? 128.0 : 80.0);
    final overlap = sm ? 64.0 : 40.0;
    final px = lg ? 32.0 : (sm ? 24.0 : 16.0);

    final sidebar = _sidebar(t, h, name, photo, verified, about, sinceText, vw);
    final list = _list(context, t, name, items, listings.isLoading, md, listings.error);

    return ListView(padding: EdgeInsets.zero, children: [
      Stack(children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bannerH,
          child: Container(color: _forest, child: CustomPaint(painter: _DotsPainter())),
        ),
        Padding(
          padding: EdgeInsets.only(top: bannerH - overlap),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Padding(
                padding: EdgeInsets.fromLTRB(px, 0, px, lg ? 128 : 96),
                child: lg
                    ? LayoutBuilder(builder: (_, c) {
                        // grid-cols-12 gap-12
                        final col = (c.maxWidth - 11 * 48) / 12;
                        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(width: col * 4 + 3 * 48, child: sidebar),
                          const SizedBox(width: 48),
                          SizedBox(width: col * 8 + 7 * 48, child: list),
                        ]);
                      })
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [sidebar, const SizedBox(height: 24), list]),
              ),
            ),
          ),
        ),
      ]),
      const StayHubFooter(),
    ]);
  }

  Widget _sidebar(Strings t, Json h, String name, String photo, bool verified, String about, String sinceText, double vw) {
    final sm = vw >= 640, md = vw >= 768;
    final av = sm ? 128.0 : 96.0;
    final initial = name.isEmpty ? '' : name.characters.first.toUpperCase();
    final color = name.isEmpty ? _avatarColors.first : _avatarColors[name.runes.first % _avatarColors.length];

    Widget meta(IconData icon, String label, String value) => Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.neutral50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x99E5E5E5)),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.neutral100),
                boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
              ),
              child: Icon(icon, size: 20, color: _green),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(), style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500, letterSpacing: 0.6)),
                Text(value, style: AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.neutral900)),
              ]),
            ),
          ]),
        );

    return Container(
      padding: EdgeInsets.all(md ? 32 : (sm ? 24 : 20)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xCCE5E5E5)),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1))],
      ),
      child: Column(children: [
        // Avatar: ring-4 white, shadow-md, check badge top -4 right 8.
        Stack(clipBehavior: Clip.none, children: [
          Container(
            width: av,
            height: av,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: photo.isEmpty ? color : null,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 6, offset: Offset(0, 4))],
              image: photo.isEmpty ? null : DecorationImage(image: NetworkImage(cloudinary(photo, width: 256, ratio: 1)), fit: BoxFit.cover),
            ),
            alignment: Alignment.center,
            child: photo.isEmpty ? Text(initial, style: AppText.inter(size: 16, weight: FontWeight.w600, color: AppColors.neutral100)) : null,
          ),
          if (verified)
            Positioned(
              top: -4,
              right: 8,
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(0xFF115E59),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 2, offset: Offset(0, 1))],
                ),
                child: const Icon(Icons.check, size: 16, color: Colors.white),
              ),
            ),
        ]),
        const SizedBox(height: 20),
        Text(name.isEmpty ? 'Host Profile' : name,
            textAlign: TextAlign.center,
            style: AppText.fraunces(size: sm ? 30 : 24, color: _forest, height: sm ? 1.2 : 32 / 24, letterSpacing: sm ? -0.75 : -0.6)),
        if (verified) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF7F4),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFD1EAE1)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.check_circle, size: 14, color: _green),
              const SizedBox(width: 6),
              Flexible(child: Text(t('StayHubVerifiedHost', 'Overený hostiteľ UK Stay Hub'), style: AppText.inter(size: 12, weight: FontWeight.w600, color: _forest))),
            ]),
          ),
        ],
        if (about.isNotEmpty) ...[
          const SizedBox(height: 24),
          Container(width: 64, height: 2, color: _green.withValues(alpha: 0.2)),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 384),
            child: Text('"$about"', textAlign: TextAlign.center, style: AppText.inter(size: 14, color: AppColors.neutral700, height: 1.625)),
          ),
        ],
        const SizedBox(height: 24),
        const Divider(height: 1, color: AppColors.neutral200),
        const SizedBox(height: 24),
        meta(Icons.chat_outlined, t('Language', 'Jazyk'), asString(h['languag']).isNotEmpty ? asString(h['languag']) : 'English'),
        const SizedBox(height: 16),
        meta(Icons.calendar_today_outlined, t('Joinedin', 'Pripojil sa v'), sinceText),
      ]),
    );
  }

  Widget _list(BuildContext context, Strings t, String name, List<Listing> items, bool loading, bool md, Object? error) {
    final sm = context.sm, xl = context.xl;
    final shown = items.take(_visible).toList();
    final gap = xl ? 32.0 : 24.0;
    final title = "${name.isEmpty ? 'Host' : name}'s ${t('listings', 'ponuky')}";
    final count = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.neutral100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.neutral200),
      ),
      child: Text('${items.length} ${items.length == 1 ? 'Stay' : 'Stays'}'.toUpperCase(),
          style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral800, letterSpacing: 0.6)),
    );
    final heading = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // md+: white, it sits over the banner.
      Text(title, style: AppText.fraunces(size: md ? 30 : 24, color: md ? Colors.white : _forest, height: md ? 1.2 : 32 / 24, letterSpacing: md ? -0.75 : -0.6)),
      const SizedBox(height: 4),
      Text(t('VerifiedAccommodations', 'Preskúmajte overené ubytovania ponúkané priamo týmto hostiteľom.'),
          style: AppText.inter(size: 14, color: md ? AppColors.neutral200 : AppColors.neutral600, height: 1.43)),
    ]);

    Widget cards() {
      if (!sm) {
        return Column(children: [
          for (var i = 0; i < shown.length; i++) ...[if (i > 0) SizedBox(height: gap), ResultCard(listing: shown[i], fill: false)],
        ]);
      }
      final rows = <Widget>[];
      for (var i = 0; i < shown.length; i += 2) {
        if (i > 0) rows.add(SizedBox(height: gap));
        rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: ResultCard(listing: shown[i], fill: false)),
          SizedBox(width: gap),
          Expanded(child: i + 1 < shown.length ? ResultCard(listing: shown[i + 1], fill: false) : const SizedBox.shrink()),
        ]));
      }
      return Column(children: rows);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.only(bottom: 20),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.neutral200))),
        child: sm
            ? Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(child: heading),
                const SizedBox(width: 8),
                count,
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [heading, const SizedBox(height: 8), count]),
      ),
      const SizedBox(height: 24),
      if (error != null && items.isEmpty)
        ErrorView(error: error, message: errorText(error), onRetry: () => ref.invalidate(_hostListingsProvider(widget.hostId)))
      else if (loading && items.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: LoadingView())
      else if (items.isEmpty)
        Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.neutral300),
          ),
          child: Column(children: [
            const SizedBox(height: 48),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.neutral50, shape: BoxShape.circle, border: Border.all(color: AppColors.neutral100)),
              child: const Icon(Icons.apartment_outlined, size: 40, color: AppColors.neutral500),
            ),
            const SizedBox(height: 16),
            Text(t('Noaccommodationsavailable', 'No current listings available for this host.'),
                textAlign: TextAlign.center, style: AppText.inter(size: 18, weight: FontWeight.w700, color: AppColors.neutral800)),
            const SizedBox(height: 48),
          ]),
        )
      else ...[
        cards(),
        if (_visible < items.length)
          Container(
            margin: const EdgeInsets.only(top: 48),
            padding: const EdgeInsets.only(top: 16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral200))),
            child: Center(
              child: GestureDetector(
                onTap: () => setState(() => _visible += 6),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: sm ? 24 : 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.neutral200),
                  ),
                  child: Text(t('Showmemore', 'Ukáž mi viac'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral700)),
                ),
              ),
            ),
          ),
      ],
    ]);
  }
}

/// `bg-[radial-gradient(#fff_1px,transparent_1px)] [background-size:16px_16px] opacity-10`
class _DotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x1AFFFFFF);
    for (var y = 8.0; y < size.height; y += 16) {
      for (var x = 8.0; x < size.width; x += 16) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

final _hostListingsProvider = FutureProvider.family<List<Listing>, String>((ref, id) => publicRepo.hostListings(id));

// ───────────────────────────── Review (/Review/:id) ─────────────────────────────
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.accommodationId});
  final String accommodationId;
  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  int _overall = 0;
  // Review.categoryRatings keys, exactly as the model names them.
  final Map<String, int> _cat = {
    'Location': 0,
    'Communication': 0,
    'Equipment': 0,
    'Cleanliness': 0,
    'ClientCare': 0,
    'WiFi': 0,
    'Activities': 0,
    'PriceQuality': 0,
  };
  final _text = TextEditingController();
  final _plus = TextEditingController();
  final _cons = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final a = ref.read(authProvider);
    _name.text = a.name;
    _email.text = a.email;
  }

  @override
  void dispose() {
    for (final c in [_text, _plus, _cons, _name, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    final t = ref.read(stringsProvider);
    if (_overall < 1) return toast(context, t.pick('Zvoľte celkové hodnotenie.', 'Choose an overall rating.'), error: true);
    if (_text.text.trim().isEmpty) return toast(context, t.pick('Napíšte text hodnotenia.', 'Please write your review.'), error: true);
    setState(() => _sending = true);
    try {
      await publicRepo.submitReview(widget.accommodationId, {
        'overallRating': _overall,
        'categoryRatings': {for (final e in _cat.entries) if (e.value > 0) e.key: e.value},
        'reviewText': _text.text.trim(),
        'pluses': _plus.text.trim(),
        'cons': _cons.text.trim(),
        'name': _name.text.trim(),
        'email': _email.text.trim(),
      });
      ref.invalidate(reviewsProvider(widget.accommodationId));
      if (!mounted) return;
      toast(context, t.pick('Ďakujeme za hodnotenie!', 'Thanks for your review!'));
      context.pop();
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _stars(int value, ValueChanged<int> onChanged, {double size = 34}) => Row(
        children: [
          for (var i = 1; i <= 5; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: i <= value ? AppColors.star : AppColors.neutral300),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final labels = {
      'Location': t.pick('Lokalita', 'Location'),
      'Communication': t.pick('Komunikácia', 'Communication'),
      'Equipment': t.pick('Vybavenie', 'Equipment'),
      'Cleanliness': t.pick('Čistota', 'Cleanliness'),
      'ClientCare': t.pick('Starostlivosť o hosťa', 'Guest care'),
      'WiFi': 'Wi-Fi',
      'Activities': t.pick('Aktivity v okolí', 'Activities'),
      'PriceQuality': t.pick('Pomer cena/kvalita', 'Value for money'),
    };
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(title: Text(t.pick('Ohodnoťte pobyt', 'Review your stay'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(t.pick('Celkové hodnotenie', 'Overall rating'), style: AppText.inter(size: 16, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        _stars(_overall, (v) => setState(() => _overall = v)),
        const SizedBox(height: 20),
        for (final e in labels.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(child: Text(e.value, style: AppText.inter(size: 14))),
              _stars(_cat[e.key]!, (v) => setState(() => _cat[e.key] = v), size: 26),
            ]),
          ),
        const SizedBox(height: 20),
        StayHubField(label: t.pick('Vaše hodnotenie', 'Your review'), controller: _text, maxLines: 5, required: true),
        const SizedBox(height: 14),
        StayHubField(label: t.pick('Čo sa vám páčilo', 'What you liked'), controller: _plus, maxLines: 2),
        const SizedBox(height: 14),
        StayHubField(label: t.pick('Čo by sa dalo zlepšiť', 'What could be better'), controller: _cons, maxLines: 2),
        const SizedBox(height: 14),
        StayHubField(label: t.pick('Meno', 'Name'), controller: _name),
        const SizedBox(height: 14),
        StayHubField(label: t('email', 'E-mail'), controller: _email, keyboard: TextInputType.emailAddress),
        const SizedBox(height: 24),
        PrimaryButton(label: t.pick('Odoslať hodnotenie', 'Submit review'), loading: _sending, onPressed: _send),
      ]),
    );
  }
}

class NotFoundScreen extends ConsumerWidget {
  const NotFoundScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    return Scaffold(
      backgroundColor: AppColors.cream,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Image.asset('assets/images/404.webp', height: 220),
            const SizedBox(height: 24),
            Text(t.pick('Stránka sa nenašla', 'Page not found'), style: AppText.fraunces(size: 26)),
            const SizedBox(height: 24),
            PrimaryButton(label: t('ReturnHome', 'Späť na úvod'), onPressed: () => context.go('/')),
          ]),
        ),
      ),
    );
  }
}
