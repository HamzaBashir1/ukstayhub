import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../../widgets/chrome.dart';
import '../../widgets/common.dart';
import '../../widgets/stay_card.dart';
import '../home/home_screen.dart' show openSearchSheet;
import 'stay_map.dart';
import '../../widgets/brand_logo_mark.dart';

const _green = Color(0xFF2C8360); // the map page's accent (#2C8360)

/// listing-stay-map (/mapa): ContentPage + HeroSection + TabFilters +
/// SectionGridHasMap, at every width the site supports.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _scroll = ScrollController();
  final _bodyKey = GlobalKey();
  final _resultsKey = GlobalKey();
  final _listKey = GlobalKey();

  List<Listing> _items = const [];
  int _page = 1;
  int _perPage = 6;
  int _total = 0;
  int _totalPages = 0;
  int? _totalReviews;
  double? _averageRating;
  bool _loading = false;
  Object? _error;
  Map<String, dynamic> _query = const {};
  int _generation = 0;

  /// xl+: where the sticky side map sits (null until measured).
  Rect? _mapRect;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_placeMap);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _perPage = _pageSizeFor(context.vw);
      _fetch(1);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // 12 results per page from 2xl (1536px), otherwise 6 (SectionGridHasMap).
  static int _pageSizeFor(double vw) => vw >= 1536 ? 12 : 6;

  Future<void> _fetch(int page) async {
    final s = ref.read(searchProvider);
    _query = s.toQuery();
    final gen = ++_generation;
    setState(() {
      _page = page;
      _loading = true;
      _error = null;
    });
    try {
      final res = await publicRepo.search({
        ..._query,
        'page': page,
        'limit': _perPage,
        'sortOption': s.filters.sort,
        'fields': 'card',
      });
      if (gen != _generation || !mounted) return;
      setState(() {
        _items = res.items;
        _total = res.totalCount;
        _totalPages = res.totalPages;
        _totalReviews = res.totalReviews;
        _averageRating = res.averageRating;
      });
    } catch (e) {
      if (gen == _generation && mounted) setState(() => _error = e);
    } finally {
      if (gen == _generation && mounted) {
        setState(() => _loading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _placeMap());
      }
    }
  }

  void _goToPage(int page) {
    _fetch(page);
    final ctx = _listKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    }
  }

  /// position: sticky for the xl side map – it rides along with the results
  /// section, pinned to the top of the viewport while the section is on screen.
  void _placeMap() {
    if (!mounted || !context.xl) {
      if (_mapRect != null) setState(() => _mapRect = null);
      return;
    }
    final body = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    final section = _resultsKey.currentContext?.findRenderObject() as RenderBox?;
    if (body == null || section == null || !body.attached || !section.attached) return;
    final top = section.localToGlobal(Offset.zero, ancestor: body).dy;
    final bottom = top + section.size.height;
    final viewport = body.size.height;
    final vw = body.size.width;
    final w = math.min(vw, 1940.0);
    final inner = w - 80; // px-10 on both sides
    final left = (vw - w) / 2 + 40 + inner * 0.6;
    final y = math.min(math.max(top, 0.0), bottom - viewport);
    final rect = Rect.fromLTWH(left, y, inner * 0.4, viewport);
    if (rect != _mapRect) setState(() => _mapRect = rect);
  }

  void _openFullMap() {
    final query = _query;
    final results = _items;
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (ctx) => Scaffold(
        body: Stack(children: [
          Positioned.fill(child: StayMap(query: query, resultListings: results)),
          Positioned(
            left: 12,
            top: 12 + MediaQuery.of(ctx).padding.top,
            child: Material(
              color: Colors.white,
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(ctx).pop(),
                child: const SizedBox(width: 40, height: 40, child: Icon(Icons.close, color: Colors.black)),
              ),
            ),
          ),
        ]),
      ),
    ));
  }

  void _openFilters({required bool full}) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 32),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 896), child: FiltersSheet(full: full)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);
    final lg = context.lg, xl = context.xl, md = context.md, sm = context.sm;

    ref.listen<SearchState>(searchProvider, (prev, next) {
      if (prev == null || prev.toQuery().toString() != next.toQuery().toString() || prev.filters.sort != next.filters.sort) {
        _fetch(1);
      }
    });
    final perPage = _pageSizeFor(context.vw);
    if (perPage != _perPage) {
      _perPage = perPage;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetch(1));
    }
    if (xl != (_mapRect != null)) WidgetsBinding.instance.addPostFrameCallback((_) => _placeMap());

    final region = s.destination?.type == 'region' ? s.destination : null;
    final hp = context.vw >= 1280 ? 40.0 : (lg ? 32.0 : (sm ? 24.0 : 16.0));

    final header = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1940),
        child: Padding(
          padding: lg ? const EdgeInsets.fromLTRB(40, 20, 40, 16) : const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _HeroStrip(total: _total, totalReviews: _totalReviews, averageRating: _averageRating),
            const SizedBox(height: 12),
            _FilterBar(onMoreFilters: () => _openFilters(full: !lg)),
          ]),
        ),
      ),
    );

    final results = Center(
      key: _resultsKey,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1940),
        child: Padding(
          padding: EdgeInsets.fromLTRB(hp, 0, hp, region != null ? 0 : (lg ? 80 : 64)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: xl ? 60 : 100,
              child: Padding(
                padding: EdgeInsets.only(top: lg ? 20 : (md ? 16 : 12), right: xl ? 32 : 0),
                child: _buildResults(t, s),
              ),
            ),
            // The side map is painted on top (see _mapRect); this keeps its column.
            if (xl) const Spacer(flex: 40),
          ]),
        ),
      ),
    );

    final scroll = CustomScrollView(
      controller: _scroll,
      slivers: [
        if (!lg)
          SliverAppBar(
            floating: true,
            snap: true,
            automaticallyImplyLeading: false,
            toolbarHeight: 80,
            titleSpacing: 0,
            backgroundColor: Colors.white.withValues(alpha: 0.85),
            surfaceTintColor: Colors.transparent,
            elevation: 2,
            shadowColor: const Color(0x1A000000),
            actions: const [SizedBox.shrink()],
            title: const MobileSearchHeader(),
          ),
        SliverToBoxAdapter(child: header),
        SliverToBoxAdapter(child: results),
        if (region != null && region.regionId != null)
          SliverToBoxAdapter(
            child: _RegionSection(
              regionId: region.regionId!,
              total: _total,
              hp: hp,
              onBrowse: () {
                final ctx = _listKey.currentContext;
                if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 400));
              },
            ),
          ),
        const SliverToBoxAdapter(child: StayHubFooter()),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: lg ? const StayHubHeader(mapSearch: true) : null,
      endDrawer: const StayHubDrawer(),
      bottomNavigationBar: md ? null : const FooterNav(),
      body: SafeArea(
        top: !lg,
        bottom: false,
        child: Stack(key: _bodyKey, children: [
          NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _placeMap());
              return false;
            },
            child: scroll,
          ),
          if (xl && _mapRect != null)
            Positioned.fromRect(
              rect: _mapRect!,
              child: ClipRRect(borderRadius: BorderRadius.circular(6), child: StayMap(query: _query, resultListings: _items)),
            ),
          if (!xl)
            Positioned(
              left: 0,
              right: 0,
              bottom: md ? 40 : 24,
              child: Center(child: _MapButton(label: t.pick('Mapa', 'Map'), onTap: _openFullMap)),
            ),
        ]),
      ),
    );
  }

  Widget _buildResults(Strings t, SearchState s) {
    final vw = context.vw, xl = context.xl, lg = context.lg, sm = context.sm, md = context.md;
    final cols = xl ? 2 : (lg ? 3 : (sm ? 2 : 1));
    final gapX = vw >= 1536 ? 20.0 : 16.0;
    final stripGap = lg ? 24.0 : (sm ? 20.0 : 16.0);

    final Widget body;
    if (_error != null && _items.isEmpty && !_loading) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: ErrorView(error: _error!, message: errorText(_error!), onRetry: () => _fetch(_page), retryLabel: t.pick('Skúsiť znova', 'Try again')),
      );
    } else if (_loading) {
      body = _CardGrid(cols: cols, gapX: gapX, children: List.generate(_perPage, (_) => const StayCardSkeleton()));
    } else if (_items.isEmpty) {
      body = _EmptyResults(destination: s.destination);
    } else {
      body = _CardGrid(cols: cols, gapX: gapX, children: [for (final l in _items) ResultCard(listing: l)]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_items.isNotEmpty && !_loading)
        Padding(padding: EdgeInsets.only(bottom: stripGap), child: _ResultsStrip(count: _total == 0 ? _items.length : _total))
      else if (_loading)
        SizedBox(height: 20 + stripGap),
      Padding(
        key: _listKey,
        padding: EdgeInsets.only(bottom: md ? 48 : 32),
        child: body,
      ),
      const SizedBox(height: 20),
      Center(child: _Pagination(current: _page, total: _totalPages, onPage: _goToPage)),
    ]);
  }
}

