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

/// Amenities, Photos and Pricing steps (host/listings/editor/EditorSteps.js).

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

bool _nonEmpty(dynamic v) => v is String && v.trim().isNotEmpty;
bool _positive(dynamic v) => v is num && v.isFinite && v > 0;

// ───────────────────────────── Amenities ─────────────────────────────
bool _matches(Json option, String item) => item == asString(option['en']) || item == asString(option['sk']);

/// What is ticked in one group. Drafts created before groups were stored only carry the flat
/// `amenities` list, so fall back to the flat entries that belong to the group.
List<String> selectedInGroup(Json data, Json group) {
  final v = data[asString(group['name'])];
  if (v is List) return asStringList(v);
  final flat = asStringList(data['amenities']);
  return [for (final o in asMapList(group['options'])) if (flat.any((f) => _matches(o, f))) asString(o['en'])];
}

Widget buildAmenitiesStep({required Json data, required Map<String, String> errors, required Strings t, required Json opts, required void Function(String, dynamic) set}) {
  final groups = asMapList(opts['AMENITY_GROUPS']);
  final error = errors['amenities'];
  final lang = t.lang;

  Json? noneOf(Json g) => asMapList(g['options']).where((o) => asString(o['en']) == 'None').firstOrNull;
  bool noneSelected(Json g) {
    final n = noneOf(g);
    return n != null && selectedInGroup(data, g).any((i) => _matches(n, i));
  }

  void toggle(Json group, Json option) {
    final current = selectedInGroup(data, group);
    final checked = current.any((i) => _matches(option, i));
    final isNone = asString(option['en']) == 'None';
    if (!isNone && noneSelected(group)) return;
    final next = isNone ? (checked ? <String>[] : [asString(option['en'])]) : (checked ? current.where((i) => !_matches(option, i)).toList() : [...current, asString(option['en'])]);
    set(asString(group['name']), next);
    // Keep the flat list in step with the groups so "at least one amenity" stays true.
    set('amenities', [for (final g in groups) ...(asString(g['name']) == asString(group['name']) ? next : selectedInGroup(data, g))]);
  }

  Widget tile(Json group, Json option) {
    final checked = selectedInGroup(data, group).any((i) => _matches(option, i));
    final disabled = noneSelected(group) && asString(option['en']) != 'None';
    final border = disabled ? AppColors.neutral200 : (checked ? _gold : (error != null ? const Color(0xFFFECACA) : AppColors.neutral200));
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: disabled ? null : () => toggle(group, option),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: disabled ? AppColors.neutral50 : (checked ? _gold.withValues(alpha: 0.05) : Colors.white),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border, width: 2),
          ),
          child: Row(children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(color: checked ? _gold : Colors.white, borderRadius: BorderRadius.circular(4), border: Border.all(color: checked ? _gold : AppColors.neutral300)),
              child: checked ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(optLabel(option, lang), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest))),
          ]),
        ),
      ),
    );
  }

  return LayoutBuilder(builder: (context, c) {
    final cols = MediaQuery.sizeOf(context).width >= 640 ? 3 : 2;
    Widget grid(List<Widget> items) {
      final rows = <Widget>[];
      for (var i = 0; i < items.length; i += cols) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var j = 0; j < cols; j++) ...[
              if (j > 0) const SizedBox(width: 12),
              Expanded(child: i + j < items.length ? items[i + j] : const SizedBox()),
            ],
          ]),
        ));
      }
      return Column(children: rows);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: EditorLabel(t.pick('Vyberte všetko, čo môžu hostia používať', 'Select everything guests can use'), required: true),
      ),
      for (final g in groups) ...[
        const SizedBox(height: 28),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(optLabel(g, lang).toUpperCase(), style: AppText.inter(size: 13, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3))),
        grid([for (final o in asMapList(g['options'])) tile(g, o)]),
      ],
      EditorFieldError(error),
    ]);
  });
}

// ───────────────────────────── Photos ─────────────────────────────
const _maxPhotoBytes = 10 * 1024 * 1024;
const _photoExts = ['jpg', 'jpeg', 'png', 'webp', 'avif'];

String _photoUrl(dynamic p) => p is String ? p : (p is Map ? asString(p['url']) : '');

class EditorDashedBorder extends CustomPainter {
  EditorDashedBorder(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)));
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 6, m.length)), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(EditorDashedBorder old) => old.color != color;
}

class PhotosStep extends ConsumerStatefulWidget {
  const PhotosStep({super.key, required this.data, required this.errors, required this.set});
  final Json data;
  final Map<String, String> errors;
  final void Function(String, dynamic) set;
  @override
  ConsumerState<PhotosStep> createState() => _PhotosStepState();
}

class _PhotosStepState extends ConsumerState<PhotosStep> {
  final _draft = TextEditingController();
  String? _draftError;
  String? _uploadError;
  String? _uploading; // 'cover' | 'gallery'
  final _broken = <String>{};

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  List<String> get _photos => [for (final p in asList(widget.data['photoUrls'])) _photoUrl(p)].where((e) => e.isNotEmpty).toList();

