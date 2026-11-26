import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../widgets/chrome.dart';
import 'host_account.dart';
import 'stripe_onboarding.dart';

/// host/onboard/success/page.js and host/onboard/refresh/page.js – the Stripe onboarding return pages.

const _green = Color(0xFF319A7A);
const _button = Color(0xFF357965);
const _deep = Color(0xFF1E4636);

/// Shared card: centred, max 448px, round icon, Fraunces title with a green rule, body, actions.
class _OnboardCard extends StatelessWidget {
  const _OnboardCard({required this.problem, required this.busy, required this.title, required this.body, this.extra = const [], required this.actions, this.footer});
  final bool problem;
  final bool busy;
  final String title;
  final String body;
  final List<Widget> extra;
  final List<Widget> actions;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final sm = MediaQuery.sizeOf(context).width >= 640;
    return Scaffold(
      backgroundColor: AppColors.neutral50,
      appBar: const StayHubHeader(logo: true),
      endDrawer: const StayHubDrawer(),
      body: SingleChildScrollView(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
            child: Center(child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 448),
              child: Container(
                padding: EdgeInsets.all(sm ? 40 : 32),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200.withValues(alpha: 0.8)), boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 30, offset: Offset(0, 8))]),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(color: problem ? const Color(0xFFFFFBEB) : const Color(0xFFECFDF5), shape: BoxShape.circle),
                      child: busy
                          ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(strokeWidth: 3, color: _green))
                          : Icon(problem ? Icons.warning_amber_rounded : Icons.check_circle_outline, size: 40, color: problem ? const Color(0xFFF59E0B) : _green),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(title, textAlign: TextAlign.center, style: AppText.fraunces(size: sm ? 30 : 24, weight: FontWeight.w700, color: _deep, height: 1.2)),
                  const SizedBox(height: 12),
                  Center(child: Container(width: 48, height: 3, decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(99)))),
                  const SizedBox(height: 20),
                  Text(body, textAlign: TextAlign.center, style: AppText.inter(size: sm ? 16 : 14, color: AppColors.neutral500, height: 1.6)),
                  ...extra,
                  if (actions.isNotEmpty) ...[const SizedBox(height: 32), for (var i = 0; i < actions.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 12), child: actions[i])],
                  if (footer != null) ...[const SizedBox(height: 28), Center(child: footer!)],
                ]),
              ),
            )),
          ),
          const StayHubFooter(),
        ]),
      ),
    );
  }
}

Widget _primary(String label, VoidCallback? onTap) => FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(backgroundColor: _button, disabledBackgroundColor: _button.withValues(alpha: 0.6), disabledForegroundColor: Colors.white, minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      child: Text(label, style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
    );

Widget _secondary(String label, VoidCallback onTap) => OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(foregroundColor: _deep, side: const BorderSide(color: AppColors.neutral200), minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      child: Text(label, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _deep)),
    );

Widget _listBox(String heading, List<String> items) => Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0x99FFFBEB), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFEF3C7))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(heading.toUpperCase(), style: AppText.inter(size: 12, weight: FontWeight.w700, color: const Color(0xFFB45309), letterSpacing: 1.2)),
        const SizedBox(height: 8),
        for (final i in items) Padding(padding: const EdgeInsets.only(left: 8, top: 4), child: Text('• $i', style: AppText.inter(size: 14, color: const Color(0xFF92400E), height: 1.4))),
      ]),
    );

// ───────────────────────────── Success ─────────────────────────────
class HostOnboardSuccessScreen extends ConsumerStatefulWidget {
  const HostOnboardSuccessScreen({super.key, this.returnTo});

  /// Where the host started onboarding from (e.g. the listing editor), if any.
  final String? returnTo;
  @override
  ConsumerState<HostOnboardSuccessScreen> createState() => _SuccessState();
}

class _SuccessState extends ConsumerState<HostOnboardSuccessScreen> {
  String _state = 'checking'; // checking | complete | incomplete | error
  Json? _status;
  bool _resuming = false;
  bool _autoPrompted = false;

  @override
  void initState() {
    super.initState();
    closeStripeSheet();
    _verify();
  }

