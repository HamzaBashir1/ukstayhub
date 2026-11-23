import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../widgets/common.dart';
import 'host_payout_removal.dart';
import 'host_shell.dart';
import 'stripe_onboarding.dart';

/// host/payouts/* – accounts panel, earnings and listing status.

const _forest = AppColors.hostForest;
const _teal = Color(0xFF319A81);
const _tealText = Color(0xFF257562);

String _money(int cents, String currency, Strings t) {
  final amount = cents / 100;
  try {
    return NumberFormat.currency(locale: 'en_GB', name: currency.toUpperCase()).format(amount);
  } catch (_) {
    return '${amount.toStringAsFixed(2)} ${currency.toUpperCase()}';
  }
}

String _day(dynamic iso, Strings t) {
  final d = DateTime.tryParse(asString(iso));
  return d == null ? '' : DateFormat('d MMM y', 'en_GB').format(d.toLocal());
}

String _pretty(dynamic req) => asString(req).replaceAll(RegExp(r'[._]'), ' ');

String _nameOf(Json a) {
  final l = asString(a['label']);
  if (l.isNotEmpty) return l;
  final i = asString(a['payoutIban']);
  return i.isNotEmpty ? i : asString(a['accountId']);
}

Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

BoxDecoration _card() => BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]);

class HostPayoutsScreen extends ConsumerStatefulWidget {
  const HostPayoutsScreen({super.key});
  @override
  ConsumerState<HostPayoutsScreen> createState() => _HostPayoutsScreenState();
}

class _HostPayoutsScreenState extends ConsumerState<HostPayoutsScreen> {
  List<Json> _accounts = const [];
  final _refreshKey = GlobalKey<_EarningsState>();

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final sm = width >= 640;
    final owned = ref.watch(hostOwnedProvider);
    final pad = EdgeInsets.all(sm ? 24 : 16);

    return RefreshIndicator(
      color: _forest,
      onRefresh: () async {
        ref.invalidate(hostOwnedProvider);
        ref.invalidate(hostStripeAccountsPanelProvider);
        await _refreshKey.currentState?.reload();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 768),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: wide ? 0 : 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(t.pick('Výplaty', 'Payouts'), style: AppText.inter(size: wide ? 30 : 24, weight: FontWeight.w700, color: _forest, height: 1.25)),
                  const SizedBox(height: 4),
                  Text(t.pick('Kam sa vyplácajú vaše rezervácie a čo od vás Stripe ešte potrebuje.', 'Where your bookings are paid out, and what Stripe still needs from you.'), style: AppText.inter(size: 15, color: AppColors.neutral500, height: 1.5)),
                  const SizedBox(height: 24),
                  Container(
                    padding: pad,
                    decoration: _card(),
                    child: _AccountsPanel(owned: owned.valueOrNull ?? const [], onAccounts: (a) => WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() => _accounts = a);
                        })),
                  ),
                  const SizedBox(height: 24),
                  _Earnings(key: _refreshKey, accounts: _accounts, pad: pad),
                  const SizedBox(height: 24),
                  Container(padding: pad, decoration: _card(), child: _ListingStatus(owned: owned, accounts: _accounts)),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Accounts panel (PayoutAccountsPanel.js) ─────────────────────────────
final hostStripeAccountsPanelProvider = FutureProvider.autoDispose<Json>((ref) async {
  final id = ref.watch(authProvider).id;
  if (id.isEmpty) return const {};
  final r = asMap(await hostRepo.stripeAccountsRaw(id));
  return r;
});

String _stateOf(Json a) {
  if (a['payoutsEnabled'] == true && a['transfersActive'] == true) return 'active';
  final s = asString(a['payoutState']);
  if (s.isNotEmpty) return s;
  if (asString(a['disabledReason']).isNotEmpty || asList(a['pastDue']).isNotEmpty) return 'restricted';
  if (asList(a['requirementsDue']).isNotEmpty) return 'pending';
  if (asList(a['pendingVerification']).isNotEmpty) return 'verifying';
  return 'pending';
}

class _AccountsPanel extends ConsumerStatefulWidget {
  const _AccountsPanel({required this.owned, required this.onAccounts});
  final List<Json> owned;
  final ValueChanged<List<Json>> onAccounts;
  @override
  ConsumerState<_AccountsPanel> createState() => _AccountsPanelState();
}

class _AccountsPanelState extends ConsumerState<_AccountsPanel> {
  bool _refreshing = false;
  String? _busy;
  String? _makingDefault;
  bool _connecting = false;
  bool _showConnect = false;
  final _label = TextEditingController();
  final _assigning = <String>{};
  final _assigned = <String, String>{};
  List<Json>? _override;
  List<Json>? _removedOverride;
  final _assignKey = GlobalKey();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  /// After a remove / restore / delete the server answers with the new lists; a partial answer leaves the rest alone.
  void _applyChange(Json data) {
    if (data['accounts'] is List) {
      final list = asMapList(data['accounts']);
      setState(() => _override = list);
      widget.onAccounts(list);
    }
    if (data['removedAccounts'] is List) setState(() => _removedOverride = asMapList(data['removedAccounts']));
  }

