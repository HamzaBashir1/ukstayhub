import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../widgets/common.dart';
import 'host_add_dates.dart';
import 'host_shell.dart';

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;
const _stages = ['request', 'upcoming', 'active', 'completed', 'declined', 'cancelled'];

// reservationModel.js ────────────────────────────────────────────────────
String _stageLabel(String s, Strings t, {bool plural = false}) => switch (s) {
      'request' => plural ? t.pick('Žiadosti', 'Requests') : t.pick('Žiadosť', 'Request'),
      'upcoming' => t.pick('Nadchádzajúce', 'Upcoming'),
      'active' => t.pick('Práve ubytovaní', 'Staying now'),
      'completed' => t.pick('Ukončené', 'Completed'),
      'declined' => t.pick('Zamietnuté', 'Declined'),
      'cancelled' => t.pick('Zrušené', 'Cancelled'),
      _ => t.pick('Všetky', 'All'),
    };

typedef _Badge = ({Color bg, Color fg, Color? border});

_Badge _stageBadge(String s) => switch (s) {
      'request' => (bg: const Color(0xFFFFFBEB), fg: const Color(0xFF92400E), border: const Color(0xFFFDE68A)),
      'upcoming' => (bg: const Color(0xFFF0FDF4), fg: const Color(0xFF15803D), border: const Color(0xFFBBF7D0)),
      'active' => (bg: _gold, fg: _forest, border: null),
      'completed' => (bg: AppColors.neutral100, fg: AppColors.neutral700, border: AppColors.neutral200),
      'declined' => (bg: AppColors.neutral100, fg: AppColors.neutral600, border: AppColors.neutral200),
      _ => (bg: const Color(0xFFFEF2F2), fg: const Color(0xFFB91C1C), border: const Color(0xFFFECACA)),
    };

({String label, _Badge badge})? _payment(Json r, Strings t) {
  final status = asString(r['paymentStatus']);
  if (status.isEmpty) return null;
  if (status == 'unpaid' && const ['request', 'declined', 'cancelled'].contains(asString(r['stage']))) return null;
  const neutral = (bg: AppColors.neutral100, fg: AppColors.neutral700, border: AppColors.neutral200);
  return switch (status) {
    'paid' => (label: t.pick('Zaplatené', 'Paid'), badge: (bg: const Color(0xFFF0FDF4), fg: const Color(0xFF15803D), border: const Color(0xFFBBF7D0))),
    'unpaid' => (label: t.pick('Čaká na platbu', 'Awaiting payment'), badge: (bg: const Color(0xFFFFFBEB), fg: const Color(0xFF92400E), border: const Color(0xFFFDE68A))),
    'refunded' => (label: t.pick('Vrátené', 'Refunded'), badge: neutral),
    'partially_refunded' => (label: t.pick('Čiastočne vrátené', 'Partly refunded'), badge: neutral),
    _ => null,
  };
}

String _stay(Json r, Strings t) {
  final a = asString(r['checkIn']);
  final b = asString(r['checkOut']);
  if (a.length < 10 || b.length < 10) return '';
  const f = 'en_GB';
  final da = DateTime.parse(a.substring(0, 10));
  final db = DateTime.parse(b.substring(0, 10));
  final sameYear = a.substring(0, 4) == b.substring(0, 4);
  final sameMonth = sameYear && a.substring(5, 7) == b.substring(5, 7);
  final start = sameMonth ? DateFormat('d', f).format(da) : DateFormat(sameYear ? 'd MMM' : 'd MMM y', f).format(da);
  return '$start – ${DateFormat('d MMM y', f).format(db)}';
}

String _nights(int n, Strings t) => t.isEn ? '$n ${n == 1 ? 'night' : 'nights'}' : '$n ${n == 1 ? 'noc' : (n >= 2 && n <= 4 ? 'noci' : 'nocí')}';
String _guests(int n, Strings t) => t.isEn ? '$n ${n == 1 ? 'guest' : 'guests'}' : '$n ${n == 1 ? 'hosť' : (n >= 2 && n <= 4 ? 'hostia' : 'hostí')}';

String _petText(String pet, int count, Strings t) {
  final label = switch (pet) {
    'dog' => t.pick('Pes', 'Dog'),
    'cat' => t.pick('Mačka', 'Cat'),
    _ => t.pick('Iné zviera', 'Other pet'),
  };
  return count > 0 ? '$count × $label' : label;
}

String _money(int cents, String currency, Strings t) {
  final amount = cents / 100;
  final f = NumberFormat.currency(locale: 'en_GB', name: currency.isEmpty ? 'GBP' : currency, decimalDigits: amount % 1 == 0 ? 0 : 2);
  return f.format(amount);
}

