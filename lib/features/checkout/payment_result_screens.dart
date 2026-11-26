import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../state/providers.dart';
import '../../widgets/chrome.dart' show StayHubDrawer, StayHubFooter, StayHubHeader;
import '../../widgets/common.dart';
import 'payment_webview.dart';
import 'receipt_screen.dart';
import '../search/search_screen.dart' show FooterNav, MobileSearchHeader;

/// request-sent/page.js wraps its content in the site chrome: the mobile search
/// header (below lg) or the desktop header, then the footer and the bottom nav.
class _SiteChrome extends StatelessWidget {
  const _SiteChrome({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final lg = context.lg;
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: lg ? const StayHubHeader() : null,
      endDrawer: const StayHubDrawer(),
      bottomNavigationBar: lg ? null : const FooterNav(),
      body: CustomScrollView(slivers: [
        if (!lg)
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppColors.neutral100))),
              child: const SafeArea(bottom: false, child: Padding(padding: EdgeInsets.symmetric(vertical: 14), child: MobileSearchHeader())),
            ),
          ),
        SliverToBoxAdapter(child: child),
        const SliverToBoxAdapter(child: StayHubFooter()),
      ]),
    );
  }
}

class _ResultScaffold extends StatelessWidget {
  const _ResultScaffold({required this.icon, required this.iconBg, required this.title, required this.body, required this.actions});
  final IconData icon;
  final Color iconBg;
  final String title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: AppColors.cream, body: SafeArea(child: SingleChildScrollView(child: _content())));

  Widget _content() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 672),
          child: Padding(padding: const EdgeInsets.fromLTRB(24, 48, 24, 24), child: Column(children: [
            Center(
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
                child: Icon(icon, size: 40, color: Colors.white),
              ),
            ),
            const SizedBox(height: 24),
            Text(title, textAlign: TextAlign.center, style: AppText.fraunces(size: 28)),
            const SizedBox(height: 16),
            body,
            const SizedBox(height: 32),
            ...actions.expand((a) => [a, const SizedBox(height: 12)]),
          ])),
        ),
      );
}

/// payment-success/page.js – verifies the Stripe session (polls while the
/// webhook is still reconciling), then shows the receipt link.
class PaymentSuccessScreen extends ConsumerStatefulWidget {
  const PaymentSuccessScreen({super.key, required this.sessionId, this.reservationId});
  final String sessionId;
  final String? reservationId;
  @override
  ConsumerState<PaymentSuccessScreen> createState() => _PaymentSuccessScreenState();
}