  Future<void> _refreshFromStripe() async {
    final id = ref.read(authProvider).id;
    setState(() => _refreshing = true);
    try {
      final list = await hostRepo.stripeAccounts(id, sync: true);
      if (mounted) setState(() => _override = list);
      widget.onAccounts(list);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _connectNew(Strings t) async {
    final id = ref.read(authProvider).id;
    setState(() => _connecting = true);
    try {
      final url = await hostRepo.connectStripeAccountLabelled(id, _label.text.trim(), '/host/payouts');
      if (url.isEmpty) throw ApiException(t('PayoutConnectFailed', 'Nepodarilo sa spustiť registráciu'));
      if (mounted) await openStripeOnboarding(context, url, returnTo: '/host/payouts');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _openAccount(Strings t, String accountId) async {
    setState(() => _busy = accountId);
    try {
      final url = await hostRepo.stripeAccountLink(ref.read(authProvider).id, accountId);
      if (url.isEmpty) throw ApiException(t('PayoutConnectFailed', 'Nepodarilo sa spustiť registráciu'));
      if (mounted) await openStripeOnboarding(context, url, returnTo: '/host/payouts');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _dashboard(String accountId) async {
    setState(() => _busy = accountId);
    try {
      final url = await hostRepo.stripeDashboardLink(ref.read(authProvider).id, accountId);
      if (url.isNotEmpty) await _open(url);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _makeDefault(Strings t, String accountId) async {
    setState(() => _makingDefault = accountId);
    try {
      final list = await hostRepo.setDefaultStripeAccount(ref.read(authProvider).id, accountId);
      if (!mounted) return;
      setState(() => _override = list);
      widget.onAccounts(list);
      toast(context, t('PayoutDefaultChanged', 'Predvolený účet bol zmenený.'));
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _makingDefault = null);
    }
  }

  Future<void> _assign(Strings t, String listingId, String accountId) async {
    final prev = _assigned[listingId] ?? '';
    setState(() {
      _assigned[listingId] = accountId;
      _assigning.add(listingId);
    });
    try {
      await hostRepo.assignListingPayoutAccount(listingId, accountId);
      if (mounted) {
        toast(context, t('PayoutListingUpdated', 'Výplatný účet ponuky bol aktualizovaný.'));
        ref.invalidate(hostOwnedProvider);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _assigned[listingId] = prev);
        toast(context, errorText(e), error: true);
      }
    } finally {
      if (mounted) setState(() => _assigning.remove(listingId));
    }
  }

  Widget _pill(String state, Strings t) {
    final (label, icon, bg, fg, border) = switch (state) {
      'active' => (t('PayoutStateActive', 'Aktívny'), Icons.check_circle_outline, _teal.withValues(alpha: 0.1), _tealText, _teal.withValues(alpha: 0.2)),
      'verifying' => (t('PayoutStateVerifying', 'Overuje sa'), Icons.sync, AppColors.hostGold.withValues(alpha: 0.15), const Color(0xFF9A7A3A), AppColors.hostGold.withValues(alpha: 0.3)),
      'restricted' => (t('PayoutStateRestricted', 'Obmedzený'), Icons.shield_outlined, const Color(0xFFFFE4E6), const Color(0xFF9F1239), const Color(0xFFFECDD3)),
      _ => (t('PayoutStatePending', 'Čaká sa'), Icons.warning_amber_rounded, const Color(0xFFFEF3C7), const Color(0xFF92400E), const Color(0xFFFDE68A)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Text(label.toUpperCase(), style: AppText.inter(size: 10, weight: FontWeight.w700, color: fg, letterSpacing: 1)),
      ]),
    );
  }

  Widget _blockers(Json a, Strings t) {
    final pastDue = asStringList(a['pastDue']);
    final due = asStringList(a['requirementsDue']).where((r) => !pastDue.contains(r)).toList();
    final errors = asMapList(a['requirementErrors']);
    final pending = asStringList(a['pendingVerification']);
    final future = asStringList(a['futureDue']);
    final disabled = asString(a['disabledReason']);
    if (disabled.isEmpty && pastDue.isEmpty && due.isEmpty && errors.isEmpty && pending.isEmpty && future.isEmpty) return const SizedBox.shrink();
    final deadline = DateTime.tryParse(asString(a['currentDeadline']));
    final futureDeadline = DateTime.tryParse(asString(a['futureDeadline']));
    TextStyle s(Color c, {bool bold = false}) => AppText.inter(size: 12, weight: bold ? FontWeight.w500 : FontWeight.w400, color: c, height: 1.45);
    Widget bullets(List<String> items, Color c) => Padding(padding: const EdgeInsets.only(left: 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final r in items) Text('• ${_pretty(r)}', style: s(c))]));
    const rose = Color(0xFFBE123C);
    const amber = Color(0xFFB45309);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (disabled.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${t('PayoutDisabledReason', 'Dôvod pozastavenia')}: ${_pretty(disabled)}', style: s(rose, bold: true))),
        if (errors.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final e in errors) Padding(padding: const EdgeInsets.only(left: 16), child: Text('• ${_pretty(e['requirement'])}${asString(e['reason']).isEmpty ? '' : ' — ${asString(e['reason'])}'}', style: s(rose)))])),
        if (pastDue.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${t('PayoutPastDue', 'Po termíne')}:', style: s(rose, bold: true)), bullets(pastDue, rose)])),
        if (due.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t('PayoutAccountAwaiting', 'Stripe čaká na')}${deadline == null ? '' : ' (${t('PayoutBy', 'do')} ${_day(deadline.toIso8601String(), t)})'}:', style: s(amber, bold: true)),
              bullets(due, amber),
            ]),
          ),
        if (pending.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${t('PayoutUnderReview', 'Prebieha kontrola')}: ${pending.map(_pretty).join(', ')}', style: s(AppColors.neutral500))),
        if (future.isNotEmpty) Text('${t('PayoutFutureDue', 'Čoskoro bude potrebné')}${futureDeadline == null ? '' : ' (${t('PayoutBy', 'do')} ${_day(futureDeadline.toIso8601String(), t)})'}: ${future.map(_pretty).join(', ')}', style: s(AppColors.neutral500)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(hostStripeAccountsPanelProvider);
    final sm = MediaQuery.sizeOf(context).width >= 640;
    final data = async.valueOrNull;
    final accounts = _override ?? asMapList(data?['accounts']);
    final loading = async.isLoading && data == null && _override == null;
    final loadError = async.hasError && data == null && _override == null ? errorText(async.error!) : null;
    if (data != null && _override == null) widget.onAccounts(accounts);

    Widget smallBtn(String label, IconData icon, VoidCallback? onTap, {Color? bg, Color? fg, Color? border, bool spin = false}) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.6 : 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6), border: border == null ? null : Border.all(color: border)),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                spin ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: fg)) : Icon(icon, size: 14, color: fg),
                const SizedBox(width: 4),
                Flexible(child: Text(label, textAlign: TextAlign.center, style: AppText.inter(size: 12, weight: FontWeight.w500, color: fg ?? _forest))),
              ]),
            ),
          ),
        );

    Widget accountRow(Json a) {
      final id = asString(a['accountId']);
      final state = _stateOf(a);
      final busy = _busy == id;
      final isDefault = a['isDefault'] == true;
      final actionLabel = state == 'restricted' ? t('PayoutFixNow', 'Opraviť teraz') : (state == 'active' ? t('PayoutUpdateDetails', 'Upraviť údaje') : t('PayoutFinishSetup', 'Dokončiť nastavenie'));
      final actionColor = state == 'restricted' ? const Color(0xFFE11D48) : (state == 'active' ? const Color(0xFF4B5563) : const Color(0xFFD97706));
      final buttons = [
        if (isDefault)
          smallBtn(t('PayoutAccountDefault', 'Predvolený'), Icons.star, null, bg: _teal.withValues(alpha: 0.1), fg: _tealText, border: _teal.withValues(alpha: 0.3))
        else
          smallBtn(t('PayoutMakeDefault', 'Nastaviť ako predvolený'), Icons.star_border, busy || _makingDefault != null ? null : () => _makeDefault(t, id), fg: AppColors.neutral700, border: AppColors.neutral300, spin: _makingDefault == id),
        smallBtn(busy ? t('PayoutConnectOpening', 'Otváram Stripe…') : actionLabel, Icons.check, busy ? null : () => _openAccount(t, id), bg: actionColor, fg: Colors.white, spin: busy),
        if (state == 'active') smallBtn(t('PayoutOpenStripeDashboard', 'Otvoriť Stripe'), Icons.open_in_new, busy ? null : () => _dashboard(id), fg: AppColors.neutral700, border: AppColors.neutral300),
        // Hidden on the only account: a host always keeps one (the server refuses it too).
        if (accounts.length > 1)
          smallBtn(t('PayoutRemove', 'Odstrániť'), Icons.delete_outline, busy ? null : () => showRemoveAccountDialog(context, hostId: ref.read(authProvider).id, account: a, onChanged: _applyChange, onGoToAssignment: () {
                final c = _assignKey.currentContext;
                if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
              }), fg: const Color(0xFFBE123C), border: const Color(0xFFFECDD3)),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 36, height: 36, decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.neutral200)), child: const Icon(Icons.account_balance_wallet_outlined, size: 16, color: AppColors.neutral600)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(asString(a['label']).isEmpty ? t('PayoutAccountUnnamed', 'Účet bez názvu') : asString(a['label']), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFF1F2937))),
                  if (isDefault)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: _teal.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: _teal.withValues(alpha: 0.2))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.star, size: 12, color: _tealText), const SizedBox(width: 4), Text(t('PayoutAccountDefault', 'Predvolený').toUpperCase(), style: AppText.inter(size: 10, weight: FontWeight.w700, color: _tealText, letterSpacing: 1))]),
                    ),
                  _pill(state, t),
                ]),
                const SizedBox(height: 2),
                Text(asString(a['payoutIban']).isEmpty ? id : '${asString(a['payoutIban'])} · $id', style: AppText.inter(size: 12, color: AppColors.neutral500)),
                _blockers(a, t),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          sm
              ? Wrap(spacing: 8, runSpacing: 8, children: buttons)
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < buttons.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 8), child: buttons[i])]),
        ]),
      );
    }

    final listings = widget.owned;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.neutral200)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
            Text(t('YourPayoutAccounts', 'Vaše výplatné účty'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF1F2937))),
            smallBtn(_refreshing ? t('PayoutRefreshing', 'Obnovujem…') : t('PayoutRefreshStatus', 'Obnoviť stav'), Icons.refresh, _refreshing ? null : _refreshFromStripe, fg: AppColors.neutral600, border: AppColors.neutral300, spin: _refreshing),
          ]),
          const SizedBox(height: 4),
          Text(t('YourPayoutAccountsExplainer', ''), style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.45)),
          const SizedBox(height: 12),
          if (loadError != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFFECACA))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t('PayoutAccountsLoadFailed', 'Výplatné účty sa nepodarilo načítať'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFB91C1C))),
                    Text(loadError, style: AppText.inter(size: 12, color: const Color(0xFFDC2626))),
                  ]),
                ),
                TextButton(onPressed: () => ref.invalidate(hostStripeAccountsPanelProvider), child: Text(t('TryAgain', 'Skúsiť znova'))),
              ]),
            ),
          if (loading)
            Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t('PayoutLoading', 'Načítavam…'), style: AppText.inter(size: 14, color: AppColors.neutral500))])
          else ...[
            if (accounts.isEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(loadError != null ? t('PayoutAccountsUnknown', '') : t('PayoutNoAccountsYet', 'Zatiaľ žiadne výplatné účty.'), style: AppText.inter(size: 14, color: AppColors.neutral500)))
            else
              for (var i = 0; i < accounts.length; i++) ...[if (i > 0) const Divider(height: 1, color: AppColors.neutral100), accountRow(accounts[i])],
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.only(top: 12),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_showConnect)
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('${t('PayoutAccountLabel', 'Názov účtu')} (${t('OptionalLabel', 'voliteľné')})', style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral600))),
                    TextField(controller: _label, maxLength: 60, decoration: InputDecoration(counterText: '', hintText: t('PayoutAccountLabelPlaceholder', ''), isDense: true)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: FilledButton(onPressed: _connecting ? null : () => _connectNew(t), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF357965), minimumSize: const Size(0, 44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))), child: Text(_connecting ? t('PayoutConnectOpening', 'Otváram Stripe…') : t('PayoutContinueToStripe', 'Pokračovať na Stripe'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w500)))),
                      const SizedBox(width: 8),
                      Expanded(child: OutlinedButton(onPressed: _connecting ? null : () => setState(() => _showConnect = false), style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), foregroundColor: AppColors.neutral700, side: const BorderSide(color: AppColors.neutral300), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))), child: Text(t('Cancel', 'Zrušiť'), style: AppText.inter(size: 14, weight: FontWeight.w500)))),
                    ]),
                  ])
                else
                  Align(
                    alignment: sm ? Alignment.centerLeft : Alignment.center,
                    child: FilledButton.icon(
                      onPressed: () => setState(() => _showConnect = true),
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(accounts.isNotEmpty ? t('ConnectAnotherStripeAccount', 'Pripojiť ďalší Stripe účet') : t('ConnectStripeAccount', 'Pripojiť Stripe účet'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w500)),
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF357965), minimumSize: Size(sm ? 0 : double.infinity, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(t('ConnectStripeAccountHint', ''), style: AppText.inter(size: 12, color: AppColors.neutral400)),
              ]),
            ),
            if (accounts.isNotEmpty && listings.isNotEmpty)
              Container(
                key: _assignKey,
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.only(top: 12),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(t('PayoutListingAssignment', 'Výplatný účet pre každú ponuku'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF1F2937))),
                  const SizedBox(height: 4),
                  Text(t('PayoutListingAssignmentExplainer', ''), style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.45)),
                  const SizedBox(height: 12),
                  for (final l in listings)
                    Builder(builder: (_) {
                      final lid = asString(l['id'], asString(l['_id']));
                      final current = _assigned[lid] ?? asString(l['payoutStripeAccountId']);
                      final known = accounts.any((a) => asString(a['accountId']) == current);
                      final dropdown = Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.neutral300)),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: known ? current : '',
                            isExpanded: true,
                            style: AppText.inter(size: 12, color: AppColors.neutral800),
                            items: [DropdownMenuItem(value: '', child: Text(t('PayoutUseDefaultAccount', 'Použiť predvolený účet'))), for (final a in accounts) DropdownMenuItem(value: asString(a['accountId']), child: Text(_nameOf(a), overflow: TextOverflow.ellipsis))],
                            onChanged: _assigning.contains(lid) ? null : (v) => _assign(t, lid, v ?? ''),
                          ),
                        ),
                      );
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: sm
                            ? Row(children: [Expanded(child: Text(asString(l['name']), style: AppText.inter(size: 14, color: const Color(0xFF1F2937)))), if (_assigning.contains(lid)) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))), SizedBox(width: 240, child: dropdown)])
                            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text(asString(l['name']), style: AppText.inter(size: 14, color: const Color(0xFF1F2937))), const SizedBox(height: 8), dropdown]),
                      );
                    }),
                ]),
              ),
            RemovedAccountsList(hostId: ref.read(authProvider).id, removed: _removedOverride ?? asMapList(data?['removedAccounts']), onChanged: _applyChange),
          ],
        ]),
      ),
    ]);
  }
}

