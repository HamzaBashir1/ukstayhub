import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'editor_fields.dart';
import 'editor_steps.dart';
import 'editor_steps2.dart';
import 'editor_steps3.dart';
import 'editor_steps4.dart';
import 'host_shell.dart';

// ───────────────────────────── List (AccommodationsList.js + ListingCard.js) ─────────────────────────────
const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

String _skCount(int n, String one, String few, String many) => '$n ${n == 1 ? one : (n >= 2 && n <= 4 ? few : many)}';

String _listingName(Json l, Strings t) {
  final a = asString(pick(l, 'data.name')).trim();
  if (a.isNotEmpty) return a;
  final b = asString(l['name']).trim();
  return b.isNotEmpty ? b : t.pick('Ponuka bez názvu', 'Unnamed listing');
}

String _listingLocation(Json l, Strings t) {
  final s = [asString(pick(l, 'data.city')).trim(), asString(pick(l, 'data.country')).trim()].where((e) => e.isNotEmpty).join(', ');
  return s.isEmpty ? t.pick('Lokalita nenastavená', 'Location not set') : s;
}

String? _cover(Json l) {
  final first = asList(pick(l, 'data.photoUrls')).firstOrNull;
  if (first is String) return first;
  if (first is Map) return asStringOrNull(first['url']);
  return null;
}

int _displayPercent(Json l) {
  final s = asString(l['status']);
  return s == 'LIVE' || s == 'READY' ? 100 : asInt(l['completionPercent']).clamp(0, 100);
}

/// statusPresentation(): label, description, badge colours.
({String label, String description, Color bg, Color fg, Color? border}) _status(String status, Strings t) {
  switch (status) {
    case 'PUBLISHED':
    case 'LIVE':
      return (label: t.pick('Zverejnené', 'Live'), description: t.pick('Viditeľné pre cestovateľov', 'Visible to travellers'), bg: const Color(0xFF16A34A), fg: Colors.white, border: null);
    case 'PENDING':
      return (label: t.pick('Na kontrole', 'In review'), description: t.pick('Čaká na schválenie', 'Awaiting approval'), bg: const Color(0xFFFFFBEB), fg: const Color(0xFF92400E), border: const Color(0xFFFDE68A));
    case 'READY':
      return (label: t.pick('Pripravené', 'Ready'), description: t.pick('Pripravené na zverejnenie', 'Ready to publish'), bg: const Color(0xFFF0FDF4), fg: const Color(0xFF15803D), border: const Color(0xFFBBF7D0));
    default:
      return (label: t.pick('Koncept', 'Draft'), description: t.pick('Nastavenie prebieha', 'Setup in progress'), bg: const Color(0xFFFFFBEB), fg: const Color(0xFFB45309), border: const Color(0xFFFDE68A));
  }
}

String? _nextStepTitle(Json l, Strings t) {
  if (asString(l['status']) != 'DRAFT') return null;
  final i = editorSteps.indexOf(asString(pick(l, 'data.lastVisitedStep')));
  if (i < 0) return null;
  final s = _stepTitles[editorSteps[i]];
  return s == null ? null : t.pick(s.$1, s.$2);
}

class HostListingsScreen extends ConsumerStatefulWidget {
  const HostListingsScreen({super.key});
  @override
  ConsumerState<HostListingsScreen> createState() => _HostListingsScreenState();
}

class _HostListingsScreenState extends ConsumerState<HostListingsScreen> {
  String _filter = 'ALL';
  bool _showRequirements = false;
  String? _adoptingId;

  Future<void> _create() async {
    try {
      final l = await hostRepo.createListing();
      ref.invalidate(hostListingsProvider);
      if (mounted) context.go('/host/listings/${asString(l['id'])}');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
  }

  Future<void> _openLegacy(Json listing) async {
    final id = asString(listing['accommodationId'], asString(listing['id']));
    if (_adoptingId != null) return;
    setState(() => _adoptingId = id);
    try {
      final draft = await hostRepo.adoptListing(id);
      ref.invalidate(hostListingsProvider);
      if (mounted) context.go('/host/listings/${asString(draft['id'], id)}');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _adoptingId = null);
    }
  }