  Future<void> _upload(String slot, {required bool multiple}) async {
    final t = ref.read(stringsProvider);
    final picker = ImagePicker();
    final List<XFile> picked;
    try {
      picked = multiple ? await picker.pickMultiImage(imageQuality: 90, maxWidth: 3000) : [if (await picker.pickImage(source: ImageSource.gallery, imageQuality: 90, maxWidth: 3000) case final x?) x];
    } catch (e) {
      setState(() => _uploadError = errorText(e));
      return;
    }
    if (picked.isEmpty) return;
    setState(() {
      _uploadError = null;
      _draftError = null;
    });
    for (final x in picked) {
      final ext = x.name.split('.').last.toLowerCase();
      if (!_photoExts.contains(ext)) {
        setState(() => _uploadError = t.pick('Použite obrázok JPEG, PNG, WebP alebo AVIF.', 'Use a JPEG, PNG, WebP or AVIF image.'));
        return;
      }
      if (await x.length() > _maxPhotoBytes) {
        setState(() => _uploadError = t.pick('${x.name} je väčší ako 10 MB.', '${x.name} is larger than 10 MB.'));
        return;
      }
    }
    setState(() => _uploading = slot);
    try {
      final uploaded = <String>[];
      // Sequential: dropping many photos on a phone connection should not open many parallel uploads.
      for (final x in picked) {
        final url = await hostRepo.uploadListingPhoto(x);
        if (url.isNotEmpty) uploaded.add(url);
      }
      if (uploaded.isEmpty) return;
      final photos = _photos;
      widget.set('photoUrls', slot == 'cover' ? [...uploaded, ...photos.skip(photos.isNotEmpty ? 1 : 0)] : [...photos, ...uploaded]);
    } catch (e) {
      if (mounted) setState(() => _uploadError = errorText(e));
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  void _submitLink() {
    final t = ref.read(stringsProvider);
    final url = _draft.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      setState(() => _draftError = t.pick('Zadajte úplný odkaz začínajúci https:// alebo http://.', 'Enter a full link starting with https:// or http://.'));
      return;
    }
    if (_photos.contains(url)) {
      setState(() => _draftError = t.pick('Táto fotografia je už pridaná.', 'This photo is already added.'));
      return;
    }
    widget.set('photoUrls', [..._photos, url]);
    setState(() {
      _draft.clear();
      _draftError = null;
    });
  }

  Widget _dropzone(Strings t, {required String slot, required bool multiple, required String title, required String hint, bool invalid = false}) {
    final busy = _uploading == slot;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: _uploading != null ? null : () => _upload(slot, multiple: multiple),
      child: CustomPaint(
        painter: EditorDashedBorder(invalid ? const Color(0xFFFCA5A5) : AppColors.neutral300),
        child: Opacity(
          opacity: _uploading != null ? 0.6 : 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 150),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            decoration: BoxDecoration(color: invalid ? const Color(0x66FEF2F2) : null, borderRadius: BorderRadius.circular(16)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF238869))) : const Icon(Icons.cloud_upload_outlined, size: 22, color: AppColors.neutral400),
              const SizedBox(height: 8),
              Text(busy ? t.pick('Nahrávam...', 'Uploading...') : title, textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
              const SizedBox(height: 8),
              Text(hint, textAlign: TextAlign.center, style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tile(Strings t, String url, int index, {required bool isCover}) {
    final broken = _broken.contains(url);
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: AppColors.neutral100,
          child: Stack(fit: StackFit.expand, children: [
            if (broken)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.link, size: 22, color: AppColors.neutral400),
                  const SizedBox(height: 4),
                  Text(t.pick('Obrázok sa nepodarilo načítať', 'Image could not be loaded'), textAlign: TextAlign.center, style: AppText.inter(size: 11, weight: FontWeight.w600, color: AppColors.neutral400, height: 1.4)),
                ]),
              )
            else
              Image.network(
                cloudinary(url, width: 600, ratio: 3 / 4),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_broken.contains(url)) setState(() => _broken.add(url));
                  });
                  return const SizedBox.shrink();
                },
              ),
            if (isCover)
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
                  child: Text(t.pick('TITULNÁ', 'COVER'), style: AppText.inter(size: 10, weight: FontWeight.w700, color: _forest, letterSpacing: 1)),
                ),
              ),
            Positioned(
              right: 8,
              top: 8,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => widget.set('photoUrls', [..._photos]..removeAt(index)),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFDC2626)),
                ),
              ),
            ),
            if (!isCover)
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    final list = [..._photos];
                    final picked = list.removeAt(index);
                    widget.set('photoUrls', [picked, ...list]);
                  },
                  child: Container(
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)),
                    child: Text(t.pick('Nastaviť ako titulnú', 'Make cover'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: _forest)),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final photos = _photos;
    final cols = MediaQuery.sizeOf(context).width >= 640 ? 3 : 2;
    final error = _draftError ?? _uploadError ?? widget.errors['photoUrls'];

    Widget grid(List<Widget> tiles) {
      final rows = <Widget>[];
      for (var i = 0; i < tiles.length; i += cols) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
          child: Row(children: [
            for (var j = 0; j < cols; j++) ...[
              if (j > 0) const SizedBox(width: 12),
              Expanded(child: i + j < tiles.length ? tiles[i + j] : const SizedBox()),
            ],
          ]),
        ));
      }
      return Column(children: rows);
    }

    return EditorStack(gap: 32, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.only(bottom: 4), child: EditorLabel(t.pick('Titulná fotografia', 'Cover photo'), required: true)),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(t.pick('Tú uvidia cestovatelia vo výsledkoch vyhľadávania ako prvú.', 'The one travellers see first in search results.'), style: AppText.inter(size: 13, color: AppColors.neutral500))),
        if (photos.isNotEmpty)
          grid([_tile(t, photos.first, 0, isCover: true)])
        else
          _dropzone(t,
              slot: 'cover',
              multiple: false,
              invalid: widget.errors['photoUrls'] != null,
              title: t.pick('Presuňte sem fotografiu alebo vyberte', 'Drag a photo here, or browse'),
              hint: t.pick('JPEG, PNG, WebP alebo AVIF · do 10 MB', 'JPEG, PNG, WebP or AVIF · up to 10 MB')),
      ]),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(t.pick('Ďalšie fotografie', 'More photos'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest))),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(t.pick('Izby, kúpeľňa, kuchyňa a výhľad. Môžete presunúť viacero naraz.', 'Rooms, bathroom, kitchen and the view. Drop several at once.'), style: AppText.inter(size: 13, color: AppColors.neutral500))),
        _dropzone(t, slot: 'gallery', multiple: true, title: t.pick('Presuňte sem fotografie alebo vyberte', 'Drag photos here, or browse'), hint: t.pick('Môžete pridať ľubovoľný počet.', 'You can add as many as you like.')),
        if (photos.length > 1) ...[
          const SizedBox(height: 16),
          grid([for (var i = 1; i < photos.length; i++) _tile(t, photos[i], i, isCover: false)]),
        ],
      ]),
      EditorFieldError(error),
      Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text(t.pick('Pridať fotografiu odkazom', 'Add a photo by link instead'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            children: [
              LayoutBuilder(builder: (context, c) {
                final field = EditorSmallField(label: '', value: _draft.text, onChanged: (v) {
                  _draft.text = v;
                  if (_draftError != null) setState(() => _draftError = null);
                }, placeholder: 'https://…/photo.jpg', keyboard: TextInputType.url, error: _draftError);
                final add = FilledButton.icon(
                  onPressed: _submitLink,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(t.pick('Pridať', 'Add'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
                  style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                );
                return MediaQuery.sizeOf(context).width >= 640
                    ? Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: field), const SizedBox(width: 12), add])
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [field, const SizedBox(height: 12), add]);
              }),
            ],
          ),
        ),
      ),
    ]);
  }
}

