import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/format.dart';
import '../core/json.dart';
import '../core/storage.dart';
import 'models.dart';

/// Every call the app makes, grouped like the website's API usage. All routes
/// are the existing Express routes – the backend needs no changes.

// ───────────────────────────── Public (no login) ─────────────────────────────
class PublicRepo {
  static const _short = Duration(minutes: 5);
  static const _long = Duration(minutes: 30);

  Future<Json> listingStats() async => asMap(await api.get('/accommodation/listing-stats', cache: _long));

  Future<List<Listing>> recommended() async =>
      _listings(await api.get('/accommodation/recommended', cache: _short));

  Future<List<Listing>> latest() async => _listings(await api.get('/accommodation/latest', cache: _short));

  Future<List<Json>> destinations() async =>
      asMapList(asMap(await api.get('/destinations', cache: _long))['destinations']);

  Future<Listing> listingBySlug(String slug) async =>
      Listing(asMap(await api.get('/accommodation/slug/${Uri.encodeComponent(slug)}', cache: const Duration(minutes: 1))));

  /// The small card the /mapa map opens from a pin (`?fields=mapCard`).
  Future<Listing> mapCard(String id) async =>
      Listing(asMap(await api.get('/accommodation/${Uri.encodeComponent(id)}', query: {'fields': 'mapCard'}, cache: const Duration(minutes: 1))));

  Future<Listing> listingById(String id) async =>
      Listing(asMap(await api.get('/accommodation/${Uri.encodeComponent(id)}', cache: const Duration(minutes: 1))));

  Future<List<Json>> reviews(String accommodationId) async =>
      asMapList(asMap(await api.get('/reviews/$accommodationId', cache: _short))['data']);

  Future<void> submitReview(String accommodationId, Json body) => api.post('/reviews/$accommodationId', body: body);

  Future<Json> cancellationPolicy(String accommodationId) async =>
      asMap(await api.get('/cancellation/policy/$accommodationId', cache: _long));

  Future<Json> host(String id) async => asMap(await api.get('/hosts/$id', cache: _short));

  // The API answers 404 for a host with no listings; the site shows an empty list.
  Future<List<Listing>> hostListings(String hostId) async {
    try {
      return _listings(await api.get('/accommodation/user/$hostId', cache: _short));
    } on ApiException catch (e) {
      if (e.status == 404) return const [];
      rethrow;
    }
  }

  Future<List<Json>> nameSuggestions(String query, {CancelToken? cancel}) async => asMapList(
        asMap(await api.get('/accommodations/searching',
            query: {'name': query, 'suggestions': 'true'}, cancelToken: cancel))['accommodations'],
      );

  Future<SearchPage> search(Map<String, dynamic> params) async {
    final j = asMap(await api.get('/accommodations/searching', query: params, cache: const Duration(seconds: 45)));
    return SearchPage(
      items: _listings(j['accommodations']),
      totalCount: asInt(j['totalCount']),
      totalPages: asInt(j['totalPages']),
      page: asInt(j['currentPage'], 1),
      totalReviews: j['totalReviews'] == null ? null : asInt(j['totalReviews']),
      averageRating: j['averageRating'] == null ? null : asDouble(j['averageRating']),
    );
  }

  Future<List<Listing>> mapPins(Map<String, dynamic> params) async {
    final j = asMap(await api.get('/accommodations/searching',
        query: {...params, 'mapOnly': 'true'}, cache: const Duration(seconds: 45)));
    return _listings(j['accommodations']).where((l) => l.hasCoords).toList();
  }

  /// Region facts for the map page (`/accommodation/market-stats?cities=[…]`).
  Future<Json> marketStats(List<String> cities) async =>
      asMap(await api.get('/accommodation/market-stats', query: {'cities': jsonEncode(cities)}, cache: _short));

  Future<List<Json>> blogs() async {
    final d = await api.get('/blog', cache: _short);
    if (d is List) return asMapList(d);
    final m = asMap(d);
    return asMapList(m['blogs'] ?? m['data'] ?? m['items']);
  }

