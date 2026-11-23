import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/config.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../core/api_client.dart';
import 'editor_rows.dart';

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

// ───────────────────────────── copy (calendarModel.js) ─────────────────────────────
Map<String, (String, String)> _errors(Strings t) => {
      'timeout': ('Druhý kalendár neodpovedal včas.', 'The other calendar did not answer in time.'),
      'unreachable': ('Odkaz sa nepodarilo načítať.', 'The link could not be reached.'),
      'notCalendar': ('Odkaz nevrátil súbor kalendára (.ics).', 'The link did not return a calendar (.ics) file.'),
      'tooLarge': ('Súbor kalendára je príliš veľký.', 'The calendar file is too large.'),
      'unreadable': ('Súbor kalendára sa nepodarilo prečítať.', 'The calendar file could not be read.'),
      'empty': ('Odkaz je prázdny.', 'The link is empty.'),
      'invalidUrl': ('Odkaz nie je platná webová adresa.', 'The link is not a valid web address.'),
      'unsupportedScheme': ('Odkaz musí začínať http:// alebo https://.', 'The link must start with http:// or https://.'),
      'privateHost': ('Odkaz musí smerovať na verejnú adresu.', 'The link must point to a public address.'),
      'tooManyRedirects': ('Odkaz sa presmerúva príliš veľakrát.', 'The link redirects too many times.'),
      'tooManyEvents': ('Tento kalendár má viac budúcich udalostí, než UK Stay Hub dokáže uložiť, preto sa nič nezmenilo.', 'This calendar has more upcoming events than UK Stay Hub can store, so nothing was changed.'),
      'incomplete': ('Súbor kalendára prišiel neúplný, preto sa nič nezmenilo.', 'The calendar file arrived incomplete, so nothing was changed.'),
      'unsupportedRecurrence': ('Tento kalendár používa opakujúce sa udalosti, ktoré UK Stay Hub zatiaľ nevie importovať, preto sa nič nezmenilo.', 'This calendar uses repeating events, which UK Stay Hub cannot import yet, so nothing was changed.'),
      'calendarsPaused': ('Pripojené kalendáre sú pozastavené. Najprv ich znova pripojte.', 'Connected calendars are paused. Reconnect them first.'),
      'invalidDate': ('Vyberte platné dátumy.', 'Choose valid dates.'),
      'endBeforeStart': ('Koncový dátum je pred začiatočným.', 'The end date is before the start date.'),
      'inPast': ('Minulé dátumy sa nedajú meniť.', 'Past dates cannot be changed.'),
      'tooLong': ('Jeden termín môže pokrývať najviac 400 dní.', 'One range can cover at most 400 days.'),
      'tooFarAhead': ('Dátumy môžu byť najviac tri roky dopredu.', 'Dates can be at most three years ahead.'),
      'tooManyFeeds': ('Ponuka môže mať najviac 10 odkazov na kalendár.', 'A listing can have at most 10 calendar links.'),
      'duplicateFeed': ('Tento odkaz na kalendár je už pripojený.', 'This calendar link is already connected.'),
      'feedNotFound': ('Tento odkaz už neexistuje. Obnovte stránku pre aktuálny zoznam.', 'This calendar link no longer exists. Refresh to see the current list.'),
      'forbidden': ('Táto ponuka patrí inému hostiteľovi.', 'This listing belongs to another host.'),
      'notFound': ('Táto ponuka už neexistuje.', 'This listing no longer exists.'),
      'unitNotFound': ('Táto jednotka už neexistuje. Obnovte stránku pre aktuálne jednotky.', 'That unit no longer exists. Refresh to see the current units.'),
    };

String _pickCode(Strings t, String code) {
  final e = _errors(t)[code];
  return e == null ? '' : t.pick(e.$1, e.$2);
}

