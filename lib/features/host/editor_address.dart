import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import 'editor_fields.dart';

/// Address suggestions for the Location step.
///
/// Suggestions come from Geoapify through the backend (`GET /api/geo/autocomplete`), so the
/// Geoapify key stays on the server. Restricted to the United Kingdom with London results first. Built to feel instant: a
/// very short debounce, the request in flight is cancelled on each keystroke, previous suggestions stay on
/// screen until new ones arrive, and answers are cached for 10 minutes (here and on the server). Suggestions are an accelerator: without a connection every field
/// below still works as a plain input.
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
  Timer? _debounce;
  List<Json> _results = const [];
  bool _unavailable = false;
  bool _loading = false;
  int _seq = 0;
  CancelToken? _inflight;

  @override
  void dispose() {
    _debounce?.cancel();
    _inflight?.cancel();
    super.dispose();
  }

  void _typed(String v) {
    widget.set('street', v);
    _debounce?.cancel();
    final q = v.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (q.length < 2) {
      _seq++;
      _inflight?.cancel();
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 120), () => _search(q));
  }

  Future<void> _search(String q) async {
    final seq = ++_seq;
    _inflight?.cancel();
    final token = _inflight = CancelToken();
    setState(() => _loading = true);
    try {
      final r = await api.get('/geo/autocomplete',
          query: {'text': q.toLowerCase(), 'country': 'gb'}, cache: const Duration(minutes: 10), cancelToken: token);
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = asMapList(asMap(r)['results']);
        _unavailable = false;
        _loading = false;
      });
    } catch (_) {
      if (mounted && seq == _seq) {
        setState(() {
          _results = const [];
          _unavailable = true;
          _loading = false;
        });
      }
    }
  }

  void _pick(Json place) {
    // The backend already flattens Geoapify's result (London boroughs collapse to "London").
    // A postcode-only match has no street: clear the field rather than leave the postcode in it.
    final street = asString(place['type']) == 'postcode'
        ? asString(place['street'])
        : asString(place['street'], asString(place['label']).split(',').first.trim());
    FocusManager.instance.primaryFocus?.unfocus();
    widget.set('street', street);
    final lat = place['latitude'], lon = place['longitude'];
    if (lat is num && lon is num) {
      widget.set('latitude', lat.toDouble());
      widget.set('longitude', lon.toDouble());
    }
    // A picked suggestion replaces city/postcode/country/region: they belong to the new street.
    if (asString(place['city']).isNotEmpty) widget.set('city', asString(place['city']));
    if (asString(place['postcode']).isNotEmpty) widget.set('zipCode', asString(place['postcode']));
    if (asString(place['country']).isNotEmpty) widget.set('country', asString(place['country']));
    if (asString(place['state']).isNotEmpty) widget.set('state', asString(place['state']));
    _seq++;
    _inflight?.cancel();
    setState(() {
      _results = const [];
      _loading = false;
    });
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
      if (_loading)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: LinearProgressIndicator(minHeight: 2, color: AppColors.hostForest, backgroundColor: AppColors.neutral100),
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
                    Expanded(child: Text(asString(_results[i]['label']), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, color: AppColors.hostForest, height: 1.35))),
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