// ───────────────────────────── Pricing validation (rows) ─────────────────────────────
void _validateDiscountRows(dynamic rows, String field, String thresholdKey, Strings t, Map<String, String> errors, [num? capacity]) {
  if (rows is! List) return;
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i] is Map ? asMap(rows[i]) : <String, dynamic>{};
    final base = '$field.$i';
    final th = row[thresholdKey];
    if (!_positive(th) || (th as num) != th.roundToDouble()) {
      errors['$base.$thresholdKey'] = t.pick('Zadajte celé číslo, aspoň 1.', 'Enter a whole number of at least 1.');
    } else if (_positive(capacity) && th > capacity!) {
      errors['$base.$thresholdKey'] = t.pick('Ubytovanie prijme najviac $capacity hostí, takže táto zľava by nikdy neplatila.', 'This listing takes at most $capacity guests, so this discount could never apply.');
    }
    final p = row['percent'];
    if (!_positive(p) || (p as num) > 90) errors['$base.percent'] = t.pick('Zadajte zľavu od 1 do 90 %.', 'Enter a discount from 1 to 90 %.');
  }
}

bool _filled(dynamic v) => v != null && v != '';

void validateOffers(dynamic offers, Strings t, Map<String, String> errors, [String field = 'flexiblePrices']) {
  if (offers is! List) return;
  for (var i = 0; i < offers.length; i++) {
    final offer = offers[i] is Map ? asMap(offers[i]) : <String, dynamic>{};
    final base = '$field.$i';
    final start = offer['start'];
    final end = offer['end'];
    if (!_nonEmpty(start)) {
      errors['$base.start'] = t.pick('Vyberte dátum začiatku a konca.', 'Choose a start and an end date.');
    } else if (!_nonEmpty(end)) {
      errors['$base.end'] = t.pick('Vyberte dátum začiatku a konca.', 'Choose a start and an end date.');
    } else if ((end as String).compareTo(start as String) < 0) {
      errors['$base.end'] = t.pick('Dátum konca je pred dátumom začiatku.', 'The end date is before the start date.');
    }
    final rows = offer['tiers'] is List ? asMapList(offer['tiers']) : <Json>[];
    if (rows.isEmpty) errors['$base.tiers.0.price'] = t.pick('Pridajte cenu.', 'Add a price.');
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final rb = '$base.tiers.$r';
      if (!_positive(row['price'])) errors['$rb.price'] = t.pick('Zadajte cenu za noc vyššiu ako 0 £.', 'Enter a price per night above £0.');
      final minN = _filled(row['minNights']) ? (row['minNights'] as num) : 1;
      final lower = t.pick('Maximum je nižšie ako minimum.', 'A maximum is lower than its minimum.');
      if (_filled(row['maxNights']) && (row['maxNights'] as num) < minN) errors['$rb.maxNights'] = lower;
      if (_filled(row['minGuests']) && _filled(row['maxGuests']) && (row['maxGuests'] as num) < (row['minGuests'] as num)) errors['$rb.maxGuests'] = lower;
    }
  }
}

/// Row-level pricing errors (discounts, flexible prices, paid extras).
void validatePricingRows(Json data, Strings t, Map<String, String> errors) {
  _validateDiscountRows(data['lengthDiscounts'], 'lengthDiscounts', 'minNights', t, errors);
  final offerMax = [
    for (final o in asList(data['flexiblePrices']).whereType<Map>()) for (final r in asList(o['tiers']).whereType<Map>()) (r['maxGuests'] is num ? r['maxGuests'] as num : 0),
  ];
  final mostGuests = _positive(data['guests']) ? [data['guests'] as num, ...offerMax].reduce(math.max) : data['guests'];
  _validateDiscountRows(data['guestDiscounts'], 'guestDiscounts', 'minGuests', t, errors, mostGuests is num ? mostGuests : null);
  validateOffers(data['flexiblePrices'], t, errors);
  final extras = asList(data['paidExtras']);
  for (var i = 0; i < extras.length; i++) {
    final row = extras[i] is Map ? asMap(extras[i]) : <String, dynamic>{};
    if (!_nonEmpty(row['amenity'])) errors['paidExtras.$i.amenity'] = t.pick('Vyberte vybavenie, alebo riadok odstráňte.', 'Choose an amenity, or remove this row.');
    if (!_positive(row['price'])) errors['paidExtras.$i.price'] = t.pick('Zadajte cenu vyššiu ako 0 £.', 'Enter a price above £0.');
  }
}

// ───────────────────────────── Weekend nights ─────────────────────────────
// Weekdays as JS numbers (0 = Sunday), Monday first — same as the web editor.
const _weekdays = [(1, 'Mon', 'Po'), (2, 'Tue', 'Ut'), (3, 'Wed', 'St'), (4, 'Thu', 'Št'), (5, 'Fri', 'Pi'), (6, 'Sat', 'So'), (0, 'Sun', 'Ne')];

