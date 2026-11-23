import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import 'editor_address.dart';
import 'editor_fields.dart';
import 'editor_steps2.dart';
import 'editor_steps3.dart';

/// Step content for the listing editor (host/listings/editor/EditorSteps.js) and the
/// client-side validation mirror (host/hostEditorValidation.js).

bool _nonEmpty(dynamic v) => v is String && v.trim().isNotEmpty;
bool _positive(dynamic v) => v is num && v.isFinite && v > 0;

/// Inline errors for one step: `{field: message}` in declaration order.
Map<String, String> validateEditorStep(String step, Json data, Strings t) {
  final e = <String, String>{};
  switch (step) {
    case 'basics':
      if (!_nonEmpty(data['name'])) e['name'] = t.pick('Zadajte názov ubytovania.', 'Enter a property name.');
      if (!_nonEmpty(data['propertyType'])) e['propertyType'] = t.pick('Vyberte typ ubytovania.', 'Choose a property type.');
      if (!_nonEmpty(data['description'])) e['description'] = t.pick('Pridajte krátky popis.', 'Add a short description.');
    case 'location':
      if (!_nonEmpty(data['street'])) e['street'] = t.pick('Zadajte ulicu a číslo.', 'Enter the street and number.');
      if (!_nonEmpty(data['city'])) e['city'] = t.pick('Zadajte mesto.', 'Enter the city.');
      if (!_nonEmpty(data['country'])) e['country'] = t.pick('Zadajte krajinu.', 'Enter the country.');
      if (!_nonEmpty(data['phoneNumber'])) e['phoneNumber'] = t.pick('Zadajte kontaktný telefón.', 'Enter a contact phone.');
    case 'spaces':
      for (final f in const ['guests', 'bedrooms', 'beds', 'bathrooms']) {
        if (!_positive(data[f])) e[f] = t.pick('Zadajte aspoň 1.', 'Enter at least 1.');
      }
    case 'amenities':
      if (asStringList(data['amenities']).where((s) => s.trim().isNotEmpty).isEmpty) {
        e['amenities'] = t.pick('Vyberte aspoň jedno vybavenie.', 'Select at least one amenity.');
      }
    case 'photos':
      final ok = asList(data['photoUrls']).any((p) {
        final url = p is String ? p : (p is Map ? asString(p['url']) : '');
        final uri = Uri.tryParse(url.trim());
        return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      });
      if (!ok) e['photoUrls'] = t.pick('Pridajte aspoň jeden odkaz na fotografiu.', 'Add at least one photo link.');
    case 'pricing':
      if (!_positive(data['nightlyPrice'])) e['nightlyPrice'] = t.pick('Zadajte cenu za noc vyššiu ako 0 £.', 'Enter a nightly price above £0.');
      final mn = data['minNights'];
      if (!_positive(mn) || mn is! int && (mn as num) != mn.roundToDouble()) {
        e['minNights'] = t.pick('Minimálny pobyt musí byť celé číslo, aspoň 1 noc.', 'Minimum stay must be a whole number of at least 1 night.');
      }
      validatePricingRows(data, t, e);
    case 'units':
      validateUnits(data, t, e);
    case 'availability':
      if (!_nonEmpty(data['checkIn'])) e['checkIn'] = t.pick('Nastavte čas príchodu.', 'Set a check-in time.');
      if (!_nonEmpty(data['checkOut'])) e['checkOut'] = t.pick('Nastavte čas odchodu.', 'Set a check-out time.');
    case 'calendar':
      final feeds = asList(data['calendarFeeds']);
      for (var i = 0; i < feeds.length; i++) {
        final url = feeds[i] is Map ? asString(asMap(feeds[i])['url']).trim() : '';
        final uri = Uri.tryParse(url);
        if (url.isNotEmpty && !(uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty)) {
          e['calendarFeeds.$i.url'] = t.pick('Zadajte platný http(s) odkaz na kalendár.', 'Enter a valid http(s) calendar link.');
        }
      }
      if (data['availabilityConfirmed'] != true) e['availabilityConfirmed'] = t.pick('Potvrďte, že vaša dostupnosť je aktuálna.', 'Confirm that your availability is up to date.');
    case 'readiness':
      if (data['payoutAcknowledged'] != true) e['payoutAcknowledged'] = t.pick('Potvrďte stav výplat, aby ste dokončili nastavenie.', 'Acknowledge the payout status to finish setup.');
  }
  return e;
}