// ───────────────────────────── Mobile chrome ─────────────────────────────

/// HeroSearchForm2Mobile + MenuBar: logo, search summary pill, burger.
class MobileSearchHeader extends ConsumerWidget {
  const MobileSearchHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);
    String d(DateTime x) => '${x.day}.${x.month}.';
    final dest = s.destination?.label ?? t('Anywhere', 'Kdekoľvek');
    final dates = s.checkIn != null && s.checkOut != null ? '${d(s.checkIn!)} – ${d(s.checkOut!)}' : t('Anyweek', 'Akýkoľvek týždeň');
    final guests = s.guests.total > 0
        ? '${s.guests.total} ${t.isEn ? (s.guests.total == 1 ? 'guest' : 'guests') : 'hostia'}'
        : t('Addguests', 'Pridať hostí');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        GestureDetector(
          onTap: () => context.go('/'),
          child: const StayHubMark(size: 40),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Material(
            color: Colors.white,
            shape: const StadiumBorder(side: BorderSide(color: AppColors.fieldBorder)),
            shadowColor: const Color(0x59112A22),
            elevation: 3,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => openSearchSheet(context, ref),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  const Icon(Icons.search, size: 20, color: AppColors.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(dest,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.forestDark, height: 20 / 14)),
                      const SizedBox(height: 2),
                      Text('$dates · $guests',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.inter(size: 12, weight: FontWeight.w300, color: AppColors.neutral500, height: 16 / 12)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
        Builder(
          builder: (ctx) => IconButton(
            onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            icon: const Icon(Icons.menu_rounded, size: 32, color: AppColors.neutral700),
          ),
        ),
      ]),
    );
  }
}

/// Shared/FooterNav.js – the bottom bar below md: Explore, Profile/Login, Menu.
class FooterNav extends ConsumerWidget {
  const FooterNav({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);

    Widget item(IconData icon, String label, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 24, color: AppColors.neutral500),
              const SizedBox(height: 4),
              Text(label, style: AppText.inter(size: 11, color: AppColors.neutral500, height: 1)),
            ]),
          ),
        );

    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.neutral300))),
      padding: const EdgeInsets.all(8),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 512),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              item(Icons.search, t('Explore', 'Preskúmať'), () => openSearchSheet(context, ref)),
              if (auth.loggedIn)
                item(Icons.account_circle_outlined, t('Profile', 'Profil'), () => context.go(auth.isHost ? '/host' : '/guest'))
              else
                item(Icons.account_circle_outlined, t('login', 'Prihlásiť sa'), () => context.push('/login')),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Builder(builder: (ctx) => item(Icons.menu_rounded, t('Menu', 'Menu'), () => Scaffold.of(ctx).openEndDrawer())),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF171717),
        shape: const StadiumBorder(),
        elevation: 10,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.map_outlined, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Text(label, style: AppText.inter(size: 14, weight: FontWeight.w600, color: Colors.white)),
              ]),
            ),
          ),
        ),
      );
}

// ───────────────────────────── HeroSection ─────────────────────────────

/// "4,700" – British English thousands separator.
String _fmtNum(int n) => NumberFormat.decimalPattern('en_GB').format(n);