/// Empty = Friday and Saturday nights, matching the pricing code.
List<int> weekendDaysOf(dynamic days) => days is List && days.isNotEmpty ? [for (final d in days) asInt(d)] : const [5, 6];

String weekendDaysLabel(dynamic days, String lang) {
  final picked = weekendDaysOf(days);
  return [for (final d in _weekdays) if (picked.contains(d.$1)) lang == 'en' ? d.$2 : d.$3].join(', ');
}

class _WeekendDays extends StatelessWidget {
  const _WeekendDays({required this.data, required this.t, required this.set});
  final Json data;
  final Strings t;
  final void Function(String, dynamic) set;

  @override
  Widget build(BuildContext context) {
    final picked = weekendDaysOf(data['weekendDays']);
    void toggle(int day) {
      final next = picked.contains(day) ? picked.where((d) => d != day).toList() : [...picked, day];
      if (next.isNotEmpty) set('weekendDays', next..sort());
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.pick('Víkendové noci', 'Weekend nights'), style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final d in _weekdays)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => toggle(d.$1),
            child: Container(
              constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: picked.contains(d.$1) ? _forest : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: picked.contains(d.$1) ? _forest : AppColors.neutral200, width: 2),
              ),
              child: Text(t.isEn ? d.$2 : d.$3, style: AppText.inter(size: 14, weight: FontWeight.w700, color: picked.contains(d.$1) ? Colors.white : _forest)),
            ),
          ),
      ]),
      const SizedBox(height: 8),
      Text(
        t.pick('Noc začínajúca v daný deň, napr. Pi = z piatka na sobotu. Platí pre víkendovú cenu vyššie aj vo flexibilných cenách.',
            'The night starting on that day, e.g. Fri = Friday to Saturday. Used by the weekend price above and in flexible prices.'),
        style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5),
      ),
    ]);
  }
}

// ───────────────────────────── Pricing ─────────────────────────────
Widget buildPricingStep({required Json data, required Map<String, String> errors, required Strings t, required Json opts, required void Function(String, dynamic) set}) {
  Widget stepper(String name, String label, String hint, {num min = 0, num step = 1, int decimals = 0, String? suffix}) => EditorNumberStepper(
        name: name,
        label: label,
        value: data[name],
        onValueChange: set,
        min: min,
        step: step,
        decimals: decimals,
        suffix: suffix,
        error: errors[name],
        hint: hint,
      );
  final policies = asMapList(opts['CANCELLATION_POLICIES']);
  final selected = policies.where((p) => asString(p['value']) == asString(data['cancellationPolicyType'])).firstOrNull;
  final lang = t.lang;
  final included = asInt(data['includedGuests']);

  return EditorStack(children: [
    stepper('nightlyPrice', t.pick('Cena za noc (£)', 'Nightly price (£)'), t.pick('Základná cena za noc v eurách, bez upratovania či príplatkov za ďalších hostí.', 'Base price per night in pounds, before cleaning or extra-guest fees.'), min: 1, decimals: 2, suffix: '£'),
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
      child: EditorStack(children: [
        stepper('weekendPricePerNight', t.pick('Víkendová cena za noc (£, voliteľné)', 'Weekend price per night (£, optional)'),
            t.pick('Účtuje sa namiesto ceny za noc vo víkendové noci (${weekendDaysLabel(data['weekendDays'], t.lang)}). Nechajte 0 pre rovnakú cenu každú noc.',
                'Charged instead of the nightly price on weekend nights (${weekendDaysLabel(data['weekendDays'], t.lang)}). Leave 0 for the same price every night.'),
            decimals: 2, suffix: '£'),
        _WeekendDays(data: data, t: t, set: set),
      ]),
    ),
    stepper('minNights', t.pick('Minimálny počet nocí', 'Minimum nights'), t.pick('Najkratší pobyt, ktorý prijímate. 1 povoľuje aj jednonocové rezervácie.', 'Shortest stay you accept. 1 allows single-night bookings.'), min: 1),
    stepper('includedGuests', t.pick('Počet osôb v cene (voliteľné)', 'Guests included in the price (optional)'),
        t.pick('Pre koľko osôb platí cena za noc, napr. 2 na pevných lôžkach. Každá ďalšia osoba platí cenu prístelky nižšie za noc. 0 = nepoužíva sa.',
            'How many guests the nightly price covers, e.g. 2 in the standard beds. Each guest above this pays the extra-bed price below per night. 0 = not used.')),
    stepper('pricePerPerson',
        included > 0 ? t.pick('Prístelka (£ za osobu / noc, voliteľné)', 'Extra bed (£ per guest / night, optional)') : t.pick('Cena za osobu (£, voliteľné)', 'Price per person (£, optional)'),
        included > 0
            ? t.pick('Pripočíta sa za noc za každú osobu nad $included, napr. 3 osoby = cena za noc + 1 × táto suma. Flexibilné ceny môžu mať vlastnú.',
                'Added per night for each guest above $included, e.g. 3 guests = nightly price + 1 × this. Flexible prices can set their own.')
            : t.pick('Za osobu a noc: pobyt stojí cenu za noc alebo počet osôb × táto suma, podľa toho, čo je vyššie. Ak chcete účtovať prístelky navyše k cene za noc, nastavte Počet osôb v cene.',
                'Per guest per night: the stay costs the nightly price or guests × this, whichever is higher. To charge extra beds on top of the nightly price instead, set Guests included in the price.'),
        decimals: 2, suffix: '£'),
    stepper('cleaningFee', t.pick('Poplatok za upratovanie (£, voliteľné)', 'Cleaning fee (£, optional)'),
        t.pick('Účtuje sa raz za pobyt a pripočíta sa k celkovej cene. Nechajte 0, ak poplatok neúčtujete.', "Charged once per stay and added to the guest's total. Leave 0 for no cleaning fee."),
        decimals: 2, suffix: '£'),
    stepper('localTaxPerPersonNight', t.pick('Miestna daň (£ za osobu / noc, voliteľné)', 'Local tax (£ per person / night, optional)'),
        t.pick('Účtuje sa za hosťa (dospelí a deti) a noc a pripočíta sa k celkovej cene. Nechajte 0, ak sa neúčtuje.', "Charged per guest (adults and children) per night and added to the guest's total. Leave 0 if none."),
        step: 0.5, decimals: 2, suffix: '£'),
    _PaidExtras(data: data, errors: errors, t: t, opts: opts, set: set),
    stepper('nightMax', t.pick('Maximálny počet nocí (voliteľné)', 'Maximum nights (optional)'), t.pick('Najdlhší pobyt, ktorý prijímate. 0 znamená bez obmedzenia.', 'Longest stay you accept. 0 means no limit.')),
    stepper('discount', t.pick('Zľava (%, voliteľné)', 'Discount (%, optional)'), t.pick('Zobrazí sa ako zníženie oproti cene za noc.', 'Shown as a reduction against the nightly price.')),
    _StayDiscounts(data: data, errors: errors, t: t, set: set),
    FlexiblePricesEditor(data: data, errors: errors, t: t, set: set),
    EditorSelect(
      name: 'cancellationPolicyType',
      label: t.pick('Storno podmienky', 'Cancellation policy'),
      value: asString(data['cancellationPolicyType']),
      options: [for (final p in policies) (asString(p['value']), '${asString(pick(p, 'label.$lang'))} — ${asString(pick(p, 'description.$lang'))}')],
      placeholder: t.pick('Vyberte podmienky', 'Select policy'),
      hint: t.pick('Určuje, koľko hosť dostane späť pri zrušení. Zobrazuje sa pred rezerváciou.', 'Decides what a guest gets back when they cancel. Shown before they book.'),
      onChanged: (v) => set('cancellationPolicyType', v),
    ),
    if (selected != null) _PolicyCard(policy: selected, t: t),
  ]);
}