  Future<Json> blogBySlug(String slug) async {
    final m = asMap(await api.get('/blog/slug/${Uri.encodeComponent(slug)}', cache: _short));
    return m['blog'] is Map ? asMap(m['blog']) : (m['data'] is Map ? asMap(m['data']) : m);
  }

  Future<void> blogView(String id) => api.post('/blog/$id/view').catchError((_) => null);

  Future<List<Json>> blogComments(String blogId) async {
    final d = await api.get('/blog-comments/blog/$blogId');
    if (d is List) return asMapList(d);
    final m = asMap(d);
    return asMapList(m['comments'] ?? m['data']);
  }

  Future<void> postBlogComment(Json body) => api.post('/blog-comments', body: body);

  Future<void> subscribe(String email) => api.post('/subscribe', body: {'email': email});

  Future<Json> feePreview(int amountCents) async =>
      asMap(await api.get('/payments/fee-preview', query: {'amountCents': amountCents}));

  List<Listing> _listings(dynamic d) {
    if (d is Map && d['accommodations'] != null) d = d['accommodations'];
    if (d is Map && d['data'] != null) d = d['data'];
    return asMapList(d).map(Listing.new).toList();
  }
}

class SearchPage {
  SearchPage({
    required this.items,
    required this.totalCount,
    required this.totalPages,
    required this.page,
    this.totalReviews,
    this.averageRating,
  });
  final List<Listing> items;
  final int totalCount;
  final int totalPages;
  final int page;

  /// Review totals across all matches; the map page's hero badges show them.
  final int? totalReviews;
  final double? averageRating;
}

// ─────────────────────────────────── Auth ───────────────────────────────────
class AuthRepo {
  Future<Json> login(String email, String password, String lang) async =>
      asMap(await api.post('/auth/login', body: {'email': email.trim(), 'password': password, 'lang': lang}));

  Future<Json> register(Json body) async => asMap(await api.post('/auth/register', body: body));

  Future<void> requestPasswordReset(String email, String lang) =>
      api.post('/auth/password-reset-request', body: {'email': email.trim(), 'lang': lang});

  Future<void> resetPassword(String token, String password, {String? role}) =>
      api.post('/auth/reset-password', body: {'token': token, 'newPassword': password, 'role': role});

  Future<Json> availableModes() async => asMap(await api.get('/auth/mode/available'));

  Future<Json> switchMode(String mode, String lang) async =>
      asMap(await api.post('/auth/mode', body: {'mode': mode, 'lang': lang}));
}

// ─────────────────────────────── Guest account ───────────────────────────────
class GuestRepo {
  Future<Json> me() async => asMap(await api.get('/guest/me'));
  Future<Json> updateMe(Json profile) async => asMap(await api.patch('/guest/me', body: profile));
  Future<void> changePassword(String current, String next) =>
      api.post('/guest/change-password', body: {'currentPassword': current, 'newPassword': next});

  Future<List<Listing>> favorites() async {
    final m = asMap(await api.get('/guest/favorites'));
    final list = m['favorites'] ?? m['data'] ?? m['accommodations'];
    return asMapList(list).map((e) => Listing(e['accommodation'] is Map ? asMap(e['accommodation']) : e)).toList();
  }

  Future<void> addFavorite(String id) => api.post('/guest/favorites', body: {'accommodationId': id});
  Future<void> removeFavorite(String id) => api.delete('/guest/favorites/${Uri.encodeComponent(id)}');

  Future<List<GuestReservation>> reservations() async =>
      asMapList(asMap(await api.get('/reservation/mine'))['reservations']).map(GuestReservation.new).toList();
}

