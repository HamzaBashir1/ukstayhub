import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'editor_fields.dart';
import 'editor_rows.dart';
import 'editor_steps2.dart';

/// Units and Policies steps (host/listings/editor/EditorSteps.js).

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

bool _nonEmpty(dynamic v) => v is String && v.trim().isNotEmpty;
bool _positive(dynamic v) => v is num && v.isFinite && v > 0;
bool _filled(dynamic v) => v != null && v != '';

/// Units validation (hostEditorValidation.js `units`): errors keyed `units.<n>.<field>`.
void validateUnits(Json data, Strings t, Map<String, String> errors) {
  final units = asList(data['units']);
  for (var i = 0; i < units.length; i++) {
    final unit = units[i] is Map ? asMap(units[i]) : <String, dynamic>{};
    final base = 'units.$i';
    if (!_nonEmpty(unit['name'])) errors['$base.name'] = t.pick('Pomenujte túto jednotku, napr. A1.', 'Give this unit a name, e.g. A1.');
    if (_filled(unit['nightlyPrice']) && !_positive(unit['nightlyPrice'])) {
      errors['$base.nightlyPrice'] = t.pick('Zadajte cenu vyššiu ako 0 £, alebo nechajte prázdne pre cenu ubytovania.', "Enter a price above £0, or leave it empty to use the listing's price.");
    }
    if (_filled(unit['guests']) && !_positive(unit['guests'])) errors['$base.guests'] = t.pick('Zadajte aspoň 1, alebo nechajte prázdne.', 'Enter at least 1, or leave it empty.');
    validateOffers(unit['flexiblePrices'], t, errors, '$base.flexiblePrices');
  }
}

/// A new unit id in MongoDB ObjectId form (8 hex of seconds + 16 random), so a unit keeps its id across saves.
String newUnitId() {
  final seconds = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toRadixString(16).padLeft(8, '0');
  final r = math.Random.secure();
  return seconds + List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

bool _matches(Json option, String item) => item == asString(option['en']) || item == asString(option['sk']);

Widget _pill(String label, bool checked, VoidCallback onTap, {double size = 14, EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10), double radius = 12}) => InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: checked ? _gold.withValues(alpha: 0.05) : Colors.white,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: checked ? _gold : AppColors.neutral200, width: 2),
        ),
        child: Text(label, style: AppText.inter(size: size, weight: FontWeight.w700, color: checked ? _forest : AppColors.neutral600)),
      ),
    );

// ───────────────────────────── Units ─────────────────────────────
Widget buildUnitsStep({required Json data, required Map<String, String> errors, required Strings t, required Json opts, required void Function(String, dynamic) set}) {
  return _UnitsStep(data: data, errors: errors, t: t, opts: opts, set: set);
}

class _UnitsStep extends StatelessWidget {
  const _UnitsStep({required this.data, required this.errors, required this.t, required this.opts, required this.set});
  final Json data;
  final Map<String, String> errors;
  final Strings t;
  final Json opts;
  final void Function(String, dynamic) set;

