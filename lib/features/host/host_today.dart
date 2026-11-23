import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'host_shell.dart';

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;
// Web breakpoints: md = 768 (no side padding, max-w-4xl = 896).
const _maxWidth = 896.0;

enum _Tone { urgent, warn, todo, info }

class _Task {
  const _Task(this.id, this.group, this.tone, this.title, this.detail, this.href, this.propertyId);
  final String id;
  final String group;
  final _Tone tone;
  final String title;
  final String detail;
  final String href;
  final String? propertyId; // null = host-level, never hidden by the filter
}

const _groups = ['setup', 'requests', 'calendar', 'messages', 'payouts'];

/// host/dashboard/Overview.js + hostDashboardModel.js – "Today".
class HostTodayScreen extends ConsumerStatefulWidget {
  const HostTodayScreen({super.key});

  @override
  ConsumerState<HostTodayScreen> createState() => _HostTodayScreenState();
}

class _HostTodayScreenState extends ConsumerState<HostTodayScreen> {
  String? _property;
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    ref.invalidate(hostDashboardProvider);
    try {
      await ref.read(hostDashboardProvider.future);
    } catch (_) {} finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(hostDashboardProvider);
    final listings = ref.watch(hostListingsProvider).valueOrNull ?? const <Json>[];
    final summary = async.valueOrNull;
    final wide = MediaQuery.sizeOf(context).width >= 768;
    final sidePad = wide ? 0.0 : 16.0;

    final property = _property != null && (listings.isEmpty || listings.any((l) => asString(l['id']) == _property)) ? _property : null;
    final propertyUnknown = _property != null && property == null;

    final tasks = summary == null ? <_Task>[] : _buildTasks(summary, t);
    final visible = property == null ? tasks : tasks.where((k) => k.propertyId == null || k.propertyId == property).toList();
    final hidden = tasks.length - visible.length;

    final header = _Header(
      t: t,
      listings: listings,
      property: property,
      refreshing: _refreshing,
      showRefresh: summary != null,
      wide: wide,
      onProperty: (v) => setState(() => _property = v),
      onRefresh: _refresh,
    );