class _PaymentSuccessScreenState extends ConsumerState<PaymentSuccessScreen> {
  bool _verifying = true;
  bool _ok = false;
  Json? _reservation;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _verify();
  }

  Future<void> _verify() async {
    // Opened without a Stripe session (an emailed link for a booking that is
    // already paid): the reservation itself says whether it is paid.
    final rid = widget.reservationId ?? '';
    if (widget.sessionId.isEmpty && rid.isNotEmpty) {
      try {
        final r = await bookingRepo.reservation(rid);
        if (!mounted) return;
        setState(() {
          _reservation = r;
          _ok = asString(r['paymentStatus']) == 'paid';
          _verifying = false;
        });
        ref.invalidate(myReservationsProvider);
        // The paid nights are now booked: drop cached listings so their
        // calendars are fetched fresh.
        api.clearCache();
      } catch (_) {
        if (mounted) setState(() => _verifying = false);
      }
      return;
    }
    if (widget.sessionId.isEmpty) {
      setState(() {
        _verifying = false;
        _ok = false;
      });
      return;
    }
    try {
      final r = await bookingRepo.verifyPayment(widget.sessionId);
      final pending = asBool(r['pending']);
      if (pending && _attempts < 6) {
        _attempts++;
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) return await _verify();
        return;
      }
      if (!mounted) return;
      setState(() {
        _ok = asString(r['status']) == 'paid' || asBool(r['settled']);
        _reservation = asMap(r['reservation']);
        _verifying = false;
      });
      ref.invalidate(myReservationsProvider);
      api.clearCache(); // fresh listing calendars after a payment
    } catch (_) {
      if (mounted) {
        setState(() {
        _verifying = false;
        _ok = false;
      });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (_verifying) {
      return Scaffold(
        backgroundColor: AppColors.cream,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: AppColors.green),
            const SizedBox(height: 20),
            Text(t('VerifyingPayment', 'Overujeme platbu…'), style: AppText.fraunces(size: 22)),
            const SizedBox(height: 8),
            Text(t('VerifyWait', 'Chvíľku strpenia.'), style: AppText.inter(size: 14, color: AppColors.slate)),
          ]),
        ),
      );
    }
    final rid = asString(_reservation?['_id'], widget.reservationId ?? '');
    return _ResultScaffold(
      icon: _ok ? Icons.check_rounded : Icons.error_outline,
      iconBg: _ok ? AppColors.green : AppColors.red,
      title: _ok ? t('PaymentSuccessful', 'Platba prebehla úspešne') : t('PaymentFailed', 'Platba zlyhala'),
      body: Column(children: [
        Text(
          _ok ? t('PaymentSuccessMessage', '') : t('PaymentErrorMessage', ''),
          textAlign: TextAlign.center,
          style: AppText.inter(size: 15, color: AppColors.slate, height: 1.6),
        ),
        if (_ok && _reservation != null) ...[
          const SizedBox(height: 20),
          _Card(rows: [
            (t('Dates', t.pick('Termín', 'Dates')),
                rangeLabel(asDay(_reservation!['checkInDate']), asDay(_reservation!['checkOutDate']), t.lang)),
            (t('Total', 'Spolu'), money(asInt(_reservation!['totalPriceCents']) / 100, decimals: true)),
            (t('TransactionID', 'ID transakcie'), rid),
          ]),
        ],
      ]),
      actions: [
        if (_ok && rid.isNotEmpty)
          OutlineBtn(
            label: t('DownloadReceipt', 'Stiahnuť potvrdenie'),
            icon: Icons.receipt_long_outlined,
            onPressed: () => ReceiptScreen.open(context, rid),
          ),
        if (_ok && rid.isNotEmpty && ref.watch(authProvider).loggedIn)
          OutlineBtn(
            label: t('MyBookings', 'My bookings'),
            icon: Icons.luggage_outlined,
            onPressed: () => context.go('/guest?tab=bookings'),
          ),
        if (!_ok) ...[
          PrimaryButton(
            label: t('TryAgain', 'Try again'),
            onPressed: () => rid.isNotEmpty ? context.go('/pay/$rid') : context.go('/mapa'),
          ),
          OutlineBtn(label: t('ContactSupport', 'Contact support'), onPressed: () => context.go('/kontakt')),
        ],
        _ok
            ? PrimaryButton(label: t('ReturnHome', 'Späť na úvod'), onPressed: () => context.go('/'))
            : OutlineBtn(label: t('ReturnHome', 'Späť na úvod'), onPressed: () => context.go('/')),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.rows});
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
        child: Column(children: [
          for (final (a, b) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Text(a, style: AppText.inter(size: 14, color: AppColors.neutral500)),
                const SizedBox(width: 12),
                Expanded(child: Text(b, textAlign: TextAlign.right, style: AppText.inter(size: 14, weight: FontWeight.w600))),
              ]),
            ),
        ]),
      );
}

/// /pay/:id – the payment link from the "request accepted" email, opened in
/// the app (App Links / Universal Links). Shows the booking, runs Stripe
/// Checkout in the in-app WebView and ends on the in-app result screens.
///
/// Closing the payment here does NOT call /payments/cancel: for an emailed
/// link that would undo the host's approval. The link simply stays valid
/// until it expires, so the guest can try again.
class PayLinkScreen extends ConsumerStatefulWidget {
  const PayLinkScreen({super.key, required this.reservationId, this.token});
  final String reservationId;
  final String? token;
  @override
  ConsumerState<PayLinkScreen> createState() => _PayLinkScreenState();
}

class _PayLinkScreenState extends ConsumerState<PayLinkScreen> {
  Json? _data;
  Object? _error;
  bool _loading = true;
  bool _paying = false;
  bool _notCompleted = false;