class _HeroStrip extends ConsumerWidget {
  const _HeroStrip({required this.total, this.totalReviews, this.averageRating});
  final int total;
  final int? totalReviews;
  final double? averageRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);
    final sm = context.sm, lg = context.lg;
    final title = s.destination?.label.isNotEmpty == true ? s.destination!.label : 'London';

    final heading = Text(title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.fraunces(size: sm ? 30 : 24, color: AppColors.forestDark, height: 1.25, letterSpacing: -0.025 * (sm ? 30 : 24)));
    final count = Row(mainAxisSize: MainAxisSize.min, children: [
      Text(total > 0 ? _fmtNum(total) : '', style: AppText.dmSans(size: sm ? 15 : 14, weight: FontWeight.w600, color: AppColors.greenText)),
      const SizedBox(width: 6),
      Text(t('properties', 'ubytovaní'), style: AppText.dmSans(size: sm ? 15 : 14, weight: FontWeight.w400, color: AppColors.mutedGreen)),
    ]);

    final Widget titleBlock = sm && !lg
        ? Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(child: heading),
            const SizedBox(width: 8),
            count,
          ])
        : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            heading,
            const SizedBox(height: 4),
            count,
          ]);

    if (!lg) return Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: titleBlock);

    final rating = averageRating != null && averageRating! > 0 ? averageRating!.toStringAsFixed(1) : '4.8';
    final reviews = totalReviews != null ? '${_fmtNum(totalReviews!)}+' : '1 200+';
    final en = t.isEn;
    Widget badge(List<Widget> children, {double px = 12}) => Container(
          padding: EdgeInsets.symmetric(horizontal: px, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.fieldBorder),
            boxShadow: const [BoxShadow(color: Color(0x14112A22), blurRadius: 8, spreadRadius: -4, offset: Offset(0, 2))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        );
    Widget pill(IconData icon, String label) => badge([
          Icon(icon, size: 14, color: AppColors.green),
          const SizedBox(width: 6),
          Text(label, style: AppText.dmSans(size: 12.5, weight: FontWeight.w600, color: AppColors.mutedGreen, height: 1)),
        ]);

    final badges = Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 10, children: [
      badge(px: 10, [
        const Icon(Icons.star_rounded, size: 16, color: AppColors.star),
        const SizedBox(width: 4),
        Text(rating, style: AppText.inter(size: 13, weight: FontWeight.w700, color: AppColors.forestDark, height: 1)),
        const SizedBox(width: 4),
        Text('·', style: AppText.inter(size: 10, weight: FontWeight.w700, color: const Color(0xFF849B90), height: 1)),
        const SizedBox(width: 4),
        Text('$reviews ${t('Hero_RatingLabel', 'hodnotení')}',
            style: AppText.inter(size: 12.5, weight: FontWeight.w600, color: AppColors.mutedGreen, height: 1)),
      ]),
      pill(Icons.toll_outlined, en ? '£0 service fee' : '£0 servisný poplatok'),
      pill(Icons.verified_outlined, en ? 'Verified photos' : 'Fotky overené tímom'),
      pill(Icons.forum_outlined, en ? 'Support daily 08:00–18:00' : 'Podpora denne 8:00 – 18:00'),
    ]);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        Flexible(child: titleBlock),
        const SizedBox(width: 12),
        Expanded(child: badges),
      ]),
    );
  }
}

// ───────────────────────────── TabFilters ─────────────────────────────

/// The pill button every filter control uses (border turns green when active).
class _FilterPill extends StatelessWidget {
  const _FilterPill({required this.label, required this.active, required this.onTap, this.icon, this.chevron = false, this.expand = false});
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;
  final bool chevron;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final fg = active ? _green : AppColors.neutral700;
    return Material(
      color: active ? _green.withValues(alpha: 0.05) : Colors.white,
      shape: StadiumBorder(side: BorderSide(color: active ? _green : AppColors.neutral200)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        hoverColor: _green.withValues(alpha: 0.04),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, color: fg))),
                if (chevron) ...[const SizedBox(width: 8), Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: fg)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// White popover card with a grey Clear / Apply footer (Popover.Panel).
class _Panel extends StatelessWidget {
  const _Panel({required this.children, required this.onClear, required this.onApply});
  final List<Widget> children;
  final VoidCallback onClear;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) => Container(
        width: 448,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.neutral200),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 20), children[i]],
            ]),
          ),
          Container(
            color: AppColors.neutral50,
            padding: const EdgeInsets.all(20),
            child: _ClearApply(onClear: onClear, onApply: onApply),
          ),
        ]),
      );
}

class _ClearApply extends ConsumerWidget {
  const _ClearApply({required this.onClear, required this.onApply});
  final VoidCallback onClear;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    return Row(children: [
      OutlinedButton(
        onPressed: onClear,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.neutral700,
          backgroundColor: Colors.white,
          side: const BorderSide(color: AppColors.neutral200),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const StadiumBorder(),
        ),
        child: Text(t('Clear', 'Vyčistiť'), style: AppText.inter(size: 14, weight: FontWeight.w500)),
      ),
      const Spacer(),
      FilledButton(
        onPressed: onApply,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.green,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const StadiumBorder(),
        ),
        child: Text(t('Apply', 'Použiť'),
            style: AppText.inter(size: 14, weight: FontWeight.w500, color: Colors.white)),
      ),
    ]);
  }
}

/// RENTAL_FORM_DESCRIPTIONS in TabFilters.js.
const _rentalFormDescriptions = {
  'Entire place': ('Majte miesto len pre seba', 'Have a place to yourself'),
  'Private room': ('Majte vlastnú izbu a zdieľajte spoločné priestory', 'Have your own room and share some common spaces'),
  'Share room': ('Zostaňte v spoločnom priestore, napríklad v spoločenskej miestnosti', 'Stay in a shared space, like a common room'),
};

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.checked, required this.onChanged, this.subLabel});
  final String label;
  final String? subLabel;
  final bool checked;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onChanged,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: checked,
              onChanged: (_) => onChanged(),
              activeColor: AppColors.green,
              side: const BorderSide(color: AppColors.neutral400),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.inter(size: 15, weight: FontWeight.w500, color: AppColors.neutral900)),
              if (subLabel != null && subLabel!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(subLabel!, style: AppText.inter(size: 14, color: AppColors.neutral500)),
              ],
            ]),
          ),
        ]),
      );
}

