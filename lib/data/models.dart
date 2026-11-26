import '../core/format.dart';
import '../core/json.dart';

/// Thin read-only views over API JSON. Keeping the raw map means a new field
/// on the backend never breaks the app, and nothing has to be code-generated.

class Listing {
  Listing(this.raw);
  final Json raw;

  String get id => asString(raw['_id'] ?? raw['id']);
  String get slug => asString(raw['slug'], id);

  String name(String lang) {
    if (lang == 'en') {
      final en = asString(pick(raw, 'translations.en.name'));
      if (en.isNotEmpty) return en;
    }
    return asString(raw['name']);
  }

  String description(String lang) {
    if (lang == 'en') {
      final en = asString(pick(raw, 'translations.en.description'));
      if (en.isNotEmpty) return en;
    }
    return asString(raw['description']);
  }

  String specialNote(String lang) {
    if (lang == 'en') {
      final en = asString(pick(raw, 'translations.en.specialNote'));
      if (en.isNotEmpty) return en;
    }
    return asString(raw['specialNote']);
  }

  List<String> get images => asStringList(raw['images']);
  String get city => titleCase(asString(pick(raw, 'locationDetails.city')));
  String get district => titleCase(asString(pick(raw, 'locationDetails.district')));
  String get country => asString(pick(raw, 'locationDetails.country'));
  String get address => asString(pick(raw, 'location.address'));
  double? get lat {
    final v = pick(raw, 'location.latitude');
    return v == null ? null : asDouble(v);
  }

  double? get lng {
    final v = pick(raw, 'location.longitude');
    return v == null ? null : asDouble(v);
  }

  bool get hasCoords {
    final a = lat, b = lng;
    return a != null && b != null && a.abs() <= 90 && b.abs() <= 180 && !(a == 0 && b == 0);
  }

  double get pricePerNight => asDouble(raw['pricePerNight']);
  double get pricePerPerson => asDouble(raw['pricePerPerson']);
  double get cleaningFee => asDouble(raw['cleaningFee']);
  double get localTax => asDouble(raw['localTaxPerPersonNight']);
  double get petFeePerNight => asDouble(raw['petFeePerNight']);

  int get person => asInt(raw['person']);
  int get bedroom => asInt(raw['bedroom']);
  int get beds => asInt(raw['beds']);
  int get singleBed => asInt(raw['singlebed']);
  int get doubleBed => asInt(raw['doublebed']);
  int get bunkBed => asInt(raw['bunkbed']);
  int get extraBeds => asInt(raw['extraBeds']);
  int get bathroom => asInt(raw['bathroom']);
  int get wcs => asInt(raw['WCs']);
  int get kitchen => asInt(raw['kitchen']);
  int get livingRoom => asInt(raw['LivingRoom']);
  int get nightMin => asInt(raw['nightMin'], 1).clamp(1, 365);
  int get nightMax {
    final v = asInt(raw['nightMax']);
    return v <= 0 ? 365 : v;
  }

  String propertyType(String lang) {
    final p = raw['propertyType'];
    if (p is Map) {
      final v = asString(p[lang]).isNotEmpty ? asString(p[lang]) : asString(p['name'] ?? p['en'] ?? p['sk']);
      if (v.isNotEmpty) return v;
    }
    return asString(p);
  }

  String rentalForm(String lang) {
    final p = raw['rentalform'];
    if (p is Map) return asString(p[lang] ?? p['en'] ?? p['sk']);
    return asString(p);
  }

  /// Every amenity group the listing page renders, in the site's order.
  static const amenityGroups = [
    'services',
    'bathroomAmenities',
    'kitchenDiningAmenities',
    'heatingCoolingAmenities',
    'safetyAmenities',
    'wellnessAmenities',
    'outdoorAmenities',
    'parkingFacilities',
  ];

  List<String> amenities(String group, String lang) {
    final g = raw[group];
    if (g is Map) return asStringList(g[lang] ?? g['en'] ?? g['sk']);
    return asStringList(g);
  }

  List<String> allAmenities(String lang) => [for (final g in amenityGroups) ...amenities(g, lang)];

  String policyValue(String field, String lang) {
    final v = raw[field];
    if (v is Map) {
      final x = v[lang] ?? v['en'] ?? v['sk'];
      if (x is List) return asStringList(x).join(', ');
      return asString(x);
    }
    if (v is List) return asStringList(v).join(', ');
    return asString(v);
  }

  String get arrivalFrom => asString(raw['arrivalFrom']);
  String get arrivalTo => asString(raw['arrivalTo']);
  String get departureFrom => asString(raw['departureFrom']);
  String get departureTo => asString(raw['departureTo']);
  String get cancellationType => asString(raw['cancellationPolicyType'], 'standard');
  String get cancellationText => asString(raw['cancellationPolicy']);
  String get virtualTourUrl => asString(raw['virtualTourUrl']);

  double get averageRatingStored => asDouble(raw['averageRating']);

  List<Json> get reviewDocs {
    final d = raw['reviewDocs'];
    if (d is List) return asMapList(d);
    return asMapList(raw['reviews']);
  }

  int get reviewCount {
    final rc = raw['reviewCount'];
    if (rc != null) return asInt(rc);
    return asList(raw['reviewDocs'] ?? raw['reviews']).length;
  }