  /// Landing here does NOT mean onboarding succeeded: ask the backend to verify against Stripe.
  Future<void> _verify() async {
    final id = ref.read(authProvider).id;
    if (id.isEmpty) {
      setState(() => _state = 'error');
      return;
    }
    setState(() => _state = 'checking');
    try {
      final data = await hostRepo.refreshStripeStatus(id);
      if (!mounted) return;
      setState(() {
        _status = data;
        _state = data['onboardingComplete'] == true ? 'complete' : 'incomplete';
      });
      // Auto-open the billing form once, only when Stripe is done and billing is genuinely outstanding.
      if (data['onboardingComplete'] == true && asList(data['missingBillingFields']).isNotEmpty && !_autoPrompted) {
        _autoPrompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openBilling();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _state = 'error');
    }
  }

  Future<void> _openBilling() async {
    Json? billing;
    try {
      billing = asMap((await hostRepo.account())['billing']);
    } catch (_) {
      // Prefill is a convenience; the form still works without it.
    }
    if (!mounted) return;
    await showHostBillingSheet(context, billing: billing, onSaved: (_) {
      if (mounted) setState(() => _status = {...?_status, 'missingBillingFields': []});
    });
  }

  Future<void> _resume() async {
    final id = ref.read(authProvider).id;
    setState(() => _resuming = true);
    try {
      final url = await hostRepo.stripeOnboardingUrl(id);
      if (url.isNotEmpty && mounted) {
        await openStripeOnboarding(context, url, returnTo: widget.returnTo);
      }
    } catch (_) {
      // Stays on this page; the button becomes available again.
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final checking = _state == 'checking';
    final stripeComplete = _state == 'complete';
    final missing = asStringList(_status?['missingBillingFields']);
    final ready = stripeComplete && missing.isEmpty;
    final needsBilling = stripeComplete && missing.isNotEmpty;
    final problem = _state == 'incomplete' || _state == 'error' || needsBilling;

    final title = checking
        ? t('OnboardVerifying', 'Overujeme váš účet…')
        : needsBilling
            ? t('OnboardBillingTitle', 'Posledný krok')
            : ready
                ? t('OnboardComplete', 'Váš účet je pripravený')
                : _state == 'error'
                    ? t('OnboardError', 'Váš účet sa nepodarilo overiť')
                    : t('OnboardIncomplete', 'Stripe potrebuje viac informácií');
    final body = checking
        ? t('OnboardVerifyingBody', 'Potvrdzujeme vaše údaje v službe Stripe. Chvíľu to potrvá.')
        : needsBilling
            ? t('OnboardBillingBody', 'Stripe vás overil. Potrebujeme ešte vaše fakturačné údaje — raz mesačne vám vystavujeme faktúru za poplatok platformy a bez nich sa vaše ponuky nedajú rezervovať.')
            : ready
                ? t('OnboardCompleteBody', 'Stripe overil vaše údaje. Teraz môžete prijímať výplaty za rezervácie.')
                : _state == 'error'
                    ? t('OnboardErrorBody', 'Otvorte svoj profil a skúste pripojenie znova. Ak sa to opakuje, kontaktujte podporu.')
                    : t('OnboardIncompleteBody', 'Stripe ešte neukončil overovanie vášho účtu, preto sú výplaty zatiaľ pozastavené.');

    final due = asStringList(_status?['requirementsDue']);
    final labelKeys = {
      'billing_name': ('BillingFieldName', 'Fakturačné meno', 'Billing name'),
      'ico': ('BillingFieldIco', 'IČO', 'IČO (business ID)'),
      'dic': ('BillingFieldDic', 'DIČ', 'DIČ (tax ID)'),
      'billing_address_street': ('BillingFieldStreet', 'Ulica a číslo', 'Street and number'),
      'billing_address_city': ('BillingFieldCity', 'Mesto', 'City'),
      'billing_address_zip': ('BillingFieldZip', 'PSČ', 'Postcode'),
      'billing_address_country': ('BillingFieldCountry', 'Krajina', 'Country'),
    };
    String fieldLabel(String k) {
      final e = labelKeys[k];
      return e == null ? k : t(e.$1, t.pick(e.$2, e.$3));
    }

    final back = widget.returnTo ?? '';
    final hasReturn = back.startsWith('/') && back != '/host/payouts';
    final goLabel = hasReturn
        ? (back.startsWith('/host/listings') ? t.pick('Späť k ubytovaniu', 'Back to your listing') : t.pick('Pokračovať', 'Continue'))
        : t('OnboardGoToPayouts', 'Prejsť na nastavenia výplat');
    void goNext() => context.go(hasReturn ? back : '/host/payouts');

    final showBadges = _status?['chargesEnabled'] != null && !checking;
    return _OnboardCard(
      problem: problem,
      busy: checking,
      title: title,
      body: body,
      extra: [
        if (_state == 'incomplete' && due.isNotEmpty) _listBox(t('OnboardStillNeeded', 'Stripe stále potrebuje'), [for (final r in due) r.replaceAll(RegExp(r'[._]'), ' ')]),
        if (needsBilling) _listBox(t('OnboardBillingMissing', 'Doplňte fakturačné údaje'), [for (final f in missing) fieldLabel(f)]),
      ],
      actions: checking
          ? const []
          : [
              if (needsBilling) _primary(t('OnboardAddBilling', 'Pridať fakturačné údaje'), _openBilling),
              if (_state == 'incomplete') _primary(_resuming ? t('OnboardOpening', 'Otváram Stripe…') : t('OnboardContinue', 'Pokračovať v registrácii'), _resuming ? null : _resume),
              if (_state == 'incomplete' || needsBilling) _secondary(goLabel, goNext) else _primary(goLabel, goNext),
              _secondary(t('ReturnHome', 'Späť domov'), () => context.go('/')),
            ],
      footer: showBadges
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.neutral100)),
              child: Wrap(spacing: 8, children: [
                Text('${t('OnboardPayments', 'Platby')}: ${_status?['chargesEnabled'] == true ? '✓' : '—'}', style: AppText.inter(size: 11, weight: FontWeight.w500, color: AppColors.neutral400)),
                Text('${t('OnboardPayouts', 'Výplaty')}: ${_status?['payoutsEnabled'] == true ? '✓' : '—'}', style: AppText.inter(size: 11, weight: FontWeight.w500, color: AppColors.neutral400)),
                Text('${t('OnboardBilling', 'Fakturácia')}: ${missing.isEmpty ? '✓' : '—'}', style: AppText.inter(size: 11, weight: FontWeight.w500, color: AppColors.neutral400)),
              ]),
            )
          : null,
    );
  }
}