  Future<void> _delete(Json listing) async {
    final t = ref.read(stringsProvider);
    final name = _listingName(listing, t);
    final wide = MediaQuery.sizeOf(context).width >= 640;
    Future<void> confirm() async {
      var id = asString(listing['id']);
      // A legacy row has no draft behind it; adopt first, then run the normal delete.
      if (listing['legacy'] == true) {
        final draft = await hostRepo.adoptListing(asString(listing['accommodationId'], id));
        id = asString(draft['id'], id);
      }
      await hostRepo.deleteListing(id);
    }

    final body = _DeleteListingBody(listing: listing, onConfirm: confirm);
    final done = wide
        ? await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => Dialog(
              backgroundColor: Colors.white,
              insetPadding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 448), child: body),
            ),
          )
        : await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            isDismissible: false,
            enableDrag: false,
            backgroundColor: Colors.white,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            builder: (_) => body,
          );
    if (done == true) {
      ref.invalidate(hostListingsProvider);
      if (mounted) toast(context, t.pick('Ponuka „$name“ bola vymazaná.', '"$name" was deleted.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(hostListingsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final listings = async.valueOrNull;
    final loaded = listings != null;
    final all = listings ?? const <Json>[];

    final counts = {'DRAFT': 0, 'READY': 0, 'LIVE': 0};
    for (final l in all) {
      final s = asString(l['status']);
      if (counts.containsKey(s)) counts[s] = counts[s]! + 1;
    }
    final activeFilter = _filter != 'ALL' && counts[_filter] == 0 ? 'ALL' : _filter;
    final visible = activeFilter == 'ALL' ? all : all.where((l) => asString(l['status']) == activeFilter).toList();

    final subtitle = loaded && all.isNotEmpty
        ? (t.isEn
            ? '${all.length} ${all.length == 1 ? 'property' : 'properties'} · ${counts['DRAFT']} ${counts['DRAFT'] == 1 ? 'draft' : 'drafts'}, ${counts['READY']} ready, ${counts['LIVE']} live'
            : '${_skCount(all.length, 'ubytovanie', 'ubytovania', 'ubytovaní')} · ${_skCount(counts['DRAFT']!, 'koncept', 'koncepty', 'konceptov')}, ${_skCount(counts['READY']!, 'pripravená', 'pripravené', 'pripravených')}, ${_skCount(counts['LIVE']!, 'zverejnená', 'zverejnené', 'zverejnených')}')
        : t.pick('Spravujte svoje ubytovania a koncepty.', 'Manage your properties and drafts.');

    final addButton = Material(
      color: _gold,
      borderRadius: BorderRadius.circular(12),
      elevation: 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _create,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.add, size: 20, color: _forest),
            const SizedBox(width: 8),
            Text(t.pick('Pridať ubytovanie', 'Add listing'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
          ]),
        ),
      ),
    );

    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.pick('Ubytovania', 'Listings'), style: AppText.inter(size: wide ? 30 : 24, weight: FontWeight.w700, color: _forest, letterSpacing: -0.6, height: 1.25)),
      const SizedBox(height: 8),
      Text(subtitle, style: AppText.inter(size: 15, color: AppColors.neutral500, height: 1.5)),
    ]);
    final showAdd = loaded && all.isNotEmpty;
    final sm = width >= 640;

    Widget content;
    if (!loaded && async.isLoading) {
      content = _grid(wide ? 2 : 1, [for (var i = 0; i < 2; i++) Container(height: 224, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)))]);
    } else if (!loaded && async.hasError) {
      content = Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFFECACA))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, size: 22, color: Color(0xFFDC2626)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.pick('Nepodarilo sa načítať vaše ponuky', "We couldn't load your listings"), style: AppText.inter(size: 18, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
                const SizedBox(height: 4),
                Text(t.pick('Skontrolujte pripojenie a skúste to znova.', 'Check your connection and try again.'), style: AppText.inter(size: 14, color: const Color(0xFFDC2626))),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => ref.invalidate(hostListingsProvider),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB91C1C),
              backgroundColor: Colors.white,
              side: const BorderSide(color: Color(0xFFFECACA)),
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
      );
    } else if (all.isEmpty) {
      content = _empty(t, wide);
    } else {
      content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (async.hasError) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDE68A))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.pick('Zobrazujú sa naposledy načítané ponuky. Posledné obnovenie zlyhalo.', 'Showing the last loaded listings. The latest refresh failed.'),
                  style: AppText.inter(size: 14, color: const Color(0xFF92400E), height: 1.4)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(hostListingsProvider),
                icon: const Icon(Icons.refresh, size: 14),
                label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF92400E),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFFFDE68A)),
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        if (all.length > 1) ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in const [('ALL', 'Všetky', 'All'), ('DRAFT', 'Koncepty', 'Drafts'), ('READY', 'Pripravené', 'Ready'), ('LIVE', 'Zverejnené', 'Live')])
              if (f.$1 == 'ALL' || counts[f.$1]! > 0) _chip(t.pick(f.$2, f.$3), f.$1 == 'ALL' ? all.length : counts[f.$1]!, activeFilter == f.$1, () => setState(() => _filter = f.$1)),
          ]),
          const SizedBox(height: 20),
        ],
        _grid(width >= 1280 ? 3 : (wide ? 2 : 1), [
          for (final l in visible)
            _ListingCard(
              key: ValueKey(asString(l['id'])),
              listing: l,
              adopting: _adoptingId == asString(l['accommodationId'], asString(l['id'])),
              onOpenLegacy: () => _openLegacy(l),
              onDelete: () => _delete(l),
            ),
        ], gap: wide ? 20 : 16),
      ]);
    }

    final padX = wide ? 0.0 : 16.0;
    return RefreshIndicator(
      color: _forest,
      onRefresh: () => ref.refresh(hostListingsProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1024),
              child: Padding(
                padding: EdgeInsets.fromLTRB(padX, wide ? 0 : 8, padX, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (sm)
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(child: titleBlock), if (showAdd) addButton])
                  else ...[
                    titleBlock,
                    if (showAdd) ...[const SizedBox(height: 16), addButton],
                  ],
                  SizedBox(height: wide ? 32 : 24),
                  content,
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, int count, bool active, VoidCallback onTap) => Material(
        color: active ? _forest : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: active ? _forest : AppColors.neutral200)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700, color: active ? Colors.white : AppColors.neutral600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: active ? Colors.white.withValues(alpha: 0.15) : AppColors.neutral100, borderRadius: BorderRadius.circular(99)),
                child: Text('$count', style: AppText.inter(size: 11, weight: FontWeight.w700, color: active ? Colors.white : AppColors.neutral600, height: 1.4)),
              ),
            ]),
          ),
        ),
      );

  /// grid-cols-N: equal-height rows.
  Widget _grid(int cols, List<Widget> items, {double gap = 16}) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += cols) {
      final slice = items.sublist(i, (i + cols).clamp(0, items.length));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var j = 0; j < cols; j++) ...[
            if (j > 0) SizedBox(width: gap),
            Expanded(child: j < slice.length ? slice[j] : const SizedBox()),
          ],
        ]),
      ));
      if (i + cols < items.length) rows.add(SizedBox(height: gap));
    }
    return Column(children: rows);
  }

  Widget _empty(Strings t, bool wide) => Container(
        padding: EdgeInsets.all(wide ? 64 : 32),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
        child: Column(children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: const Icon(Icons.house_outlined, size: 40, color: _gold),
          ),
          const SizedBox(height: 32),
          Text(t.pick('Pridajte svoje prvé ubytovanie', 'Add your first accommodation'),
              textAlign: TextAlign.center, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest)),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 384),
            child: Text(
              t.pick('Vyhraďte si približne 10 minút. Budete potrebovať údaje o ubytovaní, fotografie, ceny, dostupnosť a nastavenie výplat.',
                  'Set aside about 10 minutes. You will need property details, photos, pricing, availability, and payout readiness.'),
              textAlign: TextAlign.center,
              style: AppText.inter(size: 16, color: AppColors.neutral500, height: 1.625),
            ),
          ),
          const SizedBox(height: 40),
          Material(
            color: _forest,
            borderRadius: BorderRadius.circular(12),
            elevation: 2,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _create,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.add, size: 20, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(t.pick('Začať', 'Start'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: Colors.white)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => setState(() => _showRequirements = !_showRequirements),
            style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(t.pick('Čo budem potrebovať?', 'What will I need?'),
                style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest).copyWith(decoration: TextDecoration.underline, decorationColor: _gold, decorationThickness: 2)),
          ),
          if (_showRequirements) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 448),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: const Color(0xFFF8F4EA), borderRadius: BorderRadius.circular(16)),
                child: Text(
                  t.pick('Adresu a kapacitu, vybavenie, aspoň jednu fotografiu, cenu za noc, pravidlá, dostupnosť, voľbu kalendára a potvrdenie výplat.',
                      'Address and capacity, amenities, at least one photo, nightly price, house rules, availability, calendar choice, and payout acknowledgement.'),
                  style: AppText.inter(size: 14, color: AppColors.neutral700, height: 1.7),
                ),
              ),
            ),
          ],
        ]),
      );
}

