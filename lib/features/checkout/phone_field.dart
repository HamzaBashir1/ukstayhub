import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// The web checkout's `react-phone-input-2` (country picker + number, default
/// United Kingdom), validated like `isValidPhoneNumber` from libphonenumber-js —
/// `phone_numbers_parser` is a port of the same metadata.

/// Calling-code country list the picker offers (ISO code, English name).
const _countries = <(IsoCode, String)>[
  (IsoCode.GB, 'United Kingdom'),
  (IsoCode.IE, 'Ireland'),
  (IsoCode.SK, 'Slovakia'),
  (IsoCode.CZ, 'Czechia'),
  (IsoCode.PL, 'Poland'),
  (IsoCode.HU, 'Hungary'),
  (IsoCode.AT, 'Austria'),
  (IsoCode.DE, 'Germany'),
  (IsoCode.UA, 'Ukraine'),
  (IsoCode.FR, 'France'),
  (IsoCode.IT, 'Italy'),
  (IsoCode.ES, 'Spain'),
  (IsoCode.PT, 'Portugal'),
  (IsoCode.NL, 'Netherlands'),
  (IsoCode.BE, 'Belgium'),
  (IsoCode.LU, 'Luxembourg'),
  (IsoCode.CH, 'Switzerland'),
  (IsoCode.LI, 'Liechtenstein'),
  (IsoCode.DK, 'Denmark'),
  (IsoCode.SE, 'Sweden'),
  (IsoCode.NO, 'Norway'),
  (IsoCode.FI, 'Finland'),
  (IsoCode.IS, 'Iceland'),
  (IsoCode.EE, 'Estonia'),
  (IsoCode.LV, 'Latvia'),
  (IsoCode.LT, 'Lithuania'),
  (IsoCode.SI, 'Slovenia'),
  (IsoCode.HR, 'Croatia'),
  (IsoCode.BA, 'Bosnia and Herzegovina'),
  (IsoCode.RS, 'Serbia'),
  (IsoCode.ME, 'Montenegro'),
  (IsoCode.MK, 'North Macedonia'),
  (IsoCode.AL, 'Albania'),
  (IsoCode.XK, 'Kosovo'),
  (IsoCode.RO, 'Romania'),
  (IsoCode.BG, 'Bulgaria'),
  (IsoCode.GR, 'Greece'),
  (IsoCode.CY, 'Cyprus'),
  (IsoCode.MT, 'Malta'),
  (IsoCode.MD, 'Moldova'),
  (IsoCode.BY, 'Belarus'),
  (IsoCode.RU, 'Russia'),
  (IsoCode.TR, 'Turkey'),
  (IsoCode.GE, 'Georgia'),
  (IsoCode.AM, 'Armenia'),
  (IsoCode.AZ, 'Azerbaijan'),
  (IsoCode.KZ, 'Kazakhstan'),
  (IsoCode.IL, 'Israel'),
  (IsoCode.AE, 'United Arab Emirates'),
  (IsoCode.SA, 'Saudi Arabia'),
  (IsoCode.QA, 'Qatar'),
  (IsoCode.EG, 'Egypt'),
  (IsoCode.MA, 'Morocco'),
  (IsoCode.ZA, 'South Africa'),
  (IsoCode.NG, 'Nigeria'),
  (IsoCode.KE, 'Kenya'),
  (IsoCode.US, 'United States'),
  (IsoCode.CA, 'Canada'),
  (IsoCode.MX, 'Mexico'),
  (IsoCode.BR, 'Brazil'),
  (IsoCode.AR, 'Argentina'),
  (IsoCode.CL, 'Chile'),
  (IsoCode.CO, 'Colombia'),
  (IsoCode.PE, 'Peru'),
  (IsoCode.IN, 'India'),
  (IsoCode.PK, 'Pakistan'),
  (IsoCode.BD, 'Bangladesh'),
  (IsoCode.CN, 'China'),
  (IsoCode.HK, 'Hong Kong'),
  (IsoCode.TW, 'Taiwan'),
  (IsoCode.JP, 'Japan'),
  (IsoCode.KR, 'South Korea'),
  (IsoCode.VN, 'Vietnam'),
  (IsoCode.TH, 'Thailand'),
  (IsoCode.MY, 'Malaysia'),
  (IsoCode.SG, 'Singapore'),
  (IsoCode.ID, 'Indonesia'),
  (IsoCode.PH, 'Philippines'),
  (IsoCode.AU, 'Australia'),
  (IsoCode.NZ, 'New Zealand'),
];