  /// listingRatingFromReviews: mean of overallRating where present, else stored.
  double get rating {
    final docs = reviewDocs.where((r) => r['overallRating'] != null).toList();
    if (docs.isNotEmpty) {
      final sum = docs.fold<double>(0, (a, r) => a + asDouble(r['overallRating']));
      return sum / docs.length;
    }
    final ar = asDouble(raw['reviewRating'] ?? raw['averageReviewRating']);
    if (ar > 0) return ar;
    return averageRatingStored;
  }

  bool get bookable => asBool(raw['bookable']);
  String get bookingMode => asString(raw['bookingMode']);
  bool get isRequestMode => bookingMode == 'request';
  bool get canBook => bookable || isRequestMode;
  bool get isVerified => asBool(raw['isApproved'], true) && asString(raw['status']) != 'DRAFT';

  Json get host => asMap(raw['userId']);
  String get hostId => asString(raw['userId']);

  List<Json> get units => asMapList(raw['units']);
  List<Json> get paidExtras => asMapList(raw['paidExtras']);

  List<DateTime> get excludedDates =>
      asList(raw['excludedDates']).map(asDay).whereType<DateTime>().toList();

  /// Rows that block a night (booked, blocked, live holds).
  List<({DateTime start, DateTime end})> get blockedRanges {
    final out = <({DateTime start, DateTime end})>[];
    for (final row in asMapList(raw['occupancyCalendar'])) {
      final status = asString(row['status'], 'booked');
      if (status == 'available') continue;
      if (status == 'held') {
        final exp = asDate(row['holdExpiresAt']);
        if (exp != null && exp.isBefore(DateTime.now())) continue;
      }
      final s = asDay(row['startDate']);
      final e = asDay(row['endDate']);
      if (s != null && e != null) out.add((start: s, end: e));
    }
    return out;
  }

  /// True when the night starting on [day] cannot be booked. Rows are
  /// inclusive of their end day – the server (calendarHold.occupiedDays) and
  /// the website both count it as taken.
  bool isNightBlocked(DateTime day) {
    final d = dateOnly(day);
    if (excludedDates.any((x) => x == d)) return true;
    for (final r in blockedRanges) {
      if (!d.isBefore(r.start) && !d.isAfter(r.end)) return true;
    }
    return false;
  }
}

class Region {
  Region(this.raw, {this.count = 0});
  final Json raw;
  final int count;
  String get id => asString(raw['id']);
  String name(String lang) => lang == 'en' ? asString(raw['nameEn']) : asString(raw['nameSk']);
  List<String> get cities => asStringList(raw['cities']);
  String get image => asString(raw['image']);
}

/// Where the search is pointed: a single place, a tourism region, or a
/// listing name typed into the search box.
class Destination {
  const Destination._(this.type, this.label, {this.cities = const [], this.regionId});
  const Destination.city(String city) : this._('city', city);
  const Destination.name(String name) : this._('name', name);
  const Destination.region(String label, List<String> cities, String regionId)
      : this._('region', label, cities: cities, regionId: regionId);

  final String type;
  final String label;
  final List<String> cities;
  final String? regionId;

  Json toJson() => {'type': type, 'label': label, 'cities': cities, 'regionId': regionId};

  static Destination? fromJson(Json? j) {
    if (j == null) return null;
    final label = asString(j['label']);
    if (label.isEmpty) return null;
    switch (asString(j['type'])) {
      case 'region':
        return Destination.region(label, asStringList(j['cities']), asString(j['regionId']));
      case 'name':
        return Destination.name(label);
      default:
        return Destination.city(label);
    }
  }
}

class Guests {
  const Guests({this.adults = 0, this.children = 0, this.infants = 0, this.pets = 0});
  final int adults;
  final int children;
  final int infants;
  final int pets;

  int get total => adults + children + infants;
  int get paying => adults + children;

  Guests copyWith({int? adults, int? children, int? infants, int? pets}) => Guests(
        adults: adults ?? this.adults,
        children: children ?? this.children,
        infants: infants ?? this.infants,
        pets: pets ?? this.pets,
      );
}

class Quote {
  Quote(this.raw);
  final Json raw;
  double get total => asDouble(raw['total']);
  int get totalCents => asInt(raw['totalCents']);
  Json get breakdown => asMap(raw['breakdown']);
}

class GuestReservation {
  GuestReservation(this.raw);
  final Json raw;
  String get id => asString(raw['_id'] ?? raw['id']);
  Json get accommodation => asMap(raw['accommodationId']);
  String get accommodationId => asString(raw['accommodationId']);
  Listing get listing => Listing(accommodation);
  DateTime? get checkIn => asDay(raw['checkInDate']);
  DateTime? get checkOut => asDay(raw['checkOutDate']);
  int get persons => asInt(raw['numberOfPersons'], 1);
  double get total {
    final c = raw['totalPriceCents'];
    if (c != null && asInt(c) > 0) return asInt(c) / 100;
    return asDouble(raw['totalPrice']);
  }

  String get approval => asString(raw['isApproved'], 'pending');
  String get paymentStatus => asString(raw['paymentStatus']);
  bool get cancelled => approval == 'cancelled' || asString(raw['status']) == 'cancelled' || raw['cancelledAt'] != null;
  bool get isPast => checkOut != null && checkOut!.isBefore(DateTime.now());
  /// Settled payment – a receipt exists only then.
  bool get paid => paymentStatus == 'paid' || paymentStatus == 'partially_refunded';
  /// Host accepted a request; the guest still has to pay the emailed link.
  bool get awaitingPayment => !cancelled && !paid && approval == 'approved' && asString(raw['bookingMode']) == 'request';
}
