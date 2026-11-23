import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/json.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../state/providers.dart';
import '../state/search.dart';
import 'common.dart';
import 'range_calendar.dart';
import 'search_pickers.dart';

/// HeroComponent/MobileStaySearchForm.js – location, dates, guests, search.
class MobileSearchForm extends ConsumerWidget {
  const MobileSearchForm({super.key, this.onSearch, this.card = true, this.footer});
  final VoidCallback? onSearch;
  final bool card;

  /// HeroSearchForm's stats line under the button ("441+ overených ubytovaní").
  final Widget? footer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);

    final body = Column(mainAxisSize: MainAxisSize.min, children: [
      // MobileLocationInput: typed in place, suggestions under the field.
      const DestinationField(style: DestinationStyle.mobile),
      const SizedBox(height: 8),
      // MobileDatesInput: full-screen calendar.
      SearchTile(
        icon: Icons.calendar_month_outlined,
        label: t('CheckinCheckout', 'Príchod - Odchod'),
        value: s.checkIn == null ? null : rangeLabel(s.checkIn, s.checkOut, t.lang),
        placeholder: t('Adddates', 'Vyberte termín'),
        onTap: () => showDatesFullScreen(context, ref, phone: true),
        onClear: s.checkIn == null ? null : () => ref.read(searchProvider.notifier).setDates(null, null),
      ),
      const SizedBox(height: 8),
      // MobileGuestsInput1: the counters open inside the field.
      const _MobileGuestsTile(),
      const SizedBox(height: 10),
      PrimaryButton(
        label: t('Search', 'Nájdi overené ubytovanie'),
        icon: Icons.search,
        color: AppColors.greenSearch,
        radius: 18,
        height: 56,
        shadow: true,
        onPressed: () {
          onSearch?.call();
          context.push('/mapa');
        },
      ),
      if (footer != null) footer!,
    ]);

    if (!card) return body;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white),
        boxShadow: const [BoxShadow(color: Color(0x3D112A22), blurRadius: 60, spreadRadius: -18, offset: Offset(0, 24))],
      ),
      child: body,
    );
  }
}

class _MobileGuestsTile extends ConsumerStatefulWidget {
  const _MobileGuestsTile();
  @override
  ConsumerState<_MobileGuestsTile> createState() => _MobileGuestsTileState();
}

class _MobileGuestsTileState extends ConsumerState<_MobileGuestsTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final g = ref.watch(searchProvider).guests;
    final value = g.total == 0 ? null : '${g.total} ${t('guests', 'hostia').toLowerCase()}';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: _open ? Colors.white : AppColors.fieldBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _open ? AppColors.greenFocus : AppColors.fieldBorder),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            if (!_open && g.adults == 0) ref.read(searchProvider.notifier).setGuests(g.copyWith(adults: 1));
            setState(() => _open = !_open);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 70),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                const _TileIcon(Icons.group_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(t('guests', 'Hostia').toUpperCase(),
                        style: AppText.inter(size: 10, weight: FontWeight.w700, color: AppColors.muted, letterSpacing: 1.4, height: 1)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Flexible(
                        child: Text(value ?? t('Addguests', 'Vyberte počet hostí'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.inter(size: 15, weight: FontWeight.w600, color: value == null ? AppColors.neutral400 : AppColors.forestDark)),
                      ),
                      if (g.total > 0 && _open) ...[
                        const SizedBox(width: 6),
                        InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => ref.read(searchProvider.notifier).setGuests(const Guests(adults: 1)),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: const BoxDecoration(color: AppColors.neutral200, shape: BoxShape.circle),
                            child: const Icon(Icons.close, size: 14, color: AppColors.neutral700),
                          ),
                        ),
                      ],
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: EdgeInsets.fromLTRB(context.sm ? 32 : 24, 8, context.sm ? 32 : 24, 24),
                  child: const GuestCounters(),
                )
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.fieldBorder),
          boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2)],
        ),
        child: Icon(icon, size: 20, color: AppColors.green),
      );
}