String feedErrorText(String? code, Strings t) {
  if (code == null || code.isEmpty) return '';
  final known = _pickCode(t, code);
  if (known.isNotEmpty) return known;
  final http = RegExp(r'^http_(\d{3})$').firstMatch(code);
  if (http != null) return t.pick('Druhý kalendár odpovedal chybou ${http.group(1)}.', 'The other calendar answered with error ${http.group(1)}.');
  return t.pick('Posledný pokus zlyhal.', 'The last attempt failed.');
}

/// Localized text for an API error; generic retry message as a fallback.
String calendarErrorText(Object? e, Strings t) {
  if (e is ApiException) {
    final known = e.code == null ? '' : _pickCode(t, e.code!);
    if (known.isNotEmpty) return known;
    if (e.status == 401) return t.pick('Platnosť relácie vypršala. Prihláste sa znova.', 'Your session has expired. Please log in again.');
  }
  return t.pick('Niečo sa pokazilo. Skúste to znova.', 'Something went wrong. Please try again.');
}

String _stamp(dynamic v, Strings t) {
  final d = asDate(v);
  if (d == null) return '';
  return DateFormat('d MMM, HH:mm', 'en_GB').format(d.toLocal());
}

String feedStatusText(Json f, Strings t) {
  final status = asString(f['status']);
  if (status == 'ok') {
    final count = asInt(f['importedCount']);
    final noun = t.isEn ? (count == 1 ? 'blocked range' : 'blocked ranges') : (count == 1 ? 'blokovaný termín' : (count >= 2 && count <= 4 ? 'blokované termíny' : 'blokovaných termínov'));
    return t.pick('Aktualizované ${_stamp(f['lastFetchedAt'], t)} · importované $count $noun', 'Updated ${_stamp(f['lastFetchedAt'], t)} · $count $noun imported');
  }
  if (status == 'failed') {
    final fetched = asDate(f['lastFetchedAt']) != null ? t.pick(' · zobrazené termíny z ${_stamp(f['lastFetchedAt'], t)}', ' · showing dates from ${_stamp(f['lastFetchedAt'], t)}') : '';
    return '${t.pick('Zlyhalo', 'Failed')} ${_stamp(f['lastAttemptAt'], t)}$fetched';
  }
  return t.pick('Pripájam…', 'Connecting…');
}

String _withProtocol(String v) {
  final s = v.trim();
  if (s.isEmpty) return '';
  return RegExp(r'^https?://', caseSensitive: false).hasMatch(s) ? s : 'https://$s';
}

/// Same first-line check the server runs (feedFormProblem in FeedsSection.js).
String? feedFormProblem(String label, String url, Strings t) {
  final u = url.trim();
  if (u.isEmpty) return t.pick('Vložte odkaz na kalendár.', 'Paste the calendar link.');
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) return t.pick('Odkaz musí začínať http:// alebo https://.', 'The link must start with http:// or https://.');
  final parsed = Uri.tryParse(u);
  if (parsed == null || parsed.host.isEmpty) return t.pick('Odkaz nie je platná webová adresa.', 'The link is not a valid web address.');
  if (label.trim().length > 80) return t.pick('Názov môže mať najviac 80 znakov.', 'The name can have at most 80 characters.');
  return null;
}

// ───────────────────────────── shared bits ─────────────────────────────
BoxDecoration _card() => BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]);

Widget _pill(IconData icon, String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Text(text, style: AppText.inter(size: 12, weight: FontWeight.w700, color: fg)),
      ]),
    );

Widget _outlined(String label, VoidCallback? onTap, {IconData? icon, Color color = _forest, Color border = AppColors.neutral300}) => OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon ?? Icons.circle, size: icon == null ? 0 : 15),
      label: Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700)),
      style: OutlinedButton.styleFrom(foregroundColor: color, side: BorderSide(color: border), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );

Widget _solid(String label, VoidCallback? onTap, {Color bg = _forest, bool busy = false}) => FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(backgroundColor: bg, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy) ...[const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)), const SizedBox(width: 8)],
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700))),
      ]),
    );

Widget _err(String msg) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFDC2626)))),
      ]),
    );

