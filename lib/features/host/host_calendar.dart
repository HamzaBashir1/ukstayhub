import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../widgets/common.dart';
import 'host_add_dates.dart';
import 'host_calendar_feeds.dart';
import 'host_reservations.dart' show confirmHostCancelStay;
import 'host_shell.dart';

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

/// calendarModel ALL_LISTINGS – the combined, read-only view of every property.
const _allListings = 'all';

Json? _mapOrNull(dynamic v) => v is Map ? asMap(v) : null;

String _name(Json l, Strings t) {
  final n = asString(pick(l, 'data.name')).trim();
  if (n.isNotEmpty) return n;
  final m = asString(l['name']).trim();
  return m.isNotEmpty ? m : t.pick('Ponuka bez názvu', 'Unnamed listing');
}

DateTime _d(String iso) => DateTime.parse('${iso}T00:00:00Z');
String _iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d.toUtc());
int _days(String a, String b) => _d(b).difference(_d(a)).inDays + 1;

String _fmtDay(String iso, String lang, {bool year = false, bool weekday = false}) {
  const f = 'en_GB';
  final pattern = '${weekday ? 'EEE, ' : ''}d MMM${year ? ' y' : ''}';
  return DateFormat(pattern, f).format(_d(iso));
}

String _fmtRange(String a, String b, String lang) {
  if (a == b) return _fmtDay(a, lang, year: true, weekday: true);
  final sameYear = a.substring(0, 4) == b.substring(0, 4);
  return '${_fmtDay(a, lang, year: !sameYear)} – ${_fmtDay(b, lang, year: true)}';
}

String _daysLabel(int n, Strings t) {
  if (t.isEn) return '$n ${n == 1 ? 'day' : 'days'}';
  return '$n ${n == 1 ? 'deň' : (n >= 2 && n <= 4 ? 'dni' : 'dní')}';
}

/// host/calendar/HostCalendarPage.js + MonthGrid.js – month/list view per property,
/// block/unblock ranges, connected iCal calendars.
class HostCalendarScreen extends ConsumerStatefulWidget {
  const HostCalendarScreen({super.key, this.initialListingId});
  final String? initialListingId;
  @override
  ConsumerState<HostCalendarScreen> createState() => _HostCalendarScreenState();
}

class _HostCalendarScreenState extends ConsumerState<HostCalendarScreen> {
  String? _id;
  Json? _snap;
  Object? _loadError;
  String? _action; // 'block' | 'unblock'
  String? _actionError;
  DateTime _month = DateTime.utc(DateTime.now().year, DateTime.now().month);
  String? _unitId; // on a listing split into units: the unit on screen, null = all
  String? _anchor;
  ({String start, String end})? _sel;
  bool _list = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String get _today => (_snap?['today'] as String?) ?? _iso(DateTime.now());

  bool get _isAll => _id == _allListings;

  Future<Json> _fetch(String id) => id == _allListings ? hostRepo.allCalendars() : hostRepo.calendar(id);

  /// Re-read the snapshot without blanking the screen (after a cancel / unblock).
  Future<void> _reload() async {
    final id = _id;
    if (id == null) return;
    try {
      final s = await _fetch(id);
      if (mounted && _id == id) setState(() => _snap = s);
    } catch (_) {}
  }

  Future<void> _load(String id) async {
    setState(() {
      _id = id;
      _loadError = null;
      _anchor = null;
      _sel = null;
      _snap = null;
      _unitId = null;
    });
    try {
      final s = await _fetch(id);
      if (mounted && _id == id) setState(() => _snap = s);
    } catch (e) {
      if (mounted && _id == id) setState(() => _loadError = e);
    }
  }

  List<Json> get _units => asMapList(_snap?['units']);
  // One unit (or none) behaves like a listing without units: no switcher, no labels.
  bool get _hasUnits => _units.length > 1;
  String? get _activeUnitId => _hasUnits && _units.any((u) => asString(u['id']) == _unitId) ? _unitId : null;

  /// The blocks that matter for the unit on screen: its own and the whole listing's.
  List<Json> get _blocks {
    final all = asMapList(_snap?['blocks']);
    final u = _activeUnitId;
    return u == null ? all : all.where((b) => asStringOrNull(b['unitId']) == null || asString(b['unitId']) == u).toList();
  }

  List<Json> _on(String iso) => _blocks.where((b) => asString(b['startDate']).compareTo(iso) <= 0 && asString(b['endDate']).compareTo(iso) >= 0).toList();