class _PolicyCard extends StatelessWidget {
  const _PolicyCard({required this.policy, required this.t});
  final Json policy;
  final Strings t;

  @override
  Widget build(BuildContext context) {
    final lang = t.lang;
    final w = MediaQuery.sizeOf(context).width;
    final cols = w >= 1024 ? 3 : (w >= 640 ? 2 : 1);
    final tiers = asMapList(policy['tiers']);
    const accent = Color(0xFF319A7A);
    Widget tier(Json x) => Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200.withValues(alpha: 0.8))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${asInt(x['refundPercent'])} %', style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            const SizedBox(width: 12),
            Expanded(child: Text(asString(pick(x, 'timing.$lang')), style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.4))),
          ]),
        );
    final rows = <Widget>[];
    for (var i = 0; i < tiers.length; i += cols) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var j = 0; j < cols; j++) ...[
              if (j > 0) const SizedBox(width: 8),
              Expanded(child: i + j < tiers.length ? tier(tiers[i + j]) : const SizedBox()),
            ],
          ]),
        ),
      ));
    }
    return Container(
      padding: EdgeInsets.all(w >= 640 ? 20 : 16),
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16), border: Border.all(color: accent.withValues(alpha: 0.2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(alignment: WrapAlignment.spaceBetween, children: [
          Text(t.pick('Zvolené storno podmienky', 'Selected cancellation policy'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
          Text(asString(pick(policy, 'label.$lang')), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF257562))),
        ]),
        const SizedBox(height: 8),
        Text(asString(pick(policy, 'description.$lang')), style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.7)),
        const SizedBox(height: 12),
        Column(children: rows),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
        child: child,
      );
}

Widget _sectionTitle(String title, String hint, {double titleSize = 14}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: AppText.inter(size: titleSize, weight: FontWeight.w700, color: _forest)),
      const SizedBox(height: 2),
      Text(hint, style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.7)),
    ]);

List<Json> _rows(dynamic v) => asMapList(v);