class _FilterBar extends ConsumerStatefulWidget {
  const _FilterBar({required this.onMoreFilters});
  final VoidCallback onMoreFilters;
  @override
  ConsumerState<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends ConsumerState<_FilterBar> {
  final _typeMenu = MenuController();
  final _roomsMenu = MenuController();
  final _sortMenu = MenuController();
  String _type = '';
  int _beds = 0, _bedrooms = 0, _bathrooms = 0;

  SearchFilters get _f => ref.read(searchProvider).filters;
  void _apply(SearchFilters f) => ref.read(searchProvider.notifier).setFilters(f);

  Widget _sortButton(Strings t, {bool expand = false}) => MenuAnchor(
        controller: _sortMenu,
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.white),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.neutral100))),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
        ),
        menuChildren: [
          for (final (key, label) in [('lowToHigh', t('LowtoHigh', 'Od najnižšej')), ('highToLow', t('HightoLow', 'Od najvyššej'))])
            MenuItemButton(
              onPressed: () => _apply(_f.copyWith(sort: key)),
              child: SizedBox(width: 128, child: Text(label, style: AppText.inter(size: 15, color: AppColors.neutral900))),
            ),
        ],
        builder: (_, c, __) => _FilterPill(
          label: t('Sort', 'Triediť'),
          icon: Icons.swap_vert_rounded,
          active: c.isOpen,
          expand: expand,
          onTap: () => c.isOpen ? c.close() : c.open(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final f = ref.watch(searchProvider).filters;
    final count = f.activeCount;
    final more = count > 0 ? '${t('Morefilters', 'Viac filtrov')} ($count)' : t('Morefilters', 'Viac filtrov');
    final opts = ref.watch(optionsProvider).valueOrNull;

    if (!context.lg) {
      // Mobile: More filters + Sort, then the quick property-type chips.
      final chips = t.isEn
          ? const [('All', <String>[]), ('Apartment', ['Apartment']), ('House', _houseTypes), ('Cottage', ['Cottages'])]
          : const [('Všetky', <String>[]), ('Apartmán', ['Apartment']), ('Dom', _houseTypes), ('Chata', ['Cottages'])];
      final selected = f.propertyTypes;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Row(children: [
            Expanded(child: _FilterPill(label: more, active: count > 0, expand: true, onTap: widget.onMoreFilters)),
            const SizedBox(width: 12),
            Expanded(child: _sortButton(t, expand: true)),
          ]),
        ),
        SizedBox(
          height: 36 + 12,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
            itemCount: chips.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final (label, keys) = chips[i];
              final on = keys.isEmpty ? selected.isEmpty : (keys.length == selected.length && keys.every(selected.contains));
              return Material(
                color: on ? _green : Colors.white,
                shape: StadiumBorder(side: BorderSide(color: on ? _green : AppColors.neutral200)),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => _apply(_f.copyWith(propertyType: keys.join(','))),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Text(label,
                          style: AppText.inter(size: 12, weight: FontWeight.w600, color: on ? Colors.white : AppColors.neutral600)),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ]);
    }

    MenuStyle panelStyle() => const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(Color(0x40000000)),
          elevation: WidgetStatePropertyAll(12),
          padding: WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
        );

    final forms = asMapList(opts?['RENTAL_FORMS']);
    final type = MenuAnchor(
      controller: _typeMenu,
      style: panelStyle(),
      alignmentOffset: const Offset(0, 12),
      onOpen: () => setState(() => _type = _f.rentalForm),
      menuChildren: [
        StatefulBuilder(
          builder: (_, setLocal) => _Panel(
            onClear: () {
              setLocal(() => _type = '');
              _apply(_f.copyWith(rentalForm: ''));
            },
            onApply: () {
              _apply(_f.copyWith(rentalForm: _type));
              _typeMenu.close();
            },
            children: [
              for (final o in forms)
                _CheckRow(
                  label: optLabel(o, t.lang),
                  subLabel: t.isEn ? _rentalFormDescriptions[asString(o['en'])]?.$2 : _rentalFormDescriptions[asString(o['en'])]?.$1,
                  checked: _type == asString(o['en']),
                  onChanged: () => setLocal(() => _type = _type == asString(o['en']) ? '' : asString(o['en'])),
                ),
            ],
          ),
        ),
      ],
      builder: (_, c, __) => _FilterPill(
        label: t('Typeofplace', 'Typ miesta'),
        chevron: true,
        active: c.isOpen || f.rentalForm.isNotEmpty,
        onTap: () => c.isOpen ? c.close() : c.open(),
      ),
    );

    final rooms = MenuAnchor(
      controller: _roomsMenu,
      style: panelStyle(),
      alignmentOffset: const Offset(0, 12),
      onOpen: () => setState(() {
        _beds = _f.beds;
        _bedrooms = _f.bedrooms;
        _bathrooms = _f.bathrooms;
      }),
      menuChildren: [
        StatefulBuilder(
          builder: (_, setLocal) => _Panel(
            onClear: () {
              setLocal(() => _beds = _bedrooms = _bathrooms = 0);
              _apply(_f.copyWith(beds: 0, bedrooms: 0, bathrooms: 0));
            },
            onApply: () {
              _apply(_f.copyWith(beds: _beds, bedrooms: _bedrooms, bathrooms: _bathrooms));
              _roomsMenu.close();
            },
            children: [
              Counter(label: t('Beds', 'Postele'), value: _beds, max: 100, onChanged: (v) => setLocal(() => _beds = v)),
              Counter(label: t('Bedrooms', 'Spálne'), value: _bedrooms, max: 100, onChanged: (v) => setLocal(() => _bedrooms = v)),
              Counter(label: t('Bathrooms', 'Kúpeľne'), value: _bathrooms, max: 100, onChanged: (v) => setLocal(() => _bathrooms = v)),
            ],
          ),
        ),
      ],
      builder: (_, c, __) => _FilterPill(
        label: t('RoomsofBeds', 'Izby a postele'),
        chevron: true,
        active: c.isOpen || f.beds > 0 || f.bedrooms > 0 || f.bathrooms > 0,
        onTap: () => c.isOpen ? c.close() : c.open(),
      ),
    );

    return Row(children: [
      type,
      const SizedBox(width: 16),
      rooms,
      const SizedBox(width: 16),
      _FilterPill(label: more, active: count > 0, onTap: widget.onMoreFilters),
      const SizedBox(width: 16),
      _sortButton(t),
    ]);
  }
}

/// The "Dom" quick chip: every house-like PROPERTY_TYPES value.
const _houseTypes = ['Entire Homes', 'Nature House', 'Wooden House', 'Dome House', 'Wooden Houses'];

// ───────────────────────────── More filters (TabFilters modal) ─────────────────────────────
class FiltersSheet extends ConsumerStatefulWidget {
  const FiltersSheet({super.key, this.full = true});

  /// Phones get Type of place, Price range and Rooms here too; on desktop those
  /// live in the filter bar (and the site has no price filter there).
  final bool full;