class _ListingCard extends ConsumerWidget {
  const _ListingCard({super.key, required this.listing, required this.adopting, required this.onOpenLegacy, required this.onDelete});
  final Json listing;
  final bool adopting;
  final VoidCallback onOpenLegacy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final id = asString(listing['id']);
    final statusKey = asString(listing['status']);
    final st = _status(statusKey, t);
    final isDraft = statusKey == 'DRAFT';
    final legacy = asBool(listing['legacy']);
    final percent = _displayPercent(listing);
    final cover = _cover(listing);
    final slug = asStringOrNull(listing['slug']);
    final name = _listingName(listing, t);
    final saved = DateTime.tryParse(asString(listing['updatedAt']))?.toLocal();
    final savedText = saved == null ? null : DateFormat(t.isEn ? 'd MMM y, HH:mm' : 'd. M. y, HH:mm', 'en_GB').format(saved);
    final next = _nextStepTitle(listing, t);
    final label = switch (statusKey) {
      'READY' => t.pick('Skontrolovať a zverejniť', 'Review and publish'),
      'LIVE' => t.pick('Spravovať', 'Manage'),
      _ => t.pick('Pokračovať v nastavení', 'Continue setup'),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.neutral200),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
      ),
      child: Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 72,
                height: 72,
                child: cover == null
                    ? Container(color: AppColors.neutral100, child: const Icon(Icons.home_outlined, size: 28, color: AppColors.neutral300))
                    : NetImage(cloudinary(cover, width: 200, ratio: 1), cacheWidth: 200),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: slug != null ? 40 : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: st.bg, borderRadius: BorderRadius.circular(8), border: st.border == null ? null : Border.all(color: st.border!)),
                    child: Text(st.label.toUpperCase(), style: AppText.inter(size: 10, weight: FontWeight.w700, color: st.fg, letterSpacing: 0.5, height: 1.5)),
                  ),
                  const SizedBox(height: 4),
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest, height: 1.5)),
                  const SizedBox(height: 2),
                  Row(children: [
                    const Icon(Icons.location_on_outlined, size: 14, color: AppColors.neutral500),
                    const SizedBox(width: 4),
                    Expanded(child: Text(_listingLocation(listing, t), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500))),
                  ]),
                  if (savedText != null) ...[
                    const SizedBox(height: 4),
                    Text('${t.pick('Uložené', 'Saved')} $savedText', style: AppText.inter(size: 12, color: AppColors.neutral400)),
                  ],
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Flexible(child: Text(isDraft ? t.pick('Priebeh nastavenia', 'Setup progress') : st.description, style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral600))),
            Text('$percent%', style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral600)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(value: percent / 100, minHeight: 8, color: isDraft ? _gold : const Color(0xFF22C55E), backgroundColor: AppColors.neutral200),
          ),
          if (isDraft && next != null) ...[
            const SizedBox(height: 8),
            Text.rich(TextSpan(children: [
              TextSpan(text: '${t.pick('Ďalej', 'Next')}: ', style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
              TextSpan(text: next, style: AppText.inter(size: 12, weight: FontWeight.w700, color: _forest)),
            ])),
          ],
          Builder(builder: (_) {
            final accounts = ref.watch(hostStripeAccountsProvider).valueOrNull;
            final att = listingAttention(listing, accounts);
            Widget attentionButton(String step, String text) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: adopting ? null : (legacy ? onOpenLegacy : () => context.go('/host/listings/$id?step=$step')),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        const Icon(Icons.error_outline, size: 20, color: Color(0xFFDC2626)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(text, style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFB91C1C), height: 1.35))),
                      ]),
                    ),
                  ),
                );
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (att.calendar || att.readiness) const SizedBox(height: 12),
              if (att.calendar) attentionButton('calendar', t.pick('Vyberte, či ponúkate ubytovanie aj inde', 'Choose whether you offer this property elsewhere')),
              if (att.readiness) attentionButton('readiness', t.pick('Pripojte výplatný účet', 'Connect a payout account')),
              if (att.verifying)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12)),
                  child: Text(t.pick('Overenie prebieha', 'Verification in progress'), style: AppText.inter(size: 13, color: const Color(0xFF92400E))),
                ),
            ]);
          }),
          const Spacer(),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.only(top: 16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
            child: Row(children: [
              Expanded(
                child: Material(
                  color: _forest,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: adopting ? null : (legacy ? onOpenLegacy : () => context.go('/host/listings/$id${statusKey == 'READY' ? '?review=1' : ''}')),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        if (adopting) ...[
                          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                          const SizedBox(width: 8),
                          Text(t.pick('Otvára sa…', 'Opening…'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white)),
                        ] else ...[
                          Flexible(child: Text(legacy ? t.pick('Spravovať', 'Manage') : label, textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white))),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, size: 18, color: Colors.white),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: adopting ? null : onDelete,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
                  child: const Icon(Icons.delete_outline, size: 20, color: AppColors.neutral500),
                ),
              ),
            ]),
          ),
        ]),
        if (slug != null)
          Positioned(
            right: 0,
            top: 0,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => context.push('/listings/$slug'),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
                child: const Icon(Icons.north_east, size: 18, color: AppColors.neutral500),
              ),
            ),
          ),
      ]),
    );
  }
}

/// DeleteListingDialog.js – shared by the phone bottom sheet and the centred dialog.
class _DeleteListingBody extends ConsumerStatefulWidget {
  const _DeleteListingBody({required this.listing, required this.onConfirm});
  final Json listing;
  final Future<void> Function() onConfirm;
  @override
  ConsumerState<_DeleteListingBody> createState() => _DeleteListingBodyState();
}

class _DeleteListingBodyState extends ConsumerState<_DeleteListingBody> {
  bool _pending = false;
  bool _error = false;

  Future<void> _confirm() async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _error = false;
    });
    try {
      await widget.onConfirm();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final st = _status(asString(widget.listing['status']), t);
    final wide = MediaQuery.sizeOf(context).width >= 640;
    final keep = OutlinedButton(
      onPressed: _pending ? null : () => Navigator.of(context).pop(false),
      style: OutlinedButton.styleFrom(
        foregroundColor: _forest,
        side: const BorderSide(color: AppColors.neutral200, width: 2),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(t.pick('Ponechať ponuku', 'Keep listing'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
    );
    final del = FilledButton.icon(
      onPressed: _pending ? null : _confirm,
      icon: _pending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.delete_outline, size: 18),
      label: Text(
        _pending ? t.pick('Odstraňuje sa…', 'Deleting…') : (_error ? t.pick('Skúsiť znova', 'Try again') : t.pick('Vymazať ponuku', 'Delete listing')),
        style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFDC2626),
        disabledBackgroundColor: const Color(0xFFDC2626).withValues(alpha: 0.6),
        disabledForegroundColor: Colors.white,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    return PopScope(
      canPop: !_pending,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.warning_amber_rounded, size: 24, color: Color(0xFFDC2626)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.pick('Vymazať túto ponuku?', 'Delete this listing?'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
                const SizedBox(height: 4),
                Text(
                  t.pick('Ponuka a jej rozpracované nastavenie sa natrvalo odstránia. Túto akciu nie je možné vrátiť späť.',
                      'This permanently removes the listing and its setup progress. This cannot be undone.'),
                  style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.7),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_listingName(widget.listing, t), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
                  const SizedBox(height: 2),
                  Text(_listingLocation(widget.listing, t), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 13, color: AppColors.neutral500)),
                ]),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: st.bg, borderRadius: BorderRadius.circular(8), border: st.border == null ? null : Border.all(color: st.border!)),
                child: Text(st.label.toUpperCase(), style: AppText.inter(size: 11, weight: FontWeight.w700, color: st.fg, letterSpacing: 0.5, height: 1.2)),
              ),
            ]),
          ),
          if (_error) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFECACA))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.pick('Ponuka nebola vymazaná.', "The listing wasn't deleted."), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
                const SizedBox(height: 2),
                Text(t.pick('Skontrolujte pripojenie a skúste to znova.', 'Check your connection and try again.'), style: AppText.inter(size: 14, color: const Color(0xFFB91C1C))),
              ]),
            ),
          ],
          const SizedBox(height: 24),
          if (wide) Row(mainAxisAlignment: MainAxisAlignment.end, children: [keep, const SizedBox(width: 12), del]) else ...[del, const SizedBox(height: 12), keep],
        ]),
      ),
    );
  }
}

// ───────────────────────────── Editor (AccommodationForm + EditorStepper) ─────────────────────────────
const editorSteps = ['basics', 'location', 'spaces', 'amenities', 'photos', 'pricing', 'units', 'availability', 'calendar', 'readiness'];