// ───────────────────────────── Refresh ─────────────────────────────
/// Stripe's refresh_url: the link expired, so mint a fresh one and send the host straight back in.
class HostOnboardRefreshScreen extends ConsumerStatefulWidget {
  const HostOnboardRefreshScreen({super.key});
  @override
  ConsumerState<HostOnboardRefreshScreen> createState() => _RefreshState();
}

class _RefreshState extends ConsumerState<HostOnboardRefreshScreen> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    closeStripeSheet();
    _restart();
  }

  Future<void> _restart() async {
    final id = ref.read(authProvider).id;
    if (id.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    setState(() => _failed = false);
    try {
      // The backend reuses the existing connected account, so this only mints a new link.
      final url = await hostRepo.stripeOnboardingUrl(id);
      if (!mounted) return;
      if (url.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      await openStripeOnboarding(context, url);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return _OnboardCard(
      problem: _failed,
      busy: !_failed,
      title: _failed ? t('OnboardError', 'Stripe sa nepodarilo znova otvoriť') : t('OnboardRefreshing', 'Znova otvárame Stripe…'),
      body: _failed
          ? t('OnboardErrorBody', 'Otvorte svoj profil a skúste pripojenie znova. Ak sa to opakuje, kontaktujte podporu.')
          : t('OnboardRefreshingBody', 'Platnosť predchádzajúceho odkazu Stripe vypršala. Vraciame vás späť, aby ste dokončili nastavenie výplat.'),
      actions: _failed
          ? [
              _primary(t.pick('Skúsiť znova', 'Try again'), _restart),
              _secondary(t('OnboardGoToPayouts', 'Prejsť na nastavenia výplat'), () => context.go('/host/payouts')),
              _secondary(t('ReturnHome', 'Späť domov'), () => context.go('/')),
            ]
          : const [],
    );
  }
}