// ────────────────────────────────── Booking ──────────────────────────────────
class BookingRepo {
  Future<Quote> quote({
    required String accommodationId,
    required DateTime checkIn,
    required DateTime checkOut,
    required int adults,
    required int children,
    bool withPet = false,
    List<String> extras = const [],
    String? unitId,
  }) async =>
      Quote(asMap(await api.get('/reservation/quote/$accommodationId', query: {
        'checkIn': isoDay(checkIn),
        'checkOut': isoDay(checkOut),
        'adults': adults,
        'children': children,
        'withPet': withPet ? 'true' : null,
        'extras': extras.isEmpty ? null : extras.join(','),
        'unitId': unitId,
      })));

  /// POST /reservation – the server prices the stay itself; the client total
  /// is never trusted (createReservation strips it).
  Future<Json> createReservation(Json payload) async {
    final r = asMap(await api.post('/reservation', body: payload));
    final id = asString(r['_id']);
    final token = asString(r['accessToken']);
    if (id.isNotEmpty && token.isNotEmpty) {
      await _remember(id, token);
    }
    return r;
  }

  Future<String> checkoutUrl(String reservationId, String lang) async {
    final r = asMap(await api.post('/payments/create-checkout-session',
        reservationId: reservationId, body: {'reservationId': reservationId, 'language': lang}));
    return asString(r['url']);
  }

  Future<Json> verifyPayment(String sessionId) async =>
      asMap(await api.post('/payments/verify-payment', body: {'sessionId': sessionId}));

  Future<void> cancelPending(String reservationId) =>
      api.post('/payments/cancel', reservationId: reservationId, body: {'reservationId': reservationId});

  Future<Json> reservation(String id) async => asMap(await api.get('/reservation/$id', reservationId: id));

  Future<Json> cancellationPreview(String id) async =>
      asMap(await api.get('/cancellation/preview/$id', reservationId: id));

  Future<Json> cancel(String id, {String? reason}) async =>
      asMap(await api.post('/cancellation/$id', reservationId: id, body: {'reason': reason}));

  Future<Json> requestInvoice(String id, Json billing) async =>
      asMap(await api.post('/receipts/$id/request-invoice', reservationId: id, body: billing));

  String receiptUrl(String id, String lang) => '${AppConfig.apiBaseUrl}/receipts/$id?lang=$lang';

  Future<void> _remember(String id, String token) => SecureStore.rememberReservationToken(id, token);
}

// ─────────────────────────────── Host workspace ───────────────────────────────
class HostRepo {
  Future<Json> dashboard() async => asMap(await api.get('/host/host-dashboard'));

  Future<List<Json>> listings() async {
    final d = await api.get('/host/host-accommodations');
    if (d is List) return asMapList(d);
    final m = asMap(d);
    return asMapList(m['accommodations'] ?? m['listings'] ?? m['items']);
  }

  Future<List<Json>> ownedAccommodations() async =>
      asMapList(asMap(await api.get('/host/accommodations'))['accommodations']);

  Future<Json> createListing() async => asMap(await api.post('/host/host-accommodations'));
  Future<Json> listing(String id) async => asMap(await api.get('/host/host-accommodations/${Uri.encodeComponent(id)}'));
  Future<Json> updateListing(String id, Json data) async =>
      asMap(await api.patch('/host/host-accommodations/${Uri.encodeComponent(id)}', body: {'data': data}));
  Future<void> deleteListing(String id) => api.delete('/host/host-accommodations/${Uri.encodeComponent(id)}');
  Future<Json> publishListing(String id) async =>
      asMap(await api.post('/host/host-accommodations/${Uri.encodeComponent(id)}/publish'));
  Future<Json> adoptListing(String id) async =>
      asMap(await api.post('/host/host-accommodations/${Uri.encodeComponent(id)}/adopt'));

  String _cal(String id, [String suffix = '']) => '/host/host-accommodations/${Uri.encodeComponent(id)}/calendar$suffix';
  Future<Json> calendar(String id) async => asMap(await api.get(_cal(id)));
  Future<Json> block(String id, String start, String end, {String? note, String? unitId}) async =>
      asMap(await api.post(_cal(id, '/blocks'), body: {'startDate': start, 'endDate': end, 'note': note, 'unitId': unitId}));
  /// `blockId` frees exactly that one block (day sheet / list row); without it every manual block in the range goes.
  Future<Json> unblock(String id, String start, String end, {String? unitId, String? blockId}) async =>
      asMap(await api.post(_cal(id, '/unblock'), body: {'startDate': start, 'endDate': end, 'unitId': unitId, if (blockId != null) 'blockId': blockId}));