  ({bool manual, bool reserved, bool feed, bool full, Json? reservation}) _cover(String iso) {
    var manual = false, feed = false, full = false;
    final u = _activeUnitId;
    Json? res;
    for (final b in _on(iso)) {
      final bu = asStringOrNull(b['unitId']);
      if (bu == null || (u != null && bu == u)) full = true;
      switch (asString(b['source'])) {
        case 'manual':
          manual = true;
        case 'reservation':
          res ??= b;
        default:
          feed = true;
      }
    }
    return (manual: manual, reserved: res != null, feed: feed, full: full, reservation: res);
  }

  ({int days, bool canBlock, bool canUnblock, int feedDays, int reservedDays}) _summary() {
    final s = _sel;
    if (s == null) return (days: 0, canBlock: false, canUnblock: false, feedDays: 0, reservedDays: 0);
    var manual = 0, feed = 0, reserved = 0, covered = 0;
    final total = _days(s.start, s.end);
    for (var i = 0; i < total; i++) {
      final c = _cover(_iso(_d(s.start).add(Duration(days: i))));
      if (c.manual) manual++;
      if (c.feed) feed++;
      if (c.reserved) reserved++;
      // A day blocked for one unit only is still open to block for the rest.
      if ((c.manual && c.full) || c.reserved) covered++;
    }
    return (days: total, canBlock: covered < total, canUnblock: manual > 0, feedDays: feed, reservedDays: reserved);
  }

  void _clear() => setState(() {
        _anchor = null;
        _sel = null;
        _note.clear();
        _actionError = null;
      });

  void _tap(String iso) {
    setState(() => _actionError = null);
    if (_sel != null) {
      setState(() {
        _sel = null;
        _anchor = iso;
      });
      return;
    }
    if (_anchor == null && _on(iso).isNotEmpty) {
      _openDay(iso);
      return;
    }
    if (_isAll) return;
    if (_anchor == null) {
      setState(() => _anchor = iso);
    } else {
      final a = _anchor!;
      setState(() {
        _sel = a.compareTo(iso) <= 0 ? (start: a, end: iso) : (start: iso, end: a);
        _anchor = null;
      });
    }
  }

