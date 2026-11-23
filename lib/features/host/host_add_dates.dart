import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import 'editor_rows.dart';
import 'host_calendar_feeds.dart' show calendarErrorText;

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

String _listingName(Json l, Strings t) {
  for (final n in [asString(pick(l, 'data.name')).trim(), asString(l['name']).trim()]) {
    if (n.isNotEmpty) return n;
  }
  return t.pick('Ponuka bez názvu', 'Unnamed listing');
}

/// host/reservations/AddOwnDatesDialog.js — blocks a typed date range on one of
/// the host's properties (a stay arranged outside UK Stay Hub, maintenance, …).
/// Resolves to the (listingId, unitId) that was blocked, or null if cancelled.
Future<({String listingId, String? unitId})?> showAddOwnDatesDialog(
  BuildContext context, {
  required Strings t,
  required List<Json> listings,
  String? defaultListingId,
  String? defaultUnitId,
}) {
  final body = _AddOwnDates(t: t, listings: listings, defaultListingId: defaultListingId, defaultUnitId: defaultUnitId);
  if (MediaQuery.sizeOf(context).width >= 640) {
    return showDialog(context: context, barrierDismissible: false, builder: (_) => Dialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 448), child: SingleChildScrollView(child: body))));
  }
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom), child: SingleChildScrollView(child: body)),
  );
}

class _AddOwnDates extends StatefulWidget {
  const _AddOwnDates({required this.t, required this.listings, this.defaultListingId, this.defaultUnitId});
  final Strings t;
  final List<Json> listings;
  final String? defaultListingId;
  final String? defaultUnitId;
  @override
  State<_AddOwnDates> createState() => _AddOwnDatesState();
}

class _AddOwnDatesState extends State<_AddOwnDates> {
  late String _listingId = widget.defaultListingId ?? asString(widget.listings.firstOrNull?['id']);
  late String _unitId = widget.defaultUnitId ?? ''; // '' = all units (the whole property)
  String _start = '';
  String _end = '';
  String _note = '';
  bool _pending = false;
  String? _error;

  Strings get t => widget.t;

  List<Json> get _units => asMapList(widget.listings.where((l) => asString(l['id']) == _listingId).firstOrNull?['units']);
  // A unit chosen for another property never travels with a property switch.
  String get _chosenUnit => _units.any((u) => asString(u['id']) == _unitId) ? _unitId : '';
  bool get _canSubmit => _listingId.isNotEmpty && _start.isNotEmpty && _end.isNotEmpty && _start.compareTo(_end) <= 0;

  Future<void> _submit() async {
    if (!_canSubmit || _pending) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    final unit = _chosenUnit.isEmpty ? null : _chosenUnit;
    try {
      await hostRepo.block(_listingId, _start, _end, note: _note.trim(), unitId: unit);
      if (mounted) Navigator.pop(context, (listingId: _listingId, unitId: unit));
    } catch (e) {
      if (mounted) setState(() => _error = calendarErrorText(e, t));
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Widget _select<T>({required String label, required T value, required List<DropdownMenuItem<T>> items, required ValueChanged<T?>? onChanged, String? hint}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest)),
        const SizedBox(height: 6),
        Container(
          height: 48,
          padding: const EdgeInsets.only(left: 16, right: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.neutral500),
              style: AppText.inter(size: 15, weight: FontWeight.w600, color: _forest),
              borderRadius: BorderRadius.circular(12),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(hint, style: AppText.inter(size: 12, color: AppColors.neutral500))),
      ]);

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final units = _units;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: _gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.edit_calendar_outlined, size: 24, color: _forest)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.pick('Pridať vlastný termín', 'Add your own dates'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
              const SizedBox(height: 4),
              Text(t.pick('Zablokujte pobyt dohodnutý mimo UK Stay Hub, aby si hostia nemohli žiadať tie isté noci.', "Block a stay you arranged outside UK Stay Hub so guests can't request the same nights."),
                  style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.7)),
            ]),
          ),
        ]),
        const SizedBox(height: 20),
        _select<String>(
          label: t.pick('Ubytovanie', 'Property'),
          value: widget.listings.any((l) => asString(l['id']) == _listingId) ? _listingId : '',
          items: [
            if (!widget.listings.any((l) => asString(l['id']) == _listingId)) const DropdownMenuItem(value: '', child: Text('')),
            for (final l in widget.listings) DropdownMenuItem(value: asString(l['id']), child: Text(_listingName(l, t), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: _pending ? null : (v) => setState(() => _listingId = v ?? _listingId),
        ),
        // Only a property with more than one unit needs a picker.
        if (units.length > 1) ...[
          const SizedBox(height: 12),
          _select<String>(
            label: t.pick('Jednotka', 'Unit'),
            value: _chosenUnit,
            items: [
              DropdownMenuItem(value: '', child: Text(t.pick('Všetky jednotky', 'All units'))),
              for (final u in units) DropdownMenuItem(value: asString(u['id']), child: Text(asString(u['name']))),
            ],
            onChanged: _pending ? null : (v) => setState(() => _unitId = v ?? ''),
            hint: _chosenUnit.isNotEmpty
                ? t.pick('Zatvorí sa len táto jednotka; ostatné si hostia môžu rezervovať.', 'Only this unit is closed; guests can still book the others.')
                : t.pick('V tomto termíne sa zatvoria všetky jednotky.', 'Every unit is closed for these dates.'),
          ),
        ],
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: EditorDateField(label: t.pick('Začiatok', 'Start'), value: _start, min: today, onChanged: (v) => setState(() => _start = v))),
          const SizedBox(width: 12),
          Expanded(child: EditorDateField(label: t.pick('Koniec', 'End'), value: _end, min: _start.isEmpty ? today : _start, onChanged: (v) => setState(() => _end = v))),
        ]),
        const SizedBox(height: 12),
        EditorSmallField(label: t.pick('Meno hosťa alebo poznámka (nepovinné)', 'Guest name or note (optional)'), labelSize: 13, value: _note, maxLength: 120, placeholder: t.pick('napr. Jana Nováková', 'e.g. Jana Nováková'), onChanged: (v) => _note = v),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFDC2626)))),
            ]),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _canSubmit && !_pending ? _submit : null,
          style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_pending) ...[const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)), const SizedBox(width: 8)],
            Text(_pending ? t.pick('Blokujem…', 'Blocking…') : t.pick('Blokovať termín', 'Block these dates'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _pending ? null : () => Navigator.pop(context),
          style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral200, width: 2), minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: Text(t.pick('Zrušiť', 'Cancel'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
        ),
      ]),
    );
  }
}