  /// Every property's calendar in one read-only snapshot (web `loadAllCalendars`): each block remembers its property.
  Future<Json> allCalendars() async {
    final listings = await ownedAccommodations();
    final snaps = await Future.wait([for (final l in listings) calendar(asString(l['id']))]);
    return {
      'today': snaps.isEmpty ? null : snaps.first['today'],
      'units': <Json>[],
      'feeds': <Json>[],
      'calendarChoice': null,
      'listing': null,
      'blocks': [
        for (var i = 0; i < snaps.length; i++)
          for (final b in asMapList(snaps[i]['blocks']))
            {
              ...b,
              'id': '${asString(listings[i]['id'])}:${asString(b['id'])}',
              'blockId': b['id'],
              'sourceListingId': asString(listings[i]['id']),
              'sourceListing': snaps[i]['listing'] ?? listings[i],
            },
      ],
    };
  }
  Future<Json> addFeed(String id, String url, String label, {String? unitId}) async =>
      asMap(await api.post(_cal(id, '/feeds'), body: {'url': url, 'label': label, if (unitId != null) 'unitId': unitId}));
  Future<Json> updateFeed(String id, String feedId, Json patch) async =>
      asMap(await api.patch(_cal(id, '/feeds/${Uri.encodeComponent(feedId)}'), body: patch));
  Future<Json> setCalendarMode(String id, String choice) async => asMap(await api.post(_cal(id, '/mode'), body: {'calendarChoice': choice}));
  Future<Json> removeAllFeeds(String id, bool removeImported) async => asMap(await api.delete(_cal(id, '/feeds'), body: {'removeImported': removeImported}));
  Future<Json> refreshFeed(String id, String feedId) async =>
      asMap(await api.post(_cal(id, '/feeds/${Uri.encodeComponent(feedId)}/fetch')));
  Future<Json> removeFeed(String id, String feedId) async =>
      asMap(await api.delete(_cal(id, '/feeds/${Uri.encodeComponent(feedId)}')));

  Future<List<Json>> reservations() async => asMapList(asMap(await api.get('/host/host-reservations'))['reservations']);
  Future<Json> reservation(String id) async =>
      asMap(asMap(await api.get('/host/host-reservations/${Uri.encodeComponent(id)}'))['reservation']);
  Future<Json> transition(String id, String action, {String? note}) async {
    // The host router has no cancel route (the refund tier lives in the
    // cancellation flow, which reads the host role from the token).
    if (action == 'cancel') {
      return asMap(await api.post('/cancellation/${Uri.encodeComponent(id)}',
          body: note == null || note.isEmpty ? {} : {'reason': note}));
    }
    return asMap(await api.post('/host/host-reservations/${Uri.encodeComponent(id)}/$action',
        body: note == null || note.isEmpty ? {} : {'note': note}));
  }

  Future<List<Json>> conversations({String? accommodationId}) async => asMapList(asMap(await api.get(
      '/host/host-conversations',
      query: {'accommodationId': accommodationId}))['conversations']);
  Future<Json> conversation(String id) async =>
      asMap(asMap(await api.get('/host/host-conversations/${Uri.encodeComponent(id)}'))['conversation']);
  Future<Json> sendMessage(String id, String body, String clientKey) async => asMap(await api.post(
      '/host/host-conversations/${Uri.encodeComponent(id)}/messages',
      body: {'body': body, 'clientKey': clientKey}));
  Future<void> markRead(String id) => api.post('/host/host-conversations/${Uri.encodeComponent(id)}/read');

  Future<Json> profile() async => asMap(asMap(await api.get('/host/host-profile'))['profile']);
  Future<Json> saveProfile(Json p) async => asMap(asMap(await api.put('/host/host-profile', body: p))['profile']);