    Widget body;
    if (async.isLoading && summary == null) {
      body = _skeleton();
    } else if (async.hasError && summary == null) {
      body = _errorCard(t, async.error!, () => ref.invalidate(hostDashboardProvider));
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _figures(context, t, summary!),
        if (propertyUnknown) ...[
          const SizedBox(height: 24),
          _notice(
            t.pick('Toto ubytovanie už nie je medzi vašimi ponukami, zobrazujú sa všetky.', 'That property is no longer in your listings, so all properties are shown.'),
            const Color(0xFFFFFBEB),
            const Color(0xFFFDE68A),
            const Color(0xFF92400E),
          ),
        ],
        if (async.hasError) ...[
          const SizedBox(height: 24),
          _notice('${t.pick('Nepodarilo sa obnoviť: ', "Couldn't refresh: ")}${errorText(async.error!)}', const Color(0xFFFEF2F2), const Color(0xFFFECACA), const Color(0xFFB91C1C)),
        ],
        const SizedBox(height: 24),
        if (visible.isEmpty)
          _empty(t, property != null, hidden, () => setState(() => _property = null))
        else
          for (final g in _groups)
            if (visible.any((k) => k.group == g)) ...[
              _groupSection(context, t, g, visible.where((k) => k.group == g).toList()),
              const SizedBox(height: 24),
            ],
      ]);
    }

    return RefreshIndicator(
      color: _forest,
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              child: Padding(
                padding: EdgeInsets.fromLTRB(sidePad, wide ? 16 : 8, sidePad, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, const SizedBox(height: 24), body]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── task rules (hostDashboardModel.js) ───────────────────────────
  static String _requirementsLeft(int n, Strings t) {
    if (t.isEn) return '$n ${n == 1 ? 'item' : 'items'} left';
    return n == 1 ? 'zostáva 1 položka' : (n >= 2 && n <= 4 ? 'zostávajú $n položky' : 'zostáva $n položiek');
  }

  static String _waiting(String iso, Strings t) {
    final created = DateTime.tryParse(iso);
    if (created == null) return '';
    final hours = DateTime.now().difference(created).inHours.clamp(0, 1 << 30);
    if (hours < 1) return t.pick('práve teraz', 'just now');
    if (hours < 24) return t.isEn ? '$hours h ago' : 'pred $hours h';
    final days = hours ~/ 24;
    return t.isEn ? '$days ${days == 1 ? 'day' : 'days'} ago' : 'pred $days ${days == 1 ? 'dňom' : 'dňami'}';
  }

  static String _unread(int n, Strings t) {
    if (t.isEn) return '$n new ${n == 1 ? 'message' : 'messages'}';
    return n == 1 ? '1 nová správa' : (n >= 2 && n <= 4 ? '$n nové správy' : '$n nových správ');
  }

  static String _range(Json r, Strings t) => rangeLabel(parseDay(asString(r['checkIn'])), parseDay(asString(r['checkOut'])), t.lang);

  static String _listing(dynamic ref, Strings t) {
    final n = asString(pick(ref, 'name')).trim();
    return n.isEmpty ? t.pick('Ponuka bez názvu', 'Unnamed listing') : n;
  }

  List<_Task> _buildTasks(Json d, Strings t) {
    final tasks = <_Task>[];

    if (asInt(pick(d, 'setup.counts.total')) == 0) {
      tasks.add(_Task('setup:first', 'setup', _Tone.todo, t.pick('Pridajte prvú ponuku', 'Add your first listing'),
          t.pick('Kým nie je ponuka zverejnená, hostia vás nenájdu.', "Guests can't find you until a listing is live."), '/host/listings', null));
    }
    for (final item in asMapList(pick(d, 'setup.items'))) {
      final id = asString(pick(item, 'listing.id'));
      final name = _listing(item['listing'], t);
      if (asString(item['kind']) == 'ready') {
        tasks.add(_Task('setup:$id', 'setup', _Tone.todo, t.pick('Zverejnite $name', 'Publish $name'),
            t.pick('Všetko je vyplnené. Skontrolujte a zverejnite.', 'Everything is filled in. Review it and go live.'), '/host/listings/$id?review=1', id));
      } else {
        final left = asList(item['missingRequirements']).length;
        tasks.add(_Task('setup:$id', 'setup', _Tone.todo, t.pick('Dokončite $name', 'Finish $name'),
            '${asInt(item['completionPercent'])} % · ${_requirementsLeft(left, t)}', '/host/listings/$id', id));
      }
    }

    for (final r in asMapList(pick(d, 'requests.items'))) {
      final blocked = asList(r['conflicts']).isNotEmpty;
      tasks.add(_Task(
        'request:${asString(r['id'])}',
        'requests',
        blocked ? _Tone.urgent : _Tone.warn,
        '${asString(r['guestName'])} · ${_range(r, t)}',
        '${_listing(r['listing'], t)} · ${t.pick('požiadal(a)', 'asked')} ${_waiting(asString(r['createdAt']), t)}${blocked ? ' · ${t.pick('termín už nie je voľný', 'dates no longer free')}' : ''}',
        '/host/reservations/${asString(r['id'])}',
        asString(pick(r, 'listing.id')),
      ));
    }

    for (final c in asMapList(pick(d, 'calendar.conflicts'))) {
      final feed = asMapList(c['conflicts']).any((x) => asString(x['kind']) == 'feed');
      final source = feed ? t.pick('importovaný kalendár', 'an imported calendar') : t.pick('vaša blokácia', 'your own block');
      tasks.add(_Task(
        'conflict:${asString(c['reservationId'])}',
        'calendar',
        _Tone.urgent,
        '${t.pick('Dvojitá rezervácia', 'Double booking')}: ${asString(c['guestName'])}',
        '${_listing(c['listing'], t)} · ${_range(c, t)} · ${t.pick('prekrýva sa s', 'overlaps')} $source',
        '/host/calendar',
        asString(pick(c, 'listing.id')),
      ));
    }
    for (final f in asMapList(pick(d, 'calendar.feedFailures'))) {
      final label = asString(f['label']);
      tasks.add(_Task(
        'feed:${asString(pick(f, 'listing.id'))}:${asString(f['feedId'])}',
        'calendar',
        _Tone.warn,
        '${t.pick('Kalendárny odkaz zlyhal', 'Calendar link failed')}: ${label.isEmpty ? t.pick('kanál', 'feed') : label}',
        '${_listing(f['listing'], t)} · ${f['hasImportedDates'] == true ? t.pick('staršie importované dátumy sa stále používajú', 'older imported dates are still in use') : t.pick('zatiaľ sa nenaimportovali žiadne dátumy', 'no dates imported yet')}',
        '/host/calendar',
        asString(pick(f, 'listing.id')),
      ));
    }

    for (final m in asMapList(pick(d, 'messages.items'))) {
      tasks.add(_Task('message:${asString(m['id'])}', 'messages', _Tone.info, asString(m['guestName']),
          '${_listing(m['listing'], t)} · ${_unread(asInt(m['unreadCount']), t)}', '/host/messages/${asString(m['id'])}', asString(pick(m, 'listing.id'))));
    }

    final blocker = pick(d, 'payouts.blocker');
    if (blocker != null) {
      final live = asInt(pick(blocker, 'liveListings'));
      tasks.add(_Task(
        'payouts:not-connected',
        'payouts',
        _Tone.info,
        t.pick('Výplaty nie sú nastavené', "Payouts aren't set up"),
        t.isEn
            ? '$live live ${live == 1 ? 'listing has' : 'listings have'} no way to be paid yet.'
            : '${live == 1 ? '1 zverejnená ponuka zatiaľ nemá' : (live >= 2 && live <= 4 ? '$live zverejnené ponuky zatiaľ nemajú' : '$live zverejnených ponúk zatiaľ nemá')} spôsob výplaty.',
        '/host/payouts',
        null,
      ));
    }
    return tasks;
  }

  // ─────────────────────────── widgets ───────────────────────────
  Widget _figures(BuildContext context, Strings t, Json d) {
    final items = [
      (asInt(pick(d, 'setup.counts.live')), t.pick('Zverejnené ponuky', 'Live listings'), '/host/listings'),
      (asInt(pick(d, 'requests.count')), t.pick('Otvorené žiadosti', 'Open requests'), '/host/reservations?stage=request'),
      (asInt(pick(d, 'messages.unreadMessages')), t.pick('Neprečítané správy', 'Unread messages'), '/host/messages'),
    ];
    return Row(children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            elevation: 0.5,
            shadowColor: const Color(0x0D000000),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => context.go(items[i].$3),
              child: Container(
                constraints: const BoxConstraints(minHeight: 80),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('${items[i].$1}', style: AppText.inter(size: 24, weight: FontWeight.w800, color: _forest, height: 1)),
                  const SizedBox(height: 6),
                  Text(items[i].$2.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3, height: 1.25)),
                ]),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _groupSection(BuildContext context, Strings t, String group, List<_Task> tasks) {
    final title = switch (group) {
      'setup' => t.pick('Dokončite nastavenie', 'Finish setup'),
      'requests' => t.pick('Čaká na vašu odpoveď', 'Waiting for your reply'),
      'calendar' => t.pick('Kalendár potrebuje pozornosť', 'Calendar needs attention'),
      'messages' => t.pick('Neprečítané správy', 'Unread messages'),
      _ => t.pick('Výplaty', 'Payouts'),
    };
    final icon = switch (group) {
      'setup' => Icons.checklist_rounded,
      'requests' => Icons.assignment_outlined,
      'calendar' => Icons.event_busy_outlined,
      'messages' => Icons.forum_outlined,
      _ => Icons.account_balance_outlined,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(title.toUpperCase(), style: AppText.inter(size: 13, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(99)),
          child: Text('${tasks.length}', style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral700)),
        ),
      ]),
      const SizedBox(height: 8),
      for (final task in tasks) Padding(padding: const EdgeInsets.only(bottom: 8), child: _TaskCard(task: task, icon: icon, onTap: () => context.go(task.href))),
    ]);
  }

  Widget _empty(Strings t, bool filtered, int hidden, VoidCallback showAll) => Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
        child: Column(children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: Color(0xFFF0FDF4), shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline, size: 30, color: Color(0xFF16A34A)),
          ),
          const SizedBox(height: 16),
          Text(
            filtered ? t.pick('Pre toto ubytovanie nie je čo riešiť', 'Nothing to do for this property') : t.pick('Nič nevyžaduje vašu pozornosť', 'Nothing needs your attention'),
            textAlign: TextAlign.center,
            style: AppText.inter(size: 20, weight: FontWeight.w700, color: _forest),
          ),
          const SizedBox(height: 8),
          Text(
            t.pick('Momentálne žiadne otvorené žiadosti, problémy s kalendárom ani neprečítané správy.', 'No open requests, calendar problems or unread messages right now.'),
            textAlign: TextAlign.center,
            style: AppText.inter(size: 15, color: AppColors.neutral600, height: 1.5),
          ),
          if (hidden > 0) ...[
            const SizedBox(height: 20),
            TextButton(
              onPressed: showAll,
              child: Text(t.pick('Zobraziť všetky ubytovania ($hidden)', 'Show all properties ($hidden)'),
                  style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            ),
          ],
        ]),
      );

  Widget _notice(String text, Color bg, Color border, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: border)),
        child: Text(text, style: AppText.inter(size: 13, weight: FontWeight.w600, color: fg)),
      );

  Widget _errorCard(Strings t, Object error, VoidCallback retry) => Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFFECACA))),
        child: Column(children: [
          const Icon(Icons.error_outline, size: 30, color: Color(0xFFB91C1C)),
          const SizedBox(height: 16),
          Text(t.pick('Dnešný prehľad sa nepodarilo načítať', "We couldn't load today's overview"),
              textAlign: TextAlign.center, style: AppText.inter(size: 20, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
          const SizedBox(height: 8),
          Text(errorText(error), textAlign: TextAlign.center, style: AppText.inter(size: 15, color: const Color(0xFFDC2626))),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 15, weight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB91C1C),
              backgroundColor: Colors.white,
              side: const BorderSide(color: Color(0xFFFECACA)),
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
      );

  Widget _skeleton() {
    Widget box(double h, {bool bordered = false}) => Container(
          height: h,
          decoration: BoxDecoration(
            color: bordered ? Colors.white : AppColors.neutral200,
            borderRadius: BorderRadius.circular(16),
            border: bordered ? Border.all(color: AppColors.neutral200) : null,
          ),
        );
    return Column(children: [
      Row(children: [
        for (var i = 0; i < 3; i++) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: box(80))],
      ]),
      const SizedBox(height: 12),
      for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 12), child: box(72, bordered: true)),
    ]);
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.t,
    required this.listings,
    required this.property,
    required this.refreshing,
    required this.showRefresh,
    required this.wide,
    required this.onProperty,
    required this.onRefresh,
  });
  final Strings t;
  final List<Json> listings;
  final String? property;
  final bool refreshing;
  final bool showRefresh;
  final bool wide;
  final ValueChanged<String?> onProperty;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final date = DateFormat('EEEE, d. MMMM', 'en_GB').format(now);
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(date.toUpperCase(), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
      Text(t.pick('Dnes', 'Today'), style: AppText.inter(size: 30, weight: FontWeight.w700, color: _forest, letterSpacing: -0.75, height: 1.2)),
    ]);

    Widget? select;
    if (listings.length > 1) {
      select = Container(
        height: 48,
        constraints: BoxConstraints(minWidth: wide ? 240 : 0),
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
              for (final l in listings)
                DropdownMenuItem<String?>(
                  value: asString(l['id']),
                  child: Text(_name(l), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onProperty,
          ),
        ),
      );
    }
    final refresh = showRefresh
        ? Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: refreshing ? null : onRefresh,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
                child: refreshing
                    ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 2, color: _forest))
                    : const Icon(Icons.refresh, size: 18, color: _forest),
              ),
            ),
          )
        : null;

    final controls = Row(mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max, children: [
      if (select != null) wide ? select : Expanded(child: select),
      if (select != null && refresh != null) const SizedBox(width: 8),
      if (refresh != null) refresh,
    ]);

    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: title), controls]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      title,
      if (select != null || refresh != null) ...[const SizedBox(height: 12), controls],
    ]);
  }

  String _name(Json l) {
    final n = asString(pick(l, 'data.name')).trim();
    final m = asString(l['name']).trim();
    return n.isNotEmpty ? n : (m.isNotEmpty ? m : t.pick('Ponuka bez názvu', 'Unnamed listing'));
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.icon, required this.onTap});
  final _Task task;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bar, border, iconBg, iconFg) = switch (task.tone) {
      _Tone.urgent => (const Color(0xFFEF4444), const Color(0xFFFECACA), const Color(0xFFFEF2F2), const Color(0xFFDC2626)),
      _Tone.warn => (const Color(0xFFF59E0B), const Color(0xFFFCD34D), const Color(0xFFFFFBEB), const Color(0xFFB45309)),
      _Tone.todo => (_gold, AppColors.neutral200, _gold.withValues(alpha: 0.1), _gold),
      _Tone.info => (_forest, AppColors.neutral200, _forest.withValues(alpha: 0.05), _forest),
    };
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 0.5,
      shadowColor: const Color(0x0D000000),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: border)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(width: 4, color: bar),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
                        child: Icon(icon, size: 20, color: iconFg),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
                          const SizedBox(height: 2),
                          Text(task.detail, style: AppText.inter(size: 13, color: AppColors.neutral600, height: 1.375)),
                        ]),
                      ),
                      const SizedBox(width: 12),
                      const Icon(Icons.chevron_right, size: 20, color: AppColors.neutral400),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