const _stepTitles = {
  'basics': ('Základy', 'Basics'),
  'location': ('Lokalita', 'Location'),
  'spaces': ('Izby a hostia', 'Rooms & Guests'),
  'amenities': ('Vybavenie', 'Amenities'),
  'photos': ('Fotografie', 'Photos'),
  'pricing': ('Ceny', 'Pricing'),
  'units': ('Jednotky', 'Units'),
  'availability': ('Pravidlá', 'Policies'),
  'calendar': ('Dostupnosť a kalendáre', 'Availability & calendars'),
  'readiness': ('Výplatný účet', 'Payout Account'),
};

const _stepIcons = {
  'basics': Icons.home_outlined,
  'location': Icons.location_on_outlined,
  'spaces': Icons.bed_outlined,
  'amenities': Icons.checklist_rounded,
  'photos': Icons.image_outlined,
  'pricing': Icons.credit_card_outlined,
  'units': Icons.layers_outlined,
  'availability': Icons.calendar_today_outlined,
  'calendar': Icons.calendar_today_outlined,
  'readiness': Icons.account_balance_outlined,
};

/// hostEditorValidation.js REQUIREMENTS: server requirement id -> (step, sk, en).
const _requirements = {
  'name': ('basics', 'Názov ubytovania', 'Property name'),
  'propertyType': ('basics', 'Typ ubytovania', 'Property type'),
  'description': ('basics', 'Popis', 'Description'),
  'street': ('location', 'Ulica a číslo', 'Street address'),
  'city': ('location', 'Mesto', 'City'),
  'country': ('location', 'Krajina', 'Country'),
  'phoneNumber': ('location', 'Kontaktný telefón', 'Contact phone'),
  'guests': ('spaces', 'Počet hostí', 'Number of guests'),
  'bedrooms': ('spaces', 'Počet spální', 'Number of bedrooms'),
  'beds': ('spaces', 'Počet postelí', 'Number of beds'),
  'bathrooms': ('spaces', 'Počet kúpeľní', 'Number of bathrooms'),
  'amenities': ('amenities', 'Aspoň jedno vybavenie', 'At least one amenity'),
  'photoUrls': ('photos', 'Aspoň jedna fotografia', 'At least one photo'),
  'nightlyPrice': ('pricing', 'Cena za noc', 'Nightly price'),
  'minNights': ('pricing', 'Minimálny počet nocí', 'Minimum nights'),
  'checkIn': ('availability', 'Čas príchodu', 'Check-in time'),
  'checkOut': ('availability', 'Čas odchodu', 'Check-out time'),
  'availabilityConfirmed': ('calendar', 'Potvrdenie dostupnosti', 'Availability confirmation'),
  'calendarFeeds': ('calendar', 'Odkazy na kalendár', 'Calendar links'),
  'payoutAcknowledged': ('readiness', 'Potvrdenie podmienok výplat', 'Payout acknowledgement'),
};

const _autosaveDelay = Duration(milliseconds: 1500);

class ListingEditorScreen extends ConsumerStatefulWidget {
  const ListingEditorScreen({super.key, required this.id, this.step, this.review = false});
  final String id;

  /// `?step=` deep link (a step id) and `?review=1`, as on the website.
  final String? step;
  final bool review;
  @override
  ConsumerState<ListingEditorScreen> createState() => _ListingEditorScreenState();
}

class _ListingEditorScreenState extends ConsumerState<ListingEditorScreen> {
  Json? _listing;
  Json _data = {};
  int _step = 0;
  bool _dirty = false;
  String _savePhase = 'idle'; // idle | saving | failed
  DateTime? _savedAt;
  bool _publishing = false;
  bool _reviewReturn = false;
  final Set<String> _attempted = {};
  Object? _error;
  Timer? _timer;
  Future<bool>? _inflight;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final l = await hostRepo.listing(widget.id);
      if (!mounted) return;
      final data = asMap(l['data']);
      final last = editorSteps.indexOf(asString(data['lastVisitedStep']));
      final firstMissing = editorSteps.indexWhere((s) => !asStringList(l['completedSteps']).contains(s));
      setState(() {
        _listing = l;
        _data = {...data};
        final requested = widget.step == null ? -1 : editorSteps.indexOf(widget.step!);
        _step = requested >= 0 ? requested : (last >= 0 ? last : (firstMissing >= 0 ? firstMissing : 0));
        _savedAt = DateTime.tryParse(asString(l['updatedAt']));
      });
      if (widget.review && asString(l['status']) != 'LIVE') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openReview(validate: false);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void set(String key, dynamic value) {
    setState(() {
      _data[key] = value;
      _dirty = true;
    });
    _timer?.cancel();
    _timer = Timer(_autosaveDelay, () => _save());
  }