/// "All units" / A1 / A2 … dropdown; null value = every unit.
class _UnitSelect extends StatelessWidget {
  const _UnitSelect({required this.t, required this.units, required this.value, required this.onChanged, required this.label});
  final Strings t;
  final List<Json> units;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final current = units.any((u) => asString(u['id']) == value) ? value : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.inter(size: 12, weight: FontWeight.w700, color: _forest)),
      const SizedBox(height: 6),
      Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: current,
            isExpanded: true,
            style: AppText.inter(size: 15, color: AppColors.neutral900),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(t.pick('Všetky jednotky', 'All units'))),
              for (final u in units) DropdownMenuItem<String?>(value: asString(u['id']), child: Text(asString(u['name']))),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    ]);
  }
}

// ───────────────────────────── feed form ─────────────────────────────
class _FeedForm extends StatefulWidget {
  const _FeedForm({required this.t, required this.units, required this.busy, required this.submitLabel, required this.onCancel, required this.onSubmit, this.initial});
  final Strings t;
  final List<Json> units;
  final bool busy;
  final String submitLabel;
  final VoidCallback onCancel;
  final Json? initial;
  final Future<String?> Function(String label, String url, String? unitId) onSubmit; // returns error text

  @override
  State<_FeedForm> createState() => _FeedFormState();
}

class _FeedFormState extends State<_FeedForm> {
  late String _label = asString(widget.initial?['label']);
  late String _url = asString(widget.initial?['url']);
  late String? _unitId = asStringOrNull(widget.initial?['unitId']);
  String? _error;
  bool _saving = false;

  Future<void> _submit() async {
    final problem = feedFormProblem(_label, _url, widget.t);
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _error = null;
      _saving = true;
    });
    final err = await widget.onSubmit(_label.trim(), _url.trim(), _unitId);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final busy = widget.busy || _saving;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EditorSmallField(label: t.pick('Názov (voliteľné)', 'Name (optional)'), labelSize: 12, value: _label, placeholder: t.pick('napr. Airbnb', 'e.g. Airbnb'), maxLength: 80, onChanged: (v) => _label = v),
      const SizedBox(height: 12),
      EditorSmallField(label: t.pick('Odkaz na kalendár (.ics)', 'Calendar link (.ics)'), labelSize: 12, value: _url, placeholder: 'https://…/calendar.ics', keyboard: TextInputType.url, onChanged: (v) => _url = v),
      if (widget.units.isNotEmpty) ...[
        const SizedBox(height: 12),
        _UnitSelect(t: t, units: widget.units, value: _unitId, label: t.pick('Pre ktorú jednotku je tento kalendár?', 'Which unit is this calendar for?'), onChanged: (v) => setState(() => _unitId = v)),
      ],
      if (_error != null) _err(_error!),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _outlined(t.pick('Zrušiť', 'Cancel'), busy ? null : widget.onCancel)),
        const SizedBox(width: 8),
        Expanded(child: _solid(widget.submitLabel, busy ? null : _submit, busy: busy)),
      ]),
    ]);
  }
}

// ───────────────────────────── one feed ─────────────────────────────
class _FeedCard extends StatefulWidget {
  const _FeedCard({super.key, required this.t, required this.feed, required this.units, required this.paused, required this.busy, required this.onUpdate, required this.onRemove});
  final Strings t;
  final Json feed;
  final List<Json> units;
  final bool paused;
  final String? busy; // 'save' | 'remove'
  final Future<String?> Function(String label, String url, String? unitId) onUpdate;
  final Future<String?> Function() onRemove;

  @override
  State<_FeedCard> createState() => _FeedCardState();
}

