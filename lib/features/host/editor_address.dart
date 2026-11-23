import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import 'editor_fields.dart';

/// Address suggestions for the Location step.
///
/// The website uses Google Places with a browser key. The app carries no Google key (every key lives on
/// the server), so this uses OpenStreetMap's Nominatim search instead: restricted to the United Kingdom, debounced,
/// and one request at a time to respect its usage policy. Suggestions are an accelerator: without a
/// connection every field below still works as a plain input.
class AddressSuggestField extends StatefulWidget {
  const AddressSuggestField({super.key, required this.data, required this.error, required this.t, required this.set});
  final Json data;
  final String? error;
  final Strings t;
  final void Function(String, dynamic) set;

  @override
  State<AddressSuggestField> createState() => _AddressSuggestFieldState();
}

class _AddressSuggestFieldState extends State<AddressSuggestField> {
  static final _dio = Dio(BaseOptions(
    baseUrl: 'https://nominatim.openstreetmap.org',
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 8),
    headers: {'User-Agent': 'StayHubApp/1.0 (host listing editor)', 'Accept-Language': 'sk,en'},
  ));
  Timer? _debounce;
  List<Json> _results = const [];
  bool _unavailable = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _typed(String v) {
    widget.set('street', v);
    _debounce?.cancel();
    if (v.trim().length < 4) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 700), () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    final seq = ++_seq;
    try {
      final r = await _dio.get<dynamic>('/search', queryParameters: {'format': 'jsonv2', 'addressdetails': 1, 'countrycodes': 'gb', 'limit': 5, 'q': q});
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = asMapList(r.data);
        _unavailable = false;
      });
    } catch (_) {
      if (mounted && seq == _seq) {
        setState(() {
          _results = const [];
          _unavailable = true;
        });
      }
    }
  }

  void _pick(Json place) {
    final a = asMap(place['address']);
    final road = asString(a['road'], asString(a['pedestrian'], asString(a['footway'])));
    final number = asString(a['house_number']);
    final city = asString(a['city'], asString(a['town'], asString(a['village'], asString(a['municipality']))));
    final street = road.isNotEmpty ? [road, number].where((e) => e.isNotEmpty).join(' ') : asString(place['display_name']).split(',').first.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    widget.set('street', street);
    final lat = double.tryParse(asString(place['lat']));
    final lon = double.tryParse(asString(place['lon']));
    if (lat != null && lon != null) {
      widget.set('latitude', lat);
      widget.set('longitude', lon);
    }
    // Only fill what the host has not already typed, so a picked suggestion never overwrites a manual correction.
    final d = widget.data;
    if (city.isNotEmpty && asString(d['city']).isEmpty) widget.set('city', city);
    if (asString(a['postcode']).isNotEmpty && asString(d['zipCode']).isEmpty) widget.set('zipCode', asString(a['postcode']));
    if (asString(a['country']).isNotEmpty && asString(d['country']).isEmpty) widget.set('country', asString(a['country']));
    if (asString(a['state']).isNotEmpty && asString(d['state']).isEmpty) widget.set('state', asString(a['state']));
    setState(() => _results = const []);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EditorTextField(
        name: 'street',
        label: t.pick('Ulica a číslo', 'Street address'),
        value: asString(widget.data['street']),
        error: widget.error,
        autofill: const [AutofillHints.fullStreetAddress],
        placeholder: t.pick('Začnite písať a vyhľadajte adresu', 'Start typing to search for an address'),
        hint: t.pick('Vyberte návrh a mesto, PSČ a krajina sa doplnia.', 'Pick a suggestion and the city, postal code and country fill in.'),
        onChanged: _typed,
      ),
      if (_results.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4))]),
          child: Column(children: [
            for (var i = 0; i < _results.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.neutral100),
              InkWell(
                onTap: () => _pick(_results[i]),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    const Icon(Icons.location_on_outlined, size: 18, color: AppColors.neutral400),
                    const SizedBox(width: 10),
                    Expanded(child: Text(asString(_results[i]['display_name']), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, color: AppColors.hostForest, height: 1.35))),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      if (_unavailable)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t.pick('Návrhy adries momentálne nie sú dostupné — adresu môžete zadať ručne.', 'Address suggestions are unavailable right now — you can still type the address yourself.'), style: AppText.inter(size: 13, color: const Color(0xFFB45309))),
        ),
    ]);
  }
}