  String get _id => widget.reservationId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = widget.token ?? '';
      if (token.isNotEmpty) await bookingRepo.rememberToken(_id, token);
      final d = await bookingRepo.payLink(_id);
      if (!mounted) return;
      if (asString(d['state']) == 'paid') {
        context.go('/payment-success?reservationId=$_id');
        return;
      }
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _pay() async {
    final url = asString(_data?['url']);
    if (url.isEmpty || _paying) return;
    setState(() => _paying = true);
    final result = await Navigator.of(context).push<PaymentResult>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PaymentWebView(url: url),
    ));
    if (!mounted) return;
    setState(() => _paying = false);
    if (result?.status == PaymentStatus.success) {
      context.go('/payment-success?session_id=${Uri.encodeComponent(result!.sessionId ?? '')}&reservationId=$_id');
      return;
    }
    // Closed or cancelled: the link is still good until it expires.
    setState(() => _notCompleted = true);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (_loading && _data == null) {
      return const Scaffold(backgroundColor: AppColors.cream, body: LoadingView());
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: AppColors.cream,
        body: SafeArea(
          child: ErrorView(
            message: t('PayLinkLoadFailed', 'We could not open this payment link. Please try again.'),
            error: _error,
            onRetry: _load,
          ),
        ),
      );
    }

    final state = asString(_data?['state']);
    final r = asMap(_data?['reservation']);
    if (state == 'taken') {
      return _ResultScaffold(
        icon: Icons.event_busy_outlined,
        iconBg: AppColors.amber,
        title: t('DatesTakenTitle', 'Dates no longer available'),
        body: Text(
          t('DatesTakenBody', 'Another guest has just booked these dates, so this booking can\'t be paid. You have not been charged.'),
          textAlign: TextAlign.center,
          style: AppText.inter(size: 15, color: AppColors.slate, height: 1.6),
        ),
        actions: [
          PrimaryButton(label: t('BrowseAccommodations', 'Browse stays'), onPressed: () => context.go('/mapa')),
          OutlineBtn(label: t('ReturnHome', 'Späť na úvod'), onPressed: () => context.go('/')),
        ],
      );
    }
    if (state != 'ready') {
      final expired = state == 'expired';
      return _ResultScaffold(
        icon: expired ? Icons.timer_off_outlined : Icons.error_outline,
        iconBg: expired ? AppColors.amber : AppColors.red,
        title: expired
            ? t('PayLinkExpiredTitle', 'Payment link expired')
            : t('PayLinkUnavailableTitle', 'Payment not available'),
        body: Text(
          expired
              ? t('PayLinkExpiredBody', 'This payment link has expired and the dates have been released. You can make a new booking for the same dates if they are still free.')
              : t('PayLinkUnavailableBody', 'This booking can no longer be paid for. It may have been cancelled or declined.'),
          textAlign: TextAlign.center,
          style: AppText.inter(size: 15, color: AppColors.slate, height: 1.6),
        ),
        actions: [
          PrimaryButton(label: t('BrowseAccommodations', 'Browse stays'), onPressed: () => context.go('/mapa')),
          OutlineBtn(label: t('ReturnHome', 'Späť na úvod'), onPressed: () => context.go('/')),
        ],
      );
    }

    final total = money(asInt(r['totalPriceCents']) / 100, decimals: true);
    final expiresAt = DateTime.tryParse(asString(_data?['expiresAt']))?.toLocal();
    final listing = [asString(pick(r, 'accommodationId.name')), asString(r['unitName'])].where((e) => e.isNotEmpty).join(' · ');
    return _ResultScaffold(
      icon: Icons.credit_card,
      iconBg: AppColors.green,
      title: t('CompletePaymentTitle', 'Complete your payment'),
      body: Column(children: [
        Text(
          t('CompletePaymentBody', 'The host accepted your request. Pay now to confirm your booking.'),
          textAlign: TextAlign.center,
          style: AppText.inter(size: 15, color: AppColors.slate, height: 1.6),
        ),
        if (_notCompleted) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFF5D9A0))),
            child: Text(
              t('PaymentNotCompleted', 'The payment was not completed and you have not been charged. You can try again below.'),
              textAlign: TextAlign.center,
              style: AppText.inter(size: 14, color: const Color(0xFF8A6A1F)),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _Card(rows: [
          if (listing.isNotEmpty) (t('Accommodation', 'Stay'), listing),
          (t('Dates', t.pick('Termín', 'Dates')), rangeLabel(asDay(r['checkInDate']), asDay(r['checkOutDate']), t.lang)),
          (t('Guests', 'Guests'), '${asInt(r['numberOfPersons'], 1)}'),
          (t('Total', 'Spolu'), total),
        ]),
        if (expiresAt != null) ...[
          const SizedBox(height: 12),
          Text(
            '${t('PayBefore', 'Pay before')} ${DateFormat('d MMM yyyy, HH:mm', 'en_GB').format(expiresAt)}',
            textAlign: TextAlign.center,
            style: AppText.inter(size: 13, color: AppColors.neutral500),
          ),
        ],
      ]),
      actions: [
        PrimaryButton(
          label: _paying ? t('OpeningPayment', 'Opening payment…') : '${t('PayNow', 'Pay')} $total',
          onPressed: _paying ? null : _pay,
        ),
        OutlineBtn(label: t('NotNow', 'Not now'), onPressed: () => context.go('/')),
      ],
    );
  }
}