/// HeroComponent/StaySearchForm.js – the md+ form: a 2-column grid, 4 columns on xl.
class DesktopSearchForm extends ConsumerWidget {
  const DesktopSearchForm({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);
    final g = s.guests;
    final lg = context.lg, xl = context.xl;
    final gap = lg ? 12.0 : 8.0;

    // DestinationPicker: typed in place, suggestions drop down under the field.
    const location = DestinationField();
    final dates = _DeskTile(
      icon: Icons.calendar_month_outlined,
      label: t('CheckinCheckout', 'Príchod - Odchod'),
      value: s.checkIn == null ? null : rangeLabel(s.checkIn, s.checkOut, t.lang),
      placeholder: t('Adddates', 'Vyberte termín'),
      // StayDatesRangeInput: centred two-month modal from xl, full screen below.
      onTap: () => xl ? showDatesModal(context, ref) : showDatesFullScreen(context, ref),
      onClear: s.checkIn == null ? null : () => ref.read(searchProvider.notifier).setDates(null, null),
    );
    final guests = _DeskTile(
      icon: Icons.group_outlined,
      label: t('guests', 'Hostia'),
      value: g.total == 0 ? null : '${g.total} ${t('guests', 'hostia').toLowerCase()}',
      placeholder: t('Addguests', 'Vyberte počet hostí'),
      // GuestsInput: centred "Hostia" modal.
      onTap: () => showGuestsModal(context, ref),
      onClear: g.total == 0 ? null : () => ref.read(searchProvider.notifier).setGuests(const Guests()),
    );
    final button = SizedBox(
      height: 68,
      child: PrimaryButton(
        label: t('Search', 'Nájdi overené ubytovanie'),
        icon: Icons.search,
        color: AppColors.greenDeep,
        radius: 20,
        height: 68,
        shadow: true,
        onPressed: () => context.push('/mapa'),
      ),
    );

    final grid = xl
        ? Row(children: [
            const Expanded(flex: 115, child: location),
            SizedBox(width: gap),
            Expanded(flex: 135, child: dates),
            SizedBox(width: gap),
            Expanded(flex: 100, child: guests),
            SizedBox(width: gap),
            Expanded(flex: 115, child: ConstrainedBox(constraints: const BoxConstraints(minWidth: 190), child: button)),
          ])
        : Column(children: [
            Row(children: [const Expanded(child: location), SizedBox(width: gap), Expanded(child: dates)]),
            SizedBox(height: gap),
            Row(children: [Expanded(child: guests), SizedBox(width: gap), Expanded(child: button)]),
          ]);

    return Container(
      padding: EdgeInsets.all(lg ? 12 : 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white),
        boxShadow: const [BoxShadow(color: Color(0x26112A22), blurRadius: 60, spreadRadius: -15, offset: Offset(0, 24))],
      ),
      child: grid,
    );
  }
}