// ───────────────────────────── Paid extras ─────────────────────────────
class _PaidExtras extends StatelessWidget {
  const _PaidExtras({required this.data, required this.errors, required this.t, required this.opts, required this.set});
  final Json data;
  final Map<String, String> errors;
  final Strings t;
  final Json opts;
  final void Function(String, dynamic) set;

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data['paidExtras']);
    void write(List<Json> next) => set('paidExtras', next);
    void update(int i, Json patch) => write([for (var k = 0; k < rows.length; k++) k == i ? {...rows[k], ...patch} : rows[k]]);
    final groups = asMapList(opts['AMENITY_GROUPS']);
    final lang = t.lang;

    // Every ticked amenity except "None": value "group::en".
    final ticked = <(String, String, Json)>[
      for (final g in groups)
        for (final o in asMapList(g['options']))
          if (asString(o['en']) != 'None' && selectedInGroup(data, g).any((i) => i == asString(o['en']) || i == asString(o['sk']))) ('${asString(g['name'])}::${asString(o['en'])}', asString(g['name']), o),
    ];
    String valueOf(Json r) {
      if (asString(r['field']).isEmpty || asString(r['amenity']).isEmpty) return '';
      final g = groups.where((x) => asString(x['name']) == asString(r['field'])).firstOrNull;
      final match = asMapList(g?['options']).where((o) => asString(o['en']) == asString(r['amenity']) || asString(o['sk']) == asString(r['amenity'])).firstOrNull;
      return '${asString(r['field'])}::${match != null ? asString(match['en']) : asString(r['amenity'])}';
    }

    final used = {for (final r in rows) valueOf(r)};
    return _Section(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionTitle(
          t.pick('Platené doplnky (voliteľné)', 'Paid extras (optional)'),
          t.pick('Účtujte si vybavenie, ktoré si hosť môže zvoliť, napr. vírivka 30 £ za noc. Hosť ho zaškrtne pri rezervácii a pripočíta sa k celkovej cene. Zobrazuje sa len vybavenie zaškrtnuté v kroku Vybavenie.',
              "Charge for an amenity the guest can choose, e.g. hot tub £30 per night. Guests tick it when booking and it's added to their total. Only amenities ticked in Amenities appear here."),
        ),
        for (var i = 0; i < rows.length; i++) ...[
          const SizedBox(height: 12),
          EditorRowBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: _SmallSelect(
                    label: t.pick('Vybavenie', 'Amenity'),
                    value: valueOf(rows[i]),
                    placeholder: t.pick('Vyberte vybavenie', 'Select amenity'),
                    options: [for (final x in ticked) (x.$1, optLabel(x.$3, lang), used.contains(x.$1) && x.$1 != valueOf(rows[i]))],
                    error: errors['paidExtras.$i.amenity'],
                    onChanged: (v) {
                      final pickd = ticked.where((x) => x.$1 == v).firstOrNull;
                      update(i, pickd != null ? {'field': pickd.$2, 'amenity': asString(pickd.$3['en'])} : {'field': null, 'amenity': null});
                    },
                  ),
                ),
                EditorTrashButton(onTap: () => write([...rows]..removeAt(i)), tooltip: t.pick('Odstrániť doplnok ${i + 1}', 'Remove paid extra ${i + 1}')),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: _SmallSelect(
                    label: t.pick('Účtuje sa', 'Charged'),
                    value: asString(rows[i]['pricing']) == 'per_night' ? 'per_night' : 'per_stay',
                    options: [('per_stay', t.pick('Pevná cena (raz za pobyt)', 'Fixed price (once per stay)'), false), ('per_night', t.pick('Za noc', 'Per night'), false)],
                    onChanged: (v) => update(i, {'pricing': v}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: EditorSmallField(
                    label: t.pick('Cena (£)', 'Price (£)'),
                    value: editorNumText(rows[i]['price']),
                    placeholder: '0',
                    keyboard: const TextInputType.numberWithOptions(decimal: true),
                    error: errors['paidExtras.$i.price'],
                    onChanged: (v) => update(i, {'price': editorParseNumber(v, decimals: true)}),
                  ),
                ),
              ]),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        if (ticked.length > used.length)
          EditorAddLink(label: t.pick('Pridať platený doplnok', 'Add paid extra'), onTap: () => write([...rows, {'field': null, 'amenity': null, 'pricing': 'per_stay', 'price': null}]))
        else if (rows.isEmpty)
          Text(t.pick('Najprv zaškrtnite vybavenie v kroku Vybavenie.', 'Tick amenities in the Amenities step first.'), style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
      ]),
    );
  }
}

/// Dropdown with a compact label; options are (value, label, disabled).
class _SmallSelect extends StatelessWidget {
  const _SmallSelect({required this.label, required this.value, required this.options, required this.onChanged, this.placeholder, this.error});
  final String label;
  final String value;
  final List<(String, String, bool)> options;
  final ValueChanged<String> onChanged;
  final String? placeholder;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final known = options.any((o) => o.$1 == value);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(label, style: AppText.inter(size: 12, weight: FontWeight.w700, color: _forest))),
      Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: editorControlDecoration(error: error),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: known ? value : (placeholder != null ? '' : null),
            isExpanded: true,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20, color: AppColors.neutral500),
            style: AppText.inter(size: 16, color: _forest),
            borderRadius: BorderRadius.circular(12),
            items: [
              if (placeholder != null) DropdownMenuItem(value: '', child: Text(placeholder!)),
              for (final o in options) DropdownMenuItem(value: o.$1, enabled: !o.$3, child: Text(o.$2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 16, color: o.$3 ? AppColors.neutral400 : _forest))),
            ],
            onChanged: (v) => onChanged(v ?? ''),
          ),
        ),
      ),
      EditorFieldError(error),
    ]);
  }
}

// ───────────────────────────── Stay discounts ─────────────────────────────
class _StayDiscounts extends StatelessWidget {
  const _StayDiscounts({required this.data, required this.errors, required this.t, required this.set});
  final Json data;
  final Map<String, String> errors;
  final Strings t;
  final void Function(String, dynamic) set;

  Widget _list({required String field, required String thresholdKey, required String title, required String hint, required String thresholdLabel, required String addLabel}) {
    final rows = _rows(data[field]);
    void write(List<Json> next) => set(field, next);
    void update(int i, Json patch) => write([for (var k = 0; k < rows.length; k++) k == i ? {...rows[k], ...patch} : rows[k]]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(title, hint),
      for (var i = 0; i < rows.length; i++) ...[
        const SizedBox(height: 12),
        EditorRowBox(
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: EditorSmallField(
                label: thresholdLabel,
                value: editorNumText(rows[i][thresholdKey]),
                placeholder: '7',
                keyboard: TextInputType.number,
                error: errors['$field.$i.$thresholdKey'],
                onChanged: (v) => update(i, {thresholdKey: editorParseNumber(v)}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: EditorSmallField(
                label: t.pick('Zľava (%)', 'Discount (%)'),
                value: editorNumText(rows[i]['percent']),
                placeholder: '10',
                keyboard: TextInputType.number,
                error: errors['$field.$i.percent'],
                onChanged: (v) => update(i, {'percent': editorParseNumber(v)}),
              ),
            ),
            EditorTrashButton(onTap: () => write([...rows]..removeAt(i)), tooltip: t.pick('Odstrániť zľavu ${i + 1}', 'Remove discount ${i + 1}')),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      EditorAddLink(label: addLabel, onTap: () => write([...rows, {thresholdKey: null, 'percent': null}])),
    ]);
  }

  @override
  Widget build(BuildContext context) => _Section(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            t.pick('Voliteľné zľavy z ceny za noci (nie z upratovania, miestnej dane ani poplatku za zviera). Ak platí zľava za noci aj za hostí, sčítajú sa (max. 90 %).',
                "Optional discounts off the nights' price (not the cleaning fee, local tax or pet fee). If both a nights and a guests discount apply, they add up (max 90 %)."),
            style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5),
          ),
          const SizedBox(height: 20),
          _list(
            field: 'lengthDiscounts',
            thresholdKey: 'minNights',
            title: t.pick('Zľava podľa počtu nocí', 'Discount by number of nights'),
            hint: t.pick('napr. od 7 nocí 10 %, od 28 nocí 20 %. Platí najvyššia dosiahnutá.', 'e.g. from 7 nights 10 %, from 28 nights 20 %. The highest one reached applies.'),
            thresholdLabel: t.pick('Od počtu nocí', 'From nights'),
            addLabel: t.pick('Pridať zľavu za noci', 'Add nights discount'),
          ),
          const SizedBox(height: 20),
          _list(
            field: 'guestDiscounts',
            thresholdKey: 'minGuests',
            title: t.pick('Zľava podľa počtu hostí', 'Discount by number of guests'),
            hint: t.pick('Počítajú sa dospelí a deti. napr. od 4 hostí 5 %. Platí najvyššia dosiahnutá.', 'Counts adults and children. e.g. from 4 guests 5 %. The highest one reached applies.'),
            thresholdLabel: t.pick('Od počtu hostí', 'From guests'),
            addLabel: t.pick('Pridať zľavu za hostí', 'Add guests discount'),
          ),
        ]),
      );
}

