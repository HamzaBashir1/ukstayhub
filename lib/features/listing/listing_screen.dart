import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repo.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../../widgets/common.dart';
import '../../widgets/range_calendar.dart';
import '../../widgets/search_form.dart';
import '../../widgets/stay_card.dart';
import '../../widgets/sticky_sidebar.dart';
import '../checkout/checkout_screen.dart' show BookingDraft;
import '../../widgets/chrome.dart' show StayHubDrawer, StayHubFooter, StayHubHeader;
import '../search/search_screen.dart' show MobileSearchHeader;
import 'photo_gallery.dart';

// Tailwind colours the website's listing page uses (ClientPage.js).
const _forest = AppColors.forestListing; // #1e4636
const _green = AppColors.greenListing; // #319a7a
const _link = Color(0xFF2A8569); // "Show more" links
const _bar = Color(0xFF238869); // sticky bar button
const _barText = Color(0xFF112A22); // sticky bar price
const _border = Color(0xCCE5E5E5); // border-neutral-200/80

/// listings/[details]/ClientPage.js (mobile layout)
class ListingScreen extends ConsumerWidget {
  const ListingScreen({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(listingProvider(slug));
    return async.when(
      loading: () => const Scaffold(
          backgroundColor: Colors.white, body: _ListingSkeleton()),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: ErrorView(
          error: e,
          message: e.toString().contains('404') ||
                  e.toString().toLowerCase().contains('not found')
              ? t.pick(
                  'Ubytovanie sa nenašlo.', 'This stay could not be found.')
              : errorText(e),
          onRetry: () => ref.invalidate(listingProvider(slug)),
          retryLabel: t.pick('Skúsiť znova', 'Try again'),
        ),
      ),
      data: (l) => _ListingBody(listing: l),
    );
  }
}

/// ListingPageSkeleton.js
class _ListingSkeleton extends StatelessWidget {
  const _ListingSkeleton();
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return ListView(padding: EdgeInsets.zero, children: [
      Shimmer(height: (w * 0.82).clamp(280.0, 420.0)),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Shimmer(height: 28, width: 90, radius: 6),
          SizedBox(height: 16),
          Shimmer(height: 30, width: 280, radius: 6),
          SizedBox(height: 12),
          Shimmer(height: 16, width: 160, radius: 6),
          SizedBox(height: 28),
          Shimmer(height: 120, radius: 16),
        ]),
      ),
    ]);
  }
}

class _ListingBody extends ConsumerStatefulWidget {
  const _ListingBody({required this.listing});
  final Listing listing;
  @override
  ConsumerState<_ListingBody> createState() => _ListingBodyState();
}

class _ListingBodyState extends ConsumerState<_ListingBody> {
  DateTime? _in;
  DateTime? _out;
  Guests _guests = const Guests(adults: 1);
  String? _unitId;
  Quote? _quote;
  String? _quoteError;
  bool _quoting = false;
  bool _withPet = false;
  final Set<String> _extras = {};
  Timer? _debounce;
  final _scroll = ScrollController();
  bool _scrolled = false;

  Listing get l => widget.listing;

  @override
  void initState() {
    super.initState();
    final s = ref.read(searchProvider);
    if (s.hasDates && !_rangeBlocked(s.checkIn!, s.checkOut!)) {
      _in = s.checkIn;
      _out = s.checkOut;
    }
    if (s.guests.adults > 0) _guests = s.guests;
    // A guest always books a unit, so the first one is chosen until they pick.
    final units = l.units;
    if (units.isNotEmpty) _unitId = asString(units.first['_id']);
    // The contextual header appears once the guest scrolls past 350px.
    _scroll.addListener(() {
      final past = _scroll.hasClients && _scroll.offset > 350;
      if (past != _scrolled) setState(() => _scrolled = past);
    });
    _requote();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  bool _rangeBlocked(DateTime a, DateTime b) {
    for (var d = a; d.isBefore(b); d = d.add(const Duration(days: 1))) {
      if (l.isNightBlocked(d)) return true;
    }
    return false;
  }

  void _requote() {
    _debounce?.cancel();
    if (_in == null || _out == null || _guests.adults < 1) {
      setState(() {
        _quote = null;
        _quoteError = null;
      });
      return;
    }
    if (l.units.length > 1 && _unitId == null) {
      setState(() {
        _quote = null;
        _quoteError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      setState(() => _quoting = true);
      try {
        final q = await bookingRepo.quote(
          accommodationId: l.id,
          checkIn: _in!,
          checkOut: _out!,
          adults: _guests.adults,
          children: _guests.children,
          withPet: _withPet,
          extras: _extras.toList(),
          unitId: _unitId,
        );
        if (mounted) {
          setState(() {
            _quote = q;
            _quoteError = null;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _quote = null;
            _quoteError = errorText(e);
          });
        }
      } finally {
        if (mounted) setState(() => _quoting = false);
      }
    });
  }

  void _setDates(DateTime? a, DateTime? b) {
    setState(() {
      _in = a;
      _out = b;
    });
    ref.read(searchProvider.notifier).setDates(a, b);
    _requote();
  }

  Future<void> _pickDates() async {
    final t = ref.read(stringsProvider);
    await showStayHubSheet(
      context,
      title: t('CheckinCheckout', 'Príchod - Odchod'),
      fullHeight: true,
      builder: (_) => DatesSheetBody(
        initialStart: _in,
        initialEnd: _out,
        listing: l,
        onSave: _setDates,
      ),
    );
  }

  Future<void> _pickGuests() async {
    await openGuestsSheet(
      context,
      ref,
      max: l.person,
      initial: _guests,
      onSave: (g) {
        setState(() => _guests = g.adults < 1 ? g.copyWith(adults: 1) : g);
        ref.read(searchProvider.notifier).setGuests(_guests);
        _requote();
      },
    );
  }

  void _reserve() {
    final t = ref.read(stringsProvider);
    if (_in == null || _out == null) {
      toast(context, t('SelectRDates', 'Vyberte dátumy rezervácie'),
          error: true);
      _pickDates();
      return;
    }
    if (l.units.length > 1 && _unitId == null) {
      toast(context, t.pick('Vyberte si jednotku.', 'Choose a unit first.'),
          error: true);
      return;
    }
    final n = nightsBetween(_in, _out);
    if (n < l.nightMin || n > l.nightMax) {
      toast(context,
          '${t('Thisofferrequiresaminimumstayof', 'Minimálna dĺžka pobytu je')} ${l.nightMin} ${t('nights', 'nocí')}.',
          error: true);
      return;
    }
    if (l.person > 0 && _guests.total > l.person) {
      toast(context,
          '${t('MaxGuestsReached', 'Maximálny počet hostí je')} ${l.person}.',
          error: true);
      return;
    }
    if (_rangeBlocked(_in!, _out!)) {
      toast(
          context,
          t('PleaseselectdifferentdatesSomedatesareunavailable',
              'Niektoré dni nie sú dostupné.'),
          error: true);
      return;
    }
    if (_quoteError != null) {
      toast(context, _quoteError!, error: true);
      return;
    }
    context.push('/checkout',
        extra: BookingDraft(
          listing: l,
          checkIn: _in!,
          checkOut: _out!,
          guests: _guests,
          unitId: _unitId,
          withPet: _withPet,
          extras: _extras.toList(),
          quote: _quote,
        ));
  }

  void _back() => context.canPop() ? context.pop() : context.go('/mapa');

  final _rowKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final media = MediaQuery.of(context);
    final w = media.size.width;
    final sm = w >= 640, lg = w >= 1024, xl = w >= 1280;

    // `space-y-8 lg:space-y-10` between the page's sections.
    final gap = SizedBox(height: lg ? 40 : 32);

    final sections = <Widget>[
      _SectionCard(
        header: true,
        child: _Header(
          listing: l,
          unitId: _unitId,
          onUnit: (id) {
            setState(() => _unitId = id);
            _requote();
          },
        ),
      ),
      _SectionCard(
        child: _Section(
          title: t('AvailabilityAndPrice', 'Dostupnosť a cena'),
          child: _Availability(
            listing: l,
            checkIn: _in,
            checkOut: _out,
            guests: _guests,
            quote: _quote,
            quoting: _quoting,
            quoteError: _quoteError,
            withPet: _withPet,
            extras: _extras,
            onDates: _setDates,
            onGuests: _pickGuests,
            onPet: (v) {
              setState(() => _withPet = v);
              _requote();
            },
            onExtra: (v) {
              setState(() =>
                  _extras.contains(v) ? _extras.remove(v) : _extras.add(v));
              _requote();
            },
          ),
        ),
      ),
      _SectionCard(
          child: _Section(
              title: t('Stayinformation', 'Informácie o pobyte'),
              child: _StayInfo(listing: l))),
      _SectionCard(
          child: _Section(
              title: t('Amenities', 'Vybavenie'),
              child: _Amenities(listing: l))),
      _SectionCard(child: _Reviews(listing: l)),
      if (l.hasCoords || l.city.isNotEmpty)
        _SectionCard(child: _Location(listing: l)),
      _SectionCard(
          child: _Section(
              title: t('HostInformation', 'Informácie o hostiteľovi'),
              child: _HostBlock(listing: l))),
      _SectionCard(
          child: _Section(
              title: t('ThingsYouShouldKnow', 'Veci, ktoré by ste mali vedieť'),
              child: _Rules(listing: l))),
    ];
    final content =
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < sections.length; i++) ...[
        if (i > 0) gap,
        sections[i]
      ],
    ]);

    // `lg:w-3/5 xl:w-2/3 lg:pr-10` content + a sticky sidebar in the remaining width.
    final body = lg
        ? Row(
            key: _rowKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                Expanded(
                    flex: xl ? 2 : 3,
                    child: Padding(
                        padding: const EdgeInsets.only(right: 40),
                        child: content)),
                Expanded(
                  flex: xl ? 1 : 2,
                  child: StickySidebar(
                    scroll: _scroll,
                    rowKey: _rowKey,
                    child: _Sidebar(
                      listing: l,
                      checkIn: _in,
                      checkOut: _out,
                      guests: _guests,
                      quote: _quote,
                      quoting: _quoting,
                      onDates: _pickDates,
                      onGuests: _pickGuests,
                      onReserve: _reserve,
                    ),
                  ),
                ),
              ])
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: sm ? 0 : 16),
            child: content);

    return Scaffold(
      backgroundColor: Colors.white,
      // At lg the site's desktop header is sticky; below it the search header scrolls away.
      appBar: lg ? const StayHubHeader(background: Colors.white) : null,
      endDrawer: const StayHubDrawer(),
      body: Stack(children: [
        CustomScrollView(controller: _scroll, slivers: [
          if (!lg)
            SliverToBoxAdapter(
              child: Container(
                decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                        bottom: BorderSide(color: AppColors.neutral100))),
                child: const SafeArea(
                  bottom: false,
                  child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: MobileSearchHeader()),
                ),
              ),
            ),
          SliverToBoxAdapter(child: _Gallery(listing: l, onBack: _back)),
          SliverPadding(
            // 20px outer margin; `mt-6 lg:mt-11`.
            padding: EdgeInsets.fromLTRB(20, lg ? 44 : 24, 20, 0),
            sliver: SliverList.list(children: [
              body,
              // `mt-12 lg:mt-16 border-t pt-12`
              SizedBox(height: lg ? 64 : 48),
              const Divider(color: AppColors.neutral100),
              const SizedBox(height: 48),
              Text(
                  t('SimilarAccommodationsNearby',
                      'Podobné ubytovania v okolí'),
                  style: AppText.fraunces(
                      size: 24, color: _forest, letterSpacing: -0.6)),
              const SizedBox(height: 24),
              _Similar(listing: l),
              const SizedBox(height: 48),
            ]),
          ),
          const SliverToBoxAdapter(child: StayHubFooter()),
          // Room for the sticky booking bar over the footer (it is hidden at lg).
          if (!lg)
            SliverToBoxAdapter(
                child: ColoredBox(
                    color: AppColors.forest,
                    child: SizedBox(height: 90 + media.padding.bottom))),
        ]),
        if (_scrolled && !lg)
          Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _ContextHeader(listing: l, onBack: _back)),
      ]),
      bottomNavigationBar: lg
          ? null
          : _BookingBar(
              listing: l,
              checkIn: _in,
              checkOut: _out,
              guests: _guests,
              quote: _quote,
              quoting: _quoting,
              onDates: _pickDates,
              onReserve: _reserve,
            ),
    );
  }
}

/// A page section. From `sm` it is a card — `bg-white rounded-2xl border
/// border-neutral-200/80 shadow-xs p-6 md:p-8`; on phones it stays flat.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child, this.header = false});
  final Widget child;
  final bool
      header; // the title block has no top rule on phones, but is a card from sm
  @override
  Widget build(BuildContext context) {
    if (!context.sm) return child;
    return Container(
      padding: EdgeInsets.all(context.md ? 32 : 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xCCE5E5E5)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))
        ],
      ),
      child: child,
    );
  }
}