/// payment-cancel/page.js
class PaymentCancelScreen extends ConsumerWidget {
  const PaymentCancelScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    return _ResultScaffold(
      icon: Icons.close_rounded,
      iconBg: AppColors.amber,
      title: t('PaymentCancelled', 'Platba bola zrušená'),
      body: Text(t('PaymentCancelMessage', ''), textAlign: TextAlign.center, style: AppText.inter(size: 15, color: AppColors.slate, height: 1.6)),
      actions: [
        PrimaryButton(label: t('TryAgain', 'Skúsiť znova'), onPressed: () => context.canPop() ? context.pop() : context.go('/mapa')),
        OutlineBtn(label: t('ReturnHome', 'Späť na úvod'), onPressed: () => context.go('/')),
      ],
    );
  }
}

/// request-sent/page.js – booking-request confirmation and next steps.
class RequestSentScreen extends ConsumerStatefulWidget {
  const RequestSentScreen({super.key, required this.reservationId});
  final String reservationId;
  @override
  ConsumerState<RequestSentScreen> createState() => _RequestSentScreenState();
}

class _RequestSentScreenState extends ConsumerState<RequestSentScreen> {
  Json? _r;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    bookingRepo.reservation(widget.reservationId).then((r) {
      if (mounted) setState(() => _r = r);
    }).catchError((_) => null).whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (_loading) return const _SiteChrome(child: SizedBox(height: 400, child: LoadingView()));
    final r = _r;
    if (r == null) {
      return _SiteChrome(
        child: _Wrap(
          minHeight: 400,
          child: _WebCard(
            maxWidth: 448,
            padding: const EdgeInsets.all(32),
            child: Column(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: const Color(0xFFFEF2F2), border: Border.all(color: const Color(0xFFFECACA)), borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.cancel_outlined, size: 28, color: Color(0xFFDC2626)),
              ),
              const SizedBox(height: 20),
              Text(t('RequestNotFoundTitle', 'Žiadosť sa nenašla'), textAlign: TextAlign.center, style: AppText.inter(size: 20, weight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 8),
              Text(t('RequestNotFoundDescription', ''), textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w500, color: _slate)),
              const SizedBox(height: 24),
              _Cta(label: t('BrowseAccommodations', 'Prezerať ubytovania'), onTap: () => context.go('/mapa')),
            ]),
          ),
        ),
      );
    }
    final lang = t.lang;
    String day(dynamic v) {
      final d = asDay(v);
      return d == null ? '—' : longDate(d, lang);
    }

    final listing = [asString(pick(r, 'accommodationId.name'), asString(r['accommodationName'])), asString(r['unitName'])].where((e) => e.isNotEmpty).join(' · ');
    final cents = r['totalPriceCents'] != null ? asInt(r['totalPriceCents']) : (asInt(r['totalPrice']) * 100);
    final total = NumberFormat.currency(locale: 'en_GB', name: asString(r['currency'], 'gbp').toUpperCase()).format(cents / 100);
    final steps = [
      (Icons.send_outlined, t('RequestStepSentTitle', 'Žiadosť odoslaná'), t('RequestStepSentBody', ''), true),
      (Icons.schedule, t('RequestStepHostTitle', 'Hostiteľ odpovie'), t('RequestStepHostBody', ''), false),
      (Icons.credit_card, t('RequestStepPayTitle', 'Zaplatíte'), t('RequestStepPayBody', ''), false),
    ];
    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: _teal)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(), style: AppText.inter(size: 11, weight: FontWeight.w700, color: const Color(0xFF94A3B8))),
                Text(value, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _ink)),
              ]),
            ),
          ]),
        );
    final wide = context.md;

    return _SiteChrome(
      child: _Wrap(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _WebCard(
            topBar: _teal,
            padding: EdgeInsets.all(wide ? 40 : 32),
            child: Column(children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: _teal.withOpacity(.1), border: Border.all(color: _teal.withOpacity(.2)), borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.check_circle_outline, size: 32, color: _teal),
              ),
              const SizedBox(height: 20),
              Text(t('RequestSentTitle', 'Žiadosť odoslaná'), textAlign: TextAlign.center, style: AppText.inter(size: wide ? 30 : 24, weight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 448),
                child: Text(t('RequestSentDescription', ''), textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w500, color: _slate, height: 1.625)),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: _teal.withOpacity(.1), border: Border.all(color: _teal.withOpacity(.2)), borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.credit_card, size: 16, color: Color(0xFF257562)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(t('NothingChargedYet', ''), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF257562)))),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          _WebCard(
            leftBar: const Color(0xFFDFBA73),
            padding: EdgeInsets.fromLTRB(wide ? 36 : 28, wide ? 32 : 24, wide ? 32 : 24, wide ? 32 : 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('YourRequest', 'Vaša žiadosť'), style: AppText.inter(size: 16, weight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 20),
              if (listing.isNotEmpty) row(Icons.home_outlined, t('Accommodation', 'Ubytovanie'), listing),
              row(Icons.calendar_month_outlined, t('Dates', 'Termín'), '${day(r['checkInDate'])} — ${day(r['checkOutDate'])}'),
              row(Icons.group_outlined, t('Guests', 'Hostia'), '${asInt(r['numberOfPersons'], 1)} ${t('persons', 'osôb')}'),
              row(Icons.mail_outline, t('Email', 'E-mail'), asString(r['email'])),
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.only(top: 20),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: _ink.withOpacity(.1)))),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Flexible(child: Text(t('TotalToPayLater', 'Na úhradu neskôr'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: _slate))),
                  const SizedBox(width: 16),
                  Text(total, style: AppText.inter(size: 20, weight: FontWeight.w800, color: _ink)),
                ]),
              ),
              const SizedBox(height: 16),
              Text('${t('RequestReference', 'Číslo žiadosti')}: ${asString(r['_id'], widget.reservationId)}', style: AppText.inter(size: 12, weight: FontWeight.w500, color: const Color(0xFF94A3B8))),
            ]),
          ),
          const SizedBox(height: 24),
          _WebCard(
            padding: EdgeInsets.all(wide ? 32 : 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('WhatHappensNext', 'Čo bude ďalej'), style: AppText.inter(size: 16, weight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 20),
              for (final (icon, title, body, done) in steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: done ? _teal : _ink.withOpacity(.04),
                        border: Border.all(color: done ? _teal : _ink.withOpacity(.1)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, size: 16, color: done ? Colors.white : _teal),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _ink)),
                        const SizedBox(height: 2),
                        Text(body, style: AppText.inter(size: 14, weight: FontWeight.w500, color: _slate, height: 1.625)),
                      ]),
                    ),
                  ]),
                ),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFFDFBA73).withOpacity(.15), border: Border.all(color: const Color(0xFFDFBA73).withOpacity(.3)), borderRadius: BorderRadius.circular(12)),
                child: Text(t('RequestDatesNotBlocked', ''), style: AppText.inter(size: 12, weight: FontWeight.w500, color: const Color(0xFF9A7A3A))),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 12, children: [
            _Cta(label: t('BrowseAccommodations', 'Prezerať ubytovania'), wide: !wide, onTap: () => context.go('/mapa')),
            _Cta(label: t('BackToHome', 'Späť na úvod'), outline: true, wide: !wide, onTap: () => context.go('/')),
          ]),
        ]),
      ),
    );
  }
}