// ───────────────────────────── Flexible prices ─────────────────────────────
class FlexiblePricesEditor extends StatelessWidget {
  const FlexiblePricesEditor({super.key, required this.data, required this.errors, required this.t, required this.set, this.field = 'flexiblePrices', this.intro});
  final String field;
  final String? intro;
  final Json data;
  final Map<String, String> errors;
  final Strings t;
  final void Function(String, dynamic) set;

  static Json _emptyRow() => {'minNights': 1, 'maxNights': null, 'minGuests': null, 'maxGuests': null, 'price': null, 'weekendPrice': null};

  @override
  Widget build(BuildContext context) {
    final offers = _rows(data[field]);
    void write(List<Json> next) => set(field, next);
    void updateOffer(int i, Json patch) => write([for (var k = 0; k < offers.length; k++) k == i ? {...offers[k], ...patch} : offers[k]]);
    List<Json> tiersOf(int i) => _rows(offers[i]['tiers']);
    void updateRow(int i, int r, Json patch) => updateOffer(i, {'tiers': [for (var k = 0; k < tiersOf(i).length; k++) k == r ? {...tiersOf(i)[k], ...patch} : tiersOf(i)[k]]});
    final sm = MediaQuery.sizeOf(context).width >= 640;
    final guests = asInt(data['guests']);
    final weekendText = weekendDaysLabel(data['weekendDays'], t.lang);
    final included = asInt(data['includedGuests']);

    Widget offerCard(int index) {
      final offer = offers[index];
      final base = '$field.$index';
      final tiers = tiersOf(index);
      final datesError = errors['$base.start'] ?? errors['$base.end'];
      final nameField = EditorSmallField(label: t.pick('Názov ponuky', 'Offer name'), labelSize: 13, value: asString(offer['name']), placeholder: t.pick('napr. Letná sezóna', 'e.g. Summer season'), onChanged: (v) => updateOffer(index, {'name': v}));
      final startField = EditorDateField(label: t.pick('Dátum začiatku', 'Start date'), value: asString(offer['start']), error: errors['$base.start'], onChanged: (v) => updateOffer(index, {'start': v}));
      final endField = EditorDateField(label: t.pick('Dátum konca', 'End date'), value: asString(offer['end']), min: asStringOrNull(offer['start']), error: errors['$base.end'], onChanged: (v) => updateOffer(index, {'end': v}));
      final applyDiscounts = offer['applyDiscounts'] != false;

      Widget rowCard(int r) {
        final row = tiers[r];
        final rb = '$base.tiers.$r';
        final nightsError = errors['$rb.maxNights'];
        final guestsError = errors['$rb.maxGuests'];
        final priceError = errors['$rb.price'];
        Widget num(String key, String label, String ph, String? err) => EditorSmallField(
              label: label,
              value: editorNumText(row[key]),
              placeholder: ph,
              keyboard: TextInputType.number,
              error: null,
              onChanged: (v) => updateRow(index, r, {key: editorParseNumber(v)}),
            );
        final nums = [
          num('minNights', t.pick('Min. nocí', 'Min nights'), '1', null),
          num('maxNights', t.pick('Max. nocí', 'Max nights'), '–', nightsError),
          num('minGuests', t.pick('Min. hostí', 'Min guests'), '–', null),
          num('maxGuests', t.pick('Max. hostí', 'Max guests'), '–', guestsError),
        ];
        return EditorRowBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (sm)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var k = 0; k < 4; k++) ...[if (k > 0) const SizedBox(width: 12), Expanded(child: nums[k])]])
            else ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: nums[0]), const SizedBox(width: 12), Expanded(child: nums[1])]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: nums[2]), const SizedBox(width: 12), Expanded(child: nums[3])]),
            ],
            EditorFieldError(nightsError),
            EditorFieldError(guestsError),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: EditorSmallField(
                  label: t.pick('Cena / noc (£)', 'Price / night (£)'),
                  value: editorNumText(row['price']),
                  placeholder: '0',
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  error: priceError,
                  onChanged: (v) => updateRow(index, r, {'price': editorParseNumber(v, decimals: true)}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: EditorSmallField(
                  label: t.pick('Víkendová noc (£) · $weekendText', 'Weekend night (£) · $weekendText'),
                  value: editorNumText(row['weekendPrice']),
                  placeholder: '0',
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  error: errors['$rb.weekendPrice'],
                  onChanged: (v) => updateRow(index, r, {'weekendPrice': editorParseNumber(v, decimals: true)}),
                ),
              ),
              if (tiers.length > 1) EditorTrashButton(onTap: () => updateOffer(index, {'tiers': [...tiers]..removeAt(r)}), tooltip: t.pick('Odstrániť cenu ${r + 1}', 'Remove price ${r + 1}')),
            ]),
            if (r == 0 && priceError == null && nightsError == null && guestsError == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${t.pick('Prázdne maximum znamená bez limitu. Počet hostí rozhoduje len pri viacerých cenách: použije sa riadok pre daný počet hostí, inak riadok podľa dĺžky pobytu.', 'Leave a maximum empty for no limit. Guest numbers only matter when you add several prices: the row matching the party is used, otherwise the row matching the stay length.')}'
                  '${t.pick(' Pri pobytoch v termíne tejto ponuky platí jej min./max. počet nocí namiesto minima a maxima ubytovania.', " For stays in this offer's dates, its min/max nights replace the listing's minimum and maximum nights.")}'
                  '${t.pick(' Ak víkendovú cenu nevyplníte, platí rovnaká cena každú noc.', ' Leave the weekend price empty to charge the same price every night.')}'
                  '${guests > 0 ? t.pick(' Ubytovanie prijme $guests hostí; vyšší Max. hostí tu umožní viac hostí v termíne tejto ponuky.', ' The listing takes $guests guests; a higher Max guests here lets more guests book in this offer\'s dates.') : ''}',
                  style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5),
                ),
              ),
          ]),
        );
      }

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral100, width: 2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(t.pick('PONUKA ${index + 1}', 'OFFER ${index + 1}'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1.2)),
            EditorTrashButton(size: 40, onTap: () => write([...offers]..removeAt(index)), tooltip: t.pick('Odstrániť ponuku ${index + 1}', 'Remove offer ${index + 1}')),
          ]),
          const SizedBox(height: 12),
          if (sm)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: nameField), const SizedBox(width: 16), Expanded(child: startField), const SizedBox(width: 16), Expanded(child: endField)])
          else ...[
            nameField,
            const SizedBox(height: 16),
            startField,
            const SizedBox(height: 16),
            endField,
          ],
          EditorFieldError(datesError),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => updateOffer(index, {'applyDiscounts': !applyDiscounts}),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(color: applyDiscounts ? _forest : Colors.white, borderRadius: BorderRadius.circular(4), border: Border.all(color: applyDiscounts ? _forest : AppColors.neutral300)),
                  child: applyDiscounts ? const Icon(Icons.check, size: 15, color: Colors.white) : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.pick('Uplatniť zľavy na túto ponuku', 'Apply discounts to this offer'), style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest, height: 1.5)),
                    Text(
                      t.pick('Ak je zaškrtnuté, zľavy podľa počtu nocí a hostí sa odpočítajú aj z ceny tejto ponuky. Odškrtnite, ak chcete účtovať plnú cenu ponuky.',
                          "When ticked, the discounts by number of nights and guests also come off this offer's price. Untick to charge the full offer price."),
                      style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
          if (included > 0) ...[
            const SizedBox(height: 12),
            EditorSmallField(
              label: t.pick('Prístelka v tomto termíne (£ za osobu / noc, voliteľné)', 'Extra bed in these dates (£ per guest / night, optional)'),
              labelSize: 13,
              value: editorNumText(offer['extraPerPerson']),
              placeholder: '0',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              error: errors['$base.extraPerPerson'],
              onChanged: (v) => updateOffer(index, {'extraPerPerson': editorParseNumber(v, decimals: true)}),
            ),
            const SizedBox(height: 4),
            Text(
              t.pick('Za každú osobu nad $included. Ak nevyplníte, platí cena prístelky vyššie${asDouble(data['pricePerPerson']) > 0 ? ' (${data['pricePerPerson']} £)' : ''}; 0 = zadarmo.',
                  'For each guest above $included. Leave empty to use the extra-bed price above${asDouble(data['pricePerPerson']) > 0 ? ' (£${data['pricePerPerson']})' : ''}; 0 = free.'),
              style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5),
            ),
          ],
          const SizedBox(height: 12),
          EditorSmallField(
            label: t.pick('Poznámka pre hostí (voliteľné)', 'Note for guests (optional)'),
            labelSize: 13,
            value: asString(offer['note']),
            lines: 2,
            maxLength: 300,
            placeholder: t.pick('napr. Počas zimnej sezóny sú raňajky v cene.', 'e.g. Breakfast included during the winter season.'),
            onChanged: (v) => updateOffer(index, {'note': v}),
          ),
          const SizedBox(height: 4),
          Text(t.pick('Zobrazí sa hosťom pri cenách tejto ponuky na stránke ubytovania.', "Shown to guests with this offer's prices on the listing page."), style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
          const SizedBox(height: 16),
          for (var r = 0; r < tiers.length; r++) ...[if (r > 0) const SizedBox(height: 12), rowCard(r)],
          const SizedBox(height: 12),
          EditorAddLink(label: t.pick('Pridať ďalšiu cenu do tejto ponuky', 'Add another price to this offer'), onTap: () => updateOffer(index, {'tiers': [...tiers, _emptyRow()]})),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.only(top: 24),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.pick('Flexibilné ceny (voliteľné)', 'Flexible prices (optional)'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
        const SizedBox(height: 4),
        Text(
          intro ?? t.pick('Ponúknite inú cenu za noc pre vybrané termíny, napr. letnú sezónu alebo zvýhodnený dlhší pobyt. Noci v týchto termínoch sa účtujú touto cenou namiesto ceny za noc vyššie.',
              'Offer a different price per night for certain dates, e.g. a summer season or a long-stay deal. Nights inside these dates are charged this price instead of the nightly price above.'),
          style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5),
        ),
        for (var i = 0; i < offers.length; i++) ...[const SizedBox(height: 16), offerCard(i)],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => write([
              ...offers,
              {'name': '', 'start': '', 'end': '', 'note': '', 'applyDiscounts': true, 'tiers': [_emptyRow()]},
            ]),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(color: AppColors.neutral50.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300, width: 2)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.add, size: 18, color: _forest),
                const SizedBox(width: 8),
                Text(t.pick('Pridať flexibilnú cenu', 'Add flexible price'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