  @override
  Widget build(BuildContext context) {
    final units = asMapList(data['units']);
    void write(List<Json> next) => set('units', next);
    void updateUnit(int i, Json patch) => write([for (var k = 0; k < units.length; k++) k == i ? {...units[k], ...patch} : units[k]]);
    final sm = MediaQuery.sizeOf(context).width >= 640;

    String listingValue(dynamic v, [String suffix = '']) => v != null && v != '' ? t.pick('$v$suffix (ubytovanie)', '$v$suffix (listing)') : t.pick('Ako ubytovanie', 'Same as listing');

    Widget grid(List<Widget> items, int cols, {double gap = 12}) {
      final rows = <Widget>[];
      for (var i = 0; i < items.length; i += cols) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var j = 0; j < cols; j++) ...[
              if (j > 0) SizedBox(width: gap),
              Expanded(child: i + j < items.length ? items[i + j] : const SizedBox()),
            ],
          ]),
        ));
      }
      return Column(children: rows);
    }

    Widget unitCard(int index) {
      final unit = units[index];
      final base = 'units.$index';
      final ownPrice = unit['nightlyPrice'] is num && (unit['nightlyPrice'] as num) > 0;
      void setUnitField(String name, dynamic value) => updateUnit(index, {name: value});
      final photoCount = asList(unit['photoUrls']).length;
      Widget numField(String key, String label, {String? listingKey, String suffix = '', bool decimals = false, bool noFallback = false}) => EditorSmallField(
            label: label,
            labelSize: 13,
            value: editorNumText(unit[key]),
            placeholder: noFallback ? '–' : listingValue(data[listingKey ?? key], suffix),
            keyboard: TextInputType.numberWithOptions(decimal: decimals),
            error: errors['$base.$key'],
            onChanged: (v) => setUnitField(key, editorParseNumber(v, decimals: decimals)),
          );
      final name = asString(unit['name']).trim();

      return Container(
        padding: EdgeInsets.all(sm ? 20 : 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral100, width: 2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text((name.isEmpty ? t.pick('Jednotka ${index + 1}', 'Unit ${index + 1}') : name).toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1.2))),
            EditorTrashButton(size: 40, onTap: () => write([...units]..removeAt(index)), tooltip: t.pick('Odstrániť jednotku ${index + 1}', 'Remove unit ${index + 1}')),
          ]),
          const SizedBox(height: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            EditorSmallField(
              label: '${t.pick('Názov jednotky', 'Unit name')} *',
              labelSize: 13,
              value: asString(unit['name']),
              placeholder: t.pick('napr. A1', 'e.g. A1'),
              error: errors['$base.name'],
              onChanged: (v) => updateUnit(index, {'name': v}),
            ),
            const SizedBox(height: 16),
            EditorSmallField(
              label: t.pick('Čím sa jednotka líši (voliteľné)', 'What makes this unit different (optional)'),
              labelSize: 13,
              value: asString(unit['description']),
              lines: 2,
              maxLength: 600,
              placeholder: t.pick('napr. Prízemie so súkromnou terasou', 'e.g. Ground floor with a private terrace'),
              onChanged: (v) => updateUnit(index, {'description': v}),
            ),
            const SizedBox(height: 16),
            grid([
              numField('guests', t.pick('Hostia', 'Guests')),
              numField('bedrooms', t.pick('Spálne', 'Bedrooms')),
              numField('beds', t.pick('Postele', 'Beds')),
              numField('bathrooms', t.pick('Kúpeľne', 'Bathrooms')),
            ], sm ? 4 : 2),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.only(top: 16),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(t.pick('DETAILY POSTELÍ A OBÝVACEJ IZBY', 'BED AND LIVING ROOM DETAILS'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3))),
                grid([
                  numField('singlebed', t.pick('Jednolôžkové postele', 'Single beds')),
                  numField('doublebed', t.pick('Manželské postele', 'Double beds')),
                  numField('bunkbed', t.pick('Poschodové postele', 'Bunk beds')),
                  numField('extraBeds', t.pick('Prístelky', 'Extra beds'), listingKey: 'beds'),
                  numField('livingRoom', t.pick('Obývacie izby', 'Living rooms')),
                  numField('kitchens', t.pick('Kuchyne', 'Kitchens'), listingKey: 'kitchens'),
                ], sm ? 3 : 2),
              ]),
            ),
            const SizedBox(height: 16),
            grid([
              numField('nightlyPrice', t.pick('Cena / noc (£)', 'Price / night (£)'), suffix: ' £', decimals: true),
              numField('pricePerPerson', t.pick('Príplatok za osobu (£)', 'Extra per person (£)'), suffix: ' £', decimals: true),
              numField('weekendPricePerNight', t.pick('Víkendová noc (£)', 'Weekend night (£)'), suffix: ' £', decimals: true, noFallback: ownPrice),
              numField('includedGuests', t.pick('Osôb v cene', 'Guests in price')),
              numField('cleaningFee', t.pick('Upratovanie (£)', 'Cleaning fee (£)'), suffix: ' £', decimals: true),
            ], sm ? 3 : 1),
            const SizedBox(height: 16),
            Text(
              ownPrice
                  ? t.pick('Jednotka má vlastnú cenu, preto sa na ňu flexibilné ceny ubytovania nevzťahujú — ak potrebuje sezónne ceny, pridajte jej vlastné nižšie. Zľavy ubytovania platia aj naďalej.',
                      "This unit has its own price, so the listing's flexible prices do not apply to it — add its own below if it needs seasonal prices. The listing's discounts still apply.")
                  : t.pick('Bez vlastnej ceny sa jednotka účtuje rovnako ako ubytovanie, vrátane flexibilných cien a zliav.', 'Without its own price the unit is priced exactly like the listing, flexible prices and discounts included.'),
              style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.7),
            ),
            const SizedBox(height: 16),
            _UnitSection(
              title: t.pick('Vybavenie jednotky (voliteľné)', 'Amenities of this unit (optional)'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(t.pick('Ak nič nezaškrtnete, zobrazí sa vybavenie ubytovania. Keď niečo zaškrtnete, hostia pri tejto jednotke uvidia tento zoznam.', "Tick nothing to show the listing's amenities. Once you tick any, guests see this list for this unit instead."),
                      style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
                ),
                for (final g in asMapList(opts['AMENITY_GROUPS'])) ...[
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(optLabel(g, t.lang).toUpperCase(), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3))),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final o in asMapList(g['options']))
                        Builder(builder: (_) {
                          final sel = asStringList(unit[asString(g['name'])]);
                          final checked = sel.any((i) => _matches(o, i));
                          return _pill(optLabel(o, t.lang), checked, () {
                            final next = checked ? sel.where((i) => !_matches(o, i)).toList() : [...sel, asString(o['en'])];
                            setUnitField(asString(g['name']), next);
                          }, size: 13, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8));
                        }),
                    ]),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 16),
            _UnitSection(
              title: '${t.pick('Fotografie jednotky (voliteľné)', 'Photos of this unit (optional)')}${photoCount > 0 ? ' · $photoCount' : ''}',
              child: _UnitPhotos(photos: [for (final p in asList(unit['photoUrls'])) if (p is String ? p.isNotEmpty : (p is Map && asString(p['url']).isNotEmpty)) p is String ? p : asString((p as Map)['url'])], onChange: (next) => setUnitField('photoUrls', next)),
            ),
            if (ownPrice) ...[
              const SizedBox(height: 16),
              FlexiblePricesEditor(
                field: '$base.flexiblePrices',
                data: {'$base.flexiblePrices': unit['flexiblePrices'], 'guests': unit['guests'] ?? data['guests']},
                errors: errors,
                t: t,
                set: (_, v) => setUnitField('flexiblePrices', v),
                intro: t.pick('Sezónne ceny len pre túto jednotku. Noci v týchto termínoch sa účtujú touto cenou namiesto ceny jednotky vyššie.', "Seasonal prices for this unit only. Nights in these dates are charged this price instead of the unit's price above."),
              ),
            ],
          ]),
        ]),
      );
    }

    return EditorStack(children: [
      EditorIntro(t.pick(
          'Voliteľné. Ak má ubytovanie viac jednotiek, ktoré si hostia rezervujú samostatne — napr. apartmány A1 a A2 — pridajte ich sem. Každá jednotka má vlastný kalendár, takže rezervácia A1 nechá A2 voľnú. Prázdne pole znamená hodnotu ubytovania.',
          "Optional. If this place has several units guests book separately — e.g. apartments A1 and A2 — add them here. Each unit gets its own calendar, so a booking of A1 leaves A2 free. Leave a field empty to use the listing's value.")),
      if (units.isNotEmpty)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFF8F4EA), borderRadius: BorderRadius.circular(16), border: Border.all(color: _gold.withValues(alpha: 0.6))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.calendar_today_outlined, size: 18, color: _forest)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.pick('Hostia pred rezerváciou vyberú jednotku. Termíny zablokované v kalendári a termíny importované z iných platforiem zatvoria všetky jednotky.',
                    'Guests pick a unit before booking. Dates you block in the calendar, and dates imported from other platforms, close every unit.'),
                style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral700, height: 1.55),
              ),
            ),
          ]),
        ),
      for (var i = 0; i < units.length; i++) unitCard(i),
      Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => write([...units, {'id': newUnitId(), 'name': ''}]),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(color: AppColors.neutral50.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300, width: 2)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.add, size: 18, color: _forest),
              const SizedBox(width: 8),
              Text(t.pick('Pridať jednotku', 'Add unit'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// A collapsible section inside a unit card.
class _UnitSection extends StatelessWidget {
  const _UnitSection({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.all(16),
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text(title, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            children: [child],
          ),
        ),
      );
}

/// Photos for one unit: uploaded like the listing's, shown before the shared ones.
class _UnitPhotos extends ConsumerStatefulWidget {
  const _UnitPhotos({required this.photos, required this.onChange});
  final List<String> photos;
  final ValueChanged<List<String>> onChange;
  @override
  ConsumerState<_UnitPhotos> createState() => _UnitPhotosState();
}

class _UnitPhotosState extends ConsumerState<_UnitPhotos> {
  bool _uploading = false;
  String? _error;

  Future<void> _pick() async {
    final t = ref.read(stringsProvider);
    final List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultiImage(imageQuality: 90, maxWidth: 3000);
    } catch (e) {
      setState(() => _error = errorText(e));
      return;
    }
    if (picked.isEmpty) return;
    setState(() => _error = null);
    for (final x in picked) {
      final ext = x.name.split('.').last.toLowerCase();
      if (!const ['jpg', 'jpeg', 'png', 'webp', 'avif'].contains(ext)) {
        setState(() => _error = t.pick('Použite obrázok JPEG, PNG, WebP alebo AVIF.', 'Use a JPEG, PNG, WebP or AVIF image.'));
        return;
      }
      if (await x.length() > 10 * 1024 * 1024) {
        setState(() => _error = t.pick('${x.name} je väčší ako 10 MB.', '${x.name} is larger than 10 MB.'));
        return;
      }
    }
    setState(() => _uploading = true);
    try {
      final uploaded = <String>[];
      for (final x in picked) {
        final url = await hostRepo.uploadListingPhoto(x);
        if (url.isNotEmpty) uploaded.add(url);
      }
      if (uploaded.isNotEmpty) widget.onChange([...widget.photos, ...uploaded]);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final photos = widget.photos;
    final cols = MediaQuery.sizeOf(context).width >= 640 ? 3 : 2;

    Widget tile(int i) => AspectRatio(
          aspectRatio: 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(fit: StackFit.expand, children: [
              Container(color: AppColors.neutral100, child: Image.network(cloudinary(photos[i], width: 600, ratio: 3 / 4), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.link, color: AppColors.neutral400))),
              if (i == 0)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)), child: Text(t.pick('TITULNÁ', 'COVER'), style: AppText.inter(size: 10, weight: FontWeight.w700, color: _forest, letterSpacing: 1))),
                ),
              Positioned(
                right: 8,
                top: 8,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => widget.onChange([...photos]..removeAt(i)),
                  child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFDC2626))),
                ),
              ),
              if (i != 0)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      final l = [...photos];
                      final picked = l.removeAt(i);
                      widget.onChange([picked, ...l]);
                    },
                    child: Container(height: 36, alignment: Alignment.center, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)), child: Text(t.pick('Nastaviť ako titulnú', 'Make cover'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: _forest))),
                  ),
                ),
            ]),
          ),
        );

    final rows = <Widget>[];
    for (var i = 0; i < photos.length; i += cols) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
        child: Row(children: [
          for (var j = 0; j < cols; j++) ...[if (j > 0) const SizedBox(width: 12), Expanded(child: i + j < photos.length ? tile(i + j) : const SizedBox())],
        ]),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _uploading ? null : _pick,
        child: CustomPaint(
          painter: EditorDashedBorder(AppColors.neutral300),
          child: Opacity(
            opacity: _uploading ? 0.6 : 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: 150),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                _uploading ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF238869))) : const Icon(Icons.cloud_upload_outlined, size: 22, color: AppColors.neutral400),
                const SizedBox(height: 8),
                Text(_uploading ? t.pick('Nahrávam...', 'Uploading...') : t.pick('Presuňte sem fotografie tejto jednotky alebo vyberte', 'Drag photos of this unit here, or browse'), textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                const SizedBox(height: 8),
                Text(t.pick('Zobrazia sa ako prvé, keď hosť vyberie túto jednotku.', 'Shown first when a guest picks this unit.'), textAlign: TextAlign.center, style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
              ]),
            ),
          ),
        ),
      ),
      if (photos.isNotEmpty) ...[const SizedBox(height: 12), Column(children: rows)],
      EditorFieldError(_error),
    ]);
  }
}