/// renderSidebar — the desktop booking card.
class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.listing,
    required this.checkIn,
    required this.checkOut,
    required this.guests,
    required this.quote,
    required this.quoting,
    required this.onDates,
    required this.onGuests,
    required this.onReserve,
  });
  final Listing listing;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final Guests guests;
  final Quote? quote;
  final bool quoting;
  final VoidCallback onDates;
  final VoidCallback onGuests;
  final VoidCallback onReserve;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = listing;
    final hasDates = checkIn != null && checkOut != null;
    final nights = hasDates ? nightsBetween(checkIn, checkOut) : 1;
    final canSubmit = l.canBook;
    final label = l.isRequestMode
        ? t('RequestToBook', t.pick('Požiadať o rezerváciu', 'Request to book'))
        : l.bookable
            ? t('Reserve', 'Rezervovať')
            : t('comingSoons', t.pick('Už čoskoro', 'Coming soon'));
    final fmt =
        DateFormat('d MMM', 'en_GB');
    final dateTitle = hasDates
        ? '${fmt.format(checkIn!)} → ${fmt.format(checkOut!)}'
        : t('SelectDate', t('Adddates', 'Vyberte termín'));
    final guestCount = guests.total;
    final cleaning = l.cleaningFee;
    final tax = l.localTax;

    Widget row(IconData icon, String title, String sub, VoidCallback onTap) =>
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(children: [
              Icon(icon, size: 24, color: AppColors.neutral400),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: AppText.inter(
                              size: 16,
                              weight: FontWeight.w600,
                              color: AppColors.neutral900)),
                      Text(sub,
                          style: AppText.inter(
                              size: 13, color: AppColors.neutral500)),
                    ]),
              ),
            ]),
          ),
        );

    return Container(
      padding: EdgeInsets.all(context.sm ? 24 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xCCE5E5E5)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0F000000), blurRadius: 30, offset: Offset(0, 8))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: quote != null && hasDates
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Text.rich(TextSpan(children: [
                          TextSpan(
                              text: '£${_n(quote!.total)}',
                              style: AppText.inter(
                                  size: 30,
                                  weight: FontWeight.w800,
                                  color: _forest,
                                  letterSpacing: -0.6)),
                          TextSpan(
                              text: ' / $nights ${t('nights', 'nocí')}',
                              style: AppText.inter(
                                  size: 14,
                                  weight: FontWeight.w500,
                                  color: AppColors.neutral500)),
                        ])),
                        InkWell(
                          onTap: () => _BookingBar(
                                  listing: l,
                                  checkIn: checkIn,
                                  checkOut: checkOut,
                                  guests: guests,
                                  quote: quote,
                                  quoting: quoting,
                                  onDates: onDates,
                                  onReserve: onReserve)
                              ._priceDetails(context, t),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                                t('Viewdetails', 'Zobraziť podrobnosti'),
                                style: AppText.inter(
                                    size: 14,
                                    weight: FontWeight.w700,
                                    color: const Color(0xFF2A8569))),
                          ),
                        ),
                      ])
                : Text(
                    '$nights ${nights == 1 ? t('night', 'noc') : t('nights', 'nocí')}',
                    style: AppText.inter(
                        size: 24, weight: FontWeight.w700, color: _forest)),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFA7F3D0))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.verified_user_outlined,
                  size: 13, color: Color(0xFF059669)),
              const SizedBox(width: 6),
              Text(t('stayHubVerified', 'Overené UK Stay Hub'),
                  style: AppText.inter(
                      size: 12,
                      weight: FontWeight.w700,
                      color: const Color(0xFF047857))),
            ]),
          ),
        ]),
        if (cleaning > 0 || tax > 0) ...[
          const SizedBox(height: 8),
          if (cleaning > 0)
            Text(
                '${t('CleaningFee', 'Poplatok za upratovanie')}: £${_n(cleaning)} ${t('PerStay', 'za pobyt')}',
                style: AppText.inter(size: 12, color: AppColors.neutral500)),
          if (tax > 0)
            Text(
                '${t('LocalTax', 'Miestny poplatok')}: £${_n(tax)} ${t('PerPersonNight', 'za osobu a noc')}',
                style: AppText.inter(size: 12, color: AppColors.neutral500)),
        ],
        const SizedBox(height: 20),
        Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.neutral200)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            row(Icons.calendar_today_outlined, dateTitle,
                t('CheckinCheckout', 'Príchod - Odchod'), onDates),
            const Divider(height: 1, color: AppColors.neutral200),
            row(
                Icons.person_add_alt_outlined,
                '$guestCount ${t('guests', 'Hostia')}',
                t('guests', 'Hostia'),
                onGuests),
          ]),
        ),
        const SizedBox(height: 20),
        Opacity(
          opacity: canSubmit ? 1 : 0.5,
          child: Material(
            color: const Color(0xFF357965),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: canSubmit ? (hasDates ? onReserve : onDates) : null,
              child: Container(
                height: 48,
                alignment: Alignment.center,
                child: quoting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.white))
                    : Text(label,
                        style: AppText.inter(
                            size: 15,
                            weight: FontWeight.w600,
                            color: Colors.white)),
              ),
            ),
          ),
        ),
        if (canSubmit) ...[
          const SizedBox(height: 20),
          Text(
            l.isRequestMode
                ? t(
                    'RequestNoPaymentNote',
                    t.pick(
                        'Teraz neplatíte nič — hostiteľ má 48 hodín na prijatie.',
                        "You won't be charged now — the host has 48 hours to accept."))
                : t('Youwontbechargeyet', 'Zatiaľ vám nič neúčtujeme'),
            textAlign: TextAlign.center,
            style: AppText.inter(
                size: 12, weight: FontWeight.w500, color: AppColors.neutral500),
          ),
        ],
      ]),
    );
  }
}

// ───────────────────────────── Gallery ─────────────────────────────
/// The photo mosaic: `grid h-[clamp(280px,82vw,420px)] grid-cols-3 grid-rows-3 gap-1`
/// with the main photo spanning two columns and three thumbnails stacked beside it.
class _Gallery extends ConsumerWidget {
  const _Gallery({required this.listing, required this.onBack});
  final Listing listing;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final imgs = listing.images;
    final w = MediaQuery.sizeOf(context).width;
    if (w >= 640) return _wideGallery(context, ref, t, w);
    final height = (w * 0.82).clamp(280.0, 420.0);
    const gap = 4.0;
    // The page sits in a 20px outer margin.
    final col = ((w - 40) - gap * 2) / 3;
    final tour = listing.virtualTourUrl;

    void openGallery(int i) => openPhotoGallery(context,
        images: imgs,
        listingId: listing.id,
        name: listing.name(t.lang),
        index: i);

    Widget photo(int i, double width, double height) => ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: GestureDetector(
            onTap: () => (i == 0 && tour.isNotEmpty)
                ? launchUrl(Uri.parse(tour),
                    mode: LaunchMode.externalApplication)
                : openGallery(i),
            child: SizedBox(
              width: width,
              height: height,
              child: i < imgs.length
                  ? NetImage(cloudinary(imgs[i], width: i == 0 ? 640 : 320),
                      cacheWidth: i == 0 ? 640 : 320)
                  : (i == 0 ? _noPhoto(t) : const SizedBox.shrink()),
            ),
          ),
        );

    final thumbH = (height - gap * 2) / 3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 0),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            photo(0, col * 2 + gap, height),
            const SizedBox(width: gap),
            Column(children: [
              for (var i = 1; i <= 3; i++) ...[
                if (i > 1) const SizedBox(height: gap),
                photo(i, col, thumbH),
              ],
            ]),
          ]),
          // 360° badge – `right-3 top-3`
          if (tour.isNotEmpty)
            Positioned(
              right: 12 + col + gap,
              top: 12,
              child: IgnorePointer(
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: _glass(radius: 999),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.threesixty,
                        size: 14, color: Color(0xFF238869)),
                    const SizedBox(width: 6),
                    Text('360°',
                        style: AppText.inter(
                            size: 11,
                            weight: FontWeight.w700,
                            color: const Color(0xFF173C2E))),
                  ]),
                ),
              ),
            ),
          // Back – `left-4 top-4 h-10 w-10`
          Positioned(
            left: 16,
            top: 16,
            child: GestureDetector(
              onTap: onBack,
              child: Container(
                width: 40,
                height: 40,
                decoration: _glass(radius: 999),
                child: const Icon(Icons.chevron_left_rounded,
                    size: 22, color: Color(0xFF173C2E)),
              ),
            ),
          ),
          // "Show" – `bottom-3 left-3 min-h-10 min-w-[112px]`
          if (imgs.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 12,
              child: GestureDetector(
                onTap: () => openGallery(0),
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 112, minHeight: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: _glass(radius: 12),
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.grid_view_rounded,
                            size: 16, color: Color(0xFF238869)),
                        const SizedBox(width: 6),
                        Text(t('Show', 'Viac fotky'),
                            style: AppText.inter(
                                size: 13,
                                weight: FontWeight.w700,
                                color: const Color(0xFF173C2E))),
                      ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  /// `sm:h-[520px] sm:grid-cols-4 sm:grid-rows-2 sm:gap-2 lg:h-[560px]`: the main photo
  /// spans 2×2, four thumbnails fill the right half.
  Widget _wideGallery(
      BuildContext context, WidgetRef ref, Strings t, double w) {
    final imgs = listing.images;
    final tour = listing.virtualTourUrl;
    final height = w >= 1024 ? 560.0 : 520.0;
    const gap = 8.0;
    final col = ((w - 40) - gap * 3) / 4;
    final rowH = (height - gap) / 2;
    final md = w >= 768;
    void open(int i) => openPhotoGallery(context,
        images: imgs,
        listingId: listing.id,
        name: listing.name(t.lang),
        index: i);
    void openTour() =>
        launchUrl(Uri.parse(tour), mode: LaunchMode.externalApplication);

    Widget photo(int i, double width, double h) => ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onTap: () => (i == 0 && tour.isNotEmpty) ? openTour() : open(i),
            child: SizedBox(
              width: width,
              height: h,
              child: i < imgs.length
                  ? NetImage(cloudinary(imgs[i], width: i == 0 ? 960 : 500),
                      cacheWidth: i == 0 ? 960 : 500)
                  : (i == 0 ? _noPhoto(t) : const SizedBox.shrink()),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 0),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            photo(0, col * 2 + gap, height),
            const SizedBox(width: gap),
            Column(children: [
              photo(1, col, rowH),
              const SizedBox(height: gap),
              photo(3, col, rowH)
            ]),
            const SizedBox(width: gap),
            Column(children: [
              photo(2, col, rowH),
              const SizedBox(height: gap),
              photo(4, col, rowH)
            ]),
          ]),
          // 360° badge: `md:hidden top-3 right-3` (over the main photo's corner)
          if (tour.isNotEmpty && !md)
            Positioned(
              right: 12 + (col + gap) * 2,
              top: 12,
              child: IgnorePointer(
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: _glass(radius: 999),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.threesixty,
                        size: 14, color: Color(0xFF238869)),
                    const SizedBox(width: 6),
                    Text('360°',
                        style: AppText.inter(
                            size: 11,
                            weight: FontWeight.w700,
                            color: const Color(0xFF173C2E))),
                  ]),
                ),
              ),
            ),
          // "Show all photos +N" — `md:flex bottom-4 right-4 min-h-11`
          if (md && imgs.isNotEmpty)
            Positioned(
              right: 16,
              bottom: 16,
              child: GestureDetector(
                onTap: () => open(0),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: _glass(radius: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.grid_view_rounded,
                        size: 20, color: Color(0xFF238869)),
                    const SizedBox(width: 8),
                    Text(
                        '${t('Showallphotos', t.pick('Zobraziť všetky fotografie', 'Show all photos'))} +${imgs.length}',
                        style: AppText.inter(
                            size: 14,
                            weight: FontWeight.w700,
                            color: const Color(0xFF173C2E))),
                  ]),
                ),
              ),
            ),
          // "Show" below md; the 360° tour button from md up (bottom-left).
          if (!md && imgs.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 12,
              child: GestureDetector(
                onTap: () => open(0),
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 112, minHeight: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: _glass(radius: 12),
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.grid_view_rounded,
                            size: 16, color: Color(0xFF238869)),
                        const SizedBox(width: 6),
                        Text(t('Show', 'Viac fotky'),
                            style: AppText.inter(
                                size: 13,
                                weight: FontWeight.w700,
                                color: const Color(0xFF173C2E))),
                      ]),
                ),
              ),
            ),
          if (md && tour.isNotEmpty)
            Positioned(
              left: 16,
              bottom: 16,
              child: GestureDetector(
                onTap: openTour,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                      color: AppColors.neutral100,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x0D000000),
                            blurRadius: 2,
                            offset: Offset(0, 1))
                      ]),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.threesixty,
                        size: 20, color: AppColors.neutral500),
                    const SizedBox(width: 8),
                    Text(t('Tour', t.pick('360° Prehliadka', '360° Tour')),
                        style: AppText.inter(
                            size: 14,
                            weight: FontWeight.w500,
                            color: AppColors.neutral800)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  static BoxDecoration _glass({required double radius}) => BoxDecoration(
        color: const Color(0xF2FFFFFF),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0xB3FFFFFF)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33112A22), blurRadius: 14, offset: Offset(0, 5))
        ],
      );

  static Widget _noPhoto(Strings t) => Container(
        color: _forest,
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('UK Stay Hub',
              style: AppText.inter(
                  size: 14, weight: FontWeight.w600, color: Colors.white)),
          Text(t('PhotoNotAvailable', 'Fotografia nie je dostupná'),
              style: AppText.inter(size: 12, color: Colors.white)),
        ]),
      );
}