String _requestsWaiting(int n, Strings t) {
  if (t.isEn) return '$n ${n == 1 ? 'request is' : 'requests are'} waiting for your reply';
  return '$n ${n == 1 ? 'žiadosť čaká' : (n >= 2 && n <= 4 ? 'žiadosti čakajú' : 'žiadostí čaká')} na vašu odpoveď';
}

List<Json> _sortReservations(List<Json> list) {
  const order = {'request': 0, 'active': 1, 'upcoming': 2, 'completed': 3, 'cancelled': 4, 'declined': 5};
  int time(Json r) => DateTime.tryParse(asString(r['createdAt']))?.millisecondsSinceEpoch ?? 0;
  return [...list]..sort((a, b) {
      final sa = asString(a['stage']), sb = asString(b['stage']);
      final d = (order[sa] ?? 9) - (order[sb] ?? 9);
      if (d != 0) return d;
      if (sa == 'request') return time(a).compareTo(time(b));
      final ca = asString(a['checkIn']), cb = asString(b['checkIn']);
      return sa == 'active' || sa == 'upcoming' ? ca.compareTo(cb) : cb.compareTo(ca);
    });
}

String _listingName(Json l, Strings t) {
  final a = asString(pick(l, 'data.name')).trim();
  if (a.isNotEmpty) return a;
  final b = asString(l['name']).trim();
  return b.isNotEmpty ? b : t.pick('Ponuka bez názvu', 'Unnamed listing');
}

/// TransitionDialog.js (accept / decline) – shared by the list cards.
Future<bool> _confirmTransition(BuildContext context, WidgetRef ref, Json r, String action) async {
  final t = ref.read(stringsProvider);
  final accept = action == 'accept';
  final cancel = action == 'cancel';
  final title = accept
      ? t.pick('Prijať túto žiadosť?', 'Accept this request?')
      : cancel
          ? t.pick('Zrušiť tento pobyt?', 'Cancel this stay?')
          : t.pick('Zamietnuť túto žiadosť?', 'Decline this request?');
  final body = cancel
      ? t.pick('Noci sa v kalendári uvoľnia a pobyt hosťa bude zrušený. Túto akciu nie je možné vrátiť späť.', "The nights will be released in the calendar and the guest's stay is cancelled. This cannot be undone.")
      : accept
      ? t.pick('Noci sa zablokujú v kalendári tejto ponuky a pobyt hosťa bude potvrdený. Neskôr ho môžete zrušiť.',
          "The nights will be blocked in this property's calendar and the guest's stay becomes confirmed. You can still cancel it later.")
      : t.pick('Hosť sa v týchto termínoch nebude môcť ubytovať. Zamietnutú žiadosť už nie je možné znova otvoriť.',
          'The guest will not be able to stay on these dates. A declined request cannot be reopened.');
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(title, style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(body, style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.6)),
        const SizedBox(height: 12),
        TextField(controller: note, maxLines: 3, decoration: InputDecoration(hintText: t.pick('Správa pre hosťa (voliteľné)', 'Message to the guest (optional)'))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.pick('Zrušiť', 'Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: accept ? _forest : const Color(0xFFDC2626), foregroundColor: Colors.white, minimumSize: const Size(0, 44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(accept ? t.pick('Prijať žiadosť', 'Accept request') : (cancel ? t.pick('Zrušiť pobyt', 'Cancel stay') : t.pick('Zamietnuť žiadosť', 'Decline request')), style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white)),
        ),
      ],
    ),
  );
  final text = note.text.trim();
  note.dispose();
  if (ok != true) return false;
  try {
    await hostRepo.transition(asString(r['id']), action, note: text);
    ref.invalidate(hostReservationsProvider);
    ref.invalidate(hostDashboardProvider);
    if (context.mounted) {
      toast(
          context,
          accept
              ? t.pick('Žiadosť prijatá. Noci sú teraz zablokované v kalendári.', 'Request accepted. The nights are now blocked in the calendar.')
              : cancel
                  ? t.pick('Pobyt zrušený. Noci sú opäť voľné.', 'Stay cancelled. The nights are open again.')
                  : t.pick('Žiadosť zamietnutá.', 'Request declined.'));
    }
    return true;
  } catch (e) {
    if (context.mounted) toast(context, errorText(e), error: true);
    return false;
  }
}