// ───────────────────────────── Earnings (HostPayoutEarnings.js + PayoutRows.js) ─────────────────────────────
class _Earnings extends ConsumerStatefulWidget {
  const _Earnings({super.key, required this.accounts, required this.pad});
  final List<Json> accounts;
  final EdgeInsets pad;
  @override
  ConsumerState<_Earnings> createState() => _EarningsState();
}

class _EarningsState extends ConsumerState<_Earnings> {
  List<Json> _payable = const [];
  String _status = 'loading';
  int _delayHours = 24;
  Json? _host;
  String? _withdrawing;
  DateTime _now = DateTime.now();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    reload();
    _loadHost();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _loadHost() async {
    final id = ref.read(authProvider).id;
    if (id.isEmpty) return;
    try {
      final h = await hostRepo.hostDocument(id);
      if (mounted) setState(() => _host = h);
    } catch (_) {
      // Billing state gates Withdraw, not the money display; the server refuses with billing_incomplete either way.
    }
  }

  Future<void> reload() async {
    final id = ref.read(authProvider).id;
    if (id.isEmpty) return;
    setState(() => _status = 'loading');
    try {
      final data = await hostRepo.providerReservations(id);
      final rows = <Json>[];
      for (final r in data) {
        if (asString(r['paymentStatus']) != 'paid') continue;
        if (asString(r['isApproved']) == 'cancelled') continue;
        if (asInt(r['refundAmountCents']) > 0) continue;
        if (asInt(r['payoutDelayHours']) > 0) _delayHours = asInt(r['payoutDelayHours']);
        DateTime unlocks;
        final u = DateTime.tryParse(asString(r['payoutUnlocksAt']));
        if (u != null) {
          unlocks = u;
        } else {
          final ci = DateTime.tryParse(asString(r['checkInDate'])) ?? DateTime.now();
          unlocks = DateTime(ci.year, ci.month, ci.day).add(Duration(hours: _delayHours));
        }
        rows.add({...r, '_unlocks': unlocks});
      }
      if (mounted) {
        setState(() {
          _payable = rows;
          _status = 'ready';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _status = 'error');
    }
  }

  List<String> get _missingBilling => asStringList(pick(_host, 'billing.missing'));
  bool get _billingComplete => _host != null && _missingBilling.isEmpty;

  Future<void> _withdraw(Strings t, String reservationId) async {
    if (!_billingComplete) {
      _billingPrompt(t);
      return;
    }
    setState(() => _withdrawing = reservationId);
    try {
      final data = await hostRepo.releasePayout(reservationId);
      if (!mounted) return;
      if (data['success'] == true) {
        toast(context, t('PayoutReleasedToast', 'Výplata bola odoslaná.'));
        setState(() => _payable = [for (final r in _payable) asString(r['_id']) == reservationId ? {...r, 'payoutStatus': 'released', 'transferId': data['transferId'], 'transferredAt': DateTime.now().toIso8601String(), 'payoutLastError': null} : r]);
      } else if (data['retryable'] == true) {
        toast(context, asString(data['error'], t('PayoutQueuedToast', 'Výplata je zaradená.')));
      } else if (asString(data['code']) == 'payouts_disabled' || asString(data['code']) == 'account_restricted') {
        final due = asStringList(data['requirementsDue']).map(_pretty).toList();
        toast(context, due.isEmpty ? asString(data['error']) : '${asString(data['error'])} ${t('PayoutStillNeeded', 'Stripe ešte potrebuje')}: ${due.take(4).join(', ')}${due.length > 4 ? '…' : ''}', error: true);
      } else if (asString(data['code']) == 'billing_incomplete') {
        toast(context, asString(data['error'], t('PayoutBillingRequiredToast', 'Doplňte fakturačné údaje.')), error: true);
        _billingPrompt(t);
      } else {
        toast(context, asString(data['error'], t('PayoutFailedToast', 'Výplatu sa nepodarilo odoslať.')), error: true);
      }
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _withdrawing = null);
    }
  }

  void _billingPrompt(Strings t) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(t('PayoutBillingNeeded', 'Doplňte fakturačné údaje'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
        content: Text(t('PayoutBillingNeededBody', ''), style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('Cancel', 'Zrušiť'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _forest),
            onPressed: () {
              Navigator.pop(ctx);
              context.go('/host/account');
            },
            child: Text(t('PayoutAddBilling', 'Doplniť údaje')),
          ),
        ],
      ),
    );
  }

  String _countdown(DateTime target, Strings t) {
    final ms = target.difference(_now).inMilliseconds;
    if (ms <= 0) return '';
    final minutes = ms ~/ 60000;
    final days = minutes ~/ 1440;
    final hours = (minutes % 1440) ~/ 60;
    final mins = minutes % 60;
    if (days > 0) return hours > 0 ? '${days}d ${hours}h' : '${days}d';
    if (hours > 0) return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
    if (mins > 0) return '${mins}m';
    return '';
  }

  int _sum(List<Json> rows) => rows.fold(0, (a, r) => a + (asDouble(r['hostAmountCents']).round()));

  Json? _destination(Json r) {
    final named = asString(pick(r, 'accommodationId.payoutStripeAccountId'));
    final accounts = widget.accounts;
    return accounts.where((a) => named.isNotEmpty && asString(a['accountId']) == named).firstOrNull ?? accounts.where((a) => a['isDefault'] == true).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (ref.watch(authProvider).id.isEmpty) return const SizedBox.shrink();
    final sm = MediaQuery.sizeOf(context).width >= 640;
    Widget card(Widget child) => Container(padding: widget.pad, decoration: _card(), child: child);
    final title = Text(t.pick('Vaše zárobky', 'Your earnings'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest));

    if (_status == 'loading') {
      return card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 12), Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t.pick('Načítavam vaše výplaty…', 'Loading your payouts…'), style: AppText.inter(size: 14, color: AppColors.neutral500))])]));
    }
    if (_status == 'error') {
      return card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title,
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFECACA))),
          child: Row(children: [
            Expanded(child: Text(t.pick('Výplaty sa nepodarilo načítať.', 'Could not load your payouts.'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFB91C1C)))),
            OutlinedButton(onPressed: reload, style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 44)), child: Text(t.pick('Skúsiť znova', 'Try again'))),
          ]),
        ),
      ]));
    }

    final available = <Json>[], upcoming = <Json>[], failed = <Json>[], history = <Json>[];
    for (final r in _payable) {
      final unlocks = r['_unlocks'] as DateTime;
      final locked = _now.isBefore(unlocks);
      final item = {...r, '_locked': locked};
      if (asString(r['payoutStatus']) == 'released' || asString(r['transferId']).isNotEmpty) {
        history.add(item);
      } else if (asString(r['payoutStatus']) == 'failed') {
        failed.add(item);
      } else if (locked) {
        upcoming.add(item);
      } else {
        available.add(item);
      }
    }
    available.sort((a, b) => asString(a['checkInDate']).compareTo(asString(b['checkInDate'])));
    upcoming.sort((a, b) => (a['_unlocks'] as DateTime).compareTo(b['_unlocks'] as DateTime));
    history.sort((a, b) => asString(b['transferredAt']).compareTo(asString(a['transferredAt'])));
    final currency = [available, upcoming, history].map((l) => l.firstOrNull).whereType<Json>().map((r) => asString(r['currency'])).where((c) => c.isNotEmpty).firstOrNull ?? 'gbp';

    Widget tile(String label, int cents, Color bg, Color border, Color fg) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.toUpperCase(), style: AppText.inter(size: 11, weight: FontWeight.w700, color: fg.withValues(alpha: 0.7), letterSpacing: 1)),
            const SizedBox(height: 4),
            Text(_money(cents, currency, t), style: AppText.inter(size: 20, weight: FontWeight.w700, color: fg)),
          ]),
        );
    final tiles = [
      tile(t('PayoutSummaryAvailable', 'K dispozícii'), _sum(available), const Color(0xFFECFDF5), const Color(0xFFA7F3D0), const Color(0xFF064E3B)),
      tile(t('PayoutSummaryLocked', 'Zamknuté'), _sum(upcoming), const Color(0xFFFFFBEB), const Color(0xFFFDE68A), const Color(0xFF78350F)),
      tile(t('PayoutSummaryReleased', 'Vyplatené'), _sum(history), const Color(0xFFF9FAFB), const Color(0xFFE5E7EB), const Color(0xFF1F2937)),
    ];

    Widget section(String title, String? hint, List<Json> rows, int total, String empty, String tone) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: title, style: AppText.inter(size: 16, weight: FontWeight.w700, color: const Color(0xFF111827))),
              if (rows.isNotEmpty) TextSpan(text: '  (${rows.length})', style: AppText.inter(size: 12, weight: FontWeight.w600, color: const Color(0xFF9CA3AF))),
            ])),
            if (rows.isNotEmpty && total > 0) Text(_money(total, currency, t), style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF374151))),
          ]),
          const SizedBox(height: 8),
          if (hint != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(hint, style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.45))),
          if (rows.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE5E7EB))),
              child: Text(empty, textAlign: TextAlign.center, style: AppText.inter(size: 14, color: const Color(0xFF9CA3AF))),
            )
          else
            for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 12), child: _row(t, r, tone, sm)),
        ]);

    return card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      title,
      const SizedBox(height: 4),
      Text(t.pick('Rezerváciu si môžete vybrať $_delayHours hodín po príchode hosťa. Dovtedy je nižšie uvedená so zostávajúcim časom.', 'A booking can be withdrawn $_delayHours hours after the guest checks in. Until then it is listed below with the time left.'), style: AppText.inter(size: 13, color: AppColors.neutral500, height: 1.45)),
      const SizedBox(height: 16),
      if (_host != null && !_billingComplete)
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFDE68A))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('PayoutBillingNeeded', 'Doplňte fakturačné údaje'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF92400E))),
            const SizedBox(height: 4),
            Text(t('PayoutBillingNeededBody', ''), style: AppText.inter(size: 13, color: const Color(0xFFB45309), height: 1.45)),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => context.go('/host/account'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD97706), minimumSize: const Size(0, 44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))), child: Text(t('PayoutAddBilling', 'Doplniť údaje'), style: AppText.inter(color: Colors.white, size: 13, weight: FontWeight.w700))),
          ]),
        ),
      sm ? Row(children: [for (var i = 0; i < 3; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: tiles[i])]]) : Column(children: [for (var i = 0; i < 3; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 12), child: SizedBox(width: double.infinity, child: tiles[i]))]),
      const SizedBox(height: 24),
      section(t('PayoutAvailableTitle', 'K dispozícii'), t('PayoutAvailableHint', ''), available, _sum(available), t('PayoutAvailableEmpty', 'Nič na vyplatenie.'), 'available'),
      if (failed.isNotEmpty) ...[const SizedBox(height: 24), section(t('PayoutFailedTitle', 'Neúspešné výplaty'), t('PayoutFailedHint', ''), failed, _sum(failed), '', 'failed')],
      const SizedBox(height: 24),
      section(t('PayoutUpcomingTitle', 'Pripravované').replaceAll('{hours}', '$_delayHours'), t('PayoutUpcomingHint', '').replaceAll('{hours}', '$_delayHours'), upcoming, _sum(upcoming), t('PayoutUpcomingEmpty', ''), 'locked'),
      const SizedBox(height: 24),
      section(t('PayoutHistoryTitle', 'História výplat'), null, history, _sum(history), t('PayoutHistoryEmpty', ''), 'released'),
    ]));
  }

  Widget _row(Strings t, Json r, String tone, bool sm) {
    final (cardBg, cardBorder, chipBg, chipFg, icon) = switch (tone) {
      'available' => (const Color(0x99ECFDF5), const Color(0xFFA7F3D0), const Color(0xFFD1FAE5), const Color(0xFF065F46), Icons.check_circle_outline),
      'locked' => (const Color(0x80FFFBEB), const Color(0xFFFDE68A), const Color(0xFFFEF3C7), const Color(0xFF92400E), Icons.schedule),
      'failed' => (const Color(0x99FFF1F2), const Color(0xFFFECDD3), const Color(0xFFFFE4E6), const Color(0xFF9F1239), Icons.warning_amber_rounded),
      _ => (const Color(0xFFF9FAFB), const Color(0xFFE5E7EB), const Color(0xFFE5E7EB), const Color(0xFF374151), Icons.account_balance_wallet_outlined),
    };
    final statusLabel = switch (tone) {
      'available' => t('PayoutStatusReady', 'Pripravené'),
      'locked' => t('PayoutLocked', 'Zamknuté'),
      'failed' => t('PayoutStatusFailed', 'Zlyhalo'),
      _ => t('PayoutStatusSent', 'Odoslané'),
    };
    final hostCents = asDouble(r['hostAmountCents']).round();
    final gross = asDouble(r['totalPriceCents']).round() != 0 ? asDouble(r['totalPriceCents']).round() : (asDouble(r['totalPrice']) * 100).round();
    final known = hostCents > 0;
    final currency = asString(r['currency'], 'gbp');
    final ci = DateTime.tryParse(asString(r['checkInDate']));
    final co = DateTime.tryParse(asString(r['checkOutDate']));
    final nights = ci != null && co != null ? co.difference(ci).inDays.clamp(0, 9999) : 0;
    final unlocks = r['_unlocks'] as DateTime;
    final countdown = tone == 'locked' ? _countdown(unlocks, t) : null;
    final counting = tone == 'locked' && unlocks.isAfter(_now);
    final countdownLabel = counting ? (countdown!.isEmpty ? t.pick('Čoskoro sa odomkne', 'Unlocks soon') : t.pick('Odomkne sa o $countdown', 'Unlocks in $countdown')) : null;
    final blocked = !known ? t('PayoutAmountUnknownHint', 'Suma výplaty nie je známa.') : countdownLabel;
    final dest = _destination(r);
    final persons = asInt(r['numberOfPersons']);
    final ref6 = asString(r['_id']);
    final shortRef = ref6.length > 6 ? ref6.substring(ref6.length - 6).toUpperCase() : ref6.toUpperCase();
    final busy = _withdrawing == asString(r['_id']);
    final canWithdraw = tone == 'available' || tone == 'locked' || tone == 'failed';

    Widget meta(IconData i, String text) => text.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Padding(padding: const EdgeInsets.only(top: 1), child: Icon(i, size: 14, color: const Color(0xFF9CA3AF))), const SizedBox(width: 6), Expanded(child: Text(text, style: AppText.inter(size: 12, color: const Color(0xFF4B5563), height: 1.35)))]),
          );

    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(asString(pick(r, 'accommodationId.name'), t('PayoutPropertyUnknown', 'Neznáma nehnuteľnosť')), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF111827))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(99)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 12, color: chipFg), const SizedBox(width: 4), Text(statusLabel.toUpperCase(), style: AppText.inter(size: 10, weight: FontWeight.w700, color: chipFg, letterSpacing: 1))]),
        ),
      ]),
      meta(Icons.calendar_today_outlined, '${_day(r['checkInDate'], t)} → ${_day(r['checkOutDate'], t)}${nights > 0 ? ' · $nights ${nights == 1 ? t('PayoutNight', 'noc') : t('PayoutNights', 'nocí')}' : ''}'),
      meta(Icons.people_outline, '${asString(r['name'])}${persons > 0 ? ' · $persons ${persons == 1 ? t('PayoutGuest', 'hosť') : t('PayoutGuests', 'hostia')}' : ''}'),
      meta(Icons.home_outlined, '${t('PayoutRef', 'Ref')}: $shortRef${dest != null ? ' · ${t('PaysOutTo', 'Vypláca sa na')} ${_nameOf(dest)}' : ''}'),
      if (tone == 'locked') meta(Icons.schedule, '${t('PayoutUnlocksOn', 'Odomkne sa')} ${DateFormat('d MMM, HH:mm', 'en_GB').format(unlocks.toLocal())}'),
      if (tone == 'released' && asString(r['transferredAt']).isNotEmpty) meta(Icons.check_circle_outline, '${t('PayoutSentOn', 'Odoslané')} ${_day(r['transferredAt'], t)}'),
    ]);

    final amount = Column(crossAxisAlignment: sm ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      Text(known ? _money(hostCents, currency, t) : '—', style: AppText.inter(size: 18, weight: FontWeight.w700, color: const Color(0xFF111827), height: 1.2)),
      Text(known ? '${t('PayoutOfGross', 'z')} ${_money(gross, currency, t)}' : t('PayoutAmountUnknown', 'Suma nie je známa'), style: AppText.inter(size: 11, color: AppColors.neutral500)),
    ]);

    final withdraw = !canWithdraw
        ? null
        : FilledButton.icon(
            onPressed: busy || blocked != null ? null : () => _withdraw(t, asString(r['_id'])),
            icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : (counting ? const Icon(Icons.schedule, size: 16) : const SizedBox.shrink()),
            label: Text(busy ? t('PayoutProcessing', 'Spracúva sa…') : (counting ? countdownLabel! : t('PayoutWithdraw', 'Vybrať')), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w600)),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF059669), disabledBackgroundColor: const Color(0xFFD1D5DB), disabledForegroundColor: const Color(0xFF4B5563), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        sm
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: info),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [amount, if (withdraw != null) ...[const SizedBox(height: 12), withdraw]]),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                info,
                const SizedBox(height: 16),
                Row(children: [Expanded(child: amount), if (withdraw != null) withdraw]),
              ]),
        if (tone == 'failed')
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xB3FFE4E6), borderRadius: BorderRadius.circular(8)),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '${t('PayoutFailedLabel', 'Dôvod')}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: asString(r['payoutLastError']).isEmpty ? t('PayoutFailedUnknown', 'Neznámy dôvod') : asString(r['payoutLastError'])),
                if (asInt(r['payoutAttempts']) > 1) TextSpan(text: '\n${t('PayoutAttempts', 'Pokusov: {n}').replaceAll('{n}', '${asInt(r['payoutAttempts'])}')}'),
                TextSpan(text: '\n${t('PayoutFailedRetryNote', '')}'),
              ]),
              style: AppText.inter(size: 12, color: const Color(0xFF9F1239), height: 1.45),
            ),
          ),
        if (blocked != null && tone == 'available') Padding(padding: const EdgeInsets.only(top: 12), child: Text(blocked, style: AppText.inter(size: 12, color: const Color(0xFF4B5563)))),
        if (gross > 0) Padding(padding: const EdgeInsets.only(top: 12), child: _FeeBreakdown(amountCents: gross, stripeFeeCents: asString(r['paymentStatus']) == 'paid' && r['stripeFeeCents'] != null ? asDouble(r['stripeFeeCents']).round() : null)),
      ]),
    );
  }
}