class _FeedCardState extends State<_FeedCard> {
  String _mode = 'view'; // view | edit | confirmRemove
  String? _error;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final f = widget.feed;
    final status = asString(f['status']);
    final busy = widget.busy != null;
    final name = asString(f['label']).trim().isEmpty ? t.pick('Pripojený kalendár', 'Connected calendar') : asString(f['label']).trim();
    final pill = widget.paused
        ? _pill(Icons.pause_circle_outline, t.pick('Pozastavené', 'Paused'), const Color(0xFFFFFBEB), const Color(0xFF92400E))
        : (busy && widget.busy == 'save') || status == 'never' || status.isEmpty
            ? _pill(Icons.schedule, t.pick('Pripájam', 'Connecting'), const Color(0xFFFFFBEB), const Color(0xFF92400E))
            : status == 'ok'
                ? _pill(Icons.check_circle_outline, t.pick('Aktualizované', 'Updated'), const Color(0xFFECFDF5), const Color(0xFF047857))
                : _pill(Icons.error_outline, t.pick('Zlyhalo', 'Failed'), const Color(0xFFFEF2F2), const Color(0xFFB91C1C));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(name, style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
          pill,
        ]),
        const SizedBox(height: 4),
        Text(asString(f['url']), style: AppText.inter(size: 12, color: AppColors.neutral500)),
        if (widget.units.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${t.pick('Blokuje: ', 'Blocks: ')}${asString(f['unitName']).isEmpty ? t.pick('Všetky jednotky', 'All units') : asString(f['unitName'])}', style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral600)),
          ),
        const SizedBox(height: 6),
        Text(
          widget.paused ? t.pick('Kým je dostupnosť len manuálna, neimportuje sa.', 'Not imported while availability is manual only.') : feedStatusText(f, t),
          style: AppText.inter(size: 13, color: AppColors.neutral700),
        ),
        if (!widget.paused && status == 'failed' && asString(f['lastError']).isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 2), child: Text(feedErrorText(asString(f['lastError']), t), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFDC2626)))),
        if (_mode == 'edit') ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.only(top: 16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
            child: _FeedForm(
              t: t,
              units: widget.units,
              initial: f,
              busy: busy,
              submitLabel: t.pick('Uložiť', 'Save'),
              onCancel: () => setState(() => _mode = 'view'),
              onSubmit: (label, url, unitId) async {
                final err = await widget.onUpdate(label, url, unitId);
                if (err == null && mounted) setState(() => _mode = 'view');
                return err;
              },
            ),
          ),
        ],
        if (_mode == 'confirmRemove') ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.pick('Odstrániť tento odkaz? Termíny z neho importované sa opäť uvoľnia.', 'Remove this calendar link? Dates imported from it will open up again.'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFB91C1C))),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _outlined(t.pick('Ponechať', 'Keep'), busy ? null : () => setState(() => _mode = 'view'))),
                const SizedBox(width: 8),
                Expanded(
                  child: _solid(t.pick('Odstrániť', 'Remove'), busy
                      ? null
                      : () async {
                          setState(() => _error = null);
                          final err = await widget.onRemove();
                          if (mounted) setState(() => err == null ? _mode = 'view' : _error = err);
                        }, bg: const Color(0xFFDC2626), busy: widget.busy == 'remove'),
                ),
              ]),
            ]),
          ),
        ],
        if (_error != null && _mode != 'edit') _err(_error!),
        if (_mode == 'view') ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _outlined(t.pick('Upraviť', 'Edit'), busy ? null : () => setState(() => _mode = 'edit'), icon: Icons.edit_outlined),
            _outlined(t.pick('Odstrániť', 'Remove'), busy ? null : () => setState(() => _mode = 'confirmRemove'), icon: Icons.delete_outline, color: const Color(0xFFB91C1C), border: const Color(0xFFFECACA)),
          ]),
        ],
      ]),
    );
  }
}

// ───────────────────────────── export link ─────────────────────────────
class _ExportLinkCard extends StatefulWidget {
  const _ExportLinkCard({required this.t, required this.listingId, required this.units});
  final Strings t;
  final String listingId;
  final List<Json> units;
  @override
  State<_ExportLinkCard> createState() => _ExportLinkCardState();
}