// ───────────────────────────── Policies ─────────────────────────────
/// A time-of-day control (web `<input type="time">`); the value is "HH:mm".
class EditorTimeField extends StatelessWidget {
  const EditorTimeField({super.key, required this.name, required this.label, required this.value, required this.onChanged, this.hint, this.error});
  final String name;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? error;

  @override
  Widget build(BuildContext context) => EditorField(
        name: name,
        label: label,
        hint: hint,
        error: error,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final parts = value.split(':');
            final init = parts.length == 2 ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 12, minute: int.tryParse(parts[1]) ?? 0) : const TimeOfDay(hour: 12, minute: 0);
            final picked = await showTimePicker(context: context, initialTime: init, builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: w!));
            if (picked != null) onChanged('${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            decoration: editorControlDecoration(error: error),
            child: Row(children: [
              Expanded(child: Text(value.isEmpty ? '--:--' : value, style: AppText.inter(size: 16, color: value.isEmpty ? AppColors.neutral400 : _forest))),
              const Icon(Icons.schedule, size: 18, color: AppColors.neutral500),
            ]),
          ),
        ),
      );
}

Widget buildPoliciesStep({required Json data, required Map<String, String> errors, required Strings t, required Json opts, required void Function(String, dynamic) set}) {
  final lang = t.lang;
  Widget fieldset(String legend, Widget body) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(legend, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest))),
        body,
      ]);
  Widget choiceRow(String name, String legend, List<Json> options, dynamic value, void Function(String, dynamic) onSelect) => fieldset(
        legend,
        Wrap(spacing: 8, runSpacing: 8, children: [for (final o in options) _pill(optLabel(o, lang), _matches(o, asString(value)), () => onSelect(name, asString(o['en'])))]),
      );
  Widget choiceGroup(String name, String legend, List<Json> options, dynamic values) {
    final selected = asStringList(values);
    return fieldset(
      legend,
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final o in options)
          Builder(builder: (_) {
            final checked = selected.any((i) => _matches(o, i));
            return _pill(optLabel(o, lang), checked, () => set(name, checked ? selected.where((i) => !_matches(o, i)).toList() : [...selected, asString(o['en'])]));
          }),
      ]),
    );
  }

  final pet = asString(data['pet']);
  final petFee = pet == 'Allowed with an additional fee' || pet == 'Povolené za príplatok';
  return EditorStack(children: [
    EditorIntro(t.pick('Časy príchodu a odchodu sa zobrazujú v ponuke a v každom potvrdení rezervácie.', 'Check-in and check-out times are shown on the listing and in every booking confirmation.')),
    EditorGrid(children: [
      EditorTimeField(name: 'checkIn', label: t.pick('Čas príchodu od (check-in)', 'Check-in from'), value: asString(data['checkIn']), error: errors['checkIn'], onChanged: (v) => set('checkIn', v)),
      EditorTimeField(name: 'arrivalTo', label: t.pick('Čas príchodu do (check-in)', 'Check-in to'), value: asString(data['arrivalTo']), hint: t.pick('Po tomto čase už hostí neviete prijať.', 'After this time you cannot receive guests.'), onChanged: (v) => set('arrivalTo', v)),
    ]),
    EditorGrid(children: [
      EditorTimeField(name: 'checkOut', label: t.pick('Čas odchodu od (check-out)', 'Check-out from'), value: asString(data['checkOut']), error: errors['checkOut'], onChanged: (v) => set('checkOut', v)),
      EditorTimeField(name: 'departureFrom', label: t.pick('Čas odchodu do (check-out)', 'Check-out to'), value: asString(data['departureFrom']), onChanged: (v) => set('departureFrom', v)),
    ]),
    Container(
      padding: const EdgeInsets.only(top: 24),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
      child: EditorStack(gap: 28, children: [
        choiceGroup('checkInMethods', t.pick('Ako sa hostia dostanú dnu', 'How guests get in'), asMapList(opts['CHECK_IN_METHODS']), data['checkInMethods']),
        choiceRow('meals', t.pick('Strava v cene', 'Meals included'), asMapList(opts['MEALS']), data['meals'] is List ? asStringList(data['meals']).firstOrNull : data['meals'], (n, v) => set(n, [v])),
      ]),
    ),
    Container(
      padding: const EdgeInsets.only(top: 24),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
      child: EditorStack(gap: 28, children: [
        Text(t.pick('Domáci poriadok', 'House rules'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
        choiceRow('pet', t.pick('Domáce zvieratá', 'Pets'), asMapList(opts['PET_OPTIONS']), data['pet'], set),
        if (petFee)
          EditorNumberStepper(name: 'petFeePerNight', label: t.pick('Poplatok za zviera na noc (£)', 'Pet fee per night (£)'), value: data['petFeePerNight'], onValueChange: set, decimals: 2, suffix: '£'),
        choiceRow('smoking', t.pick('Fajčenie', 'Smoking'), asMapList(opts['SMOKING_OPTIONS']), data['smoking'], set),
        choiceRow('partyOrganizing', t.pick('Večierky a akcie', 'Parties and events'), asMapList(opts['PARTY_OPTIONS']), data['partyOrganizing'], set),
      ]),
    ),
  ]);
}