  /// Same three-step flow as prepareHostProfilePhoto on the site.
  Future<Json> uploadProfilePhoto(File file) async {
    final bytes = await file.readAsBytes();
    final name = file.path.split(Platform.pathSeparator).last;
    final type = name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    final req = asMap(await api.post('/host/host-profile-photo/upload-url',
        body: {'name': name, 'size': bytes.length, 'contentType': type}));
    final origin = Uri.parse(AppConfig.apiBaseUrl).origin;
    await api.dio.put(
      '$origin${asString(req['uploadUrl'])}',
      data: Stream.fromIterable([bytes]),
      options: Options(headers: {'Content-Type': type, Headers.contentLengthHeader: bytes.length}),
    );
    return asMap(await api.post('/host/host-profile-photo/prepare', body: {'objectPath': req['objectPath']}));
  }

  Future<Json> payouts() async => asMap(asMap(await api.get('/host/host-payouts'))['payouts']);
  Future<Json> account() async => asMap(asMap(await api.get('/host/account'))['account']);
  Future<Json> updateAccount(Json patch) async => asMap(asMap(await api.patch('/host/account', body: patch))['account']);
  Future<void> changePassword(String current, String next) =>
      api.post('/host/account/change-password', body: {'currentPassword': current, 'newPassword': next});
  Future<Json> changeEmail(String email, String password) async =>
      asMap(await api.patch('/host/account/email', body: {'newEmail': email, 'currentPassword': password}));

  /// Asks the backend to verify the account against Stripe (the onboarding return page).
  Future<Json> refreshStripeStatus(String hostId) async => asMap(await api.post('/payments/host/refresh-status', body: {'hostId': hostId}));

  String _acct(String hostId, String accountId, String tail) =>
      '/payments/host/${Uri.encodeComponent(hostId)}/stripe-accounts/${Uri.encodeComponent(accountId)}/$tail';

  /// What stands in the way of removing an account (decided by the server).
  Future<Json> accountRemovalCheck(String hostId, String accountId) async => asMap(await api.get(_acct(hostId, accountId, 'removal-check')));

  /// Removes the account from UK Stay Hub (it stays open in Stripe). Answers with the new account lists.
  Future<Json> removeStripeAccount(String hostId, String accountId) async =>
      asMap(await api.delete('/payments/host/stripe-account', body: {'hostId': hostId, 'accountId': accountId}));

  Future<Json> restoreStripeAccount(String hostId, String accountId) async => asMap(await api.post(_acct(hostId, accountId, 'restore')));

  Future<Json> stripeDeletionCheck(String hostId, String accountId) async => asMap(await api.get(_acct(hostId, accountId, 'stripe-deletion-check')));

  /// Permanently deletes a removed account in Stripe.
  Future<Json> deleteAccountInStripe(String hostId, String accountId) async => asMap(await api.delete(_acct(hostId, accountId, 'stripe')));

  /// The payment split for a booking amount, from the same calculation the payout uses.
  Future<Json> feePreview(int amountCents) async => asMap(await api.get('/payments/fee-preview', query: {'amountCents': amountCents}));

  /// Business-register lookup used by the billing form.
  Future<Json> icoLookup(String ico) async => asMap(await api.get('/ico/${Uri.encodeComponent(ico)}'));

  /// Connected Stripe accounts, the same endpoint the website's payout picker reads.
  Future<List<Json>> stripeAccounts(String hostId, {bool sync = false}) async =>
      asMapList(asMap(await api.get('/payments/host/${Uri.encodeComponent(hostId)}/stripe-accounts', query: sync ? {'refresh': '1'} : null))['accounts']);

  /// The whole stripe-accounts answer (accounts plus removed accounts).
  Future<Json> stripeAccountsRaw(String hostId) async => asMap(await api.get('/payments/host/${Uri.encodeComponent(hostId)}/stripe-accounts'));