/// Fixed bar that slides in after 350px of scroll: `h-16 … lg:hidden`.
class _ContextHeader extends ConsumerWidget {
  const _ContextHeader({required this.listing, required this.onBack});
  final Listing listing;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final top = MediaQuery.paddingOf(context).top;
    final l = listing;
    return Container(
      height: 64 + top,
      padding: EdgeInsets.fromLTRB(16, top, 16, 0),
      decoration: const BoxDecoration(
        color: Color(0xF2FFFFFF),
        border: Border(bottom: BorderSide(color: AppColors.neutral100)),
        boxShadow: [
          BoxShadow(
              color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1))
        ],
      ),
      child: Row(children: [
        InkWell(
          onTap: onBack,
          customBorder: const CircleBorder(),
          child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.chevron_left_rounded,
                  size: 24, color: AppColors.neutral800)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    l.name('en'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.inter(
                        size: 14, weight: FontWeight.w700, color: _forest)),
                Row(children: [
                  const Icon(Icons.star_rounded,
                      size: 12, color: AppColors.yellowStar),
                  const SizedBox(width: 6),
                  Text(
                      _ratingFromReviews(
                              ref.watch(reviewsProvider(l.id)).valueOrNull ??
                                  const <Json>[],
                              l.rating)
                          .toStringAsFixed(1),
                      style: AppText.inter(
                          size: 11,
                          weight: FontWeight.w600,
                          color: AppColors.neutral500)),
                  Expanded(
                    child: Text(' · ${l.city}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.inter(
                            size: 11,
                            weight: FontWeight.w600,
                            color: AppColors.neutral500)),
                  ),
                ]),
              ]),
        ),
        FavoriteButton(listingId: l.id, size: 40),
      ]),
    );
  }
}

// ───────────────────────────── Header (renderSection1) ─────────────────────────────
class _Header extends ConsumerWidget {
  const _Header(
      {required this.listing, required this.unitId, required this.onUnit});
  final Listing listing;
  final String? unitId;
  final ValueChanged<String> onUnit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = listing;
    final lang = t.lang;
    final reviews = ref.watch(reviewsProvider(l.id)).valueOrNull;
    final rating =
        reviews == null ? l.rating : _ratingFromReviews(reviews, l.rating);
    final count = reviews?.length ?? l.reviewCount;
    final host = _hostOf(ref, l);
    final verified = asBool(host['isVerified']);
    // Matched against the backend's Slovak `amenities` list, as the website does.
    final allAm = asStringList(pick(l.raw, 'amenities.sk'));
    final selectedUnit =
        firstWhereOrNull(l.units, (Json u) => asString(u['_id']) == unitId);
    // findTourismRegionByCity
    final region = firstWhereOrNull(
        ref.watch(tourismRegionsProvider).valueOrNull ?? const <Json>[],
        (Json r) => asStringList(r['cities'])
            .any((c) => c.toLowerCase() == l.city.toLowerCase()));

    final highlights = <(IconData, String)>[
      if (verified)
        (Icons.verified_user_outlined, t('VerifiedHost', 'Overený hostiteľ')),
      if (rating >= 4.8 && count >= 5)
        (Icons.star_outline_rounded, t('HighlyRated', 'Vysoko hodnotené')),
      if (['under_hour', 'within_few_hours']
          .contains(asString(host['responseTime'])))
        (Icons.schedule, t('FastResponse', 'Rýchla odpoveď')),
      if (asInt(host['responseRate']) == 100)
        (
          Icons.chat_bubble_outline,
          t('Responserate100', '100 % miera odpovede')
        ),
      if (allAm.contains('Klimatizácia'))
        (Icons.ac_unit, t('AmenityAC', 'Klimatizácia'))
      else if (allAm.contains('Práčka'))
        (
          Icons.local_laundry_service_outlined,
          t('AmenityWashingMachine', 'Práčka')
        )
      else if (allAm.contains('Parkovanie'))
        (Icons.local_parking, t('AmenityParkingHighlight', 'Parkovanie'))
      else if (allAm.contains('Wi-Fi') || allAm.contains('Wifi'))
        (Icons.wifi, 'Wi-Fi'),
    ].take(3).toList();

    Widget ratingBadge() {
      if (count == 0) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: AppColors.neutral50,
              borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const StarRow(value: 0, size: 12, color: AppColors.yellowStar),
            const SizedBox(width: 6),
            Text(t('Noreviewyet', 'Bez hodnotení'),
                style: AppText.inter(
                    size: 12,
                    weight: FontWeight.w500,
                    color: AppColors.neutral500)),
          ]),
        );
      }
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x80FEFCE8),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0x80FEF9C3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          StarRow(value: rating, size: 12, color: AppColors.yellowStar),
          const SizedBox(width: 6),
          Text(rating.toStringAsFixed(1),
              style: AppText.inter(
                  size: 12,
                  weight: FontWeight.w700,
                  color: AppColors.neutral800)),
          const SizedBox(width: 6),
          Text('($count)',
              style: AppText.inter(size: 12, color: AppColors.neutral500)),
        ]),
      );
    }

    final crumb = AppText.inter(
        size: 12, weight: FontWeight.w500, color: AppColors.neutral500);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Breadcrumb
      Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            GestureDetector(
                onTap: () => context.go('/'),
                child: Text(t.pick('Domov', 'Home'), style: crumb)),
            Text('›', style: crumb),
            GestureDetector(
                onTap: () => context.push('/ubytovanie'),
                child: Text(t.pick('Ubytovanie', 'Stays'), style: crumb)),
            if (region != null) ...[
              Text('›', style: crumb),
              GestureDetector(
                onTap: () => context.push('/ubytovanie'),
                child: Text(
                    asString(region[lang == 'en' ? 'nameEn' : 'nameSk']),
                    style: crumb),
              ),
            ],
          ]),
      const SizedBox(height: 12),
      // Category chip + like button
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(
          child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: _forest.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(
                      (l.propertyType(lang).isEmpty
                              ? t.pick('Ubytovanie', 'Stay')
                              : l.propertyType(lang))
                          .toUpperCase(),
                      style: AppText.inter(
                          size: 12,
                          weight: FontWeight.w700,
                          color: _forest,
                          letterSpacing: 0.6)),
                ),
                if (verified)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle)),
                      const SizedBox(width: 4),
                      Text(t('Verified', 'Overený'),
                          style: AppText.inter(
                              size: 12,
                              weight: FontWeight.w500,
                              color: const Color(0xFF047857))),
                    ]),
                  ),
              ]),
        ),
        const SizedBox(width: 16),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => launchUrl(Uri.parse(sitePath('/listings/${l.slug}')),
              mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.ios_share_rounded,
              size: 22, color: AppColors.neutral800),
        ),
        FavoriteButton(listingId: l.id, size: 40, plain: true),
      ]),
      const SizedBox(height: 12),
      // Title + mobile rating badge
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.name(lang),
                style: AppText.fraunces(
                    size: 24,
                    color: _forest,
                    height: 1.25,
                    letterSpacing: -0.6)),
            if (l.units.length > 1 && selectedUnit != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(asString(selectedUnit['name']),
                    style: AppText.inter(
                        size: 16, weight: FontWeight.w600, color: _green)),
              ),
          ]),
        ),
        const SizedBox(width: 12),
        Padding(padding: const EdgeInsets.only(top: 6), child: ratingBadge()),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        const Icon(Icons.location_on_outlined, size: 15, color: _green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              [if (l.district.isNotEmpty) l.district, l.city].join(', '),
              style: AppText.inter(
                  size: 14,
                  weight: FontWeight.w500,
                  color: AppColors.neutral600)),
        ),
      ]),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '${l.person} ${t('guests', 'hostia')} · ${l.bedroom} ${t('bedrooms', 'spálne')} · '
          '${l.beds} ${t('beds', 'postele')} · ${l.bathroom} ${t('Bathroom', 'kúpeľne')}',
          style: AppText.inter(
              size: 14, weight: FontWeight.w500, color: AppColors.neutral700),
        ),
      ),
      const SizedBox(height: 16),
      if (l.units.length > 1)
        _UnitPicker(listing: l, selected: unitId, onSelect: onUnit),
      if (highlights.isNotEmpty)
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            border: Border.symmetric(
                horizontal: BorderSide(color: AppColors.neutral100)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(children: [
              for (var i = 0; i < highlights.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Icon(highlights[i].$1, size: 20, color: _green),
                const SizedBox(width: 8),
                Text(highlights[i].$2,
                    style: AppText.inter(
                        size: 14,
                        weight: FontWeight.w600,
                        color: AppColors.neutral800)),
              ],
            ]),
          ),
        ),
    ]);
  }
}

/// renderUnitPicker: radio cards, one per unit, each with a "View details" sheet.
class _UnitPicker extends ConsumerWidget {
  const _UnitPicker(
      {required this.listing, required this.selected, required this.onSelect});
  final Listing listing;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final en = t.isEn;
    return Container(
      padding: const EdgeInsets.only(top: 16, bottom: 20),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.neutral100))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(en ? 'Choose your unit' : 'Vyberte si jednotku',
            style: AppText.inter(
                size: 16, weight: FontWeight.w700, color: _forest)),
        const SizedBox(height: 12),
        for (final u in listing.units) ...[
          _unitCard(context, t, u, asString(u['_id']) == selected),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }

  List<String> _facts(Strings t, Json u) => [
        if (asInt(u['person']) > 0)
          '${asInt(u['person'])} ${t('guests', 'hostia').toLowerCase()}',
        if (asInt(u['bedroom']) > 0)
          '${asInt(u['bedroom'])} ${t('bedrooms', 'spálne').toLowerCase()}',
        if (asInt(u['beds']) > 0)
          '${asInt(u['beds'])} ${t('beds', 'postele').toLowerCase()}',
      ];

  Widget _unitCard(BuildContext context, Strings t, Json u, bool isSelected) {
    final id = asString(u['_id']);
    final facts = _facts(t, u);
    final desc = asString(u['description']);
    final price = asDouble(u['pricePerNight']);
    return GestureDetector(
      onTap: () => onSelect(id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? _green.withValues(alpha: 0.05) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isSelected ? _green : AppColors.neutral200, width: 2),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 18,
                color: isSelected ? _green : AppColors.neutral400),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(asString(u['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.inter(
                              size: 15,
                              weight: FontWeight.w700,
                              color: AppColors.neutral900)),
                    ),
                    const SizedBox(width: 8),
                    if (price > 0)
                      Text.rich(TextSpan(children: [
                        TextSpan(
                            text: '£${_n(price)}',
                            style: AppText.inter(
                                size: 14,
                                weight: FontWeight.w700,
                                color: _forest)),
                        TextSpan(
                            text: ' / ${t('night', 'noc')}',
                            style: AppText.inter(
                                size: 14, color: AppColors.neutral500)),
                      ])),
                  ]),
              if (facts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(facts.join(' · '),
                      style:
                          AppText.inter(size: 13, color: AppColors.neutral500)),
                ),
              if (desc.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.inter(
                          size: 13, color: AppColors.neutral600, height: 1.55)),
                ),
              GestureDetector(
                onTap: () => _details(context, t, u),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(t.isEn ? 'View details' : 'Zobraziť detaily',
                        style: AppText.inter(
                            size: 13,
                            weight: FontWeight.w600,
                            color: _link,
                            decoration: TextDecoration.underline)),
                    const Icon(Icons.chevron_right_rounded,
                        size: 14, color: _link),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// The unit's detail sheet: photos, price, capacity facts, description.
  void _details(BuildContext context, Strings t, Json u) {
    final images = asStringList(u['images']);
    final facts = [
      for (final (label, key) in [
        (t('guests', 'Hostia'), 'person'),
        (t('Bedroom', 'Spálne'), 'bedroom'),
        (t('DoubleBed', 'Manželská posteľ'), 'doublebed'),
        (t('SingleBed', 'Jednolôžková posteľ'), 'singlebed'),
        (t('BunkBed', 'Poschodová posteľ'), 'bunkbed'),
        (t('ExtraBed', 'Prístelka'), 'extraBeds'),
        (t('Beds', 'Postele'), 'beds'),
        (t('Bathroom', 'Kúpeľne'), 'bathroom'),
        (t('LivingRoom', 'Obývačka'), 'LivingRoom'),
        (t('Kitchen', 'Kuchyňa'), 'kitchen'),
      ])
        if (asInt(u[key]) > 0) (label, asInt(u[key])),
    ];
    final price = asDouble(u['pricePerNight']);
    final desc = asString(u['description']);
    final id = asString(u['_id']);
    showStayHubSheet(
      context,
      title: asString(u['name']),
      fullHeight: true,
      builder: (ctx) => ListView(padding: EdgeInsets.zero, children: [
        if (images.isNotEmpty)
          SizedBox(
            height: 240,
            child: PageView.builder(
              itemCount: images.length,
              itemBuilder: (_, i) =>
                  NetImage(cloudinary(images[i], width: 800), cacheWidth: 800),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Text(asString(u['name']),
                      style: AppText.fraunces(size: 20, color: _forest))),
              if (price > 0)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('£${_n(price)}',
                      style: AppText.inter(
                          size: 18, weight: FontWeight.w700, color: _forest)),
                  Text('/ ${t('night', 'noc')}',
                      style:
                          AppText.inter(size: 12, color: AppColors.neutral500)),
                ]),
            ]),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 20),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final f in facts)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.neutral50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.neutral200),
                    ),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: '${f.$2} ',
                          style: AppText.inter(
                              size: 14,
                              weight: FontWeight.w700,
                              color: AppColors.neutral900)),
                      TextSpan(
                          text: f.$1,
                          style: AppText.inter(
                              size: 14,
                              weight: FontWeight.w500,
                              color: AppColors.neutral700)),
                    ])),
                  ),
              ]),
            ],
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(desc,
                  style: AppText.inter(
                      size: 14, color: AppColors.neutral600, height: 1.6)),
            ],
            const SizedBox(height: 20),
            const Divider(color: AppColors.neutral100),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () {
                  onSelect(id);
                  Navigator.of(ctx).pop();
                },
                style: TextButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                    id == selected
                        ? (t.isEn ? 'Selected' : 'Vybraté')
                        : (t.isEn
                            ? 'Select this unit'
                            : 'Vybrať túto jednotku'),
                    style: AppText.inter(
                        size: 14,
                        weight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// listingRatingFromReviews: mean of the per-category averages the guests gave,
/// else the mean of their overall star rows.
double _ratingFromReviews(List<Json> reviews, double fallback) {
  if (reviews.isEmpty) return fallback;
  final totals = <String, double>{};
  final counts = <String, int>{};
  for (final r in reviews) {
    asMap(r['categoryRatings']).forEach((k, v) {
      final d = asDouble(v);
      if (d <= 0) return;
      totals[k.toString()] = (totals[k.toString()] ?? 0) + d;
      counts[k.toString()] = (counts[k.toString()] ?? 0) + 1;
    });
  }
  if (totals.isNotEmpty) {
    final avgs = [for (final k in totals.keys) totals[k]! / counts[k]!];
    return avgs.reduce((a, b) => a + b) / avgs.length;
  }
  final overall = reviews
      .map((r) => asDouble(r['overallRating']))
      .where((v) => v > 0)
      .toList();
  return overall.isEmpty
      ? fallback
      : overall.reduce((a, b) => a + b) / overall.length;
}

/// The listing's host with the public profile merged in (isVerified,
/// responseTime, … are only on `/hosts/:id`, as on the website).
Json _hostOf(WidgetRef ref, Listing l) {
  final id = asString(l.host['_id'], l.hostId);
  final full = id.isEmpty
      ? const <String, dynamic>{}
      : (ref.watch(hostPublicProvider(id)).valueOrNull ??
          const <String, dynamic>{});
  return {...l.host, ...full};
}

/// `100` not `100.0`, but `79.5` stays.
String _n(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// A page section: `border-t pt-4`, Fraunces title and the 48×3 green bar.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!context.sm) ...[
          const Divider(color: _border),
          const SizedBox(height: 16)
        ],
        Row(children: [
          Flexible(
              child: Text(title,
                  style: AppText.fraunces(
                      size: 20, color: _forest, letterSpacing: -0.5))),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ]),
        const SizedBox(height: 8),
        Container(
            width: 48,
            height: 3,
            decoration: BoxDecoration(
                color: _green, borderRadius: BorderRadius.circular(3))),
        const SizedBox(height: 24),
        child,
      ]);
}