  @override
  ConsumerState<FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends ConsumerState<FiltersSheet> {
  late SearchFilters _f = ref.read(searchProvider).filters;
  static const _maxPrice = 2000.0;

  void _toggle(String key, String value) {
    if (key == 'propertyType') {
      final set = _f.propertyTypes;
      set.contains(value) ? set.remove(value) : set.add(value);
      setState(() => _f = _f.copyWith(propertyType: set.join(',')));
      return;
    }
    final m = {for (final e in _f.multi.entries) e.key: {...e.value}};
    final set = m.putIfAbsent(key, () => <String>{});
    set.contains(value) ? set.remove(value) : set.add(value);
    setState(() => _f = _f.copyWith(multi: m));
  }

  bool _on(String key, String value) =>
      key == 'propertyType' ? _f.propertyTypes.contains(value) : (_f.multi[key]?.contains(value) ?? false);

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final opts = ref.watch(optionsProvider).valueOrNull;
    final sm = context.sm;
    final lang = t.lang;

    Widget section(String title, Widget child) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: AppText.inter(size: 20, weight: FontWeight.w500, color: AppColors.neutral900)),
            const SizedBox(height: 24),
            child,
          ]),
        );

    Widget checks(String key, List<Json> options, {List<String> omit = const []}) {
      final list = options.where((o) => !omit.contains(asString(o['en']))).toList();
      final cols = sm ? 3 : 2;
      return LayoutBuilder(builder: (_, c) {
        final w = (c.maxWidth - (cols - 1) * 16) / cols;
        return Wrap(spacing: 16, runSpacing: 16, children: [
          for (final o in list)
            SizedBox(
              width: w,
              child: InkWell(
                onTap: () => _toggle(key, asString(o['en'])),
                child: Row(children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Checkbox(
                      value: _on(key, asString(o['en'])),
                      onChanged: (_) => _toggle(key, asString(o['en'])),
                      activeColor: AppColors.green,
                      side: const BorderSide(color: Color(0xFFD1D5DB)),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(optLabel(o, lang), style: AppText.inter(size: 15, color: AppColors.neutral900))),
                ]),
              ),
            ),
        ]);
      });
    }

    final List<Widget> sections;
    if (opts == null) {
      sections = const [Padding(padding: EdgeInsets.all(40), child: LoadingView())];
    } else {
      final groups = {for (final g in asMapList(opts['AMENITY_GROUPS'])) asString(g['name']): asMapList(g['options'])};
      final min = _f.minPrice ?? 0;
      final max = _f.maxPrice ?? _maxPrice;
      Widget priceBox(String label, num v) => Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral700)),
              const SizedBox(height: 4),
              Container(
                height: 42,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.neutral200),
                ),
                child: Text('£ ${v.round()}', style: AppText.inter(size: 14, color: AppColors.neutral900)),
              ),
            ]),
          );

      sections = [
        if (widget.full) ...[
          section(
            t('Typeofplace', 'Typ miesta'),
            Column(children: [
              for (final o in asMapList(opts['RENTAL_FORMS'])) ...[
                _CheckRow(
                  label: optLabel(o, lang),
                  subLabel: t.isEn ? _rentalFormDescriptions[asString(o['en'])]?.$2 : _rentalFormDescriptions[asString(o['en'])]?.$1,
                  checked: _f.rentalForm == asString(o['en']),
                  onChanged: () => setState(() =>
                      _f = _f.copyWith(rentalForm: _f.rentalForm == asString(o['en']) ? '' : asString(o['en']))),
                ),
                const SizedBox(height: 20),
              ],
            ]),
          ),
          section(
            t('RangePrices', 'Rozsah cien'),
            Column(children: [
              RangeSlider(
                values: RangeValues(min.toDouble().clamp(0, _maxPrice), max.toDouble().clamp(0, _maxPrice)),
                max: _maxPrice,
                activeColor: AppColors.green,
                onChanged: (v) => setState(() => _f = SearchFilters(
                      minPrice: v.start <= 0 ? null : v.start.roundToDouble(),
                      maxPrice: v.end >= _maxPrice ? null : v.end.roundToDouble(),
                      propertyType: _f.propertyType,
                      rentalForm: _f.rentalForm,
                      beds: _f.beds,
                      bedrooms: _f.bedrooms,
                      bathrooms: _f.bathrooms,
                      multi: _f.multi,
                      sort: _f.sort,
                    )),
              ),
              const SizedBox(height: 24),
              Row(children: [
                priceBox(t('Minprice', 'Minimálna cena'), min),
                const SizedBox(width: 20),
                priceBox(t('Maxprice', 'Maximálna cena'), max),
              ]),
            ]),
          ),
          section(
            t('Roomsandbeds', 'Izby a postele'),
            Column(children: [
              Counter(label: t('Beds', 'Postele'), value: _f.beds, max: 100, onChanged: (v) => setState(() => _f = _f.copyWith(beds: v))),
              const SizedBox(height: 20),
              Counter(
                  label: t('Bedrooms', 'Spálne'),
                  value: _f.bedrooms,
                  max: 100,
                  onChanged: (v) => setState(() => _f = _f.copyWith(bedrooms: v))),
              const SizedBox(height: 20),
              Counter(
                  label: t('Bathrooms', 'Kúpeľne'),
                  value: _f.bathrooms,
                  max: 100,
                  onChanged: (v) => setState(() => _f = _f.copyWith(bathrooms: v))),
            ]),
          ),
        ],
        section(t('Services', 'Služby'), checks('services', groups['services'] ?? const [])),
        section(t('Bathroom', 'Kúpeľňa'), checks('bathroomAmenities', groups['bathroomAmenities'] ?? const [])),
        section(t('KitchenandDining', 'Kuchyňa a jedáleň'), checks('kitchenDiningAmenities', groups['kitchenDiningAmenities'] ?? const [])),
        section(t('HeatingandCooling', 'Kúrenie a chladenie'), checks('heatingCoolingAmenities', groups['heatingCoolingAmenities'] ?? const [])),
        section(t('HomeSafety', 'Bezpečnosť domova'), checks('safetyAmenities', groups['safetyAmenities'] ?? const [])),
        // "None" means "no wellness/outdoor amenities"; nothing to search for.
        section(t('WellnessSpa', 'Wellness & Spa'), checks('wellnessAmenities', groups['wellnessAmenities'] ?? const [], omit: const ['None'])),
        section(t('Outdoor', 'Vonkajšie priestory'), checks('outdoorAmenities', groups['outdoorAmenities'] ?? const [], omit: const ['None'])),
        section(t('ParkingandFacilities', 'Parkovanie a zariadenia'), checks('parkingFacilities', groups['parkingFacilities'] ?? const [])),
        section(t('Checkin', 'Check-in'), checks('checkIn', asMapList(opts['CHECK_IN_METHODS']))),
        section(t('Meals', 'Jedlá'), checks('meals', asMapList(opts['MEALS']))),
        section(t('Propertytype', 'Typ nehnuteľnosti'), checks('propertyType', asMapList(opts['PROPERTY_TYPES']))),
        section(t('Pets', 'Domáce zvieratá'), checks('pet', asMapList(opts['PET_OPTIONS']))),
        section(t('Partyorganizing', 'Organizovanie párty'), checks('partyOrganizing', asMapList(opts['PARTY_OPTIONS']))),
        section(t('Smoking', 'Fajčenie'), checks('smoking', asMapList(opts['SMOKING_OPTIONS']))),
      ];
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.neutral200))),
        child: Stack(alignment: Alignment.center, children: [
          Text(t('Morefilters', 'Viac filtrov'), style: AppText.inter(size: 18, weight: FontWeight.w500, color: const Color(0xFF111827))),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              tooltip: t.pick('Zavrieť', 'Close'),
              icon: const Icon(Icons.close, size: 24, color: AppColors.neutral700),
            ),
          ),
        ]),
      ),
      Flexible(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.symmetric(horizontal: sm ? 24 : 16),
          children: [
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.neutral200),
              sections[i],
            ],
          ],
        ),
      ),
      Container(
        color: AppColors.neutral50,
        padding: const EdgeInsets.all(20),
        child: _ClearApply(
          onClear: () => setState(() => _f = SearchFilters(sort: _f.sort)),
          onApply: () {
            ref.read(searchProvider.notifier).setFilters(_f);
            Navigator.of(context).pop();
          },
        ),
      ),
    ]);
  }
}

// ───────────────────────────── Results ─────────────────────────────

class _ResultsStrip extends ConsumerWidget {
  const _ResultsStrip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final en = t.isEn;
    final grey = AppText.inter(size: 14, color: AppColors.neutral500, height: 20 / 14);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 4, children: [
      Text('$count', style: AppText.inter(size: 14, weight: FontWeight.w600, color: _green, height: 20 / 14)),
      Text(en ? 'verified properties' : 'overených ubytovaní', style: grey),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text('·', style: grey.copyWith(color: AppColors.neutral300)),
      ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_rounded, size: 13, color: _green),
        const SizedBox(width: 4),
        Text(en ? 'All prices are final – no fees' : 'Všetky ceny sú finálne – bez poplatkov', style: grey),
      ]),
    ]);
  }
}