class _DeskTile extends StatelessWidget {
  const _DeskTile({
    required this.icon,
    required this.label,
    required this.placeholder,
    required this.onTap,
    this.value,
    this.onClear,
  });
  final IconData icon;
  final String label;
  final String placeholder;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final has = value != null && value!.isNotEmpty;
    return Material(
      color: AppColors.fieldBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.fieldBorder),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: const Color(0xFFF0F5F2),
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: 68,
          child: Padding(
            padding: EdgeInsets.only(left: context.sm ? 20 : 16, right: onClear == null ? 16 : 4),
            child: Row(children: [
              Icon(icon, size: 20, color: AppColors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.mutedGreen, letterSpacing: 0.55)),
                  const SizedBox(height: 2),
                  Text(has ? value! : placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.inter(
                          size: context.xl ? 16 : 14,
                          weight: FontWeight.w600,
                          color: has ? AppColors.forestDark : AppColors.neutral400)),
                ]),
              ),
              if (onClear != null)
                IconButton(
                  onPressed: onClear,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.cancel, size: 18, color: AppColors.neutral400),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class SearchTile extends StatelessWidget {
  const SearchTile({
    super.key,
    required this.icon,
    required this.label,
    required this.placeholder,
    required this.onTap,
    this.value,
    this.onClear,
  });
  final IconData icon;
  final String label;
  final String placeholder;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final has = value != null && value!.isNotEmpty;
    return Material(
      color: AppColors.fieldBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.fieldBorder),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 70),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.fieldBorder),
                  boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2)],
                ),
                child: Icon(icon, size: 20, color: AppColors.green),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.inter(size: 10, weight: FontWeight.w700, color: AppColors.muted, letterSpacing: 1.4)),
                  const SizedBox(height: 6),
                  Text(has ? value! : placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.inter(
                          size: 15,
                          weight: FontWeight.w600,
                          color: has ? AppColors.forestDark : AppColors.neutral400)),
                ]),
              ),
              if (onClear != null)
                IconButton(
                  onPressed: onClear,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18, color: AppColors.neutral500),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Destination ─────────────────────────────
Future<void> openDestinationSheet(BuildContext context, WidgetRef ref) {
  final t = ref.read(stringsProvider);
  return showStayHubSheet(
    context,
    title: t.pick('Kam cestujete?', 'Where are you going?'),
    fullHeight: true,
    builder: (_) => const _DestinationPicker(),
  );
}

class _DestinationPicker extends ConsumerStatefulWidget {
  const _DestinationPicker();
  @override
  ConsumerState<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends ConsumerState<_DestinationPicker> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  CancelToken? _cancel;
  List<Json> _names = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _fetch(v.trim()));
  }

  Future<void> _fetch(String q) async {
    _cancel?.cancel();
    if (q.length < 2) {
      setState(() => _names = []);
      return;
    }
    final token = CancelToken();
    _cancel = token;
    setState(() => _loading = true);
    try {
      final r = await publicRepo.nameSuggestions(q, cancel: token);
      if (mounted && !token.isCancelled) setState(() => _names = r);
    } catch (_) {
      // Suggestions are optional; the typed text can still be searched.
    } finally {
      if (mounted && !token.isCancelled) setState(() => _loading = false);
    }
  }

  void _choose(Destination d) {
    ref.read(searchProvider.notifier).setDestination(d);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final q = searchKey(_ctrl.text);
    final regions = ref.watch(regionCardsProvider).valueOrNull ?? const <Region>[];
    final dests = ref.watch(destinationsProvider).valueOrNull ?? const <Json>[];

    final matchRegions = regions
        .where((r) => q.isEmpty || searchKey(r.name(t.lang)).contains(q) || r.cities.any((c) => searchKey(c).startsWith(q)))
        .take(q.isEmpty ? 6 : 4)
        .toList();
    final matchCities = dests
        .where((d) => q.isNotEmpty && searchKey(asString(d['nameSk'])).contains(q))
        .take(8)
        .toList();
    final popularCities = q.isEmpty ? dests.take(8).toList() : const <Json>[];

    Widget sectionTitle(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
          child: Text(s.toUpperCase(),
              style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500, letterSpacing: 0.6)),
        );

    Widget row(IconData icon, String title, String? sub, VoidCallback onTap) => ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.mint, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: AppColors.green, size: 20),
          ),
          title: Text(title, style: AppText.inter(size: 15, weight: FontWeight.w600, color: AppColors.neutral900)),
          subtitle: sub == null ? null : Text(sub, style: AppText.inter(size: 13, color: AppColors.neutral500)),
        );

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) _choose(Destination.city(v.trim()));
          },
          decoration: InputDecoration(
            hintText: t('Location', 'Lokalita'),
            prefixIcon: const Icon(Icons.search, color: AppColors.green),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
        ),
      ),
      Expanded(
        child: ListView(children: [
          if (q.isEmpty) sectionTitle(t.pick('Obľúbené destinácie s ponukami', 'Popular destinations with stays')),
          for (final r in matchRegions)
            row(Icons.landscape_outlined, r.name(t.lang), '${r.count} ${t('properties', 'ubytovaní')}',
                () => _choose(Destination.region(r.name(t.lang), r.cities, r.id))),
          for (final d in [...matchCities, ...popularCities])
            row(Icons.location_on_outlined, asString(d['nameSk']), '${asInt(d['count'])} ${t('properties', 'ubytovaní')}',
                () => _choose(Destination.city(asString(d['nameSk'])))),
          if (_names.isNotEmpty) sectionTitle(t.pick('Ubytovania', 'Stays')),
          for (final n in _names)
            row(Icons.home_outlined, asString(n['name']), titleCase(asString(pick(n, 'locationDetails.city'))),
                () => _choose(Destination.name(asString(n['name'])))),
          if (q.isNotEmpty && matchRegions.isEmpty && matchCities.isEmpty && _names.isEmpty && !_loading)
            row(Icons.search, '„${_ctrl.text.trim()}“', t.pick('Hľadať túto lokalitu', 'Search this place'),
                () => _choose(Destination.city(_ctrl.text.trim()))),
        ]),
      ),
    ]);
  }
}