String _canonical(List<Json> options, dynamic value) {
  final v = asString(value);
  for (final o in options) {
    if (asString(o['en']) == v || asString(o['sk']) == v) return asString(o['en']);
  }
  return v;
}

List<(String, String)> _opts(List<Json> options, String lang) => [for (final o in options) (asString(o['en']), optLabel(o, lang))];

/// Step 1: Basics.
Widget buildBasicsStep({required Json data, required Map<String, String> errors, required Strings t, required Json opts, required void Function(String, dynamic) set}) {
  final types = asMapList(opts['PROPERTY_TYPES']);
  final forms = asMapList(opts['RENTAL_FORMS']);
  Widget text(String key, String label, {String? hint, String? placeholder, int lines = 1, TextInputType? keyboard}) => EditorTextField(
        name: key,
        label: label,
        value: asString(data[key]),
        onChanged: (v) => set(key, v),
        error: errors[key],
        hint: hint,
        placeholder: placeholder,
        lines: lines,
        keyboard: keyboard,
      );
  return EditorStack(children: [
    text('name', t.pick('Názov ubytovania', 'Property name'), placeholder: t.pick('napr. Útulná chata v lese', 'e.g. Cosy Cabin in the Woods')),
    EditorSelect(
      name: 'propertyType',
      label: t.pick('Typ ubytovania', 'Property type'),
      value: _canonical(types, data['propertyType']),
      options: _opts(types, t.lang),
      placeholder: t.pick('Vyberte typ', 'Select type'),
      error: errors['propertyType'],
      onChanged: (v) => set('propertyType', v),
    ),
    EditorSelect(
      name: 'rentalform',
      label: t.pick('Čo si hostia rezervujú', 'What guests book'),
      value: _canonical(forms, data['rentalform']),
      options: _opts(forms, t.lang),
      placeholder: t.pick('Vyberte', 'Select'),
      hint: t.pick('Či dostanú celé miesto alebo izbu v ňom.', 'Whether they get the whole place or a room in it.'),
      onChanged: (v) => set('rentalform', v),
    ),
    text('description', t.pick('Popis', 'Description'),
        lines: 6, placeholder: t.pick('Popíšte svoje miesto...', 'Describe your place...'), hint: t.pick('Čím je miesto výnimočné, pre koho sa hodí a čo je v okolí.', 'What makes the place special, who it suits, and what is nearby.')),
    text('specialNote', t.pick('Čo musia hostia vedieť (voliteľné)', 'Anything guests must know (optional)'),
        lines: 3,
        placeholder: t.pick('napr. v zime strmý prístup, na 3. poschodie nevedie výťah', 'e.g. steep access road in winter, no lift to the 3rd floor'),
        hint: t.pick('Zobrazí sa výrazne v ponuke. Použite ho na veci, ktoré by hosťa pri príchode prekvapili.', 'Shown prominently on the listing. Use it for things that would otherwise surprise someone on arrival.')),
    text('nameEn', t.pick('Názov po anglicky (voliteľné)', 'Name in English (optional)'),
        hint: t.pick('Zobrazí sa na anglickej stránke (ukstayhub.co.uk). Ak ostane prázdne, zobrazí sa slovenský názov.', 'Shown on ukstayhub.co.uk. Leave empty to use the main name.')),
    text('descriptionEn', t.pick('Popis po anglicky (voliteľné)', 'Description in English (optional)'), lines: 6),
    text('specialNoteEn', t.pick('Čo musia hostia vedieť, po anglicky (voliteľné)', 'Anything guests must know, in English (optional)'), lines: 3),
    text('virtualTourUrl', t.pick('Odkaz na virtuálnu prehliadku (voliteľné)', 'Virtual tour link (optional)'), placeholder: 'https://', keyboard: TextInputType.url),
  ]);
}