/// grid-cols-* gap-x-4 2xl:gap-x-5 gap-y-6, every card in a row the same height.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.cols, required this.gapX, required this.children});
  final int cols;
  final double gapX;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += cols) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 24));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var j = 0; j < cols; j++) ...[
            if (j > 0) SizedBox(width: gapX),
            Expanded(child: i + j < children.length ? children[i + j] : const SizedBox.shrink()),
          ],
        ]),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// listing-stay-map/component/StayCardFeatured.js
class ResultCard extends ConsumerWidget {
  const ResultCard({super.key, required this.listing, this.fill = true});
  final Listing listing;
  /// true: stretch to a bounded grid cell (search). false: natural height (inside a scroll view).
  final bool fill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);
    final sm = context.sm;
    final en = t.isEn;
    final rating = listing.rating;
    final reviews = listing.reviewCount;
    final price = listing.pricePerNight;
    void open() => context.push('/listings/${listing.slug}');

    // getContextBadge
    final (String, Color)? badge = rating >= 4.9 && reviews > 0
        ? (en ? 'Popular' : 'Obľúbené', _green)
        : reviews == 0
            ? (en ? 'New' : 'Nové', AppColors.forest)
            : price > 0 && price <= 75
                ? (en ? 'Great value' : 'Výhodná cena', const Color(0xFFB45309))
                : null;

    final c = listing.country.trim().toLowerCase();
    final country = c.isEmpty || c == 'uk' || c == 'gb' || c == 'great britain' || c == 'united kingdom' || c == 'england'
        ? 'United Kingdom'
        : listing.country;

    final view = Material(
      color: AppColors.forest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(12),
        hoverColor: _green,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(en ? 'View' : 'Zobraziť', style: AppText.inter(size: 13, weight: FontWeight.w600, color: Colors.white)),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward, size: 14, color: Colors.white.withValues(alpha: 0.7)),
            ]),
          ),
        ),
      ),
    );

    final priceBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('£${price.round()}',
            style: AppText.inter(size: sm ? 22 : 20, weight: FontWeight.w700, color: AppColors.neutral900, letterSpacing: -0.5)),
        const SizedBox(width: 4),
        Text('/${t('night', 'noc')}', style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500)),
      ]),
      const SizedBox(height: 2),
      Text(en ? 'Final price, no fees' : 'Konečná cena bez poplatkov',
          style: AppText.inter(size: 11, weight: FontWeight.w600, color: _green)),
    ]);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 1,
      shadowColor: const Color(0x0D000000),
      child: InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.neutral200),
          ),
          child: Column(mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Stack(children: [
              Container(
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.neutral100))),
                child: GallerySlider(
                  images: listing.images.take(8).toList(),
                  aspectRatio: 4 / 3,
                  radius: const BorderRadius.vertical(top: Radius.circular(15)),
                  onTap: open,
                ),
              ),
              Positioned(top: 12, right: 12, child: FavoriteButton(listingId: listing.id, size: 44)),
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_rounded, size: 12, color: Color(0xFF0A7F3F)),
                    const SizedBox(width: 6),
                    Text(t('StayHubVerified', 'UK Stay Hub overené'),
                        style: AppText.inter(size: 11, weight: FontWeight.w600, color: AppColors.forest)),
                  ]),
                ),
              ),
              if (badge != null)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: badge.$2, borderRadius: BorderRadius.circular(6)),
                    child: Text(badge.$1, style: AppText.inter(size: 11, weight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
            ]),
            _fit(
              Padding(
                padding: EdgeInsets.all(sm ? 20 : 16),
                child: Column(mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(listing.name(t.lang),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.fraunces(size: sm ? 17 : 16, color: AppColors.neutral900, height: 1.375)),
                        const SizedBox(height: 4),
                        Text([if (listing.city.isNotEmpty) listing.city, country].join(', '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500)),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFBBF24)),
                        const SizedBox(width: 4),
                        rating > 0
                            ? Text(rating.toStringAsFixed(1),
                                style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral900))
                            : Text(t('New', 'Nové'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: AppColors.neutral500)),
                      ]),
                      if (reviews > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          '$reviews ${reviews == 1 ? (en ? 'review' : 'recenzia') : (en ? 'reviews' : 'recenzií')}',
                          style: AppText.inter(
                              size: 11,
                              color: AppColors.neutral500,
                              decoration: TextDecoration.underline),
                        ),
                      ],
                    ]),
                  ]),
                  if (s.hasDates) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: const Color(0x99E8F5EF), borderRadius: BorderRadius.circular(6)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 16,
                          height: 16,
                          decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                          child: const Icon(Icons.check_rounded, size: 10, color: Colors.white),
                        ),
                        const SizedBox(width: 8),
                        Text(en ? 'Available for selected dates' : 'Dostupné vo vybranom termíne',
                            style: AppText.inter(size: 12, weight: FontWeight.w600, color: const Color(0xFF1F7559))),
                      ]),
                    ),
                  ],
                  if (fill) const Spacer(),
                  const SizedBox(height: 16),
                  // flex-wrap on phones: the button drops below the price, full width.
                  if (sm)
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: priceBlock), const SizedBox(width: 12), view])
                  else
                    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Align(alignment: Alignment.centerLeft, child: priceBlock),
                      const SizedBox(height: 12),
                      view,
                    ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _fit(Widget child) => fill ? Expanded(child: child) : child;
}

class _EmptyResults extends ConsumerWidget {
  const _EmptyResults({required this.destination});
  final Destination? destination;