const _teal = Color(0xFF319A81);
const _ink = Color(0xFF1E3E2B);
const _slate = Color(0xFF64748B);

/// `px-4 py-12 md:py-16` + `max-w-2xl mx-auto`.
class _Wrap extends StatelessWidget {
  const _Wrap({required this.child, this.minHeight = 0});
  final Widget child;
  final double minHeight;
  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(minHeight: minHeight),
        alignment: Alignment.topCenter,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: context.md ? 64 : 48),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 672), child: child),
      );
}

/// White `rounded-2xl` card with an optional 6px teal (top) / gold (left) accent bar.
class _WebCard extends StatelessWidget {
  const _WebCard({required this.child, required this.padding, this.topBar, this.leftBar, this.maxWidth});
  final Widget child;
  final EdgeInsets padding;
  final Color? topBar;
  final Color? leftBar;
  final double? maxWidth;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _ink.withOpacity(.05)),
            boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          child: Stack(children: [
            Padding(padding: padding, child: child),
            if (topBar != null) Positioned(top: 0, left: 0, right: 0, height: 6, child: ColoredBox(color: topBar!)),
            if (leftBar != null) Positioned(top: 0, bottom: 0, left: 0, width: 6, child: ColoredBox(color: leftBar!)),
          ]),
        ),
      );
}

class _Cta extends StatelessWidget {
  const _Cta({required this.label, required this.onTap, this.outline = false, this.wide = false});
  final String label;
  final VoidCallback onTap;
  final bool outline;
  final bool wide;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: wide ? double.infinity : null,
        child: Material(
          color: outline ? Colors.white : _teal,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: outline ? BorderSide(color: _ink.withOpacity(.1)) : BorderSide.none),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              child: Text(label, textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w700, color: outline ? _ink : Colors.white)),
            ),
          ),
        ),
      );
}