String _dial(IsoCode iso) => PhoneNumber(isoCode: iso, nsn: '').countryCode;

/// Regional-indicator flag emoji for an ISO code.
String _flag(IsoCode iso) => iso.name.toUpperCase().runes.map((c) => String.fromCharCode(0x1F1E6 + c - 0x41)).join();

/// The digits as `react-phone-input-2` hands them over: calling code + number, no "+".
bool isValidCheckoutPhone(String digits) {
  final d = digits.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return false;
  try {
    return PhoneNumber.parse('+$d').isValid();
  } catch (_) {
    return false;
  }
}

class CheckoutPhoneField extends StatefulWidget {
  const CheckoutPhoneField({super.key, required this.t, required this.initial, required this.onChanged, this.error});
  final Strings t;

  /// Calling code + number (digits, optionally with "+"), or empty for the United Kingdom.
  final String initial;
  final ValueChanged<String> onChanged;
  final String? error;

  @override
  State<CheckoutPhoneField> createState() => _CheckoutPhoneFieldState();
}

class _CheckoutPhoneFieldState extends State<CheckoutPhoneField> {
  IsoCode _iso = IsoCode.GB;
  final _number = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final raw = widget.initial.replaceAll(RegExp(r'[^\d+]'), '');
    if (raw.isNotEmpty) {
      try {
        final p = PhoneNumber.parse(raw.startsWith('+') ? raw : '+$raw');
        _iso = p.isoCode;
        _number.text = p.nsn;
      } catch (_) {
        _number.text = raw.replaceAll('+', '');
      }
    }
    _focus.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  @override
  void dispose() {
    _number.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged('${_dial(_iso)}${_number.text.replaceAll(RegExp(r'\D'), '')}');

  Future<void> _pickCountry() async {
    final t = widget.t;
    final picked = await showStayHubSheet<IsoCode>(
      context,
      title: t.pick('Krajina', 'Country'),
      fullHeight: true,
      builder: (ctx) => _CountryList(t: t, selected: _iso),
    );
    if (picked != null && mounted) {
      setState(() => _iso = picked);
      _emit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final hasError = widget.error != null;
    final border = hasError ? AppColors.red : (focused ? const Color(0xFF319A7A) : AppColors.neutral300);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
          boxShadow: [
            const BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1)),
            if (focused && !hasError) const BoxShadow(color: Color(0x4D319A7A), spreadRadius: 1),
          ],
        ),
        child: Row(children: [
          InkWell(
            onTap: _pickCountry,
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_flag(_iso), style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Text('+${_dial(_iso)}', style: AppText.inter(size: 14, color: AppColors.neutral900)),
                const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.neutral500),
              ]),
            ),
          ),
          Container(width: 1, height: 24, color: AppColors.neutral200),
          Expanded(
            child: TextField(
              controller: _number,
              focusNode: _focus,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumberNational],
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s\-()]'))],
              onChanged: (_) => _emit(),
              style: AppText.inter(size: 14, color: AppColors.neutral900),
              decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12), isDense: true),
            ),
          ),
        ]),
      ),
      if (hasError) Padding(padding: const EdgeInsets.only(top: 6), child: Text(widget.error!, style: AppText.inter(size: 12, color: AppColors.red))),
    ]);
  }
}

class _CountryList extends StatefulWidget {
  const _CountryList({required this.t, required this.selected});
  final Strings t;
  final IsoCode selected;
  @override
  State<_CountryList> createState() => _CountryListState();
}

class _CountryListState extends State<_CountryList> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final items = [for (final c in _countries) if (q.isEmpty || c.$2.toLowerCase().contains(q) || _dial(c.$1).startsWith(q.replaceAll('+', ''))) c];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: widget.t.pick('Hľadať krajinu', 'Search country'), isDense: true),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (_, i) {
            final (iso, name) = items[i];
            return ListTile(
              dense: true,
              leading: Text(_flag(iso), style: const TextStyle(fontSize: 22)),
              title: Text(name, style: AppText.inter(size: 14, weight: iso == widget.selected ? FontWeight.w700 : FontWeight.w400)),
              trailing: Text('+${_dial(iso)}', style: AppText.inter(size: 14, color: AppColors.neutral500)),
              onTap: () => Navigator.pop(context, iso),
            );
          },
        ),
      ),
    ]);
  }
}