  Future<void> _run(bool block) async {
    final s = _sel;
    final t = ref.read(stringsProvider);
    if (s == null || _id == null || _action != null) return;
    setState(() {
      _action = block ? 'block' : 'unblock';
      _actionError = null;
    });
    try {
      final snap = block
          ? await hostRepo.block(_id!, s.start, s.end, note: _note.text.trim().isEmpty ? null : _note.text.trim(), unitId: _activeUnitId)
          : await hostRepo.unblock(_id!, s.start, s.end, unitId: _activeUnitId);
      if (!mounted) return;
      setState(() => _snap = snap);
      _clear();
      ref.invalidate(hostDashboardProvider);
      toast(context, block ? t.pick('Dni boli zablokované.', 'Dates blocked.') : t.pick('Dni boli uvoľnené.', 'Dates opened.'));
    } catch (e) {
      if (mounted) setState(() => _actionError = errorText(e));
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _unblockBlock(Json b) async {
    if (_id == null || _action != null) return;
    setState(() => _action = 'unblock');
    try {
      final snap = await hostRepo.unblock(_id!, asString(b['startDate']), asString(b['endDate']), blockId: asString(b['id']));
      if (mounted) setState(() => _snap = snap);
      ref.invalidate(hostDashboardProvider);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  /// Name of the property a block belongs to (the combined view mixes several).
  String _blockListing(Json b, Strings t) {
    final src = _mapOrNull(b['sourceListing']) ?? _mapOrNull(_snap?['listing']);
    return src == null ? t.pick('Kalendár', 'Calendar') : _name(src, t);
  }

  bool _showUnit(Json b) => _isAll ? asString(b['unitName']).isNotEmpty : _hasUnits;
  String _unitLabel(Json b, Strings t) {
    final n = asString(b['unitName']);
    return n.isNotEmpty ? n : t.pick('Všetky jednotky', 'All units');
  }

  /// Day sheet (web: dialog from sm, bottom sheet below).
  void _openDay(String iso) {
    final t = ref.read(stringsProvider);
    final sm = MediaQuery.sizeOf(context).width >= 640;
    final blocks = _on(iso)
      ..sort((a, b) {
        int rank(Json x) => asString(x['source']) == 'reservation' ? 0 : (asString(x['source']) == 'manual' ? 1 : 2);
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : asString(a['startDate']).compareTo(asString(b['startDate']));
      });
    String? pending; // block id awaiting the second tap that confirms removal
    Widget content(BuildContext ctx, StateSetter set) => Stack(children: [
          SingleChildScrollView(
            padding: EdgeInsets.all(sm ? 32 : 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: _forest.withValues(alpha: 0.05), shape: BoxShape.circle),
                  child: const Icon(Icons.calendar_today_outlined, size: 24, color: _forest),
                ),
              ),
              const SizedBox(height: 16),
              Text(t.pick('Detaily ubytovania', 'Accommodation Details'), textAlign: TextAlign.center, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest)),
              const SizedBox(height: 12),
              Center(child: Container(width: 48, height: 4, decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(99)))),
              const SizedBox(height: 8),
              Text(_fmtDay(iso, t.lang, year: true, weekday: true), textAlign: TextAlign.center, style: AppText.inter(size: 13, color: AppColors.neutral500)),
              const SizedBox(height: 24),
              for (var i = 0; i < blocks.length; i++) ...[
                _sheetRow(ctx, t, blocks[i], i, blocks.length, pending, (v) => set(() => pending = v)),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _forest,
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _forest.withValues(alpha: 0.1)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(t.pick('Zavrieť', 'Close'), style: AppText.inter(size: 14, weight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              tooltip: t.pick('Zavrieť', 'Close'),
              onPressed: () => Navigator.pop(ctx),
              icon: const Icon(Icons.close, size: 20, color: AppColors.neutral400),
            ),
          ),
        ]);
    if (sm) {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 512), child: StatefulBuilder(builder: content)),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) => StatefulBuilder(builder: content),
      );
    }
  }

  Widget _sheetRow(BuildContext ctx, Strings t, Json b, int index, int count, String? pending, ValueChanged<String?> setPending) {
    final src = asString(b['source']);
    final feeds = asMapList(_snap?['feeds']);
    final feed = src == 'feed' ? feeds.where((f) => asString(f['id']) == asString(b['feedId'])).firstOrNull : null;
    final note = asString(b['note']);
    final detailLabel = src == 'reservation'
        ? t.pick('Meno hosťa', 'Guest Name')
        : src == 'feed'
            ? t.pick('Synchronizovaný kalendár', 'Synced Calendar')
            : t.pick('Poznámka', 'Note');
    final feedLabel = asString(feed?['label']).trim();
    final detailValue = src == 'reservation'
        ? (note.isNotEmpty ? note : t.pick('Hosť', 'Guest'))
        : src == 'feed'
            ? (feedLabel.isNotEmpty ? feedLabel : t.pick('Nepomenovaný kalendár', 'Unnamed calendar'))
            : (note.isNotEmpty ? note : t.pick('Blokované vami', 'Blocked by you'));
    final s = asString(b['startDate']);
    final e = asString(b['endDate']);
    final reservationId = asStringOrNull(b['reservationId']);
    final busy = _action != null;

    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '$label: ', style: AppText.inter(size: 14, weight: FontWeight.w600, color: _forest.withValues(alpha: 0.7))),
            TextSpan(text: value, style: AppText.inter(size: 14, color: AppColors.neutral600)),
          ])),
        );
    Widget infoBox(String text) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: _forest.withValues(alpha: 0.1))),
          child: Text(text, style: AppText.inter(size: 12, weight: FontWeight.w500, color: _forest.withValues(alpha: 0.7), height: 1.5)),
        );
    Widget pill(String label, VoidCallback? onTap, {IconData? icon, Color fg = _forest, Color bg = Colors.white, Color? border, Color? spinner}) => Material(
          color: bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: border == null ? BorderSide.none : BorderSide(color: border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Opacity(
              opacity: onTap == null ? 0.5 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (spinner != null) ...[SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: spinner)), const SizedBox(width: 6)] else if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
                  Text(label, style: AppText.inter(size: 14, weight: FontWeight.w500, color: fg)),
                ]),
              ),
            ),
          ),
        );

    final Widget action;
    if (src == 'reservation') {
      if (b['pending'] == true) {
        action = infoBox(t.pick('Hosť práve platí za tieto dni. Ak platbu nedokončí, dni sa automaticky uvoľnia.', 'A guest is paying for these dates right now. They free up on their own if the payment is not completed.'));
      } else if (reservationId != null) {
        action = Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            pill(t.pick('Zrušiť rezerváciu', 'Cancel booking'), busy ? null : () async {
              if (await confirmHostCancelStay(context, ref, reservationId)) {
                if (ctx.mounted) Navigator.pop(ctx);
                ref.invalidate(hostDashboardProvider);
                await _reload();
              }
            }, icon: Icons.delete_outline, fg: const Color(0xFFDC2626), bg: const Color(0xFFFEF2F2)),
            pill(t.pick('Otvoriť rezerváciu', 'Open reservation'), () {
              Navigator.pop(ctx);
              context.go('/host/reservations/$reservationId');
            }, border: _gold, bg: _gold.withValues(alpha: 0.1)),
          ]),
        );
      } else {
        action = Padding(padding: const EdgeInsets.only(top: 12), child: Text(t.pick('Spravované v Rezerváciách', 'Managed in Reservations'), style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)));
      }
    } else if (src == 'manual' && _isAll) {
      action = Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: pill(t.pick('Otvoriť jeho kalendár a uvoľniť', 'Open its calendar to unblock'), () {
            Navigator.pop(ctx);
            _load(asString(b['sourceListingId']));
          }, border: AppColors.neutral200),
        ),
      );
    } else if (src == 'manual') {
      action = Padding(
        padding: const EdgeInsets.only(top: 12),
        child: pending == asString(b['id'])
            ? Wrap(spacing: 8, runSpacing: 8, children: [
                pill(t.pick('Áno, uvoľniť', 'Yes, unblock'), busy ? null : () {
                  Navigator.pop(ctx);
                  _unblockBlock(b);
                }, fg: Colors.white, bg: const Color(0xFFDC2626)),
                pill(t.pick('Ponechať', 'Keep'), busy ? null : () => setPending(null), border: AppColors.neutral200),
              ])
            : Align(alignment: Alignment.centerLeft, child: pill(t.pick('Uvoľniť', 'Unblock'), busy ? null : () => setPending(asString(b['id'])), icon: Icons.delete_outline, fg: const Color(0xFFDC2626), bg: const Color(0xFFFEF2F2))),
      );
    } else {
      action = infoBox(t.pick('Tieto dni odstráňte v kalendári, z ktorého pochádzajú, inak sa pri ďalšom načítaní importujú späť.', 'Remove these dates in the calendar they came from, or the next fetch will import them again.'));
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFFFAFAFA), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFF3F4F6))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (count > 1) ...[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: _gold, shape: BoxShape.circle),
            child: Text('${index + 1}', style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_blockListing(b, t), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
            const SizedBox(height: 4),
            line(detailLabel, detailValue),
            if (_showUnit(b)) line(t.pick('Jednotka', 'Unit'), _unitLabel(b, t)),
            line(t.pick('Začiatok', 'Start Date'), _fmtDay(s, t.lang, year: true)),
            line(t.pick('Koniec', 'End Date'), _fmtDay(e, t.lang, year: true)),
            Padding(padding: const EdgeInsets.only(top: 2), child: Text(_daysLabel(_days(s, e), t), style: AppText.inter(size: 14, color: AppColors.neutral500))),
            if (src == 'feed')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  const Icon(Icons.event_available_outlined, size: 16, color: Color(0xFF319A81)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(t.pick('Importované z pripojeného kalendára', 'Imported from a connected calendar'), style: AppText.inter(size: 14, color: AppColors.neutral600))),
                ]),
              ),
            action,
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final owned = ref.watch(hostOwnedProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final sm = width >= 640;
    final padX = wide ? 0.0 : 16.0;

    Widget page(Widget child) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 896), child: Padding(padding: EdgeInsets.symmetric(horizontal: padX), child: child)));

    return owned.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(hostOwnedProvider)),
      data: (items) {
        if (items.isEmpty) {
          return ListView(children: [
            page(Container(
              padding: EdgeInsets.all(wide ? 56 : 32),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
              child: Column(children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), shape: BoxShape.circle),
                  child: const Icon(Icons.calendar_month_outlined, size: 36, color: _gold),
                ),
                const SizedBox(height: 24),
                Text(t.pick('Zatiaľ žiadny kalendár', 'No calendar yet'), style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest)),
                const SizedBox(height: 12),
                Text(
                  t.pick('Každá ponuka má vlastný kalendár dostupnosti. Vytvorte prvú ponuku a začnite blokovať termíny.',
                      'Each listing gets its own availability calendar. Create your first listing to start blocking dates.'),
                  textAlign: TextAlign.center,
                  style: AppText.inter(size: 15, color: AppColors.neutral500, height: 1.6),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () => context.go('/host/listings'),
                  style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 32), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: Text(t.pick('Vytvoriť ponuku', 'Create a listing'), style: AppText.inter(color: Colors.white, size: 15, weight: FontWeight.w700)),
                ),
              ]),
            )),
          ]);
        }
        if (_id == null) {
          final first = widget.initialListingId ?? (items.length == 1 ? asString(items.first['id']) : _allListings);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _id == null) _load(first);
          });
        }
        final current = items.where((a) => asString(a['id']) == _id).firstOrNull;
        final title = _isAll ? t.pick('Všetky ponuky', 'All listings') : (current != null ? _name(current, t) : t.pick('Kalendár', 'Calendar'));

        final switcher = Container(
          height: 48,
          constraints: BoxConstraints(minWidth: sm ? 260 : 0),
          padding: const EdgeInsets.only(left: 16, right: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _id,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.neutral500),
              style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest),
              borderRadius: BorderRadius.circular(12),
              items: [
                DropdownMenuItem(value: _allListings, child: Text(t.pick('Všetky ponuky', 'All listings'), overflow: TextOverflow.ellipsis)),
                for (final a in items) DropdownMenuItem(value: asString(a['id']), child: Text(_name(a, t), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => v == null || v == _id ? null : _load(v),
            ),
          ),
        );
        final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.pick('KALENDÁR', 'CALENDAR'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest, height: 1.33)),
        ]);
        final header = sm
            ? Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: titleBlock), const SizedBox(width: 12), switcher])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [titleBlock, const SizedBox(height: 12), switcher]);

        Widget body;
        if (_loadError != null && _snap == null) {
          body = _statePanel(
            icon: Icons.error_outline,
            error: true,
            title: t.pick('Kalendár sa nepodarilo načítať', "We couldn't load this calendar"),
            body: errorText(_loadError!),
            action: OutlinedButton.icon(
              onPressed: () => _load(_id!),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 15, weight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          );
        } else if (_snap == null) {
          body = Column(children: [
            Container(height: 420, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200))),
            const SizedBox(height: 16),
            Container(height: 160, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200))),
          ]);
        } else {
          body = _content(t, sm, items);
        }

        final active = !_list && !_isAll && (_sel != null || _anchor != null);
        return Stack(children: [
          RefreshIndicator(
            color: _forest,
            onRefresh: () async {
              if (_id != null) await _load(_id!);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: active ? 220 : 32),
              children: [
                page(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, const SizedBox(height: 16), body])),
              ],
            ),
          ),
          if (active && _snap != null) Positioned(left: 12, right: 12, bottom: 12, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 768), child: _actionBar(t)))),
        ]);
      },
    );
  }

  Widget _statePanel({required IconData icon, required String title, required String body, Widget? action, bool error = false}) => Container(
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
          if (action != null) ...[const SizedBox(height: 24), action],
        ]),
      );

  Widget _content(Strings t, bool sm, List<Json> items) {
    final nowMonth = DateTime.utc(DateTime.now().year, DateTime.now().month);
    final isCurrent = _month == nowMonth;
    Widget tab(bool list, IconData icon, String label) {
      final on = _list == list;
      return Material(
        color: on ? Colors.white : Colors.transparent,
        elevation: on ? 0.5 : 0,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _list = list),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: on ? _forest : AppColors.neutral500),
              const SizedBox(width: 6),
              Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700, color: on ? _forest : AppColors.neutral500)),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_hasUnits) ...[_unitSwitcher(t), const SizedBox(height: 12)],
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: AppColors.neutral100, borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            tab(false, Icons.calendar_today_outlined, t.pick('Mesiac', 'Month')),
            tab(true, Icons.list, t.pick('Zoznam', 'List')),
          ]),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (!_list && !isCurrent)
            TextButton(
              onPressed: () => setState(() => _month = nowMonth),
              style: TextButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: Text(t.pick('Dnes', 'Today'), style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest).copyWith(decoration: TextDecoration.underline, decorationColor: _gold, decorationThickness: 2)),
            ),
          if (items.isNotEmpty) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final done = await showAddOwnDatesDialog(context, t: t, listings: items, defaultListingId: _isAll ? null : _id, defaultUnitId: _activeUnitId);
                // Only re-read when the block landed on the property on screen (or the combined view).
                if (done != null && _id != null && (_isAll || done.listingId == _id)) await _reload();
              },
              icon: const Icon(Icons.edit_calendar_outlined, size: 16),
              label: Text(sm ? t.pick('Pridať vlastný termín', 'Add your own dates') : t.pick('Pridať termín', 'Add dates'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: _forest, width: 2), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ],
        ]),
      ]),
      const SizedBox(height: 12),
      if (!_list) ...[
        Text(
          t.pick('Ťuknite na voľný deň a potom na ďalší, aby ste termín zablokovali alebo uvoľnili. Ťuknite na rezervovaný alebo blokovaný deň a uvidíte, čo na ňom je.',
              'Tap a free day, then another, to block or open dates. Tap a booked or blocked day to see what is on it.'),
          style: AppText.inter(size: 13, color: AppColors.neutral600, height: 1.5),
        ),
        const SizedBox(height: 12),
        _monthGrid(t, sm, isCurrent),
      ] else
        _upcoming(t),
      const SizedBox(height: 16),
      if (!_isAll) CalendarFeedsPanel(t: t, listingId: _id!, snapshot: _snap!, units: _hasUnits ? _units : const [], onSnapshot: (s) => mounted ? setState(() => _snap = s) : null),
    ]);
  }

  String _unitName(String id) => asString(_units.where((u) => asString(u['id']) == id).firstOrNull?['name']);

  /// "All units" / A1 / A2 … — choosing a unit shows only its own and whole-listing blocks.
  Widget _unitSwitcher(Strings t) {
    final options = <({String? id, String name})>[(id: null, name: t.pick('Všetky jednotky', 'All units')), for (final u in _units) (id: asString(u['id']), name: asString(u['name']))];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final o in options)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() {
              _unitId = o.id;
              _anchor = null;
              _sel = null;
            }),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 56),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: _activeUnitId == o.id ? _forest : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _activeUnitId == o.id ? _forest : AppColors.neutral200, width: 2),
              ),
              child: Center(widthFactor: 1, heightFactor: 1, child: Text(o.name, style: AppText.inter(size: 13, weight: FontWeight.w700, color: _activeUnitId == o.id ? Colors.white : _forest))),
            ),
          ),
      ]),
      const SizedBox(height: 12),
      Text(
        _activeUnitId != null
            ? t.pick('Zobrazená jednotka ${_unitName(_activeUnitId!)}. Termíny, ktoré tu zablokujete, zatvoria len ${_unitName(_activeUnitId!)}.',
                'Showing ${_unitName(_activeUnitId!)}. Dates you block here close ${_unitName(_activeUnitId!)} only.')
            : t.pick('Zobrazené všetky jednotky. Termíny, ktoré tu zablokujete, zatvoria všetky jednotky — ak chcete blokovať len jednu, vyberte ju vyššie.',
                'Showing all units. Dates you block here close every unit — pick a unit above to block just that one.'),
        style: AppText.inter(size: 13, color: AppColors.neutral600, height: 1.5),
      ),
    ]);
  }

  Widget _monthGrid(Strings t, bool sm, bool isCurrent) {
    final first = _month;
    final lead = (first.weekday + 6) % 7;
    final dim = DateUtils.getDaysInMonth(first.year, first.month);
    final rows = ((lead + dim) / 7).ceil();
    final start = first.subtract(Duration(days: lead));
    final labels = [for (var i = 0; i < 7; i++) DateFormat('EEE', 'en_GB').format(DateTime.utc(2024, 1, 1 + i)).replaceAll('.', '')];
    final today = _today;
    final cell = sm ? 48.0 : 44.0;
    final prev = DateTime.utc(first.year, first.month - 1);
    final next = DateTime.utc(first.year, first.month + 1);

    Widget navBtn(IconData icon, VoidCallback? onTap) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.4 : 1,
            child: Container(width: 44, height: 44, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)), child: Icon(icon, size: 20, color: _forest)),
          ),
        );

    return Container(
      padding: EdgeInsets.all(sm ? 20 : 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          navBtn(Icons.chevron_left, isCurrent ? null : () => setState(() => _month = prev)),
          Expanded(child: Text(monthTitle(first, t.lang), textAlign: TextAlign.center, style: AppText.inter(size: 17, weight: FontWeight.w700, color: _forest))),
          navBtn(Icons.chevron_right, () => setState(() => _month = next)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          for (final l in labels)
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(l.toUpperCase(), textAlign: TextAlign.center, style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 0.3)))),
        ]),
        const SizedBox(height: 4),
        for (var r = 0; r < rows; r++)
          Padding(
            padding: EdgeInsets.only(bottom: r == rows - 1 ? 0 : 4),
            child: Row(children: [
              for (var c = 0; c < 7; c++)
                Expanded(
                  child: Builder(builder: (_) {
                    final day = start.add(Duration(days: r * 7 + c));
                    final iso = _iso(day);
                    final inMonth = day.month == first.month;
                    final past = iso.compareTo(today) < 0;
                    final cov = _cover(iso);
                    final selected = _sel != null && iso.compareTo(_sel!.start) >= 0 && iso.compareTo(_sel!.end) <= 0;
                    final isAnchor = _anchor == iso && _sel == null;
                    final interactive = !past && _action == null;

                    Color? bg = Colors.white;
                    Color fg = _forest;
                    var striped = false;
                    // "All units" view: only some units are closed on this day.
                    final partial = _hasUnits && !cov.full && (cov.manual || cov.reserved);
                    if (partial) {
                      bg = cov.reserved ? _gold.withValues(alpha: 0.35) : _forest.withValues(alpha: 0.2);
                    } else if (cov.reserved) {
                      bg = _gold;
                    } else if (cov.manual) {
                      bg = _forest;
                      fg = Colors.white;
                    } else if (cov.feed) {
                      striped = true;
                      fg = AppColors.neutral600;
                    }
                    var opacity = 1.0;
                    if (!inMonth) opacity *= 0.4;
                    if (past) opacity *= 0.35;
                    final ring = selected || isAnchor;

                    return Center(
                      child: GestureDetector(
                        onTap: interactive ? () => _tap(iso) : null,
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            height: cell,
                            width: double.infinity,
                            margin: EdgeInsets.all(ring ? 1 : 0),
                            decoration: BoxDecoration(
                              color: striped ? null : bg,
                              borderRadius: BorderRadius.circular(12),
                              border: ring ? Border.all(color: _gold, width: 3) : null,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(ring ? 9 : 12),
                              child: Stack(alignment: Alignment.center, children: [
                                if (striped) Positioned.fill(child: CustomPaint(painter: _StripePainter())),
                                Text('${day.day}', style: AppText.inter(size: 14, weight: FontWeight.w700, color: fg)),
                                if (iso == today) Positioned(bottom: 4, child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: _gold, shape: BoxShape.circle))),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
            ]),
          ),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 8, children: [
          _legend(Colors.white, t.pick('Voľné', 'Available'), border: AppColors.neutral300),
          _legend(_forest, t.pick('Blokované vami', 'Blocked by you')),
          _legend(_gold, t.pick('Rezervované', 'Reserved')),
          _legend(null, t.pick('Z pripojeného kalendára', 'From a connected calendar'), border: AppColors.neutral300, striped: true),
          if (_hasUnits && _activeUnitId == null) _legend(_forest.withValues(alpha: 0.2), t.pick('Len niektoré jednotky', 'Some units only')),
          _legend(Colors.transparent, t.pick('Vybrané', 'Selected'), border: _gold, borderWidth: 2),
        ]),
      ]),
    );
  }

  Widget _legend(Color? c, String label, {Color? border, double borderWidth = 1, bool striped = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4), border: border == null ? null : Border.all(color: border, width: borderWidth)),
          child: striped ? ClipRRect(borderRadius: BorderRadius.circular(3), child: CustomPaint(painter: _StripePainter(step: 6))) : null,
        ),
        const SizedBox(width: 6),
        Text(label, style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral600)),
      ]);

  Widget _upcoming(Strings t) {
    final today = _today;
    final upcoming = _blocks.where((b) => asString(b['endDate']).compareTo(today) >= 0).toList()
      ..sort((a, b) {
        final c = asString(a['startDate']).compareTo(asString(b['startDate']));
        return c != 0 ? c : asString(a['endDate']).compareTo(asString(b['endDate']));
      });
    final feeds = asMapList(_snap?['feeds']);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.pick('Nadchádzajúce blokované termíny', 'Upcoming blocked dates'), style: AppText.inter(size: 17, weight: FontWeight.w700, color: _forest)),
        const SizedBox(height: 12),
        if (upcoming.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral300)),
            child: Text(t.pick('Nič nie je blokované. Každý deň odo dneška je pre hostí voľný.', 'Nothing is blocked. Every day from today on is open for guests.'),
                textAlign: TextAlign.center, style: AppText.inter(size: 14, color: AppColors.neutral500)),
          )
        else
          for (var i = 0; i < upcoming.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.neutral100),
            _upcomingRow(t, upcoming[i], feeds),
          ],
      ]),
    );
  }

  Widget _upcomingRow(Strings t, Json b, List<Json> feeds) {
    final src = asString(b['source']);
    final s = asString(b['startDate']);
    final e = asString(b['endDate']);
    final note = asString(b['note']);
    final feed = src == 'feed' ? feeds.where((f) => asString(f['id']) == asString(b['feedId'])).firstOrNull : null;
    final feedLabel = asString(feed?['label']).trim();
    final detail = switch (src) {
      'feed' => ' · ${t.pick('z', 'from')} ${feedLabel.isEmpty ? t.pick('pripojeného kalendára', 'connected calendar') : feedLabel}',
      'reservation' => ' · ${t.pick('rezervované', 'reserved')}${note.isEmpty ? '' : ' · $note'}',
      _ => note.isNotEmpty ? ' · $note' : ' · ${t.pick('blokované vami', 'blocked by you')}',
    };
    Widget action;
    if (src == 'reservation') {
      if (b['pending'] == true) {
        action = Text(t.pick('Prebieha platba', 'Payment in progress'), style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500));
      } else if (asStringOrNull(b['reservationId']) != null) {
        final rid = asString(b['reservationId']);
        action = Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
            onPressed: () => context.go('/host/reservations/$rid'),
            style: OutlinedButton.styleFrom(foregroundColor: _forest, backgroundColor: _gold.withValues(alpha: 0.1), side: const BorderSide(color: _gold), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(t.pick('Otvoriť rezerváciu', 'Open reservation'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
          ),
          OutlinedButton(
            onPressed: _action != null
                ? null
                : () async {
                    if (await confirmHostCancelStay(context, ref, rid)) {
                      ref.invalidate(hostDashboardProvider);
                      await _reload();
                    }
                  },
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFDC2626), backgroundColor: const Color(0xFFFEF2F2), side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(t.pick('Zrušiť rezerváciu', 'Cancel booking'), style: AppText.inter(size: 13, weight: FontWeight.w700, color: const Color(0xFFDC2626))),
          ),
        ]);
      } else {
        action = Text(t.pick('Spravované v Rezerváciách', 'Managed in Reservations'), style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500));
      }
    } else if (src == 'manual' && _isAll) {
      action = OutlinedButton(
        onPressed: () => _load(asString(b['sourceListingId'])),
        style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        child: Text(t.pick('Otvoriť jeho kalendár', 'Open its calendar'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
      );
    } else if (src == 'manual') {
      action = OutlinedButton(
        onPressed: _action != null ? null : () => _unblockBlock(b),
        style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        child: Text(t.pick('Uvoľniť', 'Unblock'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
      );
    } else {
      action = Text(t.pick('Spravované v druhom kalendári', 'Managed in the other calendar'), style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 12, spacing: 12, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_isAll) Text(_blockListing(b, t), style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest)),
            Text(_fmtRange(s, e, t.lang), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
            Text('${_daysLabel(_days(s, e), t)}${_showUnit(b) ? ' · ${_unitLabel(b, t)}' : ''}$detail', style: AppText.inter(size: 13, color: AppColors.neutral600)),
          ]),
        ),
        action,
      ]),
    );
  }

  Widget _actionBar(Strings t) {
    final range = _sel ?? (start: _anchor!, end: _anchor!);
    final sum = _summary();
    final busy = _action != null;
    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: const Color(0x1F000000),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_fmtRange(range.start, range.end, t.lang), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
                Text(
                  _sel != null
                      ? '${_daysLabel(sum.days, t)}${sum.reservedDays > 0 ? ' · ${t.pick('niektoré noci sú rezervované', 'some nights are reserved')}' : ''}${sum.feedDays > 0 ? ' · ${t.pick('niektoré dni sú z pripojeného kalendára', 'some days come from a connected calendar')}' : ''}'
                      : t.pick('Teraz ťuknite na posledný deň (alebo znova na ten istý).', 'Now tap the last day (or the same day again).'),
                  style: AppText.inter(size: 12, color: AppColors.neutral600),
                ),
              ]),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: busy ? null : _clear,
              child: const SizedBox(width: 44, height: 44, child: Icon(Icons.close, size: 18, color: AppColors.neutral500)),
            ),
          ]),
          if (_sel != null) ...[
            if (sum.canBlock) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                maxLength: 120,
                style: AppText.inter(size: 14),
                decoration: InputDecoration(
                  counterText: '',
                  isDense: true,
                  hintText: t.pick('Poznámka (nepovinné), napr. rodinná návšteva', 'Note (optional), e.g. family visit'),
                  hintStyle: AppText.inter(size: 14, color: AppColors.neutral400),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.neutral300)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _forest)),
                ),
              ),
            ],
            if (_actionError != null) ...[
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
                const SizedBox(width: 8),
                Expanded(child: Text(_actionError!, style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFDC2626)))),
              ]),
            ],
            if (sum.reservedDays > 0) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _list = true;
                  _clear();
                }),
                icon: const Icon(Icons.list, size: 16),
                label: Text(t.pick('Spravovať rezervované noci', 'Manage reserved nights'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(foregroundColor: _forest, backgroundColor: _gold.withValues(alpha: 0.1), side: const BorderSide(color: _gold), minimumSize: const Size.fromHeight(44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ],
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: !sum.canBlock || busy ? null : () => _run(true),
                  icon: _action == 'block' ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
                  label: Text(t.pick('Blokovať', 'Block'), style: AppText.inter(color: Colors.white, size: 15, weight: FontWeight.w700)),
                  style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: !sum.canUnblock || busy ? null : () => _run(false),
                  icon: _action == 'unblock' ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _forest)) : const SizedBox.shrink(),
                  label: Text(t.pick('Uvoľniť', 'Unblock'), style: AppText.inter(size: 15, weight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: _forest), minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// repeating-linear-gradient(135deg,#E5E7EB 0 4px,#F5F5F5 4px 8px)
class _StripePainter extends CustomPainter {
  _StripePainter({this.step = 8});
  final double step;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF5F5F5));
    final p = Paint()
      ..color = const Color(0xFFE5E7EB)
      ..strokeWidth = step / 2 * 1.4142
      ..style = PaintingStyle.stroke;
    final span = size.width + size.height;
    for (double x = -size.height; x < span; x += step * 1.4142) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.step != step;
}