// ───────────────────────────── Availability & price ─────────────────────────────
class _Availability extends ConsumerWidget {
  const _Availability({
    required this.listing,
    required this.checkIn,
    required this.checkOut,
    required this.guests,
    required this.quote,
    required this.quoting,
    required this.quoteError,
    required this.withPet,
    required this.extras,
    required this.onDates,
    required this.onGuests,
    required this.onPet,
    required this.onExtra,
  });
  final Listing listing;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final Guests guests;
  final Quote? quote;
  final bool quoting;
  final String? quoteError;
  final bool withPet;
  final Set<String> extras;
  final void Function(DateTime? a, DateTime? b) onDates;
  final VoidCallback onGuests;
  final ValueChanged<bool> onPet;
  final ValueChanged<String> onExtra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = listing;
    final lang = t.lang;
    final n = nightsBetween(checkIn, checkOut);
    final petAllowed =
        l.policyValue('pet', 'en').toLowerCase().contains('allow') &&
            !l.policyValue('pet', 'en').toLowerCase().contains('not allowed');

    final bd = quote?.breakdown ?? const <String, dynamic>{};
    double cents(String k) => asInt(bd[k]) / 100;

    Widget line(String a, String b, {Color? color}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: Text(a,
                        style: AppText.inter(
                            size: 14, color: color ?? AppColors.neutral600))),
                const SizedBox(width: 12),
                Text(b,
                    style: AppText.inter(
                        size: 14, color: color ?? AppColors.neutral600)),
              ]),
        );

    final accCents = asInt(bd['accommodationCents'] ?? bd['subtotalCents']);
    final nightly = n > 0 ? accCents / 100 / n : 0.0;

    // Host length-of-stay / guest discounts, listed as pills.
    final discountRows = <(String, num)>[];
    final byNights = asMapList(l.raw['lengthDiscounts'])
      ..sort((a, b) => asInt(a['minNights']).compareTo(asInt(b['minNights'])));
    for (final r in byNights) {
      if (asInt(r['minNights']) > 0 && asDouble(r['percent']) > 0) {
        discountRows.add((
          '${asInt(r['minNights'])}+ ${t.pick('nocí', 'nights')}',
          asDouble(r['percent'])
        ));
      }
    }
    final byGuests = asMapList(l.raw['guestDiscounts'])
      ..sort((a, b) => asInt(a['minGuests']).compareTo(asInt(b['minGuests'])));
    for (final r in byGuests) {
      if (asInt(r['minGuests']) > 0 && asDouble(r['percent']) > 0) {
        discountRows.add((
          '${asInt(r['minGuests'])}+ ${t.pick('hostí', 'guests')}',
          asDouble(r['percent'])
        ));
      }
    }

    final seasons = asMapList(l.raw['flexiblePrices']).where((p) {
      if (asString(p['start']).isEmpty || asString(p['end']).isEmpty) {
        return false;
      }
      return asMapList(p['tiers']).any((x) => asDouble(x['price']) > 0);
    }).toList();

    final card = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.neutral100),
      boxShadow: const [
        BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1))
      ],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // The inline calendar (`SectionDateRange`): two months, arrows, legend.
      _InlineCalendar(
          listing: l, checkIn: checkIn, checkOut: checkOut, onChanged: onDates),
      const SizedBox(height: 24),
      // At lg the booking sidebar has the guests row.
      if (!context.lg)
        SearchTile(
          icon: Icons.group_outlined,
          label: t('guests', 'Hostia'),
          placeholder: t('Addguests', 'Vyberte počet hostí'),
          value: '${guests.total} ${t('guests', 'hostia').toLowerCase()}',
          onTap: onGuests,
        ),
      if (petAllowed)
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: withPet,
          onChanged: onPet,
          title: Text(
              t.pick('Cestujem s domácim zvieratkom', 'Travelling with a pet'),
              style: AppText.inter(size: 15, weight: FontWeight.w500)),
          subtitle: l.petFeePerNight > 0
              ? Text(
                  '${t('PetFee', 'Poplatok za zviera')} ${money(l.petFeePerNight)}/${t('night', 'noc')}',
                  style: AppText.inter(size: 13, color: AppColors.neutral500))
              : null,
        ),
      if (l.paidExtras.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(t.pick('Platené služby navyše', 'Paid extras'),
            style: AppText.inter(size: 15, weight: FontWeight.w700)),
        for (final e in l.paidExtras)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: extras.contains(asString(pick(e, 'amenity.en'))),
            onChanged: (_) => onExtra(asString(pick(e, 'amenity.en'))),
            title: Text(
                asString(
                    pick(e, 'amenity.$lang'), asString(pick(e, 'amenity.en'))),
                style: AppText.inter(size: 14)),
            secondary: Text(
              '${money(asDouble(e['price']))}${asString(e['pricing']) == 'per_night' ? '/${t('night', 'noc')}' : ''}',
              style: AppText.inter(size: 14, weight: FontWeight.w600),
            ),
          ),
      ],
      const SizedBox(height: 24),
      // Price box: `p-4 bg-neutral-50/70 border border-neutral-100 rounded-2xl`
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xB3FAFAFA),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.neutral100),
        ),
        child: quoting
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(color: _green)))
            : (quote != null && n > 0)
                ? Column(children: [
                    line(
                        '£${_n(double.parse(nightly.toStringAsFixed(2)))} × $n ${n == 1 ? t('night', 'noc') : t('nightsFew', 'noci')}',
                        '£${_n(cents(bd['accommodationCents'] != null ? 'accommodationCents' : 'subtotalCents'))}'),
                    if (asInt(bd['discountCents']) > 0)
                      line(t.pick('Zľava', 'Discount'),
                          '−£${_n(cents('discountCents'))}',
                          color: const Color(0xFF237A59)),
                    if (asInt(bd['cleaningFeeCents']) > 0)
                      line(t('CleaningFee', 'Upratovanie'),
                          '£${_n(cents('cleaningFeeCents'))}'),
                    if (asInt(bd['localTaxCents']) > 0)
                      line(t('LocalTax', 'Miestny poplatok'),
                          '£${_n(cents('localTaxCents'))}'),
                    if (asInt(bd['petFeeCents']) > 0)
                      line(t('PetFee', 'Poplatok za zviera'),
                          '£${_n(cents('petFeeCents'))}'),
                    if (asInt(bd['extrasCents']) > 0)
                      line(t.pick('Služby navyše', 'Extras'),
                          '£${_n(cents('extrasCents'))}'),
                    line(t('StayHubFees', 'Poplatky UK Stay Hub'), '£0'),
                    Container(
                      padding: const EdgeInsets.only(top: 12),
                      decoration: const BoxDecoration(
                          border: Border(
                              top: BorderSide(color: AppColors.neutral200))),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(t('TotalPrice', 'Spolu'),
                                style: AppText.inter(
                                    size: 16,
                                    weight: FontWeight.w700,
                                    color: AppColors.neutral900)),
                            Text('£${_n(quote!.total)}',
                                style: AppText.inter(
                                    size: 16,
                                    weight: FontWeight.w700,
                                    color: AppColors.neutral900)),
                          ]),
                    ),
                  ])
                : Column(children: [
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: '£${_n(l.pricePerNight)} ',
                            style: AppText.inter(
                                size: 20,
                                weight: FontWeight.w700,
                                color: AppColors.neutral900)),
                        TextSpan(
                            text: '/ ${t('night', 'noc')}',
                            style: AppText.inter(
                                size: 14, color: AppColors.neutral500)),
                      ]),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                        quoteError ??
                            t('SelectDatesToSeeTotal',
                                'Vyberte dátumy a uvidíte celkovú cenu'),
                        textAlign: TextAlign.center,
                        style: AppText.inter(
                            size: 14,
                            color: quoteError != null
                                ? AppColors.red
                                : AppColors.neutral500)),
                  ]),
      ),
      if (l.pricePerPerson > 0) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: card,
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(
                child: Text(t('PricePerPerson', 'Cena za osobu'),
                    style: AppText.inter(
                        size: 14,
                        weight: FontWeight.w700,
                        color: AppColors.neutral800))),
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: '£${_n(l.pricePerPerson)} ',
                  style: AppText.inter(
                      size: 20, weight: FontWeight.w800, color: _forest)),
              TextSpan(
                  text: t('PerPersonShort', '/ osoba'),
                  style: AppText.inter(
                      size: 12,
                      weight: FontWeight.w500,
                      color: AppColors.neutral500)),
            ])),
          ]),
        ),
      ],
      if (discountRows.isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: card,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.pick('Zľavy', 'Discounts'),
                style: AppText.inter(
                    size: 14,
                    weight: FontWeight.w700,
                    color: AppColors.neutral800)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in discountRows)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                      color: _green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text('${r.$1} · −${_n(r.$2)} %',
                      style: AppText.inter(
                          size: 14, weight: FontWeight.w600, color: _forest)),
                ),
            ]),
          ]),
        ),
      ],
      if (seasons.isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.only(top: 16),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.neutral100))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.calendar_month_outlined,
                    size: 16, color: Color(0xFFD97706)),
              ),
              const SizedBox(width: 8),
              Text(t('SeasonalPrices', 'Sezónne ceny'),
                  style: AppText.inter(
                      size: 16, weight: FontWeight.w700, color: _forest)),
            ]),
            const SizedBox(height: 16),
            for (var i = 0; i < seasons.length; i++) ...[
              if (i > 0) const SizedBox(height: 16),
              _SeasonCard(
                  period: seasons[i],
                  index: i,
                  hasDiscounts: discountRows.isNotEmpty),
            ],
          ]),
        ),
      ],
    ]);
  }
}