  // suggestNearbyAreas in SectionGridHasMap.
  static const _nearby = {
    'westminster': ['Soho', 'Marylebone', 'Covent Garden'],
    'camden': ['Kings Cross', 'Islington', 'Hampstead'],
    'kensington': ['Chelsea', 'Notting Hill', 'Earls Court'],
    'shoreditch': ['Hackney', 'Spitalfields', 'Islington'],
    'greenwich': ['Canary Wharf', 'Deptford', 'Blackheath'],
    'southwark': ['Bermondsey', 'Waterloo', 'London Bridge'],
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final en = t.isEn;
    final d = destination;
    final city = d != null && d.type == 'city' ? d.label : '';
    final place = (d?.label.isNotEmpty ?? false) ? d!.label : 'London';
    var areas = const ['Westminster', 'Camden', 'Kensington'];
    final key = searchKey(city);
    if (key.isNotEmpty) {
      for (final e in _nearby.entries) {
        if (key.contains(e.key)) areas = e.value;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
      child: Column(children: [
        Text(
          en
              ? 'Unfortunately, we currently don’t have this type of accommodation in “$place”.'
              : 'Žiaľ, momentálne nemáme takéto ubytovanie v oblasti „$place“.',
          textAlign: TextAlign.center,
          style: AppText.inter(size: 20, weight: FontWeight.w600, color: AppColors.neutral700, height: 1.4),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 448),
          child: Text(
            en ? 'Don’t worry — you might love one of these nearby places instead:' : 'Ale nezúfajte – možno si zamilujete tieto blízke miesta:',
            textAlign: TextAlign.center,
            style: AppText.inter(size: 14, color: AppColors.neutral500),
          ),
        ),
        const SizedBox(height: 24),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          for (final a in areas)
            OutlinedButton(
              onPressed: () => ref.read(searchProvider.notifier).setDestination(Destination.city(a)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.neutral900,
                side: const BorderSide(color: AppColors.neutral300),
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: Text(a, style: AppText.inter(size: 14, weight: FontWeight.w500)),
            ),
        ]),
        const SizedBox(height: 24),
        Text(en ? 'Every place has a story — go explore it!' : 'Každé miesto má svoj príbeh – objavte ho!',
            textAlign: TextAlign.center, style: AppText.inter(size: 12, color: AppColors.neutral400)),
      ]),
    );
  }
}

/// Shared/Pagination.js – pages in groups of five, ‹ › jump between groups.
class _Pagination extends StatelessWidget {
  const _Pagination({required this.current, required this.total, required this.onPage});
  final int current;
  final int total;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox.shrink();
    final size = context.md ? 56.0 : (context.sm ? 48.0 : 40.0);
    final font = context.md ? 22.0 : (context.sm ? 18.0 : 16.0);
    final start = ((current - 1) ~/ 5) * 5 + 1;
    final end = math.min(start + 4, total);

    Widget dot(String label, {required bool green, VoidCallback? onTap}) => Material(
          color: green ? AppColors.green : Colors.white,
          shape: const CircleBorder(),
          elevation: green ? 0 : 2,
          shadowColor: const Color(0x0D000000),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: Text(label, style: AppText.fraunces(size: font, color: green ? Colors.white : AppColors.forest, height: 1)),
              ),
            ),
          ),
        );

    final items = <Widget>[
      if (start > 1) dot('‹', green: true, onTap: () => onPage(start - 1)),
      for (var i = start; i <= end; i++) dot('$i', green: i == current, onTap: i == current ? null : () => onPage(i)),
      if (end < total) dot('›', green: true, onTap: () => onPage(end + 1)),
    ];
    return Wrap(spacing: 12, runSpacing: 12, children: items);
  }
}

// ───────────────────────────── Region section ─────────────────────────────

final _regionContentProvider = FutureProvider<Json>((ref) async {
  final raw = await rootBundle.loadString('assets/data/region_content.json');
  return asMap(jsonDecode(raw));
});

final _marketStatsProvider = FutureProvider.family<Json, String>((ref, citiesKey) async {
  final cities = citiesKey.split('|');
  return publicRepo.marketStats(cities);
});

/// One line under the city name on the region photo, matching its picture.
const _regionTaglines = {
  'london': 'Westminster, the South Bank and riverside stays in the heart of London.',
  'birmingham': 'Canals, the Bullring and the Jewellery Quarter in the heart of the Midlands.',
  'manchester': 'Red-brick mills, the Northern Quarter and city-centre stays.',
  'edinburgh': 'The Castle, the Old Town and Georgian streets of the New Town.',
  'glasgow': 'The Clyde waterfront, the West End and Merchant City.',
  'liverpool': 'The Three Graces, Albert Dock and the Mersey waterfront.',
  'bristol': 'Clifton, the Harbourside and the Avon Gorge.',
};

class _RegionSection extends ConsumerWidget {
  const _RegionSection({required this.regionId, required this.total, required this.hp, required this.onBrowse});
  final String regionId;
  final int total;
  final double hp;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final en = t.isEn;
    final lg = context.lg, md = context.md, sm = context.sm, xl = context.xl;
    final regions = ref.watch(tourismRegionsProvider).valueOrNull ?? const <Json>[];
    final content = ref.watch(_regionContentProvider).valueOrNull;
    final r = regions.where((e) => asString(e['id']) == regionId).firstOrNull;
    final c = content == null ? null : asMap(content[regionId]);
    if (r == null || c == null || c.isEmpty) return const SizedBox.shrink();

    final nameSk = asString(r['nameSk']);
    final nameEn = asString(r['nameEn']);
    final cities = asStringList(r['cities']);
    final locSk = asString(c['locSk']);
    final intro = asStringList(en ? c['introEn'] : c['introSk']);
    final stats = ref.watch(_marketStatsProvider(cities.join('|'))).valueOrNull;
    final dest = ref.watch(destinationsProvider);
    final destList = dest.valueOrNull;
    final counts = <String, int>{};
    for (final d in destList ?? const <Json>[]) {
      final k = searchKey(asString(d['nameSk']).isEmpty ? asString(d['nameEn']) : asString(d['nameSk']));
      if (cities.any((city) => searchKey(city) == k)) counts[k] = (counts[k] ?? 0) + asInt(d['count']);
    }
    final countsLoaded = destList != null;