  /// Starts Stripe onboarding for a new account; `returnTo` is the site path to come back to.
  Future<String> connectStripeAccount(String hostId, String returnTo) async {
    final r = asMap(await api.post('/payments/host/connect-account', body: {'hostId': hostId, 'returnTo': returnTo}));
    return asString(r['onboardingUrl']);
  }

  /// The host's own monthly platform-fee invoices (newest first).
  Future<List<Json>> invoices(String hostId) async {
    final r = await api.get('/invoices/host/${Uri.encodeComponent(hostId)}');
    return asMapList(r);
  }

  /// Reopens Stripe onboarding for one account (a fresh link every time).
  Future<String> stripeAccountLink(String hostId, String accountId) async =>
      asString(asMap(await api.post('/payments/host/account-link', body: {'hostId': hostId, 'accountId': accountId, 'returnTo': '/host/payouts'}))['onboardingUrl']);

  Future<String> stripeDashboardLink(String hostId, String accountId) async =>
      asString(asMap(await api.post('/payments/host/dashboard-link', body: {'hostId': hostId, 'accountId': accountId}))['url']);

  Future<List<Json>> setDefaultStripeAccount(String hostId, String accountId) async =>
      asMapList(asMap(await api.post('/payments/host/default-account', body: {'hostId': hostId, 'accountId': accountId}))['accounts']);

  /// Starts onboarding for another account, with an optional label.
  Future<String> connectStripeAccountLabelled(String hostId, String label, String returnTo) async =>
      asString(asMap(await api.post('/payments/host/connect-account', body: {'hostId': hostId, 'label': label, 'returnTo': returnTo}))['onboardingUrl']);

  /// Points one property at one payout account; an empty id means "use the default".
  Future<void> assignListingPayoutAccount(String listingId, String accountId) =>
      api.put('/accommodation/${Uri.encodeComponent(listingId)}/payout-account', body: {'accountId': accountId.isEmpty ? null : accountId});

  /// The host document, which carries the server's verdict on missing billing details.
  Future<Json> hostDocument(String hostId) async => asMap(await api.get('/hosts/${Uri.encodeComponent(hostId)}'));

  /// Every booking made with this host, for the earnings sections.
  Future<List<Json>> providerReservations(String hostId) async {
    try {
      final r = await api.get('/reservation/provider/${Uri.encodeComponent(hostId)}');
      return r is List ? asMapList(r) : asMapList(asMap(r)['reservations']);
    } on ApiException catch (e) {
      if (e.status == 404) return const []; // a host with no bookings at all
      rethrow;
    }
  }

  /// Withdraw one booking's payout. Returns the server's answer even for 4xx/202 so callers can read `code`.
  Future<Json> releasePayout(String reservationId) async {
    try {
      return asMap(await api.post('/payments/release-payout', reservationId: reservationId, body: {'reservationId': reservationId}));
    } on ApiException catch (e) {
      if (e.data is Map) return asMap(e.data);
      rethrow;
    }
  }

  Future<String> stripeOnboardingUrl(String hostId) async {
    final r = asMap(await api.post('/payments/host/create-express-account', body: {'hostId': hostId}));
    return asString(r['url'] ?? r['onboardingUrl'] ?? r['accountLink']);
  }

  /// Listing photos: the site uploads to Cloudinary with the public unsigned
  /// preset; the API secret never leaves the server.
  Future<String> uploadListingPhoto(XFile file) async {
    final dio = Dio();
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(await file.readAsBytes(), filename: file.name),
      'upload_preset': AppConfig.cloudinaryUploadPreset,
    });
    final res = await dio.post(
      'https://api.cloudinary.com/v1_1/${AppConfig.cloudinaryCloudName}/image/upload',
      data: form,
    );
    return asString(asMap(res.data)['secure_url']);
  }
}

final publicRepo = PublicRepo();
final authRepo = AuthRepo();
final guestRepo = GuestRepo();
final bookingRepo = BookingRepo();
final hostRepo = HostRepo();

String prettyJson(Object o) => const JsonEncoder.withIndent('  ').convert(o);