/// Two stacked months with prev/next arrows and the availability legend.
class _InlineCalendar extends ConsumerStatefulWidget {
  const _InlineCalendar(
      {required this.listing,
      required this.checkIn,
      required this.checkOut,
      required this.onChanged});
  final Listing listing;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final void Function(DateTime? a, DateTime? b) onChanged;
  @override
  ConsumerState<_InlineCalendar> createState() => _InlineCalendarState();
}

class _InlineCalendarState extends ConsumerState<_InlineCalendar> {
  int _offset = 0;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final l = widget.listing;
    Widget arrow(IconData i, VoidCallback? f) => InkWell(
          onTap: f,
          customBorder: const CircleBorder(),
          child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(i,
                  size: 22,
                  color: f == null
                      ? AppColors.neutral300
                      : const Color(0xFF111827))),
        );
    Widget legend(Widget dot, String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0x80FAFAFA),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.neutral100),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            dot,
            const SizedBox(width: 12),
            Text(text,
                style: AppText.inter(
                    size: 14,
                    weight: FontWeight.w500,
                    color: AppColors.neutral700)),
          ]),
        );
    Widget dot(String n,
            {Color bg = Colors.white,
            Color fg = AppColors.neutral900,
            bool strike = false,
            bool border = true}) =>
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: border ? Border.all(color: AppColors.neutral200) : null,
          ),
          child: Text(n,
              style: AppText.inter(size: 12, weight: FontWeight.w600, color: fg)
                  .copyWith(
                      decoration: strike ? TextDecoration.lineThrough : null)),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(children: [
        RangeCalendar(
          start: widget.checkIn,
          end: widget.checkOut,
          lang: t.lang,
          inline: true,
          months: 2,
          sideBySide: context.sm,
          monthOffset: _offset,
          nightBlocked: l.isNightBlocked,
          minNights: l.nightMin,
          maxNights: l.nightMax,
          onChanged: widget.onChanged,
          onRuleViolation: (r) {
            final msg = switch (r) {
              'min' =>
                '${t('Thisofferrequiresaminimumstayof', 'Minimálna dĺžka pobytu je')} ${l.nightMin} ${t('nights', 'nocí')}.',
              'max' =>
                '${t.pick('Maximálna dĺžka pobytu je', 'Maximum stay is')} ${l.nightMax} ${t('nights', 'nocí')}.',
              _ => t('PleaseselectdifferentdatesSomedatesareunavailable',
                  'Niektoré dni nie sú dostupné.'),
            };
            toast(context, msg, error: true);
          },
        ),
        Positioned(
          top: 4,
          left: 0,
          right: 0,
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            arrow(Icons.chevron_left_rounded,
                _offset > 0 ? () => setState(() => _offset--) : null),
            arrow(Icons.chevron_right_rounded,
                _offset < 10 ? () => setState(() => _offset++) : null),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        legend(
            dot('16',
                bg: AppColors.neutral100,
                fg: AppColors.neutral400,
                strike: true),
            t.pick('Obsadené / Nedostupné', 'Booked / Unavailable')),
        legend(dot('16'), t.pick('Dostupné', 'Available')),
        legend(
            dot('17',
                bg: const Color(0xFF2A8569), fg: Colors.white, border: false),
            t.pick('Vybrané dátumy', 'Selected dates')),
      ]),
    ]);
  }
}

class _SeasonCard extends ConsumerWidget {
  const _SeasonCard(
      {required this.period, required this.index, required this.hasDiscounts});
  final Json period;
  final int index;
  final bool hasDiscounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final fmt = DateFormat('d MMM yyyy', 'en_GB');
    String day(dynamic v) {
      final d = asDate(v);
      return d == null ? '' : fmt.format(d.toLocal());
    }

    String tierLabel(Json tier) {
      final min =
          asInt(tier['minNights'], 1) <= 0 ? 1 : asInt(tier['minNights'], 1);
      final hasMax =
          tier['maxNights'] != null && asString(tier['maxNights']).isNotEmpty;
      if (!hasMax) {
        return min == 1
            ? '1+ ${t('nights', 'noc')}'
            : '$min+ ${t('nights', 'nocí')}';
      }
      final max = asInt(tier['maxNights']);
      return min == max
          ? '$min ${t('nights', 'nocí')}'
          : '$min–$max ${t('nights', 'nocí')}';
    }

    String guestLabel(Json tier) {
      final min =
          asInt(tier['minGuests']) > 0 ? asInt(tier['minGuests']) : null;
      final max =
          asInt(tier['maxGuests']) > 0 ? asInt(tier['maxGuests']) : null;
      if (min == null && max == null) return '';
      final word = t.pick('hostia', 'guests');
      if (min != null && max != null) {
        return min == max ? '$min $word' : '$min–$max $word';
      }
      if (min != null) return '$min+ $word';
      return t.pick('do $max hostí', 'up to $max $word');
    }

    final tiers = asMapList(period['tiers'])
        .where((x) => asDouble(x['price']) > 0)
        .toList()
      ..sort((a, b) =>
          asInt(a['minNights'], 1).compareTo(asInt(b['minNights'], 1)));
    final note = asString(period['note']).trim();
    final name = asString(period['name']).isNotEmpty
        ? asString(period['name'])
        : '${t('SeasonNumber', 'Sezóna')} ${index + 1}';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x99E5E5E5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
              color: Color(0x80FAFAFA),
              border: Border(bottom: BorderSide(color: AppColors.neutral100))),
          child: Row(children: [
            Expanded(
              child: Text(name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.inter(
                      size: 12,
                      weight: FontWeight.w700,
                      color: AppColors.neutral500,
                      letterSpacing: 0.6)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.neutral200)),
              child: Text('${day(period['start'])} — ${day(period['end'])}',
                  style: AppText.inter(
                      size: 12,
                      weight: FontWeight.w600,
                      color: AppColors.neutral700)),
            ),
          ]),
        ),
        if (note.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: AppColors.neutral100))),
            child: Text(note,
                style: AppText.inter(
                    size: 14, color: AppColors.neutral600, height: 1.55)),
          ),
        if (period['applyDiscounts'] == false && hasDiscounts)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: AppColors.neutral100))),
            child: Text(
                t.pick('Zľavy sa na tieto ceny nevzťahujú.',
                    'Discounts do not apply to these prices.'),
                style: AppText.inter(
                    size: 12,
                    weight: FontWeight.w500,
                    color: AppColors.neutral500)),
          ),
        for (var i = 0; i < tiers.length; i++)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : const Border(
                        top: BorderSide(color: AppColors.neutral100))),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: tierLabel(tiers[i]),
                          style: AppText.inter(
                              size: 14,
                              weight: FontWeight.w500,
                              color: AppColors.neutral700)),
                      if (guestLabel(tiers[i]).isNotEmpty)
                        TextSpan(
                            text: ' · ${guestLabel(tiers[i])}',
                            style: AppText.inter(
                                size: 14,
                                weight: FontWeight.w500,
                                color: AppColors.neutral500)),
                    ])),
                  ),
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: '£${_n(asDouble(tiers[i]['price']))} ',
                        style: AppText.inter(
                            size: 18, weight: FontWeight.w700, color: _forest)),
                    TextSpan(
                        text: '/ ${t('night', 'noc')}',
                        style: AppText.inter(
                            size: 12,
                            weight: FontWeight.w500,
                            color: AppColors.neutral500)),
                  ])),
                ]),
          ),
      ]),
    );
  }
}

// ───────────────────────────── Stay info (renderSection2) ─────────────────────────────
class _StayInfo extends ConsumerStatefulWidget {
  const _StayInfo({required this.listing});
  final Listing listing;
  @override
  ConsumerState<_StayInfo> createState() => _StayInfoState();
}

class _StayInfoState extends ConsumerState<_StayInfo> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final l = widget.listing;
    final desc = l
        .description(t.lang)
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();

    final chips = <(int, String)>[
      (l.bedroom, t('Bedroom', 'Spálňa')),
      (l.doubleBed, t('DoubleBed', 'Manželská posteľ')),
      (l.singleBed, t('SingleBed', 'Jednolôžková posteľ')),
      (l.bunkBed, t('BunkBed', 'Poschodová posteľ')),
      (l.beds, t('Beds', 'Postele')),
      (l.kitchen, t('Kitchen', 'Kuchyňa')),
      (l.livingRoom, t('LivingRoom', 'Obývačka')),
      (asInt(l.raw['SocialRoom']), t('SocialRoom', 'Spoločenská miestnosť')),
      (asInt(l.raw['CommonRoom']), t('CommonRoom', 'Spoločná miestnosť')),
    ].where((c) => c.$1 > 0).toList();

    // Special offer banner (specialPrice).
    final sp = asMap(l.raw['specialPrice']);
    final spPrice = asDouble(sp['price']);
    final spStart = asDate(sp['start']);
    final spEnd = asDate(sp['end']);
    final dd = DateFormat('dd.MM.yy');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (spPrice > 0 && spStart != null && spEnd != null) ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0x99ECFDF5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD1FAE5)),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: Color(0xFFEF4444), shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('SpecialOffers', 'Špeciálna ponuka').toUpperCase(),
                          style: AppText.inter(
                              size: 11,
                              weight: FontWeight.w700,
                              color: AppColors.neutral500,
                              letterSpacing: 0.6)),
                      Text(
                          l.name(t.lang).trim().isNotEmpty
                              ? l.name(t.lang)
                              : t('SpecialOffers', 'Špeciálna ponuka'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.inter(
                              size: 14,
                              weight: FontWeight.w700,
                              color: _forest)),
                    ]),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFD1FAE5))),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t('Termin', 'Termín').toUpperCase(),
                              style: AppText.inter(
                                  size: 11,
                                  weight: FontWeight.w600,
                                  color: AppColors.neutral500)),
                          Text(
                              '${dd.format(spStart.toLocal())} — ${dd.format(spEnd.toLocal())}',
                              style: AppText.inter(
                                  size: 12,
                                  weight: FontWeight.w700,
                                  color: AppColors.neutral700)),
                        ]),
                    Text.rich(TextSpan(children: [
                      TextSpan(
                          text: '£${_n(spPrice)}',
                          style: AppText.inter(
                              size: 14,
                              weight: FontWeight.w800,
                              color: _forest)),
                      TextSpan(
                          text: ' / ${t('night', 'noc')}',
                          style: AppText.inter(
                              size: 12,
                              weight: FontWeight.w500,
                              color: AppColors.neutral500)),
                    ])),
                  ]),
            ),
          ]),
        ),
        const SizedBox(height: 24),
      ],
      Text(
        desc.isEmpty ? '—' : desc,
        maxLines: _more ? null : 4,
        overflow: _more ? TextOverflow.visible : TextOverflow.ellipsis,
        textAlign: TextAlign.justify,
        style:
            AppText.inter(size: 14, color: AppColors.neutral600, height: 1.625),
      ),
      GestureDetector(
        onTap: () => setState(() => _more = !_more),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
              _more
                  ? t('ShowLess', 'Zobraziť menej')
                  : t('ShowMore', 'Zobraziť viac'),
              style: AppText.inter(
                  size: 14,
                  weight: FontWeight.w600,
                  color: _link,
                  decoration: TextDecoration.underline)),
        ),
      ),
      const SizedBox(height: 24),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.only(top: 24),
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.neutral100))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('BedAndRoomLayout', 'Rozloženie postelí a izieb'),
              style: AppText.inter(
                  size: 18,
                  weight: FontWeight.w700,
                  color: AppColors.neutral900)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in chips)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.neutral50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.neutral200),
                ),
                child: Text('${c.$1}x ${c.$2}',
                    style: AppText.inter(
                        size: 14,
                        weight: FontWeight.w500,
                        color: AppColors.neutral700)),
              ),
          ]),
        ]),
      ),
    ]);
  }
}

// ───────────────────────────── Amenities (renderSection3) ─────────────────────────────
class _Amenities extends ConsumerWidget {
  const _Amenities({required this.listing});
  final Listing listing;

  static const _none = {'none', 'ziadne', 'žiadne'};