// ───────────────────────────── Reservations list ─────────────────────────────
class HostReservationsScreen extends ConsumerStatefulWidget {
  const HostReservationsScreen({super.key, this.stage});
  final String? stage;
  @override
  ConsumerState<HostReservationsScreen> createState() => _HostReservationsScreenState();
}

class _HostReservationsScreenState extends ConsumerState<HostReservationsScreen> {
  late String? _stage = _stages.contains(widget.stage) ? widget.stage : null;
  String? _property;

  @override
  void didUpdateWidget(HostReservationsScreen old) {
    super.didUpdateWidget(old);
    if (old.stage != widget.stage) _stage = _stages.contains(widget.stage) ? widget.stage : null;
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(hostReservationsProvider);
    final listings = ref.watch(hostListingsProvider).valueOrNull ?? const <Json>[];
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final sm = width >= 640;
    final padX = wide ? 0.0 : 16.0;
    final propertyKnown = _property == null || listings.isEmpty || listings.any((l) => asString(l['id']) == _property);
    final property = propertyKnown ? _property : null;

    Widget page(Widget child) => Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 896), child: Padding(padding: EdgeInsets.symmetric(horizontal: padX), child: child)),
        );

    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.pick('HOSTITEĽ', 'HOST'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
      Text(t.pick('Rezervácie', 'Reservations'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest, height: 1.33)),
    ]);
    final select = listings.length > 1
        ? Container(
            height: 48,
            constraints: BoxConstraints(minWidth: sm ? 260 : 0),
            padding: const EdgeInsets.only(left: 16, right: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: property,
                isExpanded: true,
                icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.neutral500),
                style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest),
                borderRadius: BorderRadius.circular(12),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(t.pick('Všetky ubytovania', 'All properties'))),
                  for (final l in listings) DropdownMenuItem<String?>(value: asString(l['id']), child: Text(_listingName(l, t), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _property = v),
              ),
            ),
          )
        : null;
    final owned = ref.watch(hostOwnedProvider).valueOrNull ?? const <Json>[];
    final addDates = owned.isEmpty
        ? null
        : OutlinedButton.icon(
            onPressed: () async {
              final done = await showAddOwnDatesDialog(context, t: t, listings: owned);
              if (done != null && context.mounted) toast(context, t.pick('Tento termín je zablokovaný.', 'Those dates are blocked.'));
            },
            icon: const Icon(Icons.edit_calendar_outlined, size: 17),
            label: Text(t.pick('Pridať vlastný termín', 'Add your own dates'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: _forest, width: 2), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          );
    final header = sm
        ? Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: titleBlock), if (select != null) ...[const SizedBox(width: 12), select], if (addDates != null) ...[const SizedBox(width: 12), addDates]])
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [titleBlock, if (select != null) ...[const SizedBox(height: 12), select], if (addDates != null) ...[const SizedBox(height: 12), addDates]]);

    Widget body;
    if (!async.hasValue && async.isLoading) {
      Widget box(double h) => Container(height: h, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)));
      body = Column(children: [
        Container(height: 40, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(12))),
        for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 12), child: box(96)),
      ]);
    } else if (!async.hasValue && async.hasError) {
      body = Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFFECACA))),
        child: Column(children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), shape: BoxShape.circle), child: const Icon(Icons.error_outline, size: 30, color: _gold)),
          const SizedBox(height: 20),
          Text(t.pick('Rezervácie sa nepodarilo načítať', "We couldn't load your reservations"), textAlign: TextAlign.center, style: AppText.inter(size: 20, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
          const SizedBox(height: 8),
          Text(errorText(async.error!), textAlign: TextAlign.center, style: AppText.inter(size: 15, color: AppColors.neutral600)),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => ref.invalidate(hostReservationsProvider),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      );
    } else {
      final all = async.value ?? const <Json>[];
      if (all.isEmpty) {
        body = Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
          child: Column(children: [
            Container(width: 64, height: 64, decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), shape: BoxShape.circle), child: const Icon(Icons.assignment_outlined, size: 30, color: _gold)),
            const SizedBox(height: 20),
            Text(t.pick('Zatiaľ žiadne rezervácie', 'No reservations yet'), style: AppText.inter(size: 20, weight: FontWeight.w700, color: _forest)),
            const SizedBox(height: 8),
            Text(
              listings.isEmpty
                  ? t.pick('Keď zverejníte ponuku, žiadosti hostí sa zobrazia tu.', 'Once you publish a listing, guest requests will show up here.')
                  : t.pick('Žiadosti hostí o vaše ponuky sa zobrazia tu. Prijímať a zamietať ich budete z tejto obrazovky.',
                      "Guest requests for your listings will show up here. You'll accept or decline them from this screen."),
              textAlign: TextAlign.center,
              style: AppText.inter(size: 15, color: AppColors.neutral600, height: 1.6),
            ),
          ]),
        );
      } else {
        final byProperty = property == null ? all : all.where((r) => asString(r['accommodationId']) == property).toList();
        final counts = {for (final s in _stages) s: byProperty.where((r) => asString(r['stage']) == s).length};
        final visible = _sortReservations(_stage == null ? byProperty : byProperty.where((r) => asString(r['stage']) == _stage).toList());
        final requests = byProperty.where((r) => asString(r['stage']) == 'request').length;

        Widget chip(String? option) {
          final active = _stage == option;
          final count = option == null ? byProperty.length : counts[option]!;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: active ? _forest : Colors.white,
              shape: StadiumBorder(side: BorderSide(color: active ? _forest : AppColors.neutral300)),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => setState(() => _stage = option),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(option == null ? t.pick('Všetky', 'All') : _stageLabel(option, t, plural: true), style: AppText.inter(size: 13, weight: FontWeight.w700, color: active ? Colors.white : _forest)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(color: active ? Colors.white.withValues(alpha: 0.2) : AppColors.neutral100, borderRadius: BorderRadius.circular(99)),
                      child: Text('$count', style: AppText.inter(size: 11, weight: FontWeight.w700, color: active ? Colors.white : AppColors.neutral600, height: 1.5)),
                    ),
                  ]),
                ),
              ),
            ),
          );
        }

        final chips = [null, ..._stages];
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!propertyKnown) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDE68A))),
              child: Text(t.pick('Toto ubytovanie už nie je medzi vašimi ponukami, zobrazujú sa všetky.', 'That property is no longer in your listings, so all properties are shown.'),
                  style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF92400E))),
            ),
            const SizedBox(height: 12),
          ],
          if (requests > 0 && _stage == null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDE68A))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.notifications_active_outlined, size: 18, color: Color(0xFF92400E)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_requestsWaiting(requests, t), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF92400E)))),
                ]),
                const SizedBox(height: 4),
                Text(
                  t.pick('Otvorte žiadosť a prijmite ju alebo zamietnite. Prijaté pobyty zablokujú svoje noci v kalendári.',
                      'Open a request to accept or decline it. Accepted stays block their nights in the calendar.'),
                  style: AppText.inter(size: 13, color: const Color(0xCC92400E), height: 1.45),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => setState(() => _stage = 'request'),
                  style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: Text(t.pick('Zobraziť žiadosti', 'Show requests'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
                ),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (wide)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Wrap(runSpacing: 8, children: [for (final c in chips) chip(c)]))
          else
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, padding: const EdgeInsets.only(bottom: 4), children: [for (final c in chips) chip(c)]),
            ),
          const SizedBox(height: 16),
          if (visible.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral300)),
              child: Column(children: [
                Text(t.pick('Nič tu nie je', 'Nothing here'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
                const SizedBox(height: 4),
                Text(t.pick('Tomuto filtru nezodpovedajú žiadne rezervácie.', 'No reservations match this filter.'), style: AppText.inter(size: 13, color: AppColors.neutral500)),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => setState(() {
                    _stage = null;
                    _property = null;
                  }),
                  style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: Text(t.pick('Zobraziť všetky rezervácie', 'Show all reservations'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
                ),
              ]),
            )
          else
            for (final r in visible)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: _ReservationCard(r: r, showProperty: property == null)),
          if (async.hasError) ...[
            const SizedBox(height: 4),
            Text('${t.pick('Zoznam nemusí byť aktuálny: ', 'The list may be out of date: ')}${errorText(async.error!)}', style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFDC2626))),
          ],
        ]);
      }
    }

    return RefreshIndicator(
      color: _forest,
      onRefresh: () => ref.refresh(hostReservationsProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          page(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, const SizedBox(height: 16), body])),
        ],
      ),
    );
  }
}