class _ExportLinkCardState extends State<_ExportLinkCard> {
  String _scope = 'own';
  String? _unitId;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final q = <String, String>{
      if (_unitId != null && widget.units.any((u) => asString(u['id']) == _unitId)) 'unit': _unitId!,
      if (_scope == 'all') 'include': 'all',
    };
    final base = '${AppConfig.apiBaseUrl}/accommodation/${Uri.encodeComponent(widget.listingId)}/calendar.ics';
    final url = q.isEmpty ? base : '$base?${Uri(queryParameters: q).query}';
    final hint = _scope == 'own'
        ? t.pick('Rezervácie cez UK Stay Hub a termíny, ktoré blokujete tu. Termíny importované z prepojených kalendárov sa vynechajú, aby iné platformy nedostali svoje rezervácie späť ako duplicity.',
            "Bookings made on UK Stay Hub and dates you block here. Dates imported from connected calendars are left out, so other platforms don't get each other's bookings back as duplicates.")
        : t.pick('Obsahuje aj termíny importované z prepojených kalendárov. Použite len pre platformu, ktorú tu nemáte prepojenú, inak sa zobrazia duplicitné rezervácie.',
            'Also includes dates imported from your connected calendars. Use this only for a platform you have not connected here, or it will show duplicate bookings.');

    Widget seg(String value, String label) {
      final on = _scope == value;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() {
          _scope = value;
          _copied = false;
        }),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(12), boxShadow: on ? const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))] : null),
          child: Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700, color: on ? _forest : AppColors.neutral600)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.pick('Exportovať tento kalendár', 'Export this calendar'), style: AppText.inter(size: 17, weight: FontWeight.w700, color: _forest)),
        const SizedBox(height: 4),
        Text(t.pick('Vložte tento odkaz do Airbnb, Booking.com alebo inej platformy, aby videli termíny blokované tu.', 'Paste this link into Airbnb, Booking.com or any other platform so they see the dates blocked here.'),
            style: AppText.inter(size: 13, color: AppColors.neutral600, height: 1.5)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: AppColors.neutral100, borderRadius: BorderRadius.circular(16)),
            child: Wrap(spacing: 4, children: [seg('own', t.pick('Iba termíny z UK Stay Hub', 'UK Stay Hub dates only')), seg('all', t.pick('Všetky termíny', 'All dates'))]),
          ),
        ),
        const SizedBox(height: 8),
        Text(hint, style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.5)),
        if (widget.units.isNotEmpty) ...[
          const SizedBox(height: 12),
          _UnitSelect(t: t, units: widget.units, value: _unitId, label: t.pick('Odkaz pre', 'Link for'), onChanged: (v) => setState(() {
                _unitId = v;
                _copied = false;
              })),
          const SizedBox(height: 6),
          Text(
            _unitId != null
                ? t.pick('Len rezervácie tejto jednotky a termíny, ktoré zatvárajú všetky jednotky.', "Only this unit's bookings, plus dates that close every unit.")
                : t.pick('Rezervácie všetkých jednotiek. Pre platformu, kde ponúkate len jednu jednotku, použite jej vlastný odkaz.', "Every unit's bookings. Use a unit's own link for a platform listing just that unit."),
            style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.5),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
          child: SelectableText(url, style: AppText.inter(size: 13, color: AppColors.neutral700)),
        ),
        const SizedBox(height: 8),
        _solid(_copied ? t.pick('Skopírované', 'Copied') : t.pick('Kopírovať', 'Copy'), () async {
          await Clipboard.setData(ClipboardData(text: url));
          if (!mounted) return;
          setState(() => _copied = true);
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _copied = false);
          });
        }),
      ]),
    );
  }
}

// ───────────────────────────── the section ─────────────────────────────
/// Connected calendars + export link for one property (FeedsSection.js).
class CalendarFeedsPanel extends StatefulWidget {
  const CalendarFeedsPanel({super.key, required this.t, required this.listingId, required this.snapshot, required this.units, required this.onSnapshot});
  final Strings t;
  final String listingId;
  final Json snapshot;
  final List<Json> units;
  final ValueChanged<Json> onSnapshot;