  static const _icons = <(String, IconData)>[
    ('wifi', Icons.wifi),
    ('televízia', Icons.tv),
    ('tv', Icons.tv),
    ('dishwasher', Icons.countertops_outlined),
    ('umývačka riadu', Icons.countertops_outlined),
    ('pc desk', Icons.desk_outlined),
    ('počítačový stôl', Icons.desk_outlined),
    ('pc stôl', Icons.desk_outlined),
    ('bathtub', Icons.bathtub_outlined),
    ('vaňa', Icons.bathtub_outlined),
    ('sauna', Icons.bathtub_outlined),
    ('vírivka', Icons.bathtub_outlined),
    ('hot tub', Icons.bathtub_outlined),
    ('shower', Icons.shower_outlined),
    ('sprcha', Icons.shower_outlined),
    ('air conditioning', Icons.air),
    ('klimatizácia', Icons.air),
    ('washing machine', Icons.local_laundry_service_outlined),
    ('práčka', Icons.local_laundry_service_outlined),
    ('dryer', Icons.local_laundry_service_outlined),
    ('sušička', Icons.local_laundry_service_outlined),
    ('žehlenie', Icons.local_laundry_service_outlined),
    ('dining table', Icons.restaurant),
    ('jedálenský stôl', Icons.restaurant),
    ('stovetop', Icons.restaurant),
    ('vonkajší jedálenský priestor', Icons.restaurant),
    ('vonkajšie stolovanie', Icons.restaurant),
    ('oven', Icons.microwave_outlined),
    ('refrigerator', Icons.kitchen_outlined),
    ('chladnička', Icons.kitchen_outlined),
    ('freezer', Icons.ac_unit),
    ('mraznička', Icons.ac_unit),
    ('coffee maker', Icons.coffee_outlined),
    ('kávovar', Icons.coffee_outlined),
    ('breakfast', Icons.coffee_outlined),
    ('ziadne', Icons.coffee_outlined),
    ('indoor fireplace', Icons.local_fire_department_outlined),
    ('vnútorný krb', Icons.local_fire_department_outlined),
    ('varná doska', Icons.local_fire_department_outlined),
    ('sporák', Icons.local_fire_department_outlined),
    ('rúra', Icons.local_fire_department_outlined),
    ('krb', Icons.local_fire_department_outlined),
    ('ohnisko', Icons.local_fire_department_outlined),
    ('firepit', Icons.local_fire_department_outlined),
    ('gril', Icons.local_fire_department_outlined),
    ('grill', Icons.local_fire_department_outlined),
    ('central heating', Icons.device_thermostat),
    ('ústredné kúrenie', Icons.thermostat_outlined),
    ('fire extinguisher', Icons.fire_extinguisher),
    ('hasiaci prístroj', Icons.fire_extinguisher),
    ('first aid kit', Icons.medical_services_outlined),
    ('lekárnička', Icons.medical_services_outlined),
    ('prvá pomoc', Icons.medical_services_outlined),
    ('indoor pool', Icons.pool),
    ('vnútorný bazén', Icons.pool),
    ('outdoor pool', Icons.beach_access_outlined),
    ('vonkajší bazén', Icons.beach_access_outlined),
    ('balcony', Icons.balcony),
    ('balkón', Icons.apartment),
    ('terrace', Icons.balcony),
    ('terasa', Icons.apartment),
    ('free parking on-site', Icons.local_parking),
    ('bezplatné parkovanie na mieste', Icons.local_parking),
    ('paid parking on-site', Icons.local_parking),
    ('platené parkovanie', Icons.local_parking),
    ('platené parkovanie na mieste', Icons.attach_money),
    ('public parking', Icons.local_parking),
    ('verejné parkovanie', Icons.local_parking),
    ('self check-in', Icons.door_front_door_outlined),
    ('samoobslužný check-in', Icons.door_front_door_outlined),
    ('samoobslužné ubytovanie', Icons.door_front_door_outlined),
    ('reception', Icons.room_service_outlined),
    ('recepcia', Icons.room_service_outlined),
    ('bez stravy', Icons.room_service_outlined),
    ('host greeting', Icons.handshake_outlined),
    ('privítanie hostiteľom', Icons.handshake_outlined),
    ('privítanie hostiteľa', Icons.handshake_outlined),
    ('no meals', Icons.no_meals_outlined),
    ('žiadne jedlá', Icons.no_meals_outlined),
    ('half board', Icons.restaurant),
    ('polpenzia', Icons.restaurant),
    ('full board', Icons.restaurant),
    ('plná penzia', Icons.restaurant),
    ('all-inclusive', Icons.star_outline_rounded),
  ];

  static IconData _icon(String name) {
    final n = name.toLowerCase().trim();
    for (final e in _icons) {
      if (n.contains(e.$1)) return e.$2;
    }
    return Icons.check_rounded;
  }

  /// Lower-case, accents stripped, letters and digits only.
  static String _norm(String v) {
    const from = 'áäčďéěíĺľňóôŕřšťúůýž';
    const to = 'aacdeeillnoorrstuuyz';
    final b = StringBuffer();
    for (final c in v.toLowerCase().split('')) {
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : c);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final lang = t.lang;
    final l = listing;

    List<String> list(String g) => l
        .amenities(g, lang)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !_none.contains(e.toLowerCase()))
        .toList();

    // Keys stay Slovak (the backend's data); only the heading is translated.
    final categories = <String, List<String>>{
      'Kúpeľňa': list('bathroomAmenities'),
      'Kuchyňa a jedáleň': [
        ...list('kitchenDiningAmenities'),
        ...list('meals')
      ],
      'Kúrenie a chladenie': list('heatingCoolingAmenities'),
      'Parkovanie': list('parkingFacilities'),
      'Vonkajšie priestory': list('outdoorAmenities'),
      'Ostatné': [
        ...list('safetyAmenities'),
        ...list('wellnessAmenities'),
        ...list('checkIn')
      ],
      'Internet a pracovňa': list('services'),
    };
    const labelKeys = {
      'Kúpeľňa': 'Bathroom',
      'Kuchyňa a jedáleň': 'KitchenandDining',
      'Kúrenie a chladenie': 'HeatingandCooling',
      'Parkovanie': 'CategoryParking',
      'Vonkajšie priestory': 'Outdoor',
      'Ostatné': 'CategoryOther',
      'Internet a pracovňa': 'CategoryInternetWorkspace',
    };

    final priority = <({String label, List<String> keys, String? category})>[
      (label: 'Wi-Fi', keys: ['wifi'], category: null),
      (
        label: t.pick('Parkovanie', 'Parking'),
        keys: ['parkovanie', 'parking'],
        category: null
      ),
      (
        label: t.pick('Klimatizácia', 'Air conditioning'),
        keys: ['klimatizacia', 'airconditioning'],
        category: null
      ),
      (
        label: t.pick('Kuchyňa', 'Kitchen'),
        keys: ['kuchyna', 'kitchen'],
        category: 'Kuchyňa a jedáleň'
      ),
      (
        label: t.pick('Práčka', 'Washing machine'),
        keys: ['pracka', 'washingmachine'],
        category: null
      ),
      (
        label: t.pick('Umývačka riadu', 'Dishwasher'),
        keys: ['umyvackariadu', 'dishwasher'],
        category: null
      ),
      (
        label: t.pick('Balkón/terasa', 'Balcony/terrace'),
        keys: ['balkon', 'terasa', 'balcony', 'terrace'],
        category: null
      ),
    ];

    // De-duplicated by lower-cased name, first position wins.
    final all = <String, String>{};
    for (final items in categories.values) {
      for (final i in items) {
        all.putIfAbsent(i.toLowerCase(), () => i);
      }
    }
    final allList = all.values.toList();

    final collapsed = <String>[];
    final missing = <String>[];
    for (final p in priority) {
      final found = firstWhereOrNull(allList, (String a) {
        final n = _norm(a);
        return p.keys.any(n.contains);
      });
      if (found != null) {
        if (!collapsed.contains(found)) collapsed.add(found);
      } else if (!(p.category != null &&
          (categories[p.category]?.isNotEmpty ?? false))) {
        missing.add(p.label);
      }
    }
    for (final a in allList) {
      if (collapsed.length >= 8) break;
      if (!collapsed.contains(a)) collapsed.add(a);
    }

    Widget item(String name, {bool missing = false}) => Opacity(
          opacity: missing ? 0.4 : 1,
          child: Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                  color: _green.withValues(alpha: 0.05),
                  shape: BoxShape.circle),
              child: Icon(_icon(name), size: 18, color: _green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(name,
                  style: AppText.inter(
                          size: 14,
                          weight: FontWeight.w600,
                          color: AppColors.neutral800)
                      .copyWith(
                          decoration:
                              missing ? TextDecoration.lineThrough : null)),
            ),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < collapsed.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 16),
        Row(children: [
          Expanded(child: item(collapsed[i])),
          const SizedBox(width: 16),
          Expanded(
              child: i + 1 < collapsed.length
                  ? item(collapsed[i + 1])
                  : const SizedBox.shrink()),
        ]),
      ],
      if (allList.length > 8) ...[
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(
                                t('WhatThisPlaceOffers',
                                    'Čo toto ubytovanie ponúka'),
                                style: AppText.fraunces(
                                    size: 24, color: _forest))),
                        InkWell(
                          onTap: () => Navigator.of(ctx).pop(),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                                color: AppColors.neutral100,
                                shape: BoxShape.circle),
                            child: const Icon(Icons.close,
                                size: 20, color: AppColors.neutral500),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 24),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                              maxHeight: MediaQuery.sizeOf(ctx).height * 0.6),
                          child: ListView(shrinkWrap: true, children: [
                            for (final cat in const [
                              'Kúpeľňa',
                              'Kuchyňa a jedáleň',
                              'Kúrenie a chladenie',
                              'Internet a pracovňa',
                              'Parkovanie',
                              'Vonkajšie priestory',
                              'Ostatné'
                            ])
                              if ((categories[cat] ?? const []).isNotEmpty) ...[
                                Text(t(labelKeys[cat]!, cat),
                                    style: AppText.inter(
                                        size: 18,
                                        weight: FontWeight.w700,
                                        color: AppColors.neutral900)),
                                const SizedBox(height: 16),
                                for (final i in categories[cat]!)
                                  Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 16),
                                      child: item(i)),
                                const SizedBox(height: 16),
                              ],
                            if (missing.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.only(top: 16),
                                decoration: const BoxDecoration(
                                    border: Border(
                                        top: BorderSide(
                                            color: AppColors.neutral200))),
                                child: Text(
                                    t('NotAvailable', 'Nie je k dispozícii'),
                                    style: AppText.inter(
                                        size: 18,
                                        weight: FontWeight.w700,
                                        color: AppColors.neutral900)),
                              ),
                              const SizedBox(height: 16),
                              for (final i in missing)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: item(i, missing: true)),
                            ],
                          ]),
                        ),
                      ),
                    ]),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${t('ShowAllAmenitiesPrefix', 'Zobraziť všetkých')} ${allList.length} ${t('AmenitiesCountWord', 'vybavení')}',
              style: AppText.inter(
                  size: 14,
                  weight: FontWeight.w600,
                  color: _link,
                  decoration: TextDecoration.underline),
            ),
          ),
        ),
      ],
    ]);
  }
}

// ───────────────────────────── Reviews (renderSection6 + CommentListing) ─────────────────────────────
class _Reviews extends ConsumerStatefulWidget {
  const _Reviews({required this.listing});
  final Listing listing;
  @override
  ConsumerState<_Reviews> createState() => _ReviewsState();
}

class _ReviewsState extends ConsumerState<_Reviews> {
  int _visible = 3;