// ───────────────────────────── Dates ─────────────────────────────
Future<void> openDatesSheet(BuildContext context, WidgetRef ref) {
  final t = ref.read(stringsProvider);
  final s = ref.read(searchProvider);
  return showStayHubSheet(
    context,
    title: t('CheckinCheckout', 'Príchod - Odchod'),
    fullHeight: true,
    builder: (_) => DatesSheetBody(
      initialStart: s.checkIn,
      initialEnd: s.checkOut,
      onSave: (a, b) => ref.read(searchProvider.notifier).setDates(a, b),
    ),
  );
}

class DatesSheetBody extends ConsumerStatefulWidget {
  const DatesSheetBody({
    super.key,
    required this.initialStart,
    required this.initialEnd,
    required this.onSave,
    this.listing,
  });
  final DateTime? initialStart;
  final DateTime? initialEnd;
  final void Function(DateTime? a, DateTime? b) onSave;
  final Listing? listing;

  @override
  ConsumerState<DatesSheetBody> createState() => _DatesSheetBodyState();
}

class _DatesSheetBodyState extends ConsumerState<DatesSheetBody> {
  late DateTime? _a = widget.initialStart;
  late DateTime? _b = widget.initialEnd;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final l = widget.listing;
    final n = nightsBetween(_a, _b);
    return Column(children: [
      Expanded(
        child: RangeCalendar(
          start: _a,
          end: _b,
          lang: t.lang,
          nightBlocked: l?.isNightBlocked,
          minNights: l?.nightMin ?? 1,
          maxNights: l?.nightMax ?? 365,
          onChanged: (a, b) => setState(() {
            _a = a;
            _b = b;
          }),
          onRuleViolation: (r) {
            final msg = switch (r) {
              'min' => '${t('Thisofferrequiresaminimumstayof', 'Minimálna dĺžka pobytu je')} ${l?.nightMin ?? 1} ${t('nights', 'nocí')}.',
              'max' => '${t.pick('Maximálna dĺžka pobytu je', 'Maximum stay is')} ${l?.nightMax ?? 365} ${t('nights', 'nocí')}.',
              _ => t('PleaseselectdifferentdatesSomedatesareunavailable', 'Niektoré dni nie sú dostupné.'),
            };
            toast(context, msg, error: true);
          },
        ),
      ),
      SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral200))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(_a == null ? t('Adddates', 'Vyberte termín') : rangeLabel(_a, _b, t.lang),
                    style: AppText.inter(size: 15, weight: FontWeight.w600, color: AppColors.neutral900)),
                if (n > 0)
                  Text('$n ${n == 1 ? t('night', 'noc') : t('nights', 'nocí')}',
                      style: AppText.inter(size: 13, color: AppColors.neutral500)),
                if (_a != null)
                  GestureDetector(
                    onTap: () => setState(() {
                      _a = null;
                      _b = null;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(t('Clearall', 'Vymazať'),
                          style: AppText.inter(size: 13, weight: FontWeight.w600, color: AppColors.neutral600, decoration: TextDecoration.underline)),
                    ),
                  ),
              ]),
            ),
            PrimaryButton(
              label: t('save', 'Uložiť'),
              expand: false,
              onPressed: (_a != null && _b == null)
                  ? null
                  : () {
                      widget.onSave(_a, _b);
                      Navigator.of(context).pop();
                    },
            ),
          ]),
        ),
      ),
    ]);
  }
}