class _ReservationCard extends ConsumerWidget {
  const _ReservationCard({required this.r, required this.showProperty});
  final Json r;
  final bool showProperty;

  Widget _badge(String text, _Badge b, {double size = 11}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: b.bg, borderRadius: BorderRadius.circular(6), border: b.border == null ? null : Border.all(color: b.border!)),
        child: Text(text, style: AppText.inter(size: size, weight: FontWeight.w700, color: b.fg, height: 1.45)),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final stage = asString(r['stage']);
    final urgent = stage == 'request';
    final pay = _payment(r, t);
    final actions = asStringList(r['actions']);
    final quick = [if (actions.contains('accept')) 'accept', if (actions.contains('decline')) 'decline'];
    final pet = asStringOrNull(r['pet']);
    final border = urgent ? const Color(0xFFFCD34D) : AppColors.neutral200;

    Widget meta(IconData? icon, String text, {bool bold = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: AppColors.neutral600), const SizedBox(width: 4)],
          Text(text, style: AppText.inter(size: 13, weight: bold ? FontWeight.w700 : FontWeight.w400, color: bold ? _forest : AppColors.neutral600)),
        ]);
    Widget dot() => Text('·', style: AppText.inter(size: 13, color: AppColors.neutral600));

    return Material(
      color: Colors.white,
      elevation: 0.5,
      shadowColor: const Color(0x0D000000),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: border)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (urgent) Container(width: 4, color: const Color(0xFFF59E0B)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  InkWell(
                    onTap: () => context.go('/host/reservations/${asString(r['id'])}'),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 72),
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(child: Text(asString(pick(r, 'guest.name')), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest))),
                              const SizedBox(width: 8),
                              _badge(_stageLabel(stage, t), _stageBadge(stage)),
                              if (pay != null) ...[const SizedBox(width: 8), _badge(pay.label, pay.badge)],
                            ]),
                            if (showProperty) ...[
                              const SizedBox(height: 2),
                              Text(asString(pick(r, 'listing.name')), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 13, color: AppColors.neutral500)),
                            ],
                            const SizedBox(height: 4),
                            Text(_stay(r, t), style: AppText.inter(size: 14, weight: FontWeight.w600, color: _forest)),
                            const SizedBox(height: 2),
                            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                              meta(null, _nights(asInt(r['nights']), t)),
                              dot(),
                              meta(Icons.people_outline, _guests(asInt(r['guests'], 1), t)),
                              if (pet != null && pet.isNotEmpty) ...[dot(), meta(Icons.pets, _petText(pet, asInt(r['pets']), t))],
                              dot(),
                              meta(null, _money(asInt(r['totalCents']), asString(r['currency']), t), bold: true),
                            ]),
                          ]),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.chevron_right, size: 20, color: AppColors.neutral400),
                      ]),
                    ),
                  ),
                  if (quick.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
                      child: Row(children: [
                        if (quick.contains('accept'))
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _confirmTransition(context, ref, r, 'accept'),
                              icon: const Icon(Icons.check_circle_outline, size: 15),
                              label: Text(t.pick('Prijať', 'Accept'), style: AppText.inter(color: Colors.white, size: 13, weight: FontWeight.w700)),
                              style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                            ),
                          ),
                        if (quick.length > 1) const SizedBox(width: 8),
                        if (quick.contains('decline'))
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _confirmTransition(context, ref, r, 'decline'),
                              icon: const Icon(Icons.cancel_outlined, size: 15),
                              label: Text(t.pick('Zamietnuť', 'Decline'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
                              style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral300, width: 2), minimumSize: const Size(0, 44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                            ),
                          ),
                      ]),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Reservation detail (ReservationDetailPage.js) ─────────────────────────────