  @override
  State<CalendarFeedsPanel> createState() => _CalendarFeedsPanelState();
}

class _CalendarFeedsPanelState extends State<CalendarFeedsPanel> {
  bool _adding = false;
  bool _addingBusy = false;
  bool _confirmPause = false;
  bool _confirmRemoveAll = false;
  bool _removeAllImported = true;
  bool _removingAll = false;
  String? _modeBusy;
  String? _modeError;
  String? _removeAllError;
  final Map<String, String> _actions = {};

  Strings get t => widget.t;
  String get _id => widget.listingId;
  List<Json> get _feeds => asMapList(widget.snapshot['feeds']);

  bool _same(String a, String b) {
    final ua = Uri.tryParse(_withProtocol(a)), ub = Uri.tryParse(_withProtocol(b));
    return ua != null && ub != null ? ua.toString() == ub.toString() : a.trim() == b.trim();
  }

  Json? _byUrl(Json snap, String url) => asMapList(snap['feeds']).where((f) => _same(asString(f['url']), url)).firstOrNull;

  /// Connect, then pull right away so the card never sits on "Connecting".
  Future<String?> _add(String label, String url, String? unitId) async {
    setState(() => _addingBusy = true);
    try {
      var snap = widget.snapshot;
      var feed = _byUrl(snap, url);
      if (feed == null) {
        try {
          snap = await hostRepo.addFeed(_id, url, label, unitId: unitId);
          feed = _byUrl(snap, url);
        } on ApiException catch (e) {
          if (e.status == 409 || e.code == 'feedDuplicate') {
            snap = await hostRepo.calendar(_id);
            feed = _byUrl(snap, url);
          } else {
            rethrow;
          }
        }
      }
      widget.onSnapshot(snap);
      if (feed == null) return _pickCode(t, 'feedNotFound');
      final after = await hostRepo.refreshFeed(_id, asString(feed['id']));
      widget.onSnapshot(after);
      final updated = asMapList(after['feeds']).where((f) => asString(f['id']) == asString(feed!['id'])).firstOrNull;
      if (asString(updated?['status']) == 'failed') return feedErrorText(asStringOrNull(updated?['lastError']) ?? 'unreachable', t);
      if (mounted) setState(() => _adding = false);
      return null;
    } catch (e) {
      return calendarErrorText(e, t);
    } finally {
      if (mounted) setState(() => _addingBusy = false);
    }
  }

  Future<String?> _update(Json before, String label, String url, String? unitId) async {
    final feedId = asString(before['id']);
    setState(() => _actions[feedId] = 'save');
    try {
      final nextUrl = _withProtocol(url);
      final urlChanged = nextUrl != asString(before['url']);
      var next = await hostRepo.updateFeed(_id, feedId, {'label': label, 'url': nextUrl, if (widget.units.isNotEmpty) 'unitId': unitId});
      // A changed URL clears what the feed imported, so pull it again straight away.
      if (urlChanged) next = await hostRepo.refreshFeed(_id, feedId);
      widget.onSnapshot(next);
      final updated = asMapList(next['feeds']).where((f) => asString(f['id']) == feedId).firstOrNull;
      if (urlChanged && asString(updated?['status']) == 'failed') return feedErrorText(asStringOrNull(updated?['lastError']) ?? 'unreachable', t);
      return null;
    } catch (e) {
      return calendarErrorText(e, t);
    } finally {
      if (mounted) setState(() => _actions.remove(feedId));
    }
  }

  Future<String?> _remove(String feedId) async {
    setState(() => _actions[feedId] = 'remove');
    try {
      widget.onSnapshot(await hostRepo.removeFeed(_id, feedId));
      return null;
    } catch (e) {
      return calendarErrorText(e, t);
    } finally {
      if (mounted) setState(() => _actions.remove(feedId));
    }
  }