// ───────────────────────────── Guests ─────────────────────────────
Future<void> openGuestsSheet(BuildContext context, WidgetRef ref, {int? max, bool pets = false, ValueChanged<Guests>? onSave, Guests? initial}) {
  final t = ref.read(stringsProvider);
  return showStayHubSheet(
    context,
    title: t('guests', 'Hostia'),
    builder: (_) => GuestsSheetBody(
      initial: initial ?? ref.read(searchProvider).guests,
      max: max,
      showPets: pets,
      onSave: onSave ?? (g) => ref.read(searchProvider.notifier).setGuests(g),
    ),
  );
}

class GuestsSheetBody extends ConsumerStatefulWidget {
  const GuestsSheetBody({super.key, required this.initial, required this.onSave, this.max, this.showPets = false});
  final Guests initial;
  final ValueChanged<Guests> onSave;
  final int? max;
  final bool showPets;

  @override
  ConsumerState<GuestsSheetBody> createState() => _GuestsSheetBodyState();
}

class _GuestsSheetBodyState extends ConsumerState<GuestsSheetBody> {
  late Guests _g = widget.initial;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final cap = widget.max;
    final full = cap != null && cap > 0 && _g.total >= cap;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Counter(
            label: t('Adults', 'Dospelí'),
            description: t.pick('Vek 13+', 'Ages 13 or above'),
            value: _g.adults,
            max: full ? _g.adults : 99,
            onChanged: (v) => setState(() => _g = _g.copyWith(adults: v)),
          ),
          const Divider(),
          Counter(
            label: t('Children', 'Deti'),
            description: t.pick('Vek 2–12', 'Ages 2–12'),
            value: _g.children,
            max: full ? _g.children : 99,
            onChanged: (v) => setState(() => _g = _g.copyWith(children: v)),
          ),
          const Divider(),
          Counter(
            label: t('Infants', 'Dojčatá'),
            description: t.pick('Do 2 rokov', 'Under 2'),
            value: _g.infants,
            max: full ? _g.infants : 99,
            onChanged: (v) => setState(() => _g = _g.copyWith(infants: v)),
          ),
          if (widget.showPets) ...[
            const Divider(),
            Counter(
              label: t.pick('Domáce zvieratá', 'Pets'),
              value: _g.pets,
              max: 5,
              onChanged: (v) => setState(() => _g = _g.copyWith(pets: v)),
            ),
          ],
          if (full)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${t('MaxGuestsReached', 'Maximálny počet hostí je')} $cap.',
                  style: AppText.inter(size: 13, color: AppColors.amber)),
            ),
          const SizedBox(height: 16),
          Row(children: [
            TextButton(
              onPressed: () => setState(() => _g = const Guests()),
              child: Text(t('Resetguests', 'Reset'),
                  style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral600, decoration: TextDecoration.underline)),
            ),
            const Spacer(),
            PrimaryButton(
              label: t('save', 'Uložiť'),
              expand: false,
              onPressed: () {
                widget.onSave(_g);
                Navigator.of(context).pop();
              },
            ),
          ]),
        ]),
      ),
    );
  }
}