  /// Mean of the category stars a guest gave, else their overall star row.
  static double _reviewRating(Json r) {
    final cats = asMap(r['categoryRatings'])
        .values
        .map((v) => asDouble(v))
        .where((v) => v > 0)
        .toList();
    if (cats.isNotEmpty) return cats.reduce((a, b) => a + b) / cats.length;
    return asDouble(r['overallRating']);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final lang = t.lang;
    final listing = widget.listing;
    final async = ref.watch(reviewsProvider(listing.id));
    final reviews = async.valueOrNull ??
        listing.reviewDocs.where((r) => r['reviewText'] != null).toList();
    final loading = async.isLoading && reviews.isEmpty;

    // Average of each rated category.
    final totals = <String, double>{};
    final counts = <String, int>{};
    for (final r in reviews) {
      asMap(r['categoryRatings']).forEach((k, v) {
        final d = asDouble(v);
        if (d <= 0) return;
        totals[k.toString()] = (totals[k.toString()] ?? 0) + d;
        counts[k.toString()] = (counts[k.toString()] ?? 0) + 1;
      });
    }
    final averages = {for (final k in totals.keys) k: totals[k]! / counts[k]!};
    final overall = _ratingFromReviews(reviews, 0);

    Widget stars(double v, double size) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (var s = 1; s <= 5; s++)
            Icon(Icons.star_rounded,
                size: size,
                color: s <= v.round()
                    ? AppColors.yellowStar
                    : AppColors.neutral300),
        ]);

    return _Section(
      title: t('Reviews', 'Hodnotenia'),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
            color: _green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.star_rounded, size: 13, color: _green),
          const SizedBox(width: 6),
          Text('${reviews.length}',
              style: AppText.inter(
                  size: 12, weight: FontWeight.w700, color: _forest)),
        ]),
      ),
      child: loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20), child: LoadingView())
          : reviews.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                      child: Text(t('Noreviewyet', 'Zatiaľ bez hodnotení'),
                          style: AppText.inter(
                              size: 16, color: AppColors.neutral500))),
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (averages.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xB3FAFAFA),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.neutral100),
                      ),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                t('AverageCategoryRatings',
                                    'Priemerné hodnotenia kategórií'),
                                style:
                                    AppText.fraunces(size: 16, color: _forest)),
                            const SizedBox(height: 4),
                            Container(
                                width: 40,
                                height: 3,
                                decoration: BoxDecoration(
                                    color: _green,
                                    borderRadius: BorderRadius.circular(3))),
                            const SizedBox(height: 16),
                            for (final e in averages.entries) ...[
                              Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(t(e.key, e.key),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppText.inter(
                                              size: 12,
                                              weight: FontWeight.w500,
                                              color: AppColors.neutral600)),
                                    ),
                                    Text(e.value.toStringAsFixed(1),
                                        style: AppText.inter(
                                            size: 12,
                                            weight: FontWeight.w700,
                                            color: _forest)),
                                  ]),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: (e.value / 5).clamp(0.0, 1.0),
                                  minHeight: 6,
                                  backgroundColor: const Color(0xCCE5E5E5),
                                  valueColor:
                                      const AlwaysStoppedAnimation(_green),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.only(top: 16),
                              decoration: const BoxDecoration(
                                  border: Border(
                                      top: BorderSide(
                                          color: AppColors.neutral100))),
                              child: Row(children: [
                                stars(overall, 16),
                                const SizedBox(width: 8),
                                Text('${overall.toStringAsFixed(1)} / 5',
                                    style: AppText.inter(
                                        size: 12,
                                        weight: FontWeight.w700,
                                        color: _forest)),
                              ]),
                            ),
                          ]),
                    ),
                    const SizedBox(height: 24),
                  ],
                  for (final r in reviews.take(_visible)) ...[
                    _ReviewCard(
                        review: r,
                        lang: lang,
                        rating: _reviewRating(r),
                        stars: stars),
                    const SizedBox(height: 20),
                  ],
                  if (_visible < reviews.length)
                    Center(
                      child: TextButton(
                        onPressed: () => setState(() => _visible += 3),
                        style: TextButton.styleFrom(
                          backgroundColor: const Color(0xFF357965),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999)),
                        ),
                        child: Text(t('Showmemore', 'Ukáž mi viac'),
                            style: AppText.inter(
                                size: 14,
                                weight: FontWeight.w500,
                                color: Colors.white)),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => context.push('/review/${listing.id}'),
                      style: TextButton.styleFrom(
                          foregroundColor: _forest, padding: EdgeInsets.zero),
                      icon: const Icon(Icons.rate_review_outlined, size: 18),
                      label: Text(
                          t.pick('Napísať hodnotenie', 'Write a review'),
                          style:
                              AppText.inter(size: 14, weight: FontWeight.w700)),
                    ),
                  ),
                ]),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard(
      {required this.review,
      required this.lang,
      required this.rating,
      required this.stars});
  final Json review;
  final String lang;
  final double rating;
  final Widget Function(double, double) stars;

  @override
  Widget build(BuildContext context) {
    final name = asString(
        review['name'], asString(pick(review, 'user.name'), 'Anonymous'));
    final date = asDate(review['createdAt']);
    final text = asString(review['reviewText']);
    final plus = asString(review['pluses']);
    final cons = asString(review['cons']);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.neutral100),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(
              child: Text(name,
                  style: AppText.inter(
                      size: 16,
                      weight: FontWeight.w700,
                      color: AppColors.neutral900))),
          const SizedBox(width: 8),
          Text(
              date == null
                  ? 'Unknown date'
                  : longDate(date.toLocal(), lang),
              style: AppText.inter(
                  size: 12,
                  weight: FontWeight.w500,
                  color: AppColors.neutral500)),
        ]),
        const SizedBox(height: 8),
        stars(rating, 16),
        const SizedBox(height: 12),
        if (text.isNotEmpty)
          Text(text,
              style: AppText.inter(
                  size: 14, color: AppColors.neutral600, height: 1.625)),
        if (plus.isNotEmpty || cons.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (plus.isNotEmpty)
              _pill('👍 $plus', const Color(0xFFECFDF5),
                  const Color(0xFF047857), const Color(0xFFD1FAE5)),
            if (cons.isNotEmpty)
              _pill('👎 $cons', const Color(0xFFFEF2F2),
                  const Color(0xFFB91C1C), const Color(0xFFFEE2E2)),
          ]),
        ],
      ]),
    );
  }

  static Widget _pill(String text, Color bg, Color fg, Color border) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border)),
        child: Text(text,
            style: AppText.inter(size: 12, weight: FontWeight.w600, color: fg)),
      );
}

// ───────────────────────────── Location (renderSection7) ─────────────────────────────
class _Location extends ConsumerWidget {
  const _Location({required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = listing;
    final place = [if (l.district.isNotEmpty) l.district, l.city].join(', ');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!context.sm) ...[
        const Divider(color: _border),
        const SizedBox(height: 16)
      ],
      Text(t('ListingLocationHeading', 'Miesto'),
          style:
              AppText.fraunces(size: 20, color: _forest, letterSpacing: -0.5)),
      const SizedBox(height: 4),
      Row(children: [
        const Icon(Icons.location_on_outlined, size: 15, color: _green),
        const SizedBox(width: 6),
        Expanded(
            child: Text(place,
                style: AppText.inter(
                    size: 12,
                    weight: FontWeight.w500,
                    color: AppColors.neutral600))),
      ]),
      const SizedBox(height: 4),
      Text(
          t('ExactAddressAfterBooking',
              'Presná adresa bude poskytnutá po potvrdení rezervácie.'),
          style: AppText.inter(size: 12, color: AppColors.neutral500)),
      const SizedBox(height: 4),
      Container(
          width: 48,
          height: 3,
          decoration: BoxDecoration(
              color: _green, borderRadius: BorderRadius.circular(3))),
      const SizedBox(height: 24),
      // `aspect-square rounded-2xl border bg-neutral-100`
      AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.neutral100,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xB3E5E5E5)),
          ),
          clipBehavior: Clip.antiAlias,
          child: l.hasCoords
              ? FlutterMap(
                  options: MapOptions(
                    initialCenter: LatLng(l.lat!, l.lng!),
                    initialZoom: 13,
                    interactionOptions: const InteractionOptions(
                        flags:
                            InteractiveFlag.pinchZoom | InteractiveFlag.drag),
                  ),
                  children: [
                    TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'uk.co.ukstayhub.app'),
                    CircleLayer(circles: [
                      CircleMarker(
                        point: LatLng(l.lat!, l.lng!),
                        radius: 400,
                        useRadiusInMeter: true,
                        color: _green.withValues(alpha: 0.18),
                        borderColor: _green,
                        borderStrokeWidth: 2,
                      ),
                    ]),
                  ],
                )
              : const Center(
                  child: Icon(Icons.location_on_outlined,
                      size: 32, color: _green)),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        t(
            'LocationMapApproximate',
            t.pick(
                'Mapa zobrazuje približnú oblasť. Presná adresa bude zdieľaná po potvrdení rezervácie.',
                'This map shows the approximate area. The exact address is shared after your booking is confirmed.')),
        style:
            AppText.inter(size: 12, color: AppColors.neutral500, height: 1.6),
      ),
    ]);
  }
}

// ───────────────────────────── Host (renderSection5) ─────────────────────────────
final _hostPlacesProvider = FutureProvider.family<int, String>(
    (ref, id) async => (await publicRepo.hostListings(id)).length);

class _HostBlock extends ConsumerWidget {
  const _HostBlock({required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final h = _hostOf(ref, listing);
    final id = asString(h['_id'], listing.hostId);
    // The website shows `host.name` only.
    final name = asString(h['name']).isNotEmpty
        ? asString(h['name'])
        : asString(h['displayName']);
    final photo = asString(h['photo']);
    final joined = asDate(h['createdAt']);
    final joinedText = joined == null
        ? 'Unknown'
        : DateFormat('LLLL yyyy', 'en_GB')
            .format(joined.toLocal());
    final places =
        id.isEmpty ? null : ref.watch(_hostPlacesProvider(id)).valueOrNull;

    Widget infoCard(IconData icon, String label, String value) => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x99E5E5E5)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1))
            ],
          ),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: _green.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 18, color: _green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label.toUpperCase(),
                        style: AppText.inter(
                            size: 11,
                            weight: FontWeight.w700,
                            color: AppColors.neutral500,
                            letterSpacing: 0.6)),
                    Text(value,
                        style: AppText.inter(
                            size: 14,
                            weight: FontWeight.w700,
                            color: AppColors.neutral800,
                            height: 1.35)),
                  ]),
            ),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: id.isEmpty ? null : () => context.push('/host-detail/$id'),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xB3FAFAFA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.neutral100),
          ),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2)),
                child: CircleAvatar(
                  radius: 30,
                  backgroundColor: AppColors.greenSoft,
                  backgroundImage: photo.isEmpty
                      ? null
                      : NetworkImage(cloudinary(photo, width: 160, ratio: 1)),
                  child: photo.isEmpty
                      ? Text(initials(name),
                          style: AppText.inter(
                              size: 20,
                              weight: FontWeight.w700,
                              color: Colors.white))
                      : null,
                ),
              ),
              if (asBool(h['isVerified']))
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                        color: _forest,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5)),
                    child:
                        const Icon(Icons.check, size: 11, color: Colors.white),
                  ),
                ),
            ]),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('hostedBy', 'Hostiteľ').toUpperCase(),
                        style: AppText.inter(
                            size: 11,
                            weight: FontWeight.w700,
                            color: AppColors.neutral500,
                            letterSpacing: 0.6)),
                    Text(name.isEmpty ? 'UK Stay Hub' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.inter(
                            size: 18,
                            weight: FontWeight.w700,
                            color: AppColors.neutral900,
                            height: 1.2)),
                    if (places != null)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                            color: _green.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.apartment, size: 13, color: _green),
                          const SizedBox(width: 6),
                          Text(
                              '$places ${places == 1 ? t('place', 'miesto') : t('places', 'miesta')}',
                              style: AppText.inter(
                                  size: 12,
                                  weight: FontWeight.w600,
                                  color: _forest)),
                        ]),
                      ),
                  ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      infoCard(Icons.calendar_today_outlined, t('Joinedin', 'Pripojil sa v'),
          joinedText),
      const SizedBox(height: 12),
      infoCard(Icons.chat_bubble_outline, t('Response', 'Odozva'),
          t('Responserate100', 'Miera odpovede - 100%')),
      const SizedBox(height: 12),
      infoCard(
          Icons.schedule,
          t('Speed', 'Rýchlosť'),
          t('Fastresponsewithinafewhours',
              'Rýchla odpoveď - do niekoľkých hodín')),
      if (id.isNotEmpty) ...[
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: () => context.push('/host-detail/$id'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.neutral300),
              ),
              child: Text(t('Seehostprofile', 'Zobraziť profil hostiteľa'),
                  style: AppText.inter(
                      size: 14,
                      weight: FontWeight.w500,
                      color: AppColors.neutral800)),
            ),
          ),
        ),
      ],
    ]);
  }
}

// ───────────────────────────── Things you should know (renderMergedRulesAndInfo) ─────────────────────────────
class _Rules extends ConsumerWidget {
  const _Rules({required this.listing});
  final Listing listing;

  /// 24-hour "14:00" from either "14:00" or a full ISO timestamp.
  static String _time(String s) {
    if (s.isEmpty) return '';
    if (s.contains('T')) {
      final d = DateTime.tryParse(s);
      return d == null ? '' : DateFormat('HH:mm').format(d.toLocal());
    }
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
    return m == null ? '' : '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}';
  }