  /// Serialises saves: a second call waits for the first, then saves only if still dirty.
  Future<bool> _save() {
    _timer?.cancel();
    final prev = _inflight;
    late final Future<bool> f;
    f = () async {
      if (prev != null) await prev;
      if (!_dirty) return _savePhase != 'failed';
      return _doSave();
    }();
    _inflight = f;
    f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    });
    return f;
  }

  Future<bool> _doSave() async {
    final sent = {..._data};
    final sentJson = jsonEncode(sent);
    if (mounted) setState(() => _savePhase = 'saving');
    try {
      final l = await hostRepo.updateListing(widget.id, {...sent, 'lastVisitedStep': editorSteps[_step]});
      if (!mounted) return true;
      setState(() {
        _listing = l;
        // Edits typed while the request was in flight stay on screen and stay dirty.
        _dirty = jsonEncode(_data) != sentJson;
        _savePhase = 'idle';
        _savedAt = DateTime.tryParse(asString(l['updatedAt'])) ?? DateTime.now();
      });
      ref.invalidate(hostListingsProvider);
      ref.invalidate(hostDashboardProvider);
      if (_dirty) _timer = Timer(_autosaveDelay, () => _save());
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _savePhase = 'failed');
        toast(context, errorText(e), error: true);
      }
      return false;
    }
  }

  Map<String, String> get _errors => _attempted.contains(editorSteps[_step]) ? validateEditorStep(editorSteps[_step], _data, ref.read(stringsProvider)) : const {};

  /// Marks the current step attempted and reports whether it has no inline errors.
  bool _validateCurrent() {
    final id = editorSteps[_step];
    final errors = validateEditorStep(id, _data, ref.read(stringsProvider));
    setState(() => _attempted.add(id));
    if (errors.isNotEmpty) {
      // The error text renders on the next frame; then bring the first field with an error into view.
      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToEditorField(errors.keys.first));
    }
    return errors.isEmpty;
  }

  Future<void> _next() async {
    if (!_validateCurrent()) return;
    await _go(_step + 1);
  }

  Future<void> _go(int step) async {
    if (_dirty && !await _save()) return;
    if (!mounted) return;
    setState(() => _step = step.clamp(0, editorSteps.length - 1));
  }

  /// Saves the draft, then returns the site path Stripe should send the host back to.
  Future<String?> _beforeConnect() async {
    if (_dirty && !await _save()) return null;
    return '/host/listings/${widget.id}?step=readiness';
  }

  Future<void> _exit() async {
    if (_dirty || _inflight != null) {
      await _showLeave();
      return;
    }
    if (mounted) context.go('/host/listings');
  }

  Future<void> _saveAndExit() async {
    if (_dirty && !await _save()) {
      if (mounted) await _showLeave(failed: true);
      return;
    }
    if (mounted) context.go('/host/listings');
  }

  List<String> get _missing => asStringList(_listing?['missingRequirements']);
  bool get _canPublish => asBool(_listing?['canPublish']);
  String get _status => asString(_listing?['status']);

  Future<void> _publish() async {
    final t = ref.read(stringsProvider);
    if (_publishing || !_canPublish) return;
    setState(() => _publishing = true);
    try {
      if (_dirty && !await _save()) return;
      if (!_canPublish) return;
      final l = await hostRepo.publishListing(widget.id);
      ref.invalidate(hostListingsProvider);
      ref.invalidate(hostDashboardProvider);
      if (!mounted) return;
      setState(() => _listing = l);
      Navigator.of(context, rootNavigator: true).popUntil((r) => r is! PopupRoute);
      toast(context, t.pick('Úspešne zverejnené!', 'Published successfully!'));
    } catch (e) {
      // A timeout doesn't mean it failed: the server may have published the
      // listing after the app stopped waiting. Check before showing an error.
      if (e is ApiException && e.isTimeout) {
        try {
          final l = await hostRepo.listing(widget.id);
          if (asString(l['status']) == 'LIVE') {
            ref.invalidate(hostListingsProvider);
            ref.invalidate(hostDashboardProvider);
            if (!mounted) return;
            setState(() => _listing = l);
            Navigator.of(context, rootNavigator: true).popUntil((r) => r is! PopupRoute);
            toast(context, t.pick('Úspešne zverejnené!', 'Published successfully!'));
            return;
          }
        } catch (_) {}
        if (mounted) {
          toast(context, t.pick('Server odpovedá pomaly. Skúste to prosím znova o chvíľu.', 'The server is responding slowly. Please try again in a moment.'), error: true);
        }
        return;
      }
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _saveEdit() async {
    final t = ref.read(stringsProvider);
    if (!_validateCurrent()) return;
    if (_dirty && !await _save()) return;
    if (!mounted) return;
    final back = await _sheetOrDialog<bool>((ctx) => _SimpleConfirm(
          icon: Icons.check_circle_outline,
          iconBg: const Color(0xFFDCFCE7),
          iconFg: const Color(0xFF16A34A),
          title: t.pick('Zmeny uložené', 'Changes saved'),
          body: t.pick('Vaše úpravy sú uložené a zverejnená ponuka bola aktualizovaná.', 'Your edits are saved and the published listing has been updated.'),
          footnote: _savedAt == null ? null : '${t.pick('Uložené', 'Saved')} ${_fmtTime(_savedAt!, t)}',
          primary: t.pick('Pokračovať v úpravách', 'Keep editing'),
          secondary: t.pick('Späť na ponuky', 'Back to listings'),
        ));
    if (back == false && mounted) context.go('/host/listings');
  }

  Future<T?> _sheetOrDialog<T>(WidgetBuilder builder, {bool dismissible = true}) {
    final wide = MediaQuery.sizeOf(context).width >= 640;
    if (wide) {
      return showDialog<T>(
        context: context,
        barrierDismissible: dismissible,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 448), child: builder(ctx)),
        ),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: builder,
    );
  }

  Future<void> _showLeave({bool failed = false}) async {
    final t = ref.read(stringsProvider);
    final result = await _sheetOrDialog<String>(
      (ctx) => _LeaveBody(t: t, failed: failed, onSave: _save),
      dismissible: false,
    );
    if (!mounted) return;
    if (result == 'leave') {
      context.go('/host/listings');
    } else if (result == 'discard') {
      _timer?.cancel();
      _dirty = false;
      context.go('/host/listings');
    }
  }

  void _openReview({bool validate = true}) {
    final t = ref.read(stringsProvider);
    if (validate && !_validateCurrent()) return;
    final wide = MediaQuery.sizeOf(context).width >= 640;
    Widget builder(BuildContext ctx) => _PublishReview(
          t: t,
          read: () => this,
          onFix: (req) {
            final step = _requirements[req]?.$1;
            Navigator.of(ctx).pop();
            if (step != null) {
              setState(() {
                _step = editorSteps.indexOf(step);
                _attempted.add(step);
                _reviewReturn = true;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) => scrollToEditorField(req));
            }
          },
        );
    if (wide) {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(16),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 672), child: builder(ctx)),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        clipBehavior: Clip.antiAlias,
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: builder,
      );
    }
  }

  String _fmtTime(DateTime d, Strings t) {
    final l = d.toLocal();
    final sameDay = DateUtils.isSameDay(l, DateTime.now());
    return DateFormat(sameDay ? 'HH:mm' : 'd MMM, HH:mm', 'en_GB').format(l);
  }

  Widget _saveStatus(Strings t) {
    IconData icon;
    String text;
    var color = AppColors.neutral500;
    Widget? lead;
    if (_savePhase == 'saving') {
      lead = const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2));
      icon = Icons.sync;
      text = t.pick('Ukladá sa…', 'Saving…');
    } else if (_savePhase == 'failed') {
      icon = Icons.error_outline;
      text = t.pick('Neuložené', 'Not saved');
      color = const Color(0xFFDC2626);
    } else if (_dirty) {
      icon = Icons.timelapse;
      text = t.pick('Neuložené zmeny', 'Unsaved changes');
      color = const Color(0xFFB45309);
    } else {
      icon = Icons.check;
      text = _savedAt != null ? '${t.pick('Uložené', 'Saved')} ${_fmtTime(_savedAt!, t)}' : t.pick('Uložené', 'Saved');
      color = const Color(0xFF15803D);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      lead ?? Icon(icon, size: 15, color: color),
      const SizedBox(width: 6),
      Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 12, weight: FontWeight.w700, color: color))),
      if (_savePhase == 'failed') ...[
        const SizedBox(width: 8),
        TextButton(
          onPressed: _save,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            backgroundColor: const Color(0xFFFEF2F2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Color(0xFFFECACA))),
          ),
          child: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
        ),
      ],
    ]);
  }

  /// Setup attention (hostSetupAttention.js): the calendar answer is missing, or no payout account exists.
  bool _needsAttention(String stepId) {
    if (stepId == 'calendar') return platformAnswer(_data) == null;
    if (stepId == 'readiness') {
      final accounts = ref.watch(hostStripeAccountsProvider);
      if (!accounts.hasValue) return false;
      return effectivePayoutAccount(asStringOrNull(_data['payoutStripeAccountId']), accounts.value!) == null;
    }
    return false;
  }

  Widget _stepList(Strings t, {required List<String> done, required bool compact, required ValueChanged<int> onSelect}) => Column(children: [
        for (var i = 0; i < editorSteps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Builder(builder: (_) {
              final id = editorSteps[i];
              final active = i == _step;
              final complete = done.contains(id);
              return Material(
                color: active ? _forest : Colors.transparent,
                elevation: active ? 3 : 0,
                shadowColor: const Color(0x33000000),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelect(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 10 : 12),
                    child: Row(children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? Colors.white.withValues(alpha: 0.15) : (complete ? const Color(0xFFDCFCE7) : AppColors.neutral100),
                        ),
                        child: complete && !active
                            ? const Icon(Icons.check, size: 14, color: Color(0xFF15803D))
                            : Text('${i + 1}', style: AppText.inter(size: 12, weight: FontWeight.w700, color: active ? Colors.white : AppColors.neutral500)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(t.pick(_stepTitles[id]!.$1, _stepTitles[id]!.$2),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.inter(size: 14, weight: FontWeight.w700, color: active ? Colors.white : (complete ? _forest : AppColors.neutral500))),
                      ),
                      Icon(_stepIcons[id], size: 18, color: active || complete ? _gold : AppColors.neutral300),
                      if (_needsAttention(id)) ...[const SizedBox(width: 8), Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle))],
                    ]),
                  ),
                ),
              );
            }),
          ),
      ]);

  void _openSteps(Strings t, List<String> done, int pct) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      constraints: BoxConstraints(maxWidth: 512, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.pick('Kroky ponuky', 'Listing steps'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
                  Text('$pct% ${t.pick('dokončené', 'complete')}', style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500)),
                ]),
              ),
              InkWell(borderRadius: BorderRadius.circular(12), onTap: () => Navigator.pop(ctx), child: const SizedBox(width: 44, height: 44, child: Icon(Icons.close, size: 22, color: AppColors.neutral500))),
            ]),
          ),
          const Divider(height: 1, color: AppColors.neutral100),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: _stepList(t, done: done, compact: true, onSelect: (i) {
                Navigator.pop(ctx);
                _go(i);
              }),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (_error != null) return ErrorView(error: _error!, message: errorText(_error!), onRetry: _load);
    if (_listing == null) return const Center(child: CircularProgressIndicator(color: _gold));
    final width = MediaQuery.sizeOf(context).width;
    final lg = width >= 1024;
    final sm = width >= 640;
    final done = asStringList(_listing!['completedSteps']);
    final pct = _status == 'LIVE' || _status == 'READY' ? 100 : asInt(_listing!['completionPercent']).clamp(0, 100);
    final live = _status == 'LIVE';
    final stepId = editorSteps[_step];
    final title = t.pick(_stepTitles[stepId]!.$1, _stepTitles[stepId]!.$2);
    final isLast = _step == editorSteps.length - 1;

    Widget actionBar() => Container(
          padding: EdgeInsets.fromLTRB(lg ? 32 : 16, lg ? 20 : 12, lg ? 32 : 16, lg ? 20 : 12 + MediaQuery.paddingOf(context).bottom),
          decoration: BoxDecoration(
            color: lg ? AppColors.neutral50.withValues(alpha: 0.5) : Colors.white,
            border: Border(top: BorderSide(color: lg ? AppColors.neutral100 : AppColors.neutral200)),
            boxShadow: lg ? null : const [BoxShadow(color: Color(0x0F000000), blurRadius: 20, offset: Offset(0, -4))],
          ),
          child: Row(children: [
            if (_step > 0) ...[
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _go(_step - 1),
                child: Container(
                  height: 48,
                  constraints: const BoxConstraints(minWidth: 48),
                  padding: EdgeInsets.symmetric(horizontal: sm ? 16 : 0),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200, width: 2)),
                  child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.arrow_back, size: 20, color: _forest),
                    if (sm) ...[const SizedBox(width: 8), Text(t.pick('Späť', 'Back'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest))],
                  ]),
                ),
              ),
              SizedBox(width: sm ? 12 : 8),
            ],
            Expanded(
              flex: sm ? 0 : 1,
              child: OutlinedButton(
                onPressed: _savePhase == 'saving' ? null : _saveAndExit,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _forest,
                  side: const BorderSide(color: AppColors.neutral200, width: 2),
                  minimumSize: Size(sm ? 0 : 0, 48),
                  padding: EdgeInsets.symmetric(horizontal: sm ? 24 : 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(_savePhase == 'saving' ? t.pick('Ukladá sa…', 'Saving…') : t.pick('Uložiť a odísť', 'Save & exit'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, weight: FontWeight.w700)),
              ),
            ),
            if (sm) const Spacer(),
            SizedBox(width: sm ? 12 : 8),
            Expanded(
              flex: sm ? 0 : 1,
              child: !isLast
                  ? FilledButton(
                      onPressed: _savePhase == 'saving' ? null : _next,
                      style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), padding: EdgeInsets.symmetric(horizontal: sm ? 32 : 16), elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(t.pick('Ďalej', 'Next'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white)),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward, size: 18, color: Colors.white),
                      ]),
                    )
                  : live
                      ? FilledButton.icon(
                          onPressed: _savePhase == 'saving' ? null : _saveEdit,
                          icon: const Icon(Icons.check_circle_outline, size: 18),
                          label: Text(_savePhase == 'saving' ? t.pick('Ukladá sa…', 'Saving…') : t.pick('Uložiť úpravy', 'Save edit'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white)),
                          style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), padding: EdgeInsets.symmetric(horizontal: sm ? 32 : 16), elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        )
                      : FilledButton(
                          onPressed: _savePhase == 'saving' ? null : _openReview,
                          style: FilledButton.styleFrom(backgroundColor: _gold, foregroundColor: _forest, minimumSize: const Size(0, 48), padding: EdgeInsets.symmetric(horizontal: sm ? 32 : 16), elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          child: Text(t.pick('Náhľad', 'Review'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                        ),
            ),
          ]),
        );

    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '* ', style: AppText.inter(size: 13, weight: FontWeight.w500, color: const Color(0xFFDC2626))),
          TextSpan(text: t.pick('označuje údaje povinné pred zverejnením.', 'marks information required before publishing.'), style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500)),
        ])),
      ),
      if (live)
        Container(
          margin: const EdgeInsets.only(bottom: 24),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFBBF7D0))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.check_circle_outline, size: 20, color: Color(0xFF16A34A)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.pick('Táto ponuka je zverejnená', 'This listing is live'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF14532D))),
                const SizedBox(height: 2),
                Text(
                  t.pick('Uložené zmeny sa prejavia v zverejnenej ponuke. Ak odstránite povinný údaj, vráti sa do konceptu.', 'Saved changes update the published listing. It returns to draft if a required detail is removed.'),
                  style: AppText.inter(size: 13, color: const Color(0xFF166534), height: 1.4),
                ),
              ]),
            ),
          ]),
        ),
      if (_reviewReturn)
        Container(
          margin: const EdgeInsets.only(bottom: 24),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16), border: Border.all(color: _gold.withValues(alpha: 0.6))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.pick('Opravte zvýraznenú položku a potom sa vráťte ku kontrole pred zverejnením.', 'Fix the highlighted item, then return to the publish review.'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: _forest)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                if (_dirty && !await _save()) return;
                if (!mounted) return;
                setState(() => _reviewReturn = false);
                _openReview();
              },
              style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text(t.pick('Späť na kontrolu', 'Return to review'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
            ),
          ]),
        ),
      _StepBody(key: ValueKey(stepId), step: stepId, data: _data, set: set, listingId: widget.id, errors: _errors, publishedId: asStringOrNull(_listing?['accommodationId']), beforeConnect: _beforeConnect),
    ]);

    // ───── phone / tablet (<1024): sticky header, scrolling body, fixed action bar
    if (!lg) {
      final bar = _mobileHeader(t, title, pct, done);
      return PopScope(
        canPop: !_dirty && _inflight == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _showLeave();
        },
        child: Column(children: [
          bar,
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
              children: [Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1024), child: body))],
            ),
          ),
          actionBar(),
        ]),
      );
    }

    // ───── desktop (>=1024): 18rem sidebar + card
    return PopScope(
      canPop: !_dirty && _inflight == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showLeave();
      },
      child: ListView(padding: const EdgeInsets.only(top: 0, bottom: 32), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1024),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 288,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  InkWell(
                    onTap: _exit,
                    child: SizedBox(
                      height: 44,
                      child: Row(children: [
                        const Icon(Icons.arrow_back, size: 18, color: AppColors.neutral500),
                        const SizedBox(width: 8),
                        Text(t.pick('Späť na ponuky', 'Back to listings'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.neutral500)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(t.pick('Dokončenie', 'Completion'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
                    Text('$pct%', style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: pct / 100, minHeight: 8, color: _gold, backgroundColor: AppColors.neutral100)),
                  const SizedBox(height: 12),
                  SizedBox(height: 24, child: Align(alignment: Alignment.centerLeft, child: _saveStatus(t))),
                  const SizedBox(height: 24),
                  _stepList(t, done: done, compact: false, onSelect: _go),
                ]),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(color: AppColors.neutral50.withValues(alpha: 0.5), border: const Border(bottom: BorderSide(color: AppColors.neutral100))),
                      child: Row(children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
                          child: Icon(_stepIcons[stepId], size: 28, color: _forest),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest)),
                            const SizedBox(height: 4),
                            Text('${t.pick('Krok ', 'Step ')}${_step + 1} ${t.pick('z', 'of')} ${editorSteps.length}', style: AppText.inter(size: 15, weight: FontWeight.w500, color: AppColors.neutral500)),
                          ]),
                        ),
                      ]),
                    ),
                    Padding(padding: const EdgeInsets.all(32), child: body),
                    actionBar(),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _mobileHeader(Strings t, String title, int pct, List<String> done) {
    return Container(
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), border: const Border(bottom: BorderSide(color: AppColors.neutral200))),
      child: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 56,
              child: Row(children: [
                OutlinedButton.icon(
                  onPressed: () => _openSteps(t, done, pct),
                  icon: const Icon(Icons.checklist_rounded, size: 18, color: _gold),
                  label: Text(t.pick('Kroky', 'Steps'), style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest)),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.neutral200), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                ),
                const Spacer(),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: _step > 0 ? IconButton(onPressed: () => _go(_step - 1), icon: const Icon(Icons.arrow_back, size: 22, color: _forest), tooltip: t.pick('Predchádzajúci krok', 'Previous step')) : null,
                ),
                Flexible(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${t.pick('KROK', 'STEP')} ${_step + 1} / ${editorSteps.length}', style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1.5)),
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest, height: 1.25)),
                  ]),
                ),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: _step < editorSteps.length - 1 ? IconButton(onPressed: _next, icon: const Icon(Icons.arrow_forward, size: 22, color: _forest), tooltip: t.pick('Ďalší krok', 'Next step')) : null,
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: _saveAndExit,
                icon: const Icon(Icons.logout, size: 16),
                label: Text(t.pick('Uložiť a ísť na prehľad', 'Save & Exit to Dashboard'), style: AppText.inter(size: 12, weight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.neutral600,
                  backgroundColor: AppColors.neutral50,
                  side: const BorderSide(color: AppColors.neutral200),
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Align(alignment: Alignment.centerRight, child: _saveStatus(t))),
              const SizedBox(width: 12),
              Text('$pct%', style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500)),
            ]),
          ),
          Container(
            height: 4,
            color: AppColors.neutral200,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(widthFactor: pct / 100, child: Container(color: _gold)),
          ),
        ]),
      ),
    );
  }
}