/// Step 2: Location. (Google address suggestions are not available in the app; every field is a plain input.)
Widget buildLocationStep({required Json data, required Map<String, String> errors, required Strings t, required void Function(String, dynamic) set}) {
  Widget text(String key, String label, {String? hint, String? placeholder, TextInputType? keyboard, Iterable<String>? autofill}) => EditorTextField(
        name: key,
        label: label,
        value: asString(data[key]),
        onChanged: (v) => set(key, v),
        error: errors[key],
        hint: hint,
        placeholder: placeholder,
        keyboard: keyboard,
        autofill: autofill,
      );
  Widget coord(String key, String label) => EditorTextField(
        name: key,
        label: label,
        value: data[key] == null ? '' : asString(data[key]),
        onChanged: (v) {
          final n = double.tryParse(v.trim().replaceAll(',', '.'));
          set(key, v.trim().isEmpty ? null : n);
        },
        keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true),
      );
  return EditorStack(children: [
    AddressSuggestField(data: data, error: errors['street'], t: t, set: set),
    EditorGrid(children: [
      text('city', t.pick('Mesto', 'City'), autofill: const [AutofillHints.addressCity]),
      text('country', t.pick('Krajina', 'Country'), autofill: const [AutofillHints.countryName]),
    ]),
    EditorGrid(children: [
      text('zipCode', t.pick('PSČ', 'Postal code'), autofill: const [AutofillHints.postalCode]),
      text('state', t.pick('Kraj (voliteľné)', 'Region (optional)'), autofill: const [AutofillHints.addressState]),
    ]),
    text('roomNumber', t.pick('Číslo bytu alebo izby (voliteľné)', 'Apartment or room number (optional)'), hint: t.pick('Odosiela sa s adresou po potvrdení rezervácie.', 'Sent with the address after a booking is confirmed.')),
    text('phoneNumber', t.pick('Kontaktný telefón', 'Contact phone'),
        keyboard: TextInputType.phone,
        autofill: const [AutofillHints.telephoneNumber],
        placeholder: '+44 7700 900000',
        hint: t.pick('Slúži na otázky pri príchode a urgentný kontakt k tejto nehnuteľnosti.', 'Used for arrival questions and urgent contact about this property.')),
    // The website fills these from the address suggestion; without it the host can enter them.
    EditorGrid(children: [
      coord('latitude', t.pick('GPS šírka (voliteľné)', 'GPS latitude (optional)')),
      coord('longitude', t.pick('GPS dĺžka (voliteľné)', 'GPS longitude (optional)')),
    ]),
    EditorIntro(t.pick('Presná adresa sa cestovateľom zobrazí až po potvrdenej rezervácii.', 'The exact address is shared with travellers only after a confirmed booking.')),
  ]);
}

/// Step 3: Rooms & Guests.
Widget buildSpacesStep({required Json data, required Map<String, String> errors, required Strings t, required Json opts, required void Function(String, dynamic) set}) {
  Widget stepper(Json f) => EditorNumberStepper(
        name: asString(f['name']),
        label: optLabel(f, t.lang),
        value: data[asString(f['name'])],
        onValueChange: set,
        min: asInt(f['min']),
        error: errors[asString(f['name'])],
      );
  return EditorStack(children: [
    EditorIntro(t.pick('Počítajte len to, čo môžu hostia skutočne používať. Každá hodnota musí byť aspoň 1.', 'Count what guests can actually use. Each value must be at least 1.')),
    EditorGrid(gap: 20, children: [for (final f in asMapList(opts['SPACE_FIELDS'])) stepper(f)]),
    Container(
      padding: const EdgeInsets.only(top: 24),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.pick('Podrobnosti (voliteľné)', 'More detail (optional)'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: AppColors.hostForest)),
        const SizedBox(height: 4),
        Text(t.pick('Čo nemáte, nechajte na 0 — jednoducho sa nezobrazí.', 'Leave anything you do not have at 0 — it simply will not be listed.'), style: AppText.inter(size: 13, color: AppColors.neutral500)),
        const SizedBox(height: 16),
        EditorGrid(gap: 20, children: [for (final f in asMapList(opts['EXTRA_SPACE_FIELDS'])) stepper(f)]),
        const SizedBox(height: 20),
        EditorTextField(
          name: 'acreage',
          label: t.pick('Rozloha (voliteľné)', 'Floor area (optional)'),
          value: asString(data['acreage']),
          onChanged: (v) => set('acreage', v),
          placeholder: t.pick('napr. 85 m²', 'e.g. 85 m²'),
        ),
      ]),
    ),
  ]);
}