// ───────────────────────────── Listing status ─────────────────────────────
class _ListingStatus extends ConsumerWidget {
  const _ListingStatus({required this.owned, required this.accounts});
  final AsyncValue<List<Json>> owned;
  final List<Json> accounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final items = owned.valueOrNull ?? const <Json>[];
    final live = items.where((i) => asString(i['listingStatus']) == 'PUBLISHED').length;

    (String, Color, Color, Color) badge(String s) => switch (s) {
          'PUBLISHED' => (t.pick('Zverejnené', 'Live'), const Color(0xFFF0FDF4), const Color(0xFF15803D), const Color(0xFFBBF7D0)),
          'PENDING' => (t.pick('Overuje sa', 'Verifying'), const Color(0xFFFFFBEB), const Color(0xFF92400E), const Color(0xFFFDE68A)),
          _ => (t.pick('Koncept', 'Draft'), AppColors.neutral100, AppColors.neutral600, AppColors.neutral200),
        };

    String accountLine(Json item) {
      final named = accounts.where((a) => asString(a['accountId']) == asString(item['payoutStripeAccountId'])).firstOrNull;
      if (named != null) return _nameOf(named);
      final fallback = accounts.where((a) => a['isDefault'] == true).firstOrNull ?? accounts.firstOrNull;
      return fallback != null ? '${t.pick('Predvolený účet', 'Default account')}: ${_nameOf(fallback)}' : t.pick('Zatiaľ žiadny výplatný účet', 'No payout account yet');
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(alignment: WrapAlignment.spaceBetween, children: [
        Text(t.pick('Stav ponúk', 'Listing status'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
        if (owned.hasValue && items.isNotEmpty) Text('$live / ${items.length} ${t.pick('zverejnených', 'live')}', style: AppText.inter(size: 12, color: AppColors.neutral500)),
      ]),
      const SizedBox(height: 4),
      Text(t.pick('Ponuka sa zverejní sama, keď je overený účet, na ktorý sa vypláca.', 'A listing goes live on its own once the account it pays out to is verified.'), style: AppText.inter(size: 13, color: AppColors.neutral500, height: 1.45)),
      const SizedBox(height: 16),
      if (owned.isLoading && !owned.hasValue)
        Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t.pick('Načítavam vaše nehnuteľnosti…', 'Loading your properties…'), style: AppText.inter(size: 14, color: AppColors.neutral500))])
      else if (owned.hasError && !owned.hasValue)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFECACA))),
          child: Row(children: [
            Expanded(child: Text(t.pick('Nehnuteľnosti sa nepodarilo načítať.', 'Could not load your properties.'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFB91C1C)))),
            OutlinedButton(onPressed: () => ref.invalidate(hostOwnedProvider), style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)), child: Text(t.pick('Skúsiť znova', 'Try again'))),
          ]),
        )
      else if (items.isEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200, width: 2)),
          child: Text(t.pick('Zatiaľ žiadne nehnuteľnosti.', 'No properties yet.'), textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral400)),
        )
      else
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: AppColors.neutral100),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              Container(width: 36, height: 36, decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.neutral200)), child: const Icon(Icons.home_outlined, size: 16, color: AppColors.neutral400)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(asString(items[i]['name']).isEmpty ? t.pick('Ponuka bez názvu', 'Unnamed listing') : asString(items[i]['name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                  Text(accountLine(items[i]), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 12, color: AppColors.neutral500)),
                ]),
              ),
              const SizedBox(width: 12),
              Builder(builder: (_) {
                final (label, bg, fg, border) = badge(asString(items[i]['listingStatus']));
                return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: border)), child: Text(label, style: AppText.inter(size: 11, weight: FontWeight.w700, color: fg, height: 1.45)));
              }),
            ]),
          ),
        ],
    ]);
  }
}