class _SimpleConfirm extends StatelessWidget {
  const _SimpleConfirm({required this.icon, required this.iconBg, required this.iconFg, required this.title, required this.body, this.footnote, required this.primary, required this.secondary});
  final IconData icon;
  final Color iconBg;
  final Color iconFg;
  final String title;
  final String body;
  final String? footnote;
  final String primary;
  final String secondary;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 40, height: 40, decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle), child: Icon(icon, size: 22, color: iconFg)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.inter(size: 17, weight: FontWeight.w700, color: _forest)),
                  const SizedBox(height: 4),
                  Text(body, style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.45)),
                  if (footnote != null) ...[const SizedBox(height: 4), Text(footnote!, style: AppText.inter(size: 12, color: AppColors.neutral400))],
                ]),
              ),
            ]),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text(primary, style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral200, width: 2), minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text(secondary, style: AppText.inter(size: 14, weight: FontWeight.w700)),
            ),
          ]),
        ),
      );
}

/// LeaveEditorDialog.js
class _LeaveBody extends StatefulWidget {
  const _LeaveBody({required this.t, required this.failed, required this.onSave});
  final Strings t;
  final bool failed;
  final Future<bool> Function() onSave;
  @override
  State<_LeaveBody> createState() => _LeaveBodyState();
}