  Future<void> _switchMode(String choice) async {
    setState(() {
      _modeBusy = choice;
      _modeError = null;
    });
    try {
      widget.onSnapshot(await hostRepo.setCalendarMode(_id, choice));
      if (mounted) setState(() => _confirmPause = false);
    } catch (e) {
      if (mounted) setState(() => _modeError = calendarErrorText(e, t));
    } finally {
      if (mounted) setState(() => _modeBusy = null);
    }
  }

  Future<void> _removeAll() async {
    setState(() {
      _removingAll = true;
      _removeAllError = null;
    });
    try {
      widget.onSnapshot(await hostRepo.removeAllFeeds(_id, _removeAllImported));
      if (mounted) setState(() => _confirmRemoveAll = false);
    } catch (e) {
      if (mounted) setState(() => _removeAllError = calendarErrorText(e, t));
    } finally {
      if (mounted) setState(() => _removingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feeds = _feeds;
    final paused = feeds.isNotEmpty && asString(widget.snapshot['calendarChoice']) != 'connect';
    final modeBusy = _modeBusy != null;
    final imported = feeds.fold<int>(0, (s, f) => s + asInt(f['importedCount']));

    final pauseText = imported > 0
        ? t.pick(
            'Prepnúť len na manuálne? ${feeds.length == 1 ? 'Váš odkaz zostane uložený, ale pozastavený' : 'Vaše odkazy (${feeds.length}) zostanú uložené, ale pozastavené'} a $imported importovaných blokovaných termínov sa opäť uvoľní.',
            'Switch to manual only? Your ${feeds.length} ${feeds.length == 1 ? 'link stays' : 'links stay'} saved but paused, and $imported imported blocked ${imported == 1 ? 'range opens' : 'ranges open'} up again.')
        : t.pick('Prepnúť len na manuálne? Vaše odkazy zostanú uložené, ale pozastavené; kým ich znova nepripojíte, nič sa neimportuje.',
            'Switch to manual only? Your links stay saved but paused; nothing is imported until you reconnect.');

    Widget divider(Widget child) => Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.only(top: 16),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
          child: child,
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: _card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.link, size: 18, color: _gold),
                  const SizedBox(width: 8),
                  Flexible(child: Text(t.pick('Pripojené kalendáre', 'Connected calendars'), style: AppText.inter(size: 17, weight: FontWeight.w700, color: _forest))),
                ]),
                const SizedBox(height: 4),
                Text(t.pick('UK Stay Hub načíta kalendár hneď po pripojení a potom ho automaticky aktualizuje približne každé tri hodiny.', 'UK Stay Hub imports a calendar as soon as you connect it and updates it automatically about every three hours.'),
                    style: AppText.inter(size: 13, color: AppColors.neutral600, height: 1.5)),
              ]),
            ),
          ]),
          if (!_adding) ...[const SizedBox(height: 12), Align(alignment: Alignment.centerLeft, child: _outlined(t.pick('Pridať odkaz', 'Add link'), () => setState(() => _adding = true), icon: Icons.add, border: _forest))],
          if (_adding) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFFF8F4EA), borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(t.pick('Nový odkaz na kalendár', 'New calendar link'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                  IconButton(onPressed: _addingBusy ? null : () => setState(() => _adding = false), icon: const Icon(Icons.close, size: 18), tooltip: t.pick('Zavrieť', 'Close')),
                ]),
                _FeedForm(t: t, units: widget.units, busy: _addingBusy, submitLabel: t.pick('Pripojiť kalendár', 'Connect calendar'), onCancel: () => setState(() => _adding = false), onSubmit: _add),
              ]),
            ),
          ],
          if (paused) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDE68A))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.pause_circle_outline, size: 16, color: Color(0xFF78350F))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(t.pick('Dostupnosť je nastavená len manuálne, preto sú tieto odkazy pozastavené: neimportujú sa z nich žiadne termíny a platia len termíny, ktoré blokujete tu.',
                        'Availability is set to manual only, so these links are paused: no dates are imported from them and only the dates you block here count.'),
                        style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF78350F))),
                  ),
                ]),
                const SizedBox(height: 12),
                _solid(t.pick('Znova pripojiť kalendáre', 'Reconnect calendars'), modeBusy ? null : () => _switchMode('connect'), busy: _modeBusy == 'connect'),
              ]),
            ),
          ],
          if (_modeError != null) _err(_modeError!),
          if (feeds.isEmpty && !_adding) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral300)),
              child: Text(t.pick('Zatiaľ žiadne odkazy na kalendár. Jediné blokované termíny v tomto kalendári sú tie, ktoré ste nastavili tu.', 'No calendar links yet. The only blocked dates in this calendar are the ones you set here.'),
                  textAlign: TextAlign.center, style: AppText.inter(size: 13, color: AppColors.neutral500)),
            ),
          ],
          for (final f in feeds) ...[
            const SizedBox(height: 12),
            _FeedCard(
              key: ValueKey(asString(f['id'])),
              t: t,
              feed: f,
              units: widget.units,
              paused: paused,
              busy: _actions[asString(f['id'])],
              onUpdate: (l, u, unit) => _update(f, l, u, unit),
              onRemove: () => _remove(asString(f['id'])),
            ),
          ],
          if (feeds.isNotEmpty && !paused)
            divider(_confirmPause
                ? Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(pauseText, style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF78350F))),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _outlined(t.pick('Ponechať pripojené', 'Keep connected'), modeBusy ? null : () => setState(() => _confirmPause = false))),
                        const SizedBox(width: 8),
                        Expanded(child: _solid(t.pick('Prepnúť na manuálne', 'Switch to manual'), modeBusy ? null : () => _switchMode('none'), bg: const Color(0xFFB45309), busy: _modeBusy == 'none')),
                      ]),
                    ]),
                  )
                : Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: modeBusy ? null : () => setState(() => _confirmPause = true), icon: const Icon(Icons.pause_circle_outline, size: 15), label: Text(t.pick('Prepnúť len na manuálne (pozastaviť odkazy)', 'Switch to manual only (pause links)'), style: AppText.inter(size: 13, weight: FontWeight.w700)), style: TextButton.styleFrom(foregroundColor: AppColors.neutral700, minimumSize: const Size(0, 44))))),
          if (feeds.isNotEmpty)
            divider(_confirmRemoveAll
                ? Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(
                          t.pick('Odpojiť všetkých ${feeds.length} ${feeds.length == 1 ? 'odkaz' : 'odkazov'} na kalendár? Túto akciu nemožno vrátiť späť.',
                              'Disconnect all ${feeds.length} calendar ${feeds.length == 1 ? 'link' : 'links'}? This cannot be undone.'),
                          style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF991B1B))),
                      InkWell(
                        onTap: _removingAll ? null : () => setState(() => _removeAllImported = !_removeAllImported),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(_removeAllImported ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: const Color(0xFFDC2626)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(t.pick('Uvoľniť aj termíny importované z týchto kalendárov', 'Also open up the dates these calendars imported'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF7F1D1D)))),
                          ]),
                        ),
                      ),
                      if (_removeAllError != null) _err(_removeAllError!),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _outlined(t.pick('Ponechať', 'Keep them'), _removingAll ? null : () => setState(() => _confirmRemoveAll = false))),
                        const SizedBox(width: 8),
                        Expanded(child: _solid(t.pick('Odpojiť všetky', 'Disconnect all'), _removingAll ? null : _removeAll, bg: const Color(0xFFDC2626), busy: _removingAll)),
                      ]),
                    ]),
                  )
                : Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _removingAll ? null : () => setState(() => _confirmRemoveAll = true), icon: const Icon(Icons.link_off, size: 15), label: Text(t.pick('Odpojiť všetky kalendáre', 'Disconnect all calendars'), style: AppText.inter(size: 13, weight: FontWeight.w700)), style: TextButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), minimumSize: const Size(0, 44))))),
        ]),
      ),
      const SizedBox(height: 16),
      _ExportLinkCard(t: t, listingId: _id, units: widget.units),
    ]);
  }
}