String _stageHint(String stage, Strings t) => switch (stage) {
      'request' => t.pick('Hosť čaká na vašu odpoveď. Prijatím sa tieto noci zablokujú v kalendári.', 'The guest is waiting for your reply. Accepting blocks these nights in the calendar.'),
      'upcoming' => t.pick('Potvrdené. Tieto noci sú v kalendári zablokované.', 'Confirmed. These nights are blocked in the calendar.'),
      'active' => t.pick('Hosť je práve ubytovaný. Zrušením sa pobyt ukončí skôr a zvyšné noci sa uvoľnia.', 'The guest is staying now. Cancelling ends the stay early and opens the remaining nights.'),
      'completed' => t.pick('Tento pobyt sa skončil.', 'This stay has finished.'),
      'declined' => t.pick('Túto žiadosť ste zamietli. Noci zostali voľné.', 'You declined this request. The nights stayed open.'),
      'cancelled' => t.pick('Tento pobyt bol zrušený. Noci sú opäť voľné.', 'This stay was cancelled. The nights are open again.'),
      _ => '',
    };

class HostReservationDetailScreen extends ConsumerStatefulWidget {
  const HostReservationDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<HostReservationDetailScreen> createState() => _HostReservationDetailScreenState();
}

class _HostReservationDetailScreenState extends ConsumerState<HostReservationDetailScreen> {
  Json? _r;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await hostRepo.reservation(widget.id);
      if (mounted) setState(() => _r = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _act(String action) async {
    final r = _r;
    if (r == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (await _confirmTransition(context, ref, r, action)) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _day(String iso, Strings t) {
    if (iso.length < 10) return '';
    return DateFormat('EEE, d MMM y', 'en_GB').format(DateTime.parse(iso.substring(0, 10)));
  }

  String _stamp(dynamic v, Strings t) {
    final d = DateTime.tryParse(asString(v))?.toLocal();
    return d == null ? '' : DateFormat('d MMM y, HH:mm', 'en_GB').format(d);
  }

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
        child: child,
      );

  Widget _cell(String label, List<Widget> children) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
          const SizedBox(height: 2),
          ...children,
        ]),
      );

  Widget _stateCard(IconData icon, String title, String body, {bool error = false, required Widget action}) => Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: error ? const Color(0xFFFEF2F2) : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: error ? const Color(0xFFFECACA) : AppColors.neutral200),
        ),
        child: Column(children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), shape: BoxShape.circle), child: Icon(icon, size: 30, color: _gold)),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: AppText.inter(size: 20, weight: FontWeight.w700, color: error ? const Color(0xFFB91C1C) : _forest)),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: AppText.inter(size: 15, color: AppColors.neutral600, height: 1.6)),
          const SizedBox(height: 24),
          action,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final lg = width >= 1024;
    final sm = width >= 640;
    final padX = wide ? 0.0 : 16.0;
    final r = _r;

    final back = Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: () => context.go('/host/reservations'),
        child: SizedBox(
          height: 44,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.arrow_back, size: 18, color: _forest),
            const SizedBox(width: 6),
            Text(t.pick('Všetky rezervácie', 'All reservations'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
          ]),
        ),
      ),
    );

    Widget wrap(Widget child, {double bottom = 32}) => ListView(padding: EdgeInsets.only(bottom: bottom), children: [
          Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 768), child: Padding(padding: EdgeInsets.symmetric(horizontal: padX), child: child))),
        ]);

    final goBtn = FilledButton(
      onPressed: () => context.go('/host/reservations'),
      style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      child: Text(t.pick('Prejsť na moje rezervácie', 'Go to my reservations'), style: AppText.inter(color: Colors.white, size: 15, weight: FontWeight.w700)),
    );

    if (_error != null && r == null) {
      final status = _error is ApiException ? (_error as ApiException).status : 0;
      if (status == 403) {
        return wrap(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [back, _stateCard(Icons.lock_outline, t.pick('Táto rezervácia patrí inému hostiteľovi', 'This reservation belongs to another host'), t.pick('Rezervácie môžete spravovať iba pri vlastných ponukách.', 'You can only manage reservations for your own listings.'), action: goBtn)]));
      }
      if (status == 404) {
        return wrap(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [back, _stateCard(Icons.event_busy_outlined, t.pick('Táto rezervácia už neexistuje', 'This reservation no longer exists'), t.pick('Možno bola odstránená spolu so svojou ponukou.', 'It may have been removed together with its listing.'), action: goBtn)]));
      }
      return wrap(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        back,
        _stateCard(
          Icons.error_outline,
          t.pick('Rezerváciu sa nepodarilo načítať', "We couldn't load this reservation"),
          errorText(_error!),
          error: true,
          action: OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ]));
    }
    if (r == null) {
      return wrap(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        back,
        Container(height: 112, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200))),
        const SizedBox(height: 16),
        Container(height: 192, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200))),
      ]));
    }

    final stage = asString(r['stage']);
    final badge = _stageBadge(stage);
    final pay = _payment(r, t);
    final actions = asStringList(r['actions']).where((a) => const ['accept', 'decline', 'cancel'].contains(a)).toList();
    final g = asMap(r['guest']);
    final currency = asString(r['currency']);
    final extras = asMapList(r['extras']);
    final pet = asStringOrNull(r['pet']);
    final hint = _stageHint(stage, t);
    final email = asString(g['email']);
    final phone = asString(g['phone']);
    final message = asString(g['message']);
    final hostNote = asString(r['hostNote']);
    final created = _stamp(r['createdAt'], t);
    final responded = _stamp(r['respondedAt'], t);
    final cancelled = _stamp(r['cancelledAt'], t);
    final nightly = asInt(r['nightlyPriceCents']);

    Widget h2(IconData? icon, String text) => Row(children: [
          if (icon != null) ...[Icon(icon, size: 18, color: _gold), const SizedBox(width: 8)],
          Text(text, style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
        ]);
    TextStyle dd([double size = 15]) => AppText.inter(size: size, weight: FontWeight.w700, color: _forest);

    final cells = <Widget>[
      _cell(t.pick('Príchod', 'Check-in'), [Text(_day(asString(r['checkIn']), t), style: dd())]),
      _cell(t.pick('Odchod', 'Check-out'), [Text(_day(asString(r['checkOut']), t), style: dd())]),
      _cell(t.pick('Hostia', 'Guests'), [
        Row(children: [const Icon(Icons.people_outline, size: 16, color: _forest), const SizedBox(width: 6), Text(_guests(asInt(r['guests'], 1), t), style: dd())]),
        if (pet != null && pet.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [const Icon(Icons.pets, size: 14, color: AppColors.neutral600), const SizedBox(width: 6), Text(_petText(pet, asInt(r['pets']), t), style: AppText.inter(size: 13, weight: FontWeight.w600, color: AppColors.neutral600))]),
        ],
      ]),
      _cell(t.pick('Spolu', 'Total'), [
        Text(_money(asInt(r['totalCents']), currency, t), style: dd()),
        Text('${_nights(asInt(r['nights']), t)} × ${_money(nightly, currency, t)}', style: AppText.inter(size: 12, color: AppColors.neutral500)),
      ]),
      if (extras.isNotEmpty)
        _cell(t.pick('Doplnky', 'Extras'), [
          for (final e in extras)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: asString(pick(e, 'name.${t.lang}'), asString(pick(e, 'name.en'))), style: AppText.inter(size: 14, weight: FontWeight.w600, color: _forest)),
                    TextSpan(
                      text: ' ${_money(asInt(e['priceCents']), currency, t)} / ${asString(e['pricing']) == 'per_night' ? t.pick('noc', 'night') : t.pick('pobyt', 'stay')}',
                      style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500),
                    ),
                  ])),
                ),
                const SizedBox(width: 12),
                Text(_money(asInt(e['totalCents']), currency, t), style: AppText.inter(size: 14, weight: FontWeight.w600, color: _forest)),
              ]),
            ),
        ]),
      if (pay != null)
        _cell(t.pick('Platba', 'Payment'), [
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: pay.badge.bg, borderRadius: BorderRadius.circular(6), border: pay.badge.border == null ? null : Border.all(color: pay.badge.border!)),
              child: Text(pay.label, style: AppText.inter(size: 12, weight: FontWeight.w700, color: pay.badge.fg, height: 1.45)),
            ),
          ),
          if (asString(r['bookingMode']) == 'request') ...[
            const SizedBox(height: 4),
            Text(t.pick('Rezervované na požiadanie', 'Booked by request'), style: AppText.inter(size: 12, color: AppColors.neutral500)),
          ],
        ]),
    ];

    Widget grid() {
      if (!sm) return Column(children: [for (var i = 0; i < cells.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 12), child: SizedBox(width: double.infinity, child: cells[i]))]);
      final rows = <Widget>[];
      for (var i = 0; i < cells.length; i += 2) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: cells[i]),
              const SizedBox(width: 12),
              Expanded(child: i + 1 < cells.length ? cells[i + 1] : const SizedBox()),
            ]),
          ),
        ));
      }
      return Column(children: rows);
    }

    Widget contact(IconData icon, String text, String url) => InkWell(
          onTap: () => launchUrl(Uri.parse(url)),
          child: SizedBox(
            height: 44,
            child: Row(children: [
              Icon(icon, size: 16, color: AppColors.neutral400),
              const SizedBox(width: 8),
              Expanded(child: Text(text, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, color: _forest).copyWith(decoration: TextDecoration.underline))),
            ]),
          ),
        );

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      back,
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(asString(pick(r, 'listing.name')).toUpperCase(), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
              const SizedBox(height: 2),
              Text(asString(g['name']), style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest, height: 1.25)),
            ]),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: badge.bg, borderRadius: BorderRadius.circular(8), border: badge.border == null ? null : Border.all(color: badge.border!)),
            child: Text(_stageLabel(stage, t), style: AppText.inter(size: 12, weight: FontWeight.w700, color: badge.fg, height: 1.3)),
          ),
        ]),
        if (hint.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(hint, style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.6)),
        ],
      ])),
      const SizedBox(height: 16),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(Icons.calendar_today_outlined, t.pick('Pobyt', 'Stay')),
        const SizedBox(height: 12),
        grid(),
        const SizedBox(height: 12),
        InkWell(
          onTap: () => context.go('/host/calendar?property=${asString(r['accommodationId'])}'),
          child: SizedBox(
            height: 44,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(t.pick('Otvoriť kalendár ubytovania', 'Open the property calendar'),
                  style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest).copyWith(decoration: TextDecoration.underline, decorationColor: _gold, decorationThickness: 2)),
            ),
          ),
        ),
      ])),
      const SizedBox(height: 16),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(null, t.pick('Hosť', 'Guest')),
        const SizedBox(height: 12),
        if (email.isNotEmpty) contact(Icons.mail_outline, email, 'mailto:$email'),
        if (phone.isNotEmpty) contact(Icons.call_outlined, phone, 'tel:$phone'),
        if (email.isEmpty && phone.isEmpty) Text(t.pick('Hosť neuviedol kontaktné údaje.', 'No contact details were shared.'), style: AppText.inter(size: 14, color: AppColors.neutral500)),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.chat_bubble_outline, size: 14, color: AppColors.neutral500),
                const SizedBox(width: 6),
                Text(t.pick('SPRÁVA OD HOSŤA', 'MESSAGE FROM THE GUEST'), style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
              ]),
              const SizedBox(height: 4),
              Text(message, style: AppText.inter(size: 14, color: _forest, height: 1.6)),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          '${t.pick('Požiadané', 'Requested')} $created${responded.isEmpty ? '' : ' · ${t.pick('zodpovedané', 'answered')} $responded'}${cancelled.isEmpty ? '' : ' · ${t.pick('zrušené', 'cancelled')} $cancelled'}',
          style: AppText.inter(size: 12, color: AppColors.neutral500),
        ),
        if (hostNote.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text.rich(TextSpan(children: [
            TextSpan(text: '${t.pick('Vaša poznámka:', 'Your note:')} ', style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest)),
            TextSpan(text: hostNote, style: AppText.inter(size: 13, color: AppColors.neutral600)),
          ])),
        ],
      ])),
    ]);

    Widget? actionBar;
    if (actions.isNotEmpty) {
      actionBar = Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.neutral200),
          boxShadow: lg ? const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))] : const [BoxShadow(color: Color(0x1F000000), blurRadius: 30, offset: Offset(0, -8))],
        ),
        child: Row(children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _actionButton(t, actions[i])),
          ],
        ]),
      );
    }

    if (lg || actionBar == null) {
      return wrap(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [content, if (actionBar != null) ...[const SizedBox(height: 16), actionBar]]));
    }
    return Stack(children: [
      wrap(content, bottom: 120),
      Positioned(left: 12, right: 12, bottom: 12, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 768), child: actionBar))),
    ]);
  }

  Widget _actionButton(Strings t, String action) {
    final label = switch (action) {
      'accept' => t.pick('Prijať', 'Accept'),
      'decline' => t.pick('Zamietnuť', 'Decline'),
      _ => t.pick('Zrušiť pobyt', 'Cancel stay'),
    };
    final red = action == 'cancel';
    // Each label takes the colour of its button: white on the filled Accept, green/red on the outlined ones.
    final fg = action == 'accept' ? Colors.white : (red ? const Color(0xFFB91C1C) : _forest);
    final icon = Icon(action == 'accept' ? Icons.check_circle_outline : Icons.cancel_outlined, size: 18, color: fg);
    final text = Text(label, style: AppText.inter(size: 15, weight: FontWeight.w700, color: fg));
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    final spinner = SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: action == 'accept' ? Colors.white : _forest));
    if (action == 'accept') {
      return FilledButton.icon(
        onPressed: _busy ? null : () => _act(action),
        icon: _busy ? spinner : icon,
        label: text,
        style: FilledButton.styleFrom(backgroundColor: _forest, foregroundColor: Colors.white, disabledBackgroundColor: _forest.withValues(alpha: 0.6), disabledForegroundColor: Colors.white, minimumSize: const Size(0, 48), shape: shape),
      );
    }
    return OutlinedButton.icon(
      onPressed: _busy ? null : () => _act(action),
      icon: icon,
      label: text,
      style: OutlinedButton.styleFrom(
        foregroundColor: red ? const Color(0xFFB91C1C) : _forest,
        side: BorderSide(color: red ? const Color(0xFFFECACA) : AppColors.neutral300, width: 2),
        minimumSize: const Size(0, 48),
        shape: shape,
      ),
    );
  }
}

/// Cancel-stay confirmation (message to guest + server cancel) for a reservation addressed by id, e.g. from the calendar.
Future<bool> confirmHostCancelStay(BuildContext context, WidgetRef ref, String reservationId) =>
    _confirmTransition(context, ref, {"id": reservationId}, "cancel");