class _LeaveBodyState extends State<_LeaveBody> {
  bool _saving = false;
  late bool _error = widget.failed;

  Future<void> _saveAndLeave() async {
    setState(() {
      _saving = true;
      _error = false;
    });
    final ok = await widget.onSave();
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, 'leave');
    } else {
      setState(() {
        _saving = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 48, height: 48, decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.warning_amber_rounded, size: 24, color: Color(0xFFD97706))),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.pick('Neuložené zmeny', 'Unsaved changes'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
                  const SizedBox(height: 4),
                  Text(t.pick('Niektoré úpravy tejto ponuky ešte nie sú uložené. Pred odchodom ich uložte, alebo ich zahoďte.', "Some of your edits haven't been saved to this listing yet. Save them before leaving, or discard them."),
                      style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.7)),
                ]),
              ),
            ]),
            if (_error) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFECACA))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.pick('Zmeny sa nepodarilo uložiť.', "The changes couldn't be saved."), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
                  const SizedBox(height: 2),
                  Text(t.pick('Skontrolujte pripojenie a skúste to znova, alebo zostaňte a pokračujte v úprave.', 'Check your connection and try again, or stay and keep editing.'), style: AppText.inter(size: 14, color: const Color(0xFFB91C1C))),
                ]),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _saveAndLeave,
              icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
              label: Text(_saving ? t.pick('Ukladá sa…', 'Saving…') : (_error ? t.pick('Skúsiť uložiť znova', 'Try saving again') : t.pick('Uložiť a odísť', 'Save and leave')), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
              style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _saving ? null : () => Navigator.pop(context, 'discard'),
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), side: const BorderSide(color: Color(0xFFFECACA), width: 2), minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text(t.pick('Zahodiť neuložené zmeny', 'Discard unsaved changes'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _saving ? null : () => Navigator.pop(context, 'stay'),
              style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral200, width: 2), minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text(t.pick('Zostať a pokračovať', 'Stay and keep editing'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// PublishReviewDialog.js – reads live editor state so the list refreshes after saves.
class _PublishReview extends StatefulWidget {
  const _PublishReview({required this.t, required this.read, required this.onFix});
  final Strings t;
  final _ListingEditorScreenState Function() read;
  final ValueChanged<String> onFix;
  @override
  State<_PublishReview> createState() => _PublishReviewState();
}

class _PublishReviewState extends State<_PublishReview> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The editor keeps saving behind the sheet; refresh so Publish enables once it is checked.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final ed = widget.read();
    final data = ed._data;
    final missing = ed._missing;
    final canPublish = ed._canPublish;
    final live = ed._status == 'LIVE';
    final unsaved = ed._dirty || ed._savePhase == 'saving';
    final first = asList(data['photoUrls']).firstOrNull;
    final cover = first is String ? first : (first is Map ? asStringOrNull(first['url']) : null);
    final amenities = asStringList(data['amenities']);
    final location = [asString(data['city']), asString(data['country'])].where((e) => e.isNotEmpty).join(', ');
    final nightly = asString(data['nightlyPrice']).isEmpty ? '0' : asString(data['nightlyPrice']);

    Widget chipText(String s) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: AppColors.neutral100, borderRadius: BorderRadius.circular(8)),
          child: Text(s, style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral700)),
        );

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: const BoxDecoration(color: AppColors.neutral50, border: Border(bottom: BorderSide(color: AppColors.neutral100))),
        child: Row(children: [
          Expanded(child: Text(t.pick('Kontrola pred zverejnením', 'Publish Review'), style: AppText.inter(size: 20, weight: FontWeight.w700, color: _forest))),
          InkWell(
            borderRadius: BorderRadius.circular(99),
            onTap: () => Navigator.pop(context),
            child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: AppColors.neutral200)), child: const Icon(Icons.close, size: 20, color: AppColors.neutral400)),
          ),
        ]),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!canPublish)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFFEE2E2))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline, size: 24, color: Color(0xFF7F1D1D)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.pick('Chýbajúce požiadavky', 'Missing requirements'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: const Color(0xFF7F1D1D))),
                        const SizedBox(height: 4),
                        Text(t.pick('Otvorte položku a opravte ju; potom sa sem vrátite.', 'Open an item to fix it; you will be brought back here.'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFF7F1D1D))),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  for (final req in missing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => widget.onFix(req),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 48),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFECACA))),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(_requirements[req] == null ? req : t.pick(_requirements[req]!.$2, _requirements[req]!.$3), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
                                  if (_requirements[req] != null)
                                    Text('${t.pick('Krok', 'Step')}: ${t.pick(_stepTitles[_requirements[req]!.$1]!.$1, _stepTitles[_requirements[req]!.$1]!.$2)}', style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500)),
                                ]),
                              ),
                              const Icon(Icons.chevron_right, size: 18, color: AppColors.neutral400),
                            ]),
                          ),
                        ),
                      ),
                    ),
                ]),
              )
            else
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFDCFCE7))),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline, size: 32, color: Color(0xFF14532D)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(live ? t.pick('Táto ponuka je zverejnená', 'This listing is live') : t.pick('Pripravené na zverejnenie!', 'Ready to publish!'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: const Color(0xFF14532D))),
                      Text(t.pick('Všetky požiadavky sú splnené.', 'All requirements are met.'), style: AppText.inter(size: 15, weight: FontWeight.w500, color: const Color(0xFF14532D))),
                    ]),
                  ),
                ]),
              ),
            const SizedBox(height: 24),
            Text(t.pick('Náhľad pre hostí', 'Guest preview'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
            const Divider(height: 24, color: AppColors.neutral200),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: double.infinity),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral100), boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 15, offset: Offset(0, 10))]),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Stack(fit: StackFit.expand, children: [
                        cover == null ? Container(color: AppColors.neutral100, child: const Icon(Icons.image_outlined, size: 48, color: AppColors.neutral300)) : NetImage(cloudinary(cover, width: 800, ratio: 3 / 4), cacheWidth: 800),
                        Positioned(
                          left: 16,
                          top: 16,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(12)),
                            child: Text(t.pick('NÁHĽAD', 'PREVIEW'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: _forest, letterSpacing: 1)),
                          ),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(child: Text(asString(data['name']).isEmpty ? t.pick('Názov ubytovania', 'Property name') : asString(data['name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest))),
                          const SizedBox(width: 16),
                          Text.rich(TextSpan(children: [
                            TextSpan(text: '£$nightly', style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
                            TextSpan(text: ' /${t.pick('noc', 'night')}', style: AppText.inter(size: 15, weight: FontWeight.w500, color: AppColors.neutral500)),
                          ])),
                        ]),
                        const SizedBox(height: 8),
                        Text(location.isEmpty ? t.pick('Lokalita nenastavená', 'Location not set') : location, style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral500)),
                        const SizedBox(height: 16),
                        Wrap(spacing: 20, runSpacing: 8, children: [
                          Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.bed_outlined, size: 16, color: AppColors.neutral400), const SizedBox(width: 8), Text('${asInt(data['beds'])} ${t.pick('postelí', 'beds')}', style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral700))]),
                          Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.home_outlined, size: 16, color: AppColors.neutral400), const SizedBox(width: 8), Text('${asInt(data['guests'])} ${t.pick('hostí', 'guests')}', style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral700))]),
                        ]),
                        const Divider(height: 28, color: AppColors.neutral100),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final a in amenities.take(3)) chipText(t(a)),
                          if (amenities.length > 3) chipText('+${amenities.length - 3}'),
                        ]),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
      Container(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        decoration: const BoxDecoration(color: AppColors.neutral50, border: Border(top: BorderSide(color: AppColors.neutral100))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (unsaved && !live)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(t.pick('Novšie úpravy sa ukladajú; zverejnite, keď budú skontrolované.', 'Newer edits are being saved; publish once they are checked.'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFB45309))),
            ),
          FilledButton.icon(
            onPressed: !canPublish || ed._publishing || unsaved || live
                ? null
                : () async {
                    await ed._publish();
                  },
            icon: ed._publishing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
            label: Text(live ? t.pick('Už zverejnené', 'Already live') : (ed._publishing ? t.pick('Zverejňuje sa…', 'Publishing…') : t.pick('Zverejniť ponuku', 'Publish Listing')), style: AppText.inter(size: 16, weight: FontWeight.w700, color: Colors.white)),
            style: FilledButton.styleFrom(backgroundColor: _forest, foregroundColor: Colors.white, disabledBackgroundColor: _forest.withValues(alpha: 0.5), disabledForegroundColor: Colors.white, minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48), foregroundColor: AppColors.neutral600),
            child: Text(t.pick('Pokračovať v úprave', 'Keep editing'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: AppColors.neutral600)),
          ),
        ]),
      ),
    ]);
  }
}