// ───────────────────────────── Fee breakdown (FeeBreakdown.js) ─────────────────────────────
/// Payment split for a booking amount. Figures always come from the server's fee preview, the same
/// calculation the payout uses; nothing is recomputed here. Collapsed until opened, so a list of rows
/// does not mean one request per row.
class _FeeBreakdown extends ConsumerStatefulWidget {
  const _FeeBreakdown({required this.amountCents, this.stripeFeeCents});
  final int amountCents;
  final int? stripeFeeCents;
  @override
  ConsumerState<_FeeBreakdown> createState() => _FeeBreakdownState();
}

class _FeeBreakdownState extends ConsumerState<_FeeBreakdown> {
  bool _open = false;
  Json? _data;
  bool _error = false;

  Future<void> _load() async {
    try {
      final d = await hostRepo.feePreview(widget.amountCents);
      if (mounted) setState(() => _data = d);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final title = t('PaymentBreakdown', t.pick('Rozpis platby', 'Payment breakdown'));
    if (!_open) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          setState(() => _open = true);
          if (_data == null) _load();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200.withValues(alpha: 0.8))),
          child: Row(children: [
            const Icon(Icons.receipt_long_outlined, size: 15, color: _teal),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF1E4636)))),
            const Icon(Icons.keyboard_arrow_down, size: 16, color: AppColors.neutral400),
          ]),
        ),
      );
    }
    final d = _data;
    if (_error) return const SizedBox.shrink();
    if (d == null) return const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))));

    String gbp(num c) => '£${(c.round() / 100).toStringAsFixed(2)}';
    final stripeCost = widget.stripeFeeCents ?? asDouble(d['stripeCostCents']).round();
    final available = asDouble(d['platformFeeCents']).round() - asDouble(d['platformFeeVatCents']).round();
    final shortfall = (stripeCost - available).clamp(0, 1 << 31);
    Widget row(String label, String value, {Color? color}) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: AppText.inter(size: 14, color: AppColors.neutral500)),
          Text(value, style: AppText.inter(size: 14, weight: FontWeight.w600, color: color ?? const Color(0xFF262626))),
        ]);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200.withValues(alpha: 0.8))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(width: 32, height: 32, decoration: BoxDecoration(color: _teal.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.receipt_long_outlined, size: 16, color: _teal)),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF1E4636)))),
          InkWell(onTap: () => setState(() => _open = false), child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.keyboard_arrow_up, size: 16, color: AppColors.neutral400))),
        ]),
        const SizedBox(height: 16),
        row(t('StayAmount', t.pick('Cena pobytu', 'Stay amount')), gbp(asDouble(d['totalAmountCents']))),
        const SizedBox(height: 10),
        row(t('StayHubFee', 'UK Stay Hub fee'), '−${gbp(asDouble(d['platformFeeCents']))}', color: AppColors.neutral600),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: shortfall > 0
              ? Text('${gbp(stripeCost)} ${t('CardProcessing', t.pick('spracovanie karty', 'card processing'))} — ${t('FeeShortfall', t.pick('viac, než tento poplatok pokrýva. UK Stay Hub znáša rozdiel {amount}; vaša výplata sa nemení.', 'more than this fee covers. UK Stay Hub absorbs the {amount} difference; your payout is unaffected.')).replaceAll('{amount}', gbp(shortfall))}', style: AppText.inter(size: 11, color: const Color(0xFFD97706), height: 1.4))
              : Text('${t('StayHubFeeIncludes', t.pick('zahŕňa', 'includes'))} ${gbp(stripeCost)} ${t('CardProcessing', t.pick('spracovanie karty', 'card processing'))}${d['stripeCostIsEstimate'] == true && widget.stripeFeeCents == null ? ' (${t('Estimated', t.pick('odhad', 'estimated'))})' : ''} + ${gbp(asDouble(d['platformFeeVatCents']))} ${t('Vat', 'DPH')}', style: AppText.inter(size: 11, color: AppColors.neutral400, height: 1.4)),
        ),
        if (d['hostPaysStripeFee'] == true) ...[const SizedBox(height: 10), row(t('StripeDeducts', t.pick('Stripe odpočíta', 'Stripe deducts')), '−${gbp(stripeCost)}', color: AppColors.neutral600)],
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.only(top: 12),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral200))),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(t('HostReceives', t.pick('Suma vyplatená hostiteľovi', 'Amount paid to host')), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF1E4636))),
            Text(gbp(asDouble(d['hostPayoutCents'])), style: AppText.inter(size: 18, weight: FontWeight.w800, color: const Color(0xFF2E7D32))),
          ]),
        ),
        const SizedBox(height: 16),
        Text(t('FeeNote', t.pick('Poplatok UK Stay Hub pokrýva náklady na spracovanie karty a DPH z neho — UK Stay Hub si na ňom nenecháva žiadnu maržu.', 'The UK Stay Hub fee is calibrated to cover the card processing cost plus the VAT owed on it — UK Stay Hub takes no margin on it.')), style: AppText.inter(size: 11, color: AppColors.neutral400, height: 1.5)),
      ]),
    );
  }
}