    const kicker = Color(0xFF238869);
    final body = AppText.inter(size: md ? 16 : 14, color: AppColors.mutedGreen, height: 1.625);
    Text eyebrow(String s) => Text(s.toUpperCase(),
        style: AppText.inter(size: 12, weight: FontWeight.w700, color: kicker, letterSpacing: 12 * 0.16));
    Widget chip(String label, VoidCallback onTap) => OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.forest,
            backgroundColor: Colors.white,
            side: const BorderSide(color: AppColors.neutral200),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          child: Text(label, style: AppText.inter(size: 14)),
        );

    final intro0 = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      eyebrow(en ? 'Explore the region' : 'Objavte región'),
      const SizedBox(height: 8),
      Text(en ? 'Stays in $nameEn' : 'Ubytovanie $locSk', style: AppText.fraunces(size: md ? 36 : 30, height: 1.25)),
      const SizedBox(height: 16),
      for (var i = 0; i < intro.length; i++) ...[if (i > 0) const SizedBox(height: 16), Text(intro[i], style: body)],
      const SizedBox(height: 20),
      FilledButton(
        onPressed: onBrowse,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.forest,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
        child: Text(en ? 'Browse stays' : 'Zobraziť ubytovanie',
            style: AppText.inter(size: 14, weight: FontWeight.w600, color: Colors.white)),
      ),
    ]);

    final asset = destinationAsset(regionId);
    final photo = ConstrainedBox(
      constraints: BoxConstraints(minHeight: sm ? 320 : 240),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: const [BoxShadow(color: Color(0x1F1A3A2E), blurRadius: 40, offset: Offset(0, 16))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: Stack(fit: StackFit.passthrough, children: [
            Positioned.fill(
              child: asset == null
                  ? const ColoredBox(color: AppColors.forest)
                  : Image.asset(asset, fit: BoxFit.cover, cacheWidth: 1200),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xBF102B21), Colors.transparent, Colors.transparent],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                    ),
                    child: Text(en ? 'Explore the region' : 'Objavte región',
                        style: AppText.inter(size: 12, weight: FontWeight.w600, color: Colors.white, letterSpacing: 0.3)),
                  ),
                  const SizedBox(height: 12),
                  Text(en ? nameEn : nameSk, style: AppText.fraunces(size: 30, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text(
                    _regionTaglines[regionId] ?? 'Stays, sights and neighbourhood life across $nameEn.',
                    style: AppText.inter(size: 14, color: Colors.white),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );

    // "UK Stay Hub v číslach" – the same facts as the site, each only when known.
    final b = AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.mutedGreen, height: 1.625);
    final n = AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.mutedGreen, height: 1.625);
    final facts = <(IconData, List<TextSpan>)>[
      (
        Icons.home_outlined,
        en
            ? [const TextSpan(text: 'More than '), TextSpan(text: '$total stays', style: b), TextSpan(text: '\nin $nameEn')]
            : [const TextSpan(text: 'Viac ako '), TextSpan(text: '$total ubytovaní', style: b), TextSpan(text: '\nvo $nameSk')]
      ),
      if (stats != null && asInt(stats['petPolicyKnown']) > 0)
        (
          Icons.pets_outlined,
          en
              ? [TextSpan(text: '${asInt(stats['petFriendlyShare'])}% of stays', style: b), const TextSpan(text: '\nallow pets.')]
              : [TextSpan(text: '${asInt(stats['petFriendlyShare'])} % ubytovaní', style: b), const TextSpan(text: '\npovoľuje domáce zvieratá.')]
        ),
      if (stats != null && asInt(stats['listings']) > 0)
        (
          Icons.waves_outlined,
          en
              ? [
                  TextSpan(text: '${asInt(stats['wellnessShare'])}% have a sauna, hot tub or pool', style: b),
                  TextSpan(text: '\n(sauna ${asInt(stats['saunaShare'])}%, hot tub ${asInt(stats['hotTubShare'])}%).'),
                ]
              : [
                  TextSpan(text: '${asInt(stats['wellnessShare'])} % má saunu, vírivku alebo bazén', style: b),
                  TextSpan(text: '\n(sauna ${asInt(stats['saunaShare'])} %, vírivka ${asInt(stats['hotTubShare'])} %).'),
                ]
        ),
      if (stats != null && asInt(stats['ratedListings']) > 0)
        (
          Icons.star_border_rounded,
          en
              ? [
                  const TextSpan(text: 'Guests rate them\n'),
                  TextSpan(text: '${asDouble(stats['averageRating']).toStringAsFixed(1)} out of 5.', style: b),
                ]
              : [
                  const TextSpan(text: 'Hostia ich hodnotia priemerne\n'),
                  TextSpan(text: '${asDouble(stats['averageRating']).toStringAsFixed(1).replaceAll('.', ',')} z 5.', style: b),
                ]
        ),
    ];
    String? source;
    if (stats != null && asInt(stats['listings']) > 0) {
      final date = DateTime.tryParse(asString(stats['updatedAt']))?.toUtc();
      final dt = date == null ? '' : '${date.day}. ${date.month}. ${date.year}';
      source = en
          ? 'Source: UK Stay Hub listings${dt.isEmpty ? '' : ', as of $dt'}.'
          : 'Zdroj: ponuka UK Stay Hub${dt.isEmpty ? '' : ', údaje k $dt'}.';
    }

    final factCols = xl ? 4 : (sm ? 2 : 1);
    final factsCard = Container(
      padding: EdgeInsets.all(sm ? 32 : 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: const Color(0xFFDCE6DF)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF0F6F1), Colors.white, Color(0xFFFBF8EF)],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        eyebrow(en ? 'A closer look at UK Stay Hub stays' : 'Prehľad ponuky UK Stay Hub'),
        const SizedBox(height: 8),
        Text(en ? 'UK Stay Hub in numbers' : 'UK Stay Hub v číslach', style: AppText.fraunces(size: 24)),
        const SizedBox(height: 20),
        _CardGrid(
          cols: factCols,
          gapX: 12,
          children: [
            for (final (icon, spans) in facts)
              // border-l-4 on a rounded card: Flutter can't round a border whose
              // sides differ (it throws in debug), so the green edge is a bar
              // clipped inside a uniformly bordered, rounded box.
              Container(
                constraints: const BoxConstraints(minHeight: 96),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE7EEE8)),
                  boxShadow: const [BoxShadow(color: Color(0x0D1A3A2E), blurRadius: 14, offset: Offset(0, 4))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Container(
                    decoration: const BoxDecoration(border: Border(left: BorderSide(color: kicker, width: 4))),
                    padding: EdgeInsets.symmetric(horizontal: sm ? 20 : 16, vertical: 16),
                    child: Row(children: [
                      Icon(icon, size: 24, color: kicker),
                      const SizedBox(width: 12),
                      Expanded(child: Text.rich(TextSpan(style: n, children: spans))),
                    ]),
                  ),
                ),
              ),
          ],
        ),
        if (source != null) ...[
          const SizedBox(height: 16),
          Text(source, style: AppText.inter(size: 12, color: AppColors.muted)),
        ],
      ]),
    );

    final towns = [
      for (final city in cities)
        if (!(countsLoaded && (counts[searchKey(city)] ?? 0) == 0))
          chip(
            counts[searchKey(city)] == null ? city : '$city (${counts[searchKey(city)]})',
            () => ref.read(searchProvider.notifier).setDestination(Destination.city(city)),
          ),
    ];
    final others = [
      for (final o in regions)
        if (asString(o['id']) != regionId)
          chip(
            en ? asString(o['nameEn']) : asString(o['nameSk']),
            // The app has no /ubytovanie/{region} page, so this opens that region here.
            () => ref.read(searchProvider.notifier).setDestination(Destination.region(
                en ? asString(o['nameEn']) : asString(o['nameSk']), asStringList(o['cities']), asString(o['id']))),
          ),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1940),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hp),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1440),
              child: Padding(
                padding: EdgeInsets.only(top: md ? 64 : 48),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (lg)
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(child: intro0),
                        const SizedBox(width: 48),
                        Expanded(child: photo),
                      ]),
                    )
                  else ...[
                    intro0,
                    const SizedBox(height: 32),
                    photo,
                  ],
                  const SizedBox(height: 40),
                  factsCard,
                  const SizedBox(height: 40),
                  Text(en ? 'Where to stay in $nameEn' : 'Kde sa ubytovať $locSk', style: AppText.fraunces(size: 24)),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: towns),
                  const SizedBox(height: 40),
                  Text(en ? 'Other regions' : 'Ďalšie regióny', style: AppText.fraunces(size: 24)),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: others),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