  static String _range(String a, String b) =>
      {_time(a), _time(b)}.where((e) => e.isNotEmpty).join(' – ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = listing;
    final lang = t.lang;
    final policy = ref.watch(_policyProvider(l.id)).valueOrNull;

    final checkIn = _range(l.arrivalFrom, l.arrivalTo);
    final checkOut = _range(l.departureFrom, l.departureTo);
    final pet = l.policyValue('pet', lang);
    final petValue = pet.isNotEmpty && l.petFeePerNight > 0
        ? '$pet — £${_n(l.petFeePerNight)}/${t('night', 'noc')}'
        : pet;
    final rules = <(IconData, String, String)>[
      (Icons.pets_outlined, t('Pets', 'Domáce zvieratá'), petValue),
      (
        Icons.local_bar_outlined,
        t('PartyOrganizing', 'Večierky/podujatia'),
        l.policyValue('partyOrganizing', lang)
      ),
      (
        Icons.smoking_rooms_outlined,
        t('Smoking', 'Fajčenie'),
        l.policyValue('smoking', lang)
      ),
    ];
    final tagsRaw = l.raw['tags'];
    final extraRules = [
      for (final r in (tagsRaw is List ? tagsRaw : [tagsRaw]))
        if (r is String
            ? r.trim().isNotEmpty
            : (r is Map && asString(r[lang]).isNotEmpty))
          r is String ? r.trim() : asString((r as Map)[lang]),
    ];

    final tiers = asMapList(policy?['tiers']);
    const policyKeys = {
      'flexible': 'PolicyFlexible',
      'standard': 'PolicyStandard',
      'strict': 'PolicyStrict',
      'custom': 'PolicyCustom',
      'new_year_special': 'PolicyNewYearSpecial',
    };
    final policyType = asString(policy?['policy']);
    final policyName = policyType.isEmpty
        ? null
        : t(policyKeys[policyType] ?? '',
            policyType[0].toUpperCase() + policyType.substring(1));
    // HTML collapses the host's line breaks into one paragraph; so does the site.
    final cancelText =
        l.cancellationText.replaceAll(RegExp(r'\s+'), ' ').trim();
    final note = l.specialNote(lang);

    Widget timeCard(IconData icon, String label, String value) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xB3FAFAFA),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.neutral100),
          ),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: _green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: _green),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.toUpperCase(),
                  style: AppText.inter(
                      size: 12,
                      weight: FontWeight.w700,
                      color: AppColors.neutral500,
                      letterSpacing: 0.6)),
              const SizedBox(height: 2),
              Text(value,
                  style: AppText.inter(
                      size: 14,
                      weight: FontWeight.w600,
                      color: AppColors.neutral900)),
            ]),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (checkIn.isNotEmpty || checkOut.isNotEmpty) ...[
        if (checkIn.isNotEmpty)
          timeCard(Icons.login, t('Checkin', 'Check-in'), checkIn),
        if (checkIn.isNotEmpty && checkOut.isNotEmpty)
          const SizedBox(height: 16),
        if (checkOut.isNotEmpty)
          timeCard(Icons.logout, t('Checkout', 'Check-out'), checkOut),
        const SizedBox(height: 24),
      ],
      Text(t('HouseRules', 'Pravidlá domu'),
          style: AppText.inter(
              size: 18, weight: FontWeight.w700, color: AppColors.neutral900)),
      const SizedBox(height: 16),
      for (final r in rules) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xB3FAFAFA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.neutral100),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: _green.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12)),
                child: Icon(r.$1, size: 18, color: _green),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(r.$2,
                      style: AppText.inter(
                          size: 14,
                          weight: FontWeight.w700,
                          color: AppColors.neutral800))),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xB3E5E5E5)),
              ),
              child: Text(r.$3.isEmpty ? '—' : r.$3,
                  style: AppText.inter(
                      size: 12, weight: FontWeight.w600, color: _forest)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      if (extraRules.isNotEmpty) ...[
        const SizedBox(height: 0),
        for (final r in extraRules)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                  margin: const EdgeInsets.only(top: 7),
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                      color: _green, shape: BoxShape.circle)),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(r,
                      style: AppText.inter(
                          size: 14,
                          color: AppColors.neutral700,
                          height: 1.625))),
            ]),
          ),
      ],
      if (policy != null || cancelText.isNotEmpty) ...[
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.only(top: 24),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.neutral100))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Cancellationpolicy', 'Storno podmienky'),
                style: AppText.inter(
                    size: 18,
                    weight: FontWeight.w700,
                    color: AppColors.neutral900)),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xB3FAFAFA),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.neutral100),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                            color: _green.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.verified_user_outlined,
                            size: 18, color: _green),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(t('Cancellationpolicy', 'Storno podmienky'),
                            style: AppText.inter(
                                size: 14,
                                weight: FontWeight.w700,
                                color: _forest)),
                      ),
                      if (policyName != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _green.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: _green.withValues(alpha: 0.2)),
                          ),
                          child: Text(policyName.toUpperCase(),
                              style: AppText.inter(
                                  size: 12,
                                  weight: FontWeight.w700,
                                  color: const Color(0xFF257562),
                                  letterSpacing: 0.3)),
                        ),
                    ]),
                    if (tiers.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final tier in tiers)
                        Padding(
                          padding: const EdgeInsets.only(left: 48, bottom: 6),
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text('${asInt(tier['refundPercent'])}%',
                                    style: AppText.inter(
                                        size: 14,
                                        weight: FontWeight.w600,
                                        color: _forest)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    asInt(tier['hoursBefore']) == 0
                                        ? t('CancelLaterTier',
                                            'ak zrušíte neskôr')
                                        : '${t('CancelDaysBeforeTierPrefix', 'ak zrušíte aspoň')} ${(asInt(tier['hoursBefore']) / 24).round()} ${t('CancelDaysBeforeTierSuffix', 'dní pred príchodom')}',
                                    style: AppText.inter(
                                        size: 14, color: AppColors.neutral600),
                                  ),
                                ),
                              ]),
                        ),
                    ],
                    if (policy?['annualNonRefundableWindow'] != null &&
                        policy?['annualNonRefundableWindow'] != false)
                      Padding(
                        padding:
                            const EdgeInsets.only(left: 48, top: 4, bottom: 8),
                        child: Text(
                          t('PolicyNewYearSpecialWindow',
                              'Arrivals from Dec 28 through Jan 2 are non-refundable once paid (every year).'),
                          style: AppText.inter(
                              size: 14,
                              weight: FontWeight.w600,
                              color: AppColors.neutral700),
                        ),
                      ),
                    if (cancelText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 48, top: 4),
                        child: Text(cancelText,
                            style: AppText.inter(
                                size: 14,
                                color: AppColors.neutral600,
                                height: 1.625)),
                      ),
                  ]),
            ),
          ]),
        ),
      ],
      if (note.isNotEmpty) ...[
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.only(top: 24),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.neutral100))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('NotesFromHost', 'Poznámky od hostiteľa'),
                style: AppText.inter(
                    size: 18,
                    weight: FontWeight.w700,
                    color: AppColors.neutral900)),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0x80FFFBEB),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x99FEF3C7)),
              ),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.info_outline,
                        size: 20, color: Color(0xFFF59E0B))),
                const SizedBox(width: 14),
                Expanded(
                    child: Text(note,
                        style: AppText.inter(
                            size: 14,
                            color: AppColors.neutral700,
                            height: 1.625))),
              ]),
            ),
          ]),
        ),
      ],
    ]);
  }
}

final _policyProvider = FutureProvider.family<Json, String>(
    (ref, id) => publicRepo.cancellationPolicy(id));

// ───────────────────────────── Similar ─────────────────────────────
class _Similar extends ConsumerWidget {
  const _Similar({required this.listing});
  final Listing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    // Like the website: the latest listings, without this one, first four.
    final async = ref.watch(latestProvider);
    final items = (async.valueOrNull ?? const <Listing>[])
        .where((x) => x.id != listing.id)
        .take(4)
        .toList();
    if (async.isLoading) {
      return const SizedBox(height: 120, child: LoadingView());
    }
    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.neutral50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.neutral200),
        ),
        child: Text(
            t('NoSimilarAccommodations',
                'Nenašli sa žiadne podobné ubytovania.'),
            style: AppText.inter(size: 14, color: AppColors.neutral600)),
      );
    }
    final w = MediaQuery.of(context).size.width * 0.78;
    return SizedBox(
      height: w * 2 / 3 + 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (_, i) => SizedBox(
            width: w, child: StayCard(listing: items[i], showFavorite: false)),
      ),
    );
  }
}

// ───────────────────────────── Sticky booking bar (MobileFooterSticky.js) ─────────────────────────────
class _BookingBar extends ConsumerWidget {
  const _BookingBar({
    required this.listing,
    required this.checkIn,
    required this.checkOut,
    required this.guests,
    required this.quote,
    required this.quoting,
    required this.onDates,
    required this.onReserve,
  });
  final Listing listing;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final Guests guests;
  final Quote? quote;
  final bool quoting;
  final VoidCallback onDates;
  final VoidCallback onReserve;

  String _compact(DateTime? a, DateTime? b, String lang) {
    final f =
        DateFormat('d MMM', 'en_GB');
    return [a, b].whereType<DateTime>().map(f.format).join(' → ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = listing;
    final canSubmit = l.canBook;
    final label = l.isRequestMode
        ? t('RequestToBook', t.pick('Poslať žiadosť', 'Request to book'))
        : l.bookable
            ? t('Reserve', 'Rezervovať')
            : t('comingSoons', t.pick('Už čoskoro', 'Coming soon'));
    final hasDates = checkIn != null && checkOut != null;
    final price = AppText.inter(
        size: 17,
        weight: FontWeight.w700,
        color: _barText,
        letterSpacing: -0.2);
    final linkStyle = AppText.inter(
        size: 13,
        color: AppColors.neutral500,
        decoration: TextDecoration.underline);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF2FFFFFF),
        border: Border(top: BorderSide(color: AppColors.neutral100)),
        boxShadow: [
          BoxShadow(
              color: Color(0x0F000000), blurRadius: 24, offset: Offset(0, -4))
        ],
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (quote != null && hasDates) ...[
                      Text('£${_n(quote!.total)}', style: price),
                      GestureDetector(
                        onTap: () => _priceDetails(context, t),
                        child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                                t('Viewdetails', 'Zobraziť podrobnosti'),
                                style: linkStyle)),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(
                              text: '£${_n(l.pricePerNight)}', style: price),
                          TextSpan(
                              text: ' /${t('night', 'noc')}',
                              style: AppText.inter(
                                  size: 13, color: AppColors.neutral500)),
                        ])),
                      ),
                    GestureDetector(
                      onTap: onDates,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          !hasDates && checkIn == null
                              ? t('SelectDate', t('Adddates', 'Vyberte termín'))
                              : _compact(checkIn, checkOut, t.lang),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.inter(
                              size: 13,
                              color: const Color(0xFF1C1B1B),
                              decoration: TextDecoration.underline),
                        ),
                      ),
                    ),
                  ]),
            ),
            const SizedBox(width: 16),
            Opacity(
              opacity: canSubmit ? 1 : 0.5,
              child: GestureDetector(
                onTap: canSubmit ? (hasDates ? onReserve : onDates) : null,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    color: _bar,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: canSubmit
                        ? const [
                            BoxShadow(
                                color: Color(0x59238869),
                                blurRadius: 24,
                                offset: Offset(0, 8))
                          ]
                        : null,
                  ),
                  child: quoting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4, color: Colors.white))
                      : Text(label,
                          style: AppText.inter(
                              size: 15,
                              weight: FontWeight.w600,
                              color: Colors.white)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// The price-details popup (`showPricePopup`).
  void _priceDetails(BuildContext context, Strings t) {
    final q = quote;
    if (q == null) return;
    final bd = q.breakdown;
    double c(String k) => asInt(bd[k]) / 100;
    final n = nightsBetween(checkIn, checkOut);
    final accKey = bd['accommodationCents'] != null
        ? 'accommodationCents'
        : 'subtotalCents';
    final nightly = n > 0 ? c(accKey) / n : 0.0;
    final nightsLabel = n == 1 ? t('night', 'noc') : t('nights', 'nocí');

    Widget row(String a, String b, {Color? color, bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: Text(a,
                        style: AppText.inter(
                            size: 15,
                            weight: bold ? FontWeight.w700 : FontWeight.w400,
                            color: color ?? AppColors.neutral600))),
                const SizedBox(width: 16),
                Text(b,
                    style: AppText.inter(
                        size: bold ? 16 : 15,
                        weight: bold ? FontWeight.w700 : FontWeight.w500,
                        color: color ?? _barText)),
              ]),
        );

    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                      child: Text(t('PriceDetails', 'Podrobnosti o cene'),
                          style: AppText.inter(
                              size: 20,
                              weight: FontWeight.w600,
                              color: _barText))),
                  InkWell(
                    onTap: () => Navigator.of(ctx).pop(),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                          color: AppColors.neutral100, shape: BoxShape.circle),
                      child: const Icon(Icons.close,
                          size: 20, color: AppColors.neutral400),
                    ),
                  ),
                ]),
                const SizedBox(height: 20),
                row('£${_n(double.parse(nightly.toStringAsFixed(2)))} x $n $nightsLabel',
                    '£${_n(c(accKey))}'),
                if (asInt(bd['discountCents']) > 0)
                  row(t.pick('Zľava', 'Discount'),
                      '−£${_n(c('discountCents'))}',
                      color: _bar),
                if (asInt(bd['cleaningFeeCents']) > 0)
                  row(t('CleaningFee', 'Poplatok za upratovanie'),
                      '£${_n(c('cleaningFeeCents'))}'),
                if (asInt(bd['localTaxCents']) > 0)
                  row(t('LocalTax', 'Miestny poplatok'),
                      '£${_n(c('localTaxCents'))}'),
                if (asInt(bd['extrasCents']) > 0)
                  row(t.pick('Služby navyše', 'Extras'),
                      '£${_n(c('extrasCents'))}'),
                if (listing.petFeePerNight > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                        '${t('PetFee', 'Poplatok za zviera')} £${_n(listing.petFeePerNight)}/${t('night', 'noc')} · ${t('PetFeeAddedAtCheckout', 'pripočítané pri rezervácii')}',
                        style: AppText.inter(
                            size: 12, color: AppColors.neutral500)),
                  ),
                row(t('Servicecharge', 'Servisný poplatok'), '£0'),
                const Divider(color: AppColors.neutral100),
                const SizedBox(height: 12),
                row(t('Total', 'Spolu'), '£${_n(q.total)}', bold: true),
              ]),
        ),
      ),
    );
  }
}
