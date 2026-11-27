import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/json.dart';
import '../core/storage.dart';
import '../data/models.dart';

/// Filters from the map page's TabFilters, keyed by the exact query names
/// the /accommodations/searching endpoint reads.
class SearchFilters {
  const SearchFilters({
    this.minPrice,
    this.maxPrice,
    this.propertyType = '',
    this.rentalForm = '',
    this.beds = 0,
    this.bedrooms = 0,
    this.bathrooms = 0,
    this.multi = const {},
    this.sort = '',
  });

  final double? minPrice;
  final double? maxPrice;
  /// Comma-separated PROPERTY_TYPES `en` values (the site's `drop`, an array).
  final String propertyType;

  /// RENTAL_FORMS `en` value ("Type of place"), sent as `rentalform`.
  final String rentalForm;
  final int beds;
  final int bedrooms;
  final int bathrooms;

  /// query key -> selected values (services, wellnessAmenities, pet, …).
  final Map<String, Set<String>> multi;
  final String sort; // '' | lowToHigh | highToLow

  Set<String> get propertyTypes => propertyType.split(',').where((e) => e.isNotEmpty).toSet();

  /// TabFilters.activeFilterCount: rooms count once; type of place is not counted.
  int get activeCount =>
      (minPrice != null || maxPrice != null ? 1 : 0) +
      (propertyType.isNotEmpty ? 1 : 0) +
      (beds > 0 || bedrooms > 0 || bathrooms > 0 ? 1 : 0) +
      multi.values.where((v) => v.isNotEmpty).length;

  SearchFilters copyWith({
    double? minPrice,
    double? maxPrice,
    bool clearPrice = false,
    String? propertyType,
    String? rentalForm,
    int? beds,
    int? bedrooms,
    int? bathrooms,
    Map<String, Set<String>>? multi,
    String? sort,
  }) =>
      SearchFilters(
        minPrice: clearPrice ? null : (minPrice ?? this.minPrice),
        maxPrice: clearPrice ? null : (maxPrice ?? this.maxPrice),
        propertyType: propertyType ?? this.propertyType,
        rentalForm: rentalForm ?? this.rentalForm,
        beds: beds ?? this.beds,
        bedrooms: bedrooms ?? this.bedrooms,
        bathrooms: bathrooms ?? this.bathrooms,
        multi: multi ?? this.multi,
        sort: sort ?? this.sort,
      );
}

class SearchState {
  const SearchState({
    this.destination,
    this.checkIn,
    this.checkOut,
    this.guests = const Guests(),
    this.filters = const SearchFilters(),
  });

  final Destination? destination;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final Guests guests;
  final SearchFilters filters;

  bool get hasDates => checkIn != null && checkOut != null;

  SearchState copyWith({
    Destination? destination,
    bool clearDestination = false,
    DateTime? checkIn,
    DateTime? checkOut,
    bool clearDates = false,
    Guests? guests,
    SearchFilters? filters,
  }) =>
      SearchState(
        destination: clearDestination ? null : (destination ?? this.destination),
        checkIn: clearDates ? null : (checkIn ?? this.checkIn),
        checkOut: clearDates ? null : (checkOut ?? this.checkOut),
        guests: guests ?? this.guests,
        filters: filters ?? this.filters,
      );

  /// The query the website's SectionGridHasMap builds (commonParameters).
  Map<String, dynamic> toQuery() {
    final q = <String, dynamic>{};
    final d = destination;
    if (d != null) {
      switch (d.type) {
        case 'region':
          q['cities'] = jsonEncode(d.cities);
          break;
        case 'name':
          q['name'] = d.label;
          break;
        case 'place':
          q['lat'] = d.lat;
          q['lng'] = d.lng;
          q['radiusKm'] = 3;
          break;
        default:
          q['city'] = d.label;
      }
    }
    if (hasDates) {
      q['startDate'] = isoDay(checkIn!);
      q['endDate'] = isoDay(checkOut!);
    }
    if (guests.total > 0) q['person'] = guests.total;
    final f = filters;
    if (f.minPrice != null) q['minPrice'] = f.minPrice!.round();
    if (f.maxPrice != null) q['maxPrice'] = f.maxPrice!.round();
    if (f.propertyType.isNotEmpty) {
      q['propertyType'] = f.propertyType;
      q['category'] = f.propertyType;
    }
    if (f.rentalForm.isNotEmpty) q['rentalform'] = f.rentalForm;
    if (f.beds > 0) q['beds'] = f.beds;
    if (f.bedrooms > 0) q['bedroomCount'] = f.bedrooms;
    if (f.bathrooms > 0) q['bathroomCount'] = f.bathrooms;
    f.multi.forEach((k, v) {
      if (v.isNotEmpty) q[k] = v.join(',');
    });
    return q;
  }
}

class SearchNotifier extends Notifier<SearchState> {
  @override
  SearchState build() {
    final raw = Prefs.lastSearch;
    if (raw != null) {
      try {
        final j = asMap(jsonDecode(raw));
        final ci = parseDay(asString(j['checkIn']));
        final co = parseDay(asString(j['checkOut']));
        final today = dateOnly(DateTime.now());
        final validDates = ci != null && co != null && !ci.isBefore(today);
        return SearchState(
          destination: Destination.fromJson(asMap(j['destination'])),
          checkIn: validDates ? ci : null,
          checkOut: validDates ? co : null,
          guests: Guests(
            adults: asInt(j['adults']),
            children: asInt(j['children']),
            infants: asInt(j['infants']),
          ),
        );
      } catch (_) {}
    }
    return const SearchState();
  }

  void setDestination(Destination? d) => _set(d == null ? state.copyWith(clearDestination: true) : state.copyWith(destination: d));

  /// A null [b] clears the check-out (picking a new start in the calendar).
  void setDates(DateTime? a, DateTime? b) =>
      _set(a == null ? state.copyWith(clearDates: true) : state.copyWith(clearDates: true).copyWith(checkIn: a, checkOut: b));

  void setGuests(Guests g) => _set(state.copyWith(guests: g));

  void setFilters(SearchFilters f) => state = state.copyWith(filters: f);

  void clearAll() => _set(const SearchState());

  void _set(SearchState s) {
    state = s;
    Prefs.setLastSearch(jsonEncode({
      'destination': s.destination?.toJson(),
      'checkIn': s.checkIn == null ? null : isoDay(s.checkIn!),
      'checkOut': s.checkOut == null ? null : isoDay(s.checkOut!),
      'adults': s.guests.adults,
      'children': s.guests.children,
      'infants': s.guests.infants,
    }));
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);
