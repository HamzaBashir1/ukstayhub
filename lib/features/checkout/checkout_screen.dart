import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../state/search.dart';
import '../../widgets/chrome.dart' show StayHubDrawer, StayHubFooter, StayHubHeader;
import '../../widgets/common.dart';
import '../../widgets/search_form.dart';
import '../../widgets/sticky_sidebar.dart';
import '../search/search_screen.dart' show FooterNav, MobileSearchHeader;
import 'payment_webview.dart';
import 'phone_field.dart';

const _forest = AppColors.forestListing; // #1e4636
const _green = AppColors.greenListing; // #319a7a
const _cta = Color(0xFF357965);
const _maxPets = 10;

/// Everything the listing page hands to checkout (website: localStorage userData).
class BookingDraft {
  const BookingDraft({
    required this.listing,
    required this.checkIn,
    required this.checkOut,
    required this.guests,
    this.unitId,
    this.withPet = false,
    this.extras = const [],
    this.quote,
  });
  final Listing listing;
  final DateTime checkIn;
  final DateTime checkOut;
  final Guests guests;
  final String? unitId;
  final bool withPet;
  final List<String> extras;
  final Quote? quote;
}

/// Checkout/page.js — `container flex flex-col-reverse lg:flex-row`: the booking
/// summary sits above the form on phones and beside it (sticky) from lg.
class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key, required this.draft});
  final BookingDraft draft;
  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();
  final _rowKey = GlobalKey();
  final Map<String, String?> _errors = {};

  late DateTime _checkIn = d.checkIn;
  late DateTime _checkOut = d.checkOut;
  late Guests _guests = d.guests;
  late final List<String> _extras = [...d.extras];
  late int _pets = d.withPet ? 1 : 0;
  String _petType = '';
  String _phone = '';
  String _initialPhone = '';
  bool _submitting = false;
  bool _quoting = false;
  Quote? _quote;
  String? _quoteError;
  Timer? _debounce;

  BookingDraft get d => widget.draft;
  Listing get l => d.listing;
  bool get _withPet => _pets > 0;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    if (auth.loggedIn && !auth.isHost) {
      _name.text = [asString(auth.user?['name']), asString(auth.user?['lastName'])].where((e) => e.isNotEmpty).join(' ');
      _email.text = auth.email;
      _initialPhone = asString(auth.user?['phoneNumber'] ?? auth.user?['phone']);
    }
    _quote = d.quote;
    _refreshQuote();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _email.dispose();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Always re-price on the server: the total shown is what Stripe charges.
  void _requote({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      _refreshQuote();
    } else {
      _debounce = Timer(const Duration(milliseconds: 250), _refreshQuote);
    }
  }

  Future<void> _refreshQuote() async {
    if (!_checkOut.isAfter(_checkIn) || _guests.adults < 1) return;
    setState(() => _quoting = true);
    try {
      final q = await bookingRepo.quote(
        accommodationId: l.id,
        checkIn: _checkIn,
        checkOut: _checkOut,
        adults: _guests.adults,
        children: _guests.children,
        withPet: _withPet,
        extras: _extras,
        unitId: d.unitId,
      );
      if (mounted) {
        setState(() {
          _quote = q;
          _quoteError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _quoteError = errorText(e));
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  bool _rangeBlocked(DateTime a, DateTime b) {
    for (var x = a; x.isBefore(b); x = x.add(const Duration(days: 1))) {
      if (l.isNightBlocked(x)) return true;
    }
    return false;
  }

  Future<void> _pickDates() async {
    final t = ref.read(stringsProvider);
    await showStayHubSheet(
      context,
      title: t('CheckinCheckout', 'Príchod - Odchod'),
      fullHeight: true,
      builder: (_) => DatesSheetBody(
        initialStart: _checkIn,
        initialEnd: _checkOut,
        listing: l,
        onSave: (a, b) {
          if (a == null || b == null) return;
          setState(() {
            _checkIn = a;
            _checkOut = b;
          });
          ref.read(searchProvider.notifier).setDates(a, b);
          _requote(immediate: true);
        },
      ),
    );
  }

  Future<void> _pickGuests() async {
    await openGuestsSheet(
      context,
      ref,
      max: l.person,
      initial: _guests,
      onSave: (g) {
        setState(() => _guests = g.adults < 1 ? g.copyWith(adults: 1) : g);
        ref.read(searchProvider.notifier).setGuests(_guests);
        _requote(immediate: true);
      },
    );
  }

  bool _validate(Strings t) {
    _errors.clear();
    void fail(String msg) {
      toast(context, msg, error: true);
    }

    final n = nightsBetween(_checkIn, _checkOut);
    if (!_checkIn.isBefore(_checkOut)) {
      fail(t('Checkindatemustbebeforecheckoutdate', 'Dátum príchodu musí byť pred dátumom odchodu.'));
      return false;
    }
    if (n < l.nightMin || n > l.nightMax) {
      fail('${t('Thisofferrequiresaminimumstayof', 'Minimálna dĺžka pobytu je')} ${l.nightMin} ${t('nights', 'nocí')}.');
      return false;
    }
    if (l.person > 0 && _guests.total > l.person) {
      fail('${t('MaxGuestsReached', 'Maximálny počet hostí je')} ${l.person}.');
      return false;
    }
    if (_rangeBlocked(_checkIn, _checkOut)) {
      fail(t('PleaseselectdifferentdatesSomedatesareunavailable', 'Niektoré dni nie sú dostupné.'));
      return false;
    }
    if (_withPet && _petType.isEmpty) {
      fail(t('PleaseSelectPetType', 'Vyberte typ zvieraťa'));
      setState(() => _errors['pet'] = t('PleaseSelectPetType', 'Vyberte typ zvieraťa'));
      return false;
    }
    final required = t('Pleasefillinallrequiredfieldscorrectly', 'Vyplňte prosím všetky povinné polia.');
    if (_name.text.trim().isEmpty) _errors['name'] = required;
    final email = _email.text.trim();
    if (email.isEmpty) {
      _errors['email'] = required;
    } else if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      _errors['email'] = t('subscribe_error', 'Neplatný e-mail');
    }
    final digits = _phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      _errors['phone'] = required;
    } else if (!isValidCheckoutPhone(digits)) {
      _errors['phone'] = t('InvalidPhoneNumber', 'Zadajte platné telefónne číslo');
    }
    setState(() {});
    final first = ['name', 'email', 'phone'].map((k) => _errors[k]).whereType<String>().toList();
    if (first.isNotEmpty) toast(context, first.first, error: true);
    return first.isEmpty;
  }

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (_submitting || !_validate(t)) return;
    setState(() => _submitting = true);
    try {
      final payload = <String, dynamic>{
        'checkInDate': isoDay(_checkIn),
        'checkOutDate': isoDay(_checkOut),
        'numberOfPersons': _guests.total,
        'guests': {'adults': _guests.adults, 'children': _guests.children},
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        'phone': _phone.replaceAll(RegExp(r'\D'), ''),
        'message': _message.text.trim(),
        'accommodationProvider': l.hostId.isNotEmpty ? l.hostId : asString(l.host['_id']),
        'accommodationId': l.id,
        'language': t.lang,
        'isApproved': 'pending',
        'withPet': _withPet,
        'petType': _withPet ? _petType : '',
        'numberOfPets': _pets,
        'extras': _extras,
        if (d.unitId != null) 'unitId': d.unitId,
      };
      final r = await bookingRepo.createReservation(payload);
      final id = asString(r['_id']);
      if (id.isEmpty) throw Exception(t('Failedtosendreservation', 'Rezerváciu sa nepodarilo odoslať.'));
      if (!mounted) return;

      if (asString(r['bookingMode']) == 'request') {
        context.pushReplacement('/request-sent?reservationId=$id');
        return;
      }
      final url = await bookingRepo.checkoutUrl(id, t.lang);
      if (!mounted) return;
      if (url.isEmpty) throw Exception(t('Failedtocreatepayment', 'Platbu sa nepodarilo vytvoriť.'));
      final result = await Navigator.of(context).push<PaymentResult>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaymentWebView(url: url),
      ));
      if (!mounted) return;
      switch (result?.status) {
        case PaymentStatus.success:
          context.pushReplacement('/payment-success?session_id=${Uri.encodeComponent(result!.sessionId ?? '')}&reservationId=$id');
        case PaymentStatus.cancelled:
        case null:
          // Releases the calendar hold, same as the site's cancel page.
          bookingRepo.cancelPending(id).catchError((_) {});
          context.pushReplacement('/payment-cancel');
      }
    } catch (e) {
      if (mounted) {
        toast(context, e is Exception ? errorText(e) : t('TherewasanerrorsendingyourreservationPleasetryagainlater', 'Chyba pri odosielaní.'), error: true);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ───────────────────────────── sidebar (renderSidebar) ─────────────────────────────
  Widget _sidebar(Strings t, {required bool lg, required bool xl, required bool sm}) {
    final n = nightsBetween(_checkIn, _checkOut);
    final q = _quote;
    final bd = q?.breakdown ?? const <String, dynamic>{};
    double c(String k) => asInt(bd[k]) / 100;
    final nightsLabel = n == 1 ? t('night', 'noc') : t('nights', 'nocí');
    final img = l.images.isEmpty ? '' : l.images.first;
    final unitName = d.unitId == null ? '' : asString(l.units.where((u) => asString(u['_id']) == d.unitId).firstOrNull?['name']);
    final accommodation = c('accommodationCents') > 0 || bd['accommodationCents'] != null ? c('accommodationCents') : c('subtotalCents');
    final nightly = n > 0 ? double.parse((accommodation / n).toStringAsFixed(2)) : 0.0;
    final payingGuests = _guests.adults + _guests.children;

    Widget line(String a, String b, {Color? color, bool strong = true}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(a, style: AppText.inter(size: 14, color: color ?? AppColors.neutral600, height: 1.43))),
            const SizedBox(width: 16),
            Text(b, style: AppText.inter(size: 14, weight: FontWeight.w600, color: color ?? AppColors.neutral800)),
          ]),
        );

    Widget heading(String text, {double size = 18}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: AppText.fraunces(size: size, color: _forest, letterSpacing: -0.4)),
          const SizedBox(height: 6),
          Container(width: 48, height: 3, decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(3))),
        ]);

    final banner = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xB3ECFDF5), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFD1FAE5))),
      child: Row(children: [
        Container(width: 36, height: 36, decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.check_circle_outline, size: 20, color: Color(0xFF059669))),
        const SizedBox(width: 12),
        Expanded(child: Text(t('GoodnewsThisaccommodationisavailable', 'Dobrá správa! Toto ubytovanie je dostupné'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF047857), height: 1.43))),
      ]),
    );

    final kicker = [
      [l.propertyType(t.lang), l.rentalForm(t.lang)].where((s) => s.isNotEmpty).join(' '),
      [l.city, l.country].where((s) => s.isNotEmpty).join(', '),
    ].where((s) => s.isNotEmpty).join(' · ');
    final photo = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: sm ? 96 : double.infinity,
        height: sm ? 96 : 160,
        decoration: BoxDecoration(border: Border.all(color: const Color(0x99E5E5E5)), borderRadius: BorderRadius.circular(12)),
        child: img.isEmpty ? const ColoredBox(color: AppColors.neutral100) : NetImage(cloudinary(img, width: 400), cacheWidth: 400),
      ),
    );
    final propertyText = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(kicker.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 10, weight: FontWeight.w700, color: const Color(0xFF237A59), letterSpacing: 1.5)),
      const SizedBox(height: 4),
      Text('${l.name(t.lang)}${unitName.isNotEmpty ? ' · $unitName' : ''}', style: AppText.inter(size: 16, weight: FontWeight.w700, color: AppColors.neutral900, height: 1.35)),
      const SizedBox(height: 6),
      Text('${l.beds} ${t('beds', 'postele')} · ${l.bathroom} ${t('baths', 'kúpeľne')}', style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral500)),
      const SizedBox(height: 8),
      Container(width: 40, height: 3, decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(3))),
    ]);
    final property = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xB3FAFAFA), borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral100)),
      child: sm
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [photo, const SizedBox(width: 16), Expanded(child: propertyText)])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [photo, const SizedBox(height: 16), propertyText]),
    );

    final priceBox = Container(
      padding: EdgeInsets.all(sm ? 20 : 16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral100), boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 1, offset: Offset(0, 1))]),
      child: _quoteError != null
          ? Text(_quoteError!, style: AppText.inter(size: 14, color: AppColors.red))
          : q == null
              ? const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(color: _green)))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  line('${money(nightly, decimals: true)} × $n $nightsLabel', money(accommodation, decimals: true)),
                  if (asInt(bd['discountCents']) > 0) line(t.pick('Zľava', 'Discount'), '−${money(c('discountCents'), decimals: true)}', color: const Color(0xFF237A59)),
                  if (asInt(bd['petFeeCents']) > 0) line('${t('PetFee', 'Poplatok za zviera')} · ${money(l.petFeePerNight, decimals: true)} × $n $nightsLabel', money(c('petFeeCents'), decimals: true)),
                  if (asInt(bd['cleaningFeeCents']) > 0) line(t('CleaningFee', 'Poplatok za upratovanie'), money(c('cleaningFeeCents'), decimals: true)),
                  if (asInt(bd['localTaxCents']) > 0)
                    line('${t('LocalTax', 'Miestny poplatok')} · ${money(l.localTax, decimals: true)} × $payingGuests ${t('guests', 'hostia').toLowerCase()} × $n $nightsLabel', money(c('localTaxCents'), decimals: true)),
                  if (asInt(bd['extrasCents']) > 0) line(t.pick('Služby navyše', 'Extras'), money(c('extrasCents'), decimals: true)),
                  line(t('Servicecharge', 'Servisný poplatok'), '£0'),
                  const Divider(height: 1, color: AppColors.neutral100),
                  const SizedBox(height: 14),
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Expanded(child: Text(t('Total', 'Spolu'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: AppColors.neutral900))),
                    Text(money(q.total, decimals: true), style: AppText.inter(size: 20, weight: FontWeight.w800, color: _forest)),
                  ]),
                ]),
    );

    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      banner,
      const SizedBox(height: 24),
      property,
      const SizedBox(height: 24),
      heading(t('Pricedetail', 'Detaily ceny'), size: sm ? 20 : 18),
      const SizedBox(height: 16),
      AnimatedOpacity(opacity: _quoting ? 0.5 : 1, duration: const Duration(milliseconds: 150), child: priceBox),
    ]);
    if (!lg) return body;
    return Container(
      padding: EdgeInsets.all(xl ? 32 : 28),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xCCE5E5E5)), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
      child: body,
    );
  }

  // ───────────────────────────── main (renderMain) ─────────────────────────────
  Widget _main(Strings t, {required bool sm, required bool lg, required bool xl}) {
    final pet = l.policyValue('pet', 'en');
    final petsAllowed = pet.isNotEmpty && pet != 'Not Allowed';
    final fs = sm ? 20.0 : 18.0;

    Widget heading(String text, {double top = 0}) => Padding(
          padding: EdgeInsets.only(top: top, bottom: 16),
          child: Text(text, style: AppText.fraunces(size: fs, color: _forest, letterSpacing: -0.4)),
        );

    Widget tripCell(String label, String value, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(sm ? 20 : 16),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label.toUpperCase(), style: AppText.inter(size: 10, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 1)),
                  const SizedBox(height: 4),
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: sm ? 18 : 16, weight: FontWeight.w700, color: AppColors.neutral900)),
                ]),
              ),
              const SizedBox(width: 16),
              Container(width: 32, height: 32, decoration: BoxDecoration(color: const Color(0x0D319A7A), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.edit_outlined, size: 16, color: _green)),
            ]),
          ),
        );
    final dateCell = tripCell(t('date', 'Dátum'), rangeLabel(_checkIn, _checkOut, t.lang), _pickDates);
    final guestCell = tripCell(t('guests', 'Hostia'), '${_guests.adults + _guests.children} ${t('Guests', 'Hostia')}, ${_guests.infants} ${t('Infants', 'Dojčatá')}', _pickGuests);
    const div = AppColors.neutral200;
    final trip = Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: div), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 1, offset: Offset(0, 1))]),
      clipBehavior: Clip.antiAlias,
      child: sm
          ? IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: dateCell), const VerticalDivider(width: 1, color: div), Expanded(child: guestCell)]))
          : Column(children: [dateCell, const Divider(height: 1, color: div), guestCell]),
    );

    Widget roundBtn(String glyph, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Opacity(
            opacity: onTap == null ? 0.4 : 1,
            child: Container(width: 36, height: 36, alignment: Alignment.center, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.neutral300)), child: Text(glyph, style: AppText.inter(size: 18, weight: FontWeight.w600, color: AppColors.neutral700))),
          ),
        );

    final petSection = !petsAllowed
        ? const <Widget>[]
        : [
            Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.only(top: 8), decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100)))),
            heading(t('HowManyPets', 'Cestujete so zvieratkom?'), top: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t('NumberOfPets', 'Počet zvierat'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral800)),
                    Text(t('PetCountNoPriceChange', 'Počet zvierat nemení cenu'), style: AppText.inter(size: 12, color: AppColors.neutral500)),
                  ]),
                ),
                const SizedBox(width: 16),
                roundBtn('−', _pets <= 0
                    ? null
                    : () {
                        setState(() {
                          _pets = (_pets - 1).clamp(0, _maxPets);
                          if (_pets == 0) _petType = '';
                        });
                        _requote();
                      }),
                SizedBox(width: 36, child: Text('$_pets', textAlign: TextAlign.center, style: AppText.inter(size: 16, weight: FontWeight.w700, color: AppColors.neutral900))),
                roundBtn('+', _pets >= _maxPets
                    ? null
                    : () {
                        setState(() => _pets = (_pets + 1).clamp(0, _maxPets));
                        _requote();
                      }),
              ]),
            ),
            if (l.petFeePerNight > 0)
              Padding(padding: const EdgeInsets.only(top: 20), child: Text('${t('PetFee', 'Poplatok za zviera')}: £${_n(l.petFeePerNight)}/${t('night', 'noc')}', style: AppText.inter(size: 14, color: AppColors.neutral500))),
            if (_withPet) ...[
              const SizedBox(height: 20),
              FieldLabel(t('PetType', 'Typ zvieraťa'), required: true),
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: _errors['pet'] != null ? AppColors.red : AppColors.neutral300), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _petType.isEmpty ? '' : _petType,
                    isExpanded: true,
                    style: AppText.inter(size: 14, color: AppColors.neutral900),
                    items: [
                      DropdownMenuItem(value: '', child: Text(t('SelectPetType', 'Vyberte typ zvieraťa'))),
                      DropdownMenuItem(value: 'dog', child: Text(t('PetDog', 'Pes'))),
                      DropdownMenuItem(value: 'cat', child: Text(t('PetCat', 'Mačka'))),
                      DropdownMenuItem(value: 'other', child: Text(t('PetOther', 'Iné'))),
                    ],
                    onChanged: (v) => setState(() {
                      _petType = v ?? '';
                      _errors.remove('pet');
                    }),
                  ),
                ),
              ),
            ],
          ];

    final extras = l.paidExtras;
    final extrasSection = extras.isEmpty
        ? const <Widget>[]
        : [
            const SizedBox(height: 8),
            Text(t.pick('Voliteľné doplnky', 'Optional extras'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            const SizedBox(height: 8),
            for (final e in extras)
              Builder(builder: (_) {
                final key = asString(pick(e, 'amenity.en'));
                final on = _extras.contains(key);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      setState(() => on ? _extras.remove(key) : _extras.add(key));
                      _requote();
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
                      child: Row(children: [
                        Icon(on ? Icons.check_box : Icons.check_box_outline_blank, size: 22, color: on ? _green : AppColors.neutral400),
                        const SizedBox(width: 12),
                        Expanded(child: Text(asString(pick(e, 'amenity.${t.lang}'), key), style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral800))),
                        Text('${money(asDouble(e['price']))}${asString(e['pricing']) == 'per_night' ? '/${t('night', 'noc')}' : ''}', style: AppText.inter(size: 14, color: AppColors.neutral500)),
                      ]),
                    ),
                  ),
                );
              }),
          ];

    final label = _submitting
        ? t('Processing', 'Spracúvam…')
        : l.isRequestMode
            ? t('SendBookingRequest', 'Odoslať žiadosť o rezerváciu')
            : t('ProceedToPayment', 'Pokračovať k platbe');

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t('confirmAndPayment', 'Potvrdenie a platba'), style: AppText.fraunces(size: lg ? 36 : (sm ? 30 : 24), color: _forest, letterSpacing: -0.8, height: 1.15)),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerLeft, child: Container(width: 48, height: 3, decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(3)))),
      const SizedBox(height: 28),
      Text(t('yourTrip', 'Váš pobyt'), style: AppText.fraunces(size: fs, color: _forest, letterSpacing: -0.4)),
      const SizedBox(height: 16),
      trip,
      const SizedBox(height: 28),
      ...petSection,
      ...extrasSection,
      const SizedBox(height: 8),
      Container(padding: const EdgeInsets.only(top: 8), decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100)))),
      heading(t('Contactdetails', 'Kontaktné údaje'), top: 16),
      StayHubField(
        label: t('name', 'Meno'),
        controller: _name,
        required: true,
        hint: t('enterYourName', 'Zadajte vaše meno'),
        autofill: const [AutofillHints.name],
        errorText: _errors['name'],
        onChanged: (_) => setState(() => _errors.remove('name')),
      ),
      const SizedBox(height: 20),
      StayHubField(
        label: t('email', 'E-mail'),
        controller: _email,
        required: true,
        hint: t('input_placeholder', 'priklad@priklad.com'),
        keyboard: TextInputType.emailAddress,
        autofill: const [AutofillHints.email],
        errorText: _errors['email'],
        onChanged: (_) => setState(() => _errors.remove('email')),
      ),
      const SizedBox(height: 20),
      FieldLabel(t('phoneNumber', 'Telefónne číslo'), required: true),
      CheckoutPhoneField(
        t: t,
        initial: _initialPhone,
        error: _errors['phone'],
        onChanged: (v) {
          _phone = v;
          if (_errors.containsKey('phone')) setState(() => _errors.remove('phone'));
        },
      ),
      const SizedBox(height: 20),
      StayHubField(label: t('messageForAuthor', 'Správa pre hostiteľa'), controller: _message, maxLines: 4, hint: t('Writeyourmessagehere', 'Napíšte svoju správu')),
      const SizedBox(height: 32),
      Opacity(
        opacity: _submitting || _quoteError != null ? 0.6 : 1,
        child: Material(
          color: _cta,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: _submitting || _quoteError != null ? null : _submit,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: _submitting
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)),
                      const SizedBox(width: 10),
                      Text(label, style: AppText.inter(size: sm ? 16 : 14, weight: FontWeight.w500, color: Colors.white)),
                    ])
                  : Text(label, style: AppText.inter(size: sm ? 16 : 14, weight: FontWeight.w500, color: Colors.white)),
            ),
          ),
        ),
      ),
    ]);
    if (!sm) return content;
    return Container(
      padding: EdgeInsets.all(xl ? 32 : 24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xCCE5E5E5)), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
      child: content,
    );
  }

  static String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final w = MediaQuery.sizeOf(context).width;
    final sm = w >= 640, lg = w >= 1024, xl = w >= 1280;

    final main = _main(t, sm: sm, lg: lg, xl: xl);
    final side = _sidebar(t, lg: lg, xl: xl, sm: sm);

    // `container`: w-[1440px] max-w-full px-5.
    final page = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1440),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, lg ? 128 : 96),
          child: lg
              ? Row(key: _rowKey, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: xl ? 55 : 60, child: main),
                  Expanded(flex: xl ? 45 : 40, child: Padding(padding: const EdgeInsets.only(left: 32), child: StickySidebar(scroll: _scroll, rowKey: _rowKey, child: side))),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [side, const SizedBox(height: 24), main]),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: lg ? const StayHubHeader(background: Colors.white) : null,
      endDrawer: const StayHubDrawer(),
      bottomNavigationBar: lg ? null : const FooterNav(),
      body: CustomScrollView(controller: _scroll, slivers: [
        if (!lg)
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppColors.neutral100))),
              child: const SafeArea(bottom: false, child: Padding(padding: EdgeInsets.symmetric(vertical: 14), child: MobileSearchHeader())),
            ),
          ),
        SliverToBoxAdapter(child: page),
        const SliverToBoxAdapter(child: StayHubFooter()),
      ]),
    );
  }
}