class _StepBody extends ConsumerWidget {
  const _StepBody({super.key, required this.step, required this.data, required this.set, required this.listingId, this.errors = const {}, this.publishedId, this.beforeConnect});
  final String? publishedId;
  final Future<String?> Function()? beforeConnect;
  final Map<String, String> errors;
  final String step;
  final Json data;
  final void Function(String, dynamic) set;
  final String listingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final opts = ref.watch(optionsProvider).valueOrNull;
    if (opts == null) return const LoadingView();

    switch (step) {
      case 'basics':
        return buildBasicsStep(data: data, errors: errors, t: t, opts: opts, set: set);
      case 'location':
        return buildLocationStep(data: data, errors: errors, t: t, set: set);
      case 'spaces':
        return buildSpacesStep(data: data, errors: errors, t: t, opts: opts, set: set);
      case 'amenities':
        return buildAmenitiesStep(data: data, errors: errors, t: t, opts: opts, set: set);
      case 'photos':
        return PhotosStep(data: data, errors: errors, set: set);
      case 'pricing':
        return buildPricingStep(data: data, errors: errors, t: t, opts: opts, set: set);
      case 'units':
        return buildUnitsStep(data: data, errors: errors, t: t, opts: opts, set: set);
      case 'availability':
        return buildPoliciesStep(data: data, errors: errors, t: t, opts: opts, set: set);
      case 'calendar':
        return buildCalendarStep(data: data, errors: errors, t: t, set: set, publishedId: publishedId);
      case 'readiness':
      default:
        return buildReadinessStep(data: data, errors: errors, t: t, set: set, beforeConnect: beforeConnect ?? () async => null);
    }
  }
}

